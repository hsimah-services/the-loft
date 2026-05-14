# `space-needle`

> Primary server in The Loft fleet — Minisforum MS-01 (i9, x86_64) on a wired LAN, runs the bulk of services and hosts the storage volume.

## Overview

`space-needle` is the only host with persistent storage (`/mammoth`, an XFS volume on `/dev/sda1`) and the only host that runs the heavyweight services — Plex, the *arr stack, WordPress, the Music Assistant server, the reverse proxy, and the Houstn observability hub. The remote hosts ([viking](viking.md), [fjord](fjord.md), [calavera](calavera.md)) are clients of services running here. It is also the LAN's authoritative DNS for `*.space-needle`, `*.loft.hsimah.com`, `hbla.ke`, `hsimah.com`, and the per-host A records (via [mushr](../services/mushr.md)'s dnsmasq).

The host name comes from the Space Needle, the obvious Seattle landmark within sight of the desk.

## Architecture

### Services running here

`hosts/space-needle/host.conf` declares `SERVICES=(mushr pawpcorn stellarr pupyrus howlr pawst houstn snoot)`. With the Houstn `hub,metrics` profile combo this resolves to:

| Service | Containers | Notes |
|---------|-----------|-------|
| [mushr](../services/mushr.md) | `mushr`, `mushr-tunnel`, `mushr-dns` | Reverse proxy + Cloudflare Tunnel + LAN DNS |
| [pawpcorn](../services/pawpcorn.md) | `pawpcorn` | Plex, host network |
| [stellarr](../services/stellarr.md) | `stellarr-vpn`, `transmission`, `slskd`, `radarr`, `sonarr`, `lidarr`, `bazarr`, `jackett` | *arr stack behind shared NordVPN |
| [pupyrus](../services/pupyrus.md) | `pupyrus`, `pupyrus-db`, `pupyrus-redis` | WordPress |
| [howlr](../services/howlr.md) | `howlr` (Music Assistant) | Server profile only — Pi 3 B+ hosts can't run the arm64 server image |
| [pawst](../services/pawst.md) | `pawst` | Static blogs `hbla.ke` + `hsimah.com` |
| [houstn](../services/houstn.md) | `beszel`, `uptime`, `homepage`, `glances` | `COMPOSE_PROFILES=hub,metrics` |
| [snoot](../services/snoot.md) | `snoot` | Beszel agent |

### Networking

| Address | Used for |
|---------|----------|
| `192.168.86.28` | LAN IP — what dnsmasq binds to and what other hosts target |
| `host.docker.internal` | How containers on the `loft-proxy` bridge reach host-networked services on the same machine (resolves to the host gateway via `extra_hosts`) |
| `loft-proxy` bridge | Caddy ↔ bridge-networked services (radarr/sonarr/lidarr/bazarr/jackett, pupyrus, pawst, beszel, uptime, homepage, cloudflared) |
| Host network | pawpcorn, howlr, glances, snoot, stellarr-vpn (which then host-publishes 9091/5030 on behalf of transmission/slskd) |

dnsmasq inside `mushr-dns` is the LAN's primary resolver. Set the router's DHCP DNS to `192.168.86.28` and clients resolve everything: `*.loft.hsimah.com`, `*.space-needle`, the bare hostnames `fjord`/`viking`/`calavera`, and the Cloudflare-fronted blogs (so LAN traffic to `hbla.ke`/`hsimah.com` bypasses the tunnel and hits Caddy directly).

### Storage layout

`/mammoth` is an XFS volume on `/dev/sda1`, declared in `host.conf` (`STORAGE_DEVICE`/`STORAGE_MOUNT`/`STORAGE_FS`) and mounted by `setup.sh`. Service config dirs live under `/opt`.

```
/mammoth                          XFS volume (/dev/sda1)
  /library
    /movies                       Pawpcorn + Radarr
    /tv                           Pawpcorn + Sonarr
    /music                        Pawpcorn + Lidarr + slskd shared
    /videos                       Pawpcorn
    /stand-up                     Pawpcorn
  /downloads
    /transmission                 Transmission completed
    /soulseek                     slskd downloads
  /pawpcorn/transcode             Plex transcoding workspace

/opt
  /pawpcorn/config                Plex configuration
  /radarr, /sonarr, /lidarr       *arr configuration
  /bazarr, /jackett
  /transmission, /slskd
  /pupyrus/html                   WordPress files
  /pupyrus/db                     MariaDB data (see pupyrus-db debug entry below)
  /howlr                          Music Assistant data + embedded snapserver state
  /houstn/beszel/data             Beszel hub database
  /houstn/uptime/data             Uptime Kuma database
  /pawst/hblake-html              hbla.ke static site (deployed by deploy-pull.sh)
  /pawst/hsimah-html              hsimah.com static site (deployed by deploy-pull.sh)
```

`/opt` config dirs are owned `littledog:pack-member` (755). `/mammoth` media dirs are 775. Houstn's Homepage config is the exception — no `/opt` dir, the YAML files are bind-mounted directly from `services/houstn/homepage-config/` in the repo.

## Configuration

### `host.conf` highlights

See [`hosts/space-needle/host.conf`](../../hosts/space-needle/host.conf) for the full file. The notable variables:

| Variable | Value | Purpose |
|----------|-------|---------|
| `STORAGE_DEVICE` / `STORAGE_MOUNT` / `STORAGE_FS` | `/dev/sda1` / `/mammoth` / `xfs` | Mounted by `setup.sh` |
| `LITTLEDOG_EXTRA_GROUPS` | `render,video` | GPU access for Plex transcoding |
| `SSH_DISABLE_PASSWORD` | `false` | Password auth allowed (Pis disable it) |
| `DEPLOY_TARGETS` | pawst-hblake, pawst-hsimah | Hourly pull-based static-site deploys |
| `SERVICE_ENDPOINTS` / `HEALTH_URLS` | full set | All three tiers (`local` / `lan` / `ssl`) populated |

### `.env` files needed

```bash
cp services/mushr/.env.example   services/mushr/.env       # CLOUDFLARE_API_TOKEN, TUNNEL_TOKEN, LOFT_DOMAIN
cp services/pawpcorn/.env.example services/pawpcorn/.env   # PLEX_CLAIM, PUID/PGID/TZ
cp services/stellarr/.env.example services/stellarr/.env   # NORDVPN_TOKEN, PUID/PGID/TZ
cp services/pupyrus/.env.example  services/pupyrus/.env    # MYSQL_*, GRAPHQL_JWT_AUTH_SECRET_KEY
cp services/howlr/.env.example    services/howlr/.env      # COMPOSE_PROFILES=server
cp services/houstn/.env.example   services/houstn/.env     # COMPOSE_PROFILES=hub,metrics + HOMEPAGE_VAR_*
cp services/snoot/.env.example    services/snoot/.env      # BESZEL_KEY, BESZEL_TOKEN (after first hub launch)
```

### Per-host overrides

`hosts/space-needle/overrides/houstn/docker-compose.override.yml` adds `/mammoth:/mammoth:ro` to the glances container so the media volume shows up alongside the root disk in Homepage's resource widgets. Without this override glances only reports `/rootfs`.

### Container DNS quirk

Containers on the `loft-proxy` bridge that need to resolve `*.loft.hsimah.com` or `*.space-needle` from inside (e.g. Uptime Kuma) need an explicit `dns: [192.168.86.28]` in their compose service. The host itself uses `systemd-resolved` (`127.0.0.53` in `/etc/resolv.conf`), and Docker's embedded resolver filters loopback entries from the host's resolv.conf when forwarding queries from containers — so the host resolves loft names fine while containers on it get NXDOMAIN. The fix is per-service rather than daemon-wide so it doesn't restart every container. See the Debug section.

## Operations

```bash
# Provision / re-provision
sudo bash setup.sh

# Start / stop / rebuild — auto-elevates to adminhabl
loft-ctl start --all
loft-ctl stop stellarr
loft-ctl rebuild mushr               # full down + pull + up + healthcheck
loft-ctl update --all                # git pull + rebuild + healthcheck

# Health checks (all three tiers: local/lan/ssl)
loft-ctl health
loft-ctl health stellarr
```

After `rebuild`/`update`, `loft-ctl` waits for containers to report "running" (up to 30s) then runs URL checks for the targeted service across each tier defined in `HEALTH_URLS`.

### Beszel hub setup (one-time after first deploy)

1. `loft-ctl start houstn`
2. Open `https://beszel.loft.hsimah.com`, create the admin account
3. Click **Add System** for each host, copy the `KEY=` value
4. Set `BESZEL_KEY=<value>` in `services/snoot/.env` on every host (same key everywhere)
5. `loft-ctl start snoot` on each host
6. Back in the Beszel UI, configure each system's connection. **space-needle uses `host.docker.internal:45876`** (the hub container can't reach `localhost`); the others use the bare hostname (`fjord`/`viking`/`calavera`) at port 45876.

### Pull-based static-site deploys

`/etc/cron.d/loft-deploy-pawst-hblake` and `loft-deploy-pawst-hsimah` (installed from `DEPLOY_TARGETS` by `setup.sh`) run [`control-plane/deploy-pull.sh`](../../control-plane/deploy-pull.sh) hourly. To force a deploy without waiting:

```bash
sudo /srv/the-loft/control-plane/deploy-pull.sh pawst-hblake hsimah-services/hblake /opt/pawst/hblake-html
```

## Related

- Blog post: [The Loft Lab](../../../hsimah/posts/my-home-lab.md) — fleet-wide overview
- Service pages for everything that runs here (linked in the table above)
- Root [`README.md`](../../README.md) — fleet table and security model

## Debug & Troubleshooting

### Containers can't resolve `*.loft.hsimah.com` while the host can

**Symptom:** From inside a container, `nslookup radarr.loft.hsimah.com` returns NXDOMAIN, but the same query works on the host. Hit on 2026-05-12 when Uptime Kuma went red after a `mushr` rebuild.

**Cause:** mushr-dns binds to `192.168.86.28` only, not `127.0.0.1`. The host uses `systemd-resolved` (`127.0.0.53` in `/etc/resolv.conf`), so it resolves fine. But Docker's embedded DNS (127.0.0.11) filters loopback entries out of the host's resolv.conf when forwarding container queries, then falls back to `8.8.8.8`, which doesn't know about loft names.

**Fix:** Add a per-service DNS override in compose:

```yaml
services:
  uptime:
    dns:
      - 192.168.86.28
```

Containers that only talk to other containers via container-name DNS on the `loft-proxy` network (e.g. `mushr:443`, `pupyrus:80`) don't need this — Docker's embedded resolver handles those. The daemon-wide alternative (`"dns": ["192.168.86.28"]` in `/etc/docker/daemon.json` + `systemctl restart docker`) restarts every container, so prefer the per-service fix.

### `pupyrus-db` restart-loops with "Bad magic header in tc log" after `setup.sh`

**Symptom:** `sudo docker ps -a --filter name=pupyrus-db` shows `Restarting (1)`. Logs:

```
[ERROR] Bad magic header in tc log
[ERROR] Crash recovery failed. Either correct the problem ... or delete tc log
```

**Cause:** MariaDB's two-phase-commit log gets corrupted when `setup.sh`'s `docker compose up -d` recreates `pupyrus-db` mid-InnoDB-recovery. Recurring on space-needle specifically because that's the only host running pupyrus.

**Fix:** WordPress doesn't use XA transactions — `tc.log` carries no in-flight state worth preserving.

```bash
sudo docker stop pupyrus-db
sudo rm /opt/pupyrus/db/tc.log
sudo docker start pupyrus-db
sudo docker logs -f pupyrus-db   # wait for "ready for connections"
```

### `dnsmasq` (mushr-dns) won't bind port 53

**Symptom:** `mushr-dns` fails to start. Logs show "address already in use" on port 53.

**Cause:** `systemd-resolved`'s stub listener is on 53. Common on a fresh Ubuntu install.

**Fix:**

```bash
sudo ss -tlnp | grep ':53'
sudo sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
sudo systemctl restart systemd-resolved
sudo docker restart mushr-dns
```

### Caddy TLS handshake failures across `*.loft.hsimah.com`

**Cause:** Stale or corrupt cert data in Caddy's data volume.

**Fix:**

```bash
loft-ctl stop mushr
sudo docker volume rm mushr_caddy-data mushr_caddy-config
loft-ctl start mushr
# Caddy re-obtains certs via Cloudflare DNS-01 (~30s)
```

### `mushr-tunnel` won't start

**Cause:** It has `depends_on: mushr: condition: service_healthy`. If Caddy's health check fails, the tunnel never starts.

**Fix:**

```bash
sudo docker inspect mushr --format '{{.State.Health.Status}}'
sudo docker logs mushr --tail 30
sudo docker exec mushr caddy validate --config /etc/caddy/Caddyfile
```

### Plex transcoding has no GPU

**Cause:** `littledog` lost `render,video` group membership (re-check after a manual `usermod`).

**Fix:** Re-run `setup.sh` — `LITTLEDOG_EXTRA_GROUPS="render,video"` in `host.conf` is reapplied idempotently.

### Pull-based deploy isn't picking up a new release

Inspect `sudo tail -n 50 /var/log/loft/deploy.log` and `sudo cat /var/lib/loft/deploy/<name>.version`. Common causes: the release has no `.tar.gz` asset, the release is a draft (`releases/latest` skips drafts), or the GitHub App installation doesn't include the repo with `Contents: Read`. Force a manual run:

```bash
sudo /srv/the-loft/control-plane/deploy-pull.sh <name> <owner/repo> <target>
```
