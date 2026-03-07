#!/usr/bin/env bash
# deploy.sh — pull images, restart containers, run health checks
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

deploy_service() {
  local service="$1"
  local compose_file
  compose_file=$(compose_file_for "$service") || return 1

  echo "Deploying ${service}..."
  docker compose -f "$compose_file" pull
  docker compose -f "$compose_file" up -d

  local exit_code=0
  check_containers "$compose_file" "$service" || exit_code=1
  check_web_ui "$service" || exit_code=1

  if (( exit_code == 0 )); then
    echo "Deployed ${service} — all checks passed."
  else
    echo "Deployed ${service} — some checks failed (see above)."
  fi
  echo ""
  return "$exit_code"
}

run_for_targets deploy_service "${1:-}" || {
  echo "Some deploys had check failures."
  exit 1
}
