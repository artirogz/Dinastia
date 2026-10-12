#!/usr/bin/env bash
# Deploy a release on the server, or roll back to the previous good one.
#
#   infra/deploy.sh                    release origin/main: build -> backup -> migrate -> up -> smoke
#   infra/deploy.sh --sha <commit>     release an explicit commit (any reachable sha, e.g. an older good one)
#   infra/deploy.sh --no-backup        skip the pre-migration backup (first deploy only); combines with --sha
#   infra/deploy.sh rollback           start the release that was good before the current one
#
# Run on the server from any directory. Requires: git, docker compose, infra/.env.
#
# Release bookkeeping (infra/.release/, not in git):
#   current     the last release that passed smoke; this is what runs when nothing is in progress
#   previous    the good release before current; the target of `rollback`
#   candidate   the release being installed right now; removed when it passes smoke
#   failed      the last candidate that did not pass, with the reason
# A candidate that fails health or smoke is replaced automatically by `current`, so a failed deploy
# never leaves an unchecked version running and never moves the rollback target.
#
# The image is built from a temporary git worktree at the target commit; compose file, Caddyfile and
# these scripts always come from the main checkout in /opt/courses.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ENV_FILE="infra/.env"
RELEASE_DIR="infra/.release"
COMPOSE=(docker compose -f infra/docker-compose.yml --env-file "$ENV_FILE")
IMAGE_REPO="courses-app"
KEEP_IMAGES=5

log() { printf '[deploy %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

env_get() {
  # Read KEY from infra/.env without sourcing the file (values may contain shell characters).
  grep -E "^$1=" "$ENV_FILE" | tail -n1 | tr -d '\r' | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' || true
}

[ -f "$ENV_FILE" ] || die "$ENV_FILE not found (copy infra/.env.example and fill it in)"
DOMAIN="$(env_get DOMAIN)"
[ -n "$DOMAIN" ] || die "DOMAIN is empty in $ENV_FILE"
BASE_URL="https://app.${DOMAIN}"
mkdir -p "$RELEASE_DIR"

release_get() { cat "$RELEASE_DIR/$1" 2>/dev/null || true; }
release_set() { printf '%s\n' "$2" > "$RELEASE_DIR/$1"; }

wait_healthy() {
  # Wait until the container reports healthy (max ~2 minutes).
  local service="$1" tries=24 cid status
  while [ "$tries" -gt 0 ]; do
    cid="$("${COMPOSE[@]}" ps -q "$service")"
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || echo unknown)"
    [ "$status" = "healthy" ] && return 0
    tries=$((tries - 1))
    sleep 5
  done
  return 1
}

run_smoke() {
  # Smoke runs in a throwaway Node container so the server needs no Node installation.
  # Its output is kept as the release artifact (infra/.last-smoke.txt): the verdict of a deploy
  # is read from this file, not from the exit code of the wrapper.
  local artifact="$ROOT/infra/.last-smoke.txt"
  {
    echo "# smoke $(date -u +%Y-%m-%dT%H:%M:%SZ) base=${BASE_URL} release=${APP_IMAGE:-unknown}"
    docker run --rm -v "$ROOT/scripts:/scripts:ro" node:22-alpine node /scripts/smoke.mjs "$BASE_URL"
  } 2>&1 | tee "$artifact"
  # tee hides the exit code of the smoke run; read it from PIPESTATUS.
  return "${PIPESTATUS[0]}"
}

start_release() {
  # Start an already built image as web + worker and check it. Returns non-zero on health or smoke failure.
  export APP_IMAGE="$1"
  docker tag "$APP_IMAGE" "${IMAGE_REPO}:current"   # alias for backup.sh, restore.sh, `compose logs`
  "${COMPOSE[@]}" up -d --remove-orphans
  wait_healthy web || { log "web did not become healthy: ${COMPOSE[*]} logs --tail=200 web" >&2; return 1; }
  wait_healthy worker || { log "worker did not become healthy: ${COMPOSE[*]} logs --tail=200 worker" >&2; return 1; }
  log "smoke check of ${APP_IMAGE} against ${BASE_URL}"
  run_smoke || { log "smoke failed for ${APP_IMAGE}, see infra/.last-smoke.txt" >&2; return 1; }
}

prune_images() {
  # Keep the newest $KEEP_IMAGES images of our repo plus current and previous, remove the rest
  # (docker refuses to remove an image a container uses). Then drop build cache older than a week:
  # without it every release leaves ~1 GB of layers on the disk.
  local keep_cur keep_prev
  keep_cur="$(release_get current)"
  keep_prev="$(release_get previous)"
  { docker images "$IMAGE_REPO" --format '{{.Tag}}' | grep -vx current || true; } | tail -n +$((KEEP_IMAGES + 1)) | while read -r tag; do
    [ "${IMAGE_REPO}:${tag}" = "$keep_cur" ] && continue
    [ "${IMAGE_REPO}:${tag}" = "$keep_prev" ] && continue
    docker rmi "${IMAGE_REPO}:${tag}" >/dev/null 2>&1 || true
  done
  docker builder prune -f --filter until=168h >/dev/null || log "WARNING: docker builder prune failed"
}

build_image() {
  # Build $1 (commit) into image $2 from a temporary worktree, so the main checkout stays on main.
  local commit="$1" image="$2" src
  if docker image inspect "$image" >/dev/null 2>&1; then
    log "image $image already exists, not rebuilding"
    return 0
  fi
  src="$(mktemp -u /tmp/courses-build-XXXXXX)"
  git worktree add --detach "$src" "$commit" >/dev/null
  log "building $image from $commit"
  if ! docker build -t "$image" -f "$src/infra/Dockerfile" "$src"; then
    git worktree remove --force "$src"
    die "image build failed for $commit"
  fi
  git worktree remove --force "$src"
}

rollback() {
  local prev cur
  prev="$(release_get previous)"
  cur="$(release_get current)"
  [ -n "$prev" ] || die "no previous good release recorded; start a known good commit with: infra/deploy.sh --sha <sha>"
  docker image inspect "$prev" >/dev/null 2>&1 || die "image $prev is no longer on this server; rebuild it with: infra/deploy.sh --sha ${prev#"${IMAGE_REPO}:"}"
  log "rolling back ${cur:-none} -> $prev"
  log "note: migrations are not reverted; they must stay compatible with one release back"
  start_release "$prev" || die "rollback target $prev failed health or smoke; inspect logs, then infra/deploy.sh --sha <good sha>"
  release_set current "$prev"
  rm -f "$RELEASE_DIR/previous"     # one step back only; the release before it is reached with --sha
  [ -n "$cur" ] && release_set failed "$cur rolled back by hand $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log "rollback done, running $prev"
}

deploy() {
  local do_backup="$1" target_sha="$2" commit
  log "updating source"
  git fetch --prune origin
  git worktree prune                # leftovers of an interrupted build
  git checkout main
  git pull --ff-only origin main
  if [ -n "$target_sha" ]; then
    commit="$(git rev-parse --verify "${target_sha}^{commit}")" || die "unknown commit: $target_sha"
  else
    commit="$(git rev-parse HEAD)"
  fi
  local image="${IMAGE_REPO}:$(git rev-parse --short=12 "$commit")"
  local good
  good="$(release_get current)"
  [ "$image" != "$good" ] || log "note: $image is already the current release, re-running checks"
  log "release $image (current good: ${good:-none})"

  build_image "$commit" "$image"

  log "starting postgres"
  "${COMPOSE[@]}" up -d --wait postgres

  if [ "$do_backup" -eq 1 ]; then
    log "pre-migration backup"
    infra/backup.sh
  fi

  release_set candidate "$image"
  log "running migrations of $image"
  APP_IMAGE="$image" "${COMPOSE[@]}" run --rm migrate || { release_set failed "$image migrate $(date -u +%Y-%m-%dT%H:%M:%SZ)"; rm -f "$RELEASE_DIR/candidate"; die "migrations of $image failed; ${good:-nothing} keeps running"; }

  log "starting $image"
  if ! start_release "$image"; then
    release_set failed "$image health-or-smoke $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    rm -f "$RELEASE_DIR/candidate"
    if [ -n "$good" ] && [ "$good" != "$image" ] && docker image inspect "$good" >/dev/null 2>&1; then
      log "RELEASE FAILED, restoring the last good release $good" >&2
      start_release "$good" || die "the last good release $good also failed; inspect logs now"
      die "release $image failed and was replaced by $good (see infra/.release/failed)"
    fi
    die "release $image failed and there is no earlier good release on this server; it is still running, fix forward"
  fi

  if [ -n "$good" ] && [ "$good" != "$image" ]; then
    release_set previous "$good"
  fi
  release_set current "$image"
  rm -f "$RELEASE_DIR/candidate"
  prune_images
  log "deployed $image"
}

do_backup=1
target_sha=""
case "${1:-}" in
  rollback)
    [ "$#" -eq 1 ] || die "usage: infra/deploy.sh rollback"
    rollback
    exit 0
    ;;
esac
while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-backup) do_backup=0; shift ;;
    --sha) [ -n "${2:-}" ] || die "--sha needs a commit"; target_sha="$2"; shift 2 ;;
    *) die "usage: infra/deploy.sh [--sha <commit>] [--no-backup] | infra/deploy.sh rollback" ;;
  esac
done
deploy "$do_backup" "$target_sha"
