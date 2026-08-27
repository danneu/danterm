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
#
# A lint added here owes its reader an explanation on the failure path, not only in its
# own header comment: stderr is all that whoever trips the gate sees. scripts/lib/lint-rationale.sh
# is the shared shape, and each lint's self-test is where that explanation is pinned.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/scripts/lib/build-paths.sh"

TYPE_CHECK_BUILD="$(danterm_gate_build_path "$REPO_ROOT" terminal-core-type-check)"
MOBILE_KIT_BUILD="$(danterm_gate_build_path "$REPO_ROOT" mobile-kit-tests)"
APP_TEST_BUILD="$(danterm_gate_build_path "$REPO_ROOT" root-app-tests)"
HOST_TOOLS_BUILD="$(danterm_gate_build_path "$REPO_ROOT" terminal-host-tools-tests)"
SKILL_SYNOPSIS_BUILD="$(danterm_gate_build_path "$REPO_ROOT" skill-synopsis-check)"
CLANG_CACHE="$(danterm_gate_build_path "$REPO_ROOT" clang-module-cache)"

if [[ "${1:-}" == "--list-build-paths" ]]; then
    printf 'clang-module-cache\tgate\t%s\n' "$CLANG_CACHE"
    exit 0
fi

# `just lint` runs the rule checks alone. The flag is consumed here so that every `$1`
# test further down still sees the worker, list-steps, or jobs argument it expects.
LINT_ONLY=0
if [[ "${1:-}" == "--lint-only" ]]; then
    LINT_ONLY=1
    shift
fi

# The supervisor gives lint workers their own mode so they can keep the gate's output
# capture without entering the CPU-token pool. These flags are internal re-entry points.
WORKER_MODE=0
LINT_WORKER=0
case "${1:-}" in
    --worker)
        WORKER_MODE=1
        ;;
    --lint-worker)
        WORKER_MODE=1
        LINT_WORKER=1
        ;;
esac

# Keep Swift and xcrun compiler caches inside the writable workspace. Sandboxed agents cannot
# write Clang's default cache under ~/.cache, and every gate child inherits this boundary.
export CLANG_MODULE_CACHE_PATH="$CLANG_CACHE"

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

# How many tokens a `wide: ` step asks for. The ask is opportunistic, but a token a wide
# step wins is held until that step ends -- so this number is really a cap on how many
# long poles can compile beside each other, and asking for the whole budget means one
# pole runs while every other worker blocks. The gate has about a dozen wide steps and
# only a handful of cores, so serializing them is the worst arrangement available.
#
# Measured on this 10-core host, interleaved A/B, three runs per arm plus earlier
# samples: an ask of BUDGET gave {141, 159, 160, 233}s and an ask of 2 gave
# {89, 90, 90, 117, 120}s. The arms do not overlap. An ask of 1 (marker off) measured
# 124s and an ask of 3 measured 127s, so 2 is not merely "less than BUDGET" -- it is the
# floor of the curve, where four poles compile at -j2 instead of one at -j8.
#
# DANTERM_GATE_WIDE_ASK overrides it, which is how the arms above were measured.
WIDE_ASK="${DANTERM_GATE_WIDE_ASK:-2}"
(( WIDE_ASK > BUDGET )) && WIDE_ASK=$BUDGET
(( WIDE_ASK < 1 )) && WIDE_ASK=1

# The rule checks, as one named subset. These run against the working tree rather than
# against a package, so they are what `just lint` runs on its own: an agent in a
# red-green-refactor loop needs them every iteration, and needs the rest of the gate
# only before a commit. Their self-tests stay in STEPS -- those check the lint scripts,
# not the tree, so they matter when you edit a lint and not while you edit anything else.
#
# Defined once and spliced into STEPS below, so the two lists cannot drift apart.
# shellcheck disable=SC2016
LINT_STEPS=(
    './scripts/build-path-policy.sh'
    './scripts/swift-file-header-lint.sh'
    './scripts/gate-test-coverage-lint.py'
    './scripts/manifest-ownership-lint.py'
    './scripts/engine-publishable-lint.sh'
    './scripts/generated-unicode-tables-lint.py'
    './scripts/generate-terminal-capability-projection.py --check'
    "swift run --scratch-path $SKILL_SYNOPSIS_BUILD DanTermSkillSynopsisGenerator --check integrations/danterm/SKILL.md"
    './scripts/terminal-backend-boundary-lint.sh'
    './scripts/chip-artwork-isolation-gate.sh'
    'python3 ./scripts/terminal-recording-schema-audit.py'
    './scripts/core-purity-lint.sh'
    './scripts/terminal-pty-host-test-seam-lint.sh'
    './scripts/research-index-lint.sh'
    './scripts/docs-lint.py'
    './scripts/kitty-parity-lint.py'
    './scripts/alacritty-parity-lint.py'
    './scripts/external-corpus-ledger-lint.py'
    './scripts/terminal-fence-accounting-lint.sh'
    './scripts/terminal-exit-concurrency-lint.sh'
    './scripts/ambient-identity-lint.sh'
    './scripts/private-file-mode-lint.sh'
    './scripts/checkpoint-off-main-lint.sh'
    './scripts/reconcile-pass-lint.sh'
    './scripts/reducer-command-discard-lint.sh'
    './scripts/terminal-scalar-append-lint.sh'
    './scripts/terminal-benchmark-draw-path-lint.sh'
    './scripts/agents-md-budget-lint.sh'
    './scripts/scripts-swift-orphan-lint.py'
    'python3 ./scripts/checkpoint-projection-cost.py --check'
)

# Ordered longest-measured-first. With a bounded pool this is list scheduling: putting
# the long poles in front keeps the tail from being one slow step finishing alone.
#
# Every entry is a command line for a worker to expand, never for this file to expand,
# so a `$` inside one stays single-quoted on purpose.
#
# A `wide: ` prefix declares a long pole: a step whose measured time is mostly one
# SwiftPM build, which at the default one token compiles at -j1. A wide step asks for
# WIDE_ASK tokens rather than one; see the note on WIDE_ASK below for why that number is
# small. Keep the marker for steps measured in tens of seconds of compiling; a lint that
# finishes in a second gains nothing from it and only adds noise here.
# shellcheck disable=SC2016
STEPS=(
    # The cold-build lane. Every other step builds into a warm per-purpose scratch --
    # the persistent per-lane trees and the default .build -- so the gate cannot see a break
    # that stale incremental state hides. A package boundary that stops an access level
    # from reaching a consumer is exactly that kind of break: the warm lanes stayed green
    # while a cold `swift build --product DanTermCLI` failed. A throwaway scratch from
    # `mktemp -d` shares no build directory with anything, so the step is independent by
    # construction. It carries no quotes because xargs -I strips them from a step line.
    # Scope: the root graph, where every cross-manifest edge terminates. The nested
    # package test lanes and the iOS gate still build warm.
    'wide: scratch=$(mktemp -d); swift build --build-tests --scratch-path $scratch; rc=$?; rm -rf $scratch; exit $rc'
    # The wrapper owns the type-check budget: it appends the measurement flags to this
    # command, so no other build carries them, and it turns a breach into a red step --
    # the compiler only warns, and this pool discards a passing step's output. It keeps its
    # own scratch path: the compiler reports an over-budget body only when it
    # type-checks that body, so what the gate can measure is exactly what the gate's own
    # build has to recompile. A tree only gate runs touch guarantees every file changed
    # since the last `just test` is re-type-checked, and therefore measured, during the
    # run that judges it.
    "wide: ./scripts/type-check-budget-gate.sh swift test --package-path lib/TerminalCore --scratch-path $TYPE_CHECK_BUILD"
    "wide: swift test --package-path ios/DanTermMobileKit --scratch-path $MOBILE_KIT_BUILD"
    # MiniTerm is the engine's API probe: the smallest real embedding, built from
    # outside the app module. It has no test target, so the build *is* the assertion --
    # a public engine API that stops being usable from outside fails here as a compile
    # error rather than as an opinion. A probe nobody builds is not a probe, so this
    # step is what keeps the example honest.
    'wide: swift build --package-path examples/MiniTerm'
    'wide: ./scripts/test-terminal-pty.sh'
    'wide: ./scripts/tests/terminal-capture-api-gate_test.sh'
    './scripts/tests/terminal-capture-api-gate-cache_test.sh'
    './scripts/tests/shell-integration_test.sh'
    'python3 ./scripts/tests/fetch_references_test.py'
    'swift test --package-path lib/DanTermCore'
    'source ./scripts/lib/bundle-layout-tool.sh && bundle_layout_tool_init . && export DANTERM_BUNDLE_LAYOUT_TOOL="$(bundle_layout_tool_path)" && ./scripts/tests/verify-bundle-layout_test.sh && ./scripts/tests/dev-build-configuration-contract_test.sh && ./scripts/tests/build-app-helpers-contract_test.sh && ./scripts/tests/bundle-transformations_test.sh && ./scripts/tests/bundle-layout-tool_test.sh'
    './scripts/tests/danterm-cli-connect-errors_test.sh'
    'swift test --package-path lib/DanTermProtocol'
    'swift test --package-path lib/DanTermClient'
    'swift test --package-path lib/ChipArtwork'
    'python3 ./scripts/tests/terminal_benchmark_snapshot_test.py'
    'python3 ./scripts/tests/terminal_pane_tape_observer_tax_test.py'
    'python3 ./scripts/tests/terminal_benchmark_pane_tape_follower_test.py'
    'python3 ./scripts/tests/dev-slot-launcher_test.py'
    'python3 ./scripts/tests/terminal_benchmark_calibration_test.py'
    'swift test --package-path lib/DanTermSupport'
    'swift test --package-path lib/PrivateFile'
    # `--skip DanTermUITests`: that target declares DANTERM_REQUIRES_WINDOWSERVER, and
    # the gate is headless. `just test-ui` runs it.
    "wide: swift test --scratch-path $APP_TEST_BUILD --skip DanTermUITests"
    './scripts/tests/core-purity-lint_test.sh'
    './scripts/tests/swift-file-header-lint_test.sh'
    './scripts/tests/run-test-suite_test.sh'
    './scripts/tests/gate-cpu-tokens_test.sh'
    'python3 ./scripts/tests/gate_test_coverage_lint_test.py'
    'python3 ./scripts/tests/scripts_swift_orphan_lint_test.py'
    'python3 ./scripts/tests/manifest_ownership_lint_test.py'
    './scripts/tests/engine-publishable-lint_test.sh'
    'python3 ./scripts/tests/generated_unicode_tables_lint_test.py'
    'python3 ./scripts/tests/generate_terminal_capability_projection_test.py'
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
    "swift test --package-path lib/TerminalHostTools --scratch-path $HOST_TOOLS_BUILD"
    './scripts/tests/provision-worktree_test.sh'
    './scripts/tests/research-index-lint_test.sh'
    './scripts/tests/external-corpus-ledger-lint_test.sh'
    'python3 ./scripts/tests/docs_lint_test.py'
    './scripts/tests/terminal-backend-boundary-lint_test.sh'
    './scripts/tests/agent-notifications-live_test.py'
    './scripts/tests/chip-artwork-isolation-gate_test.sh'
    './scripts/tests/test-terminal-pty_test.sh'
    './scripts/tests/test-terminal-pty-cleanup_test.sh'
    'python3 ./scripts/tests/pack_theme_catalog_test.py'
    'python3 ./scripts/tests/terminal_tape_to_fixture_test.py'
    'python3 ./scripts/tests/terminal_recording_schema_audit_test.py'
    './scripts/tests/terminal-viability-harness_test.sh'
    './scripts/tests/terminal-benchmark-harness_test.sh'
    'python3 ./scripts/tests/terminal_benchmark_state_test.py'
    './scripts/tests/bundle-theme-resources_test.sh'
    './scripts/tests/terminal-fence-accounting-lint_test.sh'
    './scripts/tests/terminal-pty-host-test-seam-lint_test.sh'
    './scripts/tests/terminal-exit-concurrency-lint_test.sh'
    './scripts/tests/ambient-identity-lint_test.sh'
    './scripts/tests/private-file-mode-lint_test.sh'
    './scripts/tests/checkpoint-off-main-lint_test.sh'
    './scripts/tests/reconcile-pass-lint_test.sh'
    './scripts/tests/reducer-command-discard-lint_test.sh'
    './scripts/tests/type-check-budget-gate_test.sh'
    './scripts/tests/build-path-policy_test.sh'
    './scripts/tests/terminal-scalar-append-lint_test.sh'
    './scripts/tests/terminal-benchmark-draw-path-lint_test.sh'
    './scripts/tests/agents-md-budget-lint_test.sh'
    'python3 ./scripts/tests/terminal_benchmark_workloads_test.py'
    'python3 ./scripts/tests/terminal_benchmark_plan_calibration_test.py'
    'python3 ./scripts/tests/terminal_benchmark_candidate_screen_test.py'
    './scripts/tests/just-clean_test.sh'
    './scripts/tests/kitty-parity-lint_test.sh'
    './scripts/tests/alacritty-parity-lint_test.sh'
    'python3 ./scripts/tests/terminal_benchmark_validation_test.py'
    'python3 ./scripts/tests/terminal_benchmark_producer_test.py'
    'python3 ./scripts/tests/terminal_draw_acceptance_test.py'
    'python3 ./scripts/tests/terminal_benchmark_compare_test.py'
    'python3 ./scripts/tests/import_themes_test.py'
    'python3 ./scripts/tests/terminal_profile_report_test.py'
    'python3 ./scripts/tests/terminal_headless_draw_compare_test.py'
    'python3 ./scripts/tests/terminal_benchmark_fixtures_test.py'
    'python3 ./scripts/tests/terminal_retained_row_shape_test.py'
    'python3 ./scripts/tests/terminal_memory_profile_test.py'
    'python3 ./scripts/tests/terminal_btop_stimulus_test.py'
    'python3 ./scripts/tests/terminal_btop_artifacts_test.py'
    'python3 ./scripts/tests/terminal_btop_workload_test.py'
    "${LINT_STEPS[@]}"
)

# Test seam: the self-test substitutes a synthetic step list so it can exercise the
# pool's failure reporting without running the real gate. Nothing else sets this.
if [[ -n "${RUN_TEST_SUITE_STEPS_FILE:-}" ]]; then
    STEPS=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && STEPS+=("$line")
    done <"$RUN_TEST_SUITE_STEPS_FILE"
elif (( LINT_ONLY )); then
    STEPS=("${LINT_STEPS[@]}")
elif (( ! WORKER_MODE )); then
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
    # took 5s with a warm iOS portability tree and 116s cold at -j1, and any commit touching
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
if (( ! WORKER_MODE )); then
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
if (( WORKER_MODE )); then
    step="$2"
    # A declared long pole asks for WIDE_ASK tokens instead of one. The ask is
    # opportunistic -- the supervisor claims one token firmly and sweeps for the rest
    # without ever waiting -- but the tokens it does win are held for the whole step,
    # so the size of the ask decides how many poles can run beside each other.
    ask="${DANTERM_GATE_ASK:-1}"
    if [[ "$step" == "$WIDE_MARKER"* ]]; then
        step="${step#"$WIDE_MARKER"}"
        (( ask < WIDE_ASK )) && ask=$WIDE_ASK
    fi
    # Worker pid disambiguates the rare case of two identical step strings; the hash
    # keeps the filename traceable back to a step while debugging.
    log="$RUN_TEST_SUITE_LOGS/$$-$(printf '%s' "$step" | shasum | cut -c1-12)"
    printf '%s\n' "$step" >"$log.cmd"
    start=$SECONDS
    # Lints are fast tree checks and do not compile, so making them claim a machine-wide
    # CPU token only adds a sandbox dependency and lets a full gate delay the edit loop.
    # Test workers still hold tokens for their whole run to bound compiling work across
    # concurrent checkouts.
    if (( LINT_WORKER )); then
        if bash -c "$step" >"$log.out" 2>&1; then
            rc=0
        else
            rc=$?
        fi
    else
        if DANTERM_GATE_TOKEN_WAIT_FILE="$log.wait" \
            "$REPO_ROOT/scripts/gate-cpu-tokens.py" \
            --ask "$ask" --pool "$BUDGET" \
            -- bash -c "$step" >"$log.out" 2>&1; then
            rc=0
        else
            rc=$?
        fi
    fi
    if (( rc == 0 )); then
        printf '  ok   %4ds%s  %s\n' "$(step_seconds "$log")" "$(queued_note "$log")" "$step"
    else
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
# seconds, and wrong for the handful of steps that are one whole SwiftPM build. Those
# steps carry the `wide: ` marker in the list above and ask for WIDE_ASK tokens instead.
# The marker rides on the step string, so it stays attached to the step it describes
# rather than drifting in a second list.
#
# What a wide step must not do is ask for the whole budget. A single build does speed up
# with width -- a cold lib/DanTermCore measured 104s at -j1 against 35s at -j8 -- but a
# token a wide step wins is held until that step ends, so a pole asking for BUDGET runs
# alone while the other workers block. With a dozen wide steps that trades a little
# per-build latency for serializing all of them, and it measured much worse end to end.
# See the note on WIDE_ASK at the top of this file for the numbers.
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

# Carry the test gate's cap to SwiftPM through a `swift` shim placed first on PATH, not
# by adding -j to the step strings. The gate reaches SwiftPM three ways -- step strings
# in this file, the scripts those steps run, and the scripts those scripts run -- so a
# flag written at any one site is a flag the next site forgets. PATH is the one placement
# every descendant already goes through. Lint-only mode has no token pool and keeps
# SwiftPM's native width; applying the shim there turns an invalidated check into a -j1
# build. Only the supervisor creates it, so workers inherit one stable shim instead of
# resolving and rewriting the shim already at the front of their PATH.
REAL_SWIFT=""
if (( ! WORKER_MODE && ! LINT_ONLY )); then
    REAL_SWIFT="$(command -v "${DANTERM_SWIFT:-swift}" 2>/dev/null || true)"
fi
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

if (( LINT_ONLY )); then
    echo "run-test-suite: ${#STEPS[@]} lint steps, $JOBS parallel workers, no CPU-token pool"
    worker_flag="--lint-worker"
else
    echo "run-test-suite: ${#STEPS[@]} steps, $JOBS parallel workers," \
        "$BUDGET cpu tokens of $NCPU cores, swift -j follows tokens held (ask $ASK)"
    echo "run-test-suite: the $BUDGET-token budget is shared with every other gate on this" \
        "machine, so steps queue while another checkout is testing"
    worker_flag="--worker"
fi
started=$SECONDS

# nice(1) covers the pool and everything it forks. Leaving cores free is not enough on
# its own: the gate still competes with the UI for them, and losing that race is what
# the operator sees as lag.
# BSD xargs defaults each `-I` replacement to 255 bytes. A sequential step can name
# several commands, so give one assembled step enough room to reach its worker intact.
printf '%s\n' "${STEPS[@]}" \
    | nice -n "${DANTERM_TEST_NICE:-10}" xargs -S 4096 -P "$JOBS" -I {} \
        "$0" "$worker_flag" {}

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
