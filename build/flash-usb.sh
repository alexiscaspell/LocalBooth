#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# LocalBooth — flash ISO to USB drive (macOS & Linux)
#
# Modes:
#   Default (dd):   Raw-copy the ISO to USB.  Fast, BIOS+UEFI, but the
#                   USB is read-only (ISO 9660).
#   --writable:     Format USB as FAT32 and copy files.  Writable, so
#                   you can update config later without re-flashing.
#                   Requires UEFI boot (most modern hardware).
#
# Safety features:
#   - Auto-detects removable/external disks
#   - Shows a numbered menu to pick the target
#   - Refuses to write to the boot disk
#   - Unmounts the target before writing
#   - Uses rdisk (raw) on macOS for ~10x faster writes (dd mode)
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

WRITABLE="false"
ISO_FILE=""

for arg in "$@"; do
    case "${arg}" in
        --writable) WRITABLE="true" ;;
        -h|--help)
            echo "Usage: $0 [--writable] <path-to-iso>"
            echo ""
            echo "  --writable  Create a writable FAT32 USB (UEFI only)."
            echo "              Allows updating config without re-flashing."
            echo "              Without this flag, uses dd (read-only, BIOS+UEFI)."
            exit 0
            ;;
        *) ISO_FILE="${arg}" ;;
    esac
done

log() { echo "[localbooth] $(date '+%F %T') — $*"; }

if [[ -z "${ISO_FILE}" ]]; then
    echo "Usage: $0 [--writable] <path-to-iso>" >&2
    exit 1
fi

if [[ ! -f "${ISO_FILE}" ]]; then
    echo "ERROR: ISO not found: ${ISO_FILE}" >&2
    exit 1
fi

ISO_SIZE=$(du -h "${ISO_FILE}" | cut -f1)
OS="$(uname -s)"

# ── Detect boot disk (to exclude it) ────────────────────────────────
BOOT_DISK=""
if [[ "${OS}" == "Darwin" ]]; then
    BOOT_DISK=$(diskutil info / 2>/dev/null | awk '/Part of Whole/{print $NF}' || echo "")
else
    BOOT_DISK=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/[0-9]*$//' | xargs basename 2>/dev/null || echo "")
fi

# ── Discover removable / external disks ──────────────────────────────
declare -a DISK_NAMES=()
declare -a DISK_LABELS=()

if [[ "${OS}" == "Darwin" ]]; then
    # Parse diskutil to find external physical disks.
    # Only look at header lines like: /dev/disk4 (external, physical):
    while IFS= read -r line; do
        disk=$(echo "${line}" | awk '/^\/dev\/disk[0-9]/{gsub(/[^0-9]/,"",$1); print "disk"$1}')
        [[ -z "${disk}" ]] && continue
        [[ "${disk}" == "${BOOT_DISK}" ]] && continue

        # Skip if already added (diskutil may list partitions too)
        already_added="false"
        for existing in "${DISK_NAMES[@]+"${DISK_NAMES[@]}"}"; do
            [[ "${existing}" == "${disk}" ]] && already_added="true"
        done
        [[ "${already_added}" == "true" ]] && continue

        d_size=$(diskutil info "/dev/${disk}" 2>/dev/null | awk -F': *' '/Disk Size/{print $2}' | cut -d'(' -f1 | xargs || echo "?")
        d_name=$(diskutil info "/dev/${disk}" 2>/dev/null | awk -F': *' '/Media Name/{print $2}' | xargs || echo "Unknown")
        [[ -z "${d_name}" ]] && d_name="Unknown"
        [[ -z "${d_size}" ]] && d_size="?"

        DISK_NAMES+=("${disk}")
        DISK_LABELS+=("${disk}  ${d_size}  ${d_name}")
    done < <(diskutil list external physical 2>/dev/null || true)

else
    # Linux: find removable or USB-connected disks
    while IFS= read -r line; do
        disk=$(echo "${line}" | awk '{print $1}')
        [[ -z "${disk}" ]] && continue
        [[ "${disk}" == "${BOOT_DISK}" ]] && continue

        d_size=$(echo "${line}" | awk '{print $2}')
        d_model=$(echo "${line}" | awk '{$1=$2=$3=$4=""; print $0}' | xargs || echo "Unknown")
        d_tran=$(echo "${line}" | awk '{print $4}')
        [[ -z "${d_model}" ]] && d_model="Unknown"

        if [[ "${d_tran}" == "usb" ]] || \
           [[ -f "/sys/block/${disk}/removable" && "$(cat "/sys/block/${disk}/removable" 2>/dev/null)" == "1" ]]; then
            DISK_NAMES+=("${disk}")
            DISK_LABELS+=("${disk}  ${d_size}  ${d_model}")
        fi
    done < <(lsblk -d -n -o NAME,SIZE,TYPE,TRAN,MODEL 2>/dev/null | awk '/disk/' || true)
fi

# ── Show menu ────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           LocalBooth — Flash USB                           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  ISO: ${ISO_FILE}"
echo "  Size: ${ISO_SIZE}"
echo ""

if [[ ${#DISK_NAMES[@]} -eq 0 ]]; then
    echo "  No removable disks detected."
    echo ""
    echo "  Make sure your USB drive is plugged in."
    if [[ "${OS}" == "Darwin" ]]; then
        echo ""
        echo "  All disks on this system:"
        diskutil list
    fi
    exit 1
fi

echo "  Select the target USB drive:"
echo ""
for i in "${!DISK_LABELS[@]}"; do
    local_num=$((i + 1))
    printf "    %d)  /dev/%s\n" "${local_num}" "${DISK_LABELS[$i]}"
done
echo ""
printf "    0)  Cancel\n"
echo ""

read -rp "  Choose [0]: " SELECTION

# Default to 0 (cancel)
SELECTION="${SELECTION:-0}"

if [[ "${SELECTION}" == "0" ]]; then
    echo "  Aborted."
    exit 0
fi

if ! [[ "${SELECTION}" =~ ^[0-9]+$ ]] || (( SELECTION < 1 || SELECTION > ${#DISK_NAMES[@]} )); then
    echo "ERROR: invalid selection." >&2
    exit 1
fi

DISK_INPUT="${DISK_NAMES[$((SELECTION - 1))]}"
DEVICE="/dev/${DISK_INPUT}"

# ── Safety: double-check it's not the boot disk ─────────────────────
if [[ "${DISK_INPUT}" == "${BOOT_DISK}" ]]; then
    echo "ERROR: ${DEVICE} is your boot disk. Aborting." >&2
    exit 1
fi

if [[ ! -e "${DEVICE}" ]]; then
    echo "ERROR: ${DEVICE} does not exist." >&2
    exit 1
fi

# ── Show disk info and confirm ───────────────────────────────────────
echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │  Selected: /dev/${DISK_LABELS[$((SELECTION - 1))]}"
echo "  └─────────────────────────────────────────────────────┘"
echo ""
if [[ "${OS}" == "Darwin" ]]; then
    diskutil info "${DEVICE}" | grep -E 'Device|Media Name|Disk Size|Removable' | sed 's/^/  /'
else
    lsblk "${DEVICE}" | sed 's/^/  /'
fi

echo ""
echo "  ╔════════════════════════════════════════════════════════╗"
echo "  ║  WARNING: ALL DATA ON ${DEVICE} WILL BE ERASED        "
echo "  ╚════════════════════════════════════════════════════════╝"
echo ""
read -rp "  Type YES to continue: " CONFIRM

if [[ "${CONFIRM}" != "YES" ]]; then
    echo "  Aborted."
    exit 0
fi

# ── Unmount ──────────────────────────────────────────────────────────
log "Unmounting ${DEVICE}"
if [[ "${OS}" == "Darwin" ]]; then
    diskutil unmountDisk "${DEVICE}" 2>/dev/null || true
else
    # Kill any processes using the device
    sudo fuser -km "${DEVICE}" 2>/dev/null || true
    for part in "${DEVICE}"?* "${DEVICE}p"?*; do
        [[ -b "${part}" ]] || continue
        sudo fuser -km "${part}" 2>/dev/null || true
        sudo umount -f "${part}" 2>/dev/null || true
    done
    sudo umount -f "${DEVICE}" 2>/dev/null || true
    sleep 1

    # Verify nothing is still mounted
    if mount | grep -q "${DEVICE}"; then
        log "WARN: device still mounted — forcing lazy unmount"
        for part in "${DEVICE}"?* "${DEVICE}p"?*; do
            [[ -b "${part}" ]] || continue
            sudo umount -l "${part}" 2>/dev/null || true
        done
        sudo umount -l "${DEVICE}" 2>/dev/null || true
        sleep 2
    fi
fi

# ── Write to USB ─────────────────────────────────────────────────────
if [[ "${WRITABLE}" == "true" ]]; then
    # ── Writable mode: FAT32 + file copy (UEFI only) ─────────────────
    log "Creating writable FAT32 USB (UEFI boot)"

    if [[ "${OS}" == "Darwin" ]]; then
        log "Formatting ${DEVICE} as FAT32 (MBR)"
        diskutil eraseDisk MS-DOS LOCALBOOTH MBR "${DEVICE}"
        USB_MOUNT="/Volumes/LOCALBOOTH"

        log "Mounting ISO"
        ISO_MOUNT_INFO=$(hdiutil attach -nobrowse "${ISO_FILE}" 2>/dev/null)
        ISO_MOUNT=$(echo "${ISO_MOUNT_INFO}" | awk '{$1=$2=""; print $0}' | xargs | tail -1)
        if [[ -z "${ISO_MOUNT}" || ! -d "${ISO_MOUNT}" ]]; then
            ISO_MOUNT=$(echo "${ISO_MOUNT_INFO}" | grep -o '/Volumes/[^ ]*' | head -1)
        fi

        log "Copying files to USB (this may take a few minutes)..."
        # -L follows symlinks (copies actual files). FAT32 can't store symlinks
        # so -a alone silently skips them, losing EFI bootloader files.
        # Exclude 'ubuntu' to avoid infinite recursion (ubuntu -> . on the ISO).
        rsync -rLtD --info=progress2 --exclude='ubuntu' "${ISO_MOUNT}/" "${USB_MOUNT}/"

        log "Unmounting ISO"
        hdiutil detach "${ISO_MOUNT}" 2>/dev/null || true

        log "Ejecting USB"
        diskutil eject "${DEVICE}" 2>/dev/null || true

    else
        log "Wiping existing partition table on ${DEVICE}"
        sudo wipefs -af "${DEVICE}"
        log "Partitioning ${DEVICE} as MBR + FAT32"
        echo ',,0C,*' | sudo sfdisk --force --label dos --wipe always "${DEVICE}"

        # Tell the kernel to re-read the partition table
        sudo partprobe "${DEVICE}" 2>/dev/null || sudo blockdev --rereadpt "${DEVICE}" 2>/dev/null || true
        sleep 2

        # Format with retry in case the kernel hasn't released the old mount
        if ! sudo mkfs.vfat -F 32 -n LOCALBOOTH "${DEVICE}1" 2>/dev/null; then
            log "WARN: mkfs failed, retrying after unmount..."
            sudo umount -f "${DEVICE}1" 2>/dev/null || true
            sudo umount -l "${DEVICE}1" 2>/dev/null || true
            sleep 2
            sudo partprobe "${DEVICE}" 2>/dev/null || true
            sleep 1
            sudo mkfs.vfat -F 32 -n LOCALBOOTH "${DEVICE}1"
        fi

        USB_MOUNT=$(mktemp -d)
        ISO_MOUNT=$(mktemp -d)

        # Mount with -o flush so the kernel writes data to USB continuously
        # instead of caching everything and flushing at unmount (which hangs).
        sudo mount -o flush "${DEVICE}1" "${USB_MOUNT}"
        sudo mount -o loop,ro "${ISO_FILE}" "${ISO_MOUNT}"

        log "Copying files to USB (this may take a few minutes)..."
        log "DO NOT remove the USB until you see 'USB ready'."
        # -L follows symlinks (copies actual files). --no-links would skip
        # them entirely, losing EFI bootloader files and APT repo paths.
        # Exclude 'ubuntu' to avoid infinite recursion (ubuntu -> . on the ISO).
        sudo rsync -rLtD --info=progress2 --exclude='ubuntu' "${ISO_MOUNT}/" "${USB_MOUNT}/"

        # Verify critical boot files were copied
        log "── Verifying USB boot files ──"
        echo "  ISO EFI contents:"
        ls -la "${ISO_MOUNT}/EFI/BOOT/" 2>/dev/null || echo "  [NOT FOUND on ISO]"
        echo ""
        echo "  USB EFI contents:"
        ls -la "${USB_MOUNT}/EFI/BOOT/" 2>/dev/null || echo "  [NOT FOUND on USB]"
        echo ""
        echo "  === ISO GRUB config (FULL) ==="
        cat "${ISO_MOUNT}/boot/grub/grub.cfg" 2>/dev/null || echo "  [NOT FOUND]"
        echo ""
        echo "  === USB GRUB config (FULL) ==="
        cat "${USB_MOUNT}/boot/grub/grub.cfg" 2>/dev/null || echo "  [NOT FOUND]"
        echo ""
        for f in BOOTx64.EFI grubx64.efi shimx64.efi mmx64.efi; do
            if [[ -f "${USB_MOUNT}/EFI/BOOT/${f}" ]]; then
                SIZE=$(stat -c%s "${USB_MOUNT}/EFI/BOOT/${f}" 2>/dev/null || echo "?")
                log "  OK: EFI/BOOT/${f} (${SIZE} bytes)"
            else
                log "  MISSING: EFI/BOOT/${f}"
            fi
        done
        echo ""

        log "Unmounting ISO"
        sudo umount "${ISO_MOUNT}" 2>/dev/null || true
        rmdir "${ISO_MOUNT}" 2>/dev/null || true

        log "Flushing remaining writes to USB..."
        sync -f "${USB_MOUNT}/EFI" 2>/dev/null || sync 2>/dev/null || true

        log "Unmounting USB..."
        if ! timeout 120 sudo umount "${USB_MOUNT}" 2>/dev/null; then
            log "WARN: normal unmount timed out — forcing"
            sudo umount -f "${USB_MOUNT}" 2>/dev/null || true
            sleep 2
            sudo umount -l "${USB_MOUNT}" 2>/dev/null || true
        fi
        rmdir "${USB_MOUNT}" 2>/dev/null || true

        log "Ejecting ${DEVICE}"
        sudo eject "${DEVICE}" 2>/dev/null || true
    fi

else
    # ── Standard mode: raw dd (BIOS + UEFI) ──────────────────────────
    if [[ "${OS}" == "Darwin" ]]; then
        RAW_DEVICE="/dev/r${DISK_INPUT}"
        log "Writing ISO to ${RAW_DEVICE} (raw device for speed)"
        sudo dd if="${ISO_FILE}" of="${RAW_DEVICE}" bs=4m status=progress
    else
        log "Writing ISO to ${DEVICE}"
        sudo dd if="${ISO_FILE}" of="${DEVICE}" bs=4M status=progress oflag=sync
    fi
fi

# ── Sync & eject ─────────────────────────────────────────────────────
log "Syncing"
timeout 60 sync 2>/dev/null || log "WARN: final sync timed out — data was already flushed"

if [[ "${WRITABLE}" == "false" && "${OS}" == "Darwin" ]]; then
    log "Ejecting ${DEVICE}"
    diskutil eject "${DEVICE}" 2>/dev/null || true
fi

# ── Read username from config for the final message ──────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
CONF_FILE="${ROOT_DIR}/config/install.conf"
DISPLAY_USER="dev"
DISPLAY_PASS="changeme"
if [[ -f "${CONF_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CONF_FILE}"
    DISPLAY_USER="${INSTALL_USERNAME:-dev}"
    DISPLAY_PASS="${INSTALL_PASSWORD:-changeme}"
fi

echo ""
echo "  ═══════════════════════════════════════════════════════"
echo "  ✓ USB ready — safe to remove."
echo ""
echo "  Plug it into any machine, boot from USB (UEFI), and"
echo "  the install will run automatically."
echo ""
echo "  Credentials: ${DISPLAY_USER} / $(echo "${DISPLAY_PASS}" | sed 's/./*/g')"
if [[ "${WRITABLE}" == "true" ]]; then
    echo ""
    echo "  Mode: WRITABLE (FAT32)"
    echo "  To change config later without re-flashing:"
    echo "    ./build/update-usb.sh"
fi
echo "  ═══════════════════════════════════════════════════════"
