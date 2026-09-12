import { describe, it, expect } from '@ohos/hypium';
import {
  AppPreference,
  CardConfig,
  emptyCardData,
  KeyValueStore,
  PREF_KEYS,
  TokenCardStore,
  TokenConfig,
  TokenStore,
  otpType,
} from 'common';
import { MemorySecretStore, MemoryTokenKv } from './fakes/BackupFakes';

/**
 * 桌面卡片配置存取测试（Phase 2 KeyValueStore 端口注入）。
 *
 * 覆盖：配置 CRUD 与索引列表维护、卡片字段映射（generateCardData）、
 * HOTP 计数器自增。preferences 与 TokenStore 均为内存实现。
 * （TokenGroupStore 默认后端在 LocalUnit 下 getValue 安全返回 null，无需绑定。）
 */

class MemoryPrefKv implements KeyValueStore {
  entries: Map<string, string> = new Map();

  getValue<T>(key: string): Promise<T | null> {
    const raw = this.entries.get(key);
    if (raw === undefined) {
      return Promise.resolve(null);
    }
    return Promise.resolve(JSON.parse(raw) as T);
  }

  setValue<T>(key: string, value: T): Promise<void> {
    this.entries.set(key, JSON.stringify(value));
    return Promise.resolve();
  }

  deleteValue(key: string): Promise<void> {
    this.entries.delete(key);
    return Promise.resolve();
  }
}

function makeToken(uuid: string, secret: string, rank: number = 0, type: otpType = otpType.TOTP): TokenConfig {
  const token = new TokenConfig(secret, type);
  token.TokenUUID = uuid;
  token.RankScore = rank;
  return token;
}

function freshCardStore(): TokenCardStore {
  const prefKv = new MemoryPrefKv();
  const store = TokenCardStore.getInstance();
  store.useStoreForTest(prefKv);
  return store;
}

/** TokenStore 绑定内存后端并预置令牌 */
async function bindTokenStore(tokens: TokenConfig[]): Promise<void> {
  const kv = new MemoryTokenKv();
  const store = TokenStore.getInstance();
  store.useBackendsForTest(kv, new MemorySecretStore());
  for (const token of tokens) {
    kv.entries.set(`_token_uuid_${token.TokenUUID}`, JSON.stringify(token));
  }
  AppPreference.setPreference(PREF_KEYS.ASSET_MIGRATION_DONE, true);
  await store.LoadTokenByDataBase();
}

export default function tokenCardStoreTest() {
  describe('tokenCardStoreTest', () => {
    it('empty_card_data_has_two_slots_and_flag_false', 0, () => {
      const data = emptyCardData('form-1', 'My Card');
      expect(data['hasToken']).assertEqual('false');
      expect(data['formId']).assertEqual('form-1');
      expect(data['formName']).assertEqual('My Card');
      for (let i = 0; i < 2; i++) {
        expect(data[`token${i}_issuer`]).assertEqual('');
        expect(data[`token${i}_secret`]).assertEqual('');
      }
    });

    it('card_config_crud_maintains_index_list', 0, async () => {
      const store = freshCardStore();

      const config1: CardConfig = { formId: 'f1', formName: 'Card One', tokenUUIDs: ['u1'] };
      const config2: CardConfig = { formId: 'f2', formName: 'Card Two', tokenUUIDs: ['u2', 'u3'] };
      await store.saveCardConfig(config1);
      await store.saveCardConfig(config2);
      // 同 formId 重复保存：索引不重复
      await store.saveCardConfig(config1);

      const list = await store.getCardConfigList();
      expect(list.length).assertEqual(2);
      expect(list.includes('f1')).assertTrue();
      expect(list.includes('f2')).assertTrue();

      const loaded = await store.getCardConfig('f2');
      expect(loaded !== null).assertTrue();
      expect(loaded!.formName).assertEqual('Card Two');
      expect(loaded!.tokenUUIDs.length).assertEqual(2);

      await store.removeCardConfig('f1');
      const afterRemove = await store.getCardConfigList();
      expect(afterRemove.length).assertEqual(1);
      expect(afterRemove.includes('f2')).assertTrue();
      expect(await store.getCardConfig('f1')).assertNull();
    });

    it('remove_missing_config_is_noop', 0, async () => {
      const store = freshCardStore();
      await store.removeCardConfig('missing');
      const list = await store.getCardConfigList();
      expect(list.length).assertEqual(0);
    });

    it('generate_card_data_maps_token_fields_with_margin_pref', 0, async () => {
      const store = freshCardStore();
      const t1 = makeToken('u1', 'secret_a', 0);
      t1.TokenIssuer = 'GitHub';
      t1.TokenName = 'octocat';
      t1.TokenDigits = 8;
      t1.TokenPeriod = 60;
      await bindTokenStore([t1]);

      const config: CardConfig = { formId: 'f1', formName: 'Card One', tokenUUIDs: ['u1', 'missing'] };
      AppPreference.setPreference(PREF_KEYS.APPEARANCE_TOKEN_COUNTER_NEXT_MARGIN, 9);
      const data = await store.generateCardData('f1', config);

      expect(data['hasToken']).assertEqual('true');
      expect(data['token0_issuer']).assertEqual('GitHub');
      expect(data['token0_name']).assertEqual('octocat');
      expect(data['token0_digits']).assertEqual('8');
      expect(data['token0_period']).assertEqual('60');
      expect(data['token0_type']).assertEqual('0');
      expect(data['token0_counter']).assertEqual('0');
      // 用户设置的过期阈值流入卡片数据
      expect(data['token0_next_margin']).assertEqual('9');
      // 第二个槽位找不到令牌：保持空
      expect(data['token1_issuer']).assertEqual('');
    });

    it('generate_card_data_uses_default_margin_when_pref_not_numeric', 0, async () => {
      const store = freshCardStore();
      await bindTokenStore([makeToken('u1', 's', 0)]);
      const config: CardConfig = { formId: 'f1', formName: 'Card One', tokenUUIDs: ['u1'] };
      // 非数字偏好 → typeof 守卫走兜底 5
      AppPreference.setPreference(PREF_KEYS.APPEARANCE_TOKEN_COUNTER_NEXT_MARGIN, 'oops');
      const data = await store.generateCardData('f1', config);
      expect(data['token0_next_margin']).assertEqual('5');
    });

    it('generate_card_data_without_config_or_tokens_is_empty', 0, async () => {
      const store = freshCardStore();
      await bindTokenStore([]);

      const noConfig = await store.generateCardData('none');
      expect(noConfig['hasToken']).assertEqual('false');

      const emptyTokens: CardConfig = { formId: 'f1', formName: 'Card One', tokenUUIDs: [] };
      const noBound = await store.generateCardData('f1', emptyTokens);
      expect(noBound['hasToken']).assertEqual('false');
    });

    it('increment_token_counter_persists_and_returns_new_value', 0, async () => {
      const store = freshCardStore();
      await bindTokenStore([makeToken('hotp1', 's', 0, otpType.HOTP)]);

      const value = await store.incrementTokenCounter('hotp1');
      expect(value).assertEqual(1);

      const again = await store.incrementTokenCounter('hotp1');
      expect(again).assertEqual(2);

      const missing = await store.incrementTokenCounter('missing');
      expect(missing).assertEqual(-1);
    });
  });
}
