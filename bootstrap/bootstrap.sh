#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# LocalBooth — post-install bootstrap script
#
# Executed via autoinstall late-commands inside the freshly installed
# target system (chroot).  It configures the user environment, enables
# services, and schedules MakeInstall to run on first boot (where
# real network is available).
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

# ── Fix home directory ────────────────────────────────────────────────
log "Ensuring home directory ${DEV_HOME} is properly configured"
usermod -d "${DEV_HOME}" "${DEV_USER}" 2>/dev/null || true
mkdir -p "${DEV_HOME}"
chown -R "${DEV_USER}:${DEV_USER}" "${DEV_HOME}"

# ── User groups and sudo ──────────────────────────────────────────────
log "Adding ${DEV_USER} to system groups (sudo, adm)"
usermod -aG sudo "${DEV_USER}" 2>/dev/null || true
usermod -aG adm "${DEV_USER}" 2>/dev/null || true

log "Configuring passwordless sudo for ${DEV_USER}"
echo "${DEV_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${DEV_USER}"
chmod 440 "/etc/sudoers.d/${DEV_USER}"

# ── SSH ────────────────────────────────────────────────────────────────
log "Enabling SSH service"
systemctl enable ssh 2>/dev/null || true

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

# ── Schedule MakeInstall for first boot ───────────────────────────────
# Running git clone inside curtin chroot often fails (no reliable network).
# Instead, create a systemd one-shot service that runs on first real boot.
log "Setting up MakeInstall to run on first boot"

cat > /etc/systemd/system/localbooth-makeinstall.service <<UNIT
[Unit]
Description=LocalBooth — Install dev tools via MakeInstall
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/localbooth-makeinstall-done

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/localbooth-makeinstall.sh
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target
UNIT

cat > /usr/local/bin/localbooth-makeinstall.sh <<SCRIPT
#!/usr/bin/env bash
set -uo pipefail
LOG="/var/log/localbooth-makeinstall.log"
log() { echo "[localbooth] \$(date '+%F %T') — \$*" | tee -a "\${LOG}"; }

DEV_USER="${DEV_USER}"
REPO="${MAKEINSTALL_REPO}"
INSTALL_DIR="/tmp/MakeInstall"

log "MakeInstall first-boot: starting"

# Wait up to 60s for network
for i in \$(seq 1 30); do
    if ping -c1 -W2 github.com &>/dev/null; then
        log "Network ready"
        break
    fi
    sleep 2
done

rm -rf "\${INSTALL_DIR}"
if ! git clone --depth 1 "\${REPO}" "\${INSTALL_DIR}" 2>&1 | tee -a "\${LOG}"; then
    log "ERROR: failed to clone MakeInstall"
    exit 1
fi

cd "\${INSTALL_DIR}"
chmod +x *.sh
export USER="\${DEV_USER}"
make install-all 2>&1 | tee -a "\${LOG}" || log "WARN: some targets may have failed"

# Ensure user is in docker group after install
if getent group docker &>/dev/null; then
    usermod -aG docker "\${DEV_USER}"
    log "Added \${DEV_USER} to docker group"
fi
systemctl enable docker 2>/dev/null || true

# Fix home ownership after any changes
chown -R "\${DEV_USER}:\${DEV_USER}" "/home/\${DEV_USER}"

# Mark as done so this doesn't run again
touch /var/lib/localbooth-makeinstall-done
rm -rf "\${INSTALL_DIR}"
log "MakeInstall first-boot: complete"
SCRIPT

chmod +x /usr/local/bin/localbooth-makeinstall.sh
systemctl enable localbooth-makeinstall.service 2>/dev/null || true

# ── Final ownership pass ──────────────────────────────────────────────
chown -R "${DEV_USER}:${DEV_USER}" "${DEV_HOME}"

log "Bootstrap complete — MakeInstall will run on first boot"
