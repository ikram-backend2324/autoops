#!/usr/bin/env bash
# Screenshots of every Grafana dashboard + an example Telegram alert rendered from the real
# Alertmanager template. Needs the local stack (make local-up), ideally after `make chaos`.
set -euo pipefail
export MSYS_NO_PATHCONV=1
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
host_root=$ROOT
command -v cygpath >/dev/null && host_root=$(cygpath -w "$ROOT")
pass=$(grep -E '^GRAFANA_ADMIN_PASSWORD=' local/.env | cut -d= -f2)

render() {  # render JSON_PAYLOAD -> Telegram HTML text produced by templates/telegram.tmpl
  docker run --rm -i -e TZ=Asia/Tashkent -v "$host_root/stacks/monitoring/alertmanager/templates:/t:ro" \
    --entrypoint /bin/sh prom/alertmanager:v0.28.1 -c '
      sed "s|__GRAFANA_URL__|https://grafana.shop.example.uz|g" /t/telegram.tmpl > /tmp/t.tmpl
      amtool template render --template.glob=/tmp/t.tmpl \
        --template.text="{{ template \"telegram.autoops.message\" . }}" --template.data=/dev/stdin'
}
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
firing=$(render <<JSON
{"status":"firing","alerts":[{"status":"firing","labels":{"alertname":"PostgresDown","severity":"critical","server":"client-shop-1","app":"shop"},
"annotations":{"summary":"PostgreSQL приложения shop недоступен","description":"postgres-exporter не может подключиться к базе больше 30 секунд. Сайт, скорее всего, отдаёт ошибки.",
"runbook":"docker ps -a --filter label=autoops.app=shop; Watchdog попробует поднять стек сам. docs/PRODUCTION.md#postgresdown","dashboard":"d/autoops-postgres"},
"startsAt":"$now","endsAt":"0001-01-01T00:00:00Z"}]}
JSON
)
resolved=$(render <<JSON
{"status":"resolved","alerts":[{"status":"resolved","labels":{"alertname":"PostgresDown","severity":"critical","server":"client-shop-1","app":"shop"},
"annotations":{"summary":"PostgreSQL приложения shop недоступен"},"startsAt":"$now","endsAt":"$now"}]}
JSON
)
watchdog='🟠 🔧 Автовосстановление: стек shop запущен не полностью (остановлены: shop-postgres-1).
Выполнено: docker compose up -d. Результат: ✅ OK
🖥 Сервер: <code>client-shop-1</code>'
docker run --rm --network container:autoops-grafana-1 -v "$host_root:/work" -w /work \
  -e GRAFANA_PASSWORD="$pass" -e TELEGRAM_MSG_1="$firing" -e TELEGRAM_MSG_2="$watchdog" -e TELEGRAM_MSG_3="$resolved" -e RANGE="${RANGE:-now-1h}" \
  mcr.microsoft.com/playwright/python:v1.55.0-noble \
  sh -c 'pip install -q playwright==1.55.0 >/dev/null 2>&1; python3 scripts/dev/screenshots.py'
