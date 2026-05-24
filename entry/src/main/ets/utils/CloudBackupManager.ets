/*
 * Copyright (c) 2023-2024 ohtotptoken Project Contributors
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppPreference, PREF_KEYS } from './AppPreference';
import { CloudBackupCrypto, CloudBackupCryptoMode, CloudBackupRecord, CloudBackupTokenError } from './CloudBackupCrypto';
import { TokenStore } from './TokenStore';
import { TokenConfig } from './TokenConfig';
import { fileIo as fs, cloudSync, fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { buffer, taskpool } from '@kit.ArkTS';
import { DeviceInfoHelper } from './DeviceInfoHelper';
import { HuaweiAccountManager } from './HuaweiAccountManager';
import { SyncTimeHelper } from './SyncTimeHelper';
import { loadBackupHistoryRecords } from './CloudSyncTask';

const TAG = 'CloudBackupManager';
const DOMAIN = 0xFF00;
const MAX_BACKUP_COUNT = 5;
const BACKUP_FILE_PREFIX = 'otp_backup_';
const BACKUP_FILE_EXT = '.enc';

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
 * @module CloudBackupManager
 */
export class CloudBackupManager {
  private static instance: CloudBackupManager | null = null;
  private crypto: CloudBackupCrypto = CloudBackupCrypto.getInstance();
  private context: common.UIAbilityContext | undefined = undefined;
  private cloudDir: string = '';
  private fileSync: cloudSync.FileSync | null = null;

  private constructor() {
  }

  static getInstance(): CloudBackupManager {
    if (!CloudBackupManager.instance) {
      CloudBackupManager.instance = new CloudBackupManager();
    }
    return CloudBackupManager.instance;
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
      const stat = await fs.stat(this.cloudDir);
      hilog.info(DOMAIN, TAG, `ensureCloudDirExists: exists, location=${stat.location}`);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, `ensureCloudDirExists: not exist, creating`);
      try {
        await fs.mkdir(this.cloudDir);
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
  async backupToCloud(externalSync?: cloudSync.FileSync): Promise<boolean> {
    await this.init();
    if (!this.context || !this.cloudDir) {
      hilog.error(DOMAIN, TAG, 'backupToCloud: not initialized');
      return false;
    }

    const accountMgr = HuaweiAccountManager.getInstance();
    if (!accountMgr.userLogin) {
      hilog.warn(DOMAIN, TAG, 'backupToCloud: Huawei account not logged in, aborting');
      return false;
    }

    const encryptKey = accountMgr.userAccount.unionId;
    const mode = this.crypto.getMode(true);
    const deviceId = DeviceInfoHelper.getInstance().getDeviceId();
    const deviceName = DeviceInfoHelper.getInstance().getDeviceName();

    hilog.info(DOMAIN, TAG, `backupToCloud: starting backup, mode=${mode}`);

    const tokens = await TokenStore.getInstance().getTokens();
    const plaintext = JSON.stringify(tokens);
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
      const file = fs.openSync(filePath, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      const writeLen = fs.writeSync(file.fd, token);
      fs.closeSync(file);
      hilog.info(DOMAIN, TAG, `backupToCloud: wrote ${writeLen} bytes to ${fileName}`);
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

    await this.syncToCloud(externalSync);

    AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, `${now}`);

    hilog.info(DOMAIN, TAG, 'backupToCloud: completed successfully');
    return true;
  }

  /**
   * 从云端恢复最新的备份数据
   *
   * 解密后逐条调用 `TokenStore.updateToken` 写入本地 KV。
   * @returns 是否成功
   */
  async restoreFromCloud(): Promise<boolean> {
    await this.init();
    if (!this.context || !this.cloudDir) {
      hilog.error(DOMAIN, TAG, 'restoreFromCloud: not initialized');
      return false;
    }

    const accountMgr = HuaweiAccountManager.getInstance();
    if (!accountMgr.userLogin) {
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

    if (!HuaweiAccountManager.getInstance().userLogin) {
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

    if (!HuaweiAccountManager.getInstance().userLogin) {
      hilog.warn(DOMAIN, TAG, 'clearDeviceCloudStorage: Huawei account not logged in, aborting');
      return false;
    }

    const deviceId = DeviceInfoHelper.getInstance().getDeviceId();
    hilog.info(DOMAIN, TAG, `clearDeviceCloudStorage: clearing device=${deviceId}`);

    try {
      const records = await this.listBackupRecords();
      const deviceRecords = records.filter((r: CloudBackupRecord) => r.deviceId === deviceId);
      for (const record of deviceRecords) {
        await this.deleteBackupFile(record.id);
      }
      AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, '0');
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

    if (!HuaweiAccountManager.getInstance().userLogin) {
      hilog.warn(DOMAIN, TAG, 'clearDeviceNameCloudStorage: Huawei account not logged in, aborting');
      return false;
    }

    const currentDeviceId = DeviceInfoHelper.getInstance().getDeviceId();
    const currentDeviceName = DeviceInfoHelper.getInstance().getDeviceName();
    hilog.info(DOMAIN, TAG, `clearDeviceNameCloudStorage: name=${currentDeviceName}, excluding odid=${currentDeviceId}`);

    try {
      const records = await this.listBackupRecords();
      const staleRecords = records.filter((r: CloudBackupRecord) =>
        r.deviceName === currentDeviceName && r.deviceId !== currentDeviceId
      );
      for (const record of staleRecords) {
        await this.deleteBackupFile(record.id);
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

    if (!HuaweiAccountManager.getInstance().userLogin) {
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

    const accountMgr = HuaweiAccountManager.getInstance();
    if (!accountMgr.userLogin) {
      hilog.warn(DOMAIN, TAG, 'restoreFromBackupRecord: Huawei account not logged in, aborting');
      return false;
    }

    const encryptKey = accountMgr.userAccount.unionId;
    const mode = this.crypto.getMode(true);

    hilog.info(DOMAIN, TAG, `restoreFromBackupRecord: id=${recordId}`);

    const filePath = `${this.cloudDir}/${recordId}`;
    try {
      const stat = await fs.stat(filePath);
      hilog.info(DOMAIN, TAG, `restoreFromBackupRecord: file size=${stat.size}, location=${stat.location}`);

      if (stat.location === 2) {
        hilog.info(DOMAIN, TAG, 'restoreFromBackupRecord: file is in cloud, caching');
        await this.cacheFile(filePath);
      }

      const tokenContent = await this.readFileContent(filePath);
      hilog.info(DOMAIN, TAG, `restoreFromBackupRecord: read ${tokenContent.length} chars`);

      const decrypted = await this.crypto.decrypt(tokenContent, mode, encryptKey);
      hilog.info(DOMAIN, TAG, `restoreFromBackupRecord: decrypted size=${decrypted.length}`);

      const tokens: TokenConfig[] = JSON.parse(decrypted) as TokenConfig[];
      hilog.info(DOMAIN, TAG, `restoreFromBackupRecord: token count=${tokens.length}`);

      for (const token of tokens) {
        await TokenStore.getInstance().updateToken(token);
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
      await fs.unlink(filePath);
      hilog.info(DOMAIN, TAG, `deleteBackupFile: deleted ${fileName}`);
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, `deleteBackupFile: error=${JSON.stringify(e)}`);
      return false;
    }
  }

  /**
   * 扫描云端目录，解析备份文件头部元信息，返回按时间戳降序排列的记录列表。
   * 委托到 TaskPool 后台线程执行 I/O 密集型操作，避免阻塞主线程。
   */
  private async listBackupRecords(): Promise<CloudBackupRecord[]> {
    try {
      const result = await taskpool.execute(loadBackupHistoryRecords, this.cloudDir);
      const records = result as CloudBackupRecord[];
      hilog.info(DOMAIN, TAG, `listBackupRecords: returning ${records.length} records`);
      return records;
    } catch (e) {
      hilog.error(DOMAIN, TAG, `listBackupRecords: error=${JSON.stringify(e)}`);
      return [];
    }
  }

  /** 读取文件全部内容为 UTF-8 字符串 */
  private async readFileContent(filePath: string): Promise<string> {
    const stat = await fs.stat(filePath);
    const file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
    const bufferArray = new ArrayBuffer(stat.size);
    const readLen = fs.readSync(file.fd, bufferArray);
    fs.closeSync(file);
    const uint8Array = new Uint8Array(bufferArray.slice(0, readLen));
    return buffer.from(uint8Array).toString('utf-8');
  }

  /** 触发 FileSync 将本地变更同步到云端。接受可选的外部 FileSync 实例用于进度回调 */
  private async syncToCloud(externalSync?: cloudSync.FileSync): Promise<void> {
    const sync = externalSync || (this.fileSync || (this.fileSync = new cloudSync.FileSync()));

    try {
      await sync.start();
      hilog.info(DOMAIN, TAG, 'syncToCloud: started');
    } catch (e) {
      hilog.error(DOMAIN, TAG, `syncToCloud: error=${JSON.stringify(e)}`);
    }
  }

  /** 将云端文件缓存到本地（location=2 时文件仅存在云端，需先拉取） */
  private async cacheFile(filePath: string): Promise<void> {
    const uri = fileUri.getUriFromPath(filePath);
    const cache = new cloudSync.CloudFileCache();
    try {
      await cache.start(uri);
      hilog.info(DOMAIN, TAG, `cacheFile: cached ${filePath}`);
    } catch (e) {
      hilog.error(DOMAIN, TAG, `cacheFile: error=${JSON.stringify(e)}`);
    }
  }

  get maxBackupCount(): number {
    return MAX_BACKUP_COUNT;
  }

  private padZero(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
  }
}
