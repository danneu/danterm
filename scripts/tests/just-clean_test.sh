#!/usr/bin/env bash
# Behavioral test for `just clean`: it removes sanctioned build roots without
# crossing into pinned external checkouts or matching lookalike names.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    echo "just-clean_test: $*" >&2
    exit 1
}

command -v just > /dev/null || fail "just is not installed"

WORK="$TEST_ROOT/checkout"
mkdir -p "$WORK"
cp "$ROOT_DIR/justfile" "$WORK/justfile"

BUILD_TREES=(
    .build
    .spm-build
    .build-gate
    nested/one/two/package/.build
    nested/one/two/app/.spm-build
    nested/one/two/gate/.build-gate
)

for path in "${BUILD_TREES[@]}"; do
    mkdir -p "$WORK/$path/sentinel"
    : > "$WORK/$path/sentinel/artifact.o"
done

# Pinned external checkouts are inputs rather than build output.
PRUNED_ROOTS=(.git references .refs .cmux-ref .cmux-src)
for path in "${PRUNED_ROOTS[@]}"; do
    mkdir -p "$WORK/$path/checkout/.build"
    : > "$WORK/$path/checkout/.build/keepme"
done
mkdir -p "$WORK/src/.build-not-a-tree"
: > "$WORK/src/.build-not-a-tree/keepme"

just --justfile "$WORK/justfile" --working-directory "$WORK" clean \
    > "$TEST_ROOT/clean.out" 2> "$TEST_ROOT/clean.err" \
    || fail "just clean failed: $(cat "$TEST_ROOT/clean.err")"

for path in "${BUILD_TREES[@]}"; do
    if [[ -e "$WORK/$path" ]]; then
        fail "just clean left the $path build tree behind"
    fi
done
for path in "${PRUNED_ROOTS[@]}"; do
    [[ -f "$WORK/$path/checkout/.build/keepme" ]] \
        || fail "just clean deleted the $path external checkout"
done
[[ -f "$WORK/src/.build-not-a-tree/keepme" ]] \
    || fail "just clean deleted a directory that only starts with .build"

echo "just clean tests passed"
