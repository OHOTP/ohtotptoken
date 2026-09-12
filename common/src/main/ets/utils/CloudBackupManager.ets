import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppPreference, PREF_KEYS } from './AppPreference';
import { CloudBackupCrypto, CloudBackupRecord, CloudBackupTokenError } from './CloudBackupCrypto';
import { TokenStore } from './TokenStore';
import { TokenConfig, sanitizedTokenForBackup } from './TokenConfig';
import { TokenGroup, TokenGroupStore } from './TokenGroupStore';
import { cloudSync, fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { DeviceInfoHelper } from './DeviceInfoHelper';
import { HuaweiAccountManager } from './HuaweiAccountManager';
import { SyncTimeHelper } from './SyncTimeHelper';
import { TokenIconPacks } from './TokenUtils';
import { IconPackCloudBackup, PackMetaEntry } from './IconPackCloudBackup';
import { FsGateway, FileIoFsGateway } from './StoragePorts';
import { BACKUP_FILE_EXT, BACKUP_FILE_PREFIX, isBackupFileName, parseBackupTimestamp } from './CommonUtils';

const TAG = 'CloudBackupManager';
const DOMAIN = 0xFF00;
const MAX_BACKUP_COUNT = 5;

/** 华为账号状态端口（生产：HuaweiAccountManager 单例）。 */
export interface CloudBackupAccountPort {
  isUserLogin(): boolean;
  unionId(): string;
}

/** 设备标识端口（生产：DeviceInfoHelper 单例）。 */
export interface CloudBackupDevicePort {
  deviceId(): string;
  deviceName(): string;
}

/** 令牌数据端口（生产：TokenStore 单例）。 */
export interface CloudBackupTokenPort {
  getTokens(): Promise<TokenConfig[]>;
  updateToken(token: TokenConfig): Promise<void>;
}

/** 分组目录端口（生产：TokenGroupStore 单例）。 */
export interface CloudBackupGroupPort {
  currentGroups(): TokenGroup[];
  merge(groups: TokenGroup[] | undefined): Promise<void>;
}

/** 图标包云备份端口（生产：IconPackCloudBackup 单例）。 */
export interface CloudBackupIconPort {
  backupIconPacks(): Promise<boolean>;
  clearCloudBackup(): Promise<boolean>;
}

/** 云端同步触发端口（生产：cloudSync.FileSync）。 */
export interface CloudSyncStarter {
  start(): Promise<void>;
}

/** LocalUnit 测试注入项（cloudDir 就绪时跳过 init() 的 AppStorage 依赖）。 */
export interface CloudBackupTestDeps {
  fs?: FsGateway;
  account?: CloudBackupAccountPort;
  device?: CloudBackupDevicePort;
  tokens?: CloudBackupTokenPort;
  groups?: CloudBackupGroupPort;
  icons?: CloudBackupIconPort;
  sync?: CloudSyncStarter;
  cloudDir?: string;
}

class HuaweiAccountAdapter implements CloudBackupAccountPort {
  isUserLogin(): boolean {
    return HuaweiAccountManager.getInstance().userLogin;
  }

  unionId(): string {
    return HuaweiAccountManager.getInstance().userAccount.unionId;
  }
}

class DeviceInfoAdapter implements CloudBackupDevicePort {
  deviceId(): string {
    return DeviceInfoHelper.getInstance().getDeviceId();
  }

  deviceName(): string {
    return DeviceInfoHelper.getInstance().getDeviceName();
  }
}

class TokenStoreAdapter implements CloudBackupTokenPort {
  async getTokens(): Promise<TokenConfig[]> {
    return TokenStore.getInstance().getTokens();
  }

  async updateToken(token: TokenConfig): Promise<void> {
    await TokenStore.getInstance().updateToken(token);
  }
}

class TokenGroupStoreAdapter implements CloudBackupGroupPort {
  currentGroups(): TokenGroup[] {
    return TokenGroupStore.getInstance().state.groups;
  }

  merge(groups: TokenGroup[] | undefined): Promise<void> {
    return TokenGroupStore.getInstance().merge(groups);
  }
}

class IconPackCloudBackupAdapter implements CloudBackupIconPort {
  backupIconPacks(): Promise<boolean> {
    return IconPackCloudBackup.getInstance().backupIconPacks();
  }

  clearCloudBackup(): Promise<boolean> {
    return IconPackCloudBackup.getInstance().clearCloudBackup();
  }
}

/**
 * 云备份载荷：将 TokenConfig[] 包装为结构化格式，附带图标包启用列表和元数据。
 * 旧格式（直接序列化为 TokenConfig[]）通过 restoreFromBackupRecord 中的 Array.isArray 检测兼容。
 */
class CloudBackupPayload {
  tokens: TokenConfig[] = [];
  groups: TokenGroup[] = [];
  enabledPacks: string[] = [];
  packMeta: PackMetaEntry[] = [];
}

/**
 * 云端备份管理器
 *
 * 负责令牌数据在华为云空间的备份、恢复、清理等操作。
 *
 * ## 备份文件命名规则
 * `{BACKUP_FILE_PREFIX}{timestamp}{BACKUP_FILE_EXT}` → `otp_backup_{毫秒时间戳}.enc`
 *
 * ## 加密方案
 * 使用 {@link CloudBackupCrypto} 对明文 JSON 进行对称加密，
 * 密钥来源为华为账号 unionId，通过 `CloudBackupCryptoMode.AES256_GCM` 加密。
 *
 * ## 设备标识（ODID vs deviceName）
 * - **ODID**（`deviceInfo.ODID`）：开发者匿名设备标识符，应用卸载重装后会变化。
 * - **deviceName**（`deviceInfo.marketName`）：设备市场名称，卸载重装后不变。
 *
 * 基于上述差异，提供三种清理粒度：
 * 1. `clearDeviceCloudStorage()` — 按 ODID 匹配，清理当前安装实例产生的备份
 * 2. `clearDeviceNameCloudStorage()` — 按 deviceName 匹配且排除当前 ODID，清理卸载重装前遗留的旧备份
 * 3. `clearCloudStorage()` — 清理全部备份
 *
 * ## 备份数量限制
 * 每台设备（按 ODID 区分）最多保留 {@link MAX_BACKUP_COUNT} 份备份，
 * 超出时自动删除最旧的一份。
 *
 * ## Phase 2 解耦
 * 文件系统经 {@link FsGateway} 端口、账号/设备/令牌/分组/图标包经各自端口访问，
 * LocalUnit 注入内存/假实现测试编排逻辑（见 docs/TEST_PLAN.md 第 4 节）。
 *
 * @module CloudBackupManager
 */
export class CloudBackupManager {
  private static instance: CloudBackupManager | null = null;
  private context: common.UIAbilityContext | undefined = undefined;
  private cloudDir: string = '';
  private fileSync: cloudSync.FileSync | null = null;
  private testDeps: CloudBackupTestDeps | null = null;
  private readonly productionFs: FsGateway = new FileIoFsGateway();

  private constructor() {
  }

  static getInstance(): CloudBackupManager {
    if (!CloudBackupManager.instance) {
      CloudBackupManager.instance = new CloudBackupManager();
    }
    return CloudBackupManager.instance;
  }

  /** 测试注入：LocalUnit 下云文件/账号/设备 API 不可用，替换全部端口。 */
  useDepsForTest(deps: CloudBackupTestDeps): void {
    this.testDeps = deps;
    if (deps.cloudDir !== undefined && deps.cloudDir.length > 0) {
      // 语义上 context/cloudDir 已就绪：init() 直接短路，不再读 AppStorage
      this.context = new Object() as common.UIAbilityContext;
      this.cloudDir = deps.cloudDir;
    }
  }

  /** 测试复位：恢复生产端口与未初始化状态（与 IconPackCloudBackup.resetForTest 对称，防单例跨套件污染）。 */
  resetForTest(): void {
    this.testDeps = null;
    this.context = undefined;
    this.cloudDir = '';
    this.fileSync = null;
  }

  private get fsPort(): FsGateway {
    return this.testDeps?.fs !== undefined ? this.testDeps.fs : this.productionFs;
  }

  private get accountPort(): CloudBackupAccountPort {
    return this.testDeps?.account !== undefined ? this.testDeps.account : new HuaweiAccountAdapter();
  }

  private get devicePort(): CloudBackupDevicePort {
    return this.testDeps?.device !== undefined ? this.testDeps.device : new DeviceInfoAdapter();
  }

  private get tokenPort(): CloudBackupTokenPort {
    return this.testDeps?.tokens !== undefined ? this.testDeps.tokens : new TokenStoreAdapter();
  }

  private get groupPort(): CloudBackupGroupPort {
    return this.testDeps?.groups !== undefined ? this.testDeps.groups : new TokenGroupStoreAdapter();
  }

  private get iconPort(): CloudBackupIconPort {
    return this.testDeps?.icons !== undefined ? this.testDeps.icons : new IconPackCloudBackupAdapter();
  }

  /** 每次调用时取加密实例：测试用 useEngineForTest 替换单例后这里拿到的就是新实例。 */
  private get crypto(): CloudBackupCrypto {
    return CloudBackupCrypto.getInstance();
  }

  /** 初始化云备份管理器：获取 UIAbilityContext、确保云端目录存在。幂等，重复调用安全。 */
  async init(): Promise<void> {
    if (this.context) {
      return;
    }
    this.context = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;
    if (!this.context) {
      hilog.error(DOMAIN, TAG, 'init: failed to get appContext');
      return;
    }

    try {
      this.cloudDir = this.context.cloudFileDir;
      hilog.info(DOMAIN, TAG, `init: cloudDir=${this.cloudDir}`);
      await this.ensureCloudDirExists();
    } catch (e) {
      hilog.error(DOMAIN, TAG, `init: error=${JSON.stringify(e)}`);
    }
  }

  /** 确保云端备份目录存在，不存在则递归创建 */
  private async ensureCloudDirExists(): Promise<void> {
    try {
      const stat = await this.fsPort.stat(this.cloudDir);
      hilog.info(DOMAIN, TAG, `ensureCloudDirExists: exists, location=${stat.location}`);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, `ensureCloudDirExists: not exist, creating`);
      try {
        await this.fsPort.makeDir(this.cloudDir);
        hilog.info(DOMAIN, TAG, 'ensureCloudDirExists: created');
      } catch (err) {
        hilog.error(DOMAIN, TAG, `ensureCloudDirExists: create error=${JSON.stringify(err)}`);
      }
    }
  }

  /**
   * 将令牌数据备份到华为云空间
   *
   * 流程：初始化 → 加密 → 写文件 → 清理超限旧备份 → 触发 FileSync 同步 → 记录时间戳
   * @returns 是否成功
   */
  async backupToCloud(): Promise<boolean> {
    await this.init();
    if (!this.context || !this.cloudDir) {
      hilog.error(DOMAIN, TAG, 'backupToCloud: not initialized');
      return false;
    }

    if (!this.accountPort.isUserLogin()) {
      hilog.warn(DOMAIN, TAG, 'backupToCloud: Huawei account not logged in, aborting');
      return false;
    }

    const encryptKey = this.accountPort.unionId();
    const mode = this.crypto.getMode(true);
    const deviceId = this.devicePort.deviceId();
    const deviceName = this.devicePort.deviceName();

    hilog.info(DOMAIN, TAG, `backupToCloud: starting backup, mode=${mode}`);

    // 构造 CloudBackupPayload：包含令牌、图标包启用列表、图标包元数据
    // 注意：载荷会被序列化后上传云端，必须剥离 Steam 高权限凭证
    // （identity_secret / refresh_token / revocation_code），TokenSecret 保留以便恢复后显示动态码
    const tokens = await this.tokenPort.getTokens();
    const enabledPacks = TokenIconPacks.enabled_packs;
    const payload = new CloudBackupPayload();
    payload.tokens = tokens.map((token: TokenConfig): TokenConfig => sanitizedTokenForBackup(token));
    payload.groups = [...this.groupPort.currentGroups()];
    payload.enabledPacks = enabledPacks;
    const metaList: PackMetaEntry[] = [];
    for (const p of TokenIconPacks.aegis_icon_packs) {
      const m = new PackMetaEntry();
      m.uuid = p.uuid;
      m.name = p.name;
      m.version = p.version;
      m.iconCount = p.icons.length;
      metaList.push(m);
    }
    payload.packMeta = metaList;
    const plaintext = JSON.stringify(payload);
    const now = Date.now();

    hilog.info(DOMAIN, TAG, `backupToCloud: token count=${tokens.length}`);

    const token = await this.crypto.encrypt(
      plaintext, mode, encryptKey,
      tokens.length, now,
      deviceId, deviceName,
    );

    hilog.info(DOMAIN, TAG, `backupToCloud: token size=${token.length}`);

    const fileName = `${BACKUP_FILE_PREFIX}${now}${BACKUP_FILE_EXT}`;
    const filePath = `${this.cloudDir}/${fileName}`;

    try {
      await this.fsPort.writeTextFile(filePath, token);
      hilog.info(DOMAIN, TAG, `backupToCloud: wrote ${token.length} chars to ${fileName}`);
    } catch (e) {
      hilog.error(DOMAIN, TAG, `backupToCloud: write error=${JSON.stringify(e)}`);
      return false;
    }

    const records = await this.listBackupRecords();
    const deviceRecords = records.filter(r => r.deviceId === deviceId);
    if (deviceRecords.length > MAX_BACKUP_COUNT) {
      const oldestRecord = deviceRecords[deviceRecords.length - 1];
      hilog.info(DOMAIN, TAG, `backupToCloud: max count reached, deleting oldest ${oldestRecord.id}`);
      await this.deleteBackupFile(oldestRecord.id);
    }

    await this.syncToCloud();

    AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, `${now}`);

    hilog.info(DOMAIN, TAG, 'backupToCloud: completed successfully');

    // 图标包文件备份：fire-and-forget，不阻塞 token 备份成功返回
    this.iconPort.backupIconPacks().then((iconResult) => {
      hilog.info(DOMAIN, TAG, `backupToCloud: icon pack backup result=${iconResult}`);
    }).catch((err: Error) => {
      hilog.error(DOMAIN, TAG, `backupToCloud: icon pack backup failed: ${err.message}`);
    });

    return true;
  }

  /**
   * 从云端恢复最新的备份数据
   *
   * 解密后逐条调用令牌端口写入本地 KV。
   * @returns 是否成功
   */
  async restoreFromCloud(): Promise<boolean> {
    await this.init();
    if (!this.context || !this.cloudDir) {
      hilog.error(DOMAIN, TAG, 'restoreFromCloud: not initialized');
      return false;
    }

    if (!this.accountPort.isUserLogin()) {
      hilog.warn(DOMAIN, TAG, 'restoreFromCloud: Huawei account not logged in, aborting');
      return false;
    }

    hilog.info(DOMAIN, TAG, 'restoreFromCloud: starting restore');

    const records = await this.listBackupRecords();
    if (records.length === 0) {
      hilog.warn(DOMAIN, TAG, 'restoreFromCloud: no backup records found');
      return false;
    }

    const latestRecord = records[0];
    return await this.restoreFromBackupRecord(latestRecord.id);
  }

  /** 清理云端所有设备的全部备份数据 */
  async clearCloudStorage(): Promise<boolean> {
    await this.init();
    if (!this.context || !this.cloudDir) {
      hilog.error(DOMAIN, TAG, 'clearCloudStorage: not initialized');
      return false;
    }

    if (!this.accountPort.isUserLogin()) {
      hilog.warn(DOMAIN, TAG, 'clearCloudStorage: Huawei account not logged in, aborting');
      return false;
    }

    hilog.info(DOMAIN, TAG, 'clearCloudStorage: clearing');

    try {
      const records = await this.listBackupRecords();
      for (const record of records) {
        await this.deleteBackupFile(record.id);
      }
      AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, '0');
      // 同步清除图标包云端备份（fire-and-forget）
      this.iconPort.clearCloudBackup();
      hilog.info(DOMAIN, TAG, 'clearCloudStorage: completed');
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, `clearCloudStorage: error=${JSON.stringify(e)}`);
      return false;
    }
  }

  /** 清理云端当前 ODID 匹配的备份数据（仅当前安装实例产生的备份） */
  async clearDeviceCloudStorage(): Promise<boolean> {
    await this.init();
    if (!this.context || !this.cloudDir) {
      hilog.error(DOMAIN, TAG, 'clearDeviceCloudStorage: not initialized');
      return false;
    }

    if (!this.accountPort.isUserLogin()) {
      hilog.warn(DOMAIN, TAG, 'clearDeviceCloudStorage: Huawei account not logged in, aborting');
      return false;
    }

    const deviceId = this.devicePort.deviceId();
    hilog.info(DOMAIN, TAG, `clearDeviceCloudStorage: clearing device=${deviceId}`);

    try {
      const records = await this.listBackupRecords();
      const deviceRecords = records.filter((r: CloudBackupRecord) => r.deviceId === deviceId);
      for (const record of deviceRecords) {
        await this.deleteBackupFile(record.id);
      }
      AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, '0');
      // 同步清除图标包云端备份（fire-and-forget）
      this.iconPort.clearCloudBackup();
      hilog.info(DOMAIN, TAG, `clearDeviceCloudStorage: completed, deleted ${deviceRecords.length}`);
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, `clearDeviceCloudStorage: error=${JSON.stringify(e)}`);
      return false;
    }
  }

  /**
   * 清理云端同名设备（deviceName）但不同 ODID 的备份
   *
   * 适用场景：应用卸载重装后 ODID 变化，旧的按 ODID 匹配无法找到卸载前产生的备份，
   * 通过 deviceName 匹配可清理这些遗留备份，同时排除当前 ODID 的备份。
   */
  async clearDeviceNameCloudStorage(): Promise<boolean> {
    await this.init();
    if (!this.context || !this.cloudDir) {
      hilog.error(DOMAIN, TAG, 'clearDeviceNameCloudStorage: not initialized');
      return false;
    }

    if (!this.accountPort.isUserLogin()) {
      hilog.warn(DOMAIN, TAG, 'clearDeviceNameCloudStorage: Huawei account not logged in, aborting');
      return false;
    }

    const currentDeviceId = this.devicePort.deviceId();
    const currentDeviceName = this.devicePort.deviceName();
    hilog.info(DOMAIN, TAG, `clearDeviceNameCloudStorage: name=${currentDeviceName}, excluding odid=${currentDeviceId}`);

    try {
      const records = await this.listBackupRecords();
      const staleRecords = records.filter((r: CloudBackupRecord) =>
        r.deviceName === currentDeviceName && r.deviceId !== currentDeviceId
      );
      for (const record of staleRecords) {
        await this.deleteBackupFile(record.id);
      }
      if (staleRecords.length > 0) {
        // 仅在有实际删除时才清除图标包备份（避免不必要的云操作）
        this.iconPort.clearCloudBackup();
      }
      hilog.info(DOMAIN, TAG, `clearDeviceNameCloudStorage: completed, deleted ${staleRecords.length}`);
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, `clearDeviceNameCloudStorage: error=${JSON.stringify(e)}`);
      return false;
    }
  }

  /** 获取云端备份记录列表，按时间戳降序排列 */
  async listBackupHistory(): Promise<CloudBackupRecord[]> {
    await this.init();
    if (!this.context || !this.cloudDir) {
      hilog.error(DOMAIN, TAG, 'listBackupHistory: not initialized');
      return [];
    }

    return await this.listBackupRecords();
  }

  /** 检查是否需要自动备份：每日最多一次，需满足云同步开关 + 华为账号登录 */
  async checkAndAutoBackup(): Promise<void> {
    const enabled = AppPreference.getPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE) as boolean;
    if (!enabled) {
      return;
    }

    if (!this.accountPort.isUserLogin()) {
      return;
    }

    const lastTime = AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME) as string;
    const lastTs = SyncTimeHelper.parseStoredTimestamp(lastTime);
    if (lastTs > 0 && SyncTimeHelper.isToday(lastTs)) {
      hilog.info(DOMAIN, TAG, 'checkAndAutoBackup: already backed up today, skipping');
      return;
    }

    hilog.info(DOMAIN, TAG, 'checkAndAutoBackup: starting auto backup');
    const success = await this.backupToCloud();
    hilog.info(DOMAIN, TAG, `checkAndAutoBackup: result=${success}`);
  }

  /**
   * 从指定备份记录恢复数据
   *
   * 若文件在云端（location=2）先缓存到本地，再读取、解密、解析、写入。
   * @param recordId 备份文件名
   */
  async restoreFromBackupRecord(recordId: string): Promise<boolean> {
    await this.init();
    if (!this.context || !this.cloudDir) {
      hilog.error(DOMAIN, TAG, 'restoreFromBackupRecord: not initialized');
      return false;
    }

    if (!this.accountPort.isUserLogin()) {
      hilog.warn(DOMAIN, TAG, 'restoreFromBackupRecord: Huawei account not logged in, aborting');
      return false;
    }

    const encryptKey = this.accountPort.unionId();
    const mode = this.crypto.getMode(true);

    hilog.info(DOMAIN, TAG, `restoreFromBackupRecord: id=${recordId}`);

    const filePath = `${this.cloudDir}/${recordId}`;
    try {
      const stat = await this.fsPort.stat(filePath);
      hilog.info(DOMAIN, TAG, `restoreFromBackupRecord: file size=${stat.size}, location=${stat.location}`);

      if (stat.location === 2) {
        hilog.info(DOMAIN, TAG, 'restoreFromBackupRecord: file is in cloud, caching');
        await this.cacheFile(filePath);
      }

      const tokenContent = await this.fsPort.readTextFile(filePath);
      hilog.info(DOMAIN, TAG, `restoreFromBackupRecord: read ${tokenContent.length} chars`);

      const decrypted = await this.crypto.decrypt(tokenContent, mode, encryptKey);
      hilog.info(DOMAIN, TAG, `restoreFromBackupRecord: decrypted size=${decrypted.length}`);

      // 兼容新旧格式：新格式为 CloudBackupPayload（含 tokens 数组），旧格式为 TokenConfig[] 数组
      let tokens: TokenConfig[] = [];
      let enabledPacks: string[] = [];
      const payload = JSON.parse(decrypted) as CloudBackupPayload;
      if (payload && payload.tokens !== undefined && payload.tokens !== null) {
        tokens = payload.tokens;
        await this.groupPort.merge(payload.groups);
        if (payload.enabledPacks !== undefined && payload.enabledPacks !== null) {
          enabledPacks = payload.enabledPacks;
        }
      } else {
        const oldTokens = JSON.parse(decrypted) as TokenConfig[];
        tokens = oldTokens;
      }

      if (enabledPacks.length > 0) {
        AppPreference.saveEnabledPacks(enabledPacks);
        hilog.info(DOMAIN, TAG, `restoreFromBackupRecord: restored enabledPacks`);
      }

      hilog.info(DOMAIN, TAG, `restoreFromBackupRecord: token count=${tokens.length}`);

      for (const token of tokens) {
        await this.tokenPort.updateToken(token);
      }

      hilog.info(DOMAIN, TAG, 'restoreFromBackupRecord: completed successfully');
      return true;
    } catch (e) {
      if (e instanceof CloudBackupTokenError) {
        hilog.error(DOMAIN, TAG, `restoreFromBackupRecord: token error: ${e.message}`);
      } else {
        hilog.error(DOMAIN, TAG, `restoreFromBackupRecord: error=${JSON.stringify(e)}`);
      }
      return false;
    }
  }

  /** 删除单条备份记录并触发 FileSync 同步 */
  async deleteBackupRecord(recordId: string): Promise<boolean> {
    await this.init();
    if (!this.context || !this.cloudDir) {
      hilog.error(DOMAIN, TAG, 'deleteBackupRecord: not initialized');
      return false;
    }

    hilog.info(DOMAIN, TAG, `deleteBackupRecord: id=${recordId}`);
    const result = await this.deleteBackupFile(recordId);
    if (result) {
      await this.syncToCloud();
    }
    return result;
  }

  /** 删除指定备份文件（不同步） */
  private async deleteBackupFile(fileName: string): Promise<boolean> {
    const filePath = `${this.cloudDir}/${fileName}`;
    try {
      await this.fsPort.deleteFile(filePath);
      hilog.info(DOMAIN, TAG, `deleteBackupFile: deleted ${fileName}`);
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, `deleteBackupFile: error=${JSON.stringify(e)}`);
      return false;
    }
  }

  /** 扫描云端目录，解析备份文件头部元信息，返回按时间戳降序排列的记录列表 */
  private async listBackupRecords(): Promise<CloudBackupRecord[]> {
    const records: CloudBackupRecord[] = [];
    try {
      const files = await this.fsPort.listFiles(this.cloudDir);

      for (const fileName of files) {
        if (!isBackupFileName(fileName)) {
          continue;
        }

        const filePath = `${this.cloudDir}/${fileName}`;
        try {
          const stat = await this.fsPort.stat(filePath);
          const timestamp = parseBackupTimestamp(fileName);

          if (isNaN(timestamp)) {
            continue;
          }

          let tokenCount = 0;
          let fileSize = stat.size;
          let deviceId = '';
          let deviceName = '';
          try {
            const tokenContent = await this.fsPort.readTextFile(filePath);
            const header = this.crypto.parseTokenHeader(tokenContent);
            tokenCount = header.tokenCount;
            fileSize = header.size;
            deviceId = header.deviceId;
            deviceName = header.deviceName;
          } catch (e) {
            hilog.warn(DOMAIN, TAG, `listBackupRecords: parse header failed for ${fileName}, using file stat`);
          }

          // 与 SyncTimeHelper.formatTimestamp 同一格式，避免两处各写一遍补零逻辑
          const dateStr = SyncTimeHelper.formatTimestamp(timestamp);

          records.push({
            id: fileName,
            date: dateStr,
            timestamp: timestamp,
            tokenCount: tokenCount,
            size: fileSize,
            encrypted: true,
            deviceId: deviceId,
            deviceName: deviceName,
            location: stat.location,
          });
        } catch (e) {
          hilog.error(DOMAIN, TAG, `listBackupRecords: stat error for ${fileName}=${JSON.stringify(e)}`);
        }
      }

      records.sort((a, b) => b.timestamp - a.timestamp);
    } catch (e) {
      hilog.error(DOMAIN, TAG, `listBackupRecords: error=${JSON.stringify(e)}`);
    }

    hilog.info(DOMAIN, TAG, `listBackupRecords: returning ${records.length} records`);
    return records;
  }

  /** 触发 FileSync 将本地变更同步到云端 */
  private async syncToCloud(): Promise<void> {
    if (this.testDeps?.sync !== undefined) {
      try {
        await this.testDeps.sync.start();
        hilog.info(DOMAIN, TAG, 'syncToCloud: started');
      } catch (e) {
        hilog.error(DOMAIN, TAG, `syncToCloud: error=${JSON.stringify(e)}`);
      }
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

  /** 将云端文件缓存到本地（location=2 时文件仅存在云端，需先拉取） */
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

  get maxBackupCount(): number {
    return MAX_BACKUP_COUNT;
  }
}
