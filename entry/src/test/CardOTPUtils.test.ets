import { describe, it, expect } from '@ohos/hypium';
import { generateCardOTP } from '../main/ets/widget/utils/CardOTPUtils';

/**
 * CardOTPUtils 单元测试。
 *
 * 向量来源:RFC 4226 附录 D(secret = ASCII "12345678901234567890",
 * base32 = GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ)给出的 HOTP 截断二进制值。
 * 六位截断与 RFC 4226 附录 D 一致;counter=1 取 8 位 = 94287082,
 * 与 RFC 6238 SHA-1 @ T=59 官方向量交叉一致。
 * tokenType='2' 且 counter>=0 走确定性 HOTP 路径,不依赖时钟,可在 LocalUnit 断言。
 */
const RFC_SECRET = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';

export default function cardOTPUtilsTest() {
  describe('cardOTPUtilsTest', () => {
    it('rfc4226_six_digit_vectors', 0, () => {
      expect(generateCardOTP(RFC_SECRET, 'SHA1', 6, 30, '2', 0)).assertEqual('755224');
      expect(generateCardOTP(RFC_SECRET, 'SHA1', 6, 30, '2', 1)).assertEqual('287082');
      expect(generateCardOTP(RFC_SECRET, 'SHA1', 6, 30, '2', 2)).assertEqual('359152');
      expect(generateCardOTP(RFC_SECRET, 'SHA1', 6, 30, '2', 3)).assertEqual('969429');
      expect(generateCardOTP(RFC_SECRET, 'SHA1', 6, 30, '2', 4)).assertEqual('338314');
      expect(generateCardOTP(RFC_SECRET, 'SHA1', 6, 30, '2', 5)).assertEqual('254676');
    });

    it('rfc6238_eight_digit_cross_check', 0, () => {
      // counter=1 即 RFC 6238 的 T=59 场景
      expect(generateCardOTP(RFC_SECRET, 'SHA1', 8, 30, '2', 1)).assertEqual('94287082');
    });

    it('rfc6238_leading_zero_large_counter', 0, () => {
      // RFC 6238 SHA-1 @ T=1111111109(steps=37037036):8 位结果 07081804,
      // 同时覆盖前导零保留与大 counter 路径
      expect(generateCardOTP(RFC_SECRET, 'SHA1', 8, 30, '2', 37037036)).assertEqual('07081804');
    });

    it('steam_variant_shape', 0, () => {
      // tokenType='3' 走时钟路径(TOTP),无法离线断言具体值;
      // 字符映射逻辑已由 SteamUtils.test.ets 的确定性用例覆盖,这里只断言形状
      let otp = generateCardOTP(RFC_SECRET, 'SHA1', 10, 30, '3', 1);
      expect(otp.length).assertEqual(5);
      expect(/^[23456789BCDFGHJKMNPQRTVWXY]+$/.test(otp)).assertTrue();
    });

    it('sha256_algorithm_currently_falls_back_to_sha1', 0, () => {
      // 现状固化:实现中 SHA256 分支与默认分支相同,仍走 HMAC-SHA1。
      // 若未来真正支持 SHA256,此用例应随实现一起更新
      expect(generateCardOTP(RFC_SECRET, 'SHA256', 6, 30, '2', 1)).assertEqual('287082');
    });

    it('counter_truncates_to_uint32', 0, () => {
      // 现状固化:stepsToBytes 用 setUint32(4, steps),仅低 32 位生效,
      // 2^32+1 与 1 结果一致
      expect(generateCardOTP(RFC_SECRET, 'SHA1', 6, 30, '2', 4294967297)).assertEqual('287082');
    });

    it('invalid_base32_chars_are_skipped', 0, () => {
      // 现状固化:此实现的 base32Decode 对非法字符是跳过(continue),
      // 与 TokenUtils 版本抛异常不同;尾部非法字符不改变结果
      expect(generateCardOTP(RFC_SECRET + '!', 'SHA1', 6, 30, '2', 1)).assertEqual('287082');
    });

    it('totp_path_returns_digit_sized_numeric_string', 0, () => {
      // TOTP 路径依赖 Date.now(),只断言形状:定长数字串
      let otp = generateCardOTP(RFC_SECRET, 'SHA1', 6, 30, '0');
      expect(otp.length).assertEqual(6);
      expect(/^\d+$/.test(otp)).assertTrue();
    });
  });
}
