# `loft-ctl`

> Fleet-aware service control — start, stop, rebuild, health-check, or update the services on this host without remembering `docker compose` paths.

## Overview

[`loft-ctl`](../../loft-ctl) is the day-to-day control script for any host in The Loft. It reads `hosts/$(hostname)/host.conf`, knows which services run here, and translates short commands like `loft-ctl rebuild --all` into the correct `docker compose -f <base> -f <override>` invocations via the shared [`common.sh`](common-sh.md) helpers. It also runs URL health checks across three tiers (local / lan / ssl) for the services it just touched.

`loft-ctl` is aliased into the shell from [`bashrc.d`](../../bashrc.d) so it's available everywhere as `loft-ctl` — no need to `cd /srv/the-loft`.

## Architecture

### Invocation flow

1. `loft-ctl` is invoked as the calling user (normally `adminhabl`, or anyone in the `docker` group).
2. The script sources `hosts/$(hostname)/host.conf` to learn `SERVICES`, `HEALTH_URLS`, etc.
3. For commands that touch Docker (`start`, `stop`, `rebuild`, `health`, `update`), it auto-elevates to `adminhabl` via `su -` — so only `adminhabl` actually runs `docker`.
4. For `update`, the **`git fetch` / `checkout` / `pull --ff-only`** runs **as the calling user** (who has the SSH keys for the repo), then `loft-ctl` re-execs as `adminhabl` with `--no-pull` appended so the elevated session skips git entirely. This keeps SSH agent forwarding sane and avoids needing `adminhabl` to own a deploy key.
5. The post-elevation pass parses targets and runs the requested operation per service via the `compose_args_for` / `check_containers` / `check_web_ui` helpers in [`common.sh`](common-sh.md).

### Commands

| Command | What it does | Underlying compose |
|---------|-------------|--------------------|
| `start` | Bring services up in the background | `docker compose <args> up -d` |
| `stop` | Bring services down | `docker compose <args> down` (no `-v`) |
| `rebuild` | Down, pull, up with `--build` | `down` → `pull` → `up -d --build` |
| `health` | Container running check + URL checks across all configured tiers | `docker compose <args> ps` + `curl` |
| `update` | Pull repo (as user), elevate, rebuild + health | `git pull` → rebuild → health |

`docker compose down -v` is **never** issued by `loft-ctl` — see [`DEBUG.md`](../../DEBUG.md) and [pupyrus](../services/pupyrus.md) for which volumes carry irreplaceable data.

### Targeting

| Argument | Meaning |
|----------|---------|
| `<service> [<service> ...]` | Target named services (must be in `SERVICES`) |
| `--all` | Expand to every service in `SERVICES` |
| (none, for `health`) | Defaults to `--all` |
| (none, otherwise) | Prints usage and exits |

`health` is the only command that defaults to `--all`. Mutating commands always require an explicit target — typing `loft-ctl stop` is a no-op, not "stop everything", so a tab-completion mistake can't take the host down.

### Update-only flags

| Flag | Effect |
|------|--------|
| `--branch <name>` | Checkout `<name>` before `pull --ff-only` (default: `main`) |
| `--no-pull` | Skip the git step entirely (already up to date / pulled by hand) |

Both flags are only meaningful with `update`. They're harmless if passed to other commands but they don't do anything.

## Configuration

`loft-ctl` reads:

| Source | Purpose |
|--------|---------|
| `hosts/$(hostname)/host.conf` | `SERVICES`, `SERVICE_ENDPOINTS`, `SERVICE_ENDPOINTS_WARN`, `HEALTH_URLS`, `HEALTH_URLS_WARN` |
| `services/<service>/docker-compose.yml` | Compose definition (must exist) |
| `hosts/$(hostname)/overrides/<service>/docker-compose.override.yml` | Optional per-host override, merged via `-f` |
| `control-plane/common.sh` | `compose_args_for`, `check_containers`, `check_web_ui` |

### Health check tiers

Health URL labels are space-separated values in `SERVICE_ENDPOINTS[<service>]`. Each label has up to three tiered URLs in `HEALTH_URLS["<label>:<tier>"]`:

| Tier | What it checks | Typical URL |
|------|---------------|-------------|
| `local` | Direct host port | `http://localhost:7878` |
| `lan` | LAN HTTP fallback via [mushr](../services/mushr.md)'s Caddy + dnsmasq | `http://radarr.space-needle` |
| `ssl` | HTTPS via Caddy with real Let's Encrypt certs | `https://radarr.loft.hsimah.com` |

Warn-only labels live in `SERVICE_ENDPOINTS_WARN[<service>]` / `HEALTH_URLS_WARN[<label>:<tier>]` — used for VPN-dependent services (transmission, slskd) where a `000` response means "VPN is down" rather than "service is broken".

### Privilege model

`loft-ctl`'s auto-elevation runs `exec su - adminhabl -c "<repo>/loft-ctl <quoted-args>"`. That means:

- The interactive user types the **adminhabl password** once per session (not their own sudo password). No sudoers entry is needed for non-admin users to drive docker — `adminhabl` is the docker-capable account.
- After elevation, `$PWD` is `adminhabl`'s home (`su -`), not the calling user's cwd. `loft-ctl` re-resolves `REPO_DIR` from its own `$0` so paths still work.
- For `update`, the git pull happens **before** elevation, so the user's SSH key (in `ssh-agent` or `~/.ssh/`) is what authenticates to GitHub. `adminhabl` doesn't need a deploy key.

## Operations

```bash
loft-ctl                              # usage + this host's services list

# Lifecycle
loft-ctl start pawpcorn stellarr
loft-ctl stop --all
loft-ctl rebuild howlr                # down + pull + up + healthcheck for one service
loft-ctl rebuild --all                # rebuild every service on this host

# Health
loft-ctl health                       # implicit --all
loft-ctl health stellarr pupyrus

# Update — git pull + rebuild + healthcheck
loft-ctl update --all
loft-ctl update --branch docs/per-script-pages pawst   # try a feature branch
loft-ctl update --no-pull mushr       # rebuild without touching git
```

### Wait, what happened to my password?

You normally log in as `adminhabl`, so `loft-ctl` runs docker directly with no prompt. If you run it as some *other* non-adminhabl user, it prints `Elevating to adminhabl...` and prompts for the **adminhabl** password (set during `setup.sh` finalization via `passwd adminhabl`), then re-execs and proceeds.

### Picking up new compose / config

| Change | Command | Notes |
|--------|---------|-------|
| Hot-reload of bind-mounted config (e.g. Homepage YAML) | service auto-reloads | No `loft-ctl` needed |
| `docker-compose.yml` edit | `loft-ctl rebuild <service>` | New containers picked up |
| New image tag in compose | `loft-ctl rebuild <service>` | Pulls latest image |
| `.env` change | `loft-ctl rebuild <service>` | Env is only read on `up` |
| Per-host override added | `loft-ctl rebuild <service>` | New `-f` flag merged in |
| Adding/removing a service in `SERVICES` | `sudo bash setup.sh` | `loft-ctl --all` is computed from `SERVICES` |

## Related

- [`setup.sh`](setup.md) — provisions the host so `loft-ctl` works at all
- [`common.sh`](common-sh.md) — provides `compose_args_for`, `check_containers`, `check_web_ui`
- Service pages — every entry in `SERVICES` has one: [houstn](../services/houstn.md), [howlr](../services/howlr.md), [mushr](../services/mushr.md), [pawpcorn](../services/pawpcorn.md), [pawst](../services/pawst.md), [pupyrus](../services/pupyrus.md), [snoot](../services/snoot.md), [stellarr](../services/stellarr.md)
- Root [`DEBUG.md`](../../DEBUG.md) — fleet-wide quick reference, container name table, exit codes

## Debug & Troubleshooting

### "No host config found at hosts/<hostname>/host.conf"

**Cause:** The host's hostname doesn't match any directory under `hosts/`. Same root cause as in [`setup.sh`](setup.md#no-host-config-found-at-hostshostnamehostconf).

**Fix:**

```bash
hostname && ls hosts/
sudo hostnamectl set-hostname <expected>
```

### "Unknown service: foo"

**Cause:** `foo` isn't in `SERVICES` for this host. `loft-ctl` deliberately won't operate on services not declared in `host.conf` even if their compose files exist in `services/`.

**Fix:** Add the service to `SERVICES` in `hosts/$(hostname)/host.conf`, then re-run `sudo bash setup.sh` so directories, cron, and overrides are materialized.

### "Elevating to adminhabl..." then prompt loops

**Cause:** `adminhabl` has no password, or password is wrong.

**Fix:**

```bash
sudo passwd adminhabl                 # as a sudo-capable user
```

You log in as `adminhabl`, which has sudo. If sudo is somehow broken, recover via single-user mode / physical console.

### Health check reports `WARNING` for transmission/slskd while everything else is green

**Cause:** Those endpoints sit in `SERVICE_ENDPOINTS_WARN` / `HEALTH_URLS_WARN` because they're VPN-dependent. The VPN is down; the rest of stellarr is fine. See [stellarr](../services/stellarr.md).

**Fix:**

```bash
sudo docker logs stellarr-vpn --tail 20
sudo docker restart stellarr-vpn
loft-ctl health stellarr              # re-check after VPN reconnects (~30s)
```

### `loft-ctl rebuild` succeeds but the health check fails on `ssl` tier

**Cause:** [mushr](../services/mushr.md)'s Caddy may not have a cert for that subdomain yet (first deploy), or DNS-01 challenge is failing. The container is up — TLS just isn't ready yet.

**Fix:**

```bash
sudo docker logs mushr --tail 30      # ACME / DNS-01 progress
loft-ctl health <service>             # retry in a minute
```

If certs are persistently failing, see the Caddy section in [mushr](../services/mushr.md) and the `Nuclear option: reset Caddy TLS state` recipe in [`DEBUG.md`](../../DEBUG.md).

### `loft-ctl update --all` only pulled git but didn't rebuild

**Cause:** The git pull failed mid-script (e.g. merge conflict from uncommitted local changes). `loft-ctl` exits with `Git update failed` and skips the rebuild rather than rebuilding stale code.

**Fix:**

```bash
git -C /srv/the-loft status            # see the conflict
git -C /srv/the-loft stash             # or commit / discard
loft-ctl update --all
```

### `loft-ctl health` shows `--all` but I only have 3 services

**Cause:** `SERVICES` in `host.conf` lists services this host doesn't actually run, or `setup.sh` hasn't been re-run since you added one.

**Fix:** Reconcile `SERVICES` with what's actually deployed:

```bash
sudo docker ps --format '{{.Names}}'                   # what's running
cat hosts/$(hostname)/host.conf | grep -A 5 SERVICES   # what's declared
sudo bash setup.sh                                      # deploy any missing
```

### After `update`, containers are running but new code isn't loaded

**Cause:** `rebuild` recreates containers, but services with bind-mounted config (Homepage, Caddyfile, dnsmasq.conf) sometimes hot-reload on file change and beat the rebuild — or the image cache is stale.

**Fix:** Force-pull and rebuild:

```bash
loft-ctl rebuild <service>            # full down + pull + up --build
```

If a service uses a Dockerfile (`mushr`), the rebuild step uses `--build` and picks up `Dockerfile.*` changes automatically.
