#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# LocalBooth — post-install bootstrap script
#
# Executed via autoinstall late-commands inside the freshly installed
# target system (chroot).  It configures the user environment, enables
# services, and sets up developer conveniences.
# ──────────────────────────────────────────────────────────────────────
set -uo pipefail

LOGFILE="/var/log/localbooth-bootstrap.log"

log() { echo "[localbooth] $(date '+%F %T') — $*" | tee -a "${LOGFILE}"; }

# ── Detect the primary non-root user ──────────────────────────────────
# Inside a chroot, /cdrom isn't mounted so we can't read bootstrap.conf.
# Instead, find the first user with UID >= 1000 (the user created by
# autoinstall identity section).
DEV_USER=""

# Try bootstrap.conf first (works when script runs outside chroot)
for conf in /cdrom/bootstrap/bootstrap.conf /tmp/bootstrap.conf; do
    if [[ -f "${conf}" ]]; then
        # shellcheck source=/dev/null
        source "${conf}"
        DEV_USER="${INSTALL_USERNAME:-}"
        break
    fi
done

# Fallback: find the first non-root human user
if [[ -z "${DEV_USER}" ]]; then
    DEV_USER=$(awk -F: '$3 >= 1000 && $3 < 65000 {print $1; exit}' /etc/passwd)
fi

if [[ -z "${DEV_USER}" ]]; then
    DEV_USER="dev"
    log "WARNING: Could not detect username, falling back to '${DEV_USER}'"
fi

log "Bootstrap starting for user '${DEV_USER}'"
WORKSPACE="/home/${DEV_USER}/workspace"

# ── Docker ─────────────────────────────────────────────────────────────
if getent group docker &>/dev/null; then
    log "Adding ${DEV_USER} to the docker group"
    usermod -aG docker "${DEV_USER}" || log "WARN: failed to add user to docker group"
fi

log "Enabling Docker service"
systemctl enable docker 2>/dev/null || true

# ── SSH ────────────────────────────────────────────────────────────────
log "Enabling SSH service"
systemctl enable ssh 2>/dev/null || true

# ── Workspace directory ────────────────────────────────────────────────
log "Creating workspace at ${WORKSPACE}"
mkdir -p "${WORKSPACE}"
chown "${DEV_USER}:${DEV_USER}" "${WORKSPACE}" 2>/dev/null || true

# ── Git defaults ───────────────────────────────────────────────────────
if command -v git &>/dev/null; then
    log "Configuring Git defaults for ${DEV_USER}"
    sudo -u "${DEV_USER}" git config --global init.defaultBranch main 2>/dev/null || true
    sudo -u "${DEV_USER}" git config --global pull.rebase true 2>/dev/null || true
    sudo -u "${DEV_USER}" git config --global core.editor vim 2>/dev/null || true
    sudo -u "${DEV_USER}" git config --global color.ui auto 2>/dev/null || true
fi

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
chown "${DEV_USER}:${DEV_USER}" "${ALIAS_FILE}" 2>/dev/null || true

# ── Optional: kubectl ──────────────────────────────────────────────────
KUBECTL_SRC="/cdrom/extras/kubectl"
if [[ -f "${KUBECTL_SRC}" ]]; then
    log "Installing kubectl from install media"
    install -o root -g root -m 0755 "${KUBECTL_SRC}" /usr/local/bin/kubectl
fi

# ── Done ───────────────────────────────────────────────────────────────
log "Bootstrap complete"
