/**
 * CloudSyncTask — 云端备份初始同步的 TaskPool 并发任务
 *
 * 此文件定义 @Concurrent 函数，供 taskpool.execute() 在后台线程执行，
 * 避免 I/O 密集操作（目录检查、文件列表）阻塞 UI 主线程。
 *
 * 函数说明：
 * - checkCloudBackupRecords: 确保云端目录存在，统计备份文件数量并返回
 * - loadBackupHistoryRecords: 读取所有备份文件并解析 header 元数据，返回完整备份记录列表
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { buffer, util } from '@kit.ArkTS';
import { CloudBackupRecord, CloudBackupTokenHeader } from './CloudBackupCrypto';
import { formatRecordDate, isBackupFileName, parseBackupTimestamp } from './CommonUtils';



/**
 * 在 TaskPool 后台线程中检查云端备份记录数量。
 * 1. 检查云端目录是否存在，不存在则创建
 * 2. 遍历目录文件，统计匹配 otp_backup_*.enc 模式的文件数
 * @param cloudDir 云端目录路径（由主线程传入，避免在子线程访问 AppStorage）
 * @returns 备份文件数量
 */
@Concurrent
export async function checkCloudBackupRecords(cloudDir: string): Promise<number> {
  let recordCount: number = 0;
  const TAG = 'CloudSyncTask';
  const DOMAIN = 0xFF00;
  try {
    try {
      await fs.stat(cloudDir);
    } catch (e) {
      hilog.info(DOMAIN, TAG, `checkCloudBackupRecords: dir not exist, creating`);
      try {
        await fs.mkdir(cloudDir);
      } catch (err) {
        hilog.error(DOMAIN, TAG, `checkCloudBackupRecords: mkdir failed: ${JSON.stringify(err)}`);
        return 0;
      }
    }

    const files: Array<string> = fs.listFileSync(cloudDir);
    for (let i = 0; i < files.length; i++) {
      if (isBackupFileName(files[i])) {
        recordCount++;
      }
    }
  } catch (e) {
    hilog.error(DOMAIN, TAG, `checkCloudBackupRecords: error=${JSON.stringify(e)}`);
  }

  hilog.info(DOMAIN, TAG, `checkCloudBackupRecords: found ${recordCount} records`);
  return recordCount;
}

/**
 * 在 TaskPool 后台线程中加载完整备份历史记录。
 * 1. 遍历云端目录，筛选 otp_backup_*.enc 文件
 * 2. 读取每个文件内容，解析 JWT-like header 获取 tokenCount/deviceId/deviceName 等元数据
 * 3. 云端文件（location=2）读取失败时降级为仅 stat 信息
 * 4. 按时间戳降序排列返回
 * @param cloudDir 云端目录路径（由主线程传入，避免在子线程访问 AppStorage/单例）
 * @returns 备份记录数组
 */
@Concurrent
export async function loadBackupHistoryRecords(cloudDir: string): Promise<CloudBackupRecord[]> {
  const base64Helper: util.Base64Helper = new util.Base64Helper();
  const records: CloudBackupRecord[] = [];
  const TAG = 'CloudSyncTask';
  const DOMAIN = 0xFF00;

  try {
    const files: Array<string> = fs.listFileSync(cloudDir);
    for (let i = 0; i < files.length; i++) {
      const fileName: string = files[i];
      if (!isBackupFileName(fileName)) {
        continue;
      }

      const filePath: string = `${cloudDir}/${fileName}`;
      try {
        const stat = await fs.stat(filePath);
        const timestamp: number = parseBackupTimestamp(fileName);

        if (isNaN(timestamp)) {
          continue;
        }

        let tokenCount: number = 0;
        let fileSize: number = stat.size;
        let deviceId: string = '';
        let deviceName: string = '';
        try {
          const file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
          const bufferArray: ArrayBuffer = new ArrayBuffer(stat.size);
          const readLen: number = fs.readSync(file.fd, bufferArray);
          fs.closeSync(file);
          const uint8Array: Uint8Array = new Uint8Array(bufferArray.slice(0, readLen));
          const tokenContent: string = buffer.from(uint8Array).toString('utf-8');
          const segments: string[] = tokenContent.split('.');
          if (segments.length === 3) {
            const headerBytes: Uint8Array = base64Helper.decodeSync(segments[0]);
            const headerJson: string = buffer.from(headerBytes).toString('utf-8');
            const header: CloudBackupTokenHeader = JSON.parse(headerJson) as CloudBackupTokenHeader;
            tokenCount = header.tokenCount;
            fileSize = header.size;
            deviceId = header.deviceId;
            deviceName = header.deviceName;
          }
        } catch (e) {
          hilog.warn(DOMAIN, TAG, `loadBackupHistoryRecords: parse header failed for ${fileName}`);
        }

        const dateStr: string = formatRecordDate(timestamp);

        const record: CloudBackupRecord = {
          id: fileName,
          date: dateStr,
          timestamp: timestamp,
          tokenCount: tokenCount,
          size: fileSize,
          encrypted: true,
          deviceId: deviceId,
          deviceName: deviceName,
          location: stat.location,
        };
        records.push(record);
      } catch (e) {
        hilog.error(DOMAIN, TAG, `loadBackupHistoryRecords: stat error for ${fileName}=${JSON.stringify(e)}`);
      }
    }

    records.sort((a: CloudBackupRecord, b: CloudBackupRecord) => b.timestamp - a.timestamp);
  } catch (e) {
    hilog.error(DOMAIN, TAG, `loadBackupHistoryRecords: error=${JSON.stringify(e)}`);
  }

  hilog.info(DOMAIN, TAG, `loadBackupHistoryRecords: returning ${records.length} records`);
  return records;
}


