#!/usr/bin/env bash
#
# deploy.sh — deploy iex-code to the prod VPS over SSH (Docker + host nginx).
#
# What it does:
#   1. Runs local gates (mix precommit) unless --skip-checks.
#   2. Rsyncs this repo to a versioned release dir on the VPS.
#   3. Builds the prod image on the VPS, tags the previous :local as :prev.
#   4. Runs Ecto migrations in a one-off container.
#   5. Starts the new container on the nginx-pinned loopback port.
#   6. Waits for the container healthcheck, then for the public HTTPS URL.
#   7. Prunes old releases/images. On failure it rolls back automatically.
#
# Prod chain: nginx :443 -> 127.0.0.1:$PUBLIC_PORT -> iex-code container.
# PUBLIC_PORT defaults to 49152 to match the proxy_pass pin in
# /etc/nginx/sites-available/iex.llmotions.com. Change it only together
# with the nginx config.
#
# The first deploy from THIS repo replaces the iex-code-web container that
# currently owns the port. That cutover needs the explicit --takeover flag;
# without it the script aborts instead of touching the running container.
# State/workspace host paths are shared with the previous deployment on
# purpose so the SQLite database and workspaces survive the cutover.
#
# Configuration (flags override env, env overrides defaults):
#   DEPLOY_HOST        VPS hostname/IP            (default 34.136.10.30)
#   DEPLOY_USER        SSH user                   (default zaali)
#   DEPLOY_PORT        SSH port                   (default 22)
#   DEPLOY_RELEASES    versioned release root     (default /opt/iex-code_releases)
#   DEPLOY_ENV_FILE    container env file on VPS  (default /etc/iex-code-web/app.env)
#   DEPLOY_HEALTH_URL  public healthcheck URL     (default https://iex.llmotions.com/)
#   DEPLOY_PUBLIC_PORT loopback port nginx uses   (default 49152)
#   DEPLOY_KEEP        releases to keep           (default 5)
#
# Remote steps run as root via passwordless sudo (same privilege model as the
# previous deployment's wrapper). The default env file is the previous
# deployment's root-only app.env, reused so SECRET_KEY_BASE and session
# cookies survive the cutover. It must define at least SECRET_KEY_BASE.
#
set -euo pipefail

APP="iex-code"
IMAGE="iex-code"
SERVICE="app"

HOST="${DEPLOY_HOST:-34.136.10.30}"
USER="${DEPLOY_USER:-zaali}"
PORT="${DEPLOY_PORT:-22}"
RELEASES_ROOT="${DEPLOY_RELEASES:-/opt/iex-code_releases}"
ENV_FILE="${DEPLOY_ENV_FILE:-/etc/iex-code-web/app.env}"
HEALTH_URL="${DEPLOY_HEALTH_URL:-https://iex.llmotions.com/}"
PUBLIC_PORT="${DEPLOY_PUBLIC_PORT:-49152}"
KEEP="${DEPLOY_KEEP:-5}"

TAKEOVER=0 SKIP_CHECKS=0 ALLOW_DIRTY=0 DRY_RUN=0 ROLLBACK=0

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  echo "Usage: ./deploy.sh [options]"
  echo "  --host H --user U --port P --releases-root D --env-file F"
  echo "  --health-url U --public-port N --keep N"
  echo "  --takeover     stop the previous iex-code-web container on cutover"
  echo "  --skip-checks  skip local mix precommit gate"
  echo "  --allow-dirty  allow deploying with uncommitted changes"
  echo "  --rollback     restore the previous :prev image and restart it"
  echo "  --dry-run      print the plan without touching anything remote"
  echo "  -h, --help     this help"
}

log() { printf '[deploy] %s\n' "$*"; }
die() { printf '[deploy] ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --user) USER="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --releases-root) RELEASES_ROOT="$2"; shift 2 ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --health-url) HEALTH_URL="$2"; shift 2 ;;
    --public-port) PUBLIC_PORT="$2"; shift 2 ;;
    --keep) KEEP="$2"; shift 2 ;;
    --takeover) TAKEOVER=1; shift ;;
    --skip-checks) SKIP_CHECKS=1; shift ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    --rollback) ROLLBACK=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

case "$PUBLIC_PORT" in ''|*[!0-9]*) die "PUBLIC_PORT must be numeric: $PUBLIC_PORT" ;; esac
case "$KEEP" in ''|*[!0-9]*|0) die "KEEP must be a positive integer: $KEEP" ;; esac
case "$RELEASES_ROOT" in /*) ;; *) die "releases root must be absolute: $RELEASES_ROOT" ;; esac
case "$ENV_FILE" in /*) ;; *) die "env file must be absolute: $ENV_FILE" ;; esac

SSH="ssh -o BatchMode=yes -o ConnectTimeout=15 -p $PORT $USER@$HOST"
RSYNC_SSH="ssh -p $PORT -o BatchMode=yes -o ConnectTimeout=15"

cd "$(dirname "$0")"

# Remote steps run as root via `sudo -n bash -s` with a quoted heredoc, so
# nothing inside the script expands locally. Local values are prepended as
# assignment lines (sudo does not accept VAR=... prefixes without SETENV).
# Values are single-quote wrapped; refuse quotes.
noquotes() {
  case "$1" in *"'"*) die "value must not contain single quotes: $1" ;; esac
}
for v in "$APP" "$IMAGE" "$SERVICE" "$USER" "$HOST" "$RELEASES_ROOT" \
    "$ENV_FILE" "$HEALTH_URL" "$PUBLIC_PORT" "$KEEP"; do noquotes "$v"; done

R_ENV="APP='$APP' IMAGE='$IMAGE' SERVICE='$SERVICE' DEPLOY_USER='$USER' RELEASES_ROOT='$RELEASES_ROOT' ENV_FILE='$ENV_FILE' PUBLIC_PORT='$PUBLIC_PORT' KEEP='$KEEP'"

remote_exec() {
  # remote_exec <extra-assignments> ; script arrives on stdin (quoted heredoc)
  { printf '%s\n%s\n' "$R_ENV" "$1"; cat; } | $SSH "sudo -n bash -s"
}

# ---------------------------------------------------------------- rollback

if [ "$ROLLBACK" -eq 1 ]; then
  log "rolling back to previous image on $HOST"
  [ "$DRY_RUN" -eq 1 ] && { log "(dry run) would retag $IMAGE:prev as :local and restart"; exit 0; }
  RELEASE_DIR="$(printf 'ls -dt "$RELEASES_ROOT"/*/ 2>/dev/null | head -n 1\n' | remote_exec "")"
  [ -n "$RELEASE_DIR" ] || die "no releases found under $RELEASES_ROOT"
  noquotes "$RELEASE_DIR"
  log "using release dir $RELEASE_DIR"
  remote_exec "RELEASE_DIR='$RELEASE_DIR'" <<'REMOTE_EOF'
set -euo pipefail
cd "$RELEASE_DIR" || exit 1
export IEX_CODE_APP_ENV_FILE="$ENV_FILE" IEX_CODE_PUBLIC_PORT="$PUBLIC_PORT"
export IEX_CODE_IMAGE="$IMAGE:local"
docker tag "$IMAGE:prev" "$IMAGE:local"
docker compose -p "$APP" up -d "$SERVICE"
docker compose -p "$APP" ps "$SERVICE"
REMOTE_EOF
  log "rollback started; verify $HEALTH_URL"
  exit 0
fi

# ------------------------------------------------------------- local gates

need ssh; need rsync; need curl; need git
git rev-parse --show-toplevel >/dev/null 2>&1 || die "not inside a git checkout"

if [ "$SKIP_CHECKS" -eq 0 ]; then
  need mix
  log "running local gate: mix precommit"
  [ "$DRY_RUN" -eq 1 ] || mix precommit
else
  log "skipping local checks (--skip-checks)"
fi

if [ -n "$(git status --porcelain)" ]; then
  if [ "$ALLOW_DIRTY" -eq 0 ]; then
    die "working tree is dirty; commit first or pass --allow-dirty"
  fi
  DIRTY="-dirty"
  log "WARNING: deploying with uncommitted changes"
else
  DIRTY=""
fi

RELEASE_ID="$(date +%Y%m%d%H%M%S)-$(git rev-parse --short HEAD)${DIRTY}"
RELEASE_DIR="$RELEASES_ROOT/$RELEASE_ID"
noquotes "$RELEASE_ID"
noquotes "$RELEASE_DIR"

if [ "$DRY_RUN" -eq 1 ]; then
  log "(dry run) release=$RELEASE_ID host=$USER@$HOST:$PORT dir=$RELEASE_DIR port=$PUBLIC_PORT takeover=$TAKEOVER"
  log "(dry run) would: rsync repo, build $IMAGE:$RELEASE_ID, migrate, up, healthcheck $HEALTH_URL"
  exit 0
fi

# ---------------------------------------------------------- remote preflight

log "preflight on $HOST (release $RELEASE_ID)"
$SSH "sudo -n true" || die "$USER@$HOST needs passwordless sudo for remote steps"
PREFLIGHT_LOG="/tmp/$APP-deploy-preflight.log"
set +e
remote_exec "" <<'REMOTE_EOF' | tee "$PREFLIGHT_LOG"
set -euo pipefail
command -v docker >/dev/null || { echo 'docker not found on VPS' >&2; exit 1; }
docker compose version >/dev/null || { echo 'docker compose plugin missing on VPS' >&2; exit 1; }
[ -r "$ENV_FILE" ] || { echo "env file $ENV_FILE missing or unreadable" >&2; exit 1; }
grep -q '^SECRET_KEY_BASE=.\+' "$ENV_FILE" || { echo "SECRET_KEY_BASE empty in $ENV_FILE" >&2; exit 1; }
avail_kb=$(df -k /var/lib/docker 2>/dev/null | awk 'NR==2{print $4}');
[ "${avail_kb:-0}" -ge 5242880 ] || { echo 'less than 5G free under /var/lib/docker' >&2; exit 1; }
occupant=$(docker ps --format '{{.Names}} {{.Ports}}' | grep "127.0.0.1:$PUBLIC_PORT->" || true)
if [ -n "$occupant" ]; then
  echo "PORT-OCCUPANT:$occupant"
fi
REMOTE_EOF
PREFLIGHT_STATUS=${PIPESTATUS[0]}
set -e
[ "$PREFLIGHT_STATUS" -eq 0 ] || die "remote preflight failed"
grep -q PORT-OCCUPANT: "$PREFLIGHT_LOG" && OCCUPIED=1 || OCCUPIED=0

if [ "$OCCUPIED" -eq 1 ]; then
  OCCUPANT="$(grep PORT-OCCUPANT: "$PREFLIGHT_LOG" | head -n 1 | sed 's/^PORT-OCCUPANT://')"
  case "$OCCUPANT" in
    iex-code-web*)
      if [ "$TAKEOVER" -eq 0 ]; then
        die "port $PUBLIC_PORT is owned by the previous deployment ($OCCUPANT); re-run with --takeover to cut over"
      fi
      log "takeover: will stop $OCCUPANT after the new image builds"
      ;;
    "$APP-$SERVICE-"*)
      log "port held by our own container; plain redeploy"
      ;;
    *)
      die "port $PUBLIC_PORT is held by an unexpected container ($OCCUPANT); free it manually first"
      ;;
  esac
fi

# ------------------------------------------------------------------ rsync

log "uploading source to $RELEASE_DIR"
$SSH "sudo -n mkdir -p '$RELEASE_DIR' && sudo -n chown '$USER' '$RELEASE_DIR'"
rsync -az --delete \
  -e "$RSYNC_SSH" \
  --exclude '_build/' --exclude 'deps/' --exclude '.git/' \
  --exclude '*.db' --exclude '*.db-shm' --exclude '*.db-wal' \
  --exclude 'erl_crash.dump' --exclude 'tmp/' --exclude 'cover/' \
  ./ "$USER@$HOST:$RELEASE_DIR/"

# ------------------------------------------------------------------- build

log "building image $IMAGE:$RELEASE_ID (this takes a few minutes)"
BUILD_LOG="/tmp/$APP-deploy-build.log"
set +e
remote_exec "RELEASE_DIR='$RELEASE_DIR' RELEASE_ID='$RELEASE_ID'" <<'REMOTE_EOF' | tee "$BUILD_LOG"
set -euo pipefail
cd "$RELEASE_DIR" || exit 1
export IEX_CODE_APP_ENV_FILE="$ENV_FILE" IEX_CODE_PUBLIC_PORT="$PUBLIC_PORT"
export IEX_CODE_IMAGE="$IMAGE:$RELEASE_ID"
docker compose -p "$APP" config >/dev/null
if docker image inspect "$IMAGE:local" >/dev/null 2>&1; then
  docker tag "$IMAGE:local" "$IMAGE:prev"
  echo 'previous :local saved as :prev'
fi
docker compose -p "$APP" build "$SERVICE"
docker tag "$IMAGE:$RELEASE_ID" "$IMAGE:local"
echo "BUILD_OK:$RELEASE_ID"
REMOTE_EOF
BUILD_STATUS=${PIPESTATUS[0]}
set -e
[ "$BUILD_STATUS" -eq 0 ] || die "remote build failed"
grep -q "BUILD_OK:$RELEASE_ID" "$BUILD_LOG" || die "remote build failed"

# ------------------------------------------------- takeover / migrate / up

log "switching traffic to $IMAGE:$RELEASE_ID"
SWITCH_LOG="/tmp/$APP-deploy-switch.log"
set +e
remote_exec "RELEASE_DIR='$RELEASE_DIR' RELEASE_ID='$RELEASE_ID' TAKEOVER='$TAKEOVER'" <<'REMOTE_EOF' | tee "$SWITCH_LOG"
set -euo pipefail
cd "$RELEASE_DIR" || exit 1
export IEX_CODE_APP_ENV_FILE="$ENV_FILE" IEX_CODE_PUBLIC_PORT="$PUBLIC_PORT"
export IEX_CODE_IMAGE="$IMAGE:local"
stopped=''
if [ "$TAKEOVER" -eq 1 ]; then
  for c in $(docker ps --format '{{.Names}}' --filter "publish=$PUBLIC_PORT"); do
    case "$c" in
      iex-code-web-*) docker stop "$c" >/dev/null && stopped="$stopped $c" ;;
      *) echo "unexpected port occupant $c; aborting" >&2; exit 1 ;;
    esac
  done
  echo "STOPPED_SIBLING:$stopped"
fi
restore() {
  for c in $stopped; do docker start "$c" >/dev/null 2>&1 || true; done
}
if ! docker compose -p "$APP" run --rm --no-deps "$SERVICE" \
    /opt/iex-code/bin/iex_code eval \
    'Ecto.Migrator.with_repo(IexCode.Repo, &Ecto.Migrator.run(&1, :up, all: true))'; then
  echo 'migration failed; restoring previous container' >&2
  restore; exit 1
fi
docker compose -p "$APP" up -d "$SERVICE"
status=missing
for _i in $(seq 1 30); do
  status=$(docker inspect --format '{{.State.Health.Status}}' "$APP-$SERVICE-1" 2>/dev/null || echo missing)
  if [ "$status" = healthy ]; then echo 'CONTAINER_HEALTHY'; break; fi
  if [ "$status" = unhealthy ]; then
    echo 'new container unhealthy:' >&2
    docker logs --tail 40 "$APP-$SERVICE-1" >&2 || true
    docker compose -p "$APP" down
    restore; exit 1
  fi
  sleep 5
done
if [ "$status" != healthy ]; then
  echo 'new container never became healthy' >&2
  docker logs --tail 40 "$APP-$SERVICE-1" >&2 || true
  docker compose -p "$APP" down
  restore; exit 1
fi
echo "$RELEASE_ID" > "$RELEASES_ROOT/.current"
REMOTE_EOF
SWITCH_STATUS=${PIPESTATUS[0]}
set -e
[ "$SWITCH_STATUS" -eq 0 ] || die "cutover failed (previous container restored if this was a takeover)"
grep -q CONTAINER_HEALTHY "$SWITCH_LOG" || die "cutover failed (previous container restored if this was a takeover)"

# ---------------------------------------------------------- public health

log "waiting for $HEALTH_URL"
for _ in $(seq 1 24); do
  if curl -fsSL --max-time 10 "$HEALTH_URL" >/dev/null 2>&1; then
    log "public URL is serving the new release"
    PUBLIC_OK=1
    break
  fi
  sleep 5
done
if [ "${PUBLIC_OK:-0}" -ne 1 ]; then
  die "container is healthy but $HEALTH_URL did not respond (check nginx proxy_pass -> 127.0.0.1:$PUBLIC_PORT)"
fi

# ------------------------------------------------------------------ prune

log "pruning old releases (keeping $KEEP) and dangling images"
remote_exec "" <<'REMOTE_EOF'
set -euo pipefail
cd "$RELEASES_ROOT" || exit 1
ls -dt */ 2>/dev/null | tail -n +"$((KEEP + 1))" | xargs -r rm -rf
docker image prune -f >/dev/null
docker images "$IMAGE" --format '{{.Repository}}:{{.Tag}}'
REMOTE_EOF

log "deployed $RELEASE_ID to $HEALTH_URL"
log "rollback: ./deploy.sh --rollback"
