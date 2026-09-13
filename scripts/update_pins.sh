#!/bin/bash

set -euo pipefail

# shellcheck source=../build-config/build.env
. "$(dirname -- "${BASH_SOURCE[0]}")/../build-config/build.env"

CHECK_ONLY=0

function log() {
  echo "==> $*"
}

function die() {
  echo "ERROR: $*" >&2
  exit 1
}

function usage() {
  cat <<'USAGE'
Usage: ./scripts/update_pins.sh [--check]

Points every layer revision in build-config/source-overrides.json at the current
head of its recorded branch. Only the revisions are read over the network --
nothing is cloned, and no build is touched. Run the build afterwards and commit
the file as a change of its own.

  --check   Report what is behind and exit non-zero, without writing.
  -h        Show this help.
USAGE
}

function parse_args() {
  while (($# > 0)); do
    case "$1" in
      --check)
        CHECK_ONLY=1
        shift
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

# name|uri|branch|rev, one source per line. '|' appears in neither git URIs
# nor branch names, so it needs no escaping.
function read_sources() {
  python3 - "${BB_SOURCE_OVERRIDES}" <<'PY'
import json, sys

sources = json.load(open(sys.argv[1]))["sources"]
for name, source in sorted(sources.items()):
    remote = source.get("git-remote")
    if remote:
        print("|".join([name, remote["uri"], remote["branch"], remote["rev"]]))
PY
}

function write_updates() {
  python3 - "${BB_SOURCE_OVERRIDES}" "$@" <<'PY'
import json, sys

path = sys.argv[1]
config = json.load(open(path))
for update in sys.argv[2:]:
    name, rev = update.split("=", 1)
    config["sources"][name]["git-remote"]["rev"] = rev
with open(path, "w") as f:
    json.dump(config, f, sort_keys=True, indent=4)
    f.write(chr(10))
PY
}

function main() {
  parse_args "$@"
  [ -f "${BB_SOURCE_OVERRIDES}" ] ||
    die "${BB_SOURCE_OVERRIDES} not found, generate it from a setup's config/sources-fixed-revisions.json first."

  log "Reading branch heads for ${BB_SOURCE_OVERRIDES}"

  local updates=() name uri branch rev head listing
  while IFS='|' read -r name uri branch rev; do
    if ! listing="$(git ls-remote "${uri}" "${branch}" 2>&1)"; then
      die "cannot reach ${uri}: ${listing}"
    fi

    head="$(awk 'NR==1 {print $1}' <<<"${listing}")"
    [ -n "${head}" ] || die "branch '${branch}' is gone from ${uri}, renamed or retired?"

    if [ "${head}" = "${rev}" ]; then
      printf '  %-20s %s  up to date\n' "${name}" "${rev:0:12}"
    else
      printf '  %-20s %s  ->  %s\n' "${name}" "${rev:0:12}" "${head:0:12}"
      updates+=("${name}=${head}")
    fi
  done < <(read_sources)

  if [ "${#updates[@]}" -eq 0 ]; then
    log "Every pin is already at its branch head."
    return 0
  fi

  if [ "${CHECK_ONLY}" -eq 1 ]; then
    die "${#updates[@]} pin(s) behind; re-run without --check to update them."
  fi

  write_updates "${updates[@]}"
  log "Updated ${#updates[@]} pin(s) in ${BB_SOURCE_OVERRIDES}"
  log "Now rebuild to verify, then commit the file on its own (NFR-MNT-010 item 3)."
  log "An existing setup also needs the new revisions in its config-upstream.json:"
  log "  bitbake-setup update --setup-dir ... --update-bb-conf no"
}

main "$@"
