#!/bin/sh
# Single entrypoint for every role the image can play.
#   web     - gunicorn HTTP server (default)
#   worker  - celery worker with embedded beat scheduler
#   migrate - one-shot: apply migrations and exit
set -eu

# Multiprocess Prometheus metrics need a clean directory on every start.
rm -rf "${PROMETHEUS_MULTIPROC_DIR:-/tmp/prometheus}"
mkdir -p "${PROMETHEUS_MULTIPROC_DIR:-/tmp/prometheus}"

role="${1:-web}"
case "$role" in
  web)
    exec gunicorn config.wsgi:application \
      --config /app/docker/gunicorn.conf.py
    ;;
  worker)
    exec celery -A config worker -B \
      --loglevel=INFO \
      --concurrency="${CELERY_CONCURRENCY:-2}" \
      --schedule=/tmp/celerybeat-schedule
    ;;
  migrate)
    python manage.py migrate --noinput
    exec python manage.py seed_demo
    ;;
  *)
    exec "$@"
    ;;
esac
