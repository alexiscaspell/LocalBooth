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
PACKAGES_YAML=""
if [[ -f "${ROOT_DIR}/config/package-list.txt" ]]; then
    while IFS= read -r line; do
        line=$(echo "${line}" | sed 's/#.*//' | xargs)
        [[ -z "${line}" ]] && continue
        PACKAGES_YAML="${PACKAGES_YAML}    - ${line}\n"
    done < "${ROOT_DIR}/config/package-list.txt"
fi

# ── Generate user-data ───────────────────────────────────────────────
log "Writing user-data (user=${INSTALL_USERNAME}, host=${INSTALL_HOSTNAME})"

cat > "${OUTPUT}" <<USERDATA
#cloud-config
autoinstall:
  version: 1

  locale: ${INSTALL_LOCALE}
  keyboard:
    layout: ${INSTALL_KEYBOARD}
  timezone: ${INSTALL_TIMEZONE}

  network:
    version: 2
    ethernets: {}

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

  apt:
    preserve_sources_list: false
    sources_list: |
      deb [trusted=yes] file:///cdrom/repo ./
    geoip: false

  packages:
$(echo -e "${PACKAGES_YAML}")
  updates: security
  package_update: false
  package_upgrade: false

  late-commands:
    - cp /cdrom/bootstrap/bootstrap.sh /target/tmp/bootstrap.sh
    - chmod +x /target/tmp/bootstrap.sh
    - curtin in-target --target=/target -- /tmp/bootstrap.sh

  shutdown: reboot
USERDATA

log "user-data generated at ${OUTPUT}"
