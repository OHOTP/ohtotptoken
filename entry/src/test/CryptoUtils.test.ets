import { describe, it, expect } from '@ohos/hypium';
import {
  decryptBlePayload,
  decryptFile,
  decryptStringData,
  decryptUint8ArrayData,
  encryptBlePayload,
  encryptFile,
  encryptStringData,
  encryptUint8ArrayData,
  randomBytes,
  resetCryptoEngineForTest,
  useCryptoEngineForTest,
} from 'common';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { FakeCryptoEngine } from './fakes/BackupFakes';

/**
 * CryptoUtils 格式/协议层测试（Phase 2 CryptoEngine 端口注入）。
 *
 * 覆盖：V2 文件格式帧（MAGIC+salt+iv）、V0 legacy 派生参数、
 * MAGIC_U8 对称帧、BLE GCM 帧与防篡改失败路径。
 * AES/PBKDF2/GCM 数值正确性由生产引擎在真机 ohosTest 保证。
 */

const FILE_MAGIC: number[] = [0x4F, 0x54, 0x50, 0x02];
const U8_MAGIC: number[] = [0x4F, 0x54, 0x50, 0x03];
const BLE_MAGIC: number[] = [0x4F, 0x54, 0x50, 0x05];
const LEGACY_IV_STR = 'ohtotptokenaesiv';

/** 每个用例重新绑定干净假引擎，并清除模块级缓存（引擎单例 + BLE 派生密钥） */
function freshEngine(): FakeCryptoEngine {
  resetCryptoEngineForTest();
  const engine = new FakeCryptoEngine();
  useCryptoEngineForTest(engine);
  return engine;
}

function bytesToNumbers(data: Uint8Array): number[] {
  const out: number[] = [];
  for (let i = 0; i < data.length; i++) {
    out.push(data[i]);
  }
  return out;
}

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      return false;
    }
  }
  return true;
}

export default function cryptoUtilsTest() {
  describe('cryptoUtilsTest', () => {
    it('encryptFile_builds_v2_framing_and_roundtrips', 0, async () => {
      const engine = freshEngine();
      const plain = '{"configs":["hello world"]}';
      // 契约：随机源确定性（同种子同输出），不绑定引擎内部伪随机公式
      engine.randomSeed = 42;
      const encrypted = await encryptFile(plain, 'pass-123');
      engine.randomSeed = 42;
      const again = await encryptFile(plain, 'pass-123');
      expect(bytesEqual(encrypted, again)).assertTrue();

      // MAGIC(4) + salt(16) + iv(16) + ciphertext
      const numbers = bytesToNumbers(encrypted);
      expect(numbers.length).assertEqual(36 + engine.utf8Encode(plain).length);
      for (let i = 0; i < 4; i++) {
        expect(numbers[i]).assertEqual(FILE_MAGIC[i]);
      }
      // salt 与 iv 均来自引擎随机源（非零且互不相同）
      let saltZero = true;
      for (let i = 4; i < 20; i++) {
        if (numbers[i] !== 0) {
          saltZero = false;
        }
      }
      expect(saltZero).assertFalse();
      let saltEqualsIv = true;
      for (let i = 0; i < 16; i++) {
        if (numbers[4 + i] !== numbers[20 + i]) {
          saltEqualsIv = false;
        }
      }
      expect(saltEqualsIv).assertFalse();

      const decrypted = await decryptFile(encrypted, 'pass-123');
      expect(decrypted).assertEqual(plain);
      // 密钥变化 → 同明文不同密文
      const otherKey = await encryptFile(plain, 'pass-456');
      expect(bytesEqual(encrypted, otherKey)).assertFalse();
    });

    it('decryptFile_v2_uses_pbkdf2_600k_iterations_with_file_salt', 0, async () => {
      const engine = freshEngine();
      const encrypted = await encryptFile('data', 'key1');
      engine.lastPbkdf2Iterations = -1;
      engine.lastPbkdf2Password = '';

      await decryptFile(encrypted, 'key1');
      expect(engine.lastPbkdf2Password).assertEqual('key1');
      expect(engine.lastPbkdf2Iterations).assertEqual(600000);
      expect(engine.lastPbkdf2KeySize).assertEqual(16);
      // salt 取自文件头 [4..20)
      expect(engine.lastPbkdf2Salt.length).assertEqual(16);
      expect(engine.lastPbkdf2Salt[0]).assertEqual(encrypted[4]);
    });

    it('decryptFile_legacy_path_uses_zero_salt_and_fixed_iv', 0, async () => {
      const engine = freshEngine();
      // 构造 V0 数据：任意非 MAGIC 前缀的"密文"（假引擎 XOR 可逆）
      const keyBytes = await engine.pbkdf2Derive('legacy_key', new Uint8Array(16), 10000, 16);
      const legacyIv = engine.utf8Encode(LEGACY_IV_STR);
      const plainBytes = engine.utf8Encode('legacy secret text');
      const cipher = await engine.aesCbcEncrypt(plainBytes, keyBytes, legacyIv);

      const decrypted = await decryptFile(cipher, 'legacy_key');
      expect(decrypted).assertEqual('legacy secret text');
      // legacy 派生参数：零盐 + 10000 轮
      expect(engine.lastPbkdf2Iterations).assertEqual(10000);
      let saltAllZero = engine.lastPbkdf2Salt.length === 16;
      for (let i = 0; i < engine.lastPbkdf2Salt.length; i++) {
        if (engine.lastPbkdf2Salt[i] !== 0) {
          saltAllZero = false;
        }
      }
      expect(saltAllZero).assertTrue();
      // 解密使用硬编码 legacy IV
      expect(bytesEqual(engine.lastCbcDecryptIv, legacyIv)).assertTrue();
    });

    it('encryptUint8ArrayData_framing_and_roundtrip', 0, async () => {
      const engine = freshEngine();
      const keyBlob: cryptoFramework.DataBlob = { data: engine.utf8Encode('sym-key-bytes!!!!') };
      const plain = engine.utf8Encode('binary payload');
      const encrypted = await encryptUint8ArrayData(plain, keyBlob);

      const numbers = bytesToNumbers(encrypted);
      expect(numbers.length).assertEqual(20 + plain.length);
      for (let i = 0; i < 4; i++) {
        expect(numbers[i]).assertEqual(U8_MAGIC[i]);
      }

      const decrypted = await decryptUint8ArrayData(encrypted, keyBlob);
      expect(decrypted !== null).assertTrue();
      expect(bytesEqual(decrypted!, plain)).assertTrue();
    });

    it('decryptUint8ArrayData_legacy_fallback_uses_hardcoded_iv', 0, async () => {
      const engine = freshEngine();
      const keyBlob: cryptoFramework.DataBlob = { data: engine.utf8Encode('sym-key-bytes!!!!') };
      const legacyIv = engine.utf8Encode(LEGACY_IV_STR);
      const plain = engine.utf8Encode('old data');
      const cipher = await engine.aesCbcEncrypt(plain, new Uint8Array(keyBlob.data), legacyIv);

      const decrypted = await decryptUint8ArrayData(cipher, keyBlob);
      expect(decrypted !== null).assertTrue();
      expect(bytesEqual(decrypted!, plain)).assertTrue();
      expect(bytesEqual(engine.lastCbcDecryptIv, legacyIv)).assertTrue();
    });

    it('decryptUint8ArrayData_returns_null_on_decrypt_error', 0, async () => {
      const engine = freshEngine();
      const keyBlob: cryptoFramework.DataBlob = { data: engine.utf8Encode('sym-key-bytes!!!!') };
      const encrypted = await encryptUint8ArrayData(engine.utf8Encode('x'), keyBlob);
      engine.failNextCbcDecrypt = true;
      const result = await decryptUint8ArrayData(encrypted, keyBlob);
      expect(result).assertNull();
    });

    it('encryptStringData_roundtrip_utf8_and_null_on_failure', 0, async () => {
      const engine = freshEngine();
      const keyBlob: cryptoFramework.DataBlob = { data: engine.utf8Encode('another-sym-key!') };
      const text = 'issuer:GitHub,name=octocat';
      const encrypted = await encryptStringData(text, keyBlob);
      const decrypted = await decryptStringData(encrypted, keyBlob);
      expect(decrypted !== null).assertTrue();
      expect(decrypted!).assertEqual(text);

      // 解密失败（如填充错误）→ null
      engine.failNextCbcDecrypt = true;
      const failed = await decryptStringData(encrypted, keyBlob);
      expect(failed).assertNull();
    });

    it('randomBytes_delegates_to_engine', 0, async () => {
      const engine = freshEngine();
      // 同一种子下两次采样一致，证明 randomBytes 委托当前注入引擎
      engine.randomSeed = 12345;
      const actual = randomBytes(8);
      engine.randomSeed = 12345;
      const expected = engine.randomBytes(8);
      expect(bytesEqual(actual, expected)).assertTrue();
    });

    it('encryptBlePayload_framing_iv_and_tag_layout', 0, async () => {
      const engine = freshEngine();
      const plain = engine.utf8Encode('ble frame body');
      const payload = await encryptBlePayload(plain);

      const numbers = bytesToNumbers(payload);
      // MAGIC(4) + iv(12) + tag(16) + ciphertext
      expect(numbers.length).assertEqual(32 + plain.length);
      for (let i = 0; i < 4; i++) {
        expect(numbers[i]).assertEqual(BLE_MAGIC[i]);
      }
      // tag 区 16 字节且非全零（真实 tag 来自引擎 seal）
      let tagAllZero = true;
      for (let i = 16; i < 32; i++) {
        if (numbers[i] !== 0) {
          tagAllZero = false;
        }
      }
      expect(tagAllZero).assertFalse();

      const decrypted = await decryptBlePayload(payload);
      expect(decrypted !== null).assertTrue();
      expect(bytesEqual(decrypted!, plain)).assertTrue();
    });

    it('decryptBlePayload_rejects_short_wrong_magic_and_tampered', 0, async () => {
      freshEngine();
      expect(await decryptBlePayload(new Uint8Array(10))).assertNull();

      const wrongMagic = new Uint8Array(40);
      wrongMagic[0] = 0x00;
      expect(await decryptBlePayload(wrongMagic)).assertNull();

      // tag 校验失败（GCM open 抛错）→ null，调用方必须丢弃
      const engine = freshEngine();
      const payload = await encryptBlePayload(engine.utf8Encode('body'));
      engine.failGcmOpen = true;
      expect(await decryptBlePayload(payload)).assertNull();
    });
  });
}
