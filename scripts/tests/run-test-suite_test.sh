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
actual_ios="$(grep -cE '^\./scripts/ios-portability-gate\.sh --package ' "$TEST_ROOT/step-list" || true)"
(( expected_ios > 0 )) || fail "the gate discovered no pinned packages to make steps from"
[[ "$actual_ios" == "$expected_ios" ]] \
    || fail "gate has $actual_ios iOS steps for $expected_ios pinned packages"

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
