#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# LocalBooth — quick config update (patch existing ISO)
#
# Regenerates user-data and patches the existing ISO in output/ using
# xorriso — without re-downloading the base ISO, packages, or doing a
# full rebuild.  Takes seconds instead of minutes.
#
# Usage:
#   ./build/update-config.sh                # reconfigure + patch + flash
#   ./build/update-config.sh --no-flash     # reconfigure + patch only
#   ./build/update-config.sh --no-configure # keep config, just re-patch + flash
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
OUTPUT_DIR="${ROOT_DIR}/output"
IMAGE_NAME="localbooth-builder"
CONF_FILE="${ROOT_DIR}/config/install.conf"
FLASH="true"
SKIP_CONFIG="false"

log() { echo "[localbooth] $(date '+%F %T') — $*"; }

# ── Parse arguments ───────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-flash)
            FLASH="false"
            shift
            ;;
        --defaults)
            SKIP_CONFIG="defaults"
            shift
            ;;
        --no-configure)
            SKIP_CONFIG="true"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--no-flash] [--defaults] [--no-configure]"
            echo ""
            echo "  --no-flash      Patch the ISO but don't flash to USB"
            echo "  --defaults      Use default values without prompting"
            echo "  --no-configure  Skip configuration (use existing install.conf)"
            echo ""
            echo "Requires: Docker + a previously built ISO in output/"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# ── Pre-flight checks ────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker is not installed." >&2
    exit 1
fi

if ! docker info &>/dev/null; then
    echo "ERROR: Docker daemon is not running." >&2
    exit 1
fi

ISO_FILE=$(ls -t "${OUTPUT_DIR}"/localbooth-*.iso 2>/dev/null | head -1)
if [[ -z "${ISO_FILE}" ]]; then
    echo "ERROR: No ISO found in output/. Run ./build/make-usb.sh first." >&2
    exit 1
fi

ISO_NAME=$(basename "${ISO_FILE}")
log "Found existing ISO: ${ISO_NAME}"

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

# ── Ensure Docker image exists ────────────────────────────────────────
if ! docker image inspect "${IMAGE_NAME}" &>/dev/null; then
    log "Docker image not found — building ${IMAGE_NAME}"
    docker build --platform linux/amd64 -t "${IMAGE_NAME}" "${ROOT_DIR}"
fi

# ── Patch ISO inside Docker ──────────────────────────────────────────
log "Regenerating user-data and patching ISO..."

docker run --rm --platform linux/amd64 \
    -v "${ROOT_DIR}/config:/localbooth/config:ro" \
    -v "${ROOT_DIR}/autoinstall:/localbooth/autoinstall" \
    -v "${OUTPUT_DIR}:/output" \
    --entrypoint bash \
    "${IMAGE_NAME}" \
    -c '
        set -euo pipefail
        ROOT="/localbooth"
        log() { echo "[localbooth] $(date "+%F %T") — $*"; }

        # 1. Generate new user-data from config
        bash "${ROOT}/build/generate-userdata.sh" "${ROOT}"

        # 2. Prepare files to inject
        STAGING=$(mktemp -d)
        cp "${ROOT}/autoinstall/user-data"  "${STAGING}/user-data"
        cp "${ROOT}/autoinstall/meta-data"  "${STAGING}/meta-data"
        cp "${ROOT}/config/install.conf"    "${STAGING}/bootstrap.conf" 2>/dev/null || true

        # 3. Patch the existing ISO with xorriso
        ISO=$(ls -t /output/localbooth-*.iso 2>/dev/null | head -1)
        if [[ -z "${ISO}" ]]; then
            echo "ERROR: ISO not found in /output" >&2
            exit 1
        fi

        log "Patching ${ISO##*/}"
        xorriso -indev "${ISO}" \
            -outdev "${ISO}.tmp" \
            -boot_image any replay \
            -overwrite on \
            -map "${STAGING}/user-data"       /autoinstall/user-data \
            -map "${STAGING}/user-data"       /user-data \
            -map "${STAGING}/meta-data"       /autoinstall/meta-data \
            -map "${STAGING}/meta-data"       /meta-data \
            -map "${STAGING}/bootstrap.conf"  /bootstrap/bootstrap.conf \
            -end

        mv "${ISO}.tmp" "${ISO}"
        ISO_SIZE=$(du -h "${ISO}" | cut -f1)
        log "ISO patched: ${ISO##*/} (${ISO_SIZE})"

        rm -rf "${STAGING}"
    '

echo ""
echo "================================================================="
echo "  ISO updated successfully"
echo ""
echo "  File: ${ISO_FILE}"
echo "================================================================="

# ── Flash to USB ──────────────────────────────────────────────────────
if [[ "${FLASH}" == "true" ]]; then
    echo ""
    log "Proceeding to flash USB..."
    echo ""
    bash "${SCRIPT_DIR}/flash-usb.sh" "${ISO_FILE}"
else
    echo ""
    echo "  To flash later:"
    echo "    ./build/flash-usb.sh ${ISO_FILE}"
    echo ""
fi
