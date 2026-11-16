# Combined deployment: MinimumViablePerseus + pdl-morph-server + perseus-redirect

Runs the three apps on one CentOS host via rootless podman. Each is still
deployed independently by its own `deploy/cron-deploy.sh` (polling GHCR
every 10 minutes), but they're provisioned together so containers survive a
reboot.

- **MinimumViablePerseus (MVP):** the static site.
- **pdl-morph-server:** the morphology page.
- **perseus-redirect:** answers the legacy Perseus (hopper) URLs with
  redirects into MVP and the morph page.

**Already running MVP and the morph server?** You don't need to re-run
`setup-server.sh`; see
[Adding perseus-redirect to an existing host](#adding-perseus-redirect-to-an-existing-host).

MVP itself no longer builds anything on this host. Its ~200,000 pages are
frozen in CI, one corpus at a time and in parallel (see
`MinimumViablePerseus`'s `build-corpus.yml`/`build-global.yml`), and pushed
to GHCR as plain OCI artifacts — not runnable images. This host's
`cron-deploy.sh` just polls those artifacts' digests and, when any changed,
pulls and extracts them into a staging directory and swaps it into place as
the single live directory; no container here ever runs `mvp-build`.
`pdl-morph-server` is unaffected by any of this and still ships as a single
polled image, built the old way.

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
  populates a staging directory from every artifact on any change (rather
  than patching in place), then swaps it into place as the single live
  directory — see the script's own header for why.
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
It is idempotent — re-run it any time to pick up new config. Note that a
re-run regenerates `mvp.env` and `morph.env` from the variables you pass
(hand edits to those two are lost), and redeploys both apps.

On a fresh host it finishes by running `setup-redirect.sh`, so pass the
redirect server's settings too:

```bash
PUBLIC_HOST=perseus.example.org \
REDIRECT_MVP_ORIGIN=https://www.perseus.tufts.edu \
REDIRECT_TRUSTED_PROXIES=10.0.0.0/8 \
./setup-server.sh
```

`REDIRECT_MVP_ORIGIN` defaults to `https://$PUBLIC_HOST`. `SKIP_REDIRECT=1`
leaves the redirect server out. If its setup fails (say its image isn't on
GHCR yet), MVP and the morph server are unaffected; fix the cause and run
`./setup-redirect.sh`. See
[Adding perseus-redirect to an existing host](#adding-perseus-redirect-to-an-existing-host)
for prerequisites and the load balancer step.

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

## Adding perseus-redirect to an existing host

`setup-redirect.sh` adds perseus-redirect next to a running MVP and morph
server. It only touches perseus-redirect's own files:
`~/apps/perseus-redirect/`, `~/apps/redirect.env`, `~/apps/redirect-data/`
and one new cron line. It doesn't rewrite `mvp.env` or `morph.env`, and it
doesn't redeploy MVP or the morph server.

### Before you start

1. **The image exists.** Pushing perseus-redirect's `main` branch to
   `github.com/PerseusDLCode/perseus-redirect` makes CI publish
   `ghcr.io/perseusdlcode/perseus-redirect:latest`. Then make the package
   public at
   https://github.com/orgs/perseusdlcode/packages/container/perseus-redirect/settings,
   or pass `GHCR_USER`/`GHCR_TOKEN`.
2. **MVP publishes its manifest.** From the host, this should print a JSON
   object starting with `{"schema_version": 1`:

   ```bash
   curl -fsS https://<public MVP origin>/cts-urns.json | head -c 100
   ```

   Until it does, the redirect server answers reading-view links with 503.
3. **You know the load balancer's address,** as an IP or CIDR. That lets
   the server rate-limit per visitor instead of treating the load balancer
   as one client.
4. **Port 8090 is free,** or pick another with `REDIRECT_SERVE_PORT`.

### Install

As the `perseus` user, from this repo's checkout:

```bash
git pull
REDIRECT_MVP_ORIGIN=https://www.perseus.tufts.edu \
REDIRECT_TRUSTED_PROXIES=10.0.0.0/8 \
./setup-redirect.sh
```

`REDIRECT_MVP_ORIGIN` is where redirects point, and where the server
fetches `/cts-urns.json`. Optional settings:
- `MORPH_URL`: where legacy morph links go. The default is
  `REDIRECT_MVP_ORIGIN/morph`.
- `REDIRECT_SERVE_PORT`, `REDIRECT_IMAGE_TAG`, and the others listed in the
  script's header.

The script clones the repo, writes `~/apps/redirect.env`, adds the cron
entry, deploys, waits for `/healthz`, and prints two test `curl`s. It's safe
to re-run.

### Check it

```bash
curl -s http://127.0.0.1:8090/healthz      # "ok": true, manifest version count
curl -sI 'http://127.0.0.1:8090/hopper/text?doc=Perseus:text:1999.01.0133:book=1'
                                            # 302, Location: <MVP>/urn:cts:greekLit:tlg0012...
curl -sI 'http://127.0.0.1:8090/hopper/morph?l=lo/gos&la=greek'
                                            # 302, Location: <MORPH_URL>?language=grc&word=lo%2Fgos
podman ps                                   # redirect-serve, (healthy)
```

### Go live: load balancer

Nothing reaches the server until the load balancer sends it traffic. This
step is for Tufts IT.

- **The legacy hostname is separate from MVP's:** route all of it to
  `<host>:8090`.
- **It's the same hostname:** route the legacy paths `/hopper/`, `/cgi-bin/`
  and `/texts/urn:` to `<host>:8090`, plus `/citations/` if it isn't used by
  MVP. Everything else goes to MVP.
- **Either way:** keep the new morph page (`/morph`, `/morph/…`) routed to
  the morph server, ahead of any catch-all to this one. If it ever reaches
  perseus-redirect anyway, the server answers 404 instead of looping.

### Day to day

- **Settings:** edit `~/apps/redirect.env`. The next cron tick (within 10
  minutes) recreates the container with the new settings. Re-running
  `setup-redirect.sh` keeps your edits; `REDIRECT_REWRITE_ENV=1`
  regenerates the file from scratch.
- **Switch to permanent redirects:** set `REDIRECT_STATUS=301` once the
  replayed coverage looks right (see perseus-redirect's README). Browsers
  cache 301s, so do this last.
- **New spreadsheet data or code:** push perseus-redirect's `main`. This
  host picks up the new image within 10 minutes.
- **Logs:**
  - `~/apps/redirect-data/deploy.log` has the deploys.
  - `podman logs redirect-serve` has a traffic summary every 15 minutes,
    including the most-requested links that didn't resolve.
- **Remove it:**

  ```bash
  crontab -l | grep -v 'perseus-deploy: redirect' | crontab -
  podman rm -f redirect-serve
  ```

  Then point the load balancer back.

## Verifying reboot survival

After setup, reboot the box once and confirm, still logged in as
`perseus`:

```bash
podman ps                                  # mvp-serve, morph-serve and redirect-serve
crontab -l                                 # all three cron lines still present
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
