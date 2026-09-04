import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { buffer, util } from '@kit.ArkTS';

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

function startsWith(data: Uint8Array, prefix: Uint8Array): boolean {
  if (data.length < prefix.length) return false;
  for (let i = 0; i < prefix.length; i++) {
    if (data[i] !== prefix[i]) return false;
  }
  return true;
}

function randomBytes(length: number): Uint8Array {
  const result = cryptoFramework.createRandom().generateRandomSync(length);
  return new Uint8Array(result.data);
}

// ---- legacy helpers (used only for V0 decryption) ----
const LEGACY_IV_STR = 'ohtotptokenaesiv';
const LEGACY_SALT = new Uint8Array(16); // zero salt

function legacyDeriveKey(user_key: string): cryptoFramework.SymKey {
  let spec: cryptoFramework.PBKDF2Spec = {
    algName: 'PBKDF2',
    password: user_key,
    salt: LEGACY_SALT,
    iterations: 10000,
    keySize: 16
  };
  let kdf = cryptoFramework.createKdf('PBKDF2|SHA256');
  let symKeyBlob = kdf.generateSecretSync(spec);
  let aesGenerator = cryptoFramework.createSymKeyGenerator('AES128');
  return aesGenerator.convertKeySync(symKeyBlob);
}

function legacyIvSpec(): cryptoFramework.IvParamsSpec {
  // stringToIntArray('ohtotptokenaesiv') equivalent
  const bytes = new Uint8Array(buffer.from(LEGACY_IV_STR).buffer);
  return { algName: "IvParamsSpec", iv: { data: bytes } };
}

function deriveKey(user_key: string, salt: Uint8Array, iterations: number): cryptoFramework.SymKey {
  let spec: cryptoFramework.PBKDF2Spec = {
    algName: 'PBKDF2',
    password: user_key,
    salt: salt,
    iterations: iterations,
    keySize: 16
  };
  let kdf = cryptoFramework.createKdf('PBKDF2|SHA256');
  let symKeyBlob = kdf.generateSecretSync(spec);
  let aesGenerator = cryptoFramework.createSymKeyGenerator('AES128');
  return aesGenerator.convertKeySync(symKeyBlob);
}

export async function decryptFile(file_buf: Uint8Array, user_key: string): Promise<string> {
  let salt: Uint8Array;
  let iv: Uint8Array;
  let cipherData: Uint8Array;

  if (file_buf.length >= HEADER_SIZE && startsWith(file_buf, MAGIC)) {
    // ---- V2 (new format): MAGIC + salt:16 + iv:16 + ciphertext ----
    salt = file_buf.slice(SALT_OFS, SALT_OFS + 16);
    iv = file_buf.slice(IV_OFS, IV_OFS + 16);
    cipherData = file_buf.slice(HEADER_SIZE);
    let aes_decoder = cryptoFramework.createCipher('AES128|CBC|PKCS7');
    let aes_iv: cryptoFramework.IvParamsSpec = { algName: "IvParamsSpec", iv: { data: iv } };
    let aes_key = deriveKey(user_key, salt, 600000);
    await aes_decoder.init(cryptoFramework.CryptoMode.DECRYPT_MODE, aes_key, aes_iv);
    let decryptData = await aes_decoder.doFinal({ data: cipherData });
    let decoder = new util.TextDecoder();
    return decoder.decodeToString(decryptData.data);
  } else {
    // ---- V0 (legacy): raw ciphertext, hardcoded IV, zero salt ----
    let aes_decoder = cryptoFramework.createCipher('AES128|CBC|PKCS7');
    let aes_key = legacyDeriveKey(user_key);
    await aes_decoder.init(cryptoFramework.CryptoMode.DECRYPT_MODE, aes_key, legacyIvSpec());
    let decryptData = await aes_decoder.doFinal({ data: file_buf });
    let decoder = new util.TextDecoder();
    return decoder.decodeToString(decryptData.data);
  }
}

export async function encryptFile(file_str: string, user_key: string): Promise<Uint8Array> {
  let salt = randomBytes(16);
  let iv = randomBytes(16);
  let aes_encoder = cryptoFramework.createCipher('AES128|CBC|PKCS7');
  let aes_iv: cryptoFramework.IvParamsSpec = { algName: "IvParamsSpec", iv: { data: iv } };
  let aes_key = deriveKey(user_key, salt, 600000);
  aes_encoder.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, aes_key, aes_iv);
  let ciphertext = new Uint8Array((await aes_encoder.doFinal({ data: new Uint8Array(buffer.from(file_str).buffer) })).data);
  // Build V2 output: MAGIC(4) + salt(16) + iv(16) + ciphertext
  let output = new Uint8Array(HEADER_SIZE + ciphertext.length);
  output.set(MAGIC, 0);
  output.set(salt, SALT_OFS);
  output.set(iv, IV_OFS);
  output.set(ciphertext, HEADER_SIZE);
  return output;
}
export async function encryptUint8ArrayData(data: Uint8Array, symKeyBlob: cryptoFramework.DataBlob): Promise<Uint8Array> {
  let iv = randomBytes(16);
  let aes_encoder = cryptoFramework.createCipher('AES128|CBC|PKCS7');
  let aes_iv: cryptoFramework.IvParamsSpec = { algName: "IvParamsSpec", iv: { data: iv } };
  let aesGenerator = cryptoFramework.createSymKeyGenerator('AES128');
  let aes_key = aesGenerator.convertKeySync(symKeyBlob);
  aes_encoder.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, aes_key, aes_iv);
  let ciphertext = new Uint8Array((await aes_encoder.doFinal({ data: data })).data);
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
      iv = new Uint8Array(buffer.from(LEGACY_IV_STR).buffer);
      cipherData = data;
    }

    let aes_decoder = cryptoFramework.createCipher('AES128|CBC|PKCS7');
    let aes_iv: cryptoFramework.IvParamsSpec = { algName: "IvParamsSpec", iv: { data: iv } };
    let aesGenerator = cryptoFramework.createSymKeyGenerator('AES128');
    let aes_key = aesGenerator.convertKeySync(symKeyBlob);
    await aes_decoder.init(cryptoFramework.CryptoMode.DECRYPT_MODE, aes_key, aes_iv);
    return new Uint8Array((await aes_decoder.doFinal({ data: cipherData })).data);
  } catch (_e) {
    return null;
  }
}

/**
 * AES128 CBC 加密字符串 返回加密后的字节数组
 *
 */
export async function encryptStringData(data: string, symKeyBlob: cryptoFramework.DataBlob): Promise<Uint8Array> {
  let dataBlob = new Uint8Array(buffer.from(data, 'utf-8').buffer);
  return await encryptUint8ArrayData(dataBlob, symKeyBlob);
}
export async function decryptStringData(data: Uint8Array, symKeyBlob: cryptoFramework.DataBlob): Promise<string | null> {
  try {
    let decryptData = await decryptUint8ArrayData(data, symKeyBlob);
    if (decryptData === null) {
      return null;
    }
    let decoder = new util.TextDecoder();
    return decoder.decodeToString(decryptData);
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

let bleTransportKey: cryptoFramework.SymKey | undefined = undefined;

async function getBleTransportKey(): Promise<cryptoFramework.SymKey> {
  if (bleTransportKey === undefined) {
    let md = cryptoFramework.createMd('SHA256');
    await md.update({ data: new Uint8Array(buffer.from(BLE_KEY_CONST).buffer) });
    let digest: cryptoFramework.DataBlob = await md.digest();
    let keyGen = cryptoFramework.createSymKeyGenerator('AES256');
    bleTransportKey = keyGen.convertKeySync(digest);
  }
  return bleTransportKey;
}

/**
 * 加密 BLE 传输载荷(手机端).
 *
 * GCM 加密模式下 authTag 的获取: 个别 SDK 版本由 doFinal(null) 返回,
 * 部分版本以副作用写入 gcmParams.authTag, 此处双保险读取.
 */
export async function encryptBlePayload(plain: Uint8Array): Promise<Uint8Array> {
  let iv = randomBytes(BLE_IV_LEN);
  let key = await getBleTransportKey();
  let gcmParams: cryptoFramework.GcmParamsSpec = {
    algName: 'GcmParamsSpec',
    iv: { data: iv },
    aad: { data: BLE_AAD },
    authTag: { data: new Uint8Array(BLE_TAG_LEN) }
  };
  let cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
  cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, gcmParams);
  // 官方指南行为: update(明文) 返回 ciphertext, doFinal(null) 返回 authTag
  let enc: cryptoFramework.DataBlob = cipher.updateSync({ data: plain });
  let tagData: cryptoFramework.DataBlob = cipher.doFinalSync(null);
  // 双保险: 优先取 doFinal(null) 返回的完整 tag, 否则取副作用写入的 gcmParams.authTag
  let tag: Uint8Array = tagData.data.length === BLE_TAG_LEN ? tagData.data : gcmParams.authTag.data;
  let ciphertext: Uint8Array = new Uint8Array(enc.data);
  let out = new Uint8Array(BLE_HEADER_SIZE + ciphertext.length);
  out.set(BLE_MAGIC, 0);
  out.set(iv, 4);
  out.set(tag, 4 + BLE_IV_LEN);
  out.set(ciphertext, BLE_HEADER_SIZE);
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
    let gcmParams: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: { data: iv },
      aad: { data: BLE_AAD },
      authTag: { data: tag }
    };
    let cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, key, gcmParams);
    let dec = cipher.doFinalSync({ data: ciphertext });
    return new Uint8Array(dec.data);
  } catch (e) {
    return null;
  }
}
