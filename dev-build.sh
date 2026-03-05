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

# Find the macOS slice of the xcframework
MACOS_DIR="$LIB_DIR/GhosttyKit.xcframework/macos-arm64_x86_64"
if [ ! -d "$MACOS_DIR" ]; then
    MACOS_DIR="$LIB_DIR/GhosttyKit.xcframework/macos-arm64"
fi
if [ ! -d "$MACOS_DIR" ]; then
    echo "Error: Could not find macOS slice in XCFramework"
    ls "$LIB_DIR/GhosttyKit.xcframework/"
    exit 1
fi

# Read Swift source files from canonical list
SWIFT_FILES=()
while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    SWIFT_FILES+=("$SCRIPT_DIR/$line")
done < "$SCRIPT_DIR/swift-sources.txt"

# Build app bundle
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"

echo "Compiling..."
xcrun swiftc -O \
    -o "$APP_PATH/Contents/MacOS/DanTerm Dev" \
    "${SWIFT_FILES[@]}" \
    -I "$MACOS_DIR/Headers" \
    -Xcc -fmodule-map-file="$MACOS_DIR/Headers/module.modulemap" \
    "$MACOS_DIR/libghostty.a" \
    -framework Cocoa \
    -framework Metal \
    -framework MetalKit \
    -framework QuartzCore \
    -framework CoreText \
    -framework IOKit \
    -framework IOSurface \
    -framework Carbon \
    -framework UniformTypeIdentifiers \
    -lc++

cp "$SRC_DIR/Info.plist" "$APP_PATH/Contents/"
mkdir -p "$APP_PATH/Contents/Resources"
cp "$SCRIPT_DIR/icon/AppIcon-dev/AppIcon-dev.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
cp "$SCRIPT_DIR/icon/AppIcon-dev/Assets.car" "$APP_PATH/Contents/Resources/"

# Patch Info.plist for dev build
plutil -replace CFBundleIdentifier -string "com.danneu.danterm-dev" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleName -string "DanTerm Dev" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "DanTerm Dev" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleExecutable -string "DanTerm Dev" "$APP_PATH/Contents/Info.plist"

codesign --force --deep --sign - "$APP_PATH"

# Install the freshly built app so launchers using ~/Applications are in sync.
mkdir -p "$HOME/Applications"
rm -rf "$INSTALL_APP"
cp -R "$APP_PATH" "$INSTALL_APP"

echo "Built: $APP_PATH"
echo "Installed: $INSTALL_APP"
