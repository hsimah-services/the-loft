#!/usr/bin/env bash
# Pulsr service setup — sourced by setup.sh
# Provisions fleet accounts on GoToSocial (only runs on the host that runs Pulsr)
# Expects: REPO_DIR, hostname_to_username, hostname_to_pascal, info functions available in caller

CONTAINER="pulsr"
GTS_BIN="/gotosocial/gotosocial"

info "Provisioning Pulsr fleet accounts (space-needle hosts Pulsr)..."

for host_conf_file in "${REPO_DIR}"/hosts/*/host.conf; do
  host_dir="$(dirname "$host_conf_file")"
  fleet_host="$(basename "$host_dir")"
  fleet_username="$(hostname_to_username "$fleet_host")"
  fleet_pascal="$(hostname_to_pascal "$fleet_host")"
  fleet_email="${fleet_host}@loft.hsimah.com"
  fleet_password="${fleet_pascal}12345!"

  info "Creating Pulsr account for ${fleet_host} (${fleet_username})..."
  if docker exec "$CONTAINER" "$GTS_BIN" admin account create \
      --username "$fleet_username" \
      --email "$fleet_email" \
      --password "$fleet_password" 2>/dev/null; then
    docker exec "$CONTAINER" "$GTS_BIN" admin account confirm \
      --username "$fleet_username" 2>/dev/null || true
    info "Account '${fleet_username}' created and confirmed"
  else
    info "Account '${fleet_username}' already exists (skipping)"
  fi
done
