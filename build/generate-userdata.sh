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
INSTALL_DISK="auto"
INSTALL_SECONDARY_DISK="none"
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

# Build storage section based on disk target
_storage_match=""
case "${INSTALL_DISK}" in
    auto|ssd)  _storage_match="ssd: true" ;;
    hdd)       _storage_match="ssd: false" ;;
    largest)   _storage_match="size: largest" ;;
    smallest)  _storage_match="size: smallest" ;;
    /dev/*)    _storage_match="path: ${INSTALL_DISK}" ;;
esac

cat >> "${OUTPUT}" <<USERDATA
  storage:
    layout:
      name: ${INSTALL_DISK_LAYOUT}
      reset-partition: true
      match:
        ${_storage_match}

USERDATA

cat >> "${OUTPUT}" <<USERDATA
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
      # Ensure USB is writable for logging
      mount -o remount,rw /cdrom 2>/dev/null || true
      # Fallback: if /cdrom is the ISO, try the actual USB device
      if ! touch /cdrom/.lb_write_test 2>/dev/null; then
        for mp in /media/cdrom /run/archiso/bootmnt; do
          if [ -d "$mp/autoinstall" ]; then
            mount -o remount,rw "$mp" 2>/dev/null || true
            if touch "$mp/.lb_write_test" 2>/dev/null; then
              rm -f "$mp/.lb_write_test"
              mount --bind "$mp/logs" /cdrom/logs 2>/dev/null || true
              break
            fi
          fi
        done
      else
        rm -f /cdrom/.lb_write_test
      fi
      LB_LOG=/cdrom/logs/install.log
      mkdir -p /cdrom/logs 2>/dev/null || true
      {
        echo "=========================================="
        echo "[localbooth] Install started: $(date)"
        echo "=========================================="
        echo "Kernel: $(uname -r)"
        echo "Boot cmdline: $(cat /proc/cmdline)"
        echo ""
        echo "--- Block devices ---"
        lsblk -o NAME,SIZE,TYPE,FSTYPE,MODEL 2>/dev/null || true
        echo ""
        echo "--- user-data being used ---"
        cat /cdrom/autoinstall/user-data 2>/dev/null || true
        echo ""
      } > "$LB_LOG" 2>&1 || true
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

# ── Helper: append secondary disk formatting late-command ─────────────
append_secondary_disk_cmd() {
    if [[ "${INSTALL_SECONDARY_DISK}" == "format" ]]; then
        log "Adding secondary disk formatting late-command"
        cat >> "${OUTPUT}" <<'SECONDARYEOF'
    - |
      lb_log() { echo "[localbooth] $*"; echo "[localbooth] $*" >> /cdrom/logs/install.log 2>/dev/null || true; }
      # Format secondary disk and mount as /data
      ROOT_SRC=$(findmnt -n -o SOURCE /target 2>/dev/null)
      BOOT_DISK=$(lsblk -nso NAME,TYPE "$ROOT_SRC" 2>/dev/null | awk '$2=="disk"{print $1}' | head -1)
      if [ -z "$BOOT_DISK" ]; then
        BOOT_DISK=$(echo "$ROOT_SRC" | sed 's|/dev/||' | sed 's/[0-9]*$//' | sed 's/p$//')
      fi
      lb_log "Boot disk detected: ${BOOT_DISK} (from ${ROOT_SRC})"
      SECOND=""
      for dev in /sys/block/sd* /sys/block/nvme* /sys/block/vd*; do
        [ -d "${dev}" ] || continue
        name=$(basename "${dev}")
        [ "${name}" = "${BOOT_DISK}" ] && continue
        removable=$(cat "${dev}/removable" 2>/dev/null || echo 1)
        [ "${removable}" = "1" ] && continue
        SECOND="/dev/${name}"
        break
      done
      if [ -n "${SECOND}" ]; then
        lb_log "Formatting secondary disk ${SECOND} as ext4"
        wipefs -af "${SECOND}" || true
        parted -s "${SECOND}" mklabel gpt mkpart primary ext4 0% 100% || true
        sleep 1
        PART="${SECOND}1"
        [ -b "${SECOND}p1" ] && PART="${SECOND}p1"
        mkfs.ext4 -F -L data "${PART}" || true
        PART_UUID=$(blkid -s UUID -o value "${PART}" || true)
        if [ -n "${PART_UUID}" ]; then
          mkdir -p /target/data
          echo "UUID=${PART_UUID} /data ext4 defaults,nofail 0 2" >> /target/etc/fstab
          mount "${PART}" /target/data || true
          chown 1000:1000 /target/data || true
          lb_log "Secondary disk mounted at /data (UUID=${PART_UUID})"
        else
          lb_log "WARNING: Could not get UUID for ${PART}"
        fi
      else
        lb_log "No secondary disk found — skipping"
      fi
SECONDARYEOF
    fi
}

if [[ "${INSTALL_PKG_SOURCE}" == "online" ]]; then
    log "Mode: ONLINE — packages will be downloaded during install"
    cat >> "${OUTPUT}" <<USERDATA
  late-commands:
    - |
      lb_log() { echo "[localbooth] \$*"; echo "[localbooth] \$*" >> /cdrom/logs/install.log 2>/dev/null || true; }
      lb_log "=== late-commands start ==="
      lb_log "/target mounted from: \$(findmnt -n -o SOURCE /target 2>/dev/null || echo unknown)"
      lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT >> /cdrom/logs/install.log 2>/dev/null || true
      lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null || true
      lb_log "Waiting for network (up to 180s)..."
      for i in \$(seq 1 90); do
        if ip route | grep -q default; then
          lb_log "Network ready (attempt \$i)"
          break
        fi
        for iface in \$(ls /sys/class/net/ | grep -E '^(en|eth)'); do
          ip link set "\$iface" up 2>/dev/null || true
        done
        # Try dhclient only every 5 attempts to avoid spamming
        if [ \$((i % 5)) -eq 0 ]; then
          for iface in \$(ls /sys/class/net/ | grep -E '^(en|eth)'); do
            dhclient "\$iface" 2>/dev/null || true
          done
        fi
        sleep 2
      done
      if ! ip route | grep -q default; then
        lb_log "WARNING: No network after 180s — package install may fail"
      fi
    - curtin in-target --target=/target -- apt-get update || true
    - curtin in-target --target=/target -- apt-get install -y ${PACKAGES_SPACE} || true
    - cp /cdrom/bootstrap/bootstrap.sh /target/tmp/bootstrap.sh
    - cp /cdrom/bootstrap/bootstrap.conf /target/tmp/bootstrap.conf || true
    - chmod +x /target/tmp/bootstrap.sh
    - curtin in-target --target=/target -- /tmp/bootstrap.sh || true
    - chown -R 1000:1000 /target/home/${INSTALL_USERNAME} || true
USERDATA
    append_secondary_disk_cmd
    cat >> "${OUTPUT}" <<'USERDATA'
    - |
      lb_log() { echo "[localbooth] $*"; echo "[localbooth] $*" >> /cdrom/logs/install.log 2>/dev/null || true; }
      lb_log "Install finished: $(date)"
      lb_log "--- Copying installer logs to USB ---"
      mkdir -p /cdrom/logs/installer 2>/dev/null || true
      cp -r /var/log/installer/* /cdrom/logs/installer/ 2>/dev/null || true
      cp /target/var/log/cloud-init*.log /cdrom/logs/ 2>/dev/null || true
      lb_log "--- Final disk state ---"
      lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT >> /cdrom/logs/install.log 2>/dev/null || true
      lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null || true
      lb_log "=========================================="
      sync

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
    - curtin in-target --target=/target -- apt-get update || true
    - curtin in-target --target=/target -- apt-get install -y --no-install-recommends ${PACKAGES_SPACE} || true
    - umount /target/mnt/repo
    - rm -f /target/etc/apt/sources.list
    - mv /target/etc/apt/sources.list.d/ubuntu.sources.bak /target/etc/apt/sources.list.d/ubuntu.sources || true
    - cp /cdrom/bootstrap/bootstrap.sh /target/tmp/bootstrap.sh
    - cp /cdrom/bootstrap/bootstrap.conf /target/tmp/bootstrap.conf || true
    - chmod +x /target/tmp/bootstrap.sh
    - curtin in-target --target=/target -- /tmp/bootstrap.sh || true
    - chown -R 1000:1000 /target/home/${INSTALL_USERNAME} || true
USERDATA
    append_secondary_disk_cmd
    cat >> "${OUTPUT}" <<'USERDATA'
    - |
      lb_log() { echo "[localbooth] $*"; echo "[localbooth] $*" >> /cdrom/logs/install.log 2>/dev/null || true; }
      lb_log "Install finished: $(date)"
      lb_log "--- Copying installer logs to USB ---"
      mkdir -p /cdrom/logs/installer 2>/dev/null || true
      cp -r /var/log/installer/* /cdrom/logs/installer/ 2>/dev/null || true
      cp /target/var/log/cloud-init*.log /cdrom/logs/ 2>/dev/null || true
      lb_log "--- Final disk state ---"
      lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT >> /cdrom/logs/install.log 2>/dev/null || true
      lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null || true
      lb_log "=========================================="
      sync

  shutdown: reboot
USERDATA
fi

log "user-data generated at ${OUTPUT}"
