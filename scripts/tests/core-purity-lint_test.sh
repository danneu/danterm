#!/usr/bin/env bash
# Self-test for scripts/core-purity-lint.sh: each positive fixture MUST trip
# the lint (exit 1) and each negative fixture must NOT (exit 0). The lint is
# R1's only guard against Cocoa creep in lib/DanTermCore/Sources/DanTermCore,
# so a silent regex regression must itself be caught.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../core-purity-lint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Run the lint against a temp dir; returns 1 if forbidden import found, 0 otherwise.
run_lint() {
    "$LINT" "$1" >/dev/null 2>&1
}

write_file() {
    mkdir -p "$(dirname "$1")"
    printf '%s\n' "$2" > "$1"
}

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# Positive fixtures (must trip the lint).
positive_cases=(
    "import Cocoa"
    "@preconcurrency import AppKit"
    "  import SwiftUI"
    "@_exported import Cocoa"
    "@_spi(Foo) import AppKit"
)

for case in "${positive_cases[@]}"; do
    pos="$TMP/positive"
    rm -rf "$pos"
    write_file "$pos/Module.swift" "$case"
    if run_lint "$pos"; then
        fail "positive fixture should have tripped lint: $case"
    fi
done

# Negative fixtures (must NOT trip the lint).
negative_cases=(
    "import Foundation"
    "import CocoaLumberjack"
    "import CocoaAsyncSocket"
    "// import AppKit"
    "import SwiftUIPlus"
    "import AppKitExtensions"
    "let x = 42 // import Cocoa in a comment"
)

for case in "${negative_cases[@]}"; do
    neg="$TMP/negative"
    rm -rf "$neg"
    write_file "$neg/Module.swift" "$case"
    if ! run_lint "$neg"; then
        fail "negative fixture should NOT have tripped lint: $case"
    fi
done

echo "core-purity lint self-test passed (${#positive_cases[@]} positive, ${#negative_cases[@]} negative)"
