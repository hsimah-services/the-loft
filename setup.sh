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

# kiosk — locked-down display account (kiosk hosts only)
if [[ "${KIOSK_ENABLED:-false}" == "true" ]]; then
  if ! id kiosk &>/dev/null; then
    useradd -m -s /bin/bash kiosk
    info "Created user kiosk"
  else
    info "User kiosk already exists"
  fi
  usermod -aG video kiosk 2>/dev/null || true
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

# Hostname helpers (used by per-service setup and fleet-wide reporting)
hostname_to_username() { echo "${1//-/_}"; }
hostname_to_pascal() {
  local result=""
  local IFS='-'
  for part in $1; do
    result+="$(echo "${part:0:1}" | tr '[:lower:]' '[:upper:]')${part:1}"
  done
  echo "$result"
}

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

# ─── 11b. Kiosk provisioning (kiosk hosts only) ─────────────────────────────
if [[ "${KIOSK_ENABLED:-false}" == "true" ]]; then
  info "Provisioning kiosk mode..."

  # ── Packages ──────────────────────────────────────────────────────────────
  info "Installing kiosk packages..."
  apt-get install -y -qq cage chromium-browser greetd nftables > /dev/null

  # ── greetd auto-login ─────────────────────────────────────────────────────
  info "Configuring greetd auto-login..."
  mkdir -p /etc/greetd
  cat > /etc/greetd/config.toml <<EOF
[terminal]
vt = 7

[default_session]
command = "cage -- chromium-browser --kiosk --noerrdialogs --disable-infobars --no-first-run --disable-translate --ozone-platform=wayland --force-device-scale-factor=${KIOSK_SCALE} ${KIOSK_URL}"
user = "kiosk"
EOF

  systemctl disable gdm3 2>/dev/null || true
  systemctl enable greetd
  info "greetd configured (VT 7, user kiosk)"

  # ── Chromium managed policies ─────────────────────────────────────────────
  info "Deploying Chromium managed policies..."
  mkdir -p /etc/chromium/policies/managed
  cat > /etc/chromium/policies/managed/kiosk.json <<POLICY
{
  "URLBlocklist": ["*"],
  "URLAllowlist": [
    "loft.hsimah.com",
    ".loft.hsimah.com",
    ".space-needle",
    "space-needle",
    "pulsr.hsimah.com",
    "hbla.ke",
    "hsimah.com",
    "calavera",
    "localhost"
  ],
  "HomepageLocation": "${KIOSK_URL}",
  "HomepageIsNewTabPage": false,
  "RestoreOnStartup": 4,
  "RestoreOnStartupURLs": ["${KIOSK_URL}"],
  "BookmarkBarEnabled": false,
  "DeveloperToolsAvailability": 2,
  "IncognitoModeAvailability": 1,
  "BrowserSignin": 0,
  "SyncDisabled": true,
  "PasswordManagerEnabled": false,
  "TranslateEnabled": false,
  "EditBookmarksEnabled": false,
  "DefaultBrowserSettingEnabled": false
}
POLICY
  info "Chromium URL allowlist deployed"

  # ── nftables firewall (LAN-only) ─────────────────────────────────────────
  info "Deploying nftables firewall (LAN-only)..."
  cat > /etc/nftables.conf <<'NFT'
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    iif lo accept
    ip saddr 10.0.0.0/8 accept
    ip saddr 172.16.0.0/12 accept
    ip saddr 192.168.0.0/16 accept
    ip protocol icmp accept
    tcp dport 22 accept
    udp sport 67 udp dport 68 accept
  }
  chain output {
    type filter hook output priority 0; policy drop;
    ct state established,related accept
    oif lo accept
    ip daddr 10.0.0.0/8 accept
    ip daddr 172.16.0.0/12 accept
    ip daddr 192.168.0.0/16 accept
    ip protocol icmp accept
    udp sport 68 udp dport 67 accept
  }
  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept
    ip saddr 10.0.0.0/8 ip daddr 10.0.0.0/8 accept
    ip saddr 10.0.0.0/8 ip daddr 172.16.0.0/12 accept
    ip saddr 10.0.0.0/8 ip daddr 192.168.0.0/16 accept
    ip saddr 172.16.0.0/12 ip daddr 10.0.0.0/8 accept
    ip saddr 172.16.0.0/12 ip daddr 172.16.0.0/12 accept
    ip saddr 172.16.0.0/12 ip daddr 192.168.0.0/16 accept
    ip saddr 192.168.0.0/16 ip daddr 10.0.0.0/8 accept
    ip saddr 192.168.0.0/16 ip daddr 172.16.0.0/12 accept
    ip saddr 192.168.0.0/16 ip daddr 192.168.0.0/16 accept
  }
}
NFT
  systemctl enable nftables
  info "nftables firewall enabled (LAN-only outbound)"

  # ── Disable suspend/sleep/screen blank ────────────────────────────────────
  info "Disabling suspend/sleep/hibernate..."
  systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

  mkdir -p /etc/systemd/logind.conf.d
  cat > /etc/systemd/logind.conf.d/kiosk.conf <<'LOGIND'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
LOGIND
  info "Lid switch and sleep targets disabled"

  # ── Disable screen blanking (keep display on 24/7) ───────────────────────
  info "Disabling screen blanking..."

  # Kernel console blanker — disable at boot via kernel cmdline
  GRUB_FILE="/etc/default/grub"
  if [[ -f "$GRUB_FILE" ]]; then
    if ! grep -q "consoleblank=0" "$GRUB_FILE"; then
      sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 consoleblank=0"/' "$GRUB_FILE"
      update-grub 2>/dev/null || true
      info "Added consoleblank=0 to kernel cmdline (takes effect after reboot)"
    else
      info "consoleblank=0 already in kernel cmdline"
    fi
  fi

  # Also set at runtime for current boot
  echo 0 > /sys/module/kernel/parameters/consoleblank 2>/dev/null || true

  # Disable DPMS (display power management) via udev rule for DRM devices
  cat > /etc/udev/rules.d/99-dpms-off.rules <<'DPMS'
# Disable DPMS on all DRM connectors — keep screen on 24/7
ACTION=="add", SUBSYSTEM=="drm", RUN+="/bin/sh -c 'for f in /sys/class/drm/card*-*/dpms; do echo On > $f 2>/dev/null; done'"
DPMS
  info "DPMS disabled via udev rule (screen stays on 24/7)"

  # ── Surface Pro 2 WiFi stability ──────────────────────────────────────────
  info "Installing Surface Pro 2 WiFi udev rule..."
  echo 'ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="1286", ATTR{power/autosuspend}="-1"' \
    > /etc/udev/rules.d/99-surface-wifi.rules
  info "Marvell WiFi USB autosuspend disabled"

  # ── Remove screen rotation sensor ────────────────────────────────────────
  apt-get remove -y iio-sensor-proxy 2>/dev/null || true
  info "Removed iio-sensor-proxy (screen rotation disabled)"

  info "Kiosk provisioning complete"
fi

# ─── 11c. Audio device pinning (spinnik hosts only) ────────────────────────
if printf '%s\n' "${SERVICES[@]}" | grep -qx spinnik; then
  info "Installing LP5X ALSA device pinning udev rule..."
  echo 'SUBSYSTEM=="sound", ATTRS{idVendor}=="08bb", ATTRS{idProduct}=="29c0", ATTR{id}="LP5X"' \
    > /etc/udev/rules.d/99-lp5x.rules
  udevadm control --reload-rules 2>/dev/null || true
  info "LP5X udev rule installed (plughw:LP5X,0)"
fi

# ─── 12. Cron jobs ───────────────────────────────────────────────────────────
info "Configuring cron jobs..."

# CPU collector cron (every minute)
cat > /etc/cron.d/loft-cpu-collector <<EOF
# CPU usage sampler for fleet status reporting — installed by setup.sh
* * * * * root ${REPO_DIR}/control-plane/pulsr-collector.sh
EOF
chmod 644 /etc/cron.d/loft-cpu-collector
info "Installed CPU collector cron job"

# Package collector cron (every 6 hours, 30 min before report)
cat > /etc/cron.d/loft-package-collector <<EOF
# System package update cache for fleet status reporting — installed by setup.sh
30 5,11,17,23 * * * root ${REPO_DIR}/control-plane/package-collector.sh
EOF
chmod 644 /etc/cron.d/loft-package-collector
info "Installed package collector cron job"

# Docker image update checker (daily, 5 min before package collector)
cat > /etc/cron.d/loft-image-collector <<EOF
# Docker image update checker — installed by setup.sh
25 5 * * * root ${REPO_DIR}/control-plane/image-collector.sh
EOF
chmod 644 /etc/cron.d/loft-image-collector
info "Installed image collector cron job"

# WiFi watchdog (every 5 minutes) — restarts dhcpcd if wlan0 loses its IPv4 address
# Harmless on hosts without wlan0 (short-circuits on first check)
cat > /etc/cron.d/loft-wifi-watchdog <<EOF
# WiFi DHCP watchdog — restart dhcpcd if wlan0 loses IPv4 — installed by setup.sh
*/5 * * * * root ip link show wlan0 &>/dev/null && ! ip -4 addr show wlan0 2>/dev/null | grep -q inet && logger -t loft-wifi-watchdog "wlan0 lost IPv4, restarting dhcpcd" && systemctl restart dhcpcd 2>/dev/null
EOF
chmod 644 /etc/cron.d/loft-wifi-watchdog
info "Installed WiFi watchdog cron job"

# Status report cron (every 6 hours)
cat > /etc/cron.d/loft-pulsr-report <<EOF
# Fleet status report to Pulsr — installed by setup.sh
0 */6 * * * root ${REPO_DIR}/pulsr-ctl report
EOF
chmod 644 /etc/cron.d/loft-pulsr-report
info "Installed Pulsr status report cron job"

# ─── 12a. Pulsr reporting credentials ────────────────────────────────────────
# Obtain API token and write /etc/loft/pulsr.env for this host
info "Configuring Pulsr reporting credentials..."
FLEET_USERNAME="$(hostname_to_username "$HOST_NAME")"
FLEET_EMAIL="${HOST_NAME}@loft.hsimah.com"
FLEET_PASCAL="$(hostname_to_pascal "$HOST_NAME")"
FLEET_PASSWORD="!LoftService_${FLEET_PASCAL}12345!"

PULSR_ENV="/etc/loft/pulsr.env"
mkdir -p /etc/loft

if [[ -f "$PULSR_ENV" ]] && grep -q "^GTS_TOKEN=" "$PULSR_ENV" && [[ -n "$(sed -n 's/^GTS_TOKEN=//p' "$PULSR_ENV")" ]]; then
  info "Pulsr token already configured at ${PULSR_ENV}"
else
  info "Obtaining API token for ${FLEET_USERNAME}..."
  FLEET_TOKEN="$("${REPO_DIR}/pulsr-ctl" user-token \
    --host pulsr.hsimah.com \
    --protocol https \
    --email "$FLEET_EMAIL" \
    --password "$FLEET_PASSWORD")" || {
    warn "Failed to obtain Pulsr token — run 'pulsr-ctl user-token' manually after setup"
    FLEET_TOKEN=""
  }

  # Write pulsr.env with REPORT_DISKS from host.conf
  REPORT_DISKS_STR=""
  if [[ ${#REPORT_DISKS[@]} -gt 0 ]]; then
    REPORT_DISKS_STR="($(printf ' %s' "${REPORT_DISKS[@]}"))"
  else
    REPORT_DISKS_STR="(/)"
  fi

  cat > "$PULSR_ENV" <<EOF
# Pulsr fleet reporting config — generated by setup.sh
GTS_HOST=pulsr.hsimah.com
GTS_PROTOCOL=https
GTS_TOKEN=${FLEET_TOKEN}
REPORT_DISKS=${REPORT_DISKS_STR}
EOF
  chmod 600 "$PULSR_ENV"
  if [[ -n "$FLEET_TOKEN" ]]; then
    info "Pulsr config written to ${PULSR_ENV}"
  else
    warn "Pulsr config written to ${PULSR_ENV} (token is empty — fill in manually)"
  fi
fi

# Set profile picture if token is configured and image exists
PROFILE_IMG="${REPO_DIR}/hosts/${HOST_NAME}/profile.jpg"
if [[ -f "$PROFILE_IMG" ]] && grep -q "^GTS_TOKEN=.\+" "$PULSR_ENV" 2>/dev/null; then
  info "Setting Pulsr avatar from ${PROFILE_IMG}..."
  if "${REPO_DIR}/pulsr-ctl" set-avatar --image "$PROFILE_IMG"; then
    info "Pulsr avatar set successfully"
  else
    warn "Failed to set Pulsr avatar — set manually with: pulsr-ctl set-avatar --image ${PROFILE_IMG}"
  fi
else
  info "Skipping Pulsr avatar (no token or no profile.jpg)"
fi

# ─── 13. Verification summary ─────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  ${HOST_NAME} setup complete"
echo "============================================"
echo ""

info "Users:"
VERIFY_USERS=(littledog adminhabl hsimah)
[[ "${KIOSK_ENABLED:-false}" == "true" ]] && VERIFY_USERS+=(kiosk)
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

if [[ "${KIOSK_ENABLED:-false}" == "true" ]]; then
  echo ""
  info "Kiosk config:"
  echo "  URL: ${KIOSK_URL}"
  echo "  Scale: ${KIOSK_SCALE}"
  if systemctl is-enabled greetd &>/dev/null; then
    echo "  greetd: enabled"
  else
    warn "  greetd: not enabled"
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
