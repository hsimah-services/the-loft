#!/usr/bin/env bash
# stop.sh — stop containers
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

stop_service() {
  local service="$1"
  local compose_file
  compose_file=$(compose_file_for "$service") || return 1

  echo "Stopping ${service}..."
  docker compose -f "$compose_file" down
  echo "Stopped ${service}."
  echo ""
}

run_for_targets stop_service "${1:-}"
