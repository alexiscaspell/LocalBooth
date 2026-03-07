#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# LocalBooth — master build script
#
# End-to-end pipeline that produces a custom Ubuntu Server ISO ready to
# be flashed onto a USB drive for fully-offline automated installs.
#
# Steps:
#   1. Download the stock Ubuntu Server ISO (if not cached)
#   2. Download .deb packages for the offline repository
#   3. Build the local APT repository
#   4. Extract & customize the ISO
#   5. Rebuild the ISO
#   6. Print instructions for flashing to USB
#
# Usage:
#   sudo ./build/build-usb.sh              # uses defaults
#   sudo ./build/build-usb.sh --iso <file> # reuse an existing ISO
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

# ── Defaults (Ubuntu 24.04.1 LTS "Noble Numbat") ─────────────────────
UBUNTU_VERSION="24.04.1"
UBUNTU_CODENAME="noble"
ISO_URL="https://releases.ubuntu.com/${UBUNTU_VERSION}/ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"
ISO_DIR="${ROOT_DIR}/iso"
ISO_FILE="${ISO_DIR}/ubuntu-server.iso"
OUTPUT_ISO="${ROOT_DIR}/localbooth-ubuntu-${UBUNTU_VERSION}.iso"
EXTRACT_DIR="${ISO_DIR}/extracted"

log() { echo "[localbooth] $(date '+%F %T') — $*"; }

# ── Parse arguments ───────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --iso)
            ISO_FILE="$2"
            shift 2
            ;;
        --output)
            OUTPUT_ISO="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--iso <path>] [--output <path>]"
            echo ""
            echo "  --iso     Path to an existing Ubuntu Server ISO (skip download)"
            echo "  --output  Path for the generated custom ISO"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# ── Pre-flight checks ────────────────────────────────────────────────
if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: this script must be run as root (for apt operations and xorriso)." >&2
    echo "       Try:  sudo $0" >&2
    exit 1
fi

for cmd in wget xorriso dpkg-scanpackages apt-rdepends; do
    if ! command -v "${cmd}" &>/dev/null; then
        log "Installing missing tool: ${cmd}"
        apt-get install -y "${cmd}" || {
            # dpkg-scanpackages lives in dpkg-dev, apt-rdepends is its own package
            case "${cmd}" in
                dpkg-scanpackages) apt-get install -y dpkg-dev ;;
                *) echo "ERROR: cannot install ${cmd}" >&2; exit 1 ;;
            esac
        }
    fi
done

# ──────────────────────────────────────────────────────────────────────
# STEP 1 — Download the stock Ubuntu Server ISO
# ──────────────────────────────────────────────────────────────────────
if [[ -f "${ISO_FILE}" ]]; then
    log "Reusing existing ISO: ${ISO_FILE}"
else
    log "Downloading Ubuntu Server ${UBUNTU_VERSION} ISO"
    mkdir -p "${ISO_DIR}"
    wget --no-verbose --show-progress -O "${ISO_FILE}" "${ISO_URL}"
fi

# ──────────────────────────────────────────────────────────────────────
# STEP 2 — Download .deb packages
# ──────────────────────────────────────────────────────────────────────
log "=== Downloading packages ==="
bash "${ROOT_DIR}/packages/download-packages.sh"

# ──────────────────────────────────────────────────────────────────────
# STEP 3 — Build the local APT repository
# ──────────────────────────────────────────────────────────────────────
log "=== Building local APT repository ==="
bash "${ROOT_DIR}/repo/create-local-repo.sh"

# ──────────────────────────────────────────────────────────────────────
# STEP 4 — Extract & customize the ISO
# ──────────────────────────────────────────────────────────────────────
log "=== Customizing ISO ==="
bash "${ROOT_DIR}/iso/customize-iso.sh" "${ISO_FILE}"

# ──────────────────────────────────────────────────────────────────────
# STEP 5 — Rebuild the ISO
# ──────────────────────────────────────────────────────────────────────
log "=== Rebuilding ISO ==="

# Extract MBR from original ISO for hybrid boot
MBR_FILE="${ISO_DIR}/mbr.bin"
dd if="${ISO_FILE}" bs=1 count=446 of="${MBR_FILE}" 2>/dev/null

# Extract the EFI system partition from the original ISO.
# Ubuntu 24.04 embeds it as an El Torito entry, not a visible file.
EFI_IMG="${ISO_DIR}/efi.img"
log "Extracting EFI partition from original ISO"

BOOT_REPORT=$(xorriso -indev "${ISO_FILE}" -report_el_torito as_mkisofs 2>&1 || true)
EFI_INTERVAL=$(echo "${BOOT_REPORT}" \
    | grep -oP 'interval:local_fs:\K[0-9]+d-[0-9]+d' | head -1)

if [[ -z "${EFI_INTERVAL}" ]]; then
    log "ERROR: could not detect EFI partition in the ISO"
    exit 1
fi

EFI_START=$(echo "${EFI_INTERVAL}" | cut -d'-' -f1 | tr -d 'd')
EFI_END=$(echo "${EFI_INTERVAL}" | cut -d'-' -f2 | tr -d 'd')
EFI_COUNT=$((EFI_END - EFI_START + 1))
dd if="${ISO_FILE}" bs=512 skip="${EFI_START}" count="${EFI_COUNT}" \
    of="${EFI_IMG}" 2>/dev/null

log "Creating custom ISO: ${OUTPUT_ISO}"
xorriso -as mkisofs \
    -r -V "LocalBooth" \
    -o "${OUTPUT_ISO}" \
    --grub2-mbr "${MBR_FILE}" \
    -partition_offset 16 \
    --mbr-force-bootable \
    -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b "${EFI_IMG}" \
    -appended_part_as_gpt \
    -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
    -c '/boot.catalog' \
    -b '/boot/grub/i386-pc/eltorito.img' \
    -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
    -eltorito-alt-boot \
    -e '--interval:appended_partition_2:::' \
    -no-emul-boot \
    "${EXTRACT_DIR}"

ISO_SIZE=$(du -h "${OUTPUT_ISO}" | cut -f1)
log "Custom ISO created: ${OUTPUT_ISO} (${ISO_SIZE})"

# ──────────────────────────────────────────────────────────────────────
# STEP 6 — Instructions
# ──────────────────────────────────────────────────────────────────────
echo ""
echo "================================================================="
echo "  LocalBooth — custom ISO ready"
echo "================================================================="
echo ""
echo "  ISO:  ${OUTPUT_ISO}"
echo "  Size: ${ISO_SIZE}"
echo ""
echo "  Flash to USB:"
echo ""
echo "    # Identify your USB device (e.g. /dev/sdX)"
echo "    lsblk"
echo ""
echo "    # Write the ISO (DANGER: this erases the device)"
echo "    sudo dd if=${OUTPUT_ISO} of=/dev/sdX bs=4M status=progress oflag=sync"
echo ""
echo "    # Or use a friendlier tool:"
echo "    #   sudo apt install usb-creator-gtk"
echo "    #   Or: https://etcher.balena.io"
echo ""
echo "  Boot any machine from the USB — the install runs automatically."
echo "  Default user: dev / changeme"
echo ""
echo "================================================================="
