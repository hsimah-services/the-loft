#!/bin/bash
set -euo pipefail

# Required environment variables
: "${ACCESS_TOKEN:?ACCESS_TOKEN is required}"
: "${REPO_URL:?REPO_URL is required}"
: "${RUNNER_NAME:=iditarod}"
: "${RUNNER_LABELS:=self-hosted,linux,x64}"

# Extract owner/repo from the URL
REPO_PATH="${REPO_URL#https://github.com/}"

registration_token() {
  curl -s -X POST \
    -H "Authorization: token ${ACCESS_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO_PATH}/actions/runners/registration-token" \
    | jq -r .token
}

removal_token() {
  curl -s -X POST \
    -H "Authorization: token ${ACCESS_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO_PATH}/actions/runners/remove-token" \
    | jq -r .token
}

deregister() {
  echo "Caught signal, deregistering runner..."
  TOKEN=$(removal_token)
  ./config.sh remove --token "${TOKEN}" || true
  exit 0
}

trap deregister SIGTERM SIGINT

# Register the runner
TOKEN=$(registration_token)
./config.sh \
  --url "${REPO_URL}" \
  --token "${TOKEN}" \
  --name "${RUNNER_NAME}" \
  --labels "${RUNNER_LABELS}" \
  --unattended \
  --replace

# Start the runner (exec so it receives signals)
exec ./run.sh
