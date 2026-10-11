#!/usr/bin/env bash
# wait_healthy.sh PROJECT TIMEOUT - wait until every running container of a compose
# project reports healthy (one-shot containers that exited 0 are fine).
set -euo pipefail
export MSYS_NO_PATHCONV=1
project=${1:-autoops}
timeout=${2:-240}
deadline=$(( $(date +%s) + timeout ))

while :; do
  not_ready=$(docker ps -a --filter "label=com.docker.compose.project=$project" \
    --format '{{.Names}} {{.Status}}' | grep -vE '\(healthy\)|Exited \(0\)' || true)
  if [[ -z "$not_ready" ]]; then
    echo "✔ all containers of '$project' are healthy"
    exit 0
  fi
  if (( $(date +%s) > deadline )); then
    echo "✖ not healthy after ${timeout}s:" >&2
    echo "$not_ready" >&2
    exit 1
  fi
  sleep 5
done
