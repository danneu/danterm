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

# Ordered longest-measured-first. With a bounded pool this is list scheduling: putting
# the long poles in front keeps the tail from being one slow step finishing alone.
#
# Every entry is a command line for a worker to expand, never for this file to expand,
# so a `$` inside one stays single-quoted on purpose.
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
    'scratch=$(mktemp -d); swift build --build-tests --scratch-path $scratch; rc=$?; rm -rf $scratch; exit $rc'
    # The type-check budget lives in lib/TerminalCore/Package.swift, so this lane needs
    # no extra flags -- but the compiler only warns, and this pool discards a passing
    # step's output, so the wrapper is what turns a breach into a red step. It keeps its
    # own scratch path: the compiler reports an over-budget body only when it
    # type-checks that body, so what the gate can measure is exactly what the gate's own
    # build has to recompile. A tree only gate runs touch guarantees every file changed
    # since the last `just test` is re-type-checked, and therefore measured, during the
    # run that judges it.
    './scripts/type-check-budget-gate.sh swift test --package-path lib/TerminalCore --scratch-path lib/TerminalCore/.build-gate'
    './scripts/ios-portability-gate.sh'
    'swift test --package-path ios/DanTermMobileKit --scratch-path ios/DanTermMobileKit/.build-gate'
    './scripts/test-terminal-pty.sh'
    './scripts/tests/terminal-capture-api-gate_test.sh'
    './scripts/tests/terminal-capture-api-gate-cache_test.sh'
    './scripts/tests/shell-integration_test.sh'
    'python3 ./scripts/tests/fetch_references_test.py'
    'swift test --package-path lib/DanTermCore'
    './scripts/tests/danterm-cli-connect-errors_test.sh'
    'swift test --package-path lib/DanTermProtocol'
    'swift test --package-path lib/DanTermClient'
    'swift test --package-path lib/ChipArtwork'
    'python3 ./scripts/tests/terminal_benchmark_snapshot_test.py'
    'python3 ./scripts/tests/dev-slot-launcher_test.py'
    './scripts/tests/dev-build-configuration-contract_test.sh'
    './scripts/tests/build-app-helpers-contract_test.sh'
    'python3 ./scripts/tests/terminal_benchmark_calibration_test.py'
    'swift test --package-path lib/DanTermSupport'
    'swift test --scratch-path .build-app-tests'
    './scripts/tests/core-purity-lint_test.sh'
    './scripts/tests/run-test-suite_test.sh'
    './scripts/tests/gate-cpu-tokens_test.sh'
    './scripts/gate-test-coverage-lint.py'
    'python3 ./scripts/tests/gate_test_coverage_lint_test.py'
    './scripts/manifest-ownership-lint.py'
    'python3 ./scripts/tests/manifest_ownership_lint_test.py'
    './scripts/tests/ios-portability-gate_test.sh'
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
    './scripts/core-purity-lint.sh --allow-imports DequeModule lib/TerminalCore/Sources/TerminalCore'
    './scripts/core-purity-lint.sh lib/TerminalCore/Sources/TerminalCore'
    './scripts/tests/bundle-theme-resources_test.sh'
    './scripts/tests/verify-bundle-layout_test.sh'
    './scripts/tests/bundle-transformations_test.sh'
    './scripts/tests/terminal-fence-accounting-lint_test.sh'
    './scripts/tests/terminal-pty-host-test-seam-lint_test.sh'
    './scripts/terminal-pty-host-test-seam-lint.sh'
    './scripts/tests/terminal-exit-concurrency-lint_test.sh'
    './scripts/tests/checkpoint-off-main-lint_test.sh'
    './scripts/tests/reconcile-pass-lint_test.sh'
    './scripts/tests/reducer-command-discard-lint_test.sh'
    './scripts/tests/type-check-budget-gate_test.sh'
    './scripts/tests/terminal-scalar-append-lint_test.sh'
    './scripts/tests/terminal-benchmark-draw-path-lint_test.sh'
    'python3 ./scripts/tests/terminal_btop_gui_proof_test.py'
    'python3 ./scripts/tests/terminal_benchmark_workloads_test.py'
    'python3 ./scripts/tests/terminal_benchmark_plan_calibration_test.py'
    'python3 ./scripts/tests/terminal_benchmark_candidate_screen_test.py'
    './scripts/core-purity-lint.sh'
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
    'python3 ./scripts/tests/terminal_fixed_cost_probe_test.py'
    'python3 ./scripts/tests/terminal_btop_stimulus_test.py'
    'python3 ./scripts/tests/terminal_btop_artifacts_test.py'
    'python3 ./scripts/tests/terminal_btop_workload_test.py'
    './scripts/core-purity-lint.sh --allow-imports TerminalCore lib/TerminalCore/Sources/TerminalRenderPlanning'
    './scripts/core-purity-lint.sh lib/TerminalPTY/Sources/PaneProcessLifecycle'
    './scripts/core-purity-lint.sh lib/TerminalCore/Sources/TerminalRenderPlanning'
    './scripts/core-purity-lint.sh --forbid-imports lib/TerminalPTY/Sources/PaneProcessLifecycle'
    './scripts/terminal-exit-concurrency-lint.sh'
    './scripts/checkpoint-off-main-lint.sh'
    './scripts/reconcile-pass-lint.sh'
    './scripts/reducer-command-discard-lint.sh'
    './scripts/terminal-scalar-append-lint.sh'
    './scripts/terminal-benchmark-draw-path-lint.sh'
    './scripts/core-purity-lint.sh --profile portable lib/DanTermSupport/Sources/DanTermSupport'
    './scripts/core-purity-lint.sh --profile portable lib/DanTermProtocol/Sources/DanTermProtocol'
    './scripts/core-purity-lint.sh --profile portable lib/DanTermClient/Sources/DanTermClient'
    './scripts/core-purity-lint.sh --profile portable ios/DanTermMobileKit/Sources/DanTermMobileKit'
)

# Test seam: the self-test substitutes a synthetic step list so it can exercise the
# pool's failure reporting without running the real gate. Nothing else sets this.
if [[ -n "${RUN_TEST_SUITE_STEPS_FILE:-}" ]]; then
    STEPS=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && STEPS+=("$line")
    done <"$RUN_TEST_SUITE_STEPS_FILE"
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
    # Worker pid disambiguates the rare case of two identical step strings; the hash
    # keeps the filename traceable back to a step while debugging.
    log="$RUN_TEST_SUITE_LOGS/$$-$(printf '%s' "$step" | shasum | cut -c1-12)"
    printf '%s\n' "$step" >"$log.cmd"
    start=$SECONDS
    # Every step holds its share of the machine-wide budget for as long as it runs: the
    # helper blocks until that share is free, then supervises the step and gives the
    # share back when it ends. The share is what bounds this host's total gate load, so
    # concurrent runs in other checkouts queue here instead of oversubscribing the CPU.
    if DANTERM_GATE_TOKEN_WAIT_FILE="$log.wait" \
        "$REPO_ROOT/scripts/gate-cpu-tokens.py" \
        --weight "${DANTERM_SWIFT_JOBS:-1}" --pool "$BUDGET" \
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
# Two numbers bound it instead, and one flag would not:
#   * BUDGET     -- total compile jobs the gate may ask for. Two cores stay unspoken for
#                   so the WindowServer and the foreground app keep somewhere to run.
#   * SWIFT_JOBS -- per-worker cap, derived from the budget and whatever JOBS ended up
#                   being, so an override like `just test 8` shrinks the inner number
#                   rather than multiplying through it.
#
# BUDGET is spent against a pool shared by every checkout on the machine, not claimed
# fresh per run. Bounding it per process bounds nothing once several agents work in
# parallel worktrees: each one reserves the same cores, so N gates ask the host for N
# times its budget and all N finish later than a serial gate would have. Because BUDGET
# is derived from hw.ncpu alone, concurrent runs agree on the pool size without having
# to negotiate one. See scripts/gate-cpu-tokens.py.
#
# NCPU and BUDGET are computed at the top of this file, because a worker needs the pool
# size too.
JOBS="${1:-${JOBS:-$(( BUDGET / 2 ))}}"
(( JOBS < 1 )) && JOBS=1
SWIFT_JOBS=$(( BUDGET / JOBS ))
(( SWIFT_JOBS < 1 )) && SWIFT_JOBS=1
export DANTERM_SWIFT_JOBS="$SWIFT_JOBS"

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
# Generated by run-test-suite.sh. Caps SwiftPM build parallelism for every gate child.
# Only the subcommands that accept -j get it; the rest pass through untouched.
set -euo pipefail
case "\${1:-}" in
    build|test|run)
        exec "$REAL_SWIFT" "\$1" -j "\${DANTERM_SWIFT_JOBS:-2}" "\${@:2}"
        ;;
esac
exec "$REAL_SWIFT" "\$@"
EOF
    chmod +x "$SHIM_DIR/swift"
    export PATH="$SHIM_DIR:$PATH"
fi

echo "run-test-suite: ${#STEPS[@]} steps, $JOBS parallel workers," \
    "swift -j $SWIFT_JOBS each (<= $BUDGET of $NCPU cores)"
echo "run-test-suite: the $BUDGET-core budget is shared with every other gate on this" \
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
