#!/usr/bin/env bash
# Behavioral test that a command behind the lane deadline dies with its
# supervisor, even when that supervisor is killed in a way it cannot handle.
#
# run-with-deadline.py starts the command with start_new_session=True so the
# deadline can killpg the command without killing the wrapper. That leaves the
# command's session reachable only through the wrapper, so a SIGKILL aimed at
# the suite -- which no handler can intercept -- orphans the whole tree. Sixteen
# such strays, up to five days old, were found on a dev machine: eight fake
# Swift drivers and the eight setsid sleepers they had spawned, all with pid 1
# for a parent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HARNESS="$ROOT_DIR/scripts/tests/test-terminal-pty_test.sh"

# Give the harness a private TMPDIR so its mktemp -d lands under a path only
# this run knows. Every process match below is anchored to that path, so a
# concurrent copy of the same harness in the parallel gate is never observed.
SANDBOX="$(mktemp -d "$ROOT_DIR/.build/pty-cleanup-test.XXXXXX")"
harness_pid=""

# Every kill here is best-effort: the pid is usually already reaped, and under
# set -e a non-zero status would abort the trap before it removes the sandbox.
cleanup() {
    local status=$?
    if [[ -n "$harness_pid" ]]; then
        kill -9 "$harness_pid" 2>/dev/null || true
    fi
    for pid in $(sandbox_pids); do
        kill -9 "$pid" 2>/dev/null || true
    done
    rm -rf "$SANDBOX"
    exit "$status"
}
trap cleanup EXIT INT TERM

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# Every process whose command line names this run's sandbox: the fake Swift
# driver and the setsid escapee alike, whatever their process group.
sandbox_pids() {
    pgrep -f "$SANDBOX" 2>/dev/null || true
}

# A deadline that a passing run never approaches; expiring is itself the
# observation each caller rules out, so a bool states it honestly.
wait_until() {
    local predicate="$1" deadline=$((SECONDS + 30))
    while ((SECONDS < deadline)); do
        "$predicate" && return 0
        sleep 0.2
    done
    return 1
}

fixture_is_up() {
    [[ -n "$(pgrep -f "$SANDBOX/.*swift-escapee.pid" 2>/dev/null || true)" ]]
}

sandbox_is_empty() {
    [[ -z "$(sandbox_pids)" ]]
}

TMPDIR="$SANDBOX" "$HARNESS" >"$SANDBOX/harness.log" 2>&1 &
harness_pid=$!

# The escapee only exists during the hang scenario, so its appearance is the
# signal that the harness is in the exact state that leaks.
wait_until fixture_is_up \
    || fail "fixture never reached its hang scenario within 30s (harness log: $SANDBOX/harness.log)"

# SIGKILL the supervisor chain and nothing below it, which is what a hard abort
# of the suite does: the deadline wrapper gets no chance to run cleanup, and the
# command's own session is left with pid 1 for a parent. Signalling the command
# itself would prove nothing -- the point is that nobody is left to signal it.
kill -9 "$harness_pid" 2>/dev/null || true
for supervisor in $(pgrep -f "run-with-deadline.py.*$SANDBOX" 2>/dev/null || true); do
    kill -9 "$supervisor" 2>/dev/null || true
done
wait "$harness_pid" 2>/dev/null || true

wait_until sandbox_is_empty \
    || fail "killing the supervisor orphaned these processes: $(sandbox_pids | tr '\n' ' ')"

echo "deadline-orphan cleanup test passed"
