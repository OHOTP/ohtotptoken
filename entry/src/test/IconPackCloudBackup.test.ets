import { describe, it, expect } from '@ohos/hypium';
import {
  AppPreference,
  AegisIconPack,
  BUILTIN_DEFAULT_PACK_ID,
  HuaweiAccountManager,
  IconPackArchiver,
  IconPackBackupStatus,
  IconPackCloudBackup,
  IconPackDevicePort,
  IconPackRegistry,
  IconPackRestoreResult,
  IconPackSyncState,
  PREF_KEYS,
  mergeEnabledPacks,
} from 'common';
import { MemoryFs } from './fakes/BackupFakes';

/**
 * 图标包云备份状态机测试（Phase 2 FsGateway + IconPackArchiver 端口注入）。
 *
 * 覆盖：IDLE→X→IDLE 互斥转换（含并发拒绝与失败复位）、备份流程
 * （staging/zip/伴生元数据）、5 分钟去抖与云端较新判定、
 * 清理流程、状态查询降级、enabledPacks 合并策略（纯函数）。
 */

/** 可门控的假压缩器：compress 挂起直到测试放行，用于构造并发窗口 */
class GatedArchiver implements IconPackArchiver {
  compressCalls: number = 0;
  decompressCalls: number = 0;
  private release: (() => void) | null = null;
  private gate: Promise<void> | null = null;
  hang: boolean = false;

  compress(_srcDir: string, _destZip: string): Promise<void> {
    this.compressCalls++;
    if (this.hang) {
      this.gate = new Promise<void>((resolve: () => void) => {
        this.release = resolve;
      });
      return this.gate;
    }
    return Promise.resolve();
  }

  decompress(_zipPath: string, _destDir: string): Promise<void> {
    this.decompressCalls++;
    return Promise.resolve();
  }

  releaseGate(): void {
    if (this.release !== null) {
      this.release();
      this.release = null;
    }
  }
}

/** 假设备端口：LocalUnit 下 deviceInfo API 不可用 */
class FakeIconDevice implements IconPackDevicePort {
  deviceId(): string {
    return 'test-odid';
  }

  deviceName(): string {
    return 'TestDevice';
  }
}

/**
 * 假解压器：decompress 时把预置的"zip 内容"写入目标目录（模拟解压产物）。
 * 键为相对路径，值为文件内容。直接写 MemoryFs 公共字段（与既有播种惯例一致），
 * 并逐级登记父目录——真实解压产物包含目录，递归拷贝依赖 dirs 判定 isDirectory。
 */
class FakeUnpackArchiver implements IconPackArchiver {
  contents: Map<string, string> = new Map();
  decompressCalls: number = 0;
  fs: MemoryFs;

  constructor(fs: MemoryFs) {
    this.fs = fs;
  }

  compress(_srcDir: string, _destZip: string): Promise<void> {
    return Promise.resolve();
  }

  decompress(_zipPath: string, destDir: string): Promise<void> {
    this.decompressCalls++;
    this.contents.forEach((content: string, relPath: string) => {
      // 逐级登记父目录（与真实解压一致，供递归拷贝识别子目录）
      const segments = relPath.split('/');
      let prefix = destDir;
      for (let i = 0; i < segments.length - 1; i++) {
        prefix = `${prefix}/${segments[i]}`;
        this.fs.dirs.add(prefix);
      }
      this.fs.files.set(`${destDir}/${relPath}`, content);
    });
    return Promise.resolve();
  }
}

/** 假图标包注册表：内存维护包列表与启用列表，记录全部调用供断言。 */
class FakeIconRegistry implements IconPackRegistry {
  packs: AegisIconPack[] = [];
  enabledPacks: string[] = [];
  removedPacks: string[] = [];
  addedPackPaths: string[] = [];
  loadUserIconsCalls: string[] = [];
  reloadEnabledPacksCalls: number = 0;
  lastAppliedPacks: string[] = [];
  /** addPackFromDevice 对这些路径抛错（模拟损坏包） */
  failAddFor: Set<string> = new Set();

  listPacks(): AegisIconPack[] {
    return this.packs;
  }

  async loadUserIcons(userIconDir: string): Promise<void> {
    this.loadUserIconsCalls.push(userIconDir);
  }

  async addPackFromDevice(path: string): Promise<void> {
    if (this.failAddFor.has(path)) {
      throw new Error('corrupt pack');
    }
    this.addedPackPaths.push(path);
    const pack = new AegisIconPack();
    pack.uuid = 'dyn_' + path.split('/').pop();
    pack.on_device_path = path;
    this.packs.push(pack);
  }

  async removePack(pack: AegisIconPack): Promise<void> {
    this.removedPacks.push(pack.uuid);
    this.packs = this.packs.filter(p => p.on_device_path !== pack.on_device_path);
  }

  getEnabledPacks(): string[] {
    return this.enabledPacks;
  }

  setEnabledPacks(packs: string[]): void {
    this.enabledPacks = packs;
    this.lastAppliedPacks = packs;
  }

  reloadEnabledPacksFromPreference(): void {
    this.reloadEnabledPacksCalls++;
    // 与生产语义一致：恢复前以偏好内容为干净基线
    this.enabledPacks = AppPreference.loadEnabledPacks();
  }
}

function bindDepsWithRegistry(fs: MemoryFs, archiver: IconPackArchiver,
  registry: FakeIconRegistry): void {
  IconPackCloudBackup.getInstance().useDepsForTest({
    fs: fs,
    archiver: archiver,
    device: new FakeIconDevice(),
    registry: registry,
    filesDir: '/data/files',
    cloudDir: '/cloud',
    cacheDir: '/data/cache',
  });
}

function bindDeps(fs: MemoryFs, archiver: IconPackArchiver): void {
  IconPackCloudBackup.getInstance().useDepsForTest({
    fs: fs,
    archiver: archiver,
    device: new FakeIconDevice(),
    filesDir: '/data/files',
    cloudDir: '/cloud',
    cacheDir: '/data/cache',
  });
}

function resetSingleton(): void {
  IconPackCloudBackup.getInstance().resetForTest();
  AppPreference.setPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME, '');
}

/** 让出一轮事件循环（等待挂起操作完成状态迁移，避免用例间竞态） */
function delayForTurn(): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => resolve(), 1);
  });
}

export default function iconPackCloudBackupTest() {
  describe('iconPackCloudBackupTest', () => {
    it('backup_full_flow_writes_zip_meta_and_timestamp', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      const archiver = new GatedArchiver();
      bindDeps(fs, archiver);
      // 本地有图标包内容；假压缩器不产 zip，预置供 copyFile 到 cloudDir
      fs.files.set('/data/files/icon_packs/pack1.json', '{}');
      fs.files.set('/data/cache/icon_packs_backup.zip', 'zip');

      const ok = await IconPackCloudBackup.getInstance().backupIconPacks();
      expect(ok).assertTrue();
      expect(archiver.compressCalls).assertEqual(1);
      // zip 与伴生元数据文件落到 cloudDir
      expect(fs.files.has('/cloud/icon_packs_backup.zip')).assertTrue();
      expect(fs.files.has('/cloud/icon_packs_sync_meta.json')).assertTrue();
      const meta = fs.files.get('/cloud/icon_packs_sync_meta.json') ?? '';
      // 伴生元数据含设备与包列表字段
      expect(meta.includes('"deviceName":"TestDevice"')).assertTrue();
      expect(meta.includes('"packs"')).assertTrue();
      // 时间戳记录（防抖基准）
      const lastTime = AppPreference.getPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME) as string;
      expect(lastTime.length > 0).assertTrue();
      // staging 目录清理
      expect(fs.files.has('/data/cache/icon_pack_staging/icon_packs_meta.json')).assertFalse();
    });

    it('backup_without_content_skips_cleanly', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      const archiver = new GatedArchiver();
      bindDeps(fs, archiver);

      const ok = await IconPackCloudBackup.getInstance().backupIconPacks();
      expect(ok).assertTrue();
      expect(archiver.compressCalls).assertEqual(0);
      expect(fs.files.size).assertEqual(0);
    });

    it('backup_failure_returns_false_and_resets_state_to_idle', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      fs.files.set('/data/files/icon_packs/pack1.json', '{}');
      const archiver = new GatedArchiver();
      bindDeps(fs, archiver);
      fs.failWrite = true;

      const ok = await IconPackCloudBackup.getInstance().backupIconPacks();
      expect(ok).assertFalse();
      // 失败也必须回到 IDLE，否则状态机永久锁死
      expect(IconPackCloudBackup.getInstance().getState()).assertEqual(IconPackSyncState.IDLE);
    });

    it('operations_are_mutually_exclusive_via_state_machine', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      fs.files.set('/data/files/icon_packs/pack1.json', '{}');
      fs.files.set('/data/cache/icon_packs_backup.zip', 'zip');
      const archiver = new GatedArchiver();
      archiver.hang = true;
      bindDeps(fs, archiver);

      // 等待备份进入 BACKING_UP（挂起在 compress 门控上）
      const pending = IconPackCloudBackup.getInstance().backupIconPacks();
      await delayForTurn();
      expect(IconPackCloudBackup.getInstance().getState()).assertEqual(IconPackSyncState.BACKING_UP);

      // 并发操作全部被拒绝
      expect(await IconPackCloudBackup.getInstance().checkCloudBackupNewer()).assertFalse();
      expect(await IconPackCloudBackup.getInstance().clearCloudBackup()).assertFalse();
      const restore = await IconPackCloudBackup.getInstance().restoreIconPacks();
      expect(restore.restoredCount).assertEqual(0);
      expect(restore.restoredFiles).assertEqual(0);

      archiver.releaseGate();
      expect(await pending).assertTrue();
      expect(IconPackCloudBackup.getInstance().getState()).assertEqual(IconPackSyncState.IDLE);
    });

    it('check_newer_true_when_cloud_meta_is_fresher', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      const archiver = new GatedArchiver();
      bindDeps(fs, archiver);
      AppPreference.setPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME, '1000');
      fs.files.set('/cloud/icon_packs_sync_meta.json', '{"version":1,"timestamp":5000,"deviceId":"d","deviceName":"M","enabledPacks":[],"deletedPacks":[],"packs":[]}');

      const newer = await IconPackCloudBackup.getInstance().checkCloudBackupNewer();
      expect(newer).assertTrue();
    });

    it('check_newer_false_when_within_five_minutes_debounce', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      const archiver = new GatedArchiver();
      bindDeps(fs, archiver);
      // 刚刚恢复过（相对 stub 时钟 1 分钟前）→ 去抖跳过
      AppPreference.setPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME, `${Date.now() - 60000}`);
      fs.files.set('/cloud/icon_packs_sync_meta.json', '{"version":1,"timestamp":9999999999999,"deviceId":"","deviceName":"","enabledPacks":[],"deletedPacks":[],"packs":[]}');

      const newer = await IconPackCloudBackup.getInstance().checkCloudBackupNewer();
      expect(newer).assertFalse();
    });

    it('check_newer_false_when_meta_missing', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      const archiver = new GatedArchiver();
      bindDeps(fs, archiver);

      expect(await IconPackCloudBackup.getInstance().checkCloudBackupNewer()).assertFalse();
    });

    it('clear_removes_zip_and_meta_and_returns_true', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      const archiver = new GatedArchiver();
      bindDeps(fs, archiver);
      fs.files.set('/cloud/icon_packs_backup.zip', 'zip');
      fs.files.set('/cloud/icon_packs_sync_meta.json', '{}');

      const ok = await IconPackCloudBackup.getInstance().clearCloudBackup();
      expect(ok).assertTrue();
      expect(fs.files.size).assertEqual(0);
    });

    it('status_reports_zip_and_meta_fields', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      const archiver = new GatedArchiver();
      bindDeps(fs, archiver);
      fs.files.set('/cloud/icon_packs_backup.zip', 'zipdata');
      fs.files.set('/cloud/icon_packs_sync_meta.json',
        '{"version":1,"timestamp":7000,"deviceId":"dev-1","deviceName":"Mate60","enabledPacks":["p1"],"deletedPacks":[],"packs":[{"uuid":"p1","name":"Pack One","version":2,"iconCount":10}]}');

      const status: IconPackBackupStatus = await IconPackCloudBackup.getInstance().getCloudBackupStatus();
      expect(status.exists).assertTrue();
      expect(status.size).assertEqual(7);
      expect(status.packCount).assertEqual(1);
      expect(status.sourceDeviceId).assertEqual('dev-1');
      expect(status.sourceDeviceName).assertEqual('Mate60');
      expect(status.packs.length).assertEqual(1);
      expect(status.packs[0].iconCount).assertEqual(10);
    });

    it('status_falls_back_to_local_pack_count_when_meta_missing', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      const archiver = new GatedArchiver();
      bindDeps(fs, archiver);

      const status = await IconPackCloudBackup.getInstance().getCloudBackupStatus();
      // 无 zip、无 meta：exists=false，包数回退本地内存（LocalUnit 下为 0）
      expect(status.exists).assertFalse();
      expect(status.packCount).assertEqual(0);
    });

    it('merge_enabled_packs_appends_local_only_and_defaults_when_empty', 0, () => {
      // 云端列表为基础，本地独有追加
      let merged = mergeEnabledPacks(['p1', 'p2'], ['p2', 'p3', 'p4']);
      expect(merged.join(',')).assertEqual('p1,p2,p3,p4');

      // 云端为空 → 内置默认包兜底 + 本地追加
      merged = mergeEnabledPacks([], ['p9']);
      expect(merged.join(',')).assertEqual(`${BUILTIN_DEFAULT_PACK_ID},p9`);
    });

    it('restore_returns_empty_result_without_state_leak', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      const archiver = new GatedArchiver();
      bindDeps(fs, archiver);
      // 云端无 zip → stat 失败 → 空结果
      const result: IconPackRestoreResult = await IconPackCloudBackup.getInstance().restoreIconPacks();
      expect(result.restoredCount).assertEqual(0);
      expect(IconPackCloudBackup.getInstance().getState()).assertEqual(IconPackSyncState.IDLE);
    });

    it('restore_full_chain_deletes_refreshes_merges_and_applies', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      const archiver = new FakeUnpackArchiver(fs);
      const registry = new FakeIconRegistry();
      // 本地已有 p1（将被云端 deletedPacks 标记删除）
      const localPack = new AegisIconPack();
      localPack.uuid = 'p1';
      localPack.on_device_path = '/data/files/icon_packs/p1';
      registry.packs.push(localPack);
      registry.enabledPacks = ['p1'];
      bindDepsWithRegistry(fs, archiver, registry);

      // 云端：zip + "解压产物"（新包 packA + 元数据）
      fs.files.set('/cloud/icon_packs_backup.zip', 'zip');
      archiver.contents.set('icon_packs/packA/pack.json', '{"name":"PackA"}');
      archiver.contents.set('icon_packs_meta.json',
        '{"version":1,"timestamp":5000,"enabledPacks":["p2"],"deletedPacks":["p1"],' +
        '"packs":[{"uuid":"p2","name":"Pack Two","version":1,"iconCount":3},{"uuid":"p3","name":"Pack Three","version":1,"iconCount":4}]}');

      const result = await IconPackCloudBackup.getInstance().restoreIconPacks();
      // 恢复结果计数
      expect(result.restoredCount).assertEqual(2);
      expect(result.restoredFiles).assertEqual(1);
      // deletedPacks 清理：p1 被删除
      expect(registry.removedPacks.join(',')).assertEqual('p1');
      // 磁盘重载：user_icons 触达 + 新包 packA 按路径加载
      expect(registry.loadUserIconsCalls.join(',')).assertEqual('/data/files/user_icons');
      expect(registry.addedPackPaths.join(',')).assertEqual('/data/files/icon_packs/packA');
      // 合并应用：云端 enabledPacks 为基础 + 本地新增 packA（dyn_packA）
      expect(registry.lastAppliedPacks.join(',')).assertEqual('p2,dyn_packA');
      // 偏好持久化 + 恢复时间戳更新（防抖基准）
      const saved = AppPreference.getPreference(PREF_KEYS.APPEARANCE_ICON_PACK_ENABLED) as string;
      expect(saved).assertEqual('["p2","dyn_packA"]');
      const lastTime = AppPreference.getPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME) as string;
      expect(lastTime).assertEqual('5000');
      // 临时目录已清理（解压产物不残留）
      expect(fs.files.has('/data/cache/icon_pack_restore/icon_packs_meta.json')).assertFalse();
      // 拷贝确实发生：filesDir 出现解压出的包文件
      expect(fs.files.has('/data/files/icon_packs/packA/pack.json')).assertTrue();
      // 状态机复位
      expect(IconPackCloudBackup.getInstance().getState()).assertEqual(IconPackSyncState.IDLE);
    });

    it('restore_skips_unknown_deleted_uuid_and_broken_pack_load', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      const archiver = new FakeUnpackArchiver(fs);
      const registry = new FakeIconRegistry();
      bindDepsWithRegistry(fs, archiver, registry);
      // deletedPacks 引用本地不存在的 uuid；解压出的包损坏（加载抛错）不得中断恢复
      fs.files.set('/cloud/icon_packs_backup.zip', 'zip');
      archiver.contents.set('icon_packs/broken/pack.json', 'not-json');
      archiver.contents.set('icon_packs_meta.json',
        '{"version":1,"timestamp":6000,"enabledPacks":["p2"],"deletedPacks":["ghost"],' +
        '"packs":[{"uuid":"p2","name":"Pack Two","version":1,"iconCount":1}]}');
      registry.failAddFor.add('/data/files/icon_packs/broken');

      const result = await IconPackCloudBackup.getInstance().restoreIconPacks();
      // 未知 uuid 不触发删除；损坏包跳过后恢复整体仍成功
      expect(registry.removedPacks.length).assertEqual(0);
      expect(result.restoredCount).assertEqual(1);
      expect(registry.lastAppliedPacks.join(',')).assertEqual('p2');
    });

    it('restore_without_meta_copies_files_but_skips_registry_mutations', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      const archiver = new FakeUnpackArchiver(fs);
      const registry = new FakeIconRegistry();
      bindDepsWithRegistry(fs, archiver, registry);
      // zip 存在但无元数据（旧版本备份）：文件拷贝仍执行，注册表不改写
      fs.files.set('/cloud/icon_packs_backup.zip', 'zip');
      archiver.contents.set('user_icons/custom.svg', 'svg-data');

      const result = await IconPackCloudBackup.getInstance().restoreIconPacks();
      expect(result.restoredCount).assertEqual(0);
      expect(result.restoredFiles).assertEqual(1);
      expect(registry.removedPacks.length).assertEqual(0);
      expect(registry.lastAppliedPacks.length).assertEqual(0);
      expect(registry.reloadEnabledPacksCalls).assertEqual(0);
      // 拷贝发生：user_icons 内容落地 filesDir
      expect(fs.files.has('/data/files/user_icons/custom.svg')).assertTrue();
      expect(AppPreference.getPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME) as string).assertEqual('');
    });

    it('auto_restore_full_chain_gated_by_pref_login_and_fires', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      const archiver = new FakeUnpackArchiver(fs);
      const registry = new FakeIconRegistry();
      bindDepsWithRegistry(fs, archiver, registry);
      fs.files.set('/cloud/icon_packs_backup.zip', 'zip');
      // 去抖/较新判定读取的是伴生元数据文件（不解压 zip）
      fs.files.set('/cloud/icon_packs_sync_meta.json', '{"version":1,"timestamp":9000,"deviceId":"d","deviceName":"M","enabledPacks":["cloud1"],"deletedPacks":[],"packs":[{"uuid":"cloud1","name":"C","version":1,"iconCount":1}]}');
      archiver.contents.set('icon_packs_meta.json',
        '{"version":1,"timestamp":9000,"enabledPacks":["cloud1"],"deletedPacks":[],"packs":[{"uuid":"cloud1","name":"C","version":1,"iconCount":1}]}');
      // 账号门禁直接改单例布尔，finally 复位防跨套件泄漏
      HuaweiAccountManager.getInstance().userLogin = false;
      try {
        // 云同步开关关闭 → 直接跳过
        AppPreference.setPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE, false);
        expect(await IconPackCloudBackup.getInstance().checkAndAutoRestore()).assertFalse();

        // 开关开启但账号未登录 → 跳过
        AppPreference.setPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE, true);
        expect(await IconPackCloudBackup.getInstance().checkAndAutoRestore()).assertFalse();

        // 登录后整链路执行：恢复成功返回 true，状态机复位
        HuaweiAccountManager.getInstance().userLogin = true;
        expect(await IconPackCloudBackup.getInstance().checkAndAutoRestore()).assertTrue();
        expect(registry.lastAppliedPacks.join(',')).assertEqual('cloud1');
        expect(AppPreference.getPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME) as string).assertEqual('9000');
        expect(IconPackCloudBackup.getInstance().getState()).assertEqual(IconPackSyncState.IDLE);
      } finally {
        HuaweiAccountManager.getInstance().userLogin = false;
      }
    });

    it('auto_restore_skips_when_local_already_fresh', 0, async () => {
      resetSingleton();
      HuaweiAccountManager.getInstance().userLogin = true;
      const fs = new MemoryFs();
      const archiver = new FakeUnpackArchiver(fs);
      const registry = new FakeIconRegistry();
      bindDepsWithRegistry(fs, archiver, registry);
      AppPreference.setPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE, true);
      // 刚刚恢复过（相对 stub 时钟 1 分钟前）→ 去抖内不自动恢复。
      // 伴生元数据存在且时间戳更新，保证走的是去抖分支而非"缺 meta"分支
      AppPreference.setPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME, `${Date.now() - 60000}`);
      fs.files.set('/cloud/icon_packs_backup.zip', 'zip');
      fs.files.set('/cloud/icon_packs_sync_meta.json', '{"version":1,"timestamp":9999999999999,"deviceId":"","deviceName":"","enabledPacks":[],"deletedPacks":[],"packs":[]}');
      archiver.contents.set('icon_packs_meta.json',
        '{"version":1,"timestamp":9999999999999,"enabledPacks":[],"deletedPacks":[],"packs":[]}');

      try {
        expect(await IconPackCloudBackup.getInstance().checkAndAutoRestore()).assertFalse();
        expect(archiver.decompressCalls).assertEqual(0);
      } finally {
        HuaweiAccountManager.getInstance().userLogin = false;
      }
    });
  });
}
