#!/usr/bin/env bash
# Prints the notes for the "downloads" release: one friendly page listing every object
# that has a download, with direct links. Run by the release workflow after each release.
# Needs: gh (logged in), jq. Optional: NOTARIZED=yes to drop the first-launch steps.
set -euo pipefail
cd "$(dirname "$0")/../.."

REPO="${GITHUB_REPOSITORY:-Electrofist/desktop-objects}"
RAW="https://raw.githubusercontent.com/$REPO/main"
ASSETS="$(gh api "repos/$REPO/releases/tags/downloads" --jq '.assets')"

echo "**Pick an object, download it, drag it into Applications.** Free and open source, for Mac (macOS 14 or later)."
echo

for card in objects/*/object.json; do
    dir="$(dirname "$card")"
    name="$(jq -r .name "$card")"
    file="$(echo "$name" | tr ' ' '-').dmg"
    asset="$(echo "$ASSETS" | jq -c --arg f "$file" '.[] | select(.name == $f)')"
    [[ -n "$asset" ]] || continue

    url="$(echo "$asset" | jq -r .browser_download_url)"
    label="$(echo "$asset" | jq -r '.label // ""')"
    size="$(echo "$asset" | jq -r '(.size / 1048576 | ceil | tostring) + " MB"')"
    shot="$(jq -r '.screenshots[0] // empty' "$card")"

    echo "### $name"
    echo
    if [[ -n "$shot" ]]; then
        # Wide pictures (like the drawer front) get a width; tall ones a height.
        size_attr='height="180"'
        if [[ -f "$dir/$shot" ]]; then
            w="$(sips -g pixelWidth "$dir/$shot" | awk '/pixelWidth/ {print $2}')"
            h="$(sips -g pixelHeight "$dir/$shot" | awk '/pixelHeight/ {print $2}')"
            if (( w > h * 2 )); then size_attr='width="480"'; fi
        fi
        echo "<img src=\"$RAW/$dir/$shot\" alt=\"$name\" $size_attr>"
        echo
    fi
    echo "$(jq -r .tagline "$card")"
    echo
    echo "**[Download $name]($url)** &nbsp;·&nbsp; $size${label:+ &nbsp;·&nbsp; $label}"
    echo
done

cat <<EOF
## How to install

1. Click a **Download** link above.
2. Open the downloaded file. A window opens.
3. Drag the app onto the **Applications** folder in that window.
4. Open your **Applications** folder and double-click the app. It appears on your desktop, not in the Dock.

EOF

if [[ "${NOTARIZED:-no}" != "yes" ]]; then
cat <<EOF
## If macOS says it cannot be opened

This is normal the first time. The apps are safe and open source, but not registered with Apple yet.

1. Click **Done** on the message.
2. Open **System Settings** (the gear icon in the Dock or the Apple menu), then click **Privacy & Security** in the sidebar.
3. Scroll down to the message about the app and click **Open Anyway**.
4. Click **Open Anyway** once more and enter your Mac password if asked.

You only need to do this once per object.

EOF
fi

cat <<EOF
## Good to know

- Right-click an object any time to quit it or open its folder.
- **Start it automatically:** System Settings, General, Login Items, click **+** and choose the app.
- **Remove it:** quit it, then drag the app from Applications to the Trash. Your files stay in their folder.
- Nothing is uploaded anywhere. Files are moved into a normal folder in your home folder.
- Questions: [FAQ](https://github.com/$REPO/blob/main/docs/faq.md). Want to make your own object? [Here is how](https://github.com/$REPO/blob/main/docs/make-your-own.md).

<sub>These links always give the newest version. Older versions and checksums are on the [releases page](https://github.com/$REPO/releases).</sub>
EOF
