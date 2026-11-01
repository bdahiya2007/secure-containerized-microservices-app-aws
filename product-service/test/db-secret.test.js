// Credentials come from Secrets Manager when DB_SECRET_ARN is set, otherwise from DB_USER and DB_PASSWORD.
// A fake client stands in for AWS, so these tests need no network and no credentials.
const test = require('node:test');
const assert = require('node:assert/strict');

const logger = require('../src/logger');
const { create } = require('../src/db-secret');

logger.setSink(() => {});

// Made-up values, built in pieces so no ARN or password literal sits in the file
const ARN = ['arn:aws:secretsmanager:us-east-1', '0'.repeat(12), 'secret:rds!db-example-AbCdEf'].join(':');
const secret = (username, pw) => ({ username, password: pw });

function fakeClient(...secrets) {
  const calls = [];
  return {
    calls,
    send: async (command) => {
      calls.push(command.input);
      const next = secrets[Math.min(calls.length - 1, secrets.length - 1)];
      return { SecretString: typeof next === 'string' ? next : JSON.stringify(next) };
    },
  };
}

test('without DB_SECRET_ARN the credentials come from DB_USER and DB_PASSWORD, and nothing can be refreshed', async () => {
  const creds = create({ secretArn: '', env: { DB_USER: 'app', DB_PASSWORD: 'local-pw' } });
  assert.deepEqual(await creds.get(), secret('app', 'local-pw'));
  assert.equal(creds.canRefresh(), false);
  assert.equal(await creds.refresh(), false);
});

test('with DB_SECRET_ARN the credentials are read from the secret and cached', async () => {
  const client = fakeClient(secret('dbadmin', 'first'));
  const creds = create({ secretArn: ARN, client });
  assert.equal(creds.canRefresh(), true);
  assert.deepEqual(await creds.get(), secret('dbadmin', 'first'));
  await creds.get();
  assert.equal(client.calls.length, 1, 'the second get() uses the cache');
  assert.equal(client.calls[0].SecretId, ARN);
});

test('environment variables are ignored when a secret is configured', async () => {
  const client = fakeClient(secret('from-secret', 'secret-pw'));
  const creds = create({ secretArn: ARN, client, env: { DB_USER: 'from-env', DB_PASSWORD: 'env-pw' } });
  assert.deepEqual(await creds.get(), secret('from-secret', 'secret-pw'));
});

test('concurrent first calls share one request', async () => {
  const client = fakeClient(secret('u', 'p'));
  const creds = create({ secretArn: ARN, client });
  await Promise.all([creds.get(), creds.get(), creds.get()]);
  assert.equal(client.calls.length, 1);
});

test('refresh() fetches the secret again and returns the rotated password', async () => {
  let clock = 1000000;
  const client = fakeClient(secret('u', 'old'), secret('u', 'new'));
  const creds = create({ secretArn: ARN, client, now: () => clock });
  assert.equal((await creds.get()).password, 'old');
  clock += 60000; // a minute later
  assert.equal(await creds.refresh(), true);
  assert.equal((await creds.get()).password, 'new');
  assert.equal(client.calls.length, 2);
});

test('refresh() does not fetch again within ten seconds of the last fetch', async () => {
  let clock = 1000000;
  const client = fakeClient(secret('u', 'p'));
  const creds = create({ secretArn: ARN, client, now: () => clock });
  await creds.get();
  clock += 3000;
  assert.equal(await creds.refresh(), false);
  assert.equal(client.calls.length, 1);
});

test('a secret that is not valid JSON fails without putting the secret text in the error', async () => {
  const creds = create({ secretArn: ARN, client: fakeClient('hunter2-not-json') });
  await assert.rejects(creds.get(), (err) => {
    assert.match(err.message, /not valid JSON/);
    assert.ok(!err.message.includes('hunter2'));
    return true;
  });
});

test('a secret without a username and password is rejected', async () => {
  await assert.rejects(create({ secretArn: ARN, client: fakeClient({ username: 'u' }) }).get(), /no username and password/);
  await assert.rejects(create({ secretArn: ARN, client: fakeClient({ password: 'p' }) }).get(), /no username and password/);
  await assert.rejects(create({ secretArn: ARN, client: fakeClient(secret('', '')) }).get(), /no username and password/);
});

test('the credentials are never written to the log', async () => {
  const written = [];
  logger.setSink((level, line) => written.push(line));
  try {
    const creds = create({ secretArn: ARN, client: fakeClient(secret('dbadmin', 'super-secret-value')) });
    await creds.get();
    await creds.refresh().catch(() => {});
    assert.ok(written.length > 0, 'something is logged');
    assert.ok(!written.join('\n').includes('super-secret-value'));
  } finally {
    logger.setSink(() => {});
  }
});

test('a failed fetch is not cached: the next call tries again', async () => {
  let n = 0;
  const client = { send: async () => { n += 1; if (n === 1) throw new Error('AccessDenied'); return { SecretString: JSON.stringify(secret('u', 'p')) }; } };
  const creds = create({ secretArn: ARN, client });
  await assert.rejects(creds.get(), /AccessDenied/);
  assert.deepEqual(await creds.get(), secret('u', 'p'));
});
