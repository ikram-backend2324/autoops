#!/bin/sh
# Run a command with the environment captured at container start (/etc/autoops.env),
# logging to the container's stdout so `docker compose logs ops` shows cron jobs.
# shellcheck disable=SC1091
[ -f /etc/autoops.env ] && . /etc/autoops.env
exec "$@" >/proc/1/fd/1 2>/proc/1/fd/2
