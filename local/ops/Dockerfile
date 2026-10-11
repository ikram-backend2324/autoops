# "ops" container for the laptop demo: restic + docker CLI + cron.
# On a server the same scripts run directly on the host from systemd timers.
FROM restic/restic:0.18.0 AS restic

FROM docker:27-cli
RUN apk add --no-cache bash curl coreutils util-linux procps tzdata python3 \
    && mkdir -p /var/backups/autoops
COPY --from=restic /usr/bin/restic /usr/bin/restic
COPY scripts /opt/autoops/scripts
COPY local/ops/crontab /etc/crontabs/root
COPY local/ops/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
