#!/usr/bin/env bash
# Pupyrus (WordPress) service setup — sourced by setup.sh
# Expects: REPO_DIR, compose_args_for, info functions available in caller

if docker ps --format '{{.Names}}' | grep -q '^pupyrus$'; then
  info "Configuring WordPress..."
  compose_args=$(compose_args_for "pupyrus")
  source "${REPO_DIR}/services/pupyrus/.env"

  # shellcheck disable=SC2086
  if docker compose ${compose_args} --profile cli run --rm cli wp core is-installed 2>/dev/null; then
    info "WordPress already installed"
  else
    info "Installing WordPress..."
    # shellcheck disable=SC2086
    docker compose ${compose_args} --profile cli run --rm cli \
      wp core install \
        --url="http://localhost" \
        --title="Pupyrus" \
        --admin_user="adminhabl" \
        --admin_password="${WORDPRESS_ADMIN_PASSWORD}" \
        --admin_email="hamishblake+papyrus@gmail.com"
    info "WordPress installed"
  fi
fi
