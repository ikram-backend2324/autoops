# AutoOps - single entry point. `make help` lists everything.
# Works on Linux, macOS and Windows via WSL2 (see docs/RUN.md).

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
export MSYS_NO_PATHCONV := 1

ROOT        := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
LOCAL       := docker compose -f $(ROOT)/local/compose.yml
PYTHON      ?= $(shell command -v python3 2>/dev/null || command -v python 2>/dev/null)
TOOLS_IMAGE ?= autoops/tools:local
APP         ?= sample
INVENTORY   ?= ansible/inventory/hosts.yml
LIMIT       ?= all

# Ansible/linters run from the tools container unless ansible is installed locally.
ifeq ($(shell command -v ansible-playbook 2>/dev/null),)
  TOOLS = docker run --rm -i $(shell [ -t 0 ] && echo -t) \
          -v $(ROOT):/work -w /work \
          -v $(HOME)/.ssh:/root/.ssh:ro \
          -v /var/run/docker.sock:/var/run/docker.sock \
          -e ANSIBLE_VAULT_PASSWORD_FILE -e ANSIBLE_CONFIG=/work/ansible/ansible.cfg \
          $(TOOLS_IMAGE)
  TOOLS_DEP = tools-image
else
  TOOLS =
  TOOLS_DEP =
endif
PLAYBOOK = $(TOOLS) ansible-playbook -i $(INVENTORY) --limit $(LIMIT)

##@ Help
.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nAutoOps - make <target>\n"} \
	  /^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0, 5)} \
	  /^[a-zA-Z0-9_-]+:.*?##/ {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

##@ Local demo (laptop, no server needed)
local/.env:
	cp local/.env.example local/.env
	@echo "created local/.env from local/.env.example"

.PHONY: demo-rules
demo-rules: ## Generate demo alert rules (durations capped at 1m) into local/generated
	$(PYTHON) scripts/dev/fast_rules.py

.PHONY: local-up
local-up: local/.env demo-rules ## Start app + monitoring + alerting + self-healing + S3 locally
	docker network inspect autoops >/dev/null 2>&1 || docker network create autoops
	$(LOCAL) up -d --build --remove-orphans
	@scripts/dev/wait_healthy.sh autoops 240
	@echo
	@echo "  App:          http://localhost:$$(grep -E '^LOCAL_WEB_PORT=' local/.env | cut -d= -f2)"
	@echo "  Grafana:      http://localhost:3000  (admin / see GRAFANA_ADMIN_PASSWORD in local/.env)"
	@echo "  Prometheus:   http://localhost:9090"
	@echo "  Alertmanager: http://localhost:9093"
	@echo "  Alerts log:   make local-alerts"

.PHONY: local-down
local-down: ## Stop the local stack (keeps data volumes)
	$(LOCAL) down --remove-orphans

.PHONY: local-clean
local-clean: ## Stop the local stack AND delete its volumes (DB, metrics, backups)
	$(LOCAL) down --remove-orphans --volumes

.PHONY: local-ps
local-ps: ## Status of local containers
	$(LOCAL) ps -a --format 'table {{.Service}}\t{{.Status}}'

.PHONY: local-logs
local-logs: ## Follow logs (SERVICE=web to filter)
	$(LOCAL) logs -f --tail 100 $(SERVICE)

.PHONY: local-alerts
local-alerts: ## Follow alerts and self-healing notifications (notify-relay log)
	$(LOCAL) logs -f --tail 50 notify-relay

##@ Backups (local: run inside the ops container; server: make server-backup)
.PHONY: backup
backup: ## Run a backup now (local demo)
	$(LOCAL) exec -T ops /opt/autoops/scripts/backup/backup.sh

.PHONY: verify-restore
verify-restore: ## Restore the latest backup into a temporary DB and check it (local demo)
	$(LOCAL) exec -T ops /opt/autoops/scripts/backup/verify_restore.sh

.PHONY: restore
restore: ## Interactive restore of APP from a snapshot (local demo)
	$(LOCAL) exec ops /opt/autoops/scripts/backup/restore.sh --app $(APP)

.PHONY: report
report: ## Send the weekly report now (local demo)
	$(LOCAL) exec -T ops python3 /opt/autoops/scripts/report/weekly_report.py

##@ Chaos demo
.PHONY: chaos
chaos: ## Run all chaos scenarios interactively and write docs/chaos-report.md
	scripts/chaos/run_all.sh

.PHONY: chaos-auto
chaos-auto: ## Same, without pauses (CI / recording)
	CHAOS_NONINTERACTIVE=1 scripts/chaos/run_all.sh

.PHONY: chaos-kill chaos-unhealthy chaos-db chaos-disk chaos-cpu
chaos-kill: ; scripts/chaos/kill_container.sh      ## Scenario 1: kill web
chaos-unhealthy: ; scripts/chaos/make_unhealthy.sh ## Scenario 2: web unhealthy
chaos-db: ; scripts/chaos/stop_db.sh               ## Scenario 3: stop Postgres
chaos-disk: ; scripts/chaos/fill_disk.sh           ## Scenario 4: fill the disk
chaos-cpu: ; scripts/chaos/cpu_stress.sh           ## Scenario 5: CPU stress

##@ Quality
.PHONY: tools-image
tools-image: ## Build the tools image (ansible, linters, promtool, amtool, actionlint)
	docker build -q -t $(TOOLS_IMAGE) tools >/dev/null

.PHONY: lint
lint: $(TOOLS_DEP) ## All linters: yamllint, ansible-lint, shellcheck, ruff, promtool, amtool, actionlint, compose
	$(TOOLS) scripts/dev/lint.sh

.PHONY: test
test: test-app test-rules ## App unit tests + alert rule unit tests (Molecule: make molecule)

.PHONY: test-app
test-app: ## Django tests + ruff in the sample-app test image
	docker build -q --target test -t autoops/sample-app:test sample-app >/dev/null
	docker run --rm autoops/sample-app:test

.PHONY: test-rules
test-rules: ## promtool unit tests for alert rules
	docker run --rm -v $(ROOT)/stacks/monitoring/prometheus:/p -w /p --entrypoint promtool \
	  prom/prometheus:v3.5.0 test rules tests/rules_test.yml

.PHONY: molecule
molecule: $(TOOLS_DEP) ## Molecule converge + idempotence for all roles (ROLE=base for one)
	$(TOOLS) scripts/dev/molecule.sh $(ROLE)

.PHONY: dashboards
dashboards: ## Regenerate Grafana dashboard JSON from scripts/dev/gen_dashboards.py
	$(PYTHON) scripts/dev/gen_dashboards.py

.PHONY: screenshots
screenshots: ## Grafana screenshots into docs/screenshots (local stack must be up)
	scripts/dev/screenshots.sh

##@ Real server (Ansible)
.PHONY: ping
ping: $(TOOLS_DEP) ## Check SSH access to the inventory
	$(TOOLS) ansible -i $(INVENTORY) all -m ping

.PHONY: provision
provision: $(TOOLS_DEP) ## Clean Ubuntu -> hardened Docker host with monitoring, backups, self-healing
	$(PLAYBOOK) ansible/playbooks/provision.yml

.PHONY: deploy
deploy: $(TOOLS_DEP) ## Deploy/upgrade the apps defined in inventory (TAG=<sha> to pin a version)
	$(PLAYBOOK) ansible/playbooks/deploy.yml $(if $(TAG),-e app_tag_override=$(TAG))

.PHONY: monitoring
monitoring: $(TOOLS_DEP) ## Re-apply only the monitoring stack and alert rules
	$(PLAYBOOK) ansible/playbooks/monitoring.yml

.PHONY: server-backup
server-backup: $(TOOLS_DEP) ## Configure backups (and run one now with RUN=1)
	$(PLAYBOOK) ansible/playbooks/backup.yml $(if $(RUN),-e backup_run_now=true)

.PHONY: update
update: $(TOOLS_DEP) ## Rolling OS + Docker updates (one host at a time, reboot if needed)
	$(PLAYBOOK) ansible/playbooks/update.yml

.PHONY: rollback
rollback: $(TOOLS_DEP) ## Roll APP back to the previous image tag on the server
	$(PLAYBOOK) ansible/playbooks/deploy.yml -e app_rollback=$(APP)

.PHONY: vault-edit
vault-edit: $(TOOLS_DEP) ## Edit encrypted secrets (ansible/inventory/group_vars/all/vault.yml)
	$(TOOLS) ansible-vault edit ansible/inventory/group_vars/all/vault.yml
