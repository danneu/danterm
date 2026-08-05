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

# Ordered longest-measured-first. With a bounded pool this is list scheduling: putting
# the long poles in front keeps the tail from being one slow step finishing alone.
STEPS=(
    'swift test --package-path lib/TerminalCore --scratch-path lib/TerminalCore/.build-gate -Xswiftc -Xfrontend -Xswiftc -warn-long-function-bodies=500'
    './scripts/test-terminal-pty.sh'
    './scripts/tests/terminal-capture-api-gate_test.sh'
    './scripts/tests/shell-integration_test.sh'
    'python3 ./scripts/tests/fetch_references_test.py'
    'swift test --package-path lib/DanTermCore'
    './scripts/tests/danterm-cli-connect-errors_test.sh'
    'swift test --package-path lib/DanTermProtocol --filter DanTermProtocolTests'
    'python3 ./scripts/tests/terminal_benchmark_snapshot_test.py'
    'python3 ./scripts/tests/dev-slot-launcher_test.py'
    './scripts/tests/dev-build-configuration-contract_test.sh'
    'python3 ./scripts/tests/terminal_benchmark_calibration_test.py'
    'swift test --package-path lib/DanTermSupport'
    'swift test --scratch-path .build-app-tests'
    './scripts/tests/core-purity-lint_test.sh'
    './scripts/tests/run-test-suite_test.sh'
    './scripts/tests/terminal-characterization-harness_test.sh'
    './scripts/tests/research-index-lint_test.sh'
    './scripts/tests/terminal-backend-boundary-lint_test.sh'
    './scripts/tests/agent-notifications-live_test.py'
    './scripts/terminal-backend-boundary-lint.sh'
    './scripts/tests/test-terminal-pty_test.sh'
    'python3 ./scripts/tests/pack_theme_catalog_test.py'
    'python3 ./scripts/tests/terminal_tape_to_fixture_test.py'
    'python3 ./scripts/tests/terminal_recording_research_producers_test.py'
    'python3 ./scripts/tests/terminal_recording_schema_audit_test.py'
    'python3 ./scripts/terminal-recording-schema-audit.py'
    './scripts/tests/build-lib-contract_test.sh'
    './scripts/tests/terminal-viability-harness_test.sh'
    './scripts/tests/build-lib-fetch_test.sh'
    './scripts/tests/terminal-benchmark-harness_test.sh'
    './scripts/core-purity-lint.sh --forbid-imports lib/TerminalCore/Sources/TerminalCore'
    './scripts/core-purity-lint.sh lib/TerminalCore/Sources/TerminalCore'
    './scripts/tests/load-ghostty-version_test.sh'
    './scripts/tests/terminal-fence-accounting-lint_test.sh'
    './scripts/tests/terminal-exit-concurrency-lint_test.sh'
    './scripts/tests/checkpoint-off-main-lint_test.sh'
    './scripts/tests/terminal-scalar-append-lint_test.sh'
    './scripts/tests/terminal-benchmark-draw-path-lint_test.sh'
    './scripts/tests/build-lib-stale-guard_test.sh'
    './scripts/tests/terminal-benchmark-commands_test.sh'
    'python3 ./scripts/tests/terminal_btop_gui_proof_test.py'
    'python3 ./scripts/tests/terminal_benchmark_workloads_test.py'
    'python3 ./scripts/tests/terminal_benchmark_plan_calibration_test.py'
    'python3 ./scripts/tests/terminal_benchmark_candidate_screen_test.py'
    './scripts/core-purity-lint.sh'
    './scripts/research-index-lint.sh'
    './scripts/kitty-parity-lint.py'
    './scripts/tests/kitty-parity-lint_test.sh'
    './scripts/alacritty-parity-lint.py'
    './scripts/tests/alacritty-parity-lint_test.sh'
    'python3 ./scripts/tests/terminal_benchmark_validation_test.py'
    'python3 ./scripts/tests/terminal_benchmark_producer_test.py'
    'python3 ./scripts/tests/terminal_draw_acceptance_test.py'
    'python3 ./scripts/tests/terminal_benchmark_compare_test.py'
    'python3 ./scripts/tests/import_ghostty_themes_test.py'
    './scripts/terminal-fence-accounting-lint.sh'
    'python3 ./scripts/tests/terminal_profile_report_test.py'
    'python3 ./scripts/tests/terminal_headless_draw_compare_test.py'
    'python3 ./scripts/tests/terminal_benchmark_fixtures_test.py'
    'python3 ./scripts/tests/terminal_retained_row_shape_test.py'
    'python3 ./scripts/tests/terminal_memory_profile_test.py'
    'python3 ./scripts/tests/terminal_btop_stimulus_test.py'
    'python3 ./scripts/tests/terminal_btop_artifacts_test.py'
    'python3 ./scripts/tests/terminal_btop_workload_test.py'
    './scripts/core-purity-lint.sh --allow-imports TerminalCore lib/TerminalCore/Sources/TerminalRenderPlanning'
    './scripts/core-purity-lint.sh lib/TerminalPTY/Sources/PaneLifecycle'
    './scripts/core-purity-lint.sh lib/TerminalCore/Sources/TerminalRenderPlanning'
    './scripts/core-purity-lint.sh --forbid-imports lib/TerminalPTY/Sources/PaneLifecycle'
    './scripts/terminal-exit-concurrency-lint.sh'
    './scripts/checkpoint-off-main-lint.sh'
    './scripts/terminal-scalar-append-lint.sh'
    './scripts/terminal-benchmark-draw-path-lint.sh'
    './scripts/core-purity-lint.sh --profile portable lib/DanTermSupport/Sources/DanTermSupport'
)

# Test seam: the self-test substitutes a synthetic step list so it can exercise the
# pool's failure reporting without running the real gate. Nothing else sets this.
if [[ -n "${RUN_TEST_SUITE_STEPS_FILE:-}" ]]; then
    STEPS=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && STEPS+=("$line")
    done <"$RUN_TEST_SUITE_STEPS_FILE"
fi

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
    if bash -c "$step" >"$log.out" 2>&1; then
        printf '  ok   %4ds  %s\n' "$((SECONDS - start))" "$step"
    else
        rc=$?
        printf '%d\n' "$rc" >"$log.rc"
        printf '  FAIL %4ds  %s\n' "$((SECONDS - start))" "$step"
    fi
    exit 0
fi

# Swift builds already saturate the machine on their own, so one worker per core
# oversubscribes badly. Half the cores keeps the long poles overlapped without
# thrashing; override with `just test 8` or JOBS=8.
default_jobs=$(( $(sysctl -n hw.ncpu 2>/dev/null || echo 4) / 2 ))
(( default_jobs < 2 )) && default_jobs=2
JOBS="${1:-${JOBS:-$default_jobs}}"

RUN_TEST_SUITE_LOGS="$(mktemp -d)"
trap 'rm -rf "$RUN_TEST_SUITE_LOGS"' EXIT
export RUN_TEST_SUITE_LOGS

echo "run-test-suite: ${#STEPS[@]} steps, $JOBS parallel workers"
started=$SECONDS

printf '%s\n' "${STEPS[@]}" | xargs -P "$JOBS" -I {} "$0" --worker {}

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
