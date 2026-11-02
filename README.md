# Centralized Observability Platform

A hybrid-cloud observability platform: metrics, logs, alerting, SLOs and incident
management for multiple applications, developed locally on OrbStack with
[Floci](https://github.com/floci-io/floci) emulating AWS APIs, and validated on AWS (`ap-south-1`).

Inspired by Uber Engineering's
[From Monitoring to Observability: Our Ultra-Marathon to a Cloud-Native Platform](https://www.uber.com/in/en/blog/from-monitoring-to-observability-cloud-native/).

> **Status: Phase 1 (development foundation).** Only what is listed under
> "Working today" has been implemented and tested. The full README is written in Phase 9.

## Working today

| Component | Version | Notes |
|---|---|---|
| Floci (AWS emulator) | `floci/floci:2.4.0` | Bound to `127.0.0.1:4566`, state persisted in the `floci-data` volume |
| AWS CLI | `amazon/aws-cli:2.38.6` | Container, hardwired to Floci with fake credentials |
| Terraform | `hashicorp/terraform:1.16.7` | Container, Floci credentials, shared plugin cache |

All images are pinned by tag and multi-arch digest. No `latest` tags.

## Prerequisites

- macOS on Apple Silicon with [OrbStack](https://orbstack.dev) (Docker Engine + Compose v2)
- `make`, `curl`, `git`

Terraform and the AWS CLI are **not** installed on the host; they run as containers.

## Quick start

```bash
cp .env.example .env
make doctor   # read-only toolchain check
make up       # start the stack, waits for healthchecks
make health   # Floci ready + AWS CLI provably pointed at Floci
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
