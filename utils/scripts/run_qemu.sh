#!/bin/bash

set -euo pipefail
BB_MACHINE="${BB_MACHINE:-qemu-rpi4-64}"

# shellcheck source=../../build-config/build.env
. "$(dirname -- "${BASH_SOURCE[0]}")/../../build-config/build.env"

readonly SETUP_DIR="${REPO_ROOT}/${BB_TOP_DIR_NAME}/${BB_SETUP_DIR}"
readonly BUILD_CONF="${SETUP_DIR}/build/tmp/deploy/images/${BB_MACHINE}/${BB_TARGET}-${BB_MACHINE}.rootfs.qemuboot.conf"
readonly ARTIFACTS_CONF="${ARTIFACTS_DIR}/${BB_MACHINE}/${BB_TARGET}-${BB_MACHINE}.rootfs.qemuboot.conf"

function log() {
    echo "==> $*"
}

function die() {
    echo "ERROR: $*" >&2
    exit 1
}

function usage() {
    cat <<EOF
Usage: $(basename -- "$0") [--from auto|build|artifacts] [RUNQEMU_ARG]...

Boots ${BB_TARGET} for ${BB_MACHINE} in QEMU.

    --from build      the image of the build: ${BUILD_CONF}
    --from artifacts  the image in ${ARTIFACTS_DIR}/${BB_MACHINE},
                      made by get_artifacts.sh or install_artifacts.sh
    --from auto       build if it has the image, artifacts otherwise (default)
    -h, --help        show this help
EOF
}

function run_build() {
    [ -e "${BUILD_CONF}" ] ||
        die "${BUILD_CONF} not found, build it with: ./utils/scripts/prepare_env.sh -m ${BB_MACHINE}"
    log "Image of the build: ${BUILD_CONF}"
    RUNQEMU="${SETUP_DIR}/layers/openembedded-core/scripts/runqemu"
    CONF="${BUILD_CONF}"
}

# The conf's path to the build's QEMU is dead outside deploy, use the host's.
function run_artifacts() {
    local qemu
    [ -e "${ARTIFACTS_CONF}" ] ||
        die "${ARTIFACTS_CONF} not found, get it with: ./utils/scripts/install_artifacts.sh --qemu"
    qemu="$(sed -n 's/^qb_system_name = //p' "${ARTIFACTS_CONF}")"
    command -v "${qemu}" >/dev/null ||
        die "${qemu} not found, install it with: sudo apt install qemu-system-arm"
    log "Image of the artifacts: ${ARTIFACTS_CONF}"
    export OECORE_NATIVE_SYSROOT=/
    RUNQEMU="$(dirname -- "${ARTIFACTS_CONF}")/runqemu"
    CONF="${ARTIFACTS_CONF}"
}

function main() {
    local from=auto

    if [ "${1:-}" = --from ]; then
        [ $# -ge 2 ] || die "--from needs a value"
        from="$2"
        shift 2
    elif [[ "${1:-}" == --from=* ]]; then
        from="${1#--from=}"
        shift
    elif [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; then
        usage
        exit 0
    fi

    [[ "${BB_MACHINE}" == qemu* ]] ||
        die "${BB_MACHINE} is a board, write its .wic image with bmaptool instead."

    if [ "${from}" = build ]; then
        run_build
    elif [ "${from}" = artifacts ]; then
        run_artifacts
    elif [ "${from}" = auto ]; then
        if [ -e "${BUILD_CONF}" ]; then
            run_build
        else
            run_artifacts
        fi
    else
        die "unknown --from '${from}', one of: auto build artifacts"
    fi

    log "Leave the console with Ctrl-A, then X."
    exec python3 "${RUNQEMU}" "${CONF}" "${RUNQEMU_OPTS[@]}" "$@"
}

main "$@"
