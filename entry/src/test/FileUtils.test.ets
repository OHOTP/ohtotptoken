import { describe, it, expect } from '@ohos/hypium';
import {
  ChunkedTextReader,
  constantTimeCompare,
  HashCompareWriteIo,
  readTextViaChunks,
  writeTextIfHashDiffers,
} from 'common';

/**
 * FileUtils 可测核心测试（Phase 2 抽出的分块读取与哈希防重写入）。
 * fs/cryptoFramework 真机部分不在 LocalUnit 覆盖范围。
 */

const BUFFER_SIZE = 4096;

/** 按预定块大小依次返回内容的假读取器（写入真实字节，供拼接契约断言） */
class ScriptedReader implements ChunkedTextReader {
  private chunks: number[] = [];
  private content: string;
  private callIndex: number = 0;
  private buffer: ArrayBuffer = new ArrayBuffer(BUFFER_SIZE);
  closed: boolean = false;
  readCalls: number = 0;

  constructor(content: string, chunks: number[]) {
    this.content = content;
    this.chunks = chunks;
  }

  readChunk(offset: number): number {
    const size = this.chunks[this.callIndex];
    this.callIndex++;
    this.readCalls++;
    const view = new Uint8Array(this.buffer);
    for (let i = 0; i < size && i < view.length; i++) {
      view[i] = this.content.charCodeAt(offset + i) & 0xFF;
    }
    return size;
  }

  chunkBuffer(): ArrayBuffer {
    return this.buffer;
  }

  close(): void {
    this.closed = true;
  }
}

class MemoryHashIo implements HashCompareWriteIo {
  files: Map<string, string> = new Map();
  writeCalls: string[] = [];

  fileExists(uri: string): Promise<boolean> {
    return Promise.resolve(this.files.has(uri));
  }

  readText(uri: string): Promise<string> {
    const content = this.files.get(uri);
    if (content === undefined) {
      return Promise.reject(new Error('missing'));
    }
    return Promise.resolve(content);
  }

  writeText(uri: string, content: string): Promise<void> {
    this.writeCalls.push(uri);
    this.files.set(uri, content);
    return Promise.resolve();
  }
}

/** 确定性假哈希：字节和（区分度足够触发同/异分支） */
async function fakeHash(content: string): Promise<Uint8Array> {
  let sum = 0;
  for (let i = 0; i < content.length; i++) {
    sum = (sum + content.charCodeAt(i)) % 65536;
  }
  const out = new Uint8Array(2);
  out[0] = sum >> 8;
  out[1] = sum & 0xFF;
  return out;
}

export default function fileUtilsTest() {
  describe('fileUtilsTest', () => {
    it('read_via_chunks_concatenates_all_blocks_in_order', 0, async () => {
      // 第一块读满 4096 + 第二块部分读取：拼接必须保序且无丢失
      const part1 = 'a'.repeat(BUFFER_SIZE);
      const part2 = 'bc'.repeat(50);
      const reader = new ScriptedReader(part1 + part2, [BUFFER_SIZE, part2.length]);
      const content = await readTextViaChunks(reader);
      expect(content).assertEqual(part1 + part2);
      expect(reader.readCalls).assertEqual(2);
      expect(reader.closed).assertTrue();
    });

    it('read_via_chunks_single_partial_block_reads_once', 0, async () => {
      const reader = new ScriptedReader('short file', [10]);
      const content = await readTextViaChunks(reader);
      expect(content).assertEqual('short file');
      expect(reader.readCalls).assertEqual(1);
      expect(reader.closed).assertTrue();
    });

    it('read_via_chunks_exact_multiple_reads_one_extra_empty_block', 0, async () => {
      // 恰好整块：还需一次额外读取得到 0 才终止；内容不重复
      const part1 = 'x'.repeat(BUFFER_SIZE);
      const reader = new ScriptedReader(part1, [BUFFER_SIZE, 0]);
      const content = await readTextViaChunks(reader);
      expect(content).assertEqual(part1);
      expect(reader.readCalls).assertEqual(2);
      expect(reader.closed).assertTrue();
    });

    it('constant_time_compare_behaves_like_equality', 0, () => {
      const a = new Uint8Array([1, 2, 3]);
      const b = new Uint8Array([1, 2, 3]);
      const c = new Uint8Array([1, 2, 4]);
      const d = new Uint8Array([1, 2]);

      expect(constantTimeCompare(a, b)).assertTrue();
      expect(constantTimeCompare(a, c)).assertFalse();
      expect(constantTimeCompare(a, d)).assertFalse();
      expect(constantTimeCompare(new Uint8Array(0), new Uint8Array(0))).assertTrue();
    });

    it('write_if_hash_differs_skips_identical_content', 0, async () => {
      const io = new MemoryHashIo();
      io.files.set('memory://f.txt', 'stable content');

      await writeTextIfHashDiffers(io, fakeHash, 'memory://f.txt', 'stable content');
      expect(io.writeCalls.length).assertEqual(0);
      expect(io.files.get('memory://f.txt')).assertEqual('stable content');
    });

    it('write_if_hash_differs_writes_on_change_and_when_missing', 0, async () => {
      const io = new MemoryHashIo();

      // 文件不存在 → 直接写
      await writeTextIfHashDiffers(io, fakeHash, 'memory://f.txt', 'v1');
      expect(io.writeCalls.length).assertEqual(1);

      // 内容变化 → 覆盖
      await writeTextIfHashDiffers(io, fakeHash, 'memory://f.txt', 'v2');
      expect(io.writeCalls.length).assertEqual(2);
      expect(io.files.get('memory://f.txt')).assertEqual('v2');
    });
  });
}
