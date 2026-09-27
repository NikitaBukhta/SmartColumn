#!/bin/bash

set -euo pipefail

# shellcheck source=../../build-config/build.env
. "$(dirname -- "${BASH_SOURCE[0]}")/../../build-config/build.env"

readonly SCRIPTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

readonly BOARDS=(rpi4-64)
readonly EMULATORS=(qemu-rpi4-64)
readonly ALL_MACHINES=("${BOARDS[@]}" "${EMULATORS[@]}")

function log() {
    echo "==> $*"
}

function die() {
    echo "ERROR: $*" >&2
    exit 1
}

function usage() {
    cat <<EOF
Usage: $(basename -- "$0") [-m MACHINE]... [--with-sdk]

Copies the ${BB_TARGET} images to ${ARTIFACTS_DIR}/<machine>
and packs them there into image-<machine>-<version>.tar.gz.

    -m, --machine MACHINE  ${ALL_MACHINES[*]}
                           (repeatable, default: all of them)
    --with-sdk             also build the SDK into ${SDK_DIR}
                           (default: for ${BOARDS[*]}, otherwise for each -m)
    -h, --help             show this help
EOF
}

function contains() {
    local item="$1"
    shift
    [[ " $* " == *" ${item} "* ]]
}

function is_emulator() {
    contains "$1" "${EMULATORS[@]}"
}

function setup_dir() {
    echo "${REPO_ROOT}/${BB_TOP_DIR_NAME}/smartcolumn-$1"
}

# The machine option is not always the Yocto MACHINE (rpi4-64 builds
# raspberrypi4-64), so take the one directory the build made.
function deploy_dir() {
    local machine="$1"
    local images dirs=()

    images="$(setup_dir "${machine}")/build/tmp/deploy/images"
    [ -d "${images}" ] ||
        die "${images} not found, build it with: ./utils/scripts/prepare_env.sh -m ${machine}"

    mapfile -t dirs < <(find "${images}" -mindepth 1 -maxdepth 1 -type d)
    [ "${#dirs[@]}" -eq 1 ] || die "expected one machine in ${images}, found ${#dirs[@]}"
    echo "${dirs[0]}"
}

# Stable names, which deploy keeps as symlinks to the timestamped files.
function image_files() {
    local machine="$1" rootfs="$2"

    if is_emulator "${machine}"; then
        printf '%s\n' "${rootfs}.qemuboot.conf" "${rootfs}.ext4.zst" Image
    else
        printf '%s\n' "${rootfs}.wic.bz2" "${rootfs}.wic.bmap"
    fi
    echo "${rootfs}.manifest"
}

function distro_version() {
    python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["DISTRO_VERSION"])' "$1"
}

function copy_images() {
    local src="$1" dest="$2"
    shift 2
    local file

    for file in "$@"; do
        [ -e "${src}/${file}" ] || die "${src}/${file} not found, is the ${BB_TARGET} build complete?"
    done

    rm -rf "${dest}"
    mkdir -p "${dest}"
    for file in "$@"; do
        echo "    ${file} <- $(basename -- "$(readlink -f "${src}/${file}")")"
        cp -L --preserve=timestamps "${src}/${file}" "${dest}/${file}"
    done
}

function write_checksums() {
    local dir="$1" sums
    sums="$(cd "${dir}" && sha256sum -- *)"
    echo "${sums}" >"${dir}/SHA256SUMS"
}

# Written outside the directory first: tar fails on one that changes under it.
function pack() {
    local machine="$1" archive="$2"
    tar -czf "${ARTIFACTS_DIR}/${archive}" -C "${ARTIFACTS_DIR}" "${machine}"
    mv "${ARTIFACTS_DIR}/${archive}" "${ARTIFACTS_DIR}/${machine}/"
    log "${machine}: ${ARTIFACTS_DIR}/${machine}/${archive}"
}

function collect() {
    local machine="$1"
    local deploy rootfs version files=()
    local dest="${ARTIFACTS_DIR}/${machine}"

    deploy="$(deploy_dir "${machine}")"
    rootfs="${BB_TARGET}-$(basename -- "${deploy}").rootfs"
    version="$(distro_version "${deploy}/${rootfs}.testdata.json")"
    mapfile -t files < <(image_files "${machine}" "${rootfs}")

    log "${machine}: ${deploy}"
    copy_images "${deploy}" "${dest}" "${files[@]}"
    if is_emulator "${machine}"; then
        # Standalone for a .qemuboot.conf, so the image runs without a build.
        cp "$(setup_dir "${machine}")/layers/openembedded-core/scripts/runqemu" "${dest}/"
    fi
    write_checksums "${dest}"
    pack "${machine}" "image-${machine}-${version}.tar.gz"
}

function build_sdk() {
    local machine="$1"
    log "${machine}: building the SDK"
    BB_MACHINE="${machine}" BB_SETUP_DIR="smartcolumn-${machine}" "${SCRIPTS_DIR}/build_sdk.sh"
}

function main() {
    local machines=() sdk_machines=() with_sdk=0 machine

    while [ $# -gt 0 ]; do
        if [ "$1" = -m ] || [ "$1" = --machine ]; then
            [ $# -ge 2 ] || die "$1 needs a machine"
            contains "$2" "${ALL_MACHINES[@]}" || die "unknown machine: $2 (one of: ${ALL_MACHINES[*]})"
            machines+=("$2")
            shift
        elif [ "$1" = --with-sdk ]; then
            with_sdk=1
        elif [ "$1" = -h ] || [ "$1" = --help ]; then
            usage
            exit 0
        else
            usage >&2
            die "unknown option: $1"
        fi
        shift
    done

    if [ "${#machines[@]}" -eq 0 ]; then
        machines=("${ALL_MACHINES[@]}")
        # The board's SDK covers QEMU too, so by default only boards get one.
        sdk_machines=("${BOARDS[@]}")
    else
        sdk_machines=("${machines[@]}")
    fi

    for machine in "${machines[@]}"; do
        collect "${machine}"
    done

    if [ "${with_sdk}" -eq 1 ]; then
        for machine in "${sdk_machines[@]}"; do
            build_sdk "${machine}"
        done
    fi

    log "Artifacts are in ${ARTIFACTS_DIR}"
}

main "$@"
