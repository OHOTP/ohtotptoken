import { describe, it, expect } from '@ohos/hypium';
import { NamedSecretStore, SteamAuth, SteamSecretStore } from 'common';
import { MemoryNamedSecretStore } from './fakes/BackupFakes';

/**
 * Steam 凭证分片存储测试（Phase 2 NamedSecretStore 端口注入）。
 *
 * 覆盖：别名规则、空值删除语义、refresh_token 分片与尾部分片回收、
 * load「ASSET 有值才覆盖」语义（保护旧 mafile 迁移路径）、remove 全量清理。
 */

const ALIAS_PREFIX = 'opt_steam_sec_';

/** hypium 顺序执行：绑定后端并存模块级引用，避免数组解构（ArkTS 禁用） */
let currentBackend: MemoryNamedSecretStore = new MemoryNamedSecretStore();

function bindSteamStore(): SteamSecretStore {
  currentBackend = new MemoryNamedSecretStore();
  const store = SteamSecretStore.getInstance();
  store.useBackendForTest(currentBackend);
  return store;
}

function makeAuth(identity: string, revocation: string, refresh: string): SteamAuth {
  const auth = new SteamAuth();
  auth.identitySecret = identity;
  auth.revocationCode = revocation;
  auth.refreshToken = refresh;
  return auth;
}

function longRefreshToken(): string {
  // > 800 字节（STEAM_SECRET_CHUNK_BYTES），必然产生 ≥2 个分片
  return 'a'.repeat(2000);
}

export default function steamSecretStoreTest() {
  describe('steamSecretStoreTest', () => {
    it('save_writes_identity_and_revocation_aliases', 0, async () => {
      const store = bindSteamStore();
      const backend = currentBackend;

      await store.save('uuid1', makeAuth('identity_v2', 'R123', ''));

      expect(backend.secrets.get(`${ALIAS_PREFIX}uuid1_id`)).assertEqual('identity_v2');
      expect(backend.secrets.get(`${ALIAS_PREFIX}uuid1_rev`)).assertEqual('R123');
    });

    it('save_empty_value_removes_alias', 0, async () => {
      const store = bindSteamStore();
      const backend = currentBackend;
      await store.save('uuid1', makeAuth('id', 'rev', ''));
      expect(backend.secrets.has(`${ALIAS_PREFIX}uuid1_id`)).assertTrue();

      // 置空 → 对应别名被删除
      await store.save('uuid1', makeAuth('', 'rev', ''));
      expect(backend.secrets.has(`${ALIAS_PREFIX}uuid1_id`)).assertFalse();
      expect(backend.secrets.has(`${ALIAS_PREFIX}uuid1_rev`)).assertTrue();
    });

    it('refresh_token_chunking_splits_and_joins', 0, async () => {
      const store = bindSteamStore();
      const backend = currentBackend;
      const refresh = longRefreshToken();

      await store.save('uuid2', makeAuth('id', 'rev', refresh));

      // 多分片写入：_rt_0 与 _rt_1 均存在
      const chunk0 = backend.secrets.get(`${ALIAS_PREFIX}uuid2_rt_0`);
      const chunk1 = backend.secrets.get(`${ALIAS_PREFIX}uuid2_rt_1`);
      expect(chunk0 !== undefined && chunk1 !== undefined).assertTrue();

      // load 按序拼接还原
      const auth = makeAuth('', '', '');
      await store.load('uuid2', auth);
      expect(auth.identitySecret).assertEqual('id');
      expect(auth.refreshToken).assertEqual(refresh);
    });

    it('save_shorter_refresh_token_removes_stale_chunks', 0, async () => {
      const store = bindSteamStore();
      const backend = currentBackend;
      await store.save('uuid3', makeAuth('', '', longRefreshToken()));
      expect(backend.secrets.has(`${ALIAS_PREFIX}uuid3_rt_1`)).assertTrue();

      // 缩短为单分片：探测到残留分片并回收，避免下次 load 拼接出错误长 token
      await store.save('uuid3', makeAuth('', '', 'short-token'));
      expect(backend.secrets.has(`${ALIAS_PREFIX}uuid3_rt_0`)).assertTrue();
      expect(backend.secrets.has(`${ALIAS_PREFIX}uuid3_rt_1`)).assertFalse();
      // 先探测再删除：probe 调用包含 _rt_1
      let probedStale = false;
      for (const alias of backend.probeCalls) {
        if (alias === `${ALIAS_PREFIX}uuid3_rt_1`) {
          probedStale = true;
        }
      }
      expect(probedStale).assertTrue();
    });

    it('load_keeps_existing_values_when_asset_empty', 0, async () => {
      const store = bindSteamStore();
      // mafile 迁移路径：TokenStore 先用 mafile 构造 SteamAuth，此时 ASSET 尚无数据
      const auth = makeAuth('mafile_identity', 'mafile_rev', 'mafile_refresh');

      await store.load('uuid4', auth);
      // ASSET 为空必须保留调用方已有值，否则等于把密钥丢掉
      expect(auth.identitySecret).assertEqual('mafile_identity');
      expect(auth.revocationCode).assertEqual('mafile_rev');
      expect(auth.refreshToken).assertEqual('mafile_refresh');
    });

    it('load_overrides_only_fields_present_in_asset', 0, async () => {
      const store = bindSteamStore();
      const backend = currentBackend;
      backend.secrets.set(`${ALIAS_PREFIX}uuid5_id`, 'asset_identity');

      const auth = makeAuth('local_identity', 'local_rev', '');
      await store.load('uuid5', auth);
      expect(auth.identitySecret).assertEqual('asset_identity');
      expect(auth.revocationCode).assertEqual('local_rev');
    });

    it('remove_cleans_all_aliases_including_chunks', 0, async () => {
      const store = bindSteamStore();
      const backend = currentBackend;
      await store.save('uuid6', makeAuth('id', 'rev', longRefreshToken()));
      expect(backend.secrets.size >= 4).assertTrue();

      await store.remove('uuid6');
      expect(backend.secrets.size).assertEqual(0);
    });

    it('named_backend_failure_keeps_alias_missing_semantics', 0, async () => {
      const store = bindSteamStore();
      const backend = currentBackend;
      backend.failUpsertFor.add(`${ALIAS_PREFIX}uuid7_id`);

      const auth = makeAuth('id_value', '', '');
      await store.save('uuid7', auth);
      // upsert 失败 → 无别名落盘（不抛错，由上层验证三重机制兜底）
      expect(backend.secrets.has(`${ALIAS_PREFIX}uuid7_id`)).assertFalse();
    });
  });
}
