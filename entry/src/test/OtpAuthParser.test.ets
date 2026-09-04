import { describe, it, expect } from '@ohos/hypium';
import { otpType, TokenConfig, parseOtpAuthUris } from 'common';

/**
 * OtpAuthParser 单元测试,对齐 openspec 变更 add-core-unit-tests 的
 * specs/otpauth-uri-parsing 行为契约。
 */
function firstToken(uris: string[]): TokenConfig {
  const tokens = parseOtpAuthUris(uris);
  expect(tokens.length).assertEqual(1);
  return tokens[0];
}

export default function otpAuthParserTest() {
  describe('otpAuthParserTest', () => {
    it('standard_totp_uri', 0, () => {
      let t = firstToken(['otpauth://totp/Example:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example']);
      expect(t.TokenType).assertEqual(otpType.TOTP);
      // 现状固化:query 整体小写化,secret 以小写形式存入(解码时大小写不敏感)
      expect(t.TokenSecret).assertEqual('jbswy3dpehpk3pxp');
      expect(t.TokenIssuer).assertEqual('Example');
      expect(t.TokenName).assertEqual('alice@example.com');
    });

    it('default_period_digits_counter', 0, () => {
      let t = firstToken(['otpauth://totp/Demo:x?secret=JBSWY3DPEHPK3PXP']);
      expect(t.TokenPeriod).assertEqual(30);
      expect(t.TokenDigits).assertEqual(6);
      expect(t.TokenCounter).assertEqual(0);
    });

    it('hotp_with_counter', 0, () => {
      let t = firstToken(['otpauth://hotp/Demo:x?secret=ABCDEF&counter=5']);
      expect(t.TokenType).assertEqual(otpType.HOTP);
      expect(t.TokenCounter).assertEqual(5);
    });

    it('batch_isolates_invalid_entries', 0, () => {
      let tokens = parseOtpAuthUris([
        'otpauth://totp/Good:a?secret=JBSWY3DPEHPK3PXP',
        'https://example.com/not/otp',
        'otpauth://totp/MissingSecret:x',
        'otpauth://unknown/Type:x?secret=ABCDEF'
      ]);
      expect(tokens.length).assertEqual(1);
      expect(tokens[0].TokenIssuer).assertEqual('Good');
    });

    it('steam_issuer_maps_to_steam_type', 0, () => {
      let t = firstToken(['otpauth://totp/Steam:user?secret=JBSWY3DPEHPK3PXP&issuer=Steam']);
      expect(t.TokenType).assertEqual(otpType.Steam);
      expect(t.TokenAlgorithm).assertEqual('SHA1');
      expect(t.TokenPeriod).assertEqual(30);
      expect(t.TokenDigits).assertEqual(10);
    });

    it('secret_is_case_insensitive', 0, () => {
      // query 整体小写化后 secret 变小写;解码应与原大写形式一致
      let lower = firstToken(['otpauth://totp/Demo:x?secret=jbswy3dpehpk3pxp']);
      expect(Array.from(base32Bytes('JBSWY3DPEHPK3PXP')).join(','))
        .assertEqual(Array.from(base32Bytes(lower.TokenSecret)).join(','));
    });

    it('issuer_falls_back_to_label_prefix', 0, () => {
      // 无 issuer 参数时 issuer 取 label 冒号前缀
      let t = firstToken(['otpauth://totp/MyCorp:bob?secret=JBSWY3DPEHPK3PXP']);
      expect(t.TokenIssuer).assertEqual('MyCorp');
      expect(t.TokenName).assertEqual('bob');
    });

    it('label_without_colon_has_no_name', 0, () => {
      // 现状固化:label 无冒号时 TokenName 为 undefined
      let t = firstToken(['otpauth://totp/plainname?secret=JBSWY3DPEHPK3PXP']);
      expect(t.TokenIssuer).assertEqual('plainname');
      expect(t.TokenName === undefined).assertTrue();
    });

    it('percent_encoded_label_decoded', 0, () => {
      let t = firstToken(['otpauth://totp/My%20Corp:bob?secret=JBSWY3DPEHPK3PXP']);
      expect(t.TokenIssuer).assertEqual('My Corp');
    });

    it('empty_input_yields_empty_result', 0, () => {
      expect(parseOtpAuthUris([]).length).assertEqual(0);
    });
  });
}

// 仅用于 secret 大小写一致性比较(不经被测函数)
function base32Bytes(secret: string): Uint8Array {
  const ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  const cleaned = secret.toUpperCase().replace(/=+$/, '');
  const bytes: number[] = [];
  let buffer = 0;
  let bits = 0;
  for (let i = 0; i < cleaned.length; i++) {
    const v = ALPHABET.indexOf(cleaned.charAt(i));
    if (v < 0) {
      continue;
    }
    buffer = (buffer << 5) | v;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      bytes.push((buffer >> bits) & 0xFF);
    }
  }
  return new Uint8Array(bytes);
}
