import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { buffer, util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CryptoEngine, CryptoSealedBytes } from './StoragePorts';

// ---- version markers for new ciphertext format ----
// New encryptFile  : [MAGIC(4)] [salt:16] [iv:16] [ciphertext]
// New encryptUint8 : [MAGIC_U8(4)] [iv:16] [ciphertext]
// Old format (V0)  : raw AES-128-CBC ciphertext (no header)
const MAGIC = new Uint8Array([0x4F, 0x54, 0x50, 0x02]); // "OTP\x02"
const MAGIC_U8 = new Uint8Array([0x4F, 0x54, 0x50, 0x03]); // "OTP\x03"
const HEADER_SIZE = 4 + 16 + 16; // MAGIC + salt + iv = 36
const HEADER_U8_SIZE = 4 + 16;   // MAGIC_U8 + iv = 20
const SALT_OFS = 4;
const IV_OFS = 4 + 16;

const PBKDF2_ITERATIONS = 600000;
const PBKDF2_KEY_SIZE = 16;
// legacy helpers (used only for V0 decryption)
const LEGACY_IV_STR = 'ohtotptokenaesiv';
const LEGACY_SALT = new Uint8Array(16); // zero salt
const LEGACY_PBKDF2_ITERATIONS = 10000;

function startsWith(data: Uint8Array, prefix: Uint8Array): boolean {
  if (data.length < prefix.length) return false;
  for (let i = 0; i < prefix.length; i++) {
    if (data[i] !== prefix[i]) return false;
  }
  return true;
}

/**
 * 密码学安全随机字节。
 *
 * 云备份等场景必须用本函数，**不要**用 `Math.random()`
 * （`CloudBackupCrypto.generateRandomBytes` 曾是后者，salt/iv 可被预测）。
 */
export function randomBytes(length: number): Uint8Array {
  return getEngine().randomBytes(length);
}

/**
 * 密码学引擎端口（见 StoragePorts.CryptoEngine）。
 * LocalUnit 下 cryptoFramework 静默失效，格式层用例经 useCryptoEngineForTest 注入
 * 确定性假引擎；AES/PBKDF2/GCM 数值正确性由生产实现 + 真机 ohosTest 保证。
 * 延迟构造：避免模块加载期引用声明在后的类。
 */
let engine: CryptoEngine | undefined = undefined;

const TAG = 'CryptoUtils';

/**
 * 测试注入：替换全局密码学引擎。
 * 信任模型与 CloudBackupCrypto.useEngineForTest 一致——生产代码不得调用；
 * 调用会留下 hilog.warn 审计痕迹（LocalUnit 下为空操作）。
 */
export function useCryptoEngineForTest(custom: CryptoEngine): void {
  hilog.warn(0xFF00, TAG, 'useCryptoEngineForTest called (test-only entry point)');
  engine = custom;
}

/** 测试复位：恢复生产引擎并清除 BLE 派生密钥缓存（供套件间隔离）。 */
export function resetCryptoEngineForTest(): void {
  engine = undefined;
  bleTransportKey = undefined;
}

function getEngine(): CryptoEngine {
  let current = engine;
  if (current === undefined) {
    current = new CryptoFrameworkCryptoEngine();
    engine = current;
  }
  return current;
}

/** cryptoFramework 生产实现（LocalUnit 不会执行到）。 */
export class CryptoFrameworkCryptoEngine implements CryptoEngine {
  randomBytes(length: number): Uint8Array {
    return new Uint8Array(cryptoFramework.createRandom().generateRandomSync(length).data);
  }

  utf8Encode(text: string): Uint8Array {
    return new Uint8Array(buffer.from(text, 'utf-8').buffer);
  }

  utf8Decode(data: Uint8Array): string {
    const decoder = new util.TextDecoder();
    return decoder.decodeToString(data);
  }

  async pbkdf2Derive(password: string, salt: Uint8Array, iterations: number, keySize: number): Promise<Uint8Array> {
    let spec: cryptoFramework.PBKDF2Spec = {
      algName: 'PBKDF2',
      password: password,
      salt: salt,
      iterations: iterations,
      keySize: keySize
    };
    let kdf = cryptoFramework.createKdf('PBKDF2|SHA256');
    let symKeyBlob = await kdf.generateSecret(spec);
    let aesGenerator = cryptoFramework.createSymKeyGenerator('AES128');
    let symKey = aesGenerator.convertKeySync(symKeyBlob);
    return new Uint8Array(symKey.getEncoded().data);
  }

  async sha256(data: Uint8Array): Promise<Uint8Array> {
    let md = cryptoFramework.createMd('SHA256');
    await md.update({ data: data });
    return new Uint8Array((await md.digest()).data);
  }

  private async cbcCipher(mode: cryptoFramework.CryptoMode, key: Uint8Array, iv: Uint8Array):
    Promise<cryptoFramework.Cipher> {
    let aesKeyGen = cryptoFramework.createSymKeyGenerator('AES128');
    let aesKey = aesKeyGen.convertKeySync({ data: key });
    let aesCipher = cryptoFramework.createCipher('AES128|CBC|PKCS7');
    let aesIv: cryptoFramework.IvParamsSpec = { algName: "IvParamsSpec", iv: { data: iv } };
    await aesCipher.init(mode, aesKey, aesIv);
    return aesCipher;
  }

  async aesCbcEncrypt(plain: Uint8Array, key: Uint8Array, iv: Uint8Array): Promise<Uint8Array> {
    const cipher = await this.cbcCipher(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, iv);
    return new Uint8Array((await cipher.doFinal({ data: plain })).data);
  }

  async aesCbcDecrypt(cipherData: Uint8Array, key: Uint8Array, iv: Uint8Array): Promise<Uint8Array> {
    const cipher = await this.cbcCipher(cryptoFramework.CryptoMode.DECRYPT_MODE, key, iv);
    return new Uint8Array((await cipher.doFinal({ data: cipherData })).data);
  }

  async aesGcmSeal(plain: Uint8Array, key: Uint8Array, iv: Uint8Array, aad: Uint8Array): Promise<CryptoSealedBytes> {
    let gcmParams: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: { data: iv },
      aad: { data: aad },
      authTag: { data: new Uint8Array(BLE_TAG_LEN) }
    };
    let cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, await this.aes256Key(key), gcmParams);
    // 官方指南行为: update(明文) 返回 ciphertext, doFinal(null) 返回 authTag
    let enc: cryptoFramework.DataBlob = cipher.updateSync({ data: plain });
    let tagData: cryptoFramework.DataBlob = cipher.doFinalSync(null);
    let sealed = new CryptoSealedBytes();
    sealed.ciphertext = new Uint8Array(enc.data);
    // 双保险: 优先取 doFinal(null) 返回的完整 tag, 否则取副作用写入的 gcmParams.authTag
    sealed.tag = tagData.data.length === BLE_TAG_LEN ? tagData.data : gcmParams.authTag.data;
    return sealed;
  }

  async aesGcmOpen(cipherData: Uint8Array, key: Uint8Array, iv: Uint8Array, aad: Uint8Array,
    tag: Uint8Array): Promise<Uint8Array> {
    let gcmParams: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: { data: iv },
      aad: { data: aad },
      authTag: { data: tag }
    };
    let cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, await this.aes256Key(key), gcmParams);
    let dec = cipher.doFinalSync({ data: cipherData });
    return new Uint8Array(dec.data);
  }

  private async aes256Key(keyBytes: Uint8Array): Promise<cryptoFramework.SymKey> {
    let keyGen = cryptoFramework.createSymKeyGenerator('AES256');
    return keyGen.convertKeySync({ data: keyBytes });
  }
}

export async function decryptFile(file_buf: Uint8Array, user_key: string): Promise<string> {
  if (file_buf.length >= HEADER_SIZE && startsWith(file_buf, MAGIC)) {
    // ---- V2 (new format): MAGIC + salt:16 + iv:16 + ciphertext ----
    let salt = file_buf.slice(SALT_OFS, SALT_OFS + 16);
    let iv = file_buf.slice(IV_OFS, IV_OFS + 16);
    let cipherData = file_buf.slice(HEADER_SIZE);
    let keyBytes = await getEngine().pbkdf2Derive(user_key, salt, PBKDF2_ITERATIONS, PBKDF2_KEY_SIZE);
    let plain = await getEngine().aesCbcDecrypt(cipherData, keyBytes, iv);
    return getEngine().utf8Decode(plain);
  }
  // ---- V0 (legacy): raw ciphertext, hardcoded IV, zero salt ----
  let keyBytes = await getEngine().pbkdf2Derive(user_key, LEGACY_SALT, LEGACY_PBKDF2_ITERATIONS, PBKDF2_KEY_SIZE);
  let plain = await getEngine().aesCbcDecrypt(file_buf, keyBytes, getEngine().utf8Encode(LEGACY_IV_STR));
  return getEngine().utf8Decode(plain);
}

export async function encryptFile(file_str: string, user_key: string): Promise<Uint8Array> {
  let salt = getEngine().randomBytes(16);
  let iv = getEngine().randomBytes(16);
  let keyBytes = await getEngine().pbkdf2Derive(user_key, salt, PBKDF2_ITERATIONS, PBKDF2_KEY_SIZE);
  let ciphertext = await getEngine().aesCbcEncrypt(getEngine().utf8Encode(file_str), keyBytes, iv);
  // Build V2 output: MAGIC(4) + salt(16) + iv(16) + ciphertext
  let output = new Uint8Array(HEADER_SIZE + ciphertext.length);
  output.set(MAGIC, 0);
  output.set(salt, SALT_OFS);
  output.set(iv, IV_OFS);
  output.set(ciphertext, HEADER_SIZE);
  return output;
}

export async function encryptUint8ArrayData(data: Uint8Array, symKeyBlob: cryptoFramework.DataBlob): Promise<Uint8Array> {
  let iv = getEngine().randomBytes(16);
  let ciphertext = await getEngine().aesCbcEncrypt(data, new Uint8Array(symKeyBlob.data), iv);
  // Build V2 output: MAGIC_U8(4) + iv(16) + ciphertext
  let output = new Uint8Array(HEADER_U8_SIZE + ciphertext.length);
  output.set(MAGIC_U8, 0);
  output.set(iv, 4);
  output.set(ciphertext, HEADER_U8_SIZE);
  return output;
}

export async function decryptUint8ArrayData(data: Uint8Array, symKeyBlob: cryptoFramework.DataBlob): Promise<Uint8Array | null> {
  try {
    let iv: Uint8Array;
    let cipherData: Uint8Array;

    if (data.length >= HEADER_U8_SIZE && startsWith(data, MAGIC_U8)) {
      iv = data.slice(4, 4 + 16);
      cipherData = data.slice(HEADER_U8_SIZE);
    } else {
      // Legacy: use hardcoded IV
      iv = getEngine().utf8Encode(LEGACY_IV_STR);
      cipherData = data;
    }

    return await getEngine().aesCbcDecrypt(cipherData, new Uint8Array(symKeyBlob.data), iv);
  } catch (_e) {
    return null;
  }
}

/**
 * AES128 CBC 加密字符串 返回加密后的字节数组
 *
 */
export async function encryptStringData(data: string, symKeyBlob: cryptoFramework.DataBlob): Promise<Uint8Array> {
  return await encryptUint8ArrayData(getEngine().utf8Encode(data), symKeyBlob);
}

export async function decryptStringData(data: Uint8Array, symKeyBlob: cryptoFramework.DataBlob): Promise<string | null> {
  try {
    let decryptData = await decryptUint8ArrayData(data, symKeyBlob);
    if (decryptData === null) {
      return null;
    }
    return getEngine().utf8Decode(decryptData);
  } catch (err) {
    return null;
  }
}

// ---- BLE 传输加密 (AES-256-GCM) ----
// 载荷格式: [BLE_MAGIC(4)] [iv(12)] [authTag(16)] [ciphertext]
//
// 安全模型(与"系统 BLE 配对 + 应用层纵深防御"决策一致):
// - 主防线: 系统 BLE 配对(LE Secure Connections), 链路层由系统 LTK 加密
// - 本层: 常量派生密钥的 AES-256-GCM, 防止链路被降级/未加密时被动嗅探与内容篡改(tag 校验)
// - 局限: 常量可从任一安装包提取, 不防逆向分析者, 仅作纵深防御, 不承担认证职责
const BLE_MAGIC = new Uint8Array([0x4F, 0x54, 0x50, 0x05]); // "OTP\x05"
const BLE_IV_LEN = 12;
const BLE_TAG_LEN = 16;
const BLE_HEADER_SIZE = 4 + BLE_IV_LEN + BLE_TAG_LEN; // MAGIC + iv + authTag = 32
const BLE_AAD = new Uint8Array(buffer.from('ohtotptoken-ble-aad-v1').buffer);
const BLE_KEY_CONST = 'ohtotptoken-ble-transport-v1';

let bleTransportKey: Uint8Array | undefined = undefined;

async function getBleTransportKey(): Promise<Uint8Array> {
  if (bleTransportKey === undefined) {
    bleTransportKey = await getEngine().sha256(getEngine().utf8Encode(BLE_KEY_CONST));
  }
  return bleTransportKey;
}

/**
 * 加密 BLE 传输载荷(手机端).
 */
export async function encryptBlePayload(plain: Uint8Array): Promise<Uint8Array> {
  let iv = getEngine().randomBytes(BLE_IV_LEN);
  let key = await getBleTransportKey();
  let sealed = await getEngine().aesGcmSeal(plain, key, iv, BLE_AAD);
  let out = new Uint8Array(BLE_HEADER_SIZE + sealed.ciphertext.length);
  out.set(BLE_MAGIC, 0);
  out.set(iv, 4);
  out.set(sealed.tag, 4 + BLE_IV_LEN);
  out.set(sealed.ciphertext, BLE_HEADER_SIZE);
  return out;
}

/**
 * 解密 BLE 传输载荷(手表端). 任何失败(MAGIC 不符/长度不符/tag 校验失败)返回 null,
 * 调用方应视为"数据被篡改或密钥版本不匹配"而丢弃, 不得入库.
 */
export async function decryptBlePayload(data: Uint8Array): Promise<Uint8Array | null> {
  try {
    if (data.length < BLE_HEADER_SIZE || !startsWith(data, BLE_MAGIC)) {
      return null;
    }
    let iv = data.slice(4, 4 + BLE_IV_LEN);
    let tag = data.slice(4 + BLE_IV_LEN, BLE_HEADER_SIZE);
    let ciphertext = data.slice(BLE_HEADER_SIZE);
    let key = await getBleTransportKey();
    return await getEngine().aesGcmOpen(ciphertext, key, iv, BLE_AAD, tag);
  } catch (e) {
    return null;
  }
}
