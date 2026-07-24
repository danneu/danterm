#!/usr/bin/env bash
# Contract tests for benchmark ownership, backend scope, and marker protocol.
# Every assertion greps for literal shell source text, so single quotes are
# deliberate throughout and SC2016 does not apply.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HARNESS="$ROOT/scripts/terminal-benchmark.sh"
PRODUCER="$ROOT/scripts/terminal-benchmark-producer.py"
PROFILE="$ROOT/scripts/terminal-benchmark-profile.sh"

grep -q 'DANTERM_TERMINAL_BACKEND="$BACKEND"' "$HARNESS"
grep -q 'terminate_owned_pid "$APP_PID"' "$HARNESS"
grep -q 'swift|ghostty' "$HARNESS"
grep -q 'BACKEND="${BACKEND#backend=}"' "$HARNESS"
grep -q 'DANTERM_TERMINAL_BENCHMARK_BACKEND="$BACKEND"' "$HARNESS"
grep -q 'monotonic_ns=time.monotonic_ns' "$PRODUCER"
grep -q 'backend == "swift"' "$PRODUCER"
grep -q 'wait_for_target_geometry' "$PRODUCER"
grep -q 'await_start_ack()' "$PRODUCER"
grep -q 'await_draw_result()' "$PRODUCER"
grep -q 'draw_elapsed >= producer_elapsed' "$HARNESS"
grep -q 'finalDraw.*available.*false' "$HARNESS"
grep -q 'Benchmark path escaped isolated runtime' "$HARNESS"
grep -q '"geometry"' "$PRODUCER"
grep -q 'displayScale' "$HARNESS"
grep -q 'DANTERM_TERMINAL_BENCHMARK >&2' "$HARNESS"
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
grep -q 'get-task-allow' "$ROOT/scripts/terminal-benchmark-entitlements.plist"
grep -q 'DANTERM_BENCHMARK_BUNDLE_SUFFIX' "$HARNESS"
grep -q '""|.a|.b|.bystander' "$HARNESS"
grep -q 'DANTERM_BENCHMARK_PHASE_LOG' "$HARNESS"
grep -q 'record_phase "build-start"' "$HARNESS"
grep -q 'record_phase "build-complete"' "$HARNESS"
grep -q 'record_phase "assemble-sign-complete"' "$HARNESS"
grep -q 'record_phase "launch-complete"' "$HARNESS"
grep -q 'record_phase "app-ready"' "$HARNESS"
grep -q 'record_phase "converge-complete"' "$HARNESS"
grep -q 'record_phase "teardown-complete"' "$HARNESS"
grep -q 'BUNDLE_ID="com.danneu.danterm-terminal-benchmark${BUNDLE_SUFFIX}"' "$HARNESS"
grep -q 'terminal-benchmark-state.py' "$HARNESS"
grep -q 'DANTERM_TERMINAL_BENCHMARK_STATE_RESULT' "$HARNESS"
grep -q 'event: "block-invalidated"' "$HARNESS"
grep -q 'machineStateSamples' "$ROOT/app/TerminalBenchmark.swift"
grep -q 'setFrameTopLeftPoint' "$ROOT/app/TerminalBenchmark.swift"
grep -q 'screenVisibleFrame.contains' "$ROOT/app/TerminalBenchmark.swift"
grep -q 'drawDurationsNanoseconds' "$ROOT/app/TerminalBenchmark.swift"
grep -q 'benchmarkStateRecorder?.windowDidChangeOcclusionState()' "$ROOT/app/AppDelegate.swift"
grep -q 'NSApp.activate()' "$ROOT/app/AppDelegate.swift"
python3 "$ROOT/scripts/tests/terminal_benchmark_state_test.py"
if grep -q 'com.danneu.danterm-terminal-benchmark\.\$\$' "$HARNESS"; then
    echo "benchmark bundle id must stay stable across runs" >&2
    exit 1
fi
grep -q 'benchmark-loop' "$ROOT/justfile"
grep -q 'benchmark-sample' "$ROOT/justfile"
grep -q 'benchmark-trace' "$ROOT/justfile"
grep -q 'observeTitle(title)' "$ROOT/app/SwiftTerminalSessionView.swift"
grep -q 'pendingRedrawSequence' "$ROOT/app/TerminalBenchmark.swift"
grep -q 'profilesIncrementalMixedDamage ? 6 : plan.rows' "$ROOT/app/TerminalBenchmark.swift"
grep -q 'reopenCompletedBlockIfRequested' "$ROOT/app/TerminalBenchmark.swift"
awk '
    /#if DANTERM_TERMINAL_BENCHMARK/ {
        getline
        if (index($0, "window.orderFront(nil)") != 0) found = 1
    }
    END { exit(found ? 0 : 1) }
' "$ROOT/app/AppDelegate.swift"
echo "terminal benchmark harness contract: ok"
