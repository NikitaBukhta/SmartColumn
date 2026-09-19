# A .qemuboot.conf gives runqemu every path and option, so the build
# environment does not have to be sourced. Extra arguments go to runqemu.

#!/bin/bash

set -euo pipefail
BB_MACHINE="${BB_MACHINE:-qemu-rpi4-64}"

# shellcheck source=../build-config/build.env
. "$(dirname -- "${BASH_SOURCE[0]}")/../build-config/build.env"

readonly SETUP_DIR="${REPO_ROOT}/${BB_TOP_DIR_NAME}/${BB_SETUP_DIR}"
readonly CONF="${SETUP_DIR}/build/tmp/deploy/images/${BB_MACHINE}/${BB_TARGET}-${BB_MACHINE}.rootfs.qemuboot.conf"

[[ "${BB_MACHINE}" == qemu* ]] ||
  { echo "ERROR: ${BB_MACHINE} is a board, write its .wic image with bmaptool instead." >&2; exit 1; }
if [ ! -e "${CONF}" ]; then
  echo "ERROR: ${CONF} not found, build it with: ./scripts/prepare_env.sh -m ${BB_MACHINE}" >&2
  exit 1
fi

echo "==> Leave the console with Ctrl-A, then X."
exec "${SETUP_DIR}/layers/openembedded-core/scripts/runqemu" "${CONF}" "${RUNQEMU_OPTS[@]}" "$@"