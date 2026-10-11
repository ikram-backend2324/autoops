#!/bin/sh
# Render Alertmanager config at start-up:
#   TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID set -> alertmanager.yml (Telegram + relay)
#   otherwise                                -> alertmanager.local.yml (relay log only)
set -eu

src=/etc/alertmanager
out=/tmp/am
mkdir -p "$out/templates"

for tmpl in "$src"/templates/*.tmpl; do
  sed "s|__GRAFANA_URL__|${GRAFANA_URL:-http://localhost:3000}|g" "$tmpl" > "$out/templates/$(basename "$tmpl")"
done

if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
  umask 077
  printf '%s' "$TELEGRAM_BOT_TOKEN" > "$out/bot_token"
  sed "s|__TELEGRAM_CHAT_ID__|${TELEGRAM_CHAT_ID}|g" "$src/alertmanager.yml" > "$out/alertmanager.yml"
  echo "autoops: Telegram notifications enabled (chat ${TELEGRAM_CHAT_ID})"
else
  cp "$src/alertmanager.local.yml" "$out/alertmanager.yml"
  echo "autoops: TELEGRAM_BOT_TOKEN not set -> alerts are only logged by notify-relay"
fi

exec /bin/alertmanager \
  --config.file="$out/alertmanager.yml" \
  --storage.path=/alertmanager \
  --web.external-url="${ALERTMANAGER_EXTERNAL_URL:-http://localhost:9093}"
