#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# LocalBooth — interactive configuration
#
# Prompts for install parameters and writes them to config/install.conf.
# The build pipeline reads this file and generates the final user-data
# with the correct values (including password hash).
#
# Usage:
#   ./build/configure.sh           # interactive prompts
#   ./build/configure.sh --defaults # skip prompts, use defaults
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
CONF_FILE="${ROOT_DIR}/config/install.conf"

# ── Defaults ──────────────────────────────────────────────────────────
DEF_USERNAME="dev"
DEF_PASSWORD="changeme"
DEF_HOSTNAME="localbooth"
DEF_LOCALE="en_US.UTF-8"
DEF_KEYBOARD="us"
DEF_TIMEZONE="UTC"
DEF_DISK_LAYOUT="lvm"
DEF_SSH="yes"
DEF_PKG_SOURCE="online"
DEF_INTERACTIVE="no"

# ── Load existing config if present ──────────────────────────────────
if [[ -f "${CONF_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CONF_FILE}"
    DEF_USERNAME="${INSTALL_USERNAME:-${DEF_USERNAME}}"
    DEF_PASSWORD="${INSTALL_PASSWORD:-${DEF_PASSWORD}}"
    DEF_HOSTNAME="${INSTALL_HOSTNAME:-${DEF_HOSTNAME}}"
    DEF_LOCALE="${INSTALL_LOCALE:-${DEF_LOCALE}}"
    DEF_KEYBOARD="${INSTALL_KEYBOARD:-${DEF_KEYBOARD}}"
    DEF_TIMEZONE="${INSTALL_TIMEZONE:-${DEF_TIMEZONE}}"
    DEF_DISK_LAYOUT="${INSTALL_DISK_LAYOUT:-${DEF_DISK_LAYOUT}}"
    DEF_SSH="${INSTALL_SSH:-${DEF_SSH}}"
    DEF_PKG_SOURCE="${INSTALL_PKG_SOURCE:-${DEF_PKG_SOURCE}}"
    DEF_INTERACTIVE="${INSTALL_INTERACTIVE:-${DEF_INTERACTIVE}}"
fi

# ── Check for --defaults flag ────────────────────────────────────────
USE_DEFAULTS="false"
if [[ "${1:-}" == "--defaults" ]]; then
    USE_DEFAULTS="true"
fi

# ── Helper: free-text prompt ─────────────────────────────────────────
ask() {
    local prompt="$1"
    local default="$2"
    local varname="$3"

    if [[ "${USE_DEFAULTS}" == "true" ]]; then
        eval "${varname}='${default}'"
        return
    fi

    local input
    read -rp "${prompt} [${default}]: " input
    eval "${varname}='${input:-${default}}'"
}

# ── Helper: hidden password prompt with confirmation ─────────────────
ask_password() {
    local prompt="$1"
    local default="$2"
    local varname="$3"

    if [[ "${USE_DEFAULTS}" == "true" ]]; then
        eval "${varname}='${default}'"
        return
    fi

    echo -n "${prompt} [$(echo "${default}" | sed 's/./*/g')]: "
    local input
    read -rs input
    echo ""

    if [[ -z "${input}" ]]; then
        eval "${varname}='${default}'"
    else
        echo -n "  Confirm password: "
        local confirm
        read -rs confirm
        echo ""
        if [[ "${input}" != "${confirm}" ]]; then
            echo "  ✗ Passwords don't match. Try again."
            ask_password "$@"
            return
        fi
        eval "${varname}='${input}'"
    fi
}

# ── Helper: numbered menu selector ───────────────────────────────────
#   ask_menu "Label" "default_value" "VARNAME" "opt1" "opt2" ...
ask_menu() {
    local label="$1"
    local default="$2"
    local varname="$3"
    shift 3
    local -a options=("$@")

    if [[ "${USE_DEFAULTS}" == "true" ]]; then
        eval "${varname}='${default}'"
        return
    fi

    # Find which option is the default
    local default_idx=1
    for i in "${!options[@]}"; do
        if [[ "${options[$i]}" == "${default}" ]]; then
            default_idx=$((i + 1))
            break
        fi
    done

    echo "  ${label}:"
    for i in "${!options[@]}"; do
        local num=$((i + 1))
        if [[ "${options[$i]}" == "${default}" ]]; then
            printf "    \033[1;32m▸ %d) %s  (default)\033[0m\n" "${num}" "${options[$i]}"
        else
            printf "      %d) %s\n" "${num}" "${options[$i]}"
        fi
    done

    local input
    read -rp "  Choose [${default_idx}]: " input

    if [[ -z "${input}" ]]; then
        eval "${varname}='${default}'"
    elif [[ "${input}" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= ${#options[@]} )); then
        eval "${varname}='${options[$((input - 1))]}'"
    else
        echo "  ✗ Invalid selection. Try again."
        ask_menu "${label}" "${default}" "${varname}" "${options[@]}"
        return
    fi
    echo ""
}

# ── Options ──────────────────────────────────────────────────────────
LOCALES=(
    "en_US.UTF-8"
    "es_ES.UTF-8"
    "es_AR.UTF-8"
    "es_MX.UTF-8"
    "pt_BR.UTF-8"
    "fr_FR.UTF-8"
    "de_DE.UTF-8"
    "it_IT.UTF-8"
    "ja_JP.UTF-8"
    "zh_CN.UTF-8"
    "ko_KR.UTF-8"
    "ru_RU.UTF-8"
)

KEYBOARDS=(
    "us"
    "latam"
    "es"
    "br"
    "uk"
    "fr"
    "de"
    "it"
    "pt"
    "jp"
    "ru"
)

TIMEZONES=(
    "UTC"
    "America/New_York"
    "America/Chicago"
    "America/Denver"
    "America/Los_Angeles"
    "America/Argentina/Buenos_Aires"
    "America/Sao_Paulo"
    "America/Mexico_City"
    "America/Bogota"
    "America/Santiago"
    "America/Lima"
    "Europe/London"
    "Europe/Madrid"
    "Europe/Paris"
    "Europe/Berlin"
    "Europe/Rome"
    "Asia/Tokyo"
    "Asia/Shanghai"
    "Asia/Kolkata"
    "Australia/Sydney"
)

DISK_LAYOUTS=(
    "lvm"
    "direct"
)

SSH_OPTIONS=(
    "yes"
    "no"
)

PKG_SOURCE_OPTIONS=(
    "online"
    "offline"
)

INTERACTIVE_OPTIONS=(
    "no"
    "yes"
)

# ── Interactive prompts ──────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           LocalBooth — Install Configuration               ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Press Enter to accept the default (highlighted in green)."
echo ""

ask          "  Username"  "${DEF_USERNAME}"  "INSTALL_USERNAME"
ask_password "  Password"  "${DEF_PASSWORD}"  "INSTALL_PASSWORD"
ask          "  Hostname"  "${DEF_HOSTNAME}"  "INSTALL_HOSTNAME"
echo ""

ask_menu "Locale"          "${DEF_LOCALE}"      "INSTALL_LOCALE"      "${LOCALES[@]}"
ask_menu "Keyboard layout" "${DEF_KEYBOARD}"    "INSTALL_KEYBOARD"    "${KEYBOARDS[@]}"
ask_menu "Timezone"        "${DEF_TIMEZONE}"    "INSTALL_TIMEZONE"    "${TIMEZONES[@]}"
ask_menu "Disk layout"     "${DEF_DISK_LAYOUT}" "INSTALL_DISK_LAYOUT" "${DISK_LAYOUTS[@]}"
ask_menu "Enable SSH"      "${DEF_SSH}"         "INSTALL_SSH"         "${SSH_OPTIONS[@]}"
ask_menu "Package source (online = needs internet during install, offline = bundled in USB)" \
                          "${DEF_PKG_SOURCE}"  "INSTALL_PKG_SOURCE"  "${PKG_SOURCE_OPTIONS[@]}"
ask_menu "Interactive config at boot (TUI to change settings before install — requires writable USB)" \
                          "${DEF_INTERACTIVE}" "INSTALL_INTERACTIVE" "${INTERACTIVE_OPTIONS[@]}"

# ── Write config file ────────────────────────────────────────────────
cat > "${CONF_FILE}" <<EOF
# LocalBooth install configuration
# Generated by configure.sh on $(date '+%F %T')
# Re-run ./build/configure.sh to change these values.

INSTALL_USERNAME="${INSTALL_USERNAME}"
INSTALL_PASSWORD="${INSTALL_PASSWORD}"
INSTALL_HOSTNAME="${INSTALL_HOSTNAME}"
INSTALL_LOCALE="${INSTALL_LOCALE}"
INSTALL_KEYBOARD="${INSTALL_KEYBOARD}"
INSTALL_TIMEZONE="${INSTALL_TIMEZONE}"
INSTALL_DISK_LAYOUT="${INSTALL_DISK_LAYOUT}"
INSTALL_SSH="${INSTALL_SSH}"
INSTALL_PKG_SOURCE="${INSTALL_PKG_SOURCE}"
INSTALL_INTERACTIVE="${INSTALL_INTERACTIVE}"
EOF

echo "  ┌──────────────────────────────────────────────────┐"
printf "  │  Username:    %-34s │\n" "${INSTALL_USERNAME}"
printf "  │  Password:    %-34s │\n" "$(echo "${INSTALL_PASSWORD}" | sed 's/./*/g')"
printf "  │  Hostname:    %-34s │\n" "${INSTALL_HOSTNAME}"
printf "  │  Locale:      %-34s │\n" "${INSTALL_LOCALE}"
printf "  │  Keyboard:    %-34s │\n" "${INSTALL_KEYBOARD}"
printf "  │  Timezone:    %-34s │\n" "${INSTALL_TIMEZONE}"
printf "  │  Disk layout: %-34s │\n" "${INSTALL_DISK_LAYOUT}"
printf "  │  SSH:         %-34s │\n" "${INSTALL_SSH}"
printf "  │  Packages:    %-34s │\n" "${INSTALL_PKG_SOURCE}"
printf "  │  Interactive: %-34s │\n" "${INSTALL_INTERACTIVE}"
echo "  └──────────────────────────────────────────────────┘"
echo ""
echo "  ✓ Configuration saved to config/install.conf"
echo ""
echo "  Run ./build/make-usb.sh to build the ISO with these settings."
echo ""
