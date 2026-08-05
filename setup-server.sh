#!/usr/bin/env bash
#
# setup-server.sh — one-time (idempotent) provisioning for running
# MinimumViablePerseus and pdl-morph-server together, via rootless podman,
# on a CentOS server that reboots occasionally.
#
# Run as the perseus service user directly (NOT root/sudo) — everything
# here only touches that user's own files, crontab, and systemd --user
# units.
#
# Assumes podman + podman-compose + zstd are already installed (zstd is
# needed to extract the .tar.zst artifacts cron-deploy.sh pulls — GNU tar's
# --zstd shells out to it rather than linking it in, unlike gzip), this
# user account already exists, crond is already running, and the two
# service ports are opened for you externally — none of that is this
# script's job.
#
# What it does:
#   1. Enables lingering for this user (if not already enabled), so
#      containers/cron/systemd --user units keep running — and come back
#      after reboot — without an active login session. If this account
#      isn't allowed to enable its own lingering, it warns instead of
#      failing; ask an admin to run `loginctl enable-linger perseus` once.
#   2. Clones or updates both app repos under $APPS_DIR.
#   3. Writes per-app env files (ports, image, compose project name,
#      MORPH_URL, state/lock/log paths) OUTSIDE the repo checkouts, so
#      `git pull` never clobbers local config.
#   4. Installs two cron entries (one per app), each under its own flock.
#   5. Enables podman-restart.service (a systemd --user unit) so
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
#   ./setup-server.sh
#
set -euo pipefail

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
warn() { echo "WARN: $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ----- Configuration (override via environment) ----------------------------
APPS_DIR="${APPS_DIR:-${HOME}/apps}"

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
MORPH_SERVE_PORT="${MORPH_SERVE_PORT:-5000}"
# If the morph server sits behind a reverse proxy on the standard port, set
# MORPH_URL directly instead and this is ignored.
#
# MVP no longer reads this: it used to be baked into the frozen HTML by a
# build container running on this host, but that freeze now happens in CI
# (see MVP_REGISTRY/MVP_CORPORA above), which reads its own `vars.MORPH_URL`
# GitHub Actions repo variable instead. Still computed and printed at the
# end of this script as a convenience — set that CI variable to the same
# value, since it needs to resolve from a visitor's browser either way.
MORPH_URL="${MORPH_URL:-${PUBLIC_SCHEME}://${PUBLIC_HOST}:${MORPH_SERVE_PORT}/morph}"

CONTAINER_CMD="${CONTAINER_CMD:-podman}"

# MVP no longer ships as a single image polled/built on this host — CI
# (MinimumViablePerseus's build-corpus.yml/build-global.yml) freezes pages
# and pushes them as OCI artifacts; cron-deploy.sh just pulls and extracts
# them (see that script's header). CORPORA must match the lowercase
# tag_name values in build-corpus.yml's matrix, not the case-sensitive
# corpus directory names.
MVP_REGISTRY="${MVP_REGISTRY:-ghcr.io/perseusdlcode}"
MVP_CORPORA="${MVP_CORPORA:-greeklit latinlit first1kgreek}"
ORAS_VERSION="${ORAS_VERSION:-1.2.0}"

# Still used by pdl-morph-server's own env file below — that app is
# unaffected by MVP's corpus split and still ships as a single polled image.
IMAGE_TAG="${IMAGE_TAG:-dev-latest}"

# Which alias of the MVP corpus/global artifacts this host tracks — set by
# which branch's build-corpus.yml/build-global.yml push pushed them (see
# MinimumViablePerseus's build-corpus.yml: main -> latest = production,
# dev -> staging). Production hosts should leave this at the default;
# staging hosts should set TAG=staging.
TAG="${TAG:-latest}"

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
[ "$(id -u)" -ne 0 ] || die "run this as the perseus user, not root/sudo"
command -v podman >/dev/null 2>&1 || die "podman not found on PATH — this script assumes it's already installed"

# ----- 1. Lingering (keeps user services/cron/podman running without login) -
if loginctl show-user "$(id -un)" -p Linger 2>/dev/null | grep -q "yes"; then
  log "Lingering already enabled."
elif loginctl enable-linger 2>/dev/null; then
  log "Enabled lingering for $(id -un)."
else
  warn "Could not enable lingering for $(id -un) (needs admin privileges)." \
       "Ask an admin to run: sudo loginctl enable-linger $(id -un)" \
       "Without it, containers/cron/systemd --user units may not survive a reboot."
fi

# systemd --user needs these; they're normally set in a real login session,
# but may be missing when this script runs non-interactively (e.g. over ssh
# before lingering has kicked in).
: "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
: "${DBUS_SESSION_BUS_ADDRESS:=unix:path=${XDG_RUNTIME_DIR}/bus}"
export XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS

# ----- 2. Clone/update both repos -------------------------------------------
mkdir -p "$APPS_DIR" "$MVP_DATA_DIR" "$MORPH_DATA_DIR" \
  "${MVP_DATA_DIR}/build-a" "${MVP_DATA_DIR}/build-b" "${MVP_DATA_DIR}/state" \
  "${APPS_DIR}/bin"

# ----- 1b. Install oras (cron-deploy.sh pulls GHCR artifacts with it) -------
ORAS_BIN="${APPS_DIR}/bin/oras"
if [ ! -x "$ORAS_BIN" ]; then
  log "Installing oras v${ORAS_VERSION}..."
  case "$(uname -m)" in
    x86_64) ORAS_ARCH=amd64 ;;
    aarch64|arm64) ORAS_ARCH=arm64 ;;
    *) die "Unsupported architecture for oras: $(uname -m)" ;;
  esac
  ORAS_TMP="$(mktemp -d)"
  curl -fsSL \
    "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_${ORAS_ARCH}.tar.gz" \
    | tar -xz -C "$ORAS_TMP" oras
  install -m 0755 "${ORAS_TMP}/oras" "$ORAS_BIN"
  rm -rf "$ORAS_TMP"
else
  log "oras already installed at ${ORAS_BIN}."
fi

clone_or_update() {
  local url="$1" dir="$2" branch="$3"
  if [ -d "${dir}/.git" ]; then
    log "Updating $(basename "$dir")..."
    git -C "$dir" fetch --depth 1 origin "$branch"
    git -C "$dir" checkout "$branch"
    git -C "$dir" reset --hard "origin/${branch}"
  else
    log "Cloning $(basename "$dir")..."
    git clone --branch "$branch" --depth 1 "$url" "$dir"
  fi
}
clone_or_update "$MVP_REPO_URL" "$MVP_DIR" "$MVP_BRANCH"
clone_or_update "$MORPH_REPO_URL" "$MORPH_DIR" "$MORPH_BRANCH"

chmod +x "${MVP_DIR}/deploy/cron-deploy.sh" "${MORPH_DIR}/deploy/cron-deploy.sh"

# ----- 3. Per-app env files (kept outside the repo checkouts) --------------
cat > "$MVP_ENV_FILE" <<EOF
# Managed by setup-server.sh — safe to hand-edit; not touched by git pull.
REGISTRY=${MVP_REGISTRY}
CORPORA="${MVP_CORPORA}"
TAG=${TAG}
ORAS_BIN=${ORAS_BIN}
CONTAINER_CMD=${CONTAINER_CMD}
COMPOSE_PROJECT=mvp
SERVE_PORT=${MVP_SERVE_PORT}
SERVE_CTR=mvp-serve
BUILD_DIR=${MVP_DATA_DIR}/build
STATE_DIR=${MVP_DATA_DIR}/state
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

chmod 600 "$MVP_ENV_FILE" "$MORPH_ENV_FILE"

# ----- 4. Cron entries -------------------------------------------------------
MVP_CRON_MARK="# perseus-deploy: mvp"
MORPH_CRON_MARK="# perseus-deploy: morph"
MVP_CRON_LINE="${CRON_SCHEDULE} ENV_FILE=${MVP_ENV_FILE} /usr/bin/flock -n ${MVP_DATA_DIR}/deploy.lock ${MVP_DIR}/deploy/cron-deploy.sh >> ${MVP_DATA_DIR}/deploy.log 2>&1 ${MVP_CRON_MARK}"
MORPH_CRON_LINE="${CRON_SCHEDULE} ENV_FILE=${MORPH_ENV_FILE} /usr/bin/flock -n ${MORPH_DATA_DIR}/deploy.lock ${MORPH_DIR}/deploy/cron-deploy.sh >> ${MORPH_DATA_DIR}/deploy.log 2>&1 ${MORPH_CRON_MARK}"

EXISTING_CRON="$(crontab -l 2>/dev/null || true)"
NEW_CRON="$EXISTING_CRON"
if ! grep -qF "$MVP_CRON_MARK" <<<"$EXISTING_CRON"; then
  NEW_CRON="$(printf '%s\n%s\n' "$NEW_CRON" "$MVP_CRON_LINE")"
fi
if ! grep -qF "$MORPH_CRON_MARK" <<<"$EXISTING_CRON"; then
  NEW_CRON="$(printf '%s\n%s\n' "$NEW_CRON" "$MORPH_CRON_LINE")"
fi
if [ "$NEW_CRON" != "$EXISTING_CRON" ]; then
  log "Installing crontab entries for $(id -un)..."
  printf '%s\n' "$NEW_CRON" | sed '/^$/d' | crontab -
fi

# ----- 5. Enable podman-restart (user unit) ----------------------------------
log "Enabling podman-restart.service (restarts containers after reboot)..."
if ! systemctl --user enable --now podman-restart.service 2>/dev/null; then
  warn "Could not enable podman-restart.service --user unit." \
       "Containers may not come back automatically after a reboot until lingering is enabled (see step 1)."
fi

# ----- 6. First deploy --------------------------------------------------------
log "Running initial deploy of pdl-morph-server..."
ENV_FILE="$MORPH_ENV_FILE" "${MORPH_DIR}/deploy/cron-deploy.sh"

log "Running initial deploy of MinimumViablePerseus..."
ENV_FILE="$MVP_ENV_FILE" "${MVP_DIR}/deploy/cron-deploy.sh"

log "Done."
cat <<SUMMARY

--------------------------------------------------------------------
Setup complete.

  pdl-morph-server:        http://${PUBLIC_HOST}:${MORPH_SERVE_PORT}
  MinimumViablePerseus:     http://${PUBLIC_HOST}:${MVP_SERVE_PORT}

  MVP's pages are no longer built here — they're frozen in CI and this
  host only pulls the finished artifacts (see cron-deploy.sh). MORPH_URL
  is baked in at that CI build step, not by this script:
    MORPH_URL to set as the "MORPH_URL" repo variable in
    MinimumViablePerseus's GitHub Actions settings: ${MORPH_URL}

Config lives in:
  ${MVP_ENV_FILE}
  ${MORPH_ENV_FILE}

Logs:
  ${MVP_DATA_DIR}/deploy.log
  ${MORPH_DATA_DIR}/deploy.log

Cron (as $(id -un)):
  ${MVP_CRON_LINE}
  ${MORPH_CRON_LINE}

Remaining manual steps, if not already done:
  1. Make sure every GHCR package this host pulls is public (or set
     GHCR_USER/GHCR_TOKEN in the env files above for private pulls) —
     each is created on its first CI push, so these may not exist yet:
       https://github.com/orgs/perseusdlcode/packages/container/pdl-morph-server/settings
       https://github.com/orgs/perseusdlcode/packages/container/mvp-corpus-greeklit/settings
       https://github.com/orgs/perseusdlcode/packages/container/mvp-corpus-greeklit-manifest/settings
       https://github.com/orgs/perseusdlcode/packages/container/mvp-corpus-latinlit/settings
       https://github.com/orgs/perseusdlcode/packages/container/mvp-corpus-latinlit-manifest/settings
       https://github.com/orgs/perseusdlcode/packages/container/mvp-corpus-first1kgreek/settings
       https://github.com/orgs/perseusdlcode/packages/container/mvp-corpus-first1kgreek-manifest/settings
       https://github.com/orgs/perseusdlcode/packages/container/mvp-global/settings
  2. If MORPH_URL should go through a reverse proxy / TLS terminator
     instead of a bare port, set it as the "MORPH_URL" repo variable in
     MinimumViablePerseus's GitHub Actions settings (Settings > Secrets
     and variables > Actions > Variables) — this script no longer writes
     it anywhere on this host, since it's read at CI build time, not
     serve time.
  3. If lingering couldn't be enabled above, ask an admin to run:
       sudo loginctl enable-linger $(id -un)
     (one-time, requires root — everything else in this script does not).
  4. Reboot once to confirm containers and cron come back on their own:
     `podman ps` should show mvp-serve and morph-serve running within a
     minute or two of boot.
--------------------------------------------------------------------
SUMMARY
