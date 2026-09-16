#!/bin/zsh
# Packages build/UsageBar.app into a verified, checksummed disk image.
# Usage: scripts/build-dmg.sh            -> build/UsageBar-<version>-<date>-<arch>.dmg (+ .sha256)
# Env:   VERSION (defaults to the app bundle's CFBundleShortVersionString), DATE (defaults to today)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/UsageBar.app"
[[ -d "$APP" ]] || { echo "missing $APP — run scripts/build-app.sh first"; exit 1; }
VERSION="${VERSION:-$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleShortVersionString)}"
ARCH="$(lipo -archs "$APP/Contents/MacOS/UsageBar" | tr ' ' '-')"
[[ "$ARCH" == "x86_64-arm64" || "$ARCH" == "arm64-x86_64" ]] && ARCH="universal"
NAME="UsageBar-${VERSION}-${DATE:-$(date +%F)}-${ARCH}"
STAGE="build/.dmg-staging"
DMG="build/${NAME}.dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname UsageBar -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
hdiutil verify "$DMG" >/dev/null
(cd build && shasum -a 256 "${NAME}.dmg" > "${NAME}.dmg.sha256")

MOUNT="$(hdiutil attach -nobrowse -readonly "$DMG" | awk -F'\t' '/Volumes/{print $NF}')"
trap 'hdiutil detach "$MOUNT" -quiet || true' EXIT
codesign --verify --deep --strict "$MOUNT/UsageBar.app"
echo "built $DMG ($ARCH, $(cut -d' ' -f1 "build/${NAME}.dmg.sha256"))"
echo "dmg=$DMG" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "name=$NAME" >> "${GITHUB_OUTPUT:-/dev/null}"
