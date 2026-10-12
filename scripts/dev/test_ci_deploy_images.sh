#!/usr/bin/env bash
# Build the image tags used by test_ci_deploy.sh: v1 and v2 (good) and "broken"
# (the process runs but its healthcheck always fails - a typical bad release).
set -euo pipefail
cd "$(dirname "$0")/../.."
docker build -q --target runtime -t autoops/sample-app:v1 sample-app >/dev/null
docker tag autoops/sample-app:v1 autoops/sample-app:v2
printf 'FROM autoops/sample-app:v1\nUSER root\nRUN echo "raise SystemExit(1)" > /app/docker/healthcheck.py\nUSER app\n' \
  | docker build -q -t autoops/sample-app:broken - >/dev/null
echo "built autoops/sample-app:{v1,v2,broken}"
