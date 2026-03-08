# Raspberry Pi Provisioning — viking & fjord

Provisioning guide for The Loft's Raspberry Pi 4 fleet. Both devices (`viking` and `fjord`) get identical configuration: same user/group model as space-needle, Docker, iditarod (GitHub Actions runner), and shared shell configs.

---

## 1. Overview

| Hostname | Role | Location |
|----------|------|----------|
| `viking` | Snapcast client + GitHub Actions runner | TBD room in The Loft |
| `fjord` | Snapcast client + GitHub Actions runner | TBD room in The Loft |

Both Pis serve dual purposes:
1. **Howlr audio clients** — run `snapclient` to play synchronized audio from space-needle's `snapserver` (future, added when howlr is implemented)
2. **CI runners** — run iditarod (self-hosted GitHub Actions runner) for arm64 builds and repo automation

---

## 2. OS Installation

Use **Raspberry Pi Imager** to flash **Raspberry Pi OS Lite (64-bit, Bookworm)** onto each Pi's SD card.

### Imager settings (gear icon / Ctrl+Shift+X)

| Setting | Value |
|---------|-------|
| Hostname | `viking` or `fjord` |
| Enable SSH | Yes, public-key only |
| SSH public key | `~/.ssh/id_ed25519.pub` (your key) |
| Username | `hsimah` |
| Password | Set a temporary password (SSH key is primary) |
| WiFi SSID | Your network SSID |
| WiFi password | Your network password |
| WiFi country | AU |
| Locale | en_AU.UTF-8, timezone Australia/Sydney |

### Write and boot

1. Insert SD card into your computer
2. Open Raspberry Pi Imager, select OS and storage
3. Apply the settings above
4. Write the image
5. Insert SD card into the Pi and power on

---

## 3. Initial SSH Access

After first boot, the Pi should be reachable via mDNS:

```bash
# From your workstation
ssh hsimah@viking.local
# or
ssh hsimah@fjord.local
```

If mDNS doesn't resolve, find the Pi's IP from your router's DHCP lease table or use:

```bash
# Scan local network for SSH
nmap -p 22 --open 192.168.1.0/24
```

Once connected, verify the hostname:

```bash
hostname    # should print viking or fjord
uname -m    # should print aarch64
```

---

## 4. Running setup.sh

The setup script handles everything from user creation to Docker installation. Clone the repo and run:

```bash
# Clone the repo
sudo git clone <repo-url> /srv/$(hostname)

# Copy .env files for iditarod
cd /srv/$(hostname)/raspberry-pi/iditarod
sudo cp .env.example .env
sudo nano .env   # fill in GITHUB_ACCESS_TOKEN, adjust RUNNER_NAME/LABELS

# Run setup as root
sudo bash /srv/$(hostname)/raspberry-pi/setup.sh
```

The script is idempotent — safe to re-run at any time.

---

## 5. User & Group Model

Identical to space-needle:

| User | UID | Primary Group | Shell | Additional Groups | Role |
|------|-----|---------------|-------|-------------------|------|
| `littledog` | 1003 | `pack-member` (1003) | `/usr/sbin/nologin` | `docker` | Service account for containers |
| `adminhabl` | auto | `adminhabl` | `/bin/bash` | `sudo`, `docker`, `pack-member` | Admin (passworded, no SSH) |
| `hsimah` | auto | `hsimah` | `/bin/bash` | `pack-member` | SSH user, manages repo |

**Differences from space-needle:**
- `littledog` does **not** get `render` or `video` groups (no GPU workloads on Pis)
- No Plex, media, or pupyrus services

---

## 6. SSH Hardening

The setup script applies:

| Setting | Value | Reason |
|---------|-------|--------|
| `AllowUsers hsimah` | Only hsimah can SSH in | Same as space-needle |
| `PasswordAuthentication no` | Disabled | Key-only access; Pis are on WiFi and more exposed |

After setup, verify:

```bash
sudo sshd -T | grep -E 'allowusers|passwordauthentication'
# allowusers hsimah
# passwordauthentication no
```

---

## 7. Docker

Docker CE is installed via the official apt repository (same method as space-needle). The setup script also installs:
- `daemon.json` from the repo for log rotation (10m max-size, 3 files)
- Docker group membership for `littledog` and `adminhabl`

Verify after setup:

```bash
sudo docker version
sudo docker run --rm hello-world
```

---

## 8. iditarod (GitHub Actions Runner)

Each Pi runs its own iditarod instance, registered as a separate runner to the same repo.

### Configuration

Edit `/srv/<hostname>/raspberry-pi/iditarod/.env`:

```bash
GITHUB_OWNER=hsimah
GITHUB_REPO=space-needle
GITHUB_ACCESS_TOKEN=<PAT with repo scope>
RUNNER_NAME=viking          # or fjord
RUNNER_LABELS=self-hosted,linux,arm64,viking   # or fjord
DOCKER_GID=999              # check with: getent group docker | cut -d: -f3
```

### Build and start

The setup script handles this automatically, but to run manually:

```bash
cd /srv/$(hostname)/raspberry-pi/iditarod

# Build with correct Docker GID
sudo docker compose build --build-arg DOCKER_GID=$(getent group docker | cut -d: -f3)

# Start
sudo docker compose up -d
```

### Verify

```bash
# Check container is running
sudo docker ps --filter name=iditarod

# Check logs for successful registration
sudo docker logs iditarod

# Verify runner appears in GitHub
# Settings → Actions → Runners — should show viking/fjord as "Idle"
```

**Important:** The PAT needs `repo` scope for repo-level runner registration. Use the repo-level API (`/repos/{owner}/{repo}/actions/runners/`), not org-level.

---

## 9. Directory Structure

Pis use a simpler layout than space-needle (no `/mammoth` volume, no `/opt` service configs):

```
/srv/<hostname>/                    Git clone of space-needle repo
  raspberry-pi/
    setup.sh                        Pi provisioning script
    iditarod/
      docker-compose.yml            Pi-specific compose
      Dockerfile                    Pi-specific Dockerfile (parameterized GID)
      entrypoint.sh                 Runner entrypoint
      .env                          Secrets (gitignored)
```

No additional directories are created. All state lives in the Docker volume (`runner-work`).

---

## 10. Shared Shell Config (bashrc)

The setup script adds a `source` line to both `hsimah` and `adminhabl`'s `~/.bashrc`:

```bash
source /srv/<hostname>/bashrc
```

This gives both users the shared prompt, aliases, key bindings, and nano config from the repo. The bashrc resolves `__REPO_DIR` dynamically via `BASH_SOURCE[0]` (line 76), so aliases like `space-needle-ctl` and `nano --rcfile` resolve correctly regardless of clone path.

The `space-needle-ctl` alias will point to `/srv/<hostname>/space-needle-ctl`. Running it on a Pi to deploy space-needle services will harmlessly fail (those compose files reference space-needle paths), which is correct behavior.

---

## 11. WiFi Power Management

WiFi power saving causes audio dropouts when snapclient is running. Disable it:

```bash
# Immediate
sudo iw wlan0 set power_save off

# Persistent (via NetworkManager dispatcher)
sudo tee /etc/NetworkManager/dispatcher.d/99-wifi-powersave <<'EOF'
#!/bin/bash
iw wlan0 set power_save off
EOF
sudo chmod +x /etc/NetworkManager/dispatcher.d/99-wifi-powersave
```

**Note:** The setup script does NOT do this automatically — it's only relevant when howlr/snapclient is installed. Add this step when implementing howlr Phase 1.

If the Pi uses wired Ethernet, this step is unnecessary (and `wlan0` won't exist).

---

## 12. Future: howlr (snapclient)

When howlr is implemented (see `howlr/plan.md`), each Pi will additionally run `snapclient`:

```bash
# Install snapclient (arm64 .deb from GitHub releases)
wget https://github.com/badaix/snapcast/releases/download/v0.28.0/snapclient_0.28.0-1_arm64.deb
sudo dpkg -i snapclient_0.28.0-1_arm64.deb
sudo apt install -f -y

# Configure
sudo nano /etc/default/snapclient
# SNAPCLIENT_OPTS="--host <space-needle-ip> --soundcard <alsa-device> --hostID <room-name>"

# Enable and start
sudo systemctl enable snapclient
sudo systemctl start snapclient
```

This will be scripted as part of howlr implementation. For now, the Pis run iditarod only.

---

## Checklist

Per-Pi provisioning checklist:

- [ ] Flash Raspberry Pi OS Lite 64-bit with hostname, SSH key, WiFi
- [ ] Boot and verify SSH access via `<hostname>.local`
- [ ] Clone repo to `/srv/<hostname>`
- [ ] Copy `.env.example` to `.env` and fill in secrets
- [ ] Run `sudo bash /srv/<hostname>/raspberry-pi/setup.sh`
- [ ] Set adminhabl password: `sudo passwd adminhabl`
- [ ] Verify SSH hardening: `sudo sshd -T | grep -E 'allowusers|passwordauthentication'`
- [ ] Verify Docker: `sudo docker run --rm hello-world`
- [ ] Verify iditarod: check GitHub Settings → Actions → Runners
- [ ] Verify shared bashrc: log out and back in, check prompt
