#!/usr/bin/env bash
# deploy-pull.sh — pull latest GitHub Release and deploy into a target directory.
#
# Usage: deploy-pull.sh <name> <repo> <target_dir> [post_hook]
#   name         — short identifier, used for state file & log prefix (e.g. pawst-hblake)
#   repo         — GitHub repo in "owner/repo" form (e.g. hsimah-services/hbla.ke)
#   target_dir   — directory to sync the release's tarball contents into
#   post_hook    — optional shell snippet run after a successful swap (cwd = target_dir)
#
# Auth: if /etc/loft/deploy.env exposes GitHub App credentials, requests are
# authenticated and private repos work. Otherwise unauthenticated public access
# is attempted (rate-limited; fine for hourly polling of a public repo).
#
# State: /var/lib/loft/deploy/<name>.version — holds last-deployed tag.
# Release contract:
#   - Repo publishes a release with a single .tar.gz asset whose contents are
#     the deployable tree (no top-level wrapper directory required; both
#     wrapped and unwrapped tarballs handled).
set -euo pipefail

CONTROL_PLANE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/var/lib/loft/deploy"

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <name> <repo> <target_dir> [post_hook]" >&2
  exit 1
fi

NAME="$1"
REPO="$2"
TARGET="$3"
POST_HOOK="${4:-}"

LOG_PREFIX="[deploy:${NAME}]"
log() { echo "$(date -Is) ${LOG_PREFIX} $*"; }
fail() { log "ERROR: $*"; exit 1; }

mkdir -p "$STATE_DIR"
STATE_FILE="${STATE_DIR}/${NAME}.version"
LAST_TAG=""
[[ -f "$STATE_FILE" ]] && LAST_TAG="$(<"$STATE_FILE")"

# ── Auth (best-effort) ──────────────────────────────────────────────────────
AUTH_HEADER=()
if TOKEN="$("${CONTROL_PLANE_DIR}/github-app-token.sh" 2>/dev/null)"; then
  AUTH_HEADER=(-H "Authorization: Bearer ${TOKEN}")
fi

api() {
  curl -fsS "${AUTH_HEADER[@]}" -H "Accept: application/vnd.github+json" "$@"
}

# ── Fetch release metadata ──────────────────────────────────────────────────
RELEASE_JSON="$(api "https://api.github.com/repos/${REPO}/releases/latest")" \
  || fail "Failed to query latest release for ${REPO}"

TAG="$(printf '%s' "$RELEASE_JSON" | jq -r '.tag_name // empty')"
[[ -z "$TAG" ]] && fail "No tag_name in release response for ${REPO}"

if [[ "$TAG" == "$LAST_TAG" ]]; then
  log "Already at ${TAG}, nothing to do."
  exit 0
fi

ASSET_URL="$(printf '%s' "$RELEASE_JSON" \
  | jq -r '.assets[] | select(.name | endswith(".tar.gz")) | .url' \
  | head -1)"
[[ -z "$ASSET_URL" ]] && fail "No .tar.gz asset on release ${TAG} for ${REPO}"

log "New release ${TAG} (was: ${LAST_TAG:-none})"

# ── Download tarball ────────────────────────────────────────────────────────
TARBALL="$(mktemp --suffix=.tar.gz)"
trap 'rm -f "$TARBALL"' EXIT

curl -fsSL "${AUTH_HEADER[@]}" \
  -H "Accept: application/octet-stream" \
  -o "$TARBALL" \
  "$ASSET_URL" || fail "Failed to download asset"

# ── Stage and sync ──────────────────────────────────────────────────────────
# TARGET is synced in place (never renamed/replaced): it may be bind-mounted
# into a running container, and bind mounts track the inode — replacing the
# directory would leave the container serving the deleted old tree.
PARENT="$(dirname "$TARGET")"
BASENAME="$(basename "$TARGET")"
mkdir -p "$PARENT"

STAGING="$(mktemp -d "${PARENT}/.${BASENAME}.deploy.XXXXXX")"
trap 'rm -f "$TARBALL"; rm -rf "$STAGING"' EXIT
tar xzf "$TARBALL" -C "$STAGING" || fail "tar extract failed"

# Unwrap if release tarball has a single top-level dir.
shopt -s dotglob nullglob
entries=("$STAGING"/*)
shopt -u dotglob nullglob
if [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" ]]; then
  inner="${entries[0]}"
  mv "$inner"/* "$inner"/.[!.]* "$STAGING/" 2>/dev/null || true
  rmdir "$inner" 2>/dev/null || true
fi

chown -R littledog:pack-member "$STAGING" 2>/dev/null || true
chmod -R u=rwX,go=rX "$STAGING"

mkdir -p "$TARGET"
rsync -a --delete "$STAGING"/ "$TARGET"/ || fail "rsync into ${TARGET} failed"

echo "$TAG" > "$STATE_FILE"
log "Deployed ${TAG} to ${TARGET}"

# ── Post-deploy hook ────────────────────────────────────────────────────────
if [[ -n "$POST_HOOK" ]]; then
  log "Running post-deploy hook"
  ( cd "$TARGET" && bash -c "$POST_HOOK" ) || log "WARNING: post-deploy hook exited non-zero"
fi
