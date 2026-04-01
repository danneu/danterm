#!/usr/bin/env bash
#
# Build DanTerm Dev locally without nix.
# Assumes build-lib.sh has already been run to produce lib/GhosttyKit.xcframework.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build"
APP_PATH="$BUILD_DIR/DanTerm Dev.app"
INSTALL_APP="$HOME/Applications/DanTerm Dev.app"
SRC_DIR="$SCRIPT_DIR/app"
LIB_DIR="$SCRIPT_DIR/lib"

# Verify XCFramework exists
if [ ! -d "$LIB_DIR/GhosttyKit.xcframework" ]; then
    echo "Error: GhosttyKit.xcframework not found. Run ./build-lib.sh first."
    exit 1
fi

# Build with SwiftPM (incremental — only recompiles changed files).
echo "Compiling..."
swift build --package-path "$SCRIPT_DIR" --build-path "$SCRIPT_DIR/.spm-build"
BIN_PATH=$(swift build --package-path "$SCRIPT_DIR" --build-path "$SCRIPT_DIR/.spm-build" --show-bin-path)

# Build app bundle
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
cp "$BIN_PATH/DanTerm" "$APP_PATH/Contents/MacOS/DanTerm Dev"

cp "$SRC_DIR/Info.plist" "$APP_PATH/Contents/"
mkdir -p "$APP_PATH/Contents/Resources"
cp "$SCRIPT_DIR/icon/AppIcon-dev/Assets.car" "$APP_PATH/Contents/Resources/"

# Bundle all ghostty themes for per-pane theme switching and browsing.
THEMES_SRC="$SCRIPT_DIR/.ghostty-src/zig-out/share/ghostty/themes"
THEMES_DST="$APP_PATH/Contents/Resources/ghostty/themes"
if [ -d "$THEMES_SRC" ]; then
    mkdir -p "$THEMES_DST"
    cp -R "$THEMES_SRC"/* "$THEMES_DST/"
fi

# Patch Info.plist for dev build
plutil -replace CFBundleIdentifier -string "com.danneu.danterm-dev" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleName -string "DanTerm Dev" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "DanTerm Dev" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleExecutable -string "DanTerm Dev" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleIconName -string "AppIcon-dev" "$APP_PATH/Contents/Info.plist"

codesign --force --deep --sign "Apple Development" --entitlements "$SCRIPT_DIR/dev-entitlements.plist" "$APP_PATH"

# Install the freshly built app so launchers using ~/Applications are in sync.
mkdir -p "$HOME/Applications"
rm -rf "$INSTALL_APP"
cp -R "$APP_PATH" "$INSTALL_APP"

# Force macOS to rescan the app bundle so icon changes take effect immediately.
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$INSTALL_APP"

echo "Built: $APP_PATH"
echo "Installed: $INSTALL_APP"
