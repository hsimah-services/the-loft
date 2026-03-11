#!/usr/bin/env bash
# common.sh — shared variables and helper functions for loft-ctl
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Load host config ──────────────────────────────────────────────────────────
HOST_NAME="$(hostname)"
HOST_CONF="${REPO_DIR}/hosts/${HOST_NAME}/host.conf"

if [[ ! -f "$HOST_CONF" ]]; then
  echo "ERROR: No host config found at ${HOST_CONF}" >&2
  echo "This host (${HOST_NAME}) is not configured in the fleet." >&2
  exit 1
fi

source "$HOST_CONF"

# Health-check timeout (seconds)
HC_TIMEOUT=30
HC_INTERVAL=5

# ── Resolve compose files ─────────────────────────────────────────────────────
# Returns -f flags for docker compose, including override if present.
compose_args_for() {
  local service="$1"
  local base="${REPO_DIR}/services/${service}/docker-compose.yml"
  local override="${REPO_DIR}/hosts/${HOST_NAME}/overrides/${service}/docker-compose.override.yml"

  if [[ ! -f "$base" ]]; then
    echo "ERROR: No docker-compose.yml found for '${service}'" >&2
    return 1
  fi

  local args="-f ${base}"
  [[ -f "$override" ]] && args+=" -f ${override}"
  echo "$args"
}

# ── Container health check ─────────────────────────────────────────────────────
check_containers() {
  local compose_args="$1"
  local service="$2"
  local elapsed=0

  echo "  Checking containers for ${service}..."
  while (( elapsed < HC_TIMEOUT )); do
    local states
    # shellcheck disable=SC2086
    states=$(docker compose ${compose_args} ps --format '{{.State}}' 2>/dev/null | grep -v '^$' || true)

    if [[ -z "$states" ]]; then
      sleep "$HC_INTERVAL"
      (( elapsed += HC_INTERVAL ))
      continue
    fi

    local all_running=true
    while IFS= read -r state; do
      if [[ "$state" != "running" ]]; then
        all_running=false
        break
      fi
    done <<< "$states"

    if $all_running; then
      echo "  All containers running."
      return 0
    fi

    sleep "$HC_INTERVAL"
    (( elapsed += HC_INTERVAL ))
  done

  echo "  WARNING: Not all containers running after ${HC_TIMEOUT}s."
  # shellcheck disable=SC2086
  docker compose ${compose_args} ps
  return 1
}

# ── Web UI health check ────────────────────────────────────────────────────────
check_url() {
  local url="$1"
  local label="$2"
  local warn_only="${3:-false}"

  local http_code
  http_code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || echo "000")

  if [[ "$http_code" == "000" ]]; then
    if $warn_only; then
      echo "    WARNING: ${label} (${url}) — no response (VPN-dependent)"
    else
      echo "    FAIL: ${label} (${url}) — no response"
      return 1
    fi
  else
    echo "    OK: ${label} (${url}) — HTTP ${http_code}"
  fi
  return 0
}

# ── Data-driven web UI checks ────────────────────────────────────────────────
check_web_ui() {
  local service="$1"
  local failed=0

  # Check required health URLs
  for label in "${!HEALTH_URLS[@]}"; do
    local url="${HEALTH_URLS[$label]}"
    check_url "$url" "$label" || (( failed++ ))
  done

  # Check warn-only health URLs
  for label in "${!HEALTH_URLS_WARN[@]}"; do
    local url="${HEALTH_URLS_WARN[$label]}"
    check_url "$url" "$label" true
  done

  return "$failed"
}
