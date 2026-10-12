#!/usr/bin/env bash
# Database + media backup. Run nightly from cron on the server and before every migration
# (infra/deploy.sh calls it).
#
#   0 3 * * * /opt/courses/infra/backup.sh >> /var/log/courses-backup.log 2>&1
#
# What it does:
#   1. pg_dump (custom format) into $BACKUP_DIR, written to a temp name and renamed when complete
#   2. verifies the dump is readable (pg_restore --list)
#   3. copies the dump to a Russian S3 bucket via rclone and mirrors the media directory there:
#      <remote>/media/current is an exact copy of the media directory; a file removed or replaced on the
#      server is moved to <remote>/media/deleted/<stamp>/ by the same sync (rclone --backup-dir)
#   4. removes local dumps, remote dumps and <remote>/media/deleted/<stamp> folders older than
#      $BACKUP_RETENTION_DAYS, so files deleted by /forget leave the backups after that many days
#   5. pings $BACKUP_HEARTBEAT_URL (Uptime Kuma push monitor) only on full success,
#      so a silent failure turns the monitor red
# Any failing step aborts the script with a non-zero exit code.
#
# Media keys are write-once (docs/02-data-model.md, file_key): a changed file gets a new key, so the media of
# any dump inside the retention window = media/current plus media/deleted/<stamp> for stamps after the dump
# (procedure: docs/09-infra-and-deploy.md section 8).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ENV_FILE="infra/.env"
COMPOSE=(docker compose -f infra/docker-compose.yml --env-file "$ENV_FILE")

log() { printf '[backup %s] %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

env_get() {
  grep -E "^$1=" "$ENV_FILE" | tail -n1 | tr -d '\r' | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' || true
}

[ -f "$ENV_FILE" ] || die "$ENV_FILE not found"
POSTGRES_USER="$(env_get POSTGRES_USER)"
POSTGRES_DB="$(env_get POSTGRES_DB)"
BACKUP_DIR="$(env_get BACKUP_DIR)"; BACKUP_DIR="${BACKUP_DIR:-/srv/courses/backups}"
RETENTION="$(env_get BACKUP_RETENTION_DAYS)"; RETENTION="${RETENTION:-14}"
REMOTE="$(env_get BACKUP_RCLONE_REMOTE)"
HEARTBEAT="$(env_get BACKUP_HEARTBEAT_URL)"
MEDIA_DIR="$(env_get MEDIA_HOST_DIR)"; MEDIA_DIR="${MEDIA_DIR:-/srv/courses/media}"
[ -n "$POSTGRES_USER" ] && [ -n "$POSTGRES_DB" ] || die "POSTGRES_USER / POSTGRES_DB missing in $ENV_FILE"

mkdir -p "$BACKUP_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
NAME="${POSTGRES_DB}-${STAMP}.dump"
TMP="$BACKUP_DIR/.${NAME}.partial"
FINAL="$BACKUP_DIR/$NAME"

log "dumping ${POSTGRES_DB}"
"${COMPOSE[@]}" exec -T postgres pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB" > "$TMP"
[ -s "$TMP" ] || { rm -f "$TMP"; die "dump is empty"; }

log "verifying dump"
"${COMPOSE[@]}" exec -T postgres pg_restore --list < "$TMP" > /dev/null || { rm -f "$TMP"; die "dump is not readable by pg_restore"; }
mv "$TMP" "$FINAL"
log "local dump: $FINAL ($(du -h "$FINAL" | cut -f1))"

if [ -n "$REMOTE" ]; then
  command -v rclone >/dev/null || die "rclone is not installed but BACKUP_RCLONE_REMOTE is set"
  log "uploading dump to ${REMOTE}/db/"
  rclone copyto "$FINAL" "${REMOTE}/db/${NAME}"
  if [ -d "$MEDIA_DIR" ]; then
    # An empty directory over a non-empty copy means a lost mount or disk, not deleted content: stop
    # before the sync moves every remote file into media/deleted.
    if [ -z "$(ls -A "$MEDIA_DIR")" ] && [ -n "$(rclone lsf --max-depth 1 "${REMOTE}/media/current" 2>/dev/null | head -n1)" ]; then
      die "$MEDIA_DIR is empty but ${REMOTE}/media/current is not; check the mount, then restore media (docs/09 section 8)"
    fi
    log "syncing media to ${REMOTE}/media/current (removed files go to ${REMOTE}/media/deleted/${STAMP})"
    rclone sync "$MEDIA_DIR" "${REMOTE}/media/current" --backup-dir "${REMOTE}/media/deleted/${STAMP}"
  fi
  log "pruning remote dumps older than ${RETENTION} days"
  rclone delete "${REMOTE}/db" --min-age "${RETENTION}d"
  # Moved files keep their original modification time, so age is taken from the folder name, not --min-age.
  CUTOFF="$(date -d "-${RETENTION} days" +%Y%m%d-%H%M%S)"
  log "pruning ${REMOTE}/media/deleted folders older than ${CUTOFF}"
  { rclone lsf --dirs-only "${REMOTE}/media/deleted" 2>/dev/null || true; } | sed 's#/$##' | while read -r dir; do
    if [[ "$dir" =~ ^[0-9]{8}-[0-9]{6}$ ]] && [[ "$dir" < "$CUTOFF" ]]; then
      rclone purge "${REMOTE}/media/deleted/${dir}"
    fi
  done
else
  log "WARNING: BACKUP_RCLONE_REMOTE is empty, the backup exists only on this server"
fi

log "pruning local dumps older than ${RETENTION} days"
find "$BACKUP_DIR" -maxdepth 1 -name "${POSTGRES_DB}-*.dump" -type f -mtime "+${RETENTION}" -delete

if [ -n "$HEARTBEAT" ]; then
  curl -fsS --max-time 10 "$HEARTBEAT" > /dev/null || log "WARNING: heartbeat ping failed"
fi
log "done"
