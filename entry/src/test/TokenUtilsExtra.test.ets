import { describe, it, expect } from '@ohos/hypium';
import {
  otpType, TokenConfig, convertToken2URI,
  stringToArray, stringToIntArray, intArrayToString, generateFileNameWithDate,
  TokenIconPacks, OTPDefaultIconPack
} from 'common';

/**
 * TokenUtils 其余纯函数补充测试(字节串编解码 / URI 生成 / 文件名 / 内置图标映射)。
 * base32Encode/base32Decode 已由 Base32.test.ets 以 RFC 4648 向量覆盖。
 */
export default function tokenUtilsExtraTest() {
  describe('tokenUtilsExtraTest', () => {
    it('stringToArray_utf8_multibyte', 0, () => {
      // 中文字节串不截断(历史修复点)
      let bytes = stringToArray('中文');
      expect(Array.from(bytes).join(',')).assertEqual('228,184,173,230,150,135');
      expect(Array.from(stringToArray('foo')).join(',')).assertEqual('102,111,111');
      expect(stringToArray('').length).assertEqual(0);
    });

    it('stringToIntArray_utf8_multibyte', 0, () => {
      let bytes = stringToIntArray('中文');
      expect(Array.from(bytes).join(',')).assertEqual('228,184,173,230,150,135');
    });

    it('intArrayToString_roundtrip_utf8', 0, () => {
      let ab = stringToArray('中文ABC').buffer as ArrayBuffer;
      expect(intArrayToString(ab)).assertEqual('中文ABC');
    });

    it('convertToken2uri_totp_fields', 0, () => {
      let conf = new TokenConfig();
      conf.TokenType = otpType.TOTP;
      conf.TokenIssuer = 'Example';
      conf.TokenName = 'alice';
      conf.TokenSecret = 'JBSWY3DPEHPK3PXP';
      conf.TokenPeriod = 30;
      conf.TokenDigits = 6;
      conf.TokenCounter = 0;
      expect(convertToken2URI(conf))
        .assertEqual('otpauth://totp/Example:alice?secret=JBSWY3DPEHPK3PXP&issuer=Example&digits=6&period=30');
    });

    it('convertToken2uri_hotp_uses_counter', 0, () => {
      let conf = new TokenConfig();
      conf.TokenType = otpType.HOTP;
      conf.TokenIssuer = 'Example';
      conf.TokenName = 'alice';
      conf.TokenSecret = 'ABCDEF';
      conf.TokenDigits = 6;
      conf.TokenCounter = 5;
      expect(convertToken2URI(conf))
        .assertEqual('otpauth://hotp/Example:alice?secret=ABCDEF&issuer=Example&digits=6&counter=5');
    });

    it('generateFileNameWithDate_format', 0, () => {
      let name = generateFileNameWithDate();
      expect(name.length).assertEqual(14);
      expect(/^\d+$/.test(name)).assertTrue();
    });

    it('default_icon_pack_matches_issuer', 0, () => {
      let pack = new OTPDefaultIconPack();
      expect(pack.getIconPathByIssuer('GitHub')).assertEqual('rawfile://icons/token_image_github.svg');
      // 空格归一为下划线后匹配 digital_ocean
      expect(pack.getIconPathByIssuer('Digital Ocean'))
        .assertEqual('rawfile://icons/token_image_digital_ocean.svg');
      expect(pack.getIconPathByIssuer('UnknownCorp')).assertEqual('');
    });

    it('picker_preview_path_mapping', 0, () => {
      expect(TokenIconPacks.getPickerPreviewPath('rawfile://icons/token_image_github.svg'))
        .assertEqual('rawfile://icon_thumbnails/token_image_github.png');
      // 大小写不敏感地识别内置 .svg 路径
      expect(TokenIconPacks.getPickerPreviewPath('rawfile://icons/x.SVG'))
        .assertEqual('rawfile://icon_thumbnails/x.png');
      // 非内置路径透传
      expect(TokenIconPacks.getPickerPreviewPath('file://docs/photo.png'))
        .assertEqual('file://docs/photo.png');
    });

    it('tokenconfig_defaults', 0, () => {
      let conf = new TokenConfig();
      expect(conf.TokenPeriod).assertEqual(30);
      expect(conf.TokenDigits).assertEqual(6);
      expect(conf.TokenCounter).assertEqual(0);
      expect(conf.TokenAlgorithm).assertEqual('SHA1');
      expect(conf.TokenType).assertEqual(otpType.TOTP);
      // 枚举显式赋值点:HOTP=2, NFC_external=4
      expect(otpType.HOTP).assertEqual(2);
      expect(otpType.NFC_external).assertEqual(4);
    });
  });
}
