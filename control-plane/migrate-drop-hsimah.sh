#!/usr/bin/env bash
# migrate-drop-hsimah.sh — migrate a Loft host from the hsimah SSH login to
# logging in directly as adminhabl, then retire the hsimah account.
#
# Runs on each host (fleet-wide). Two phases, so a bad run can never lock you
# out of a host:
#
#   sudo ./control-plane/migrate-drop-hsimah.sh            # phase 1: provision
#       - copies hsimah's SSH keys (login + git deploy) to adminhabl
#       - chowns the repo to adminhabl
#       - allows BOTH adminhabl and hsimah via sshd (hsimah still works)
#
#   ---> now open a NEW terminal and confirm:  ssh adminhabl@<host>  <---
#
#   sudo ./control-plane/migrate-drop-hsimah.sh --finalize # phase 2: retire
#       - restricts sshd AllowUsers to adminhabl only
#       - backs up and deletes the hsimah account
#
# Both phases are idempotent and safe to re-run.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SSHD_CONFIG="/etc/ssh/sshd_config"
OLD_USER="hsimah"
NEW_USER="adminhabl"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[*]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[x]${NC} $*" >&2; }

[[ $EUID -eq 0 ]] || { error "Must run as root (use sudo)."; exit 1; }
id "$NEW_USER" &>/dev/null || { error "User $NEW_USER does not exist — run setup.sh first."; exit 1; }

NEW_HOME="$(getent passwd "$NEW_USER" | cut -d: -f6)"

reload_sshd() { systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true; }

# ── Phase 2: finalize ─────────────────────────────────────────────────────────
if [[ "${1:-}" == "--finalize" ]]; then
  info "Finalizing: restricting SSH to $NEW_USER and removing $OLD_USER"

  # Safety: never lock out — adminhabl must have working login keys first.
  if [[ ! -s "${NEW_HOME}/.ssh/authorized_keys" ]]; then
    error "${NEW_HOME}/.ssh/authorized_keys is missing or empty."
    error "Run phase 1 and confirm 'ssh ${NEW_USER}@$(hostname)' works before finalizing."
    exit 1
  fi

  if grep -q "^AllowUsers" "$SSHD_CONFIG"; then
    sed -i 's/^AllowUsers.*/AllowUsers adminhabl/' "$SSHD_CONFIG"
  else
    echo "AllowUsers adminhabl" >> "$SSHD_CONFIG"
  fi
  reload_sshd
  info "sshd AllowUsers -> adminhabl (reloaded)"

  if id "$OLD_USER" &>/dev/null; then
    OLD_HOME="$(getent passwd "$OLD_USER" | cut -d: -f6)"
    if [[ -d "$OLD_HOME" ]]; then
      backup="/var/backups/${OLD_USER}-home-$(date +%Y%m%d%H%M%S).tar.gz"
      mkdir -p /var/backups
      tar -czf "$backup" -C "$(dirname "$OLD_HOME")" "$(basename "$OLD_HOME")" 2>/dev/null || true
      info "Backed up $OLD_HOME -> $backup"
    fi
    pkill -u "$OLD_USER" 2>/dev/null || true
    userdel -r "$OLD_USER" 2>/dev/null || userdel "$OLD_USER"
    info "Removed user $OLD_USER"
  else
    info "User $OLD_USER already absent — nothing to remove"
  fi

  info "Finalize complete on $(hostname)."
  exit 0
fi

# ── Phase 1: provision adminhabl ──────────────────────────────────────────────
info "Provisioning $NEW_USER login on $(hostname) (repo: $REPO_DIR)"

install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "${NEW_HOME}/.ssh"

if id "$OLD_USER" &>/dev/null; then
  OLD_HOME="$(getent passwd "$OLD_USER" | cut -d: -f6)"

  # Login keys — merge + de-dupe so we never drop an existing adminhabl key.
  if [[ -f "${OLD_HOME}/.ssh/authorized_keys" ]]; then
    tmp="$(mktemp)"
    # adminhabl may not have an authorized_keys yet (fresh host reached only via
    # su); the '|| true' keeps that missing file from tripping pipefail + set -e.
    { cat "${OLD_HOME}/.ssh/authorized_keys" "${NEW_HOME}/.ssh/authorized_keys" 2>/dev/null || true; } \
      | sed '/^$/d' | sort -u > "$tmp"
    install -m 600 -o "$NEW_USER" -g "$NEW_USER" "$tmp" "${NEW_HOME}/.ssh/authorized_keys"
    rm -f "$tmp"
    info "Merged authorized_keys into $NEW_USER"
  else
    warn "No ${OLD_HOME}/.ssh/authorized_keys found — skipping login key copy"
  fi

  # Git deploy key for 'loft-ctl update' — only if adminhabl lacks one.
  for f in id_ed25519 id_ed25519.pub known_hosts; do
    if [[ -f "${OLD_HOME}/.ssh/${f}" && ! -f "${NEW_HOME}/.ssh/${f}" ]]; then
      perm=600; [[ "$f" == *.pub || "$f" == known_hosts ]] && perm=644
      install -m "$perm" -o "$NEW_USER" -g "$NEW_USER" "${OLD_HOME}/.ssh/${f}" "${NEW_HOME}/.ssh/${f}"
      info "Copied ${f} to $NEW_USER"
    fi
  done
else
  warn "User $OLD_USER not present — assuming keys already on $NEW_USER"
fi

# Ensure github.com is a known host so git pull as adminhabl doesn't prompt.
if [[ ! -f "${NEW_HOME}/.ssh/known_hosts" ]] || ! grep -q "github.com" "${NEW_HOME}/.ssh/known_hosts" 2>/dev/null; then
  ssh-keyscan -t ed25519 github.com >> "${NEW_HOME}/.ssh/known_hosts" 2>/dev/null || true
  chown "$NEW_USER:$NEW_USER" "${NEW_HOME}/.ssh/known_hosts" 2>/dev/null || true
  chmod 644 "${NEW_HOME}/.ssh/known_hosts" 2>/dev/null || true
fi

# Repo ownership — loft-ctl update runs 'git pull' as the login user.
chown -R "$NEW_USER:$NEW_USER" "$REPO_DIR"
git config --global --add safe.directory "$REPO_DIR" 2>/dev/null || true
sudo -u "$NEW_USER" git config --global --add safe.directory "$REPO_DIR" 2>/dev/null || true
info "Repo $REPO_DIR now owned by $NEW_USER"

# Allow adminhabl now, but keep hsimah working until you verify (no lockout).
if ! grep -q "^AllowUsers" "$SSHD_CONFIG"; then
  echo "AllowUsers adminhabl hsimah" >> "$SSHD_CONFIG"
  reload_sshd
elif ! grep -qE "^AllowUsers.*\badminhabl\b" "$SSHD_CONFIG"; then
  sed -i 's/^AllowUsers.*/AllowUsers adminhabl hsimah/' "$SSHD_CONFIG"
  reload_sshd
fi
info "sshd allows both adminhabl and hsimah (reloaded)"

echo ""
info "Phase 1 complete. Before finalizing:"
echo "  1. In a NEW terminal, confirm:  ssh ${NEW_USER}@$(hostname)"
echo "  2. Confirm sudo works there:    sudo -v"
echo "  3. Then retire hsimah:          sudo ${0} --finalize"
