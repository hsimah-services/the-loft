#!/usr/bin/env bash
set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────
GITHUB_ORG="${GITHUB_ORG:?GITHUB_ORG is required}"
GITHUB_APP_ID="${GITHUB_APP_ID:?GITHUB_APP_ID is required}"
GITHUB_APP_INSTALLATION_ID="${GITHUB_APP_INSTALLATION_ID:?GITHUB_APP_INSTALLATION_ID is required}"
GITHUB_APP_PRIVATE_KEY_FILE="${GITHUB_APP_PRIVATE_KEY_FILE:-/run/secrets/github_app_key}"
RUNNER_NAME="${RUNNER_NAME:-space-needle}"
RUNNER_LABELS="${RUNNER_LABELS:-space-needle,self-hosted,linux}"

RUNNER_HOME="/home/runner"
ORG_URL="https://github.com/${GITHUB_ORG}"
API_BASE="https://api.github.com/orgs/${GITHUB_ORG}/actions/runners"

# ─── GitHub App Auth ────────────────────────────────────────────────────────
base64url() {
  openssl base64 -e -A | tr '+/' '-_' | tr -d '='
}

generate_jwt() {
  local now
  now=$(date +%s)
  local iat=$(( now - 60 ))
  local exp=$(( now + 600 ))

  local header='{"alg":"RS256","typ":"JWT"}'
  local payload
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$GITHUB_APP_ID")

  local unsigned
  unsigned="$(printf '%s' "$header" | base64url).$(printf '%s' "$payload" | base64url)"

  local signature
  signature=$(printf '%s' "$unsigned" \
    | openssl dgst -sha256 -sign "$GITHUB_APP_PRIVATE_KEY_FILE" \
    | base64url)

  printf '%s.%s' "$unsigned" "$signature"
}

get_installation_token() {
  local jwt
  jwt=$(generate_jwt)

  local response
  response=$(curl -s -X POST \
    -H "Authorization: Bearer ${jwt}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/${GITHUB_APP_INSTALLATION_ID}/access_tokens")

  local token
  token=$(printf '%s' "$response" | jq -r '.token')

  if [[ -z "$token" || "$token" == "null" ]]; then
    echo "ERROR: Failed to get installation token."
    echo "Response: ${response}"
    exit 1
  fi

  printf '%s' "$token"
}

# ─── Registration ───────────────────────────────────────────────────────────
if [[ ! -f "$GITHUB_APP_PRIVATE_KEY_FILE" ]]; then
  echo "ERROR: Private key file not found at ${GITHUB_APP_PRIVATE_KEY_FILE}"
  exit 1
fi

echo "Generating GitHub App installation token..."
INSTALL_TOKEN=$(get_installation_token)
echo "Installation token obtained."

echo "Requesting registration token for org ${GITHUB_ORG}..."
REG_TOKEN=$(curl -s -X POST \
  -H "Authorization: token ${INSTALL_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${API_BASE}/registration-token" \
  | jq -r '.token')

if [[ -z "$REG_TOKEN" || "$REG_TOKEN" == "null" ]]; then
  echo "ERROR: Failed to get registration token. Check app permissions and installation."
  exit 1
fi

echo "Registering runner '${RUNNER_NAME}' with labels: ${RUNNER_LABELS}..."
gosu runner "${RUNNER_HOME}/config.sh" \
  --url "${ORG_URL}" \
  --token "${REG_TOKEN}" \
  --name "${RUNNER_NAME}" \
  --labels "${RUNNER_LABELS}" \
  --unattended \
  --replace

# ─── Cleanup trap ───────────────────────────────────────────────────────────
cleanup() {
  echo "Caught signal, deregistering runner..."

  local token
  token=$(get_installation_token 2>/dev/null) || true

  if [[ -n "$token" ]]; then
    REMOVE_TOKEN=$(curl -s -X POST \
      -H "Authorization: token ${token}" \
      -H "Accept: application/vnd.github+json" \
      "${API_BASE}/remove-token" \
      | jq -r '.token')

    if [[ -n "$REMOVE_TOKEN" && "$REMOVE_TOKEN" != "null" ]]; then
      gosu runner "${RUNNER_HOME}/config.sh" remove --token "${REMOVE_TOKEN}"
      echo "Runner deregistered."
    else
      echo "WARNING: Failed to get removal token. Runner may need manual removal."
    fi
  else
    echo "WARNING: Failed to get installation token for cleanup. Runner may need manual removal."
  fi
}

trap cleanup SIGTERM SIGINT

# ─── Run ────────────────────────────────────────────────────────────────────
echo "Starting runner..."
gosu runner "${RUNNER_HOME}/run.sh" &
wait $!
