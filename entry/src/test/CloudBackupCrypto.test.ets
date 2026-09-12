import { describe, it, expect } from '@ohos/hypium';
import { buffer } from '@kit.ArkTS';
import {
  BackupCryptoEngine,
  Base64Codec,
  CloudBackupCrypto,
  CloudBackupCryptoMode,
  CloudBackupTokenError,
  CloudBackupTokenHeader,
} from 'common';
import { sha256 } from '../main/ets/crypto/PureHash';
import { base64Decode, base64Encode, utf8ToBytes } from '../main/ets/steam/SteamCrypto';

/**
 * 云备份加密编排逻辑测试（注入纯 TS 引擎与编解码器，无 cryptoFramework/Base64Helper）。
 *
 * cryptoFramework 与 util.Base64Helper 在 LocalUnit 下都静默返回空数据，
 * 因此 AES/PBKDF2 数值正确性归 ohosTest 真机回归；这里用可逆 XOR 引擎覆盖
 * 三段式格式、签名校验、mock 旧格式兼容与错误分支。签名段用 PureHash 的真实 SHA-256。
 */

function bytesToHex(data: Uint8Array): string {
  let hex = '';
  for (let i = 0; i < data.length; i++) {
    hex += data[i].toString(16).padStart(2, '0');
  }
  return hex;
}

/** 纯 TS base64 编解码（SteamCrypto），绕开 LocalUnit 下静默失效的 util.Base64Helper */
class PureTsCodec implements Base64Codec {
  encodeText(text: string): string {
    return base64Encode(utf8ToBytes(text));
  }

  decodeText(base64Str: string): string {
    return buffer.from(base64Decode(base64Str)).toString('utf-8');
  }

  encodeBytes(data: Uint8Array): string {
    return base64Encode(data);
  }

  decodeBytes(base64Str: string): Uint8Array {
    return base64Decode(base64Str);
  }
}

class XorBackupEngine implements BackupCryptoEngine {
  round: number = 0;

  randomBytes(length: number): Uint8Array {
    // 确定性伪随机：每次调用递增轮次，保证两次加密的 salt/iv 不同且可复现
    const out = new Uint8Array(length);
    for (let i = 0; i < length; i++) {
      out[i] = (this.round * 37 + i * 13 + 5) & 0xff;
    }
    this.round++;
    return out;
  }

  async sha256Hex(data: string): Promise<string> {
    return bytesToHex(sha256(utf8ToBytes(data)));
  }

  async aesCbcEncrypt(plaintext: Uint8Array, password: string, salt: Uint8Array,
    iv: Uint8Array): Promise<Uint8Array> {
    return this.xor(plaintext, password, salt, iv);
  }

  async aesCbcDecrypt(ciphertext: Uint8Array, password: string, salt: Uint8Array,
    iv: Uint8Array): Promise<Uint8Array> {
    return this.xor(ciphertext, password, salt, iv);
  }

  /** 可逆 XOR：密钥流由 password+salt+iv 派生，错误密钥必然产生不同明文 */
  private xor(data: Uint8Array, password: string, salt: Uint8Array, iv: Uint8Array): Uint8Array {
    const material = utf8ToBytes(password + ':' + bytesToHex(salt) + bytesToHex(iv));
    const pad = sha256(material);
    const out = new Uint8Array(data.length);
    for (let i = 0; i < data.length; i++) {
      out[i] = data[i] ^ pad[i % pad.length];
    }
    return out;
  }
}

function b64(text: string): string {
  return base64Encode(utf8ToBytes(text));
}

/** 手工拼装三段式 token（用于 mock 旧格式与篡改用例） */
function buildToken(headerObj: CloudBackupTokenHeader, payloadText: string, signature: string): string {
  return b64(JSON.stringify(headerObj)) + '.' + b64(payloadText) + '.' + signature;
}

export default function cloudBackupCryptoTest() {
  describe('cloudBackupCryptoTest', () => {
    it('get_mode_follows_huawei_login_state', 0, () => {
      const crypto = CloudBackupCrypto.useEngineForTest(new XorBackupEngine(), new PureTsCodec());
      expect(crypto.getMode(true)).assertEqual(CloudBackupCryptoMode.HUAWEI_ACCOUNT);
      expect(crypto.getMode(false)).assertEqual(CloudBackupCryptoMode.NONE);
      expect(CloudBackupCryptoMode.HUAWEI_ACCOUNT).assertEqual(1);
      expect(CloudBackupCryptoMode.NONE).assertEqual(0);
    });

    it('encrypt_rejects_none_mode_with_code_3', 0, async () => {
      const crypto = CloudBackupCrypto.useEngineForTest(new XorBackupEngine(), new PureTsCodec());
      let threw = false;
      let code = 0;
      try {
        await crypto.encrypt('{}', CloudBackupCryptoMode.NONE, 'k', 0, 0, 'dev', 'name');
      } catch (e) {
        threw = true;
        code = (e as CloudBackupTokenError).code;
      }
      expect(threw).assertTrue();
      expect(code).assertEqual(3);
    });

    it('roundtrip_preserves_plaintext_and_header_metadata', 0, async () => {
      const crypto = CloudBackupCrypto.useEngineForTest(new XorBackupEngine(), new PureTsCodec());
      const plaintext = '{"tokens":[{"issuer":"GitHub","name":"alice"}]}';
      const token = await crypto.encrypt(plaintext, CloudBackupCryptoMode.HUAWEI_ACCOUNT, 'key-1',
        3, 1788953926000, 'odid-123', 'Mate 60');

      expect(token.split('.').length).assertEqual(3);
      expect(await crypto.decrypt(token, CloudBackupCryptoMode.HUAWEI_ACCOUNT, 'key-1'))
        .assertEqual(plaintext);

      const header = crypto.parseTokenHeader(token);
      expect(header.version).assertEqual(2);
      expect(header.mode).assertEqual(CloudBackupCryptoMode.HUAWEI_ACCOUNT);
      expect(header.tokenCount).assertEqual(3);
      expect(header.size).assertEqual(plaintext.length);
      expect(header.timestamp).assertEqual(1788953926000);
      expect(header.deviceId).assertEqual('odid-123');
      expect(header.deviceName).assertEqual('Mate 60');
      expect(header.salt.startsWith('mock_salt_')).assertFalse();
    });

    it('encrypt_is_non_deterministic_across_calls', 0, async () => {
      const crypto = CloudBackupCrypto.useEngineForTest(new XorBackupEngine(), new PureTsCodec());
      const first = await crypto.encrypt('same-plaintext', CloudBackupCryptoMode.HUAWEI_ACCOUNT,
        'k', 1, 1, 'd', 'n');
      const second = await crypto.encrypt('same-plaintext', CloudBackupCryptoMode.HUAWEI_ACCOUNT,
        'k', 1, 1, 'd', 'n');
      // salt/iv 每次重新生成：header 与密文段都必须不同（否则 salt/iv 可预测）
      expect(first.split('.')[0] !== second.split('.')[0]).assertTrue();
      expect(first.split('.')[1] !== second.split('.')[1]).assertTrue();
      // 两次的 salt 也要互不相同（engine.round 递增保证）
      const h1 = crypto.parseTokenHeader(first);
      const h2 = crypto.parseTokenHeader(second);
      expect(h1.salt === h2.salt).assertFalse();
      expect(h1.iv === h2.iv).assertFalse();
      // 错误密钥不会抛异常（XOR 引擎无填充校验），但明文必须是乱码而非原文
      const wrong = await crypto.decrypt(first, CloudBackupCryptoMode.HUAWEI_ACCOUNT, 'other-key');
      expect(wrong === 'same-plaintext').assertFalse();
    });

    it('decrypt_tampered_signature_fails_integrity_with_code_2', 0, async () => {
      const crypto = CloudBackupCrypto.useEngineForTest(new XorBackupEngine(), new PureTsCodec());
      const token = await crypto.encrypt('data', CloudBackupCryptoMode.HUAWEI_ACCOUNT, 'k',
        1, 1, 'd', 'n');
      const segments = token.split('.');
      const tampered = `${segments[0]}.${segments[1]}.${'0'.repeat(segments[2].length)}`;
      let threw = false;
      let code = 0;
      try {
        await crypto.decrypt(tampered, CloudBackupCryptoMode.HUAWEI_ACCOUNT, 'k');
      } catch (e) {
        threw = true;
        code = (e as CloudBackupTokenError).code;
      }
      expect(threw).assertTrue();
      expect(code).assertEqual(2);
    });

    it('decrypt_and_parse_reject_wrong_segment_count_with_code_1', 0, async () => {
      const crypto = CloudBackupCrypto.useEngineForTest(new XorBackupEngine(), new PureTsCodec());
      for (const bad of ['a.b', 'a.b.c.d']) {
        let threw = false;
        let code = 0;
        try {
          await crypto.decrypt(bad, CloudBackupCryptoMode.HUAWEI_ACCOUNT, 'k');
        } catch (e) {
          threw = true;
          code = (e as CloudBackupTokenError).code;
        }
        expect(threw).assertTrue();
        expect(code).assertEqual(1);

        let parseThrew = false;
        try {
          crypto.parseTokenHeader(bad);
        } catch (e) {
          parseThrew = true;
          code = (e as CloudBackupTokenError).code;
        }
        expect(parseThrew).assertTrue();
        expect(code).assertEqual(1);
      }
    });

    it('verify_token_checks_signature_without_decrypting', 0, async () => {
      const crypto = CloudBackupCrypto.useEngineForTest(new XorBackupEngine(), new PureTsCodec());
      const token = await crypto.encrypt('payload', CloudBackupCryptoMode.HUAWEI_ACCOUNT, 'k',
        1, 1, 'd', 'n');
      expect(await crypto.verifyToken(token)).assertTrue();

      const segments = token.split('.');
      const forged = `${segments[0]}.${segments[1]}.deadbeef`;
      expect(await crypto.verifyToken(forged)).assertFalse();
      expect(await crypto.verifyToken('only.two')).assertFalse();
    });

    it('mock_legacy_format_returns_plaintext_without_decrypting', 0, async () => {
      const engine = new XorBackupEngine();
      const crypto = CloudBackupCrypto.useEngineForTest(engine, new PureTsCodec());
      const legacyHeader: CloudBackupTokenHeader = {
        version: 1,
        mode: CloudBackupCryptoMode.NONE,
        salt: 'mock_salt_legacy',
        iv: b64('legacy-iv'),
        tokenCount: 2,
        size: 13,
        timestamp: 1700000000000,
        deviceId: 'old-device',
        deviceName: 'old-name',
      };
      const payloadText = '{"tokens":[1,2]}';
      const headerB64 = b64(JSON.stringify(legacyHeader));
      const payloadB64 = b64(payloadText);
      // mock 旧格式同样先过签名校验（decrypt 先验签后判 mock），再跳过 AES 直接返回明文
      const signature = await engine.sha256Hex(`${headerB64}.${payloadB64}`);
      const token = `${headerB64}.${payloadB64}.${signature}`;

      expect(crypto.isMockFormat(token)).assertTrue();
      expect(await crypto.decrypt(token, CloudBackupCryptoMode.HUAWEI_ACCOUNT, 'any-key'))
        .assertEqual(payloadText);
      expect(await crypto.verifyToken(token)).assertTrue();
    });

    it('is_mock_format_returns_false_for_invalid_or_normal_tokens', 0, async () => {
      const crypto = CloudBackupCrypto.useEngineForTest(new XorBackupEngine(), new PureTsCodec());
      expect(crypto.isMockFormat('not-a-token')).assertFalse();

      const normalHeader: CloudBackupTokenHeader = {
        version: 2,
        mode: CloudBackupCryptoMode.HUAWEI_ACCOUNT,
        salt: b64('0123456789abcdef'),
        iv: b64('0123456789abcdef'),
        tokenCount: 1,
        size: 4,
        timestamp: 0,
        deviceId: 'd',
        deviceName: 'n',
      };
      const token = buildToken(normalHeader, 'data', 'ff');
      expect(crypto.isMockFormat(token)).assertFalse();
      const header = crypto.parseTokenHeader(token);
      expect(header.salt.startsWith('mock_salt_')).assertFalse();
    });

    it('singleton_returns_same_instance', 0, () => {
      const a = CloudBackupCrypto.getInstance();
      const b = CloudBackupCrypto.getInstance();
      expect(a === b).assertTrue();
    });
  });
}
