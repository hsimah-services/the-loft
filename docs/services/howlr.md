# `howlr`

> Music Assistant on space-needle plus Snapcast clients on the fleet — whole-home audio with phone, Spotify, and AirPlay as sources.

## Overview

`howlr` (howl + er — huskies howl) is multi-room audio for The Loft. A single [Music Assistant](https://music-assistant.io) container on [space-needle](../hosts/space-needle.md) acts as the music brain, the source plugin host, *and* the Snapcast server. Snapclients on [viking](../hosts/viking.md) (Upstairs) and [calavera](../hosts/calavera.md) (Downstairs) receive the synchronized stream and play it through whatever's wired into each host.

## Architecture

### Compose profiles

Two services, picked per-host via `COMPOSE_PROFILES`:

| Profile | Container | Image | Where it runs |
|---------|-----------|-------|---------------|
| `server` | `howlr` | `ghcr.io/music-assistant/server:latest` | space-needle only |
| `client` | `howlr-snapclient` | `ivdata/snapclient:latest` | viking, calavera |

Both run with `network_mode: host` so mDNS / Bonjour / Snapcast multicast work without bridge translation.

### What Music Assistant does in the `howlr` container

The MA image is the single brain — no separate snapserver, shairport-sync, or librespot containers (unlike the multi-container plan in [`plans/howlr.md`](../../plans/howlr.md), which predates MA having all of this built-in):

- **Embedded Snapcast server** on ports 1704 (stream), 1705 (control), 1780 (Snapweb UI + JSON-RPC). Players appear as `ma_<hostname>` (e.g. `ma_viking`).
- **Source plugins**: Spotify (multiple accounts), Spotify Connect target ("The Loft"), AirPlay Receiver ("The Loft" on port 7589), Plex library on space-needle, plus standard MA providers (Tidal, local files, etc.).
- **shairport-sync as a subprocess**: MA spawns it internally and writes config to `/tmp/ma_shairport_sync_airplay_receiver--<id>.conf` at runtime. Uses tinysvcmdns (no avahi-daemon). Do not hand-edit the generated config — MA rewrites it every start.
- **Web UI** at `https://howlr.loft.hsimah.com` (proxied through [mushr](mushr.md)) and Snapweb at `http://snapweb.loft.hsimah.com` / `localhost:1780`.

State persists in `/opt/howlr` (bind-mounted as `/data`).

### Snapcast players and groups (current layout)

| MA player | Host | Available | Snapcast group |
|-----------|------|-----------|----------------|
| `ma_viking` | viking | yes | Upstairs |
| `ma_calavera` | calavera | yes (always-on) | Downstairs |

The `All` group spans calavera + viking for whole-home playback. `ma_calavera` inherited the Downstairs role from the retired `ma_fjord` (see [calavera](../hosts/calavera.md)). Groups are managed in the MA UI or directly via Snapweb.

### Audio flow

```
iPhone / Spotify / Plex / Tidal
        │
        ▼
   Music Assistant (howlr container, space-needle)
        │  ├─ source plugins
        │  └─ embedded snapserver
        │
        ▼  TCP 1704/1705 to each client
   howlr-snapclient on viking / fjord / calavera
        │
        ▼  ALSA  (SOUND_DEVICE env)
   speakers
```

## Configuration

### `.env` per host

Copy from [`services/howlr/.env.example`](../../services/howlr/.env.example).

**space-needle (`server` profile):**

```bash
COMPOSE_PROFILES=server
```

Nothing else — MA's source plugins, Spotify accounts, AirPlay name, and Snapcast groups are all configured through the web UI on first login.

**Each Pi / calavera (`client` profile):**

| Var | Purpose |
|-----|---------|
| `COMPOSE_PROFILES` | `client` |
| `SNAPSERVER_HOST` | space-needle's LAN IP (`192.168.86.28`) |
| `SOUND_DEVICE` | ALSA device — usually `default`; specific name (e.g. `plughw:CARD=Headphones,DEV=0`) if the host has multiple sound cards |
| `HOST_ID` | Bare hostname (e.g. `viking`) — stable client ID so MA remembers the player across restarts |

Compose passes `EXTRA_ARGS="--soundcard ${SOUND_DEVICE:-default} --hostID ${HOST_ID}"` to snapclient.

### Storage

| Path | Purpose |
|------|---------|
| `/opt/howlr` (server only) | MA data — library DB, source plugin state, embedded snapserver state, generated `/tmp/ma_*` configs |
| `/dev/snd` (client) | ALSA passthrough — required for snapclient to reach the sound card |

### Why the Pis can't run the `server` profile

Pi 3 B+ is arm64 but has 1GB RAM. The MA server image's footprint pushes it past usable. Stay on `client`. If `COMPOSE_PROFILES=server` ends up in a Pi's `.env`, `loft-ctl rebuild howlr` will either OOM or stall on image pull.

## Operations

```bash
# Server (space-needle)
loft-ctl start howlr
loft-ctl rebuild howlr            # required after MA config changes — see audio-no-output debug
loft-ctl health howlr             # checks the MA web UI + Snapweb

# Client (any Pi / calavera)
loft-ctl rebuild howlr
sudo docker logs howlr-snapclient --tail 30 | grep -i 'connected\|ready'
```

### Adding a new room

1. Provision the new host (see [`plans/raspberry-pi.md`](../../plans/raspberry-pi.md)).
2. Set `HOST_ID=<bare-hostname>` and `SOUND_DEVICE` in that host's `services/howlr/.env`.
3. `loft-ctl start howlr` — the client connects, then the player shows up in MA as `ma_<hostname>`.
4. In the MA UI, drop it into a Snapcast group (or create a new one).

## Related

- [mushr](mushr.md) — Caddy reverse proxy for `howlr.loft.hsimah.com` and `snapweb.loft.hsimah.com`
- [snoot](snoot.md) / [houstn](houstn.md) — health and container metrics
- [viking](../hosts/viking.md), [calavera](../hosts/calavera.md) — client hosts
- Blog: [Multi-room audio with Music Assistant and Snapcast](../../../hblake/posts/howlr.md)
- Design notes: [`plans/howlr.md`](../../plans/howlr.md) — original multi-container plan, now superseded by MA's all-in-one image

## Debug & Troubleshooting

### No audio after a config change (stale FIFOs)

**Symptom:** Snapclients log "connected" but play silence after editing snapserver or shairport-sync configuration (via MA UI or a compose edit).

**Cause:** MA's internal pipeline uses named pipes (FIFOs) between shairport-sync / librespot / source plugins and the embedded snapserver. Just restarting the container leaves the FIFOs in a stale state — a full down/up is needed.

**Fix:**

```bash
loft-ctl rebuild howlr            # `down` + `up`, not just `restart`
```

### Snapclient connects but no sound

**Checks:**

```bash
# Did snapclient pick up an ALSA device?
sudo docker logs howlr-snapclient --tail 30 | grep -i 'soundcard\|alsa\|hw:'

# What ALSA cards does the host see?
sudo docker exec howlr-snapclient aplay -l 2>/dev/null || aplay -l
```

If `SOUND_DEVICE=default` and the host has multiple cards (e.g. HDMI + USB), pick a specific one: e.g. `SOUND_DEVICE=plughw:CARD=Headphones,DEV=0`. Then `loft-ctl rebuild howlr` on that host.

### `ma_<host>` shows as offline in MA after rebuild

**Cause:** `HOST_ID` not set, so snapclient picked a random ID on restart and MA sees it as a new player.

**Fix:** Set `HOST_ID=<bare-hostname>` in that host's `services/howlr/.env`, rebuild, and in MA delete the orphaned `ma_<random>` entry.

### AirPlay session leaves Snapcast stuck on a silent stream

**Symptom:** Disconnecting an iPhone from "The Loft" AirPlay target leaves fjord/viking silent until MA is restarted. Tracked in [#62](https://github.com/hsimah-services/the-loft/issues/62).

**Cause:** When a phone connects to AirPlay, MA's internal shairport-sync takes over the Snapcast session. On disconnect, the session is not cleanly restored.

**Workaround:** `loft-ctl rebuild howlr` after AirPlay use, or switch the active group's source manually in MA.

**Eventual fix (per #62):** Run a standalone `shairport-sync` container with its own AirPlay name, feeding snapserver as an independent stream source, bypassing MA's AirPlay plugin.

### Spotify Connect / AirPlay startup latency on play/pause/skip

Plugins are early-stage with 0.5–5s startup latency on play/pause/skip; ongoing playback is real-time and unaffected. This is upstream MA behavior, not a config issue. Spotify Connect also only allows one active target per Spotify account at a time — Family-plan members with separate logins can stream to different rooms simultaneously.

### Snapweb crashes on AirPlay 2 stream

**Symptom:** The Snapweb browser client loads fine, but the audio playback element crashes/stutters specifically on AirPlay 2 streams.

**Cause:** AirPlay 2 uses 48kHz/32-bit format (`sampleformat=48000:32:2`). Snapweb's in-browser decoder can't handle 32-bit samples.

**Fix:** Use a native snapclient (viking, fjord, calavera) for AirPlay 2 playback. Spotify Connect (44100:16:2) works on Snapweb.

### WiFi-related dropouts on a Pi

See [viking](../hosts/viking.md#audio-dropouts-when-wifi-power-saving-is-on) — the WiFi power-saving and dhcpcd lease watchdog fixes live on the host page since they apply to anything WiFi-bound on a Pi, not just snapclient.
