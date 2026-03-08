#!/usr/bin/env bash
# stop.sh — stop containers
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

stop_service() {
  local service="$1"
  local compose_args
  compose_args=$(compose_args_for "$service") || return 1

  echo "Stopping ${service}..."
  # shellcheck disable=SC2086
  docker compose ${compose_args} down
  echo "Stopped ${service}."
  echo ""
}

run_for_targets stop_service "${1:-}"
