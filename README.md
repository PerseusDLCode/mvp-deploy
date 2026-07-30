# Combined deployment: MinimumViablePerseus + pdl-morph-server

Runs both apps on one CentOS host via rootless podman, each still deployed
independently by its own `deploy/cron-deploy.sh` (polling GHCR every 10
minutes), but provisioned together so containers survive a reboot.

MVP itself no longer builds anything on this host. Its ~200,000 pages are
frozen in CI, one corpus at a time and in parallel (see
`MinimumViablePerseus`'s `build-corpus.yml`/`build-global.yml`), and pushed
to GHCR as plain OCI artifacts — not runnable images. This host's
`cron-deploy.sh` just polls those artifacts' digests and, when any changed,
pulls and extracts them straight into the live blue-green directory; no
container here ever runs `mvp-build`. `pdl-morph-server` is unaffected by
any of this and still ships as a single polled image, built the old way.

## Why they don't need to share a container network

`MORPH_URL` is not fetched server-side during MVP's build — it's baked
into the rendered HTML (by CI now, not this host) and hit by the visitor's
*browser*. So it must stay a public URL (`https://your-host:8081/morph` or
a reverse-proxied path), never a container-internal address. That means
the two apps only need to coexist on the same host, not the same podman
network.

## What was changed in each repo

- **MinimumViablePerseus/deploy/cron-deploy.sh** — now sources an
  `ENV_FILE` (default: next to the script) like pdl-morph-server's script
  already did, and the podman/docker compose project name is now
  configurable via `COMPOSE_PROJECT` (was hardcoded to `perseus`).
- **pdl-morph-server/deploy/cron-deploy.sh** — fixed `ENV_FILE` to default
  to a path relative to the script, not the cron job's CWD (previously
  fragile under cron).
- **Both `deploy/compose.yaml`** — `serve` now has an explicit
  `container_name` (`mvp-serve` / `morph-serve` by default) so they're
  unambiguous in `podman ps` regardless of compose project naming.

These were needed because both scripts previously defaulted to the same
compose project name (`perseus`). Two compose projects with the same name
on one host will collide on container names — the reason to keep them
apart is naming hygiene, not networking.

- **MinimumViablePerseus/deploy/cron-deploy.sh** (again) — rewritten to
  pull and extract pre-built OCI artifacts (`oras manifest fetch`/`pull`)
  instead of pulling and running a build image. Tracks one digest per
  artifact under `STATE_DIR` rather than a single `STATE_FILE`, and fully
  repopulates the inactive blue-green slot from every artifact on any
  change, rather than patching in place — see the script's own header
  for why.
- **MinimumViablePerseus/deploy/compose.yaml** — dropped the `build`
  service entirely; only `serve` (nginx) remains, since no build ever
  runs on this host anymore.
- **setup-server.sh** — installs the `oras` CLI to `~/apps/bin/oras`
  (needed for the above), and `mvp.env` no longer carries `IMAGE`/
  `IMAGE_TAG`/`BUILD_CTR` or `MORPH_URL` — the first three don't apply to
  artifact-only pulls, and `MORPH_URL` is now read at CI build time (as
  the `MORPH_URL` GitHub Actions repo variable on `MinimumViablePerseus`),
  not by anything on this host.

## Server setup

Run this logged in **as the `perseus` user directly** — not root, not
`sudo`. It only ever touches that user's own files, crontab, and
`systemctl --user` units.

```bash
PUBLIC_HOST=perseus.example.org ./setup-server.sh
```

See the comment block at the top of `setup-server.sh` for every variable
it accepts (ports, image tag, repo URLs/branches, GHCR credentials, etc).
It is idempotent — re-run it any time to pick up new config.

It assumes podman + podman-compose + zstd are already installed (zstd
extracts the `.tar.zst` artifacts `cron-deploy.sh` pulls — a one-time root
step, e.g. `dnf install -y zstd`), this account already exists, crond is
already running, and the two service ports are opened for you externally
— none of that is this script's job. It
provisions:

1. `loginctl enable-linger` for itself — required for rootless podman
   containers, cron jobs, and `systemctl --user` units to keep running
   (and come back after reboot) without an active login session. If this
   account isn't allowed to self-service that (`enable-linger` typically
   needs elevated privileges), the script warns instead of failing — see
   "Remaining manual steps" below.
2. Clones of both repos under `~/apps/`.
3. Env files (`mvp.env`, `morph.env`) **outside** the repo checkouts, so
   `git pull`/re-cloning never clobbers local config. `morph.env` still
   carries image/tag config (that app is unaffected by MVP's move to
   pre-built artifacts); `mvp.env` instead carries the GHCR registry/corpus
   list `cron-deploy.sh` pulls from. Both carry compose project name and
   state/lock/log paths.
4. Two cron entries (one per app, each under its own `flock`), pointed at
   those env files via `ENV_FILE=...`.
5. `systemctl --user enable --now podman-restart.service` — this is what
   actually restarts `unless-stopped` containers after a reboot; without
   it (and without lingering, see step 1), rootless podman has no daemon
   watching for the box coming back up.
6. An immediate first deploy of both apps, so you get running containers
   right away instead of waiting for the next cron tick.

## Verifying reboot survival

After setup, reboot the box once and confirm, still logged in as
`perseus`:

```bash
podman ps                                  # mvp-serve and morph-serve
crontab -l                                 # both cron lines still present
systemctl --user is-active podman-restart.service
```

## Remaining manual steps

- If the script warned it couldn't enable lingering, ask an admin to run
  (one-time, requires root): `sudo loginctl enable-linger perseus`.
- Make every GHCR package this host pulls public (or set `GHCR_USER`/
  `GHCR_TOKEN` in the generated env files for private pulls) — links are
  printed at the end of `setup-server.sh`. MVP's packages
  (`mvp-corpus-<name>`, `mvp-corpus-<name>-manifest` for each corpus, and
  `mvp-global`) are each created on their first CI push, so they may not
  exist yet the first time you run this.
- If `MORPH_URL` should go through a reverse proxy/TLS instead of a bare
  port, set it as the `MORPH_URL` repo variable in `MinimumViablePerseus`'s
  GitHub Actions settings (Settings > Secrets and variables > Actions >
  Variables) — `setup-server.sh` only prints the value to use, it no
  longer writes it anywhere on this host.
