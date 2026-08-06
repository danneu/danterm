#!/usr/bin/env bash
# Contract tests for scripts/bundle-theme-resources.sh, focused on the one input shape
# the primary checkout never produces: a symlinked lib/ghostty-themes.
#
# `just provision-worktree` links that path into a linked worktree rather than copying
# it, so in a worktree the bundler is always handed a symlink. Everyone develops in the
# primary checkout, where it is a real directory, which is exactly why the symlink case
# needs a test of its own -- it is unexercised by every other route into this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    echo "bundle-theme-resources_test: $*" >&2
    exit 1
}

# Builds a repository-root fixture holding everything the bundler reads except the
# legacy Ghostty themes, which each case supplies in the shape it is testing.
make_repository_root() {
    local root="$1"
    local symbols="$root/lib/TerminalCore/Sources/TerminalRenderExecution/Resources/NerdFontsSymbolsOnly"
    mkdir -p "$root/scripts" "$root/themes" "$symbols"
    cp "$ROOT_DIR/scripts/bundle-theme-resources.sh" "$root/scripts/"
    cp "$ROOT_DIR/scripts/pack-theme-catalog.py" "$root/scripts/"
    cp "$ROOT_DIR/themes/0x96f.json" "$root/themes/"
    : > "$symbols/SymbolsNerdFontMono-Regular.ttf"
    : > "$symbols/LICENSE"
}

# --- Case 1: lib/ghostty-themes is a symlink to a real directory --------------------
# This is the worktree shape. Both halves of the script have to see through the link:
# the emptiness guard (or it reports "themes are missing" and exits 1) and the copy
# (or the bundle receives the link itself, which points outside the app).

symlink_root="$TEST_ROOT/symlink-case"
make_repository_root "$symlink_root"
mkdir -p "$TEST_ROOT/real-themes"
printf 'palette = 0=#000000\n' > "$TEST_ROOT/real-themes/FixtureTheme"
mkdir -p "$symlink_root/lib"
ln -s "$TEST_ROOT/real-themes" "$symlink_root/lib/ghostty-themes"

symlink_app="$TEST_ROOT/symlink-case-app/DanTerm.app"
if ! "$symlink_root/scripts/bundle-theme-resources.sh" "$symlink_root" "$symlink_app" \
    >"$TEST_ROOT/symlink.out" 2>&1; then
    echo "--- bundler output ---" >&2
    cat "$TEST_ROOT/symlink.out" >&2
    fail "the bundler rejected a symlinked lib/ghostty-themes"
fi

bundled="$symlink_app/Contents/Resources/ghostty/themes"
[[ ! -L "$bundled" ]] \
    || fail "the bundle got a symlink at ghostty/themes; it must hold real files, because the link's target is outside the app"
[[ -d "$bundled" ]] \
    || fail "the bundle has no ghostty/themes directory"
[[ -f "$bundled/FixtureTheme" ]] \
    || fail "the bundled ghostty/themes is missing the theme behind the symlink"
cmp -s "$bundled/FixtureTheme" "$TEST_ROOT/real-themes/FixtureTheme" \
    || fail "the bundled theme does not match its source"

# --- Case 2: lib/ghostty-themes is a real directory ---------------------------------
# The primary-checkout shape. Guards against a fix for case 1 that only works on links.

plain_root="$TEST_ROOT/plain-case"
make_repository_root "$plain_root"
mkdir -p "$plain_root/lib/ghostty-themes"
printf 'palette = 0=#ffffff\n' > "$plain_root/lib/ghostty-themes/FixtureTheme"

plain_app="$TEST_ROOT/plain-case-app/DanTerm.app"
if ! "$plain_root/scripts/bundle-theme-resources.sh" "$plain_root" "$plain_app" \
    >"$TEST_ROOT/plain.out" 2>&1; then
    echo "--- bundler output ---" >&2
    cat "$TEST_ROOT/plain.out" >&2
    fail "the bundler rejected a real lib/ghostty-themes directory"
fi
[[ -f "$plain_app/Contents/Resources/ghostty/themes/FixtureTheme" ]] \
    || fail "the bundled ghostty/themes is missing the theme from the real directory"

# --- Case 3: no themes anywhere -----------------------------------------------------
# The genuine missing-themes path still has to fail loudly. A fix that makes the guard
# see through links must not make it see through nothing.

missing_root="$TEST_ROOT/missing-case"
make_repository_root "$missing_root"
mkdir -p "$missing_root/lib/ghostty-themes"

missing_app="$TEST_ROOT/missing-case-app/DanTerm.app"
if "$missing_root/scripts/bundle-theme-resources.sh" "$missing_root" "$missing_app" \
    >"$TEST_ROOT/missing.out" 2>&1; then
    fail "the bundler accepted an empty lib/ghostty-themes with no fallback present"
fi
grep -q "Ghostty themes are missing" "$TEST_ROOT/missing.out" \
    || fail "the missing-themes failure did not name the cause"

echo "bundle-theme-resources tests passed"
