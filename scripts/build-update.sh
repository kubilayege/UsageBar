#!/bin/zsh
# Package the CI-built app for Sparkle and sign both its archive and release feed.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/UsageBar.app"
TOOLS=".build/artifacts/sparkle/Sparkle/bin"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCH="$(lipo -archs "$APP/Contents/MacOS/UsageBar" | tr ' ' '-')"
NAME="UsageBar-${VERSION}-${ARCH}"
UPDATES="build/sparkle"
[[ -n "${SPARKLE_PRIVATE_KEY:-}" ]] || { echo "SPARKLE_PRIVATE_KEY is required to sign updates"; exit 1; }
[[ ! -e "$UPDATES" ]] || { echo "$UPDATES already exists; use a fresh build directory"; exit 1; }
mkdir -p "$UPDATES"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$UPDATES/${NAME}.zip"
printf '%s\n' "${NOTES:-UsageBar ${VERSION}}" > "$UPDATES/${NAME}.md"
# Send the private key through stdin; never put it in command arguments or release files.
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$TOOLS/generate_appcast" --ed-key-file - \
  --maximum-deltas 0 --embed-release-notes \
  --download-url-prefix "https://github.com/kubilayege/UsageBar/releases/download/v${VERSION}/" \
  --link "https://github.com/kubilayege/UsageBar/releases/tag/v${VERSION}" "$UPDATES"
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$TOOLS/sign_update" --ed-key-file - --verify "$UPDATES/appcast.xml"
swift scripts/verify-update.swift "$UPDATES/appcast.xml" "$UPDATES/${NAME}.zip" scripts/sparkle-public-key.txt "$VERSION"
echo "archive=$UPDATES/${NAME}.zip" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "appcast=$UPDATES/appcast.xml" >> "${GITHUB_OUTPUT:-/dev/null}"
