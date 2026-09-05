import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { runInNewContext } from 'node:vm';
import { test } from 'node:test';

// Execute the production store with in-memory SDK/KV mocks, not a duplicate implementation.
const source = readFileSync(new URL('../common/src/main/ets/utils/TokenGroupStore.ets', import.meta.url), 'utf8')
  .replace(/^import .*;\r?\n/gm, '')
  .replace(/^@ObservedV2\r?\n/gm, '')
  .replace(/@Trace /g, '')
  .replace(/export /g, '');
const code = stripTypeScriptTypes(source) + '\n({ TokenGroup, TokenGroupStore });';
const colorSource = readFileSync(new URL('../common/src/main/ets/utils/ColorUtils.ets', import.meta.url), 'utf8')
  .replace(/export /g, '');
const { hexColor, setRgba } = runInNewContext(stripTypeScriptTypes(colorSource) + '\n({ hexColor, setRgba });');

function fixture(initial = []) {
  let saved = structuredClone(initial);
  let failSave = false;
  let sequence = 0;
  const kv = {
    getValue: async () => structuredClone(saved),
    setValue: async (_key, groups) => {
      if (failSave) throw new Error('Save failed');
      saved = JSON.parse(JSON.stringify(groups));
    }
  };
  const { TokenGroup, TokenGroupStore } = runInNewContext(code, {
    AppStorageV2: { connect: (_type, factory) => factory() },
    util: { generateRandomUUID: () => `group-${++sequence}` },
    KvManager: { getInstance: () => kv }
  });
  return {
    store: TokenGroupStore.getInstance(), TokenGroup,
    persisted: () => structuredClone(saved),
    fail: () => { failSave = true; }
  };
}

test('create, save and reload a group color', async () => {
  const { store, persisted } = fixture();
  await store.renameOrCreate(' Work ', '', 0xFF2288CC);
  assert.equal(persisted()[0].name, 'Work');
  assert.equal(persisted()[0].color, 0xFF2288CC);
  store.state.groups = [];
  await store.load();
  assert.equal(store.state.groups[0].color, 0xFF2288CC);
});

test('edit color without changing name; rename preserves all existing colors', async () => {
  const { store } = fixture([
    { id: 'a', name: 'A', color: 0xFF112233 },
    { id: 'b', name: 'B', color: 0xFF445566 }
  ]);
  await store.load();
  await store.renameOrCreate('A', 'a', 0xFF778899);
  await store.renameOrCreate('Renamed', 'a');
  assert.equal(store.state.groups[0].color, 0xFF778899);
  assert.equal(store.state.groups[1].color, 0xFF445566);
  await store.renameOrCreate('New', '', 0xFF123456);
  assert.equal(store.state.groups[0].color, 0xFF778899);
});

test('legacy groups retain an unset color after loading and renaming', async () => {
  const { store } = fixture([{ id: 'old', name: 'Legacy' }]);
  await store.load();
  assert.equal(store.state.groups[0].color, undefined);
  await store.renameOrCreate('Renamed', 'old');
  assert.equal(store.state.groups[0].color, undefined);
});

test('backup merge preserves colors and does not overwrite local groups', async () => {
  const { store } = fixture([{ id: 'local', name: 'Local', color: 0xFF123456 }]);
  await store.load();
  await store.merge([
    { id: 'local', name: 'Remote', color: 0xFFABCDEF },
    { id: 'new', name: 'Imported', color: 0xFFABCDEF },
    { id: 'old', name: 'Legacy' }
  ]);
  assert.equal(store.state.groups[0].color, 0xFF123456);
  assert.equal(store.state.groups[1].color, 0xFFABCDEF);
  assert.equal(store.state.groups[2].color, undefined);
});

test('invalid colors fall back while transparent ARGB remains valid', async () => {
  const { TokenGroup } = fixture();
  for (const color of [-0x80000001, 0x100000000, NaN, Infinity, 1.5, 'red', null]) {
    assert.equal(new TokenGroup('a', 'A', color).color, undefined);
  }
  assert.equal(new TokenGroup('a', 'A', 0).color, 0);
});

test('picker conversion saves signed ARGB and survives editing and reload', async () => {
  const { store, persisted } = fixture();
  const picked = hexColor('#FFFF0000');
  assert.ok(picked < 0, 'production converter returns signed ARGB');
  await store.renameOrCreate('Red', '', picked);
  assert.equal(persisted()[0].color, 0xFFFF0000);
  await store.load();
  assert.equal(store.state.groups[0].color, 0xFFFF0000);
  await store.renameOrCreate('Red', store.state.groups[0].id, setRgba(0, 255, 0, 255));
  assert.equal(persisted()[0].color, 0xFF00FF00);
  await store.load();
  assert.equal(store.state.groups[0].color, 0xFF00FF00);
});

test('signed colors from local storage and backups are normalized', async () => {
  const { store, TokenGroup } = fixture([{ id: 'a', name: 'Red', color: hexColor('#FFFF0000') }]);
  await store.load();
  assert.equal(store.state.groups[0].color, 0xFFFF0000);
  await store.merge([{ id: 'b', name: 'White', color: hexColor('#FFFFFFFF') }]);
  assert.equal(store.state.groups[1].color, 0xFFFFFFFF);
  assert.equal(new TokenGroup('c', 'Black', -0x80000000).color, 0x80000000);
});

test('reordering and removing other groups preserve color', async () => {
  const { store, persisted } = fixture([
    { id: 'a', name: 'A', color: 0xFF112233 },
    { id: 'b', name: 'B', color: 0xFF445566 }
  ]);
  await store.load();
  await store.move('b', -1);
  await store.remove('a');
  assert.equal(persisted()[0].id, 'b');
  assert.equal(persisted()[0].color, 0xFF445566);
});

test('save failure leaves the prior name and color unchanged', async () => {
  const { store, fail, persisted } = fixture([{ id: 'a', name: 'A', color: 0xFF112233 }]);
  await store.load();
  fail();
  await assert.rejects(store.renameOrCreate('Changed', 'a', 0xFF445566));
  assert.equal(store.state.groups[0].name, 'A');
  assert.equal(store.state.groups[0].color, 0xFF112233);
  assert.equal(persisted()[0].color, 0xFF112233);
});
