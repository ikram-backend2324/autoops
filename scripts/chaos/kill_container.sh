#!/usr/bin/env bash
# Scenario 1: the web process dies abruptly (SIGKILL, like an OOM kill or a segfault).
# Expected: Docker's restart policy brings it back within seconds; Prometheus notices the
# restart (ContainerRestarted, info) and the event reaches notify-relay / Telegram.
source "$(dirname "$0")/lib.sh"
preflight

name="1. Убит контейнер web"
banner "$name"
web=$(container_of web)
started_before=$(docker inspect -f '{{.State.StartedAt}}' "$web")
pid=$(docker inspect -f '{{.State.Pid}}' "$web")
T0=$(date +%s)
step "kill -9 главного процесса $(container_name "$web") (pid $pid на хосте Docker)"
docker run --rm --pid=host --entrypoint kill "$HELPER_IMAGE" -9 "$pid"

restarted() { [[ "$(docker inspect -f '{{.State.StartedAt}}' "$web")" != "$started_before" ]]; }
step "ждём, пока Docker обнаружит падение и перезапустит контейнер…"
detected=$(wait_until 60 restarted) || true
step "контейнер перезапущен через ${detected} с, ждём ответа /health/ = 200…"
web_healthy() { [[ "$(health_of "$web")" == healthy ]] && app_ok; }
recovered=$(wait_until 120 web_healthy) || true
step "сервис снова отвечает (через ${recovered} с). Ждём оповещение ContainerRestarted…"
if wait_until 120 relay_has "$T0" '"alertname": "ContainerRestarted"' >/dev/null; then
  alert="алерт ContainerRestarted"
else
  alert="нет"
fi

result=PASS
[[ "$detected" == - || "$recovered" == - ]] && result=FAIL
record "$name" "$detected" "$recovered" "$alert" "$result"
[[ $result == PASS ]]
