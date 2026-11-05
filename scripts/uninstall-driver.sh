#!/bin/bash
#
# uninstall-driver.sh — remove the EQtargets Audio HAL driver and restart coreaudiod.
#
#   scripts/uninstall-driver.sh
#
# Needs an admin password (sudo). If EQtargets Audio is the default output when
# it disappears, macOS falls back to another output device by itself.
#
# Leftover: the shared-memory ring (/eqtargets.audio.ring, ~270 KB, owned by
# _coreaudiod) stays in kernel memory until the next reboot. It is harmless and
# a reinstalled driver re-attaches to it.
#
set -euo pipefail

readonly DRIVER_NAME="EQtargetsAudio.driver"
readonly HAL_DIR="/Library/Audio/Plug-Ins/HAL"
readonly DEST="${HAL_DIR}/${DRIVER_NAME}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

die() { echo "uninstall-driver: $*" >&2; exit 1; }

if [[ ! -e "${DEST}" ]]; then
    echo "EQtargets Audio is not installed (${DEST} does not exist). Nothing to do."
    exit 0
fi

echo "Removing ${DEST} (sudo) ..."
sudo rm -rf "${DEST}"
[[ ! -e "${DEST}" ]] || die "could not remove ${DEST}"

echo "Restarting coreaudiod (audio drops out for a moment) ..."
if ! sudo launchctl kickstart -k system/com.apple.audio.coreaudiod; then
    echo "launchctl kickstart failed; falling back to killall (launchd relaunches it)" >&2
    sudo killall coreaudiod || true
fi

# eqt-probe --devices exits 3 when EQtargets Audio is absent.
PROBE="${EQT_PROBE:-${REPO_ROOT}/build/release/Build/Products/Release/eqt-probe}"
for ((i = 0; i < 20; i++)); do
    sleep 0.5
    if [[ -x "${PROBE}" ]]; then
        status=0
        "${PROBE}" --devices >/dev/null 2>&1 || status=$?
        if [[ "${status}" -eq 3 ]]; then
            echo "EQtargets Audio removed; coreaudiod no longer publishes it."
            exit 0
        fi
    elif ! system_profiler SPAudioDataType 2>/dev/null | grep "EQtargets Audio" >/dev/null; then
        echo "EQtargets Audio removed; coreaudiod no longer publishes it."
        exit 0
    fi
done

die "EQtargets Audio is still published 10 s after the restart. Restart the Mac to be sure."
