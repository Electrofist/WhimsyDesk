#!/usr/bin/env bash
# Builds "build/__APP_NAME__.app". Usage: ./build.sh [run]
set -euo pipefail
cd "$(dirname "$0")"

EXEC="__EXEC__"
APP="build/__APP_NAME__.app"

echo "==> swift build (release)"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/$EXEC"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXEC"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Art/*.png "$APP/Contents/Resources/"
if [[ -f Art/AppIcon.icns ]]; then
    cp Art/AppIcon.icns "$APP/Contents/Resources/"
fi
cp object.json "$APP/Contents/Resources/"
if compgen -G "Sounds/*.wav" >/dev/null; then
    cp Sounds/*.wav "$APP/Contents/Resources/"
fi

echo "==> ad-hoc codesign"
codesign --force --sign - "$APP"

echo "Built $APP"
if [[ "${1:-}" == "run" ]]; then
    open "$APP"
fi
