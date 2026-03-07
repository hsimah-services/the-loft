#!/usr/bin/env bash
# start.sh — start containers
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

start_service() {
  local service="$1"
  local compose_file
  compose_file=$(compose_file_for "$service") || return 1

  echo "Starting ${service}..."
  docker compose -f "$compose_file" up -d
  echo "Started ${service}."
  echo ""
}

run_for_targets start_service "${1:-}"
