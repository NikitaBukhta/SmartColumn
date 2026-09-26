#!/bin/bash

set -euo pipefail

readonly CONFIG_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../build-config" && pwd)"
readonly ROOT_LOGIN_FRAGMENT="core/yocto/root-login-with-empty-password"

function log() {
  echo "==> $*"
}

function die() {
  echo "ERROR: $*" >&2
  exit 1
}

function usage() {
  cat <<'USAGE'
Usage: ./scripts/prepare_env.sh [-m MACHINE]

Prepares the build host, sets up the build for MACHINE and builds the image.

  -m, --machine MACHINE   rpi4-64 (default), qemu-rpi4-64, or any other
                          "machine" option in build-config/smartcolumn-wrynose.conf.json
  -h, --help              Show this help.
USAGE
}

function parse_args() {
  while (($# > 0)); do
    case "$1" in
      -m | --machine)
        (($# > 1)) || die "$1 needs a machine name (try --help)"
        BB_MACHINE="$2"
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1 (try --help)"
        ;;
    esac
  done
}

# The environment wins over the machine file, which wins over build.env:
# each file only fills in what is still unset.
function load_config() {
  local file
  for file in "machines/${BB_MACHINE:-rpi4-64}.env" build.env; do
    if [ -f "${CONFIG_DIR}/${file}" ]; then
      # shellcheck source=/dev/null
      . "${CONFIG_DIR}/${file}"
    fi
  done

  VENV_DIR="${REPO_ROOT}/bitbake-setup-venv"
  SETUP_DIR="${REPO_ROOT}/${BB_TOP_DIR_NAME}/${BB_SETUP_DIR}"
  BUILD_ENV="${SETUP_DIR}/build/init-build-env"
}

# BB_MACHINE is the short name; bitbake-setup wants the full fragment name.
function select_machine() {
  [ -f "${BB_CONFIG}" ] || die "${BB_CONFIG} not found."

  local names
  names="$(python3 -c 'import json, sys
for c in json.load(open(sys.argv[1]))["bitbake-setup"]["configurations"]:
    for o in c["oe-fragments-one-of"]["machine"]["options"]:
        print(o["name"])' "${BB_CONFIG}")"

  MACHINE_FRAGMENT="$(awk -F/ -v m="${BB_MACHINE}" '$NF == m {print; exit}' <<<"${names}")"
  [ -n "${MACHINE_FRAGMENT}" ] ||
    die "unknown machine '${BB_MACHINE}', choose one of: $(awk -F/ '{printf "%s ", $NF}' <<<"${names}")"
}

function check_build_dir() {
  local dir="${REPO_ROOT}/${BB_TOP_DIR_NAME}"
  while [ ! -d "${dir}" ]; do
    dir="$(dirname "${dir}")"
  done

  local fs free_gb
  fs="$(df -T "${dir}" | awk 'NR==2 {print $2}')"
  free_gb="$(df -BG --output=avail "${dir}" | awk 'NR==2 {gsub(/[^0-9]/, ""); print}')"

  case "${fs}" in
    9p | drvfs | cifs | smbfs | nfs | nfs4 | fuseblk)
      die "${dir} is on ${fs}: the build must live in the Linux filesystem, not on a Windows mount or a network share."
      ;;
  esac
  [ "${free_gb}" -ge "${BB_MIN_FREE_GB}" ] ||
    die "only ${free_gb} GB free in ${dir}, a clean build needs ${BB_MIN_FREE_GB} GB."

  log "Build directory: ${dir} (${fs}, ${free_gb} GB free)"
}

function install_deps() {
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential chrpath cpio debianutils diffstat file gawk gcc git \
    iputils-ping libacl1 libcrypt-dev locales python3 python3-git \
    python3-jinja2 python3-pexpect python3-pip python3-subunit python3-venv \
    python3-websockets socat texinfo unzip wget xz-utils zstd

  if dpkg-query -W -f='${Status}' oss4-dev 2>/dev/null | grep -q "ok installed"; then
    echo "warning: oss4-dev breaks the QEMU build, remove it with 'sudo apt remove oss4-dev'."
  fi
}

function enable_locale() {
  if ! locale --all-locales | grep -q en_US.utf8; then
    echo "en_US.UTF-8 UTF-8" | sudo tee -a /etc/locale.gen >/dev/null
    sudo locale-gen
  fi
}

function set_parallelism() {
  local cpus ram_gb threads
  cpus="$(nproc)"
  ram_gb="$(free -g | awk '/^Mem:/ {print $2}')"

  # Load is BB_NUMBER_THREADS * PARALLEL_MAKE, so cap both by 2 GB per thread.
  threads=$((ram_gb / 2 < cpus ? ram_gb / 2 : cpus))
  ((threads > 0)) || threads=1

  export BB_NUMBER_THREADS="${threads}"
  export PARALLEL_MAKE="-j${threads}"
  log "Parallelism: ${threads} threads (${cpus} CPUs, ${ram_gb} GB RAM)"
}

function install_bitbake_setup() {
  if [ ! -x "${VENV_DIR}/bin/bitbake-setup" ]; then
    log "Creating virtual environment in ${VENV_DIR}"
    python3 -m venv "${VENV_DIR}"
  fi

  # 'pip show' fails when the package is not installed yet, a fresh venv.
  local installed
  installed="$("${VENV_DIR}/bin/pip" show bitbake-setup 2>/dev/null | awk '/^Version:/ {print $2}' || true)"
  if [ "${installed}" != "${BB_SETUP_VERSION}" ]; then
    log "Installing bitbake-setup ${BB_SETUP_VERSION}"
    "${VENV_DIR}/bin/pip" install --quiet "bitbake-setup==${BB_SETUP_VERSION}"
  fi
}

function bitbake_setup() {
  [ "${EUID}" -ne 0 ] || die "BitBake refuses to run as root, run this script as a normal user."
  install_bitbake_setup

  local bbsetup=("${VENV_DIR}/bin/bitbake-setup"
    --setting default top-dir-prefix "${REPO_ROOT}"
    --setting default top-dir-name "${BB_TOP_DIR_NAME}")

  if [ -f "${BUILD_ENV}" ]; then
    check_setup_config
    # Re-reads BB_CONFIG; fragments dropped by the regenerated conf/ are
    # enabled again by bitbake_build.
    log "Updating ${SETUP_DIR}"
    "${bbsetup[@]}" update --setup-dir "${SETUP_DIR}" --update-bb-conf yes
  else
    log "Initializing ${BB_CONFIG_NAME} for ${MACHINE_FRAGMENT} in ${SETUP_DIR}"
    "${bbsetup[@]}" init --non-interactive --setup-dir-name "${BB_SETUP_DIR}" \
      "${BB_CONFIG}" "${BB_CONFIG_NAME}" "${MACHINE_FRAGMENT}"
    [ -f "${BUILD_ENV}" ] || die "${BUILD_ENV} not found after init."
  fi
}

function check_setup_config() {
  local recorded
  recorded="$(python3 -c 'import json, sys
print(json.load(open(sys.argv[1]))["non-interactive-cmdline-options"][0])' \
    "${SETUP_DIR}/config/config-upstream.json")"
  [ "${recorded}" = "${BB_CONFIG}" ] ||
    die "${SETUP_DIR} was made from ${recorded}, remove it and run this script again."
}

# Toggled, not just enabled: a fragment left over from a debug build
# would otherwise stay in the image configuration unnoticed.
function toggle_root_login() {
  if [ "${BB_ROOT_LOGIN}" != "0" ]; then
    log "Root login enabled with an empty password (BB_ROOT_LOGIN=0 to disable)"
    bitbake-config-build enable-fragment "${ROOT_LOGIN_FRAGMENT}" >/dev/null
  else
    bitbake-config-build disable-fragment "${ROOT_LOGIN_FRAGMENT}" >/dev/null
  fi
}

function enable_fragments() {
  local fragment
  for fragment in "${BB_FRAGMENTS[@]}"; do
    bitbake-config-build enable-fragment "${fragment}" >/dev/null
  done
  toggle_root_login
}

function bitbake_build() {
  # oe-init-build-env is not written for 'set -eu' and changes the directory.
  (
    set +eu
    # shellcheck source=/dev/null # generated by bitbake-setup, absent until init runs
    . "${BUILD_ENV}"
    set -e
    enable_fragments
    log "Building ${BB_TARGET} for ${BB_MACHINE}"
    bitbake "${BB_TARGET}"
  )
}

function main() {
  parse_args "$@"
  load_config
  select_machine

  check_build_dir
  install_deps
  enable_locale
  set_parallelism
  bitbake_setup
  bitbake_build
}

main "$@"
