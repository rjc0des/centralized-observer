SHELL := /bin/bash
.DEFAULT_GOAL := help
-include .env
export FLOCI_PORT
FLOCI_PORT ?= 4566
COMPOSE := docker compose
RUN := $(COMPOSE) --progress quiet run --rm
DURATION ?= 2m

.PHONY: help doctor up down ps logs reload health aws tf unit test load clean

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(firstword $(MAKEFILE_LIST)) | awk -F':.*## ' '{printf "  %-8s %s\n", $$1, $$2}'

doctor: ## Check the local toolchain (read-only)
	@scripts/doctor.sh

up: ## Build the app, start the stack and wait until healthy
	$(COMPOSE) up -d --wait --build
	@# Loki has no container healthcheck (distroless) and needs ~15-30s to form its ring.
	@# Running containers don't see edited config files until reloaded.
	@$(MAKE) --no-print-directory reload
	@for i in $$(seq 1 30); do curl -fs -o /dev/null http://127.0.0.1:3100/ready && { echo "loki: ready"; exit 0; }; sleep 2; done; \
	  echo "loki: not ready after 60s (make logs S=loki)"; exit 1

reload: ## Validate, then reload Prometheus, Alertmanager, Blackbox and Alloy configs (fails if any is rejected)
	@scripts/reload.sh

down: ## Stop the stack (volumes kept)
	$(COMPOSE) down

ps: ## Show stack containers
	$(COMPOSE) ps

logs: ## Follow logs (S=<service> for one)
	$(COMPOSE) logs -f $(S)

health: ## Check every published endpoint is ready, and the AWS CLI talks to Floci, not real AWS
	@for u in prometheus=http://127.0.0.1:9090/-/ready alertmanager=http://127.0.0.1:9093/-/ready \
	          loki=http://127.0.0.1:3100/ready alloy=http://127.0.0.1:12345/-/ready grafana=http://127.0.0.1:3000/api/health \
	          ecommerce-api=http://127.0.0.1:8080/health incident-api=http://127.0.0.1:8081/health mailpit=http://127.0.0.1:8025/readyz; do \
	  curl -fsS -o /dev/null -m 5 "$${u#*=}" && echo "$${u%%=*}: ready" || { echo "$${u%%=*}: NOT ready ($${u#*=})"; exit 1; }; \
	done
	@curl -fsS http://127.0.0.1:$(FLOCI_PORT)/_floci/init | grep -q '"ready":true' && echo "floci: ready on 127.0.0.1:$(FLOCI_PORT)"
	@acct=$$($(RUN) -T aws sts get-caller-identity --query Account --output text); \
	  if [ "$$acct" = 000000000000 ]; then echo "aws cli: -> floci (account $$acct)"; \
	  else echo "aws cli: NOT pointed at floci (account '$$acct')"; exit 1; fi

aws: ## AWS CLI against Floci, e.g. make aws ARGS="s3 ls"
	@$(RUN) aws $(ARGS)

tf: ## Terraform (Floci creds), e.g. make tf ARGS="-chdir=infrastructure/terraform/environments/local plan"
	@$(RUN) terraform $(ARGS)

unit: ## Unit tests: apps (Docker test stage), alert rules (promtool), Alertmanager config (amtool); no stack needed
	docker build --target test apps/ecommerce-api
	docker build --target test apps/incident-api
	@$(RUN) --no-deps -T --entrypoint promtool prometheus check config /etc/prometheus/prometheus.yml
	@$(RUN) --no-deps -T --entrypoint promtool -w /etc/prometheus/tests prometheus test rules alerts.test.yml
	@$(RUN) --no-deps -T alertmanager check

test: ## Integration tests against the running stack
	@tests/integration/observability.sh
	@tests/integration/ecommerce.sh
	@tests/integration/incidents.sh
	@tests/integration/alerting.sh

load: ## Generate shop traffic with k6, e.g. make load DURATION=5m
	@$(RUN) -e DURATION=$(DURATION) k6 run /scripts/ecommerce.js

clean: ## Stop the stack and DELETE its volumes (asks first)
	@read -rp "Delete all cop volumes (metrics, logs, Grafana, Postgres, Floci data, plugin cache)? [y/N] " a; \
	  if [ "$$a" = y ]; then $(COMPOSE) --profile tools down -v --remove-orphans; else echo "aborted, nothing deleted"; fi
