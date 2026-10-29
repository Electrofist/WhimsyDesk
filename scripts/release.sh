#!/usr/bin/env bash
# Builds one object and packages it for download.
#
# Usage: scripts/release.sh <id>          for example: scripts/release.sh fridge
#
# Writes:
#   dist/<Name>-<version>.dmg / .zip / .sha256    the downloads
#   dist-notes.md                                 release notes for people, not developers
#   dist-meta.env                                 NAME, VERSION, BASE, APP_FILE, RUNS_ON, SIZE_MB
#
# The DMG opens as a "drag into Applications" window, laid out by Finder.
# Set PLAIN_DMG=1 to skip that (or it falls back by itself if Finder cannot be scripted).
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
BUILD_COMMAND="$(card .build.command)"
APP_PATH="$DIR/$(card .build.app)"
APP_NAME="$(basename "$APP_PATH")"
PLIST="$APP_PATH/Contents/Info.plist"
APP_FILE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$PLIST" 2>/dev/null ||
            /usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$PLIST" 2>/dev/null ||
            echo "${APP_NAME%.app}")"                    # friendly name people see, e.g. "Desktop Fridge"
BASE="$(echo "$NAME" | tr ' ' '-')-$VERSION"            # Desktop-Fridge-1.0

echo "==> building $NAME $VERSION"
(cd "$DIR" && bash -c "$BUILD_COMMAND")
[[ -d "$APP_PATH" ]] || { echo "Build did not produce $APP_PATH"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/app"
# Ship the app under its friendly name. Only the folder name changes; the app inside is untouched.
APP_NAME="$APP_FILE.app"
cp -R "$APP_PATH" "$WORK/app/$APP_NAME"
APP="$WORK/app/$APP_NAME"

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
        ditto -c -k --keepParent "$APP" "$WORK/notarize.zip"
        xcrun notarytool submit "$WORK/notarize.zip" --wait \
            --apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$APPLE_TEAM_ID"
        xcrun stapler staple "$APP"
        rm "$WORK/notarize.zip"
        NOTARIZED=yes
    fi
fi

echo "==> packaging"
rm -rf dist
mkdir -p dist
DMG="dist/$BASE.dmg"
ditto -c -k --keepParent "$APP" "dist/$BASE.zip"

styled=no
if [[ "${PLAIN_DMG:-}" != "1" ]]; then
    # A writable image that Finder lays out, then compressed.
    swift scripts/release/dmg-background.swift "$NAME" "$APP_FILE" "$WORK/background.tiff"
    APP_MB="$(du -sm "$APP" | cut -f1)"
    hdiutil create -quiet -srcfolder "$WORK/app" -volname "$NAME" -fs HFS+ -format UDRW \
        -size "$((APP_MB + 20))m" "$WORK/rw.dmg"
    MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$WORK/rw.dmg" | grep -o '/Volumes/.*$' | head -1)"
    VOLUME="$(basename "$MOUNT")"
    mkdir "$MOUNT/.background"
    cp "$WORK/background.tiff" "$MOUNT/.background/background.tiff"
    ln -s /Applications "$MOUNT/Applications"
    # Finder sets the background, icon size and the two icon positions.
    # Allow 60 seconds; if Finder cannot be scripted here, fall back to a plain DMG.
    osascript > "$WORK/finder.log" 2>&1 <<APPLESCRIPT &
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        try
            set pathbar visible of container window to false
        end try
        set the bounds of container window to {200, 120, 860, 548}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "$APP_NAME" of container window to {165, 190}
        set position of item "Applications" of container window to {495, 190}
        set extension hidden of item "$APP_NAME" to true
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT
    LAYOUT_PID=$!
    for _ in $(seq 60); do kill -0 "$LAYOUT_PID" 2>/dev/null || break; sleep 1; done
    if kill -0 "$LAYOUT_PID" 2>/dev/null; then
        kill "$LAYOUT_PID" 2>/dev/null || true
        echo "Finder layout timed out; making a plain DMG instead"
    elif wait "$LAYOUT_PID"; then
        styled=yes
    else
        echo "Finder layout failed: $(cat "$WORK/finder.log"). Making a plain DMG instead."
    fi
    sync
    hdiutil detach -quiet "$MOUNT" || hdiutil detach -quiet -force "$MOUNT"
    if [[ "$styled" == "yes" ]]; then
        hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG"
    fi
fi
if [[ "$styled" == "no" ]]; then
    ln -s /Applications "$WORK/app/Applications"
    hdiutil create -quiet -volname "$NAME" -srcfolder "$WORK/app" -ov -format UDZO "$DMG"
    rm "$WORK/app/Applications"
fi
if [[ "$SIGNED" == "yes" ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
(cd dist && shasum -a 256 "$BASE.dmg" "$BASE.zip" > "$BASE.sha256")

EXEC="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/$EXEC")"
case "$ARCHS" in
    *arm64*x86_64*|*x86_64*arm64*) RUNS_ON="any Mac with Apple silicon or Intel" ;;
    *arm64*) RUNS_ON="Macs with Apple silicon (M1 or newer)" ;;
    *) RUNS_ON="Intel Macs" ;;
esac
SIZE_MB="$(du -m "$DMG" | cut -f1)"

{
    echo "**$TAGLINE**"
    echo
    echo "## How to install"
    echo
    echo "1. Under **Assets** below, click **$BASE.dmg** to download it ($SIZE_MB MB)."
    echo "2. Open the downloaded file. A window opens."
    echo "3. Drag **$APP_FILE** onto the **Applications** folder in that window."
    echo "4. Open your **Applications** folder and double-click **$APP_FILE**."
    echo
    echo "$NAME appears on your desktop, not in the Dock. Right-click it any time to quit."
    echo
    if [[ "$NOTARIZED" == "no" ]]; then
        echo "## If macOS says it cannot be opened"
        echo
        echo "This is normal the first time. The app is safe and open source, but it is not registered with Apple yet."
        echo
        echo "1. Click **Done** on the message."
        echo "2. Open **System Settings** (the gear icon in the Dock or the Apple menu), then click **Privacy & Security** in the sidebar."
        echo "3. Scroll down to the message about **$APP_FILE** and click **Open Anyway**."
        echo "4. Click **Open Anyway** once more and enter your Mac password if asked."
        echo
        echo "You only need to do this once."
        echo
    fi
    echo "## Good to know"
    echo
    echo "- Works on $RUNS_ON with macOS $MIN_MACOS or later."
    echo "- Files you drop in are moved to \`$STORES\`. Nothing is uploaded anywhere."
    echo "- **Start it automatically:** System Settings, General, Login Items, click **+** and choose $APP_FILE."
    echo "- **Remove it:** right-click it and quit, then drag $APP_FILE from Applications to the Trash. Your files stay in \`$STORES\`."
    echo
    echo "<sub>Signed: $SIGNED. Notarized by Apple: $NOTARIZED. SHA-256 checksums: $BASE.sha256. Developers: the zip holds the same app.</sub>"
} > dist-notes.md

{
    echo "NAME=\"$NAME\""
    echo "VERSION=\"$VERSION\""
    echo "BASE=\"$BASE\""
    echo "APP_FILE=\"$APP_FILE\""
    echo "RUNS_ON=\"$RUNS_ON\""
    echo "SIZE_MB=\"$SIZE_MB\""
    echo "NOTARIZED=\"$NOTARIZED\""
} > dist-meta.env

echo
echo "Done:"
ls -1 dist
echo "Runs on $RUNS_ON. Styled DMG: $styled. Signed: $SIGNED. Notarized: $NOTARIZED."
