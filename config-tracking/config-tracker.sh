#!/usr/bin/env bash
# config-tracker.sh — rsync service configs into a git-tracked directory
# Runs via systemd timer every 6 hours
set -euo pipefail

TRACKING_DIR="/opt/config-tracking"
SERVICES=(plex radarr sonarr lidarr jackett transmission soulseek)

RSYNC_EXCLUDES=(
  --exclude='*.db'
  --exclude='*.db-shm'
  --exclude='*.db-wal'
  --exclude='*.db-journal'
  --exclude='Cache/'
  --exclude='Metadata/'
  --exclude='Logs/'
  --exclude='logs/'
  --exclude='Plug-in*/'
  --exclude='*.pid'
  --exclude='*.lock'
  --exclude='*.log'
)

# Max file size to track (1MB)
MAX_SIZE="1M"

cd "$TRACKING_DIR"

for service in "${SERVICES[@]}"; do
  src="/opt/${service}/"
  dest="${TRACKING_DIR}/${service}/"

  if [[ ! -d "$src" ]]; then
    echo "SKIP: $src does not exist"
    continue
  fi

  mkdir -p "$dest"
  rsync -a --delete \
    --max-size="$MAX_SIZE" \
    "${RSYNC_EXCLUDES[@]}" \
    "$src" "$dest"
done

# Commit changes if any
if [[ -n $(git status --porcelain) ]]; then
  git add -A
  git commit -m "config snapshot $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "Changes committed."
else
  echo "No config changes detected."
fi
