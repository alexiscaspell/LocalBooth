#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# LocalBooth — build a local APT repository from downloaded .deb files
#
# Creates a Packages.gz / Release structure that APT can consume with:
#   deb [trusted=yes] file:///cdrom/repo ./
#
# Prerequisites: dpkg-dev (provides dpkg-scanpackages)
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
DEB_DIR="${ROOT_DIR}/packages/debs"
REPO_DIR="${SCRIPT_DIR}/local-repo"

log() { echo "[localbooth] $(date '+%F %T') — $*"; }
SUDO="sudo"; [[ "$(id -u)" -eq 0 ]] && SUDO=""

# ── Validate ───────────────────────────────────────────────────────────
if [[ ! -d "${DEB_DIR}" ]]; then
    echo "ERROR: ${DEB_DIR} does not exist. Run packages/download-packages.sh first." >&2
    exit 1
fi

DEB_COUNT=$(find "${DEB_DIR}" -maxdepth 1 -name '*.deb' | wc -l)
if [[ "${DEB_COUNT}" -eq 0 ]]; then
    echo "ERROR: no .deb files found in ${DEB_DIR}" >&2
    exit 1
fi

# ── Ensure dpkg-dev is installed ──────────────────────────────────────
if ! command -v dpkg-scanpackages &>/dev/null; then
    log "Installing dpkg-dev (provides dpkg-scanpackages)"
    $SUDO apt-get install -y dpkg-dev
fi

# ── Build the repo ────────────────────────────────────────────────────
log "Creating local APT repository at ${REPO_DIR}"
rm -rf "${REPO_DIR}"
mkdir -p "${REPO_DIR}"

# Copy all .deb files into the repo root
cp "${DEB_DIR}"/*.deb "${REPO_DIR}/"

cd "${REPO_DIR}"

# Generate Packages index
log "Generating Packages index"
dpkg-scanpackages . /dev/null > Packages
gzip -k Packages              # keeps uncompressed copy too

# Generate Release file
log "Generating Release file"
cat > Release <<EOF
Archive: stable
Component: main
Origin: LocalBooth
Label: LocalBooth Offline Repo
Architecture: amd64
Date: $(date -Ru)
EOF

apt-ftparchive release . >> Release 2>/dev/null || true

log "Local repository ready (${DEB_COUNT} packages in ${REPO_DIR})"
