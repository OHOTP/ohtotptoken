import { hilog } from '@kit.PerformanceAnalysisKit';
import { cloudSync, fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { zlib } from '@kit.BasicServicesKit';
import { AppPreference, PREF_KEYS, BUILTIN_DEFAULT_PACK_ID, EVENT_NAMES } from './AppPreference';
import { TokenIconPacks, AegisIconPack } from './TokenUtils';
import { SyncTimeHelper } from './SyncTimeHelper';
import { HuaweiAccountManager } from './HuaweiAccountManager';
import { DeviceInfoHelper } from './DeviceInfoHelper';
import { FsGateway, FileIoFsGateway } from './StoragePorts';

const TAG = 'IconPackCloudBackup';
const DOMAIN = 0xFF00;
const ICON_PACK_BACKUP_ZIP = 'icon_packs_backup.zip';
const META_JSON_NAME = 'icon_packs_meta.json';
/**
 * 云端伴生元数据文件名（放在 cloudDir，与 zip 同级）。
 * 仅 ~1-2KB，包含时间戳、设备信息、图标包列表。
 * checkCloudBackupNewer 只读取此文件而不用解压整个 zip，大幅降低冷启动开销。
 */
const SYNC_META_FILE = 'icon_packs_sync_meta.json';

/** zip 压缩/解压端口（生产：zlib，LocalUnit 不可用）。 */
export interface IconPackArchiver {
  compress(srcDir: string, destZip: string): Promise<void>;
  decompress(zipPath: string, destDir: string): Promise<void>;
}

class ZlibIconPackArchiver implements IconPackArchiver {
  async compress(srcDir: string, destZip: string): Promise<void> {
    const options: zlib.Options = {
      level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION,
    };
    await zlib.compressFile(srcDir, destZip, options);
  }

  async decompress(zipPath: string, destDir: string): Promise<void> {
    await zlib.decompressFile(zipPath, destDir);
  }
}

/**
 * 恢复时的启用列表合并策略（纯函数）：
 * 以云端 enabledPacks 为基础（为空则回退内置默认包），追加本地独有的包（不丢失本地新增包）。
 */
export function mergeEnabledPacks(cloudEnabledPacks: string[], localPackUuids: string[]): string[] {
  const basePacks = cloudEnabledPacks && cloudEnabledPacks.length > 0
    ? cloudEnabledPacks
    : [BUILTIN_DEFAULT_PACK_ID];
  const merged = [...basePacks];
  for (const localUuid of localPackUuids) {
    if (!merged.includes(localUuid)) {
      merged.push(localUuid);
    }
  }
  return merged;
}

/** 设备标识端口（生产：DeviceInfoHelper，LocalUnit 不可用）。 */
export interface IconPackDevicePort {
  deviceId(): string;
  deviceName(): string;
}

class DeviceInfoAdapter implements IconPackDevicePort {
  deviceId(): string {
    return DeviceInfoHelper.getInstance().getDeviceId();
  }

  deviceName(): string {
    return DeviceInfoHelper.getInstance().getDeviceName();
  }
}

/**
 * 图标包注册表端口（Phase 3，docs/TEST_PLAN.md 第 4 节）。
 * 恢复成功链路（deletedPacks 清理 → 磁盘重载 → enabledPacks 合并应用）经此端口
 * 访问 TokenIconPacks 静态状态，LocalUnit 注入内存假实现全测；
 * 生产适配器保证真机行为不变（磁盘加载/偏好读写归 TokenIconPacks/AppPreference）。
 */
export interface IconPackRegistry {
  /** 当前已加载的自定义图标包（含无效包） */
  listPacks(): AegisIconPack[];
  /** 从 user_icons 目录重载用户图标 */
  loadUserIcons(userIconDir: string): Promise<void>;
  /** 从设备目录加载图标包（pack.json 解析 + 磁盘读取） */
  addPackFromDevice(path: string): Promise<void>;
  /** 删除图标包（清理预览缓存、enabledPacks 过滤、磁盘目录删除） */
  removePack(pack: AegisIconPack): Promise<void>;
  getEnabledPacks(): string[];
  setEnabledPacks(packs: string[]): void;
  /** 从偏好重新加载 enabledPacks 到内存（恢复前的干净基线） */
  reloadEnabledPacksFromPreference(): void;
}

/** {@link IconPackRegistry} 生产实现：委托 TokenIconPacks 静态接口。 */
class TokenIconPacksRegistry implements IconPackRegistry {
  listPacks(): AegisIconPack[] {
    return TokenIconPacks.aegis_icon_packs;
  }

  async loadUserIcons(userIconDir: string): Promise<void> {
    await TokenIconPacks.addUserIconPack(userIconDir);
  }

  async addPackFromDevice(path: string): Promise<void> {
    await TokenIconPacks.addAegisIconPack(path);
  }

  async removePack(pack: AegisIconPack): Promise<void> {
    await TokenIconPacks.removeAegisIconPack(pack);
  }

  getEnabledPacks(): string[] {
    return TokenIconPacks.enabled_packs;
  }

  setEnabledPacks(packs: string[]): void {
    TokenIconPacks.enabled_packs = packs;
  }

  reloadEnabledPacksFromPreference(): void {
    TokenIconPacks.enabled_packs = AppPreference.loadEnabledPacks();
  }
}

/** LocalUnit 测试注入项（目录就绪时跳过 init() 的 AppStorage 依赖）。 */
export interface IconPackBackupTestDeps {
  fs?: FsGateway;
  archiver?: IconPackArchiver;
  device?: IconPackDevicePort;
  registry?: IconPackRegistry;
  filesDir?: string;
  cloudDir?: string;
  cacheDir?: string;
}

/**
 * 图标包云备份同步状态机
 *
 * 状态转换图：
 *   IDLE ──→ BACKING_UP ──→ IDLE   (备份图标包到云端)
 *   IDLE ──→ RESTORING   ──→ IDLE   (从云端恢复图标包)
 *   IDLE ──→ CLEARING    ──→ IDLE   (清除云端图标包备份)
 *   IDLE ──→ CHECKING    ──→ IDLE   (检查云端备份是否较新)
 *
 * 规则：只有 IDLE 状态才能转换到其他状态，任何操作结束后（无论成功/失败）均回到 IDLE。
 * 这确保了备份、恢复、清理、检查四类操作互斥，不会同时操作同一组文件。
 *
 * 生命周期：纯内存态（实例变量），不持久化。
 * - 应用重启后 singleton 重建，状态自动重置为 IDLE，不会出现永久锁死。
 * - 进程被系统回收同理。
 */
export enum IconPackSyncState {
  IDLE = 0,
  BACKING_UP = 1,
  RESTORING = 2,
  CLEARING = 3,
  CHECKING = 4,
}

export class IconPackRestoreResult {
  restoredCount: number = 0;
  restoredFiles: number = 0;
}

export class IconPackBackupStatus {
  exists: boolean = false;
  packCount: number = 0;
  size: number = 0;
  lastTime: string = '';
  sourceDeviceName: string = '';
  sourceDeviceId: string = '';
  packs: PackMetaEntry[] = [];
}

export class PackMetaEntry {
  uuid: string = '';
  name: string = '';
  version: number = 0;
  iconCount: number = 0;
}

/**
 * 备份 zip 内的元数据记录，包含时间戳、启用的图标包列表、已删除的图标包列表等。
 */
class IconPackMetaRecord {
  version: number = 0;
  timestamp: number = 0;
  enabledPacks: string[] = [];
  deletedPacks: string[] = [];
  packs: PackMetaEntry[] = [];
}

/**
 * 云端伴生元数据文件的结构（SYNC_META_FILE）。
 * 与 zip 同级存放，供 checkCloudBackupNewer 直接读取，避免解压整个 zip。
 * 含设备信息便于 UI 展示"此备份来自 xxx 设备"。
 */
class SyncMetaRecord {
  version: number = 0;
  timestamp: number = 0;
  deviceId: string = '';
  deviceName: string = '';
  enabledPacks: string[] = [];
  deletedPacks: string[] = [];
  packs: PackMetaEntry[] = [];
}

/**
 * 图标包云备份/恢复管理器（单例）
 *
 * 职责：
 * 1. 将 icon_packs/ 和 user_icons/ 目录打包为 zip，通过 FileSync 上传到华为云
 * 2. 从云端下载 zip，解压并合并到本地 filesDir
 * 3. 管理 enabledPacks 列表的云端同步（随 token 备份一起序列化）
 *
 * 线程安全：ArkTS 单线程事件循环，通过 IconPackSyncState 状态机保证操作互斥，
 * 不需要真正的锁。所有公开异步方法在入口处 tryTransition，在 finally 中回到 IDLE。
 *
 * 状态机生命周期：纯内存态，不持久化。应用重启后 singleton 重建，自动恢复 IDLE。
 *
 * ## Phase 2 解耦
 * 文件系统经 {@link FsGateway} 端口、压缩经 {@link IconPackArchiver} 端口访问，
 * 状态机/去抖/合并决策在 LocalUnit 下可测（见 docs/TEST_PLAN.md 第 4 节）。
 */
export class IconPackCloudBackup {
  private static instance: IconPackCloudBackup | null = null;
  private context: common.UIAbilityContext | undefined = undefined;
  private cloudDir: string = '';
  private filesDir: string = '';
  private cacheDir: string = '';
  private fileSync: cloudSync.FileSync | null = null;
  /** 状态机当前状态，纯内存态，重启自动重置 */
  private syncState: IconPackSyncState = IconPackSyncState.IDLE;
  private testDeps: IconPackBackupTestDeps | null = null;
  private readonly productionFs: FsGateway = new FileIoFsGateway();
  private readonly productionRegistry: IconPackRegistry = new TokenIconPacksRegistry();

  private constructor() {
  }

  static getInstance(): IconPackCloudBackup {
    if (!IconPackCloudBackup.instance) {
      IconPackCloudBackup.instance = new IconPackCloudBackup();
    }
    return IconPackCloudBackup.instance;
  }

  /** 测试注入：LocalUnit 下 fileIo/zlib 不可用，替换文件系统/压缩端口与目录。 */
  useDepsForTest(deps: IconPackBackupTestDeps): void {
    this.testDeps = deps;
    if (deps.cloudDir !== undefined || deps.filesDir !== undefined || deps.cacheDir !== undefined) {
      // 语义上 context 已就绪：init() 直接短路，不再读 AppStorage
      this.context = new Object() as common.UIAbilityContext;
      this.cloudDir = deps.cloudDir !== undefined ? deps.cloudDir : this.cloudDir;
      this.filesDir = deps.filesDir !== undefined ? deps.filesDir : this.filesDir;
      this.cacheDir = deps.cacheDir !== undefined ? deps.cacheDir : this.cacheDir;
    }
  }

  /** 重置测试注入（恢复生产端口与未初始化状态）。 */
  resetForTest(): void {
    this.testDeps = null;
    this.context = undefined;
    this.cloudDir = '';
    this.filesDir = '';
    this.cacheDir = '';
    this.syncState = IconPackSyncState.IDLE;
  }

  private get fs(): FsGateway {
    return this.testDeps?.fs !== undefined ? this.testDeps.fs : this.productionFs;
  }

  private get archiver(): IconPackArchiver {
    return this.testDeps?.archiver !== undefined ? this.testDeps.archiver : new ZlibIconPackArchiver();
  }

  private get devicePort(): IconPackDevicePort {
    return this.testDeps?.device !== undefined ? this.testDeps.device : new DeviceInfoAdapter();
  }

  private get registry(): IconPackRegistry {
    return this.testDeps?.registry !== undefined ? this.testDeps.registry : this.productionRegistry;
  }

  async init(): Promise<void> {
    if (this.context) {
      return;
    }
    this.context = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;
    if (!this.context) {
      hilog.error(DOMAIN, TAG, 'init: failed to get appContext');
      return;
    }
    this.filesDir = this.context.filesDir;
    this.cloudDir = this.context.cloudFileDir;
    this.cacheDir = this.context.cacheDir;
  }

  /**
   * 冷启动自动恢复入口（Index.ets deferredInit 调用）
   *
   * 流程：IDLE→RESTORING → 前置条件检查 → 检查云端时间戳 → 恢复 → 合并 enabledPacks → 发事件 → IDLE
   * 直接调用 doCheckCloudBackupNewer/doRestoreIconPacks（私有方法，不经过状态检查），
   * 因为整个 check+restore 已在 RESTORING 状态保护下作为原子操作执行。
   */
  async checkAndAutoRestore(): Promise<boolean> {
    await this.init();
    if (!this.context || !this.cloudDir) return false;

    if (!this.tryTransition(IconPackSyncState.RESTORING)) {
      hilog.warn(DOMAIN, TAG, `checkAndAutoRestore: state=${this.syncState}, skip`);
      return false;
    }
    try {
      const enabled = AppPreference.getPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE) as boolean;
      if (!enabled) return false;
      if (!HuaweiAccountManager.getInstance().userLogin) return false;

      if (!await this.doCheckCloudBackupNewer()) return false;

      const result = await this.doRestoreIconPacks();
      if (result.restoredCount > 0 || result.restoredFiles > 0) {
        this.context.eventHub?.emit(EVENT_NAMES.ICON_PACK_CHANGED);
      }
      return result.restoredCount > 0 || result.restoredFiles > 0;
    } finally {
      this.syncState = IconPackSyncState.IDLE;
    }
  }

  /**
   * 备份图标包到云端（由 CloudBackupManager.backupToCloud 在 token 备份成功后 fire-and-forget 调用）
   *
   * 流程：IDLE→BACKING_UP → 检查本地是否有图标包 → 拷贝到 staging → 压缩 zip →
   *       复制到 cloudDir → FileSync.start() → IDLE
   */
  async backupIconPacks(): Promise<boolean> {
    await this.init();
    if (!this.context || !this.cloudDir) {
      return false;
    }
    if (!this.tryTransition(IconPackSyncState.BACKING_UP)) {
      hilog.warn(DOMAIN, TAG, `backupIconPacks: state=${this.syncState}, skip`);
      return false;
    }
    try {
      return await this.doBackupIconPacks();
    } finally {
      this.syncState = IconPackSyncState.IDLE;
    }
  }

  /** 实际备份逻辑：staging 目录构建 → zip 压缩 → 复制到 cloudDir → 触发同步 */
  private async doBackupIconPacks(): Promise<boolean> {
    const iconPackDir = this.filesDir + '/icon_packs';
    const userIconDir = this.filesDir + '/user_icons';
    let hasContent = false;

    try {
      const packFiles = await this.fs.listFiles(iconPackDir);
      if (packFiles.length > 0) hasContent = true;
    } catch (_) {}

    try {
      const userFiles = await this.fs.listFiles(userIconDir);
      if (userFiles.length > 0) hasContent = true;
    } catch (_) {}

    if (!hasContent) {
      hilog.info(DOMAIN, TAG, 'backupIconPacks: no icon packs to backup, skip');
      return true;
    }

    const now = Date.now();
    const packEntries: PackMetaEntry[] = [];
    for (const p of this.registry.listPacks()) {
      const entry = new PackMetaEntry();
      entry.uuid = p.uuid;
      entry.name = p.name;
      entry.version = p.version;
      entry.iconCount = p.icons.length;
      packEntries.push(entry);
    }
    const meta = new IconPackMetaRecord();
    meta.version = 1;
    meta.timestamp = now;
    meta.enabledPacks = this.registry.getEnabledPacks();
    meta.deletedPacks = [];
    meta.packs = packEntries;

    const stagingDir = this.cacheDir + '/icon_pack_staging';
    const metaPath = stagingDir + '/' + META_JSON_NAME;
    const tempZipPath = this.cacheDir + '/' + ICON_PACK_BACKUP_ZIP;

    try {
      // 1. 清理并创建 staging 目录（防止上次中断残留旧文件污染本次备份）
      await this.removeDirRecursive(stagingDir);
      try {
        await this.fs.makeDir(stagingDir);
      } catch (_) {}

      // 2. 写入元数据文件
      await this.fs.writeTextFile(metaPath, JSON.stringify(meta));

      // 3. 递归拷贝 icon_packs 和 user_icons 到 staging（fs.copyFile 不支持目录）
      try {
        const destIconDir = stagingDir + '/icon_packs';
        try {
          await this.fs.makeDir(destIconDir);
        } catch (_) {}
        await this.copyDirRecursive(iconPackDir, destIconDir);
      } catch (_) {}
      try {
        const destUserDir = stagingDir + '/user_icons';
        try {
          await this.fs.makeDir(destUserDir);
        } catch (_) {}
        await this.copyDirRecursive(userIconDir, destUserDir);
      } catch (_) {}

      // 4. 压缩 staging 目录为 zip
      await this.archiver.compress(stagingDir, tempZipPath);

      // 5. 将 zip 复制到 cloudDir
      const cloudZipPath = this.cloudDir + '/' + ICON_PACK_BACKUP_ZIP;
      await this.fs.copyFile(tempZipPath, cloudZipPath);

      // 6. 写入伴生元数据文件（~1-2KB，含设备信息、时间戳、图标包列表）
      const syncMeta = new SyncMetaRecord();
      syncMeta.version = 1;
      syncMeta.timestamp = now;
      syncMeta.deviceId = this.devicePort.deviceId();
      syncMeta.deviceName = this.devicePort.deviceName();
      syncMeta.enabledPacks = this.registry.getEnabledPacks();
      syncMeta.deletedPacks = [];
      syncMeta.packs = packEntries;
      const syncMetaPath = this.cloudDir + '/' + SYNC_META_FILE;
      await this.fs.writeTextFile(syncMetaPath, JSON.stringify(syncMeta));

      // 7. 触发云端同步（zip + 伴生文件一起上传）
      await this.syncToCloud();

      AppPreference.setPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME, `${now}`);
      hilog.info(DOMAIN, TAG, `backupIconPacks: completed, timestamp=${now}`);
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, `backupIconPacks: error=${JSON.stringify(e)}`);
      return false;
    } finally {
      await this.removeDirRecursive(stagingDir);
      try {
        await this.fs.deleteFile(tempZipPath);
      } catch (_) {}
    }
  }

  /**
   * 检查云端备份是否比本地更新（公开入口，外部可独立调用）
   * 内部先做 5 分钟去抖，再读取伴生元数据文件比较时间戳（不解压 zip）。
   */
  async checkCloudBackupNewer(): Promise<boolean> {
    await this.init();
    if (!this.context || !this.cloudDir) {
      return false;
    }
    if (!this.tryTransition(IconPackSyncState.CHECKING)) {
      hilog.warn(DOMAIN, TAG, `checkCloudBackupNewer: state=${this.syncState}, skip`);
      return false;
    }
    try {
      return await this.doCheckCloudBackupNewer();
    } finally {
      this.syncState = IconPackSyncState.IDLE;
    }
  }

  /** 读取云端伴生元数据文件比较 timestamp，无需下载/解压 zip */
  private async doCheckCloudBackupNewer(): Promise<boolean> {
    const lastRestoreStr = AppPreference.getPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME) as string;
    const lastRestoreTs = SyncTimeHelper.parseStoredTimestamp(lastRestoreStr);
    if (lastRestoreTs > 0 && SyncTimeHelper.isWithinMinutes(lastRestoreTs, 5)) {
      hilog.info(DOMAIN, TAG, 'checkCloudBackupNewer: restored within 5 min, skip');
      return false;
    }

    const syncMetaPath = this.cloudDir + '/' + SYNC_META_FILE;
    try {
      const stat = await this.fs.stat(syncMetaPath);
      if (stat.location === 2) {
        await this.cacheFile(syncMetaPath);
      }

      const content = await this.fs.readTextFile(syncMetaPath);
      const meta = JSON.parse(content) as SyncMetaRecord;
      const cloudTs = meta.timestamp || 0;
      hilog.info(DOMAIN, TAG, `checkCloudBackupNewer: cloudTs=${cloudTs}, localTs=${lastRestoreTs}, device=${meta.deviceName}`);
      return cloudTs > lastRestoreTs;
    } catch (e) {
      hilog.info(DOMAIN, TAG, `checkCloudBackupNewer: no sync meta or error=${JSON.stringify(e)}`);
      return false;
    }
  }

  /**
   * 从云端恢复图标包（公开入口，checkAndAutoRestore 内部直接调用 doRestoreIconPacks）
   *
   * 流程：IDLE→RESTORING → 下载解压 → 拷贝到 filesDir → 处理 deletedPacks →
   *       刷新内存状态 → 合并 enabledPacks → IDLE
   */
  async restoreIconPacks(): Promise<IconPackRestoreResult> {
    await this.init();
    if (!this.context || !this.cloudDir) {
      return new IconPackRestoreResult();
    }
    if (!this.tryTransition(IconPackSyncState.RESTORING)) {
      hilog.warn(DOMAIN, TAG, `restoreIconPacks: state=${this.syncState}, skip`);
      return new IconPackRestoreResult();
    }
    try {
      return await this.doRestoreIconPacks();
    } finally {
      this.syncState = IconPackSyncState.IDLE;
    }
  }

  /** 实际恢复逻辑：解压 → 拷贝文件 → 处理已删除包 → 刷新内存 → 合并启用列表 */
  private async doRestoreIconPacks(): Promise<IconPackRestoreResult> {
    const cloudZipPath = this.cloudDir + '/' + ICON_PACK_BACKUP_ZIP;
    try {
      // 若文件仍在云端（location=2），先缓存到本地
      const stat = await this.fs.stat(cloudZipPath);
      if (stat.location === 2) {
        await this.cacheFile(cloudZipPath);
      }

      // 解压到临时目录（cacheDir，不直接写 filesDir）
      const tempDir = this.cacheDir + '/icon_pack_restore';
      try {
        await this.fs.makeDir(tempDir);
      } catch (_) {}

      await this.archiver.decompress(cloudZipPath, tempDir);

      // 确保目标目录存在
      const iconPackDir = this.filesDir + '/icon_packs';
      const userIconDir = this.filesDir + '/user_icons';
      try {
        await this.fs.makeDir(iconPackDir);
      } catch (_) {}
      try {
        await this.fs.makeDir(userIconDir);
      } catch (_) {}

      // 选择性拷贝：只还原 icon_packs 和 user_icons 子目录
      const tempIconPacks = tempDir + '/icon_packs';
      const tempUserIcons = tempDir + '/user_icons';
      try {
        await this.copyDirRecursive(tempIconPacks, iconPackDir);
      } catch (_) {}
      try {
        await this.copyDirRecursive(tempUserIcons, userIconDir);
      } catch (_) {}

      // 读取元数据
      let meta: IconPackMetaRecord | null = null;
      try {
        const metaContent = await this.fs.readTextFile(tempDir + '/' + META_JSON_NAME);
        meta = JSON.parse(metaContent) as IconPackMetaRecord;
      } catch (_) {}

      // 清理临时目录
      await this.removeDirRecursive(tempDir);

      if (meta) {
        // 处理云端标记为已删除的图标包
        if (meta.deletedPacks && meta.deletedPacks.length > 0) {
          for (const deletedUuid of meta.deletedPacks) {
            const pack = this.registry.listPacks().find(p => p.uuid === deletedUuid);
            if (pack) {
              try {
                await this.registry.removePack(pack);
              } catch (e) {
                hilog.warn(DOMAIN, TAG, `restoreIconPacks: failed to delete pack ${deletedUuid}: ${JSON.stringify(e)}`);
              }
            }
          }
        }

        // 在 merge 前重新从磁盘加载图标包，使注册表内存状态包含新拷贝的文件
        await this.refreshIconPackState();

        // 合并策略：以云端 enabledPacks 为基础，追加本地独有的包（不丢失本地新增包）
        const localPacks = this.registry.listPacks().map(p => p.uuid);
        const merged = mergeEnabledPacks(meta.enabledPacks, localPacks);

        this.registry.setEnabledPacks(merged);
        AppPreference.saveEnabledPacks(merged);
        AppPreference.setPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME, `${meta.timestamp}`);

        hilog.info(DOMAIN, TAG, `restoreIconPacks: merged enabledPacks=${JSON.stringify(merged)}`);
      }

      const result = new IconPackRestoreResult();
      result.restoredCount = meta?.packs?.length ?? 0;
      result.restoredFiles = 1;
      return result;
    } catch (e) {
      hilog.error(DOMAIN, TAG, `restoreIconPacks: error=${JSON.stringify(e)}`);
      return new IconPackRestoreResult();
    }
  }

  /**
   * 从磁盘重新加载图标包到注册表内存（在 merge enabledPacks 前调用）
   * 包含：user_icons 目录 + icon_packs 下所有子目录 + enabled_packs 偏好
   */
  private async refreshIconPackState(): Promise<void> {
    const iconPackDir = this.filesDir + '/icon_packs';
    const userIconDir = this.filesDir + '/user_icons';

    await this.registry.loadUserIcons(userIconDir);
    try {
      const paths = await this.fs.listFiles(iconPackDir);
      for (const path of paths) {
        const fullPath = iconPackDir + '/' + path;
        if (this.registry.listPacks().some(pack => pack.on_device_path === fullPath)) {
          continue;
        }
        try {
          await this.registry.addPackFromDevice(fullPath);
        } catch (err) {
          hilog.warn(DOMAIN, TAG, `refreshIconPackState: failed to load pack ${path}: ${JSON.stringify(err)}`);
        }
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, `refreshIconPackState: failed to list ${iconPackDir}: ${JSON.stringify(err)}`);
    }
    this.registry.reloadEnabledPacksFromPreference();
  }

  /** 查询云端图标包备份状态（是否存在、包数量、大小、来源设备等），供 UI 展示 */
  async getCloudBackupStatus(): Promise<IconPackBackupStatus> {
    await this.init();
    const result = new IconPackBackupStatus();

    const lastTimeStr = AppPreference.getPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME) as string;
    const lastTs = SyncTimeHelper.parseStoredTimestamp(lastTimeStr);
    result.lastTime = SyncTimeHelper.formatTimestamp(lastTs);

    if (!this.context || !this.cloudDir) {
      return result;
    }

    const cloudZipPath = this.cloudDir + '/' + ICON_PACK_BACKUP_ZIP;
    try {
      const stat = await this.fs.stat(cloudZipPath);
      result.exists = true;
      result.size = stat.size;
    } catch (_) {}

    // 从伴生元数据文件读取详细信息（包列表、来源设备等）
    const syncMetaPath = this.cloudDir + '/' + SYNC_META_FILE;
    try {
      const smStat = await this.fs.stat(syncMetaPath);
      if (smStat.location === 2) {
        await this.cacheFile(syncMetaPath);
      }
      const content = await this.fs.readTextFile(syncMetaPath);
      const meta = JSON.parse(content) as SyncMetaRecord;
      result.packCount = meta.packs?.length ?? 0;
      result.sourceDeviceId = meta.deviceId ?? '';
      result.sourceDeviceName = meta.deviceName ?? '';
      result.packs = meta.packs ?? [];
    } catch (_) {
      // 伴生文件不存在（旧版本备份），回退到本地内存
      result.packCount = this.registry.listPacks().length;
    }

    return result;
  }

  /** 删除云端图标包备份 zip（由 CloudBackupManager 的三个 clear 方法调用） */
  async clearCloudBackup(): Promise<boolean> {
    await this.init();
    if (!this.context || !this.cloudDir) {
      return false;
    }
    if (!this.tryTransition(IconPackSyncState.CLEARING)) {
      hilog.warn(DOMAIN, TAG, `clearCloudBackup: state=${this.syncState}, skip`);
      return false;
    }
    try {
      const cloudZipPath = this.cloudDir + '/' + ICON_PACK_BACKUP_ZIP;
      try {
        await this.fs.deleteFile(cloudZipPath);
      } catch (_) {}
      try {
        await this.fs.deleteFile(this.cloudDir + '/' + SYNC_META_FILE);
      } catch (_) {}
      await this.syncToCloud();
      hilog.info(DOMAIN, TAG, 'clearCloudBackup: completed');
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, `clearCloudBackup: error=${JSON.stringify(e)}`);
      return false;
    } finally {
      this.syncState = IconPackSyncState.IDLE;
    }
  }

  /** 状态机原子转换：仅 IDLE→target 允许，其他状态拒绝（返回 false） */
  private tryTransition(target: IconPackSyncState): boolean {
    if (this.syncState !== IconPackSyncState.IDLE) {
      return false;
    }
    this.syncState = target;
    return true;
  }

  /** 暴露当前状态机状态，供 UI 层查询同步进度 */
  getState(): IconPackSyncState {
    return this.syncState;
  }

  /** 触发 FileSync.start() 将 cloudDir 变更同步到云端（复用实例避免重复创建） */
  private async syncToCloud(): Promise<void> {
    // 测试注入下无需真实云同步
    if (this.testDeps !== null) {
      return;
    }
    try {
      if (!this.fileSync) {
        this.fileSync = new cloudSync.FileSync();
      }
      await this.fileSync.start();
      hilog.info(DOMAIN, TAG, 'syncToCloud: started');
    } catch (e) {
      hilog.error(DOMAIN, TAG, `syncToCloud: error=${JSON.stringify(e)}`);
    }
  }

  /** 将云端文件（location=2）缓存到本地，以便读取内容 */
  private async cacheFile(filePath: string): Promise<void> {
    // 测试注入下假文件系统内容均在本地，跳过云端缓存拉取
    if (this.testDeps !== null) {
      return;
    }
    try {
      const uri = fileUri.getUriFromPath(filePath);
      const cache = new cloudSync.CloudFileCache();
      await cache.start(uri);
      hilog.info(DOMAIN, TAG, `cacheFile: cached ${filePath}`);
    } catch (e) {
      hilog.error(DOMAIN, TAG, `cacheFile: error=${JSON.stringify(e)}`);
    }
  }

  private async removeDirRecursive(dirPath: string): Promise<void> {
    try {
      const files = await this.fs.listFiles(dirPath);
      for (const file of files) {
        const fullPath = dirPath + '/' + file;
        try {
          const stat = await this.fs.stat(fullPath);
          if (stat.isDirectory) {
            await this.removeDirRecursive(fullPath);
          } else {
            await this.fs.deleteFile(fullPath);
          }
        } catch (e) {
          hilog.warn(DOMAIN, TAG, `removeDirRecursive: failed to remove ${fullPath}: ${JSON.stringify(e)}`);
        }
      }
      await this.fs.removeDir(dirPath);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, `removeDirRecursive: failed to process ${dirPath}: ${JSON.stringify(e)}`);
    }
  }

  private async copyDirRecursive(srcDir: string, destDir: string): Promise<void> {
    try {
      const files = await this.fs.listFiles(srcDir);
      for (const file of files) {
        const srcPath = srcDir + '/' + file;
        const destPath = destDir + '/' + file;
        try {
          const stat = await this.fs.stat(srcPath);
          if (stat.isDirectory) {
            try {
              await this.fs.makeDir(destPath);
            } catch (_) {}
            await this.copyDirRecursive(srcPath, destPath);
          } else {
            await this.fs.copyFile(srcPath, destPath);
          }
        } catch (e) {
          hilog.warn(DOMAIN, TAG, `copyDirRecursive: failed to copy ${srcPath}: ${JSON.stringify(e)}`);
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, `copyDirRecursive: failed to read ${srcDir}: ${JSON.stringify(e)}`);
    }
  }
}
