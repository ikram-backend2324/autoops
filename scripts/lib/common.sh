#!/usr/bin/env bash
# Shared helpers for AutoOps shell scripts (sourced, not executed).
# shellcheck disable=SC2034  # colour variables are used by the scripts that source this file

# Git Bash on Windows rewrites /paths in docker arguments; disable that.
export MSYS_NO_PATHCONV=1

if [[ -t 1 ]]; then
  C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_RESET=$'\e[0m'
else
  C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_BOLD='' C_DIM='' C_RESET=''
fi

log()  { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
info() { printf '%s\n' "${C_BLUE}ℹ${C_RESET} $*" >&2; }
ok()   { printf '%s\n' "${C_GREEN}✔${C_RESET} $*" >&2; }
warn() { printf '%s\n' "${C_YELLOW}⚠${C_RESET} $*" >&2; }
die()  { printf '%s\n' "${C_RED}✖ $*${C_RESET}" >&2; exit 1; }

# json_escape STRING -> STRING escaped for embedding in a JSON string literal
json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/}
  s=${s//$'\t'/ }
  printf '%s' "$s"
}

# notify SEVERITY TEXT [SOURCE] - via notify-relay, falling back to direct Telegram.
notify() {
  local severity=$1 text=$2 source=${3:-script}
  local url=${NOTIFY_URL:-http://127.0.0.1:9095/notify}
  local body
  body=$(printf '{"severity":"%s","source":"%s","text":"%s"}' "$severity" "$source" "$(json_escape "$text")")
  if curl -fsS -m 5 -H 'Content-Type: application/json' -d "$body" "$url" >/dev/null 2>&1; then
    return 0
  fi
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    curl -fsS -m 10 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${text}"$'\n'"🖥 Сервер: ${SERVER_NAME:-$(hostname)}" >/dev/null 2>&1 && return 0
  fi
  log "notify (no relay/telegram reachable): [$severity] $text"
}

# write_textfile NAME CONTENT - atomically publish metrics for node_exporter's textfile collector.
write_textfile() {
  local name=$1 content=$2 dir=${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}
  [[ -d "$dir" ]] || { log "textfile dir $dir missing, metrics skipped"; return 0; }
  printf '%s\n' "$content" > "$dir/.$name.prom.tmp"
  mv "$dir/.$name.prom.tmp" "$dir/$name.prom"
}

# find_container APP ROLE -> container id of the running service with autoops labels
find_container() {
  docker ps -q --filter "label=autoops.app=$1" --filter "label=autoops.role=$2" | head -n1
}
