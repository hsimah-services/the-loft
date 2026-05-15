# `spinnik`

> Vinyl turntable streamer — captures the Audio-Technica LP5X via USB, encodes to Ogg Vorbis with DarkIce, serves the stream from Icecast, and ships a touch UI for the kiosk.

## Overview

`spinnik` (spin + Sputnik) lives on [calavera](../hosts/calavera.md), the Surface Pro 2 kiosk next to the turntable. Three containers cooperate: `spinnik-darkice` captures USB audio from the LP5X and pushes an Ogg Vorbis stream to `spinnik-icecast`; `spinnik-icecast` serves that stream at `http://calavera:8000/vinyl`; `spinnik-ui` is the nginx-served touch controller the kiosk chromium loads at `localhost:8080`. [Music Assistant on space-needle](howlr.md) pulls the Icecast URL as a custom radio station, so vinyl flows to the rest of the fleet's Snapcast clients.

## Architecture

### Containers

| Container | Image | Network | Purpose |
|-----------|-------|---------|---------|
| `spinnik-icecast` | `libretime/icecast:2.4.4` | bridge (default) | Icecast streaming server — port `8000` exposed on the host |
| `spinnik-darkice` | Custom build from `debian:bookworm-slim` + `darkice` apt package | bridge (default) | Captures LP5X via ALSA, encodes to Ogg Vorbis, pushes to Icecast |
| `spinnik-ui` | `nginx:alpine` | bridge (default) | Touch UI on host port `8080`; reverse-proxies MA API + Icecast stream |

DarkIce is built locally via [`Dockerfile.darkice`](../../services/spinnik/Dockerfile.darkice) — no upstream image carries DarkIce that's recent enough for the Ogg Vorbis VBR settings used here. The Dockerfile is intentionally tiny: just `apt-get install darkice` over `bookworm-slim`.

`spinnik-darkice` mounts `/dev/snd` so it can reach the host's ALSA devices, and binds [`darkice.cfg`](../../services/spinnik/darkice.cfg) read-only at `/etc/darkice.cfg`.

`spinnik-ui` uses nginx's `templates/default.conf.template` mechanism — the `${MA_HOST}` and `${MA_API_TOKEN}` env vars are substituted into the rendered config at container startup, not hardcoded into the image.

### Audio flow

```
Audio-Technica LP5X (USB, vendor 08bb:29c0)
       │  ALSA  (pinned to name "LP5X" by /etc/udev/rules.d/99-lp5x.rules)
       ▼
   plughw:LP5X,0 (44.1 kHz 16-bit stereo)
       │
       ▼
   spinnik-darkice  (encodes to Ogg Vorbis, VBR quality 0.8)
       │  HTTP PUT  (source password from .env, must match darkice.cfg)
       ▼
   spinnik-icecast  (mount point /vinyl, host port 8000)
       │
       ▼
   Music Assistant on space-needle (radio station: http://calavera:8000/vinyl)
       │  embedded Snapcast server
       ▼
   howlr-snapclient on viking / fjord / calavera
```

### LP5X device pinning

USB audio devices don't get stable Linux names — depending on enumeration order the LP5X could be `hw:1,0` or `hw:3,0` after any reboot. To give DarkIce a deterministic target, `setup.sh` on calavera installs `/etc/udev/rules.d/99-lp5x.rules`:

```
SUBSYSTEM=="sound", ATTRS{idVendor}=="08bb", ATTRS{idProduct}=="29c0", ATTR{id}="LP5X"
```

That matches the LP5X's TI PCM2900C audio chip by USB vendor/product ID and pins it to ALSA card name `LP5X`. DarkIce always references `plughw:LP5X,0` regardless of enumeration order. The rule is re-applied on every `setup.sh` run.

### Two proxies in the UI nginx

[`services/spinnik/nginx.conf`](../../services/spinnik/nginx.conf) defines two server-side proxies so the browser doesn't need to talk to MA or Icecast directly:

- **`/api/spinnik`** → `http://${MA_HOST}:8095/api` — nginx injects `Authorization: Bearer ${MA_API_TOKEN}` server-side. The browser never holds the MA API token, and the kiosk's locked-down chromium can't be tricked into leaking it.
- **`/stream`** → `http://spinnik-icecast:8000/vinyl` (same-origin, `proxy_buffering off`). The Web Audio API can analyze the audio for the canvas visualizer; cross-origin would block that.

Static UI files come from `./ui` (mounted at `/usr/share/nginx/html` read-only) — currently `ui/index.html`, a single-page touch controller with a frequency-bar visualizer.

## Configuration

### `.env`

Copy [`services/spinnik/.env.example`](../../services/spinnik/.env.example).

| Variable | Purpose |
|----------|---------|
| `ICECAST_SOURCE_PASSWORD` | Used by darkice to push to Icecast. **Must match the `password = …` line in [`services/spinnik/darkice.cfg`](../../services/spinnik/darkice.cfg)** — those two are coupled by the protocol, not by env substitution. |
| `ICECAST_ADMIN_PASSWORD` | Icecast admin UI password |
| `MA_HOST` | Music Assistant host on space-needle. **Must be an IP** (`192.168.86.28`) — nginx's resolver can't reach mushr-dns from inside the container without `dns: [192.168.86.28]` in compose, and dropping the IP into `.env` avoids that wrinkle entirely. |
| `MA_API_TOKEN` | Generated in MA → Settings → Security → API Tokens; gives the UI control of playback for the vinyl source |

### `darkice.cfg` highlights

| Section | Key | Value | Notes |
|---------|-----|-------|-------|
| `[general]` | `bufferSecs` | `5` | Buffers 5s of audio; values <2 cause stuttering on USB hiccups |
| `[general]` | `reconnect` | `yes` | Re-establishes the Icecast connection automatically |
| `[input]` | `device` | `plughw:LP5X,0` | Stable ALSA name — set by udev, see device pinning above |
| `[input]` | `sampleRate` / `bitsPerSample` / `channel` | `44100` / `16` / `2` | Matches the LP5X's USB capture format |
| `[icecast2-0]` | `format` / `quality` | `vorbis` / `0.8` | ~256 kbps VBR Ogg Vorbis |
| `[icecast2-0]` | `server` / `mountPoint` | `spinnik-icecast` / `vinyl` | Container-name DNS; the mount point is what MA subscribes to (`/vinyl`) |
| `[icecast2-0]` | `password` | `lofty-vinyl-stream` | Must match `ICECAST_SOURCE_PASSWORD` in `.env` |

### Host requirements (calavera)

- LP5X plugged into USB
- `LITTLEDOG_EXTRA_GROUPS="audio"` in `hosts/calavera/host.conf`
- `/etc/udev/rules.d/99-lp5x.rules` (installed by `setup.sh`)
- For the UI to be the kiosk content, `KIOSK_URL="http://localhost:8080"`

## Operations

```bash
loft-ctl start spinnik
loft-ctl rebuild spinnik          # rebuilds spinnik-darkice locally

# Inspect the stream
curl -sI http://calavera:8000/vinyl
# Or play it
mpv http://calavera:8000/vinyl

# DarkIce status
sudo docker logs spinnik-darkice --tail 30

# Icecast admin
open http://calavera:8000/admin/         # user: admin / password: ICECAST_ADMIN_PASSWORD
```

### Adding spinnik as a source in Music Assistant

In the MA web UI on space-needle: **Settings → Music providers → Add provider → Radio Stations**, then add a custom stream URL `http://calavera:8000/vinyl` named "Vinyl". MA's player UI will then show "Vinyl" as a playable source.

### Verifying the LP5X pin

```bash
arecord -l                                         # should list a card named "LP5X"
ls /proc/asound/LP5X 2>/dev/null                   # directory exists when the rule applied
sudo docker exec spinnik-darkice cat /proc/asound/cards | grep LP5X
```

If `LP5X` isn't there, see the calavera page's [LP5X debug section](../hosts/calavera.md#lp5x-audio-not-captured-by-darkice).

## Related

- [calavera](../hosts/calavera.md) — the only host that runs spinnik; covers udev rules, USB WiFi quirks, kiosk lockdown
- [howlr](howlr.md) — Music Assistant on space-needle picks up the Icecast URL as a radio station and distributes it via Snapcast
- Blog: [Spinnik — vinyl streaming on the loft (hblake)](../../../hblake/posts/spinnik.md)
- Blog: [Spinnik — vinyl streaming on the loft (hsimah)](../../../hsimah/posts/spinnik.md)

## Debug & Troubleshooting

### Icecast stream silent but `spinnik-darkice` is running

**Checks:**

```bash
# Did darkice actually connect to Icecast?
sudo docker logs spinnik-darkice --tail 30 | grep -i 'connect\|encode\|alsa'

# What does Icecast think?
curl -s http://calavera:8000/status-json.xsl | python3 -m json.tool
# Look for "icestats.source" — if absent, darkice isn't pushing
```

If darkice can't reach Icecast: the `ICECAST_SOURCE_PASSWORD` in `.env` and `password = …` in `darkice.cfg` are out of sync (the two are independently encoded, not substituted). Make them match and `loft-ctl rebuild spinnik`.

### LP5X not detected

See the calavera page: [LP5X audio not captured by DarkIce](../hosts/calavera.md#lp5x-audio-not-captured-by-darkice). The root cause is almost always the udev rule (rule missing, USB device not enumerating, or another process holding the device).

### MA can't reach `http://calavera:8000/vinyl`

**Checks:**

```bash
# From space-needle, can it reach the URL?
curl -sI http://calavera:8000/vinyl

# Does mushr-dns resolve calavera?
dig @192.168.86.28 calavera +short
# Expected: 192.168.86.35
```

If the LAN hostname doesn't resolve from inside the MA container specifically (but works from the space-needle host), MA hit the same container-DNS quirk that uptime kuma hit: add `dns: [192.168.86.28]` to the `music-assistant` service in `services/howlr/docker-compose.yml` and `loft-ctl rebuild howlr`. (However, MA on space-needle runs `network_mode: host` — so it inherits the host's resolver and the IP form `192.168.86.35:8000/vinyl` always works as a fallback.)

### `spinnik-ui` API calls return 502

**Checks:**

```bash
sudo docker logs spinnik-ui --tail 30
# Look for: upstream resolution errors targeting MA_HOST
```

**Common causes:**
- `MA_HOST` is a hostname (`space-needle`) rather than an IP. Docker's embedded DNS doesn't resolve `space-needle`. Use `192.168.86.28` directly or add `dns: [192.168.86.28]` to the `spinnik-ui` service.
- `MA_API_TOKEN` is stale — MA returns 401, which nginx surfaces as a 502 to the browser. Regenerate a token in MA, update `.env`, `loft-ctl rebuild spinnik`.

### Visualizer is dead but audio plays

**Cause:** Web Audio API requires same-origin for the `<audio>` source to be analyzable. If the UI HTML was edited to reference `http://calavera:8000/vinyl` directly (bypassing the nginx `/stream` proxy), CORS will break the analyzer node even though playback works.

**Fix:** The UI must hit `/stream` (proxied) and never the Icecast URL directly. Confirm `ui/index.html` references `/stream` rather than `http://calavera:8000/vinyl`.

### Icecast 401 on `/admin/`

**Cause:** Wrong `ICECAST_ADMIN_PASSWORD` in `.env`, or the Icecast UI is asking for the source user/password instead of admin.

**Fix:** Username is `admin`, password is whatever's in `ICECAST_ADMIN_PASSWORD`. Don't confuse it with the source password — those are different credentials in Icecast.

### `spinnik-darkice` exits at startup with "could not open audio device"

**Cause:** The container started before the LP5X enumerated (e.g. cold boot, USB hub still settling) or the udev rule didn't apply.

**Fix:**

```bash
# Wait for the LP5X
arecord -l | grep -i lp5x

# Then restart darkice
sudo docker restart spinnik-darkice
```

The `restart: unless-stopped` policy on darkice means it will retry on its own after a short delay, so this usually self-heals within a minute on a fresh boot.
