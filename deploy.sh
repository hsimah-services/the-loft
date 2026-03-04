#!/usr/bin/env bash
# deploy.sh — pull latest config and optionally restart services
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# Pull latest
git -C "$REPO_DIR" pull --ff-only

# If no service specified, just pull
if [[ $# -eq 0 ]]; then
  echo "Pulled latest. Usage: $0 <service> to also restart."
  echo "Services: plex media pupyrus iditarod"
  exit 0
fi

SERVICE="$1"
COMPOSE_FILE="${REPO_DIR}/${SERVICE}/docker-compose.yml"

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "ERROR: No docker-compose.yml found for '${SERVICE}'"
  exit 1
fi

docker compose -f "$COMPOSE_FILE" pull
docker compose -f "$COMPOSE_FILE" up -d
echo "Deployed ${SERVICE}"
