#!/usr/bin/env bash
#
# setup-redirect.sh — add perseus-redirect (the legacy-Perseus redirect
# server) to this host, next to MinimumViablePerseus and pdl-morph-server.
#
# Safe to run on a host that is already serving MVP and the morph server:
# it touches only perseus-redirect's own checkout, env file, data directory
# and cron entry. It does not rewrite mvp.env or morph.env, and it does not
# redeploy either app. setup-server.sh calls it at the end of a full setup.
#
# Run as the perseus service user (NOT root/sudo), e.g.:
#
#   REDIRECT_MVP_ORIGIN=https://www.perseus.tufts.edu \
#   REDIRECT_TRUSTED_PROXIES=10.0.0.0/8 \
#   ./setup-redirect.sh
#
# Settings (environment variables):
#   REDIRECT_MVP_ORIGIN       Public MVP origin that redirects point at, and
#                             where /cts-urns.json is fetched from. Required
#                             the first time.
#   MORPH_URL                 The new morph page that legacy /hopper/morph
#                             links go to (default: REDIRECT_MVP_ORIGIN/morph).
#   REDIRECT_TRUSTED_PROXIES  Comma-separated load balancer addresses/CIDRs.
#                             X-Forwarded-For is only believed from these.
#                             Without it, every client behind the LB shares
#                             one rate-limit bucket.
#   REDIRECT_SERVE_PORT       Host port (default: 8090).
#   REDIRECT_IMAGE_TAG        latest = main (production), staging = dev
#                             (default: latest).
#   REDIRECT_STATUS           302 (default) or 301.
#   REDIRECT_REPO_URL / REDIRECT_BRANCH  Checkout to deploy from.
#   GHCR_USER / GHCR_TOKEN    Only needed if the image is private.
#   APPS_DIR                  Default: ~/apps, as for the other apps.
#   CRON_SCHEDULE             Default: every 10 minutes, as for the other apps.
#
# The env file (~/apps/redirect.env) is written ONCE. A re-run leaves it
# alone, so hand edits survive (e.g. REDIRECT_STATUS=301 later on). Edit it
# directly to change settings: cron-deploy.sh notices the change and
# recreates the container on its next tick. To regenerate the file from the
# settings above, re-run with REDIRECT_REWRITE_ENV=1.
#
set -euo pipefail

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
warn() { echo "WARN: $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

APPS_DIR="${APPS_DIR:-${HOME}/apps}"
REDIRECT_REPO_URL="${REDIRECT_REPO_URL:-https://github.com/PerseusDLCode/perseus-redirect.git}"
REDIRECT_BRANCH="${REDIRECT_BRANCH:-main}"
REDIRECT_SERVE_PORT="${REDIRECT_SERVE_PORT:-8090}"
REDIRECT_IMAGE_TAG="${REDIRECT_IMAGE_TAG:-latest}"
REDIRECT_STATUS="${REDIRECT_STATUS:-302}"
REDIRECT_TRUSTED_PROXIES="${REDIRECT_TRUSTED_PROXIES:-}"
REDIRECT_MVP_ORIGIN="${REDIRECT_MVP_ORIGIN:-}"
REDIRECT_MVP_ORIGIN="${REDIRECT_MVP_ORIGIN%/}"
MORPH_URL="${MORPH_URL:-}"
CONTAINER_CMD="${CONTAINER_CMD:-podman}"
GHCR_USER="${GHCR_USER:-}"
GHCR_TOKEN="${GHCR_TOKEN:-}"
CRON_SCHEDULE="${CRON_SCHEDULE:-*/10 * * * *}"

REDIRECT_DIR="${APPS_DIR}/perseus-redirect"
REDIRECT_ENV_FILE="${APPS_DIR}/redirect.env"
REDIRECT_DATA_DIR="${APPS_DIR}/redirect-data"

[ "$(id -u)" -ne 0 ] || die "run this as the perseus user, not root/sudo"
command -v "$CONTAINER_CMD" >/dev/null 2>&1 || die "${CONTAINER_CMD} not found on PATH"
command -v git >/dev/null 2>&1 || die "git not found on PATH"

if ! loginctl show-user "$(id -un)" -p Linger 2>/dev/null | grep -q "yes"; then
  warn "Lingering is not enabled for $(id -un); containers and cron may not" \
       "survive a reboot. Ask an admin to run: sudo loginctl enable-linger $(id -un)"
fi

# Catch a port clash before the first deploy does, with a clearer message.
if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${REDIRECT_SERVE_PORT}\$" \
   && ! ${CONTAINER_CMD} ps --format '{{.Names}}' 2>/dev/null | grep -qx redirect-serve; then
  die "port ${REDIRECT_SERVE_PORT} is already in use; set REDIRECT_SERVE_PORT to a free port"
fi

mkdir -p "$APPS_DIR" "$REDIRECT_DATA_DIR"

# ----- 1. Checkout (holds compose.yaml and cron-deploy.sh) ------------------
if [ -d "${REDIRECT_DIR}/.git" ]; then
  log "Updating perseus-redirect checkout..."
  git -C "$REDIRECT_DIR" fetch --depth 1 origin "$REDIRECT_BRANCH"
  git -C "$REDIRECT_DIR" checkout -B "$REDIRECT_BRANCH" FETCH_HEAD
  git -C "$REDIRECT_DIR" reset --hard FETCH_HEAD
else
  log "Cloning perseus-redirect..."
  git clone --branch "$REDIRECT_BRANCH" --depth 1 "$REDIRECT_REPO_URL" "$REDIRECT_DIR"
fi
chmod +x "${REDIRECT_DIR}/deploy/cron-deploy.sh"

# ----- 2. Env file (kept outside the checkout; written once) -----------------
if [ -f "$REDIRECT_ENV_FILE" ] && [ -z "${REDIRECT_REWRITE_ENV:-}" ]; then
  log "Keeping existing ${REDIRECT_ENV_FILE} (REDIRECT_REWRITE_ENV=1 regenerates it)."
else
  [ -n "$REDIRECT_MVP_ORIGIN" ] || die "set REDIRECT_MVP_ORIGIN to the public MVP origin (e.g. https://www.perseus.tufts.edu)"
  case "$REDIRECT_MVP_ORIGIN" in
    http://*|https://*) ;;
    *) die "REDIRECT_MVP_ORIGIN must start with http:// or https:// (got '${REDIRECT_MVP_ORIGIN}')" ;;
  esac
  log "Writing ${REDIRECT_ENV_FILE}..."
  cat > "$REDIRECT_ENV_FILE" <<EOF
# perseus-redirect settings. Written by setup-redirect.sh and never
# overwritten by it afterwards: edit freely. cron-deploy.sh recreates the
# container on its next tick (within 10 minutes) when these change.
IMAGE=ghcr.io/perseusdlcode/perseus-redirect
IMAGE_TAG=${REDIRECT_IMAGE_TAG}
CONTAINER_CMD=${CONTAINER_CMD}
COMPOSE_PROJECT=redirect
SERVE_PORT=${REDIRECT_SERVE_PORT}
SERVE_CTR=redirect-serve
STATE_FILE=${REDIRECT_DATA_DIR}/deployed.digest

# Public MVP origin redirects point at; /cts-urns.json is fetched from it.
MVP_ORIGIN=${REDIRECT_MVP_ORIGIN}
# Where legacy /hopper/morph links go (empty: MVP_ORIGIN/morph).
MORPH_URL=${MORPH_URL}
# 302 until replayed coverage is trusted, then 301 (cached by browsers).
REDIRECT_STATUS=${REDIRECT_STATUS}
# Load balancer address(es)/CIDRs, comma-separated.
TRUSTED_PROXIES=${REDIRECT_TRUSTED_PROXIES}

GHCR_USER=${GHCR_USER}
GHCR_TOKEN=${GHCR_TOKEN}
EOF
  chmod 600 "$REDIRECT_ENV_FILE"
fi

# ----- 3. Cron entry ----------------------------------------------------------
CRON_MARK="# perseus-deploy: redirect"
CRON_LINE="${CRON_SCHEDULE} ENV_FILE=${REDIRECT_ENV_FILE} /usr/bin/flock -n ${REDIRECT_DATA_DIR}/deploy.lock ${REDIRECT_DIR}/deploy/cron-deploy.sh >> ${REDIRECT_DATA_DIR}/deploy.log 2>&1 ${CRON_MARK}"
EXISTING_CRON="$(crontab -l 2>/dev/null || true)"
if grep -qF "$CRON_MARK" <<<"$EXISTING_CRON"; then
  log "Cron entry already present."
else
  log "Adding cron entry (existing entries are kept)..."
  printf '%s\n%s\n' "$EXISTING_CRON" "$CRON_LINE" | sed '/^$/d' | crontab -
fi

# ----- 4. First deploy --------------------------------------------------------
# Under the cron entry's lock, so it can't race a tick. Fails if the image
# isn't on GHCR yet (push perseus-redirect's main branch first) or isn't
# public (see GHCR_USER/GHCR_TOKEN).
log "Deploying perseus-redirect..."
if ! ENV_FILE="$REDIRECT_ENV_FILE" /usr/bin/flock "${REDIRECT_DATA_DIR}/deploy.lock" \
    "${REDIRECT_DIR}/deploy/cron-deploy.sh"; then
  die "first deploy failed; see the output above. The cron entry will retry every 10 minutes."
fi

# ----- 5. Check it answers ----------------------------------------------------
HEALTH=""
for _ in $(seq 1 15); do
  if HEALTH="$(curl -fsS "http://127.0.0.1:${REDIRECT_SERVE_PORT}/healthz" 2>/dev/null)"; then
    break
  fi
  HEALTH=""
  sleep 2
done
if [ -n "$HEALTH" ]; then
  log "perseus-redirect is up on port ${REDIRECT_SERVE_PORT}:"
  echo "$HEALTH"
else
  warn "perseus-redirect isn't healthy yet. It answers 503 until it has fetched" \
       "the manifest: check that MVP_ORIGIN/cts-urns.json is reachable from this" \
       "host, then: curl http://127.0.0.1:${REDIRECT_SERVE_PORT}/healthz ; podman logs redirect-serve"
fi

cat <<SUMMARY

--------------------------------------------------------------------
perseus-redirect:  http://127.0.0.1:${REDIRECT_SERVE_PORT}  (container: redirect-serve)
Config:            ${REDIRECT_ENV_FILE}
Deploy log:        ${REDIRECT_DATA_DIR}/deploy.log
Server log:        podman logs redirect-serve   (a summary every 15 minutes)
Cron:              ${CRON_LINE}

Try it:
  curl -sI 'http://127.0.0.1:${REDIRECT_SERVE_PORT}/hopper/text?doc=Perseus:text:1999.01.0133:book=1'
  curl -sI 'http://127.0.0.1:${REDIRECT_SERVE_PORT}/hopper/morph?l=lo/gos&la=greek'

To go live, point the legacy Perseus hostnames' traffic at this port at
the load balancer (see mvp-deploy's README).
--------------------------------------------------------------------
SUMMARY
