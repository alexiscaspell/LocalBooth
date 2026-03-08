#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# LocalBooth — update config directly on a writable USB
#
# Mounts the LOCALBOOTH USB, regenerates user-data with the new config,
# and copies the updated files in place.  No re-flashing needed.
#
# The USB must have been created with:  flash-usb.sh --writable
#
# Usage:
#   ./build/update-usb.sh                # reconfigure + update USB
#   ./build/update-usb.sh --no-configure # update USB with current config
#   ./build/update-usb.sh --defaults     # use defaults without prompting
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
CONF_FILE="${ROOT_DIR}/config/install.conf"
IMAGE_NAME="localbooth-builder"
SKIP_CONFIG="false"
GUI=""
USB_LABEL="LOCALBOOTH"

log() { echo "[localbooth] $(date '+%F %T') — $*"; }

# ── Parse arguments ───────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --defaults)
            SKIP_CONFIG="defaults"
            shift
            ;;
        --no-configure)
            SKIP_CONFIG="true"
            shift
            ;;
        --gui)
            GUI="yes"
            shift
            ;;
        --no-gui)
            GUI="no"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--no-configure] [--defaults] [--gui] [--no-gui]"
            echo ""
            echo "  --no-configure  Skip prompts (use existing install.conf)"
            echo "  --defaults      Use default values without prompting"
            echo "  --gui           Enable interactive TUI at boot time"
            echo "  --no-gui        Disable interactive TUI at boot time"
            echo ""
            echo "Requires: Docker + a writable LOCALBOOTH USB (created with flash-usb.sh --writable)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# ── Pre-flight ────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker is not installed." >&2
    exit 1
fi

if ! docker info &>/dev/null; then
    echo "ERROR: Docker daemon is not running." >&2
    exit 1
fi

# ── Find the mounted USB ─────────────────────────────────────────────
OS="$(uname -s)"
USB_MOUNT=""

if [[ "${OS}" == "Darwin" ]]; then
    if [[ -d "/Volumes/${USB_LABEL}" ]]; then
        USB_MOUNT="/Volumes/${USB_LABEL}"
    fi
else
    USB_MOUNT=$(findmnt -rn -o TARGET -S LABEL="${USB_LABEL}" 2>/dev/null | head -1 || true)
    if [[ -z "${USB_MOUNT}" ]]; then
        USB_MOUNT=$(lsblk -rn -o MOUNTPOINT,LABEL 2>/dev/null | awk -v lbl="${USB_LABEL}" '$2==lbl{print $1}' | head -1 || true)
    fi
fi

if [[ -z "${USB_MOUNT}" || ! -d "${USB_MOUNT}" ]]; then
    echo "ERROR: USB '${USB_LABEL}' not found." >&2
    echo "" >&2
    echo "  Make sure the LocalBooth USB is plugged in and mounted." >&2
    echo "  The USB must have been created with:  ./build/flash-usb.sh --writable" >&2
    exit 1
fi

if [[ ! -d "${USB_MOUNT}/autoinstall" ]]; then
    echo "ERROR: ${USB_MOUNT} does not look like a LocalBooth USB (no autoinstall/ directory)." >&2
    exit 1
fi

log "Found USB at: ${USB_MOUNT}"

# ── Configure ─────────────────────────────────────────────────────────
if [[ "${SKIP_CONFIG}" == "defaults" ]]; then
    bash "${SCRIPT_DIR}/configure.sh" --defaults
elif [[ "${SKIP_CONFIG}" == "false" ]]; then
    bash "${SCRIPT_DIR}/configure.sh"
else
    if [[ ! -f "${CONF_FILE}" ]]; then
        log "No config/install.conf found — running configuration"
        bash "${SCRIPT_DIR}/configure.sh"
    else
        log "Using existing config/install.conf"
    fi
fi

# ── Handle --gui / --no-gui flag ──────────────────────────────────────
if [[ -n "${GUI}" ]]; then
    if grep -q '^INSTALL_INTERACTIVE=' "${CONF_FILE}" 2>/dev/null; then
        sed -i.bak "s/^INSTALL_INTERACTIVE=.*/INSTALL_INTERACTIVE=\"${GUI}\"/" "${CONF_FILE}"
        rm -f "${CONF_FILE}.bak"
    else
        echo "INSTALL_INTERACTIVE=\"${GUI}\"" >> "${CONF_FILE}"
    fi
    if [[ "${GUI}" == "yes" ]]; then
        log "Interactive TUI enabled"
    else
        log "Interactive TUI disabled"
    fi
fi

# ── Ensure Docker image exists ────────────────────────────────────────
if ! docker image inspect "${IMAGE_NAME}" &>/dev/null; then
    log "Docker image not found — building ${IMAGE_NAME}"
    docker build --platform linux/amd64 -t "${IMAGE_NAME}" "${ROOT_DIR}"
fi

# ── Generate user-data (Docker for password hash) ─────────────────────
log "Generating user-data..."

docker run --rm --platform linux/amd64 \
    -v "${ROOT_DIR}/config:/localbooth/config:ro" \
    -v "${ROOT_DIR}/autoinstall:/localbooth/autoinstall" \
    --entrypoint bash \
    "${IMAGE_NAME}" \
    -c 'bash /localbooth/build/generate-userdata.sh /localbooth'

# ── Copy updated files to USB ─────────────────────────────────────────
log "Updating files on USB..."

cp "${ROOT_DIR}/autoinstall/user-data" "${USB_MOUNT}/autoinstall/user-data"
cp "${ROOT_DIR}/autoinstall/user-data" "${USB_MOUNT}/user-data"
cp "${ROOT_DIR}/autoinstall/meta-data" "${USB_MOUNT}/autoinstall/meta-data"
cp "${ROOT_DIR}/autoinstall/meta-data" "${USB_MOUNT}/meta-data"

if [[ -f "${CONF_FILE}" ]]; then
    mkdir -p "${USB_MOUNT}/bootstrap"
    cp "${CONF_FILE}" "${USB_MOUNT}/bootstrap/bootstrap.conf"
fi

# Copy scripts directory (interactive TUI, etc.)
SCRIPTS_SRC="${ROOT_DIR}/scripts"
if [[ -d "${SCRIPTS_SRC}" ]]; then
    mkdir -p "${USB_MOUNT}/scripts"
    cp "${SCRIPTS_SRC}"/*.sh "${USB_MOUNT}/scripts/" 2>/dev/null || true
    chmod +x "${USB_MOUNT}/scripts/"*.sh 2>/dev/null || true
fi

# Copy package-list.txt (needed by interactive TUI for user-data generation)
if [[ -f "${ROOT_DIR}/config/package-list.txt" ]]; then
    mkdir -p "${USB_MOUNT}/config"
    cp "${ROOT_DIR}/config/package-list.txt" "${USB_MOUNT}/config/package-list.txt"
fi

sync

# ── Read config for display ──────────────────────────────────────────
DISPLAY_USER="dev"
DISPLAY_HOST="localbooth"
DISPLAY_PASS="changeme"
DISPLAY_PKG="online"
if [[ -f "${CONF_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CONF_FILE}"
    DISPLAY_USER="${INSTALL_USERNAME:-dev}"
    DISPLAY_HOST="${INSTALL_HOSTNAME:-localbooth}"
    DISPLAY_PASS="${INSTALL_PASSWORD:-changeme}"
    DISPLAY_PKG="${INSTALL_PKG_SOURCE:-online}"
fi

echo ""
echo "  ═══════════════════════════════════════════════════════"
echo "  USB updated."
echo ""
printf "  User:     %s\n" "${DISPLAY_USER}"
printf "  Password: %s\n" "$(echo "${DISPLAY_PASS}" | sed 's/./*/g')"
printf "  Hostname: %s\n" "${DISPLAY_HOST}"
printf "  Packages: %s\n" "${DISPLAY_PKG}"
echo ""
echo "  Eject the USB and plug it into the target machine."
echo "  ═══════════════════════════════════════════════════════"
echo ""
