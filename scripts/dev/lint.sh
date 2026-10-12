#!/usr/bin/env bash
# Every static check of the repository. Runs inside the tools image (make lint / CI).
# shellcheck disable=SC2016  # the bash -c snippets are single-quoted on purpose
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
export ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg" ANSIBLE_ROLES_PATH="$PWD/ansible/roles"
failed=()
run() {
  local name=$1; shift
  printf '\n\033[1m▶ %s\033[0m\n' "$name"
  if "$@"; then
    printf '\033[32m✔ %s\033[0m\n' "$name"
  else
    printf '\033[31m✖ %s\033[0m\n' "$name"
    failed+=("$name")
  fi
}

mapfile -t shell_scripts < <(git ls-files '*.sh' 2>/dev/null || find . -name '*.sh' -not -path './.git/*')

run "yamllint" yamllint -s .
run "ansible-lint" bash -c 'cd ansible && ansible-lint'
run "ansible syntax-check" bash -c 'cd ansible && for p in playbooks/*.yml; do
  ansible-playbook -i inventory/hosts.example.yml --syntax-check "$p" >/dev/null || exit 1; done'
run "shellcheck" shellcheck -x --source-path=SCRIPTDIR "${shell_scripts[@]}"
run "ruff" ruff check sample-app scripts stacks/monitoring/notify-relay
run "promtool check config" promtool check config --syntax-only stacks/monitoring/prometheus/prometheus.yml
run "promtool check rules" promtool check rules stacks/monitoring/prometheus/rules/*.yml
run "promtool test rules" promtool test rules stacks/monitoring/prometheus/tests/rules_test.yml
run "amtool check-config" bash -c '
  set -e; tmp=$(mktemp -d); mkdir -p /tmp/am/templates
  cp stacks/monitoring/alertmanager/templates/*.tmpl /tmp/am/templates/
  printf x > /tmp/am/bot_token
  sed "s/__TELEGRAM_CHAT_ID__/-100123/" stacks/monitoring/alertmanager/alertmanager.yml > "$tmp/am.yml"
  amtool check-config "$tmp/am.yml" stacks/monitoring/alertmanager/alertmanager.local.yml'
run "actionlint" actionlint
run "docker compose config" bash -c '
  set -e
  APP_NAME=x APP_IMAGE=x POSTGRES_PASSWORD=x APP_ENV_FILE=/dev/null docker compose -f stacks/app/compose.yml config -q
  GRAFANA_ADMIN_PASSWORD=x docker compose -f stacks/monitoring/compose.yml config -q
  ACME_EMAIL=a@b.c docker compose -f stacks/proxy/compose.yml config -q
  ACME_EMAIL=a@b.c APP_DOMAIN=x APP_NAME=x GRAFANA_DOMAIN=y docker compose -f stacks/proxy-caddy/compose.yml config -q
  created=0; [ -f local/.env ] || { cp local/.env.example local/.env; created=1; }
  rc=0; docker compose -f local/compose.yml config -q || rc=$?
  [ "$created" = 1 ] && rm -f local/.env
  exit $rc'
run "dashboards are generated" bash -c 'python3 scripts/dev/gen_dashboards.py >/dev/null && git diff --quiet -- stacks/monitoring/grafana/dashboards'

echo
if (( ${#failed[@]} )); then
  printf '\033[31mFAILED: %s\033[0m\n' "${failed[*]}"
  exit 1
fi
printf '\033[32mAll checks passed.\033[0m\n'
