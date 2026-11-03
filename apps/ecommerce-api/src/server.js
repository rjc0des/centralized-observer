'use strict';

const { Pool, types } = require('pg');
const { createClient, ClientOfflineError } = require('redis');
const { buildApp, loggerOptions } = require('./app');
const { createStore } = require('./store');
const { metrics, trackPool, exceptionType } = require('./metrics');

const PORT = 3000;
const DEPENDENCY_POLL_MS = 5000;
const REDIS_STARTUP_GRACE_MS = 2000;

// pg returns BIGINT (OID 20) as a string to avoid precision loss. Our bigints are
// money totals in cents, far below Number.MAX_SAFE_INTEGER (2^53), so parse to Number.
types.setTypeParser(20, Number);

async function main() {
  // Connection settings come from the standard PG* environment variables.
  const pool = new Pool({
    max: 10,
    connectionTimeoutMillis: 2000,
    idleTimeoutMillis: 30000,
    statement_timeout: 5000,
  });
  trackPool(pool);

  // Health checks get their own connection, so a saturated request pool (slow queries,
  // lock waits) is not misreported as "Postgres down". Pool saturation shows up in
  // db_pool_connections{state="waiting"} and POOL_TIMEOUT exceptions instead.
  const healthPool = new Pool({ max: 1, connectionTimeoutMillis: 1000, statement_timeout: 1000 });

  // disableOfflineQueue: while Redis is down, commands fail immediately instead of
  // queueing, so the API falls back to Postgres rather than hanging.
  const redis = createClient({
    url: process.env.REDIS_URL,
    password: process.env.REDIS_PASSWORD,
    disableOfflineQueue: true,
    socket: {
      connectTimeout: 2000,
      reconnectStrategy: (retries) => Math.min(250 * 2 ** retries, 5000),
    },
  });

  // While offline, every command fails with a generic ClientOfflineError; the actual
  // cause (ECONNREFUSED, WRONGPASS, DNS...) only arrives on the 'error' event. Keep it
  // so the dependency check reports why Redis is down, not just that it is.
  let lastRedisError = null;
  redis.on('ready', () => { lastRedisError = null; });
  const withCause = (err) => (err instanceof ClientOfflineError && lastRedisError ? lastRedisError : err);

  const cache = {
    get: (key) => redis.get(key),
    set: (key, value, ttlSeconds) => redis.set(key, value, { EX: ttlSeconds }),
    ping: () => redis.ping().catch((err) => { throw withCause(err); }),
  };

  const app = buildApp({
    store: createStore(pool, { healthPool }),
    cache,
    logger: loggerOptions({ environment: process.env.ENVIRONMENT || 'local', level: process.env.LOG_LEVEL }),
  });

  // Connection-level errors (e.g. Postgres restarted) surface here; the next query
  // reconnects. The dependency poller logs the outage itself, so these stay at debug.
  for (const p of [pool, healthPool]) p.on('error', (err) => app.log.debug({ err }, 'idle postgres client error'));
  redis.on('error', (err) => {
    lastRedisError = err;
    app.log.debug({ err }, 'redis client error');
  });

  // Not awaited: the API starts (degraded) even if Redis is down; the client keeps
  // reconnecting. The connect() promise only settles on success or on quit(), so a
  // rejection during shutdown is expected and not logged.
  let shuttingDown = false;
  redis.connect().catch((err) => { if (!shuttingDown) app.log.error({ err }, 'redis connect failed'); });

  // Wait up to 2s for Redis to become ready (errors during that window don't end the
  // wait), so a normal or slightly slow start doesn't log a false "redis connection failed".
  await new Promise((resolve) => {
    redis.once('ready', resolve);
    setTimeout(resolve, REDIS_STARTUP_GRACE_MS).unref();
  });

  // Schema migrations run before this, as the separate ecommerce-migrate job.
  await app.checkDependencies();
  const poller = setInterval(() => app.checkDependencies().catch(() => {}), DEPENDENCY_POLL_MS);
  poller.unref();

  await app.listen({ host: '0.0.0.0', port: PORT });

  const shutdown = async (signal) => {
    shuttingDown = true;
    app.log.info({ signal }, 'shutting down');
    clearInterval(poller);
    await app.close();
    await Promise.allSettled([pool.end(), healthPool.end(), redis.quit()]);
    process.exit(0);
  };
  process.once('SIGTERM', shutdown);
  process.once('SIGINT', shutdown);

  for (const event of ['uncaughtException', 'unhandledRejection']) {
    process.on(event, (err) => {
      metrics.exceptions.inc({ type: exceptionType(err) });
      app.log.fatal({ err }, event);
      process.exit(1);
    });
  }
}

main().catch((err) => {
  // Unexpected startup failure: log as JSON and exit non-zero so Docker restarts it.
  process.stdout.write(`${JSON.stringify({
    time: new Date().toISOString(),
    level: 'fatal',
    service: 'ecommerce-api',
    environment: process.env.ENVIRONMENT || 'local',
    msg: 'startup failed',
    err: { type: err.name, code: err.code, message: err.message },
  })}\n`);
  process.exit(1);
});
