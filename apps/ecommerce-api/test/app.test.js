'use strict';

// Unit tests with in-memory fakes for Postgres and Redis. Real-database behaviour
// (transactions, stock locking) is covered by tests/integration/ecommerce.sh.

const { test, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { Writable } = require('node:stream');
const { buildApp, loggerOptions } = require('../src/app');
const { createStore } = require('../src/store');
const { registry, normalizeMethod, exceptionType } = require('../src/metrics');

const PRODUCT = { id: '0190f8a1-0000-7000-8000-000000000001', sku: 'KB-001', name: 'Keyboard', price_cents: 8999, stock: 10 };
const ORDER_ID = '0190f8a1-0000-7000-8000-0000000000aa';

function fakeStore(overrides = {}) {
  const calls = { listProducts: 0 };
  return {
    calls,
    ping: async () => 1,
    listProducts: async () => { calls.listProducts++; return [PRODUCT]; },
    getOrder: async (id) => (id === ORDER_ID ? { id, items: [] } : null),
    createOrder: async () => ({ ok: true, order: { id: ORDER_ID, total_cents: 8999, items: [] } }),
    ...overrides,
  };
}

function fakeCache(overrides = {}) {
  const data = new Map();
  return {
    get: async (k) => data.get(k) ?? null,
    set: async (k, v) => { data.set(k, v); },
    ping: async () => 'PONG',
    ...overrides,
  };
}

const down = async () => { throw Object.assign(new Error('connect ECONNREFUSED'), { code: 'ECONNREFUSED' }); };

async function metricValue(name, labels) {
  const metric = (await registry.getMetricsAsJSON()).find((m) => m.name === name);
  const match = metric?.values.find((v) => Object.entries(labels).every(([k, val]) => v.labels[k] === val));
  return match?.value ?? 0;
}

beforeEach(() => registry.resetMetrics());

test('GET /products: miss, then served from cache', async () => {
  const store = fakeStore();
  const app = buildApp({ store, cache: fakeCache() });

  const first = await app.inject('/products');
  assert.equal(first.statusCode, 200);
  assert.equal(first.headers['x-cache'], 'miss');
  assert.deepEqual(first.json().products, [PRODUCT]);

  await new Promise((r) => setImmediate(r)); // cache write is fire-and-forget
  const second = await app.inject('/products');
  assert.equal(second.headers['x-cache'], 'hit');
  assert.equal(store.calls.listProducts, 1, 'second request must not hit Postgres');
  assert.equal(await metricValue('cache_requests_total', { result: 'hit' }), 1);
});

test('GET /products: Redis down falls back to Postgres', async () => {
  const app = buildApp({ store: fakeStore(), cache: fakeCache({ get: down, set: down }) });
  const res = await app.inject('/products');
  assert.equal(res.statusCode, 200);
  assert.equal(res.headers['x-cache'], 'bypass');
  assert.equal(await metricValue('cache_requests_total', { result: 'error' }), 1);
});

test('POST /orders: created -> 201', async () => {
  const app = buildApp({ store: fakeStore(), cache: fakeCache() });
  const res = await app.inject({ method: 'POST', url: '/orders', payload: { items: [{ product_id: PRODUCT.id, quantity: 1 }] } });
  assert.equal(res.statusCode, 201);
  assert.equal(await metricValue('orders_total', { result: 'created' }), 1);
});

test('POST /orders: invalid body -> 400 and not counted as an exception', async () => {
  const app = buildApp({ store: fakeStore(), cache: fakeCache() });
  for (const payload of [{}, { items: [] }, { items: [{ product_id: 'nope', quantity: 1 }] }, { items: [{ product_id: PRODUCT.id, quantity: 0 }] }]) {
    const res = await app.inject({ method: 'POST', url: '/orders', payload });
    assert.equal(res.statusCode, 400, JSON.stringify(payload));
  }
  assert.equal((await registry.getSingleMetric('app_exceptions_total').get()).values.length, 0);
});

test('POST /orders: insufficient stock -> 409, unknown product -> 422', async () => {
  for (const [reason, status] of [['insufficient_stock', 409], ['unknown_product', 422]]) {
    const store = fakeStore({ createOrder: async () => ({ ok: false, reason, productId: PRODUCT.id }) });
    const app = buildApp({ store, cache: fakeCache() });
    const res = await app.inject({ method: 'POST', url: '/orders', payload: { items: [{ product_id: PRODUCT.id, quantity: 1 }] } });
    assert.equal(res.statusCode, status);
    assert.equal(res.json().error, reason);
  }
  assert.equal(await metricValue('orders_total', { result: 'rejected' }), 2);
});

test('GET /orders/:id: found, not found, malformed id', async () => {
  const app = buildApp({ store: fakeStore(), cache: fakeCache() });
  assert.equal((await app.inject(`/orders/${ORDER_ID}`)).statusCode, 200);
  assert.equal((await app.inject('/orders/0190f8a1-0000-7000-8000-0000000000ff')).statusCode, 404);
  assert.equal((await app.inject('/orders/not-a-uuid')).statusCode, 400);
});

test('unexpected error -> generic 500, exception counted by type, no internals leaked', async () => {
  const store = fakeStore({ listProducts: async () => { throw Object.assign(new Error('relation "products" does not exist'), { code: '42P01' }); } });
  const app = buildApp({ store, cache: fakeCache() });
  const res = await app.inject('/products');
  assert.equal(res.statusCode, 500);
  assert.deepEqual(res.json(), { error: 'internal_error' });
  assert.equal(await metricValue('app_exceptions_total', { type: '42P01' }), 1);
});

test('GET /health: ok, degraded without Redis, 503 without Postgres', async () => {
  const ok = await buildApp({ store: fakeStore(), cache: fakeCache() }).inject('/health');
  assert.equal(ok.statusCode, 200);
  assert.equal(ok.json().status, 'ok');

  const degraded = await buildApp({ store: fakeStore(), cache: fakeCache({ ping: down }) }).inject('/health');
  assert.equal(degraded.statusCode, 200);
  assert.deepEqual(degraded.json(), { status: 'degraded', checks: { postgres: 'up', redis: 'down' } });
  assert.equal(await metricValue('dependency_up', { dependency: 'redis' }), 0);

  const dbDown = await buildApp({ store: fakeStore({ ping: down }), cache: fakeCache() }).inject('/health');
  assert.equal(dbDown.statusCode, 503);
  assert.equal(await metricValue('dependency_up', { dependency: 'postgres' }), 0);
});

test('dependency outage logs once when down (including at startup) and once on recovery', async () => {
  const lines = [];
  const stream = new Writable({ write(chunk, _enc, cb) { lines.push(JSON.parse(chunk)); cb(); } });
  let redisUp = false; // already down when the app starts
  const cache = fakeCache({ ping: async () => { if (!redisUp) throw new Error('ECONNREFUSED'); return 'PONG'; } });
  const app = buildApp({ store: fakeStore(), cache, logger: loggerOptions({ environment: 'test', stream }) });

  await app.checkDependencies();
  await app.checkDependencies();
  redisUp = true;
  await app.checkDependencies();
  await app.checkDependencies();

  const events = lines.filter((l) => l.dependency).map((l) => `${l.level}:${l.msg}`);
  assert.deepEqual(events, ['error:redis connection failed', 'info:redis connection recovered']);
});

test('metrics use route templates, never raw IDs; /health and /metrics not recorded', async () => {
  const app = buildApp({ store: fakeStore(), cache: fakeCache() });
  await app.inject(`/orders/${ORDER_ID}`);
  await app.inject('/no/such/route');
  await app.inject('/health');
  await app.inject('/metrics');
  const { values } = await registry.getSingleMetric('http_requests_total').get();
  const routes = values.map((v) => v.labels.route).sort();
  assert.deepEqual(routes, ['/orders/:id', 'unmatched']);
  assert.ok(!JSON.stringify(values).includes(ORDER_ID), 'order ID leaked into labels');
});

test('POST /orders: schema is strict (unknown fields and type coercion rejected)', async () => {
  const app = buildApp({ store: fakeStore(), cache: fakeCache() });
  for (const payload of [
    { items: [{ product_id: PRODUCT.id, quantity: 1 }], coupon: 'x' },
    { items: [{ product_id: PRODUCT.id, quantity: 1, price_cents: 0 }] },
    { items: [{ product_id: PRODUCT.id, quantity: true }] },
    { items: [{ product_id: PRODUCT.id, quantity: '2' }] },
  ]) {
    const res = await app.inject({ method: 'POST', url: '/orders', payload });
    assert.equal(res.statusCode, 400, JSON.stringify(payload));
  }
});

test('orders_total counts orders that fail with a 500 as result="error"', async () => {
  const store = fakeStore({ createOrder: async () => { throw new Error('boom'); } });
  const app = buildApp({ store, cache: fakeCache() });
  const res = await app.inject({ method: 'POST', url: '/orders', payload: { items: [{ product_id: PRODUCT.id, quantity: 1 }] } });
  assert.equal(res.statusCode, 500);
  assert.equal(await metricValue('orders_total', { result: 'error' }), 1);
});

test('in-flight gauge returns to 0 and is not raised by /metrics or /health', async () => {
  const app = buildApp({ store: fakeStore(), cache: fakeCache() });
  await app.inject('/products');
  const scrape = await app.inject('/metrics');
  assert.match(scrape.body, /^http_requests_in_flight 0$/m);
  await app.inject('/health');
  assert.equal(await metricValue('http_requests_in_flight', {}), 0);
});

test('concurrent dependency checks share one in-flight check (single-flight)', async () => {
  let pings = 0;
  const store = fakeStore({ ping: async () => { pings++; await new Promise((r) => setTimeout(r, 20)); } });
  const app = buildApp({ store, cache: fakeCache() });
  const results = await Promise.all([app.checkDependencies(), app.checkDependencies(), app.inject('/health')]);
  assert.equal(pings, 1, 'three concurrent callers should trigger one ping');
  assert.equal(results[0], results[1]);
  await app.checkDependencies();
  assert.equal(pings, 2, 'a later call runs a fresh check');
});

test('store.ping uses the dedicated health pool, not the request pool', async () => {
  const used = [];
  const pool = { query: async () => { used.push('request'); } };
  const healthPool = { query: async () => { used.push('health'); } };
  await createStore(pool, { healthPool }).ping();
  await createStore(pool).ping();
  assert.deepEqual(used, ['health', 'request']);
});

test('label helpers stay bounded', () => {
  assert.equal(exceptionType(new Error('timeout exceeded when trying to connect')), 'POOL_TIMEOUT');
  assert.equal(normalizeMethod('GET'), 'GET');
  assert.equal(normalizeMethod('BREW'), 'OTHER');
  assert.equal(exceptionType({ code: 'ECONNREFUSED' }), 'ECONNREFUSED');
  assert.equal(exceptionType(new TypeError('x')), 'TypeError');
  assert.equal(exceptionType({ code: 'a b/c'.repeat(20) }).length, 40);
  assert.match(exceptionType({ code: 'a b/c' }), /^[A-Za-z0-9_]+$/);
});

test('logs are JSON with service/environment/level, and secrets are redacted', async () => {
  const lines = [];
  const stream = new Writable({ write(chunk, _enc, cb) { lines.push(JSON.parse(chunk)); cb(); } });
  const app = buildApp({ store: fakeStore(), cache: fakeCache(), logger: loggerOptions({ environment: 'test', stream }) });
  app.log.info({ password: 'hunter2', headers: { authorization: 'Bearer abc' }, user: { email: 'a@b.c' } }, 'probe');
  await app.inject('/products');

  const probe = lines.find((l) => l.msg === 'probe');
  assert.equal(probe.service, 'ecommerce-api');
  assert.equal(probe.environment, 'test');
  assert.equal(probe.level, 'info');
  assert.match(probe.time, /^\d{4}-\d{2}-\d{2}T/);
  assert.equal(probe.password, '[REDACTED]');
  assert.equal(probe.headers.authorization, '[REDACTED]');
  assert.equal(probe.user.email, '[REDACTED]');

  const request = lines.find((l) => l.msg === 'request completed');
  assert.deepEqual(
    { method: request.method, route: request.route, status_code: request.status_code },
    { method: 'GET', route: '/products', status_code: 200 },
  );
  assert.ok(!('headers' in request) && !('req' in request), 'request headers must not be logged');
});
