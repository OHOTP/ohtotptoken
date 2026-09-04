import { describe, it, expect } from '@ohos/hypium';
import { padZero } from 'common';

/**
 * CommonUtils.padZero 单元测试。
 */
export default function commonUtilsTest() {
  describe('commonUtilsTest', () => {
    it('pads_single_digits', 0, () => {
      expect(padZero(0)).assertEqual('00');
      expect(padZero(9)).assertEqual('09');
    });

    it('keeps_double_and_larger_digits', 0, () => {
      expect(padZero(10)).assertEqual('10');
      expect(padZero(99)).assertEqual('99');
      expect(padZero(100)).assertEqual('100');
    });

    it('negative_input_current_quirk', 0, () => {
      // 现状固化:n<10 一律前插 '0',负数得到 '0-1'。调用方均为日期分量,不会为负;
      // 若未来需要支持负数,应先修正实现再更新此用例
      expect(padZero(-1)).assertEqual('0-1');
    });
  });
}
