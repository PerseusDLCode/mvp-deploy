# Combined deployment: MinimumViablePerseus + pdl-morph-server

Runs both apps on one CentOS host via rootless podman, each still deployed
independently by its own `deploy/cron-deploy.sh` (polling GHCR every 10
minutes), but provisioned together so containers survive a reboot.

## Why they don't need to share a container network

`MORPH_URL` is not fetched server-side during the MVP build — it's baked
into the rendered HTML and hit by the visitor's *browser*. So it must stay
a public URL (`https://your-host:8081/morph` or a reverse-proxied path),
never a container-internal address. That means the two apps only need to
coexist on the same host, not the same podman network.

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

## Server setup

```bash
sudo -E PUBLIC_HOST=perseus.example.org ./setup-server.sh
```

See the comment block at the top of `setup-server.sh` for every variable
it accepts (ports, image tag, repo URLs/branches, GHCR credentials, etc).
It is idempotent — re-run it any time to pick up new config.

It assumes podman + podman-compose are already installed, the `perseus`
service user already exists, and the two service ports are opened for you
externally — none of that is this script's job. It provisions:

1. `loginctl enable-linger perseus` — required for rootless podman
   containers, the user's cron jobs, and `systemctl --user` units to keep
   running (and come back after reboot) without an active login session.
2. Clones of both repos under `/home/perseus/apps/`.
3. Env files (`mvp.env`, `morph.env`) **outside** the repo checkouts, so
   `git pull`/re-cloning never clobbers local config — ports, image tag,
   compose project name, `MORPH_URL`, and state/lock/log paths all live
   there.
4. Two cron entries (one per app, each under its own `flock`), pointed at
   those env files via `ENV_FILE=...`.
5. `systemctl enable --now crond` and
   `systemctl --user enable --now podman-restart.service` — the latter is
   what actually restarts `unless-stopped` containers after a reboot;
   without it, rootless podman has no daemon watching for the box coming
   back up.
6. An immediate first deploy of both apps, so you get running containers
   right away instead of waiting for the next cron tick.

## Verifying reboot survival

After setup, reboot the box once and confirm:

```bash
sudo -u perseus podman ps    # should show mvp-serve and morph-serve
sudo -u perseus crontab -l   # both cron lines still present
systemctl is-active crond
sudo -u perseus XDG_RUNTIME_DIR=/run/user/$(id -u perseus) \
  systemctl --user is-active podman-restart.service
```

## Remaining manual steps

- Make the GHCR packages public (or set `GHCR_USER`/`GHCR_TOKEN` in the
  generated env files for private pulls) — links are printed at the end of
  `setup-server.sh`.
- If `MORPH_URL` should go through a reverse proxy/TLS instead of a bare
  port, set `MORPH_URL` directly when invoking the setup script, or edit
  `mvp.env` afterward (cron picks it up on the next tick).
