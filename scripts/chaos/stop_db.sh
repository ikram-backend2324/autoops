#!/usr/bin/env bash
# Scenario 3: PostgreSQL is stopped (someone ran `docker stop`, or the DB crashed hard).
# A manual stop is NOT covered by restart policies - this is the watchdog's job.
# Expected: /health/ -> 503, PostgresDown (critical) alert, watchdog restarts the stack
# after its grace period, alert resolves.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
preflight

name="3. Остановлен PostgreSQL"
banner "$name"
db=$(container_of db)
T0=$(date +%s)
step "docker stop $(container_name "$db")"
docker stop "$db" >/dev/null

app_failing() { ! app_ok; }
detected=$(wait_until 30 app_failing) || true
step "приложение отвечает ошибкой через ${detected} с; ждём алерт и watchdog (grace-период)…"
alert_seen=0
db_back() { [[ "$(health_of "$db")" == healthy ]] && app_ok; }
deadline=$(( $(date +%s) + 240 ))
recovered="-"
while (( $(date +%s) <= deadline )); do
  if (( alert_seen == 0 )) && relay_has "$T0" '"alertname": "PostgresDown"'; then
    alert_seen=1
    step "🚨 алерт PostgresDown получен через $(( $(date +%s) - T0 )) с"
  fi
  if [[ "$recovered" == - ]] && db_back; then
    recovered=$(( $(date +%s) - T0 ))
    step "✅ база и приложение снова работают через ${recovered} с"
  fi
  [[ "$recovered" != - && $alert_seen == 1 ]] && break
  sleep 3
done

alerts=()
(( alert_seen )) && alerts+=("PostgresDown")
relay_has "$T0" '"source": "watchdog"' && alerts+=("watchdog 🔧")
if (( ${#alerts[@]} )); then
  alert=$(printf '%s + ' "${alerts[@]}"); alert=${alert% + }
else
  alert="нет"
fi

result=PASS
[[ "$detected" == - || "$recovered" == - ]] && result=FAIL
record "$name" "$detected" "$recovered" "$alert" "$result"
[[ $result == PASS ]]
