import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { runInNewContext } from 'node:vm';
import { randomUUID } from 'node:crypto';
import { test } from 'node:test';

// Run production ArkTS with an SDK boundary mock; the batching/queue/planning code is not copied.
// Node's strip-only parser cannot lower enums. Read numeric members from the source, not a test copy.
function lowerNumericEnum(_match, name, body) {
  let next = 0;
  const fields = body.replace(/\/\*[\s\S]*?\*\//g, '').split(',').filter(part => part.trim()).map(part => {
    const match = part.trim().match(/^(\w+)(?:\s*=\s*(\d+))?$/);
    assert.ok(match, `unsupported enum member: ${part}`);
    if (match[2] !== undefined) next = Number(match[2]);
    return `${JSON.stringify(match[1])}: ${next++}`;
  });
  return `const ${name} = {${fields.join(',')}};`;
}
function source(file) {
  return stripTypeScriptTypes(readFileSync(new URL(`../${file}`, import.meta.url), 'utf8')
    .replace(/^import .*;\r?\n/gm, '').replace(/export /g, '')
    .replace(/enum (\w+)\s*\{([^}]+)\}/g, lowerNumericEnum));
}
const code = [
  'common/src/main/ets/utils/SteamAuth.ets',
  'common/src/main/ets/utils/TokenConfig.ets',
  'common/src/main/ets/utils/TokenBatchProgress.ets',
  'common/src/main/ets/utils/TokenKvBatch.ets',
  'common/src/main/ets/utils/KvManager.ets',
  'common/src/main/ets/utils/TokenStore.ets',
  'common/src/main/ets/utils/OtpAuthParser.ets'
].map(source).join('\n') + `
// SteamSecretStore 依赖 ASSET（@kit.AssetStoreKit），本 harness 不加载该边界，用桩替代。
// TokenStore 仅对带 SteamAuth 的令牌调用它；本文件用到的令牌都没有 SteamAuth。
class SteamSecretStore {
  static getInstance() {
    if (!SteamSecretStore.instance) SteamSecretStore.instance = new SteamSecretStore();
    return SteamSecretStore.instance;
  }
  async save() {}
  async load() {}
  async remove() {}
}
// maFile 定义在 SteamUtils.ets（依赖 @kit.NetworkKit），此处只按字段形状补一个桩
class maFile {
  constructor() {
    this.shared_secret = ''; this.serial_number = ''; this.revocation_code = '';
    this.uri = ''; this.server_time = 0; this.account_name = ''; this.token_gid = '';
    this.identity_secret = ''; this.secret_1 = ''; this.status = 0; this.device_id = '';
    this.fully_enrolled = false; this.Session = null;
  }
}
` + '\n({ KvManager, TokenStore, TokenConfig, TokenConfigVM, copyTokenConfig, otpType, parseOtpAuthUris, TokenBatchStage, SteamAuth });';
const plain = value => JSON.parse(JSON.stringify(value));
const prefix = '_token_uuid_';

async function fixture(count = 0) {
  let data = new Map();
  let transaction;
  let failAt = '';
  let pause;
  const calls = [];
  const events = [];
  const secrets = new Map();
  let assetFails = false;
  function check(kind) {
    if (failAt === kind || failAt === `${kind}:${calls.filter(call => call[0] === kind).length}`) {
      failAt = '';
      throw new Error(`injected ${kind} failure`);
    }
  }
  const native = {
    async startTransaction() {
      calls.push(['begin']);
      check('begin');
      assert.equal(transaction, undefined, 'no overlapping transactions');
      transaction = new Map(data);
    },
    async putBatch(entries) {
      assert.ok(entries.length > 0 && entries.length <= 128);
      calls.push(['putBatch', entries.length, entries.map(entry => entry.key)]);
      entries.forEach(entry => (transaction ?? data).set(entry.key, entry.value.value));
      if (pause) { const wait = pause; pause = undefined; await wait; }
      check('putBatch');
    },
    async deleteBatch(keys) {
      assert.ok(keys.length > 0 && keys.length <= 128);
      calls.push(['deleteBatch', keys.length]);
      keys.forEach(key => (transaction ?? data).delete(key));
      check('deleteBatch');
    },
    async commit() {
      calls.push(['commit']);
      check('commit');
      data = transaction;
      transaction = undefined;
    },
    async rollback() { calls.push(['rollback']); transaction = undefined; },
    async put(key, value) { calls.push(['put', key]); (transaction ?? data).set(key, value); },
    async delete(key) { calls.push(['delete', key]); (transaction ?? data).delete(key); },
    async get(key) { return (transaction ?? data).get(key); },
    async getEntries(keyPrefix) {
      return [...(transaction ?? data)].filter(([key]) => key.startsWith(keyPrefix))
        .map(([key, value]) => ({ key, value: { value } }));
    }
  };
  const context = {
    eventHub: { emit: (name, token) => events.push([name, token]) }
  };
  const api = runInNewContext(code, {
    util: { generateRandomUUID: randomUUID },
    distributedKVStore: { ValueType: { STRING: 0 } },
    RdbManager: { getInstance: () => ({}) },
    TokenGroupStore: { getInstance: () => ({ load: async () => {}, state: { groups: [{ id: 'work' }] } }) },
    AssetSecretStore: { getInstance: () => ({
      isSecretSizeValid: secret => secret.length > 0 && Buffer.byteLength(secret) <= 900,
      upsertSecret: async (id, secret) => {
        calls.push(['assetPut', id]);
        if (assetFails) return false;
        secrets.set(id, secret); return true;
      },
      removeSecret: async id => { calls.push(['assetDelete', id]); secrets.delete(id); },
      querySecret: async id => secrets.get(id) ?? null
    }) },
    AppStorage: { get: () => context },
    AppPreference: { getPreference: () => true },
    PREF_KEYS: { ASSET_MIGRATION_DONE: 'migrated' },
    EVENT_NAMES: { TOKEN_CHANGED: 'changed', TOKEN_SINGLE_UPDATED: 'single' },
    hilog: { info() {}, warn() {}, error() {} }
  });
  const kv = api.KvManager.getInstance();
  kv._kvStore = native;
  const store = api.TokenStore.getInstance();
  const make = (id, rank = 0) => {
    const token = new api.TokenConfig('JBSWY3DPEHPK3PXP', 0, 'BatchFixture', id);
    token.TokenUUID = id;
    token.RankScore = rank;
    return token;
  };
  for (let i = 0; i < count; i++) {
    const token = make(`old-${i}`, i);
    data.set(prefix + token.TokenUUID, JSON.stringify(token));
    secrets.set(token.TokenUUID, token.TokenSecret);
  }
  await store.initTokenStore();
  calls.length = events.length = 0;
  return {
    ...api, store, kv, make, calls, events, secrets,
    reset: () => { calls.length = events.length = 0; },
    persisted: () => [...data].filter(([key]) => key.startsWith(prefix)).map(([, value]) => JSON.parse(value))
      .sort((a, b) => a.RankScore - b.RankScore),
    fail: kind => { failAt = kind; },
    failAsset: () => { assetFails = true; },
    pauseWrite: promise => { pause = promise; },
    disconnect: () => { kv._kvStore = undefined; }
  };
}
const sizes = (f, kind) => f.calls.filter(call => call[0] === kind).map(call => call[1]);
const ids = tokens => Array.from(tokens, token => token.TokenUUID);

for (const count of [1, 127, 128, 129, 257]) {
  test(`import ${count} tokens uses bounded batches and one notification`, async () => {
    const f = await fixture(3);
    const tokens = Array.from({ length: count }, (_, i) => f.make(`new-${i}`));
    await f.store.updateTokens(tokens);
    assert.equal(f.persisted().length, count + 3);
    assert.deepEqual(f.persisted().map(t => t.RankScore), Array.from({ length: count + 3 }, (_, i) => i));
    assert.equal(sizes(f, 'putBatch').length, Math.ceil(count / 128));
    assert.equal(sizes(f, 'putBatch').reduce((sum, n) => sum + n, 0), count);
    assert.equal(sizes(f, 'put').length, 0);
    assert.equal(sizes(f, 'assetPut').length, count);
    assert.deepEqual(f.events.map(e => e[0]), ['changed']);
    assert.equal(f.calls.filter(c => c[0] === 'commit').length, 1);
    assert.equal(tokens[0].RankScore, 0, 'input was not mutated');
  });
}

test('import progress counts actual ASSET work, and DONE follows KV commit and all secrets', async () => {
  const f = await fixture(1);
  const updates = [];
  await f.store.updateTokens([f.make('old-0'), f.make('new-1'), f.make('new-2')], update => {
    updates.push({ ...plain(update), assetWrites: sizes(f, 'assetPut').length,
      commits: f.calls.filter(call => call[0] === 'commit').length });
  });
  assert.equal(updates.at(-1).assetWrites, 2);
  assert.equal(updates.at(-1).commits, 1);
  const secrets = updates.filter(p => p.stage === f.TokenBatchStage.WRITING_SECRETS);
  assert.deepEqual(secrets.map(p => p.completed), [0, 1, 2]);
  assert.equal(secrets.every(p => p.total === 2), true, 'unchanged secret is not counted');
  assert.equal(updates.at(-1).stage, f.TokenBatchStage.DONE);
  assert.ok(updates.findIndex(p => p.stage === f.TokenBatchStage.COMMITTING) < updates.findIndex(p => p.stage === f.TokenBatchStage.WRITING_SECRETS));
});

test('delete progress follows KV removal and only finishes after ASSET cleanup', async () => {
  const f = await fixture(3);
  const updates = [];
  await f.store.deleteTokens(['old-0', 'old-2'], p => updates.push(plain(p)));
  assert.deepEqual(updates.filter(p => p.stage === f.TokenBatchStage.REMOVING_SECRETS).map(p => p.completed), [0, 1, 2]);
  assert.equal(updates.at(-1).stage, f.TokenBatchStage.DONE);
});

test('failed batch reports rollback without false DONE; observer failure never alters persistence', async () => {
  const f = await fixture(2);
  const updates = [];
  f.fail('commit');
  await assert.rejects(f.store.setTokensFavorite(['old-0'], true, p => updates.push(plain(p))));
  assert.equal(updates.at(-1).stage, f.TokenBatchStage.ROLLING_BACK);
  assert.equal(updates.some(p => p.stage === f.TokenBatchStage.DONE), false);
  await f.store.updateTokens([f.make('new')], () => { throw new Error('UI was destroyed'); });
  assert.equal(f.persisted().length, 3);
  assert.equal(f.events.length, 1);
});

test('empty/no-op progress finishes without database calls or token notifications', async () => {
  const f = await fixture(1);
  const updates = [];
  await f.store.setTokensFavorite(['old-0'], false, p => updates.push(plain(p)));
  await f.store.updateTokens([], p => updates.push(plain(p)));
  await f.store.deleteTokens([], p => updates.push(plain(p)));
  assert.equal(updates.length, 3);
  assert.equal(updates.every(p => p.stage === f.TokenBatchStage.DONE), true);
  assert.equal(f.calls.length, 0);
  assert.equal(f.events.length, 0);
});

test('snapshot preserves all token fields, including Forti/Steam/icon metadata', async () => {
  const f = await fixture();
  const original = f.make('snapshot', 41);
  original.TokenType = f.otpType.Steam;
  original.TokenAlgorithm = 'SHA512';
  original.TokenDigits = 8;
  original.TokenCounter = 99;
  original.TokenPeriod = 60;
  original.FortiToken = 'generated-forti';
  original.FortiDevID = 'generated-device';
  original.TokenGroupId = 'work';
  original.TokenFavorite = true;
  original.TokenIconPath = 'generated/icon.png';
  original.TokenExternalCode = '123456';
  original.SteamMaFile = { shared_secret: 'generated-only' };
  const copy = f.copyTokenConfig(original);
  assert.notEqual(copy, original);
  assert.deepEqual(plain(copy), plain(original));
});

test('URI parser skips invalid input; repeated URIs still create separate UUIDs', async () => {
  const f = await fixture();
  const uri = 'otpauth://totp/Batch:User?secret=JBSWY3DPEHPK3PXP';
  const tokens = f.parseOtpAuthUris([uri, 'bad', uri, 'otpauth://totp/X']);
  assert.equal(tokens.length, 2);
  assert.notEqual(tokens[0].TokenUUID, tokens[1].TokenUUID);
  await f.store.updateTokens(tokens);
  assert.equal(f.persisted().length, 2);
  assert.equal(f.events.length, 1);
});

test('backup update preserves existing rank/favorite but imports group and new content', async () => {
  const f = await fixture(3);
  await f.store.setTokensFavorite(['old-1'], true);
  f.reset();
  const updated = f.make('old-1', 999);
  updated.TokenName = 'Restored';
  updated.TokenGroupId = 'work';
  updated.TokenFavorite = false;
  await f.store.updateTokens([updated]);
  const saved = f.persisted()[1];
  assert.equal(saved.RankScore, 1);
  assert.equal(saved.TokenFavorite, true);
  assert.equal(saved.TokenGroupId, 'work');
  assert.equal(saved.TokenName, 'Restored');
  assert.equal(sizes(f, 'assetPut').length, 0, 'unchanged secret avoids ASSET');
  assert.deepEqual(f.events.map(e => e[0]), ['changed'], 'even overwrite-only default-sort import refreshes');
});

test('new backup favorite is retained; duplicate UUID is last content wins without duplicate rank', async () => {
  const f = await fixture(2);
  const first = f.make('new'); first.TokenFavorite = true;
  const last = f.make('new'); last.TokenName = 'Last';
  await f.store.updateTokens([first, f.make('another'), last]);
  assert.deepEqual(ids(f.persisted()), ['old-0', 'old-1', 'new', 'another']);
  assert.equal(f.persisted()[2].TokenName, 'Last');
  assert.equal(f.persisted()[2].TokenFavorite, true);
  assert.deepEqual(sizes(f, 'putBatch'), [2]);
  assert.equal(sizes(f, 'assetPut').length, 2);
});

test('empty operations and missing/duplicate IDs do not produce redundant writes/events', async () => {
  const f = await fixture(3);
  await f.store.updateTokens([]);
  await f.store.deleteTokens(['absent']);
  await f.store.setTokensFavorite(['absent', 'old-0', 'old-0'], false);
  assert.equal(f.calls.length, 0);
  assert.equal(f.events.length, 0);
});

test('favorite/unfavorite only writes changed rows, does not touch ASSET, persists after reload', async () => {
  const f = await fixture(257);
  const selection = ids(f.persisted());
  await f.store.setTokensFavorite(selection, true);
  assert.deepEqual(sizes(f, 'putBatch'), [128, 128, 1]);
  assert.equal(f.persisted().every(token => token.TokenFavorite), true);
  assert.equal(sizes(f, 'assetPut').length + sizes(f, 'assetDelete').length, 0);
  assert.equal(f.events.length, 1);
  f.reset();
  await f.store.setTokensFavorite(selection, true);
  assert.equal(f.calls.length, 0);
  await f.store.setTokensFavorite(['old-0', 'old-0', 'absent'], false);
  assert.deepEqual(sizes(f, 'putBatch'), [1]);
  await f.store.LoadTokenByDataBase();
  assert.equal((await f.store.getTokens())[0].TokenFavorite, false);
  assert.equal((await f.store.getTokens())[1].TokenFavorite, true);
});

test('mixed favorites skip already-correct rows and keep caller snapshots unchanged', async () => {
  const f = await fixture(3);
  const old = await f.store.getTokens();
  await f.store.setTokensFavorite(['old-0'], true);
  f.reset();
  await f.store.setTokensFavorite(['old-0', 'old-1'], true);
  assert.deepEqual(sizes(f, 'putBatch'), [1]);
  assert.equal(old[0].TokenFavorite, false);
  assert.equal(old[1].TokenFavorite, false);
});

test('sparse delete computes final ranks once and only rewrites affected survivors', async () => {
  const f = await fixture(8);
  await f.store.deleteTokens(['old-6', 'old-2', 'old-2', 'absent']);
  assert.deepEqual(ids(f.persisted()), ['old-0', 'old-1', 'old-3', 'old-4', 'old-5', 'old-7']);
  assert.deepEqual(f.persisted().map(t => t.RankScore), [0, 1, 2, 3, 4, 5]);
  assert.deepEqual(sizes(f, 'putBatch'), [4]);
  assert.deepEqual(sizes(f, 'deleteBatch'), [2]);
  assert.equal(sizes(f, 'put').length, 0);
  assert.equal(sizes(f, 'assetDelete').length, 2);
  assert.equal(f.events.length, 1);
  assert.equal(f.calls.find(c => c[0] === 'putBatch')[2].includes(prefix + 'old-2'), false);
});

test('delete all 1000 tokens makes zero rank writes and 8 delete batches, not 500500 puts', async () => {
  const f = await fixture(1000);
  await f.store.deleteTokens(ids(f.persisted()).reverse());
  assert.equal(f.persisted().length, 0);
  assert.equal((await f.store.getTokens()).length, 0);
  assert.equal(sizes(f, 'putBatch').length + sizes(f, 'put').length, 0);
  assert.deepEqual(sizes(f, 'deleteBatch'), [128, 128, 128, 128, 128, 128, 128, 104]);
  assert.equal(f.events.length, 1);
});

test('deleting tail does not rewrite unaffected tokens', async () => {
  const f = await fixture(4);
  await f.store.deleteTokens(['old-2', 'old-3']);
  assert.deepEqual(sizes(f, 'putBatch'), []);
  assert.deepEqual(ids(f.persisted()), ['old-0', 'old-1']);
});

for (const operation of ['import', 'favorite', 'delete']) {
  for (const phase of ['begin', 'putBatch', 'commit']) {
    test(`${operation}: ${phase} failure keeps KV, memory and ASSET unchanged; queue recovers`, async () => {
      const f = await fixture(5);
      const before = f.persisted();
      const secrets = [...f.secrets];
      f.fail(phase);
      const promise = operation === 'import' ? f.store.updateTokens([f.make('new')]) :
        operation === 'favorite' ? f.store.setTokensFavorite(['old-0'], true) : f.store.deleteTokens(['old-0']);
      await assert.rejects(promise);
      assert.deepEqual(f.persisted(), before);
      assert.deepEqual(plain(await f.store.getTokens()), before);
      assert.deepEqual([...f.secrets], secrets);
      assert.equal(f.events.length, 0);
      assert.equal(f.calls.filter(c => c[0] === 'rollback').length, phase === 'begin' ? 0 : 1);
      await f.store.setTokensFavorite(['old-1'], true);
      assert.equal(f.persisted()[1].TokenFavorite, true);
    });
  }
}

test('deleteBatch failure rolls back preceding survivor rank writes too', async () => {
  const f = await fixture(5);
  const before = f.persisted();
  f.fail('deleteBatch');
  await assert.rejects(f.store.deleteTokens(['old-0', 'old-2']));
  assert.deepEqual(f.persisted(), before);
  assert.deepEqual(plain(await f.store.getTokens()), before);
  assert.equal(f.events.length, 0);
  assert.equal(sizes(f, 'assetDelete').length, 0);
});

test('uninitialized database fails loudly rather than reporting successful import', async () => {
  const f = await fixture();
  f.disconnect();
  await assert.rejects(f.store.updateTokens([f.make('new')]), /not initialized/);
  assert.equal((await f.store.getTokens()).length, 0);
  assert.equal(f.events.length, 0);
});

test('no memory/event/ASSET publication before commit; queued mutations and reload see latest state', async () => {
  const f = await fixture(3);
  let release;
  f.pauseWrite(new Promise(resolve => { release = resolve; }));
  const imported = f.make('new');
  const pendingImport = f.store.updateTokens([imported]);
  imported.TokenName = 'Caller changed after dispatch';
  const pendingFavorite = f.store.setTokensFavorite(['new'], true);
  const pendingDelete = f.store.deleteTokens(['old-0']);
  const pendingReload = f.store.LoadTokenByDataBase();
  // Flush microtasks only, not a timer-based performance assertion.
  for (let i = 0; i < 10; i++) await Promise.resolve();
  assert.equal((await f.store.getTokens()).length, 3);
  assert.equal(f.events.length, 0);
  assert.equal(sizes(f, 'assetPut').length, 0);
  release();
  await Promise.all([pendingImport, pendingFavorite, pendingDelete, pendingReload]);
  assert.deepEqual(ids(await f.store.getTokens()), ['old-1', 'old-2', 'new']);
  assert.equal(f.persisted()[2].TokenFavorite, true);
  assert.equal(f.persisted()[2].TokenName, 'new');
  assert.deepEqual(f.persisted().map(t => t.RankScore), [0, 1, 2]);
});

test('ordinary KV writes cannot be absorbed by a failing batch transaction', async () => {
  const f = await fixture();
  let release;
  f.pauseWrite(new Promise(resolve => { release = resolve; }));
  f.fail('putBatch');
  const batch = f.store.updateTokens([f.make('new')]);
  for (let i = 0; i < 10; i++) await Promise.resolve();
  const setting = f.kv.setValue('setting', { preserved: true });
  const string = f.kv.setString('plain', 'preserved');
  release();
  await assert.rejects(batch);
  await Promise.all([setting, string]);
  assert.deepEqual(plain(await f.kv.getValue('setting')), { preserved: true });
  assert.equal(await f.kv.getString('plain'), 'preserved');
  assert.equal(f.persisted().length, 0);
});

test('changed/cleared/oversized secrets update or clear ASSET only after commit', async () => {
  const f = await fixture(3);
  const changed = f.make('old-0'); changed.TokenSecret = 'NEWSECRET';
  const cleared = f.make('old-1'); cleared.TokenSecret = '';
  const oversized = f.make('old-2'); oversized.TokenSecret = 'X'.repeat(901);
  await f.store.updateTokens([changed, cleared, oversized]);
  assert.equal(f.secrets.get('old-0'), 'NEWSECRET');
  assert.equal(f.secrets.has('old-1'), false);
  assert.equal(f.secrets.has('old-2'), false);
  assert.equal(f.persisted()[2].TokenSecret.length, 901);
  const commit = f.calls.findIndex(c => c[0] === 'commit');
  assert.ok(f.calls.findIndex(c => c[0] === 'assetPut') > commit);
});

test('ASSET failure preserves committed encrypted KV fallback and discards stale ASSET', async () => {
  const f = await fixture(1);
  const token = f.make('old-0'); token.TokenSecret = 'CHANGEDSECRET';
  f.failAsset();
  await f.store.updateTokens([token]);
  assert.equal(f.persisted()[0].TokenSecret, 'CHANGEDSECRET');
  assert.equal((await f.store.getTokens())[0].TokenSecret, 'CHANGEDSECRET');
  assert.equal(f.secrets.has('old-0'), false);
  assert.equal(f.events.length, 1);
});

test('invalid token or NFC input rejects whole import before writes', async () => {
  const f = await fixture(1);
  const external = f.make('external'); external.TokenType = f.otpType.NFC_external;
  await assert.rejects(f.store.updateTokens([f.make('new'), external]));
  const invalid = f.make('bad'); invalid.TokenSecret = undefined;
  await assert.rejects(f.store.updateTokens([f.make('new'), invalid]));
  assert.equal(f.persisted().length, 1);
  assert.equal(f.calls.length, 0);
});

test('single update retains precise event, favorite/deletion delegate to atomic batch paths', async () => {
  const f = await fixture(2);
  const token = f.make('old-0'); token.TokenName = 'Edited';
  await f.store.updateToken(token);
  assert.deepEqual(f.events.map(e => e[0]), ['single']);
  await f.store.setTokenFavorite('old-0', true);
  await f.store.deleteToken('old-1');
  assert.equal(f.persisted()[0].TokenName, 'Edited');
  assert.equal(f.persisted()[0].TokenFavorite, true);
  assert.equal(f.persisted().length, 1);
});

test('second put/delete chunk failure rolls back all earlier chunks', async () => {
  const f = await fixture(257);
  const before = f.persisted();
  f.fail('putBatch:2');
  await assert.rejects(f.store.setTokensFavorite(ids(before), true));
  assert.deepEqual(f.persisted(), before);
  assert.deepEqual(plain(await f.store.getTokens()), before);
  f.reset();
  f.fail('deleteBatch:2');
  await assert.rejects(f.store.deleteTokens(ids(before)));
  assert.deepEqual(f.persisted(), before);
  assert.equal(sizes(f, 'assetDelete').length, 0);
});

test('deleting appended tokens does not normalize historical rank gaps', async () => {
  const f = await fixture(2);
  // Seed legacy data through the SDK boundary, then use the real load/delete flow.
  const historical = f.make('old-1', 7);
  await f.kv.setValue(prefix + 'old-1', historical);
  await f.store.LoadTokenByDataBase();
  const before = f.persisted();
  // Existing import assigns new ranks using array length; keep this test focused on tail cleanup.
  const extra = f.make('test-tail', 8);
  await f.kv.setValue(prefix + extra.TokenUUID, extra);
  await f.store.LoadTokenByDataBase();
  f.reset();
  await f.store.deleteTokens(['test-tail']);
  assert.deepEqual(f.persisted(), before);
  assert.equal(sizes(f, 'putBatch').length, 0);
});

test('list bulk refresh replaces keys only for changed token objects and reloads once', async () => {
  const f = await fixture(2);
  const listSource = readFileSync(new URL('../entry/src/main/ets/pages/TokenListPage.ets', import.meta.url), 'utf8');
  const start = listSource.indexOf('  onTokensChange(');
  const end = listSource.indexOf('\n  }', start) + 4;
  const fn = stripTypeScriptTypes(listSource.slice(start, end).replace('  onTokensChange(', 'function onTokensChange('));
  const handle = runInNewContext(fn + '\nonTokensChange;', { TokenConfigVM: f.TokenConfigVM });
  let rows = (await f.store.getTokens()).map(token => new f.TokenConfigVM(token));
  const oldKeys = rows.map(row => row.objid);
  let reloads = 0;
  const dataSource = { totalCount: () => rows.length, getData: i => rows[i], updateData: next => { rows = next; reloads++; } };
  const changed = f.make('old-1'); changed.TokenFavorite = true;
  handle.call({ dataSource }, { value: () => ({ now: [rows[0].config, changed, f.make('new')] }) });
  assert.equal(rows[0].objid, oldKeys[0]);
  assert.notEqual(rows[1].objid, oldKeys[1]);
  assert.equal(rows[1].config.TokenFavorite, true);
  assert.equal(rows[2].objid, 'new');
  assert.equal(reloads, 1);
});

test('NFC batch removal is session-only, duplicate-safe and notifies once', async () => {
  const f = await fixture();
  const events = [];
  const { NfcSessionTokens } = runInNewContext(source('entry/src/main/ets/oath/NfcSessionTokens.ets') + '\n({ NfcSessionTokens });', {
    TokenConfig: f.TokenConfig, otpType: f.otpType, Logger: { info() {} },
    AppStorage: { get: () => ({ eventHub: { emit: event => events.push(event) } }) },
    EVENT_NAMES: { NFC_EXTERNAL_TOKENS_CHANGED: 'nfc' }
  });
  const session = NfcSessionTokens.getInstance();
  session.tokens = [f.make('nfc-a'), f.make('nfc-b'), f.make('nfc-c')];
  session.removeMany(['nfc-a', 'nfc-a', 'nfc-c']);
  assert.deepEqual(ids(session.getTokens()), ['nfc-b']);
  assert.deepEqual(events, ['nfc']);
  session.removeMany(['missing']);
  assert.equal(events.length, 1);
  assert.equal(f.calls.length, 0);
});

test('rank changes are queued/atomic and maintain order on persistence failure', async () => {
  const f = await fixture(5);
  await f.store.updateTokenRank(0, 4);
  assert.deepEqual(ids(f.persisted()), ['old-1', 'old-2', 'old-3', 'old-4', 'old-0']);
  assert.deepEqual(sizes(f, 'putBatch'), [5]);
  const before = f.persisted();
  f.fail('commit');
  await assert.rejects(f.store.updateTokenRank(4, 0));
  assert.deepEqual(plain(await f.store.getTokens()), before);
});

test('steam high-privilege credentials are stripped from KV while TokenSecret is kept', async () => {
  const f = await fixture(0);
  const token = f.make('steam-1');
  token.TokenType = f.otpType.Steam;
  const auth = new f.SteamAuth();
  auth.accountName = 'steamuser';
  auth.steamid = '76561198000000000';
  auth.deviceId = 'android:11111111-2222-3333-4444-555555555555';
  auth.tokenGid = 'gid-1';
  auth.identitySecret = 'identity-secret';
  auth.revocationCode = 'revoke-code';
  auth.refreshToken = 'refresh-token';
  token.SteamAuth = auth;

  await f.store.updateToken(token);
  const [persisted] = f.persisted();

  // 动态码密钥必须保留：手表显示与云备份恢复都依赖它
  assert.equal(persisted.TokenSecret, 'JBSWY3DPEHPK3PXP');
  assert.equal(persisted.TokenType, f.otpType.Steam);
  // 高权限凭证不得进入加密 KV（KV 会被手表同步与云备份原样序列化）
  assert.equal(persisted.SteamAuth.identitySecret, '');
  assert.equal(persisted.SteamAuth.revocationCode, '');
  assert.equal(persisted.SteamAuth.refreshToken, '');
  // 非敏感元数据照常持久化
  assert.equal(persisted.SteamAuth.steamid, '76561198000000000');
  assert.equal(persisted.SteamAuth.deviceId, 'android:11111111-2222-3333-4444-555555555555');
  assert.equal(persisted.SteamAuth.accountName, 'steamuser');

  // 内存中的对象仍持有明文，供本机交易确认/撤销使用
  const inMemory = await f.store.getTokens();
  assert.equal(inMemory[0].SteamAuth.refreshToken, 'refresh-token');
  assert.equal(inMemory[0].SteamAuth.identitySecret, 'identity-secret');
});

test('legacy mafile secrets are stripped from KV too', async () => {
  const f = await fixture(0);
  const token = f.make('steam-legacy');
  token.TokenType = f.otpType.Steam;
  const file = {
    shared_secret: 'JBSWY3DPEHPK3PXP', serial_number: '1', revocation_code: 'R1',
    uri: 'otpauth://totp/Steam:u?secret=JBSWY3DPEHPK3PXP&issuer=Steam', server_time: 1,
    account_name: 'u', token_gid: 'g', identity_secret: 'identity-secret', secret_1: 's1',
    status: 2, device_id: 'android:dev', fully_enrolled: true, Session: null
  };
  token.SteamMaFile = file;

  await f.store.updateToken(token);
  const [persisted] = f.persisted();
  assert.equal(persisted.SteamMaFile.shared_secret, '');
  assert.equal(persisted.SteamMaFile.identity_secret, '');
  assert.equal(persisted.SteamMaFile.revocation_code, '');
  assert.equal(persisted.SteamMaFile.secret_1, '');
  assert.equal(persisted.SteamMaFile.account_name, 'u');
});
