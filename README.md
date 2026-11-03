# Centralized Observability Platform

A hybrid-cloud observability platform: metrics, logs, alerting, SLOs and incident
management for multiple applications, developed locally on OrbStack with
[Floci](https://github.com/floci-io/floci) emulating AWS APIs, and validated on AWS (`ap-south-1`).

Inspired by Uber Engineering's
[From Monitoring to Observability: Our Ultra-Marathon to a Cloud-Native Platform](https://www.uber.com/in/en/blog/from-monitoring-to-observability-cloud-native/).

> **Status: Phase 4 (alerting and SLOs).** Only what is listed under
> "Working today" has been implemented and tested. The full README is written in Phase 9.

## Working today

| Component | Version | Local URL | Notes |
|---|---|---|---|
| E-commerce API | Node.js `24.22.2`, Fastify `5.12.8` | http://127.0.0.1:8080 | Metrics, JSON logs, OTel trace IDs; non-root, read-only FS |
| PostgreSQL | `18.6` | internal | `ecommerce` DB; owner role for migrations, row-only role for the API |
| Redis | `8.8.4` | internal | Cache only: password, 64 MB LRU, no persistence |
| Prometheus | `v3.15.1` | http://127.0.0.1:9090 | 15s scrape/eval, 30d / 5GB retention, file-based target discovery, alert + SLO rules |
| Grafana | `13.2.5` | http://127.0.0.1:3000 | Datasources and 5 dashboards provisioned from Git; login from `.env` |
| Loki | `3.7.9` | http://127.0.0.1:3100 | Filesystem storage, 72h retention |
| Alloy | `v1.21.3` | http://127.0.0.1:12345 | Docker + system logs → redact → parse → Loki |
| Alertmanager | `v0.34.2` | http://127.0.0.1:9093 | Severity routing, grouping, inhibition; email + Slack + webhook |
| Mailpit | `v1.31.6` | http://127.0.0.1:8025 | Local inbox for alert email (default SMTP target) |
| alert-sink | Python `3.14.9` (stdlib) | internal | Logs webhook and Slack-format notifications (default Slack target) |
| Node Exporter | `v1.12.1` | internal | Host = OrbStack Linux VM locally |
| cAdvisor | `v0.60.6` | internal | Per-container CPU, memory, network |
| Blackbox Exporter | `v0.29.1` | internal | HTTP uptime probes + TCP probes (Postgres, Redis) |
| k6 | `1.8.2` | — | Load generator (`make load`) |
| Floci (AWS emulator) | `2.4.0` | http://127.0.0.1:4566 | State persisted in the `floci-data` volume |
| AWS CLI | `2.38.6` | — | Container, hardwired to Floci with fake credentials |
| Terraform | `1.16.7` | — | Container, Floci credentials, shared plugin cache |

All images are pinned by tag and multi-arch digest. No `latest` tags.
Everything published binds to `127.0.0.1`; exporters are only reachable inside the Docker network.

### E-commerce API

| Endpoint | Behaviour |
|---|---|
| `GET /health` | `200 ok`, `200 degraded` (Redis down, API still works), `503 down` (Postgres down). Uses its own DB connection, so a saturated request pool is not reported as "Postgres down" |
| `GET /products` | Redis cache-aside, 30s TTL; `x-cache: hit\|miss\|bypass`. Falls back to Postgres if Redis is down |
| `POST /orders` | `{"items":[{"product_id":"<uuid>","quantity":1}]}` → `201`; `409` out of stock, `422` unknown product, `400` invalid (strict schema: unknown fields and wrong types are rejected, not dropped or coerced). Product rows are locked (`FOR UPDATE`) so racing buyers get a clean `409`; `CHECK (stock >= 0)` is the last line against overselling |
| `GET /orders/:id` | `200`, `404`, or `400` for a malformed id |
| `GET /metrics` | Prometheus metrics |

**Database access (least privilege).** Schema changes and runtime access use different roles:

| Role | Used by | Can |
|---|---|---|
| `ecommerce_owner` | `ecommerce-migrate` (one-shot job, runs before the API starts) | Owns the database; applies `migrations/*.sql` |
| `ecommerce_app` | the API | Read products, change `products.stock` only, insert/read orders. Cannot update prices, update/delete orders, or create/alter/drop anything |

Grants live in [`003_app_grants.sql`](apps/ecommerce-api/migrations/003_app_grants.sql), so new
tables stay private until a migration grants access. Neither role can connect to the
`postgres` or `template1` databases. `make test` verifies all of this.

**Startup behaviour.** If Postgres is down, the API still starts, returns `503` from
`/health` and logs the outage, then recovers when Postgres returns. If Redis is down,
it starts `degraded`. Either way, one `error` line is logged at startup, and it carries the
real cause (e.g. `WRONGPASS`, `ECONNREFUSED`), not just "client is offline".

**Saturation vs outage.** When every request connection is busy (slow queries, lock waits),
`/health` and `dependency_up{postgres}` stay `up`. The saturation shows as
`db_pool_connections{state="waiting"} > 0` and `app_exceptions_total{type="POOL_TIMEOUT"}`.

**Metrics** (all labels bounded; route is the template `/orders/:id`, never a raw ID):
`http_requests_total`, `http_request_duration_seconds` (buckets include 0.5s for the p95 SLO),
`http_requests_in_flight`, `app_exceptions_total{type}`, `dependency_up{dependency=postgres|redis}`,
`db_pool_connections{state}`, `cache_requests_total{result}`, `orders_total{result=created|rejected|error}`,
plus Node.js runtime metrics. `/metrics` and `/health` are excluded from request metrics and the in-flight gauge.

**Logs**: one JSON line per event with `time, level, service, environment, msg`, and `trace_id`
inside requests. An incoming W3C `traceparent` header is continued, so a caller's trace ID
appears in this service's logs. Bodies and headers are never logged; known secret fields are
redacted in the app before Alloy's redaction runs. Dependency outages log one `error` line
when they start and one `info` line when they recover.

**Investigating with LogQL** (Grafana → Explore → Loki):

```logql
{service="ecommerce-api"} | json | status_code >= 500                     # HTTP 5xx
{service="ecommerce-api", level="error"} | json | dependency="postgres"   # database failures
{service="ecommerce-api", level="error"} | json | dependency="redis"      # Redis failures
{service="ecommerce-api", level=~"error|fatal"} |= "unhandled error"      # application exceptions
{service="ecommerce-api"} |= "startup failed"                             # startup errors
{service="ecommerce-api"} | json | duration_ms > 100                      # slow requests
{service="ecommerce-api"} | trace_id="<id>"                               # everything for one request
sum by (service) (count_over_time({level=~"error|fatal"}[5m]))           # error volume per service
```

**Tracing scope:** OpenTelemetry creates spans so trace IDs propagate and correlate logs.
Spans are not exported or stored, because no trace backend is in scope; adding Grafana Tempo is a future improvement.

### Alerting

Rules: [`alerts.yml`](observability/prometheus/rules/alerts.yml) and
[`slo.yml`](observability/prometheus/rules/slo.yml). Routing: [`alertmanager.yml`](observability/alertmanager/alertmanager.yml).

| Alert | Severity | Fires when |
|---|---|---|
| HighCPUUsage | warning | host CPU > 85% for 10m |
| HighMemoryUsage | warning | host memory > 90% for 10m |
| DiskSpaceLow | warning / critical | < 15% / < 5% free on a disk for 5m |
| InstanceDown | critical | Node Exporter unreachable for 1m |
| ApplicationDown | critical | app `/metrics` unreachable for 1m |
| EndpointDown | warning | a Blackbox HTTP check (incl. Floci, app `/health`) failing for 2m |
| HighHTTPErrorRate | critical | 5xx > 1% for 5m, at ≥ 0.5 req/s |
| HighRequestLatency | warning | p95 > 500ms for 10m, at ≥ 0.5 req/s |
| DatabaseUnavailable | critical | API's Postgres check **or** TCP probe failing for 1m |
| RedisUnavailable | warning | same for Redis (the API degrades, still serves) |
| ContainerRestarting | warning | ≥ 2 observed restarts of a container in 15m (sampled: see the rule's comment) |
| PrometheusTargetMissing | warning | any scrape target down for 2m |
| LokiIngestionFailure | critical / warning | log lines dropped or rejected / Alloy retrying for 5m |
| MonitoringStoragePressure | warning | Prometheus storage > 80% of its size limit for 15m |
| ErrorBudgetFastBurn | critical | SLO burn rate > 14.4× over 1h **and** 5m |
| ErrorBudgetSlowBurn | warning | SLO burn rate > 6× over 6h **and** 30m |

- **Routing:** critical → email + Slack + webhook (updates within 1m, repeat 1h);
  warning → Slack + webhook (repeat 4h). Grouped by `alertname, environment`.
  Every receiver gets recovery (`RESOLVED`) notifications.
- **Inhibition:** a critical alert mutes its warning twin on the same disk/target;
  InstanceDown/ApplicationDown mute PrometheusTargetMissing for that target;
  DatabaseUnavailable mutes HighHTTPErrorRate and the error-budget burn alerts;
  ApplicationDown or DatabaseUnavailable mutes the app's failing `/health` check (EndpointDown).
- **Links** in notifications point to `PROMETHEUS_EXTERNAL_URL` / `ALERTMANAGER_EXTERNAL_URL`
  (default `http://127.0.0.1:9090` / `:9093`).
- **Minimum traffic:** request-based alerts need ≥ 0.5 req/s (5m alerts) or ≥ 0.1 req/s
  (burn-rate windows). Below that one failed request is already > 1%; a single `make test`
  run (~60 requests, 5 deliberate 500s) would otherwise page. ApplicationDown still covers a
  dead service at any traffic level.
- **Receivers without credentials:** with the alerting variables in `.env` left empty, email
  lands in [Mailpit](http://127.0.0.1:8025) and Slack messages in `docker compose logs alert-sink`.
  Set `SMTP_*`, `ALERT_EMAIL_TO` and `SLACK_WEBHOOK_URL` for real delivery ([.env.example](.env.example)).
  Alertmanager can't read environment variables itself, so
  [`render.sh`](observability/alertmanager/render.sh) fills them into its config at start.
- **Tests:** `make unit` runs promtool unit tests (a firing case and a near miss for every
  alert) and validates both configs. `make test` stops Postgres and follows the real alert
  through Alertmanager to the webhook, Slack-format and email receivers, checks every link
  in the email opens, then checks the recovery notifications. With real email/Slack settings
  in `.env` that outage step is skipped (it would page people) and reported as `SKIP`.
  Running `make test` twice within 15 minutes fires ContainerRestarting (warning): each run
  restarts the API once.

### SLOs

| SLO | Objective | Bad event | Error budget (30d) |
|---|---|---|---|
| availability | 99.9% | ecommerce-api request returned 5xx | 0.1% of requests |
| latency | 95% | request slower than 500 ms (i.e. p95 < 500 ms) | 5% of requests |
| freshness | 99% of the time | logs not reaching Loki within 60 s: Alloy or Loki down, Alloy retrying, or a push > 60 s | 1% of the time (7.2 h) |

Availability and latency count requests; freshness counts time, because Alloy times a
line from when it reads it, so lines written while Alloy is down would otherwise count as
fresh (measured: 150 s late, counted as on time).
Each SLI is recorded as an error ratio (`slo:error_ratio:rate5m|30m|1h|6h|30d{slo=...}`);
budget left = 1 − (30-day error ratio ÷ budget). The budget is computed over the data
Prometheus actually holds (up to 30 days; the SLO dashboard shows how much that is), never
from a hard-coded number of minutes. Burn-rate alerts follow the multi-window,
multi-burn-rate pattern from the Google SRE workbook.

### Dashboards

Provisioned read-only into Grafana's **COP** folder from
[`observability/grafana/provisioning/dashboards/`](observability/grafana/provisioning/dashboards/):

| Dashboard | Shows |
|---|---|
| Overview | firing alerts, targets up, probes, availability budget left, traffic and 5xx by service |
| Infrastructure | host CPU, memory, disk, load, I/O; container CPU, memory, network, restarts |
| E-commerce API | rate, errors, latency (p50/p95/p99), dependencies, DB pool, cache, orders, logs |
| SLOs and error budgets | objectives, 30-day SLIs, budget left, burn rate per window |
| Telemetry pipeline | Prometheus ingestion and storage, Alertmanager notifications, log delivery latency, drops |

`make test` checks every panel query returns data (panels documented as "Empty when
healthy", such as firing alerts, are allowed to be empty).

### Adding a monitoring target

Drop a file into `observability/prometheus/targets/`. Prometheus picks it up within seconds
(measured ~3s), no restart and no edit to `prometheus.yml`:

```yaml
# observability/prometheus/targets/node-aws.yml
- targets: [10.0.1.15:9100]
  labels: {environment: aws, host: app-1}
```

Target *files* reload automatically; edits to `prometheus.yml`, `rules/*.yml`, `alertmanager.yml`,
`blackbox.yml` or `config.alloy` need `make reload` (also run by `make up`). It validates each
config with the tool's own checker first and fails if any service doesn't load its config
(a rejected config otherwise only shows in that service's log). Dashboards reload by themselves within 30s.

### Log pipeline

Alloy collects logs from every container in this compose project (and `/var/log/syslog`,
`kern.log`, `auth.log` on Linux hosts), then:

0. **Keeps only Compose-named containers** (`cop-*`). Compose-built images carry the project
   labels, so an ad-hoc `docker run cop/ecommerce-api:dev` would otherwise pose as the real
   service in Loki.

1. **Redacts** `password`, `token`, `secret`, `api_key`, `authorization`… values (JSON and `key=value`) and Bearer tokens.
2. **Parses** `level` from JSON or logfmt and lowercases it.
3. **Labels** streams with `service`, `container`, `level`, `environment`; `trace_id` goes to
   structured metadata, never a label, to keep cardinality bounded.

### Security notes (current state)

- **Docker socket = root.** Alloy and cAdvisor mount `/var/run/docker.sock`. Mounting it `:ro`
  does *not* limit the Docker API (verified: a container can be created through a `:ro` mount),
  so both effectively have root on the host. Acceptable on a laptop; before the AWS deployment
  a socket proxy will restrict them to read-only container endpoints.
- **Redaction is a safety net, not the primary control.** Alloy redacts secrets before logs
  reach Loki, but Docker's own log files (`docker logs`) still hold the original lines. The
  real rule is that applications never log secrets (enforced in the app code from Phase 3).
  The JSON pattern only matches string values (`"password": "…"`), not numbers or nested objects.
- **Locally built images are never pulled.** `cop/ecommerce-api` has `pull_policy: build`
  (API) and `never` (migrate job): the `cop` namespace is unclaimed on Docker Hub, so a pull
  could fetch someone else's image and hand it the database owner password. Tested by `make test`.
- **Deferred to the AWS phase:** the API serves `/metrics` on its public port (fine on
  `127.0.0.1`, not behind a public load balancer), and secrets are environment variables
  (visible in `docker inspect`); both move behind a private port / AWS SSM in Phase 7.
- **Log `level` label is allowlisted** to `debug|info|warn|error|fatal` (`warning`→`warn`,
  `err`→`error`, `critical`/`panic`→`fatal`); any other value gets no label, so free text
  can't create new label values.

### Known local limitations

- `GRAFANA_ADMIN_PASSWORD` is applied only when Grafana first creates its database. To change
  it later: `docker compose exec grafana grafana cli admin reset-admin-password '<new>'`.

- Node Exporter reports OrbStack's Linux VM, not macOS. Its network metrics cover only its own
  container (bridge networking); per-container traffic comes from cAdvisor.
- OrbStack's VM has no syslog/journal, so system-log collection is idle locally (active on EC2).
- Loki and Alloy images are distroless with no probe tool, so they have no Compose healthcheck;
  `make up` waits for Loki's `/ready`, and Blackbox probes both.
- Postgres passwords from `.env` are applied only when the `postgres-data` volume is first
  created. Changing them later needs `ALTER ROLE` (or recreating the volume, which deletes data).
- Integration test scripts run under macOS's built-in bash 3.2; they avoid constructs it mis-parses.
- **One-shot jobs that exit within a second (`ecommerce-migrate`) don't reach Loki**: Alloy
  discovers *running* containers, and the job is gone first. Read them with
  `docker compose logs ecommerce-migrate`. A failed migration stops `make up` with
  `service "ecommerce-migrate" didn't complete successfully` (Compose may also print a
  misleading `dependency redis failed to start`). Crash-looping services are unaffected:
  Docker restarts the same container and Alloy keeps tailing it.
- If a migration fails while an older API container is already running, that container keeps
  running on the previous schema; Compose only blocks starting a new one.

## Prerequisites

- macOS on Apple Silicon with [OrbStack](https://orbstack.dev) (Docker Engine + Compose v2)
- `make`, `curl`, `git`

Terraform and the AWS CLI are **not** installed on the host; they run as containers.

## Quick start

```bash
cp .env.example .env
# fill in the empty passwords in .env (each line says how to generate it)
make doctor   # read-only toolchain check
make unit     # app unit tests, alert rule tests, config checks (in Docker, no stack needed)
make up       # build the app, start the stack, wait for healthchecks, reload configs
make health   # every endpoint ready + AWS CLI provably pointed at Floci
make test     # integration tests: platform, app, alerting (~5 min; briefly stops Redis and Postgres)
make load     # k6 shoppers for 2m (DURATION=5m to change); watch Grafana meanwhile
make aws ARGS="s3 ls"
make tf ARGS="version"
make down     # stop (keeps data); `make clean` deletes volumes after confirmation
```

## Safety: local credentials cannot reach AWS

The `aws` and `terraform` containers set `AWS_ACCESS_KEY_ID=test`,
`AWS_ENDPOINT_URL=http://floci:4566` and never mount `~/.aws`. Even with the
endpoint removed, the fake keys are rejected by real AWS. `make health` asserts
the caller account is Floci's `000000000000`.

## Environment variables

See [.env.example](.env.example); every variable is documented there.
