#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# LocalBooth — one command to rule them all
#
# Builds the custom ISO inside Docker and flashes it to a USB drive.
# Run this from your Mac (or any machine with Docker installed).
#
# Usage:
#   ./build/make-usb.sh            # build + flash
#   ./build/make-usb.sh --no-flash # build only (ISO left in output/)
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
OUTPUT_DIR="${ROOT_DIR}/output"
IMAGE_NAME="localbooth-builder"
ISO_CACHE_DIR="${ROOT_DIR}/.iso-cache"
FLASH="true"
SKIP_CONFIG="false"
CONF_FILE="${ROOT_DIR}/config/install.conf"

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
            echo "  --no-flash      Build the ISO but don't flash to USB"
            echo "  --defaults      Use default values without prompting"
            echo "  --no-configure  Skip configuration (use existing install.conf)"
            echo ""
            echo "Requires: Docker"
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
    echo "       Install Docker Desktop: https://www.docker.com/products/docker-desktop" >&2
    exit 1
fi

if ! docker info &>/dev/null; then
    echo "ERROR: Docker daemon is not running. Start Docker Desktop first." >&2
    exit 1
fi

# ── Configure ────────────────────────────────────────────────────────
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

# ── Prepare directories ──────────────────────────────────────────────
mkdir -p "${OUTPUT_DIR}" "${ISO_CACHE_DIR}"

# ── Build Docker image ───────────────────────────────────────────────
log "Building Docker image: ${IMAGE_NAME} (linux/amd64)"
docker build --platform linux/amd64 -t "${IMAGE_NAME}" "${ROOT_DIR}"

# ── Run the build inside Docker ──────────────────────────────────────
# Mount two volumes:
#   - output/      → /output     (ISO written here, persists on host)
#   - .iso-cache/  → /localbooth/iso  (cache the downloaded ISO between runs)
log "Running build inside Docker container..."
log "This will download the Ubuntu ISO (~2.6 GB) on first run."
echo ""

docker run --rm \
    --platform linux/amd64 \
    -v "${OUTPUT_DIR}:/output" \
    -v "${ISO_CACHE_DIR}:/iso-cache" \
    -v "${ROOT_DIR}/config:/localbooth/config" \
    "${IMAGE_NAME}"

# ── Find the output ISO ──────────────────────────────────────────────
ISO_FILE=$(find "${OUTPUT_DIR}" -maxdepth 1 -name '*.iso' -type f | head -1)

if [[ -z "${ISO_FILE}" ]]; then
    echo "ERROR: no ISO found in ${OUTPUT_DIR}" >&2
    exit 1
fi

ISO_SIZE=$(du -h "${ISO_FILE}" | cut -f1)
echo ""
echo "================================================================="
echo "  ISO built successfully"
echo ""
echo "  File: ${ISO_FILE}"
echo "  Size: ${ISO_SIZE}"
echo "================================================================="

# ── Flash to USB ─────────────────────────────────────────────────────
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
