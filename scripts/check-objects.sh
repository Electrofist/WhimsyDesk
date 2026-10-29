#!/usr/bin/env bash
# Checks every objects/<id>/object.json. Run from anywhere: scripts/check-objects.sh
# Needs jq (built into macOS 15 and later; `brew install jq` otherwise).
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
err() { echo "  x $1"; fail=1; }

for dir in objects/*/; do
    id="$(basename "$dir")"
    manifest="$dir/object.json"
    echo "$id"

    if [[ ! -f "$manifest" ]]; then err "missing object.json"; continue; fi
    if ! jq empty "$manifest" 2>/dev/null; then err "object.json is not valid JSON"; continue; fi

    get() { jq -r "$1 // empty" "$manifest"; }

    for field in .id .name .tagline .description .author.name .version .minMacOS .license .build.command .build.app; do
        [[ -n "$(get "$field")" ]] || err "missing $field"
    done

    [[ "$(get .id)" == "$id" ]] || err "id \"$(get .id)\" must equal the folder name \"$id\""
    [[ "$id" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || err "folder name must be lowercase letters, digits and hyphens"
    [[ "$(get .version)" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || err "version must look like 1.0 or 1.0.0"
    [[ "$(get .minMacOS)" =~ ^1[4-9](\.[0-9]+)?$|^[2-9][0-9](\.[0-9]+)?$ ]] || err "minMacOS must be 14.0 or later"
    [[ "$(get .tagline | wc -c)" -le 101 ]] || err "tagline must be 100 characters or fewer"
    [[ "$(get .tagline)" != "Write one line about your object here." ]] || err "write your own tagline"
    [[ "$(get .description)" != Write\ a\ few\ sentences* ]] || err "write your own description"

    if [[ "$(jq 'has("look") and (.look | has("itemsArea"))' "$manifest")" == "true" ]]; then
        jq -e '.look.itemsArea | type == "array" and length == 4 and all(.[]; type == "number" and . >= 0 and . <= 1)' \
            "$manifest" >/dev/null || err "look.itemsArea must be four numbers from 0 to 1"
    fi

    script="$(get .build.command | awk '{print $NF}')"
    [[ -f "$dir/$script" ]] || err "build script \"$script\" not found"

    for shot in $(jq -r '.screenshots[]? // empty' "$manifest"); do
        [[ -f "$dir/$shot" ]] || err "screenshot \"$shot\" not found"
    done
done

if [[ $fail -ne 0 ]]; then
    echo "Some objects need fixing."
    exit 1
fi
echo "All objects look good."
