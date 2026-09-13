#!/bin/bash

set -euo pipefail

declare -A SDK_ASSETS=(
  [x86]="sdk-qemux86-64-64bit-6.0.3.tar.gz"
)

SDK_REPO="${SDK_REPO:-NikitaBukhta/SmartColumn}"
SDK_RELEASE="${SDK_RELEASE:-dummy}"
SDK_INSTALL_ROOT="${SDK_INSTALL_ROOT:-/opt/smart-column-sdk}"
readonly SDK_ARCH="${1:-x86}"

TMP_DIR=""

function log() {
  echo "==> $*"
}

function die() {
  echo "ERROR: $*" >&2
  exit 1
}

function sdk_asset() {
  [ -n "${SDK_ASSETS[${SDK_ARCH}]:-}" ] ||
    die "unknown architecture '${SDK_ARCH}', available: ${!SDK_ASSETS[*]}"
  echo "${SDK_ASSETS[${SDK_ARCH}]}"
}

function download_with_gh() {
  local asset="$1" dir="$2"
  gh release download "${SDK_RELEASE}" --repo "${SDK_REPO}" --pattern "${asset}" --dir "${dir}"
}

function asset_id() {
  local asset="$1"
  curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    "https://api.github.com/repos/${SDK_REPO}/releases/tags/${SDK_RELEASE}" |
    python3 -c 'import json,sys
assets = json.load(sys.stdin)["assets"]
print(next((a["id"] for a in assets if a["name"] == sys.argv[1]), ""))' "${asset}"
}

function download_with_token() {
  local asset="$1" dir="$2" id
  id="$(asset_id "${asset}")"
  [ -n "${id}" ] || die "release '${SDK_RELEASE}' of ${SDK_REPO} has no asset '${asset}'"
  curl -fL --retry 3 -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/octet-stream" \
    -o "${dir}/${asset}" "https://api.github.com/repos/${SDK_REPO}/releases/assets/${id}"
}

function download() {
  local asset="$1" dir="$2"
  if command -v gh >/dev/null; then
    download_with_gh "${asset}" "${dir}"
  elif [ -n "${GITHUB_TOKEN:-}" ]; then
    download_with_token "${asset}" "${dir}"
  else
    die "${SDK_REPO} is private, so the download needs credentials:
       install the GitHub CLI and run 'gh auth login', or export GITHUB_TOKEN
       from a token with read access to the repository."
  fi
  [ -f "${dir}/${asset}" ] || die "${asset} was not downloaded"
}

function installer_path() {
  local dir="$1" installer
  installer="$(find "${dir}" -maxdepth 1 -name '*-toolchain*.sh' | head -n 1)"
  [ -n "${installer}" ] || die "no SDK installer inside ${SDK_ASSETS[${SDK_ARCH}]}"
  echo "${installer}"
}

function install_sdk() {
  local installer="$1" dest="$2"
  chmod +x "${installer}"
  "${installer}" -y -d "${dest}"
}

function main() {
  local asset dest archive installer
  asset="$(sdk_asset)"
  dest="${SDK_INSTALL_ROOT}/${SDK_ARCH}"

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "${TMP_DIR}"' EXIT

  log "Downloading ${asset} from ${SDK_REPO} (${SDK_RELEASE})"
  download "${asset}" "${TMP_DIR}"
  archive="${TMP_DIR}/${asset}"

  log "Extracting"
  tar -xzf "${archive}" -C "${TMP_DIR}"
  installer="$(installer_path "${TMP_DIR}")"

  log "Installing to ${dest}"
  install_sdk "${installer}" "${dest}"

  log "Activate with: . $(find "${dest}" -maxdepth 1 -name 'environment-setup-*' -print -quit)"
}

main "$@"
