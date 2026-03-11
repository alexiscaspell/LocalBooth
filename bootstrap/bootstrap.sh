#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# LocalBooth — post-install bootstrap script
#
# Executed via autoinstall late-commands inside the freshly installed
# target system (chroot).  It configures the user environment, enables
# services, and installs dev tools via MakeInstall.
# ──────────────────────────────────────────────────────────────────────
set -uo pipefail

LOGFILE="/var/log/localbooth-bootstrap.log"
MAKEINSTALL_REPO="https://github.com/alexiscaspell/MakeInstall.git"

log() { echo "[localbooth] $(date '+%F %T') — $*" | tee -a "${LOGFILE}"; }

# ── Detect the primary non-root user ──────────────────────────────────
DEV_USER=""

for conf in /cdrom/bootstrap/bootstrap.conf /tmp/bootstrap.conf; do
    if [[ -f "${conf}" ]]; then
        # shellcheck source=/dev/null
        source "${conf}"
        DEV_USER="${INSTALL_USERNAME:-}"
        break
    fi
done

if [[ -z "${DEV_USER}" ]]; then
    DEV_USER=$(awk -F: '$3 >= 1000 && $3 < 65000 {print $1; exit}' /etc/passwd)
fi

if [[ -z "${DEV_USER}" ]]; then
    DEV_USER="dev"
    log "WARNING: Could not detect username, falling back to '${DEV_USER}'"
fi

log "Bootstrap starting for user '${DEV_USER}'"
DEV_HOME="/home/${DEV_USER}"

# ── Fix home directory ownership ──────────────────────────────────────
# Ensure the user's home dir exists and is correctly owned
log "Ensuring home directory ${DEV_HOME} is properly configured"
usermod -d "${DEV_HOME}" "${DEV_USER}" 2>/dev/null || true
mkdir -p "${DEV_HOME}"
chown -R "${DEV_USER}:${DEV_USER}" "${DEV_HOME}"

# ── User groups and sudo ──────────────────────────────────────────────
log "Adding ${DEV_USER} to system groups (sudo, adm)"
usermod -aG sudo "${DEV_USER}" 2>/dev/null || true
usermod -aG adm "${DEV_USER}" 2>/dev/null || true

# Passwordless sudo for the dev user
log "Configuring passwordless sudo for ${DEV_USER}"
echo "${DEV_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${DEV_USER}"
chmod 440 "/etc/sudoers.d/${DEV_USER}"

# ── SSH ────────────────────────────────────────────────────────────────
log "Enabling SSH service"
systemctl enable ssh 2>/dev/null || true

# ── Install dev tools via MakeInstall ─────────────────────────────────
log "Installing dev tools via MakeInstall"
MAKEINSTALL_DIR="/tmp/MakeInstall"

if command -v git &>/dev/null && command -v make &>/dev/null; then
    rm -rf "${MAKEINSTALL_DIR}"
    if git clone --depth 1 "${MAKEINSTALL_REPO}" "${MAKEINSTALL_DIR}" 2>&1 | tee -a "${LOGFILE}"; then
        log "MakeInstall cloned, running install-all..."
        cd "${MAKEINSTALL_DIR}"
        chmod +x *.sh

        # MakeInstall scripts use ${USER} for usermod; set it to the actual user
        export USER="${DEV_USER}"
        make install-all 2>&1 | tee -a "${LOGFILE}" || log "WARN: some MakeInstall targets may have failed"

        cd /
        rm -rf "${MAKEINSTALL_DIR}"
        log "MakeInstall complete"
    else
        log "WARN: failed to clone MakeInstall — skipping tool installation"
    fi
else
    log "WARN: git or make not available — skipping MakeInstall"
fi

# ── Ensure docker group membership (in case MakeInstall created it) ───
if getent group docker &>/dev/null; then
    log "Adding ${DEV_USER} to docker group"
    usermod -aG docker "${DEV_USER}" || log "WARN: failed to add user to docker group"
fi
systemctl enable docker 2>/dev/null || true

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
ALIAS_FILE="${DEV_HOME}/.bash_aliases"
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

# ── Final ownership pass ──────────────────────────────────────────────
# Ensure everything in home is owned by the user after all changes
chown -R "${DEV_USER}:${DEV_USER}" "${DEV_HOME}"

log "Bootstrap complete"
