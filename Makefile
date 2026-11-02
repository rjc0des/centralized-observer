SHELL := /bin/bash
.DEFAULT_GOAL := help
-include .env
FLOCI_PORT ?= 4566
COMPOSE := docker compose
RUN := $(COMPOSE) --progress quiet run --rm

.PHONY: help doctor up down ps logs health aws tf clean

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-8s %s\n", $$1, $$2}'

doctor: ## Check the local toolchain (read-only)
	@scripts/doctor.sh

up: ## Start the stack and wait until healthy
	$(COMPOSE) up -d --wait

down: ## Stop the stack (volumes kept)
	$(COMPOSE) down

ps: ## Show stack containers
	$(COMPOSE) ps

logs: ## Follow logs (S=<service> for one)
	$(COMPOSE) logs -f $(S)

health: ## Verify Floci is ready and the AWS CLI container talks to it, not real AWS
	@curl -fsS http://127.0.0.1:$(FLOCI_PORT)/_floci/init | grep -q '"ready":true' && echo "floci: ready on 127.0.0.1:$(FLOCI_PORT)"
	@acct=$$($(RUN) -T aws sts get-caller-identity --query Account --output text); \
	  if [ "$$acct" = 000000000000 ]; then echo "aws cli: -> floci (account $$acct)"; \
	  else echo "aws cli: NOT pointed at floci (account '$$acct')"; exit 1; fi

aws: ## AWS CLI against Floci, e.g. make aws ARGS="s3 ls"
	@$(RUN) aws $(ARGS)

tf: ## Terraform (Floci creds), e.g. make tf ARGS="-chdir=infrastructure/terraform/environments/local plan"
	@$(RUN) terraform $(ARGS)

clean: ## Stop the stack and DELETE its volumes (asks first)
	@read -rp "Delete all cop volumes (Floci data, Terraform plugin cache)? [y/N] " a; \
	  if [ "$$a" = y ]; then $(COMPOSE) --profile tools down -v --remove-orphans; else echo "aborted, nothing deleted"; fi
