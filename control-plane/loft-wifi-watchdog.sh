#!/usr/bin/env bash
# loft-wifi-watchdog.sh — restart networking (and optionally reload the driver)
# when a host's WiFi interface loses its IPv4 lease.
#
# Installed by setup.sh to /usr/local/bin/loft-wifi-watchdog, invoked by
# /etc/cron.d/loft-wifi-watchdog, config sourced from /etc/default/loft-wifi-watchdog
# (WIFI_IFACE, WIFI_DHCP_UNIT, WIFI_FW_RECOVERY, WIFI_FW_MODULE — all from
# host.conf).
#
# No-ops cleanly on hosts without the configured interface.
set -u

# Cron's default PATH (/usr/bin:/bin on Debian) omits /sbin and /usr/sbin,
# where ip/rmmod/modprobe live — without this, `ip` fails with "command not
# found" under cron, and the `||` below misreads that as "interface absent",
# silently no-oping instead of recovering the connection.
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

: "${WIFI_IFACE:=wlan0}"
: "${WIFI_DHCP_UNIT:=dhcpcd}"
: "${WIFI_FW_RECOVERY:=false}"
: "${WIFI_FW_MODULE:=}"

ip link show "$WIFI_IFACE" &>/dev/null || exit 0
ip -4 addr show "$WIFI_IFACE" 2>/dev/null | grep -q inet && exit 0

# ── Optional firmware-crash recovery ────────────────────────────────────────
# Some USB WiFi chips (seen on calavera's Marvell 88W8797/mwifiex) can crash
# their firmware under USB autosuspend: the interface stays present but dead,
# and no amount of restarting the DHCP unit brings it back — only reloading
# the kernel driver module re-uploads firmware. Restarting NetworkManager/
# dhcpcd is a no-op for this failure mode.
#
# WIFI_FW_MODULE must name the module explicitly (e.g. mwifiex_usb) — this
# used to be discovered dynamically via
# /sys/class/net/$WIFI_IFACE/device/driver/module, but on calavera that path
# resolves to usbcore even while the interface is healthy, not the actual
# bus-glue driver. rmmod usbcore then silently fails (2>/dev/null; it backs
# every other USB device on the box), so the reload never ran at all.
if [[ "$WIFI_FW_RECOVERY" == "true" ]]; then
  if [[ -n "$WIFI_FW_MODULE" ]]; then
    logger -t loft-wifi-watchdog "${WIFI_IFACE} lost IPv4, reloading driver module ${WIFI_FW_MODULE}"
    rmmod "$WIFI_FW_MODULE" 2>/dev/null
    sleep 1
    modprobe "$WIFI_FW_MODULE" 2>/dev/null
    sleep 3
  else
    logger -t loft-wifi-watchdog "${WIFI_IFACE} lost IPv4, WIFI_FW_RECOVERY=true but WIFI_FW_MODULE is unset, skipping driver reload"
  fi
fi

logger -t loft-wifi-watchdog "${WIFI_IFACE} lost IPv4, restarting ${WIFI_DHCP_UNIT}"
systemctl restart "$WIFI_DHCP_UNIT" 2>/dev/null
