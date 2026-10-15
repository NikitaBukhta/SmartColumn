#!/bin/bash

set -euo pipefail

# Optional: the script also works downloaded without the repository.
BUILD_ENV_FILE="$(dirname -- "${BASH_SOURCE[0]}")/../../build-config/build.env"
# shellcheck source=../../build-config/build.env
[ ! -f "${BUILD_ENV_FILE}" ] || . "${BUILD_ENV_FILE}"

ARTIFACTS_REPO="${ARTIFACTS_REPO:-NikitaBukhta/SmartColumn}"
ARTIFACTS_RELEASE="${ARTIFACTS_RELEASE:-v0.0.3}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-${PWD}/artifacts}"
SDK_DIR="${SDK_DIR:-${ARTIFACTS_DIR}/sdk}"
SDK_INSTALL_ROOT="${SDK_INSTALL_ROOT:-/opt/smart-column-sdk}"

# qemu-rpi4-64 shares the board's CPU tuning, so the board's SDK serves both.
readonly SDK_ASSET="sdk-raspberrypi4-64-*.tar.gz"
readonly SDK_DEST="${SDK_INSTALL_ROOT}/rpi4-64"
readonly QEMU_MACHINE="qemu-rpi4-64"
readonly BOARD_MACHINE="rpi4-64"

TMP_DIR=""
RELEASE_JSON=""
LOCAL=0

function log() {
    echo "==> $*"
}

function die() {
    echo "ERROR: $*" >&2
    exit 1
}

function usage() {
    cat <<EOF
Usage: $(basename -- "$0") [--sdk] [--qemu] [--image] [--local]

Installs artifacts of ${ARTIFACTS_REPO} ${ARTIFACTS_RELEASE}, all of them by default.

    --sdk       the SDK, to ${SDK_DEST}
    --qemu      the QEMU image, to ${ARTIFACTS_DIR}/${QEMU_MACHINE}
    --image     the Raspberry Pi 4 image, to ${ARTIFACTS_DIR}/${BOARD_MACHINE}
    --local     instead of the release, take what get_artifacts.sh left:
                the SDK from ${SDK_DIR},
                the images are only verified where they already are
    -h, --help  show this help

The repository and release come from ARTIFACTS_REPO and ARTIFACTS_RELEASE.
EOF
}

function gh_logged_in() {
    command -v gh >/dev/null && gh auth status >/dev/null 2>&1
}

# A GET of the GitHub REST API: through a logged-in GitHub CLI, with
# GITHUB_TOKEN, or anonymously. Credentials only raise the rate limit.
function github_get() {
    local path="$1" accept="$2"
    local auth=()

    if gh_logged_in; then
        gh api -H "Accept: ${accept}" "${path}"
    else
        [ -z "${GITHUB_TOKEN:-}" ] || auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
        curl -fsSL --retry 3 \
            "${auth[@]}" \
            -H "Accept: ${accept}" \
            "https://api.github.com/${path}"
    fi
}

function github_release_json() {
    github_get "repos/${ARTIFACTS_REPO}/releases/tags/${ARTIFACTS_RELEASE}" "application/vnd.github+json"
}

function github_download_asset() {
    local id="$1" file="$2"
    github_get "repos/${ARTIFACTS_REPO}/releases/assets/${id}" "application/octet-stream" >"${file}"
}

# "<id> <name>" of each release asset matching a glob.
function assets_matching() {
    python3 -c '
import fnmatch, json, sys
for asset in json.load(sys.stdin)["assets"]:
    if fnmatch.fnmatch(asset["name"], sys.argv[1]):
        print(asset["id"], asset["name"])' "$1" <<<"${RELEASE_JSON}"
}

function download_asset() {
    local pattern="$1" file="$2"
    local matches=() id name

    mapfile -t matches < <(assets_matching "${pattern}")
    [ "${#matches[@]}" -eq 1 ] ||
        die "expected one '${pattern}' in ${ARTIFACTS_REPO} ${ARTIFACTS_RELEASE}, found ${#matches[@]}"
    read -r id name <<<"${matches[0]}"

    log "Downloading ${name}"
    github_download_asset "${id}" "${file}"
}

# The newest, as build_sdk.sh adds one archive per SDK version.
function local_sdk_archive() {
    local archive
    archive="$(find "${SDK_DIR}" -maxdepth 1 -name "${SDK_ASSET}" -printf '%T@ %p\n' 2>/dev/null |
        sort -rn | head -n 1 | cut -d' ' -f2-)"
    [ -n "${archive}" ] ||
        die "no '${SDK_ASSET}' in ${SDK_DIR}, build it with: ./utils/scripts/build_sdk.sh"
    echo "${archive}"
}

function install_sdk() {
    local archive installer

    if [ "${LOCAL}" -eq 1 ]; then
        archive="$(local_sdk_archive)"
        log "Using ${archive}"
    else
        archive="${TMP_DIR}/sdk.tar.gz"
        download_asset "${SDK_ASSET}" "${archive}"
    fi
    tar -xzf "${archive}" -C "${TMP_DIR}"
    installer="$(find "${TMP_DIR}" -maxdepth 1 -name '*-toolchain*.sh' -print -quit)"
    [ -n "${installer}" ] || die "no SDK installer inside ${SDK_ASSET}"

    log "Installing the SDK to ${SDK_DEST}"
    chmod +x "${installer}"
    "${installer}" -y -d "${SDK_DEST}"
    log "Activate with: . $(find "${SDK_DEST}" -maxdepth 1 -name 'environment-setup-*' -print -quit)"
}

function install_image() {
    local machine="$1"
    local archive="${TMP_DIR}/${machine}.tar.gz"
    local unpacked="${TMP_DIR}/${machine}"
    local dest="${ARTIFACTS_DIR}/${machine}"

    # get_artifacts.sh already put it where it is installed to.
    if [ "${LOCAL}" -eq 1 ]; then
        [ -f "${dest}/SHA256SUMS" ] ||
            die "${dest} not found, collect it with: ./utils/scripts/get_artifacts.sh -m ${machine}"
        (cd "${dest}" && sha256sum --quiet -c SHA256SUMS) || die "${dest} is damaged"
        log "${dest} is in place"
        return
    fi

    download_asset "image-${machine}-*.tar.gz" "${archive}"
    tar -xzf "${archive}" -C "${TMP_DIR}" "${machine}"
    # Verified before replacing, so a broken archive keeps the installed image.
    (cd "${unpacked}" && sha256sum --quiet -c SHA256SUMS) ||
        die "the ${machine} archive is damaged, ${dest} is left as it was"

    rm -rf "${dest}"
    mkdir -p "${ARTIFACTS_DIR}"
    mv "${unpacked}" "${dest}"
    log "Installed to ${dest}"
}

function main() {
    local components=() component

    while [ $# -gt 0 ]; do
        if [ "$1" = --sdk ]; then
            components+=(sdk)
        elif [ "$1" = --qemu ]; then
            components+=(qemu)
        elif [ "$1" = --image ]; then
            components+=(image)
        elif [ "$1" = --local ]; then
            LOCAL=1
        elif [ "$1" = -h ] || [ "$1" = --help ]; then
            usage
            exit 0
        else
            usage >&2
            die "unknown option: $1"
        fi
        shift
    done
    [ "${#components[@]}" -gt 0 ] || components=(sdk qemu image)

    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "${TMP_DIR}"' EXIT
    [ "${LOCAL}" -eq 1 ] || RELEASE_JSON="$(github_release_json)"

    for component in "${components[@]}"; do
        if [ "${component}" = sdk ]; then
            install_sdk
        elif [ "${component}" = qemu ]; then
            install_image "${QEMU_MACHINE}"
        elif [ "${component}" = image ]; then
            install_image "${BOARD_MACHINE}"
        fi
    done
}

main "$@"
