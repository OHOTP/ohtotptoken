import { describe, it, expect } from '@ohos/hypium';
import {
  AppPreference,
  PREF_KEYS,
  otpType,
  SteamAuth,
  TokenGroup,
  TokenConfig,
  TokenGroupStore,
  TokenStore,
} from 'common';
import { MemoryNamedSecretStore, MemorySecretStore, MemoryTokenKv } from './fakes/BackupFakes';
import { SteamSecretStore } from 'common';

/**
 * TokenStore 纯逻辑测试（Phase 2 端口注入：KeyValueStore + SecretStore + Steam 后端）。
 *
 * 覆盖高风险清单首位的迁移决策（ASSET 三重验证的每个失败分支）、
 * KV 双写/降级语义、持久化编排（Rank/收藏/脱敏）与删除重排。
 * distributedKVStore/asset 均被内存假实现替换。
 */

const TOKEN_PREFIX = '_token_uuid_';

function makeToken(uuid: string, secret: string, rank: number = 0, type: otpType = otpType.TOTP): TokenConfig {
  const token = new TokenConfig(secret, type);
  token.TokenUUID = uuid;
  token.RankScore = rank;
  return token;
}

function putTokenInKv(kv: MemoryTokenKv, token: TokenConfig): void {
  kv.entries.set(`${TOKEN_PREFIX}${token.TokenUUID}`, JSON.stringify(token));
}

/** 重绑全部端口并清空迁移标记，隔离用例间污染 */
function freshStore(): TokenStore {
  const kv = new MemoryTokenKv();
  const secrets = new MemorySecretStore();
  const store = TokenStore.getInstance();
  store.useBackendsForTest(kv, secrets);
  TokenGroupStore.getInstance().useKvBackendForTest(kv);
  AppPreference.setPreference(PREF_KEYS.ASSET_MIGRATION_DONE, false);
  return store;
}

/** 迁移已完成标记 */
function setMigrationDone(done: boolean): void {
  AppPreference.setPreference(PREF_KEYS.ASSET_MIGRATION_DONE, done);
}

function migrationDone(): boolean {
  return AppPreference.getPreference(PREF_KEYS.ASSET_MIGRATION_DONE) === true;
}

export default function tokenStoreTest() {
  describe('tokenStoreTest', () => {
    it('initTokenStore_initializes_kv_and_loads', 0, async () => {
      const kv = new MemoryTokenKv();
      const store = TokenStore.getInstance();
      store.useBackendsForTest(kv, new MemorySecretStore());
      TokenGroupStore.getInstance().useKvBackendForTest(kv);
      setMigrationDone(false);

      await store.initTokenStore();
      expect(kv.initCalls).assertEqual(1);
      // 重复调用幂等：底层 init 不再触发
      await store.initTokenStore();
      expect(kv.initCalls).assertEqual(1);
    });

    it('migration_flag_set_true_skips_all_asset_io', 0, async () => {
      const kv = new MemoryTokenKv();
      const secrets = new MemorySecretStore();
      putTokenInKv(kv, makeToken('u1', 'JBSWY3DPEHPK3PXP'));
      const store = TokenStore.getInstance();
      store.useBackendsForTest(kv, secrets);
      TokenGroupStore.getInstance().useKvBackendForTest(kv);
      setMigrationDone(true);

      await store.LoadTokenByDataBase();
      const tokens = await store.getTokens();
      expect(tokens.length).assertEqual(1);
      // 标记已置位：零 ASSET 调用（含批量预查）
      expect(secrets.upsertCalls.length).assertEqual(0);
      expect(secrets.batchQueryCalls).assertEqual(0);
      expect(migrationDone()).assertTrue();
    });

    it('migration_empty_token_list_sets_flag_directly', 0, async () => {
      const store = freshStore();
      expect(migrationDone()).assertFalse();

      await store.LoadTokenByDataBase();
      expect(migrationDone()).assertTrue();
    });

    it('migration_asset_already_has_secret_wins_over_kv', 0, async () => {
      const kv = new MemoryTokenKv();
      const secrets = new MemorySecretStore();
      putTokenInKv(kv, makeToken('u1', 'kv_secret'));
      secrets.secrets.set('u1', 'asset_secret');
      const store = TokenStore.getInstance();
      store.useBackendsForTest(kv, secrets);
      TokenGroupStore.getInstance().useKvBackendForTest(kv);
      setMigrationDone(false);

      await store.LoadTokenByDataBase();
      const tokens = await store.getTokens();
      expect(tokens[0].TokenSecret).assertEqual('asset_secret');
      expect(secrets.upsertCalls.length).assertEqual(0);
      expect(migrationDone()).assertTrue();
    });

    it('migration_kv_only_secret_triple_verified_and_copied_to_asset', 0, async () => {
      const kv = new MemoryTokenKv();
      const secrets = new MemorySecretStore();
      putTokenInKv(kv, makeToken('u1', 'kv_only_secret'));
      const store = TokenStore.getInstance();
      store.useBackendsForTest(kv, secrets);
      TokenGroupStore.getInstance().useKvBackendForTest(kv);
      setMigrationDone(false);

      await store.LoadTokenByDataBase();
      // 三重验证：upsert 一次 + 查询一致；KV 保留不动（双写）
      expect(secrets.upsertCalls.length).assertEqual(1);
      expect(secrets.upsertCalls[0]).assertEqual('u1');
      expect(secrets.secrets.get('u1')).assertEqual('kv_only_secret');
      const tokens = await store.getTokens();
      expect(tokens[0].TokenSecret).assertEqual('kv_only_secret');
      expect(migrationDone()).assertTrue();
    });

    it('migration_upsert_failure_keeps_flag_unset_for_retry', 0, async () => {
      const kv = new MemoryTokenKv();
      const secrets = new MemorySecretStore();
      putTokenInKv(kv, makeToken('u1', 'retry_secret'));
      secrets.failUpsertFor.add('u1');
      const store = TokenStore.getInstance();
      store.useBackendsForTest(kv, secrets);
      TokenGroupStore.getInstance().useKvBackendForTest(kv);
      setMigrationDone(false);

      await store.LoadTokenByDataBase();
      // 第一重失败：不置位，KV 数据保留，下次加载重试
      expect(migrationDone()).assertFalse();
      const tokens = await store.getTokens();
      expect(tokens[0].TokenSecret).assertEqual('retry_secret');
    });

    it('migration_verify_not_found_keeps_flag_unset', 0, async () => {
      const kv = new MemoryTokenKv();
      const secrets = new MemorySecretStore();
      putTokenInKv(kv, makeToken('u1', 'verify_secret'));
      // upsert 成功但第二重（查回）失败
      secrets.dropQueryFor.add('u1');
      const store = TokenStore.getInstance();
      store.useBackendsForTest(kv, secrets);
      TokenGroupStore.getInstance().useKvBackendForTest(kv);
      setMigrationDone(false);

      await store.LoadTokenByDataBase();
      expect(secrets.upsertCalls.length).assertEqual(1);
      expect(migrationDone()).assertFalse();
    });

    it('migration_verify_content_mismatch_keeps_flag_unset', 0, async () => {
      const kv = new MemoryTokenKv();
      const secrets = new MemorySecretStore();
      putTokenInKv(kv, makeToken('u1', 'original_secret'));
      // 第三重（内容一致）失败：查回被篡改的值
      secrets.corruptQueryFor.set('u1', 'tampered_secret');
      const store = TokenStore.getInstance();
      store.useBackendsForTest(kv, secrets);
      TokenGroupStore.getInstance().useKvBackendForTest(kv);
      setMigrationDone(false);

      await store.LoadTokenByDataBase();
      expect(secrets.upsertCalls.length).assertEqual(1);
      // 内存不被篡改值污染
      const tokens = await store.getTokens();
      expect(tokens[0].TokenSecret).assertEqual('original_secret');
      expect(migrationDone()).assertFalse();
    });

    it('migration_oversized_secret_degrades_to_kv_and_sets_flag', 0, async () => {
      const kv = new MemoryTokenKv();
      const secrets = new MemorySecretStore();
      // >900 UTF-8 字节（700 个两字节汉字 ≈ 1400 字节）
      const bigSecret = '令'.repeat(700);
      putTokenInKv(kv, makeToken('u1', bigSecret));
      const store = TokenStore.getInstance();
      store.useBackendsForTest(kv, secrets);
      TokenGroupStore.getInstance().useKvBackendForTest(kv);
      setMigrationDone(false);

      await store.LoadTokenByDataBase();
      // 设计降级：不迁移、不视为失败（置位，避免每次加载重复探测）
      expect(secrets.upsertCalls.length).assertEqual(0);
      const tokens = await store.getTokens();
      expect(tokens[0].TokenSecret).assertEqual(bigSecret);
      expect(migrationDone()).assertTrue();
    });

    it('migration_mixed_batch_any_failure_blocks_flag', 0, async () => {
      const kv = new MemoryTokenKv();
      const secrets = new MemorySecretStore();
      putTokenInKv(kv, makeToken('ok', 'secret_ok', 0));
      putTokenInKv(kv, makeToken('bad', 'secret_bad', 1));
      secrets.failUpsertFor.add('bad');
      const store = TokenStore.getInstance();
      store.useBackendsForTest(kv, secrets);
      TokenGroupStore.getInstance().useKvBackendForTest(kv);
      setMigrationDone(false);

      await store.LoadTokenByDataBase();
      // ok 已迁移；bad 失败 → 整体标记不置位
      expect(secrets.secrets.get('ok')).assertEqual('secret_ok');
      expect(migrationDone()).assertFalse();
    });

    it('migration_both_empty_secret_is_noop', 0, async () => {
      const kv = new MemoryTokenKv();
      const secrets = new MemorySecretStore();
      putTokenInKv(kv, makeToken('u1', ''));
      const store = TokenStore.getInstance();
      store.useBackendsForTest(kv, secrets);
      TokenGroupStore.getInstance().useKvBackendForTest(kv);
      setMigrationDone(false);

      await store.LoadTokenByDataBase();
      expect(secrets.upsertCalls.length).assertEqual(0);
      expect(migrationDone()).assertTrue();
    });

    it('steam_token_load_keeps_secrets_without_migration_writes', 0, async () => {
      const kv = new MemoryTokenKv();
      const secrets = new MemorySecretStore();
      const named = new MemoryNamedSecretStore();
      const steamStore = SteamSecretStore.getInstance();
      steamStore.useBackendForTest(named);

      const token = makeToken('steam1', 'shared_secret_b64', 0, otpType.Steam);
      const auth = new SteamAuth();
      auth.identitySecret = 'identity_x';
      auth.revocationCode = 'R1';
      token.SteamAuth = auth;
      putTokenInKv(kv, token);

      const store = TokenStore.getInstance();
      store.useBackendsForTest(kv, secrets, steamStore);
      TokenGroupStore.getInstance().useKvBackendForTest(kv);
      setMigrationDone(false);

      await store.LoadTokenByDataBase();
      // 非 mafile 路径：load 回填（ASSET 空 → 保留内存值），不触发迁移写
      expect(named.upsertCalls.length).assertEqual(0);
      const tokens = await store.getTokens();
      expect(tokens[0].TokenType).assertEqual(otpType.Steam);
    });

    it('updateToken_new_token_appended_with_next_rank_and_secret_written', 0, async () => {
      const kv = new MemoryTokenKv();
      const secrets = new MemorySecretStore();
      putTokenInKv(kv, makeToken('old', 'old_secret', 3));
      const store = TokenStore.getInstance();
      store.useBackendsForTest(kv, secrets);
      TokenGroupStore.getInstance().useKvBackendForTest(kv);
      setMigrationDone(true);
      await store.LoadTokenByDataBase();

      const created = makeToken('new', 'new_secret', 99);
      await store.updateToken(created);

      const tokens = await store.getTokens();
      expect(tokens.length).assertEqual(2);
      // 新令牌追加末尾，历史 RankScore 间隙被兼容（nextRank = max+1）
      expect(tokens[1].TokenUUID).assertEqual('new');
      expect(tokens[1].RankScore).assertEqual(4);
      expect(tokens[1].TokenGroupId).assertEqual('');
      // 密钥变化 → 写 ASSET
      expect(secrets.upsertCalls.length).assertEqual(1);
      expect(secrets.upsertCalls[0]).assertEqual('new');
      // KV 已写入
      expect(kv.entries.has(`${TOKEN_PREFIX}new`)).assertTrue();
    });

    it('updateToken_existing_keeps_rank_and_local_favorite', 0, async () => {
      const kv = new MemoryTokenKv();
      const secrets = new MemorySecretStore();
      const existing = makeToken('u1', 'old_secret', 2);
      existing.TokenFavorite = true;
      existing.TokenGroupId = 'g1';
      putTokenInKv(kv, existing);
      const store = TokenStore.getInstance();
      store.useBackendsForTest(kv, secrets);
      TokenGroupStore.getInstance().useKvBackendForTest(kv);
      setMigrationDone(true);
      await store.LoadTokenByDataBase();

      const incoming = makeToken('u1', 'new_secret', 42);
      incoming.TokenFavorite = false;
      await store.updateToken(incoming);

      const tokens = await store.getTokens();
      expect(tokens.length).assertEqual(1);
      expect(tokens[0].RankScore).assertEqual(2);
      // 本地收藏保留，不被备份/导入数据覆盖
      expect(tokens[0].TokenFavorite).assertTrue();
      expect(tokens[0].TokenSecret).assertEqual('new_secret');
      expect(secrets.upsertCalls.length).assertEqual(1);
    });

    it('updateToken_invalid_inputs_throw_and_do_not_touch_state', 0, async () => {
      const kv = new MemoryTokenKv();
      const secrets = new MemorySecretStore();
      const store = TokenStore.getInstance();
      store.useBackendsForTest(kv, secrets);
      TokenGroupStore.getInstance().useKvBackendForTest(kv);
      setMigrationDone(true);
      await store.LoadTokenByDataBase();

      let threwEmpty = false;
      try {
        await store.updateToken(makeToken('', 'secret'));
      } catch (e) {
        threwEmpty = (e as Error).message === 'Invalid persistent token';
      }
      expect(threwEmpty).assertTrue();

      const nfc = makeToken('nfc', 'secret', 0, otpType.NFC_external);
      let threwNfc = false;
      try {
        await store.updateToken(nfc);
      } catch (e) {
        threwNfc = true;
      }
      expect(threwNfc).assertTrue();
      expect((await store.getTokens()).length).assertEqual(0);
      expect(kv.batchCallCount).assertEqual(0);
    });

    it('updateToken_kv_failure_rolls_back_memory_and_skips_asset', 0, async () => {
      const kv = new MemoryTokenKv();
      const secrets = new MemorySecretStore();
      const store = TokenStore.getInstance();
      store.useBackendsForTest(kv, secrets);
      TokenGroupStore.getInstance().useKvBackendForTest(kv);
      setMigrationDone(true);
      await store.LoadTokenByDataBase();
      kv.failNextBatch = true;

      let threw = false;
      try {
        await store.updateToken(makeToken('u1', 'secret'));
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
      // 不发布未保存数据：内存与 ASSET 都未变
      expect((await store.getTokens()).length).assertEqual(0);
      expect(secrets.upsertCalls.length).assertEqual(0);
    });

    it('updateToken_unchanged_secret_skips_asset_io', 0, async () => {
      const kv = new MemoryTokenKv();
      const secrets = new MemorySecretStore();
      putTokenInKv(kv, makeToken('u1', 'same_secret', 0));
      const store = TokenStore.getInstance();
      store.useBackendsForTest(kv, secrets);
      TokenGroupStore.getInstance().useKvBackendForTest(kv);
      setMigrationDone(true);
      await store.LoadTokenByDataBase();
      secrets.upsertCalls = [];

      const renamed = makeToken('u1', 'same_secret', 0);
      renamed.TokenName = 'Renamed';
      await store.updateToken(renamed);

      expect(secrets.upsertCalls.length).assertEqual(0);
      expect(secrets.removeCalls.length).assertEqual(0);
    });

    it('updateToken_oversized_secret_removes_stale_asset_copy', 0, async () => {
      const kv = new MemoryTokenKv();
      const secrets = new MemorySecretStore();
      putTokenInKv(kv, makeToken('u1', 'short', 0));
      const store = TokenStore.getInstance();
      store.useBackendsForTest(kv, secrets);
      TokenGroupStore.getInstance().useKvBackendForTest(kv);
      setMigrationDone(true);
      await store.LoadTokenByDataBase();

      await store.updateToken(makeToken('u1', '长'.repeat(600)));

      // 超限密钥降级 KV：清除旧 ASSET 副本，避免迁移回填旧值
      expect(secrets.upsertCalls.length).assertEqual(0);
      expect(secrets.removeCalls.length).assertEqual(1);
      expect(secrets.removeCalls[0]).assertEqual('u1');
    });

    it('updateToken_cleared_secret_removes_asset_copy', 0, async () => {
      const kv = new MemoryTokenKv();
      const secrets = new MemorySecretStore();
      putTokenInKv(kv, makeToken('u1', 'short', 0));
      const store = TokenStore.getInstance();
      store.useBackendsForTest(kv, secrets);
      TokenGroupStore.getInstance().useKvBackendForTest(kv);
      setMigrationDone(true);
      await store.LoadTokenByDataBase();

      await store.updateToken(makeToken('u1', ''));
      expect(secrets.removeCalls.length).assertEqual(1);
      expect(secrets.removeCalls[0]).assertEqual('u1');
    });

    it('updateToken_asset_save_failure_removes_partial_secret', 0, async () => {
      const kv = new MemoryTokenKv();
      const secrets = new MemorySecretStore();
      putTokenInKv(kv, makeToken('u1', 'old', 0));
      secrets.failUpsertFor.add('u1');
      const store = TokenStore.getInstance();
      store.useBackendsForTest(kv, secrets);
      TokenGroupStore.getInstance().useKvBackendForTest(kv);
      setMigrationDone(true);
      await store.LoadTokenByDataBase();

      await store.updateToken(makeToken('u1', 'changed'));
      // 写入失败不保留可能过期的密钥；加密 KV 仍是降级来源
      expect(secrets.upsertCalls.length).assertEqual(1);
      expect(secrets.removeCalls.length).assertEqual(1);
      expect(secrets.removeCalls[0]).assertEqual('u1');
    });

    it('persistTokens_strips_steam_credentials_from_kv_payload', 0, async () => {
      const kv = new MemoryTokenKv();
      const secrets = new MemorySecretStore();
      const named = new MemoryNamedSecretStore();
      const steamStore = SteamSecretStore.getInstance();
      steamStore.useBackendForTest(named);
      const store = TokenStore.getInstance();
      store.useBackendsForTest(kv, secrets, steamStore);
      TokenGroupStore.getInstance().useKvBackendForTest(kv);
      setMigrationDone(true);
      await store.LoadTokenByDataBase();

      const steamToken = makeToken('st', 'shared_secret', 0, otpType.Steam);
      const auth = new SteamAuth();
      auth.identitySecret = 'identity_x';
      auth.revocationCode = 'R1';
      auth.refreshToken = 'jwt_token';
      steamToken.SteamAuth = auth;

      await store.updateToken(steamToken);

      // Steam 凭证进 ASSET（别名分片语义由 SteamSecretStore 套件覆盖）
      expect(named.upsertCalls.length).assertEqual(3);
      // 内存对象保留明文
      const tokens = await store.getTokens();
      const memAuth = tokens[0].SteamAuth;
      expect(memAuth !== undefined).assertTrue();
      // KV 载荷已脱敏：identity/refresh/revocation 不落 KV
      const kvRaw = kv.entries.get(`${TOKEN_PREFIX}st`) ?? '';
      expect(kvRaw.includes('identity_x')).assertFalse();
      expect(kvRaw.includes('jwt_token')).assertFalse();
      expect(kvRaw.includes('R1')).assertFalse();
    });

    it('deleteTokens_compacts_ranks_only_after_first_removal_and_cleans_secrets', 0, async () => {
      const kv = new MemoryTokenKv();
      const secrets = new MemorySecretStore();
      const named = new MemoryNamedSecretStore();
      const steamStore = SteamSecretStore.getInstance();
      steamStore.useBackendForTest(named);
      putTokenInKv(kv, makeToken('a', 'sa', 0));
      putTokenInKv(kv, makeToken('b', 'sb', 1));
      putTokenInKv(kv, makeToken('c', 'sc', 2));
      putTokenInKv(kv, makeToken('d', 'sd', 3));
      const store = TokenStore.getInstance();
      store.useBackendsForTest(kv, secrets, steamStore);
      TokenGroupStore.getInstance().useKvBackendForTest(kv);
      setMigrationDone(true);
      await store.LoadTokenByDataBase();

      await store.deleteTokens(['a', 'c']);

      const tokens = await store.getTokens();
      expect(tokens.length).assertEqual(2);
      expect(tokens[0].TokenUUID).assertEqual('b');
      // 旧排序语义：只扣除前面删除的数量
      expect(tokens[0].RankScore).assertEqual(0);
      expect(tokens[1].TokenUUID).assertEqual('d');
      expect(tokens[1].RankScore).assertEqual(1);
      // 被删令牌的密钥从 ASSET 与 Steam 存储清除（Steam 每令牌 id+rev 两个别名）
      expect(secrets.removeCalls.length).assertEqual(2);
      expect(named.removeCalls.length).assertEqual(4);
    });

    it('deleteTokens_unknown_uuids_is_noop', 0, async () => {
      const kv = new MemoryTokenKv();
      const secrets = new MemorySecretStore();
      putTokenInKv(kv, makeToken('a', 'sa', 0));
      const store = TokenStore.getInstance();
      store.useBackendsForTest(kv, secrets);
      TokenGroupStore.getInstance().useKvBackendForTest(kv);
      setMigrationDone(true);
      await store.LoadTokenByDataBase();

      await store.deleteTokens(['missing']);
      expect((await store.getTokens()).length).assertEqual(1);
      expect(secrets.removeCalls.length).assertEqual(0);
    });

    it('updateTokenRank_moves_within_bounds_and_noop_out_of_bounds', 0, async () => {
      const kv = new MemoryTokenKv();
      const secrets = new MemorySecretStore();
      putTokenInKv(kv, makeToken('a', 'sa', 0));
      putTokenInKv(kv, makeToken('b', 'sb', 1));
      putTokenInKv(kv, makeToken('c', 'sc', 2));
      const store = TokenStore.getInstance();
      store.useBackendsForTest(kv, secrets);
      TokenGroupStore.getInstance().useKvBackendForTest(kv);
      setMigrationDone(true);
      await store.LoadTokenByDataBase();

      await store.updateTokenRank(2, 0);
      let uuids = (await store.getTokens()).map((t: TokenConfig): string => t.TokenUUID);
      expect(uuids.join(',')).assertEqual('c,a,b');

      // 越界：不变
      await store.updateTokenRank(-1, 0);
      await store.updateTokenRank(0, 3);
      await store.updateTokenRank(1, 1);
      uuids = (await store.getTokens()).map((t: TokenConfig): string => t.TokenUUID);
      expect(uuids.join(',')).assertEqual('c,a,b');

      // 窗口内 RankScore 重写为连续索引
      const tokens = await store.getTokens();
      for (let i = 0; i < tokens.length; i++) {
        expect(tokens[i].RankScore).assertEqual(i);
      }
    });

    it('moveTokenToGroup_validates_group_and_persists_kv_only', 0, async () => {
      const kv = new MemoryTokenKv();
      const secrets = new MemorySecretStore();
      putTokenInKv(kv, makeToken('u1', 's', 0));
      const store = TokenStore.getInstance();
      store.useBackendsForTest(kv, secrets);
      const groupKv = new MemoryTokenKv();
      TokenGroupStore.getInstance().useKvBackendForTest(groupKv);
      setMigrationDone(true);
      await store.LoadTokenByDataBase();
      // load 会以 KV 内容覆盖目录：种子放在 load 之后（本用例只读 state.groups）
      TokenGroupStore.getInstance().state.groups = [new TokenGroup('g1', 'Work')];
      secrets.upsertCalls = [];

      // 分组不存在 → 抛错
      let threw = false;
      try {
        await store.moveTokenToGroup('u1', 'missing');
      } catch (e) {
        threw = (e as Error).message === 'Group no longer exists';
      }
      expect(threw).assertTrue();

      await store.moveTokenToGroup('u1', 'g1');
      let tokens = await store.getTokens();
      expect(tokens[0].TokenGroupId).assertEqual('g1');
      // 分组变更只写 KV（saveTokenKvOnly 而非事务批量），不触碰 ASSET
      expect(kv.batchCallCount).assertEqual(0);
      const kvRaw = kv.entries.get(`${TOKEN_PREFIX}u1`) ?? '';
      expect(kvRaw.includes('g1')).assertTrue();
      expect(secrets.upsertCalls.length).assertEqual(0);

      // 同组重复移动：no-op（不再产生 KV 写）
      const rawBefore = kvRaw;
      await store.moveTokenToGroup('u1', 'g1');
      expect(kv.entries.get(`${TOKEN_PREFIX}u1`)).assertEqual(rawBefore);

      // 归还到未分组
      await store.moveTokenToGroup('u1', '');
      tokens = await store.getTokens();
      expect(tokens[0].TokenGroupId).assertEqual('');
    });

    it('setTokensFavorite_writes_only_real_changes_and_skips_nfc', 0, async () => {
      const kv = new MemoryTokenKv();
      const secrets = new MemorySecretStore();
      const t1 = makeToken('t1', 's1', 0);
      t1.TokenFavorite = true;
      putTokenInKv(kv, t1);
      putTokenInKv(kv, makeToken('nfc', 's2', 1, otpType.NFC_external));
      const t3 = makeToken('t3', 's3', 2);
      putTokenInKv(kv, t3);
      const store = TokenStore.getInstance();
      store.useBackendsForTest(kv, secrets);
      TokenGroupStore.getInstance().useKvBackendForTest(kv);
      setMigrationDone(true);
      await store.LoadTokenByDataBase();

      // t1 true→false 是唯一真实变更；NFC 排除；t3 已是 false 不写
      await store.setTokensFavorite(['t1', 'nfc', 't3', 'missing'], false);
      expect(kv.lastBatchTokens.length).assertEqual(1);
      expect(kv.lastBatchTokens[0].TokenUUID).assertEqual('t1');
      let tokens = await store.getTokens();
      const byUuid = new Map<string, TokenConfig>();
      for (const t of tokens) {
        byUuid.set(t.TokenUUID, t);
      }
      const afterT1 = byUuid.get('t1');
      expect(afterT1 !== undefined && afterT1.TokenFavorite === false).assertTrue();
      const afterNfc = byUuid.get('nfc');
      expect(afterNfc !== undefined && afterNfc.TokenFavorite === false).assertTrue();

      // 全部无变更：不产生 KV 写
      const before = kv.batchCallCount;
      await store.setTokensFavorite(['t1', 'nfc', 't3'], false);
      expect(kv.batchCallCount).assertEqual(before);

      await store.setTokenFavorite('t3', true);
      tokens = await store.getTokens();
      const afterT3 = tokens.find((t: TokenConfig): boolean => t.TokenUUID === 't3');
      expect(afterT3 !== undefined && afterT3.TokenFavorite === true).assertTrue();
    });

    it('queryToken_backfills_secret_from_asset_when_kv_empty', 0, async () => {
      const kv = new MemoryTokenKv();
      const secrets = new MemorySecretStore();
      const bare = makeToken('u1', '', 0);
      putTokenInKv(kv, bare);
      secrets.secrets.set('u1', 'asset_backfill');
      const store = TokenStore.getInstance();
      store.useBackendsForTest(kv, secrets);
      TokenGroupStore.getInstance().useKvBackendForTest(kv);
      setMigrationDone(true);

      const token = await store.queryToken('u1');
      expect(token.TokenSecret).assertEqual('asset_backfill');

      const missing = await store.queryToken('missing');
      expect(missing.TokenSecret).assertEqual('');
    });

    it('load_revives_json_bare_objects_and_sorts_by_rank', 0, async () => {
      const kv = new MemoryTokenKv();
      const secrets = new MemorySecretStore();
      putTokenInKv(kv, makeToken('second', 's2', 5));
      putTokenInKv(kv, makeToken('first', 's1', 1));
      const store = TokenStore.getInstance();
      store.useBackendsForTest(kv, secrets);
      TokenGroupStore.getInstance().useKvBackendForTest(kv);
      setMigrationDone(true);

      await store.LoadTokenByDataBase();
      const tokens = await store.getTokens();
      expect(tokens[0].TokenUUID).assertEqual('first');
      expect(tokens[1].TokenUUID).assertEqual('second');
    });
  });
}
