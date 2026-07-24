#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Token Usage Island"
BUNDLE_ID="com.pierre.tokenusageisland"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
BIN_NAME="TokenUsageIsland"

# Version: explicit $VERSION, else the latest git tag (v1.2.3 -> 1.2.3), else a dev marker.
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0-dev}"

echo "▸ Building $APP_NAME $VERSION"
echo "▸ Compiling…"
rm -rf "$BUILD_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O \
  -o "$APP/Contents/MacOS/$BIN_NAME" \
  Sources/Data.swift Sources/IslandView.swift Sources/main.swift \
  -framework AppKit -framework SwiftUI -framework Combine \
  -target arm64-apple-macos14.0

echo "▸ Copying resources…"
cp Resources/* "$APP/Contents/Resources/"

echo "▸ Writing Info.plist…"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$BIN_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "✓ Built: $APP ($VERSION)"
