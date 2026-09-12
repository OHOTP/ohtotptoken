import { describe, it, expect } from '@ohos/hypium';
import { buffer } from '@kit.ArkTS';
import {
  AppPreference,
  BackupCryptoEngine,
  Base64Codec,
  CloudBackupAccountPort,
  CloudBackupCrypto,
  CloudBackupDevicePort,
  CloudBackupGroupPort,
  CloudBackupIconPort,
  CloudBackupManager,
  CloudBackupTokenPort,
  CloudSyncStarter,
  FsStatInfo,
  PREF_KEYS,
  TokenConfig,
  TokenGroup,
  otpType,
} from 'common';
import { sha256 } from '../main/ets/crypto/PureHash';
import { base64Decode, base64Encode, utf8ToBytes } from '../main/ets/steam/SteamCrypto';
import { MemoryFs } from './fakes/BackupFakes';

/**
 * 云备份编排逻辑测试（Phase 2 端口注入：FsGateway + 账号/设备/令牌/分组/图标包/同步）。
 *
 * 覆盖：登录门禁、备份写文件与失败回退、MAX_BACKUP_COUNT 最旧清理、
 * 记录扫描（过滤/排序/头部解析降级）、新旧载荷恢复、三种清理粒度、
 * 自动备份门禁。加密数值由注入引擎保证可逆，不测 AES 本身。
 */

function bytesToHex(data: Uint8Array): string {
  let hex = '';
  for (let i = 0; i < data.length; i++) {
    hex += data[i].toString(16).padStart(2, '0');
  }
  return hex;
}

class PureTsCodec implements Base64Codec {
  encodeText(text: string): string {
    return base64Encode(utf8ToBytes(text));
  }

  decodeText(base64Str: string): string {
    return buffer.from(base64Decode(base64Str)).toString('utf-8');
  }

  encodeBytes(data: Uint8Array): string {
    return base64Encode(data);
  }

  decodeBytes(base64Str: string): Uint8Array {
    return base64Decode(base64Str);
  }
}

/** 可逆 XOR 备份引擎（密钥流由 PureHash SHA-256 派生） */
class XorBackupEngine implements BackupCryptoEngine {
  round: number = 0;

  randomBytes(length: number): Uint8Array {
    const out = new Uint8Array(length);
    for (let i = 0; i < length; i++) {
      out[i] = (this.round * 37 + i * 13 + 5) & 0xff;
    }
    this.round++;
    return out;
  }

  async sha256Hex(data: string): Promise<string> {
    return bytesToHex(sha256(utf8ToBytes(data)));
  }

  async aesCbcEncrypt(plaintext: Uint8Array, password: string, salt: Uint8Array, iv: Uint8Array): Promise<Uint8Array> {
    return this.xor(plaintext, password, salt, iv);
  }

  async aesCbcDecrypt(ciphertext: Uint8Array, password: string, salt: Uint8Array, iv: Uint8Array): Promise<Uint8Array> {
    return this.xor(ciphertext, password, salt, iv);
  }

  private xor(data: Uint8Array, password: string, salt: Uint8Array, iv: Uint8Array): Uint8Array {
    const material = utf8ToBytes(password + ':' + bytesToHex(salt) + bytesToHex(iv));
    const pad = sha256(material);
    const out = new Uint8Array(data.length);
    for (let i = 0; i < data.length; i++) {
      out[i] = data[i] ^ pad[i % pad.length];
    }
    return out;
  }
}

class FakeAccount implements CloudBackupAccountPort {
  login: boolean = true;
  union: string = 'union-1';

  isUserLogin(): boolean {
    return this.login;
  }

  unionId(): string {
    return this.union;
  }
}

class FakeDevice implements CloudBackupDevicePort {
  id: string = 'odid-A';
  name: string = 'Mate60';

  deviceId(): string {
    return this.id;
  }

  deviceName(): string {
    return this.name;
  }
}

class FakeTokens implements CloudBackupTokenPort {
  list: TokenConfig[] = [];
  updated: TokenConfig[] = [];

  getTokens(): Promise<TokenConfig[]> {
    return Promise.resolve(this.list);
  }

  updateToken(token: TokenConfig): Promise<void> {
    this.updated.push(token);
    return Promise.resolve();
  }
}

class FakeGroups implements CloudBackupGroupPort {
  groups: TokenGroup[] = [];
  mergedGroups: TokenGroup[] | null = null;

  currentGroups(): TokenGroup[] {
    return this.groups;
  }

  merge(groups: TokenGroup[] | undefined): Promise<void> {
    this.mergedGroups = groups !== undefined ? groups : null;
    return Promise.resolve();
  }
}

class FakeIcons implements CloudBackupIconPort {
  backupCalls: number = 0;
  clearCalls: number = 0;

  backupIconPacks(): Promise<boolean> {
    this.backupCalls++;
    return Promise.resolve(true);
  }

  clearCloudBackup(): Promise<boolean> {
    this.clearCalls++;
    return Promise.resolve(true);
  }
}

class FakeSync implements CloudSyncStarter {
  startCalls: number = 0;

  start(): Promise<void> {
    this.startCalls++;
    return Promise.resolve();
  }
}

/** 同步触发可失败：验证备份主流程对同步故障的容忍 */
class FlakySync implements CloudSyncStarter {
  fail: boolean = false;
  startCalls: number = 0;

  async start(): Promise<void> {
    this.startCalls++;
    if (this.fail) {
      throw new Error('sync down');
    }
  }
}

/** 可注入单点故障的文件系统：验证记录扫描/清理对单文件 IO 异常的隔离 */
class FlakyFs extends MemoryFs {
  failStatFor: Set<string> = new Set();
  failDeleteFor: Set<string> = new Set();

  stat(path: string): Promise<FsStatInfo> {
    if (this.failStatFor.has(path)) {
      return Promise.reject(new Error('stat flake'));
    }
    return super.stat(path);
  }

  async deleteFile(path: string): Promise<void> {
    if (this.failDeleteFor.has(path)) {
      throw new Error('delete flake');
    }
    await super.deleteFile(path);
  }
}

function makeToken(uuid: string, secret: string): TokenConfig {
  const token = new TokenConfig(secret, otpType.TOTP);
  token.TokenUUID = uuid;
  token.RankScore = 0;
  return token;
}

interface TestRig {
  fs: MemoryFs;
  account: FakeAccount;
  device: FakeDevice;
  tokens: FakeTokens;
  groups: FakeGroups;
  icons: FakeIcons;
  sync: FakeSync;
}

function freshRig(): TestRig {
  CloudBackupCrypto.useEngineForTest(new XorBackupEngine(), new PureTsCodec());
  AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, '');
  // 复位静态偏好与单例，隔离套件间污染
  AppPreference.setPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE, false);
  AppPreference.setPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME, '');
  CloudBackupManager.getInstance().resetForTest();

  const rig: TestRig = {
    fs: new MemoryFs(),
    account: new FakeAccount(),
    device: new FakeDevice(),
    tokens: new FakeTokens(),
    groups: new FakeGroups(),
    icons: new FakeIcons(),
    sync: new FakeSync(),
  };
  CloudBackupManager.getInstance().useDepsForTest({
    fs: rig.fs,
    account: rig.account,
    device: rig.device,
    tokens: rig.tokens,
    groups: rig.groups,
    icons: rig.icons,
    sync: rig.sync,
    cloudDir: '/cloud',
  });
  return rig;
}

function backupFileName(ts: number): string {
  return `otp_backup_${ts}.enc`;
}

/** 直接向假文件系统写入一份合法加密备份 */
async function seedBackup(rig: TestRig, ts: number, plaintext: string, deviceId: string,
  deviceName: string = 'Mate60'): Promise<void> {
  const crypto = CloudBackupCrypto.getInstance();
  const content = await crypto.encrypt(plaintext, crypto.getMode(true), 'union-1', 1, ts, deviceId, deviceName);
  rig.fs.files.set(`/cloud/${backupFileName(ts)}`, content);
}

async function flushMicrotasks(): Promise<void> {
  // fire-and-forget promise（图标包备份）需要一次事件循环轮转
  await Promise.resolve();
  await Promise.resolve();
}

export default function cloudBackupManagerTest() {
  describe('cloudBackupManagerTest', () => {
    it('backup_aborts_when_not_logged_in', 0, async () => {
      const rig = freshRig();
      rig.account.login = false;

      const result = await CloudBackupManager.getInstance().backupToCloud();
      expect(result).assertFalse();
      expect(rig.fs.files.size).assertEqual(0);
      expect(rig.sync.startCalls).assertEqual(0);
    });

    it('backup_success_writes_file_sets_pref_and_triggers_sync_icons', 0, async () => {
      const rig = freshRig();
      rig.tokens.list = [makeToken('u1', 'secret1')];

      const result = await CloudBackupManager.getInstance().backupToCloud();
      expect(result).assertTrue();
      // 文件名规则 otp_backup_{ts}.enc
      let backupFiles: string[] = [];
      rig.fs.files.forEach((_: string, name: string) => {
        backupFiles.push(name.substring(name.lastIndexOf('/') + 1));
      });
      expect(backupFiles.length).assertEqual(1);
      expect(backupFiles[0].startsWith('otp_backup_')).assertTrue();
      expect(backupFiles[0].endsWith('.enc')).assertTrue();
      // 同步触发一次；图标包备份 fire-and-forget 已排队
      expect(rig.sync.startCalls).assertEqual(1);
      await flushMicrotasks();
      expect(rig.icons.backupCalls).assertEqual(1);
      // last time 已记录（同步内存缓存）
      const lastTime = AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME) as string;
      expect(lastTime.length > 0).assertTrue();
    });

    it('backup_write_failure_returns_false', 0, async () => {
      const rig = freshRig();
      rig.fs.failWrite = true;

      const result = await CloudBackupManager.getInstance().backupToCloud();
      expect(result).assertFalse();
      expect(rig.sync.startCalls).assertEqual(0);
    });

    it('backup_prunes_oldest_only_beyond_max_count', 0, async () => {
      const rig = freshRig();
      // 预置 5 份旧备份（相对 stub 时钟递减），上限为 5 → 写入后应删除最旧一份
      const stubNow = Date.now();
      for (let i = 1; i <= 5; i++) {
        await seedBackup(rig, stubNow - 1000 * i, '{"tokens":[]}', 'odid-A');
      }

      const result = await CloudBackupManager.getInstance().backupToCloud();
      expect(result).assertTrue();

      let backupFiles: string[] = [];
      rig.fs.files.forEach((_: string, name: string) => {
        const base = name.substring(name.lastIndexOf('/') + 1);
        if (base.startsWith('otp_backup_')) {
          backupFiles.push(base);
        }
      });
      expect(backupFiles.length).assertEqual(5);
      // 最旧的一份（stubNow-5000）被删除（其余保留）
      let deletedOldest = false;
      for (const path of rig.fs.deletedPaths) {
        if (path.endsWith(`otp_backup_${stubNow - 5000}.enc`)) {
          deletedOldest = true;
        }
      }
      expect(deletedOldest).assertTrue();
    });

    it('list_history_filters_suffix_and_nan_and_sorts_desc', 0, async () => {
      const rig = freshRig();
      await seedBackup(rig, 2000, '{"tokens":[]}', 'odid-A');
      await seedBackup(rig, 3000, '{"tokens":[]}', 'odid-B');
      rig.fs.files.set('/cloud/otp_backup_notanumber.enc', 'junk');
      rig.fs.files.set('/cloud/unrelated.txt', 'junk');

      const records = await CloudBackupManager.getInstance().listBackupHistory();
      expect(records.length).assertEqual(2);
      // 时间戳降序
      expect(records[0].timestamp).assertEqual(3000);
      expect(records[1].timestamp).assertEqual(2000);
      // 头部解析成功：deviceId/设备名来自加密头
      expect(records[0].deviceId).assertEqual('odid-B');
      expect(records[0].deviceName).assertEqual('Mate60');
    });

    it('list_history_header_parse_failure_falls_back_to_stat', 0, async () => {
      const rig = freshRig();
      // 非 JWT 三段式内容 → 头部解析失败，回退 stat
      rig.fs.files.set('/cloud/otp_backup_4000.enc', 'not-a-jwt');

      const records = await CloudBackupManager.getInstance().listBackupHistory();
      expect(records.length).assertEqual(1);
      expect(records[0].tokenCount).assertEqual(0);
      expect(records[0].deviceId).assertEqual('');
      expect(records[0].size).assertEqual(9);
    });

    it('restore_from_cloud_false_when_no_records', 0, async () => {
      const rig = freshRig();
      const result = await CloudBackupManager.getInstance().restoreFromCloud();
      expect(result).assertFalse();
      expect(rig.tokens.updated.length).assertEqual(0);
    });

    it('restore_new_payload_restores_tokens_groups_and_packs', 0, async () => {
      const rig = freshRig();
      const tokenJson = JSON.stringify(makeToken('u1', 'restored_secret'));
      const payload = `{"tokens":[${tokenJson}],"groups":[{"id":"g1","name":"Work"}],"enabledPacks":["pack-x"],"packMeta":[]}`;
      await seedBackup(rig, 5000, payload, 'odid-A');
      await seedBackup(rig, 6000, payload, 'odid-A');

      // 恢复最新（6000）
      const result = await CloudBackupManager.getInstance().restoreFromCloud();
      expect(result).assertTrue();
      expect(rig.tokens.updated.length).assertEqual(1);
      expect(rig.tokens.updated[0].TokenUUID).assertEqual('u1');
      expect(rig.tokens.updated[0].TokenSecret).assertEqual('restored_secret');
      expect(rig.groups.mergedGroups !== null && rig.groups.mergedGroups!.length === 1).assertTrue();
    });

    it('restore_legacy_array_payload_skips_group_merge', 0, async () => {
      const rig = freshRig();
      const tokenJson = JSON.stringify(makeToken('legacy', 'legacy_secret'));
      await seedBackup(rig, 7000, `[${tokenJson}]`, 'odid-A');

      const result = await CloudBackupManager.getInstance().restoreFromBackupRecord(backupFileName(7000));
      expect(result).assertTrue();
      expect(rig.tokens.updated.length).assertEqual(1);
      expect(rig.tokens.updated[0].TokenUUID).assertEqual('legacy');
      expect(rig.groups.mergedGroups).assertNull();
    });

    it('restore_cloud_only_file_location2_still_restores', 0, async () => {
      const rig = freshRig();
      const tokenJson = JSON.stringify(makeToken('cloud', 'cloud_secret'));
      await seedBackup(rig, 8600, `{"tokens":[${tokenJson}]}`, 'odid-A');
      // 标记为云端文件（location=2）：注入模式下 cacheFile 跳过，读取与恢复不中断
      rig.fs.locationOverride.set('/cloud/otp_backup_8600.enc', 2);

      const result = await CloudBackupManager.getInstance().restoreFromBackupRecord(backupFileName(8600));
      expect(result).assertTrue();
      expect(rig.tokens.updated.length).assertEqual(1);
      expect(rig.tokens.updated[0].TokenSecret).assertEqual('cloud_secret');
    });

    it('restore_missing_record_returns_false', 0, async () => {
      freshRig();
      const result = await CloudBackupManager.getInstance().restoreFromBackupRecord('otp_backup_9999.enc');
      expect(result).assertFalse();
    });

    it('restore_aborts_when_not_logged_in', 0, async () => {
      const rig = freshRig();
      await seedBackup(rig, 8000, '{"tokens":[]}', 'odid-A');
      rig.account.login = false;

      const result = await CloudBackupManager.getInstance().restoreFromBackupRecord(backupFileName(8000));
      expect(result).assertFalse();
      expect(rig.tokens.updated.length).assertEqual(0);
    });

    it('clear_storage_deletes_all_and_resets_last_time', 0, async () => {
      const rig = freshRig();
      await seedBackup(rig, 9100, '{"tokens":[]}', 'odid-A');
      await seedBackup(rig, 9200, '{"tokens":[]}', 'odid-B');

      const result = await CloudBackupManager.getInstance().clearCloudStorage();
      expect(result).assertTrue();
      expect(rig.fs.files.size).assertEqual(0);
      expect(rig.icons.clearCalls).assertEqual(1);
      expect(AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME)).assertEqual('0');
    });

    it('clear_device_storage_deletes_only_matching_odid', 0, async () => {
      const rig = freshRig();
      await seedBackup(rig, 9300, '{"tokens":[]}', 'odid-A');
      await seedBackup(rig, 9400, '{"tokens":[]}', 'odid-B');

      const result = await CloudBackupManager.getInstance().clearDeviceCloudStorage();
      expect(result).assertTrue();
      expect(rig.fs.files.size).assertEqual(1);
      expect(rig.fs.files.has('/cloud/otp_backup_9400.enc')).assertTrue();
      expect(rig.icons.clearCalls).assertEqual(1);
    });

    it('clear_device_name_storage_deletes_stale_install_only', 0, async () => {
      const rig = freshRig();
      // 同名设备、不同 ODID（卸载重装遗留）
      await seedBackup(rig, 9500, '{"tokens":[]}', 'odid-OLD');
      // 当前 ODID：保留；其他名称：保留
      await seedBackup(rig, 9600, '{"tokens":[]}', 'odid-A');
      await seedBackup(rig, 9700, '{"tokens":[]}', 'odid-B', 'OtherDev');

      const result = await CloudBackupManager.getInstance().clearDeviceNameCloudStorage();
      expect(result).assertTrue();
      expect(rig.fs.files.size).assertEqual(2);
      expect(rig.fs.files.has('/cloud/otp_backup_9600.enc')).assertTrue();
      expect(rig.fs.files.has('/cloud/otp_backup_9700.enc')).assertTrue();
      // 有实际删除才清理图标包
      expect(rig.icons.clearCalls).assertEqual(1);

      // 无遗留：不触发图标包清理
      const iconsBefore = rig.icons.clearCalls;
      const again = await CloudBackupManager.getInstance().clearDeviceNameCloudStorage();
      expect(again).assertTrue();
      expect(rig.icons.clearCalls).assertEqual(iconsBefore);
    });

    it('delete_record_syncs_only_on_success', 0, async () => {
      const rig = freshRig();
      await seedBackup(rig, 9800, '{"tokens":[]}', 'odid-A');

      const missing = await CloudBackupManager.getInstance().deleteBackupRecord('otp_backup_1111.enc');
      expect(missing).assertFalse();
      expect(rig.sync.startCalls).assertEqual(0);

      const ok = await CloudBackupManager.getInstance().deleteBackupRecord(backupFileName(9800));
      expect(ok).assertTrue();
      expect(rig.sync.startCalls).assertEqual(1);
    });

    it('auto_backup_skips_when_disabled', 0, async () => {
      const rig = freshRig();
      AppPreference.setPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE, false);

      await CloudBackupManager.getInstance().checkAndAutoBackup();
      expect(rig.sync.startCalls).assertEqual(0);
    });

    it('auto_backup_runs_when_last_backup_is_stale', 0, async () => {
      const rig = freshRig();
      AppPreference.setPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE, true);
      // 上次备份相对 stub 时钟在一天前 → 不命中"今日已备份"跳过分支
      AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, `${Date.now() - 86400000}`);

      await CloudBackupManager.getInstance().checkAndAutoBackup();
      expect(rig.fs.written.size).assertEqual(1);
      expect(rig.sync.startCalls).assertEqual(1);
    });

    it('auto_backup_skips_when_logged_out', 0, async () => {
      const rig = freshRig();
      AppPreference.setPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE, true);
      rig.account.login = false;

      await CloudBackupManager.getInstance().checkAndAutoBackup();
      expect(rig.fs.written.size).assertEqual(0);
    });

    it('restore_invalid_record_returns_false_without_writes', 0, async () => {
      const rig = freshRig();
      // 非 3 段格式 → decrypt 抛 CloudBackupTokenError → 恢复失败且异常被吞、零写入
      rig.fs.files.set(`/cloud/${backupFileName(9500)}`, 'garbage-not-a-token');

      const ok = await CloudBackupManager.getInstance().restoreFromCloud();
      expect(ok).assertFalse();
      expect(rig.tokens.updated.length).assertEqual(0);
    });

    it('backup_succeeds_even_when_cloud_sync_start_fails', 0, async () => {
      const rig = freshRig();
      const flakySync = new FlakySync();
      flakySync.fail = true;
      // useDepsForTest 为整体替换语义：必须传完整端口集，否则其余端口回退生产实现
      CloudBackupManager.getInstance().useDepsForTest({
        fs: rig.fs, account: rig.account, device: rig.device, tokens: rig.tokens,
        groups: rig.groups, icons: rig.icons, sync: flakySync, cloudDir: '/cloud',
      });
      rig.tokens.list.push(makeToken('u1', 'SECRET'));

      const ok = await CloudBackupManager.getInstance().backupToCloud();
      // 同步触发失败不回滚备份结果（下次冷启动 FileSync 会补同步）
      expect(ok).assertTrue();
      expect(rig.fs.written.size).assertEqual(1);
      expect(flakySync.startCalls).assertEqual(1);
    });

    it('clear_cloud_storage_tolerates_individual_delete_failures', 0, async () => {
      const rig = freshRig();
      const flaky = new FlakyFs();
      // useDepsForTest 为整体替换语义：先注入再向同一个假文件系统种子备份
      CloudBackupManager.getInstance().useDepsForTest({
        fs: flaky, account: rig.account, device: rig.device, tokens: rig.tokens,
        groups: rig.groups, icons: rig.icons, sync: rig.sync, cloudDir: '/cloud',
      });
      const crypto = CloudBackupCrypto.getInstance();
      const content = await crypto.encrypt('{}', crypto.getMode(true), 'union-1', 1, 9100, 'odid-A', 'Mate60');
      flaky.files.set(`/cloud/${backupFileName(9100)}`, content);
      flaky.failDeleteFor.add(`/cloud/${backupFileName(9100)}`);

      const ok = await CloudBackupManager.getInstance().clearCloudStorage();
      // 现网行为：deleteBackupFile 内部吞错，单个文件删除失败不中断整体清理
      // （红方评审关注点：清理"成功"反馈与云端实际状态可能不一致，归产品决策）
      expect(ok).assertTrue();
      expect(rig.icons.clearCalls).assertEqual(1);
    });

    it('clear_device_name_storage_noop_does_not_clear_icons', 0, async () => {
      const rig = freshRig();
      // 只有"同名不同 ODID"才算遗留备份；异名设备备份不受影响、不触发图标包清理
      await seedBackup(rig, 9200, '{}', 'odid-B', 'Pixel8');

      const ok = await CloudBackupManager.getInstance().clearDeviceNameCloudStorage();
      expect(ok).assertTrue();
      expect(rig.icons.clearCalls).assertEqual(0);
      expect(rig.fs.deletedPaths.length).assertEqual(0);
    });

    it('list_records_skip_files_that_fail_stat_and_continue', 0, async () => {
      const rig = freshRig();
      const flaky = new FlakyFs();
      CloudBackupManager.getInstance().useDepsForTest({
        fs: flaky, account: rig.account, device: rig.device, tokens: rig.tokens,
        groups: rig.groups, icons: rig.icons, sync: rig.sync, cloudDir: '/cloud',
      });
      const crypto = CloudBackupCrypto.getInstance();
      const content1 = await crypto.encrypt('{"tokens":[]}', crypto.getMode(true), 'union-1', 1, 9300, 'odid-A', 'Mate60');
      const content2 = await crypto.encrypt('{"tokens":[]}', crypto.getMode(true), 'union-1', 1, 9400, 'odid-A', 'Mate60');
      flaky.files.set(`/cloud/${backupFileName(9300)}`, content1);
      flaky.files.set(`/cloud/${backupFileName(9400)}`, content2);
      flaky.failStatFor.add(`/cloud/${backupFileName(9300)}`);

      const records = await CloudBackupManager.getInstance().listBackupHistory();
      // 单文件 stat 失败只跳过该文件，其余记录正常返回（降序）
      expect(records.length).assertEqual(1);
      expect(records[0].timestamp).assertEqual(9400);
    });

    it('restore_new_payload_without_enabled_packs_keeps_current_setting', 0, async () => {
      const rig = freshRig();
      AppPreference.setPreference(PREF_KEYS.APPEARANCE_ICON_PACK_ENABLED, '["keep"]');
      const payload = '{"tokens":[{"TokenUUID":"t1"}],"groups":[]}';
      await seedBackup(rig, 9600, payload, 'odid-A');

      const ok = await CloudBackupManager.getInstance().restoreFromCloud();
      expect(ok).assertTrue();
      // 载荷无 enabledPacks 字段 → 保留本地当前启用列表
      expect(AppPreference.getPreference(PREF_KEYS.APPEARANCE_ICON_PACK_ENABLED) as string).assertEqual('["keep"]');
      expect(rig.tokens.updated.length).assertEqual(1);
      expect(rig.groups.mergedGroups !== null).assertTrue();
    });

    it('clear_methods_abort_when_not_logged_in', 0, async () => {
      const rig = freshRig();
      rig.account.login = false;
      await seedBackup(rig, 9700, '{}', 'odid-A');

      expect(await CloudBackupManager.getInstance().clearCloudStorage()).assertFalse();
      expect(await CloudBackupManager.getInstance().clearDeviceCloudStorage()).assertFalse();
      expect(await CloudBackupManager.getInstance().clearDeviceNameCloudStorage()).assertFalse();
      expect(rig.fs.deletedPaths.length).assertEqual(0);
      expect(rig.icons.clearCalls).assertEqual(0);
    });
  });
}
