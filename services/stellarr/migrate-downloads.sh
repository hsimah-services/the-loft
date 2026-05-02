#!/usr/bin/env bash
# migrate-downloads.sh
# Migrates from the old split downloads layout to the unified layout.
#
# Old layout:
#   /mammoth/downloads/transmission/          (flat, all transmission downloads)
#   /mammoth/downloads/soulseek/complete/     (slskd completed downloads)
#   /mammoth/downloads/soulseek/downloading/  (slskd incomplete downloads)
#
# New layout:
#   /mammoth/downloads/incomplete/            (shared incomplete dir)
#   /mammoth/downloads/completed/radarr/
#   /mammoth/downloads/completed/sonarr/
#   /mammoth/downloads/completed/lidarr/      (transmission torrents + slskd downloads)

set -euo pipefail

DOWNLOADS=/mammoth/downloads

echo "==> Stopping stellarr stack..."
sudo loft-ctl stop stellarr

echo ""
echo "==> Creating new directory structure..."
sudo mkdir -p \
    "$DOWNLOADS/incomplete" \
    "$DOWNLOADS/completed/radarr" \
    "$DOWNLOADS/completed/sonarr" \
    "$DOWNLOADS/completed/lidarr"

# --- Transmission ---
# Transmission's incomplete dir is typically configured as a subdir inside its
# mount. Move any incomplete torrents across, then move completed content to
# completed/lidarr as a staging area — you will need to re-point radarr/sonarr
# categories in their download client settings after this migration.
if [ -d "$DOWNLOADS/transmission" ]; then
    echo ""
    echo "==> Migrating transmission downloads..."

    # Move incomplete subdir if it exists
    if [ -d "$DOWNLOADS/transmission/incomplete" ]; then
        echo "    Moving transmission/incomplete/* -> incomplete/"
        sudo find "$DOWNLOADS/transmission/incomplete" -mindepth 1 -maxdepth 1 \
            -exec mv -v {} "$DOWNLOADS/incomplete/" \;
    fi

    # Move everything else (completed content) — placed in completed/lidarr as a
    # neutral staging dir. Re-sort into radarr/sonarr/lidarr manually or via
    # the *arr import functions after reconfiguring download client categories.
    echo "    Moving remaining transmission content -> completed/lidarr/ (staging)"
    sudo find "$DOWNLOADS/transmission" -mindepth 1 -maxdepth 1 \
        ! -name "incomplete" \
        -exec mv -v {} "$DOWNLOADS/completed/lidarr/" \;

    echo "    Removing old transmission/ dir (should be empty)..."
    sudo rmdir --ignore-fail-on-non-empty "$DOWNLOADS/transmission" \
        && echo "    Removed." \
        || echo "    WARNING: transmission/ not empty — check contents before deleting manually."
fi

# --- Soulseek / slskd ---
if [ -d "$DOWNLOADS/soulseek" ]; then
    echo ""
    echo "==> Migrating soulseek downloads..."

    if [ -d "$DOWNLOADS/soulseek/complete" ]; then
        echo "    Moving soulseek/complete/* -> completed/lidarr/"
        sudo find "$DOWNLOADS/soulseek/complete" -mindepth 1 -maxdepth 1 \
            -exec mv -v {} "$DOWNLOADS/completed/lidarr/" \;
    fi

    if [ -d "$DOWNLOADS/soulseek/downloading" ]; then
        echo "    Moving soulseek/downloading/* -> incomplete/"
        sudo find "$DOWNLOADS/soulseek/downloading" -mindepth 1 -maxdepth 1 \
            -exec mv -v {} "$DOWNLOADS/incomplete/" \;
    fi

    echo "    Removing old soulseek/ dir (should be empty)..."
    sudo rm -rf "$DOWNLOADS/soulseek" \
        && echo "    Removed." \
        || echo "    WARNING: Could not remove soulseek/ — check contents manually."
fi

echo ""
echo "==> New layout:"
sudo find "$DOWNLOADS" -maxdepth 3 -type d | sort

echo ""
echo "==> Starting stellarr stack..."
sudo loft-ctl start stellarr

echo ""
echo "Done. Post-migration checklist:"
echo "  1. Transmission: set incomplete dir to /downloads/incomplete in settings.json"
echo "     (or via the web UI: Preferences > Downloading > Keep incomplete files in)"
echo "  2. Transmission: configure per-category download dirs:"
echo "     - radarr   -> /downloads/completed/radarr"
echo "     - sonarr   -> /downloads/completed/sonarr"
echo "     - lidarr   -> /downloads/completed/lidarr"
echo "  3. Radarr: Settings > Download Clients > Transmission — set category to 'radarr'"
echo "  4. Sonarr: Settings > Download Clients > Transmission — set category to 'sonarr'"
echo "  5. Lidarr: Settings > Download Clients > Transmission — set category to 'lidarr'"
echo "  6. Review any staged files in completed/lidarr/ and re-trigger imports as needed."
