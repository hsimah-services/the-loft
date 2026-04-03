#!/usr/bin/env bash
# image-collector.sh — check running containers for Docker image updates
# Runs daily via cron, writes results to /var/log/loft/images.log
set -euo pipefail

LOG_FILE="/var/log/loft/images.log"
TMP_FILE="${LOG_FILE}.tmp"

# Skip images that are locally built (no registry hostname)
is_remote_image() {
  local ref="$1"
  # Remote images contain a dot in the first segment (registry hostname)
  # or use Docker Hub shorthand (library/image or org/image)
  local first_segment="${ref%%/*}"
  if [[ "$first_segment" == *"."* ]]; then
    return 0
  fi
  # Docker Hub images: either "image:tag" (official) or "org/image:tag"
  # Local builds typically have no slash and no dot (e.g. "mushr", "iditarod")
  if [[ "$ref" == *"/"* ]]; then
    return 0
  fi
  return 1
}

# Get version label from image inspect output (skopeo or docker)
extract_version() {
  local inspect_json="$1"
  echo "$inspect_json" | sed -n 's/.*"org\.opencontainers\.image\.version" *: *"\([^"]*\)".*/\1/p' | head -1
}

# Iterate running containers
while IFS= read -r line; do
  container_name="$(echo "$line" | awk '{print $1}')"
  image_ref="$(echo "$line" | awk '{print $2}')"

  # Skip locally-built images
  if ! is_remote_image "$image_ref"; then
    continue
  fi

  status="error"
  local_version="unknown"
  remote_version="unknown"

  # Get local image digest and labels
  local_inspect=""
  local_digest=""
  if local_inspect="$(docker image inspect "$image_ref" 2>/dev/null)"; then
    local_digest="$(echo "$local_inspect" | sed -n 's/.*"RepoDigests".*"[^"]*@\(sha256:[a-f0-9]*\)".*/\1/p' | head -1)"
    local_version="$(echo "$local_inspect" | sed -n 's/.*"org\.opencontainers\.image\.version" *: *"\([^"]*\)".*/\1/p' | head -1)"
    [[ -z "$local_version" ]] && local_version="unknown"
  fi

  # Get remote digest and labels via skopeo
  remote_inspect=""
  remote_digest=""
  if remote_inspect="$(skopeo inspect "docker://${image_ref}" 2>/dev/null)"; then
    remote_digest="$(echo "$remote_inspect" | sed -n 's/.*"Digest" *: *"\(sha256:[a-f0-9]*\)".*/\1/p' | head -1)"
    remote_version="$(extract_version "$remote_inspect")"
    [[ -z "$remote_version" ]] && remote_version="unknown"

    # Compare digests
    if [[ -n "$local_digest" && -n "$remote_digest" ]]; then
      if [[ "$local_digest" == "$remote_digest" ]]; then
        status="current"
      else
        status="update"
      fi
    elif [[ -n "$remote_digest" ]]; then
      # No local digest to compare (unusual), mark as error
      status="error"
    fi
  fi

  echo "${container_name}|${image_ref}|${local_version}|${remote_version}|${status}"
done < <(docker ps --format '{{.Names}} {{.Image}}') > "$TMP_FILE"

mv "$TMP_FILE" "$LOG_FILE"
