#!/usr/bin/with-contenv bash
# Custom init script for linuxserver/transmission.
# Patches settings.json on container start to enable auto-cleanup of seeded torrents.

SETTINGS="/config/settings.json"

if [ ! -f "$SETTINGS" ]; then
    echo "[configure-transmission] settings.json not found — first run, creating seed"
    echo '{}' > "$SETTINGS"
fi

python3 -c "
import json, sys

with open('$SETTINGS', 'r') as f:
    s = json.load(f)

s['ratio-limit'] = 2.0
s['ratio-limit-enabled'] = True
s['script-torrent-done-seeding-enabled'] = True
s['script-torrent-done-seeding-filename'] = '/scripts/done-seeding.sh'

with open('$SETTINGS', 'w') as f:
    json.dump(s, f, indent=4, sort_keys=True)

print('[configure-transmission] Configured ratio limit (2.0) and done-seeding script')
"
