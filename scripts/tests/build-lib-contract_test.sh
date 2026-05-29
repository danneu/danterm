#!/usr/bin/env bash
# Contract test for build-lib.sh's GhosttyKit build invocation. Pins three
# behaviors that no other self-test covers and that would each land green under
# `just test` if silently reverted:
#   (a) zig is pulled from this repo's flake ("$SCRIPT_DIR#zig_0_15"), not stock
#       nixpkgs#zig_0_15 -- only the flake-side zig carries the macOS 26.4+ SDK
#       patch that keeps the linker from dropping every libSystem symbol.
#   (b) the zig build passes -Dxcframework-target=native, so CI's
#       `./build-lib.sh all` builds arm64 instead of falling into the broken
#       universal cross-compile.
#   (c) both lib/GhosttyKit.xcframework/ and lib/ghostty-themes/ are populated
#       after a build -- on a CI cache hit .ghostty-src/ is gone, so build-app.sh
#       reads themes from lib/ghostty-themes; the bundle step fails without them.
#   (d) the built archive is asserted (via nm -gU) to export the apprt C API, so
#       the macOS 26.x libtool member-drop regression fails the build loudly
#       instead of shipping a GhosttyKit that only breaks at Swift link time.
#
# nix, xcodebuild, and nm are PATH-shimmed and never run the real toolchains, so
# this test stays portable to ubuntu-latest in CI and never touches the network.
# It stays behavioral (asserts the observable invocation and output paths) and
# structure-insensitive (a refactor preserving both leaves it green).
set -euo pipefail
unset GITHUB_ENV

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

dir_nonempty() {
    [ -d "$1" ] && [ -n "$(find "$1" -mindepth 1 -print -quit 2>/dev/null)" ]
}

# Fake SCRIPT_DIR: symlink the real build inputs so the script resolves ZIG_PKG
# against $WORKDIR and reads the real .ghostty-version / flake.
ln -s "$ROOT_DIR/build-lib.sh" "$WORKDIR/build-lib.sh"
ln -s "$ROOT_DIR/scripts" "$WORKDIR/scripts"
ln -s "$ROOT_DIR/.ghostty-version" "$WORKDIR/.ghostty-version"
ln -s "$ROOT_DIR/flake.nix" "$WORKDIR/flake.nix"
ln -s "$ROOT_DIR/flake.lock" "$WORKDIR/flake.lock"

# build-lib.sh derives SCRIPT_DIR as `cd "$(dirname "$0")" && pwd`; mirror that
# so the expected zig-package arg matches regardless of symlink normalization.
EXPECTED_SCRIPT_DIR="$(cd "$WORKDIR" && pwd)"
GHOSTTY_TAG="$("$ROOT_DIR/scripts/load-ghostty-version.sh")"

# Fake .ghostty-src: a real git checkout tagged exactly to the pinned tag, so
# build_xcframework's stale-tag guard passes without fetch_ghostty / the network.
CACHE_DIR="$WORKDIR/.ghostty-src"
mkdir -p "$CACHE_DIR"
git -C "$CACHE_DIR" init -q
git -C "$CACHE_DIR" config user.email "test@example.invalid"
git -C "$CACHE_DIR" config user.name "Test User"
printf 'fixture\n' > "$CACHE_DIR/README.md"
git -C "$CACHE_DIR" add README.md
git -C "$CACHE_DIR" commit -q -m "initial"
git -C "$CACHE_DIR" tag "$GHOSTTY_TAG"
# Regression: a rolling `tip` tag colliding with the pinned commit must not fool
# the cache-state check. `tip` is annotated, so it outranks the lightweight
# pinned tag under `git describe --tags`; the old describe-based guard would
# report HEAD as `tip` and wrongly reject this correct checkout as stale.
git -C "$CACHE_DIR" tag -a -m tip tip

# PATH-shimmed nix + xcodebuild that never invoke the real toolchains. The build
# subshell cd's into .ghostty-src before calling nix, so the nix shim emits the
# zig-build outputs relative to cwd -- the same paths the script then copies.
BIN="$WORKDIR/bin"
mkdir -p "$BIN"
export NIX_ARGV_LOG="$WORKDIR/nix-argv.log"

cat > "$BIN/nix" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NIX_ARGV_LOG"
case " $* " in
    *" zig build "*)
        mkdir -p macos/GhosttyKit.xcframework/macos-arm64
        : > macos/GhosttyKit.xcframework/macos-arm64/libghostty-fat.a
        mkdir -p zig-out/share/ghostty/themes
        : > zig-out/share/ghostty/themes/FixtureTheme
        ;;
esac
SHIM
chmod +x "$BIN/nix"

cat > "$BIN/xcodebuild" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
chmod +x "$BIN/xcodebuild"

# nm shim for build-lib.sh's apprt-API guard. By default it reports the apprt
# exports so the guard passes; CONTRACT_NM_OMIT_APPRT=1 omits them to simulate
# the macOS 26.x libtool member-drop, which must fail the build.
cat > "$BIN/nm" <<'SHIM'
#!/usr/bin/env bash
if [ "${CONTRACT_NM_OMIT_APPRT:-0}" = "1" ]; then
    printf '%s\n' '0000000000000000 T _ghostty_simd_base64_decode'
else
    printf '%s\n' '0000000000000000 T _ghostty_app_free'
    printf '%s\n' '0000000000000000 T _ghostty_app_new'
fi
SHIM
chmod +x "$BIN/nm"

# Run build mode directly (bypasses fetch_ghostty, which would hit the network).
rm -f "$NIX_ARGV_LOG"
PATH="$BIN:$PATH" "$WORKDIR/build-lib.sh" build >"$WORKDIR/stdout" 2>"$WORKDIR/stderr" \
    || fail "build-lib.sh build exited non-zero; stderr: $(cat "$WORKDIR/stderr")"

# (a) zig package resolves from the fake SCRIPT_DIR's flake, not stock nixpkgs.
grep -qF "$EXPECTED_SCRIPT_DIR#zig_0_15" "$NIX_ARGV_LOG" \
    || fail "nix not invoked with \$SCRIPT_DIR#zig_0_15 (argv: $(cat "$NIX_ARGV_LOG"))"

# (b) the build is native-targeted, not a universal cross-compile.
grep -qF -- '-Dxcframework-target=native' "$NIX_ARGV_LOG" \
    || fail "zig build invocation missing -Dxcframework-target=native"

# (c) both cache-persisted artifacts are populated.
dir_nonempty "$WORKDIR/lib/GhosttyKit.xcframework" \
    || fail "lib/GhosttyKit.xcframework missing or empty after build"
dir_nonempty "$WORKDIR/lib/ghostty-themes" \
    || fail "lib/ghostty-themes missing or empty after build"

# (d) when the built archive lacks the apprt C API (the macOS 26.x libtool
#     member-drop), the guard must fail the build loudly and name the symbol --
#     not ship a GhosttyKit that only breaks at Swift link time.
if CONTRACT_NM_OMIT_APPRT=1 PATH="$BIN:$PATH" "$WORKDIR/build-lib.sh" build \
    >"$WORKDIR/stdout.omit" 2>"$WORKDIR/stderr.omit"; then
    fail "build-lib.sh succeeded with the apprt C API missing -- the symbol guard did not fire"
fi
grep -q '_ghostty_app_free' "$WORKDIR/stderr.omit" \
    || fail "missing-apprt failure did not name _ghostty_app_free; stderr: $(cat "$WORKDIR/stderr.omit")"

echo "build-lib contract self-test passed"
