#!/usr/bin/env bash
# update.sh — git checkout/pull latest config
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

echo "Updating space-needle..."
git -C "$REPO_DIR" checkout main
git -C "$REPO_DIR" pull --ff-only
echo "Updated to $(git -C "$REPO_DIR" rev-parse --short HEAD)."
