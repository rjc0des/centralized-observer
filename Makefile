SHELL := /bin/bash
.DEFAULT_GOAL := help
-include .env
export FLOCI_PORT
FLOCI_PORT ?= 4566
COMPOSE := docker compose
RUN := $(COMPOSE) --progress quiet run --rm

.PHONY: help doctor up down ps logs health aws tf test clean

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-8s %s\n", $$1, $$2}'

doctor: ## Check the local toolchain (read-only)
	@scripts/doctor.sh

up: ## Start the stack and wait until healthy
	$(COMPOSE) up -d --wait
	@# Loki has no container healthcheck (distroless) and needs ~15-30s to form its ring.
	@for i in $$(seq 1 30); do curl -fs -o /dev/null http://127.0.0.1:3100/ready && { echo "loki: ready"; exit 0; }; sleep 2; done; \
	  echo "loki: not ready after 60s (make logs S=loki)"; exit 1

down: ## Stop the stack (volumes kept)
	$(COMPOSE) down

ps: ## Show stack containers
	$(COMPOSE) ps

logs: ## Follow logs (S=<service> for one)
	$(COMPOSE) logs -f $(S)

health: ## Check every published endpoint is ready, and the AWS CLI talks to Floci, not real AWS
	@for u in prometheus=http://127.0.0.1:9090/-/ready alertmanager=http://127.0.0.1:9093/-/ready \
	          loki=http://127.0.0.1:3100/ready alloy=http://127.0.0.1:12345/-/ready grafana=http://127.0.0.1:3000/api/health; do \
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

test: ## Integration tests against the running stack
	@tests/integration/observability.sh

clean: ## Stop the stack and DELETE its volumes (asks first)
	@read -rp "Delete all cop volumes (metrics, logs, Grafana, Floci data, plugin cache)? [y/N] " a; \
	  if [ "$$a" = y ]; then $(COMPOSE) --profile tools down -v --remove-orphans; else echo "aborted, nothing deleted"; fi
