#!/usr/bin/env bash
# Contract tests for benchmark ownership and marker protocol.
# Every assertion greps for literal shell source text, so single quotes are
# deliberate throughout and SC2016 does not apply.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HARNESS="$ROOT/scripts/terminal-benchmark.sh"
PRODUCER="$ROOT/scripts/terminal-benchmark-producer.py"
PROFILE="$ROOT/scripts/terminal-benchmark-profile.sh"

grep -q 'terminate_owned_pid "$APP_PID"' "$HARNESS"
# The benchmark harness has one engine and therefore no backend argument or
# selector to parse or forward.
grep -q '(( $# <= 1 ))' "$HARNESS"
grep -q '(( $# <= max_arguments ))' "$PROFILE"
if grep -qE 'BACKEND|backend=|ghostty|DANTERM_TERMINAL_BACKEND' \
    "$HARNESS" "$PROFILE" "$PRODUCER"; then
    echo "the benchmark harness must not carry a terminal backend selector" >&2
    exit 1
fi
grep -q 'monotonic_ns=time.monotonic_ns' "$PRODUCER"
grep -q 'wait_for_target_geometry' "$PRODUCER"
grep -q 'await_start_ack()' "$PRODUCER"
grep -q 'await_draw_result()' "$PRODUCER"
grep -q 'draw_elapsed >= producer_elapsed' "$HARNESS"
# An invalidated block is the one remaining way a run reports no final draw, and
# it must stay reported rather than becoming a timeout the operator has to guess at.
grep -q 'available: false,' "$HARNESS"
grep -q 'Benchmark path escaped isolated runtime' "$HARNESS"
grep -q '"geometry"' "$PRODUCER"
grep -q 'displayScale' "$HARNESS"
grep -q 'DANTERM_TERMINAL_BENCHMARK >&2' "$HARNESS"
grep -q '^assemble_benchmark_bundle()' "$HARNESS"
grep -q 'deadline=$((SECONDS + 20))' "$HARNESS"
grep -q 'front_owned_app "$APP_PID"' "$HARNESS"
grep -q 'DANTERM_BENCHMARK_MODE' "$HARNESS"
grep -q 'measure|loop|persistent' "$HARNESS"
grep -q 'DANTERM_TERMINAL_BENCHMARK_COLUMNS="$TARGET_COLUMNS"' "$HARNESS"
grep -q 'DANTERM_TERMINAL_BENCHMARK_ROWS="$TARGET_ROWS"' "$HARNESS"
grep -q 'TARGET_COLUMNS="${DANTERM_TERMINAL_BENCHMARK_COLUMNS:-179}"' "$HARNESS"
grep -q 'TARGET_ROWS="${DANTERM_TERMINAL_BENCHMARK_ROWS:-66}"' "$HARNESS"
grep -q 'while \[\[ ! -f "$GEOMETRY_READY" \]\]' "$HARNESS"
grep -q 'PROFILE_IDENTITY_PATH' "$HARNESS"
grep -q -- '--attach "$target_pid"' "$PROFILE"
grep -q -- '--no-prompt' "$PROFILE"
grep -q 'symbols.txt' "$PROFILE"
grep -q 'decisionEligible: false' "$PROFILE"
grep -q 'historyEligible: false' "$PROFILE"
grep -q 'profiledTimingsAreDiagnosticOnly: true' "$PROFILE"
grep -q 'binarySHA256' "$PROFILE"
grep -q 'machOUUID' "$PROFILE"
grep -q 'sourceTree' "$PROFILE"
grep -q 'fixtureIdentity' "$PROFILE"
grep -q 'resetBehavior' "$PROFILE"
grep -q 'geometry' "$PROFILE"
grep -q 'profile-command.txt' "$PROFILE"

# Draw counters (`research/17/T2`). Loop mode never completes a block, so
# these snapshots are the only frame count an attached profiler gets.
grep -q 'DANTERM_TERMINAL_BENCHMARK_ACTIVITY_PATH="$ACTIVITY_PATH"' "$PROFILE"
grep -q 'DANTERM_TERMINAL_BENCHMARK_ACTIVITY_PATH="${DANTERM_TERMINAL_BENCHMARK_ACTIVITY_PATH:-}"' "$HARNESS"
grep -q 'capture_activity before' "$PROFILE"
grep -q 'capture_activity after' "$PROFILE"
grep -q 'report_frame_accounting' "$PROFILE"
# The counted window must bracket the profiled one: each `before` snapshot
# precedes its profiler invocation and each `after` follows it. Asserted on line
# order because a snapshot taken inside the window would still grep clean while
# silently under-counting the run it is meant to normalize.
python3 - "$PROFILE" <<'PY'
import re, sys

lines = open(sys.argv[1]).read().splitlines()
def rows(pattern):
    return [i for i, line in enumerate(lines) if re.search(pattern, line)]

befores = rows(r'^\s+capture_activity before$')
afters = rows(r'^\s+capture_activity after$')
attaches = rows(r'^\s+run_profiler (sample|xcrun xctrace record)')
assert len(befores) == len(afters) == len(attaches) == 2, (
    f"expected two bracketed profilers, got {len(befores)}/{len(attaches)}/{len(afters)}"
)
for before, attach, after in zip(befores, attaches, afters):
    assert before < attach < after, (
        f"snapshot at {before}/{after} does not bracket the profiler at {attach}"
    )
PY

# A decision run must never publish counters: the extra per-draw work is not in
# the tree the paired thresholds were calibrated against.
for decision_script in "$ROOT/scripts/terminal-benchmark-compare.py" \
    "$ROOT/scripts/terminal-benchmark-validation.py"; do
    if grep -q 'DANTERM_TERMINAL_BENCHMARK_ACTIVITY_PATH' "$decision_script"; then
        echo "Decision script must not publish draw counters: $decision_script" >&2
        exit 1
    fi
done
grep -q 'get-task-allow' "$ROOT/scripts/terminal-benchmark-entitlements.plist"
grep -q 'DANTERM_BENCHMARK_BUNDLE_SUFFIX' "$HARNESS"
grep -q '""|.a|.b|.bystander|.isolation' "$HARNESS"
grep -q 'DANTERM_BENCHMARK_PHASE_LOG' "$HARNESS"
grep -q 'record_phase "build-start"' "$HARNESS"
grep -q 'record_phase "build-complete"' "$HARNESS"
grep -q 'record_phase "assemble-sign-complete"' "$HARNESS"
grep -q 'record_phase "launch-complete"' "$HARNESS"
grep -q 'record_phase "app-ready"' "$HARNESS"
grep -q 'record_phase "converge-complete"' "$HARNESS"
grep -q 'record_phase "teardown-complete"' "$HARNESS"
grep -q '"$layout_tool" benchmark "$bundle_suffix"' "$HARNESS"
grep -q 'terminal-benchmark-state.py' "$HARNESS"
grep -q 'DANTERM_TERMINAL_BENCHMARK_STATE_RESULT' "$HARNESS"
grep -q 'event: "block-invalidated"' "$HARNESS"
grep -q 'machineStateSamples' "$ROOT/app/TerminalBenchmark.swift"
grep -q 'setFrameTopLeftPoint' "$ROOT/app/TerminalBenchmark.swift"
grep -q 'screenVisibleFrame.contains' "$ROOT/app/TerminalBenchmark.swift"
grep -q 'drawDurationsNanoseconds' "$ROOT/app/TerminalBenchmark.swift"
grep -q 'benchmarkStateRecorder?.windowDidChangeOcclusionState()' \
    "$ROOT/app/AppPresentationLifecycle.swift"
grep -q 'NSApp.activate()' "$ROOT/app/AppDelegate.swift"
if grep -q 'com.danneu.danterm-terminal-benchmark\.\$\$' "$HARNESS"; then
    echo "benchmark bundle id must stay stable across runs" >&2
    exit 1
fi
grep -q 'observeTitle(title)' "$ROOT/app/SwiftTerminalSessionView.swift"
grep -q 'pendingRedrawSequence' "$ROOT/app/TerminalBenchmark.swift"
# A partial-damage workload selects its accepted draws on the stimulus, never on
# the rendered rectangle: a render brings a stale swapchain buffer current over
# composed damage, so that rectangle measures buffer depth (research/33/F25).
# A full-screen workload keeps the rectangle rule, which staleness cannot widen
# past the whole grid.
grep -q 'acceptsRedrawDraw = redrawDirtyRowCount == plan.rowCount' "$ROOT/app/TerminalBenchmark.swift"
grep -q 'damageTopologyRecorder?.recordDrawIfTopologyMatches' "$ROOT/app/TerminalBenchmark.swift"
grep -q 'reopenCompletedBlockIfRequested' "$ROOT/app/TerminalBenchmark.swift"
# A block is opened only by a marker the frame itself wrote, and re-armed only
# in the mode that reuses one app across blocks. A reused app keeps the previous
# block's start, completion, and final-state markers standing on screen, so a
# whole-plan scan let an unrelated frame open and instantly complete a block
# nobody had started -- and the mode gate is what keeps the file checks off the
# fresh-app workloads that measure the PTY-output path end to end.
grep -q 'limitedToRows: damage.isFull ? nil : Set(damage.expandingShift().rowIndices)' "$ROOT/app/TerminalBenchmark.swift"
grep -q 'damage: frame.damage' "$ROOT/app/SwiftTerminalSessionView.swift"
grep -q 'requiresSettlingDraw == false || observedSettlingDraw' "$ROOT/app/TerminalBenchmark.swift"
grep -q 'DANTERM_BENCHMARK_MODE"\] == "persistent"' "$ROOT/app/TerminalBenchmark.swift"
# The two block-boundary probes run once per published frame of an open block,
# on the PTY-output path: they stay on `access` over a pre-encoded path.
grep -q 'access($0.baseAddress!, F_OK)' "$ROOT/app/TerminalBenchmark.swift"
if grep -q 'FileManager.default.fileExists' "$ROOT/app/TerminalBenchmark.swift"; then
    echo "block-boundary probes must not take the FileManager path" >&2
    exit 1
fi
grep -q 'DANTERM_BENCHMARK_MODE="$MODE"' "$HARNESS"
# The producer's result is the one artifact a reader parses that the app does
# not write atomically; `open(..., "w")` would publish a truncated file that
# exists but cannot be parsed.
grep -q 'os.replace(temporary, output)' "$PRODUCER"
if grep -q 'open(output, "w"' "$PRODUCER"; then
    echo "producer result must be published atomically, not truncated in place" >&2
    exit 1
fi
# The plan timer must stay at its source and stay separate from the draw timer:
# planning runs on the PTY-output path, so folding it into drawDurationNanoseconds
# would redefine the calibrated decision metric instead of adding to it.
grep -q 'cumulativePlanNanoseconds' "$ROOT/app/TerminalBenchmark.swift"
grep -q 'planDurationsNanoseconds' "$ROOT/app/TerminalBenchmark.swift"
grep -q 'lastPlanDurationNanoseconds' \
    "$ROOT/lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift"
grep -q 'planDurationNanoseconds: controller.lastPlanDurationNanoseconds' \
    "$ROOT/app/SwiftTerminalSessionView.swift"
# Marker detection must stay on the scanned-frame path and off the allocator.
# The observer lives in app/, which no test target compiles, so these greps plus
# TerminalBenchmarkMarkersTests are the only guard that the acknowledgments the
# producer blocks on are still driven by what was actually drawn.
grep -q 'import TerminalBenchmarkMarkers' "$ROOT/app/TerminalBenchmark.swift"
grep -q 'markerScanner.scan(' "$ROOT/app/TerminalBenchmark.swift"
grep -q 'markers.containsStartMarker' "$ROOT/app/TerminalBenchmark.swift"
grep -q 'markers.containsLocalizedReady' "$ROOT/app/TerminalBenchmark.swift"
grep -q 'markers.containsCompletionMarker' "$ROOT/app/TerminalBenchmark.swift"
grep -q 'markers.containsExpectedFinalState' "$ROOT/app/TerminalBenchmark.swift"
grep -q 'markers.localizedSequence' "$ROOT/app/TerminalBenchmark.swift"
grep -q 'startDrawAcknowledgmentPath' "$ROOT/app/TerminalBenchmark.swift"
grep -q 'readyDrawAcknowledgmentPath' "$ROOT/app/TerminalBenchmark.swift"
# The per-scalar String join it replaced cost more main-thread time than the
# drawing it measured; reintroducing it would silently re-inflate every profile.
if grep -q 'func frameText' "$ROOT/app/TerminalBenchmark.swift"; then
    echo "benchmark marker detection must not rebuild the frame as a String" >&2
    exit 1
fi
awk '
    /#if DANTERM_TERMINAL_BENCHMARK/ {
        getline
        if (index($0, "window.orderFront(nil)") != 0) found = 1
    }
    END { exit(found ? 0 : 1) }
' "$ROOT/app/AppDelegate.swift"
# Localized profiling (`research/17/F17`). The three churn workloads force a
# republished full viewport every frame, which pins per-frame glyph counts at
# maximum; `localized-draw-acceptance` is the opposite extreme -- one damaged row
# against a dense screen -- and the two together bracket what live use costs.
# Without the env var below the case would silently profile a workload that never
# writes an update, so the run would look valid and measure an idle app.
grep -q 'DANTERM_TERMINAL_BENCHMARK_LOCALIZED_UPDATES="$localized_updates"' "$PROFILE"
grep -q 'localized-draw-acceptance)' "$PROFILE"

# The live btop workload's preflight must precede the harness launch, which is
# what builds and launches the app. Asserted on line order because a preflight
# that ran afterwards would still grep clean while costing an operator a release
# build and a GUI launch before telling them btop is not installed.
python3 - "$PROFILE" <<'PY'
import re, sys

lines = open(sys.argv[1]).read().splitlines()
def row(pattern):
    matches = [i for i, line in enumerate(lines) if re.search(pattern, line)]
    assert len(matches) == 1, f"expected exactly one {pattern!r}, got {len(matches)}"
    return matches[0]

preflight = row(r'terminal_btop_workload\.py" preflight')
launch = row(r'^\s+"\$SCRIPT_DIR/terminal-benchmark\.sh"')
assert preflight < launch, "the btop preflight must run before the app is built and launched"
PY
grep -q 'DANTERM_TERMINAL_BENCHMARK_BTOP="$BTOP_EXECUTABLE"' "$PROFILE"
grep -q 'BTOP_EXECUTABLE="${DANTERM_TERMINAL_BENCHMARK_BTOP:-}"' "$HARNESS"
grep -q 'terminal_btop_workload.py" readiness' "$HARNESS"
grep -q 'terminal_btop_artifacts.py' "$PROFILE"

# Provenance: `fixtureIdentity` must carry the geometry actually measured. The
# harness takes DANTERM_TERMINAL_BENCHMARK_COLUMNS/_ROWS, so a hardcoded 179x66
# in the identity is a lie the moment anyone varies geometry -- as `research/17/F16`
# did, producing artifacts whose fixtureIdentity disagreed with their own
# geometry field.
if grep -q '179x66' "$PROFILE"; then
    echo "profile fixture identity must derive geometry, not hardcode 179x66" >&2
    exit 1
fi
grep -q 'geometry_label=' "$PROFILE"

# The sourceable packaging phase is tested with command shims so a successful
# launch cannot hide a missing verifier call, and both failures propagate.
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
# shellcheck disable=SC1090
source "$HARNESS"
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/products"
for command in DanTermBundleLayoutTool assemble-app-bundle.sh sign-app-bundle.sh; do
    cat >"$TEST_ROOT/bin/$command" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "${0##*/}" >> "$DANTERM_TEST_CALLS"
if [[ "${0##*/}" == "DanTermBundleLayoutTool" ]]; then
    printf '{}\n'
elif [[ "${0##*/}" == "assemble-app-bundle.sh" ]]; then
    mkdir -p "$1"
fi
SHIM
    chmod +x "$TEST_ROOT/bin/$command"
done
export DANTERM_TEST_CALLS="$TEST_ROOT/calls"
PATH="$TEST_ROOT/bin:/usr/bin:/bin" assemble_benchmark_bundle \
    "$TEST_ROOT/test.app" "$TEST_ROOT/layout.json" "$ROOT" \
    "$TEST_ROOT/bin/DanTermBundleLayoutTool" "$TEST_ROOT/products/gui" \
    "$TEST_ROOT/products/cli" "$TEST_ROOT/products/bootstrap" ".a"
[[ "$(tr '\n' ' ' < "$DANTERM_TEST_CALLS")" == \
    "DanTermBundleLayoutTool assemble-app-bundle.sh sign-app-bundle.sh " ]] || {
    echo "benchmark bundle phase did not emit, assemble, then sign-and-verify" >&2
    exit 1
}
cat >"$TEST_ROOT/bin/sign-app-bundle.sh" <<'SHIM'
#!/usr/bin/env bash
exit 71
SHIM
chmod +x "$TEST_ROOT/bin/sign-app-bundle.sh"
if PATH="$TEST_ROOT/bin:/usr/bin:/bin" assemble_benchmark_bundle \
    "$TEST_ROOT/test.app" "$TEST_ROOT/layout.json" "$ROOT" \
    "$TEST_ROOT/bin/DanTermBundleLayoutTool" "$TEST_ROOT/products/gui" \
    "$TEST_ROOT/products/cli" "$TEST_ROOT/products/bootstrap" ""; then
    echo "benchmark bundle phase swallowed signer failure" >&2
    exit 1
fi
cat >"$TEST_ROOT/bin/sign-app-bundle.sh" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
cat >"$TEST_ROOT/bin/assemble-app-bundle.sh" <<'SHIM'
#!/usr/bin/env bash
exit 72
SHIM
chmod +x "$TEST_ROOT/bin/sign-app-bundle.sh" "$TEST_ROOT/bin/assemble-app-bundle.sh"
if PATH="$TEST_ROOT/bin:/usr/bin:/bin" assemble_benchmark_bundle \
    "$TEST_ROOT/test.app" "$TEST_ROOT/layout.json" "$ROOT" \
    "$TEST_ROOT/bin/DanTermBundleLayoutTool" "$TEST_ROOT/products/gui" \
    "$TEST_ROOT/products/cli" "$TEST_ROOT/products/bootstrap" ""; then
    echo "benchmark bundle phase swallowed assembler failure" >&2
    exit 1
fi

echo "terminal benchmark harness contract: ok"
