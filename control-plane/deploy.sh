#!/usr/bin/env bash
# deploy.sh — pull images, restart containers, run health checks
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

deploy_service() {
  local service="$1"
  local compose_args
  compose_args=$(compose_args_for "$service") || return 1

  echo "Deploying ${service}..."
  # shellcheck disable=SC2086
  docker compose ${compose_args} pull
  # shellcheck disable=SC2086
  docker compose ${compose_args} up -d

  local exit_code=0
  check_containers "$compose_args" "$service" || exit_code=1
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
