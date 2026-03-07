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

# In offline mode, disable network to prevent APT from reaching the internet.
# In online mode, omit the network section so the installer uses DHCP.
if [[ "${INSTALL_PKG_SOURCE}" == "offline" ]]; then
    cat >> "${OUTPUT}" <<USERDATA
  network:
    version: 2
    ethernets: {}

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

if [[ "${INSTALL_PKG_SOURCE}" == "online" ]]; then
    log "Mode: ONLINE — packages will be downloaded during install"
    cat >> "${OUTPUT}" <<USERDATA
  packages:
$(echo -e "${PACKAGES_YAML}")
  late-commands:
    - cp /cdrom/bootstrap/bootstrap.sh /target/tmp/bootstrap.sh
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
    # Run the bootstrap provisioning script
    - cp /cdrom/bootstrap/bootstrap.sh /target/tmp/bootstrap.sh
    - chmod +x /target/tmp/bootstrap.sh
    - curtin in-target --target=/target -- /tmp/bootstrap.sh

  shutdown: reboot
USERDATA
fi

log "user-data generated at ${OUTPUT}"
