#!/usr/bin/env bash
# Builds build/DesktopFridge.app from the Swift package.
# Usage: ./build.sh [run]
set -euo pipefail
cd "$(dirname "$0")"

APP="build/DesktopFridge.app"
CONTENTS="$APP/Contents"

echo "==> swift build (release)"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/DesktopFridge"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/DesktopFridge"
cp Support/Info.plist "$CONTENTS/Info.plist"
cp Assets/Sounds/*.wav "$CONTENTS/Resources/"
cp Assets/Door/*.png "$CONTENTS/Resources/"

echo "==> assets"
if xcrun --find actool >/dev/null 2>&1; then
    # Preferred: compiled asset catalog (Assets.car) with 1x and 2x fog frames.
    xcrun actool Assets/Assets.xcassets \
        --compile "$CONTENTS/Resources" \
        --platform macosx \
        --minimum-deployment-target 14.0 \
        --output-format human-readable-text \
        --notices --warnings >/dev/null
    echo "    compiled Assets.xcassets with actool"
else
    # Fallback when only the Command Line Tools are installed: loose PNGs.
    # NSImage(named:) finds fog_00.png and fog_00@2x.png in Resources automatically.
    find Assets/Assets.xcassets -name '*.png' -exec cp {} "$CONTENTS/Resources/" \;
    echo "    actool not found, copied loose PNGs (install Xcode for a real Assets.car)"
fi

echo "==> ad-hoc codesign"
codesign --force --sign - "$APP"

echo "Built $APP"
if [[ "${1:-}" == "run" ]]; then
    open "$APP"
fi

# install: copies the app to ~/Applications and starts it at every login with a LaunchAgent.
# launchd also restarts it if it ever crashes. Choosing Quit from its menu exits cleanly and
# leaves it quit until the next login.
if [[ "${1:-}" == "install" ]]; then
    LABEL="in.krisby.desktopfridge"
    DEST="$HOME/Applications/DesktopFridge.app"
    AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
    DOMAIN="gui/$(id -u)"

    echo "==> installing to $DEST"
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    pkill -x DesktopFridge 2>/dev/null || true
    mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"

    echo "==> login agent $AGENT"
    cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DEST/Contents/MacOS/DesktopFridge</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLIST
    launchctl bootstrap "$DOMAIN" "$AGENT"
    echo "Installed. Desktop Fridge now starts at every login."
fi
