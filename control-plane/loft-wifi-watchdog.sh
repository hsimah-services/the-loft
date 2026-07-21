#!/usr/bin/env bash
# loft-wifi-watchdog.sh — restart networking (and optionally reload the driver)
# when a host's WiFi interface loses its IPv4 lease.
#
# Installed by setup.sh to /usr/local/bin/loft-wifi-watchdog, invoked by
# /etc/cron.d/loft-wifi-watchdog, config sourced from /etc/default/loft-wifi-watchdog
# (WIFI_IFACE, WIFI_DHCP_UNIT, WIFI_FW_RECOVERY — all from host.conf).
#
# No-ops cleanly on hosts without the configured interface.
set -u

: "${WIFI_IFACE:=wlan0}"
: "${WIFI_DHCP_UNIT:=dhcpcd}"
: "${WIFI_FW_RECOVERY:=false}"

ip link show "$WIFI_IFACE" &>/dev/null || exit 0
ip -4 addr show "$WIFI_IFACE" 2>/dev/null | grep -q inet && exit 0

# ── Optional firmware-crash recovery ────────────────────────────────────────
# Some USB WiFi chips (seen on calavera's Marvell 88W8797/mwifiex) can crash
# their firmware under USB autosuspend: the interface stays present but dead,
# and no amount of restarting the DHCP unit brings it back — only reloading
# the kernel driver module re-uploads firmware. Restarting NetworkManager/
# dhcpcd is a no-op for this failure mode, so detect it separately and reload
# the actual driver bound to the interface before falling through to the
# normal DHCP-unit restart below.
if [[ "$WIFI_FW_RECOVERY" == "true" ]]; then
  if dmesg -T 2>/dev/null | tail -50 | grep -qiE 'firmware is in a bad state|firmware in bad state|card removed'; then
    driver_path="/sys/class/net/${WIFI_IFACE}/device/driver/module"
    if [[ -e "$driver_path" ]]; then
      module="$(basename "$(readlink -f "$driver_path")")"
      logger -t loft-wifi-watchdog "${WIFI_IFACE} firmware crash detected, reloading driver module ${module}"
      rmmod "$module" 2>/dev/null
      sleep 1
      modprobe "$module" 2>/dev/null
      sleep 3
    fi
  fi
fi

logger -t loft-wifi-watchdog "${WIFI_IFACE} lost IPv4, restarting ${WIFI_DHCP_UNIT}"
systemctl restart "$WIFI_DHCP_UNIT" 2>/dev/null
