# `pawpcorn`

> Plex Media Server on space-needle — host networking, hardware transcoding via the i9's iGPU, library on `/mammoth`.

## Overview

`pawpcorn` (paw + popcorn) is the Plex Media Server. One container on [space-needle](../hosts/space-needle.md), `network_mode: host` so direct-play / discovery / GDM all work without bridge translation, library mounted from the `/mammoth` XFS volume, transcoding offloaded to the MS-01's Intel iGPU via `/dev/dri`.

## Architecture

Single container, `plexinc/pms-docker:latest`, running on the host network. Plex's well-known port `32400` is exposed directly on space-needle.

### Why host networking

Plex relies on GDM (Plex's UDP discovery on `32414`–`32417`) and Bonjour-like client probes. Bridge mode breaks the broadcast/multicast path; clients on the LAN need to see Plex appear naturally rather than reach it only through Caddy. Caddy still proxies `pawpcorn.loft.hsimah.com` to `host.docker.internal:32400` for clean external-looking URLs — but direct LAN clients hit `:32400` natively.

### Library + transcode mounts

All read-write from the container:

| Host path | Container path | Purpose |
|-----------|----------------|---------|
| `/opt/pawpcorn/config` | `/config` | Plex DB, metadata cache, watch state — never delete |
| `/mammoth/pawpcorn/transcode` | `/transcode` | Transcoding workspace on the XFS volume (avoids hammering root) |
| `/mammoth/library/movies` | `/data/Movies` | shared with Radarr |
| `/mammoth/library/tv` | `/data/TV` | shared with Sonarr |
| `/mammoth/library/music` | `/data/Music` | shared with Lidarr + slskd |
| `/mammoth/library/videos` | `/data/Videos` | home videos |
| `/mammoth/library/stand-up` | `/data/Stand Up` | comedy specials (separate library type) |

Radarr/Sonarr/Lidarr hardlink completed downloads from `/mammoth/downloads/*` into these library paths — that's why the layout is hardlink-safe (same filesystem, same UID).

### Hardware transcoding

`devices: - /dev/dri:/dev/dri` exposes the iGPU. For Plex to use it, the in-container Plex process needs to be in the `render` and `video` groups on the host — `LITTLEDOG_EXTRA_GROUPS="render,video"` in [`hosts/space-needle/host.conf`](../../hosts/space-needle/host.conf) handles this and `setup.sh` applies it idempotently. Plex Pass is required to enable hardware transcoding in Settings → Transcoder.

## Configuration

### `.env`

Copy [`services/pawpcorn/.env.example`](../../services/pawpcorn/.env.example).

| Variable | Purpose |
|----------|---------|
| `PLEX_CLAIM` | Server claim token from <https://plex.tv/claim> — only used on first boot to associate the server with your Plex account |
| `PUID` | `1004` (littledog UID) — note this differs from the documented `1003`; the `.env.example` ships with `PUID=1004` to match the actual user record |
| `PGID` | `1003` (pack-member group) |
| `TZ` | `America/Los_Angeles` — used for scheduled tasks (library scan, metadata refresh) |

`PLEX_CLAIM` tokens expire after 4 minutes — grab fresh one immediately before first `loft-ctl start pawpcorn`.

### Host requirements

- `LITTLEDOG_EXTRA_GROUPS="render,video"` in `host.conf` (already set on space-needle)
- `/dev/dri` exists on the host (it does on the MS-01 with the i9 iGPU drivers; check `ls /dev/dri/` shows `renderD128` + `card0`)

## Operations

```bash
loft-ctl start pawpcorn
loft-ctl stop pawpcorn
loft-ctl rebuild pawpcorn       # pulls a fresh image
loft-ctl health pawpcorn        # GET http://localhost:32400/web → 200

# Direct access
open http://localhost:32400/web              # on space-needle
open https://pawpcorn.loft.hsimah.com/web    # any client on the LAN
```

### First-time setup

1. Generate a claim token at <https://plex.tv/claim>, paste into `services/pawpcorn/.env` as `PLEX_CLAIM=claim-...`
2. `loft-ctl start pawpcorn`
3. Open `https://pawpcorn.loft.hsimah.com/web`, finish the setup wizard, add libraries pointed at `/data/Movies`, `/data/TV`, etc.
4. Settings → Transcoder → check **Use hardware acceleration when available** and **Use hardware-accelerated video encoding** (requires Plex Pass)
5. Settings → Library → set **Scheduled tasks** for off-hours; the timezone from `.env` controls when those run.

### Updating Plex

```bash
loft-ctl rebuild pawpcorn   # pulls plexinc/pms-docker:latest
```

Plex updates frequently; image rebuilds are cheap. `/opt/pawpcorn/config` carries the DB through.

## Related

- [stellarr](stellarr.md) — Radarr/Sonarr/Lidarr feed the library this serves
- [space-needle](../hosts/space-needle.md) — the only host with `/mammoth` and the iGPU
- [mushr](mushr.md) — provides `pawpcorn.loft.hsimah.com` via `host.docker.internal:32400`
- Blog: [Pawpcorn — Plex on the loft](../../../hblake/posts/pawpcorn.md)

## Debug & Troubleshooting

### Plex transcoding has no GPU

**Symptom:** Settings → Transcoder shows "Hardware acceleration is not enabled" or transcodes peg the CPU.

**Cause:** Either Plex Pass isn't active on the account claimed for this server, or `littledog` lost `render,video` group membership.

**Fix:**

```bash
# Verify group membership on the host
id littledog
# Expected: groups include 'render' and 'video'

# Re-apply via setup.sh — idempotent, just runs usermod
sudo bash /srv/the-loft/setup.sh

# Verify the container can see the iGPU
sudo docker exec pawpcorn ls -la /dev/dri/
# Expected: renderD128 with group rw

# In Plex Settings → Transcoder, re-enable hardware acceleration
```

### `PLEX_CLAIM` rejected on first start

**Cause:** Claim tokens expire after 4 minutes. If `loft-ctl start pawpcorn` was slow (e.g. image pull on first run), the token may already be stale.

**Fix:** Generate a fresh token at <https://plex.tv/claim>, update `services/pawpcorn/.env`, then:

```bash
loft-ctl stop pawpcorn
sudo rm -rf /opt/pawpcorn/config/Library/Application\ Support/Plex\ Media\ Server/Preferences.xml
loft-ctl start pawpcorn
```

Deleting `Preferences.xml` forces Plex back into the claim flow. The rest of `/opt/pawpcorn/config` is preserved.

### Library scans hang or miss files

**Checks:**

```bash
# Permissions — bind mounts must be readable by littledog
sudo -u littledog ls /mammoth/library/movies/ | head

# Plex log
sudo docker exec pawpcorn tail -n 100 \
  '/config/Library/Application Support/Plex Media Server/Logs/Plex Media Server.log'
```

If files exist on disk but Plex doesn't see them, the library type is usually wrong (e.g. Stand Up imported as a Movies library — Plex skips files that don't match the agent's naming heuristics). Use the correct library type ("Other Videos" for Stand Up) and refresh.

### Transcodes fill `/mammoth/pawpcorn/transcode`

Plex auto-cleans transcode segments, but a crashed transcode can leave stale dirs behind.

```bash
# Check usage
sudo du -sh /mammoth/pawpcorn/transcode

# Safe to clear when Plex is stopped (or no active transcodes)
loft-ctl stop pawpcorn
sudo rm -rf /mammoth/pawpcorn/transcode/*
loft-ctl start pawpcorn
```

### Plex can't be reached via `host.docker.internal` from Caddy

**Symptom:** `https://pawpcorn.loft.hsimah.com` returns 502 / Caddy upstream timeout, but `http://localhost:32400/web` on space-needle works.

**Cause:** Plex is host-network; Caddy is bridge-network. Caddy reaches Plex via the `extra_hosts: host.docker.internal:host-gateway` entry on `mushr`. If that entry is missing (rare — only after a manual compose edit), there is no route.

**Fix:** Restore the `extra_hosts` block in `services/mushr/docker-compose.yml` and `loft-ctl rebuild mushr`.

### Plex shows the wrong external IP

**Symptom:** Remote Access tab shows the wrong public IP, or remote clients can't connect.

**Cause:** Plex's auto-detected public IP doesn't match what the LAN reports. Most often happens after a router change.

**Fix:** Settings → Remote Access → manually set the public port to `32400` (or another forwarded port) and tick "Manually specify public port". Remote access through Plex Relay continues to work unless explicitly disabled.
