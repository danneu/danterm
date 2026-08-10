#!/usr/bin/env bash
# Self-test for the exit-path Swift concurrency architecture gate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../terminal-exit-concurrency-lint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

mkdir -p "$TMP/allowed" "$TMP/denied"
printf 'import Dispatch\n// Task(priority: .high) is forbidden in production code.\nDispatchQueue.main.async {}\n' > "$TMP/allowed/Boundary.swift"
"$LINT" "$TMP/allowed" >/dev/null || fail "dispatch-only delivery should pass"

for construct in \
    'Task { @MainActor in }' \
    'Task(priority: .high) {}' \
    'Task.detached {}' \
    'let work: Task<Void, Never>?' \
    'let stream = AsyncStream<Int> { _ in }' \
    'withCheckedContinuation { continuation in continuation.resume() }' \
    'let continuation: UnsafeContinuation<Void, Never>'
do
    printf '%s\n' "$construct" > "$TMP/denied/Adapter.swift"
    if "$LINT" "$TMP/denied" >/dev/null 2>&1; then
        fail "forbidden construct should fail: $construct"
    fi
done

echo "terminal exit concurrency lint self-test passed"
