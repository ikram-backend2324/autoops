#!/usr/bin/env bash
# Interactive restore of one app from a restic snapshot into the LIVE stack.
#
#   restore.sh                        # asks for app, snapshot, confirmation
#   restore.sh --app sample --snapshot latest --yes   # non-interactive (DR scripts)
#   restore.sh --no-media             # database only
#
# Safety: a fresh pg_dump of the current database is taken first
# (BACKUP_STAGING/<app>/pre-restore-<ts>.dump) so a wrong restore can be undone.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is required}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD is required}"
STAGING=${BACKUP_STAGING:-/var/backups/autoops}
MEDIA_PATH=${BACKUP_MEDIA_PATH:-/app/media}
HOST_TAG=${RESTORE_FROM_HOST:-${SERVER_NAME:-$(hostname)}}
MAINT=${WATCHDOG_MAINTENANCE_FILE:-/var/lib/autoops/maintenance}
app="" snapshot="" assume_yes=0 with_media=1

while [[ $# -gt 0 ]]; do
  case $1 in
    --app) app=$2; shift 2 ;;
    --snapshot) snapshot=$2; shift 2 ;;
    --yes|-y) assume_yes=1; shift ;;
    --no-media) with_media=0; shift ;;
    --host) HOST_TAG=$2; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done

exec 9>"${BACKUP_LOCK_FILE:-/tmp/autoops-backup.lock}"
flock -n 9 || die "a backup is running right now, try again later"

printf '%s\n' "${C_BOLD}Snapshots in $RESTIC_REPOSITORY (host $HOST_TAG):${C_RESET}"
restic snapshots --host "$HOST_TAG" --compact

if [[ -z "$snapshot" ]]; then
  read -r -p "Snapshot ID to restore [latest]: " snapshot
  snapshot=${snapshot:-latest}
fi
if [[ -z "$app" ]]; then
  mapfile -t available < <(restic ls --host "$HOST_TAG" "$snapshot" "$STAGING" | sed -n "s#^$STAGING/\([^/]*\)/db.dump\$#\1#p")
  printf 'Apps in snapshot: %s\n' "${available[*]}"
  read -r -p "App to restore: " app
fi
[[ -n "$app" ]] || die "app is required"

db=$(find_container "$app" db)
[[ -n "$db" ]] || die "database container of '$app' is not running (start the stack first: make deploy)"

warn "This REPLACES the live database of '$app' (and media=$with_media) with snapshot '$snapshot'."
if [[ $assume_yes != 1 ]]; then
  read -r -p "Type the app name ($app) to confirm: " answer
  [[ "$answer" == "$app" ]] || die "aborted"
fi

ts=$(date +%Y%m%d-%H%M%S)
mkdir -p "$STAGING/$app"
info "safety dump of the current database -> $STAGING/$app/pre-restore-$ts.dump"
docker exec "$db" sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "$STAGING/$app/pre-restore-$ts.dump"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
restic dump --host "$HOST_TAG" "$snapshot" "$STAGING/$app/db.dump" > "$tmp/db.dump"

info "stopping web and worker of $app"
mapfile -t app_containers < <(docker ps -q --filter "label=autoops.app=$app" --filter label=autoops.role=web; \
                              docker ps -q --filter "label=autoops.app=$app" --filter label=autoops.role=worker)
touch "$MAINT" 2>/dev/null || true   # keep the watchdog from "healing" the stop
[[ ${#app_containers[@]} -gt 0 ]] && docker stop "${app_containers[@]}" >/dev/null

info "restoring database"
docker exec -i "$db" sh -c 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner --no-privileges' < "$tmp/db.dump"

if [[ $with_media == 1 ]] && restic dump --host "$HOST_TAG" "$snapshot" "$STAGING/$app/media.tar" > "$tmp/media.tar" 2>/dev/null; then
  info "restoring media"
  [[ ${#app_containers[@]} -gt 0 ]] && docker start "${app_containers[@]}" >/dev/null
  web=$(find_container "$app" web)
  docker exec -i "$web" sh -c "mkdir -p '$MEDIA_PATH' && tar -C '$MEDIA_PATH' -xf -" < "$tmp/media.tar"
fi

[[ ${#app_containers[@]} -gt 0 ]] && docker start "${app_containers[@]}" >/dev/null
rm -f "$MAINT" 2>/dev/null || true

ok "restore of '$app' from snapshot '$snapshot' finished. Undo file: $STAGING/$app/pre-restore-$ts.dump"
notify warning "♻️ Выполнено восстановление приложения $app из снапшота $snapshot (ручной запуск)." backup
