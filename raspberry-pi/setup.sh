#!/usr/bin/env bash
# setup.sh — idempotent setup for Raspberry Pi fleet (viking, fjord)
# Must be run as root on Raspberry Pi OS (Debian-based)
set -euo pipefail

HOSTNAME=$(hostname)
REPO_DIR="/srv/${HOSTNAME}"

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
  error "This script requires a Debian-based system (apt-get not found)"
  exit 1
fi

if [[ ! -d "$REPO_DIR" ]]; then
  error "Repo not found at ${REPO_DIR} — clone it first"
  exit 1
fi

info "Hostname: ${HOSTNAME}"
info "Repo dir: ${REPO_DIR}"

# ─── 2. System packages ──────────────────────────────────────────────────────
info "Installing system packages..."
apt-get update -qq
apt-get install -y -qq git curl jq > /dev/null

# ─── 3. Groups ───────────────────────────────────────────────────────────────
info "Configuring groups..."

if ! getent group pack-member &>/dev/null; then
  groupadd -g 1003 pack-member
  info "Created group pack-member (GID 1003)"
else
  info "Group pack-member already exists"
fi

# ─── 4. Users ────────────────────────────────────────────────────────────────
info "Configuring users..."

# littledog — service account
if ! id littledog &>/dev/null; then
  useradd -u 1003 -g pack-member -s /usr/sbin/nologin -M littledog
  info "Created user littledog"
else
  info "User littledog already exists"
fi
usermod -aG docker littledog 2>/dev/null || true

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

# ─── 5. SSH lockdown ─────────────────────────────────────────────────────────
info "Configuring SSH..."

SSHD_CONFIG="/etc/ssh/sshd_config"
if [[ -f "$SSHD_CONFIG" ]]; then
  SSHD_CHANGED=false

  if ! grep -q "^AllowUsers hsimah" "$SSHD_CONFIG"; then
    echo "AllowUsers hsimah" >> "$SSHD_CONFIG"
    info "Added AllowUsers hsimah to sshd_config"
    SSHD_CHANGED=true
  else
    info "SSH AllowUsers already configured"
  fi

  if grep -q "^PasswordAuthentication yes" "$SSHD_CONFIG"; then
    sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' "$SSHD_CONFIG"
    info "Disabled password authentication"
    SSHD_CHANGED=true
  elif ! grep -q "^PasswordAuthentication no" "$SSHD_CONFIG"; then
    echo "PasswordAuthentication no" >> "$SSHD_CONFIG"
    info "Added PasswordAuthentication no to sshd_config"
    SSHD_CHANGED=true
  else
    info "Password authentication already disabled"
  fi

  if [[ "$SSHD_CHANGED" == "true" ]]; then
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
  fi
else
  warn "sshd_config not found, skipping SSH lockdown"
fi

# ─── 6. Sudo config ──────────────────────────────────────────────────────────
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

# ─── 7. Shell config ─────────────────────────────────────────────────────────
info "Configuring shared shell config..."

BASHRC_SOURCE="source ${REPO_DIR}/bashrc"

# hsimah
ALIAS_FILE="/home/hsimah/.admin_alias"
echo "alias admin='su - adminhabl'" > "$ALIAS_FILE"
chown hsimah:hsimah "$ALIAS_FILE"
chmod 600 "$ALIAS_FILE"

BASHRC="/home/hsimah/.bashrc"
if [[ -f "$BASHRC" ]]; then
  if ! grep -qF ".admin_alias" "$BASHRC"; then
    echo '[ -f ~/.admin_alias ] && source ~/.admin_alias' >> "$BASHRC"
    info "Added admin alias sourcing to hsimah .bashrc"
  fi
  if ! grep -qF "$BASHRC_SOURCE" "$BASHRC"; then
    echo "$BASHRC_SOURCE" >> "$BASHRC"
    info "Added shared bashrc sourcing to hsimah .bashrc"
  fi
else
  printf '%s\n' '[ -f ~/.admin_alias ] && source ~/.admin_alias' "$BASHRC_SOURCE" > "$BASHRC"
  chown hsimah:hsimah "$BASHRC"
  info "Created hsimah .bashrc with admin alias and shared bashrc sourcing"
fi

# adminhabl
ADMIN_BASHRC="/home/adminhabl/.bashrc"
if [[ -f "$ADMIN_BASHRC" ]]; then
  if ! grep -qF "$BASHRC_SOURCE" "$ADMIN_BASHRC"; then
    echo "$BASHRC_SOURCE" >> "$ADMIN_BASHRC"
    info "Added shared bashrc sourcing to adminhabl .bashrc"
  fi
else
  echo "$BASHRC_SOURCE" > "$ADMIN_BASHRC"
  chown adminhabl:adminhabl "$ADMIN_BASHRC"
  info "Created adminhabl .bashrc with shared bashrc sourcing"
fi

# ─── 8. Docker install ───────────────────────────────────────────────────────
info "Checking Docker..."

if ! command -v docker &>/dev/null; then
  info "Installing Docker CE..."
  apt-get install -y -qq ca-certificates gnupg > /dev/null

  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
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

# ─── 8a. Docker log rotation ─────────────────────────────────────────────────
info "Configuring Docker log rotation..."

DAEMON_JSON="/etc/docker/daemon.json"
DAEMON_JSON_SRC="${REPO_DIR}/daemon.json"

if [[ -f "$DAEMON_JSON_SRC" ]]; then
  if [[ -f "$DAEMON_JSON" ]] && diff -q "$DAEMON_JSON" "$DAEMON_JSON_SRC" &>/dev/null; then
    info "Docker daemon.json already up to date"
  else
    cp "$DAEMON_JSON_SRC" "$DAEMON_JSON"
    info "Installed daemon.json, restarting Docker..."
    systemctl restart docker
  fi
else
  warn "daemon.json not found in repo, skipping log rotation config"
fi

# ─── 9. Deploy services ──────────────────────────────────────────────────────
info "Deploying services..."

SERVICES=(iditarod)

for service in "${SERVICES[@]}"; do
  compose_file="${REPO_DIR}/raspberry-pi/${service}/docker-compose.yml"

  if [[ ! -f "$compose_file" ]]; then
    warn "No docker-compose.yml for ${service}, skipping"
    continue
  fi

  # Warn if .env is expected but missing
  if [[ -f "${REPO_DIR}/raspberry-pi/${service}/.env.example" && ! -f "${REPO_DIR}/raspberry-pi/${service}/.env" ]]; then
    warn "${service}: .env file missing (see .env.example)"
    continue
  fi

  info "Building ${service}..."
  DOCKER_GID=$(getent group docker | cut -d: -f3)
  docker compose -f "$compose_file" build --build-arg DOCKER_GID="${DOCKER_GID}"

  info "Starting ${service}..."
  docker compose -f "$compose_file" up -d
done

# ─── 10. Verification summary ────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  ${HOSTNAME} setup complete"
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
info "SSH config:"
if grep -q "^AllowUsers hsimah" /etc/ssh/sshd_config 2>/dev/null; then
  echo "  AllowUsers: hsimah"
else
  warn "  AllowUsers not configured"
fi
if grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config 2>/dev/null; then
  echo "  PasswordAuthentication: no"
else
  warn "  PasswordAuthentication not disabled"
fi

echo ""
info "Docker containers:"
docker ps --format "  {{.Names}}: {{.Status}}" 2>/dev/null || warn "  Could not list containers"

echo ""
info "Done. Remember to:"
echo "  - Set adminhabl password:  passwd adminhabl"
echo "  - Verify SSH:              sshd -T | grep -E 'allowusers|passwordauthentication'"
echo "  - Check .env files for any services that were skipped"
