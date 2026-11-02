// Run with: npm test (Node's built-in test runner, no extra dependencies).
// The database is deliberately unreachable (nothing listens on port 1), so these tests cover routing, request
// logging and the failure paths without needing PostgreSQL.
process.env.DB_HOST = '127.0.0.1';
process.env.DB_PORT = '1';
process.env.DB_SSL = 'false';
delete process.env.DB_PASSWORD;

const test = require('node:test');
const assert = require('node:assert/strict');
const { once } = require('node:events');

const logger = require('../src/logger');
const app = require('../src/app');
const pool = require('../src/db');

const lines = [];
logger.setSink((level, line) => lines.push(JSON.parse(line)));

let server;
let base;

test.before(async () => {
  server = app.listen(0, '127.0.0.1');
  await once(server, 'listening');
  base = `http://127.0.0.1:${server.address().port}`;
});

test.after(async () => {
  await new Promise((resolve) => server.close(resolve));
  await pool.end();
});

test.beforeEach(() => { lines.length = 0; });

const requestLines = () => lines.filter((l) => l.msg === 'request');

test('an unknown path returns 404 JSON and one structured request log line', async () => {
  const res = await fetch(`${base}/nope`);
  assert.equal(res.status, 404);
  assert.deepEqual(await res.json(), { error: 'Not found' });

  const [entry] = requestLines();
  assert.equal(entry.level, 'info');
  assert.equal(entry.method, 'GET');
  assert.equal(entry.path, '/nope');
  assert.equal(entry.status, 404);
  assert.equal(typeof entry.duration_ms, 'number');
  assert.equal(entry.request_id, res.headers.get('x-request-id'));
  assert.ok(!Number.isNaN(Date.parse(entry.time)));
});

test('a valid X-Amzn-Trace-Id from the load balancer becomes the request ID', async () => {
  const trace = 'Root=1-67891233-abcdef012345678912345678';
  const res = await fetch(`${base}/nope`, { headers: { 'X-Amzn-Trace-Id': trace } });
  assert.equal(res.headers.get('x-request-id'), trace);
  assert.equal(requestLines()[0].request_id, trace);
});

test('an unsafe trace ID is replaced by a generated one', async () => {
  const res = await fetch(`${base}/nope`, { headers: { 'X-Amzn-Trace-Id': 'bad value;{"x":1}' } });
  const id = res.headers.get('x-request-id');
  assert.match(id, /^[0-9a-f-]{36}$/);
  assert.equal(requestLines()[0].request_id, id);
});

test('the query string is never logged', async () => {
  await fetch(`${base}/nope?token=supersecret&email=a@b.c`);
  const text = JSON.stringify(lines);
  assert.equal(requestLines()[0].path, '/nope');
  assert.ok(!text.includes('supersecret'));
  assert.ok(!text.includes('a@b.c'));
});

test('a failing /products returns a generic 500 and logs the error with a stack and the request ID', async () => {
  const res = await fetch(`${base}/products`);
  assert.equal(res.status, 500);
  assert.deepEqual(await res.json(), { error: 'Failed to fetch products' });

  const failure = lines.find((l) => l.msg === 'Failed to fetch products');
  assert.equal(failure.level, 'error');
  assert.equal(failure.request_id, res.headers.get('x-request-id'));
  assert.match(failure.stack, /Error/);
  assert.equal(requestLines()[0].status, 500);
});

test('the database state is logged once when it fails, not on every health check', async () => {
  const first = await fetch(`${base}/health`);
  const second = await fetch(`${base}/health`);
  assert.equal(first.status, 503);
  assert.equal(second.status, 503);
  assert.deepEqual(await first.json(), { status: 'unavailable' });

  // Both checks fail and are logged as requests, but "Database unavailable" appears at most once overall
  assert.equal(requestLines().filter((l) => l.path === '/health' && l.status === 503).length, 2);
  assert.ok(lines.filter((l) => l.msg === 'Database unavailable').length <= 1);
});

test('no log line contains the word password or a database credential', async () => {
  await fetch(`${base}/products`);
  assert.ok(!JSON.stringify(lines).toLowerCase().includes('password'));
});

test('debug lines are not written at the default level', () => {
  logger.debug('hidden');
  logger.info('shown');
  assert.equal(lines.filter((l) => l.msg === 'hidden').length, 0);
  assert.equal(lines.filter((l) => l.msg === 'shown').length, 1);
});

test('the bare address returns a small JSON description that needs no database', async () => {
  // The database is unreachable in these tests, so a 200 here also proves the route does not touch it
  const res = await fetch(`${base}/`);
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-type'), /application\/json/);
  assert.deepEqual(await res.json(), {
    service: 'product-service',
    status: 'ok',
    endpoints: { products: '/products', health: '/health' },
  });
  assert.equal(requestLines().filter((l) => l.path === '/' && l.status === 200).length, 1);
});

test('an unknown path still returns 404 after the landing route was added', async () => {
  const res = await fetch(`${base}/nope`);
  assert.equal(res.status, 404);
  assert.deepEqual(await res.json(), { error: 'Not found' });
});
