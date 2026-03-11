#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# LocalBooth — generate autoinstall user-data from config/install.conf
#
# Reads the configuration values and produces the final user-data YAML
# with the password hash generated via openssl.  This script runs
# inside the Docker container where openssl supports SHA-512.
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT_DIR="${1:-.}"
CONF_FILE="${ROOT_DIR}/config/install.conf"
TEMPLATE="${ROOT_DIR}/autoinstall/user-data.tmpl"
OUTPUT="${ROOT_DIR}/autoinstall/user-data"

log() { echo "[localbooth] $(date '+%F %T') — $*"; }

# ── Defaults (used when no install.conf exists) ──────────────────────
INSTALL_USERNAME="dev"
INSTALL_PASSWORD="changeme"
INSTALL_HOSTNAME="localbooth"
INSTALL_LOCALE="en_US.UTF-8"
INSTALL_KEYBOARD="us"
INSTALL_TIMEZONE="UTC"
INSTALL_DISK_LAYOUT="lvm"
INSTALL_SSH="yes"
INSTALL_PKG_SOURCE="online"
INSTALL_INTERACTIVE="no"

# ── Load config ──────────────────────────────────────────────────────
if [[ -f "${CONF_FILE}" ]]; then
    log "Loading configuration from ${CONF_FILE}"
    # shellcheck source=/dev/null
    source "${CONF_FILE}"
else
    log "No install.conf found — using defaults"
fi

# ── Generate password hash ───────────────────────────────────────────
log "Generating password hash for user '${INSTALL_USERNAME}'"
PASSWORD_HASH=$(openssl passwd -6 "${INSTALL_PASSWORD}")

# ── Resolve SSH boolean ──────────────────────────────────────────────
SSH_INSTALL="true"
SSH_ALLOW_PW="true"
if [[ "${INSTALL_SSH}" == "no" ]]; then
    SSH_INSTALL="false"
    SSH_ALLOW_PW="false"
fi

# ── Read packages from package-list.txt ──────────────────────────────
PACKAGES_SPACE=""
PACKAGES_YAML=""
if [[ -f "${ROOT_DIR}/config/package-list.txt" ]]; then
    while IFS= read -r line; do
        line=$(echo "${line}" | sed 's/#.*//' | xargs)
        [[ -z "${line}" ]] && continue
        PACKAGES_SPACE="${PACKAGES_SPACE} ${line}"
        PACKAGES_YAML="${PACKAGES_YAML}    - ${line}\n"
    done < "${ROOT_DIR}/config/package-list.txt"
fi
PACKAGES_SPACE=$(echo "${PACKAGES_SPACE}" | xargs)

# ── Generate user-data ───────────────────────────────────────────────
log "Writing user-data (user=${INSTALL_USERNAME}, host=${INSTALL_HOSTNAME}, pkg_source=${INSTALL_PKG_SOURCE})"

# Common header shared by both modes
cat > "${OUTPUT}" <<USERDATA
#cloud-config
autoinstall:
  version: 1

  locale: ${INSTALL_LOCALE}
  keyboard:
    layout: ${INSTALL_KEYBOARD}
  timezone: ${INSTALL_TIMEZONE}

USERDATA

if [[ "${INSTALL_PKG_SOURCE}" == "offline" ]]; then
    cat >> "${OUTPUT}" <<USERDATA
  network:
    version: 2
    ethernets: {}

USERDATA
else
    cat >> "${OUTPUT}" <<USERDATA
  network:
    version: 2
    ethernets:
      any-ethernet:
        match:
          name: "e*"
        dhcp4: true

USERDATA
fi

cat >> "${OUTPUT}" <<USERDATA
  storage:
    layout:
      name: ${INSTALL_DISK_LAYOUT}

  identity:
    hostname: ${INSTALL_HOSTNAME}
    username: ${INSTALL_USERNAME}
    password: "${PASSWORD_HASH}"

  ssh:
    install-server: ${SSH_INSTALL}
    allow-pw: ${SSH_ALLOW_PW}

USERDATA

# ── Early-commands ────────────────────────────────────────────────────
# Always add early-commands to fix FAT32 symlink issues on writable USBs.
# On read-only ISO boots these commands fail silently (harmless).
log "Adding early-commands (FAT32 compat + optional TUI)"
cat >> "${OUTPUT}" <<'USERDATA'
  early-commands:
    - |
      # Fix missing symlinks on FAT32 writable USB.
      # The ISO has symlinks (ubuntu -> ., dists/stable -> noble, etc.)
      # that rsync --no-links skips. Without them the installer's APT
      # can't find bootloader packages (grub-efi-amd64, shim-signed).
      # Bind-mounting restores the paths the installer expects.
      if [ ! -e /cdrom/ubuntu ] && [ -d /cdrom/dists ]; then
        mkdir -p /cdrom/ubuntu 2>/dev/null || true
        mount --bind /cdrom /cdrom/ubuntu 2>/dev/null || true
        echo '[localbooth] Created /cdrom/ubuntu bind mount (FAT32 fix)'
      fi
      CODENAME=""
      for d in /cdrom/dists/*/; do
        name=$(basename "$d")
        case "$name" in stable|unstable) continue ;; esac
        CODENAME="$name"
        break
      done
      if [ -n "$CODENAME" ]; then
        if [ ! -e /cdrom/dists/stable ]; then
          mkdir -p /cdrom/dists/stable 2>/dev/null || true
          mount --bind "/cdrom/dists/$CODENAME" /cdrom/dists/stable 2>/dev/null || true
        fi
        if [ ! -e /cdrom/dists/unstable ]; then
          mkdir -p /cdrom/dists/unstable 2>/dev/null || true
          mount --bind "/cdrom/dists/$CODENAME" /cdrom/dists/unstable 2>/dev/null || true
        fi
      fi
USERDATA

if [[ "${INSTALL_INTERACTIVE}" == "yes" ]]; then
    log "Interactive mode enabled — adding TUI to early-commands"
    cat >> "${OUTPUT}" <<'USERDATA'
    - |
      # Remount /cdrom read-write so the TUI can update user-data on the USB
      mount -o remount,rw /cdrom 2>/dev/null || true
      # Launch TUI on a visible virtual terminal
      if command -v openvt >/dev/null 2>&1; then
        openvt -s -w -- bash /cdrom/scripts/interactive-config.sh
      elif command -v chvt >/dev/null 2>&1; then
        chvt 2
        bash /cdrom/scripts/interactive-config.sh </dev/tty2 >/dev/tty2 2>&1
        chvt 1
      else
        bash /cdrom/scripts/interactive-config.sh </dev/tty1 >/dev/tty1 2>&1
      fi
USERDATA
fi

# Blank line after early-commands section
echo "" >> "${OUTPUT}"

if [[ "${INSTALL_PKG_SOURCE}" == "online" ]]; then
    log "Mode: ONLINE — packages will be downloaded during install"
    cat >> "${OUTPUT}" <<USERDATA
  late-commands:
    # Wait for network — USB-C/USB ethernet adapters may take time to initialize
    - |
      echo '[localbooth] Waiting for network...'
      for i in \$(seq 1 60); do
        if ip route | grep -q default; then
          echo "[localbooth] Network ready (attempt \$i)"
          break
        fi
        # Try to bring up any ethernet interface via DHCP
        for iface in \$(ls /sys/class/net/ | grep -E '^(en|eth)'); do
          ip link set "\$iface" up 2>/dev/null || true
          dhclient "\$iface" 2>/dev/null || true
        done
        sleep 2
      done
      if ! ip route | grep -q default; then
        echo '[localbooth] WARNING: No network after 120s — package install may fail'
      fi
    - curtin in-target --target=/target -- apt-get update
    - curtin in-target --target=/target -- apt-get install -y ${PACKAGES_SPACE}
    # Bootstrap handles: MakeInstall (docker, terraform, etc.), user groups, permissions
    - cp /cdrom/bootstrap/bootstrap.sh /target/tmp/bootstrap.sh
    - cp /cdrom/bootstrap/bootstrap.conf /target/tmp/bootstrap.conf || true
    - chmod +x /target/tmp/bootstrap.sh
    - curtin in-target --target=/target -- /tmp/bootstrap.sh

  shutdown: reboot
USERDATA
else
    log "Mode: OFFLINE — packages will be installed from local repo"
    log "Packages: ${PACKAGES_SPACE}"
    cat >> "${OUTPUT}" <<USERDATA
  updates: security
  package_update: false
  package_upgrade: false

  late-commands:
    # Temporarily disable default sources and point APT at our offline repo
    - mv /target/etc/apt/sources.list.d/ubuntu.sources /target/etc/apt/sources.list.d/ubuntu.sources.bak || true
    - echo 'deb [trusted=yes] file:///mnt/repo ./' > /target/etc/apt/sources.list
    - mkdir -p /target/mnt/repo
    - mount --bind /cdrom/repo /target/mnt/repo
    - curtin in-target --target=/target -- apt-get update
    - curtin in-target --target=/target -- apt-get install -y --no-install-recommends ${PACKAGES_SPACE}
    - umount /target/mnt/repo
    # Restore the original APT sources for future online updates
    - rm -f /target/etc/apt/sources.list
    - mv /target/etc/apt/sources.list.d/ubuntu.sources.bak /target/etc/apt/sources.list.d/ubuntu.sources || true
    # Bootstrap handles: MakeInstall (docker, terraform, etc.), user groups, permissions
    - cp /cdrom/bootstrap/bootstrap.sh /target/tmp/bootstrap.sh
    - cp /cdrom/bootstrap/bootstrap.conf /target/tmp/bootstrap.conf || true
    - chmod +x /target/tmp/bootstrap.sh
    - curtin in-target --target=/target -- /tmp/bootstrap.sh

  shutdown: reboot
USERDATA
fi

log "user-data generated at ${OUTPUT}"
