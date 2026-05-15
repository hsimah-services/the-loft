# `stellarr`

> Eight-container *arr + VPN bundle on space-needle — Radarr / Sonarr / Lidarr / Bazarr / Jackett / Transmission / slskd, with NordVPN sharing one egress.

## Overview

`stellarr` (stellar + the *arr suffix) is the media-acquisition stack. Everything that needs to fetch torrents or query indexers routes through a shared NordVPN container (`stellarr-vpn`). Transmission and slskd inherit that network namespace so they egress through the VPN; the *arr apps stay on the `loft-proxy` bridge for normal Caddy routing but reach the download clients via `host.docker.internal` at the VPN container's host-published ports. Eight containers, one compose file, one `loft-ctl` target.

## Architecture

### Containers

| Container | Image | Network | Why |
|-----------|-------|---------|-----|
| `stellarr-vpn` | `ghcr.io/bubuntux/nordvpn` | bridge (default), `NET_ADMIN`/`NET_RAW` caps | Establishes a NordLynx tunnel and publishes Transmission/slskd ports on the host |
| `transmission` | `lscr.io/linuxserver/transmission:latest` | `service:vpn` | All egress through NordVPN; Transmission's web UI exposed via the VPN's `9091:9091` port mapping |
| `slskd` | `slskd/slskd:latest` | `service:vpn` | Same — Soulseek peers see the VPN exit IP, not the home IP |
| `radarr` | `lscr.io/linuxserver/radarr:latest` | `loft-proxy` bridge | Movies — fed by Transmission downloads, hardlinked into `/mammoth/library/movies` |
| `sonarr` | `lscr.io/linuxserver/sonarr:latest` | `loft-proxy` bridge | TV — same pattern |
| `lidarr` | `lscr.io/linuxserver/lidarr:nightly` | `loft-proxy` bridge | Music — **nightly** specifically for the slskd plugin support |
| `bazarr` | `lscr.io/linuxserver/bazarr:latest` | `loft-proxy` bridge | Subtitles for Radarr + Sonarr libraries |
| `jackett` | `lscr.io/linuxserver/jackett:latest` | `loft-proxy` bridge | Indexer proxy used by all three *arr |

The *arr apps each declare `extra_hosts: host.docker.internal:host-gateway` so they can reach Transmission at `host.docker.internal:9091` and slskd at `host.docker.internal:5030` (those are exposed on the host by `stellarr-vpn`'s port mappings, since transmission + slskd are on `service:vpn` and don't have their own port mappings). Bazarr and Jackett don't need that — they only talk to other *arr.

### Why `network_mode: service:vpn`

Transmission and slskd join the VPN container's network namespace at compose time. Three consequences:

1. Their egress goes through NordVPN — Soulseek peers and BitTorrent trackers see the NordVPN exit IP.
2. They can't have their own `ports:` block — port mappings must live on `stellarr-vpn` (`9091:9091`, `5030:5030`, etc.). If the VPN container dies, the entire network namespace evaporates and Transmission/slskd lose connectivity at the kernel level.
3. From inside the *arr containers, the path to the download client isn't `transmission:9091` — Transmission has no container-name DNS entry because it shares the VPN's network. Hence `host.docker.internal:9091` via `extra_hosts`.

### Hardlink-safe layout

Both `/mammoth/library` and `/mammoth/downloads` sit on the same XFS volume, owned by `littledog:pack-member`. Radarr/Sonarr/Lidarr hardlink completed downloads into the library rather than copy — instant move, zero extra disk. Transmission and slskd both mount `/mammoth/downloads` so the source paths are identical for *arr to see.

```
/mammoth
  /downloads
    /transmission         Transmission completed
    /soulseek             slskd downloads (incomplete + complete subdirs)
  /library
    /movies               Radarr → hardlinked from /mammoth/downloads
    /tv                   Sonarr →
    /music                Lidarr + slskd shared (shared dir for slskd browsing)
```

slskd has `SLSKD_DOWNLOADS_DIR=/downloads/complete/lidarr` and `SLSKD_SHARED_DIR=/music` — Lidarr's Slskd plugin connects to slskd's API, picks results, and the downloads land where Lidarr expects them.

### Transmission ratio cleanup cron

[`services/stellarr/transmission/remove-torrents.sh`](../../services/stellarr/transmission/remove-torrents.sh) is bind-mounted into the container. `services/stellarr/setup.sh` installs `/etc/cron.d/transmission-cleanup` to run it at midnight:

```
0 0 * * * root docker exec transmission /scripts/remove-torrents.sh
```

The script lists torrents via `transmission-remote -l`, filters to ratio ≥ 2.0, and removes them with `--remove-and-delete`. That's safe because Radarr/Sonarr/Lidarr already hardlinked the files into the library — removing the download copy doesn't touch the library.

### Caddy routing

From [`services/mushr/Caddyfile`](../../services/mushr/Caddyfile):

- `radarr.loft.hsimah.com` → `radarr:7878` (container-name DNS on `loft-proxy`)
- Same shape for `sonarr:8989`, `lidarr:8686`, `bazarr:6767`, `jackett:9117`
- `transmission.loft.hsimah.com` → `host.docker.internal:9091` (the VPN container's host port mapping)
- `soulseek.loft.hsimah.com` → `host.docker.internal:5030`

No host ports for the *arr apps — they're reachable **only** through Caddy. That's intentional: the *arr APIs hand out API keys in URL query strings, which we'd rather not have flying around in cleartext on the LAN.

## Configuration

### `.env`

Copy [`services/stellarr/.env.example`](../../services/stellarr/.env.example).

| Variable | Purpose |
|----------|---------|
| `NORDVPN_TOKEN` | NordVPN access token (from your NordVPN account dashboard). The compose hardcodes `CONNECT=NETHERLANDS` and `TECHNOLOGY=NordLynx` — adjust in the compose if you want a different exit or OpenVPN |
| `PUID` / `PGID` / `TZ` | `1003` / `1003` / `America/Los_Angeles` — the `littledog:pack-member` UID/GID and the timezone for scheduled tasks |
| `SLSKD_SOULSEEK_USERNAME` / `SLSKD_SOULSEEK_PASSWORD` | Soulseek account creds — slskd logs in on container start |

`NETWORK=192.168.86.0/24` is set on the VPN container so the *arr apps and the host can reach Transmission/slskd despite the VPN — without it the VPN kill switch would block LAN-originated traffic too.

### Volumes

| Host path | Container path | Service | Purpose |
|-----------|----------------|---------|---------|
| `/opt/radarr`, `/opt/sonarr`, `/opt/lidarr`, `/opt/bazarr`, `/opt/jackett` | `/config` | each *arr | App config + database |
| `/opt/transmission` | `/config` | transmission | Transmission settings + state |
| `/opt/slskd` | `/app` | slskd | slskd config + state |
| `/mammoth/library/{movies,tv,music}` | `/movies`, `/tv`, `/music` | per app | Library |
| `/mammoth/downloads` | `/downloads` | transmission, slskd, *arr | Shared downloads |

### Cloudflare DNS-01 share

The Caddy `cloudflare_tls` import in mushr's Caddyfile handles cert issuance for `radarr.loft.hsimah.com`, `sonarr.loft.hsimah.com`, etc. — see the [mushr page](mushr.md) for one-time Cloudflare setup.

## Operations

```bash
loft-ctl start stellarr
loft-ctl rebuild stellarr           # full down + pull + up; reissues a fresh VPN connection
loft-ctl health stellarr            # checks radarr/sonarr/lidarr/bazarr/jackett URLs; transmission/slskd are WARN-only

# VPN status
sudo docker exec stellarr-vpn curl -s https://api.nordvpn.com/vpn/check/full | python3 -m json.tool
sudo docker exec stellarr-vpn curl -s https://ifconfig.me

# Trigger the ratio cleanup manually
sudo docker exec transmission /scripts/remove-torrents.sh
```

### Adding the slskd plugin to Lidarr

Lidarr `nightly` ships with plugin support enabled. In Lidarr → Settings → Plugins, install [Lidarr.Plugin.Slskd](https://github.com/allquiet-hub/Lidarr.Plugin.Slskd), then add slskd as both an **indexer** and a **download client** with the slskd API URL at `http://host.docker.internal:5030` and the API key from slskd's Settings → Security → API Keys page.

### Switching VPN exit country

Edit `CONNECT=NETHERLANDS` in [`services/stellarr/docker-compose.yml`](../../services/stellarr/docker-compose.yml) (or move it into `.env` if you want to vary it across hosts), then:

```bash
loft-ctl rebuild stellarr
```

## Related

- [pawpcorn](pawpcorn.md) — consumes the libraries that Radarr/Sonarr/Lidarr produce
- [mushr](mushr.md) — Caddy routes for the *arr UIs, Cloudflare DNS-01 for the certs
- [space-needle](../hosts/space-needle.md) — only host that runs stellarr (`/mammoth` is here)
- Blog: [Stellarr — *arr + VPN on the loft](../../../hblake/posts/stellarr.md)

## Debug & Troubleshooting

### VPN-dependent health checks failing (transmission / slskd)

**Symptom:** `loft-ctl health stellarr` shows WARNING for transmission/slskd but the *arr apps are OK.

**Cause:** The VPN tunnel is down. Transmission and slskd are on `service:vpn` — when the VPN container drops, their network namespace goes with it.

**Fix:**

```bash
sudo docker logs stellarr-vpn --tail 30
sudo docker restart stellarr-vpn
# Wait ~30s for reconnect:
loft-ctl health stellarr
```

If reconnect keeps failing, the most common cause is a bad `NORDVPN_TOKEN` (rotated, expired) or NordVPN's NL servers all rejecting the connection — try a different `CONNECT=` value temporarily.

### *arr apps can't reach the download client

**Symptom:** Radarr/Sonarr/Lidarr → Activity/Queue shows "unable to connect to Transmission" or slskd.

**Checks:**

```bash
# Is transmission reachable from inside an *arr container?
sudo docker exec radarr wget -q -O - http://host.docker.internal:9091/transmission/web/ 2>&1 | head

# What about slskd?
sudo docker exec lidarr wget -q -O - http://host.docker.internal:5030/health 2>&1 | head
```

**Common causes:**
- The VPN container is down (see above).
- The *arr download-client setting points at `transmission:9091` (container-name DNS — wrong, transmission shares the VPN namespace) instead of `host.docker.internal:9091`.
- The `extra_hosts: host.docker.internal:host-gateway` block was dropped from one of the *arr services. Restore and `loft-ctl rebuild stellarr`.

### Ratio cleanup not firing

**Checks:**

```bash
cat /etc/cron.d/transmission-cleanup
sudo grep -i transmission /var/log/syslog | tail -20
# Trigger manually
sudo docker exec transmission /scripts/remove-torrents.sh
```

**Common causes:**
- `setup.sh` hasn't been re-run since the script was added (the cron file is installed there). Re-run `sudo bash /srv/the-loft/setup.sh`.
- A torrent name has shell-special characters that `awk` mis-parses — the script keys on the torrent's numeric ID, but if `transmission-remote -l`'s output layout shifts (upstream column changes) the `ratio=$9` field index can break. Confirm column 9 still holds the ratio: `sudo docker exec transmission transmission-remote -l | head`.

### Lidarr nightly broke a plugin

**Cause:** `lidarr:nightly` is, by definition, churning. The Slskd plugin pins to a specific Lidarr plugin API, and upstream changes can desync.

**Fix:** Pin a known-good nightly tag in the compose, e.g. `image: lscr.io/linuxserver/lidarr:nightly-2.x.y.NNNN`, then `loft-ctl rebuild stellarr`. The [Lidarr.Plugin.Slskd repo](https://github.com/allquiet-hub/Lidarr.Plugin.Slskd) typically calls out which Lidarr nightly is compatible in its releases.

### slskd can't find files in `SLSKD_SHARED_DIR`

**Checks:**

```bash
sudo docker exec slskd ls /music | head
sudo docker logs slskd --tail 50 | grep -i share
```

`SLSKD_SHARED_DIR=/music` maps to `/mammoth/library/music:/music:ro`. If the shared dir is empty inside the container, the bind mount was edited or `/mammoth/library/music` isn't populated. Re-share via the slskd UI after Lidarr populates the library.

### Transmission web UI 401 on `https://transmission.loft.hsimah.com`

**Cause:** Transmission's auth is configured (Settings → Network → RPC username/password) but the Homepage widget / your browser-saved credentials don't match.

**Fix:** Update `HOMEPAGE_VAR_TRANSMISSION_USERNAME` / `_PASSWORD` in `services/houstn/.env` (see [houstn](houstn.md)) and `loft-ctl rebuild houstn`. For your own browser, just re-enter when prompted.

### `stellarr-vpn` boot-loop with `iptables: command not found` or similar

The `bubuntux/nordvpn` image is host-kernel-sensitive — some kernel modules need to be loadable from inside the container. If kernel updates landed and `stellarr-vpn` started failing afterward:

```bash
sudo docker logs stellarr-vpn --tail 50
sudo modprobe wireguard          # NordLynx needs wireguard module
sudo modprobe nf_conntrack       # iptables NAT needs this
loft-ctl rebuild stellarr
```

If WireGuard isn't loadable, fall back to `TECHNOLOGY=OpenVPN` in the compose temporarily.
