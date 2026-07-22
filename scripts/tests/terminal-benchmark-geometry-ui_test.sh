#!/usr/bin/env bash
# End-to-end GUI proof that each real terminal backend reaches the requested grid.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HARNESS="$ROOT/scripts/terminal-benchmark.sh"

for backend in swift ghostty; do
    result="$(
        DANTERM_TERMINAL_BENCHMARK_COLUMNS=81 \
        DANTERM_TERMINAL_BENCHMARK_ROWS=25 \
        "$HARNESS" scrollback-stream "$backend"
    )"
    geometry="$(jq -c '.geometry' <<<"$result")"
    [[ "$geometry" == '{"columns":81,"rows":25}' ]] || {
        echo "$backend benchmark reported unexpected geometry: $geometry" >&2
        exit 1
    }
done

echo "terminal benchmark geometry UI tests passed"
