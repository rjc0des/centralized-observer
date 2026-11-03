# Centralized Observability Platform

A hybrid-cloud observability platform: metrics, logs, alerting, SLOs and incident
management for multiple applications, developed locally on OrbStack with
[Floci](https://github.com/floci-io/floci) emulating AWS APIs, and validated on AWS (`ap-south-1`).

Inspired by Uber Engineering's
[From Monitoring to Observability: Our Ultra-Marathon to a Cloud-Native Platform](https://www.uber.com/in/en/blog/from-monitoring-to-observability-cloud-native/).

> **Status: Phase 2 (local observability stack).** Only what is listed under
> "Working today" has been implemented and tested. The full README is written in Phase 9.

## Working today

| Component | Version | Local URL | Notes |
|---|---|---|---|
| Prometheus | `v3.15.1` | http://127.0.0.1:9090 | 15s scrape/eval, 3d / 5GB retention, file-based target discovery |
| Grafana | `13.2.5` | http://127.0.0.1:3000 | Datasources provisioned from Git; login from `.env` |
| Loki | `3.7.9` | http://127.0.0.1:3100 | Filesystem storage, 72h retention |
| Alloy | `v1.21.3` | http://127.0.0.1:12345 | Docker + system logs → redact → parse → Loki |
| Alertmanager | `v0.34.2` | http://127.0.0.1:9093 | Placeholder route; real routing in Phase 4 |
| Node Exporter | `v1.12.1` | internal | Host = OrbStack Linux VM locally |
| cAdvisor | `v0.60.6` | internal | Per-container CPU, memory, network |
| Blackbox Exporter | `v0.29.1` | internal | HTTP uptime probes |
| Floci (AWS emulator) | `2.4.0` | http://127.0.0.1:4566 | State persisted in the `floci-data` volume |
| AWS CLI | `2.38.6` | — | Container, hardwired to Floci with fake credentials |
| Terraform | `1.16.7` | — | Container, Floci credentials, shared plugin cache |

All images are pinned by tag and multi-arch digest. No `latest` tags.
Everything published binds to `127.0.0.1`; exporters are only reachable inside the Docker network.

### Adding a monitoring target

Drop a file into `observability/prometheus/targets/`. Prometheus picks it up within seconds
(measured ~3s), no restart and no edit to `prometheus.yml`:

```yaml
# observability/prometheus/targets/node-aws.yml
- targets: [10.0.1.15:9100]
  labels: {environment: aws, host: app-1}
```

### Log pipeline

Alloy collects logs from every container in this compose project (and `/var/log/syslog`,
`kern.log`, `auth.log` on Linux hosts), then:

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

## Prerequisites

- macOS on Apple Silicon with [OrbStack](https://orbstack.dev) (Docker Engine + Compose v2)
- `make`, `curl`, `git`

Terraform and the AWS CLI are **not** installed on the host; they run as containers.

## Quick start

```bash
cp .env.example .env
# set GRAFANA_ADMIN_PASSWORD in .env, e.g. openssl rand -base64 18
make doctor   # read-only toolchain check
make up       # start the stack, waits for healthchecks
make health   # every endpoint ready + AWS CLI provably pointed at Floci
make test     # integration tests: targets, metrics, log ingestion, redaction, datasources
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
