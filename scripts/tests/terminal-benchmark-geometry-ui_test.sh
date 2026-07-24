#!/usr/bin/env bash
# End-to-end GUI proof that each real terminal backend reaches the requested grid.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HARNESS="$ROOT/scripts/terminal-benchmark.sh"

for backend in swift; do
    result="$("$HARNESS" scrollback-stream "$backend")"
    geometry="$(jq -c '.geometry' <<<"$result")"
    [[ "$geometry" == '{"columns":179,"rows":66}' ]] || {
        echo "$backend benchmark reported unexpected geometry: $geometry" >&2
        exit 1
    }
done

echo "terminal benchmark geometry UI tests passed"
