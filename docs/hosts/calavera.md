# `calavera`

> Surface Pro 2 (x86_64, touchscreen) in The Loft fleet — always-on Downstairs Snapcast client with an i3 desktop. Previously the vinyl kiosk; that role (Spinnik) has been retired.

## Overview

`calavera` is an old Surface Pro 2 (Ubuntu, 4GB RAM, Intel 3rd-gen, 10.6" 1080p touchscreen) sitting in a dock. It took over the **Downstairs Snapcast client** role from [fjord](fjord.md), so it's now an always-on audio sink: [Music Assistant on space-needle](space-needle.md) streams to it and it plays out through a USB DAC into the Downstairs speakers.

The display runs an **i3** desktop (lightdm autologs the `rodnik` service account into i3) that auto-launches `firefox --kiosk` fullscreen as a **Music Assistant touch dashboard** (`https://howlr.loft.hsimah.com`) at 200% scale. Unlike the old locked chromium/greetd kiosk, this is a real i3 session — `mod+Return` drops to a kitty terminal for local admin. (Firefox rather than Chromium because trixie's Chromium build SIGTRAPs on startup — see the browser note below.) The vinyl-casting stack (Spinnik — DarkIce + Icecast + touch UI capturing the Audio-Technica LP5X) has been **retired entirely** and removed from the repo.

It also runs the [Houstn](../services/houstn.md) `metrics` profile and the [Snoot](../services/snoot.md) Beszel agent like the rest of the fleet.

Naming aside: calavera is **not** a Raspberry Pi. It's an x86_64 Surface Pro 2 — easy to forget because it sits in the same "edge device" mental bucket as viking and fjord.

## Architecture

### Services running here

`hosts/calavera/host.conf` declares `SERVICES=(howlr snoot houstn)` and `I3_ENABLED=true`. With `COMPOSE_PROFILES=client` for howlr and `COMPOSE_PROFILES=metrics` for houstn this resolves to:

| Service | Container | Profile | Purpose |
|---------|-----------|---------|---------|
| [howlr](../services/howlr.md) | `howlr-snapclient` | `client` | Snapcast client — plays the Downstairs zone through the USB DAC |
| [snoot](../services/snoot.md) | `snoot` | — | Beszel agent |
| [houstn](../services/houstn.md) | `glances` | `metrics` | Per-host metrics for Homepage |

### i3 desktop stack

```
lightdm (auto-login as rodnik)
  └── i3 session (config from hosts/calavera/i3/config)
        ├── loft-dashboard → firefox --kiosk fullscreen → Music Assistant
        └── kitty (mod+Return, admin shell)
```

`rodnik` is a locked-down display service account (created by `setup.sh` only when `I3_ENABLED=true`): home dir + login shell, member of `video`/`input`/`audio`, no sudo and no docker. lightdm autologin is configured via `/etc/lightdm/lightdm.conf.d/50-rodnik-autologin.conf`.

The i3 config, kitty config, and the generated `/usr/local/bin/loft-dashboard` launcher (plus a dedicated firefox kiosk profile under `~rodnik/.local/share/loft-dashboard-firefox/`) come from `hosts/calavera/i3/` + `host.conf`; the dashboard URL and HiDPI scale are host-config knobs (`I3_DASHBOARD_URL`, `I3_DPI`) so the i3 config itself stays generic. `I3_DPI="96"` keeps the session at native scale (1.0). Rather than upscale the whole X session, the dashboard runs Music Assistant's **mobile-mode UI**, which gives a good touch layout at 1.0 (200% was tried on-panel and was too big). `I3_DPI` still drives `~/.Xresources` `Xft.dpi` and firefox's `layout.css.devPixelsPerPx` if a future host wants upscaling.

**Touch swipe-scroll:** Firefox on X11 does nothing with touch drag unless XInput2 touch events are on, so the launcher exports `MOZ_USE_XINPUT2=1` (there's no CLI flag for it) and the kiosk `user.js` sets `dom.w3c_touch_events.enabled=1` + `apz.gtk.kinetic_scroll.enabled=true`. Together these give the Surface panel swipe-to-scroll and kinetic panning in the Music Assistant UI.

> **Browser: Firefox, not Chromium.** trixie's Chromium (150.x) SIGTRAPs immediately on startup — the `chrome_crashpad_handler` helper is invoked with a malformed argv (`chrome_crashpad_handler: --database is required`) and the browser aborts before drawing a window. It reproduces with `--no-sandbox`, `--disable-gpu`, and `--headless`, survives a package reinstall, and isn't AppArmor (no `DENIED` in `dmesg`) — i.e. the packaged build itself is broken. `firefox-esr --kiosk` works out of the box, so the dashboard runs on it. If a future trixie Chromium fixes this, revisit.

Always-on hardening (also in `setup.sh`, because this is now a 24/7 audio sink):

- `sleep.target`, `suspend.target`, `hibernate.target`, `hybrid-sleep.target` are masked
- `HandleLidSwitch*=ignore` in `/etc/systemd/logind.conf.d/i3.conf` (runs docked, lid closed)
- `iio-sensor-proxy` removed (no auto-rotation)

The dashboard screen is kept awake: the i3 config runs `xset s off -dpms` + `xset s noblank` so it never blanks or DPMS-sleeps (it's a wall dashboard), and `unclutter` hides the idle mouse cursor.

### Audio output — USB DAC on the dock

The Downstairs speakers connect to calavera via a **USB DAC** (reports as `CONEXANT CNXT Audio`, ALSA card name `Audio`) plugged into a dock USB port. howlr's snapclient targets it with:

```
SOUND_DEVICE=plughw:Audio,0
```

Pinned by card **name** (`Audio`), not number, so it survives reboots / re-enumeration. `littledog` (the container user) is in the `audio` group via `LITTLEDOG_EXTRA_GROUPS=audio`, so `howlr-snapclient` can open `/dev/snd`.

**Why a USB DAC and not the 3.5mm jack** — the Surface's internal codec (Realtek ALC280, ALSA card `PCH`) only exposes two analog output pins: the internal speaker (node 0x14) and the tablet body's own headphone jack (node 0x15). The Surface Pro 2 **dock's** 3.5mm out is *not* wired through the codec — plugging into it produces no jack event and no audio, so it's dead under Linux. The tablet's own headphone jack works, but the USB DAC is tidier (one cable to the dock) and more reliable than the flaky internal codec.

### Surface Pro 2 WiFi quirks

The Surface's Marvell 88W8797 USB WiFi flakes out under aggressive USB autosuspend. `setup.sh` installs `/etc/udev/rules.d/99-surface-wifi.rules`:

```
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="1286", ATTR{power/autosuspend}="-1"
```

That disables autosuspend for the Marvell USB WiFi adapter. The fleet-wide `/etc/cron.d/loft-wifi-watchdog` (restarts the DHCP unit if the WiFi interface loses IPv4) also runs here — but calavera's WiFi is a USB adapter with a predictable name (`wlx501ac51167c0`) managed by NetworkManager, **not** the Pis' `wlan0` + `dhcpcd`. So `host.conf` overrides the watchdog defaults via `WIFI_IFACE="wlx501ac51167c0"`, `WIFI_DHCP_UNIT="NetworkManager"`, and `WIFI_WATCHDOG_MINUTES="2"` (checks every 2 min instead of the fleet default 5, since the USB adapter drops more often).

### Networking

- LAN IP: `192.168.86.35` (per the dnsmasq A record in [`services/mushr/dnsmasq.conf`](../../services/mushr/dnsmasq.conf) and Houstn's `extra_hosts`)
- DNS: pointed at `192.168.86.28` (mushr-dns on space-needle)

## Configuration

### `host.conf`

See [`hosts/calavera/host.conf`](../../hosts/calavera/host.conf). The notable variables:

| Variable | Value | Purpose |
|----------|-------|---------|
| `SERVICES` | `(howlr snoot houstn)` | Always-on snapclient + fleet metrics |
| `I3_ENABLED` | `true` | Triggers the i3 provisioning block in `setup.sh` (rodnik + lightdm + kitty/firefox dashboard + Surface hardening) |
| `I3_DASHBOARD_URL` | `https://howlr.loft.hsimah.com` | Fullscreen firefox kiosk target (Music Assistant). Direct fallback: `http://192.168.86.28:8095` |
| `I3_DPI` | `96` | HiDPI scale for the X session + firefox dashboard (96 = 100%; MA mobile-mode handles the touch layout, so no upscaling needed) |
| `LITTLEDOG_EXTRA_GROUPS` | `audio` | snapclient needs ALSA access |
| `SSH_DISABLE_PASSWORD` | `true` | Key-only SSH |
| `WIFI_IFACE` | `wlx501ac51167c0` | USB adapter's predictable name (not `wlan0`) for the WiFi watchdog |
| `WIFI_DHCP_UNIT` | `NetworkManager` | Unit the watchdog restarts on IPv4 loss (not `dhcpcd`) |
| `WIFI_WATCHDOG_MINUTES` | `2` | Watchdog check interval in minutes (fleet default 5; USB adapter drops more often) |
| `SERVICE_ENDPOINTS` / `HEALTH_URLS` | empty | No web endpoints health-checked from this host |

### `.env` files

```bash
cp services/howlr/.env.example  services/howlr/.env       # client profile
cp services/snoot/.env.example  services/snoot/.env       # BESZEL_*
cp services/houstn/.env.example services/houstn/.env      # COMPOSE_PROFILES=metrics
```

howlr `.env` (the per-host values that matter here):

| Var | Value |
|-----|-------|
| `COMPOSE_PROFILES` | `client` |
| `SNAPSERVER_HOST` | `192.168.86.28` (space-needle) |
| `SOUND_DEVICE` | `plughw:Audio,0` (USB DAC) |
| `HOST_ID` | `calavera` |

## Operations

### First-time provisioning

> Reimaging from the old Ubuntu install to **Debian 13 + i3**? Follow the full runbook:
> [`plans/calavera-debian.md`](../../plans/calavera-debian.md). The notes below cover an
> in-place re-provision on an already-set-up host.

Same shape as the Pis — clone the repo, copy `.env` files, run `setup.sh`. The script auto-detects `I3_ENABLED=true` and runs the i3 block (installs `xorg`, `i3`, `lightdm`, `kitty`, `firefox-esr`, `unclutter`, `x11-xserver-utils`, `dmenu`; creates `rodnik`; configures lightdm autologin; deploys the `hosts/calavera/i3/` config + `~/.Xresources` + firefox kiosk profile + `/usr/local/bin/loft-dashboard`; masks sleep targets; installs the Surface WiFi udev rule; removes `iio-sensor-proxy`). It also cleans up legacy kiosk artifacts (greetd config, chromium managed policy, DPMS-off rule) and removes the `cage`/`chromium-browser`/`greetd` packages.

```bash
cd /srv/the-loft
sudo bash setup.sh
sudo reboot   # boot into the i3 session
```

> Migration note: `setup.sh` does **not** delete the old `kiosk` user. Once you've confirmed i3 works, remove it manually: `sudo userdel -r kiosk`.

### Day-to-day

```bash
loft-ctl health
loft-ctl rebuild howlr
loft-ctl update --all
```

### Verify the snapclient is connected

```bash
sudo docker logs howlr-snapclient --tail 30    # steady connection to 192.168.86.28
```

In Music Assistant on space-needle, calavera plays as `ma_calavera`, a member of the `Downstairs` (and `All`) sync groups — it inherited that membership from the retired `ma_fjord`.

### Check / set the audio output device

```bash
cat /proc/asound/cards          # 'Audio' = the USB DAC (CONEXANT)
sudo aplay -l                   # card 'Audio', device 0
sudo speaker-test -D plughw:Audio,0 -c 2 -t wav -l 2
```

## Related

- [fjord](fjord.md) — previously held the Downstairs Snapcast role
- [howlr](../services/howlr.md) — Music Assistant + Snapcast architecture
- [viking](viking.md) — the other Snapcast client (Upstairs)
- [`hsimah/posts/my-home-lab.md`](../../../hsimah/posts/my-home-lab.md) — fleet overview

## Debug & Troubleshooting

### No sound from the speakers

**Symptom:** MA plays to Downstairs but nothing comes out.

**Checks:**

1. **USB DAC present?** `cat /proc/asound/cards` should list card `Audio`. If missing, the DAC isn't enumerating — confirm the **dock is powered** (a common trap: the Surface's own battery keeps it running while the dock, and therefore its USB ports, are dead) and the cable is a data cable, then re-check.
2. **Right device?** `SOUND_DEVICE=plughw:Audio,0` in `services/howlr/.env`. Test directly with `sudo speaker-test -D plughw:Audio,0 -c 2 -t wav -l 2`.
3. **Container can't open ALSA?** `sudo docker logs howlr-snapclient` for `cannot open` errors. If the card-name form fails inside the container, fall back to the numeric (`plughw:N,0` from `aplay -l`) and `loft-ctl rebuild howlr`.
4. **Volume:** final loudness is the DAC's own level × the MA group volume. The USB DAC has its own mixer — `sudo amixer -c Audio` to unmute / raise.

### Snapclient won't connect to the snapserver

```bash
sudo docker logs howlr-snapclient --tail 50
ping 192.168.86.28
```

Confirm `SNAPSERVER_HOST=192.168.86.28` in `services/howlr/.env` and that MA/Snapserver is up on space-needle.

### Surface Pro WiFi drops out

**Causes:**

- Marvell USB autosuspend re-enabled (re-run `setup.sh` to reinstall `/etc/udev/rules.d/99-surface-wifi.rules`)
- `wlx501ac51167c0` lost its DHCP lease — the `/etc/cron.d/loft-wifi-watchdog` (here: watches `wlx501ac51167c0`, restarts `NetworkManager`, every 2 min) should recover it within ~2 minutes:

```bash
journalctl -t loft-wifi-watchdog --since '1 day ago'
```

### i3 doesn't start / drops to a login prompt

```bash
systemctl status lightdm
journalctl -u lightdm --since '5 min ago' | tail -50
```

Common causes: lightdm not enabled (`sudo systemctl enable --now lightdm`); the `rodnik` account or its `~/.config/i3/config` missing (re-run `setup.sh`); a leftover greetd still grabbing the VT (`sudo systemctl disable --now greetd`).

### Dashboard is blank / won't load Music Assistant

The `loft-dashboard` launcher loops `firefox --kiosk`, so a crash self-recovers within ~2s. If it stays blank:

- Check the URL resolves from calavera: `curl -sI https://howlr.loft.hsimah.com` (or `ping howlr.loft.hsimah.com`). If DNS/proxy is the problem, set `I3_DASHBOARD_URL="http://192.168.86.28:8095"` in `host.conf` and re-run `setup.sh`.
- Confirm space-needle's `howlr` (Music Assistant) is up.
- Everything too small/large? Adjust `I3_DPI` in `host.conf` (96 = 100%; 192 = 200%) and re-run `setup.sh` — it regenerates `~/.Xresources` (session `Xft.dpi`) and the firefox kiosk profile's `user.js` (`layout.css.devPixelsPerPx`).
- Restart just the dashboard without a reboot: as `rodnik`, `pkill firefox` (the loop relaunches it), or `i3-msg restart`.
