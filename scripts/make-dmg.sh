#!/bin/bash
#
# make-dmg.sh — build EQtargets (Release, universal) and package it as a
# drag-to-Applications disk image.
#
#   scripts/make-dmg.sh
#   → build/dist/EQtargets_<version>_universal.dmg (and its SHA-256)
#
# The app (with the driver embedded) is ad-hoc signed, so no Apple account is
# needed. Downloaders approve it once in System Settings → Privacy & Security.
#
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

die() { echo "make-dmg: $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

readonly DERIVED="build/release"
readonly APP="${DERIVED}/Build/Products/Release/EQtargets.app"
readonly DRIVER_BIN="${APP}/Contents/Resources/EQtargetsAudio.driver/Contents/MacOS/EQtargetsAudio"

echo "Building EQtargets (Release)…"
xcodebuild -project EQtargets.xcodeproj -scheme EQtargets -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "${DERIVED}" -quiet build

# ------------------------------------------------------------------ check what ships
[[ -d "${APP}" ]] || die "no app at ${APP}"
[[ -f "${DRIVER_BIN}" ]] || die "the driver is not embedded in the app (${DRIVER_BIN})"
codesign --verify --deep --strict "${APP}" || die "the app's signature does not verify"
for bin in "${APP}/Contents/MacOS/EQtargets" "${DRIVER_BIN}"; do
    archs="$(xcrun lipo -archs "${bin}")"
    [[ " ${archs} " == *" arm64 "* && " ${archs} " == *" x86_64 "* ]] \
        || die "$(basename "${bin}") is not universal (has: ${archs})"
done
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP}/Contents/Info.plist")"
[[ -n "${VERSION}" ]] || die "no CFBundleShortVersionString"

# ------------------------------------------------------------------ package
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
ditto "${APP}" "${STAGE}/EQtargets.app"
ln -s /Applications "${STAGE}/Applications"

mkdir -p build/dist
readonly OUT="build/dist/EQtargets_${VERSION}_universal.dmg"
rm -f "${OUT}"
hdiutil create -quiet -volname "EQtargets ${VERSION}" -srcfolder "${STAGE}" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 "${OUT}"
hdiutil verify -quiet "${OUT}" || die "hdiutil verify failed for ${OUT}"

shasum -a 256 "${OUT}" | tee "${OUT}.sha256"
echo "Done: ${OUT}"
