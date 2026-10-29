#!/usr/bin/env bash
# Builds one object and packages it for download: a DMG, a zip and checksums in dist/,
# plus release notes in dist-notes.md.
#
# Usage: scripts/release.sh <id>          for example: scripts/release.sh fridge
#
# Optional signing (otherwise the app keeps the ad-hoc signature from its build script):
#   SIGN_IDENTITY       "Developer ID Application: Name (TEAMID)", already in the keychain
# Optional notarization (needs SIGN_IDENTITY too):
#   APPLE_ID, APPLE_APP_PASSWORD, APPLE_TEAM_ID
set -euo pipefail
cd "$(dirname "$0")/.."

ID="${1:-}"
DIR="objects/$ID"
if [[ -z "$ID" || ! -f "$DIR/object.json" ]]; then
    echo "Usage: scripts/release.sh <id>   (one of: $(ls objects | tr '\n' ' '))"
    exit 1
fi

card() { jq -r "$1" "$DIR/object.json"; }
NAME="$(card .name)"
VERSION="$(card .version)"
TAGLINE="$(card .tagline)"
MIN_MACOS="$(card .minMacOS)"
STORES="$(card .storesFilesIn)"
APP_PATH="$DIR/$(card .build.app)"
APP_NAME="$(basename "$APP_PATH")"
BASE="$(echo "$NAME" | tr ' ' '-')-$VERSION"          # Desktop-Fridge-1.0

BUILD_COMMAND="$(card .build.command)"

echo "==> building $NAME $VERSION"
(cd "$DIR" && bash -c "$BUILD_COMMAND")
[[ -d "$APP_PATH" ]] || { echo "Build did not produce $APP_PATH"; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP_PATH" "$STAGE/"
APP="$STAGE/$APP_NAME"

SIGNED=no
NOTARIZED=no
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    echo "==> signing with $SIGN_IDENTITY"
    codesign --force --options runtime --timestamp \
        --entitlements scripts/release/entitlements.plist \
        --sign "$SIGN_IDENTITY" "$APP"
    SIGNED=yes
    if [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
        echo "==> notarizing (this can take a few minutes)"
        ditto -c -k --keepParent "$APP" "$STAGE/notarize.zip"
        xcrun notarytool submit "$STAGE/notarize.zip" --wait \
            --apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$APPLE_TEAM_ID"
        xcrun stapler staple "$APP"
        rm "$STAGE/notarize.zip"
        NOTARIZED=yes
    fi
fi

echo "==> packaging"
rm -rf dist
mkdir -p dist
ditto -c -k --keepParent "$APP" "dist/$BASE.zip"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "dist/$BASE.dmg"
(cd dist && shasum -a 256 "$BASE.dmg" "$BASE.zip" > "$BASE.sha256")

EXEC="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/$EXEC")"
case "$ARCHS" in
    *arm64*x86_64*|*x86_64*arm64*) RUNS_ON="Apple silicon and Intel Macs" ;;
    *arm64*) RUNS_ON="Apple silicon Macs (M1 and later)" ;;
    *) RUNS_ON="Intel Macs" ;;
esac

{
    echo "**$TAGLINE**"
    echo
    echo "## Install"
    echo
    echo "1. Download **$BASE.dmg** below."
    echo "2. Open it and drag **${APP_NAME%.app}** into **Applications**."
    echo "3. Open ${APP_NAME%.app} from Applications. $NAME appears on your desktop, not in the Dock. Right-click it to quit."
    echo
    if [[ "$NOTARIZED" == "no" ]]; then
        echo "> [!IMPORTANT]"
        echo "> This build is not notarized by Apple yet, so macOS blocks the first launch. To open it:"
        echo "> 1. Try to open it once and click **Done** on the warning."
        echo "> 2. Open **System Settings**, then **Privacy & Security**."
        echo "> 3. Scroll down and click **Open Anyway** next to $NAME, then confirm."
        echo ">"
        echo "> You only do this once. The source is all in this repo if you would rather build it yourself."
        echo
    fi
    echo "## Details"
    echo
    echo "- Needs macOS $MIN_MACOS or later. Runs on $RUNS_ON."
    echo "- Stores files in \`$STORES\`."
    echo "- Signed: $SIGNED. Notarized: $NOTARIZED."
    echo "- SHA-256 checksums are in **$BASE.sha256**."
} > dist-notes.md

echo
echo "Done:"
ls -1 dist
echo "Runs on: $RUNS_ON. Signed: $SIGNED. Notarized: $NOTARIZED."
