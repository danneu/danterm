#!/usr/bin/env bash
# Reject Swift concurrency bridges from TerminalPTY's production exit ownership path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/lint-rationale.sh
source "$SCRIPT_DIR/lib/lint-rationale.sh"

ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ "$#" -eq 0 ]]; then
    set -- \
        "$ROOT/lib/TerminalPTY/Sources" \
        "$ROOT/app/SwiftTerminalBackend.swift"
fi

PATTERN='^(?![[:space:]]*//).*(Task[[:space:]]*(<|\.|\{|\()|Async(Stream|ThrowingStream)|with(Check|Unsafe)(Throwing)?Continuation|(Checked|Unsafe)(Throwing)?Continuation)'

if rg --pcre2 --glob '*.swift' -n "$PATTERN" "$@"; then
    echo "terminal-exit-concurrency-lint: Swift concurrency bridge in exit-reachable production code" >&2
    lint_rationale <<'EOF'
terminal-exit-concurrency lint FAILED: production code on the exit path
used a Swift concurrency primitive.

Application termination blocks the main thread. A main-actor Task or a
host AsyncStream can sit suspended across that block and then resume on
the far side of the recovery fence, delivering a callback the shutdown
already accounted for as inert -- so the checkpoint written at quit does
not describe the state the app actually reached. A continuation has the
same shape: the suspension point is where the ordering is lost.

Deliver through the Dispatch boundary instead: a queue hop or a callback
the owner invokes, both of which the shutdown can stop. Async
conveniences are legal in test support, which does not run at exit.
EOF
    exit 1
fi

echo "terminal exit concurrency lint passed"
