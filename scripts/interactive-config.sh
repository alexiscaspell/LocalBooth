#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# LocalBooth — interactive TUI for boot-time configuration
#
# Launched by the "Configure Installation" GRUB entry (lb.configure).
# Shows a whiptail-based TUI that lets the user change hostname, user,
# password, locale, keyboard, timezone, disk layout and SSH settings.
# After configuration, regenerates user-data on the writable USB,
# creates a .configured flag, and reboots so the installer picks up
# the new values via the "Install" GRUB entry.
#
# Requires a writable USB (FAT32, created with make-usb.sh --writable --gui).
# ──────────────────────────────────────────────────────────────────────
set -uo pipefail

# ── TTY detection ─────────────────────────────────────────────────────
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
    exit 0
fi

USERDATA="${USB_ROOT}/autoinstall/user-data"
USERDATA_ROOT="${USB_ROOT}/user-data"
CONF="${USB_ROOT}/bootstrap/bootstrap.conf"
CONFIGURED_FLAG="${USB_ROOT}/autoinstall/.configured"

# ── Load current defaults from bootstrap.conf ────────────────────────
INSTALL_USERNAME="dev"
INSTALL_PASSWORD="changeme"
INSTALL_HOSTNAME="localbooth"
INSTALL_LOCALE="en_US.UTF-8"
INSTALL_KEYBOARD="us"
INSTALL_TIMEZONE="UTC"
INSTALL_DISK_LAYOUT="lvm"
INSTALL_SSH="yes"
INSTALL_PKG_SOURCE="online"

if [[ -f "${CONF}" ]]; then
    # shellcheck source=/dev/null
    source "${CONF}"
fi

# ── Ensure USB is writable ───────────────────────────────────────────
mount -o remount,rw "${USB_ROOT}" 2>/dev/null || true

if ! touch "${USERDATA}" 2>/dev/null; then
    whiptail --title "${TITLE}" --msgbox \
        "ERROR: USB is not writable.\n\nThe USB was not created with --writable.\nRebooting..." \
        10 60 <"${TTY}" >"${TTY}"
    reboot -f
fi

# ── Welcome screen ───────────────────────────────────────────────────
whiptail --title "${TITLE}" --yesno \
    "Welcome to LocalBooth.\n\nConfigure the installation parameters before proceeding.\nPress <Yes> to configure, or <No> to install with current values." \
    12 65 <"${TTY}" >"${TTY}"

if [[ $? -ne 0 ]]; then
    # User chose "No" — skip configuration, mark as configured, reboot to install
    touch "${CONFIGURED_FLAG}" 2>/dev/null || true
    sync
    reboot -f
fi

# ── Whiptail helpers ─────────────────────────────────────────────────
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

# ── Run the TUI ──────────────────────────────────────────────────────
INSTALL_USERNAME=$(wt_input  "Username:" "${INSTALL_USERNAME}")
INSTALL_PASSWORD=$(wt_password "Password (leave empty to keep current):")
INSTALL_HOSTNAME=$(wt_input  "Hostname:" "${INSTALL_HOSTNAME}")
INSTALL_LOCALE=$(wt_menu    "Locale:"          "${INSTALL_LOCALE}"      "${LOCALES[@]}")
INSTALL_KEYBOARD=$(wt_menu  "Keyboard layout:" "${INSTALL_KEYBOARD}"    "${KEYBOARDS[@]}")
INSTALL_TIMEZONE=$(wt_menu  "Timezone:"        "${INSTALL_TIMEZONE}"    "${TIMEZONES[@]}")
INSTALL_DISK_LAYOUT=$(wt_menu "Disk layout:"   "${INSTALL_DISK_LAYOUT}" "${DISK_LAYOUTS[@]}")
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

    cat >> "${outfile}" <<USERDATA
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

  early-commands:
    - |
      # Fix missing symlinks on FAT32 writable USB (bind-mount approach)
      if [ ! -e /cdrom/ubuntu ] && [ -d /cdrom/dists ]; then
        mkdir -p /cdrom/ubuntu 2>/dev/null || true
        mount --bind /cdrom /cdrom/ubuntu 2>/dev/null || true
      fi
      CODENAME=""
      for d in /cdrom/dists/*/; do
        name=\$(basename "\$d")
        case "\$name" in stable|unstable) continue ;; esac
        CODENAME="\$name"
        break
      done
      if [ -n "\$CODENAME" ]; then
        if [ ! -e /cdrom/dists/stable ]; then
          mkdir -p /cdrom/dists/stable 2>/dev/null || true
          mount --bind "/cdrom/dists/\$CODENAME" /cdrom/dists/stable 2>/dev/null || true
        fi
        if [ ! -e /cdrom/dists/unstable ]; then
          mkdir -p /cdrom/dists/unstable 2>/dev/null || true
          mount --bind "/cdrom/dists/\$CODENAME" /cdrom/dists/unstable 2>/dev/null || true
        fi
      fi
    - |
      # Run TUI only when the "Configure" GRUB entry was selected
      if grep -q lb.configure /proc/cmdline; then
        mount -o remount,rw /cdrom 2>/dev/null || true
        if command -v openvt >/dev/null 2>&1; then
          openvt -s -w -- bash /cdrom/scripts/interactive-config.sh
        elif command -v chvt >/dev/null 2>&1; then
          chvt 2
          bash /cdrom/scripts/interactive-config.sh </dev/tty2 >/dev/tty2 2>&1
          chvt 1
        else
          bash /cdrom/scripts/interactive-config.sh </dev/tty1 >/dev/tty1 2>&1
        fi
      fi

USERDATA

    if [[ "${INSTALL_PKG_SOURCE}" == "online" ]]; then
        cat >> "${outfile}" <<USERDATA
  late-commands:
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

  shutdown: reboot
USERDATA
    fi
}

# ── Write files to USB ───────────────────────────────────────────────
echo "[localbooth] Writing new configuration to USB..." > "${TTY}"

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
INSTALL_SSH="${INSTALL_SSH}"
INSTALL_PKG_SOURCE="${INSTALL_PKG_SOURCE}"
EOF

# Mark as configured so GRUB defaults to "Install" on next boot
touch "${CONFIGURED_FLAG}" 2>/dev/null || true

sync

# ── Show summary and reboot ──────────────────────────────────────────
whiptail --title "${TITLE}" --msgbox "\
Configuration saved!\n\n\
The system will reboot and start the installation with:\n\n\
  User:     ${INSTALL_USERNAME}\n\
  Hostname: ${INSTALL_HOSTNAME}\n\
  Locale:   ${INSTALL_LOCALE}\n\
  Keyboard: ${INSTALL_KEYBOARD}\n\
  Timezone: ${INSTALL_TIMEZONE}\n\
  Disk:     ${INSTALL_DISK_LAYOUT}\n\
  SSH:      ${INSTALL_SSH}\n\
  Packages: ${INSTALL_PKG_SOURCE}" \
    20 ${COLS} <"${TTY}" >"${TTY}"

echo "[localbooth] Rebooting to start install with new configuration..." > "${TTY}"
sleep 2
reboot -f
