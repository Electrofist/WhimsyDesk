#!/bin/bash
# Builds "Desktop Drawer.app" into ./build. Requires Xcode command line tools (macOS 14+).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Desktop Drawer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DesktopDrawer "$APP/Contents/MacOS/DesktopDrawer"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature gives the app a stable identity for the Finder-automation permission prompt.
codesign --force --sign - "$APP"

echo "Built: $APP"
echo "Run:   open \"$APP\""
