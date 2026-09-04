import { describe, it, expect } from '@ohos/hypium';
import { colorHex, hexColor, scaleRgba, mixRgba, setRgba } from 'common';

/**
 * ColorUtils 单元测试(位运算组合 / 双格式解析 / 钳位)。
 * 注:scaleRgba/mixRgba 中 `& 0xff * scale` 因运算符优先级等价于
 * `& (0xff * scale)`,并非"先取通道再缩放"——相关用例按现状语义固化。
 */
export default function colorUtilsTest() {
  describe('colorUtilsTest', () => {
    it('colorHex_pads_and_handles_sign', 0, () => {
      expect(colorHex(0x123456)).assertEqual('#00123456');
      expect(colorHex(0xFFFFFFFF)).assertEqual('#ffffffff');
      // (255<<24) 为负 int32,>>>0 归一后仍正确
      expect(colorHex(setRgba(255, 255, 255, 255))).assertEqual('#ffffffff');
      expect(colorHex(setRgba(255, 100, 0, 255))).assertEqual('#ffff6400');
    });

    it('hexColor_parses_rrggbb', 0, () => {
      expect(hexColor('#FF6400')).assertEqual(setRgba(255, 100, 0, 255));
      expect(hexColor('#102030')).assertEqual(setRgba(0x10, 0x20, 0x30, 255));
    });

    it('hexColor_parses_aarrggbb_ignoring_alpha', 0, () => {
      // 9 位格式跳过 alpha 两位,结果与 6 位一致
      expect(hexColor('#80FF6400')).assertEqual(setRgba(255, 100, 0, 255));
    });

    it('hexColor_invalid_inputs_return_zero', 0, () => {
      expect(hexColor('#FFF')).assertEqual(0);
      expect(hexColor('FF6400')).assertEqual(0);
      expect(hexColor('')).assertEqual(0);
    });

    it('scaleRgba_full_and_zero', 0, () => {
      // scale=1: & 0xff*1 即原通道;scale=0: & 0 全黑
      expect(scaleRgba(0xFF964300, 1)).assertEqual(setRgba(0x96, 0x43, 0x00, 255));
      expect(scaleRgba(0xFF964300, 0)).assertEqual(setRgba(0, 0, 0, 255));
    });

    it('scaleRgba_half_scale_pin_current_semantics', 0, () => {
      // 现状固化:0xff*0.5 = 127.5 → ToInt32 127,即"通道 & 127"。
      // 0x96(150) & 127 = 22;0x43(67) & 127 = 67(<127 不变);0 不变
      expect(scaleRgba(0xFF964300, 0.5)).assertEqual(setRgba(22, 67, 0, 255));
    });

    it('scaleRgba_clamps_out_of_range', 0, () => {
      expect(scaleRgba(0xFF964300, 5)).assertEqual(scaleRgba(0xFF964300, 1));
      expect(scaleRgba(0xFF964300, -1)).assertEqual(setRgba(0, 0, 0, 255));
    });

    it('mixRgba_at_zero_and_one', 0, () => {
      let a = 0xFF964300;
      let b = 0xFF0043FF;
      // ratio=0 → 全取 b 通道;ratio=1 → 全取 a 通道
      expect(mixRgba(a, b, 0)).assertEqual(setRgba(0x00, 0x43, 0xFF, 255));
      expect(mixRgba(a, b, 1)).assertEqual(setRgba(0x96, 0x43, 0x00, 255));
    });

    it('mixRgba_clamps_out_of_range', 0, () => {
      let a = 0xFF964300;
      let b = 0xFF0043FF;
      expect(mixRgba(a, b, 2)).assertEqual(mixRgba(a, b, 1));
      expect(mixRgba(a, b, -1)).assertEqual(mixRgba(a, b, 0));
    });
  });
}
