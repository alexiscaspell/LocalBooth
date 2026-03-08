#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# LocalBooth — extract and customize the Ubuntu Server ISO
#
# 1. Extracts the stock ISO into iso/extracted/
# 2. Injects autoinstall configuration (user-data + meta-data)
# 3. Injects the local APT repository
# 4. Injects the bootstrap script
# 5. Patches GRUB to auto-start the installer with autoinstall
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

ISO_FILE="${1:-}"
EXTRACT_DIR="${SCRIPT_DIR}/extracted"
LOCAL_REPO="${ROOT_DIR}/repo/local-repo"
AUTOINSTALL_DIR="${ROOT_DIR}/autoinstall"
BOOTSTRAP_DIR="${ROOT_DIR}/bootstrap"

log() { echo "[localbooth] $(date '+%F %T') — $*"; }
SUDO="sudo"; [[ "$(id -u)" -eq 0 ]] && SUDO=""

# ── Validate inputs ───────────────────────────────────────────────────
if [[ -z "${ISO_FILE}" ]]; then
    echo "Usage: $0 <path-to-ubuntu-server.iso>" >&2
    exit 1
fi

if [[ ! -f "${ISO_FILE}" ]]; then
    echo "ERROR: ISO file not found: ${ISO_FILE}" >&2
    exit 1
fi

# Detect package source mode from config
INSTALL_PKG_SOURCE="online"
INSTALL_CONF="${ROOT_DIR}/config/install.conf"
if [[ -f "${INSTALL_CONF}" ]]; then
    # shellcheck source=/dev/null
    source "${INSTALL_CONF}"
    INSTALL_PKG_SOURCE="${INSTALL_PKG_SOURCE:-online}"
fi

if [[ "${INSTALL_PKG_SOURCE}" == "offline" && ! -d "${LOCAL_REPO}" ]]; then
    echo "ERROR: local repo not found at ${LOCAL_REPO}. Run repo/create-local-repo.sh first." >&2
    exit 1
fi

# ── Ensure required tools ─────────────────────────────────────────────
for cmd in xorriso; do
    if ! command -v "${cmd}" &>/dev/null; then
        log "Installing ${cmd}"
        $SUDO apt-get install -y "${cmd}"
    fi
done

# ── Extract ISO ───────────────────────────────────────────────────────
log "Extracting ISO to ${EXTRACT_DIR}"
rm -rf "${EXTRACT_DIR}"
mkdir -p "${EXTRACT_DIR}"

xorriso -osirrox on -indev "${ISO_FILE}" -extract / "${EXTRACT_DIR}"

# The extracted tree is read-only; fix permissions
chmod -R u+w "${EXTRACT_DIR}"

# ── Inject autoinstall directory ──────────────────────────────────────
# Ubuntu Server 22.04+ looks for autoinstall config at:
#   /autoinstall/user-data   and   /autoinstall/meta-data
# on the installation media (the ISO / USB root).
log "Injecting autoinstall configuration"
AUTOINSTALL_DEST="${EXTRACT_DIR}/autoinstall"
mkdir -p "${AUTOINSTALL_DEST}"
cp "${AUTOINSTALL_DIR}/user-data"  "${AUTOINSTALL_DEST}/user-data"
cp "${AUTOINSTALL_DIR}/meta-data"  "${AUTOINSTALL_DEST}/meta-data"

# Also place at the ISO root for compatibility with older subiquity
cp "${AUTOINSTALL_DIR}/user-data"  "${EXTRACT_DIR}/user-data"
cp "${AUTOINSTALL_DIR}/meta-data"  "${EXTRACT_DIR}/meta-data"

# ── Inject local APT repository (offline mode only) ──────────────────
if [[ "${INSTALL_PKG_SOURCE}" == "offline" ]]; then
    log "Injecting local APT repository (offline mode)"
    REPO_DEST="${EXTRACT_DIR}/repo"
    rm -rf "${REPO_DEST}"
    cp -a "${LOCAL_REPO}" "${REPO_DEST}"
else
    log "Skipping local APT repository (online mode)"
fi

# ── Inject bootstrap script ──────────────────────────────────────────
log "Injecting bootstrap script"
BOOTSTRAP_DEST="${EXTRACT_DIR}/bootstrap"
mkdir -p "${BOOTSTRAP_DEST}"
cp "${BOOTSTRAP_DIR}/bootstrap.sh" "${BOOTSTRAP_DEST}/bootstrap.sh"
chmod +x "${BOOTSTRAP_DEST}/bootstrap.sh"

if [[ -f "${INSTALL_CONF}" ]]; then
    cp "${INSTALL_CONF}" "${BOOTSTRAP_DEST}/bootstrap.conf"
    log "Injected bootstrap.conf with install configuration"
fi

# ── Inject scripts directory (interactive TUI, etc.) ──────────────────
SCRIPTS_SRC="${ROOT_DIR}/scripts"
if [[ -d "${SCRIPTS_SRC}" ]]; then
    log "Injecting scripts directory"
    SCRIPTS_DEST="${EXTRACT_DIR}/scripts"
    rm -rf "${SCRIPTS_DEST}"
    cp -a "${SCRIPTS_SRC}" "${SCRIPTS_DEST}"
    chmod +x "${SCRIPTS_DEST}"/*.sh 2>/dev/null || true
fi

# ── Inject config directory (package-list.txt for interactive TUI) ────
CONFIG_SRC="${ROOT_DIR}/config"
if [[ -d "${CONFIG_SRC}" ]]; then
    log "Injecting config directory"
    CONFIG_DEST="${EXTRACT_DIR}/config"
    mkdir -p "${CONFIG_DEST}"
    cp "${CONFIG_SRC}/package-list.txt" "${CONFIG_DEST}/package-list.txt" 2>/dev/null || true
fi

# ── Inject extras directory (for optional kubectl, etc.) ──────────────
EXTRAS_SRC="${ROOT_DIR}/extras"
if [[ -d "${EXTRAS_SRC}" ]]; then
    log "Injecting extras directory"
    cp -a "${EXTRAS_SRC}" "${EXTRACT_DIR}/extras"
fi

# ── Patch GRUB — add autoinstall kernel parameter ─────────────────────
log "Patching GRUB configuration"
GRUB_CFG="${EXTRACT_DIR}/boot/grub/grub.cfg"

if [[ -f "${GRUB_CFG}" ]]; then
    # Insert 'autoinstall' parameter and point to our cloud-init data
    # The ds=nocloud flag tells cloud-init where to find user-data/meta-data.
    sed -i 's|---$|autoinstall ds=nocloud\\;s=/cdrom/autoinstall/ ---|g' "${GRUB_CFG}"
    if [[ "${INSTALL_INTERACTIVE}" == "yes" ]]; then
        # Skip GRUB menu entirely — TUI is the first screen the user sees
        sed -i 's/^set timeout=.*/set timeout=0/' "${GRUB_CFG}"
        log "GRUB timeout set to 0 (interactive TUI mode)"
    else
        sed -i 's/^set timeout=.*/set timeout=1/' "${GRUB_CFG}"
    fi
    log "GRUB patched"
else
    log "WARN: grub.cfg not found at expected path — you may need to patch it manually"
fi

log "ISO customization complete. Extracted tree at: ${EXTRACT_DIR}"
