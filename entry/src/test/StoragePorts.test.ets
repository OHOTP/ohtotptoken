import { describe, it, expect } from '@ohos/hypium';
import {
  BACKUP_FILE_EXT,
  BACKUP_FILE_PREFIX,
  formatRecordDate,
  isBackupFileName,
  parseBackupTimestamp,
  utf8ByteLength,
} from 'common';

/**
 * Phase 2 端口基础工具与共享助手测试：
 * utf8ByteLength（ASSET 900 字节上限判定基础）、备份文件名解析/过滤/日期格式化。
 */

export default function storagePortsTest() {
  describe('storagePortsTest', () => {
    it('utf8_byte_length_counts_ascii_single_bytes', 0, () => {
      expect(utf8ByteLength('')).assertEqual(0);
      expect(utf8ByteLength('hello')).assertEqual(5);
      expect(utf8ByteLength('JBSWY3DPEHPK3PXP')).assertEqual(16);
    });

    it('utf8_byte_length_counts_cjk_three_bytes', 0, () => {
      expect(utf8ByteLength('令')).assertEqual(3);
      expect(utf8ByteLength('中文abc')).assertEqual(3 + 3 + 3);
    });

    it('utf8_byte_length_counts_emoji_as_four_bytes', 0, () => {
      // 😀 = U+1F600，代理对，4 字节
      expect(utf8ByteLength('😀')).assertEqual(4);
      expect(utf8ByteLength('a😀b')).assertEqual(6);
    });

    it('utf8_byte_length_matches_asset_900_byte_boundary', 0, () => {
      // 900 字节 ASCII 恰好在限内；901 超限
      const ok = 'a'.repeat(900);
      const tooLong = 'a'.repeat(901);
      expect(utf8ByteLength(ok) <= 900).assertTrue();
      expect(utf8ByteLength(tooLong) <= 900).assertFalse();
      // 300 个汉字 = 900 字节（恰好在限内）
      expect(utf8ByteLength('令'.repeat(300))).assertEqual(900);
    });

    it('backup_file_name_filter_matches_prefix_and_suffix', 0, () => {
      expect(isBackupFileName('otp_backup_123.enc')).assertTrue();
      expect(isBackupFileName('otp_backup_notanumber.enc')).assertTrue();
      expect(isBackupFileName('otp_backup_123.txt')).assertFalse();
      expect(isBackupFileName('other_otp_backup_123.enc')).assertFalse();
      expect(BACKUP_FILE_PREFIX).assertEqual('otp_backup_');
      expect(BACKUP_FILE_EXT).assertEqual('.enc');
    });

    it('parse_backup_timestamp_reads_millisecond_field', 0, () => {
      expect(parseBackupTimestamp('otp_backup_1745385600000.enc')).assertEqual(1745385600000);
      expect(isNaN(parseBackupTimestamp('otp_backup_notanumber.enc'))).assertTrue();
    });

    it('format_record_date_produces_display_format', 0, () => {
      // 2025-04-23 14:30 UTC+8 = 1745385000000；本地时区影响绝对值，
      // 因此用本地 Date 构造后对照字段值
      const d = new Date(2025, 3, 23, 14, 30, 0);
      const formatted = formatRecordDate(d.getTime());
      expect(formatted).assertEqual('2025-04-23 14:30');
    });
  });
}
