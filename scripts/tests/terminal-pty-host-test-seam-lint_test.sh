#!/usr/bin/env bash
# Self-test for the production PTY host test-control seam gate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../terminal-pty-host-test-seam-lint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

host_dir="$TMP/allowed/lib/TerminalPTY/Sources/TerminalPTYHost"
suite_dir="$TMP/allowed/lib/TerminalPTY/Tests/TerminalPTYHostTests"
mkdir -p "$host_dir" "$suite_dir"
printf 'func forceExitBoundForTesting() {}\n' > "$host_dir/TerminalPTYHost.swift"
printf 'let channel = ChildlessPTYChannel()\n' > "$suite_dir/TerminalPTYHostTests.swift"
"$LINT" "$TMP/allowed" >/dev/null || fail "the retained exit-bound driver should pass"

printf 'var spawnReportDelay: Double?\n' >> "$host_dir/TerminalPTYHost.swift"
if "$LINT" "$TMP/allowed" >/dev/null 2>&1; then
    fail "a removed spawn seam should fail"
fi

printf 'func injectInputWriteFailure(_ code: Int32) {}\n' > "$host_dir/TerminalPTYHost.swift"
if "$LINT" "$TMP/allowed" >/dev/null 2>&1; then
    fail "a removed write-failure fault flag should fail"
fi

# The host's own suite must reach the byte plane through a real PTY master descriptor, so
# staging output straight onto a host is a bypass there even though a consumer suite may
# legitimately do it as fixture setup.
printf 'func forceExitBoundForTesting() {}\n' > "$host_dir/TerminalPTYHost.swift"
printf 'host.stageFixtureOutput(Array("hi".utf8))\n' >> "$suite_dir/TerminalPTYHostTests.swift"
if "$LINT" "$TMP/allowed" >/dev/null 2>&1; then
    fail "the host's own suite applying output directly should fail"
fi

if "$LINT" "$TMP/missing" >/dev/null 2>&1; then
    fail "a missing host source should fail"
fi

rm -rf "$TMP/no-suite"
mkdir -p "$TMP/no-suite/lib/TerminalPTY/Sources/TerminalPTYHost"
printf 'func forceExitBoundForTesting() {}\n' \
    > "$TMP/no-suite/lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift"
if "$LINT" "$TMP/no-suite" >/dev/null 2>&1; then
    fail "a missing host suite should fail"
fi

echo "TerminalPTY host test-seam lint self-test passed"
