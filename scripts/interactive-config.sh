#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# LocalBooth — interactive TUI for boot-time configuration
#
# Runs during autoinstall early-commands on the target machine.
# Shows a whiptail-based TUI that lets the user change hostname, user,
# password, locale, keyboard, timezone, disk layout and SSH settings.
# After configuration, regenerates user-data on the writable USB and
# reboots so the installer picks up the new values.
#
# Requires a writable USB (FAT32, created with flash-usb.sh --writable).
# ──────────────────────────────────────────────────────────────────────
set -uo pipefail

# Use the TTY we were redirected to (tty2 via chvt in early-commands).
# Fall back to /dev/tty2, then /dev/console.
if [ -t 0 ]; then
    TTY="$(tty)"
elif [ -e /dev/tty2 ]; then
    TTY="/dev/tty2"
else
    TTY="/dev/console"
fi
TITLE="LocalBooth — Install Configuration"
USB_ROOT=""

# ── Locate the writable USB mount (where autoinstall/ lives) ─────────
for candidate in /cdrom /media/cdrom /run/archiso/bootmnt; do
    if [[ -f "${candidate}/autoinstall/user-data" ]]; then
        USB_ROOT="${candidate}"
        break
    fi
done

if [[ -z "${USB_ROOT}" ]]; then
    echo "[localbooth] ERROR: Cannot find USB mount with autoinstall/user-data" >&2
    echo "[localbooth] Interactive config requires a writable USB (--writable)" >&2
    exit 0
fi

USERDATA="${USB_ROOT}/autoinstall/user-data"
USERDATA_ROOT="${USB_ROOT}/user-data"
CONF="${USB_ROOT}/bootstrap/bootstrap.conf"

# ── Load current defaults from bootstrap.conf ────────────────────────
INSTALL_USERNAME="dev"
INSTALL_PASSWORD="changeme"
INSTALL_HOSTNAME="localbooth"
INSTALL_LOCALE="en_US.UTF-8"
INSTALL_KEYBOARD="us"
INSTALL_TIMEZONE="UTC"
INSTALL_DISK_LAYOUT="lvm"
INSTALL_DISK="auto"
INSTALL_SECONDARY_DISK="none"
INSTALL_SSH="yes"
INSTALL_PKG_SOURCE="online"

if [[ -f "${CONF}" ]]; then
    # shellcheck source=/dev/null
    source "${CONF}"
fi

# ── Countdown prompt — skip TUI if no key pressed ────────────────────
show_countdown() {
    local secs=30
    while (( secs > 0 )); do
        printf "\r[localbooth] Press any key in %2d seconds to configure install (or wait to auto-install)..." "${secs}" > "${TTY}"
        if read -rsn1 -t1 <"${TTY}" 2>/dev/null; then
            printf "\n" > "${TTY}"
            return 0
        fi
        secs=$((secs - 1))
    done
    printf "\n[localbooth] No input — proceeding with saved configuration.\n" > "${TTY}"
    return 1
}

if ! show_countdown; then
    exit 0
fi

# ── Whiptail helpers ─────────────────────────────────────────────────
WT="whiptail --title ${TITLE}"
LINES=20
COLS=70

wt_input() {
    local label="$1" default="$2"
    result=$(whiptail --title "${TITLE}" --inputbox "${label}" ${LINES} ${COLS} "${default}" 3>&1 1>&2 2>&3 <"${TTY}" >"${TTY}") || result="${default}"
    echo "${result}"
}

wt_password() {
    local label="$1"
    local pass1 pass2
    while true; do
        pass1=$(whiptail --title "${TITLE}" --passwordbox "${label}" ${LINES} ${COLS} 3>&1 1>&2 2>&3 <"${TTY}" >"${TTY}") || { echo "${INSTALL_PASSWORD}"; return; }
        if [[ -z "${pass1}" ]]; then
            echo "${INSTALL_PASSWORD}"
            return
        fi
        pass2=$(whiptail --title "${TITLE}" --passwordbox "Confirm password:" ${LINES} ${COLS} 3>&1 1>&2 2>&3 <"${TTY}" >"${TTY}") || { echo "${INSTALL_PASSWORD}"; return; }
        if [[ "${pass1}" == "${pass2}" ]]; then
            echo "${pass1}"
            return
        fi
        whiptail --title "${TITLE}" --msgbox "Passwords don't match. Try again." 8 ${COLS} <"${TTY}" >"${TTY}"
    done
}

wt_menu() {
    local label="$1" default="$2"
    shift 2
    local -a items=()
    for opt in "$@"; do
        if [[ "${opt}" == "${default}" ]]; then
            items+=("${opt}" "(current)")
        else
            items+=("${opt}" "")
        fi
    done
    result=$(whiptail --title "${TITLE}" --default-item "${default}" \
        --menu "${label}" ${LINES} ${COLS} 10 "${items[@]}" \
        3>&1 1>&2 2>&3 <"${TTY}" >"${TTY}") || result="${default}"
    echo "${result}"
}

# ── Option lists (same as build/configure.sh) ─────────────────────────
LOCALES=(
    "en_US.UTF-8" "es_ES.UTF-8" "es_AR.UTF-8" "es_MX.UTF-8"
    "pt_BR.UTF-8" "fr_FR.UTF-8" "de_DE.UTF-8" "it_IT.UTF-8"
    "ja_JP.UTF-8" "zh_CN.UTF-8" "ko_KR.UTF-8" "ru_RU.UTF-8"
)

KEYBOARDS=(
    "us" "latam" "es" "br" "uk" "fr" "de" "it" "pt" "jp" "ru"
)

TIMEZONES=(
    "UTC"
    "America/New_York" "America/Chicago" "America/Denver"
    "America/Los_Angeles" "America/Argentina/Buenos_Aires"
    "America/Sao_Paulo" "America/Mexico_City" "America/Bogota"
    "America/Santiago" "America/Lima"
    "Europe/London" "Europe/Madrid" "Europe/Paris" "Europe/Berlin"
    "Europe/Rome"
    "Asia/Tokyo" "Asia/Shanghai" "Asia/Kolkata"
    "Australia/Sydney"
)

DISK_LAYOUTS=("lvm" "direct")
SSH_OPTIONS=("yes" "no")

# Build disk target list: abstract criteria + detected devices
build_disk_targets() {
    local -a targets=("auto" "largest" "smallest" "ssd" "hdd")
    for dev in /sys/block/sd* /sys/block/nvme* /sys/block/vd*; do
        [ -d "${dev}" ] || continue
        local name
        name=$(basename "${dev}")
        local removable
        removable=$(cat "${dev}/removable" 2>/dev/null || echo 1)
        [ "${removable}" = "1" ] && continue
        local size_sectors
        size_sectors=$(cat "${dev}/size" 2>/dev/null || echo 0)
        (( size_sectors < 2097152 )) && continue
        local size_gb=$(( size_sectors / 2097152 ))
        local rotational
        rotational=$(cat "${dev}/queue/rotational" 2>/dev/null || echo "?")
        local dtype="SSD"
        [ "${rotational}" = "1" ] && dtype="HDD"
        targets+=("/dev/${name}(${size_gb}GB,${dtype})")
    done
    echo "${targets[@]}"
}

SECONDARY_DISK_OPTIONS=("none" "format")

# ── Run the TUI ──────────────────────────────────────────────────────
INSTALL_USERNAME=$(wt_input  "Username:" "${INSTALL_USERNAME}")
INSTALL_PASSWORD=$(wt_password "Password (leave empty to keep current):")
INSTALL_HOSTNAME=$(wt_input  "Hostname:" "${INSTALL_HOSTNAME}")
INSTALL_LOCALE=$(wt_menu    "Locale:"          "${INSTALL_LOCALE}"      "${LOCALES[@]}")
INSTALL_KEYBOARD=$(wt_menu  "Keyboard layout:" "${INSTALL_KEYBOARD}"    "${KEYBOARDS[@]}")
INSTALL_TIMEZONE=$(wt_menu  "Timezone:"        "${INSTALL_TIMEZONE}"    "${TIMEZONES[@]}")
INSTALL_DISK_LAYOUT=$(wt_menu "Disk layout:"   "${INSTALL_DISK_LAYOUT}" "${DISK_LAYOUTS[@]}")

# Discover available disks at runtime
read -ra DISK_TARGETS <<< "$(build_disk_targets)"
INSTALL_DISK=$(wt_menu "Install disk:" "${INSTALL_DISK}" "${DISK_TARGETS[@]}")
INSTALL_SECONDARY_DISK=$(wt_menu "Secondary disk (format = wipe & mount /data):" "${INSTALL_SECONDARY_DISK}" "${SECONDARY_DISK_OPTIONS[@]}")

INSTALL_SSH=$(wt_menu       "Enable SSH:"      "${INSTALL_SSH}"         "${SSH_OPTIONS[@]}")

# ── Generate password hash ───────────────────────────────────────────
PASSWORD_HASH=$(openssl passwd -6 "${INSTALL_PASSWORD}")

SSH_INSTALL="true"
SSH_ALLOW_PW="true"
if [[ "${INSTALL_SSH}" == "no" ]]; then
    SSH_INSTALL="false"
    SSH_ALLOW_PW="false"
fi

# ── Read package list ────────────────────────────────────────────────
PKG_LIST="${USB_ROOT}/config/package-list.txt"
PACKAGES_SPACE=""
if [[ -f "${PKG_LIST}" ]]; then
    while IFS= read -r line; do
        line=$(echo "${line}" | sed 's/#.*//' | xargs)
        [[ -z "${line}" ]] && continue
        PACKAGES_SPACE="${PACKAGES_SPACE} ${line}"
    done < "${PKG_LIST}"
fi
PACKAGES_SPACE=$(echo "${PACKAGES_SPACE}" | xargs)

# ── Helper: append secondary disk formatting late-command ─────────────
append_secondary_disk_cmd() {
    local outfile="$1"
    if [[ "${INSTALL_SECONDARY_DISK}" == "format" ]]; then
        cat >> "${outfile}" <<'SECONDARYEOF'
    - |
      # Format secondary disk and mount as /data
      BOOT_DISK=$(findmnt -n -o SOURCE /target | sed 's/[0-9]*$//' | sed 's/p$//')
      BOOT_DISK=$(basename "${BOOT_DISK}")
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
        echo "[localbooth] Formatting secondary disk ${SECOND} as ext4"
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
          echo "[localbooth] Secondary disk mounted at /data (UUID=${PART_UUID})"
        fi
      else
        echo "[localbooth] No secondary disk found — skipping"
      fi
SECONDARYEOF
    fi
}

# ── Write user-data ──────────────────────────────────────────────────
write_userdata() {
    local outfile="$1"

    cat > "${outfile}" <<USERDATA
#cloud-config
autoinstall:
  version: 1

  locale: ${INSTALL_LOCALE}
  keyboard:
    layout: ${INSTALL_KEYBOARD}
  timezone: ${INSTALL_TIMEZONE}

USERDATA

    if [[ "${INSTALL_PKG_SOURCE}" == "offline" ]]; then
        cat >> "${outfile}" <<USERDATA
  network:
    version: 2
    ethernets: {}

USERDATA
    else
        cat >> "${outfile}" <<USERDATA
  network:
    version: 2
    ethernets:
      any-ethernet:
        match:
          name: "e*"
        dhcp4: true

USERDATA
    fi

    # Strip size/type annotations from TUI device paths, e.g. /dev/sda(500GB,HDD) -> /dev/sda
    local disk_val="${INSTALL_DISK}"
    disk_val="${disk_val%%(*}"

    local _match=""
    case "${disk_val}" in
        auto|ssd)  _match="ssd: true" ;;
        hdd)       _match="ssd: false" ;;
        largest)   _match="size: largest" ;;
        smallest)  _match="size: smallest" ;;
        /dev/*)    _match="path: ${disk_val}" ;;
    esac

    cat >> "${outfile}" <<USERDATA
  storage:
    layout:
      name: ${INSTALL_DISK_LAYOUT}
      reset-partition: true
      match:
        ${_match}

USERDATA

    cat >> "${outfile}" <<USERDATA
  identity:
    hostname: ${INSTALL_HOSTNAME}
    username: ${INSTALL_USERNAME}
    password: "${PASSWORD_HASH}"

  ssh:
    install-server: ${SSH_INSTALL}
    allow-pw: ${SSH_ALLOW_PW}

USERDATA

    if [[ "${INSTALL_PKG_SOURCE}" == "online" ]]; then
        cat >> "${outfile}" <<USERDATA
  late-commands:
    # Wait for network
    - |
      echo '[localbooth] Waiting for network...'
      for i in \$(seq 1 60); do
        if ip route | grep -q default; then
          echo "[localbooth] Network ready (attempt \$i)"
          break
        fi
        for iface in \$(ls /sys/class/net/ | grep -E '^(en|eth)'); do
          ip link set "\$iface" up 2>/dev/null || true
          dhclient "\$iface" 2>/dev/null || true
        done
        sleep 2
      done
      if ! ip route | grep -q default; then
        echo '[localbooth] WARNING: No network after 120s'
      fi
    - curtin in-target --target=/target -- apt-get update
    - curtin in-target --target=/target -- apt-get install -y ${PACKAGES_SPACE}
    - curtin in-target --target=/target -- usermod -aG docker ${INSTALL_USERNAME} || true
    - cp /cdrom/bootstrap/bootstrap.sh /target/tmp/bootstrap.sh
    - cp /cdrom/bootstrap/bootstrap.conf /target/tmp/bootstrap.conf || true
    - chmod +x /target/tmp/bootstrap.sh
    - curtin in-target --target=/target -- /tmp/bootstrap.sh
USERDATA
        append_secondary_disk_cmd "${outfile}"
        cat >> "${outfile}" <<USERDATA

  shutdown: reboot
USERDATA
    else
        cat >> "${outfile}" <<USERDATA
  updates: security
  package_update: false
  package_upgrade: false

  late-commands:
    - mv /target/etc/apt/sources.list.d/ubuntu.sources /target/etc/apt/sources.list.d/ubuntu.sources.bak || true
    - echo 'deb [trusted=yes] file:///mnt/repo ./' > /target/etc/apt/sources.list
    - mkdir -p /target/mnt/repo
    - mount --bind /cdrom/repo /target/mnt/repo
    - curtin in-target --target=/target -- apt-get update
    - curtin in-target --target=/target -- apt-get install -y --no-install-recommends ${PACKAGES_SPACE}
    - umount /target/mnt/repo
    - rm -f /target/etc/apt/sources.list
    - mv /target/etc/apt/sources.list.d/ubuntu.sources.bak /target/etc/apt/sources.list.d/ubuntu.sources || true
    - curtin in-target --target=/target -- usermod -aG docker ${INSTALL_USERNAME} || true
    - cp /cdrom/bootstrap/bootstrap.sh /target/tmp/bootstrap.sh
    - cp /cdrom/bootstrap/bootstrap.conf /target/tmp/bootstrap.conf || true
    - chmod +x /target/tmp/bootstrap.sh
    - curtin in-target --target=/target -- /tmp/bootstrap.sh
USERDATA
        append_secondary_disk_cmd "${outfile}"
        cat >> "${outfile}" <<USERDATA

  shutdown: reboot
USERDATA
    fi
}

# ── Write files to USB ───────────────────────────────────────────────
echo "[localbooth] Writing new configuration to USB..." > "${TTY}"

# Ensure USB is mounted read-write (Ubuntu mounts /cdrom read-only by default)
mount -o remount,rw "${USB_ROOT}" 2>/dev/null || true

if ! touch "${USERDATA}" 2>/dev/null; then
    whiptail --title "${TITLE}" --msgbox \
        "ERROR: USB is not writable.\n\nThe USB was not created with --writable.\nContinuing with saved configuration." \
        10 60 <"${TTY}" >"${TTY}"
    exit 0
fi

write_userdata "${USERDATA}"
cp "${USERDATA}" "${USERDATA_ROOT}" 2>/dev/null || true

# Update bootstrap.conf
cat > "${CONF}" <<EOF
INSTALL_USERNAME="${INSTALL_USERNAME}"
INSTALL_PASSWORD="${INSTALL_PASSWORD}"
INSTALL_HOSTNAME="${INSTALL_HOSTNAME}"
INSTALL_LOCALE="${INSTALL_LOCALE}"
INSTALL_KEYBOARD="${INSTALL_KEYBOARD}"
INSTALL_TIMEZONE="${INSTALL_TIMEZONE}"
INSTALL_DISK_LAYOUT="${INSTALL_DISK_LAYOUT}"
INSTALL_DISK="${INSTALL_DISK}"
INSTALL_SECONDARY_DISK="${INSTALL_SECONDARY_DISK}"
INSTALL_SSH="${INSTALL_SSH}"
INSTALL_PKG_SOURCE="${INSTALL_PKG_SOURCE}"
EOF

sync

# ── Show summary and reboot ──────────────────────────────────────────
whiptail --title "${TITLE}" --msgbox "\
Configuration saved. The system will now reboot \
and the install will start automatically with:\n\n\
  User:     ${INSTALL_USERNAME}\n\
  Hostname: ${INSTALL_HOSTNAME}\n\
  Locale:   ${INSTALL_LOCALE}\n\
  Keyboard: ${INSTALL_KEYBOARD}\n\
  Timezone: ${INSTALL_TIMEZONE}\n\
  Disk:     ${INSTALL_DISK_LAYOUT}\n\
  Target:   ${INSTALL_DISK}\n\
  2nd disk: ${INSTALL_SECONDARY_DISK}\n\
  SSH:      ${INSTALL_SSH}\n\
  Packages: ${INSTALL_PKG_SOURCE}" \
    20 ${COLS} <"${TTY}" >"${TTY}"

echo "[localbooth] Rebooting to start install with new configuration..." > "${TTY}"
sleep 2
reboot -f
