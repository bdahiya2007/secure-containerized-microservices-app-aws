// The database wrapper retries once with a fresh secret when the password was rotated (PostgreSQL code 28P01).
// A fake pool and fake credentials stand in for PostgreSQL and AWS.
const test = require('node:test');
const assert = require('node:assert/strict');

const logger = require('../src/logger');
const { createDb } = require('../src/db');

logger.setSink(() => {});

const PW = ['not', 'a', 'real', 'password'].join('-'); // made up

function setup({ queryResults, canRefresh = true, refreshResults = [true], versionBumpedByOthers = false }) {
  const state = { refreshCalls: 0, pools: [], queries: 0, version: 1 };
  const creds = {
    canRefresh: () => canRefresh,
    get: async () => ({ username: 'dbadmin', password: PW }),
    version: () => state.version,
    refresh: async () => {
      const result = refreshResults[Math.min(state.refreshCalls++, refreshResults.length - 1)];
      if (result) state.version += 1;
      return result;
    },
  };
  class FakePool {
    constructor(config) { state.config = config; state.pools.push(this); }
    on() {}
    async query() {
      const next = queryResults[Math.min(state.queries++, queryResults.length - 1)];
      // Another request fetches the new password while this one is failing (a burst of parallel requests after a rotation)
      if (next instanceof Error && versionBumpedByOthers) state.version += 1;
      if (next instanceof Error) throw next;
      return next;
    }
    async end() { state.ended = true; }
  }
  return { state, db: createDb({ credentials: creds, PoolImpl: FakePool, env: { DB_HOST: 'h', DB_NAME: 'n' } }) };
}

const authError = () => Object.assign(new Error('password authentication failed'), { code: '28P01' });

test('the pool is built with the username from the credentials and a password function', async () => {
  const { state, db } = setup({ queryResults: [{ rows: [1] }] });
  await db.query('SELECT 1');
  assert.equal(state.config.user, 'dbadmin');
  assert.equal(typeof state.config.password, 'function');
  assert.equal(await state.config.password(), PW);
});

test('a failed login is retried once with a refreshed secret', async () => {
  const { state, db } = setup({ queryResults: [authError(), { rows: [{ ok: 1 }] }] });
  assert.deepEqual(await db.query('SELECT 1'), { rows: [{ ok: 1 }] });
  assert.equal(state.refreshCalls, 1);
  assert.equal(state.queries, 2);
});

test('a second failed login is not retried again', async () => {
  const { state, db } = setup({ queryResults: [authError()] });
  await assert.rejects(db.query('SELECT 1'), { code: '28P01' });
  assert.equal(state.queries, 2, 'one try and one retry');
  assert.equal(state.refreshCalls, 1);
});

test('other database errors are not retried', async () => {
  const { state, db } = setup({ queryResults: [Object.assign(new Error('boom'), { code: '57P01' })] });
  await assert.rejects(db.query('SELECT 1'), { code: '57P01' });
  assert.equal(state.queries, 1);
  assert.equal(state.refreshCalls, 0);
});

test('without a secret (local development) a failed login is not retried', async () => {
  const { state, db } = setup({ queryResults: [authError()], canRefresh: false });
  await assert.rejects(db.query('SELECT 1'), { code: '28P01' });
  assert.equal(state.queries, 1);
  assert.equal(state.refreshCalls, 0);
});

test('when the secret was just fetched (refresh declines) the failure is returned, not retried', async () => {
  const { state, db } = setup({ queryResults: [authError()], refreshResults: [false] });
  await assert.rejects(db.query('SELECT 1'), { code: '28P01' });
  assert.equal(state.queries, 1);
});

test('end() closes the pool, and it is safe to call without one', async () => {
  const { state, db } = setup({ queryResults: [{ rows: [] }] });
  await db.end();
  await db.query('SELECT 1');
  await db.end();
  assert.equal(state.ended, true);
});

test('a request that failed after another request already refreshed the secret is retried without fetching again', async () => {
  // This is what a burst of parallel requests does after a rotation: the first failure triggers the fetch, and the others,
  // failing a moment later, find the secret already fresh (refresh() would decline). They must still retry.
  const { state, db } = setup({ queryResults: [authError(), { rows: [{ ok: 1 }] }], refreshResults: [false], versionBumpedByOthers: true });
  assert.deepEqual(await db.query('SELECT 1'), { rows: [{ ok: 1 }] });
  assert.equal(state.refreshCalls, 0, 'no second fetch');
  assert.equal(state.queries, 2);
});

test('twenty parallel requests that all fail with the old password all succeed after one refresh', async () => {
  let failures = 0;
  const state = { version: 1, fetches: 0 };
  let inflight = null;
  const creds = {
    canRefresh: () => true,
    get: async () => ({ username: 'dbadmin', password: PW }),
    version: () => state.version,
    // Like the real one: one shared fetch, and a decline when the secret was fetched a moment ago
    refresh: async () => {
      if (inflight) { await inflight; return true; }
      if (state.fetches > 0) return false;
      inflight = new Promise((resolve) => setTimeout(resolve, 20)).then(() => { state.fetches += 1; state.version += 1; inflight = null; });
      await inflight;
      return true;
    },
  };
  class FakePool {
    on() {}
    async query() {
      if (state.version === 1) { failures += 1; throw authError(); } // still the old password
      return { rows: [{ ok: 1 }] };
    }
    async end() {}
  }
  const db = createDb({ credentials: creds, PoolImpl: FakePool, env: {} });
  const results = await Promise.allSettled(Array.from({ length: 20 }, () => db.query('SELECT 1')));
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 20);
  assert.equal(state.fetches, 1);
  assert.ok(failures >= 20);
});
