#!/bin/bash
# Builds "Desktop Drawer.app" into ./build. Requires Xcode command line tools (macOS 14+).
set -euo pipefail
cd "$(dirname "$0")"

# Universal binary: runs on Apple silicon and Intel Macs.
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/DesktopDrawer"

APP="build/Desktop Drawer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DesktopDrawer"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature gives the app a stable identity for the Finder-automation permission prompt.
codesign --force --sign - "$APP"

echo "Built: $APP"
echo "Run:   open \"$APP\""
