#!/usr/bin/env bash
# Restore a dump made by infra/backup.sh.
#
#   infra/restore.sh <dump-file>                  restore into a scratch database "<db>_restore" (the monthly drill)
#   infra/restore.sh <dump-file> --drop           same, then drop the scratch database
#   infra/restore.sh <dump-file> --into-live      restore into "<db>_restore", show it next to the live numbers,
#                                                 ask for the database name, then swap the databases by rename
#
# The live database is never dropped. --into-live keeps it as "<db>_before_<timestamp>" and switches only after
# the restored copy loaded completely and you confirmed its row counts. After the switch only `web` starts
# (it runs `migrate` first, so a dump older than the code is brought up to date). The worker stays stopped:
# it would resend funnel steps and broadcasts that already went out after the dump. Start it by hand after
# the checks in docs/09-infra-and-deploy.md section 8, "Восстановление после аварии".
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ENV_FILE="infra/.env"
COMPOSE=(docker compose -f infra/docker-compose.yml --env-file "$ENV_FILE")

log() { printf '[restore %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

env_get() {
  grep -E "^$1=" "$ENV_FILE" | tail -n1 | tr -d '\r' | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' || true
}

DUMP="${1:-}"
MODE="${2:-}"
[ -n "$DUMP" ] && [ -f "$DUMP" ] || die "usage: infra/restore.sh <dump-file> [--drop|--into-live]"
case "$MODE" in ""|--drop|--into-live) ;; *) die "unknown option: $MODE" ;; esac
[ -f "$ENV_FILE" ] || die "$ENV_FILE not found"

PGUSER="$(env_get POSTGRES_USER)"
LIVE_DB="$(env_get POSTGRES_DB)"
[ -n "$PGUSER" ] && [ -n "$LIVE_DB" ] || die "POSTGRES_USER / POSTGRES_DB missing in $ENV_FILE"
SCRATCH_DB="${LIVE_DB}_restore"

psql_admin() { "${COMPOSE[@]}" exec -T postgres psql -U "$PGUSER" -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_db() { local db="$1"; shift; "${COMPOSE[@]}" exec -T postgres psql -U "$PGUSER" -d "$db" -v ON_ERROR_STOP=1 "$@"; }

row_counts() {
  psql_db "$1" -At -F ' | ' -c "
    select 'users', count(*) from users
    union all select 'courses', count(*) from courses
    union all select 'lessons', count(*) from lessons
    union all select 'orders', count(*) from orders
    union all select 'orders succeeded, last paid_at', count(*) || ' / ' || coalesce(max(paid_at)::text, '-') from orders where status = 'succeeded'
    union all select 'entitlements', count(*) from entitlements
    union all select 'progress', count(*) from progress"
}

resend_risk() {
  # What the worker would send again if started on this copy (docs/09 section 8).
  psql_db "$1" -At -F ' | ' -c "
    select 'broadcasts in sending', count(*) from broadcasts where status = 'sending'
    union all select 'broadcast recipients pending', count(*) from broadcast_recipients where status = 'pending'
    union all select 'funnel steps due now', count(*) from funnel_enrollments where status = 'active' and next_run_at <= now()
    union all select 'orders pending', count(*) from orders where status = 'pending'" \
    || log "WARNING: resend check failed (tables of a later stage may not exist yet)"
}

"${COMPOSE[@]}" up -d --wait postgres

log "preparing scratch database $SCRATCH_DB"
psql_admin -c "drop database if exists \"$SCRATCH_DB\" with (force)"
psql_admin -c "create database \"$SCRATCH_DB\""
log "restoring $DUMP into $SCRATCH_DB"
"${COMPOSE[@]}" exec -T postgres pg_restore -U "$PGUSER" -d "$SCRATCH_DB" --no-owner --no-privileges --exit-on-error < "$DUMP" \
  || die "pg_restore failed; the live database was not touched, $SCRATCH_DB is incomplete"

log "row counts in $SCRATCH_DB (restored)"
row_counts "$SCRATCH_DB"

case "$MODE" in
  "")
    log "scratch database $SCRATCH_DB left in place; drop it with:"
    log "  ${COMPOSE[*]} exec -T postgres psql -U $PGUSER -d postgres -c 'drop database \"$SCRATCH_DB\" with (force)'"
    exit 0
    ;;
  --drop)
    psql_admin -c "drop database \"$SCRATCH_DB\" with (force)"
    log "scratch database dropped"
    exit 0
    ;;
esac

# ---- --into-live: swap databases by rename, keep the old one ----
log "row counts in $LIVE_DB (live, may be empty or unreadable after a crash)"
row_counts "$LIVE_DB" || log "live database is not readable"
log "what the worker would send again from the restored copy"
resend_risk "$SCRATCH_DB"

STAMP="$(date +%Y%m%d_%H%M%S)"
OLD_DB="${LIVE_DB}_before_${STAMP}"
printf 'Switch the app to the restored copy? "%s" becomes "%s" and is kept. Type "%s" to continue: ' "$LIVE_DB" "$OLD_DB" "$LIVE_DB"
read -r answer
[ "$answer" = "$LIVE_DB" ] || die "confirmation does not match; nothing changed, $SCRATCH_DB is left in place"

log "stopping web and worker"
"${COMPOSE[@]}" stop web worker
psql_admin -c "select pg_terminate_backend(pid) from pg_stat_activity where datname in ('$LIVE_DB', '$SCRATCH_DB') and pid <> pg_backend_pid()" > /dev/null
# Both renames in one statement string: psql sends it as one implicit transaction, so either both happen or none.
psql_admin -c "alter database \"$LIVE_DB\" rename to \"$OLD_DB\"; alter database \"$SCRATCH_DB\" rename to \"$LIVE_DB\";"
log "databases swapped: live data kept as $OLD_DB"

log "starting web (migrate runs first); the worker stays stopped"
"${COMPOSE[@]}" up -d web
log "next steps, docs/09 section 8 \"Восстановление после аварии\":"
log "  1. node scripts/smoke.mjs https://app.<domain>"
log "  2. payments made after the dump: compare the YooKassa dashboard with orders, grant missing access with /grant"
log "  3. review the resend list above, then start the worker: ${COMPOSE[*]} up -d worker"
log "  4. when everything is confirmed: drop database \"$OLD_DB\""
