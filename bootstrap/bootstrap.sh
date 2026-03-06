#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# LocalBooth — post-install bootstrap script
#
# Executed via autoinstall late-commands inside the freshly installed
# target system.  It configures the "dev" user environment, enables
# services, and sets up developer conveniences.
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

LOGFILE="/var/log/localbooth-bootstrap.log"
exec > >(tee -a "$LOGFILE") 2>&1

# Read the configured username, fall back to "dev"
BOOTSTRAP_CONF="/cdrom/bootstrap/bootstrap.conf"
DEV_USER="dev"
if [[ -f "${BOOTSTRAP_CONF}" ]]; then
    # shellcheck source=/dev/null
    source "${BOOTSTRAP_CONF}"
    DEV_USER="${INSTALL_USERNAME:-dev}"
fi
WORKSPACE="/home/${DEV_USER}/workspace"

log() { echo "[localbooth] $(date '+%F %T') — $*"; }

# ── Docker ─────────────────────────────────────────────────────────────
log "Adding ${DEV_USER} to the docker group"
usermod -aG docker "${DEV_USER}"

log "Enabling and starting Docker"
systemctl enable docker
systemctl start docker || true   # may fail inside chroot; fine

# ── SSH ────────────────────────────────────────────────────────────────
log "Enabling SSH"
systemctl enable ssh

# ── Workspace directory ────────────────────────────────────────────────
log "Creating workspace at ${WORKSPACE}"
mkdir -p "${WORKSPACE}"
chown "${DEV_USER}:${DEV_USER}" "${WORKSPACE}"

# ── Git defaults ───────────────────────────────────────────────────────
log "Configuring Git defaults for ${DEV_USER}"
sudo -u "${DEV_USER}" git config --global init.defaultBranch main
sudo -u "${DEV_USER}" git config --global pull.rebase true
sudo -u "${DEV_USER}" git config --global core.editor vim
sudo -u "${DEV_USER}" git config --global color.ui auto

# ── Shell aliases ──────────────────────────────────────────────────────
log "Installing developer aliases"
ALIAS_FILE="/home/${DEV_USER}/.bash_aliases"
cat > "${ALIAS_FILE}" <<'ALIASES'
# ── LocalBooth developer aliases ──
alias ll='ls -lAhF --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias gs='git status'
alias gd='git diff'
alias gl='git log --oneline --graph --decorate -20'
alias dc='docker compose'
alias dps='docker ps --format "table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Names}}"'
alias k='kubectl'
alias ..='cd ..'
alias ...='cd ../..'
ALIASES
chown "${DEV_USER}:${DEV_USER}" "${ALIAS_FILE}"

# ── Optional: kubectl ──────────────────────────────────────────────────
# If a kubectl binary was bundled on the install media, install it.
KUBECTL_SRC="/cdrom/extras/kubectl"
if [[ -f "${KUBECTL_SRC}" ]]; then
    log "Installing kubectl from install media"
    install -o root -g root -m 0755 "${KUBECTL_SRC}" /usr/local/bin/kubectl
else
    log "kubectl binary not found on media — skipping"
fi

# ── Done ───────────────────────────────────────────────────────────────
log "Bootstrap complete"
