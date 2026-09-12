import { describe, it, expect } from '@ohos/hypium';
import { util } from '@kit.ArkTS';
import {
  decryptBlePayload,
  encryptBlePayload,
  TransferFrameBuilder,
  TransferFrameEventKind,
  TransferFrameOptions,
  TransferFrameReceiver,
  concatenateChunks,
  utf8Decode,
  utf8Encode,
} from 'common';

/**
 * 真机 BLE 传输通道冒烟（Phase 3，docs/TEST_PLAN.md 第 4 节出口条件）。
 *
 * GATT 扫描/配对/写入部分归手工与页面联调；本套件在真机验证通道两端都依赖的
 * 生产密码学与协议纯类：AES-256-GCM 载荷加解密回路、篡改载荷被拒、
 * 分帧→重组回路在真机字节序下无损、纯 TS UTF-8 与系统 TextEncoder 一致。
 */

const BLE_MAX_CHUNK = 480;

function bleReceiver(): TransferFrameReceiver {
  return new TransferFrameReceiver({ headerPrefix: '', maxTotal: 512 * 1024 } as TransferFrameOptions);
}

export default function bleTransferSmokeTest(): void {
  describe('BleTransferSmokeDeviceTest', () => {
    it('ble_payload_encrypt_decrypt_roundtrip', 0, async () => {
      // 生产 AES-256-GCM（[MAGIC][iv][tag][ciphertext]）加解密回路
      const plain = utf8Encode('{"total":1,"tokens":[{"TokenSecret":"device-secret"}]}');
      const sealed = await encryptBlePayload(plain);
      // 密文比明文长（MAGIC+iv+tag 开销）
      expect(sealed.byteLength > plain.byteLength).assertTrue();

      const opened = await decryptBlePayload(sealed);
      expect(opened !== null).assertTrue();
      expect(utf8Decode(opened!)).assertEqual('{"total":1,"tokens":[{"TokenSecret":"device-secret"}]}');
    });

    it('ble_payload_tamper_is_rejected_by_gcm_tag', 0, async () => {
      const plain = utf8Encode('tamper-detection-payload');
      const sealed = await encryptBlePayload(plain);
      // 翻转密文尾部一个字节 → GCM tag 校验必须失败（返回 null，丢弃且不入库）
      const tampered = sealed.slice();
      tampered[tampered.length - 1] = (tampered[tampered.length - 1] ^ 0x01) & 0xFF;
      const opened = await decryptBlePayload(tampered);
      expect(opened === null).assertTrue();
    });

    it('ble_frame_protocol_roundtrip_on_device', 0, async () => {
      // 分帧→重组回路：1000 字节载荷跨三片，验证真机字节序下协议无损
      const cipher = new Uint8Array(1000);
      for (let i = 0; i < cipher.length; i++) {
        cipher[i] = (i * 31 + 7) % 256;
      }
      const frames = new TransferFrameBuilder('', BLE_MAX_CHUNK).buildFrames(cipher, 5, 'tokens');
      const receiver = bleReceiver();
      let done = false;
      let batchTotal = -1;
      let byteIdentical = true;
      const chunks: Array<Uint8Array> = [];
      for (let i = 0; i < frames.length; i++) {
        const event = receiver.onFrame(frames[i].bytes);
        if (event.kind === TransferFrameEventKind.BATCH_COMPLETE) {
          done = true;
          batchTotal = event.batch!.total;
          for (let j = 0; j < event.batch!.chunks.length; j++) {
            chunks.push(event.batch!.chunks[j]);
          }
        }
      }
      const reassembled = done ? concatenateChunks(batchTotal, chunks) : new Uint8Array(0);
      for (let i = 0; i < cipher.length; i++) {
        if (reassembled[i] !== cipher[i]) {
          byteIdentical = false;
          break;
        }
      }
      expect(done).assertTrue();
      expect(batchTotal).assertEqual(1000);
      expect(byteIdentical).assertTrue();
    });

    it('pure_ts_utf8_matches_system_text_encoder', 0, () => {
      // 纯 TS UTF-8 与系统 util.TextEncoder 字节级一致（含多字节）
      const samples = ['OHOTP', '中文令牌抽象', 'emoji 😀'];
      const encoder = new util.TextEncoder();
      for (const s of samples) {
        const sys = encoder.encodeInto(s);
        const own = utf8Encode(s);
        expect(own.length).assertEqual(sys.length);
        let same = true;
        for (let i = 0; i < own.length; i++) {
          if (own[i] !== sys[i]) {
            same = false;
            break;
          }
        }
        expect(same).assertTrue();
      }
    });
  });
}
