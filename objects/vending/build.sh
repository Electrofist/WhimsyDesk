#!/usr/bin/env bash
# Builds "build/Desktop Vending Machine.app" for Apple silicon and Intel. Usage: ./build.sh [run]
set -euo pipefail
cd "$(dirname "$0")"

EXEC="DesktopVendingMachine"
APP="build/Desktop Vending Machine.app"

echo "==> swift build (release, universal)"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$EXEC"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXEC"
cp Support/Info.plist "$APP/Contents/Info.plist"
if compgen -G "Resources/Sounds/*.wav" >/dev/null; then
    cp Resources/Sounds/*.wav "$APP/Contents/Resources/"
fi
if compgen -G "Resources/Art/*.png" >/dev/null; then
    mkdir -p "$APP/Contents/Resources/Art"
    cp Resources/Art/*.png "$APP/Contents/Resources/Art/"
fi
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/"
fi

echo "==> ad-hoc codesign"
codesign --force --sign - "$APP"

echo "Built $APP"
if [[ "${1:-}" == "run" ]]; then
    open "$APP"
fi
