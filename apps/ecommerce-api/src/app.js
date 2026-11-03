'use strict';

const Fastify = require('fastify');
const { LogController } = require('fastify');
const { registry, metrics, normalizeMethod, exceptionType } = require('./metrics');

const PRODUCTS_CACHE_KEY = 'products:v1';
// Stock shown in the list may be up to 30s stale; POST /orders always checks live stock.
const PRODUCTS_CACHE_TTL_S = 30;
const DEPENDENCY_TIMEOUT_MS = 1000;
const UUID = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';

// Request logs and metrics skip these: they are polled every few seconds.
const QUIET_ROUTES = new Set(['/health', '/metrics']);

function withTimeout(promise, ms) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(Object.assign(new Error(`timed out after ${ms}ms`), { code: 'ETIMEOUT' })), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

// JSON logs: time, level (as text), service, environment, msg (+ trace_id from OTel).
// Bodies and headers are never logged; redaction is a second line of defence for
// anything passed to the logger by mistake.
function loggerOptions({ environment, level = 'info', stream } = {}) {
  return {
    level,
    stream,
    base: { service: 'ecommerce-api', environment },
    timestamp: () => `,"time":"${new Date().toISOString()}"`,
    formatters: { level: (label) => ({ level: label }) },
    redact: {
      paths: [
        'req.headers.authorization', 'req.headers.cookie', 'headers.authorization', 'headers.cookie',
        'password', '*.password', 'token', '*.token', 'authorization', '*.authorization',
        'email', '*.email', 'card_number', '*.card_number',
        // Postgres errors can echo row values in `detail` (e.g. constraint violations).
        'err.detail', 'err.where',
      ],
      censor: '[REDACTED]',
    },
  };
}

function buildApp({ store, cache, logger = false }) {
  const app = Fastify({
    logger,
    // Fastify's own per-request log lines are replaced by one line in finish() below.
    logController: new LogController({ disableRequestLogging: true }),
    // Fastify's Ajv defaults silently drop unknown fields and coerce types ("true" -> 1).
    // Reject instead, so the schemas mean what they say.
    ajv: { customOptions: { removeAdditional: false, coerceTypes: false } },
  });

  // --- Dependency checks: shared by /health, the Docker healthcheck, Blackbox and the
  // background poller. Single-flight: concurrent callers share one in-progress check, so
  // an older, slower check can never overwrite a newer result (no flapping logs).
  const lastState = {};
  let running = null;
  function checkDependencies() {
    running ??= runChecks().finally(() => { running = null; });
    return running;
  }
  async function runChecks() {
    const [postgres, redis] = await Promise.allSettled([
      withTimeout(store.ping(), DEPENDENCY_TIMEOUT_MS),
      withTimeout(cache.ping(), DEPENDENCY_TIMEOUT_MS),
    ]);
    const result = {};
    for (const [name, outcome] of Object.entries({ postgres, redis })) {
      const up = outcome.status === 'fulfilled';
      result[name] = up ? 'up' : 'down';
      metrics.dependencyUp.set({ dependency: name }, up ? 1 : 0);
      // Log transitions only, so an outage is one "down" line and one "recovered" line.
      // The first check counts as a transition when the dependency is down; otherwise an
      // outage that began before this process started would never be logged.
      const previous = lastState[name];
      if (previous !== up && (previous !== undefined || !up)) {
        if (up) app.log.info({ dependency: name }, `${name} connection recovered`);
        else app.log.error({ dependency: name, err: outcome.reason }, `${name} connection failed`);
      }
      lastState[name] = up;
    }
    return result;
  }
  app.decorate('checkDependencies', checkDependencies);

  // --- Metrics + one log line per request (quiet routes skipped entirely, including
  // the in-flight gauge, so a /metrics scrape doesn't count itself)
  app.addHook('onRequest', async (req) => {
    if (QUIET_ROUTES.has(req.routeOptions.url)) return;
    req.tracked = true;
    req.startedAt = process.hrtime.bigint();
    metrics.httpInFlight.inc();
  });

  const finish = (req, statusCode) => {
    if (!req.tracked || req.metricsRecorded) return;
    req.metricsRecorded = true;
    metrics.httpInFlight.dec();
    const route = req.routeOptions.url ?? 'unmatched';
    const seconds = Number(process.hrtime.bigint() - req.startedAt) / 1e9;
    const labels = { method: normalizeMethod(req.method), route, status_code: String(statusCode) };
    metrics.httpRequests.inc(labels);
    metrics.httpDuration.observe(labels, seconds);
    const level = statusCode >= 500 ? 'error' : statusCode >= 400 ? 'warn' : 'info';
    req.log[level]({
      method: req.method,
      route,
      path: req.url.split('?')[0],
      status_code: statusCode,
      duration_ms: Math.round(seconds * 1000),
    }, 'request completed');
  };
  app.addHook('onResponse', async (req, reply) => finish(req, reply.statusCode));
  app.addHook('onRequestAbort', async (req) => finish(req, 499));

  // --- Errors: 4xx pass through; anything else is a counted exception and a generic 500
  app.setErrorHandler((err, req, reply) => {
    if (err.validation) {
      return reply.code(400).send({ error: 'invalid_request', message: err.message });
    }
    if (err.statusCode >= 400 && err.statusCode < 500) {
      return reply.code(err.statusCode).send({ error: 'bad_request', message: err.message });
    }
    metrics.exceptions.inc({ type: exceptionType(err) });
    req.log.error({ err }, 'unhandled error');
    return reply.code(500).send({ error: 'internal_error' });
  });

  // --- Routes
  app.get('/health', async (req, reply) => {
    const checks = await checkDependencies();
    // Postgres is required; without Redis the API still works (uncached), so it's "degraded".
    if (checks.postgres === 'down') return reply.code(503).send({ status: 'down', checks });
    return { status: checks.redis === 'up' ? 'ok' : 'degraded', checks };
  });

  app.get('/metrics', async (req, reply) => {
    reply.type(registry.contentType);
    return registry.metrics();
  });

  app.get('/products', async (req, reply) => {
    let cacheResult = 'miss';
    try {
      const cached = await withTimeout(cache.get(PRODUCTS_CACHE_KEY), DEPENDENCY_TIMEOUT_MS);
      if (cached) {
        metrics.cacheRequests.inc({ result: 'hit' });
        reply.header('x-cache', 'hit');
        return JSON.parse(cached);
      }
    } catch (err) {
      cacheResult = 'error';
      req.log.warn({ err }, 'redis read failed, serving products from postgres');
    }
    metrics.cacheRequests.inc({ result: cacheResult });

    const body = { products: await store.listProducts() };
    if (cacheResult === 'miss') {
      withTimeout(cache.set(PRODUCTS_CACHE_KEY, JSON.stringify(body), PRODUCTS_CACHE_TTL_S), DEPENDENCY_TIMEOUT_MS)
        .catch((err) => req.log.warn({ err }, 'redis write failed'));
    }
    reply.header('x-cache', cacheResult === 'miss' ? 'miss' : 'bypass');
    return body;
  });

  app.post('/orders', {
    schema: {
      body: {
        type: 'object',
        required: ['items'],
        additionalProperties: false,
        properties: {
          items: {
            type: 'array',
            minItems: 1,
            maxItems: 20,
            items: {
              type: 'object',
              required: ['product_id', 'quantity'],
              additionalProperties: false,
              properties: {
                product_id: { type: 'string', pattern: UUID },
                quantity: { type: 'integer', minimum: 1, maximum: 100 },
              },
            },
          },
        },
      },
    },
  }, async (req, reply) => {
    let result;
    try {
      result = await store.createOrder(req.body.items);
    } catch (err) {
      metrics.orders.inc({ result: 'error' }); // becomes a 500 in the error handler
      throw err;
    }
    if (!result.ok) {
      metrics.orders.inc({ result: 'rejected' });
      req.log.warn({ reason: result.reason, product_id: result.productId }, 'order rejected');
      const status = result.reason === 'insufficient_stock' ? 409 : 422;
      return reply.code(status).send({ error: result.reason, product_id: result.productId });
    }
    metrics.orders.inc({ result: 'created' });
    req.log.info({ order_id: result.order.id, total_cents: result.order.total_cents }, 'order created');
    return reply.code(201).send(result.order);
  });

  app.get('/orders/:id', {
    schema: {
      params: {
        type: 'object',
        required: ['id'],
        properties: { id: { type: 'string', pattern: UUID } },
      },
    },
  }, async (req, reply) => {
    const order = await store.getOrder(req.params.id);
    if (!order) return reply.code(404).send({ error: 'order_not_found' });
    return order;
  });

  return app;
}

module.exports = { buildApp, loggerOptions, withTimeout, PRODUCTS_CACHE_KEY };
