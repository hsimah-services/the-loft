#!/usr/bin/env bash
set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────
GITHUB_OWNER="${GITHUB_OWNER:?GITHUB_OWNER is required}"
GITHUB_REPO="${GITHUB_REPO:?GITHUB_REPO is required}"
GITHUB_ACCESS_TOKEN="${GITHUB_ACCESS_TOKEN:?GITHUB_ACCESS_TOKEN is required}"
RUNNER_NAME="${RUNNER_NAME:-space-needle}"
RUNNER_LABELS="${RUNNER_LABELS:-space-needle,self-hosted,linux}"

RUNNER_HOME="/home/runner"
REPO_URL="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}"
API_BASE="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/runners"

# ─── Registration ───────────────────────────────────────────────────────────
echo "Requesting registration token for ${GITHUB_OWNER}/${GITHUB_REPO}..."
REG_TOKEN=$(curl -s -X POST \
  -H "Authorization: token ${GITHUB_ACCESS_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${API_BASE}/registration-token" \
  | jq -r '.token')

if [[ -z "$REG_TOKEN" || "$REG_TOKEN" == "null" ]]; then
  echo "ERROR: Failed to get registration token. Check GITHUB_ACCESS_TOKEN, GITHUB_OWNER, and GITHUB_REPO."
  exit 1
fi

echo "Registering runner '${RUNNER_NAME}' with labels: ${RUNNER_LABELS}..."
"${RUNNER_HOME}/config.sh" \
  --url "${REPO_URL}" \
  --token "${REG_TOKEN}" \
  --name "${RUNNER_NAME}" \
  --labels "${RUNNER_LABELS}" \
  --unattended \
  --replace

# ─── Cleanup trap ───────────────────────────────────────────────────────────
cleanup() {
  echo "Caught signal, deregistering runner..."
  REMOVE_TOKEN=$(curl -s -X POST \
    -H "Authorization: token ${GITHUB_ACCESS_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${API_BASE}/remove-token" \
    | jq -r '.token')

  if [[ -n "$REMOVE_TOKEN" && "$REMOVE_TOKEN" != "null" ]]; then
    "${RUNNER_HOME}/config.sh" remove --token "${REMOVE_TOKEN}"
    echo "Runner deregistered."
  else
    echo "WARNING: Failed to get removal token. Runner may need manual removal."
  fi
}

trap cleanup SIGTERM SIGINT

# ─── Run ────────────────────────────────────────────────────────────────────
echo "Starting runner..."
"${RUNNER_HOME}/run.sh" &
wait $!
