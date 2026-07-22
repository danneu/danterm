#!/usr/bin/env bash
# Contract tests for benchmark ownership, backend scope, and marker protocol.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HARNESS="$ROOT/scripts/terminal-benchmark.sh"
PRODUCER="$ROOT/scripts/terminal-benchmark-producer.py"
SUITE="$ROOT/scripts/terminal-benchmark-suite.py"

grep -q 'DANTERM_TERMINAL_BACKEND="$BACKEND"' "$HARNESS"
grep -q 'terminate_owned_pid "$APP_PID"' "$HARNESS"
grep -q 'swift|ghostty' "$HARNESS"
grep -q 'BACKEND="${BACKEND#backend=}"' "$HARNESS"
grep -q 'DANTERM_TERMINAL_BENCHMARK_BACKEND="$BACKEND"' "$HARNESS"
grep -q 'time.monotonic_ns()' "$PRODUCER"
grep -q 'backend == "swift"' "$PRODUCER"
grep -q 'while not os.path.exists(start_ack)' "$PRODUCER"
grep -q 'while not os.path.exists(draw_result)' "$PRODUCER"
grep -q 'draw_elapsed >= producer_elapsed' "$HARNESS"
grep -q 'finalDraw.*available.*false' "$HARNESS"
grep -q 'Benchmark path escaped isolated runtime' "$HARNESS"
grep -q '"geometry"' "$PRODUCER"
grep -q 'displayScale' "$HARNESS"
grep -q 'DANTERM_TERMINAL_BENCHMARK >&2' "$HARNESS"
grep -q 'terminal-benchmark-suite.py' "$ROOT/justfile"
grep -q '"benchmarks" / "results"' "$SUITE"
echo "terminal benchmark harness contract: ok"
