import { KvBatchEntry, LegacyTokenKv, TransactionalKv } from './StoragePorts';
import { TokenBatchProgressCallback, TokenBatchStage, reportTokenBatchProgress } from './TokenBatchProgress';

/** 平台单次批量写入上限（distributedKVStore.putBatch/deleteBatch 限制）。 */
const MAX_BATCH_SIZE = 128;

/** 旧版本令牌存储的键前缀（Phase 2 之前的历史格式）。 */
const LEGACY_PREFIX = '$.SA_token_uuids_';

/**
 * 事务内分块提交令牌批量写入：按 MAX_BATCH_SIZE 分块 put/delete，
 * 全部成功后 commit；任一步失败 rollback 并向上抛错（调用方据此回滚内存状态）。
 * 从 KvManager.saveTokenBatch 抽出，事务原语经 {@link TransactionalKv} 端口注入。
 */
export async function commitTokenBatchInChunks(store: TransactionalKv, entries: KvBatchEntry[],
  deleteKeys: string[], onProgress?: TokenBatchProgressCallback): Promise<void> {
  if (entries.length === 0 && deleteKeys.length === 0) {
    return;
  }
  const total = entries.length + deleteKeys.length;
  reportTokenBatchProgress(onProgress, TokenBatchStage.SAVING, 0, total);
  await store.startTransaction();
  try {
    for (let offset = 0; offset < entries.length; offset += MAX_BATCH_SIZE) {
      await store.putBatch(entries.slice(offset, offset + MAX_BATCH_SIZE));
      reportTokenBatchProgress(onProgress, TokenBatchStage.SAVING,
        Math.min(offset + MAX_BATCH_SIZE, entries.length), total);
    }
    for (let offset = 0; offset < deleteKeys.length; offset += MAX_BATCH_SIZE) {
      await store.deleteBatch(deleteKeys.slice(offset, offset + MAX_BATCH_SIZE));
      reportTokenBatchProgress(onProgress, TokenBatchStage.SAVING,
        entries.length + Math.min(offset + MAX_BATCH_SIZE, deleteKeys.length), total);
    }
    reportTokenBatchProgress(onProgress, TokenBatchStage.COMMITTING);
    await store.commit();
  } catch (error) {
    reportTokenBatchProgress(onProgress, TokenBatchStage.ROLLING_BACK);
    await store.rollback();
    throw error instanceof Error ? error : new Error(String(error));
  }
}

/**
 * 旧版本令牌存储迁移：`$.SA_token_uuids_{uuid}` 列表键 + `token_{uuid}` 值键
 * → `{newPrefix}{uuid}`。逐条搬运并删除旧键；失败由调用方容忍（下次加载重试）。
 * 从 KvManager.getTokenArray 抽出，KV 读写经 {@link LegacyTokenKv} 端口注入。
 */
export async function migrateLegacyTokenEntries(kv: LegacyTokenKv, newPrefix: string): Promise<void> {
  const oldEntries = await kv.getRawEntries(LEGACY_PREFIX);
  for (let i = 0; i < oldEntries.length; i++) {
    const oldKey = oldEntries[i].key;
    await kv.deleteValue(oldKey);
    const oldTokenUuid = oldKey.substring(LEGACY_PREFIX.length);
    const oldTokenKey = 'token_' + oldTokenUuid;
    const oldTokenValue = await kv.getString(oldTokenKey);
    await kv.setString(newPrefix + oldTokenUuid, oldTokenValue ?? '');
    await kv.deleteValue(oldTokenKey);
  }
}
