#!/usr/bin/env bash
# Behavioral self-test for the tracked Swift file-header lint.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../swift-file-header-lint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

REPO="$TMP/repository"
mkdir -p "$REPO/Nested Folder"
git -C "$REPO" init -q

printf '%s\n' '// A useful file comment.' 'struct Good {}' > "$REPO/Good.swift"
printf '%s\n' '// swift-tools-version: 6.0' 'import PackageDescription' > "$REPO/Package.swift"
printf '%s\n' '/// Detached declaration documentation.' 'struct Detached {}' > "$REPO/Detached.swift"
printf '%s\n' 'struct Missing {}' > "$REPO/Nested Folder/Missing.swift"
printf '%s\n' '// Banner.swift' 'struct Banner {}' > "$REPO/Banner.swift"
git -C "$REPO" add -- '*.swift'

message="$(SWIFT_FILE_HEADER_LINT_ROOT="$REPO" "$LINT" 2>&1 || true)"
for expected in \
    "Detached.swift" \
    "Nested Folder/Missing.swift" \
    "Banner.swift" \
    "ordinary // file comment" \
    "declaration documentation"
do
    case "$message" in
        *"$expected"*) ;;
        *) fail "failure output should contain '$expected': $message" ;;
    esac
done

case "$message" in
    *"Good.swift"*|*"Package.swift"*)
        fail "valid headers should not be reported: $message"
        ;;
esac

printf '%s\n' '// Detached declarations live below this file comment.' 'struct Detached {}' > "$REPO/Detached.swift"
printf '%s\n' '// Defines the nested fixture.' 'struct Missing {}' > "$REPO/Nested Folder/Missing.swift"
printf '%s\n' '// Defines the banner fixture.' 'struct Banner {}' > "$REPO/Banner.swift"
SWIFT_FILE_HEADER_LINT_ROOT="$REPO" "$LINT" >/dev/null \
    || fail "ordinary comments and the tools-version directive should pass"

# A tracked file deleted in the working tree has no header left to check. The edit-loop
# lint runs before staging, so an ordinary source deletion must not make it fail.
rm "$REPO/Good.swift"
SWIFT_FILE_HEADER_LINT_ROOT="$REPO" "$LINT" >/dev/null \
    || fail "a tracked Swift file deleted from the working tree should be skipped"

EMPTY="$TMP/empty"
mkdir -p "$EMPTY"
git -C "$EMPTY" init -q
empty_message="$(SWIFT_FILE_HEADER_LINT_ROOT="$EMPTY" "$LINT" 2>&1 || true)"
case "$empty_message" in
    *"no tracked Swift files"*) ;;
    *) fail "an empty tracked inventory should fail clearly: $empty_message" ;;
esac

echo "Swift file-header lint self-test passed"
