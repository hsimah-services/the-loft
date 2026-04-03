# Raspberry Pi Provisioning — viking & fjord

Provisioning guide for The Loft's Raspberry Pi 3 B+ fleet. Both devices (`viking` and `fjord`) get identical configuration: same user/group model as space-needle, Docker, iditarod (GitHub Actions runner), and shared shell configs.

---

## 1. Overview

| Hostname | Role | Location |
|----------|------|----------|
| `viking` | Snapcast client + GitHub Actions runner | TBD room in The Loft |
| `fjord` | Snapcast client + GitHub Actions runner | TBD room in The Loft |

Both Pis serve dual purposes:
1. **Howlr audio clients** — run `snapclient` via Docker Compose (`client` profile) to play synchronized audio from space-needle's `snapserver` (deployed later when server side is ready)
2. **CI runners** — run iditarod (self-hosted GitHub Actions runner) for arm64 builds and repo automation

---

## 2. Prerequisites (on your laptop)

1. **Create a GitHub PAT** (for iditarod)
   - Go to GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens
   - Create a token with `repo` scope for `hsimah/the-loft`
   - Save the token — you'll need it for the `.env` file

2. **Generate an SSH deploy key** — done later on the Pi itself (Phase C)

---

## 3. OS Installation

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
| WiFi country | US |
| Locale | en_US.UTF-8, timezone America/Los_Angeles |

### Write and boot

1. Insert SD card into your computer
2. Open Raspberry Pi Imager, select OS and storage
3. Apply the settings above
4. Write the image
5. Remove SD card from laptop
6. Insert SD card into the Pi and power on

---

## 4. Initial SSH Access

After first boot (~60 seconds), the Pi should be reachable via mDNS:

```bash
ssh hsimah@viking.local
# or
ssh hsimah@fjord.local
```

If mDNS doesn't resolve, find the Pi's IP from your router's DHCP lease table.

Once connected, verify the hostname:

```bash
hostname    # should print viking or fjord
uname -m    # should print aarch64
```

---

## 5. Deploy Key and Clone Repo

1. Install git (needed before `setup.sh` can run):
   ```bash
   sudo apt-get update && sudo apt-get install -y git
   ```

2. Generate an SSH key on the Pi:
   ```bash
   ssh-keygen -t ed25519 -C "<hostname>-deploy-key" -f ~/.ssh/id_ed25519 -N ""
   cat ~/.ssh/id_ed25519.pub
   ```

3. Copy the public key output, then on GitHub:
   - Go to `hsimah/the-loft` → Settings → Deploy keys → Add deploy key
   - Title: `viking` (or `fjord`)
   - Key: paste the public key
   - Allow write access: No (read-only is fine)

4. Clone the repo:
   ```bash
   sudo mkdir /srv/the-loft
   sudo chown hsimah:hsimah /srv/the-loft
   git clone git@github.com:hsimah/the-loft.git /srv/the-loft
   ```

---

## 6. Configure .env Files

### iditarod

```bash
cd /srv/the-loft
cp services/iditarod/.env.example services/iditarod/.env
nano services/iditarod/.env
```

Fill in:

```bash
GITHUB_OWNER=hsimah
GITHUB_REPO=the-loft
GITHUB_ACCESS_TOKEN=<your-PAT>
RUNNER_NAME=viking          # or fjord
RUNNER_LABELS=viking,self-hosted,linux,arm64   # or fjord,...
DOCKER_GID=999
```

> Note: `DOCKER_GID` defaults to 999 which is typical for Debian. If Docker uses a different GID after install, you can update it — `setup.sh` will detect the correct value during build.

### howlr (skip for now)

Don't create `services/howlr/.env`. `setup.sh` will warn and skip howlr, which is correct until the server side on space-needle is ready.

---

## 7. Run setup.sh

```bash
cd /srv/the-loft
sudo bash setup.sh
```

The script will:
- Install system packages (git, curl, jq)
- Skip storage mount (none configured in `hosts/viking/host.conf`)
- Create groups (`pack-member`)
- Create users (`littledog` with `audio` group, `adminhabl`, configure `hsimah`)
- Harden SSH (`AllowUsers hsimah`, disable password auth)
- Configure sudo for `adminhabl`
- Set up shared bashrc.d sourcing
- Install Docker CE
- Configure Docker log rotation
- Build and start iditarod (with correct Docker GID)
- Warn and skip howlr (no `.env`)

The script is idempotent — safe to re-run at any time.

---

## 8. Post-Setup Verification

### Set adminhabl password

```bash
sudo passwd adminhabl
```

### Remove hsimah from sudoers

Raspberry Pi OS grants the initial user passwordless sudo via drop-in files. Remove them so only `adminhabl` has sudo:

```bash
su - adminhabl
sudo rm -f /etc/sudoers.d/010_pi-nopasswd /etc/sudoers.d/90-cloud-init-users
exit
```

Verify hsimah no longer has sudo:

```bash
sudo echo test
# Expected: permission denied
```

### Verify SSH hardening

```bash
sudo sshd -T | grep -E 'allowusers|passwordauthentication'
# Expected: allowusers hsimah / passwordauthentication no
```

### Verify Docker

```bash
sudo docker run --rm hello-world
```

### Verify iditarod

```bash
# Check container is running
sudo docker ps --filter name=iditarod

# Check logs for successful registration
sudo docker logs iditarod
```

Then on GitHub: Settings → Actions → Runners — should show `viking` (or `fjord`) as "Idle".

### Verify shared bashrc.d

```bash
exit
ssh hsimah@viking.local
# Prompt should show the shared format
```

---

## 9. User & Group Model

Identical to space-needle:

| User | UID | Primary Group | Shell | Additional Groups | Role |
|------|-----|---------------|-------|-------------------|------|
| `littledog` | 1003 | `pack-member` (1003) | `/usr/sbin/nologin` | `docker`, `audio` | Service account for containers |
| `adminhabl` | auto | `adminhabl` | `/bin/bash` | `sudo`, `docker`, `pack-member` | Admin (passworded, no SSH) |
| `hsimah` | auto | `hsimah` | `/bin/bash` | `pack-member` | SSH user, manages repo |

**Differences from space-needle:**
- `littledog` gets `audio` group (for howlr sound output) but **not** `render` or `video` (no GPU workloads)
- No Pawpcorn, stellarr, or pupyrus services

---

## 10. SSH Hardening

The setup script applies:

| Setting | Value | Reason |
|---------|-------|--------|
| `AllowUsers hsimah` | Only hsimah can SSH in | Same as space-needle |
| `PasswordAuthentication no` | Disabled | Key-only access; Pis are on WiFi and more exposed |

---

## 11. Docker

Docker CE is installed via the official apt repository (same method as space-needle). The setup script also installs:
- `daemon.json` from the repo for log rotation (10m max-size, 3 files)
- Docker group membership for `littledog` and `adminhabl`

---

## 12. Directory Structure

Pis use a simpler layout than space-needle (no `/mammoth` volume, no `/opt` service configs):

```
/srv/the-loft/                      Git clone of the repo
  setup.sh                          Unified host provisioner
  hosts/viking/host.conf            Host configuration (services, users, storage)
  services/
    iditarod/
      docker-compose.yml            Compose file
      Dockerfile                    Pi-compatible Dockerfile (parameterized GID)
      entrypoint.sh                 Runner entrypoint
      .env                          Secrets (gitignored)
      .env.example                  Template
    howlr/
      docker-compose.yml            Compose file (client profile for Pis)
      .env                          Secrets (gitignored, created later)
```

No additional directories are created. All iditarod state lives in the Docker volume (`runner-work`).

---

## 13. Shared Shell Config (bashrc.d)

The setup script adds a `source` line to both `hsimah` and `adminhabl`'s `~/.bashrc`:

```bash
source /srv/the-loft/bashrc.d
```

This gives both users the shared prompt, aliases, key bindings, and nano config from the repo. The bashrc.d resolves `__REPO_DIR` dynamically via `BASH_SOURCE[0]`, so aliases like `loft-ctl` and `nano --rcfile` resolve correctly regardless of clone path.

---

## 14. WiFi Power Management

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

**Note:** Only needed when howlr/snapclient is deployed. Skip this step until then. If the Pi uses wired Ethernet, this step is unnecessary.

---

## 15. Future: howlr (snapclient)

When the howlr server side is deployed on space-needle, each Pi will run `snapclient` via Docker Compose:

1. Create the `.env` file:
   ```bash
   cp services/howlr/.env.example services/howlr/.env
   nano services/howlr/.env
   # Set SNAPSERVER_HOST, SOUND_DEVICE, HOST_ID
   ```

2. Re-run setup or start manually:
   ```bash
   cd /srv/the-loft
   sudo bash setup.sh
   # or manually:
   sudo docker compose -f services/howlr/docker-compose.yml --profile client up -d
   ```

3. Apply WiFi power management fix (section 14)

The howlr compose file uses profiles — Pis use the `client` profile (snapclient only), while space-needle uses the `server` profile (snapserver + shairport-sync + librespot).

---

## Checklist

Per-Pi provisioning checklist:

- [ ] Create GitHub PAT with `repo` scope
- [ ] Flash Raspberry Pi OS Lite 64-bit with hostname, SSH key, WiFi
- [ ] Boot and verify SSH access via `<hostname>.local`
- [ ] Generate deploy key on Pi and add to GitHub repo
- [ ] Clone repo to `/srv/the-loft`
- [ ] Copy `services/iditarod/.env.example` to `services/iditarod/.env` and fill in secrets
- [ ] Skip howlr `.env` (deploy later)
- [ ] Run `sudo bash setup.sh` from `/srv/the-loft`
- [ ] Set adminhabl password: `sudo passwd adminhabl`
- [ ] Verify SSH hardening: `sudo sshd -T | grep -E 'allowusers|passwordauthentication'`
- [ ] Verify Docker: `sudo docker run --rm hello-world`
- [ ] Verify iditarod: `sudo docker ps --filter name=iditarod` + check GitHub Runners
- [ ] Verify shared bashrc.d: log out and back in, check prompt
