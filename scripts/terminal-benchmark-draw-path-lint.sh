#!/usr/bin/env bash
# Keep the benchmark activity snapshot's file write off the AppKit draw path.
#
# The incident that made this a gate, and the shape that satisfies it, are in the
# rationale the failure prints -- that is where the reader who trips this gate is
# looking, and one copy cannot drift from itself.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/lint-rationale.sh
source "$SCRIPT_DIR/lib/lint-rationale.sh"
# shellcheck source=lib/lint-targets.sh
source "$SCRIPT_DIR/lib/lint-targets.sh"

ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE="${1:-$ROOT/app/TerminalBenchmark.swift}"
ALLOWED_CALLER="samplePresentationCoverage"

fail() {
    echo "terminal-benchmark-draw-path-lint: $1" >&2
    lint_rationale <<'EOF'
terminal-benchmark-draw-path lint FAILED: the activity snapshot's file
write can reach the AppKit draw path.

publishActivity does a synchronous atomic Data.write(to:). It was once
called from observeCompletedDraw, which AppKit invokes from inside
draw(_:) under the CoreAnimation transaction commit -- so the
instrumentation billed its own IO to the frame it exists to measure:
71 ms of a 20 s btop-scroll trace, attributed to drawing.

The 100 ms presentation-sampling timer publishes the same counters at
the same throttle, from the run loop between draws. That makes
samplePresentationCoverage the only legitimate caller, and this lint
pins it. Publish from there, or from another run-loop callback that no
draw(_:) can be on the stack for -- never from a draw observer.
EOF
    exit 1
}

# A gate that cannot find its target must fail, not pass over nothing at all.
lint_require_targets "terminal-benchmark-draw-path-lint" "$SOURCE"

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
