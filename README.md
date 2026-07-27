# the-loft

Fleet configuration for The Loft — a mono-repo managing all hosts with shared service definitions, per-host configuration, and a unified setup/control-plane.

For deep dives, see [`docs/`](docs/README.md).

## Fleet

| Host | Hardware | Role |
|------|----------|------|
| [space-needle](docs/hosts/space-needle.md) | Minisforum MS-01 (i9, x86_64) | Primary server — runs everything |
| [viking](docs/hosts/viking.md) | Raspberry Pi 3 B+ | Snapcast client + per-host metrics |
| [fjord](docs/hosts/fjord.md) | Raspberry Pi 3 B+ | Per-host metrics (awaiting cyberdeck repurpose) |
| [calavera](docs/hosts/calavera.md) | Surface Pro 2 (touchscreen) | Always-on Snapcast client + i3 desktop |

## Services

| Service | Purpose |
|---------|---------|
| [houstn](docs/services/houstn.md) | Fleet observability — Beszel, Uptime Kuma, Homepage, Glances |
| [howlr](docs/services/howlr.md) | Music Assistant + Snapcast — whole-home audio |
| [mushr](docs/services/mushr.md) | Caddy reverse proxy + Cloudflare Tunnel + LAN DNS |
| [pawpcorn](docs/services/pawpcorn.md) | Plex Media Server |
| [pawst](docs/services/pawst.md) | Static blogs `hbla.ke` and `hsimah.com` |
| [pupyrus](docs/services/pupyrus.md) | WordPress (+ MariaDB + Redis) |
| [snoot](docs/services/snoot.md) | Beszel agent on every host |
| [stellarr](docs/services/stellarr.md) | *arr stack + Transmission + slskd, behind NordVPN |

## Image pinning

Every container image is pinned to an explicit version. Nothing runs on `latest`.
Upgrades are therefore reviewable git commits rather than an untracked
`docker compose pull`, and `git revert` is a real rollback path.

To bump a service: edit the tag in `services/<name>/docker-compose.yml`, commit,
then on the host run `loft-ctl update <name>`. Because `loft-ctl rebuild` takes
the service `down` before it pulls, warm the image first to shorten the outage:

```bash
sudo docker compose -f services/<name>/docker-compose.yml pull
loft-ctl update <name>
```

Rolling back is `git revert` + the same command — the previous image is still on
disk under its own tag, so no re-download is needed.

Four images are pinned with caveats worth knowing about:

| Image | Pin | Why |
|-------|-----|-----|
| `ivdata/snapclient` | digest `sha256:0270a64f…` | Publishes **no** version tags — only `latest` (2023-03-25) and `alpine` (2022-06-06). A digest is the only reproducible pin. Upstream looks abandoned; worth replacing. |
| `ghcr.io/bubuntux/nordvpn` | `v3.12.3` | Repo **archived** (read-only since 2025-11-22). `v3.12.3` is the final tag and will never be updated. Needs a maintained replacement. |
| `lscr.io/linuxserver/lidarr` | `nightly` *(unpinned)* | Nightly's database schema is ahead of stable (`3.1.0.4875-ls36`); pinning to stable is a downgrade Lidarr will refuse. Pin to the exact nightly build currently running instead — see the comment in the compose file. |
| `louislam/uptime-kuma` | `1.23.17` | Deliberately held on 1.x. Kuma 2.x migrates the monitor DB on first start with no rollback. |

`mariadb` (held on 12.2.x) and `redis` (held on 7.x) are likewise pinned below
their newest releases — both sit under a live WordPress install, so major
version moves belong in their own change, not a pinning pass.

## How it's organized

```
hosts/<hostname>/host.conf          # Per-host manifest (services, storage, health checks)
hosts/<hostname>/overrides/...      # Per-host compose overrides
hosts/<hostname>/bootstrap          # Optional host-specific provisioning, sourced by setup.sh if present
hosts/<hostname>/i3/...             # Optional i3 desktop config (deployed by setup.sh when I3_ENABLED)
services/<name>/docker-compose.yml  # Shared service definition
services/<name>/.env.example        # Secret template
control-plane/                      # Shared scripts (common.sh, deploy-pull.sh, ...)
setup.sh                            # Idempotent host provisioner
loft-ctl                            # Day-to-day fleet control
```

Services are defined once and customized per host via Docker Compose's native merge from `hosts/<hostname>/overrides/<service>/docker-compose.override.yml`. Fleet-wide containers prefer Compose **profiles** inside an existing service (e.g. `houstn`'s `hub` / `metrics`) over standalone services.

## Scripts

| Script | Purpose |
|--------|---------|
| [setup.sh](docs/scripts/setup.md) | Provisions a host from `hosts/$(hostname)/host.conf` |
| [loft-ctl](docs/scripts/loft-ctl.md) | start / stop / rebuild / health / update |
| [deploy-pull.sh](docs/scripts/deploy-pull.md) | Hourly GitHub Release puller for static-site deploys |
| [github-app-token.sh](docs/scripts/github-app-token.md) | GitHub App installation tokens for private-repo pulls |
| [common.sh](docs/scripts/common-sh.md) | Sourced library — compose-arg resolution + health checks |

## Quick start

```bash
sudo git clone git@github.com:hsimah-services/the-loft.git /srv/the-loft
cd /srv/the-loft

# Copy .env.example → .env for each service this host runs
# (see hosts/<hostname>/host.conf for the SERVICES list, and the
#  per-host docs page for which .env files matter)

sudo bash setup.sh
```

Day-to-day after that is `loft-ctl` — see [`docs/scripts/loft-ctl.md`](docs/scripts/loft-ctl.md).

For a fresh host, see the host-specific docs page and [`docs/scripts/setup.md`](docs/scripts/setup.md).

## Security model

- **SSH**: Only `adminhabl` can SSH in. Password auth disabled on Pis.
- **Containers**: All run as `littledog` (UID/GID 1003), a `nologin` service account.
- **Admin escalation**: You log in as `adminhabl` and use `sudo` for privileged actions; `loft-ctl` still auto-elevates to `adminhabl` via `su` if invoked by another user.
- **External access**: Only Pawst (`hbla.ke` + `hsimah.com`) is exposed externally, via Cloudflare Tunnel — no open ports. Everything else is LAN-only.
- **i3 desktop** (calavera): lightdm autologs the `rodnik` service account into an i3 session that auto-launches `firefox --kiosk` fullscreen as a Music Assistant touch dashboard (config in `hosts/calavera/i3/`, URL + HiDPI scaling from `host.conf`); `rodnik` has no sudo or docker.

## Debugging

See [DEBUG.md](DEBUG.md) for container/log/network/Caddy diagnostics, plus the **Debug & Troubleshooting** section at the bottom of every page in [`docs/`](docs/README.md).

## CI

A GitHub Actions workflow (`.github/workflows/validate.yml`) validates every push:
- All compose + override combinations pass `docker compose config --quiet`
- Howlr validated under both `COMPOSE_PROFILES=server` and `=client`
- All shell scripts and `host.conf` files pass `bash -n`
