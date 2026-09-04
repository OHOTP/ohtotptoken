import { describe, it, expect } from '@ohos/hypium';
import { otpType, TokenConfig, MAGIC_TWOFA, TwoFAParseStatus, parseTwoFABackup } from 'common';

/**
 * TwoFAImporter 备份映射纯函数单元测试,对齐 openspec 变更
 * add-core-unit-tests 的 specs/twofa-backup-parsing 行为契约。
 * 输入为已解码的 JSON 字符串(Base32/UTF-8 外壳依赖系统能力,留在 import 链路)。
 */
function backupJson(tokens: string, tokensEncrypted: string = ''): string {
  return `{"magic": ${MAGIC_TWOFA}, "tokens": ${tokens}, "groups": [],` +
    ` "appVersionCode": 1, "appVersionName": "1.0", "appOrigin": "",` +
    ` "tokensEncrypted": "${tokensEncrypted}", "reference": "", "updatedAt": 0}`;
}

const VALID_TOKEN = '{"id":"1","span":30,"rank":0,"groupId":"","createdAt":0,"updatedAt":0,' +
  '"type":0,"issuer":"GitHub","label":"alice","secret":"JBSWY3DPEHPK3PXP","algorithm":"SHA1","digits":6}';

export default function twoFaBackupTest() {
  describe('twoFaBackupTest', () => {
    it('valid_backup_maps_all_fields', 0, () => {
      let r = parseTwoFABackup(backupJson(`[${VALID_TOKEN}]`));
      expect(r.status).assertEqual(TwoFAParseStatus.OK);
      expect(r.tokens.length).assertEqual(1);
      let t: TokenConfig = r.tokens[0];
      expect(t.TokenSecret).assertEqual('JBSWY3DPEHPK3PXP');
      expect(t.TokenIssuer).assertEqual('GitHub');
      expect(t.TokenName).assertEqual('alice');
      expect(t.TokenType).assertEqual(otpType.TOTP);
      expect(t.TokenAlgorithm).assertEqual('SHA1');
      expect(t.TokenDigits).assertEqual(6);
      expect(t.TokenPeriod).assertEqual(30);
    });

    it('bad_magic_rejected', 0, () => {
      let bad = backupJson(`[${VALID_TOKEN}]`).replace(`${MAGIC_TWOFA}`, '12345');
      expect(parseTwoFABackup(bad).status).assertEqual(TwoFAParseStatus.INVALID_FORMAT);
    });

    it('malformed_json_rejected', 0, () => {
      expect(parseTwoFABackup('not-a-json').status).assertEqual(TwoFAParseStatus.INVALID_FORMAT);
    });

    it('encrypted_backup_rejected', 0, () => {
      let r = parseTwoFABackup(backupJson('[]', 'encrypted-blob'));
      expect(r.status).assertEqual(TwoFAParseStatus.ENCRYPTED);
    });

    it('empty_tokens_reported_empty', 0, () => {
      expect(parseTwoFABackup(backupJson('[]')).status).assertEqual(TwoFAParseStatus.EMPTY);
    });

    it('algorithm_normalized_and_fallback', 0, () => {
      expect(parseTwoFABackup(backupJson(
        `[{"id":"1","span":30,"rank":0,"groupId":"","createdAt":0,"updatedAt":0,` +
        `"type":0,"issuer":"A","label":"a","secret":"ABCDEF","algorithm":"sha256","digits":6}]`
      )).tokens[0].TokenAlgorithm).assertEqual('SHA256');
      // 不在支持集合 → 回退 SHA1
      expect(parseTwoFABackup(backupJson(
        `[{"id":"1","span":30,"rank":0,"groupId":"","createdAt":0,"updatedAt":0,` +
        `"type":0,"issuer":"A","label":"a","secret":"ABCDEF","algorithm":"sha3","digits":6}]`
      )).tokens[0].TokenAlgorithm).assertEqual('SHA1');
    });

    it('digits_and_period_fallback', 0, () => {
      let r = parseTwoFABackup(backupJson(
        `[{"id":"1","span":0,"rank":0,"groupId":"","createdAt":0,"updatedAt":0,` +
        `"type":0,"issuer":"A","label":"a","secret":"ABCDEF","algorithm":"SHA1","digits":0}]`
      ));
      expect(r.tokens[0].TokenDigits).assertEqual(6);
      expect(r.tokens[0].TokenPeriod).assertEqual(30);
    });

    it('type_mapping_totp_hotp', 0, () => {
      let mk = (type: number): string =>
        `{"id":"1","span":30,"rank":0,"groupId":"","createdAt":0,"updatedAt":0,` +
        `"type":${type},"issuer":"A","label":"a","secret":"ABCDEF","algorithm":"SHA1","digits":6}`;
      let r = parseTwoFABackup(backupJson(`[${mk(0)}, ${mk(1)}]`));
      expect(r.tokens[0].TokenType).assertEqual(otpType.TOTP);
      expect(r.tokens[1].TokenType).assertEqual(otpType.HOTP);
    });

    it('null_secret_entries_filtered', 0, () => {
      let r = parseTwoFABackup(backupJson(
        `[${VALID_TOKEN},` +
        ` {"id":"2","span":30,"rank":0,"groupId":"","createdAt":0,"updatedAt":0,` +
        `"type":0,"issuer":"B","label":"b","secret":null,"algorithm":"SHA1","digits":6},` +
        ` ${VALID_TOKEN}]`
      ));
      expect(r.status).assertEqual(TwoFAParseStatus.OK);
      expect(r.tokens.length).assertEqual(2);
    });
  });
}
