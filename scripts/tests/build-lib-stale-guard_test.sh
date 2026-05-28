#!/usr/bin/env bash
# Self-test for build-lib.sh build mode: it must reject missing or stale Ghostty
# source before any Metal toolchain or zig build work starts.
set -euo pipefail
unset GITHUB_ENV

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_LIB="$ROOT_DIR/build-lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

run_build() {
    local cache_dir="$1"
    local version_file="$2"
    rm -f "$TMP/stdout" "$TMP/stderr"
    set +e
    GHOSTTY_VERSION_FILE="$version_file" GHOSTTY_CACHE_DIR="$cache_dir" "$BUILD_LIB" build >"$TMP/stdout" 2>"$TMP/stderr"
    status=$?
    set -e
    return "$status"
}

assert_stopped_before_build() {
    ! grep -q "Ensuring Metal toolchain" "$TMP/stdout" || fail "Metal toolchain check ran before stale guard"
    ! grep -q "Building GhosttyKit XCFramework" "$TMP/stdout" || fail "zig build path ran before stale guard"
}

repo="$TMP/ghostty-src"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email "test@example.invalid"
git -C "$repo" config user.name "Test User"
printf 'fixture\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -q -m "initial"
git -C "$repo" tag v0.0.1

version_file="$TMP/.ghostty-version"
printf 'v0.0.2\n' > "$version_file"

if run_build "$repo" "$version_file"; then
    fail "stale source build unexpectedly succeeded"
fi
grep -q "v0.0.1" "$TMP/stderr" || fail "stale guard stderr did not name actual tag"
grep -q "v0.0.2" "$TMP/stderr" || fail "stale guard stderr did not name expected tag"
assert_stopped_before_build

missing="$TMP/missing-source"
if run_build "$missing" "$version_file"; then
    fail "missing source build unexpectedly succeeded"
fi
grep -qi "missing" "$TMP/stderr" || fail "missing-source stderr did not explain missing source"
grep -q "v0.0.2" "$TMP/stderr" || fail "missing-source stderr did not name expected tag"
assert_stopped_before_build

echo "build-lib stale-source guard self-test passed"
