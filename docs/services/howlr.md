# `howlr`

> Music Assistant on space-needle plus Snapcast clients on the fleet — whole-home audio with Spotify and Plex as sources.

## Overview

`howlr` (howl + er — huskies howl) is multi-room audio for The Loft. A single [Music Assistant](https://music-assistant.io) container on [space-needle](../hosts/space-needle.md) acts as the music brain, the source plugin host, *and* the Snapcast server. Snapclients on [viking](../hosts/viking.md) (Upstairs) and [calavera](../hosts/calavera.md) (Downstairs) receive the synchronized stream and play it through whatever's wired into each host.

## Architecture

### Compose profiles

Two services, picked per-host via `COMPOSE_PROFILES`:

| Profile | Container | Image | Where it runs |
|---------|-----------|-------|---------------|
| `server` | `howlr` | `ghcr.io/music-assistant/server:2.10.1` | space-needle only |
| `client` | `howlr-snapclient` | `ivdata/snapclient` (digest-pinned) | viking, calavera |

Both run with `network_mode: host` so mDNS / Bonjour / Snapcast multicast work without bridge translation.

### What Music Assistant does in the `howlr` container

The MA image is the single brain — there are no separate snapserver, shairport-sync, or librespot containers to look for:

- **Embedded Snapcast server** on ports 1704 (stream), 1705 (control), 1780 (Snapweb UI + JSON-RPC). Players appear as `ma_<hostname>` (e.g. `ma_viking`).
- **Source plugins**: two Spotify music providers, one account each (see [Spotify accounts and per-user access](#spotify-accounts-and-per-user-access)); Plex library on space-needle; plus standard MA providers (Tidal, local files, etc.). AirPlay Receiver and Spotify Connect are both **disabled** — no players are exposed through either.
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
Spotify / Plex / Tidal
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

Nothing else — MA's source plugins, Spotify accounts, and Snapcast groups are all configured through the web UI on first login. See [Spotify accounts and per-user access](#spotify-accounts-and-per-user-access) for the account layout.

**Each Pi / calavera (`client` profile):**

| Var | Purpose |
|-----|---------|
| `COMPOSE_PROFILES` | `client` |
| `SNAPSERVER_HOST` | space-needle's LAN IP (`192.168.86.28`) |
| `SOUND_DEVICE` | ALSA device — usually `default`; specific name (e.g. `plughw:CARD=Headphones,DEV=0`) if the host has multiple sound cards |
| `HOST_ID` | Bare hostname (e.g. `viking`) — stable client ID so MA remembers the player across restarts |

Compose passes `EXTRA_ARGS="--soundcard ${SOUND_DEVICE:-default} --hostID ${HOST_ID}"` to snapclient.

### Spotify accounts and per-user access

Configured entirely in the MA web UI. None of this lives in git — it is state in
`/opt/howlr`, so it survives `loft-ctl rebuild` but is invisible to the repo.

Two Spotify **music provider** instances run side by side, one per person, both seats
on the same Premium Family plan:

| MA user | Spotify account | Notes |
|---------|-----------------|-------|
| `hsimah` | Hamish | Rarely used — Plexamp is the primary listening path |
| `gemo` | Georgia | Primary Spotify user |
| `calavera` | Georgia | Downstairs always-on client |

Separation is enforced by MA's per-user music-source filter (Settings → Users), which
is an **allowlist**: a provider a user has not been granted is invisible to them in
both Browse and Library, with nothing logged.

The playback engine is **Soloist** (Spotify's official engine for screenless devices),
not librespot, on default settings. Each account needs its own API key from Spotify's
Soloist dashboard — generated while signed in as that account, Premium required — plus
a one-off pairing from that account's phone app. A personal developer Client ID is
optional; without one the provider uses MA's shared API allowance.

Soloist permits **one active player at a time per Spotify account**. Because
`calavera` shares Georgia's account, the Downstairs client and Georgia's own playback
contend for the same slot.

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

## Debug & Troubleshooting

### No audio after a config change (stale FIFOs)

**Symptom:** Snapclients log "connected" but play silence after editing snapserver or source-plugin configuration (via MA UI or a compose edit).

**Cause:** MA's internal pipeline uses named pipes (FIFOs) between the source plugins and the embedded snapserver. Just restarting the container leaves the FIFOs in a stale state — a full down/up is needed.

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

### Spotify loads cleanly but is missing from Browse

**Symptom:** `sudo docker logs howlr` shows `Loaded music provider Spotify` with no
errors at all, but Spotify appears nowhere in Browse or Library for a given user.

**Cause:** the per-user music-source filter is an allowlist keyed on **provider
instance id**. Deleting a Spotify provider strips it from every user's filter:

```
Removed spotify--6Hc5Rmpt from the provider_filter of user 'hsimah'
```

The replacement provider gets a *new* instance id and is never re-added, so it loads
correctly server-side while staying invisible in the UI. MA's cleanup only rescues a
user whose list is emptied entirely — anyone with another source (e.g. Plex) keeps a
non-empty list that no longer mentions Spotify.

**Fix:** Settings → Users → edit each affected user → add the new instance to their
music sources (or clear the restriction altogether). Then trigger a library sync:
removing the old provider purged its items from the library.

Applies to any music provider, not just Spotify — re-check Settings → Users after
deleting and re-adding one.

### "Premium account required" when re-adding a Spotify account

**Cause:** the Premium entitlement check runs at **authorization time only**. An
existing provider keeps working indefinitely on its stored token, so a lapse goes
unnoticed until the next re-add. Most often the browser was signed into a *different*
Spotify account than the one on the Family plan; a failed Family address
re-verification does the same thing.

**Fix:** sign out of Spotify in the browser, re-run the OAuth step, and confirm the
account MA reports:

```bash
sudo docker logs howlr --since 15m 2>&1 | grep -i 'logged in to Spotify'
```

### WiFi-related dropouts on a Pi

See [viking](../hosts/viking.md#audio-dropouts-when-wifi-power-saving-is-on) — the WiFi power-saving and dhcpcd lease watchdog fixes live on the host page since they apply to anything WiFi-bound on a Pi, not just snapclient.
