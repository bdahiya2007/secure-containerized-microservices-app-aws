// One-off schema loader: runs db/schema.sql against the database named by the DB_* variables.
// Safe to run again: the SQL uses CREATE TABLE IF NOT EXISTS and only seeds an empty table.
const fs = require('fs');
const path = require('path');
const pool = require('./db');
const logger = require('./logger');

async function main() {
  const sql = fs.readFileSync(path.join(__dirname, '..', 'db', 'schema.sql'), 'utf8');
  await pool.query(sql);
  logger.info('Schema applied');
}

main()
  .then(() => pool.end())
  .catch(async (err) => {
    logger.error('Migration failed', { error: err.message });
    await pool.end().catch(() => {});
    process.exit(1);
  });
