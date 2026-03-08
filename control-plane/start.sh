#!/usr/bin/env bash
# start.sh — start containers
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

start_service() {
  local service="$1"
  local compose_args
  compose_args=$(compose_args_for "$service") || return 1

  echo "Starting ${service}..."
  # shellcheck disable=SC2086
  docker compose ${compose_args} up -d
  echo "Started ${service}."
  echo ""
}

run_for_targets start_service "${1:-}"
