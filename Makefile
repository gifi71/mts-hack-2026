SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

TOFU     ?= tofu
TOFU_DIR := infra/tofu/proxmox

VENV      ?= .venv
INVENTORY ?= $(firstword $(wildcard ansible/inventory/generated/proxmox.yml ansible/inventory/hosts.yml))
ANSIBLE_ARGS ?=

export ANSIBLE_CONFIG := ansible/ansible.cfg

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

##@ Deploy

$(VENV)/.deps: requirements.txt ansible/requirements.yml
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install -q --upgrade pip
	$(VENV)/bin/pip install -q -r requirements.txt
	$(VENV)/bin/ansible-galaxy collection install -r ansible/requirements.yml -p ansible/.ansible/collections
	touch $@

.PHONY: deps
deps: $(VENV)/.deps ## Install pinned Ansible and collections into .venv

.PHONY: check-inventory
check-inventory:
	@test -n "$(INVENTORY)" || { echo "No inventory: run 'make infra-up' or create ansible/inventory/hosts.yml"; exit 1; }

.PHONY: deploy
deploy: deps check-inventory ## Install Kubernetes and the platform (idempotent, safe to re-run)
	$(VENV)/bin/ansible-playbook -i $(INVENTORY) ansible/site.yml $(ANSIBLE_ARGS)

.PHONY: verify
verify: deps check-inventory ## Smoke tests: Gateway API routing, Prometheus targets and queries, logs in Loki
	$(VENV)/bin/ansible-playbook -i $(INVENTORY) ansible/verify.yml

.PHONY: ssh
ssh: deps check-inventory ## Open a shell on the node
	$(VENV)/bin/ansible -i $(INVENTORY) control_plane -m ansible.builtin.ping >/dev/null
	@ssh $$($(VENV)/bin/ansible-inventory -i $(INVENTORY) --host $$($(VENV)/bin/ansible-inventory -i $(INVENTORY) --list | python3 -c 'import sys,json;print(json.load(sys.stdin)["control_plane"]["hosts"][0])') | python3 -c 'import sys,json;h=json.load(sys.stdin);print(h.get("ansible_ssh_common_args",""),"-i",h["ansible_ssh_private_key_file"],h["ansible_user"]+"@"+h["ansible_host"])')

##@ Quality

KUSTOMIZE_DIRS := gitops/platform/gateway gitops/platform/monitoring/manifests gitops/workloads/demo-app
CRD_SCHEMAS := https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json

.PHONY: manifests-check
manifests-check: ## Render the app of apps and kustomize trees, validate with kubeconform
	helm lint gitops/apps
	helm template root gitops/apps | kubeconform -strict -summary -schema-location default -schema-location '$(CRD_SCHEMAS)'
	for d in $(KUSTOMIZE_DIRS); do \
	  kubectl kustomize $$d | kubeconform -strict -summary -schema-location default -schema-location '$(CRD_SCHEMAS)' -skip EnvoyProxy || exit 1; \
	done

.PHONY: tofu-check
tofu-check: ## fmt check, validate and unit tests for OpenTofu code
	$(TOFU) fmt -recursive -check infra/tofu
	$(TOFU) -chdir=$(TOFU_DIR) init -backend=false -input=false >/dev/null
	$(TOFU) -chdir=$(TOFU_DIR) validate
	$(TOFU) -chdir=infra/tofu/modules/ansible-inventory init -input=false >/dev/null
	$(TOFU) -chdir=infra/tofu/modules/ansible-inventory test
