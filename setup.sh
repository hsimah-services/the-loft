#!/usr/bin/env bash
# setup.sh — idempotent setup for space-needle home server
# Must be run as root on Debian/Ubuntu
set -euo pipefail

REPO_DIR="/home/hsimah/projects/space-needle"

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ─── 1. Preflight ────────────────────────────────────────────────────────────
info "Preflight checks..."

if [[ $EUID -ne 0 ]]; then
  error "This script must be run as root"
  exit 1
fi

if ! command -v apt-get &>/dev/null; then
  error "This script requires a Debian/Ubuntu system (apt-get not found)"
  exit 1
fi

# ─── 2. System packages ──────────────────────────────────────────────────────
info "Installing system packages..."
apt-get update -qq
apt-get install -y -qq git curl jq xfsprogs > /dev/null

# ─── 3. Storage mount ────────────────────────────────────────────────────────
info "Configuring storage mount..."

FSTAB_ENTRY="/dev/sda1 /mammoth xfs defaults 0 0"

if ! grep -qF "/dev/sda1" /etc/fstab; then
  echo "$FSTAB_ENTRY" >> /etc/fstab
  info "Added /mammoth to fstab"
fi

mkdir -p /mammoth

if ! mountpoint -q /mammoth; then
  mount /mammoth
  info "Mounted /mammoth"
else
  info "/mammoth already mounted"
fi

# ─── 4. Groups ───────────────────────────────────────────────────────────────
info "Configuring groups..."

if ! getent group pack-member &>/dev/null; then
  groupadd -g 1003 pack-member
  info "Created group pack-member (GID 1003)"
else
  info "Group pack-member already exists"
fi

# ─── 5. Users ────────────────────────────────────────────────────────────────
info "Configuring users..."

# littledog — service account
if ! id littledog &>/dev/null; then
  useradd -u 1003 -g pack-member -s /usr/sbin/nologin -M littledog
  info "Created user littledog"
else
  info "User littledog already exists"
fi
usermod -aG docker,render,video littledog 2>/dev/null || true

# adminhabl — admin account
if ! id adminhabl &>/dev/null; then
  useradd -m -s /bin/bash adminhabl
  info "Created user adminhabl"
  warn "Set adminhabl password with: passwd adminhabl"
else
  info "User adminhabl already exists"
fi
usermod -aG sudo,docker,pack-member adminhabl 2>/dev/null || true

# hsimah — SSH user
if ! id hsimah &>/dev/null; then
  useradd -m -s /bin/bash hsimah
  info "Created user hsimah"
else
  info "User hsimah already exists"
fi
usermod -aG pack-member hsimah 2>/dev/null || true

# ─── 6. SSH lockdown ─────────────────────────────────────────────────────────
info "Configuring SSH..."

SSHD_CONFIG="/etc/ssh/sshd_config"
if [[ -f "$SSHD_CONFIG" ]]; then
  if ! grep -q "^AllowUsers hsimah" "$SSHD_CONFIG"; then
    echo "AllowUsers hsimah" >> "$SSHD_CONFIG"
    info "Added AllowUsers hsimah to sshd_config"
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
  else
    info "SSH AllowUsers already configured"
  fi
else
  warn "sshd_config not found, skipping SSH lockdown"
fi

# ─── 7. Sudo config ──────────────────────────────────────────────────────────
info "Configuring sudo..."

SUDOERS_FILE="/etc/sudoers.d/adminhabl"
echo "adminhabl ALL=(ALL:ALL) ALL" > "$SUDOERS_FILE"
chmod 0440 "$SUDOERS_FILE"

if visudo -c -f "$SUDOERS_FILE" &>/dev/null; then
  info "Sudoers file validated"
else
  error "Sudoers file validation failed, removing"
  rm -f "$SUDOERS_FILE"
  exit 1
fi

# ─── 8. hsimah alias ─────────────────────────────────────────────────────────
info "Configuring admin alias..."

ALIAS_FILE="/home/hsimah/.admin_alias"
echo "alias admin='su - adminhabl'" > "$ALIAS_FILE"
chown hsimah:hsimah "$ALIAS_FILE"
chmod 600 "$ALIAS_FILE"

BASHRC="/home/hsimah/.bashrc"
if [[ -f "$BASHRC" ]]; then
  if ! grep -qF ".admin_alias" "$BASHRC"; then
    echo '[ -f ~/.admin_alias ] && source ~/.admin_alias' >> "$BASHRC"
    info "Added admin alias sourcing to .bashrc"
  else
    info "Admin alias already sourced in .bashrc"
  fi
else
  echo '[ -f ~/.admin_alias ] && source ~/.admin_alias' > "$BASHRC"
  chown hsimah:hsimah "$BASHRC"
  info "Created .bashrc with admin alias sourcing"
fi

# ─── 9. Directory structure ──────────────────────────────────────────────────
info "Creating directory structure..."

# Config dirs (755)
CONFIG_DIRS=(
  /opt/plex/config
  /opt/radarr
  /opt/sonarr
  /opt/lidarr
  /opt/jackett
  /opt/transmission
  /opt/soulseek
  /opt/soulseek/logs
  /opt/pupyrus/html
  /opt/pupyrus/db
)

for dir in "${CONFIG_DIRS[@]}"; do
  mkdir -p "$dir"
  chown littledog:pack-member "$dir"
  chmod 755 "$dir"
done

# Media/download dirs (775)
MEDIA_DIRS=(
  /mammoth/library/movies
  /mammoth/library/tv
  /mammoth/library/music
  /mammoth/library/videos
  /mammoth/library/stand-up
  /mammoth/downloads/transmission
  /mammoth/downloads/soulseek
  /mammoth/plex/transcode
  /mammoth/transmission/torrents
)

for dir in "${MEDIA_DIRS[@]}"; do
  mkdir -p "$dir"
  chown littledog:pack-member "$dir"
  chmod 775 "$dir"
done

info "Directory structure created"

# ─── 10. Docker install ──────────────────────────────────────────────────────
info "Checking Docker..."

if ! command -v docker &>/dev/null; then
  info "Installing Docker CE..."
  apt-get install -y -qq ca-certificates gnupg > /dev/null

  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  # Detect distro for apt source
  . /etc/os-release
  DOCKER_REPO="deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable"

  if ! grep -qF "download.docker.com" /etc/apt/sources.list.d/docker.list 2>/dev/null; then
    echo "$DOCKER_REPO" > /etc/apt/sources.list.d/docker.list
  fi

  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null
  info "Docker CE installed"
else
  info "Docker already installed"
fi

# Ensure docker group memberships
usermod -aG docker littledog 2>/dev/null || true
usermod -aG docker adminhabl 2>/dev/null || true

# ─── 11. Deploy services ─────────────────────────────────────────────────────
info "Deploying services..."

SERVICES=(plex radarr sonarr lidarr jackett transmission soulseek pupyrus iditarod)

for service in "${SERVICES[@]}"; do
  compose_file="${REPO_DIR}/${service}/docker-compose.yml"

  if [[ ! -f "$compose_file" ]]; then
    warn "No docker-compose.yml for ${service}, skipping"
    continue
  fi

  # Warn if .env is expected but missing
  if [[ -f "${REPO_DIR}/${service}/.env.example" && ! -f "${REPO_DIR}/${service}/.env" ]]; then
    warn "${service}: .env file missing (see .env.example)"
    continue
  fi

  info "Starting ${service}..."
  docker compose -f "$compose_file" up -d
done

# ─── 11a. WordPress setup ───────────────────────────────────────────────────
if docker ps --format '{{.Names}}' | grep -q '^pupyrus$'; then
  info "Configuring WordPress..."
  compose_file="${REPO_DIR}/pupyrus/docker-compose.yml"
  source "${REPO_DIR}/pupyrus/.env"

  if docker compose -f "$compose_file" --profile cli run --rm cli wp core is-installed 2>/dev/null; then
    info "WordPress already installed"
  else
    info "Installing WordPress..."
    docker compose -f "$compose_file" --profile cli run --rm cli \
      wp core install \
        --url="http://localhost" \
        --title="Pupyrus" \
        --admin_user="adminhabl" \
        --admin_password="${WORDPRESS_ADMIN_PASSWORD}" \
        --admin_email="hamishblake+papyrus@gmail.com"
    info "WordPress installed"
  fi
fi

# ─── 12. Config tracking ─────────────────────────────────────────────────────
info "Setting up config tracking..."

TRACKING_DIR="/opt/config-tracking"
mkdir -p "$TRACKING_DIR"

# Init git repo if needed
if [[ ! -d "${TRACKING_DIR}/.git" ]]; then
  git -C "$TRACKING_DIR" init
  info "Initialized config tracking repo"
fi

# Install gitignore
cp "${REPO_DIR}/config-tracking/.gitignore-configs" "${TRACKING_DIR}/.gitignore"

# Install tracker script
cp "${REPO_DIR}/config-tracking/config-tracker.sh" "${TRACKING_DIR}/config-tracker.sh"
chmod +x "${TRACKING_DIR}/config-tracker.sh"

# Install systemd units
cp "${REPO_DIR}/config-tracking/config-tracker.service" /etc/systemd/system/
cp "${REPO_DIR}/config-tracking/config-tracker.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now config-tracker.timer
info "Config tracking timer enabled"

# ─── 13. Verification summary ────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  space-needle setup complete"
echo "============================================"
echo ""

info "Users:"
for user in littledog adminhabl hsimah; do
  if id "$user" &>/dev/null; then
    echo "  $(id "$user")"
  else
    warn "  $user not found"
  fi
done

echo ""
info "Service account shell:"
echo "  $(getent passwd littledog | cut -d: -f7)"

echo ""
info "Mount status:"
if mountpoint -q /mammoth; then
  echo "  /mammoth is mounted"
else
  warn "  /mammoth is NOT mounted"
fi

echo ""
info "Docker containers:"
docker ps --format "  {{.Names}}: {{.Status}}" 2>/dev/null || warn "  Could not list containers"

echo ""
info "Config tracker timer:"
systemctl status config-tracker.timer --no-pager 2>/dev/null | head -5 || warn "  Timer not found"

echo ""
info "Done. Remember to:"
echo "  - Set adminhabl password:  passwd adminhabl"
echo "  - Verify SSH:              sshd -T | grep allowusers"
echo "  - Check .env files for any services that were skipped"
