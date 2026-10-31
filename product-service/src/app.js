const crypto = require('node:crypto');
const express = require('express');
const pool = require('./db');
const logger = require('./logger');

const app = express();
app.disable('x-powered-by');

// A request ID on every request, so an application log line can be matched to the load balancer's access log
// line (the ALB adds X-Amzn-Trace-Id). Only a safe-looking value is accepted, because the header is
// client-controlled and is echoed back in a response header.
const SAFE_TRACE_ID = /^[A-Za-z0-9=\-]{1,100}$/;

app.use((req, res, next) => {
  const incoming = req.get('x-amzn-trace-id');
  const requestId = incoming && SAFE_TRACE_ID.test(incoming) ? incoming : crypto.randomUUID();
  res.locals.requestId = requestId;
  res.setHeader('X-Request-Id', requestId);
  const start = process.hrtime.bigint();

  res.on('finish', () => {
    const fields = {
      request_id: requestId,
      method: req.method,
      path: req.path, // not req.url: a query string can carry tokens or personal data
      status: res.statusCode,
      duration_ms: Math.round(Number(process.hrtime.bigint() - start) / 1e5) / 10,
    };
    // The load balancer checks /health every 30 seconds on every task, so only log it when it fails
    if (req.path === '/health' && res.statusCode < 400) logger.debug('request', fields);
    else logger.info('request', fields);
  });
  next();
});

// Liveness/readiness probe for ALB target groups, ECS and Docker HEALTHCHECK.
// The database state is logged once when it changes, not on every check.
let databaseHealthy = true;

app.get('/health', async (req, res) => {
  try {
    await pool.query('SELECT 1');
    if (!databaseHealthy) {
      databaseHealthy = true;
      logger.info('Database recovered');
    }
    res.status(200).json({ status: 'ok' });
  } catch (err) {
    if (databaseHealthy) {
      databaseHealthy = false;
      logger.error('Database unavailable', { request_id: res.locals.requestId, error: err.message });
    }
    res.status(503).json({ status: 'unavailable' });
  }
});

app.get('/products', async (req, res) => {
  try {
    const { rows } = await pool.query(
      'SELECT id, name, description, price::float8 AS price, created_at FROM products ORDER BY id'
    );
    res.json(rows);
  } catch (err) {
    // A 5XX is unexpected, so this one includes the stack trace. The client only gets a generic message.
    logger.error('Failed to fetch products', {
      request_id: res.locals.requestId,
      error: err.message,
      stack: err.stack,
    });
    res.status(500).json({ error: 'Failed to fetch products' });
  }
});

app.use((req, res) => {
  res.status(404).json({ error: 'Not found' });
});

module.exports = app;
