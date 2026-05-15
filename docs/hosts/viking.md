# `viking`

> Raspberry Pi 3 B+ in The Loft fleet — Snapcast client (Upstairs zone) plus per-host metrics for [Houstn](../services/houstn.md).

## Overview

`viking` is one of two near-identical Raspberry Pi 3 B+ devices in the fleet (the other is [fjord](fjord.md)). It runs a Snapcast client that plays the Upstairs zone of the multi-room audio system, plus the [Snoot](../services/snoot.md) Beszel agent and the [Houstn](../services/houstn.md) `metrics` profile (Glances). Music Assistant on [space-needle](space-needle.md) drives playback to it.

Naming: `viking` and `fjord` are both lifted from a bottle of Vikingfjord vodka on the bar.

## Architecture

### Services running here

`hosts/viking/host.conf` declares `SERVICES=(howlr snoot houstn)`. With `COMPOSE_PROFILES=client` for howlr and `COMPOSE_PROFILES=metrics` for houstn this resolves to:

| Service | Container | Profile | Purpose |
|---------|-----------|---------|---------|
| [howlr](../services/howlr.md) | `howlr-snapclient` | `client` | Snapcast client — plays Upstairs zone |
| [snoot](../services/snoot.md) | `snoot` | — | Beszel agent (host metrics + Docker stats) |
| [houstn](../services/houstn.md) | `glances` | `metrics` | Per-host CPU/RAM/disk API consumed by Homepage on space-needle |

There is no Music Assistant **server** here — the Pi 3 B+ is arm64 but the MA server image's footprint and the host's 1GB RAM push it past usable. MA runs only on space-needle.

### Networking

- LAN IP: `192.168.86.26` (per the dnsmasq A record in [`services/mushr/dnsmasq.conf`](../../services/mushr/dnsmasq.conf) and Houstn's `extra_hosts`)
- DNS: pointed at `192.168.86.28` (mushr-dns on space-needle) so it resolves the rest of the fleet
- WiFi: connected via `wlan0`, hence the WiFi-related quirks below

### MA player layout

Inside Music Assistant, viking shows up as Snapcast player `ma_viking` and is the sole member of the `Upstairs` sync group (see [howlr.md memory](../../../.claude/projects/-home-hsimah-Projects-the-loft/memory/howlr.md) for the full group table).

## Configuration

### `host.conf`

See [`hosts/viking/host.conf`](../../hosts/viking/host.conf). The notable variables:

| Variable | Value | Purpose |
|----------|-------|---------|
| `STORAGE_DEVICE` / `STORAGE_MOUNT` | empty | Pi has no media volume |
| `CONFIG_DIRS` / `MEDIA_DIRS` | `()` | Nothing to create under `/opt` |
| `LITTLEDOG_EXTRA_GROUPS` | `audio` | Snapclient needs ALSA access; no `render`/`video` (no GPU workloads) |
| `SSH_DISABLE_PASSWORD` | `true` | Key-only SSH (Pis are on WiFi, more exposed) |
| `SERVICE_ENDPOINTS` / `HEALTH_URLS` | empty | No web endpoints to health-check on this host |

### `.env` files

```bash
cp services/howlr/.env.example services/howlr/.env
cp services/snoot/.env.example services/snoot/.env
cp services/houstn/.env.example services/houstn/.env
```

Howlr `.env` (client) — set these per-host:

| Var | Value | Purpose |
|-----|-------|---------|
| `COMPOSE_PROFILES` | `client` | Selects the snapclient container |
| `SNAPSERVER_HOST` | `192.168.86.28` (space-needle) | Where to pull the Snapcast stream from |
| `SOUND_DEVICE` | `default` (or specific ALSA name) | Output device for snapclient |
| `HOST_ID` | `viking` | Stable identifier so MA remembers the player across restarts |

Houstn `.env`:

```bash
COMPOSE_PROFILES=metrics   # not hub,metrics — the hub only runs on space-needle
```

Snoot `.env`: `BESZEL_KEY` and `BESZEL_TOKEN` are filled in **after** the Beszel hub on space-needle is running and you've added this system in the UI. The same key value is reused on every host.

## Operations

### First-time provisioning

Follow [`plans/raspberry-pi.md`](../../plans/raspberry-pi.md) — the canonical Pi guide. Short version once the OS is flashed and SSH works:

```bash
sudo apt-get update && sudo apt-get install -y git
sudo git clone git@github.com:hsimah-services/the-loft.git /srv/the-loft
cd /srv/the-loft
sudo cp services/snoot/.env.example services/snoot/.env
sudo cp services/houstn/.env.example services/houstn/.env
sudo sed -i 's/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=metrics/' services/houstn/.env
# Skip howlr .env until space-needle's MA server is reachable
sudo bash setup.sh
```

`setup.sh` auto-detects the hostname and sources `hosts/viking/host.conf`. It is idempotent — safe to re-run.

### Day-to-day

```bash
loft-ctl health
loft-ctl rebuild howlr
loft-ctl update --all
```

### Verify the snapclient is connected

```bash
sudo docker logs howlr-snapclient --tail 30 | grep -i 'connected\|ready'
```

In Music Assistant on space-needle, viking should appear as `ma_viking` with `available: true`.

## Related

- [fjord](fjord.md) — sibling Pi, identical configuration shape (different zone)
- [`plans/raspberry-pi.md`](../../plans/raspberry-pi.md) — full provisioning guide
- [howlr](../services/howlr.md) — Music Assistant + Snapcast architecture
- [houstn](../services/houstn.md) — `metrics` profile that runs Glances here
- [snoot](../services/snoot.md) — Beszel agent
- Blog: [Multi-Room Audio With Music Assistant and Snapcast](../../../hblake/posts/howlr.md)

## Debug & Troubleshooting

### Audio dropouts when WiFi power-saving is on

**Symptom:** Snapclient runs but audio cuts in/out, especially under light network load.

**Cause:** WiFi power management on `wlan0` parks the radio between packets, which stalls the Snapcast stream long enough to drop samples.

**Fix:**

```bash
# Immediate
sudo iw wlan0 set power_save off

# Persistent (NetworkManager dispatcher)
sudo tee /etc/NetworkManager/dispatcher.d/99-wifi-powersave <<'EOF'
#!/bin/bash
iw wlan0 set power_save off
EOF
sudo chmod +x /etc/NetworkManager/dispatcher.d/99-wifi-powersave
```

### `wlan0` loses its DHCP lease overnight

**Symptom:** Pi is unreachable in the morning; physical reboot fixes it.

**Cause:** Sporadic dhcpcd / driver bugs on the BCM43455 — common Pi 3 B+ failure mode.

**Fix (already installed):** `setup.sh` writes `/etc/cron.d/loft-wifi-watchdog`, which every 5 minutes restarts `dhcpcd` if `wlan0` has no IPv4 address. Verify it's there:

```bash
cat /etc/cron.d/loft-wifi-watchdog
journalctl -t loft-wifi-watchdog --since '1 day ago'
```

### `snapclient` can't reach the server

**Checks:**

```bash
# Can the Pi resolve space-needle via mushr-dns?
nslookup space-needle 192.168.86.28

# Is the Snapcast server port open?
nc -zv 192.168.86.28 1704

# Snapclient log
sudo docker logs howlr-snapclient --tail 30
```

If DNS is the issue, check `/etc/resolv.conf` is pointed at `192.168.86.28`. If TCP is the issue, the howlr server on space-needle is probably not running — `loft-ctl health howlr` from there.

### MA server image fails to pull on the Pi

`COMPOSE_PROFILES=server` won't work on viking — Pi 3 B+ doesn't have the headroom to run Music Assistant. Stay on `client`. If the wrong profile sneaks into `.env`, `loft-ctl rebuild howlr` will try to pull `ghcr.io/music-assistant/server:latest` and either OOM or stall.

### OOM kills (exit code 137)

The Pi 3 B+ has 1GB of RAM. Confirm and triage:

```bash
sudo docker inspect <container> --format '{{.State.OOMKilled}}'
free -h
sudo docker stats --no-stream
```

Most likely culprit if it happens: someone set `COMPOSE_PROFILES=server` on howlr, or a Glances/snapclient version regression. Remediate by reverting and rebuilding.
