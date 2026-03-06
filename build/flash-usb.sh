#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# LocalBooth — flash ISO to USB drive (macOS & Linux)
#
# Safety features:
#   - Shows all removable disks and asks for confirmation
#   - Refuses to write to the boot disk
#   - Unmounts the target before writing
#   - Uses rdisk (raw) on macOS for ~10x faster writes
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

ISO_FILE="${1:-}"

log() { echo "[localbooth] $(date '+%F %T') — $*"; }

if [[ -z "${ISO_FILE}" ]]; then
    echo "Usage: $0 <path-to-iso>" >&2
    exit 1
fi

if [[ ! -f "${ISO_FILE}" ]]; then
    echo "ERROR: ISO not found: ${ISO_FILE}" >&2
    exit 1
fi

ISO_SIZE=$(du -h "${ISO_FILE}" | cut -f1)
OS="$(uname -s)"

# ── List available disks ─────────────────────────────────────────────
echo ""
echo "=== Available disks ==="
echo ""

if [[ "${OS}" == "Darwin" ]]; then
    diskutil list external physical 2>/dev/null || diskutil list
else
    lsblk -d -o NAME,SIZE,TYPE,MODEL,TRAN | grep -E 'disk|usb' || lsblk -d
fi

echo ""
echo "ISO to write: ${ISO_FILE} (${ISO_SIZE})"
echo ""

# ── Ask for target device ────────────────────────────────────────────
read -rp "Enter the target disk (e.g. disk2 on macOS, sdb on Linux): " DISK_INPUT

# Normalize: strip /dev/ prefix if provided
DISK_INPUT="${DISK_INPUT#/dev/}"

if [[ -z "${DISK_INPUT}" ]]; then
    echo "ERROR: no disk specified." >&2
    exit 1
fi

DEVICE="/dev/${DISK_INPUT}"

# ── Safety: refuse to write to boot disk ─────────────────────────────
if [[ "${OS}" == "Darwin" ]]; then
    BOOT_DISK=$(diskutil info / | grep "Part of Whole" | awk '{print $NF}')
    if [[ "${DISK_INPUT}" == "${BOOT_DISK}" ]]; then
        echo "ERROR: ${DEVICE} is your boot disk. Aborting." >&2
        exit 1
    fi
else
    ROOT_DEV=$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//' | xargs basename)
    if [[ "${DISK_INPUT}" == "${ROOT_DEV}" ]]; then
        echo "ERROR: ${DEVICE} is your root disk. Aborting." >&2
        exit 1
    fi
fi

if [[ ! -e "${DEVICE}" ]]; then
    echo "ERROR: ${DEVICE} does not exist." >&2
    exit 1
fi

# ── Show disk info and confirm ───────────────────────────────────────
echo ""
echo "=== Target disk ==="
if [[ "${OS}" == "Darwin" ]]; then
    diskutil info "${DEVICE}" | grep -E 'Device|Media Name|Disk Size|Removable'
else
    lsblk "${DEVICE}"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  WARNING: ALL DATA ON ${DEVICE} WILL BE PERMANENTLY ERASED  "
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
read -rp "Type YES to continue: " CONFIRM

if [[ "${CONFIRM}" != "YES" ]]; then
    echo "Aborted."
    exit 0
fi

# ── Unmount ──────────────────────────────────────────────────────────
log "Unmounting ${DEVICE}"
if [[ "${OS}" == "Darwin" ]]; then
    diskutil unmountDisk "${DEVICE}" 2>/dev/null || true
else
    umount "${DEVICE}"* 2>/dev/null || true
fi

# ── Write ISO ────────────────────────────────────────────────────────
if [[ "${OS}" == "Darwin" ]]; then
    RAW_DEVICE="/dev/r${DISK_INPUT}"
    log "Writing ISO to ${RAW_DEVICE} (raw device for speed)"
    sudo dd if="${ISO_FILE}" of="${RAW_DEVICE}" bs=4m status=progress
else
    log "Writing ISO to ${DEVICE}"
    sudo dd if="${ISO_FILE}" of="${DEVICE}" bs=4M status=progress oflag=sync
fi

# ── Sync & eject ─────────────────────────────────────────────────────
log "Syncing"
sync

if [[ "${OS}" == "Darwin" ]]; then
    log "Ejecting ${DEVICE}"
    diskutil eject "${DEVICE}" 2>/dev/null || true
fi

echo ""
echo "================================================================="
echo "  USB ready."
echo ""
echo "  Plug it into any machine, boot from USB, and the install"
echo "  will run automatically.  Default user: dev / changeme"
echo "================================================================="
