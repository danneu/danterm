#!/usr/bin/env bash
#
# Build GhosttyKit XCFramework from Ghostty source.
#
# Uses nix to get the correct zig version.
# Clones/fetches Ghostty at the pinned tag, builds the XCFramework,
# and copies it into lib/ for the Swift app to link against.
#
# Requirements:
#   - nix (for zig via nixpkgs)
#   - Xcode
#
# Output: lib/GhosttyKit.xcframework/
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION_FILE="${GHOSTTY_VERSION_FILE:-$SCRIPT_DIR/.ghostty-version}"
GHOSTTY_TAG="$(GHOSTTY_VERSION_FILE="$VERSION_FILE" "$SCRIPT_DIR/scripts/load-ghostty-version.sh")"
ZIG_PKG="nixpkgs#zig_0_15"  # Ghostty v1.3.x requires Zig 0.15.x
GHOSTTY_REPO="https://github.com/ghostty-org/ghostty.git"
CACHE_DIR="${GHOSTTY_CACHE_DIR:-$SCRIPT_DIR/.ghostty-src}"
LIB_DIR="$SCRIPT_DIR/lib"

usage() {
    cat >&2 <<EOF
Usage: ./build-lib.sh [fetch|build|all]

  fetch  clone or update Ghostty source at the pinned tag
  build  build GhosttyKit from existing source after checking the tag
  all    fetch, then build (default)
EOF
}

ghostty_tag_at_cache() {
    git -C "$CACHE_DIR" describe --tags --exact-match 2>/dev/null || printf 'unknown'
}

fetch_ghostty() {
    if [ -d "$CACHE_DIR/.git" ]; then
        echo "Ghostty source exists at $CACHE_DIR"
        current_tag="$(ghostty_tag_at_cache)"
        if [ "$current_tag" != "$GHOSTTY_TAG" ]; then
            echo "Fetching $GHOSTTY_TAG..."
            git -C "$CACHE_DIR" fetch --tags --depth 1 origin "$GHOSTTY_TAG"
            git -C "$CACHE_DIR" checkout "$GHOSTTY_TAG"
        fi
    elif [ -e "$CACHE_DIR" ]; then
        echo "Error: $CACHE_DIR exists but is not a git checkout" >&2
        exit 1
    else
        echo "Cloning Ghostty source (shallow)..."
        git clone --depth 1 --branch "$GHOSTTY_TAG" "$GHOSTTY_REPO" "$CACHE_DIR"
    fi
    echo "Ghostty $(ghostty_tag_at_cache)"
}

stale_source_error() {
    local actual="$1"
    echo "Error: run \`./build-lib.sh fetch\` (or \`./build-lib.sh all\`) -- .ghostty-src/ is at \`$actual\` but .ghostty-version requires \`$GHOSTTY_TAG\`" >&2
}

build_xcframework() {
    if [ ! -d "$CACHE_DIR/.git" ]; then
        echo "Error: missing source at $CACHE_DIR" >&2
        stale_source_error "missing"
        exit 1
    fi

    current_tag="$(ghostty_tag_at_cache)"
    if [ "$current_tag" != "$GHOSTTY_TAG" ]; then
        stale_source_error "$current_tag"
        exit 1
    fi

    echo "Ghostty $current_tag"

    # Ensure Metal toolchain is available (idempotent; no-op if already installed).
    echo "Ensuring Metal toolchain is installed..."
    xcodebuild -downloadComponent MetalToolchain

    echo "Building GhosttyKit XCFramework (this may take several minutes)..."
    (
        cd "$CACHE_DIR"
        nix shell "$ZIG_PKG" nixpkgs#gettext --command zig build \
            -Demit-xcframework \
            -Demit-macos-app=false \
            -Dsentry=false \
            -Doptimize=ReleaseFast
    )

    # XCFramework is emitted to macos/ rather than zig-out/.
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
}

case "${1:-all}" in
    fetch)
        fetch_ghostty
        ;;
    build)
        build_xcframework
        ;;
    all)
        fetch_ghostty
        build_xcframework
        ;;
    *)
        usage
        exit 2
        ;;
esac
