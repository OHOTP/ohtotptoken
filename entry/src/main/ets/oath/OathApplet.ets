import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from 'common';
import { TagTransport } from './TagTransport';

/**
 * OATH Applet 协议层（OATH 规范 / ykman-yubikit 参考实现）
 *
 * 指令字节与 TLV 标签严格对照 ykman/yubikit 的 oath.py：
 *   INS: SELECT=0xA4, VALIDATE=0xA3, CALCULATE=0xA2, CALCULATE ALL=0xA4, SEND REMAINING=0xA5
 *   TLV: 0x71 name / 0x73 key / 0x74 challenge / 0x75 response / 0x76 truncated
 *        0x77 hotp / 0x7c touch / 0x79 version
 *
 * ⚠️ 本层禁止直接依赖 @kit.ConnectivityKit（FR-014）：仅通过 TagTransport 抽象通信，
 * 使未来 USB 传输可复用本层。
 */

// ---------- 协议常量 ----------
const TAG_NAME = 0x71;
const TAG_CHALLENGE = 0x74;
const TAG_RESPONSE = 0x75;
const TAG_TRUNCATED = 0x76;
const TAG_HOTP = 0x77;
const TAG_TOUCH = 0x7C;
const TAG_VERSION = 0x79;

const INS_CALCULATE = 0xA2;
const INS_VALIDATE = 0xA3;
const INS_CALCULATE_ALL = 0xA4;
const INS_SEND_REMAINING = 0xA5;

const OATH_AID: number[] = [0xA0, 0x00, 0x00, 0x05, 0x27, 0x21, 0x01];
const DEFAULT_PERIOD = 30;
const CHALLENGE_LEN = 8;
const SW_OK = 0x9000;
const SW1_MORE_DATA = 0x61;
/** 需要认证（已锁定未解锁） */
const SW_SECURITY_CONDITION_NOT_SATISFIED = 0x6982;

let logger = Logger;

// ---------- 数据类型 ----------

export type OathType = 'TOTP' | 'HOTP';

export interface OathCredential {
  /** 卡片原始凭据名（uri-string 格式，如 30/issuer:name） */
  credentialId: string;
  /** 原始凭据名 UTF-8 字节（CALCULATE 重算时按原样发送） */
  rawId: Uint8Array;
  /** 解析出的发行方（可为空串） */
  issuer: string;
  /** 解析出的账户名 */
  name: string;
  /** 凭据类型 */
  oathType: OathType;
  /** 验证码位数 */
  digits: number;
  /** TOTP 周期（HOTP 为 0） */
  period: number;
  /** 本次验证码（touch 凭据不返回） */
  code: string | null;
  /** 是否需触摸（touch 凭据已被跳过，恒为 false） */
  touchRequired: boolean;
}

export interface OathReadResult {
  /** 本次读取的全部可用凭据（touch 凭据不含在内） */
  credentials: OathCredential[];
  /** 读取使用的 Unix 时间戳 */
  timestamp: number;
}

export type OathErrorKind =
  'NOT_OATH' | 'PASSWORD_REQUIRED' | 'WRONG_PASSWORD' | 'TRANSPORT' | 'PROTOCOL' | 'NO_TOKENS';

/** OATH 协议错误：kind 分类 + 可选状态字 */
export class OathError extends Error {
  kind: OathErrorKind;
  sw?: number;

  constructor(kind: OathErrorKind, message: string, sw?: number) {
    super(message);
    this.name = 'OathError';
    this.kind = kind;
    this.sw = sw;
  }
}

// ---------- BER-TLV 短格式编解码 ----------

interface OathTlv {
  tag: number;
  value: Uint8Array;
}

/** 编码短格式 TLV（标签 0x71-0x79，长度 < 128） */
function encodeTlv(tag: number, value: number[]): number[] {
  return [tag, value.length].concat(value);
}

/** 解析短格式 TLV 列表（标签 0x71-0x79，长度 < 128） */
function parseTlvList(data: number[]): OathTlv[] {
  const result: OathTlv[] = [];
  let offset = 0;
  while (offset + 1 < data.length) {
    const tag = data[offset];
    offset++;
    const length = data[offset];
    offset++;
    if (offset + length > data.length) {
      break;
    }
    const value = new Uint8Array(data.slice(offset, offset + length));
    offset += length;
    const tlv: OathTlv = { tag: tag, value: value };
    result.push(tlv);
  }
  return result;
}

// ---------- 状态字判定 ----------

/** 取响应最后两字节状态字（9000 成功 / 61xx 更多数据 / 6982 需认证等） */
function getStatusWord(response: number[]): number {
  const n = response.length;
  if (n < 2) {
    return 0;
  }
  return (response[n - 2] << 8) | response[n - 1];
}

/** 取响应中去除状态字后的数据部分 */
function getResponseData(response: number[]): number[] {
  const n = response.length;
  if (n < 2) {
    return [];
  }
  return response.slice(0, n - 2);
}

// ---------- 编解码工具 ----------

const textEncoder = new util.TextEncoder();
const textDecoder = util.TextDecoder.create('utf-8');

function utf8BytesToString(bytes: Uint8Array): string {
  return textDecoder.decodeToString(bytes);
}

/** 大端字节序列（用于 8 字节 challenge 时间步） */
function bigEndianBytes(value: number, len: number): number[] {
  const bytes = new Array<number>(len);
  let tmp = value;
  for (let i = len - 1; i >= 0; i--) {
    bytes[i] = tmp & 0xFF;
    tmp = Math.floor(tmp / 256);
  }
  return bytes;
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

// ---------- 凭据名 uri-string 解析（ykman _parse_cred_id 等价） ----------

interface ParsedCredId {
  issuer: string;
  name: string;
  period: number;
}

/**
 * TOTP 用正则 ^((\d+)/)?(([^:]+):)?(.+)$ 提取 period/issuer/name；
 * HOTP 以首个 ':' 分割 issuer/name（无 issuer 则为空串）。
 */
function parseCredId(credIdBytes: Uint8Array, oathType: OathType): ParsedCredId {
  const data = utf8BytesToString(credIdBytes);
  if (oathType === 'TOTP') {
    const pattern = new RegExp('^((\\d+)/)?(([^:]+):)?(.+)$');
    const match = pattern.exec(data);
    if (match !== null) {
      const periodStr: string | undefined = match[2];
      const issuerStr: string | undefined = match[4];
      const nameStr: string | undefined = match[5];
      const period = periodStr !== undefined && periodStr !== '' ? parseInt(periodStr, 10) : DEFAULT_PERIOD;
      const parsed: ParsedCredId = {
        issuer: issuerStr ?? '',
        name: nameStr ?? data,
        period: period > 0 ? period : DEFAULT_PERIOD
      };
      return parsed;
    }
    const fallback: ParsedCredId = { issuer: '', name: data, period: DEFAULT_PERIOD };
    return fallback;
  }
  let issuer = '';
  let name = data;
  const colonIdx = data.indexOf(':');
  if (colonIdx > 0) {
    issuer = data.substring(0, colonIdx);
    name = data.substring(colonIdx + 1);
  }
  const hotp: ParsedCredId = { issuer: issuer, name: name, period: 0 };
  return hotp;
}

// ---------- 验证码格式化（ykman _format_code 等价） ----------

/**
 * truncated = [digits, 4字节hash]；code = ((bytes2int(truncated[1:]) & 0x7FFFFFFF) % 10^digits)
 * 左补零至 digits 位。
 */
function formatCode(truncated: Uint8Array): string {
  if (truncated.length < 2) {
    return '';
  }
  const digits = truncated[0];
  let value = 0;
  for (let i = 1; i < truncated.length; i++) {
    value = value * 256 + truncated[i];
  }
  value = value & 0x7FFFFFFF;
  return (value % Math.pow(10, digits)).toString().padStart(digits, '0');
}

/** 单条 CALCULATE 的结果：验证码 + 位数（取自响应 0x76 truncated[0]） */
interface CalcResult {
  code: string;
  digits: number;
}

// ---------- OathSession ----------

/**
 * OATH Applet 会话：SELECT → (VALIDATE) → CALCULATE ALL → close。
 * 与传输层解耦（仅依赖 TagTransport）；每次读取开始新建，读取完成后 close。
 */
export class OathSession {
  private transport: TagTransport;
  private version: string = '';
  private salt: Uint8Array = new Uint8Array(0);
  /** SELECT 响应中的 challenge，存在即锁定（需 VALIDATE 解锁） */
  private challenge: Uint8Array | undefined = undefined;
  private closed: boolean = false;

  constructor(transport: TagTransport) {
    this.transport = transport;
  }

  /** 是否锁定（存在 challenge 即需认证） */
  get locked(): boolean {
    return this.challenge !== undefined;
  }

  /**
   * SELECT OATH Applet：APDU 00 A4 04 00 07 A0 00 00 05 27 21 01。
   * 解析响应 TLV：0x79 版本 / 0x71 盐(ID) / 0x74 challenge（存在即置 locked）。
   * SELECT 失败（非 OATH 卡片）抛 OathError(NOT_OATH)。
   */
  async select(): Promise<void> {
    const apdu: number[] = [0x00, 0xA4, 0x04, 0x00, 0x07].concat(OATH_AID);
    const response = await this.transmitApdu(apdu);
    const sw = getStatusWord(response);
    if (sw !== SW_OK) {
      logger.error(`SELECT failed sw=0x${sw.toString(16)}`);
      throw new OathError('NOT_OATH', `OATH applet select failed (SW=0x${sw.toString(16)})`, sw);
    }
    const tlvs = parseTlvList(getResponseData(response));
    let versionValue: Uint8Array | undefined = undefined;
    let saltValue: Uint8Array | undefined = undefined;
    let challengeValue: Uint8Array | undefined = undefined;
    for (const tlv of tlvs) {
      if (tlv.tag === TAG_VERSION) {
        versionValue = tlv.value;
      } else if (tlv.tag === TAG_NAME) {
        saltValue = tlv.value;
      } else if (tlv.tag === TAG_CHALLENGE) {
        challengeValue = tlv.value;
      }
    }
    this.version = versionValue !== undefined && versionValue.length >= 3
      ? `${versionValue[0]}.${versionValue[1]}.${versionValue[2]}`
      : '';
    this.salt = saltValue ?? new Uint8Array(0);
    this.challenge = challengeValue;
    logger.info(`SELECT ok version=${this.version} locked=${this.locked}`);
  }

  /**
   * VALIDATE：PBKDF2-HMAC-SHA1（1000 轮，16 字节，盐 = SELECT 响应 0x71）派生密钥；
   * HMAC-SHA1(key, challenge) 计算响应；发送 VALIDATE APDU
   * 00 A3 00 00 <len> 75 <20B response> 74 08 <8B 随机新 challenge>；
   * 校验响应 TLV 0x75 与 HMAC-SHA1(key, 新 challenge) 一致。
   * APDU 错误或校验失败抛 OathError(WRONG_PASSWORD)；成功置 locked = false。
   */
  async validate(password: string): Promise<void> {
    if (this.challenge === undefined) {
      return;
    }
    const key = await this.deriveKey(password);
    const response = await this.hmacSha1(key, this.challenge);
    const newChallenge = this.randomBytes(CHALLENGE_LEN);
    const data: number[] = encodeTlv(TAG_RESPONSE, Array.from(response))
      .concat(encodeTlv(TAG_CHALLENGE, Array.from(newChallenge)));
    const apdu: number[] = [0x00, INS_VALIDATE, 0x00, 0x00, data.length].concat(data);
    const resp = await this.transmitApdu(apdu);
    const sw = getStatusWord(resp);
    if (sw !== SW_OK) {
      logger.error(`VALIDATE failed sw=0x${sw.toString(16)}`);
      throw new OathError('WRONG_PASSWORD', `OATH validate failed (SW=0x${sw.toString(16)})`, sw);
    }
    const verification = await this.hmacSha1(key, newChallenge);
    const tlvs = parseTlvList(getResponseData(resp));
    let respValue: Uint8Array | undefined = undefined;
    for (const tlv of tlvs) {
      if (tlv.tag === TAG_RESPONSE) {
        respValue = tlv.value;
      }
    }
    if (respValue === undefined || !bytesEqual(respValue, verification)) {
      logger.error('VALIDATE response mismatch');
      throw new OathError('WRONG_PASSWORD', 'OATH validate response mismatch');
    }
    this.challenge = undefined;
    logger.info('VALIDATE ok');
  }

  /**
   * CALCULATE ALL：APDU 00 A4 00 01 0A 74 08 <8字节大端 timestamp//30>。
   * 解析 [0x71 name, 响应TLV] 列表；61xx 分片经 SEND REMAINING（00 A5 00 00 00）循环取回。
   * 响应 TLV 处理：
   *   - 0x76 truncated：TOTP 验证码（默认周期直接取码）
   *   - 0x77 hotp：记录后逐个 CALCULATE（空 challenge）补码（不推进计数器）
   *   - 0x7c touch：跳过不返回
   *   - 非默认周期（period≠30）TOTP：以自身周期时间步 CALCULATE 重算
   * 已锁定未解锁时 APDU 返回 6982 → 抛 OathError(PASSWORD_REQUIRED)。
   */
  async calculateAll(timestamp: number): Promise<OathCredential[]> {
    const timeStep = Math.floor(timestamp / DEFAULT_PERIOD);
    const challenge = bigEndianBytes(timeStep, CHALLENGE_LEN);
    const data: number[] = encodeTlv(TAG_CHALLENGE, challenge);
    const apdu: number[] = [0x00, INS_CALCULATE_ALL, 0x00, 0x01, data.length].concat(data);
    const response = await this.transmitApdu(apdu);
    const sw = getStatusWord(response);
    if (sw === SW_SECURITY_CONDITION_NOT_SATISFIED) {
      throw new OathError('PASSWORD_REQUIRED', 'OATH calculate all requires authentication', sw);
    }
    if (sw !== SW_OK) {
      throw new OathError('PROTOCOL', `OATH calculate all failed (SW=0x${sw.toString(16)})`, sw);
    }
    const tlvs = parseTlvList(getResponseData(response));
    const credentials: OathCredential[] = [];
    let idx = 0;
    while (idx + 1 < tlvs.length) {
      const nameTlv = tlvs[idx];
      const respTlv = tlvs[idx + 1];
      idx += 2;
      if (nameTlv.tag !== TAG_NAME) {
        continue;
      }
      const oathType: OathType = respTlv.tag === TAG_HOTP ? 'HOTP' : 'TOTP';
      const parsed = parseCredId(nameTlv.value, oathType);
      // touch 凭据：免交互流程无法取码，跳过（FR-016）
      if (respTlv.tag === TAG_TOUCH) {
        logger.info(`skip touch credential: ${parsed.name}`);
        continue;
      }
      const credential: OathCredential = {
        credentialId: utf8BytesToString(nameTlv.value),
        rawId: nameTlv.value,
        issuer: parsed.issuer,
        name: parsed.name,
        oathType: oathType,
        digits: respTlv.tag === TAG_TRUNCATED && respTlv.value.length > 0 ? respTlv.value[0] : 6,
        period: oathType === 'HOTP' ? 0 : parsed.period,
        code: null,
        touchRequired: false
      };
      // 默认周期 TOTP 直接取码；HOTP 与非默认周期 TOTP 稍后单独 CALCULATE
      if (respTlv.tag === TAG_TRUNCATED && credential.period === DEFAULT_PERIOD) {
        credential.code = formatCode(respTlv.value);
      }
      credentials.push(credential);
    }
    // 逐个补码（HOTP 空 challenge；非默认周期 TOTP 自身周期时间步），失败则跳过该凭据
    const filled: OathCredential[] = [];
    for (const cred of credentials) {
      if (cred.code !== null) {
        filled.push(cred);
        continue;
      }
      try {
        const calcResult = await this.calculate(cred, timestamp);
        if (calcResult !== null) {
          cred.code = calcResult.code;
          cred.digits = calcResult.digits;
          filled.push(cred);
        }
      } catch (e) {
        logger.error(`CALCULATE failed for ${cred.name}: ${(e as Error).message}`);
      }
    }
    logger.info(`CALCULATE ALL done credentials=${filled.length}`);
    return filled;
  }

  /**
   * CALCULATE 单条凭据取码（不推进 HOTP 计数器）：
   * APDU 00 A2 00 01 <len> 71 <len> <name> 74 00（HOTP 空 challenge）
   * 或 74 08 <challenge>（TOTP 自身周期时间步）。
   * 响应 0x76 truncated → 格式化验证码；失败返回 null。
   */
  private async calculate(credential: OathCredential, timestamp: number): Promise<CalcResult | null> {
    let challenge: number[];
    if (credential.oathType === 'HOTP') {
      challenge = [];
    } else {
      const period = credential.period > 0 ? credential.period : DEFAULT_PERIOD;
      challenge = bigEndianBytes(Math.floor(timestamp / period), CHALLENGE_LEN);
    }
    const data: number[] = encodeTlv(TAG_NAME, Array.from(credential.rawId))
      .concat(encodeTlv(TAG_CHALLENGE, challenge));
    const apdu: number[] = [0x00, INS_CALCULATE, 0x00, 0x01, data.length].concat(data);
    const response = await this.transmitApdu(apdu);
    const sw = getStatusWord(response);
    if (sw !== SW_OK) {
      logger.error(`CALCULATE sw=0x${sw.toString(16)}`);
      return null;
    }
    const tlvs = parseTlvList(getResponseData(response));
    for (const tlv of tlvs) {
      if (tlv.tag === TAG_TRUNCATED) {
        const result: CalcResult = {
          code: formatCode(tlv.value),
          digits: tlv.value.length > 0 ? tlv.value[0] : credential.digits
        };
        return result;
      }
    }
    return null;
  }

  /** 关闭会话与底层传输连接 */
  async close(): Promise<void> {
    if (this.closed) {
      return;
    }
    this.closed = true;
    try {
      await this.transport.close();
    } catch (e) {
      // 忽略关闭异常
    }
  }

  /**
   * 发送 APDU 并处理 61xx 分片：循环发送 00 A5 00 00 00（SEND REMAINING）拼接，
   * 直至状态字非 61xx；返回含最终状态字的完整响应。
   */
  private async transmitApdu(apdu: number[]): Promise<number[]> {
    let buf: number[] = [];
    let response = await this.transport.transmit(apdu);
    let sw = getStatusWord(response);
    buf = buf.concat(getResponseData(response));
    let guard = 0;
    while ((sw >> 8) === SW1_MORE_DATA && guard < 16) {
      response = await this.transport.transmit([0x00, INS_SEND_REMAINING, 0x00, 0x00, 0x00]);
      sw = getStatusWord(response);
      buf = buf.concat(getResponseData(response));
      guard++;
    }
    buf.push((sw >> 8) & 0xFF);
    buf.push(sw & 0xFF);
    return buf;
  }

  /** PBKDF2-HMAC-SHA1 派生 16 字节访问密钥（与 ykman _derive_key 等价） */
  private async deriveKey(password: string): Promise<Uint8Array> {
    const spec: cryptoFramework.PBKDF2Spec = {
      algName: 'PBKDF2',
      password: password,
      salt: this.salt,
      iterations: 1000,
      keySize: 16
    };
    const kdf = cryptoFramework.createKdf('PBKDF2|SHA1');
    const secret = await kdf.generateSecret(spec);
    return secret.data;
  }

  /** HMAC-SHA1 计算（参照 TokenUtils.ets 的 genSymKeyByData/doHmacBySync 写法） */
  private async hmacSha1(key: Uint8Array, message: Uint8Array): Promise<Uint8Array> {
    const keyBlob: cryptoFramework.DataBlob = { data: key };
    const symKeyGenerator = cryptoFramework.createSymKeyGenerator('HMAC');
    const symKey = symKeyGenerator.convertKeySync(keyBlob);
    const mac = cryptoFramework.createMac('SHA1');
    mac.initSync(symKey);
    mac.updateSync({ data: message });
    const macResult = mac.doFinalSync();
    return macResult.data;
  }

  /** 生成 len 字节系统随机数 */
  private randomBytes(len: number): Uint8Array {
    const random = cryptoFramework.createRandom();
    return random.generateRandomSync(len).data;
  }
}
