import { TokenConfig } from './TokenConfig';

/**
 * 手机↔手表 传输协议纯类层（Phase 3，docs/TEST_PLAN.md 第 4 节）。
 *
 * BLE（GATT 写特征）与 WearEngine（P2P 消息）共用同一分片协议：
 * - 首帧: JSON 头 {"total": 数据总字节数, "count": 消息数, "type": "tokens"|"settings"}
 *   （WearEngine 首帧额外带 "OTPW" 前缀以区分头帧与数据帧）
 * - 后续帧: ≤ maxChunk 的加密载荷分片（AES-256-GCM，[MAGIC][iv][tag][ciphertext]）
 * - 接收方按 total 重组，解密后按 type 分发
 *
 * 本文件把分帧构建、头解析、接收状态机与令牌批次 UUID 复用抽成纯类：
 * - 不依赖任何 @ohos 系统 API（UTF-8 编解码为纯 TS 实现），LocalUnit 可全分支测试；
 * - 生产帧序/重组语义与抽离前逐分支等价（见各类注释），真机行为由 ohosTest 冒烟兜底。
 */

/** 传输头部帧结构（BLE 与 WearEngine 共用） */
export interface TransferHeader {
  total: number;
  count: number;
  /** 消息类型: 缺省为 tokens(向后兼容旧版发送端) */
  type?: string;
}

/** 纯 TS UTF-8 编码（合法标量与 util.TextEncoder.encodeInto 字节级一致，含代理对；孤立代理编为 U+FFFD，对齐 WHATWG TextEncoder）。 */
export function utf8Encode(text: string): Uint8Array {
  const out: number[] = [];
  for (let i = 0; i < text.length; i++) {
    let code = text.charCodeAt(i);
    if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length) {
      const lo = text.charCodeAt(i + 1);
      if (lo >= 0xDC00 && lo <= 0xDFFF) {
        code = 0x10000 + ((code - 0xD800) << 10) + (lo - 0xDC00);
        i++;
      } else {
        code = 0xFFFD;
      }
    } else if (code >= 0xD800 && code <= 0xDFFF) {
      // 孤立代理（含尾部悬挂的高代理与任意低代理）
      code = 0xFFFD;
    }
    if (code < 0x80) {
      out.push(code);
    } else if (code < 0x800) {
      out.push(0xC0 | (code >> 6), 0x80 | (code & 63));
    } else if (code < 0x10000) {
      out.push(0xE0 | (code >> 12), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
    } else {
      out.push(0xF0 | (code >> 18), 0x80 | ((code >> 12) & 63), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
    }
  }
  return new Uint8Array(out);
}

/** UTF-8 续字节（0x80-0xBF）。 */
function isContinuation(b: number): boolean {
  return b >= 0x80 && b < 0xC0;
}

/**
 * 纯 TS UTF-8 解码（lenient）：非法/截断/过度编码/代理区编码序列以 U+FFFD 替换并跳过
 * （与 TextDecoder 的 replacement 容错对齐，序列合法性含续字节取值范围与首字节边界）。
 * 协议用途：合法载荷精确还原，加密分片误当头帧时必然产出 JSON.parse 无法接受的内容。
 */
export function utf8Decode(data: Uint8Array): string {
  let out = '';
  let i = 0;
  while (i < data.length) {
    const b = data[i];
    let code = -1;
    let width = 1;
    if (b < 0x80) {
      code = b;
    } else if (b >= 0xC2 && b < 0xE0 && i + 1 < data.length && isContinuation(data[i + 1])) {
      code = ((b & 0x1F) << 6) | (data[i + 1] & 63);
      width = 2;
    } else if (b >= 0xE0 && b < 0xF0 && i + 2 < data.length
      && isContinuation(data[i + 1]) && isContinuation(data[i + 2])) {
      // 过度编码（E0 后 A0-BF 才合法）与代理区（ED 后 80-9F 才合法）
      const ok = (b === 0xE0 && data[i + 1] >= 0xA0) || (b === 0xED && data[i + 1] < 0xA0)
        || (b > 0xE0 && b < 0xED) || (b > 0xED && b < 0xF0);
      if (ok) {
        code = ((b & 0x0F) << 12) | ((data[i + 1] & 63) << 6) | (data[i + 2] & 63);
        width = 3;
      }
    } else if (b >= 0xF0 && b < 0xF5 && i + 3 < data.length
      && isContinuation(data[i + 1]) && isContinuation(data[i + 2]) && isContinuation(data[i + 3])) {
      // F0 后 90-BF 才合法（防过度编码），F4 后 80-8F 才合法（防超出 U+10FFFF）
      const ok = (b === 0xF0 && data[i + 1] >= 0x90) || (b === 0xF4 && data[i + 1] < 0x90)
        || (b > 0xF0 && b < 0xF4);
      if (ok) {
        code = ((b & 0x07) << 18) | ((data[i + 1] & 63) << 12) | ((data[i + 2] & 63) << 6) | (data[i + 3] & 63);
        width = 4;
      }
    }
    if (code < 0) {
      out += String.fromCharCode(0xFFFD);
      i += 1;
      continue;
    }
    i += width;
    if (code >= 0x10000) {
      code -= 0x10000;
      out += String.fromCharCode(0xD800 + (code >> 10), 0xDC00 + (code & 1023));
    } else {
      out += String.fromCharCode(code);
    }
  }
  return out;
}

/** 发送侧一帧：bytes 为线上字节，isFinal 标记收尾数据帧（BLE 收尾帧用放宽超时）。 */
export class TransferFrame {
  bytes: Uint8Array = new Uint8Array(0);
  isFinal: boolean = false;
}

/**
 * 发送侧分帧构建器：头帧（前缀 + JSON）+ ≤maxChunk 数据分片。
 * 构建顺序与分片边界和抽离前的 BLE/WearEngine 实现逐字节一致。
 */
export class TransferFrameBuilder {
  private readonly prefix: string;
  private readonly maxChunk: number;

  constructor(prefix: string, maxChunk: number) {
    this.prefix = prefix;
    this.maxChunk = maxChunk;
  }

  /** 头帧字节（独立导出供头帧与数据帧分开发送的通道使用） */
  buildHeaderBytes(total: number, count: number, type: string): Uint8Array {
    return utf8Encode(`${this.prefix}${JSON.stringify({ total: total, count: count, type: type })}`);
  }

  /** 完整帧序列：头帧 + 数据分片；payload 为空时仅有头帧（与原实现 while 循环边界一致） */
  buildFrames(payload: Uint8Array, count: number, type: string): TransferFrame[] {
    const total: number = payload.byteLength;
    const frames: TransferFrame[] = [];
    const header = new TransferFrame();
    header.bytes = this.buildHeaderBytes(total, count, type);
    frames.push(header);

    let offset = 0;
    while (offset < total) {
      const end = Math.min(offset + this.maxChunk, total);
      const chunk = new Uint8Array(end - offset);
      chunk.set(payload.subarray(offset, end));
      const frame = new TransferFrame();
      frame.bytes = chunk;
      frame.isFinal = offset + chunk.byteLength >= total;
      frames.push(frame);
      offset = end;
    }
    return frames;
  }
}

/** 一次完整批次的快照（收齐 total 字节时生成，接收状态机随即复位）。 */
export class TransferBatch {
  total: number = 0;
  count: number = 0;
  type: string = '';
  chunks: Array<Uint8Array> = [];
  /** 实际收到的分片总字节（发送方 total 声明不符时的失败判定依据） */
  receivedBytes: number = 0;
}

/** 帧事件类别 */
export enum TransferFrameEventKind {
  /** 有效头帧：新批次开始（含批次中途新头帧丢弃残留批次的场景） */
  BATCH_STARTED = 0,
  /** 数据帧已并入进行中批次，尚未收齐 */
  CHUNK_ACCEPTED = 1,
  /** 分片收齐，batch 携带快照，接收状态已自动复位 */
  BATCH_COMPLETE = 2,
  /** 头帧非法（解析失败/total ≤ 0/超上限）：批次状态保持不变 */
  HEADER_INVALID = 3,
  /** 数据帧到达但无进行中批次（旧实现静默忽略） */
  ORPHAN_CHUNK = 4,
  /** 缺省占位：新增事件种类未显式赋值时可被通道层识别为异常 */
  UNKNOWN = 5,
}

/** 帧事件：kind + BATCH_STARTED 时的头帧明细（供日志）+ BATCH_COMPLETE 时的批次快照 */
export class TransferFrameEvent {
  kind: TransferFrameEventKind = TransferFrameEventKind.UNKNOWN;
  header: TransferHeader | null = null;
  batch: TransferBatch | null = null;
}

/** 接收侧配置（BLE 与 WearEngine 差异点） */
export class TransferFrameOptions {
  /** 头帧前缀；空串 = 无前缀模式（BLE：每帧都是头帧候选，数据帧解析必然失败） */
  headerPrefix: string = '';
  /** 头帧 total 上限（字节）；0 = 不设上限（WearEngine） */
  maxTotal: number = 0;
}

/**
 * 接收侧分片重组状态机。
 *
 * 与抽离前行为的等价性说明：
 * - 任何有效头帧（含批次中途）都会丢弃残留分片并重启批次：BLE 的"手机端超时中断后
 *   立即重试"与 WearEngine 的头前缀判定均依赖此语义；
 * - HEADER_INVALID 保持当前批次不变。注意这是对 WearEngine 旧实现的有意收口：
 *   旧代码对 total ≤ 0 的头帧静默忽略（批次保留），但对 JSON 解析抛错的头帧会落入
 *   外层 catch 并重置批次（传输挂死）；此处统一为保留批次，解析抛错不再有副作用；
 *   BLE 旧实现的解析失败路径（reset + FAILED + 失败应答）由 ORPHAN_CHUNK 映射保持不变；
 * - 收齐判定为 received >= total（与原实现一致，交叠写入的精确性校验由
 *   {@link concatenateChunks} 与通道层的 receivedBytes !== total 分支承担）；
 * - BATCH_COMPLETE 后状态立即复位，收尾帧处理（解密/入库）期间新批次可立即开始。
 */
export class TransferFrameReceiver {
  private readonly options: TransferFrameOptions;
  private readonly prefixBytes: Uint8Array;
  private batch: TransferBatch | null = null;

  constructor(options: TransferFrameOptions) {
    this.options = options;
    this.prefixBytes = utf8Encode(options.headerPrefix);
  }

  /** 是否有进行中的批次 */
  isInProgress(): boolean {
    return this.batch !== null;
  }

  /** 丢弃进行中的批次（断连/失败路径复位） */
  reset(): void {
    this.batch = null;
  }

  /** 送入一帧，返回事件供通道层映射各自的状态上报与写应答 */
  onFrame(bytes: Uint8Array): TransferFrameEvent {
    const event = new TransferFrameEvent();
    if (this.prefixBytes.length > 0) {
      if (!this.startsWith(bytes, this.prefixBytes)) {
        return this.acceptChunk(bytes, event);
      }
      const header = this.parseHeader(bytes.subarray(this.prefixBytes.length));
      if (header === null) {
        event.kind = TransferFrameEventKind.HEADER_INVALID;
        return event;
      }
      this.startBatch(header);
      event.kind = TransferFrameEventKind.BATCH_STARTED;
      event.header = header;
      return event;
    }

    // 无前缀模式：每帧都是头帧候选；解析成功即头帧（数据帧为加密随机字节，不可能解析出合法头）
    const header = this.parseHeader(bytes);
    if (header !== null) {
      this.startBatch(header);
      event.kind = TransferFrameEventKind.BATCH_STARTED;
      event.header = header;
      return event;
    }
    return this.acceptChunk(bytes, event);
  }

  /** 数据帧并入：无批次则孤儿帧；收齐则产出快照并复位 */
  private acceptChunk(bytes: Uint8Array, event: TransferFrameEvent): TransferFrameEvent {
    if (this.batch === null) {
      event.kind = TransferFrameEventKind.ORPHAN_CHUNK;
      return event;
    }
    this.batch.chunks.push(bytes);
    this.batch.receivedBytes += bytes.byteLength;
    if (this.batch.receivedBytes >= this.batch.total) {
      event.kind = TransferFrameEventKind.BATCH_COMPLETE;
      event.batch = this.batch;
      this.batch = null;
      return event;
    }
    event.kind = TransferFrameEventKind.CHUNK_ACCEPTED;
    return event;
  }

  private startBatch(header: TransferHeader): void {
    const batch = new TransferBatch();
    batch.total = header.total;
    batch.count = header.count;
    batch.type = header.type !== undefined ? header.type : 'tokens';
    this.batch = batch;
  }

  /** 头帧解析与校验：非 JSON/total 非有限正数/超上限返回 null */
  private parseHeader(bytes: Uint8Array): TransferHeader | null {
    let header: TransferHeader | null = null;
    try {
      header = JSON.parse(utf8Decode(bytes)) as TransferHeader;
    } catch (err) {
      return null;
    }
    if (header !== null && typeof header.total === 'number' && header.total > 0
      && (this.options.maxTotal <= 0 || header.total <= this.options.maxTotal)) {
      return header;
    }
    return null;
  }

  private startsWith(data: Uint8Array, prefix: Uint8Array): boolean {
    if (data.length < prefix.length) {
      return false;
    }
    for (let i = 0; i < prefix.length; i++) {
      if (data[i] !== prefix[i]) {
        return false;
      }
    }
    return true;
  }
}

/**
 * 按头帧 total 重组分片：与抽离前实现一致，缓冲区按 total 分配，
 * 分片超出 total 时 set 越界抛异常（交叠写入的保护路径，由通道层捕获判失败）。
 */
export function concatenateChunks(total: number, chunks: Array<Uint8Array>): Uint8Array {
  const full = new Uint8Array(total);
  let offset = 0;
  for (let i = 0; i < chunks.length; i++) {
    full.set(chunks[i], offset);
    offset += chunks[i].byteLength;
  }
  return full;
}

/**
 * 令牌批次入库的 UUID 复用决策（P2P/BLE 两通道共享，纯函数）：
 * 按 issuer+name 匹配本地已有令牌并复用其 UUID。
 *
 * 手机端与手表端令牌 UUID 不同(各端独立生成)，直接 updateToken 会按 UUID 判为
 * 新增导致重复令牌；复用本地 UUID 同时维持排序/删除等引用的稳定性。
 *
 * @returns 复用本地 UUID 的令牌数（原位修改 incoming）
 */
export function reuseLocalTokenUuids(incoming: TokenConfig[], existing: TokenConfig[]): number {
  let reused = 0;
  for (let i = 0; i < incoming.length; i++) {
    for (let j = 0; j < existing.length; j++) {
      if (existing[j].TokenIssuer === incoming[i].TokenIssuer &&
        existing[j].TokenName === incoming[i].TokenName) {
        incoming[i].TokenUUID = existing[j].TokenUUID;
        reused++;
        break;
      }
    }
  }
  return reused;
}
