import { describe, it, expect } from '@ohos/hypium';
import { counterToBytes64, OTPDefaultIconPack } from 'common';

/**
 * OTPDefaultIconPack 数据完整性与 counterToBytes64 大数值边界。
 * （getIconPathByIssuer 基础映射已由 TokenUtilsExtra.test.ets 覆盖；
 * base32 各变体已由 Base32.test.ets 覆盖。）
 */
export default function tokenUtilsIconPackTest() {
  describe('tokenUtilsIconPackTest', () => {
    it('issuer_table_has_no_duplicates_and_is_lowercase', 0, () => {
      const pack = new OTPDefaultIconPack();
      const unique = new Set<string>(pack.issuers);
      expect(unique.size).assertEqual(pack.issuers.length);
      for (const issuer of pack.issuers) {
        expect(issuer).assertEqual(issuer.toLowerCase());
      }
    });

    it('built_in_path_set_covers_every_issuer', 0, () => {
      const pack = new OTPDefaultIconPack();
      expect(pack.default_icon_pack_path.length).assertEqual(pack.issuers.length);
      for (const path of pack.default_icon_pack_path) {
        expect(path.startsWith('rawfile://icons/token_image_')).assertTrue();
        expect(path.endsWith('.svg')).assertTrue();
      }
    });

    it('get_icon_path_normalizes_space_and_case_or_empty', 0, () => {
      const pack = new OTPDefaultIconPack();
      expect(pack.getIconPathByIssuer('')).assertEqual('');
      expect(pack.getIconPathByIssuer('GITHUB')).assertEqual('rawfile://icons/token_image_github.svg');
      expect(pack.getIconPathByIssuer('Microsoft Teams'))
        .assertEqual('rawfile://icons/token_image_microsoft_teams.svg');
      // key 存在性查的是小写集合：非法 issuer 返回空串而不是抛异常
      expect(pack.getIconPathByIssuer('Not An Issuer')).assertEqual('');
    });

    it('counter_to_bytes64_handles_large_counters', 0, () => {
      // 2^40 = 0x0000010000000000：32 位右移实现会出错的量级
      expect(Array.from(counterToBytes64(1099511627776)).join(','))
        .assertEqual('0,0,1,0,0,0,0,0');
      expect(Array.from(counterToBytes64(1)).join(','))
        .assertEqual('0,0,0,0,0,0,0,1');
      expect(Array.from(counterToBytes64(0)).join(','))
        .assertEqual('0,0,0,0,0,0,0,0');
      // 接近 2^53（JS 安全整数上限）
      expect(Array.from(counterToBytes64(9007199254740991)).join(','))
        .assertEqual('0,31,255,255,255,255,255,255');
    });
  });
}
