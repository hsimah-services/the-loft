#!/usr/bin/env bash
# package-collector.sh — cache system package update counts for fleet status reporting
# Runs every 6 hours via cron, writes results to /var/log/loft/packages.log
set -euo pipefail

LOG_FILE="/var/log/loft/packages.log"

# Refresh package lists
apt-get update -qq 2>/dev/null

# Count total upgradeable packages
TOTAL_UPDATES=0
upgradeable="$(apt list --upgradeable 2>/dev/null | tail -n +2)"
if [[ -n "$upgradeable" ]]; then
  TOTAL_UPDATES="$(echo "$upgradeable" | wc -l)"
fi

# Count security updates (packages from *-security origins)
SECURITY_UPDATES=0
if [[ -n "$upgradeable" ]]; then
  security_count="$(echo "$upgradeable" | grep -c '-security' || true)"
  SECURITY_UPDATES="$security_count"
fi

# Check reboot-required flag
REBOOT_REQUIRED="no"
if [[ -f /var/run/reboot-required ]]; then
  REBOOT_REQUIRED="yes"
fi

cat > "$LOG_FILE" <<EOF
SECURITY_UPDATES=${SECURITY_UPDATES}
TOTAL_UPDATES=${TOTAL_UPDATES}
REBOOT_REQUIRED=${REBOOT_REQUIRED}
EOF
