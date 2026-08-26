#!/usr/bin/env bash
#
# Compile one development slot's icon, or all eight, into .build/icons.
#
# Slot icons are derived, not authored: gen-slot-icon.sh writes each SVG from the
# committed raw-dev.svg. Compiling all eight would add about 13 MB of binary to
# the repository, and another 13 MB of new blobs every time the mark changes, so
# they are built on demand into .build instead and never committed. The slot
# launcher calls this before it stages a bundle.
#
# The build is skipped when the compiled catalog is newer than every input, so
# the common case -- launching a slot whose icon already exists -- costs a stat.
#
# Usage: ./build-slot-icons.sh [slot 1-8]   (no slot: all eight)
#
# Prints the path of each Assets.car it guarantees, one per line. That output is
# the contract: callers read the path from here rather than rebuilding it.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
OUT_ROOT="$REPO_DIR/.build/icons"
ACTOOL=/Applications/Xcode.app/Contents/Developer/usr/bin/actool
TEMPLATE="$SCRIPT_DIR/AppIcon-dev.icon/icon.json"

if [[ $# -gt 1 ]]; then
    echo "build-slot-icons: usage: build-slot-icons.sh [slot 1-8]" >&2
    exit 2
fi
if [[ $# -eq 1 ]]; then
    [[ "$1" =~ ^[1-8]$ ]] || { echo "build-slot-icons: slot must be 1 through 8, got '$1'" >&2; exit 2; }
    slots=("$1")
else
    slots=(1 2 3 4 5 6 7 8)
fi

for slot in "${slots[@]}"; do
    name="AppIcon-dev-$slot"
    catalog="$OUT_ROOT/$name/Assets.car"

    # Rebuild when any input is newer than the product, or the product is missing.
    stale=0
    [[ -f "$catalog" ]] || stale=1
    for input in "$SCRIPT_DIR/raw-dev.svg" "$SCRIPT_DIR/gen-slot-icon.sh" \
                 "$SCRIPT_DIR/build-slot-icons.sh" "$TEMPLATE"; do
        [[ "$input" -nt "$catalog" ]] && stale=1
    done

    if [[ "$stale" -eq 1 ]]; then
        [[ -x "$ACTOOL" ]] || {
            echo "build-slot-icons: needs Xcode's actool at $ACTOOL" >&2
            exit 1
        }
        document="$OUT_ROOT/$name.icon"
        rm -rf "$document" "$OUT_ROOT/$name"
        mkdir -p "$document/Assets" "$OUT_ROOT/$name"
        "$SCRIPT_DIR/gen-slot-icon.sh" "$slot" "$document/Assets/raw-dev-$slot.svg" >/dev/null
        # The document is the committed dev icon's, with its one layer pointed at
        # this slot's artwork -- so a change to that document reaches all nine.
        sed "s|raw-dev\.svg|raw-dev-$slot.svg|g; s|\"name\" : \"raw-dev\"|\"name\" : \"raw-dev-$slot\"|" \
            "$TEMPLATE" > "$document/icon.json"
        "$ACTOOL" "$document" --app-icon "$name" \
            --compile "$OUT_ROOT/$name" \
            --output-partial-info-plist /dev/null \
            --minimum-deployment-target 26.0 --platform macosx --target-device mac >/dev/null
        rm -f "$OUT_ROOT/$name/$name.icns"
    fi

    [[ -f "$catalog" ]] || { echo "build-slot-icons: $ACTOOL produced no $catalog" >&2; exit 1; }
    echo "$catalog"
done
