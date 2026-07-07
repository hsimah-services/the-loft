# calavera Reimage — Ubuntu → Debian 13 + i3

Reimage guide for `calavera` (Surface Pro 2, x86_64, LAN `192.168.86.35`). Replaces the
existing Ubuntu install with **Debian 13 (trixie)** and provisions the i3 desktop via
`setup.sh`. calavera is the always-on **Downstairs** Snapcast client (took over from
`fjord`), plus `snoot` (Beszel agent) and `houstn` metrics.

> **⚠️ Downtime:** reimaging takes Downstairs Snapcast audio offline until `setup.sh`
> finishes and `howlr` comes back up.

---

## 1. Overview

| Hostname | Role | Hardware |
|----------|------|----------|
| `calavera` | Downstairs Snapcast client + Beszel agent + i3 desktop | Surface Pro 2 (Haswell, Marvell WiFi, USB DAC audio) |

Services (`hosts/calavera/host.conf` → `SERVICES=(howlr snoot houstn)`):
1. **howlr** — `snapclient` (`client` profile) playing synchronized audio from space-needle's `snapserver` out the **USB DAC**
2. **snoot** — Beszel agent reporting metrics to the houstn hub
3. **houstn** — `metrics` profile (glances)

Display: lightdm autologin as service account **`rodnik`** → i3 (`I3_ENABLED="true"`),
auto-launching `firefox --kiosk` fullscreen as a **Music Assistant touch dashboard** at 200% scale.

---

## 2. Prerequisites

- The merged branch **`calavera-fjord-swap`** carries both the i3 provisioning and the
  adminhabl-only SSH login. The reimaged box tracks this branch until i3 is proven on
  hardware, then it gets merged to `main`.
- Debian 13 **netinst with firmware included** (`debian-13.x.x-amd64-netinst.iso` from
  `cdimage.debian.org`). The bundled non-free firmware is required for the Surface Pro 2's
  Marvell WiFi and the USB DAC.
- Surface **Type Cover** (keyboard) and the **powered dock** — the DAC only enumerates
  when the dock has power.
- Your SSH public key (`~/.ssh/id_ed25519.pub`).

---

## 3. Build the installer USB (on your workstation)

```bash
sudo dd if=debian-13.x.x-amd64-netinst.iso of=/dev/sdX bs=4M status=progress oflag=sync
```
(or Balena Etcher). Replace `/dev/sdX` with the USB stick.

---

## 4. Boot the Surface Pro 2 from USB

1. Attach the Type Cover and the powered dock.
2. Power off. Hold **Volume-Down**, tap **Power**, release Volume-Down at the Surface logo
   → boots removable media. Secure Boot can stay on (Debian's installer is signed).

---

## 5. Debian install choices

| Setting | Value |
|---------|-------|
| Hostname | **`calavera`** — mandatory; `setup.sh` requires `hosts/$(hostname)/host.conf` to exist |
| Primary user | **`adminhabl`** — this is the SSH login |
| Partitioning | Guided, use entire disk (wipes Ubuntu; reuse the EFI partition) |
| Software selection | **Untick** "Debian desktop environment"; **tick** "SSH server" + "standard system utilities" |

`setup.sh` installs i3/lightdm itself, so no desktop is selected here.

---

## 6. First boot — bootstrap

From your workstation, seed key auth **before** `setup.sh` disables password login:

```bash
ssh-copy-id adminhabl@192.168.86.35
ssh adminhabl@192.168.86.35
```

On calavera:
```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/hsimah-services/the-loft.git
cd the-loft && git checkout calavera-fjord-swap
```

---

## 7. Create howlr's `.env`

`.env` files are gitignored, so this must be recreated or `setup.sh` skips howlr
(Phase 11 short-circuits a service whose `.env.example` exists but `.env` doesn't):

```bash
# the-loft/services/howlr/.env
COMPOSE_PROFILES=client
SNAPSERVER_HOST=192.168.86.28        # space-needle's IP — verify
SOUND_DEVICE=plughw:Audio,0          # USB DAC (ALSA card "Audio", CONEXANT) — NOT "default"
HOST_ID=calavera                     # per-HOST id (= hostname) → MA player ma_calavera.
                                     # NOT the room/group name — "Downstairs" is a sync GROUP
                                     # you create in MA and add ma_calavera to.
```

> The Surface Pro 2 **dock 3.5mm jack is dead under Linux** — audio must go out the USB DAC.
> `plughw:Audio,0` is the DAC; confirm the card name with `aplay -l` if it differs.

---

## 8. Run the provisioner

```bash
sudo ./setup.sh
```

This creates `adminhabl` (already present) + `rodnik`, sets `AllowUsers adminhabl` +
`PasswordAuthentication no`, installs Docker + i3/lightdm/kitty/firefox-esr (rodnik autologin
→ i3), deploys the repo's i3 config (`hosts/calavera/i3/`) and generates
`/usr/local/bin/loft-dashboard` + a firefox kiosk profile + `~/.Xresources` from `host.conf`
(`I3_DASHBOARD_URL`, `I3_DPI`), applies the Marvell WiFi USB-autosuspend udev rule, drops
`splash` from the kernel cmdline (plymouth VT7 race), and brings up `howlr` / `snoot` / `houstn`.

The i3 session auto-launches `firefox --kiosk` fullscreen as the **Music Assistant dashboard**
(`https://howlr.loft.hsimah.com`) at **200% scale** (`I3_DPI="192"`, needed because the
Surface's 1920×1080 panel is tiny at 96 DPI). `mod+Return` (Super) drops to a kitty terminal.

> **Why not Chromium?** trixie's Chromium (150.x) SIGTRAPs on startup — its `chrome_crashpad_handler`
> helper gets a malformed argv (`--database is required`) and the browser aborts before drawing,
> regardless of `--no-sandbox`/`--disable-gpu`/`--headless`. Firefox works out of the box, so the
> dashboard runs on `firefox-esr`.

---

## 9. Reboot & verify

```bash
sudo reboot
```

- Lands on the i3 session (rodnik autologin, no VT7 hang). If lightdm fails its first
  start, the `Restart=` override recovers it.
- Dashboard: firefox comes up fullscreen (`--kiosk`) on the Music Assistant UI at 200% scale.
  If it can't reach `howlr.loft.hsimah.com` (DNS/proxy), edit `I3_DASHBOARD_URL` in `host.conf`
  to the direct `http://192.168.86.28:8095` and re-run `sudo ./setup.sh`. Touch works;
  `mod+Return` opens kitty for admin.
- Audio: Downstairs rejoins Snapcast — `docker logs howlr-snapclient`; confirm `ma_calavera`
  plays in the Downstairs/All groups.
- WiFi stable (issue #65 udev rule applied): `iw dev wlan0 link`.
- SSH lockdown correct: `sudo grep AllowUsers /etc/ssh/sshd_config` → `AllowUsers adminhabl`.

---

## 10. Wrap-up

- Once i3 + audio are proven on hardware, **merge `calavera-fjord-swap` → `main`**.
- calavera is freshly imaged, so no `migrate-drop-hsimah.sh` is needed (that's for existing
  hosts still on the `hsimah` login).
