#!/usr/bin/env bash
# health.sh — run health checks only
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

health_check_service() {
  local service="$1"
  local compose_args
  compose_args=$(compose_args_for "$service") || return 1

  echo "Health check: ${service}"
  local exit_code=0
  check_containers "$compose_args" "$service" || exit_code=1
  check_web_ui "$service" || exit_code=1

  if (( exit_code == 0 )); then
    echo "Health check ${service} — all checks passed."
  else
    echo "Health check ${service} — some checks failed (see above)."
  fi
  echo ""
  return "$exit_code"
}

# Default to all services if no argument given
arg="${1:-}"
if [[ -z "$arg" ]]; then
  targets=("${SERVICES[@]}")
else
  targets=("$arg")
fi

echo "Running health checks: ${targets[*]}"
echo ""
overall=0
for svc in "${targets[@]}"; do
  health_check_service "$svc" || (( overall++ ))
done
if (( overall == 0 )); then
  echo "All health checks passed."
else
  echo "${overall} service(s) had check failures."
  exit 1
fi
