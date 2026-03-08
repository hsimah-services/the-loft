#!/usr/bin/env bash
# update.sh — git checkout/pull latest config
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

echo "Updating the-loft on ${HOST_NAME}..."
git -C "$REPO_DIR" checkout main
git -C "$REPO_DIR" pull --ff-only
echo "Updated to $(git -C "$REPO_DIR" rev-parse --short HEAD)."
