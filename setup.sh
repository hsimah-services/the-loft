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
PACKAGES=(git curl jq skopeo)
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

# rodnik — i3 display service account (i3 hosts only)
if [[ "${I3_ENABLED:-false}" == "true" ]]; then
  if ! id rodnik &>/dev/null; then
    useradd -m -s /bin/bash rodnik
    info "Created user rodnik"
  else
    info "User rodnik already exists"
  fi
  usermod -aG video,input,audio rodnik 2>/dev/null || true
fi

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

# ─── 9a. Log directory ──────────────────────────────────────────────────────
info "Creating log directory..."
mkdir -p /var/log/loft

# ─── 9b. Deploy state directory ─────────────────────────────────────────────
mkdir -p /var/lib/loft/deploy
chmod 755 /var/lib/loft/deploy

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

# ─── 11a. Per-service setup ──────────────────────────────────────────────────
for service in "${SERVICES[@]}"; do
  service_setup="${REPO_DIR}/services/${service}/setup.sh"
  if [[ -f "$service_setup" ]]; then
    info "Running ${service} setup..."
    source "$service_setup"
  fi
done

# ─── 11b. i3 desktop provisioning (i3 hosts only) ───────────────────────────
if [[ "${I3_ENABLED:-false}" == "true" ]]; then
  info "Provisioning i3 desktop..."

  # ── Packages ──────────────────────────────────────────────────────────────
  # Preseed the display-manager debconf question so the install never blocks on
  # the interactive "default display manager" prompt (lightdm vs gdm3).
  info "Installing i3 + Xorg packages..."
  echo "lightdm shared/default-x-display-manager select lightdm" | debconf-set-selections
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq xorg i3 xterm lightdm > /dev/null

  # ── lightdm auto-login (rodnik → i3) ──────────────────────────────────────
  info "Configuring lightdm auto-login (rodnik → i3)..."
  systemctl disable gdm3 2>/dev/null || true
  mkdir -p /etc/lightdm/lightdm.conf.d
  cat > /etc/lightdm/lightdm.conf.d/50-rodnik-autologin.conf <<'LIGHTDM'
[Seat:*]
autologin-user=rodnik
autologin-user-timeout=0
autologin-session=i3
user-session=i3
LIGHTDM

  # Survive the boot-time VT/X race: lightdm can fail its first few starts
  # before the console/DRM handoff completes, exhaust systemd's default start
  # rate limit, and give up. Remove the limit and retry until X is ready.
  mkdir -p /etc/systemd/system/lightdm.service.d
  cat > /etc/systemd/system/lightdm.service.d/restart.conf <<'RESTART'
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=on-failure
RestartSec=2
RESTART

  # lightdm.service is static (no [Install] section), so `systemctl enable`
  # no-ops on it. Select it as THE display manager the Debian/Ubuntu way:
  # the display-manager.service symlink (disabling gdm3 removes the old one).
  ln -sf /usr/lib/systemd/system/lightdm.service /etc/systemd/system/display-manager.service
  echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager
  info "lightdm auto-login configured (rodnik → i3)"

  # Stop plymouth grabbing VT7: its graphical splash claims the console via
  # vt.handoff and races lightdm's X server for it, which can deadlock the
  # boot (splash spins forever, lightdm retries and never wins the VT). Drop
  # `splash` from the kernel cmdline so plymouth never seizes the VT.
  if [[ -f /etc/default/grub ]] && grep -qE '\bsplash\b' /etc/default/grub; then
    sed -i 's/\bsplash\b//' /etc/default/grub
    update-grub 2>/dev/null || true
    info "Removed 'splash' from kernel cmdline (plymouth VT7 race)"
  fi

  # ── Seed rodnik's i3 config (avoids the first-run wizard under autologin) ──
  if [[ -f /etc/i3/config && ! -f /home/rodnik/.config/i3/config ]]; then
    install -d -o rodnik -g rodnik /home/rodnik/.config/i3
    install -o rodnik -g rodnik -m 644 /etc/i3/config /home/rodnik/.config/i3/config
    info "Seeded /home/rodnik/.config/i3/config from i3 defaults"
  fi

  # ── Clean up legacy kiosk artifacts (calavera migrated kiosk → i3) ────────
  systemctl disable greetd 2>/dev/null || true
  rm -f /etc/greetd/config.toml \
        /etc/chromium/policies/managed/kiosk.json \
        /etc/systemd/logind.conf.d/kiosk.conf \
        /etc/udev/rules.d/99-dpms-off.rules
  apt-get remove -y -qq cage chromium-browser greetd 2>/dev/null || true

  # ── Disable suspend/sleep (always-on audio sink) ──────────────────────────
  info "Disabling suspend/sleep/hibernate..."
  systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

  mkdir -p /etc/systemd/logind.conf.d
  cat > /etc/systemd/logind.conf.d/i3.conf <<'LOGIND'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
LOGIND
  info "Lid switch and sleep targets disabled"

  # ── Surface Pro 2 WiFi stability ──────────────────────────────────────────
  info "Installing Surface Pro 2 WiFi udev rule..."
  echo 'ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="1286", ATTR{power/autosuspend}="-1"' \
    > /etc/udev/rules.d/99-surface-wifi.rules
  info "Marvell WiFi USB autosuspend disabled"

  # ── Remove screen rotation sensor ────────────────────────────────────────
  apt-get remove -y iio-sensor-proxy 2>/dev/null || true
  info "Removed iio-sensor-proxy (screen rotation disabled)"

  info "i3 provisioning complete"
fi

# ─── 12. Cron jobs ───────────────────────────────────────────────────────────
info "Configuring cron jobs..."

# WiFi watchdog (every 5 minutes) — restarts dhcpcd if wlan0 loses its IPv4 address
# Harmless on hosts without wlan0 (short-circuits on first check)
cat > /etc/cron.d/loft-wifi-watchdog <<EOF
# WiFi DHCP watchdog — restart dhcpcd if wlan0 loses IPv4 — installed by setup.sh
*/5 * * * * root ip link show wlan0 &>/dev/null && ! ip -4 addr show wlan0 2>/dev/null | grep -q inet && logger -t loft-wifi-watchdog "wlan0 lost IPv4, restarting dhcpcd" && systemctl restart dhcpcd 2>/dev/null
EOF
chmod 644 /etc/cron.d/loft-wifi-watchdog
info "Installed WiFi watchdog cron job"

# Deploy puller cron entries (one per DEPLOY_TARGETS entry)
# Clear any stale entries from a previous run before installing fresh ones.
rm -f /etc/cron.d/loft-deploy-*
if [[ -v DEPLOY_TARGETS && ${#DEPLOY_TARGETS[@]} -gt 0 ]]; then
  for entry in "${DEPLOY_TARGETS[@]}"; do
    IFS='|' read -r dt_name dt_repo dt_target dt_hook <<< "$entry"
    safe_name="${dt_name//[^a-zA-Z0-9-]/-}"
    cat > "/etc/cron.d/loft-deploy-${safe_name}" <<EOF
# Release puller for ${dt_repo} → ${dt_target} — installed by setup.sh
0 * * * * root ${REPO_DIR}/control-plane/deploy-pull.sh '${dt_name}' '${dt_repo}' '${dt_target}' '${dt_hook}' >> /var/log/loft/deploy.log 2>&1
EOF
    chmod 644 "/etc/cron.d/loft-deploy-${safe_name}"
    info "Installed deploy puller cron: ${safe_name} (${dt_repo})"
  done
fi

# ─── 13. Verification summary ─────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  ${HOST_NAME} setup complete"
echo "============================================"
echo ""

info "Users:"
VERIFY_USERS=(littledog adminhabl hsimah)
[[ "${I3_ENABLED:-false}" == "true" ]] && VERIFY_USERS+=(rodnik)
for user in "${VERIFY_USERS[@]}"; do
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

if [[ "${I3_ENABLED:-false}" == "true" ]]; then
  echo ""
  info "i3 desktop config:"
  echo "  Autologin: rodnik → i3"
  if systemctl is-enabled lightdm &>/dev/null; then
    echo "  lightdm: enabled"
  else
    warn "  lightdm: not enabled"
  fi
  if systemctl is-enabled nftables &>/dev/null; then
    echo "  nftables: enabled"
  else
    warn "  nftables: not enabled"
  fi
fi

echo ""
info "Done. Remember to:"
echo "  - Set adminhabl password:  passwd adminhabl"
echo "  - Verify SSH:              sshd -T | grep -E 'allowusers|passwordauthentication'"
echo "  - Check .env files for any services that were skipped"
