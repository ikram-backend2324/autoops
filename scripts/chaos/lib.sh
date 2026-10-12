#!/usr/bin/env bash
# Shared helpers for chaos scenarios (sourced).
# shellcheck disable=SC2034
set -Eeuo pipefail

CHAOS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$CHAOS_DIR/../lib/common.sh"

# Defaults fit the laptop demo; on a server export e.g.
#   CHAOS_APP=shop APP_HEALTH_URL=https://shop.uz/health/ CHAOS_DISK_MODE=host
CHAOS_APP=${CHAOS_APP:-sample}
RELAY_URL=${RELAY_URL:-http://127.0.0.1:9095}
PROM_URL=${PROM_URL:-http://127.0.0.1:9090}
if [[ -z "${APP_HEALTH_URL:-}" ]]; then
  port=$(grep -E '^LOCAL_WEB_PORT=' "$CHAOS_DIR/../../local/.env" 2>/dev/null | cut -d= -f2 || true)
  APP_HEALTH_URL="http://127.0.0.1:${port:-8088}/health/"
fi
RESULTS_FILE=${CHAOS_RESULTS_FILE:-${TMPDIR:-/tmp}/autoops-chaos-results.tsv}
HELPER_IMAGE=${CHAOS_HELPER_IMAGE:-docker:27-cli}

banner() {
  printf '\n%s\n' "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
  printf '%s\n' "${C_BOLD}  💥 $*${C_RESET}"
  printf '%s\n' "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
}
step() { printf '%s\n' "${C_DIM}$(date +%H:%M:%S)${C_RESET} $*"; }

container_of() {  # container_of ROLE -> id of the app container with that role (running or not)
  docker ps -aq --filter "label=autoops.app=$CHAOS_APP" --filter "label=autoops.role=$1" | head -n1
}
container_name() { docker inspect -f '{{.Name}}' "$1" | sed 's#^/##'; }
health_of() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null || echo missing; }
http_code() { curl -s -o /dev/null -m 5 -w '%{http_code}' "$1" || true; }
app_ok() { [[ "$(http_code "$APP_HEALTH_URL")" == 200 ]]; }

# wait_until TIMEOUT CMD... -> prints elapsed seconds since $T0 when CMD succeeds, or "-" on timeout
wait_until() {
  local timeout=$1; shift
  local deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) <= deadline )); do
    if "$@" >/dev/null 2>&1; then
      echo $(( $(date +%s) - T0 ))
      return 0
    fi
    sleep 2
  done
  echo "-"
  return 1
}

# relay_has SINCE REGEX -> true if notify-relay received a matching event after SINCE
relay_has() {
  curl -fsS -m 5 "$RELAY_URL/events?since=$1&limit=500" 2>/dev/null | grep -Eq "$2"
}
prom_value() {  # prom_value QUERY -> first value or empty
  curl -fsS -m 5 -G "$PROM_URL/api/v1/query" --data-urlencode "query=$1" 2>/dev/null \
    | grep -o '"value":\[[^]]*\]' | head -n1 | sed -E 's/.*,"([^"]+)"\]/\1/'
}
prom_gt() { local v; v=$(prom_value "$1"); [[ -n "$v" ]] && awk -v v="$v" -v t="$2" 'BEGIN{exit !(v > t)}'; }
prom_lt() { local v; v=$(prom_value "$1"); [[ -n "$v" ]] && awk -v v="$v" -v t="$2" 'BEGIN{exit !(v < t)}'; }

# record SCENARIO DETECTED RECOVERED ALERT RESULT
record() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$RESULTS_FILE"
  if [[ "$5" == PASS ]]; then
    ok "${C_BOLD}$1${C_RESET}: обнаружено за $2 с, восстановлено за $3 с, оповещение: $4"
  else
    warn "${C_BOLD}$1${C_RESET}: $5 (обнаружено: $2, восстановлено: $3, оповещение: $4)"
  fi
}

preflight() {
  command -v docker >/dev/null || die "docker is required"
  command -v curl >/dev/null || die "curl is required"
  [[ -n "$(container_of web)" ]] || die "app '$CHAOS_APP' is not running (make local-up)"
  app_ok || die "app is not healthy before the test ($APP_HEALTH_URL) - fix that first"
  curl -fsS -m 5 "$RELAY_URL/health" >/dev/null || die "notify-relay is not reachable at $RELAY_URL"
}
