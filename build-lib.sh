#!/usr/bin/env bash
#
# Build GhosttyKit XCFramework from Ghostty source.
#
# Uses nix to get the correct zig version.
# Clones/fetches Ghostty at the pinned tag, builds the XCFramework,
# and copies it (plus the bundled themes) into lib/ for the Swift app.
#
# Requirements:
#   - nix (zig from this repo's flake -- see ZIG_PKG; gettext from nixpkgs)
#   - Xcode
#
# Output: lib/GhosttyKit.xcframework/ and lib/ghostty-themes/
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION_FILE="${GHOSTTY_VERSION_FILE:-$SCRIPT_DIR/.ghostty-version}"
GHOSTTY_TAG="$(GHOSTTY_VERSION_FILE="$VERSION_FILE" "$SCRIPT_DIR/scripts/load-ghostty-version.sh")"
# Pull zig from this repo's flake -- it carries a patch for
# macOS 26.4+ SDK compatibility (see flake.nix for details).
# gettext stays on system nixpkgs; it doesn't need the patch.
ZIG_PKG="$SCRIPT_DIR#zig_0_15"
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

    # macOS 26.x (Command Line Tools 26.x) /usr/bin/libtool drops the
    # non-8-byte-aligned libghostty_zcu.o when Ghostty's LibtoolStep combines
    # the static archives, silently producing a libghostty-fat.a missing the
    # apprt C API (ghostty_app_new, ...) so the Swift app fails to link.
    # Shim `libtool` for the build to ranlib-normalize each input archive
    # first -- a port of Ghostty main's fix (commit a83a82b, "normalize input
    # archives before Darwin libtool merge"), which no released tag carries
    # yet. Remove once .ghostty-version moves to a Ghostty release that
    # includes it (it's on main / 1.3.2-dev; v1.3.0 and v1.3.1 lack it).
    libtool_shim_dir="$(mktemp -d)"
    trap 'rm -rf "$libtool_shim_dir"' EXIT
    cat > "$libtool_shim_dir/libtool" <<'LIBTOOL_SHIM'
#!/bin/sh
set -eu
# Only intercept the static-archive merge; pass anything else straight through.
case " $* " in
    *" -static "*) ;;
    *) exec /usr/bin/libtool "$@" ;;
esac
# Rewrite each existing input .a through ranlib so libtool keeps every member;
# leave flags and the (not-yet-existing) -o output path untouched.
norm_dir="$(mktemp -d)"
trap 'rm -rf "$norm_dir"' EXIT
n=0
first=1
for arg in "$@"; do
    case "$arg" in
        *.a)
            if [ -f "$arg" ]; then
                n=$((n + 1))
                norm="$norm_dir/$n-$(basename "$arg")"
                cp "$arg" "$norm"
                /usr/bin/ranlib "$norm"
                arg="$norm"
            fi
            ;;
    esac
    if [ "$first" = 1 ]; then set -- "$arg"; first=0; else set -- "$@" "$arg"; fi
done
/usr/bin/libtool "$@"
LIBTOOL_SHIM
    chmod +x "$libtool_shim_dir/libtool"

    (
        cd "$CACHE_DIR"
        PATH="$libtool_shim_dir:$PATH" nix shell "$ZIG_PKG" nixpkgs#gettext --command zig build \
            -Demit-xcframework \
            -Dxcframework-target=native \
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

    # Bundle the themes alongside the xcframework. On a CI cache hit
    # .ghostty-src/ is absent, so build-app.sh reads themes from
    # lib/ghostty-themes; this copy is what persists them into the cache.
    THEMES_SRC="$CACHE_DIR/zig-out/share/ghostty/themes"
    if [ ! -d "$THEMES_SRC" ] || [ -z "$(ls -A "$THEMES_SRC" 2>/dev/null)" ]; then
        echo "Error: themes not found or empty at $THEMES_SRC" >&2
        exit 1
    fi
    echo "Copying themes to $LIB_DIR/ghostty-themes..."
    rm -rf "$LIB_DIR/ghostty-themes"
    cp -R "$THEMES_SRC" "$LIB_DIR/ghostty-themes"

    # Fail loudly if the libtool member-drop regression (see the shim above)
    # ever ships a GhosttyKit without the apprt C API instead of a broken
    # xcframework that only surfaces at Swift link time. nm -gU lists external
    # defined symbols; _ghostty_app_free is a representative apprt export.
    # Capture then match in-shell: piping nm into `grep -q` lets grep close the
    # pipe on the first hit, and under `set -o pipefail` nm's resulting SIGPIPE
    # would spuriously fail the check even when the symbol is present.
    xcfw_lib="$LIB_DIR/GhosttyKit.xcframework/macos-arm64/libghostty-fat.a"
    xcfw_syms="$(nm -gU "$xcfw_lib" 2>/dev/null || true)"
    case "$xcfw_syms" in
        *_ghostty_app_free*) ;;
        *)
            echo "Error: $xcfw_lib is missing the apprt C API (_ghostty_app_free)." >&2
            echo "Apple's libtool likely dropped libghostty_zcu.o; the ranlib-normalize" >&2
            echo "workaround in this script may have failed. See the libtool shim above." >&2
            exit 1
            ;;
    esac

    echo "Done! GhosttyKit.xcframework and ghostty-themes are in $LIB_DIR"
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
