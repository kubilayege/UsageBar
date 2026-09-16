#!/bin/zsh
# Builds UsageBar in release mode and assembles a proper .app bundle (menu-bar-only, LSUIElement).
# Usage: scripts/build-app.sh [--install]   (--install copies to /Applications and relaunches)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="UsageBar"
BUNDLE_ID="com.kubilay.usagebar"
VERSION="${VERSION:-1.2.0}"
OUT="build/${APP_NAME}.app"
ICON="Sources/UsageBar/Resources/AppLogo.png"
[[ -f "$ICON" ]] || { echo "missing app artwork: $ICON"; exit 1; }

swift build -c release 2>&1 | tail -3
BIN=".build/release/${APP_NAME}"
[[ -x "$BIN" ]] || { echo "build failed: $BIN missing"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/${APP_NAME}"
cp "$ICON" "$OUT/Contents/Resources/AppLogo.png"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Used to open agent sessions in your terminal and request administrator authorization for changing the macOS sleep setting.</string>
  <key>NSHumanReadableCopyright</key><string>Local-only usage tracker. No telemetry.</string>
</dict>
</plist>
PLIST

# Generate every standard macOS icon size from the same artwork used inside the app.
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICON" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ICON" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Ad-hoc sign so the bundle identity is stable for Keychain / notifications.
codesign --force --deep --sign - "$OUT"
codesign --verify --deep --strict "$OUT"
echo "built $OUT"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "$OUT" /Applications/
  open "/Applications/${APP_NAME}.app"
  echo "installed and launched /Applications/${APP_NAME}.app"
fi
