#!/usr/bin/env bash
# Contract self-test for scripts/run-test-suite.sh, the parallel `just test` pool.
#
# Parallelizing a gate is only safe if a failure inside one worker still reaches the
# operator intact. These cases pin the three properties that make the pool trustworthy
# as a gate: a failing step fails the run, its output survives being captured, and one
# failure does not cancel the steps still queued behind it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/scripts/run-test-suite.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    echo "run-test-suite_test: $*" >&2
    exit 1
}

run_with_steps() {
    local steps_file="$TEST_ROOT/steps"
    printf '%s\n' "$@" >"$steps_file"
    RUN_TEST_SUITE_STEPS_FILE="$steps_file" "$RUNNER" 4 >"$TEST_ROOT/output" 2>&1 && echo 0 || echo $?
}

# An all-passing list exits clean.
rc="$(run_with_steps 'true' 'true' 'true')"
[[ "$rc" == "0" ]] || fail "all-passing run exited $rc; expected 0"
grep -q 'all 3 steps passed' "$TEST_ROOT/output" \
    || fail "all-passing run did not report success: $(cat "$TEST_ROOT/output")"

# Every worker inherits a writable compiler cache inside the repository, so Swift and
# xcrun builds do not fall back to a sandbox-blocked cache under the user's home directory.
rc="$(run_with_steps "test \"\$CLANG_MODULE_CACHE_PATH\" = '$REPO_ROOT/.build/clang-module-cache'")"
[[ "$rc" == "0" ]] || fail "worker did not inherit the workspace compiler cache"

# A failing step fails the whole run, and its captured stdout is replayed. Without the
# replay the pool would swallow the only diagnostic a developer has.
rc="$(run_with_steps 'true' 'echo distinctive-failure-marker; exit 3' 'true')"
[[ "$rc" == "1" ]] || fail "run with a failing step exited $rc; expected 1"
grep -q 'distinctive-failure-marker' "$TEST_ROOT/output" \
    || fail "failing step output was not replayed: $(cat "$TEST_ROOT/output")"
grep -q 'exit 3' "$TEST_ROOT/output" \
    || fail "failing step exit code was not reported: $(cat "$TEST_ROOT/output")"

# A failure must not abort the queue: xargs exits early on some conditions, so this
# pins that every remaining step still runs and every failure is reported, not just
# the first one encountered.
rc="$(run_with_steps 'exit 1' 'echo second-marker; exit 1' "touch $TEST_ROOT/third-ran")"
[[ "$rc" == "1" ]] || fail "multi-failure run exited $rc; expected 1"
grep -q 'second-marker' "$TEST_ROOT/output" \
    || fail "queue aborted before the second failing step ran: $(cat "$TEST_ROOT/output")"
[[ -e "$TEST_ROOT/third-ran" ]] \
    || fail "queue aborted before the trailing passing step ran: $(cat "$TEST_ROOT/output")"
grep -q '2 of 3 steps FAILED' "$TEST_ROOT/output" \
    || fail "failure count was not reported: $(cat "$TEST_ROOT/output")"

echo "run-test-suite_test: ok"
