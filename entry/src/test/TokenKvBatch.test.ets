import { describe, it, expect } from '@ohos/hypium';
import {
  KvBatchEntry,
  TokenBatchProgress,
  TokenBatchStage,
  commitTokenBatchInChunks,
  migrateLegacyTokenEntries,
} from 'common';
import { MemoryLegacyKv, MemoryTransactionalKv } from './fakes/BackupFakes';

/**
 * 令牌 KV 批量提交与旧版本迁移测试（Phase 2 从 KvManager 抽出的编排逻辑）。
 *
 * 覆盖：128 分块、事务提交/回滚、空批量短路、进度回调序列、
 * `$.SA_token_uuids_` 旧前缀 → 新前缀的逐条迁移。
 */

interface RecordedProgress {
  stage: number;
  current: number;
  total: number;
}

function makeEntries(count: number): KvBatchEntry[] {
  const out: KvBatchEntry[] = [];
  for (let i = 0; i < count; i++) {
    const entry: KvBatchEntry = { key: `key_${i}`, value: `value_${i}` };
    out.push(entry);
  }
  return out;
}

export default function tokenKvBatchTest() {
  describe('tokenKvBatchTest', () => {
    it('commit_persists_entries_and_deletes_in_transaction', 0, async () => {
      const kv = new MemoryTransactionalKv();
      const entries = makeEntries(3);

      await commitTokenBatchInChunks(kv, entries, ['gone_1', 'gone_2']);

      expect(kv.startCount).assertEqual(1);
      expect(kv.commitCount).assertEqual(1);
      expect(kv.rollbackCount).assertEqual(0);
      expect(kv.committed.get('key_0')).assertEqual('value_0');
      expect(kv.committed.get('key_2')).assertEqual('value_2');
      expect(kv.committed.has('gone_1')).assertFalse();
      expect(kv.committed.has('gone_2')).assertFalse();
    });

    it('commit_chunks_batches_at_128', 0, async () => {
      const kv = new MemoryTransactionalKv();

      await commitTokenBatchInChunks(kv, makeEntries(300), []);

      // 300 = 128 + 128 + 44
      expect(kv.putBatchCalls.length).assertEqual(3);
      expect(kv.putBatchCalls[0].length).assertEqual(128);
      expect(kv.putBatchCalls[1].length).assertEqual(128);
      expect(kv.putBatchCalls[2].length).assertEqual(44);

      // 删除同样分块：257 个 key = 128 + 128 + 1
      const kv2 = new MemoryTransactionalKv();
      const deleteKeys: string[] = [];
      for (let i = 0; i < 257; i++) {
        deleteKeys.push(`del_${i}`);
      }
      await commitTokenBatchInChunks(kv2, [], deleteKeys);
      expect(kv2.deleteBatchCalls.length).assertEqual(3);
      expect(kv2.deleteBatchCalls[2].length).assertEqual(1);
    });

    it('empty_batch_is_noop_without_transaction', 0, async () => {
      const kv = new MemoryTransactionalKv();

      await commitTokenBatchInChunks(kv, [], []);

      expect(kv.startCount).assertEqual(0);
      expect(kv.commitCount).assertEqual(0);
    });

    it('failure_rolls_back_and_rethrows_with_nothing_committed', 0, async () => {
      const kv = new MemoryTransactionalKv();
      // 第二个分块（下标 1）失败
      kv.failPutBatchAt = 1;

      let threw = false;
      try {
        await commitTokenBatchInChunks(kv, makeEntries(200), []);
      } catch (e) {
        threw = (e as Error).message === 'putBatch failed';
      }
      expect(threw).assertTrue();
      expect(kv.rollbackCount).assertEqual(1);
      expect(kv.commitCount).assertEqual(0);
      expect(kv.committed.size).assertEqual(0);
    });

    it('progress_reports_saving_committing_sequence', 0, async () => {
      const kv = new MemoryTransactionalKv();
      const progress: RecordedProgress[] = [];

      await commitTokenBatchInChunks(kv, makeEntries(2), [], (item: TokenBatchProgress): void => {
        progress.push({ stage: item.stage, current: item.completed, total: item.total });
      });

      // 首条 SAVING 0/2；随后 SAVING 2/2；COMMITTING 收尾
      expect(progress.length >= 3).assertTrue();
      expect(progress[0].stage).assertEqual(TokenBatchStage.SAVING);
      expect(progress[0].current).assertEqual(0);
      expect(progress[0].total).assertEqual(2);
      expect(progress[1].current).assertEqual(2);
      const lastStage = progress[progress.length - 1].stage;
      expect(lastStage).assertEqual(TokenBatchStage.COMMITTING);
    });

    it('progress_reports_rolling_back_on_failure', 0, async () => {
      const kv = new MemoryTransactionalKv();
      kv.failPutBatchAt = 0;
      const progress: RecordedProgress[] = [];

      try {
        await commitTokenBatchInChunks(kv, makeEntries(1), [], (item: TokenBatchProgress): void => {
          progress.push({ stage: item.stage, current: item.completed, total: item.total });
        });
      } catch (e) {
        // 预期失败
      }
      const lastStage = progress[progress.length - 1].stage;
      expect(lastStage).assertEqual(TokenBatchStage.ROLLING_BACK);
    });

    it('legacy_migration_moves_old_prefix_to_new_and_cleans_up', 0, async () => {
      const kv = new MemoryLegacyKv();
      kv.entries.set('$.SA_token_uuids_uuid-a', '$.SA_token_uuids_uuid-a');
      kv.entries.set('token_uuid-a', '{"TokenUUID":"uuid-a"}');
      kv.entries.set('$.SA_token_uuids_uuid-b', '$.SA_token_uuids_uuid-b');
      // token_uuid-b 的值缺失 → 迁移为空串
      kv.entries.set('untouched', 'keep');

      await migrateLegacyTokenEntries(kv, '_token_uuid_');

      // 新键写入
      expect(kv.entries.get('_token_uuid_uuid-a')).assertEqual('{"TokenUUID":"uuid-a"}');
      expect(kv.entries.get('_token_uuid_uuid-b')).assertEqual('');
      // 旧键全部清理
      expect(kv.entries.has('$.SA_token_uuids_uuid-a')).assertFalse();
      expect(kv.entries.has('$.SA_token_uuids_uuid-b')).assertFalse();
      expect(kv.entries.has('token_uuid-a')).assertFalse();
      // 无关键不动
      expect(kv.entries.get('untouched')).assertEqual('keep');
    });

    it('legacy_migration_without_legacy_keys_is_noop', 0, async () => {
      const kv = new MemoryLegacyKv();
      kv.entries.set('_token_uuid_existing', 'x');

      await migrateLegacyTokenEntries(kv, '_token_uuid_');
      expect(kv.entries.size).assertEqual(1);
    });
  });
}
