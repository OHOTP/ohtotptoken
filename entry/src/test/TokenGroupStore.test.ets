import { describe, it, expect } from '@ohos/hypium';
import {
  ALL_TOKEN_GROUPS,
  FAVORITE_TOKEN_GROUP,
  TokenGroup,
  TokenGroupKvBackend,
  TokenGroupStore,
} from 'common';

/**
 * TokenGroupStore 纯逻辑测试（注入内存 KV 后端，无 distributedKVStore）。
 *
 * 覆盖：isValidName 校验、renameOrCreate/remove/move、merge 的 ID 合并策略、
 * load 后的选中态自愈（reconcileSelection）。持久化层行为由
 * scripts/token-group-store.test.mjs 的 Node 移植套件补充回归。
 */

class MemoryKv implements TokenGroupKvBackend {
  saved: TokenGroup[] | null = null;
  failNextSave: boolean = false;

  getValue<T>(key: string): Promise<T | null> {
    if (this.saved === null) {
      return Promise.resolve(null);
    }
    return Promise.resolve(JSON.parse(JSON.stringify(this.saved)) as T);
  }

  setValue<T>(key: string, value: T): Promise<void> {
    if (this.failNextSave) {
      return Promise.reject(new Error('kv write failed'));
    }
    this.saved = JSON.parse(JSON.stringify(value)) as TokenGroup[];
    return Promise.resolve();
  }

  deleteValue(_key: string): Promise<void> {
    return Promise.resolve();
  }
}

function group(id: string, name: string, color?: number): TokenGroup {
  return new TokenGroup(id, name, color);
}

/** 重置单例状态并绑定内存后端，隔离用例间污染 */
function freshStore(kv: MemoryKv): TokenGroupStore {
  const store = TokenGroupStore.getInstance();
  store.useKvBackendForTest(kv);
  store.state.groups = [];
  store.state.selectedId = ALL_TOKEN_GROUPS;
  kv.saved = null;
  return store;
}

export default function tokenGroupStoreTest() {
  describe('tokenGroupStoreTest', () => {
    it('is_valid_name_rejects_empty_too_long_and_duplicates', 0, () => {
      const kv = new MemoryKv();
      const store = freshStore(kv);
      store.state.groups = [group('g1', '工作'), group('g2', 'Finance')];

      expect(store.isValidName('')).assertFalse();
      expect(store.isValidName('   ')).assertFalse();
      // 上限 24 字符（按 UTF-16 code unit 计）
      expect(store.isValidName('a'.repeat(25))).assertFalse();
      expect(store.isValidName('a'.repeat(24))).assertTrue();
      // 大小写不敏感查重
      expect(store.isValidName('FINANCE')).assertFalse();
      expect(store.isValidName('finance  ')).assertFalse();
      expect(store.isValidName('生活')).assertTrue();
      // exceptId：重命名时排除自身
      expect(store.isValidName('Finance', 'g2')).assertTrue();
    });

    it('rename_existing_group_updates_state_and_persists', 0, async () => {
      const kv = new MemoryKv();
      const store = freshStore(kv);
      store.state.groups = [group('g1', 'Old'), group('g2', 'Keep')];

      await store.renameOrCreate('Renamed', 'g1', 0xFF0000FF);

      expect(store.state.groups[0].name).assertEqual('Renamed');
      expect(store.state.groups[0].color).assertEqual(0xFF0000FF);
      expect(store.state.groups[1].name).assertEqual('Keep');
      // 状态与持久化一致
      expect(kv.saved!.length).assertEqual(2);
      expect(kv.saved![0].name).assertEqual('Renamed');
      // 名称统一为 trim 后的值
      await store.renameOrCreate('  Trimmed  ', 'g1');
      expect(store.state.groups[0].name).assertEqual('Trimmed');
    });

    it('rename_or_create_throws_on_invalid_name', 0, async () => {
      const kv = new MemoryKv();
      const store = freshStore(kv);
      store.state.groups = [group('g1', 'Dup')];

      let threw = false;
      try {
        await store.renameOrCreate('dup');
      } catch (e) {
        threw = (e as Error).message === 'Invalid group name';
      }
      expect(threw).assertTrue();
      // 失败时不应改动目录
      expect(store.state.groups.length).assertEqual(1);
    });

    it('rename_or_create_without_id_appends_new_group', 0, async () => {
      const kv = new MemoryKv();
      const store = freshStore(kv);
      // LocalUnit 下 util.generateRandomUUID 返回空串（真机为随机 UUID），
      // 因此只断言追加行为与名称，不断言 id 非空。
      await store.renameOrCreate(' NewGroup ');
      expect(store.state.groups.length).assertEqual(1);
      expect(store.state.groups[0].name).assertEqual('NewGroup');
      expect(kv.saved!.length).assertEqual(1);
    });

    it('remove_deletes_only_target_group', 0, async () => {
      const kv = new MemoryKv();
      const store = freshStore(kv);
      store.state.groups = [group('g1', 'A'), group('g2', 'B')];

      await store.remove('g1');
      expect(store.state.groups.length).assertEqual(1);
      expect(store.state.groups[0].id).assertEqual('g2');
    });

    it('move_swaps_order_within_bounds_and_noop_out_of_bounds', 0, async () => {
      const kv = new MemoryKv();
      const store = freshStore(kv);
      store.state.groups = [group('a', 'A'), group('b', 'B'), group('c', 'C')];

      await store.move('c', -1);
      expect(store.state.groups.map(g => g.id).join(',')).assertEqual('a,c,b');

      await store.move('a', -1); // 越界：不变
      expect(store.state.groups.map(g => g.id).join(',')).assertEqual('a,c,b');

      await store.move('b', 1); // 越界：不变
      expect(store.state.groups.map(g => g.id).join(',')).assertEqual('a,c,b');

      await store.move('a', 1);
      expect(store.state.groups.map(g => g.id).join(',')).assertEqual('c,a,b');

      // 未知 id：from < 0，直接返回
      await store.move('missing', 1);
      expect(store.state.groups.length).assertEqual(3);
    });

    it('merge_by_id_skips_reserved_invalid_and_duplicates', 0, async () => {
      const kv = new MemoryKv();
      const store = freshStore(kv);
      store.state.groups = [group('g1', 'A')];

      await store.merge([
        group(ALL_TOKEN_GROUPS, 'All'),
        group(FAVORITE_TOKEN_GROUP, 'Favorites'),
        group('', 'no id'),
        group('x1', '   '),
        group('g1', 'dup id'),
        group('x2', '  Padded  ', 0x11223344),
        group('x3', 'y'.repeat(30)),
      ]);

      expect(store.state.groups.length).assertEqual(3);
      expect(store.state.groups[1].id).assertEqual('x2');
      expect(store.state.groups[1].name).assertEqual('Padded');
      expect(store.state.groups[1].color).assertEqual(0x11223344);
      // 名称截断到 24 字符
      expect(store.state.groups[2].name.length).assertEqual(24);
    });

    it('merge_ignores_undefined_and_empty_arrays', 0, async () => {
      const kv = new MemoryKv();
      const store = freshStore(kv);
      store.state.groups = [group('g1', 'A')];

      await store.merge(undefined);
      await store.merge([]);
      expect(store.state.groups.length).assertEqual(1);
      expect(kv.saved).assertNull();
    });

    it('load_restores_groups_and_reconciles_selection', 0, async () => {
      const kv = new MemoryKv();
      const store = freshStore(kv);
      kv.saved = [group('g1', 'A'), group('g2', 'B')];

      // 选中了不存在的分组 → 自愈为「全部」
      store.state.selectedId = 'missing';
      await store.load();
      expect(store.state.groups.length).assertEqual(2);
      expect(store.state.selectedId).assertEqual(ALL_TOKEN_GROUPS);

      // 选中合法分组 → 保留
      store.state.selectedId = 'g2';
      await store.load();
      expect(store.state.selectedId).assertEqual('g2');

      // 内置「收藏」筛选不参与自愈
      store.state.selectedId = FAVORITE_TOKEN_GROUP;
      await store.load();
      expect(store.state.selectedId).assertEqual(FAVORITE_TOKEN_GROUP);
    });

    it('token_group_color_normalizes_signed_and_rejects_invalid', 0, () => {
      expect(new TokenGroup('i', 'n', 0xFF112233).color).assertEqual(0xFF112233);
      // 有符号 ARGB -1 归一为无符号 0xFFFFFFFF
      expect(new TokenGroup('i', 'n', -1).color).assertEqual(0xFFFFFFFF);
      expect(new TokenGroup('i', 'n', -0x80000000).color).assertEqual(0x80000000);
      expect(new TokenGroup('i', 'n', 1.5).color === undefined).assertTrue();
      expect(new TokenGroup('i', 'n', NaN).color === undefined).assertTrue();
      expect(new TokenGroup('i', 'n').color === undefined).assertTrue();
    });

    it('save_failure_keeps_state_unchanged', 0, async () => {
      const kv = new MemoryKv();
      const store = freshStore(kv);
      store.state.groups = [group('g1', 'A')];
      kv.failNextSave = true;

      let threw = false;
      try {
        await store.remove('g1');
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
      // 写入失败时内存目录不变（状态与持久层保持一致）
      expect(store.state.groups.length).assertEqual(1);
    });
  });
}
