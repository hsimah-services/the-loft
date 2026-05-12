#!/usr/bin/env bash
# github-app-token.sh — generate a GitHub App installation token
# Sources /etc/loft/deploy.env (or path in LOFT_DEPLOY_ENV) for credentials.
# Prints token on stdout. Returns non-zero if credentials are unset.
#
# Required env (typically in /etc/loft/deploy.env):
#   LOFT_DEPLOY_APP_ID            GitHub App ID
#   LOFT_DEPLOY_INSTALLATION_ID   Installation ID for the org/user
#   LOFT_DEPLOY_KEY_PATH          Path to App private key PEM
set -euo pipefail

DEPLOY_ENV="${LOFT_DEPLOY_ENV:-/etc/loft/deploy.env}"
[[ -f "$DEPLOY_ENV" ]] && source "$DEPLOY_ENV"

if [[ -z "${LOFT_DEPLOY_APP_ID:-}" \
   || -z "${LOFT_DEPLOY_INSTALLATION_ID:-}" \
   || -z "${LOFT_DEPLOY_KEY_PATH:-}" ]]; then
  return 1 2>/dev/null || exit 1
fi

if [[ ! -f "$LOFT_DEPLOY_KEY_PATH" ]]; then
  echo "ERROR: GitHub App key not found at ${LOFT_DEPLOY_KEY_PATH}" >&2
  exit 1
fi

base64url() {
  openssl base64 -e -A | tr '+/' '-_' | tr -d '='
}

now=$(date +%s)
iat=$(( now - 60 ))
exp=$(( now + 600 ))

header='{"alg":"RS256","typ":"JWT"}'
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$LOFT_DEPLOY_APP_ID")

unsigned="$(printf '%s' "$header" | base64url).$(printf '%s' "$payload" | base64url)"
signature=$(printf '%s' "$unsigned" \
  | openssl dgst -sha256 -sign "$LOFT_DEPLOY_KEY_PATH" \
  | base64url)
jwt="${unsigned}.${signature}"

response=$(curl -fsS -X POST \
  -H "Authorization: Bearer ${jwt}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/app/installations/${LOFT_DEPLOY_INSTALLATION_ID}/access_tokens")

token=$(printf '%s' "$response" | jq -r '.token')
if [[ -z "$token" || "$token" == "null" ]]; then
  echo "ERROR: Failed to obtain installation token: ${response}" >&2
  exit 1
fi

printf '%s' "$token"
