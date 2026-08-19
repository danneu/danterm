#!/usr/bin/env bash
# Contract self-test for scripts/gate-cpu-tokens.py, the machine-wide CPU budget.
#
# The pool is what stops N concurrent gates from each reserving the whole machine, so
# these cases pin the properties that make it safe to put in front of every gate step:
# it is a mutual exclusion (not a delay), a dead holder returns its share without any
# cleanup path, extras are opportunistic and never block, and the step's exit code
# survives.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOKENS="$REPO_ROOT/scripts/gate-cpu-tokens.py"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# Never touch the real pool under the user's cache: this test would contend with any
# gate actually running on the machine, and would leave its own tokens behind.
export DANTERM_GATE_TOKEN_DIR="$TEST_ROOT/pool"

# Every wait here is a hang guard, not a measurement. A passing run reaches these
# conditions in well under a second; the guard exists so a wedged pool names itself
# instead of hanging the gate that runs this file.
GUARD_SECONDS=30

fail() {
    echo "gate-cpu-tokens_test: $*" >&2
    exit 1
}

# Waits for a condition, then fails by name rather than hanging. Polls rather than
# sleeping a fixed span so a passing run pays nothing for the guard.
await() {
    local description="$1" deadline=$((SECONDS + GUARD_SECONDS))
    shift
    until "$@"; do
        (( SECONDS < deadline )) || fail "timed out after ${GUARD_SECONDS}s waiting for $description"
        sleep 0.05
    done
}

# The step's exit code is the run's exit code: the supervisor holds the tokens and
# relays the child's status untouched.
rc=0
"$TOKENS" --ask 1 --pool 2 -- bash -c 'exit 7' || rc=$?
[[ "$rc" == "7" ]] || fail "step exit code came back as $rc; expected 7"

# The step is told how many tokens it holds. This is what makes the claim honest: the
# runner's swift shim reads DANTERM_SWIFT_JOBS, so a step can never ask SwiftPM for
# more compile jobs than the tokens standing behind it. The step lines stay single
# quoted on purpose: the child, not this test, expands the variable.
# shellcheck disable=SC2016
held="$("$TOKENS" --ask 1 --pool 2 -- bash -c 'echo "$DANTERM_SWIFT_JOBS"')"
[[ "$held" == "1" ]] || fail "single-token step saw DANTERM_SWIFT_JOBS=$held; expected 1"

# When the pool has room, an ask above one is granted from whatever is free right now.
# shellcheck disable=SC2016
held="$("$TOKENS" --ask 2 --pool 2 -- bash -c 'echo "$DANTERM_SWIFT_JOBS"')"
[[ "$held" == "2" ]] || fail "ask-2 step on an empty pool saw DANTERM_SWIFT_JOBS=$held; expected 2"

# An ask larger than the whole pool takes what exists and runs. `just test-serial`
# derives an ask of the full budget, so on a tiny machine this is the everyday case,
# and a wedge here would look like a hung gate with no output.
# shellcheck disable=SC2016
held="$("$TOKENS" --ask 99 --pool 2 -- bash -c 'echo "$DANTERM_SWIFT_JOBS"')"
[[ "$held" == "2" ]] || fail "oversized ask saw DANTERM_SWIFT_JOBS=$held; expected the pool size 2"

# A held pool excludes the next claimant rather than merely slowing it down. The
# assertion is on the order of two appends, not on how long the second one waited:
# an ordering can be asserted exactly, where a duration could only be guessed at.
order="$TEST_ROOT/order"
: >"$order"
(
    "$TOKENS" --ask 1 --pool 1 -- \
        bash -c "touch '$TEST_ROOT/holder-started'; sleep 1; echo A >>'$order'"
) &
holder=$!
await "the holder to claim the only token" test -e "$TEST_ROOT/holder-started"

waited_file="$TEST_ROOT/waited"
DANTERM_GATE_TOKEN_WAIT_FILE="$waited_file" \
    "$TOKENS" --ask 1 --pool 1 -- bash -c "echo B >>'$order'" \
    || fail "the waiting claimant failed once the pool freed up"
wait "$holder"

[[ "$(tr -d '\n' <"$order")" == "AB" ]] \
    || fail "pool did not exclude the second claimant: got $(tr -d '\n' <"$order")"

# The wait is reported so a gate step's own duration stays comparable between a quiet
# machine and a busy one. Only the shape is pinned: the value is a real queue delay,
# and asserting a floor on it would be asserting a scheduling speed.
[[ -s "$waited_file" ]] || fail "queue wait was not reported"
grep -qE '^[0-9]+$' "$waited_file" \
    || fail "queue wait was not a whole number of seconds: $(cat "$waited_file")"

# Extras beyond the first token must never be waited for. A claimant that would block
# for its full ask reintroduces the deadlock the old multi-token design needed an
# admission lock to prevent; taking only what is free right now is what lets that lock
# not exist. The holder below cannot exit until the ask-2 claimant has run, so the
# claimant demonstrably finished with the pool still partly held.
cat >"$TEST_ROOT/holder.sh" <<CASE
#!/usr/bin/env bash
# Holds one token until released, guarded so a broken release names itself.
touch "$TEST_ROOT/blocker-started"
deadline=\$((SECONDS + $GUARD_SECONDS))
until [[ -e "$TEST_ROOT/release-blocker" ]]; do
    (( SECONDS < deadline )) || { echo "holder timed out" >&2; exit 70; }
    sleep 0.05
done
CASE
(
    "$TOKENS" --ask 1 --pool 2 -- bash "$TEST_ROOT/holder.sh"
) &
blocker=$!
await "the blocker to claim one of two tokens" test -e "$TEST_ROOT/blocker-started"
held="$("$TOKENS" --ask 2 --pool 2 -- bash -c "echo \"\$DANTERM_SWIFT_JOBS\"; touch '$TEST_ROOT/release-blocker'")" \
    || fail "ask-2 claimant failed against a partly held pool"
wait "$blocker" || fail "the blocking holder did not exit cleanly"
[[ "$held" == "1" ]] \
    || fail "ask-2 claimant against a partly held pool saw DANTERM_SWIFT_JOBS=$held; expected 1"

# A killed step returns its share with no cleanup path involved. This is the case that
# decides whether the pool can be trusted in front of a gate at all: a leaked token is
# permanent, and would shrink the machine's budget until the user noticed by hand.
# Run through a wrapper whose stderr can be dropped: the shell that waits on a
# signal-killed command is the one that announces "Killed: 9", and that notice is
# noise here rather than a finding.
cat >"$TEST_ROOT/kill-case.sh" <<'CASE'
"$1" --ask 1 --pool 1 -- bash -c 'kill -9 $$'
CASE
bash "$TEST_ROOT/kill-case.sh" "$TOKENS" 2>/dev/null && fail "killed step reported success"
timeout_marker="$TEST_ROOT/after-kill"
(
    "$TOKENS" --ask 1 --pool 1 -- touch "$timeout_marker"
) &
await "the token held by a killed step to come back" test -e "$timeout_marker"
wait $!

# A step that leaves a background process behind must not leave its share of the
# machine behind with it. Gate steps spawn PTY children, servers, and launched apps,
# and a descendant that outlives its step would hold gate CPU tokens for as long as it
# lived -- a leak the pool cannot recover from, because nothing is left to blame.
cat >"$TEST_ROOT/lingering.sh" <<'CASE'
# A step whose child outlives it, the shape a spawned server or PTY child has.
nohup sleep 30 >/dev/null 2>&1 &
echo $! >"$1"
CASE
"$TOKENS" --ask 1 --pool 1 -- bash "$TEST_ROOT/lingering.sh" "$TEST_ROOT/lingering.pid" \
    || fail "step with a lingering child failed"
reclaimed="$TEST_ROOT/reclaimed"
(
    "$TOKENS" --ask 1 --pool 1 -- touch "$reclaimed"
) &
await "the token to come back from a step that left a child running" test -e "$reclaimed"
wait $!
kill -9 "$(cat "$TEST_ROOT/lingering.pid")" 2>/dev/null || true

# The same holds when the process holding the tokens is killed outright: its share goes
# back even though the step it started is still running. The kernel is the release path,
# so there is no cleanup here that a hard kill could skip.
"$TOKENS" --ask 1 --pool 1 -- sleep 30 &
supervisor=$!
await "the supervised step to start" pgrep -qP "$supervisor" sleep
kill -9 "$supervisor" 2>/dev/null || true
wait "$supervisor" 2>/dev/null || true
survivor="$TEST_ROOT/survivor"
(
    "$TOKENS" --ask 1 --pool 1 -- touch "$survivor"
) &
await "a killed holder to return its tokens" test -e "$survivor"
wait $!

echo "gate-cpu-tokens_test: ok"
