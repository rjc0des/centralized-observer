# Centralized Observability Platform

A hybrid-cloud observability platform: metrics, logs, alerting, SLOs and incident
management for multiple applications, developed locally on OrbStack with
[Floci](https://github.com/floci-io/floci) emulating AWS APIs, and validated on AWS (`ap-south-1`).

Inspired by Uber Engineering's
[From Monitoring to Observability: Our Ultra-Marathon to a Cloud-Native Platform](https://www.uber.com/in/en/blog/from-monitoring-to-observability-cloud-native/).

> **Status: Phase 8 (CI/CD, security scans, deploy + rollback, backups, failure drills).** Only what is listed under
> "Working today" has been implemented and tested. The full README is written in Phase 9.

## Working today

| Component | Version | Local URL | Notes |
|---|---|---|---|
| E-commerce API | Node.js `24.22.2`, Fastify `5.12.8` | http://127.0.0.1:8080 | Metrics, JSON logs, OTel trace IDs; non-root, read-only FS |
| PostgreSQL | `18.6` | internal | `ecommerce` DB; owner role for migrations, row-only role for the API |
| Incident API | Python `3.14.9`, FastAPI `0.162.0` | http://127.0.0.1:8081 | Alertmanager webhook → deduplicated, correlated incidents; lifecycle, reports. Docs at `/docs` |
| incident-db | PostgreSQL `18.6` | internal | Separate instance, so incidents are recorded while the app database is down |
| Redis | `8.8.4` | internal | Cache only: password, 64 MB LRU, no persistence |
| Prometheus | `v3.15.1` | http://127.0.0.1:9090 | 15s scrape/eval, 30d / 5GB retention, file-based target discovery, alert + SLO rules |
| Grafana | `13.2.5` | http://127.0.0.1:3000 | Datasources and 5 dashboards provisioned from Git; login from `.env` |
| Loki | `3.7.9` | http://127.0.0.1:3100 | Filesystem storage, 72h retention |
| Alloy | `v1.21.3` | http://127.0.0.1:12345 | Docker + system logs → redact → parse → Loki |
| Alertmanager | `v0.34.2` | http://127.0.0.1:9093 | Severity routing, grouping, inhibition; email + Slack + webhook |
| Mailpit | `v1.31.6` | http://127.0.0.1:8025 | Local inbox for alert email (default SMTP target) |
| alert-sink | Python `3.14.9` (stdlib) | internal | Logs Slack-format notifications (default Slack target) |
| Node Exporter | `v1.12.1` | internal | Host = OrbStack Linux VM locally |
| cAdvisor | `v0.60.6` | internal | Per-container CPU, memory, network |
| Blackbox Exporter | `v0.29.1` | internal | HTTP uptime probes + TCP probes (Postgres, Redis) |
| k6 | `1.8.2` | — | Load generator (`make load`) |
| Floci (AWS emulator) | `2.4.0` | http://127.0.0.1:4566 | State persisted in the `floci-data` volume |
| AWS CLI | `2.38.6` | — | Container, hardwired to Floci with fake credentials |
| Terraform | `1.16.7`, AWS provider `6.71.0` | — | Container, Floci credentials, shared plugin cache; lock file committed |
| AWS tools (real AWS) | AWS CLI `2.38.6` + Session Manager plugin `1.2.896.0` | — | `aws-real` / `terraform-aws` containers, the only ones that read `~/.aws` (profile `cop`) |

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
  The webhook is the [incident API](#incident-management).
  Every receiver gets recovery (`RESOLVED`) notifications.
- **Inhibition:** a critical alert mutes its warning twin on the same disk/target;
  InstanceDown/ApplicationDown mute PrometheusTargetMissing for that target;
  DatabaseUnavailable (the e-commerce Postgres) mutes ecommerce-api's HighHTTPErrorRate,
  error-budget burn alerts and failing `/health` check (EndpointDown), not other services';
  ApplicationDown mutes the same service's failing `/health` check.
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
  through Alertmanager to an incident (opened while Postgres is still down), Slack-format
  and email receivers, checks every link in the email opens, then checks the recovery
  notifications and that the incident auto-resolved. With real email/Slack settings
  in `.env` that outage step is skipped (it would page people) and reported as `SKIP`.
  Running `make test` twice within 15 minutes fires ContainerRestarting (warning): each run
  restarts the API once.

### Incident management

[`apps/incident-api`](apps/incident-api) receives Alertmanager's webhook and turns alerts
into incidents, stored in its own Postgres (`incident-db`).

```
Prometheus ─▶ Alertmanager ─▶ webhook (Bearer token) ─▶ incident API ─▶ incident-db
                                                             │
                     people: acknowledge / resolve / notes ──┘   reports, metrics
```

- **Deduplication.** One alert firing = `(fingerprint, startsAt)`, unique in the database.
  Alertmanager re-sends notifications (every group change, and hourly/4-hourly while
  firing); re-sends only update `last_received_at`. A notification for a fingerprint that
  is still firing here belongs to that firing even with a new `startsAt` (Prometheus gives
  a still-firing alert a new one after a restart). Resolved is final.
- **Deterministic correlation.** A new alert joins the oldest unresolved incident in its
  environment that has a related alert, else it opens a new one. The rule is written to
  the timeline ([`correlation.py`](apps/incident-api/app/correlation.py)):

  | Rule | Related when |
  |---|---|
  | `same-alert` | same alertname and service (e.g. DiskSpaceLow on two disks) |
  | `same-service` | same `service` label (e.g. ApplicationDown + HighRequestLatency) |
  | `database-down` | DatabaseUnavailable ↔ ecommerce-api's HighHTTPErrorRate, burn alerts, EndpointDown |
  | `target-down` | InstanceDown/ApplicationDown ↔ PrometheusTargetMissing on the same job and instance |

  The cause → symptom pairs are Alertmanager's inhibit rules. Alertmanager never sends a
  muted symptom, so these rules matter when the symptom fired first or the cause resolves
  before it. The report's **probable cause** is the earliest alert that a rule lists as a
  cause, else the earliest alert. No AI or heuristics.
- **Lifecycle:** `open → acknowledged → resolved` (or `open → resolved`). An incident
  resolves itself when all its alerts have resolved; it can be resolved by hand earlier.
  Invalid transitions answer 409. A later firing of the same alert opens a new incident.
  Resolving and recording webhooks take the same lock, so an alert can't slip into an
  incident while someone resolves it. An auto-resolved incident's end is its alerts'
  latest end, whatever order the notifications arrived in.
  Severity is the highest of its alerts; a raise is logged. The timeline is append-only:
  the API's database role can insert events but not change or delete anything.
- **Writes** (webhook, acknowledge, resolve, notes) need `Authorization: Bearer $INCIDENT_API_TOKEN`,
  checked before the request body is read; people also give an `actor` name. An alert
  without an `alertname` is skipped (and counted), not a reason to reject the whole
  notification: Alertmanager never retries a 4xx, so that group would be lost.

```bash
source .env; A=http://127.0.0.1:8081
curl -s "$A/incidents?status=open" | jq          # filters: status, environment, limit
curl -s "$A/incidents/1" | jq                     # alerts + timeline
curl -s -X POST -H "Authorization: Bearer $INCIDENT_API_TOKEN" -H 'content-type: application/json' \
  "$A/incidents/1/acknowledge" -d '{"actor":"ana"}'
curl -s -X POST ... "$A/incidents/1/notes" -d '{"actor":"ana","text":"failed over"}'
curl -s -X POST ... "$A/incidents/1/resolve" -d '{"actor":"ana","note":"replaced disk"}'
curl -s "$A/incidents/1/report"                   # Markdown: summary, probable cause, alerts, timeline
curl -s "$A/reports/summary?days=30" | jq         # counts by severity, mean time to acknowledge / resolve
```

- **Lost resolutions.** Alertmanager keeps alerts in memory only. After a restart, an
  alert that cleared meanwhile never gets a "resolved" notification, and its incident
  stayed open (seen after `make down && make up`). Every 15 s the API compares its firing
  alerts with Alertmanager's active ones (`/api/v2/alerts`, including silenced and
  inhibited); one missing for 10 minutes is resolved, with a timeline note saying so.
  10 minutes is longer than any `group_interval`, so a real resolved notification, with
  the true end time, normally arrives first. If Alertmanager can't be reached, nothing is
  decided.
- **When incident-db is down** the webhook is still accepted (200) and written to a spool
  volume, then recorded in order once the database is back (within 15 s, or by the next
  webhook). Answering 503 wasn't enough: Alertmanager sends a receiver the "resolved"
  notification only if it got the "firing" one, so an alert that fired and cleared during
  the outage was lost (reproduced: Mailpit had both emails, the incident API nothing).
  `/health` turns 503, which fires EndpointDown, and `incident_spool_pending` counts what
  waits. Its own Postgres means the DatabaseUnavailable incident is recorded while the
  app's database is down.
- **Metrics:** `incidents_open{environment,severity}` (read at scrape time; Overview
  dashboard; it shows "unknown", not 0, while the API or its database is down; severity is
  limited to known values), `incident_webhook_alerts_total{outcome}`
  (new/duplicate/resolved/skipped), `incident_spool_pending`, and the same
  `http_requests_total` / `http_request_duration_seconds` as ecommerce-api. `/health` and
  `/metrics` aren't counted, so webhooks are its only steady traffic: far below the HTTP
  alerts' traffic floors. Its health is watched by ApplicationDown (scrape) and
  EndpointDown (`/health`), not by the 5xx/latency alerts.
- **Tests:** `make unit` tests the correlation rules and the report. `make test`
  (`incidents.sh`, 59 checks) posts webhooks for auth, validation, deduplication, each
  correlation rule with a control, the lifecycle, reports, the database role's limits,
  reconciliation (with a control alert Alertmanager still has), an incident-db outage
  (spooled webhooks recorded afterwards; panel shows unknown), a restart's new `startsAt`,
  out-of-order resolutions, a resolve racing a webhook, and 20 concurrent related webhooks (a session holds inserts so they truly overlap: without
  the webhook lock they made 20 incidents).

### SLOs

| SLO | Objective | Bad event | Error budget (30d) |
|---|---|---|---|
| availability | 99.9% | an app request returned 5xx (health checks and scrapes don't count) | 0.1% of requests |
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
| Overview | firing alerts, open incidents, targets up, probes, availability budget left, traffic and 5xx by service |
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

1. **Drops replayed lines older than 1h.** A container that is stopped and started again is
   re-read from the start of its Docker log; Loki rejects lines that far behind a stream, which
   used to fire a critical `LokiIngestionFailure` for lines Loki already had. Counted in
   `loki_process_dropped_lines_total{reason="too_old"}`.
2. **Redacts** `password`, `token`, `secret`, `api_key`, `authorization`… values (JSON and `key=value`) and Bearer tokens.
3. **Parses** `level` from JSON or logfmt and lowercases it.
4. **Labels** streams with `service`, `container`, `level`, `environment`; `trace_id` goes to
   structured metadata, never a label, to keep cardinality bounded.

### Infrastructure as code (Terraform)

```
infrastructure/terraform/
  modules/network   VPC, one public subnet, IGW, host security group (no inbound; egress 443/587), default SG emptied
  modules/storage   S3 bucket: versioned, SSE-S3, TLS-only policy, public access blocked, ACLs off, old versions expire (30d)
  modules/ecr       ECR repos cop/ecommerce-api, cop/incident-api: immutable tags, scan on push, keep newest 10
  modules/secrets   SSM SecureString per secret, /cop/<env>/<ENV_VAR_NAME>; values write-only (never in state).
                    Locally the 9 required ones: SMTP_AUTH_PASSWORD and SLACK_WEBHOOK_URL are empty and
                    SSM rejects empty values
  modules/host      t4g.small (Amazon Linux 2023 arm64), IMDSv2, encrypted gp3; instance role: own secrets,
                    own images, own bucket (no delete), Session Manager. No SSH key, no managed policies
                    (AmazonSSMManagedInstanceCore would allow reading every parameter in the account)
  environments/local  all modules applied to Floci: `make infra`
```

- **Secrets never reach the state file.** `aws_ssm_parameter.value_wo` (write-only) with an
  ephemeral variable; Compose builds `TF_VAR_secrets` from `.env`. Terraform cannot detect
  drift in a write-only value: re-sync one with
  `-replace='module.secrets.aws_ssm_parameter.this["NAME"]'` or bump the module's `rotation`.
- **The local provider only accepts account `000000000000`** (`allowed_account_ids`), on top of
  the fake credentials. `make test` proves a plan in another account is refused.
- `tests/integration/infra.sh` applies, requires an empty second plan (Floci returns what
  was written), checks no secret is in the state, then reads every security setting back with
  the AWS CLI. Each check was made to fail once by reverting what it guards.

**What Floci 2.4.0 was verified to do** (AWS CLI first, then Terraform), `ap-south-1`:

| Service | Operations verified | Gaps found |
|---|---|---|
| S3 | create (location constraint), versioning, SSE-S3, public access block, ownership controls, lifecycle, bucket policy, tags (incl. S3 Control), put/get/delete objects and versions | Bucket policies are stored, **not enforced** (a TLS-only bucket still answered plain HTTP) |
| ECR | create (immutable, scan on push, AES256), lifecycle policy, describe, auth token | **DeleteRepository fails** ("backing registry unreachable"); push/pull unavailable. With the Docker socket mounted Floci starts `registry:2` but still can't reach it from its own container, so the socket stays unmounted |
| IAM | roles, inline and AWS-managed policies, instance profiles | Policies are not enforced by default |
| SSM / KMS | SecureString with `alias/aws/ssm`, by-path reads, write-only values, public AMI parameter | `get-parameter` returns plaintext even without `--with-decryption` |
| VPC | VPC + DNS attributes, subnet, IGW, route table + route, SG rules (`aws_vpc_security_group_*_rule`), default SG | `ModifySecurityGroupRules` returns true and changes nothing (Terraform then shows drift: change a rule by replacing it). After the default egress rule is revoked, `describe-security-group-rules` still lists it while `describe-security-groups` doesn't (tests read the latter) |
| EC2 | describe images/AZs/instance types, run/terminate, IMDSv2 options, encrypted root volume | **Metadata only** without a Docker socket: no container, UserData or SSM commands (experimental; workloads run in Compose) |

Not verified on Floci, so not claimed there: real network isolation, IAM enforcement, ECR image
push, deletion of ECR repositories. The AWS deployment below verifies the first three on real AWS.

### Deploying to AWS

The same stack runs on one Graviton instance in `ap-south-1`, as a short-lived demo: apply,
deploy, verify, destroy. The host has **no inbound ports**; humans reach the UIs through an SSM
Session Manager port-forward.

```
Mac                                       AWS ap-south-1 (VPC, one public subnet, no ingress)
make aws-deploy ── ECR push (2 app images) ──► ECR (immutable tags = commit)
                ── release tarball ─────────► S3 releases/<tag>.tar.gz
                ── SSM Run Command ─────────► t4g.small host: deploy.sh
                                                .env from SSM /cop/aws (SecureString)
                                                docker compose -f docker-compose.yml -f docker-compose.aws.yml up
make aws-tunnel ◄── SSM port-forward ───────── Grafana :3000, Prometheus :9090, Alertmanager :9093
  127.0.0.1:13000 / :19090 / :19093
```

**One-time account setup (as an admin, in the console):**
1. Root MFA; a monthly budget with alerts (untick *Credits* so it tracks real usage).
2. Two customer-managed policies from `infrastructure/iam/` (replace `ACCOUNT_ID`):
   `cop-host-boundary` and `cop-deployer`.
3. An IAM user with **only** `cop-deployer` attached and an access key, stored as profile
   `cop` in `~/.aws/credentials`. Set `AWS_ACCOUNT_ID` in `.env`.

```bash
make aws-plan     # read-only; saves the plan
make aws-apply    # applies exactly that plan (billable from here)
make aws-deploy   # build + push images, upload the release, run it on the host (or: GitHub deploy workflow)
make aws-test     # on-host health, environment labels, real IAM enforcement
make aws-tunnel   # Grafana http://127.0.0.1:13000 (same login as local)
make aws-destroy  # asks, then removes everything
```

- **Credential isolation:** only the `aws-real` and `terraform-aws` containers mount `~/.aws`
  (read-only, profile `cop`); every `make aws-*` target first checks the account against
  `AWS_ACCOUNT_ID`, and Terraform's `allowed_account_ids` does too. `infra.sh` fails if the
  Floci containers ever mount `~/.aws`.
- **No admin-role escalation:** the deployer may create `cop-*` roles only with
  `cop-host-boundary` attached (and an explicit Deny otherwise), so a leaked deploy key can't
  mint a role wider than the host's own. `make aws-test` proves it on real IAM.
- **Host role, enforced by real IAM** (checked by `make aws-test`): reads secrets only under
  `/cop/aws`, pulls only `cop/*` images, reads/writes but never deletes objects in its bucket.
- **Free account plan:** only free-tier instance types launch; `t4g.small` (2 GiB) is the
  largest arm64 one, so the host adds 2 GiB swap (stack ≈1 GiB). Creating an AWS Organization
  (e.g. for IAM Identity Center) upgrades the account to paid and **forfeits free-plan credits**.
- **Demo shortcuts** (`ponytail:` in the code): local Terraform state, data on the root volume
  (lost with the instance), Loki on local disk, Mailpit/alert-sink instead of real email/Slack,
  the host reuses the local `.env` secret values.

### CI/CD

GitHub Actions run the same `make` targets as a laptop, on arm64 runners (like the Mac and
the t4g host). Actions are pinned to commit SHAs; Docker Compose is the host's pinned,
checksum-verified binary.

| Workflow | Trigger | Does |
|---|---|---|
| `ci.yml` | push to `master`, every PR | `make scan`, and `make unit && make up && make health && make test` on a fresh stack with random secrets (`scripts/ci-env.sh`) |
| `deploy.yml` | manual, with a commit/tag/branch | builds and pushes the images (skipped when ECR already has that commit), then `scripts/aws.sh deploy`. If the release fails its checks on the host, `scripts/aws.sh rollback` puts the host back on the last release that passed them |

**Security scans** (`make scan`, fails on any finding):

| Tool | Scans |
|---|---|
| Gitleaks | the whole Git history for secrets (`.gitleaksignore` lists reviewed false positives by fingerprint) |
| Checkov | Terraform, Dockerfiles, workflows. Accepted findings are skipped **at the resource** with the reason (e.g. no KMS CMK: $1/month per key; no VPC flow logs: no ingress, demo lifetime) |
| actionlint | workflow syntax and expressions |
| Trivy | npm/pip lockfiles and the three built images (`cop/ecommerce-api`, `cop/incident-api`, `cop/aws-tools`), HIGH/CRITICAL with a fix available. Images are scanned from `docker save` tarballs, so Trivy never gets the Docker socket |

**Deploys and rollback.** Images and release tarballs are tagged with the commit and never
overwritten (ECR tags are immutable), so deploying an older commit **is** the rollback, and
it is fast: the images are already in ECR. `deploy.sh` on the host waits for every
healthcheck and every endpoint; only a release that passes becomes `/opt/cop/current` (the
one before it is kept as `previous`). A failed release prints both migration jobs' logs.
Migrations are forward-only, so a release must stay compatible with the schema of the one
after it (expand, then contract) for a rollback to be safe.

**GitHub → AWS without stored keys (one-time, as an admin):**
1. IAM → Identity providers → OpenID Connect: `https://token.actions.githubusercontent.com`,
   audience `sts.amazonaws.com`.
2. Policy `github-cop-deploy` from `infrastructure/iam/github-deploy-policy.json`, and role
   `github-cop-deploy` with trust policy `infrastructure/iam/github-deploy-trust.json`
   (replace `ACCOUNT_ID` in both). The role can push `cop/*` images, upload `releases/*`, and
   run commands only on `project=cop` instances: no Terraform, IAM, or reads of secrets. The
   trust allows only this repository's `aws` environment. The name is outside `cop-*`, so the
   deployer key can't modify it.
3. GitHub → Settings → Environments → `aws`: a required reviewer, deployment branch `master`,
   and the secret `AWS_ACCOUNT_ID`.

### Backups and restore

```bash
scripts/backup.sh                  # both databases -> backups/<UTC timestamp>/ (git-ignored); online
scripts/restore.sh backups/<ts>    # replaces both databases; the APIs are stopped meanwhile
```

- `pg_dump` custom format of `ecommerce` and `incidents`, including ownership and grants. Each
  dump is listed back right after it is written (a truncated dump fails then, not at restore).
- Restore runs per database in **one transaction**: a failed restore leaves the data as it was.
- **On AWS** a systemd timer (`cop-backup.timer`, installed by every deploy) runs the backup daily
  at 02:00 UTC and copies it to `s3://cop-aws-backups-<account>/backups/<ts>/`. The bucket is
  versioned and the host role can't delete objects, so a compromised host can't erase backups.
  The local copy stays in the release directory until a later deploy prunes that release.
  Restore on the host: `scripts/restore.sh s3://cop-aws-backups-<account>/backups/<ts>`.
- `make test` runs a restore drill (`tests/integration/backup.sh`): back up, **drop the order
  tables** and delete marker rows, restore, then check row counts, the markers, and that the API
  can place an order again (its role's grants came back). Proven to fail with a no-op restore
  and with a restore that skips grants.
- Not backed up: Prometheus and Loki data (re-collected; 30d / 72h retention) and Grafana
  (provisioned from Git). Backups are kept as long as the bucket lives.

### Failure drills

`scripts/simulate.sh app-down | db-down | redis-down | loki-down` stops one component and
times the response: alert firing → incident opened → component restarted → alert resolved
→ incident resolved. It refuses to start while that alert is already firing. Runs on the AWS
host too: `scripts/aws.sh run '/opt/cop/current/scripts/simulate.sh db-down'`. Configured
email/Slack receivers are paged: that is the point of a drill.

Measured 2026-11-05 (locally unless marked), seconds from the break and from the restart:

| Drill | Alert (rule `for:`) | Firing | Incident opened | Alert resolved | Incident resolved |
|---|---|---|---|---|---|
| `app-down` | ApplicationDown (1m), critical | 85 | 116 | 10 | 55 |
| `db-down` | DatabaseUnavailable (1m), critical | 75 | 106 | 15 | 61 |
| `redis-down` | RedisUnavailable (1m), warning | 80 | 110 | 30 | 298 |
| `loki-down` | EndpointDown (2m), warning | 145 | 176 | 60 | 303 |
| `db-down` on AWS (t4g.small) | DatabaseUnavailable (1m), critical | 75 | 105 | 25 | 55 |

Firing = `for:` + up to two 15s scrape/evaluation cycles; the incident follows after the
route's `group_wait` (30s). Warnings resolve slower because their route batches
notifications every 5 minutes (`group_interval`), critical ones every minute. The first
drills found a real bug: restarting a container made Loki reject its replayed log and page
a critical `LokiIngestionFailure` (fixed in Alloy, see "Log pipeline").

### Security notes (current state)

- **Docker socket = root.** Alloy and cAdvisor mount `/var/run/docker.sock`. Mounting it `:ro`
  does *not* limit the Docker API (verified: a container can be created through a `:ro` mount),
  so both effectively have root on the host. Accepted for the short AWS demo (no inbound
  ports). A socket proxy would help only Alloy: cAdvisor also needs `/var/run` and
  `/var/lib/docker` from the host, so it stays root-equivalent either way.
- **Redaction is a safety net, not the primary control.** Alloy redacts secrets before logs
  reach Loki, but Docker's own log files (`docker logs`) still hold the original lines. The
  real rule is that applications never log secrets (enforced in the app code from Phase 3).
  The JSON pattern only matches string values (`"password": "…"`), not numbers or nested objects.
- **Locally built images are never pulled.** `cop/ecommerce-api` has `pull_policy: build`
  (API) and `never` (migrate job): the `cop` namespace is unclaimed on Docker Hub, so a pull
  could fetch someone else's image and hand it the database owner password. Tested by `make test`.
- **Incident API:** every write needs the bearer token (Alertmanager sends it); reads are
  open, fine on `127.0.0.1`. One shared token, and `actor` is whoever the caller says:
  per-user authentication comes before anyone outside the team can reach it.
- **`/metrics` and secrets:** the API serves `/metrics` on its own port; on AWS no port is
  reachable from outside (no inbound rules), so it's moot until a load balancer is added. On
  AWS the secrets' source of truth is SSM (SecureString), but containers still receive them as
  environment variables (visible to root via `docker inspect`).
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
- Same for `incident-migrate`: read it with `docker compose logs incident-migrate`.
- An incident opens when its first alert **fires** (after the rule's `for`), so "opened"
  is that time, not when the problem began (e.g. 1 minute earlier for DatabaseUnavailable).
- The spool covers incident-db outages only. If the incident API container itself is down
  while an alert fires and clears, Alertmanager can't deliver it and won't send the
  resolved one later: that alert is missing here (email and Slack still have it).
- Resolved is final for an alert firing `(fingerprint, startsAt)`. If Alertmanager itself
  resolves an alert because Prometheus stopped re-sending it (Prometheus down for 4+
  minutes) and Prometheus later re-sends the same firing, it is not reopened.
- Correlation only joins **unresolved** incidents: a symptom that fires after its cause's
  incident auto-resolved opens a new incident.
- `make test` leaves its incidents (environment `incident-test-<pid>`), all resolved, in the
  history: nothing is deleted. Running it twice within 15 minutes also fires
  ContainerRestarting for incident-db (each run restarts it once).
- `environments/local` stays applied (like the rest of the stack); `terraform destroy` stops at
  the ECR repositories (Floci can't delete them, see above). `make clean` wipes Floci's data;
  the next `make infra` recreates everything (state notices the resources are gone).
- The emulated EC2 instance is a record, not a machine; the platform itself runs in Compose.
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
make unit     # app + incident API unit tests, alert rule tests, config checks, terraform fmt (in Docker, no stack needed)
make up       # build the app, start the stack, wait for healthchecks, reload configs
make health   # every endpoint ready + AWS CLI provably pointed at Floci
make test     # integration tests: platform, app, incidents, alerting, backup/restore, Terraform on Floci (~7 min; briefly stops Redis, Postgres, incident-db, both APIs)
make scan     # Gitleaks, Checkov, actionlint, Trivy (lockfiles + images); same as CI
make infra    # apply infrastructure/terraform/environments/local to Floci
make load     # k6 shoppers for 2m (DURATION=5m to change); watch Grafana meanwhile
make aws ARGS="s3 ls"
make tf ARGS="version"
make down     # stop (keeps data); `make clean` deletes volumes after confirmation
```

## Safety: local credentials cannot reach AWS

The `aws` and `terraform` containers set `AWS_ACCESS_KEY_ID=test`,
`AWS_ENDPOINT_URL=http://floci:4566` and never mount `~/.aws`. Even with the
endpoint removed, the fake keys are rejected by real AWS. `make health` asserts
the caller account is Floci's `000000000000`, and the local Terraform provider refuses
any other account (`allowed_account_ids`). Real AWS goes through separate containers
(`aws-real`, `terraform-aws`); see "Deploying to AWS".

## Environment variables

See [.env.example](.env.example); every variable is documented there.
