import { hilog } from '@kit.PerformanceAnalysisKit';
import { buffer, util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { randomBytes } from './CryptoUtils';

const TAG = 'CloudBackupCrypto';
const DOMAIN = 0xFF00;
/** JWT-like 三段式分隔符：header.payload.signature */
const TOKEN_SEPARATOR = '.';
/** PBKDF2 密钥派生迭代次数，10000 次平衡安全性与性能 */
const PBKDF2_ITERATIONS = 10000;
/** AES-128 密钥长度（字节） */
const KEY_SIZE = 16;
/** 旧版 mock 文件的 salt 前缀标识，用于向后兼容检测 */
const MOCK_SALT_PREFIX = 'mock_salt_';

/**
 * 可注入的 base64 编解码器。
 *
 * 实测 `util.Base64Helper` 在 LocalUnit / Previewer 运行时下**静默返回空数据**
 * （不抛异常），因此三段式 header 的编解码与 AES 同样走注入：
 * 生产用 UtilBase64Codec，测试注入纯 TS 编解码（SteamCrypto.base64Encode 等）。
 */
export interface Base64Codec {
  /** UTF-8 文本 → base64 */
  encodeText(text: string): string;
  /** base64 → UTF-8 文本 */
  decodeText(base64Str: string): string;
  /** 字节 → base64 */
  encodeBytes(data: Uint8Array): string;
  /** base64 → 字节 */
  decodeBytes(base64Str: string): Uint8Array;
}

/** 默认编解码器：@kit.ArkTS 的 util.Base64Helper（设备端专用）。 */
export class UtilBase64Codec implements Base64Codec {
  private helper: util.Base64Helper = new util.Base64Helper();

  encodeText(text: string): string {
    const uint8Array = new Uint8Array(buffer.from(text, 'utf-8').buffer);
    return this.helper.encodeToStringSync(uint8Array);
  }

  decodeText(base64Str: string): string {
    const uint8Array = this.helper.decodeSync(base64Str);
    return buffer.from(uint8Array).toString('utf-8');
  }

  encodeBytes(data: Uint8Array): string {
    return this.helper.encodeToStringSync(data);
  }

  decodeBytes(base64Str: string): Uint8Array {
    return this.helper.decodeSync(base64Str);
  }
}

/**
 * 可注入的备份加密引擎（沿用 HttpTransport/Sleeper 的注入模式）。
 *
 * 生产环境使用 {@link CryptoFrameworkBackupEngine}；LocalUnit / Previewer 下
 * cryptoFramework 不可用（静默返回空数据），测试注入纯 TS 引擎覆盖
 * 三段式格式、签名校验与 mock 兼容分支——真正的 AES/PBKDF2 数值正确性
 * 由 ohosTest 真机用例回归。
 */
export interface BackupCryptoEngine {
  /** CSPRNG 随机字节。salt/iv 必须不可预测，测试可注入确定性实现。 */
  randomBytes(length: number): Uint8Array;
  /** SHA-256 十六进制摘要，用于三段式的签名段。 */
  sha256Hex(data: string): Promise<string>;
  /** AES-128|CBC|PKCS7 加密，密钥由 PBKDF2|SHA256(password, salt) 派生。 */
  aesCbcEncrypt(plaintext: Uint8Array, password: string, salt: Uint8Array,
    iv: Uint8Array): Promise<Uint8Array>;
  /** AES-128|CBC|PKCS7 解密，密钥派生方式同上。 */
  aesCbcDecrypt(ciphertext: Uint8Array, password: string, salt: Uint8Array,
    iv: Uint8Array): Promise<Uint8Array>;
}

/** 默认引擎：cryptoFramework AES-128|CBC|PKCS7 + PBKDF2|SHA256（设备端专用）。 */
export class CryptoFrameworkBackupEngine implements BackupCryptoEngine {
  randomBytes(length: number): Uint8Array {
    // 必须用 CSPRNG：salt/iv 若可预测，AES-CBC 密文可被离线攻击。
    // 委托 CryptoUtils.randomBytes（cryptoFramework.createRandom），保持单一实现。
    return randomBytes(length);
  }

  async sha256Hex(data: string): Promise<string> {
    const md = cryptoFramework.createMd('SHA256');
    const inputData = new Uint8Array(buffer.from(data, 'utf-8').buffer);
    await md.update({ data: inputData });
    const result = await md.digest();
    return buffer.from(result.data).toString('hex');
  }

  async aesCbcEncrypt(plaintext: Uint8Array, password: string, salt: Uint8Array,
    iv: Uint8Array): Promise<Uint8Array> {
    const symKey = await deriveKey(password, salt);
    const cipher = cryptoFramework.createCipher('AES128|CBC|PKCS7');
    const ivSpec: cryptoFramework.IvParamsSpec = {
      algName: 'IvParamsSpec',
      iv: { data: iv },
    };
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, ivSpec);
    const result = await cipher.doFinal({ data: plaintext });
    return result.data;
  }

  async aesCbcDecrypt(ciphertext: Uint8Array, password: string, salt: Uint8Array,
    iv: Uint8Array): Promise<Uint8Array> {
    const symKey = await deriveKey(password, salt);
    const cipher = cryptoFramework.createCipher('AES128|CBC|PKCS7');
    const ivSpec: cryptoFramework.IvParamsSpec = {
      algName: 'IvParamsSpec',
      iv: { data: iv },
    };
    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, ivSpec);
    const result = await cipher.doFinal({ data: ciphertext });
    return result.data;
  }
}

/** PBKDF2|SHA256 密钥派生：将密码字符串 + salt 迭代生成 AES-128 对称密钥 */
async function deriveKey(password: string, salt: Uint8Array): Promise<cryptoFramework.SymKey> {
  const spec: cryptoFramework.PBKDF2Spec = {
    algName: 'PBKDF2',
    password: password,
    salt: salt,
    iterations: PBKDF2_ITERATIONS,
    keySize: KEY_SIZE,
  };
  const kdf = cryptoFramework.createKdf('PBKDF2|SHA256');
  const symKeyBlob = await kdf.generateSecret(spec);
  const aesGenerator = cryptoFramework.createSymKeyGenerator('AES128');
  return aesGenerator.convertKey(symKeyBlob);
}

/** 加密模式枚举：NONE=未加密（旧 mock 格式），HUAWEI_ACCOUNT=华为账号绑定密钥加密 */
export enum CloudBackupCryptoMode {
  NONE = 0,
  HUAWEI_ACCOUNT = 1,
}

/** 备份文件头部元数据，base64 编码后作为 JWT-like 第一段 */
export interface CloudBackupTokenHeader {
  version: number;
  mode: CloudBackupCryptoMode;
  salt: string;
  iv: string;
  tokenCount: number;
  size: number;
  timestamp: number;
  deviceId: string;
  deviceName: string;
}

/** 云端备份记录，用于备份历史列表展示 */
export interface CloudBackupRecord {
  id: string;
  date: string;
  timestamp: number;
  tokenCount: number;
  size: number;
  encrypted: boolean;
  deviceId: string;
  deviceName: string;
  location: number;
}

export class CloudBackupTokenError extends Error {
  code: number;
  constructor(message: string, code: number = 0) {
    super(message);
    this.name = 'CloudBackupTokenError';
    this.code = code;
  }
}

/**
 * 云端备份加密/解密单例。
 * 文件格式为 JWT-like 三段式：base64(header).base64(ciphertext).hex(sha256)
 * 加密算法：AES-128|CBC|PKCS7，密钥派生：PBKDF2|SHA256
 * 向后兼容：旧版 mock 文件（salt 以 mock_salt_ 开头）直接 base64 解码返回明文
 */
export class CloudBackupCrypto {
  private static instance: CloudBackupCrypto | null = null;
  private readonly engine: BackupCryptoEngine;
  private readonly codec: Base64Codec;

  private constructor(engine?: BackupCryptoEngine, codec?: Base64Codec) {
    this.engine = engine !== undefined ? engine : new CryptoFrameworkBackupEngine();
    this.codec = codec !== undefined ? codec : new UtilBase64Codec();
  }

  static getInstance(): CloudBackupCrypto {
    if (!CloudBackupCrypto.instance) {
      CloudBackupCrypto.instance = new CloudBackupCrypto();
    }
    return CloudBackupCrypto.instance;
  }

  /** 测试注入：替换单例并绑定给定引擎/编解码器，返回新实例。 */
  static useEngineForTest(engine: BackupCryptoEngine, codec?: Base64Codec): CloudBackupCrypto {
    CloudBackupCrypto.instance = new CloudBackupCrypto(engine, codec);
    return CloudBackupCrypto.instance;
  }

  /** 根据华为账号登录状态决定加密模式 */
  getMode(isHuaweiLoggedIn: boolean): CloudBackupCryptoMode {
    return isHuaweiLoggedIn ? CloudBackupCryptoMode.HUAWEI_ACCOUNT : CloudBackupCryptoMode.NONE;
  }

  /**
   * 加密明文令牌数据，生成 JWT-like 三段式备份文件内容。
   * 流程：生成随机 salt+iv → 构建 header → AES 加密 → 拼接 header.payload.signature
   * @param plaintext 令牌 JSON 明文
   * @param mode 加密模式（必须非 NONE）
   * @param key 密钥材料（华为账号关联的密钥字符串）
   * @param tokenCount 令牌数量，写入 header 用于 UI 展示
   * @param timestamp 备份时间戳（毫秒）
   * @param deviceId 设备 ODID
   * @param deviceName 设备市场名称
   * @returns 三段式加密字符串
   */
  async encrypt(
    plaintext: string,
    mode: CloudBackupCryptoMode,
    key: string,
    tokenCount: number,
    timestamp: number,
    deviceId: string,
    deviceName: string,
  ): Promise<string> {
    if (mode === CloudBackupCryptoMode.NONE) {
      throw new CloudBackupTokenError('Encryption requires a valid mode', 3);
    }

    const salt = this.engine.randomBytes(KEY_SIZE);
    const iv = this.engine.randomBytes(KEY_SIZE);

    const saltB64 = this.uint8ArrayToBase64(salt);
    const ivB64 = this.uint8ArrayToBase64(iv);

    const header: CloudBackupTokenHeader = {
      version: 2,
      mode: mode,
      salt: saltB64,
      iv: ivB64,
      tokenCount: tokenCount,
      size: plaintext.length,
      timestamp: timestamp,
      deviceId: deviceId,
      deviceName: deviceName,
    };

    const plaintextBytes = new Uint8Array(buffer.from(plaintext, 'utf-8').buffer);
    const ciphertext = await this.engine.aesCbcEncrypt(plaintextBytes, key, salt, iv);

    const headerB64 = this.encodeBase64(JSON.stringify(header));
    const payloadB64 = this.uint8ArrayToBase64(ciphertext);
    const hash = await this.engine.sha256Hex(headerB64 + TOKEN_SEPARATOR + payloadB64);

    hilog.info(DOMAIN, TAG, `encrypt: version=2, tokenCount=${tokenCount}, size=${header.size}`);
    return headerB64 + TOKEN_SEPARATOR + payloadB64 + TOKEN_SEPARATOR + hash;
  }

  /**
   * 解密 JWT-like 三段式备份文件内容，返回令牌 JSON 明文。
   * 流程：拆分三段 → 验证 SHA256 签名 → 解析 header → 检测是否 mock 旧格式 → AES 解密
   * 向后兼容：若 header.salt 以 "mock_salt_" 开头，直接 base64 解码 payload 返回明文
   */
  async decrypt(token: string, mode: CloudBackupCryptoMode, key: string): Promise<string> {
    const segments = token.split(TOKEN_SEPARATOR);
    if (segments.length !== 3) {
      throw new CloudBackupTokenError('Invalid token format: expected 3 segments', 1);
    }

    const headerB64 = segments[0];
    const payloadB64 = segments[1];
    const signature = segments[2];

    const isValid = await this.verifySha256(headerB64 + TOKEN_SEPARATOR + payloadB64, signature);
    if (!isValid) {
      throw new CloudBackupTokenError('Token integrity check failed', 2);
    }

    const headerJson = this.decodeBase64(headerB64);
    const header = JSON.parse(headerJson) as CloudBackupTokenHeader;

    if (header.salt.startsWith(MOCK_SALT_PREFIX)) {
      hilog.info(DOMAIN, TAG, 'decrypt: legacy mock format detected, returning plaintext payload');
      const payload = this.decodeBase64(payloadB64);
      return payload;
    }

    const salt = this.base64ToUint8Array(header.salt);
    const iv = this.base64ToUint8Array(header.iv);
    const ciphertext = this.base64ToUint8Array(payloadB64);

    const plaintextBytes = await this.engine.aesCbcDecrypt(ciphertext, key, salt, iv);
    const result = buffer.from(plaintextBytes).toString('utf-8');

    hilog.info(DOMAIN, TAG, `decrypt: version=${header.version}, decrypted size=${result.length}`);
    return result;
  }

  /** 仅解析 header 段（不解密 payload），用于读取元数据如 tokenCount、deviceId 等 */
  parseTokenHeader(token: string): CloudBackupTokenHeader {
    const segments = token.split(TOKEN_SEPARATOR);
    if (segments.length !== 3) {
      throw new CloudBackupTokenError('Invalid token format: expected 3 segments', 1);
    }
    const headerJson = this.decodeBase64(segments[0]);
    return JSON.parse(headerJson) as CloudBackupTokenHeader;
  }

  /** 验证三段式 token 的 SHA256 签名是否完整，不执行解密 */
  async verifyToken(token: string): Promise<boolean> {
    const segments = token.split(TOKEN_SEPARATOR);
    if (segments.length !== 3) {
      return false;
    }
    return await this.verifySha256(segments[0] + TOKEN_SEPARATOR + segments[1], segments[2]);
  }

  /** 检测 token 是否为旧版 mock 格式（salt 以 "mock_salt_" 开头） */
  isMockFormat(token: string): boolean {
    try {
      const header = this.parseTokenHeader(token);
      return header.salt.startsWith(MOCK_SALT_PREFIX);
    } catch (e) {
      return false;
    }
  }

  private encodeBase64(text: string): string {
    return this.codec.encodeText(text);
  }

  private decodeBase64(base64Str: string): string {
    return this.codec.decodeText(base64Str);
  }

  private uint8ArrayToBase64(data: Uint8Array): string {
    return this.codec.encodeBytes(data);
  }

  private base64ToUint8Array(base64Str: string): Uint8Array {
    return this.codec.decodeBytes(base64Str);
  }

  /** 验证 SHA256 签名：比较计算值与期望值是否一致 */
  private async verifySha256(data: string, expectedHex: string): Promise<boolean> {
    const actualHex = await this.engine.sha256Hex(data);
    return actualHex === expectedHex;
  }
}
