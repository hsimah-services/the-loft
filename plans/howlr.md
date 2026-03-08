# Howlr — Multi-Room Audio Streaming for The Loft

Synchronized whole-home audio streaming from phone to Raspberry Pi speakers across The Loft.

## Goal

Stream audio from a phone (iPhone or Android) to any combination of Raspberry Pi speakers in different rooms, with tight synchronization so walking between rooms sounds seamless.

---

## Protocol Landscape

| Protocol | Multi-Room Sync | iOS | Android | Open Source | Notes |
|----------|----------------|-----|---------|-------------|-------|
| **Snapcast** | Sub-millisecond | Controller only | Controller only | Yes (GPLv3) | Distribution + sync layer; needs a source feeding it |
| **AirPlay 1** | No (single target) | Native | Third-party apps | Reverse-engineered | Well supported by Shairport Sync |
| **AirPlay 2** | Yes (Apple-coordinated) | Native | Poor | Partially reverse-engineered | Shairport Sync has support; multi-room via iOS picker works but less reliable than Snapcast |
| **Spotify Connect** | No (single target) | Spotify app | Spotify app | librespot (reverse-engineered) | Phone becomes remote; device pulls from Spotify CDN |
| **DLNA/UPnP** | No sync mechanism | Poor | BubbleUPnP etc. | Yes | No sync at all — rooms drift by hundreds of ms |
| **Google Cast** | Yes (audio groups) | Cast SDK apps | Native | No | Cannot make a Pi into a Cast group receiver |
| **Bluetooth A2DP** | No (point-to-point) | Native | Native | bluez | One device at a time; variable latency |
| **PulseAudio/PipeWire RTP** | No active sync | None | None | Yes | Linux-to-Linux only; phones can't participate |

### Verdict

No single protocol solves phone-to-multi-room on its own. The winning approach is a **layered architecture**: use familiar phone protocols (AirPlay, Spotify Connect) as **input sources**, and **Snapcast** as the **synchronized distribution layer** to all speakers.

---

## Recommended Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  Phone                                                           │
│                                                                  │
│  AirPlay ──────► Shairport Sync ──► FIFO ──┐                    │
│  Spotify app ──► librespot ───────► FIFO ──┤                    │
│  Web browser ──► Mopidy ──────────► FIFO ──┤                    │
│  BubbleUPnP ──► upmpdcli+mpd ────► FIFO ──┘                    │
│                                             │                    │
│                               ┌─────────────┘                   │
│                               ▼                                  │
│                         snapserver                               │
│                     (space-needle Docker host)                   │
│                          │    │    │                              │
│                          ▼    ▼    ▼                              │
│                   snapclient instances                            │
│                  (Raspberry Pis in each room)                    │
│                          │    │    │                              │
│                          ▼    ▼    ▼                              │
│                      Speakers throughout The Loft                │
└──────────────────────────────────────────────────────────────────┘
```

### Why This Works

1. **Snapcast** handles distribution + synchronization (sub-millisecond on wired LAN, 1-5ms on WiFi — both inaudible)
2. **Multiple input protocols** cover both platforms natively — no third-party apps needed for the common cases
3. **Central server** on space-needle runs all the intelligence; Pis are thin clients
4. **Zero custom code** — all mature open-source projects, glued together with configuration

---

## Components in Detail

### Snapcast (the core)

[github.com/badaix/snapcast](https://github.com/badaix/snapcast)

`snapserver` reads audio from named pipes (FIFOs), timestamps each chunk, and distributes to connected `snapclient` instances. Each client measures its clock offset from the server and adjusts playback timing. Multiple "streams" can be defined (one per input source), and clients are organized into "groups" that can each play a different stream.

**Sync quality:** <0.02ms on wired Ethernet, 1-5ms on WiFi.

Room/group management is done via:
- **snapweb** — built-in web UI served on port 1780
- **Snapcast mobile apps** — iOS and Android controller apps
- **JSON-RPC API** on port 1780 — for custom integrations

### Shairport Sync (AirPlay input)

[github.com/mikebrady/shairport-sync](https://github.com/mikebrady/shairport-sync)

Makes the server appear as an AirPlay target. iPhone users select "The Loft" in Control Center and audio from any app (Music, Spotify, YouTube, podcasts) routes through. Outputs decoded PCM to a named pipe that snapserver reads.

Supports AirPlay 2 with the `--with-airplay-2` build flag (uses NQPTP for timing).

### librespot (Spotify Connect input)

[github.com/librespot-org/librespot](https://github.com/librespot-org/librespot)

Open-source Spotify Connect receiver in Rust. The phone becomes a remote control; librespot pulls audio directly from Spotify's CDN at 320kbps. Outputs to a named pipe for snapserver. Requires Spotify Premium.

### Mopidy (music server input, optional)

[mopidy.com](https://mopidy.com/)

Music server with web UI (Iris). Plays from local library (`/mammoth/library/music`), Spotify, YouTube, TuneIn radio, SoundCloud. Outputs via GStreamer to a named pipe. Useful for browsing and queueing music from a browser rather than a specific app.

### upmpdcli (DLNA input, optional)

[lesbonscomptes.com/upmpdcli](https://www.lesbonscomptes.com/upmpdcli/)

DLNA/UPnP renderer that outputs to MPD, which outputs to a Snapcast pipe. Gives Android users a DLNA casting target via BubbleUPnP. Not needed if Spotify Connect covers the use case.

---

## What Runs Where

### space-needle Docker Host

All server-side services containerized in `howlr/docker-compose.yml`:

| Container | Image | Network | Ports | Shared Volume |
|-----------|-------|---------|-------|---------------|
| `snapserver` | Custom or `ghcr.io/badaix/snapcast` | host | 1704, 1705, 1780 | `snapcast-pipes:/tmp/snapcast` |
| `shairport-sync` | `mikebrady/shairport-sync` | host | 7000, 319, 320 (AirPlay) | `snapcast-pipes:/tmp/snapcast` |
| `librespot` | Custom build | host | — | `snapcast-pipes:/tmp/snapcast` |
| `mopidy` | `mopidy/mopidy` | bridge | 6680, 6600 | `snapcast-pipes:/tmp/snapcast`, `/mammoth/library/music:/music:ro` |

All containers share a `snapcast-pipes` volume containing the named FIFOs. `network_mode: host` is required for shairport-sync and librespot so mDNS/Bonjour discovery works (phones find them on the LAN).

#### Key Config Files

**snapserver.conf:**
```ini
[http]
enabled = true
bind_address = 0.0.0.0
port = 1780
doc_root = /usr/share/snapserver/snapweb

[stream]
source = pipe:///tmp/snapcast/shairport-fifo?name=AirPlay&sampleformat=44100:16:2&mode=create
source = pipe:///tmp/snapcast/spotify-fifo?name=Spotify&sampleformat=44100:16:2&mode=create
source = pipe:///tmp/snapcast/mopidy-fifo?name=Mopidy&sampleformat=48000:16:2&mode=create
```

**shairport-sync.conf:**
```
general = {
  name = "The Loft";
  output_backend = "pipe";
};
pipe = {
  name = "/tmp/snapcast/shairport-fifo";
  audio_backend_buffer_desired_length_in_seconds = 0.0;
};
```

**librespot command:**
```bash
librespot \
  --name "The Loft Spotify" \
  --backend pipe \
  --device /tmp/snapcast/spotify-fifo \
  --bitrate 320 \
  --initial-volume 100 \
  --enable-volume-normalisation \
  --device-type speaker
```

**mopidy.conf:**
```ini
[audio]
output = audioresample ! audioconvert ! audio/x-raw,rate=48000,channels=2,format=S16LE ! wavenc ! filesink location=/tmp/snapcast/mopidy-fifo

[http]
enabled = true
hostname = 0.0.0.0
port = 6680

[file]
enabled = true
media_dirs = /music
```

### Raspberry Pis (each room)

Each Pi runs **only** `snapclient` — a single lightweight process.

#### OS & Setup

**OS:** Raspberry Pi OS Lite (64-bit, Bookworm+). No desktop environment needed.

**Install:**
```bash
# Install snapclient from GitHub releases (latest version)
wget https://github.com/badaix/snapcast/releases/download/v0.28.0/snapclient_0.28.0-1_armhf.deb
sudo dpkg -i snapclient_0.28.0-1_armhf.deb
sudo apt install -f -y

# Audio utilities for testing
sudo apt install -y alsa-utils avahi-daemon
```

**Configure snapclient** — edit `/etc/default/snapclient`:
```bash
SNAPCLIENT_OPTS="--host <space-needle-ip> --soundcard <alsa-device> --hostID <room-name>"
```

Where `<room-name>` is e.g. `living-room`, `bedroom`, `kitchen`. The `--hostID` is important — without it the client ID changes on reboot and group assignments are lost.

**Find the right ALSA device:**
```bash
# List devices
snapclient -l

# Test audio
speaker-test -D hw:0,0 -c 2 -t wav
```

**Disable WiFi power saving** (critical — causes audio dropouts):
```bash
sudo iw wlan0 set power_save off

# Make persistent:
sudo tee /etc/NetworkManager/dispatcher.d/99-wifi-powersave <<'EOF'
#!/bin/bash
iw wlan0 set power_save off
EOF
sudo chmod +x /etc/NetworkManager/dispatcher.d/99-wifi-powersave
```

**Wired Ethernet is strongly recommended** over WiFi for best sync quality and zero dropouts.

**Enable and start:**
```bash
sudo systemctl enable snapclient
sudo systemctl start snapclient
```

#### Per-Pi resource usage

- RAM: ~10-15 MB
- CPU: <1% during playback
- Disk: ~200 MB (OS + snapclient)

---

## Phone Experience

### iPhone

| Action | How |
|--------|-----|
| **Stream any audio** | Control Center → AirPlay → "The Loft" |
| **Spotify** | Spotify app → Devices → "The Loft Spotify" |
| **Manage rooms** | Snapcast iOS app or `http://<server>:1780` (snapweb) |
| **Browse music library** | Safari → `http://<server>:6680/iris/` (Mopidy) |

AirPlay is the primary path — it captures audio from any app with no extra setup.

### Android

| Action | How |
|--------|-----|
| **Spotify** | Spotify app → Devices → "The Loft Spotify" |
| **Cast via DLNA** | BubbleUPnP → select "The Loft" renderer |
| **Manage rooms** | Snapcast Android app or `http://<server>:1780` (snapweb) |
| **Browse music library** | Chrome → `http://<server>:6680/iris/` (Mopidy) |

Spotify Connect is the smoothest Android path. DLNA via BubbleUPnP covers casting arbitrary audio.

---

## Implementation Phases

### Phase 1 — Minimum Viable (AirPlay + Spotify + Snapcast)

1. Create `howlr/docker-compose.yml` with `snapserver`, `shairport-sync`, `librespot`
2. Add howlr to space-needle-ctl `SERVICES` array
3. Flash Raspberry Pi OS Lite on each Pi
4. Install + configure `snapclient` on each Pi
5. Test: AirPlay from iPhone, Spotify from both platforms
6. Use snapweb for room management

**Custom code: none.** All config files.

### Phase 2 — Music Library

1. Add Mopidy container with Iris web UI
2. Mount `/mammoth/library/music` as read-only
3. Add Spotify and TuneIn extensions to Mopidy

### Phase 3 — Android DLNA + Polish

1. Add upmpdcli container for DLNA casting
2. Set up reverse proxy for clean URLs (snapweb, Mopidy Iris)
3. Automate Pi provisioning (Ansible playbook or a setup script)
4. Add monitoring for client connectivity via snapserver JSON-RPC API

---

## Firewall / Ports Summary

| Port | Protocol | Service | Direction |
|------|----------|---------|-----------|
| 1704 | TCP | snapserver (streaming) | Pis → server |
| 1705 | TCP | snapserver (control) | Pis → server |
| 1780 | TCP | snapweb UI + JSON-RPC | LAN → server |
| 5353 | UDP | mDNS (AirPlay/Spotify discovery) | LAN multicast |
| 7000 | TCP | AirPlay 2 event | Phone → server |
| 319, 320 | UDP | AirPlay 2 timing | Phone → server |
| 6680 | TCP | Mopidy web UI | LAN → server |
| 6600 | TCP | Mopidy MPD | LAN → server |

---

## Resource Usage on space-needle

| Container | CPU (during playback) | RAM |
|-----------|-----------------------|-----|
| snapserver | <1% | ~20 MB |
| shairport-sync | ~5% | ~15 MB |
| librespot | ~5% | ~20 MB |
| mopidy | ~3% | ~80 MB |

Total: negligible impact alongside existing services.
