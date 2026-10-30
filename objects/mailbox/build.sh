#!/usr/bin/env bash
# Builds "build/Desktop Mailbox.app" for Apple silicon and Intel. Usage: ./build.sh [run]
set -euo pipefail
cd "$(dirname "$0")"

EXEC="DesktopMailbox"
APP="build/Desktop Mailbox.app"

echo "==> swift build (release, universal)"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$EXEC"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXEC"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Resources/letters.json "$APP/Contents/Resources/"
if compgen -G "Resources/Letters/*.json" >/dev/null; then
    mkdir -p "$APP/Contents/Resources/Letters"
    cp Resources/Letters/*.json "$APP/Contents/Resources/Letters/"
fi
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
