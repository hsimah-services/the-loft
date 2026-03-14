#!/usr/bin/env bash
# pulsr-collector.sh — lightweight CPU sampler for fleet status reporting
# Runs every minute via cron, appends CPU usage % to /var/log/loft/cpu.log
set -euo pipefail

LOG_FILE="/var/log/loft/cpu.log"

# Read /proc/stat twice, 1 second apart
read_cpu() {
  local line
  line="$(head -1 /proc/stat)"
  echo "$line"
}

parse_cpu() {
  local line="$1"
  # cpu user nice system idle iowait irq softirq steal
  set -- $line
  shift  # drop "cpu" label
  local total=0
  local idle="$4"
  for val in "$@"; do
    (( total += val ))
  done
  echo "$total $idle"
}

snap1="$(read_cpu)"
sleep 1
snap2="$(read_cpu)"

read total1 idle1 <<< "$(parse_cpu "$snap1")"
read total2 idle2 <<< "$(parse_cpu "$snap2")"

total_diff=$(( total2 - total1 ))
idle_diff=$(( idle2 - idle1 ))

if (( total_diff > 0 )); then
  cpu_pct=$(( (total_diff - idle_diff) * 100 / total_diff ))
else
  cpu_pct=0
fi

echo "$cpu_pct" >> "$LOG_FILE"
