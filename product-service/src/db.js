const { Pool } = require('pg');
const credentials = require('./db-secret');
const logger = require('./logger');

// RDS connection settings come from environment variables; the credentials come from db-secret.js (AWS Secrets
// Manager in AWS, DB_USER and DB_PASSWORD locally). Never hardcode credentials.
// DB_SSL defaults to on, since RDS supports TLS; set DB_SSL=false only for local development.
const useSsl = process.env.DB_SSL !== 'false';

// PostgreSQL error code for a failed password login
const INVALID_PASSWORD = '28P01';

// Same interface as a pg Pool for the parts the app uses (query, end), so callers do not change.
function createDb({ credentials: creds = credentials, PoolImpl = Pool, env = process.env } = {}) {
  let poolPromise = null;

  function getPool() {
    if (!poolPromise) {
      poolPromise = creds.get().then((c) => {
        const pool = new PoolImpl({
          host: env.DB_HOST,
          port: Number(env.DB_PORT) || 5432,
          database: env.DB_NAME,
          user: c.username,
          // Called for every new connection, so after a rotation a reconnect uses the refreshed secret
          password: async () => (await creds.get()).password,
          max: Number(env.DB_POOL_MAX) || 10,
          idleTimeoutMillis: 30000,
          connectionTimeoutMillis: 5000,
          // rejectUnauthorized=false accepts the RDS cert without bundling the AWS CA;
          // mount the RDS CA bundle and enable verification for stricter setups.
          ssl: useSsl ? { rejectUnauthorized: env.DB_SSL_REJECT_UNAUTHORIZED === 'true' } : false,
        });
        pool.on('error', (err) => {
          logger.error('Unexpected idle database client error', { error: err.message });
        });
        return pool;
      }).catch((err) => {
        poolPromise = null; // try again on the next call
        throw err;
      });
    }
    return poolPromise;
  }

  async function query(text, params) {
    const seen = creds.version();
    try {
      return await (await getPool()).query(text, params);
    } catch (err) {
      // The password was rotated since this task read the secret. Retry once with the current one: if another request has
      // already fetched it since this query started (the version changed) just retry, otherwise fetch it first.
      if (err.code === INVALID_PASSWORD && creds.canRefresh() && (creds.version() !== seen || (await creds.refresh()))) {
        logger.warn('Database login failed, retrying with the current secret');
        return (await getPool()).query(text, params);
      }
      throw err;
    }
  }

  async function end() {
    if (!poolPromise) return;
    const pool = await poolPromise.catch(() => null);
    poolPromise = null;
    if (pool) await pool.end();
  }

  return { query, end };
}

module.exports = { createDb, ...createDb() };
