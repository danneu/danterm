#!/usr/bin/env bash
# Self-test for the production PTY host test-control seam gate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../terminal-pty-host-test-seam-lint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

host_dir="$TMP/allowed/lib/TerminalPTY/Sources/TerminalPTYHost"
mkdir -p "$host_dir"
printf 'func forceExitBoundForTesting() {}\n' > "$host_dir/TerminalPTYHost.swift"
"$LINT" "$TMP/allowed" >/dev/null || fail "the retained exit-bound driver should pass"

printf 'var spawnReportDelay: Double?\n' >> "$host_dir/TerminalPTYHost.swift"
if "$LINT" "$TMP/allowed" >/dev/null 2>&1; then
    fail "a removed spawn seam should fail"
fi

if "$LINT" "$TMP/missing" >/dev/null 2>&1; then
    fail "a missing host source should fail"
fi

echo "TerminalPTY host test-seam lint self-test passed"
