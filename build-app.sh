#!/usr/bin/env bash
#
# Canonical release build: SwiftPM compile + app bundle assembly.
# Called by CI and release workflows. Does NOT sign or notarize.
#
# Usage: ./build-app.sh [--version VERSION]
#   --version VERSION   Stamp CFBundleVersion and CFBundleShortVersionString
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Verify XCFramework exists
if [ ! -d "$SCRIPT_DIR/lib/GhosttyKit.xcframework" ]; then
    echo "Error: GhosttyKit.xcframework not found. Run ./build-lib.sh first."
    exit 1
fi

# Compile with SwiftPM (release mode, optimized)
echo "Compiling (release)..."
swift build --package-path "$SCRIPT_DIR" --build-path "$SCRIPT_DIR/.spm-build" --configuration release
BIN_PATH=$(swift build --package-path "$SCRIPT_DIR" --build-path "$SCRIPT_DIR/.spm-build" --configuration release --show-bin-path)

# Assemble app bundle
APP_PATH="$SCRIPT_DIR/build/DanTerm.app"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
cp "$BIN_PATH/DanTerm" "$APP_PATH/Contents/MacOS/DanTerm"
mkdir -p "$APP_PATH/Contents/Helpers"
cp "$BIN_PATH/DanTermCLI" "$APP_PATH/Contents/Helpers/danterm"
chmod +x "$APP_PATH/Contents/Helpers/danterm"

# Defense in depth. A case-insensitive filesystem can collapse paths
# that differ only by case, and a copy-source mistake can write the CLI
# bytes into both files. Either produces a signed bundle that will not launch.
GUI="$APP_PATH/Contents/MacOS/DanTerm"
CLI="$APP_PATH/Contents/Helpers/danterm"
GUI_INODE=$(stat -f %i "$GUI")
CLI_INODE=$(stat -f %i "$CLI")
if [ "$GUI_INODE" = "$CLI_INODE" ]; then
    echo "Error: GUI and CLI bundle paths collided (same inode)" >&2
    exit 1
fi
if cmp -s "$GUI" "$CLI"; then
    echo "Error: GUI and CLI bundle binaries have identical content" >&2
    exit 1
fi

cp "$SCRIPT_DIR/app/Info.plist" "$APP_PATH/Contents/"

if [ -n "$VERSION" ]; then
    plutil -replace CFBundleVersion -string "$VERSION" "$APP_PATH/Contents/Info.plist"
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP_PATH/Contents/Info.plist"
fi

mkdir -p "$APP_PATH/Contents/Resources"
cp "$SCRIPT_DIR/icon/AppIcon/Assets.car" "$APP_PATH/Contents/Resources/"

# Bundle ghostty themes (CI caches to lib/ghostty-themes; local builds have .ghostty-src)
THEMES_SRC="$SCRIPT_DIR/lib/ghostty-themes"
if [ ! -d "$THEMES_SRC" ]; then
    THEMES_SRC="$SCRIPT_DIR/.ghostty-src/zig-out/share/ghostty/themes"
fi
mkdir -p "$APP_PATH/Contents/Resources/ghostty"
cp -R "$THEMES_SRC" "$APP_PATH/Contents/Resources/ghostty/themes"

THEME_COUNT=$(ls "$APP_PATH/Contents/Resources/ghostty/themes" | wc -l | tr -d ' ')
echo "Bundled $THEME_COUNT themes"
if [ "$THEME_COUNT" -eq 0 ]; then
    echo "Error: no themes bundled"
    exit 1
fi

echo "Built: $APP_PATH"
