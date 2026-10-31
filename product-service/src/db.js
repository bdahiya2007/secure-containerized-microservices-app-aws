const { Pool } = require('pg');
const logger = require('./logger');

// RDS connection settings come from environment variables (never hardcode credentials).
// DB_SSL defaults to on, since RDS supports TLS; set DB_SSL=false only for local development.
const useSsl = process.env.DB_SSL !== 'false';

const pool = new Pool({
  host: process.env.DB_HOST,
  port: Number(process.env.DB_PORT) || 5432,
  database: process.env.DB_NAME,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  max: Number(process.env.DB_POOL_MAX) || 10,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
  // rejectUnauthorized=false accepts the RDS cert without bundling the AWS CA;
  // mount the RDS CA bundle and enable verification for stricter setups.
  ssl: useSsl ? { rejectUnauthorized: process.env.DB_SSL_REJECT_UNAUTHORIZED === 'true' } : false,
});

pool.on('error', (err) => {
  logger.error('Unexpected idle database client error', { error: err.message });
});

module.exports = pool;
