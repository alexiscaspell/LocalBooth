#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# LocalBooth — download .deb packages and all dependencies
#
# Run this on an internet-connected Ubuntu machine whose release matches
# the target (e.g. 24.04 Noble).  The packages are saved to
# packages/debs/ so they can later be turned into a local APT repo.
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
PACKAGE_LIST="${ROOT_DIR}/config/package-list.txt"
DEB_DIR="${SCRIPT_DIR}/debs"

log() { echo "[localbooth] $(date '+%F %T') — $*"; }
SUDO="sudo"; [[ "$(id -u)" -eq 0 ]] && SUDO=""

# ── Validate ───────────────────────────────────────────────────────────
if [[ ! -f "${PACKAGE_LIST}" ]]; then
    echo "ERROR: package list not found at ${PACKAGE_LIST}" >&2
    exit 1
fi

# ── Read packages (strip comments and blanks) ─────────────────────────
mapfile -t PACKAGES < <(grep -v '^\s*#' "${PACKAGE_LIST}" | grep -v '^\s*$')

if [[ ${#PACKAGES[@]} -eq 0 ]]; then
    echo "ERROR: no packages found in ${PACKAGE_LIST}" >&2
    exit 1
fi

log "Packages to download: ${PACKAGES[*]}"

# ── Prepare output directory ──────────────────────────────────────────
mkdir -p "${DEB_DIR}"

# ── Update local apt cache (needed for dependency resolution) ─────────
log "Updating APT cache"
$SUDO apt-get update -qq

# ── Download packages + full dependency tree ──────────────────────────
# apt-get download only fetches the named packages.  We use
# apt-rdepends to resolve the full transitive closure, then download
# every .deb that isn't virtual.
log "Resolving dependencies"

DEP_LIST=$(apt-rdepends "${PACKAGES[@]}" 2>/dev/null \
    | grep -v '^ ' \
    | sort -u)

log "Total packages (including dependencies): $(echo "${DEP_LIST}" | wc -l)"

log "Downloading .deb files into ${DEB_DIR}"
cd "${DEB_DIR}"

echo "${DEP_LIST}" | while IFS= read -r pkg; do
    [[ -z "${pkg}" ]] && continue
    # Skip virtual / unavailable packages gracefully
    apt-get download "${pkg}" 2>/dev/null || \
        log "WARN: could not download '${pkg}' (virtual or unavailable) — skipping"
done

DEB_COUNT=$(find "${DEB_DIR}" -maxdepth 1 -name '*.deb' | wc -l)
log "Downloaded ${DEB_COUNT} .deb file(s) into ${DEB_DIR}"
