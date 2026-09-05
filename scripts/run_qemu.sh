#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

BB_TOP_DIR_NAME="${BB_TOP_DIR_NAME:-bitbake-builds}"
BB_SETUP_DIR="${BB_SETUP_DIR:-poky-wrynose}"
BB_TARGET="${BB_TARGET:-core-image-minimal}"
# nographic: no display under WSL. slirp: user networking, needs no sudo.
# snapshot: required for a compressed (.zst) rootfs, and keeps it read-only.
read -ra RUNQEMU_OPTS <<<"${RUNQEMU_OPTS:-nographic slirp snapshot}"

readonly SETUP_DIR="${REPO_ROOT}/${BB_TOP_DIR_NAME}/${BB_SETUP_DIR}"
readonly RUNQEMU="${SETUP_DIR}/layers/openembedded-core/scripts/runqemu"
readonly IMAGES_DIR="${SETUP_DIR}/build/tmp/deploy/images"

function log() {
  echo "==> $*"
}

function die() {
  echo "ERROR: $*" >&2
  exit 1
}

function pick_machine() {
  local machines=()
  mapfile -t machines < <(find "${IMAGES_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)

  if [ "${#machines[@]}" -eq 0 ]; then
    die "no built machine found in ${IMAGES_DIR}
       Build an image first: ./scripts/prepare_env.sh"
  fi

  if [ -n "${QEMU_MACHINE:-}" ]; then
    local candidate
    for candidate in "${machines[@]}"; do
      if [ "${candidate}" = "${QEMU_MACHINE}" ]; then
        echo "${candidate}"
        return
      fi
    done
    die "machine '${QEMU_MACHINE}' is not built, ${IMAGES_DIR} has: ${machines[*]}
       Build it with: BB_INIT_ARGS='${BB_SETUP_DIR} poky distro/poky machine/${QEMU_MACHINE}' ./scripts/prepare_env.sh"
  fi

  if [ "${#machines[@]}" -gt 1 ]; then
    die "several machines are built: ${machines[*]}
       Choose one: QEMU_MACHINE=<name> ./scripts/run_qemu.sh"
  fi

  echo "${machines[0]}"
}

# Giving runqemu a .qemuboot.conf makes it read every path and QEMU option from
# that file, so the build environment does not have to be sourced.
function pick_conf() {
  local machine="$1"
  local dir="${IMAGES_DIR}/${machine}"
  local conf="${dir}/${BB_TARGET}-${machine}.rootfs.qemuboot.conf"

  # The stable symlink can be missing; fall back to the newest timestamped
  # file, but never to a different image than the one asked for.
  if [ ! -e "${conf}" ]; then
    conf="$(find "${dir}" -maxdepth 1 -name "${BB_TARGET}-${machine}*.qemuboot.conf" -printf '%T@ %p\n' 2>/dev/null |
      sort -rn | head -n 1 | cut -d' ' -f2-)"
  fi

  if [ -z "${conf}" ] || [ ! -e "${conf}" ]; then
    local built=()
    mapfile -t built < <(find "${dir}" -maxdepth 1 -type l -name '*.qemuboot.conf' -printf '%f\n' 2>/dev/null |
      sed "s/-${machine}\.rootfs\.qemuboot\.conf//" | sort -u)
    die "image '${BB_TARGET}' is not built for machine '${machine}', ${dir} has: ${built[*]:-nothing}
       Build it with: BB_TARGET=${BB_TARGET} ./scripts/prepare_env.sh"
  fi

  echo "${conf}"
}

# KVM only helps when the target architecture matches the host.
function kvm_available() {
  [ -r /dev/kvm ] && [ -w /dev/kvm ] &&
    [ "$(uname -m)" = "x86_64" ] && [[ "$1" == qemux86-64* ]]
}

function main() {
  [ -x "${RUNQEMU}" ] || die "${RUNQEMU} not found
       Set up the build first: ./scripts/prepare_env.sh"

  local machine conf
  machine="$(pick_machine)"
  conf="$(pick_conf "${machine}")"

  local opts=("${RUNQEMU_OPTS[@]}")
  if kvm_available "${machine}"; then
    opts+=(kvm)
  fi

  log "Machine: ${machine}"
  log "Config:  ${conf}"
  log "Options: ${opts[*]}"
  log "Leave the console with Ctrl-A, then X."

  "${RUNQEMU}" "${conf}" "${opts[@]}" "$@"
}

main "$@"
