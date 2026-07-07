# `setup.sh`

> Idempotent host provisioner — reads `hosts/$(hostname)/host.conf` and bootstraps a Loft host from scratch (or top of an existing one).

## Overview

[`setup.sh`](../../setup.sh) is the unified host provisioner: one script that brings any host in the fleet from a clean Debian/Ubuntu install to a fully configured Loft member. It's idempotent — every re-run reconciles the host with `hosts/$(hostname)/host.conf`, so the same script handles fresh provisioning, recovery after a re-image, and routine drift correction.

The script auto-detects the host by hostname and sources its [`host.conf`](../../hosts/), so a single invocation works the same on [space-needle](../hosts/space-needle.md), [viking](../hosts/viking.md), [fjord](../hosts/fjord.md), or [calavera](../hosts/calavera.md). It does everything except fill in `.env` files — those have to exist before the docker-compose stage so individual services can start.

## Architecture

`setup.sh` runs in numbered phases. Each phase is conditional on the host config and is safe to re-run:

| # | Phase | Driven by |
|---|-------|-----------|
| 1 | Preflight — must run as root on Debian/Ubuntu | — |
| 1a | Source `hosts/$(hostname)/host.conf` | hostname |
| 2 | `apt install` base packages (`git curl jq skopeo kitty-terminfo`, plus `xfsprogs` if `STORAGE_FS=xfs`) | `STORAGE_FS` |
| 3 | Storage mount — add fstab entry, mount `STORAGE_MOUNT` | `STORAGE_DEVICE` / `STORAGE_MOUNT` / `STORAGE_FS` |
| 4 | Groups — create `pack-member` (GID 1003) | — |
| 5 | Users — `littledog` (UID 1003, nologin service account), `adminhabl` (SSH login + sudo admin), `rodnik` (i3 display account, i3 hosts) | `LITTLEDOG_EXTRA_GROUPS`, `I3_ENABLED` |
| 6 | SSH lockdown — `AllowUsers adminhabl`, optional `PasswordAuthentication no` | `SSH_DISABLE_PASSWORD` |
| 7 | Sudoers entry for `adminhabl` (`/etc/sudoers.d/adminhabl`, validated with `visudo -c`) | — |
| 8 | Shell config — `.bashrc` sources [`bashrc.d`](../../bashrc.d), `.inputrc` includes [`inputrc.d`](../../inputrc.d) for `adminhabl` | — |
| 9 | Directory structure — `CONFIG_DIRS` (755) and `MEDIA_DIRS` (775), both owned `littledog:pack-member` | `CONFIG_DIRS`, `MEDIA_DIRS` |
| 9a | `/var/log/loft` for log output | — |
| 9b | `/var/lib/loft/deploy` for [deploy-pull.sh](deploy-pull.md) state | — |
| 10 | Docker install — Docker CE + Compose plugin from `download.docker.com`, add `littledog` and `adminhabl` to the `docker` group | — |
| 10a | Install [`daemon.json`](../../daemon.json) (log rotation), restart Docker if changed | — |
| 10b | Create the `loft-proxy` Docker bridge network (idempotent) | — |
| 11 | For each service in `SERVICES`: build (if a `Dockerfile` is present), then `docker compose up -d` using the override-aware args from [`common.sh`](common-sh.md) | `SERVICES` |
| 11a | Source any per-service `services/<name>/setup.sh` after deployment | `SERVICES` |
| 11b | i3 desktop provisioning — `xorg`, `i3`, `xterm`, `lightdm`; `rodnik` autologin → i3; mask suspend/sleep; Surface Pro 2 WiFi udev rule; remove `iio-sensor-proxy`; clean up legacy kiosk artifacts | `I3_ENABLED` |
| 12 | Cron — `/etc/cron.d/loft-wifi-watchdog` (every 5min; watches `WIFI_IFACE`, restarts `WIFI_DHCP_UNIT` on IPv4 loss; no-op on hosts without the interface) + one `/etc/cron.d/loft-deploy-<name>` per `DEPLOY_TARGETS` entry (hourly, runs [`deploy-pull.sh`](deploy-pull.md)) | `WIFI_IFACE`, `WIFI_DHCP_UNIT`, `DEPLOY_TARGETS` |
| 13 | Verification summary — print users, mount status, SSH config, running containers, i3 status | — |

Phase 11 short-circuits a service if its `.env.example` exists but `.env` doesn't — the script logs a warning and moves on instead of failing the whole run.

## Configuration

`setup.sh` itself takes no arguments. All configuration comes from `hosts/$(hostname)/host.conf` (a bash-sourced file) — see the host pages for the full per-host values:

- [space-needle](../hosts/space-needle.md#configuration) — storage volume, `render,video` groups for Plex, `DEPLOY_TARGETS` for the pawst sites
- [viking](../hosts/viking.md#configuration) / [fjord](../hosts/fjord.md#configuration) — Pi hosts, no storage, `SSH_DISABLE_PASSWORD=true`
- [calavera](../hosts/calavera.md#configuration) — i3 host, `I3_ENABLED=true`, always-on Snapcast client

### Things `setup.sh` writes to the host

| Path | Owner | Purpose |
|------|-------|---------|
| `/etc/fstab` (one line) | root | Adds `STORAGE_DEVICE STORAGE_MOUNT STORAGE_FS defaults 0 0` |
| `STORAGE_MOUNT` (e.g. `/mammoth`) | — | Mountpoint for the data volume |
| `/etc/ssh/sshd_config` | root | `AllowUsers adminhabl` + optional `PasswordAuthentication no` |
| `/etc/sudoers.d/adminhabl` | root (0440) | `adminhabl ALL=(ALL:ALL) ALL` |
| `/home/adminhabl/.bashrc` | user | Sources `bashrc.d` from the repo |
| `/home/adminhabl/.inputrc` | user | Includes `inputrc.d` from the repo |
| `CONFIG_DIRS[*]` | `littledog:pack-member` 755 | Per-service config dirs (typically under `/opt`) |
| `MEDIA_DIRS[*]` | `littledog:pack-member` 775 | Media dirs (e.g. `/mammoth/library/movies`) |
| `/var/log/loft` | root | Log directory, target for `deploy-pull.sh` output |
| `/var/lib/loft/deploy` | root 755 | State directory, stores `<name>.version` files |
| `/etc/docker/daemon.json` | root | Copied from repo `daemon.json` (log rotation) |
| `/etc/cron.d/loft-wifi-watchdog` | root 644 | restart `WIFI_DHCP_UNIT` (default `dhcpcd`) if `WIFI_IFACE` (default `wlan0`) loses IPv4 |
| `/etc/cron.d/loft-deploy-<name>` | root 644 | One file per `DEPLOY_TARGETS` entry (cleared and reinstalled every run) |
| `/etc/lightdm/lightdm.conf.d/50-rodnik-autologin.conf` | root | Autologin `rodnik` → i3 (i3 hosts) |
| `/etc/udev/rules.d/99-surface-wifi.rules` | root | Disable Marvell WiFi USB autosuspend (i3 hosts) |
| `/etc/systemd/logind.conf.d/i3.conf` | root | Ignore lid switch (i3 hosts) |

Nothing is deleted from disk except `/etc/cron.d/loft-deploy-*` (re-created from `DEPLOY_TARGETS` each run, so a removed entry stops being scheduled).

## Operations

```bash
# Fresh host (or re-provision an existing one)
cd /srv/the-loft
sudo bash setup.sh
```

`setup.sh` only needs to be re-run when:

- A new service is added to the host's `SERVICES` list (or `services/<name>/setup.sh` changes)
- `CONFIG_DIRS` / `MEDIA_DIRS` change (new directories need creating with correct ownership)
- `DEPLOY_TARGETS` changes (cron files need re-installing)
- `LITTLEDOG_EXTRA_GROUPS` changes (e.g. adding `render` for a new GPU)
- `I3_ENABLED` flips on
- Docker `daemon.json` changes

For routine code/config changes after the host is provisioned, use [`loft-ctl update`](loft-ctl.md) — it pulls the repo and rebuilds services without re-running the OS-level provisioning.

After the first run, fill in any `.env` files that were skipped with warnings, then re-run `setup.sh` (or just `loft-ctl start <service>` for that service):

```bash
# Example: stellarr was skipped because services/stellarr/.env was missing
cp services/stellarr/.env.example services/stellarr/.env
$EDITOR services/stellarr/.env
sudo bash setup.sh
```

## Related

- [`loft-ctl`](loft-ctl.md) — day-to-day control of services after the host is provisioned
- [`common.sh`](common-sh.md) — sourced by `setup.sh` to resolve per-service compose args (base + per-host override)
- [`deploy-pull.sh`](deploy-pull.md) — installed as `/etc/cron.d/loft-deploy-*` by phase 12
- Host pages: [space-needle](../hosts/space-needle.md), [viking](../hosts/viking.md), [fjord](../hosts/fjord.md), [calavera](../hosts/calavera.md)
- Root [`README.md`](../../README.md) — Quick Start section

## Debug & Troubleshooting

### "No host config found at hosts/<hostname>/host.conf"

**Cause:** `hostname` doesn't match any directory under `hosts/`. Common after re-imaging a host without setting its hostname, or when running the script from a checkout cloned for a different host.

**Fix:**

```bash
hostname                                        # what does the system think it's called?
ls hosts/                                       # which configs exist?
sudo hostnamectl set-hostname <one-of-those>    # set it to match
sudo bash setup.sh
```

### A service was skipped with "<service>: .env file missing"

**Cause:** The service has a `services/<service>/.env.example` template but no `.env` file. `setup.sh` deliberately doesn't fail the whole run — it warns and continues so the other services still come up.

**Fix:**

```bash
cp services/<service>/.env.example services/<service>/.env
$EDITOR services/<service>/.env       # fill in real values
sudo bash setup.sh                    # or: loft-ctl start <service>
```

### Sudoers validation failed

**Symptom:** `setup.sh` prints "Sudoers file validation failed, removing" and exits.

**Cause:** `/etc/sudoers.d/adminhabl` failed `visudo -c`. Usually means the file was hand-edited or an upstream change broke the format. `setup.sh` removes the broken file before exiting so the system isn't left with a syntax error that blocks sudo.

**Fix:** Inspect the script's heredoc for the offending line, then re-run. If sudo is now broken (you can't `sudo` anymore), recover via the root account or single-user mode.

### Storage mount entry exists but `/mammoth` isn't mounted

**Cause:** `setup.sh` adds to `/etc/fstab` only if the line is missing, and runs `mount` only if the path isn't already a mountpoint. If a previous run partially succeeded, the fstab line can exist while the mount has been lost.

**Fix:**

```bash
sudo mount /mammoth                # uses the fstab entry
mountpoint -q /mammoth && echo OK
sudo bash setup.sh                 # idempotent re-run
```

If the device path changed (new disk, different drive letter), edit `STORAGE_DEVICE` in `host.conf`, remove the old fstab line, then re-run.

### Docker daemon won't restart after `daemon.json` change

**Symptom:** `setup.sh` reports "Installed daemon.json, restarting Docker..." and then hangs or fails.

**Cause:** A malformed `daemon.json` (rare — the file is in-repo and CI-validated) or another process holding Docker's lock.

**Fix:**

```bash
sudo journalctl -u docker --since '5 min ago' --no-pager | tail -50
sudo dockerd --debug                # foreground run to see parse errors
```

Restore the previous `daemon.json` (`git checkout daemon.json`) if the new one is the cause.

### i3 provisioning ran but the host still boots into the old kiosk

**Cause:** A leftover greetd session is still grabbing the VT, or lightdm didn't get enabled.

**Fix:** Reboot after `setup.sh`. If it persists, `sudo systemctl disable --now greetd` and `sudo systemctl enable --now lightdm`. `setup.sh` also leaves the old `kiosk` user in place — remove it manually once i3 is confirmed: `sudo userdel -r kiosk`.

### Cron deploy puller entries didn't update

**Cause:** A `DEPLOY_TARGETS` entry was renamed or removed. `setup.sh` cleans `/etc/cron.d/loft-deploy-*` at the start of phase 12 and reinstalls only the entries currently in the array, so the old file should be gone — but if phase 12 was skipped (e.g. a Docker-install failure stopped the run earlier), the stale file remains.

**Fix:**

```bash
ls /etc/cron.d/loft-deploy-*
sudo rm /etc/cron.d/loft-deploy-<stale-name>   # if any
sudo bash setup.sh                              # phase 12 reinstalls from DEPLOY_TARGETS
```
