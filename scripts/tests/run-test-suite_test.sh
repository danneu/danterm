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

# The gate draws CPU tokens from a pool shared by every checkout on the machine. This
# file must never draw on the real one: it runs as a gate step itself, so it would
# compete with the very run that started it, and it would leave tokens in the user's
# cache. Every case below inherits this throwaway pool.
export DANTERM_GATE_TOKEN_DIR="$TEST_ROOT/token-pool"

fail() {
    echo "run-test-suite_test: $*" >&2
    exit 1
}

run_with_steps() {
    local steps_file="$TEST_ROOT/steps"
    printf '%s\n' "$@" >"$steps_file"
    RUN_TEST_SUITE_STEPS_FILE="$steps_file" "$RUNNER" 4 >"$TEST_ROOT/output" 2>&1 && echo 0 || echo $?
}

# Same, but without an explicit worker count, so the runner picks its own defaults.
run_with_default_jobs() {
    local steps_file="$TEST_ROOT/steps"
    printf '%s\n' "$@" >"$steps_file"
    RUN_TEST_SUITE_STEPS_FILE="$steps_file" "$RUNNER" >"$TEST_ROOT/output" 2>&1 && echo 0 || echo $?
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

# The iOS portability gate is one cross-compile per pinned package, and those builds
# share nothing -- each writes its own scratch path. Run as a single looping step it was
# the gate's whole critical path, so the pool expands it into one step per package.
# The list has to come from the gate's own discovery: a package list written here would
# drift from the manifests, and the drift would show up as a pinned package silently
# getting no step at all.
"$RUNNER" --list-steps >"$TEST_ROOT/step-list" 2>&1 \
    || fail "--list-steps failed: $(cat "$TEST_ROOT/step-list")"
if grep -qE '^\./scripts/ios-portability-gate\.sh$' "$TEST_ROOT/step-list"; then
    fail "the gate still runs the iOS sweep as one looping step"
fi
expected_ios="$("$REPO_ROOT/scripts/ios-portability-gate.sh" --list | wc -l | tr -d ' ')"
actual_ios="$(grep -cE '(^|^wide: )\./scripts/ios-portability-gate\.sh --package ' "$TEST_ROOT/step-list" || true)"
(( expected_ios > 0 )) || fail "the gate discovered no pinned packages to make steps from"
[[ "$actual_ios" == "$expected_ios" ]] \
    || fail "gate has $actual_ios iOS steps for $expected_ios pinned packages"

# Every iOS step is a SwiftPM cross-compile, so the whole class earns the wide marker.
# Which of them is cheap is not a property of the package: lib/TerminalCore measured 5s
# with a warm .build-ios-gate and 116s cold at -j1, and any commit touching its sources
# turns the first into the second. Marking the class rather than a measured subset also
# keeps this out of the drift the discovery loop exists to avoid.
wide_ios="$(grep -cE '^wide: \./scripts/ios-portability-gate\.sh --package ' "$TEST_ROOT/step-list" || true)"
[[ "$wide_ios" == "$expected_ios" ]] \
    || fail "$wide_ios of $expected_ios iOS steps declare themselves wide, so the rest compile at -j1"

# A long pole only widens where the pool is already idle, and the pool is only idle at
# the start of a run. A step that declares itself wide but is dispatched behind a hundred
# one-token steps therefore finds nothing free to claim, and the declaration buys it
# nothing. So the assembled list must lead with the wide steps -- including after the iOS
# package steps are spliced in, which is where the ordering used to be lost.
last_wide="$(grep -n '^wide: ' "$TEST_ROOT/step-list" | tail -1 | cut -d: -f1)"
first_plain="$(grep -vn '^wide: ' "$TEST_ROOT/step-list" | head -1 | cut -d: -f1)"
[[ "$last_wide" =~ ^[0-9]+$ ]] || fail "the gate declares no wide steps, so nothing pins the order"
[[ "$first_plain" =~ ^[0-9]+$ ]] || fail "the gate is entirely wide steps; the list is not what it was"
(( last_wide < first_plain )) \
    || fail "a one-token step is dispatched at line $first_plain, ahead of a wide step at line $last_wide"

# Leading with the wide group is not enough on its own: the pool is empty for one moment
# at the start of a run, and whichever wide steps reach it are the only ones whose ask
# finds anything free. So the heaviest step has to be the one dispatched into it. The iOS
# package steps are the trap here -- they are all wide, and splicing them in at the front
# once put ChipArtwork's 3s cross-compile in the slot the cold-build lane needed.
head_step="$(head -1 "$TEST_ROOT/step-list")"
[[ "$head_step" == *'swift build --build-tests --scratch-path'* ]] \
    || fail "the run leads with '$head_step', not the cold-build lane the list calls its longest step"

# The pool nests: each worker can be a whole `swift build`, and SwiftPM defaults to one
# compile job per core. Uncapped, N workers ask for N x ncpu compile jobs on an ncpu
# machine, which saturates the desktop and makes the OS UI lag. These cases pin the two
# halves of the bound -- the arithmetic, and the shim that carries it to every child.

# With defaults the runner leaves the machine some headroom: the firm tokens workers can
# hold at once must not exceed the cores it says it is budgeting for.
rc="$(run_with_default_jobs 'true')"
[[ "$rc" == "0" ]] || fail "default-jobs run exited $rc; expected 0"
header="$(grep '^run-test-suite: .*workers' "$TEST_ROOT/output")"
workers="$(sed -E 's/.*, ([0-9]+) parallel workers.*/\1/' <<<"$header")"
ask="$(sed -E 's/.*\(ask ([0-9]+)\).*/\1/' <<<"$header")"
budget="$(sed -E 's/.*, ([0-9]+) cpu tokens of [0-9]+ cores.*/\1/' <<<"$header")"
ncpu="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
[[ "$workers" =~ ^[0-9]+$ ]] || fail "header did not report a worker count: $header"
[[ "$ask" =~ ^[0-9]+$ ]] || fail "header did not report a per-worker token ask: $header"
[[ "$budget" =~ ^[0-9]+$ ]] || fail "header did not report a token budget: $header"
(( ask >= 1 )) || fail "per-worker token ask was $ask; expected at least 1"
(( workers <= budget )) \
    || fail "budget overshot: $workers workers can hold more firm tokens than the $budget budget"
(( budget < ncpu )) || fail "budget $budget left no headroom on a $ncpu-core machine"

# A larger worker count must shrink the per-worker ask rather than multiply through it.
# This is the case that actually bites: `just test 8` on an uncapped pool is 8 x ncpu.
# The step string stays single-quoted so the worker, not this test, expands it, and the
# token supervisor is what sets DANTERM_SWIFT_JOBS to the tokens the step really holds.
# shellcheck disable=SC2016
rc="$(run_with_steps 'test "$DANTERM_SWIFT_JOBS" -ge 1')"
[[ "$rc" == "0" ]] || fail "steps were not told how many tokens they hold"
header="$(grep '^run-test-suite: .*workers' "$TEST_ROOT/output")"
explicit_ask="$(sed -E 's/.*\(ask ([0-9]+)\).*/\1/' <<<"$header")"
(( explicit_ask * 4 <= budget || explicit_ask == 1 )) \
    || fail "4-worker override kept a per-worker ask of $explicit_ask"

# A declared long pole builds wide. Most of the gate is sub-second lint steps, so the
# default ask of one token is right for them -- but it also compiled the gate's two
# longest lanes at -j1, which measured 3x slower than a wide build of the same package.
# A step that marks itself wide asks for the whole budget instead.
# The step lines below carry no quotes: xargs -I strips them out of a step line.
# shellcheck disable=SC2016
rc="$(run_with_default_jobs 'wide: test $DANTERM_SWIFT_JOBS -gt 1')"
[[ "$rc" == "0" ]] || fail "a wide step got one compile job on an idle pool: $(cat "$TEST_ROOT/output")"

# The marker is a declaration, not part of the command line: the step that runs, and the
# step the report names, are both the command that follows the marker.
# shellcheck disable=SC2016
grep -qE '^  ok +[0-9]+s +test \$DANTERM_SWIFT_JOBS -gt 1$' "$TEST_ROOT/output" \
    || fail "wide marker was not stripped from the reported step: $(cat "$TEST_ROOT/output")"

# A step that does not declare itself wide still holds exactly one token, so the light
# lint tail cannot sit on half the budget while a long pole waits behind it.
# shellcheck disable=SC2016
rc="$(run_with_default_jobs 'test $DANTERM_SWIFT_JOBS -eq 1')"
[[ "$rc" == "0" ]] || fail "an undeclared step was given more than one token: $(cat "$TEST_ROOT/output")"

# A wide ask is opportunistic and must never wait. This is the property the whole design
# rests on: a claimant that blocked while holding would reintroduce the deadlock the
# token pool has no admission lock to prevent. The holder below keeps every token but one
# until the wide step has run, so the step demonstrably finished against a full pool.
cat >"$TEST_ROOT/saturate.sh" <<CASE
#!/usr/bin/env bash
# Holds all but one token until the wide step runs. The deadline is a hang guard: it
# fails by name so a wide step that blocks does not read as an unrelated slow test.
touch "$TEST_ROOT/saturated"
deadline=\$((SECONDS + 60))
until [[ -e "$TEST_ROOT/wide-ran" ]]; do
    (( SECONDS < deadline )) || { echo "saturating holder timed out" >&2; exit 70; }
    sleep 0.05
done
CASE
(
    "$REPO_ROOT/scripts/gate-cpu-tokens.py" --ask $((budget - 1)) --pool "$budget" \
        -- bash "$TEST_ROOT/saturate.sh"
) &
saturator=$!
saturate_deadline=$((SECONDS + 60))
until [[ -e "$TEST_ROOT/saturated" ]]; do
    (( SECONDS < saturate_deadline )) || {
        kill -9 "$saturator" 2>/dev/null || true
        fail "the holder never claimed its share of the test pool"
    }
    sleep 0.05
done

rc="$(run_with_default_jobs "wide: touch $TEST_ROOT/wide-ran; test \$DANTERM_SWIFT_JOBS -eq 1")"
[[ "$rc" == "0" ]] \
    || fail "a wide step waited for extras against a full pool: $(cat "$TEST_ROOT/output")"
wait "$saturator" || fail "the saturating holder did not exit cleanly"

# `just test-serial` runs one step at a time with an ask of the whole budget, so a solo
# serial run still builds wide. The wide marker must not narrow that.
run_serial() {
    printf '%s\n' "$@" >"$TEST_ROOT/steps"
    JOBS=1 RUN_TEST_SUITE_STEPS_FILE="$TEST_ROOT/steps" "$RUNNER" \
        >"$TEST_ROOT/output" 2>&1 && echo 0 || echo $?
}
rc="$(run_serial "test \$DANTERM_SWIFT_JOBS -eq $budget")"
[[ "$rc" == "0" ]] \
    || fail "the serial path did not give its one step the whole budget: $(cat "$TEST_ROOT/output")"

# The cap has to reach every descendant, not just the `swift` calls written in the step
# list: steps call scripts, and those scripts call SwiftPM too. A shim first on PATH is
# the only placement a new call site cannot forget, so pin that `swift` resolves to it
# and that it injects -j into a build. DANTERM_SWIFT is the project's existing override
# for which swift to run, so pointing it at `echo` reveals the command line.
run_shim_step() {
    printf '%s\n' "$1" >"$TEST_ROOT/steps"
    DANTERM_SWIFT=/bin/echo RUN_TEST_SUITE_STEPS_FILE="$TEST_ROOT/steps" "$RUNNER" 4 \
        >"$TEST_ROOT/shim-output" 2>&1 \
        || fail "shim run failed: $(cat "$TEST_ROOT/shim-output")"
}

run_shim_step 'swift build --package-path lib/TerminalCore >"'"$TEST_ROOT"'/shim-cmd"'
grep -qE '^build -j [0-9]+ --package-path lib/TerminalCore$' "$TEST_ROOT/shim-cmd" \
    || fail "shim did not inject a job cap into swift build: $(cat "$TEST_ROOT/shim-cmd")"

# Non-build subcommands take no -j; injecting one would break them.
run_shim_step 'swift --version >"'"$TEST_ROOT"'/shim-version"'
if grep -q -- '-j' "$TEST_ROOT/shim-version"; then
    fail "shim injected a job cap into a non-build subcommand: $(cat "$TEST_ROOT/shim-version")"
fi

# The gate runs below normal scheduling priority, so the foreground UI wins the CPU it
# needs even while the pool is packed. Without this the desktop stalls for the whole run.
# The step carries no quotes on purpose: xargs -I strips them out of the step line.
# shellcheck disable=SC2016
rc="$(run_with_steps 'test $(ps -o nice= -p $$) -gt 0')"
[[ "$rc" == "0" ]] || fail "gate steps did not run at reduced scheduling priority"

# The budget is machine-wide, not per run. This is the case the pool exists for: several
# agents in separate worktrees each used to reserve the same cores, so N concurrent
# gates asked the machine for N times its budget and every one of them ran slower than
# a serial gate would have. Two runs are started against one shared pool and every step
# records the interval it occupied; the peak overlap computed from those intervals is
# what the budget has to hold down.
#
# Overlap is computed from recorded intervals rather than sampled while the runs go, so
# the verdict is exact rather than dependent on catching the pool at its peak.
mkdir -p "$TEST_ROOT/intervals"
cat >"$TEST_ROOT/observe.sh" <<'OBSERVE'
#!/usr/bin/env bash
# One gate step that does nothing but record when it held a token.
exec python3 -c 'import os, sys, time
started = time.time()
time.sleep(0.4)
with open(os.path.join(sys.argv[1], str(os.getpid())), "w") as record:
    record.write(f"{started} {time.time()}")' "$1"
OBSERVE

# The step line carries no quotes: xargs -I strips them out.
for run in a b; do
    : >"$TEST_ROOT/steps-$run"
    for _ in $(seq 1 8); do
        echo "bash $TEST_ROOT/observe.sh $TEST_ROOT/intervals" >>"$TEST_ROOT/steps-$run"
    done
done

RUN_TEST_SUITE_STEPS_FILE="$TEST_ROOT/steps-a" "$RUNNER" 8 >"$TEST_ROOT/shared-a" 2>&1 &
run_a=$!
RUN_TEST_SUITE_STEPS_FILE="$TEST_ROOT/steps-b" "$RUNNER" 8 >"$TEST_ROOT/shared-b" 2>&1 &
run_b=$!

# A hang guard, not a measurement: 16 sleeps of 0.4s finish in seconds even on a packed
# machine, so only a wedged pool can reach this deadline. It fails by name so a stuck
# token pool does not read as an unrelated slow test.
guard_deadline=$((SECONDS + 120))
for pid in $run_a $run_b; do
    while kill -0 "$pid" 2>/dev/null; do
        (( SECONDS < guard_deadline )) || {
            kill -9 $run_a $run_b 2>/dev/null || true
            fail "concurrent runs did not finish within 120s; the token pool is wedged"
        }
        sleep 0.1
    done
done
wait $run_a || fail "first concurrent run failed: $(cat "$TEST_ROOT/shared-a")"
wait $run_b || fail "second concurrent run failed: $(cat "$TEST_ROOT/shared-b")"

# Every step holds at least one firm token, so the peak number of overlapping steps
# across both runs is bounded by the pool size itself.
header="$(grep -h '^run-test-suite: .*workers' "$TEST_ROOT/shared-a")"
budget="$(sed -E 's/.*, ([0-9]+) cpu tokens of [0-9]+ cores.*/\1/' <<<"$header")"
allowed=$budget
observed="$(python3 -c 'import pathlib, sys
events = []
for record in pathlib.Path(sys.argv[1]).iterdir():
    start, end = (float(value) for value in record.read_text().split())
    events += [(start, 1), (end, -1)]
peak = live = 0
for _, delta in sorted(events):
    live += delta
    peak = max(peak, live)
print(peak)' "$TEST_ROOT/intervals")"

(( observed <= allowed )) \
    || fail "two runs overlapped $observed steps against a machine budget of $allowed"
(( allowed < 2 || observed >= 2 )) \
    || fail "pool serialized the gate to $observed step at a time; expected up to $allowed"

echo "run-test-suite_test: ok"
