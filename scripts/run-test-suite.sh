#!/usr/bin/env bash
# The `just test` gate, run as a bounded parallel job pool instead of a serial list.
#
# This file -- not the justfile -- is the source of truth for which steps make up the
# local gate. It lives here because the list needs two things a justfile recipe cannot
# express: an explicit ordering (longest step first, so the pool packs well) and
# per-step output capture (so concurrent steps do not interleave their stdout into
# unreadable mush). Add new gate steps to STEPS below, not to the justfile.
#
# Every step must be independent of every other one: no shared temp paths, no shared
# SwiftPM build directory, no shared port/socket. Steps that genuinely must run in
# sequence belong in a single STEPS entry joined with `&&`, which keeps them on one
# worker. See scripts/tests/run-test-suite_test.sh for the contract this upholds.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Keep Swift and xcrun compiler caches inside the writable workspace. Sandboxed agents cannot
# write Clang's default cache under ~/.cache, and every gate child inherits this boundary.
export CLANG_MODULE_CACHE_PATH="$REPO_ROOT/.build/clang-module-cache"

# Total compile jobs the gate may ask this machine for. Derived from hw.ncpu alone, so
# concurrent runs in different checkouts agree on the size of the pool they share
# without negotiating it. Computed up here because the worker branch below needs it as
# well; the rest of the budget arithmetic stays with its explanation further down.
NCPU="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
BUDGET=$(( NCPU - 2 ))
(( BUDGET < 2 )) && BUDGET=2

# Opens a step that declares itself a long pole; see the STEPS list and the concurrency
# budget below. The worker strips it before running or reporting the step, so nothing
# downstream of here ever sees it.
WIDE_MARKER='wide: '

# Ordered longest-measured-first. With a bounded pool this is list scheduling: putting
# the long poles in front keeps the tail from being one slow step finishing alone.
#
# Every entry is a command line for a worker to expand, never for this file to expand,
# so a `$` inside one stays single-quoted on purpose.
#
# A `wide: ` prefix declares a long pole: a step whose measured time is mostly one
# SwiftPM build, which at the default one token compiles at -j1. A wide step asks for the
# whole budget and takes only what is free at that instant, so it can never starve the
# rest of the gate -- it widens where the pool is already idle. Keep the marker for steps
# measured in tens of seconds of compiling; a lint that finishes in a second gains
# nothing from it and only adds noise here.
# shellcheck disable=SC2016
STEPS=(
    # The cold-build lane. Every other step builds into a warm per-purpose scratch --
    # .build-app-tests, .build-gate, the default .build -- so the gate cannot see a break
    # that stale incremental state hides. A package boundary that stops an access level
    # from reaching a consumer is exactly that kind of break: the warm lanes stayed green
    # while a cold `swift build --product DanTermCLI` failed. A throwaway scratch from
    # `mktemp -d` shares no build directory with anything, so the step is independent by
    # construction. It carries no quotes because xargs -I strips them from a step line.
    # Scope: the root graph, where every cross-manifest edge terminates. The nested
    # package test lanes and the iOS gate still build warm.
    'wide: scratch=$(mktemp -d); swift build --build-tests --scratch-path $scratch; rc=$?; rm -rf $scratch; exit $rc'
    # The type-check budget lives in lib/TerminalCore/Package.swift, so this lane needs
    # no extra flags -- but the compiler only warns, and this pool discards a passing
    # step's output, so the wrapper is what turns a breach into a red step. It keeps its
    # own scratch path: the compiler reports an over-budget body only when it
    # type-checks that body, so what the gate can measure is exactly what the gate's own
    # build has to recompile. A tree only gate runs touch guarantees every file changed
    # since the last `just test` is re-type-checked, and therefore measured, during the
    # run that judges it.
    'wide: ./scripts/type-check-budget-gate.sh swift test --package-path lib/TerminalCore --scratch-path lib/TerminalCore/.build-gate'
    'wide: swift test --package-path ios/DanTermMobileKit --scratch-path ios/DanTermMobileKit/.build-gate'
    'wide: ./scripts/test-terminal-pty.sh'
    'wide: ./scripts/tests/terminal-capture-api-gate_test.sh'
    './scripts/tests/terminal-capture-api-gate-cache_test.sh'
    './scripts/tests/shell-integration_test.sh'
    'python3 ./scripts/tests/fetch_references_test.py'
    'swift test --package-path lib/DanTermCore'
    './scripts/tests/bundle-contract-suite.sh'
    './scripts/tests/danterm-cli-connect-errors_test.sh'
    'swift test --package-path lib/DanTermProtocol'
    'swift test --package-path lib/DanTermClient'
    'swift test --package-path lib/ChipArtwork'
    'python3 ./scripts/tests/terminal_benchmark_snapshot_test.py'
    'python3 ./scripts/tests/dev-slot-launcher_test.py'
    'python3 ./scripts/tests/terminal_benchmark_calibration_test.py'
    'swift test --package-path lib/DanTermSupport'
    'wide: swift test --scratch-path .build-app-tests'
    './scripts/tests/core-purity-lint_test.sh'
    './scripts/tests/run-test-suite_test.sh'
    './scripts/tests/gate-cpu-tokens_test.sh'
    './scripts/gate-test-coverage-lint.py'
    'python3 ./scripts/tests/gate_test_coverage_lint_test.py'
    './scripts/manifest-ownership-lint.py'
    'python3 ./scripts/tests/manifest_ownership_lint_test.py'
    './scripts/generated-unicode-tables-lint.py'
    'python3 ./scripts/tests/generated_unicode_tables_lint_test.py'
    'python3 ./scripts/tests/manifest_targets_test.py'
    # The compiling half of the iOS gate's self-test. It runs its fixture cases in
    # parallel and is mostly SwiftPM startup, so it earns the wide marker.
    'wide: ./scripts/tests/ios-portability-gate_test.sh'
    # The half of the same self-test that answers from manifests alone. It is split out
    # because it needs no iOS SDK and no compiler at all, so it has no business paying
    # for one -- and because a broken manifest-discovery claim should be reported as
    # that, not as an iOS portability failure.
    './scripts/tests/ios-portability-gate-discovery_test.sh'
    './scripts/tests/ios-app_test.sh'
    'swift test --package-path lib/TerminalHostTools --scratch-path lib/TerminalHostTools/.build-gate'
    './scripts/tests/provision-worktree_test.sh'
    './scripts/tests/test-ui-harness_test.sh'
    './scripts/tests/research-index-lint_test.sh'
    'python3 ./scripts/tests/docs_lint_test.py'
    './scripts/tests/terminal-backend-boundary-lint_test.sh'
    './scripts/tests/agent-notifications-live_test.py'
    './scripts/terminal-backend-boundary-lint.sh'
    './scripts/chip-artwork-isolation-gate.sh'
    './scripts/tests/chip-artwork-isolation-gate_test.sh'
    './scripts/tests/test-terminal-pty_test.sh'
    './scripts/tests/test-terminal-pty-cleanup_test.sh'
    'python3 ./scripts/tests/pack_theme_catalog_test.py'
    'python3 ./scripts/tests/terminal_tape_to_fixture_test.py'
    'python3 ./scripts/tests/terminal_recording_schema_audit_test.py'
    'python3 ./scripts/terminal-recording-schema-audit.py'
    './scripts/tests/terminal-viability-harness_test.sh'
    './scripts/tests/terminal-benchmark-harness_test.sh'
    './scripts/core-purity-lint.sh'
    './scripts/tests/bundle-theme-resources_test.sh'
    './scripts/tests/terminal-fence-accounting-lint_test.sh'
    './scripts/tests/terminal-pty-host-test-seam-lint_test.sh'
    './scripts/terminal-pty-host-test-seam-lint.sh'
    './scripts/tests/terminal-exit-concurrency-lint_test.sh'
    './scripts/tests/ambient-identity-lint_test.sh'
    './scripts/tests/checkpoint-off-main-lint_test.sh'
    './scripts/tests/reconcile-pass-lint_test.sh'
    './scripts/tests/reducer-command-discard-lint_test.sh'
    './scripts/tests/type-check-budget-gate_test.sh'
    './scripts/tests/terminal-scalar-append-lint_test.sh'
    './scripts/tests/terminal-benchmark-draw-path-lint_test.sh'
    './scripts/tests/usage-single-source-lint_test.sh'
    'python3 ./scripts/tests/terminal_benchmark_workloads_test.py'
    'python3 ./scripts/tests/terminal_benchmark_plan_calibration_test.py'
    'python3 ./scripts/tests/terminal_benchmark_candidate_screen_test.py'
    './scripts/research-index-lint.sh'
    './scripts/docs-lint.py'
    './scripts/tests/just-clean_test.sh'
    './scripts/kitty-parity-lint.py'
    './scripts/tests/kitty-parity-lint_test.sh'
    './scripts/alacritty-parity-lint.py'
    './scripts/tests/alacritty-parity-lint_test.sh'
    'python3 ./scripts/tests/terminal_benchmark_validation_test.py'
    'python3 ./scripts/tests/terminal_benchmark_producer_test.py'
    'python3 ./scripts/tests/terminal_draw_acceptance_test.py'
    'python3 ./scripts/tests/terminal_benchmark_compare_test.py'
    'python3 ./scripts/tests/import_themes_test.py'
    './scripts/terminal-fence-accounting-lint.sh'
    'python3 ./scripts/tests/terminal_profile_report_test.py'
    'python3 ./scripts/tests/terminal_headless_draw_compare_test.py'
    'python3 ./scripts/tests/terminal_benchmark_fixtures_test.py'
    'python3 ./scripts/tests/terminal_retained_row_shape_test.py'
    'python3 ./scripts/tests/terminal_memory_profile_test.py'
    'python3 ./scripts/tests/terminal_btop_stimulus_test.py'
    'python3 ./scripts/tests/terminal_btop_artifacts_test.py'
    'python3 ./scripts/tests/terminal_btop_workload_test.py'
    './scripts/terminal-exit-concurrency-lint.sh'
    './scripts/ambient-identity-lint.sh'
    './scripts/checkpoint-off-main-lint.sh'
    './scripts/reconcile-pass-lint.sh'
    './scripts/reducer-command-discard-lint.sh'
    './scripts/terminal-scalar-append-lint.sh'
    './scripts/terminal-benchmark-draw-path-lint.sh'
    './scripts/usage-single-source-lint.sh'
)

# Test seam: the self-test substitutes a synthetic step list so it can exercise the
# pool's failure reporting without running the real gate. Nothing else sets this.
if [[ -n "${RUN_TEST_SUITE_STEPS_FILE:-}" ]]; then
    STEPS=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && STEPS+=("$line")
    done <"$RUN_TEST_SUITE_STEPS_FILE"
elif [[ "${1:-}" != "--worker" ]]; then
    # The iOS portability gate is one cross-compile per pinned package, and the packages
    # share nothing -- each writes its own scratch path inside itself. Looping over them
    # inside a single step hid that from the pool and made the sweep the gate's entire
    # critical path: one worker held one token while six independent builds ran in
    # series. One step per package lets them pack like everything else.
    #
    # The list comes from the gate's own discovery rather than from this file, because a
    # package list written here is a list that drifts. The gate reads the manifests, so a
    # newly pinned package gets a step by existing, which is the property the gate is for.
    # Discovery only greps manifests and needs no SDK, so it costs nothing here; it fails
    # loudly, before the header prints, if the pinned set is empty or DanTermSupport has
    # picked up a pin.
    #
    # Every one of these is a SwiftPM cross-compile, so the whole class carries the wide
    # marker. Which package is cheap is not a property of the package: lib/TerminalCore
    # took 5s with a warm .build-ios-gate and 116s cold at -j1, and any commit touching
    # its sources turns the first into the second. Marking the class rather than a
    # measured subset also keeps the marker out of the drift the discovery loop exists to
    # avoid -- a written-down list of which packages are expensive would go stale exactly
    # like a written-down list of which packages are pinned.
    #
    # These sort in front of the light lint tail but behind the poles declared above.
    ios_steps=()
    while IFS= read -r package; do
        [[ -n "$package" ]] \
            && ios_steps+=("${WIDE_MARKER}./scripts/ios-portability-gate.sh --package $package")
    done < <(./scripts/ios-portability-gate.sh --list)
    (( ${#ios_steps[@]} > 0 )) || {
        echo "run-test-suite: the iOS portability gate reported no pinned packages." >&2
        exit 1
    }
    # Appended, not prepended. These sort into the wide group either way, but a stable
    # partition keeps written order inside it, so prepending put the cheapest iOS steps
    # (ChipArtwork and the two small libraries, 2-4s each) at the head of the run -- the
    # one moment the token pool is empty and a wide ask can actually claim anything. The
    # measured long poles above have to be the steps that reach that idle pool.
    STEPS=("${STEPS[@]}" "${ios_steps[@]}")
fi

# Put the declared long poles at the head of the assembled list. A wide step's extra
# tokens are claimed opportunistically -- it takes only what is free at that instant and
# never waits -- so a long pole that starts late finds a full pool and compiles at one
# job, which is the whole thing the marker exists to avoid. The pool is idle only at the
# start of a run, so that is where the wide steps have to be dispatched. Writing them
# first in STEPS is not enough on its own: the iOS package steps are spliced in above,
# and they used to take the startup slots away from steps ten times their length.
#
# The reorder is stable, so within each group the list keeps the longest-measured-first
# order it is written in. It happens before --list-steps prints, so what a reader sees is
# the order the gate really dispatches.
if [[ "${1:-}" != "--worker" ]]; then
    wide_steps=()
    plain_steps=()
    for step in "${STEPS[@]}"; do
        if [[ "$step" == "$WIDE_MARKER"* ]]; then
            wide_steps+=("$step")
        else
            plain_steps+=("$step")
        fi
    done
    STEPS=()
    if (( ${#wide_steps[@]} > 0 )); then STEPS+=("${wide_steps[@]}"); fi
    if (( ${#plain_steps[@]} > 0 )); then STEPS+=("${plain_steps[@]}"); fi
fi

# Report the assembled list and stop. The list is built rather than written down, so
# this is how a reader -- and the self-test -- sees what the gate actually runs.
if [[ "${1:-}" == "--list-steps" ]]; then
    printf '%s\n' "${STEPS[@]}"
    exit 0
fi

# Time waiting for the machine-wide budget is reported apart from time spent running,
# so a step's own duration stays comparable between a quiet machine and a busy one.
# Reading the gate's timings would otherwise mean guessing how loaded the host was.
queue_seconds() {
    local waited
    waited="$(cat "$1.wait" 2>/dev/null || true)"
    [[ "$waited" =~ ^[0-9]+$ ]] || waited=0
    printf '%d' "$waited"
}

step_seconds() {
    local ran=$((SECONDS - start - $(queue_seconds "$1")))
    # Both terms are whole seconds from clocks that truncate, so a very short step can
    # subtract its way below zero. Report the floor rather than a negative duration.
    (( ran < 0 )) && ran=0
    printf '%d' "$ran"
}

queued_note() {
    local waited
    waited="$(queue_seconds "$1")"
    (( waited > 0 )) && printf ' +%ds queued' "$waited"
    return 0
}

# Worker mode: the pool re-invokes this script once per step. Output is captured to a
# file so a failing step can be replayed in one contiguous block at the end, rather
# than interleaved with whatever else was running at the same instant.
if [[ "${1:-}" == "--worker" ]]; then
    step="$2"
    # A declared long pole asks for the whole budget. The ask is opportunistic -- the
    # supervisor claims one token firmly and sweeps for the rest without ever waiting --
    # so a wide step still holds only tokens that stand behind work it is doing.
    ask="${DANTERM_GATE_ASK:-1}"
    if [[ "$step" == "$WIDE_MARKER"* ]]; then
        step="${step#"$WIDE_MARKER"}"
        (( ask < BUDGET )) && ask=$BUDGET
    fi
    # Worker pid disambiguates the rare case of two identical step strings; the hash
    # keeps the filename traceable back to a step while debugging.
    log="$RUN_TEST_SUITE_LOGS/$$-$(printf '%s' "$step" | shasum | cut -c1-12)"
    printf '%s\n' "$step" >"$log.cmd"
    start=$SECONDS
    # Every step holds one token of the machine-wide budget for as long as it runs: the
    # helper blocks until a token is free, then supervises the step and gives the token
    # back when it ends. The pool is what bounds this host's total gate load, so
    # concurrent runs in other checkouts queue here instead of oversubscribing the CPU.
    if DANTERM_GATE_TOKEN_WAIT_FILE="$log.wait" \
        "$REPO_ROOT/scripts/gate-cpu-tokens.py" \
        --ask "$ask" --pool "$BUDGET" \
        -- bash -c "$step" >"$log.out" 2>&1; then
        printf '  ok   %4ds%s  %s\n' "$(step_seconds "$log")" "$(queued_note "$log")" "$step"
    else
        rc=$?
        printf '%d\n' "$rc" >"$log.rc"
        printf '  FAIL %4ds%s  %s\n' "$(step_seconds "$log")" "$(queued_note "$log")" "$step"
    fi
    exit 0
fi

# Concurrency budget.
#
# The pool nests, and that is what hurts: a worker is often a whole `swift build`, and
# SwiftPM defaults to one compile job per core. Bounding only the worker count therefore
# bounds nothing -- N workers ask for N x ncpu compile jobs on an ncpu machine. The gate
# then owns every core at normal priority and the whole desktop stalls for the run.
#
# One machine-wide pool of BUDGET tokens bounds it instead. Every step holds exactly one
# token while it runs, and SwiftPM parallelism follows the tokens held (the helper tells
# the step through DANTERM_SWIFT_JOBS, the shim below carries it to SwiftPM). A
# reservation therefore always stands behind real work: the pool can only be full when
# BUDGET steps are actually running. Weighing steps up front was tried and mis-tuned the
# gate: a uniform weight of 2 let the light lint tail hold half the budget idle, and
# per-step guesses would drift as the step list does. BUDGET leaves two cores unspoken
# for, so the WindowServer and the foreground app keep somewhere to run.
#
# The pool is shared by every checkout on the machine, not claimed fresh per run.
# Bounding it per process bounds nothing once several agents work in parallel worktrees:
# each one reserves the same cores, so N gates ask the host for N times its budget and
# all N finish later than a serial gate would have. Because BUDGET is derived from
# hw.ncpu alone, concurrent runs agree on the pool size without having to negotiate one.
# See scripts/gate-cpu-tokens.py.
#
# ASK is the one knob left: a worker may take up to ASK - 1 extra tokens beyond its firm
# one, but only if they are free at that instant -- it never waits for them. With the
# default worker count ASK is 1, so tokens and steps stay one-to-one. Fewer workers mean
# a bigger ASK: `just test-serial` runs one step at a time with an ask of the whole
# budget, so a solo serial run still builds wide, and one beside other gates degrades
# toward -j1 instead of blocking for the whole pool.
#
# The default ASK of 1 is right for the sixty-odd lint steps that finish in under two
# seconds, and wrong for the handful of steps that are one whole SwiftPM build: a cold
# build of lib/DanTermCore measured 104s at -j1 against 35s at -j8. Those steps carry the
# `wide: ` marker in the list above and ask for the whole budget instead. The marker rides
# on the step string, so it stays attached to the step it describes rather than drifting
# in a second list, and because the ask is still opportunistic a wide step waits for
# nothing and holds nothing that is not standing behind its own compile.
#
# NCPU and BUDGET are computed at the top of this file, because a worker needs the pool
# size too.
JOBS="${1:-${JOBS:-$BUDGET}}"
(( JOBS < 1 )) && JOBS=1
ASK=$(( BUDGET / JOBS ))
(( ASK < 1 )) && ASK=1
export DANTERM_GATE_ASK="$ASK"

RUN_TEST_SUITE_LOGS="$(mktemp -d)"
trap 'rm -rf "$RUN_TEST_SUITE_LOGS"' EXIT
export RUN_TEST_SUITE_LOGS

# Carry the cap to SwiftPM through a `swift` shim placed first on PATH, not by adding -j
# to the step strings. The gate reaches SwiftPM three ways -- step strings in this file,
# the scripts those steps run, and the scripts those scripts run -- so a flag written at
# any one site is a flag the next site forgets. PATH is the one placement every
# descendant already goes through. DANTERM_SWIFT is the project's existing "which swift"
# override, and resolving it here, before PATH changes, keeps the shim from finding itself.
REAL_SWIFT="$(command -v "${DANTERM_SWIFT:-swift}" 2>/dev/null || true)"
if [[ -n "$REAL_SWIFT" ]]; then
    SHIM_DIR="$RUN_TEST_SUITE_LOGS/shim"
    mkdir -p "$SHIM_DIR"
    cat >"$SHIM_DIR/swift" <<EOF
#!/usr/bin/env bash
# Generated by run-test-suite.sh. Caps SwiftPM build parallelism for every gate child
# at the CPU tokens its step holds, which the token supervisor exports as
# DANTERM_SWIFT_JOBS. Only the subcommands that accept -j get it; the rest pass
# through untouched.
set -euo pipefail
case "\${1:-}" in
    build|test|run)
        exec "$REAL_SWIFT" "\$1" -j "\${DANTERM_SWIFT_JOBS:-1}" "\${@:2}"
        ;;
esac
exec "$REAL_SWIFT" "\$@"
EOF
    chmod +x "$SHIM_DIR/swift"
    export PATH="$SHIM_DIR:$PATH"
fi

echo "run-test-suite: ${#STEPS[@]} steps, $JOBS parallel workers," \
    "$BUDGET cpu tokens of $NCPU cores, swift -j follows tokens held (ask $ASK)"
echo "run-test-suite: the $BUDGET-token budget is shared with every other gate on this" \
    "machine, so steps queue while another checkout is testing"
started=$SECONDS

# nice(1) covers the pool and everything it forks. Leaving cores free is not enough on
# its own: the gate still competes with the UI for them, and losing that race is what
# the operator sees as lag.
printf '%s\n' "${STEPS[@]}" \
    | nice -n "${DANTERM_TEST_NICE:-10}" xargs -P "$JOBS" -I {} "$0" --worker {}

failed=0
for rc in "$RUN_TEST_SUITE_LOGS"/*.rc; do
    [[ -e "$rc" ]] || break
    base="${rc%.rc}"
    failed=$((failed + 1))
    echo
    echo "=============================================================================="
    echo "FAILED (exit $(cat "$rc")): $(cat "$base.cmd")"
    echo "=============================================================================="
    cat "$base.out"
done

echo
if (( failed > 0 )); then
    echo "run-test-suite: $failed of ${#STEPS[@]} steps FAILED in $((SECONDS - started))s"
    exit 1
fi
echo "run-test-suite: all ${#STEPS[@]} steps passed in $((SECONDS - started))s"
