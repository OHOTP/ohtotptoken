import { describe, it, expect } from '@ohos/hypium';
import { generateCardOTP } from '../main/ets/widget/utils/CardOTPUtils';

/**
 * CardOTPUtils 单元测试。
 *
 * 向量来源:RFC 4226 附录 D(secret = ASCII "12345678901234567890",
 * base32 = GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ)给出的 HOTP 截断二进制值:
 *   counter 0..5 → 1284755224 / 1094287082 / 137409008 / 1726717525 /
 *                  1640338314 / 1087423071
 * 其中 counter=1 取 8 位 = 94287082,与 RFC 6238 SHA-1 @ T=59 官方向量一致(交叉验证)。
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

    it('leading_zero_padding', 0, () => {
      // counter=2 的 8 位结果为 137409008 % 10^8 = 3709008,前导零必须保留
      expect(generateCardOTP(RFC_SECRET, 'SHA1', 8, 30, '2', 2)).assertEqual('03709008');
    });

    it('steam_variant_from_rfc_binary', 0, () => {
      // digits=10 时截断值 1094287082(< 10^10 不变),按字符表
      // 23456789BCDFGHJKMNPQRTVWXY 逐位取模手算 → P/V/9/M/4
      expect(generateCardOTP(RFC_SECRET, 'SHA1', 10, 30, '3', 1)).assertEqual('PV9M4');
    });

    it('sha256_algorithm_currently_falls_back_to_sha1', 0, () => {
      // 现状固化:实现中 SHA256 分支与默认分支相同,仍走 HMAC-SHA1。
      // 若未来真正支持 SHA256,此用例应随实现一起更新。
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
