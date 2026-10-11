#!/bin/sh
# busybox crond does not pass the container environment to jobs: snapshot it for run-with-env.sh.
set -eu
export -p > /etc/autoops.env
chmod 600 /etc/autoops.env
if [ "$#" -gt 0 ]; then
  exec "$@"
fi
echo "ops: cron schedule:"; grep -v '^#' /etc/crontabs/root
exec crond -f -l 6
