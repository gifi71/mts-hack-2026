SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

TOFU     ?= tofu
TOFU_DIR := infra/tofu/proxmox

.PHONY: help
help: ## Show available targets
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

##@ Infrastructure (optional: skip if you already have an Ubuntu 24.04 VM)

.PHONY: infra-init
infra-init: ## tofu init
	$(TOFU) -chdir=$(TOFU_DIR) init -input=false

.PHONY: infra-plan
infra-plan: infra-init ## Show planned VM changes
	$(TOFU) -chdir=$(TOFU_DIR) plan

.PHONY: infra-up
infra-up: infra-init ## Create the VM and write ansible/inventory/generated/proxmox.yml
	$(TOFU) -chdir=$(TOFU_DIR) apply -auto-approve

.PHONY: infra-down
infra-down: ## Destroy the VM
	$(TOFU) -chdir=$(TOFU_DIR) destroy -auto-approve

.PHONY: infra-output
infra-output: ## Print VM IP, inventory path and ssh command
	$(TOFU) -chdir=$(TOFU_DIR) output

##@ Quality

.PHONY: tofu-check
tofu-check: ## fmt check, validate and unit tests for OpenTofu code
	$(TOFU) fmt -recursive -check infra/tofu
	$(TOFU) -chdir=$(TOFU_DIR) init -backend=false -input=false >/dev/null
	$(TOFU) -chdir=$(TOFU_DIR) validate
	$(TOFU) -chdir=infra/tofu/modules/ansible-inventory init -input=false >/dev/null
	$(TOFU) -chdir=infra/tofu/modules/ansible-inventory test
