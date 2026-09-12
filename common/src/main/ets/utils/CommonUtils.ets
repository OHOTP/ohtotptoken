/**
 * CommonUtils — 通用工具函数
 *
 * 此文件导出纯函数，可安全在 @Concurrent 装饰的 TaskPool 函数中通过 import 引入。
 */

import { systemDateTime } from '@kit.BasicServicesKit';

/** 数字补零：小于 10 时前补 '0'，用于日期/时间格式化 */
export function padZero(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

/**
 * 当前 Unix 秒。
 *
 * 全工程统一走这里（手机/手表），避免各页面各自内联
 * `Math.floor(systemDateTime.getTime()/1000)` 与 `Math.floor(Date.now()/1000)`
 * 两套基准。卡片进程（FormExtensionAbility）不能 import common，
 * 仍使用 `Date.now()`，两者读取的是同一个系统时钟。
 */
export function nowUnixSeconds(): number {
  return Math.floor(systemDateTime.getTime() / 1000);
}

/** 异步延时（毫秒）；替代各处重复的 `new Promise(resolve => setTimeout(resolve, ms))` */
export function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => resolve(), ms);
  });
}

// ---- 云备份文件名规则（CloudBackupManager 与 CloudSyncTask 共享）----

/** 备份文件命名规则：`otp_backup_{毫秒时间戳}.enc` */
export const BACKUP_FILE_PREFIX = 'otp_backup_';
export const BACKUP_FILE_EXT = '.enc';

/** 是否为备份文件（按前缀/后缀过滤） */
export function isBackupFileName(fileName: string): boolean {
  return fileName.startsWith(BACKUP_FILE_PREFIX) && fileName.endsWith(BACKUP_FILE_EXT);
}

/** 从备份文件名解析毫秒时间戳；非法（NaN）由调用方跳过 */
export function parseBackupTimestamp(fileName: string): number {
  return parseInt(fileName.replace(BACKUP_FILE_PREFIX, '').replace(BACKUP_FILE_EXT, ''));
}

/** 备份记录展示日期（与 SyncTimeHelper.formatTimestamp 同一格式） */
export function formatRecordDate(timestamp: number): string {
  const d: Date = new Date(timestamp);
  return `${d.getFullYear()}-${padZero(d.getMonth() + 1)}-${padZero(d.getDate())} ${padZero(d.getHours())}:${padZero(d.getMinutes())}`;
}
