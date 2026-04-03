#!/usr/bin/env bash
# Stellarr service setup — sourced by setup.sh
# Expects: info function available in caller

CRON_FILE="/etc/cron.d/transmission-cleanup"
cat > "$CRON_FILE" <<'EOF'
# Remove torrents that have reached 200% seed ratio — installed by setup.sh
0 0 * * * root docker exec transmission /scripts/remove-torrents.sh
EOF
chmod 644 "$CRON_FILE"
info "Installed transmission cleanup cron job"
