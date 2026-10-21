#!/bin/bash

set -euo pipefail
BB_MACHINE="${BB_MACHINE:-qemu-rpi4-64}"

# shellcheck source=../../build-config/build.env
. "$(dirname -- "${BASH_SOURCE[0]}")/../../build-config/build.env"

readonly SETUP_DIR="${REPO_ROOT}/${BB_TOP_DIR_NAME}/${BB_SETUP_DIR}"
readonly BUILD_CONF="${SETUP_DIR}/build/tmp/deploy/images/${BB_MACHINE}/${BB_TARGET}-${BB_MACHINE}.rootfs.qemuboot.conf"
readonly ARTIFACTS_CONF="${ARTIFACTS_DIR}/${BB_MACHINE}/${BB_TARGET}-${BB_MACHINE}.rootfs.qemuboot.conf"
readonly WSLG_PULSE=/mnt/wslg/PulseServer
readonly WSLG_BRIDGE_CONF="${XDG_CONFIG_HOME:-${HOME}/.config}/pipewire/pipewire.conf.d/50-wslg-tunnel.conf"
readonly WSLG_SINK_FIFO="${XDG_RUNTIME_DIR:-/run/user/${UID}}/smartcolumn-wslg-sink.fifo"
readonly WSLG_SOURCE_FIFO="${XDG_RUNTIME_DIR:-/run/user/${UID}}/smartcolumn-wslg-source.fifo"
readonly WSLG_SINK_UNIT=smartcolumn-wslg-speaker
readonly WSLG_SOURCE_UNIT=smartcolumn-wslg-mic
# The raw format both ends of each fifo agree on
readonly WSLG_PCM_ARGS="--raw --format=s16le --rate=48000 --channels=2 --latency-msec=100"

function log() {
    echo "==> $*"
}

function die() {
    echo "ERROR: $*" >&2
    exit 1
}

function usage() {
    cat <<EOF
Usage: $(basename -- "$0") [--from auto|build|artifacts] [--no-audio] [RUNQEMU_ARG]...

Boots ${BB_TARGET} for ${BB_MACHINE} in QEMU.

    --from build      the image of the build: ${BUILD_CONF}
    --from artifacts  the image in ${ARTIFACTS_DIR}/${BB_MACHINE},
                      made by get_artifacts.sh or install_artifacts.sh
    --from auto       build if it has the image, artifacts otherwise (default)
    --no-audio        no sound card in the guest, for hosts without pipewire;
                      by default it plays through the host's pipewire, which
                      under WSL is started and bridged to WSLg
    -h, --help        show this help
EOF
}

function run_build() {
    [ -e "${BUILD_CONF}" ] ||
        die "${BUILD_CONF} not found, build it with: ./utils/scripts/prepare_env.sh -m ${BB_MACHINE}"
    log "Image of the build: ${BUILD_CONF}"
    RUNQEMU="${SETUP_DIR}/layers/openembedded-core/scripts/runqemu"
    CONF="${BUILD_CONF}"
    QEMU="$(dirname -- "${CONF}")/$(conf_value staging_bindir_native)/$(conf_value qb_system_name)"
}

# The conf's path to the build's QEMU is dead outside deploy, use the host's.
function run_artifacts() {
    [ -e "${ARTIFACTS_CONF}" ] ||
        die "${ARTIFACTS_CONF} not found, get it with: ./utils/scripts/install_artifacts.sh --qemu"
    CONF="${ARTIFACTS_CONF}"
    QEMU="$(conf_value qb_system_name)"
    command -v "${QEMU}" >/dev/null ||
        die "${QEMU} not found, install it with: sudo apt install qemu-system-arm"
    log "Image of the artifacts: ${ARTIFACTS_CONF}"
    export OECORE_NATIVE_SYSROOT=/
    RUNQEMU="$(dirname -- "${ARTIFACTS_CONF}")/runqemu"
}

function conf_value() {
    sed -n "s/^$1 = //p" "${CONF}"
}

function is_wsl() {
    [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null
}

# Every failure here can be skipped with --no-audio, so each message says so.
function die_audio() {
    die "$*
       Or run without sound: $(basename -- "$0") --no-audio"
}

function check_audio_host() {
    local missing=() tool
    for tool in pipewire wireplumber wpctl; do
        command -v "${tool}" >/dev/null || missing+=("${tool}")
    done
    [ ${#missing[@]} -eq 0 ] ||
        die_audio "${missing[*]} not found, install them with: sudo apt install pipewire wireplumber"

    if [ -z "$(conf_value qb_audio_drv)" ]; then
        if [ "${CONF}" = "${ARTIFACTS_CONF}" ]; then
            die_audio "${CONF} has no sound card, get newer artifacts with: ./utils/scripts/install_artifacts.sh --qemu"
        fi
        die_audio "${CONF} has no sound card, rebuild the image with: ./utils/scripts/prepare_env.sh -m ${BB_MACHINE}"
    fi

    # pipewire came to QEMU in 8.1, Ubuntu 22.04 has 6.2
    if ! "${QEMU}" -audiodev help 2>/dev/null | grep -qx pipewire; then
        if [ "${CONF}" = "${ARTIFACTS_CONF}" ]; then
            die_audio "${QEMU} has no pipewire sound backend, it needs QEMU 8.1 or newer (Ubuntu 24.04)"
        fi
        die_audio "${QEMU} has no pipewire sound backend, rebuild it with: ./utils/scripts/prepare_env.sh -m ${BB_MACHINE}"
    fi

    if is_wsl; then
        [ -S "${WSLG_PULSE}" ] ||
            die_audio "${WSLG_PULSE} not found: WSLg is off or too old, run 'wsl --update' in Windows"
        [ "$(ps -p 1 -o comm=)" = systemd ] ||
            die_audio "systemd is not running: add '[boot]' 'systemd=true' to /etc/wsl.conf, then 'wsl --shutdown' in Windows"
        command -v pacat >/dev/null && command -v pactl >/dev/null ||
            die_audio "pacat or pactl not found, install them with: sudo apt install pulseaudio-utils"
        # WSLg's sound server blocks for good when Windows stops taking its sound
        timeout 3 pactl --server="unix:${WSLG_PULSE}" info >/dev/null 2>&1 ||
            die_audio "WSLg's sound server does not answer; restart WSL with 'wsl --shutdown' in Windows"
    fi

    systemctl --user show-environment >/dev/null 2>&1 ||
        die_audio "no systemd user session to run pipewire in (ssh without a login session, CI, a container?)"

    # A second sound server next to PulseAudio would fight it for the sound card.
    if pgrep -u "${UID}" -x pulseaudio >/dev/null; then
        die_audio "the host's sound server is PulseAudio, not pipewire; switch the host to pipewire
       (Ubuntu 22.04: sudo apt install pipewire-pulse wireplumber, then log in again)"
    fi
}

# One pipe-tunnel node: $1 sink|source, $2 fifo, $3 node name, $4 description.
# It never suspends: steady streams are what keep WSLg's server healthy.
function wslg_pipe_tunnel() {
    cat <<EOF
    {   name = libpipewire-module-pipe-tunnel
        args = {
            tunnel.mode = $1
            pipe.filename = "$2"
            audio.format = S16LE
            audio.rate = 48000
            audio.channels = 2
            audio.position = [ FL FR ]
            stream.props = {
                node.name = "$3"
                node.description = "$4"
                node.pause-on-idle = false
                session.suspend-timeout-seconds = 0
            }
        }
    }
EOF
}

# WSLg has no pipewire, only a PulseAudio server, and pipewire's own
# pulse-tunnel to it hangs that server. Instead pipewire's default sink and
# source are fifos, which plain PulseAudio clients (pacat, parec) connect to WSLg.
function write_wslg_bridge_conf() {
    local conf
    conf="$(
        echo "# Written by SmartColumn/utils/scripts/run_qemu.sh: pipewire's sound through fifos to WSLg"
        echo "context.modules = ["
        wslg_pipe_tunnel sink "${WSLG_SINK_FIFO}" wslg-sink "WSLg output"
        wslg_pipe_tunnel source "${WSLG_SOURCE_FIFO}" wslg-source "WSLg input"
        echo "]"
    )"
    if [ "$(cat "${WSLG_BRIDGE_CONF}" 2>/dev/null)" != "${conf}" ]; then
        log "Bridging pipewire to WSLg: ${WSLG_BRIDGE_CONF}"
        mkdir -p "$(dirname -- "${WSLG_BRIDGE_CONF}")"
        echo "${conf}" >"${WSLG_BRIDGE_CONF}"
        timeout 15 systemctl --user restart pipewire.service wireplumber.service ||
            die_audio "pipewire did not restart, see: journalctl --user -u pipewire"
    fi
}

# A user service, so it outlives this shell: $1 unit, $2 fifo, $3 command.
function start_wslg_pipe() {
    local i
    for i in 1 2 3 4 5; do
        [ -p "$2" ] && break
        sleep 1
    done
    [ -p "$2" ] || die_audio "pipewire made no $2, see: journalctl --user -u pipewire"

    systemctl --user stop "$1" >/dev/null 2>&1 || true
    systemctl --user reset-failed "$1" >/dev/null 2>&1 || true
    systemd-run --user --quiet --collect --unit="$1" \
        -p Restart=on-failure -p RestartSec=5 -p StartLimitIntervalSec=60 -p StartLimitBurst=3 \
        sh -c "exec $3"
}

function stop_wslg_bridge() {
    systemctl --user stop "${WSLG_SINK_UNIT}" "${WSLG_SOURCE_UNIT}" >/dev/null 2>&1 || true
}

# Both run only while QEMU does, the microphone stays closed otherwise.
# PULSE_SERVER of this shell doesn't reach user services, so the server is explicit.
function start_wslg_bridge() {
    trap stop_wslg_bridge EXIT
    start_wslg_pipe "${WSLG_SINK_UNIT}" "${WSLG_SINK_FIFO}" \
        "pacat --server=unix:${WSLG_PULSE} --playback ${WSLG_PCM_ARGS} --client-name=SmartColumn-QEMU < '${WSLG_SINK_FIFO}'"
    start_wslg_pipe "${WSLG_SOURCE_UNIT}" "${WSLG_SOURCE_FIFO}" \
        "parec --server=unix:${WSLG_PULSE} ${WSLG_PCM_ARGS} --client-name=SmartColumn-QEMU > '${WSLG_SOURCE_FIFO}'"

    sleep 2
    local unit
    for unit in "${WSLG_SINK_UNIT}" "${WSLG_SOURCE_UNIT}"; do
        systemctl --user is-active --quiet "${unit}" ||
            die_audio "the bridge to WSLg failed, see: journalctl --user -u ${unit}"
    done
}

function start_audio() {
    check_audio_host
    if is_wsl; then
        write_wslg_bridge_conf
    fi
    timeout 15 systemctl --user start pipewire.socket pipewire.service wireplumber.service ||
        die_audio "pipewire did not start, see: journalctl --user -u pipewire -u wireplumber"

    if is_wsl; then
        start_wslg_bridge
        log "Sound goes to and comes from: Windows' default devices, through WSLg"
        return
    fi

    # wireplumber picks the default sink a moment after pipewire is up
    local i
    for i in 1 2 3 4 5; do
        wpctl inspect @DEFAULT_AUDIO_SINK@ >/dev/null 2>&1 && break
        sleep 1
    done
    wpctl inspect @DEFAULT_AUDIO_SINK@ >/dev/null 2>&1 ||
        die_audio "pipewire has no output (a host without a sound card?), see: journalctl --user -u pipewire -u wireplumber"
    log "Sound goes to: $(wpctl inspect @DEFAULT_AUDIO_SINK@ | sed -n 's/.*node.description = "\(.*\)"/\1/p')"
}

function main() {
    local from=auto audio=1

    while [ $# -gt 0 ]; do
        if [ "$1" = --from ]; then
            [ $# -ge 2 ] || die "--from needs a value"
            from="$2"
            shift 2
        elif [[ "$1" == --from=* ]]; then
            from="${1#--from=}"
            shift
        elif [ "$1" = --no-audio ]; then
            audio=0
            shift
        elif [ "$1" = -h ] || [ "$1" = --help ]; then
            usage
            exit 0
        else
            break
        fi
    done

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

    local opts=("${RUNQEMU_OPTS[@]}")
    if [ "${audio}" = 1 ]; then
        start_audio
        opts+=(audio)
    fi

    log "Leave the console with Ctrl-A, then X."
    # Not exec: the EXIT trap stops the WSLg bridge after QEMU.
    python3 "${RUNQEMU}" "${CONF}" "${opts[@]}" "$@"
}

main "$@"
