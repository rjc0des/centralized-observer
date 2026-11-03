'use strict';

const client = require('prom-client');

// Every label value here comes from a small fixed set: route templates (never raw
// URLs), a fixed method list, status codes, dependency names, result enums.
// IDs (order, user, request) must never become label values.

const registry = new client.Registry();
client.collectDefaultMetrics({ register: registry });

const KNOWN_METHODS = new Set(['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS']);
const normalizeMethod = (method) => (KNOWN_METHODS.has(method) ? method : 'OTHER');

// pg-pool's "no free connection in time" error has no code; give it one so pool
// exhaustion is distinguishable from other errors. (Matches pg 8.x's message text.)
const POOL_TIMEOUT = /timeout exceeded when trying to connect/i;

// Error class or code, e.g. "TypeError", "ECONNREFUSED", "57P01" (Postgres SQLSTATE).
// Clamped to a safe charset and length so a weird error can't mint arbitrary labels.
const exceptionType = (err) => {
  if (!err?.code && POOL_TIMEOUT.test(err?.message ?? '')) return 'POOL_TIMEOUT';
  return String(err?.code ?? err?.name ?? 'Error').replace(/[^A-Za-z0-9_]/g, '_').slice(0, 40);
};

const metrics = {
  httpRequests: new client.Counter({
    name: 'http_requests_total',
    help: 'HTTP requests handled, by method, route template and status code',
    labelNames: ['method', 'route', 'status_code'],
    registers: [registry],
  }),
  // Buckets include 0.5s exactly, so "p95 < 500ms" is measured without interpolation error.
  httpDuration: new client.Histogram({
    name: 'http_request_duration_seconds',
    help: 'HTTP request duration in seconds',
    labelNames: ['method', 'route', 'status_code'],
    buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
    registers: [registry],
  }),
  httpInFlight: new client.Gauge({
    name: 'http_requests_in_flight',
    help: 'HTTP requests currently being handled',
    registers: [registry],
  }),
  exceptions: new client.Counter({
    name: 'app_exceptions_total',
    help: 'Unhandled application exceptions, by error type',
    labelNames: ['type'],
    registers: [registry],
  }),
  cacheRequests: new client.Counter({
    name: 'cache_requests_total',
    help: 'Product cache lookups: hit, miss, or error (Redis unavailable)',
    labelNames: ['result'],
    registers: [registry],
  }),
  orders: new client.Counter({
    name: 'orders_total',
    help: 'Order attempts: created, rejected (stock/unknown product) or error (5xx)',
    labelNames: ['result'],
    registers: [registry],
  }),
  dependencyUp: new client.Gauge({
    name: 'dependency_up',
    help: '1 if the last check of the dependency succeeded, else 0',
    labelNames: ['dependency'],
    registers: [registry],
  }),
};

// Connection pool state is read from the pool at scrape time.
function trackPool(pool) {
  new client.Gauge({
    name: 'db_pool_connections',
    help: 'Postgres pool connections by state (total, idle, waiting clients)',
    labelNames: ['state'],
    registers: [registry],
    collect() {
      this.set({ state: 'total' }, pool.totalCount);
      this.set({ state: 'idle' }, pool.idleCount);
      this.set({ state: 'waiting' }, pool.waitingCount);
    },
  });
}

module.exports = { registry, metrics, trackPool, normalizeMethod, exceptionType };
