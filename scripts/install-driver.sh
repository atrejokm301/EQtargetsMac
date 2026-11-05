#!/bin/bash
#
# install-driver.sh — install the EQtargets Audio HAL driver and restart coreaudiod.
#
#   scripts/install-driver.sh [path/to/EQtargetsAudio.driver]
#
# Default source: the Release product of
#   xcodebuild -project EQtargets.xcodeproj -scheme EQtargetsAudioDriver \
#              -configuration Release -derivedDataPath build/release build
#
# Needs an admin password (sudo): it writes /Library/Audio/Plug-Ins/HAL and
# restarts coreaudiod, which briefly interrupts ALL audio on the Mac.
# It never changes the default output device.
#
set -euo pipefail

readonly DRIVER_NAME="EQtargetsAudio.driver"
readonly BUNDLE_ID="com.eqtargets.app.driver"
readonly EXECUTABLE="EQtargetsAudio"
readonly HAL_DIR="/Library/Audio/Plug-Ins/HAL"
readonly DEST="${HAL_DIR}/${DRIVER_NAME}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly DEFAULT_SRC="${REPO_ROOT}/build/release/Build/Products/Release/${DRIVER_NAME}"

# nm / lipo / codesign come from Xcode; the default CLT may be missing.
# (No `grep -q` in pipelines below: under pipefail, grep -q exiting early can
# SIGPIPE the producer and turn a match into a failure.)
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

die() { echo "install-driver: $*" >&2; exit 1; }

SRC="${1:-${DEFAULT_SRC}}"
SRC="${SRC%/}"

# ------------------------------------------------------------------ validate the bundle
if [[ ! -d "${SRC}" ]]; then
    die "no driver bundle at '${SRC}'.
Build it first:
  cd '${REPO_ROOT}' && xcodebuild -project EQtargets.xcodeproj -scheme EQtargetsAudioDriver -configuration Release -derivedDataPath build/release build"
fi
[[ "$(basename "${SRC}")" == "${DRIVER_NAME}" ]] || die "expected a bundle named ${DRIVER_NAME}, got '$(basename "${SRC}")'"

readonly PLIST="${SRC}/Contents/Info.plist"
readonly BINARY="${SRC}/Contents/MacOS/${EXECUTABLE}"
[[ -f "${PLIST}" ]] || die "missing ${PLIST}"
plutil -lint -s "${PLIST}" || die "Info.plist does not lint"
found_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${PLIST}" 2>/dev/null || true)"
[[ "${found_id}" == "${BUNDLE_ID}" ]] || die "CFBundleIdentifier is '${found_id}', expected ${BUNDLE_ID}"
/usr/libexec/PlistBuddy -c 'Print :CFPlugInFactories' "${PLIST}" 2>/dev/null | grep 'EQTargets_Create' >/dev/null \
    || die "Info.plist has no CFPlugInFactories entry for EQTargets_Create"
[[ -f "${BINARY}" ]] || die "missing executable ${BINARY}"
xcrun nm -gU "${BINARY}" | grep ' _EQTargets_Create$' >/dev/null || die "factory EQTargets_Create is not exported from ${BINARY}"
arch="$(uname -m)"
xcrun lipo -archs "${BINARY}" | tr ' ' '\n' | grep -x "${arch}" >/dev/null \
    || die "binary does not contain ${arch} (has: $(xcrun lipo -archs "${BINARY}"))"
codesign --verify --strict "${SRC}" || die "code signature is invalid — rebuild (ad-hoc signing is fine on this Mac)"

echo "Validated ${SRC}"

# ------------------------------------------------------------------ install (root)
echo "Installing to ${DEST} (sudo) ..."
sudo mkdir -p "${HAL_DIR}"
sudo rm -rf "${DEST}"
sudo cp -R "${SRC}" "${DEST}"
sudo chown -R root:wheel "${DEST}"
# Strip every ACL (cp/ditto keep them: a planted "everyone allow write" ACL
# would leave the root-owned driver writable by any user) and every
# setuid/setgid/sticky bit; no group/world write.
sudo chmod -R -N "${DEST}"
sudo chmod -R a-st,go-w "${DEST}"

# ------------------------------------------------------------------ restart coreaudiod
echo "Restarting coreaudiod (audio drops out for a moment) ..."
if ! sudo launchctl kickstart -k system/com.apple.audio.coreaudiod; then
    echo "launchctl kickstart failed; falling back to killall (launchd relaunches it)" >&2
    sudo killall coreaudiod || true
fi

# ------------------------------------------------------------------ confirm
# eqt-probe --devices exits 0 when EQtargets Audio is present, 3 when it is not.
PROBE="${EQT_PROBE:-$(dirname "${SRC}")/eqt-probe}"
for ((i = 0; i < 20; i++)); do
    sleep 0.5
    if [[ -x "${PROBE}" ]]; then
        if "${PROBE}" --devices >/dev/null 2>&1; then
            "${PROBE}" --devices
            echo "EQtargets Audio is installed and published by coreaudiod."
            exit 0
        fi
    elif system_profiler SPAudioDataType 2>/dev/null | grep "EQtargets Audio" >/dev/null; then
        echo "EQtargets Audio is installed and published by coreaudiod (eqt-probe not found at '${PROBE}')."
        exit 0
    fi
done

[[ -x "${PROBE}" ]] && "${PROBE}" --devices || true
die "EQtargets Audio did not appear within 10 s. Driver log:
  log show --last 2m --predicate 'subsystem == \"${BUNDLE_ID}\"'"
