#!/usr/bin/env bash
# Weekly proof that backups can actually be restored:
#   latest snapshot -> temporary Postgres container -> pg_restore -> control queries
#   -> metrics for Prometheus + Telegram report -> container removed.
#
# VERIFY_TABLES  tables whose row count must be > 0 (default: core_note; set per client app)
# VERIFY_MIN_RATIO  restored rows must be >= ratio * rows recorded at backup time (default 1.0)
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is required}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD is required}"
STAGING=${BACKUP_STAGING:-/var/backups/autoops}
HOST_TAG=${SERVER_NAME:-$(hostname)}
PG_IMAGE=${VERIFY_PG_IMAGE:-postgres:16-alpine}
TABLES=${VERIFY_TABLES:-core_note}  # space or comma separated
WORK=$(mktemp -d)
started=$(date +%s)
overall=0
report=()
metrics="# HELP autoops_restore_verify_success 1 if the latest backup restored and passed checks.
# TYPE autoops_restore_verify_success gauge"
rows_metrics="# HELP autoops_restore_verify_rows Rows found in the restored copy.
# TYPE autoops_restore_verify_rows gauge"

cleanup() {
  docker rm -f "${containers[@]}" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
containers=()
trap cleanup EXIT

if [[ -n "${BACKUP_APPS:-}" ]]; then
  read -r -a apps <<< "$BACKUP_APPS"
else
  mapfile -t apps < <(restic ls latest --host "$HOST_TAG" "$STAGING" 2>/dev/null \
    | sed -n "s#^$STAGING/\([^/]*\)/db.dump\$#\1#p" | sort -u)
fi
[[ ${#apps[@]} -gt 0 ]] || die "no apps found in the latest snapshot"

snapshot=$(restic snapshots latest --host "$HOST_TAG" --json | grep -o '"short_id":"[^"]*"' | head -n1 | cut -d'"' -f4)
info "verifying snapshot $snapshot for: ${apps[*]}"

for app in "${apps[@]}"; do
  app_start=$(date +%s)
  status=1
  detail=""
  name="autoops-restore-verify-$app-$$"
  containers+=("$name")
  {
    restic dump --host "$HOST_TAG" latest "$STAGING/$app/db.dump" > "$WORK/$app.dump"
    restic dump --host "$HOST_TAG" latest "$STAGING/$app/rowcounts.txt" > "$WORK/$app.rowcounts" 2>/dev/null || : > "$WORK/$app.rowcounts"
    docker run -d --name "$name" --label autoops.role=restore-verify \
      -e POSTGRES_PASSWORD=verify -e POSTGRES_DB=verify "$PG_IMAGE" >/dev/null
    for _ in $(seq 1 60); do
      docker exec "$name" pg_isready -U postgres -d verify >/dev/null 2>&1 && break
      sleep 1
    done
    sleep 2  # the image restarts postgres once after init
    for _ in $(seq 1 30); do
      docker exec "$name" pg_isready -U postgres -d verify >/dev/null 2>&1 && break
      sleep 1
    done
    docker exec -i "$name" pg_restore -U postgres -d verify --no-owner --no-privileges --exit-on-error < "$WORK/$app.dump"
  } >"$WORK/$app.log" 2>&1 || { status=0; detail="restore failed: $(tail -n 3 "$WORK/$app.log" | tr '\n' ' ')"; }

  if [[ $status == 1 ]]; then
    for table in ${TABLES//,/ }; do
      rows=$(docker exec "$name" psql -U postgres -d verify -At -c "SELECT count(*) FROM \"$table\"" 2>/dev/null || echo "ERR")
      expected=$(awk -F'|' -v t="$table" '$1==t {print $2}' "$WORK/$app.rowcounts")
      if [[ "$rows" == "ERR" ]]; then
        status=0; detail+="$table: таблица отсутствует; "
        continue
      fi
      rows_metrics+=$'\n'"autoops_restore_verify_rows{app=\"$app\",table=\"$table\"} $rows"
      if (( rows == 0 )); then
        status=0; detail+="$table: 0 строк; "
      elif [[ -n "$expected" ]] && ! awk -v r="$rows" -v e="$expected" -v m="${VERIFY_MIN_RATIO:-1.0}" 'BEGIN{exit !(r >= e*m)}'; then
        status=0; detail+="$table: $rows строк, при бэкапе было $expected; "
      else
        detail+="$table: $rows строк ✓; "
      fi
    done
  fi

  dur=$(( $(date +%s) - app_start ))
  metrics+=$'\n'"autoops_restore_verify_success{app=\"$app\"} $status"
  metrics+=$'\n'"autoops_restore_verify_duration_seconds{app=\"$app\"} $dur"
  metrics+=$'\n'"autoops_restore_verify_last_run_timestamp_seconds{app=\"$app\"} $(date +%s)"
  if [[ $status == 1 ]]; then
    ok "[$app] restore OK in ${dur}s - $detail"
    report+=("✅ $app: восстановлено за ${dur} с — $detail")
  else
    warn "[$app] restore FAILED - $detail"
    report+=("❌ $app: $detail")
    overall=1
  fi
  docker rm -f "$name" >/dev/null 2>&1 || true
done

write_textfile autoops_restore_verify "$metrics
$rows_metrics"

total=$(( $(date +%s) - started ))
summary=$(printf '%s\n' "${report[@]}")
if [[ $overall == 0 ]]; then
  notify info "🧪 Проверка восстановления бэкапа (снапшот $snapshot) прошла успешно за ${total} с:
$summary" backup
else
  notify critical "🧪❌ Проверка восстановления бэкапа (снапшот $snapshot) ПРОВАЛЕНА:
$summary" backup
fi
exit $overall
