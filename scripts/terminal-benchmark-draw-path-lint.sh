#!/usr/bin/env bash
# Keep the benchmark activity snapshot's file write off the AppKit draw path.
#
# `publishActivity` does a synchronous atomic `Data.write(to:)`. It was once
# called from `observeCompletedDraw`, which AppKit invokes from inside
# `draw(_:)` under the CoreAnimation transaction commit -- so the instrumentation
# billed its own IO to the frame it exists to measure (71 ms of a 20 s
# `btop-scroll` trace). The 100 ms presentation-sampling timer publishes the same
# counters at the same throttle from the run loop between draws, so the timer is
# the only legitimate caller. This lint pins that: any other caller puts the
# write back on a stack a profiler attributes to drawing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-$ROOT/app/TerminalBenchmark.swift}"
ALLOWED_CALLER="samplePresentationCoverage"

fail() {
    echo "terminal-benchmark-draw-path-lint: $1" >&2
    exit 1
}

[[ -f "$SOURCE" ]] || fail "missing benchmark observer source: $SOURCE"

# Attribute each call to the nearest preceding `func`, skipping the declaration
# itself and comment lines so the doc block explaining this rule cannot satisfy
# or trip it.
callers="$(
    awk '
        /^[[:space:]]*(private |internal |public )?func [A-Za-z_]/ {
            line = $0
            sub(/^[[:space:]]*(private |internal |public )?func /, "", line)
            sub(/[(<].*$/, "", line)
            current = line
        }
        /^[[:space:]]*\/\// { next }
        /publishActivity\(atPath:/ {
            if (current != "publishActivity") print current
        }
    ' "$SOURCE"
)"

call_count="$(printf '%s\n' "$callers" | sed '/^$/d' | wc -l | tr -d ' ')"
[[ "$call_count" == "1" ]] \
    || fail "expected exactly one publishActivity call site, found $call_count: $(
        printf '%s' "$callers" | tr '\n' ' '
    )"

[[ "$callers" == "$ALLOWED_CALLER" ]] \
    || fail "publishActivity called from '$callers'; only '$ALLOWED_CALLER' may write from off the draw path"

echo "terminal benchmark draw path lint passed"
