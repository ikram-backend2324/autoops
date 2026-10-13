#!/bin/sh
# Single entrypoint for every role the image can play.
#   web     - gunicorn HTTP server (default)
#   worker  - celery worker with embedded beat scheduler
#   migrate - one-shot: apply migrations, demo data and admin account, then exit
#   serve   - migrate + web in one container, for platforms without a separate
#             release step (Render free tier, single-container hosting)
set -eu

# Multiprocess Prometheus metrics need a clean directory on every start.
rm -rf "${PROMETHEUS_MULTIPROC_DIR:-/tmp/prometheus}"
mkdir -p "${PROMETHEUS_MULTIPROC_DIR:-/tmp/prometheus}"

prepare_database() {
  python manage.py migrate --noinput
  python manage.py seed_demo
  python manage.py ensure_superuser
}

start_web() {
  exec gunicorn config.wsgi:application --config /app/docker/gunicorn.conf.py
}

role="${1:-web}"
case "$role" in
  web)
    start_web
    ;;
  worker)
    exec celery -A config worker -B \
      --loglevel=INFO \
      --concurrency="${CELERY_CONCURRENCY:-2}" \
      --schedule=/tmp/celerybeat-schedule
    ;;
  migrate)
    prepare_database
    ;;
  serve)
    prepare_database
    start_web
    ;;
  *)
    exec "$@"
    ;;
esac
