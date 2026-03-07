#!/usr/bin/env bash
# common.sh — shared variables and helper functions for space-needle-ctl
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICES=(plex media pupyrus iditarod)

# Health-check timeout (seconds)
HC_TIMEOUT=30
HC_INTERVAL=5

# ── Resolve compose file ──────────────────────────────────────────────────────
compose_file_for() {
  local service="$1"
  local compose_file="${REPO_DIR}/${service}/docker-compose.yml"
  if [[ ! -f "$compose_file" ]]; then
    echo "ERROR: No docker-compose.yml found for '${service}'" >&2
    return 1
  fi
  echo "$compose_file"
}

# ── Resolve target services ───────────────────────────────────────────────────
# Returns SERVICES array if --all, or the single named service.
resolve_targets() {
  local arg="${1:-}"
  if [[ -z "$arg" ]]; then
    echo "ERROR: Missing <service|--all> argument." >&2
    exit 1
  fi
  if [[ "$arg" == "--all" ]]; then
    echo "${SERVICES[@]}"
  else
    echo "$arg"
  fi
}

# ── Container health check ─────────────────────────────────────────────────────
check_containers() {
  local compose_file="$1"
  local service="$2"
  local elapsed=0

  echo "  Checking containers for ${service}..."
  while (( elapsed < HC_TIMEOUT )); do
    local states
    states=$(docker compose -f "$compose_file" ps --format '{{.State}}' 2>/dev/null | grep -v '^$' || true)

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
  docker compose -f "$compose_file" ps
  return 1
}

# ── Web UI health check ────────────────────────────────────────────────────────
check_url() {
  local url="$1"
  local label="$2"
  local warn_only="${3:-false}"

  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || echo "000")

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

# ── Web UI checks per service ──────────────────────────────────────────────────
check_web_ui() {
  local service="$1"
  local failed=0

  case "$service" in
    plex)
      echo "  Checking web UIs for plex..."
      check_url "http://localhost:32400/web" "Plex" || (( failed++ ))
      ;;
    media)
      echo "  Checking web UIs for media..."
      check_url "http://localhost:7878" "Radarr" || (( failed++ ))
      check_url "http://localhost:8989" "Sonarr" || (( failed++ ))
      check_url "http://localhost:8686" "Lidarr" || (( failed++ ))
      check_url "http://localhost:9117" "Jackett" || (( failed++ ))
      check_url "http://localhost:9091" "Transmission" true
      check_url "http://localhost:6080" "Soulseek" true
      ;;
    pupyrus)
      echo "  Checking web UIs for pupyrus..."
      check_url "http://localhost:80" "WordPress" || (( failed++ ))
      ;;
    iditarod)
      ;;
  esac

  return "$failed"
}

# ── Run a command across targets ──────────────────────────────────────────────
run_for_targets() {
  local cmd="$1"
  shift
  local targets
  read -ra targets <<< "$(resolve_targets "${1:-}")"

  local overall=0
  for svc in "${targets[@]}"; do
    "$cmd" "$svc" || (( overall++ ))
  done
  return "$overall"
}
