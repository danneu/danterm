#!/usr/bin/env bash
#
# Compile an Icon Composer .icon document into .icns + Assets.car.
# Uses actool to preserve Icon Composer effects (glass, shadow, translucency).
#
# Usage: ./build-icns.sh [IconName]  (default: AppIcon)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NAME="${1:-AppIcon}"
ICON="$SCRIPT_DIR/$NAME.icon"
OUT="$SCRIPT_DIR/$NAME"
ACTOOL=/Applications/Xcode.app/Contents/Developer/usr/bin/actool

mkdir -p "$OUT"

$ACTOOL "$ICON" --app-icon "$NAME" \
    --compile "$OUT" \
    --output-partial-info-plist /dev/null \
    --minimum-deployment-target 26.0 --platform macosx --target-device mac

echo "Built: $OUT/$NAME.icns + $OUT/Assets.car"
