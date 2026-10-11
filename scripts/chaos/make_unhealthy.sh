#!/usr/bin/env bash
# Scenario 2: web is running but broken (hung, deadlocked...). Simulated with the
# demo-only endpoint POST /chaos/unhealthy/ that makes /health/live/ return 503.
# Expected: Docker marks it unhealthy after 3 failed checks, autoheal restarts it,
# autoheal's webhook reports the restart (notify-relay -> Telegram).
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
preflight

name="2. web завис (unhealthy)"
banner "$name"
web=$(container_of web)
T0=$(date +%s)
step "включаем флаг неисправности внутри $(container_name "$web")"
docker exec "$web" python -c '
import os, urllib.request
req = urllib.request.Request("http://127.0.0.1:8000/chaos/unhealthy/", method="POST",
                             headers={"X-Chaos-Token": os.environ.get("CHAOS_TOKEN", "")})
print(urllib.request.urlopen(req, timeout=5).read().decode())'

is_unhealthy() { [[ "$(health_of "$web")" == unhealthy ]]; }
step "ждём, пока healthcheck Docker пометит контейнер unhealthy (3 проверки × 10 с)…"
detected=$(wait_until 90 is_unhealthy) || true
step "unhealthy через ${detected} с — теперь работа autoheal"
healed() { [[ "$(health_of "$web")" == healthy ]] && app_ok; }
recovered=$(wait_until 120 healed) || true
step "контейнер снова healthy через ${recovered} с"
if wait_until 30 relay_has "$T0" '"source": "autoheal"' >/dev/null; then
  alert="autoheal → relay/Telegram"
else
  alert="нет"
fi

result=PASS
[[ "$detected" == - || "$recovered" == - ]] && result=FAIL
record "$name" "$detected" "$recovered" "$alert" "$result"
[[ $result == PASS ]]
