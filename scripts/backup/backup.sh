#!/usr/bin/env bash
# Daily backup: pg_dump (custom format) + media of every app -> restic -> S3.
#
# Environment (on a server: /etc/autoops/backup.env, rendered by Ansible from the vault):
#   RESTIC_REPOSITORY      s3:https://s3.eu-central-003.backblazeb2.com/my-bucket/autoops
#   RESTIC_PASSWORD        encryption password (keep a copy OUTSIDE the server!)
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY   S3 key limited to this bucket
#   BACKUP_APPS            "sample shop" - apps to back up (default: every app with a db container)
#   BACKUP_STAGING         /var/backups/autoops (also the path inside restic snapshots)
#   BACKUP_MEDIA_PATH      /app/media (inside the web container)
#   VERIFY_TABLES          "core_note" - key tables whose row counts are recorded for verify_restore.sh
#                          (per app: VERIFY_TABLES_<APP>, e.g. VERIFY_TABLES_SHOP="orders_order")
#   KEEP_DAILY/KEEP_WEEKLY/KEEP_MONTHLY   retention, default 7/4/6
#   TEXTFILE_DIR, NOTIFY_URL, SERVER_NAME
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is required}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD is required}"
STAGING=${BACKUP_STAGING:-/var/backups/autoops}
MEDIA_PATH=${BACKUP_MEDIA_PATH:-/app/media}
HOST_TAG=${SERVER_NAME:-$(hostname)}
LOCK_FILE=${BACKUP_LOCK_FILE:-/tmp/autoops-backup.lock}
started=$(date +%s)

exec 9>"$LOCK_FILE"
flock -n 9 || die "another backup/restore is running ($LOCK_FILE)"

publish_metrics() {
  local success=$1 size=${2:-0} snapshots=${3:-0}
  local now; now=$(date +%s)
  local last_ok_line=""
  if [[ "$success" == 1 ]]; then
    last_ok_line="autoops_backup_last_success_timestamp_seconds $now"
  elif [[ -f "${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}/autoops_backup.prom" ]]; then
    last_ok_line=$(grep '^autoops_backup_last_success_timestamp_seconds' \
      "${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}/autoops_backup.prom" || true)
  fi
  write_textfile autoops_backup "# HELP autoops_backup_last_run_success 1 if the last backup run succeeded.
# TYPE autoops_backup_last_run_success gauge
autoops_backup_last_run_success $success
# HELP autoops_backup_last_run_timestamp_seconds Last backup attempt.
# TYPE autoops_backup_last_run_timestamp_seconds gauge
autoops_backup_last_run_timestamp_seconds $now
# HELP autoops_backup_last_success_timestamp_seconds Last successful backup.
# TYPE autoops_backup_last_success_timestamp_seconds gauge
${last_ok_line}
# HELP autoops_backup_duration_seconds Duration of the last backup run.
# TYPE autoops_backup_duration_seconds gauge
autoops_backup_duration_seconds $(( now - started ))
# HELP autoops_backup_size_bytes Size of the data handed to restic in the last run.
# TYPE autoops_backup_size_bytes gauge
autoops_backup_size_bytes $size
# HELP autoops_backup_snapshots_total Snapshots in the restic repository.
# TYPE autoops_backup_snapshots_total gauge
autoops_backup_snapshots_total $snapshots"
}

on_error() {
  local line=$1
  publish_metrics 0
  notify critical "❌ Бэкап завершился ошибкой (строка $line скрипта backup.sh). Проверьте: journalctl -u autoops-backup -n 100" backup
}
trap 'on_error $LINENO' ERR

# Apps: explicit list or every running database container labelled by AutoOps.
if [[ -n "${BACKUP_APPS:-}" ]]; then
  read -r -a apps <<< "$BACKUP_APPS"
else
  mapfile -t apps < <(docker ps --filter label=autoops.role=db --format '{{.Label "autoops.app"}}' | sort -u)
fi
[[ ${#apps[@]} -gt 0 ]] || die "no apps to back up (no running containers with label autoops.role=db)"

mkdir -p "$STAGING"
chmod 700 "$STAGING"

for app in "${apps[@]}"; do
  log "[$app] dumping database"
  db=$(find_container "$app" db)
  [[ -n "$db" ]] || die "[$app] database container is not running"
  mkdir -p "$STAGING/$app"
  # Credentials come from the container's own environment - nothing to configure here.
  # Exact row counts of the key tables, taken BEFORE the dump so that the dump always
  # contains at least these rows; verify_restore.sh compares against them.
  : > "$STAGING/$app/rowcounts.txt"
  for table in $(tables_for "$app"); do
    sql="SELECT count(*) FROM \"$table\""
    if count=$(docker exec "$db" sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -c "$1"' _ "$sql" 2>/dev/null); then
      printf '%s|%s\n' "$table" "$count" >> "$STAGING/$app/rowcounts.txt"
    fi
  done
  # Credentials come from the container's own environment - nothing to configure here.
  docker exec "$db" sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc --no-owner' > "$STAGING/$app/db.dump.tmp"
  mv "$STAGING/$app/db.dump.tmp" "$STAGING/$app/db.dump"

  web=$(find_container "$app" web)
  if [[ -n "$web" ]]; then
    log "[$app] archiving media ($MEDIA_PATH)"
    docker exec "$web" sh -c "[ -d '$MEDIA_PATH' ] && tar -C '$MEDIA_PATH' -cf - . || tar -cf - -T /dev/null" > "$STAGING/$app/media.tar"
  else
    warn "[$app] web container not running, media skipped"
  fi
done

size=$(du -sb "$STAGING" | cut -f1)

# `restic init` fails fast on an existing repository, whereas probing with
# `restic cat config` retries for minutes when the bucket does not exist yet.
if init_out=$(restic init 2>&1); then
  log "initialised new restic repository $RESTIC_REPOSITORY"
elif ! grep -qi "already" <<< "$init_out"; then
  printf '%s
' "$init_out" >&2
  false
fi

log "uploading to $RESTIC_REPOSITORY"
restic backup "$STAGING" --host "$HOST_TAG" --tag autoops --tag daily
restic forget --host "$HOST_TAG" --tag autoops \
  --keep-daily "${KEEP_DAILY:-7}" --keep-weekly "${KEEP_WEEKLY:-4}" --keep-monthly "${KEEP_MONTHLY:-6}" --prune

snapshots=$(restic snapshots --host "$HOST_TAG" --json | grep -o '"short_id"' | wc -l)
publish_metrics 1 "$size" "$snapshots"

duration=$(( $(date +%s) - started ))
human_size=$(numfmt --to=iec "$size" 2>/dev/null || echo "${size} B")
ok "backup finished: apps=${apps[*]} size=$human_size duration=${duration}s snapshots=$snapshots"
notify info "💾 Бэкап выполнен: ${apps[*]} · ${human_size} · ${duration} с · снапшотов: ${snapshots}" backup
