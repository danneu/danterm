#!/usr/bin/env bash
# Behavioral test for `just clean`: it must remove every build tree the gate creates.
#
# The scratch paths are chosen in scripts/run-test-suite.sh, so this test reads them
# from there rather than restating them. A gate step that picks a new scratch path
# fails here until clean removes it too.
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

# The default SwiftPM trees are implied by every `swift build`/`swift test` step
# that names no scratch path; the rest are declared by the gate itself.
SCRATCH_PATHS=(.spm-build .build)
# A scratch path written as a shell variable is a throwaway directory the step makes
# with `mktemp -d` and deletes itself, so it is never a tree in the checkout for clean
# to remove. Only the literal paths belong in this list.
while IFS= read -r path; do
    [[ "$path" == *'$'* ]] && continue
    SCRATCH_PATHS+=("$path")
done < <(grep -o -- '--scratch-path [^ ]*' "$ROOT_DIR/scripts/run-test-suite.sh" \
    | awk '{print $2}' | tr -d "\"'")

# Nested packages build into their own default tree when tested directly, which
# `swift test --package-path lib/X` does throughout the gate and the docs.
while IFS= read -r manifest; do
    package_dir="${manifest%/Package.swift}"
    SCRATCH_PATHS+=("${package_dir#"$ROOT_DIR"/}/.build")
done < <(find "$ROOT_DIR/lib" -maxdepth 2 -name Package.swift)

for path in "${SCRATCH_PATHS[@]}"; do
    mkdir -p "$WORK/$path/sentinel"
    : > "$WORK/$path/sentinel/artifact.o"
done

# Pinned external checkouts are not build output, and a pattern-based clean must
# not reach into them.
mkdir -p "$WORK/references/ghostty/.build"
: > "$WORK/references/ghostty/.build/keepme"
mkdir -p "$WORK/src/.build-not-a-tree"
: > "$WORK/src/.build-not-a-tree/keepme"

just --justfile "$WORK/justfile" --working-directory "$WORK" clean \
    > "$TEST_ROOT/clean.out" 2> "$TEST_ROOT/clean.err" \
    || fail "just clean failed: $(cat "$TEST_ROOT/clean.err")"

for path in "${SCRATCH_PATHS[@]}"; do
    if [[ -e "$WORK/$path" ]]; then
        fail "just clean left the $path build tree behind"
    fi
done
[[ -f "$WORK/references/ghostty/.build/keepme" ]] \
    || fail "just clean deleted a pinned reference checkout"
[[ -f "$WORK/src/.build-not-a-tree/keepme" ]] \
    || fail "just clean deleted a directory that only starts with .build"

echo "just clean tests passed"
