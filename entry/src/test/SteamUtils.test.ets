import { describe, it, expect } from '@ohos/hypium';
import { SteamUtils } from 'common';

/**
 * SteamUtils.SteamTokenFromTOTP 单元测试。
 * 字符表 "23456789BCDFGHJKMNPQRTVWXY"(26 字符,排除易混淆字符),
 * 对输入数字做 5 轮"取模 + 缩小"映射。
 */
export default function steamUtilsTest() {
  describe('steamUtilsTest', () => {
    it('zero_input_maps_to_first_char_repeated', 0, () => {
      expect(SteamUtils.SteamTokenFromTOTP(0)).assertEqual('22222');
    });

    it('small_input_known_values', 0, () => {
      // 1: 首位 chars[1]='3',其后 int_code 归零 → '32222'
      expect(SteamUtils.SteamTokenFromTOTP(1)).assertEqual('32222');
      // 26 = 26*1+0 → 首位 '2',次位 1 → '3',其余归零 → '23222'
      expect(SteamUtils.SteamTokenFromTOTP(26)).assertEqual('23222');
    });

    it('rfc_derived_large_input', 0, () => {
      // 1094287082 = RFC 4226 counter=1 的截断二进制值(见 CardOTPUtils.test.ets),
      // 逐轮取模 26 → P/V/9/M/4
      expect(SteamUtils.SteamTokenFromTOTP(1094287082)).assertEqual('PV9M4');
    });

    it('output_length_is_five', 0, () => {
      expect(SteamUtils.SteamTokenFromTOTP(987654321).length).assertEqual(5);
    });
  });
}
