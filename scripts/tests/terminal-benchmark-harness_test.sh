#!/usr/bin/env bash
# Contract tests for benchmark ownership, backend scope, and marker protocol.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HARNESS="$ROOT/scripts/terminal-benchmark.sh"
PRODUCER="$ROOT/scripts/terminal-benchmark-producer.py"

grep -q 'DANTERM_TERMINAL_BACKEND=swift' "$HARNESS"
grep -q 'terminate_owned_pid "$APP_PID"' "$HARNESS"
grep -q 'Commit 1 supports only backend=swift' "$HARNESS"
grep -q 'BACKEND="${BACKEND#backend=}"' "$HARNESS"
grep -q 'time.monotonic_ns()' "$PRODUCER"
grep -q 'while not os.path.exists(start_ack)' "$PRODUCER"
grep -q 'while not os.path.exists(draw_result)' "$PRODUCER"
grep -q 'draw_elapsed >= producer_elapsed' "$HARNESS"
grep -q 'Benchmark path escaped isolated runtime' "$HARNESS"
echo "terminal benchmark harness contract: ok"
