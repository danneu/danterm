#!/usr/bin/env bash
#
# Build GhosttyKit XCFramework from Ghostty source.
#
# Uses nix to get the correct zig version.
# Clones/fetches Ghostty at a pinned tag, builds the XCFramework,
# and copies it into lib/ for the Swift app to link against.
#
# Requirements:
#   - nix (for zig via nixpkgs)
#   - Xcode with Metal toolchain (xcodebuild -downloadComponent MetalToolchain)
#
# Output: lib/GhosttyKit.xcframework/
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GHOSTTY_TAG="v1.2.3"
ZIG_PKG="nixpkgs#zig_0_14"  # Ghostty v1.2.x requires Zig 0.14.x
GHOSTTY_REPO="https://github.com/ghostty-org/ghostty.git"
CACHE_DIR="$SCRIPT_DIR/.ghostty-src"
LIB_DIR="$SCRIPT_DIR/lib"

# Clone or fetch Ghostty source
if [ -d "$CACHE_DIR" ]; then
    echo "Ghostty source exists at $CACHE_DIR"
    cd "$CACHE_DIR"
    # Only fetch if we need a different tag
    CURRENT_TAG=$(git describe --tags --exact-match 2>/dev/null || echo "unknown")
    if [ "$CURRENT_TAG" != "$GHOSTTY_TAG" ]; then
        echo "Fetching $GHOSTTY_TAG..."
        git fetch --tags --depth 1 origin "$GHOSTTY_TAG"
        git checkout "$GHOSTTY_TAG"
    fi
else
    echo "Cloning Ghostty source (shallow)..."
    git clone --depth 1 --branch "$GHOSTTY_TAG" "$GHOSTTY_REPO" "$CACHE_DIR"
    cd "$CACHE_DIR"
fi

echo "Ghostty $(git describe --tags --exact-match 2>/dev/null)"

# Build XCFramework
echo "Building GhosttyKit XCFramework (this may take several minutes)..."
nix shell "$ZIG_PKG" nixpkgs#gettext --command zig build \
    -Demit-xcframework \
    -Demit-macos-app=false \
    -Dsentry=false \
    -Doptimize=ReleaseFast

# Copy output — xcframework is emitted to macos/ not zig-out/
XCFW_SRC="$CACHE_DIR/macos/GhosttyKit.xcframework"
if [ ! -d "$XCFW_SRC" ]; then
    echo "Error: XCFramework not found at $XCFW_SRC"
    echo "Build may have failed or output path may have changed."
    exit 1
fi

echo "Copying XCFramework to $LIB_DIR..."
rm -rf "$LIB_DIR/GhosttyKit.xcframework"
mkdir -p "$LIB_DIR"
cp -R "$XCFW_SRC" "$LIB_DIR/"

echo "Done! GhosttyKit.xcframework is at $LIB_DIR/GhosttyKit.xcframework"
