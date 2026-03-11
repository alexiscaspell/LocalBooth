#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# LocalBooth — build the custom ISO (runs INSIDE the Docker container)
#
# This script is the container ENTRYPOINT.  It runs the full pipeline
# and writes the final ISO to /output/ (a bind-mounted volume from the
# host so the ISO is accessible after the container exits).
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT_DIR="/localbooth"
OUTPUT_DIR="/output"
ISO_CACHE="/iso-cache"
WORK_DIR="${ROOT_DIR}/iso"

UBUNTU_VERSION="24.04.1"
ISO_URL="https://releases.ubuntu.com/${UBUNTU_VERSION}/ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"
ISO_FILE="${ISO_CACHE}/ubuntu-server.iso"
OUTPUT_ISO="${OUTPUT_DIR}/localbooth-ubuntu-${UBUNTU_VERSION}.iso"
EXTRACT_DIR="${WORK_DIR}/extracted"

log() { echo "[localbooth] $(date '+%F %T') — $*"; }

# ── Detect package source mode from config ────────────────────────────
CONF_FILE="${ROOT_DIR}/config/install.conf"
INSTALL_PKG_SOURCE="online"
if [[ -f "${CONF_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CONF_FILE}"
    INSTALL_PKG_SOURCE="${INSTALL_PKG_SOURCE:-online}"
fi

mkdir -p "${OUTPUT_DIR}" "${ISO_CACHE}" "${WORK_DIR}"

# ── STEP 1 — Download stock ISO ──────────────────────────────────────
if [[ -f "${ISO_FILE}" ]]; then
    log "Reusing cached ISO: ${ISO_FILE}"
else
    log "Downloading Ubuntu Server ${UBUNTU_VERSION} ISO (this may take a while)..."
    wget --no-verbose --show-progress -O "${ISO_FILE}" "${ISO_URL}"
fi

# ── STEP 1.5 — Generate user-data from config ────────────────────────
log "=== Generating autoinstall user-data ==="
log "Config: PKG_SOURCE=${INSTALL_PKG_SOURCE:-unset}, INTERACTIVE=${INSTALL_INTERACTIVE:-unset}"
bash "${ROOT_DIR}/build/generate-userdata.sh" "${ROOT_DIR}"

# ── STEP 2 & 3 — Download packages & build repo (offline mode only) ──
if [[ "${INSTALL_PKG_SOURCE}" == "offline" ]]; then
    log "=== Downloading packages (offline mode) ==="
    bash "${ROOT_DIR}/packages/download-packages.sh"

    log "=== Building local APT repository ==="
    bash "${ROOT_DIR}/repo/create-local-repo.sh"
else
    log "=== Skipping package download (online mode — packages will be fetched during install) ==="
fi

# ── STEP 4 — Extract & customize ISO ─────────────────────────────────
log "=== Customizing ISO ==="
bash "${ROOT_DIR}/iso/customize-iso.sh" "${ISO_FILE}"

# ── STEP 5 — Rebuild the ISO ─────────────────────────────────────────
log "=== Rebuilding ISO ==="

# Extract MBR (first 446 bytes) for hybrid BIOS boot
MBR_FILE="${WORK_DIR}/mbr.bin"
dd if="${ISO_FILE}" bs=1 count=446 of="${MBR_FILE}" 2>/dev/null

# Extract the EFI system partition image from the original ISO.
# Ubuntu 24.04 embeds the EFI image as an El Torito partition, not a
# visible file.  We parse xorriso's report to locate and extract it.
EFI_IMG="${WORK_DIR}/efi.img"
log "Extracting EFI partition from original ISO"

BOOT_REPORT=$(xorriso -indev "${ISO_FILE}" -report_el_torito as_mkisofs 2>&1 || true)

EFI_INTERVAL=$(echo "${BOOT_REPORT}" \
    | grep -oP 'interval:local_fs:\K[0-9]+d-[0-9]+d' \
    | head -1)

if [[ -z "${EFI_INTERVAL}" ]]; then
    log "ERROR: could not detect EFI partition boundaries in the original ISO"
    log "xorriso report:"
    echo "${BOOT_REPORT}"
    exit 1
fi

EFI_START=$(echo "${EFI_INTERVAL}" | cut -d'-' -f1 | tr -d 'd')
EFI_END=$(echo "${EFI_INTERVAL}" | cut -d'-' -f2 | tr -d 'd')
EFI_COUNT=$((EFI_END - EFI_START + 1))

log "EFI partition: sectors ${EFI_START}–${EFI_END} (${EFI_COUNT} × 512 bytes)"
dd if="${ISO_FILE}" bs=512 skip="${EFI_START}" count="${EFI_COUNT}" \
    of="${EFI_IMG}" 2>/dev/null

if [[ ! -s "${EFI_IMG}" ]]; then
    log "ERROR: EFI image extraction produced an empty file"
    exit 1
fi
log "EFI image extracted: $(du -h "${EFI_IMG}" | cut -f1)"

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
log "ISO ready: ${OUTPUT_ISO} (${ISO_SIZE})"
