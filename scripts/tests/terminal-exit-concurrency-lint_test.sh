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

# The violation has to explain what a suspension point costs on this path. A bare
# "concurrency bridge found" reads as a style rule, and the obvious way to satisfy a
# style rule is to move the Task one call up.
printf 'Task { @MainActor in }\n' > "$TMP/denied/Adapter.swift"
message="$("$LINT" "$TMP/denied" 2>&1 || true)"
for expected in "recovery fence" "Dispatch boundary"; do
    case "$message" in
        *"$expected"*) ;;
        *) fail "the violation message should explain '$expected': $message" ;;
    esac
done


# --- a lint that cannot find its subject must fail -------------------------
# A rename that outruns the target list has to go red naming the path, not report
# "passed" over nothing. `rg` exits non-zero on a missing path and `if rg` reads any
# non-zero status as "no violations", so the targets have to be resolved before the
# sweep rather than handed to the search.
assert_checked_nothing() {
    local label="$1"; shift
    local message
    if message="$("$LINT" "$@" 2>&1)"; then
        fail "$label should fail"
    fi
    case "$message" in
        *"checked nothing"*) ;;
        *) fail "$label should say the lint checked nothing: $message" ;;
    esac
    case "$message" in
        *"$1"*) ;;
        *) fail "$label should name the path: $message" ;;
    esac
}

assert_checked_nothing "a missing target" "$TMP/never-created"

# An existing directory holding no Swift file is the same hole with the path still in
# place: the subject moved out from under a name that survives an existence check.
mkdir -p "$TMP/empty"
assert_checked_nothing "a target directory holding no Swift file" "$TMP/empty"

echo "terminal exit concurrency lint self-test passed"
