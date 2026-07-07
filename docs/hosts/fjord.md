# `fjord`

> Raspberry Pi 3 B+ in The Loft fleet — currently runs per-host metrics only; its former Downstairs Snapcast role moved to [calavera](calavera.md). Being repurposed as the driver for a cyberdeck build.

## Overview

`fjord` used to be the Downstairs sibling of [viking](viking.md) — a Snapcast client feeding the Downstairs speakers. That role has been **relocated to [calavera](calavera.md)** (the always-on Surface Pro 2), and `fjord` no longer runs [howlr](../services/howlr.md). Today it only runs the [Snoot](../services/snoot.md) Beszel agent and the [Houstn](../services/houstn.md) `metrics` profile (Glances), so it stays visible in fleet monitoring while it awaits its next life.

**Next up:** `fjord` is being repurposed as the driver for a cyberdeck build (a project for Georgia). That software stack isn't in this repo yet; when it lands it'll be documented here.

Naming: `viking` and `fjord` are both lifted from a bottle of Vikingfjord vodka on the bar.

## Architecture

### Services running here

`hosts/fjord/host.conf` declares `SERVICES=(snoot houstn)`. With `COMPOSE_PROFILES=metrics` for houstn:

| Service | Container | Profile | Purpose |
|---------|-----------|---------|---------|
| [snoot](../services/snoot.md) | `snoot` | — | Beszel agent (host metrics + Docker stats) |
| [houstn](../services/houstn.md) | `glances` | `metrics` | Per-host CPU/RAM/disk API consumed by Homepage on space-needle |

No audio services and no Music Assistant here — the Downstairs snapclient now lives on [calavera](calavera.md).

### Networking

- LAN IP: `192.168.86.30` (per the dnsmasq A record in [`services/mushr/dnsmasq.conf`](../../services/mushr/dnsmasq.conf) and Houstn's `extra_hosts`)
- DNS: pointed at `192.168.86.28` (mushr-dns on space-needle)
- WiFi: connected via `wlan0` — same Pi 3 B+ quirks as viking

### Music Assistant

`fjord` is no longer a Snapcast player. The old `ma_fjord` player and its membership in the `Downstairs` / `All` sync groups were replaced by `ma_calavera` when the role moved — see [calavera.md](calavera.md). If a stale `ma_fjord` entry still lingers in the MA UI it can be deleted.

## Configuration

### `host.conf`

See [`hosts/fjord/host.conf`](../../hosts/fjord/host.conf). Same shape as viking: empty storage, empty `CONFIG_DIRS` / `MEDIA_DIRS`, `SSH_DISABLE_PASSWORD=true`, no `HEALTH_URLS`. `LITTLEDOG_EXTRA_GROUPS=audio` is a harmless leftover from the snapclient days.

### `.env` files

Just two now — snoot and houstn. Houstn `.env`: `COMPOSE_PROFILES=metrics`. Snoot `.env`: same `BESZEL_KEY` / `BESZEL_TOKEN` values as the rest of the fleet (the key belongs to the hub, not the agent).

## Operations

### First-time provisioning

Follow [`plans/raspberry-pi.md`](../../plans/raspberry-pi.md). The walkthrough in [viking.md](viking.md#first-time-provisioning) applies — substitute `fjord` for `viking`, and note `fjord` runs no howlr `.env`.

### Day-to-day

```bash
loft-ctl health
loft-ctl update --all
```

## Related

- [calavera](calavera.md) — inherited fjord's Downstairs Snapcast role
- [viking](viking.md) — sibling Pi, still a Snapcast client
- [`plans/raspberry-pi.md`](../../plans/raspberry-pi.md) — full provisioning guide
- [houstn](../services/houstn.md), [snoot](../services/snoot.md)

## Debug & Troubleshooting

The Pi-specific failure modes (WiFi power-save dropouts, the `loft-wifi-watchdog` cron, OOM kills) are identical to viking's. To avoid drift, see [viking.md → Debug & Troubleshooting](viking.md#debug--troubleshooting). Note that audio-related failure modes no longer apply here — `fjord` runs no snapclient.
