#!/usr/bin/env bash
# setup.sh — idempotent setup for any host in The Loft fleet
# Must be run as root on Debian/Ubuntu
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

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

# ─── 1a. Load host config ─────────────────────────────────────────────────────
HOST_NAME="$(hostname)"
HOST_CONF="${REPO_DIR}/hosts/${HOST_NAME}/host.conf"

if [[ ! -f "$HOST_CONF" ]]; then
  error "No host config found at ${HOST_CONF}"
  error "This host (${HOST_NAME}) is not configured in the fleet."
  exit 1
fi

source "$HOST_CONF"
info "Host: ${HOST_NAME}"
info "Repo dir: ${REPO_DIR}"
info "Services: ${SERVICES[*]}"

# ─── 2. System packages ──────────────────────────────────────────────────────
info "Installing system packages..."
PACKAGES=(git curl jq)
[[ "$STORAGE_FS" == "xfs" ]] && PACKAGES+=(xfsprogs)
apt-get update -qq
apt-get install -y -qq "${PACKAGES[@]}" > /dev/null

# ─── 3. Storage mount ────────────────────────────────────────────────────────
if [[ -n "$STORAGE_DEVICE" ]]; then
  info "Configuring storage mount..."
  FSTAB_ENTRY="${STORAGE_DEVICE} ${STORAGE_MOUNT} ${STORAGE_FS} defaults 0 0"

  if ! grep -qF "$STORAGE_DEVICE" /etc/fstab; then
    echo "$FSTAB_ENTRY" >> /etc/fstab
    info "Added ${STORAGE_MOUNT} to fstab"
  fi

  mkdir -p "$STORAGE_MOUNT"

  if ! mountpoint -q "$STORAGE_MOUNT"; then
    mount "$STORAGE_MOUNT"
    info "Mounted ${STORAGE_MOUNT}"
  else
    info "${STORAGE_MOUNT} already mounted"
  fi
else
  info "No storage device configured, skipping mount"
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

LITTLEDOG_GROUPS="docker"
if [[ -n "$LITTLEDOG_EXTRA_GROUPS" ]]; then
  LITTLEDOG_GROUPS+=",${LITTLEDOG_EXTRA_GROUPS}"
fi
usermod -aG "$LITTLEDOG_GROUPS" littledog 2>/dev/null || true

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
  SSHD_CHANGED=false

  if ! grep -q "^AllowUsers hsimah" "$SSHD_CONFIG"; then
    echo "AllowUsers hsimah" >> "$SSHD_CONFIG"
    info "Added AllowUsers hsimah to sshd_config"
    SSHD_CHANGED=true
  else
    info "SSH AllowUsers already configured"
  fi

  if [[ "$SSH_DISABLE_PASSWORD" == "true" ]]; then
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
  fi

  if [[ "$SSHD_CHANGED" == "true" ]]; then
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
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

# ─── 8. Shell config ─────────────────────────────────────────────────────────
info "Configuring shared shell config..."

BASHRC_SOURCE="source ${REPO_DIR}/bashrc.d"
INPUTRC_INCLUDE="\$include ${REPO_DIR}/inputrc.d"

for user in hsimah adminhabl; do
  home_dir="/home/${user}"

  echo "$BASHRC_SOURCE" > "${home_dir}/.bashrc"
  chown "${user}:${user}" "${home_dir}/.bashrc"

  echo "$INPUTRC_INCLUDE" > "${home_dir}/.inputrc"
  chown "${user}:${user}" "${home_dir}/.inputrc"

  info "Installed .bashrc and .inputrc for ${user}"
done

# ─── 9. Directory structure ──────────────────────────────────────────────────
info "Creating directory structure..."

for dir in "${CONFIG_DIRS[@]}"; do
  mkdir -p "$dir"
  chown littledog:pack-member "$dir"
  chmod 755 "$dir"
done

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
    . /etc/os-release
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
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

# ─── 10a. Docker log rotation ────────────────────────────────────────────
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

# ─── 10b. Shared Docker networks ────────────────────────────────────────
info "Ensuring shared Docker networks..."
docker network create loft-proxy 2>/dev/null || true

# ─── 11. Deploy services ─────────────────────────────────────────────────────
info "Deploying services..."

# Source compose helper from control-plane
source "${REPO_DIR}/control-plane/common.sh"

for service in "${SERVICES[@]}"; do
  compose_args=$(compose_args_for "$service") || {
    warn "No compose config for ${service}, skipping"
    continue
  }

  # Warn if .env is expected but missing
  service_dir="${REPO_DIR}/services/${service}"
  if [[ -f "${service_dir}/.env.example" && ! -f "${service_dir}/.env" ]]; then
    warn "${service}: .env file missing (see .env.example)"
    continue
  fi

  # Build if the service has a Dockerfile
  if [[ -f "${service_dir}/Dockerfile" ]]; then
    info "Building ${service}..."
    DOCKER_GID=$(getent group docker | cut -d: -f3)
    # shellcheck disable=SC2086
    docker compose ${compose_args} build --build-arg DOCKER_GID="${DOCKER_GID}"
  fi

  info "Starting ${service}..."
  # shellcheck disable=SC2086
  docker compose ${compose_args} up -d
done

# ─── 11a. WordPress setup ───────────────────────────────────────────────────
if printf '%s\n' "${SERVICES[@]}" | grep -qx pupyrus; then
  if docker ps --format '{{.Names}}' | grep -q '^pupyrus$'; then
    info "Configuring WordPress..."
    compose_args=$(compose_args_for "pupyrus")
    source "${REPO_DIR}/services/pupyrus/.env"

    # shellcheck disable=SC2086
    if docker compose ${compose_args} --profile cli run --rm cli wp core is-installed 2>/dev/null; then
      info "WordPress already installed"
    else
      info "Installing WordPress..."
      # shellcheck disable=SC2086
      docker compose ${compose_args} --profile cli run --rm cli \
        wp core install \
          --url="http://localhost" \
          --title="Pupyrus" \
          --admin_user="adminhabl" \
          --admin_password="${WORDPRESS_ADMIN_PASSWORD}" \
          --admin_email="hamishblake+papyrus@gmail.com"
      info "WordPress installed"
    fi
  fi
fi

# ─── 12. Verification summary ─────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  ${HOST_NAME} setup complete"
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

if [[ -n "$STORAGE_MOUNT" ]]; then
  echo ""
  info "Mount status:"
  if mountpoint -q "$STORAGE_MOUNT"; then
    echo "  ${STORAGE_MOUNT} is mounted"
  else
    warn "  ${STORAGE_MOUNT} is NOT mounted"
  fi
fi

echo ""
info "SSH config:"
if grep -q "^AllowUsers hsimah" /etc/ssh/sshd_config 2>/dev/null; then
  echo "  AllowUsers: hsimah"
else
  warn "  AllowUsers not configured"
fi
if [[ "$SSH_DISABLE_PASSWORD" == "true" ]]; then
  if grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config 2>/dev/null; then
    echo "  PasswordAuthentication: no"
  else
    warn "  PasswordAuthentication not disabled"
  fi
fi

echo ""
info "Docker containers:"
docker ps --format "  {{.Names}}: {{.Status}}" 2>/dev/null || warn "  Could not list containers"

echo ""
info "Done. Remember to:"
echo "  - Set adminhabl password:  passwd adminhabl"
echo "  - Verify SSH:              sshd -T | grep -E 'allowusers|passwordauthentication'"
echo "  - Check .env files for any services that were skipped"
