# `fjord`

> Raspberry Pi 3 B+ in The Loft fleet — Snapcast client (Downstairs zone) plus per-host metrics for [Houstn](../services/houstn.md).

## Overview

`fjord` is the Downstairs sibling of [viking](viking.md). Same hardware (Pi 3 B+), same services, same provisioning path — only the LAN IP, the room/zone, and the MA player ID differ. It runs a Snapcast client, the [Snoot](../services/snoot.md) Beszel agent, and the [Houstn](../services/houstn.md) `metrics` profile (Glances). Music Assistant on [space-needle](space-needle.md) drives playback.

Naming: `viking` and `fjord` are both lifted from a bottle of Vikingfjord vodka on the bar.

## Architecture

### Services running here

`hosts/fjord/host.conf` declares `SERVICES=(howlr snoot houstn)`. With `COMPOSE_PROFILES=client` for howlr and `COMPOSE_PROFILES=metrics` for houstn:

| Service | Container | Profile | Purpose |
|---------|-----------|---------|---------|
| [howlr](../services/howlr.md) | `howlr-snapclient` | `client` | Snapcast client — plays Downstairs zone |
| [snoot](../services/snoot.md) | `snoot` | — | Beszel agent (host metrics + Docker stats) |
| [houstn](../services/houstn.md) | `glances` | `metrics` | Per-host CPU/RAM/disk API consumed by Homepage on space-needle |

No Music Assistant **server** here — Pi 3 B+ can't run it. MA runs only on space-needle.

### Networking

- LAN IP: `192.168.86.30` (per the dnsmasq A record in [`services/mushr/dnsmasq.conf`](../../services/mushr/dnsmasq.conf) and Houstn's `extra_hosts`)
- DNS: pointed at `192.168.86.28` (mushr-dns on space-needle)
- WiFi: connected via `wlan0` — same Pi 3 B+ quirks as viking

### MA player layout

Inside Music Assistant, fjord shows up as Snapcast player `ma_fjord` and is the sole member of the `Downstairs` sync group. fjord is configured with `hide_in_ui: true` in MA — it is managed exclusively via the sync groups (Downstairs / All) rather than as a directly-selectable target. See the [howlr memory entry](../../../.claude/projects/-home-hsimah-Projects-the-loft/memory/howlr.md) for the full group table.

## Configuration

### `host.conf`

See [`hosts/fjord/host.conf`](../../hosts/fjord/host.conf). Identical shape to viking: empty storage, empty `CONFIG_DIRS` / `MEDIA_DIRS`, `LITTLEDOG_EXTRA_GROUPS=audio`, `SSH_DISABLE_PASSWORD=true`, no `HEALTH_URLS`.

### `.env` files

Same three files as viking — howlr (client profile), snoot, houstn. The only per-host values that differ are inside `services/howlr/.env`:

| Var | viking | fjord |
|-----|--------|-------|
| `HOST_ID` | `viking` | `fjord` |
| `SOUND_DEVICE` | room-specific ALSA device | room-specific ALSA device |

Everything else (`COMPOSE_PROFILES=client`, `SNAPSERVER_HOST=192.168.86.28`) is the same.

Houstn `.env`: `COMPOSE_PROFILES=metrics`. Snoot `.env`: same `BESZEL_KEY` / `BESZEL_TOKEN` values as the rest of the fleet (the key belongs to the hub, not the agent).

## Operations

### First-time provisioning

Follow [`plans/raspberry-pi.md`](../../plans/raspberry-pi.md). The walkthrough in [viking.md](viking.md#first-time-provisioning) applies verbatim — substitute `fjord` for `viking`.

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

In Music Assistant on space-needle, fjord should appear as `ma_fjord` (hidden in the player picker but selectable as part of the Downstairs / All sync groups).

## Related

- [viking](viking.md) — sibling Pi, identical configuration shape (different zone)
- [`plans/raspberry-pi.md`](../../plans/raspberry-pi.md) — full provisioning guide
- [howlr](../services/howlr.md), [houstn](../services/houstn.md), [snoot](../services/snoot.md)
- Blog: [Multi-Room Audio With Music Assistant and Snapcast](../../../hblake/posts/howlr.md)

## Debug & Troubleshooting

The Pi-specific failure modes (WiFi power-save audio dropouts, the `loft-wifi-watchdog` cron, snapclient connectivity checks, OOM kills, "MA server profile won't fit") are identical to viking's. To avoid drift, see [viking.md → Debug & Troubleshooting](viking.md#debug--troubleshooting).

### fjord-specific: missing from the MA player picker

**Symptom:** Music Assistant doesn't show fjord as a selectable target in the room dropdown, even though `loft-ctl health snoot` is green and `howlr-snapclient` is connected.

**Cause:** Expected behaviour — fjord is configured with `hide_in_ui: true` in MA. It's controllable only via the `Downstairs` and `All` sync groups, not as a standalone player.

**Fix:** Use the `Downstairs` group to play to fjord alone, or `All` to play to viking + fjord together. If you genuinely want fjord visible as an individual player, flip `hide_in_ui` for `ma_fjord` in the Music Assistant UI.
