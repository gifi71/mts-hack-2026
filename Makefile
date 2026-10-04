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

$(VENV)/.deps: ansible/requirements.txt ansible/requirements.yml
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install -q --require-hashes -r ansible/requirements.txt
	$(VENV)/bin/ansible-galaxy collection install -r ansible/requirements.yml -p ansible/.ansible/collections
	touch $@

.PHONY: deps
deps: $(VENV)/.deps ## Install pinned Ansible and collections into .venv

# Developer only: experts install the generated lock with plain pip.
.PHONY: lock
lock: ## Regenerate the hashed Python locks (Ansible, CI tools) from their requirements.in with uv
	uv pip compile ansible/requirements.in --generate-hashes --universal --python-version 3.12 --quiet -o ansible/requirements.txt
	uv pip compile .github/ci-requirements.in --generate-hashes --universal --python-version 3.12 --quiet -o .github/ci-requirements.txt

.PHONY: check-inventory
check-inventory:
	@test -n "$(INVENTORY)" || { echo "No inventory: on the VM itself use INVENTORY=ansible/inventory/localhost.yml, over SSH create ansible/inventory/hosts.yml, on Proxmox run make infra-up"; exit 1; }

.PHONY: deploy
deploy: deps check-inventory ## Install Kubernetes and the platform (idempotent, safe to re-run)
	$(VENV)/bin/ansible-playbook -i $(INVENTORY) ansible/site.yml $(ANSIBLE_ARGS)

.PHONY: verify
verify: deps check-inventory ## Smoke tests: Gateway API routing, Prometheus targets and queries, SLO rules, Kyverno, logs in Loki
	$(VENV)/bin/ansible-playbook -i $(INVENTORY) ansible/verify.yml $(ANSIBLE_ARGS)

.PHONY: credentials
credentials: deps check-inventory ## Print Grafana and Argo CD admin passwords (generated at install)
	$(VENV)/bin/ansible-playbook -i $(INVENTORY) ansible/info.yml --tags credentials $(ANSIBLE_ARGS)

.PHONY: ca-cert
ca-cert: deps check-inventory ## Save the local CA certificate to mts-hack-ca.crt (for curl --cacert / browser)
	$(VENV)/bin/ansible-playbook -i $(INVENTORY) ansible/info.yml --tags ca $(ANSIBLE_ARGS)

.PHONY: cis
cis: deps check-inventory ## CIS Kubernetes Benchmark on the node (kube-bench, accepted failures skipped)
	@scripts/ssh-node.sh $(INVENTORY) 'cd /tmp && sudo bash -s' < tests/cis/kube-bench.sh

.PHONY: ssh
ssh: deps check-inventory ## Open a shell on the node (same key, known_hosts and jump host as Ansible)
	@scripts/ssh-node.sh $(INVENTORY)

##@ Docs

.PHONY: passport
passport: ## Build docs/passport/Паспорт.pdf (needs pandoc, graphviz, chromium)
	docs/passport/build.sh

REPO_URL ?= https://github.com/gifi71/mts-hack-2026

.PHONY: submission
submission: passport ## Build dist/<SURNAME>.zip with Ссылка.txt and Паспорт.pdf (SURNAME=...)
	@test -n "$(SURNAME)" || { echo "Usage: make submission SURNAME=<фамилия при регистрации>"; exit 1; }
	mkdir -p dist/submission
	printf '%s\n' "$(REPO_URL)" > dist/submission/Ссылка.txt
	cp docs/passport/Паспорт.pdf dist/submission/Паспорт.pdf
	cd dist/submission && rm -f "../$(SURNAME).zip" && python3 -m zipfile -c "../$(SURNAME).zip" Ссылка.txt Паспорт.pdf
	@python3 -m zipfile -l "dist/$(SURNAME).zip"
	@ls -l "dist/$(SURNAME).zip"

##@ Quality

PRE_COMMIT ?= pre-commit

.PHONY: hooks
hooks: ## Install the git pre-commit hooks (needs pre-commit and tofu on PATH)
	$(PRE_COMMIT) install

.PHONY: lint
lint: ## Run every pre-commit check on all files, the same set as the CI lint job
	$(PRE_COMMIT) run --all-files

KUSTOMIZE_DIRS := gitops/platform/gateway gitops/platform/monitoring/manifests gitops/platform/kyverno/policies gitops/workloads/demo-app
CRD_SCHEMAS := https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json

.PHONY: manifests-check
manifests-check: ## Render the app of apps and kustomize trees, validate with kubeconform
	helm lint gitops/apps
	helm template root gitops/apps | kubeconform -strict -summary -schema-location default -schema-location '$(CRD_SCHEMAS)'
	for d in $(KUSTOMIZE_DIRS); do \
	  kubectl kustomize $$d | kubeconform -strict -summary -schema-location default -schema-location '$(CRD_SCHEMAS)' -skip EnvoyProxy || exit 1; \
	done

SLOTH ?= sloth
SLO_SPEC := gitops/platform/monitoring/slo/demo-app.yaml
SLO_RULES := gitops/platform/monitoring/manifests/slo-rules.yaml

.PHONY: slo
slo: ## Generate SLO recording rules and burn-rate alerts from the Sloth spec
	$(SLOTH) generate -i $(SLO_SPEC) -o $(SLO_RULES)

RENDER_DIR := .rendered
KUBESCAPE ?= kubescape
KUBESCAPE_ARGS ?=

.PHONY: render
render: ## Render the Kustomize trees into .rendered/ (input for scanners)
	rm -rf $(RENDER_DIR) && mkdir -p $(RENDER_DIR)
	for d in $(KUSTOMIZE_DIRS); do \
	  kubectl kustomize $$d > $(RENDER_DIR)/$$(echo $$d | tr / _).yaml || exit 1; \
	done

.PHONY: kubescape
kubescape: render ## Kubescape NSA and MITRE ATT&CK frameworks over the rendered manifests
	$(KUBESCAPE) scan framework nsa,mitre $(RENDER_DIR) $(KUBESCAPE_ARGS)

.PHONY: tofu-check
tofu-check: ## fmt check, validate and unit tests for OpenTofu code
	$(TOFU) fmt -recursive -check infra/tofu
	$(TOFU) -chdir=$(TOFU_DIR) init -backend=false -input=false >/dev/null
	$(TOFU) -chdir=$(TOFU_DIR) validate
	$(TOFU) -chdir=infra/tofu/modules/ansible-inventory init -input=false >/dev/null
	$(TOFU) -chdir=infra/tofu/modules/ansible-inventory test
