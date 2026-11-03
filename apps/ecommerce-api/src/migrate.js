'use strict';

const fs = require('node:fs');
const path = require('node:path');

const MIGRATIONS_DIR = path.join(__dirname, '..', 'migrations');
// Arbitrary constant: serialises migrations if several instances start at once.
const LOCK_ID = 727001;

// ponytail: forward-only SQL files applied in name order, one transaction each,
// recorded in schema_migrations. Use a migration tool if down-migrations are needed.
async function migrate(pool, log) {
  const client = await pool.connect();
  try {
    await client.query('SELECT pg_advisory_lock($1)', [LOCK_ID]);
    await client.query(`CREATE TABLE IF NOT EXISTS schema_migrations (
      version text PRIMARY KEY,
      applied_at timestamptz NOT NULL DEFAULT now()
    )`);
    const { rows } = await client.query('SELECT version FROM schema_migrations');
    const applied = new Set(rows.map((r) => r.version));

    const files = fs.readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort();
    for (const file of files) {
      if (applied.has(file)) continue;
      await client.query('BEGIN');
      try {
        await client.query(fs.readFileSync(path.join(MIGRATIONS_DIR, file), 'utf8'));
        await client.query('INSERT INTO schema_migrations (version) VALUES ($1)', [file]);
        await client.query('COMMIT');
        log.info({ migration: file }, 'migration applied');
      } catch (err) {
        // If the connection itself died, ROLLBACK fails too; keep the original error.
        await client.query('ROLLBACK').catch(() => {});
        throw err;
      }
    }
  } finally {
    await client.query('SELECT pg_advisory_unlock($1)', [LOCK_ID]).catch(() => {});
    client.release();
  }
}

module.exports = { migrate };

// Run as a one-shot job (`node src/migrate.js`) with the owner role's PG* credentials,
// before the API starts. The API itself connects as a role that cannot change schema.
if (require.main === module) {
  const { Pool } = require('pg');
  const log = (level) => (fields, msg) => process.stdout.write(`${JSON.stringify({
    time: new Date().toISOString(),
    level,
    service: 'ecommerce-migrate',
    environment: process.env.ENVIRONMENT || 'local',
    ...fields,
    msg,
  })}\n`);
  const logger = { info: log('info'), error: log('error') };

  const pool = new Pool({ max: 1, connectionTimeoutMillis: 5000 });
  migrate(pool, logger)
    .then(() => { logger.info({}, 'migrations complete'); return pool.end(); })
    .catch((err) => {
      logger.error({ err: { type: err.name, code: err.code, message: err.message } }, 'migration failed');
      process.exitCode = 1;
      return pool.end();
    });
}
