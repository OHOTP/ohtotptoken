import { describe, it, expect } from '@ohos/hypium';
import { SyncTimeHelper } from 'common';

/**
 * SyncTimeHelper 单元测试(云同步时间戳的格式化/解析/边界)。
 * 使用本地时区构造期望值,避免断言依赖运行环境的时区设置。
 */
export default function syncTimeHelperTest() {
  describe('syncTimeHelperTest', () => {
    it('formatTimestamp_invalid_returns_empty', 0, () => {
      expect(SyncTimeHelper.formatTimestamp(0)).assertEqual('');
      expect(SyncTimeHelper.formatTimestamp(-5)).assertEqual('');
    });

    it('formatTimestamp_local_time_format', 0, () => {
      // 2026-04-23 14:30 本地时间
      let ts = new Date(2026, 3, 23, 14, 30).getTime();
      expect(SyncTimeHelper.formatTimestamp(ts)).assertEqual('2026-04-23 14:30');
    });

    it('formatTimestamp_pads_single_digits', 0, () => {
      let ts = new Date(2026, 0, 5, 3, 7).getTime();
      expect(SyncTimeHelper.formatTimestamp(ts)).assertEqual('2026-01-05 03:07');
    });

    it('parseStoredTimestamp_number_passthrough', 0, () => {
      expect(SyncTimeHelper.parseStoredTimestamp(1745385600000)).assertEqual(1745385600000);
      expect(SyncTimeHelper.parseStoredTimestamp(0)).assertEqual(0);
    });

    it('parseStoredTimestamp_numeric_string', 0, () => {
      expect(SyncTimeHelper.parseStoredTimestamp('1745385600000')).assertEqual(1745385600000);
    });

    it('parseStoredTimestamp_empty_or_invalid_returns_zero', 0, () => {
      expect(SyncTimeHelper.parseStoredTimestamp('')).assertEqual(0);
      expect(SyncTimeHelper.parseStoredTimestamp('garbage')).assertEqual(0);
    });

    it('parseStoredTimestamp_legacy_date_string', 0, () => {
      // 旧格式 "YYYY-MM-DD HH:mm" 兼容解析
      let expected = new Date(2026, 3, 23, 14, 30).getTime();
      expect(SyncTimeHelper.parseStoredTimestamp('2026-04-23 14:30')).assertEqual(expected);
    });

    it('yesterday_end_adjacent_to_today_start', 0, () => {
      expect(SyncTimeHelper.getYesterdayEndTs()).assertEqual(SyncTimeHelper.getTodayStartTs() - 1);
    });

    it('isToday_and_isWithinMinutes_reject_nonpositive', 0, () => {
      expect(SyncTimeHelper.isToday(0)).assertFalse();
      expect(SyncTimeHelper.isWithinMinutes(0, 5)).assertFalse();
    });
  });
}
