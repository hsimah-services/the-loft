# `calavera`

> Surface Pro 2 (x86_64, touchscreen) in The Loft fleet — locked-down vinyl kiosk plus the [Spinnik](../services/spinnik.md) audio capture stack.

## Overview

`calavera` is an old Surface Pro 2 (Ubuntu, 4GB RAM, Intel 3rd-gen, 10.6" 1080p touchscreen) that sits in a dock next to the Audio-Technica LP5X turntable. It runs two distinct workloads on the same machine:

1. **Audio capture + streaming** — the [Spinnik](../services/spinnik.md) stack (DarkIce + Icecast + nginx UI) ingests USB audio from the LP5X, encodes it to Ogg Vorbis, and serves it at `http://calavera:8000/vinyl` for [Music Assistant on space-needle](space-needle.md) to pick up as a radio station.
2. **Touchscreen kiosk** — a single-app Wayland kiosk (cage + chromium) displays the Spinnik web UI fullscreen at `http://localhost:8080` so anyone in the room can start/stop vinyl playback and pick which Snapcast group hears it.

It also runs the [Houstn](../services/houstn.md) `metrics` profile and the [Snoot](../services/snoot.md) Beszel agent like the rest of the fleet.

Naming aside: calavera is **not** a Raspberry Pi. It's an x86_64 Surface Pro 2 — easy to forget because it sits in the same "edge device" mental bucket as viking and fjord.

## Architecture

### Services running here

`hosts/calavera/host.conf` declares `SERVICES=(howlr spinnik snoot houstn)` and `KIOSK_ENABLED=true`. With `COMPOSE_PROFILES=client` for howlr and `COMPOSE_PROFILES=metrics` for houstn this resolves to:

| Service | Container | Profile | Purpose |
|---------|-----------|---------|---------|
| [spinnik](../services/spinnik.md) | `spinnik-icecast`, `spinnik-darkice`, `spinnik-ui` | — | Vinyl capture + Icecast stream + touch UI |
| [howlr](../services/howlr.md) | `howlr-snapclient` | `client` | Snapcast client (kiosk audio output) |
| [snoot](../services/snoot.md) | `snoot` | — | Beszel agent |
| [houstn](../services/houstn.md) | `glances` | `metrics` | Per-host metrics for Homepage |

### Kiosk stack

```
greetd (auto-login as kiosk user, VT 7)
  └── cage -s (Wayland kiosk compositor, single fullscreen app, no WM)
       └── chromium-browser --kiosk --ozone-platform=wayland \
                            --force-device-scale-factor=${KIOSK_SCALE} \
                            ${KIOSK_URL}
```

Chromium runs under managed policies (`/etc/chromium/policies/managed/kiosk.json`) that block all URLs by default and allowlist only:

```
loft.hsimah.com   .loft.hsimah.com
space-needle      .space-needle
hbla.ke           hsimah.com
calavera          localhost
```

DevTools, incognito, password manager, sync, translate, and bookmark editing are all disabled. The kiosk user has no sudo or docker access.

Power-state hardening (also in `setup.sh`):

- `sleep.target`, `suspend.target`, `hibernate.target`, `hybrid-sleep.target` are masked
- `HandleLidSwitch*=ignore` in `/etc/systemd/logind.conf.d/kiosk.conf` (always-on display)
- `consoleblank=0` added to the kernel cmdline + a udev rule that forces DPMS On for every DRM connector — screen never blanks
- `iio-sensor-proxy` removed (no auto-rotation)

### LP5X audio device pinning

USB audio devices don't get stable Linux names. After a reboot the LP5X might be `hw:1,0` or `hw:3,0` depending on USB enumeration order, but DarkIce needs a deterministic device. `setup.sh` installs `/etc/udev/rules.d/99-lp5x.rules`:

```
SUBSYSTEM=="sound", ATTRS{idVendor}=="08bb", ATTRS{idProduct}=="29c0", ATTR{id}="LP5X"
```

That matches the TI PCM2900C audio chip inside the LP5X by USB vendor/product ID and pins it to ALSA name `LP5X`, so DarkIce can always reference `plughw:LP5X,0` regardless of enumeration order. The rule is reapplied on every `setup.sh` run.

### Surface Pro 2 WiFi quirks

The Surface's Marvell 88W8797 USB WiFi flakes out under aggressive USB autosuspend. `setup.sh` installs `/etc/udev/rules.d/99-surface-wifi.rules`:

```
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="1286", ATTR{power/autosuspend}="-1"
```

That disables autosuspend for the Marvell USB WiFi adapter. The fleet-wide `/etc/cron.d/loft-wifi-watchdog` (every 5 minutes, restarts `dhcpcd` if `wlan0` loses IPv4) also runs here, same as on the Pis.

### Networking

- LAN IP: `192.168.86.35` (per the dnsmasq A record in [`services/mushr/dnsmasq.conf`](../../services/mushr/dnsmasq.conf) and Houstn's `extra_hosts`)
- DNS: pointed at `192.168.86.28` (mushr-dns on space-needle)

## Configuration

### `host.conf`

See [`hosts/calavera/host.conf`](../../hosts/calavera/host.conf). The kiosk-specific variables:

| Variable | Value | Purpose |
|----------|-------|---------|
| `SERVICES` | `(howlr spinnik snoot houstn)` | Spinnik is calavera-only |
| `KIOSK_ENABLED` | `true` | Triggers the kiosk provisioning block in `setup.sh` |
| `KIOSK_URL` | `http://localhost:8080` | What chromium loads on startup (the spinnik-ui nginx container) |
| `KIOSK_SCALE` | `1` | `--force-device-scale-factor` value |
| `LITTLEDOG_EXTRA_GROUPS` | `audio` | DarkIce / snapclient need ALSA |
| `SSH_DISABLE_PASSWORD` | `true` | Key-only SSH |
| `SERVICE_ENDPOINTS` / `HEALTH_URLS` | empty | No web endpoints health-checked from this host |

### `.env` files

```bash
cp services/howlr/.env.example   services/howlr/.env       # client profile
cp services/spinnik/.env.example services/spinnik/.env     # ICECAST_*, MA_HOST, MA_API_TOKEN
cp services/snoot/.env.example   services/snoot/.env       # BESZEL_*
cp services/houstn/.env.example  services/houstn/.env      # COMPOSE_PROFILES=metrics
```

Spinnik notes:

| Var | Purpose |
|-----|---------|
| `ICECAST_SOURCE_PASSWORD` | Must match the `password = ...` line in `services/spinnik/darkice.cfg` (DarkIce uses this to push to Icecast) |
| `ICECAST_ADMIN_PASSWORD` | Icecast admin UI |
| `MA_HOST`, `MA_API_TOKEN` | The nginx UI server-side-injects this Bearer token when proxying calls to Music Assistant on space-needle, so the browser never holds the token |

## Operations

### First-time provisioning

Same shape as the Pis — clone the repo, copy `.env` files, run `setup.sh`. The script auto-detects `KIOSK_ENABLED=true` and runs the kiosk block (installs `cage`, `chromium-browser`, `greetd`, deploys the managed policy, masks sleep targets, installs the LP5X + Surface WiFi udev rules).

```bash
cd /srv/the-loft
sudo bash setup.sh
sudo udevadm control --reload-rules
sudo reboot   # so the kernel cmdline change (consoleblank=0) takes effect
```

After reboot, greetd auto-logs in the `kiosk` user on VT 7, cage starts chromium fullscreen at `KIOSK_URL`.

### Day-to-day

```bash
loft-ctl health
loft-ctl rebuild spinnik
loft-ctl rebuild howlr
loft-ctl update --all
```

### Adding a URL to the kiosk allowlist

Edit `URLAllowlist` in `setup.sh` (the `# ── Chromium managed policies ──` block) and re-run `sudo bash setup.sh` — the file at `/etc/chromium/policies/managed/kiosk.json` is overwritten on every run, so any manual edits to that file get clobbered. After re-running, restart chromium (kill cage and let greetd respawn it, or reboot).

### Verify the LP5X is pinned

```bash
arecord -l                                   # should show 'LP5X' as a card name
ls /proc/asound/LP5X 2>/dev/null              # directory exists when the rule applied
sudo docker exec spinnik-darkice darkice -v   # darkice version + config check
```

If `LP5X` isn't there, the udev rule didn't match — check `lsusb | grep -i 08bb` to confirm the LP5X is actually plugged in and enumerating, then `sudo udevadm control --reload-rules && sudo udevadm trigger`.

## Related

- [spinnik service page](../services/spinnik.md) — Icecast/DarkIce/UI details and `darkice.cfg`
- [howlr](../services/howlr.md) — how the Icecast stream becomes a fleet-wide MA radio station
- [`hsimah/posts/my-home-lab.md`](../../../hsimah/posts/my-home-lab.md) — fleet overview
- [`hblake/posts/spinnik.md`](../../../hblake/posts/spinnik.md) — the technical writeup of the Spinnik build
- [`hblake/posts/gnome-chromium-pwa.md`](../../../hblake/posts/gnome-chromium-pwa.md) — chromium PWA war stories (background reading; not specific to this kiosk)

## Debug & Troubleshooting

### LP5X audio not captured by DarkIce

**Symptom:** `spinnik-darkice` runs but the Icecast stream is silent or the container exits with an ALSA error like `cannot open audio device plughw:LP5X,0`.

**Causes / checks:**

1. **udev rule didn't apply.** `arecord -l` should list `LP5X` as a card name. If it doesn't:
   ```bash
   lsusb | grep -i 08bb                                # is the LP5X enumerating?
   cat /etc/udev/rules.d/99-lp5x.rules                 # rule present?
   sudo udevadm control --reload-rules
   sudo udevadm trigger
   ```
2. **USB enumeration changed and the rule was removed.** Re-run `sudo bash setup.sh` to reinstall it.
3. **Another process holds the device.** `sudo fuser -v /dev/snd/*` — kill anything that grabbed the LP5X.

### Kiosk shows a black screen / chromium doesn't appear

**Checks:**

```bash
systemctl status greetd
journalctl -u greetd --since '5 min ago' | tail -50
sudo journalctl -b -t cage | tail -30
```

Common causes: chromium policy JSON has a syntax error (chromium refuses to start with malformed managed policies — re-run `setup.sh` to regenerate the file); `${KIOSK_URL}` isn't reachable yet (e.g. spinnik-ui container hasn't started); display rotation got re-enabled (confirm `iio-sensor-proxy` is still removed).

### Display blanks after a few minutes

**Cause:** Either the kernel console blanker or DPMS came back on. The fixes from `setup.sh` (`consoleblank=0` kernel arg + DPMS-off udev rule) require a reboot to take full effect.

**Fix:**

```bash
# Confirm the kernel cmdline took effect
cat /proc/cmdline | grep consoleblank

# Force DPMS On now
for f in /sys/class/drm/card*-*/dpms; do echo On | sudo tee "$f"; done

# If consoleblank=0 isn't in /proc/cmdline, re-run setup and reboot
sudo bash setup.sh && sudo reboot
```

### Surface Pro WiFi drops out

**Causes:**

- Marvell USB autosuspend re-enabled (re-run `setup.sh` to reinstall `/etc/udev/rules.d/99-surface-wifi.rules`)
- `wlan0` lost its DHCP lease — the fleet-wide `/etc/cron.d/loft-wifi-watchdog` should restart `dhcpcd` within 5 minutes:

```bash
journalctl -t loft-wifi-watchdog --since '1 day ago'
```

### Chromium navigates to a URL outside the allowlist

**Symptom:** A page that used to work shows "This site can't be reached" or chromium shows the policy-blocked page.

**Cause:** The kiosk allowlist in `setup.sh` doesn't include that URL.

**Fix:** Add the host to the `URLAllowlist` block in `setup.sh`, re-run `sudo bash setup.sh`, then restart chromium (`sudo systemctl restart greetd`).

### Spinnik UI can't reach Music Assistant

**Symptom:** Buttons in the touch UI don't trigger MA playback; the browser console shows 401/502 from `/api/spinnik`.

**Causes:**

- `MA_API_TOKEN` in `services/spinnik/.env` is wrong or stale (regenerate in MA, restart `spinnik-ui`)
- DNS — the `spinnik-ui` nginx container needs to resolve `space-needle` (or whatever `MA_HOST` is). If it can't, add `dns: [192.168.86.28]` to the `spinnik-ui` service in compose, same pattern as the [container DNS quirk on space-needle](space-needle.md#containers-cant-resolve-loft-hsimah-com-while-the-host-can)
