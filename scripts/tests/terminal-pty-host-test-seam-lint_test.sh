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

# The shape the real tree holds: retained seams unguarded, and one debug region around the
# consumer-side fixture stager. Every case below starts from this and breaks one thing.
write_host() {
    cat > "$host_dir/TerminalPTYHost.swift" <<'SWIFT'
func forceExitBoundForTesting() {}
#if DEBUG
package nonisolated func stageFixtureOutput(_ bytes: [UInt8]) {}
#endif
SWIFT
}

write_host
printf 'let channel = ChildlessPTYChannel()\n' > "$suite_dir/TerminalPTYHostTests.swift"
"$LINT" "$TMP/allowed" >/dev/null || fail "the retained exit-bound driver should pass"

write_host
printf 'var spawnReportDelay: Double?\n' >> "$host_dir/TerminalPTYHost.swift"
if "$LINT" "$TMP/allowed" >/dev/null 2>&1; then
    fail "a removed spawn seam should fail"
fi

write_host
printf 'func injectInputWriteFailure(_ code: Int32) {}\n' >> "$host_dir/TerminalPTYHost.swift"
if "$LINT" "$TMP/allowed" >/dev/null 2>&1; then
    fail "a removed write-failure fault flag should fail"
fi

# The host's own suite must reach the byte plane through a real PTY master descriptor, so
# staging output straight onto a host is a bypass there even though a consumer suite may
# legitimately do it as fixture setup.
write_host
printf 'host.stageFixtureOutput(Array("hi".utf8))\n' >> "$suite_dir/TerminalPTYHostTests.swift"
if "$LINT" "$TMP/allowed" >/dev/null 2>&1; then
    fail "the host's own suite applying output directly should fail"
fi
printf 'let channel = ChildlessPTYChannel()\n' > "$suite_dir/TerminalPTYHostTests.swift"

# Dropping the guard puts the fixture stager into shipping builds. No release build runs in
# the gate, so this check is the only thing that would notice.
write_host
printf 'package nonisolated func stageFixtureOutput(_ b: [UInt8]) {}\n' \
    > "$host_dir/TerminalPTYHost.swift"
if "$LINT" "$TMP/allowed" >/dev/null 2>&1; then
    fail "an unguarded fixture stager should fail"
fi

# A second region is new test-only surface accreting onto the host, which is the way this
# file grew the seams the name list above now bans.
write_host
cat >> "$host_dir/TerminalPTYHost.swift" <<'SWIFT'
#if DEBUG
func someNewTestOnlyHook() {}
#endif
SWIFT
if "$LINT" "$TMP/allowed" >/dev/null 2>&1; then
    fail "a second debug region should fail"
fi

# One region is not enough on its own: it has to be the one this file expects.
cat > "$host_dir/TerminalPTYHost.swift" <<'SWIFT'
func forceExitBoundForTesting() {}
#if DEBUG
func someOtherHook() {}
#endif
SWIFT
if "$LINT" "$TMP/allowed" >/dev/null 2>&1; then
    fail "a debug region that does not enclose the fixture stager should fail"
fi

# A nested directive must not close the debug region early, or the check would read the
# stager as unguarded and fail a tree that is correct.
cat > "$host_dir/TerminalPTYHost.swift" <<'SWIFT'
func forceExitBoundForTesting() {}
#if DEBUG
#if canImport(Darwin)
package nonisolated func stageFixtureOutput(_ bytes: [UInt8]) {}
#endif
#endif
SWIFT
"$LINT" "$TMP/allowed" >/dev/null || fail "a nested directive inside the region should pass"

write_host
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
