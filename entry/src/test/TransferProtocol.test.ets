import { describe, it, expect } from '@ohos/hypium';
import { TokenConfig, otpType } from 'common';
import {
  TransferBatch,
  TransferHeader,
  TransferFrameBuilder,
  TransferFrameEventKind,
  TransferFrameOptions,
  TransferFrameReceiver,
  concatenateChunks,
  reuseLocalTokenUuids,
  utf8Decode,
  utf8Encode,
} from 'common';

/**
 * 手机↔手表 传输协议纯类测试（Phase 3，docs/TEST_PLAN.md 第 4 节）。
 *
 * 覆盖：纯 TS UTF-8 编解码（多字节/代理对/非法字节容错）、分帧构建
 * （边界切片/收尾帧标记/空载荷）、无前缀（BLE）与 OTPW 前缀（WearEngine）
 * 两种接收状态机（批次重启/非法头帧保持批次/孤儿帧/total 上限）、
 * 重组精确性与越界保护、令牌批次 UUID 复用决策、双通道端到端帧回路。
 */

const BLE_MAX_CHUNK = 480;
const BLE_MAX_TOTAL = 512 * 1024;
const WEAR_PREFIX = 'OTPW';

function bytesOf(text: string): Uint8Array {
  return utf8Encode(text);
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

function bleReceiver(): TransferFrameReceiver {
  return new TransferFrameReceiver({ headerPrefix: '', maxTotal: BLE_MAX_TOTAL } as TransferFrameOptions);
}

function wearReceiver(): TransferFrameReceiver {
  return new TransferFrameReceiver({ headerPrefix: WEAR_PREFIX, maxTotal: 0 } as TransferFrameOptions);
}

export default function transferProtocolTest() {
  describe('transferProtocolTest', () => {
    it('utf8_roundtrip_ascii_multibyte_and_emoji', 0, () => {
      const samples = ['hello', 'café', '中文令牌', 'emoji 😀🎉', 'mix中e😀文', ''];
      for (const s of samples) {
        expect(utf8Decode(utf8Encode(s))).assertEqual(s);
      }
      // 已知字节向量：'A中' = 41 E4 B8 AD；😀 = F0 9F 98 80（代理对合并）
      const a = utf8Encode('A中');
      expect([a[0], a[1], a[2], a[3]].join(',')).assertEqual('65,228,184,173');
      const e = utf8Encode('😀');
      expect([e[0], e[1], e[2], e[3]].join(',')).assertEqual('240,159,152,128');
    });

    it('utf8_decode_replaces_invalid_bytes_with_replacement_char', 0, () => {
      // 非法首字节 0xFF、截断的 2 字节序列 0xC3（缺续字节）
      const bad = new Uint8Array([0x61, 0xFF, 0xC3, 0x62]);
      const text = utf8Decode(bad);
      // 每个非法字节独立替换，不吞掉后续合法字节
      expect(text.length).assertEqual(4);
      expect(text.charCodeAt(1)).assertEqual(0xFFFD);
      expect(text.charCodeAt(3)).assertEqual('b'.charCodeAt(0));
    });

    it('utf8_decode_rejects_overlong_surrogate_and_overflow_encodings', 0, () => {
      // 过度编码 E0 80 AF（合法应为 C2 AF）：首字节边界校验拒绝
      const t1 = utf8Decode(new Uint8Array([0xE0, 0x80, 0xAF]));
      expect(t1.length).assertEqual(3);
      expect(t1.charCodeAt(0)).assertEqual(0xFFFD);
      // 代理区编码 ED A0 80（U+D800 的 CESU-8 形态）：拒绝
      const t2 = utf8Decode(new Uint8Array([0xED, 0xA0, 0x80]));
      expect(t2.length).assertEqual(3);
      // 超出 U+10FFFF 的 F4 90 80 80：拒绝
      const t3 = utf8Decode(new Uint8Array([0xF4, 0x90, 0x80, 0x80]));
      expect(t3.length).assertEqual(4);
      // 边界内仍精确解码：E0 A0 80 = U+0800（3 字节序列的最小编码），F4 8F BF BF = U+10FFFF
      expect(utf8Decode(new Uint8Array([0xE0, 0xA0, 0x80])).charCodeAt(0)).assertEqual(0x0800);
    });

    it('utf8_encode_encodes_lone_surrogate_as_replacement_char', 0, () => {
      // 孤立高代理（无后续低代理）与孤立低代理 → U+FFFD 三字节 EF BF BD（对齐 TextEncoder）
      const loneHigh = utf8Encode(String.fromCharCode(0xD800));
      expect([loneHigh[0], loneHigh[1], loneHigh[2]].join(',')).assertEqual('239,191,189');
      const loneLow = utf8Encode(String.fromCharCode(0xDC00));
      expect(loneLow.length).assertEqual(3);
      // 合法代理对不受影响（已在 roundtrip 用例覆盖），此处验证混合场景
      const mixed = utf8Encode(`${String.fromCharCode(0xD83D)}${String.fromCharCode(0xDE00)}`);
      expect(mixed.length).assertEqual(4);
    });

    it('builder_header_carries_prefix_json_and_total', 0, () => {
      const builder = new TransferFrameBuilder(WEAR_PREFIX, BLE_MAX_CHUNK);
      const header = utf8Decode(builder.buildHeaderBytes(1234, 7, 'tokens'));
      expect(header.startsWith(WEAR_PREFIX)).assertTrue();
      const parsed = JSON.parse(header.substring(WEAR_PREFIX.length)) as TransferHeader;
      expect(parsed.total).assertEqual(1234);
      expect(parsed.count).assertEqual(7);
      expect(parsed.type).assertEqual('tokens');

      // BLE 无前缀：纯 JSON
      const bleHeader = utf8Decode(new TransferFrameBuilder('', BLE_MAX_CHUNK).buildHeaderBytes(9, 1, 'settings'));
      expect(bleHeader.startsWith('{')).assertTrue();
    });

    it('builder_frames_single_chunk_marks_only_last_final', 0, () => {
      const payload = bytesOf('a'.repeat(100));
      const frames = new TransferFrameBuilder('', BLE_MAX_CHUNK).buildFrames(payload, 1, 'tokens');
      expect(frames.length).assertEqual(2);
      expect(frames[0].isFinal).assertFalse();
      expect(frames[1].isFinal).assertTrue();
      expect(bytesEqual(frames[1].bytes, payload)).assertTrue();
    });

    it('builder_frames_split_exact_multiple_and_remainder', 0, () => {
      // 整除边界：2×480 → 两片，第二片 isFinal
      const exact = new Uint8Array(BLE_MAX_CHUNK * 2);
      const frames = new TransferFrameBuilder('', BLE_MAX_CHUNK).buildFrames(exact, 2, 'tokens');
      expect(frames.length).assertEqual(3);
      expect(frames[1].bytes.length).assertEqual(BLE_MAX_CHUNK);
      expect(frames[1].isFinal).assertFalse();
      expect(frames[2].isFinal).assertTrue();

      // 余数：2×480+100 → 480/480/100
      const rem = new Uint8Array(BLE_MAX_CHUNK * 2 + 100);
      const frames2 = new TransferFrameBuilder('', BLE_MAX_CHUNK).buildFrames(rem, 2, 'tokens');
      expect(frames2.length).assertEqual(4);
      expect(frames2[3].bytes.length).assertEqual(100);
      expect(frames2[2].isFinal).assertFalse();
      expect(frames2[3].isFinal).assertTrue();
    });

    it('builder_empty_payload_produces_header_only', 0, () => {
      const frames = new TransferFrameBuilder('', BLE_MAX_CHUNK).buildFrames(new Uint8Array(0), 0, 'tokens');
      expect(frames.length).assertEqual(1);
      expect(frames[0].isFinal).assertFalse();
    });

    it('ble_receiver_full_batch_lifecycle_with_type_default', 0, () => {
      const receiver = bleReceiver();
      const payload = new Uint8Array(700); // 两片
      const frames = new TransferFrameBuilder('', BLE_MAX_CHUNK).buildFrames(payload, 3, 'tokens');

      let e = receiver.onFrame(frames[0].bytes);
      expect(e.kind).assertEqual(TransferFrameEventKind.BATCH_STARTED);
      expect(receiver.isInProgress()).assertTrue();

      e = receiver.onFrame(frames[1].bytes);
      expect(e.kind).assertEqual(TransferFrameEventKind.CHUNK_ACCEPTED);

      e = receiver.onFrame(frames[2].bytes);
      expect(e.kind).assertEqual(TransferFrameEventKind.BATCH_COMPLETE);
      const batch: TransferBatch = e.batch!;
      expect(batch.total).assertEqual(700);
      expect(batch.count).assertEqual(3);
      expect(batch.type).assertEqual('tokens');
      expect(batch.receivedBytes).assertEqual(700);
      expect(bytesEqual(concatenateChunks(batch.total, batch.chunks), payload)).assertTrue();
      // 收齐后状态自动复位，可立即开新批次
      expect(receiver.isInProgress()).assertFalse();
    });

    it('ble_receiver_defaults_type_to_tokens_for_legacy_header', 0, () => {
      const receiver = bleReceiver();
      // 旧版发送端头帧无 type 字段
      receiver.onFrame(bytesOf('{"total":2,"count":1}'));
      const done = receiver.onFrame(new Uint8Array([1, 2]));
      expect(done.kind).assertEqual(TransferFrameEventKind.BATCH_COMPLETE);
      expect(done.batch!.type).assertEqual('tokens');
    });

    it('ble_receiver_rejects_invalid_headers_as_orphan_frames', 0, () => {
      const receiver = bleReceiver();
      // 乱码（解密分片误当头帧）
      expect(receiver.onFrame(new Uint8Array([0x00, 0xFF, 0x37])).kind)
        .assertEqual(TransferFrameEventKind.ORPHAN_CHUNK);
      // JSON 标量 total=0 / 负数 / 超上限 / 非数值 total 均拒绝
      expect(receiver.onFrame(bytesOf('{"total":0,"count":1}')).kind)
        .assertEqual(TransferFrameEventKind.ORPHAN_CHUNK);
      expect(receiver.onFrame(bytesOf('{"total":-5,"count":1}')).kind)
        .assertEqual(TransferFrameEventKind.ORPHAN_CHUNK);
      expect(receiver.onFrame(bytesOf(`{"total":${BLE_MAX_TOTAL + 1},"count":1}`)).kind)
        .assertEqual(TransferFrameEventKind.ORPHAN_CHUNK);
      expect(receiver.onFrame(bytesOf('{"total":"5","count":1}')).kind)
        .assertEqual(TransferFrameEventKind.ORPHAN_CHUNK);
      expect(receiver.isInProgress()).assertFalse();
    });

    it('ble_receiver_discards_stale_batch_when_new_header_arrives', 0, () => {
      const receiver = bleReceiver();
      receiver.onFrame(bytesOf('{"total":100,"count":1,"type":"tokens"}'));
      receiver.onFrame(new Uint8Array(10));
      // 批次中途新头帧：残留分片丢弃，干净重启
      const e = receiver.onFrame(bytesOf('{"total":3,"count":1,"type":"settings"}'));
      expect(e.kind).assertEqual(TransferFrameEventKind.BATCH_STARTED);
      const done = receiver.onFrame(new Uint8Array([7, 8, 9]));
      expect(done.kind).assertEqual(TransferFrameEventKind.BATCH_COMPLETE);
      expect(done.batch!.receivedBytes).assertEqual(3);
      expect(done.batch!.type).assertEqual('settings');
    });

    it('wear_receiver_prefix_discriminates_header_and_ignores_orphans', 0, () => {
      const receiver = wearReceiver();
      // 无前缀数据帧且无批次 → 孤儿帧静默（WearEngine 语义）
      expect(receiver.onFrame(new Uint8Array([1, 2, 3])).kind)
        .assertEqual(TransferFrameEventKind.ORPHAN_CHUNK);
      // 比前缀还短的帧同样安全
      expect(receiver.onFrame(new Uint8Array([0x4F])).kind)
        .assertEqual(TransferFrameEventKind.ORPHAN_CHUNK);

      const builder = new TransferFrameBuilder(WEAR_PREFIX, 4000);
      const payload = new Uint8Array(4001); // 跨两帧
      const frames = builder.buildFrames(payload, 1, 'tokens');
      expect(receiver.onFrame(frames[0].bytes).kind).assertEqual(TransferFrameEventKind.BATCH_STARTED);
      expect(receiver.onFrame(frames[1].bytes).kind).assertEqual(TransferFrameEventKind.CHUNK_ACCEPTED);
      const done = receiver.onFrame(frames[2].bytes);
      expect(done.kind).assertEqual(TransferFrameEventKind.BATCH_COMPLETE);
      expect(done.batch!.total).assertEqual(4001);
      expect(bytesEqual(concatenateChunks(done.batch!.total, done.batch!.chunks), payload)).assertTrue();
    });

    it('wear_receiver_invalid_header_keeps_batch_and_restarts_on_valid', 0, () => {
      const receiver = wearReceiver();
      receiver.onFrame(bytesOf(`${WEAR_PREFIX}{"total":10,"count":1,"type":"tokens"}`));
      receiver.onFrame(new Uint8Array(4));
      // 非法头帧（total≤0 / 非 JSON）：批次保持不触碰。
      // 注意：这是对 WearEngine 旧实现的有意收口——旧代码对 total≤0 静默忽略（批次保留），
      // 但 JSON 解析抛错会落入外层 catch 重置批次致传输挂死；新实现统一为无副作用忽略。
      expect(receiver.onFrame(bytesOf(`${WEAR_PREFIX}{"total":0,"count":1}`)).kind)
        .assertEqual(TransferFrameEventKind.HEADER_INVALID);
      expect(receiver.onFrame(bytesOf(`${WEAR_PREFIX}not-json`)).kind)
        .assertEqual(TransferFrameEventKind.HEADER_INVALID);
      expect(receiver.isInProgress()).assertTrue();
      // 原批次仍可继续收齐：4 + 6 = 10
      const done = receiver.onFrame(new Uint8Array(6));
      expect(done.kind).assertEqual(TransferFrameEventKind.BATCH_COMPLETE);
      expect(done.batch!.receivedBytes).assertEqual(10);
    });

    it('receiver_completes_on_overshoot_and_surfaces_received_bytes', 0, () => {
      // 收齐判定为 received >= total：超量投递时完成事件带真实字节数，
      // 精确性校验由通道层的 receivedBytes !== total 分支承担（判失败丢弃）
      const receiver = bleReceiver();
      receiver.onFrame(bytesOf('{"total":4,"count":1,"type":"tokens"}'));
      const done = receiver.onFrame(new Uint8Array(9));
      expect(done.kind).assertEqual(TransferFrameEventKind.BATCH_COMPLETE);
      expect(done.batch!.receivedBytes).assertEqual(9);
      expect(done.batch!.total).assertEqual(4);
    });

    it('wear_receiver_accepts_unlimited_total_and_restarts_mid_batch', 0, () => {
      const receiver = wearReceiver();
      // maxTotal=0 不设上限（P2P 头帧无上限校验）
      const e = receiver.onFrame(bytesOf(`${WEAR_PREFIX}{"total":99999999,"count":1,"type":"tokens"}`));
      expect(e.kind).assertEqual(TransferFrameEventKind.BATCH_STARTED);
      // 批次中途新头帧重启
      const restart = receiver.onFrame(bytesOf(`${WEAR_PREFIX}{"total":1,"count":1,"type":"tokens"}`));
      expect(restart.kind).assertEqual(TransferFrameEventKind.BATCH_STARTED);
      const done = receiver.onFrame(new Uint8Array([9]));
      expect(done.kind).assertEqual(TransferFrameEventKind.BATCH_COMPLETE);
      expect(done.batch!.receivedBytes).assertEqual(1);
    });

    it('receiver_reset_drops_pending_batch', 0, () => {
      const receiver = bleReceiver();
      receiver.onFrame(bytesOf('{"total":100,"count":1,"type":"tokens"}'));
      receiver.reset();
      expect(receiver.isInProgress()).assertFalse();
      // 复位后数据帧成为孤儿帧
      expect(receiver.onFrame(new Uint8Array(5)).kind).assertEqual(TransferFrameEventKind.ORPHAN_CHUNK);
    });

    it('concatenate_chunks_underfill_pads_and_overflow_throws', 0, () => {
      // 分片不足 total：缓冲区按 total 分配，尾部补零（与抽离前实现一致）
      const short = concatenateChunks(5, [new Uint8Array([1, 2])]);
      expect(short.length).assertEqual(5);
      expect([short[0], short[1], short[4]].join(',')).assertEqual('1,2,0');
      // 分片超出 total：set 越界抛异常（交叠写入保护路径）
      let threw = false;
      try {
        concatenateChunks(2, [new Uint8Array([1, 2, 3])]);
      } catch (err) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    it('reuse_local_token_uuids_matches_issuer_and_name', 0, () => {
      const local1 = new TokenConfig('SECRET1', otpType.TOTP, 'GitHub', 'github');
      local1.TokenUUID = 'local-uuid-1';
      const local2 = new TokenConfig('SECRET2', otpType.TOTP, 'GitLab', 'gitlab');
      local2.TokenUUID = 'local-uuid-2';

      const incoming1 = new TokenConfig('SECRET1', otpType.TOTP, 'GitHub', 'github');
      incoming1.TokenUUID = 'device-uuid-x';
      const incoming2 = new TokenConfig('SECRET3', otpType.TOTP, 'NewService', 'new');
      incoming2.TokenUUID = 'device-uuid-y';
      const incoming3 = new TokenConfig('SECRET9', otpType.TOTP, 'GitHub', 'gitee'); // issuer 不同不复用
      incoming3.TokenUUID = 'device-uuid-z';

      const reused = reuseLocalTokenUuids([incoming1, incoming2, incoming3], [local1, local2]);
      expect(reused).assertEqual(1);
      expect(incoming1.TokenUUID).assertEqual('local-uuid-1');
      expect(incoming2.TokenUUID).assertEqual('device-uuid-y');
      expect(incoming3.TokenUUID).assertEqual('device-uuid-z');
      // 同 issuer+name 多本地匹配取第一个
      const dup = new TokenConfig('SECRET1', otpType.TOTP, 'GitHub', 'github');
      dup.TokenUUID = 'device-uuid-z';
      expect(reuseLocalTokenUuids([dup], [local1, local2])).assertEqual(1);
      expect(dup.TokenUUID).assertEqual('local-uuid-1');
      // 空批次
      expect(reuseLocalTokenUuids([], [])).assertEqual(0);
    });

    it('end_to_end_ble_frames_reassemble_to_original_payload', 0, () => {
      // 加密载荷模拟：随机字节 1000 字节（跨三片）
      const cipher = new Uint8Array(1000);
      for (let i = 0; i < cipher.length; i++) {
        cipher[i] = (i * 31 + 7) % 256;
      }
      const sender = new TransferFrameBuilder('', BLE_MAX_CHUNK);
      const receiver = bleReceiver();
      let batch: TransferBatch | null = null;
      for (const frame of sender.buildFrames(cipher, 5, 'tokens')) {
        const e = receiver.onFrame(frame.bytes);
        if (e.kind === TransferFrameEventKind.BATCH_COMPLETE) {
          batch = e.batch;
        }
      }
      expect(batch !== null).assertTrue();
      expect(bytesEqual(concatenateChunks(batch!.total, batch!.chunks), cipher)).assertTrue();
    });

    it('end_to_end_wear_frames_reassemble_with_settings_type', 0, () => {
      const cipher = new Uint8Array(5200);
      for (let i = 0; i < cipher.length; i++) {
        cipher[i] = (i * 17) % 256;
      }
      const sender = new TransferFrameBuilder(WEAR_PREFIX, 4000);
      const receiver = wearReceiver();
      let batch: TransferBatch | null = null;
      for (const frame of sender.buildFrames(cipher, 26, 'settings')) {
        const e = receiver.onFrame(frame.bytes);
        if (e.kind === TransferFrameEventKind.BATCH_COMPLETE) {
          batch = e.batch;
        }
      }
      expect(batch !== null).assertTrue();
      expect(batch!.type).assertEqual('settings');
      expect(batch!.count).assertEqual(26);
      expect(bytesEqual(concatenateChunks(batch!.total, batch!.chunks), cipher)).assertTrue();
    });
  });
}
