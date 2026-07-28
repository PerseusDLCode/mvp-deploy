#!/usr/bin/env bash
#
# setup-server.sh — one-time (idempotent) provisioning for running
# MinimumViablePerseus and pdl-morph-server together, via rootless podman,
# on a CentOS server that reboots occasionally.
#
# Run as root (or via sudo). Safe to re-run.
#
# Assumes podman + podman-compose are already installed, the service user
# already exists, and the two service ports are opened for you externally
# (e.g. by a firewall managed outside this box) — none of that is handled
# here.
#
# What it does:
#   1. Enables lingering for the service user, so its containers/cron/
#      systemd --user units keep running (and come back after reboot)
#      without anyone logging in.
#   2. Clones or updates both app repos under the service user's home.
#   3. Writes per-app env files (ports, image, compose project name,
#      MORPH_URL, state/lock/log paths) OUTSIDE the repo checkouts, so
#      `git pull` never clobbers local config.
#   4. Installs two cron entries (one per app), each under its own flock.
#   5. Enables crond (system) and podman-restart.service (user), so
#      containers started with `restart: unless-stopped` come back
#      automatically after a reboot.
#   6. Runs an initial deploy of both apps immediately, so you don't have
#      to wait for the first cron tick.
#
# Configure via environment variables before running, e.g.:
#
#   PUBLIC_HOST=perseus.example.org \
#   MVP_SERVE_PORT=8000 \
#   MORPH_SERVE_PORT=8081 \
#   sudo -E ./setup-server.sh
#
set -euo pipefail

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ----- Configuration (override via environment) ----------------------------
SERVICE_USER="${SERVICE_USER:-perseus}"
APPS_DIR="${APPS_DIR:-/home/${SERVICE_USER}/apps}"

MVP_REPO_URL="${MVP_REPO_URL:-https://github.com/PerseusDLCode/MinimumViablePerseus.git}"
MORPH_REPO_URL="${MORPH_REPO_URL:-https://github.com/PerseusDLCode/pdl-morph-server.git}"
MVP_BRANCH="${MVP_BRANCH:-main}"
MORPH_BRANCH="${MORPH_BRANCH:-main}"

# PUBLIC_HOST is how BROWSERS reach this server. MORPH_URL is baked into the
# static HTML that mvp-build renders and fetched client-side — it must be
# reachable from visitors' browsers, not just from this host. It is NOT an
# internal container-network address.
PUBLIC_HOST="${PUBLIC_HOST:?Set PUBLIC_HOST to the public hostname or IP visitors use (e.g. perseus.example.org)}"
PUBLIC_SCHEME="${PUBLIC_SCHEME:-https}"

MVP_SERVE_PORT="${MVP_SERVE_PORT:-8000}"
MORPH_SERVE_PORT="${MORPH_SERVE_PORT:-8081}"
# If the morph server sits behind a reverse proxy on the standard port, set
# MORPH_URL directly instead and this is ignored.
MORPH_URL="${MORPH_URL:-${PUBLIC_SCHEME}://${PUBLIC_HOST}:${MORPH_SERVE_PORT}/morph}"

IMAGE_TAG="${IMAGE_TAG:-dev-latest}"
CONTAINER_CMD="${CONTAINER_CMD:-podman}"

# Optional GHCR credentials, only needed if the packages are private.
GHCR_USER="${GHCR_USER:-}"
GHCR_TOKEN="${GHCR_TOKEN:-}"

CRON_SCHEDULE="${CRON_SCHEDULE:-*/10 * * * *}"

MVP_DIR="${APPS_DIR}/MinimumViablePerseus"
MORPH_DIR="${APPS_DIR}/pdl-morph-server"
MVP_ENV_FILE="${APPS_DIR}/mvp.env"
MORPH_ENV_FILE="${APPS_DIR}/morph.env"
MVP_DATA_DIR="${APPS_DIR}/mvp-data"
MORPH_DATA_DIR="${APPS_DIR}/morph-data"

# ----------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "run as root (sudo -E $0)"

id "$SERVICE_USER" >/dev/null 2>&1 || die "service user ${SERVICE_USER} does not exist (set SERVICE_USER=... if it's not 'perseus')"

as_user() { runuser -u "$SERVICE_USER" -- "$@"; }

as_user command -v podman >/dev/null 2>&1 || die "podman not found on ${SERVICE_USER}'s PATH — this script assumes it's already installed"

# ----- 1. Lingering (keeps user services/cron/podman running without login) -
if ! loginctl show-user "$SERVICE_USER" -p Linger 2>/dev/null | grep -q "yes"; then
  log "Enabling lingering for ${SERVICE_USER}..."
  loginctl enable-linger "$SERVICE_USER"
fi

# loginctl needs a moment to create /run/user/<uid> the first time.
UID_NUM="$(id -u "$SERVICE_USER")"
for _ in $(seq 1 10); do
  [ -d "/run/user/${UID_NUM}" ] && break
  sleep 1
done
[ -d "/run/user/${UID_NUM}" ] || die "lingering did not create /run/user/${UID_NUM}; try rebooting once and re-running this script"

as_user_systemctl() {
  sudo -u "$SERVICE_USER" XDG_RUNTIME_DIR="/run/user/${UID_NUM}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${UID_NUM}/bus" \
    systemctl --user "$@"
}

# ----- 2. Clone/update both repos -------------------------------------------
mkdir -p "$APPS_DIR" "$MVP_DATA_DIR" "$MORPH_DATA_DIR" \
  "${MVP_DATA_DIR}/build-a" "${MVP_DATA_DIR}/build-b"
chown -R "${SERVICE_USER}:${SERVICE_USER}" "$APPS_DIR"

clone_or_update() {
  local url="$1" dir="$2" branch="$3"
  if [ -d "${dir}/.git" ]; then
    log "Updating $(basename "$dir")..."
    as_user git -C "$dir" fetch --depth 1 origin "$branch"
    as_user git -C "$dir" checkout "$branch"
    as_user git -C "$dir" reset --hard "origin/${branch}"
  else
    log "Cloning $(basename "$dir")..."
    as_user git clone --branch "$branch" --depth 1 "$url" "$dir"
  fi
}
clone_or_update "$MVP_REPO_URL" "$MVP_DIR" "$MVP_BRANCH"
clone_or_update "$MORPH_REPO_URL" "$MORPH_DIR" "$MORPH_BRANCH"

chmod +x "${MVP_DIR}/deploy/cron-deploy.sh" "${MORPH_DIR}/deploy/cron-deploy.sh"

# ----- 3. Per-app env files (kept outside the repo checkouts) --------------
cat > "$MVP_ENV_FILE" <<EOF
# Managed by setup-server.sh — safe to hand-edit; not touched by git pull.
IMAGE=ghcr.io/perseusdlcode/minimumviableperseus
IMAGE_TAG=${IMAGE_TAG}
CONTAINER_CMD=${CONTAINER_CMD}
COMPOSE_PROJECT=mvp
SERVE_PORT=${MVP_SERVE_PORT}
SERVE_CTR=mvp-serve
BUILD_CTR=mvp-build
BUILD_DIR=${MVP_DATA_DIR}/build
STATE_FILE=${MVP_DATA_DIR}/last-digest
MORPH_URL=${MORPH_URL}
GHCR_USER=${GHCR_USER}
GHCR_TOKEN=${GHCR_TOKEN}
EOF

cat > "$MORPH_ENV_FILE" <<EOF
# Managed by setup-server.sh — safe to hand-edit; not touched by git pull.
IMAGE=ghcr.io/perseusdlcode/pdl-morph-server
IMAGE_TAG=${IMAGE_TAG}
CONTAINER_CMD=${CONTAINER_CMD}
COMPOSE_PROJECT=morph
SERVE_PORT=${MORPH_SERVE_PORT}
SERVE_CTR=morph-serve
STATE_FILE=${MORPH_DATA_DIR}/deployed.digest
GHCR_USER=${GHCR_USER}
GHCR_TOKEN=${GHCR_TOKEN}
EOF

chown "${SERVICE_USER}:${SERVICE_USER}" "$MVP_ENV_FILE" "$MORPH_ENV_FILE"
chmod 600 "$MVP_ENV_FILE" "$MORPH_ENV_FILE"

# ----- 4. Cron entries -------------------------------------------------------
MVP_CRON_MARK="# perseus-deploy: mvp"
MORPH_CRON_MARK="# perseus-deploy: morph"
MVP_CRON_LINE="${CRON_SCHEDULE} ENV_FILE=${MVP_ENV_FILE} /usr/bin/flock -n ${MVP_DATA_DIR}/deploy.lock ${MVP_DIR}/deploy/cron-deploy.sh >> ${MVP_DATA_DIR}/deploy.log 2>&1 ${MVP_CRON_MARK}"
MORPH_CRON_LINE="${CRON_SCHEDULE} ENV_FILE=${MORPH_ENV_FILE} /usr/bin/flock -n ${MORPH_DATA_DIR}/deploy.lock ${MORPH_DIR}/deploy/cron-deploy.sh >> ${MORPH_DATA_DIR}/deploy.log 2>&1 ${MORPH_CRON_MARK}"

EXISTING_CRON="$(as_user crontab -l 2>/dev/null || true)"
NEW_CRON="$EXISTING_CRON"
if ! grep -qF "$MVP_CRON_MARK" <<<"$EXISTING_CRON"; then
  NEW_CRON="$(printf '%s\n%s\n' "$NEW_CRON" "$MVP_CRON_LINE")"
fi
if ! grep -qF "$MORPH_CRON_MARK" <<<"$EXISTING_CRON"; then
  NEW_CRON="$(printf '%s\n%s\n' "$NEW_CRON" "$MORPH_CRON_LINE")"
fi
if [ "$NEW_CRON" != "$EXISTING_CRON" ]; then
  log "Installing crontab entries for ${SERVICE_USER}..."
  printf '%s\n' "$NEW_CRON" | sed '/^$/d' | as_user crontab -
fi

# ----- 5. Enable crond + podman-restart --------------------------------------
log "Enabling crond..."
systemctl enable --now crond

log "Enabling podman-restart.service for ${SERVICE_USER} (restarts containers after reboot)..."
as_user_systemctl enable --now podman-restart.service

# ----- 6. First deploy --------------------------------------------------------
log "Running initial deploy of pdl-morph-server..."
as_user env ENV_FILE="$MORPH_ENV_FILE" "${MORPH_DIR}/deploy/cron-deploy.sh"

log "Running initial deploy of MinimumViablePerseus..."
as_user env ENV_FILE="$MVP_ENV_FILE" "${MVP_DIR}/deploy/cron-deploy.sh"

log "Done."
cat <<SUMMARY

--------------------------------------------------------------------
Setup complete.

  pdl-morph-server:        http://${PUBLIC_HOST}:${MORPH_SERVE_PORT}
  MinimumViablePerseus:     http://${PUBLIC_HOST}:${MVP_SERVE_PORT}
  MORPH_URL baked into MVP: ${MORPH_URL}

Config lives in:
  ${MVP_ENV_FILE}
  ${MORPH_ENV_FILE}

Logs:
  ${MVP_DATA_DIR}/deploy.log
  ${MORPH_DATA_DIR}/deploy.log

Cron (as ${SERVICE_USER}):
  ${MVP_CRON_LINE}
  ${MORPH_CRON_LINE}

Remaining manual steps, if not already done:
  1. Make sure both GHCR packages are public (or set GHCR_USER/GHCR_TOKEN
     in the env files above for private pulls):
       https://github.com/orgs/perseusdlcode/packages/container/minimumviableperseus/settings
       https://github.com/orgs/perseusdlcode/packages/container/pdl-morph-server/settings
  2. If MORPH_URL should go through a reverse proxy / TLS terminator
     instead of a bare port, set MORPH_URL directly in ${MVP_ENV_FILE}
     and re-run this script (or just edit the file — cron picks it up
     next tick).
  3. Reboot once to confirm containers and cron come back on their own:
     `podman ps` (as ${SERVICE_USER}) should show mvp-serve and
     morph-serve running within a minute or two of boot.
--------------------------------------------------------------------
SUMMARY
