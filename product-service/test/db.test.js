// The database wrapper retries once with a fresh secret when the password was rotated (PostgreSQL code 28P01).
// A fake pool and fake credentials stand in for PostgreSQL and AWS.
const test = require('node:test');
const assert = require('node:assert/strict');

const logger = require('../src/logger');
const { createDb } = require('../src/db');

logger.setSink(() => {});

const PW = ['not', 'a', 'real', 'password'].join('-'); // made up

function setup({ queryResults, canRefresh = true, refreshResults = [true] }) {
  const state = { refreshCalls: 0, pools: [], queries: 0 };
  const creds = {
    canRefresh: () => canRefresh,
    get: async () => ({ username: 'dbadmin', password: PW }),
    refresh: async () => refreshResults[Math.min(state.refreshCalls++, refreshResults.length - 1)],
  };
  class FakePool {
    constructor(config) { state.config = config; state.pools.push(this); }
    on() {}
    async query() {
      const next = queryResults[Math.min(state.queries++, queryResults.length - 1)];
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
