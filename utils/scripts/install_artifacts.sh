#!/bin/bash

set -euo pipefail

# Optional: the script also works downloaded without the repository.
BUILD_ENV_FILE="$(dirname -- "${BASH_SOURCE[0]}")/../../build-config/build.env"
# shellcheck source=../../build-config/build.env
[ ! -f "${BUILD_ENV_FILE}" ] || . "${BUILD_ENV_FILE}"

ARTIFACTS_REPO="${ARTIFACTS_REPO:-NikitaBukhta/SmartColumn}"
ARTIFACTS_RELEASE="${ARTIFACTS_RELEASE:-v0.0.2}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-${PWD}/artifacts}"
SDK_INSTALL_ROOT="${SDK_INSTALL_ROOT:-/opt/smart-column-sdk}"

# qemu-rpi4-64 shares the board's CPU tuning, so the board's SDK serves both.
readonly SDK_ASSET="sdk-raspberrypi4-64-*.tar.gz"
readonly SDK_DEST="${SDK_INSTALL_ROOT}/rpi4-64"
readonly QEMU_MACHINE="qemu-rpi4-64"
readonly BOARD_MACHINE="rpi4-64"

TMP_DIR=""
RELEASE_JSON=""

function log() {
    echo "==> $*"
}

function die() {
    echo "ERROR: $*" >&2
    exit 1
}

function usage() {
    cat <<EOF
Usage: $(basename -- "$0") [--sdk] [--qemu] [--image]

Installs artifacts of ${ARTIFACTS_REPO} ${ARTIFACTS_RELEASE}, all of them by default.

    --sdk       the SDK, to ${SDK_DEST}
    --qemu      the QEMU image, to ${ARTIFACTS_DIR}/${QEMU_MACHINE}
    --image     the Raspberry Pi 4 image, to ${ARTIFACTS_DIR}/${BOARD_MACHINE}
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

function install_sdk() {
    local archive="${TMP_DIR}/sdk.tar.gz" installer

    download_asset "${SDK_ASSET}" "${archive}"
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
    RELEASE_JSON="$(github_release_json)"

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
