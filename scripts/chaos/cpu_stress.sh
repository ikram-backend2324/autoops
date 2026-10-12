#!/usr/bin/env bash
# Scenario 5: CPU saturation (runaway task, crypto-miner, traffic spike).
# Expected: HighCPU alert fires (demo rules: after 1 min; production: after 10 min),
# and resolves once the load is gone. There is nothing to "heal" automatically here -
# the point is that a human is told, with the top consumer visible in Grafana.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
preflight

name="5. Нагрузка на CPU"
banner "$name"
cpus=$(docker info --format '{{.NCPU}}')
duration=${CHAOS_CPU_SECONDS:-240}
T0=$(date +%s)
step "запускаем $cpus потоков нагрузки на ${duration} с (контейнер autoops-chaos-cpu)"
docker rm -f autoops-chaos-cpu >/dev/null 2>&1 || true
docker run -d --rm --name autoops-chaos-cpu --label autoops.role=chaos --entrypoint sh "$HELPER_IMAGE" -c \
  "for i in \$(seq $cpus); do (while :; do :; done) & done; sleep $duration; kill 0" >/dev/null
trap 'docker rm -f autoops-chaos-cpu >/dev/null 2>&1 || true' EXIT

cpu_q='100 * (1 - avg(rate(node_cpu_seconds_total{mode="idle"}[2m])))'
cpu_high() { prom_gt "$cpu_q" 85; }
detected=$(wait_until 120 cpu_high) || true
step "CPU > 85% в Prometheus через ${detected} с; ждём алерт HighCPU…"
alert="нет"
if wait_until $(( duration - 10 )) relay_has "$T0" '"alertname": "HighCPU"' >/dev/null; then
  alert="алерт HighCPU"
  step "🚨 HighCPU получен через $(( $(date +%s) - T0 )) с — снимаем нагрузку"
fi
docker rm -f autoops-chaos-cpu >/dev/null 2>&1 || true
cpu_normal() { prom_lt "$cpu_q" 50; }
recovered=$(wait_until 240 cpu_normal) || true
step "нагрузка снята, CPU в норме через ${recovered} с от начала"

result=PASS
[[ "$detected" == - || "$recovered" == - || "$alert" == нет ]] && result=FAIL
record "$name" "$detected" "$recovered" "$alert" "$result"
[[ $result == PASS ]]
