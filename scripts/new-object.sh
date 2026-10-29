#!/usr/bin/env bash
# Creates a new object from templates/object.
# Usage: scripts/new-object.sh "Air Fryer" [your-github-username]
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="${1:-}"
if [[ -z "$NAME" ]]; then
    echo "Usage: scripts/new-object.sh \"Object Name\" [github-username]"
    echo "Example: scripts/new-object.sh \"Air Fryer\" octocat"
    exit 1
fi
if [[ ! "$NAME" =~ ^[A-Za-z][A-Za-z0-9\ -]*$ ]]; then
    echo "The name can use letters, digits, spaces and hyphens, and must start with a letter."
    exit 1
fi

GITHUB="${2:-$(git config github.user 2>/dev/null || true)}"
GITHUB="${GITHUB:-your-github-username}"
AUTHOR="$(git config user.name 2>/dev/null || true)"
AUTHOR="${AUTHOR:-Your Name}"

ID="$(echo "$NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -s '-')"   # air-fryer
EXEC="Desktop$(echo "$NAME" | tr -cd '[:alnum:]')"                            # DesktopAirFryer
APP_NAME="Desktop $NAME"                                                        # Desktop Air Fryer
FOLDER="$NAME"                                                                  # ~/Desktop Objects/Air Fryer
OWNER="$(echo "$GITHUB" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')"
BUNDLE_ID="io.github.${OWNER:-unknown}.$(echo "$ID" | tr -d '-')"

DEST="objects/$ID"
if [[ -e "$DEST" ]]; then
    echo "$DEST already exists. Pick another name."
    exit 1
fi

cp -R templates/object "$DEST"
mv "$DEST/Sources/__EXEC__" "$DEST/Sources/$EXEC"

# Fill in the placeholders in every text file.
find "$DEST" -type f \( -name '*.swift' -o -name '*.json' -o -name '*.md' -o -name '*.sh' -o -name '*.plist' \) -print0 |
    while IFS= read -r -d '' file; do
        sed -i '' \
            -e "s|__ID__|$ID|g" \
            -e "s|__EXEC__|$EXEC|g" \
            -e "s|__APP_NAME__|$APP_NAME|g" \
            -e "s|__FOLDER__|$FOLDER|g" \
            -e "s|__BUNDLE_ID__|$BUNDLE_ID|g" \
            -e "s|__AUTHOR__|$AUTHOR|g" \
            -e "s|__GITHUB__|$GITHUB|g" \
            "$file"
    done
chmod +x "$DEST/build.sh"

printf '%-19s @%s\n' "/objects/$ID/" "$GITHUB" >> .github/CODEOWNERS

cat <<EOF

Created $DEST ($APP_NAME)

Next:
  1. cd $DEST && ./build.sh run      see it on your desktop
  2. Replace Art/closed.png and Art/open.png with your art
  3. Edit object.json: tagline, description, look.itemsArea
  4. scripts/check-objects.sh        from the repo root
  5. Open a pull request

Full guide: docs/make-your-own.md
EOF
