#!/usr/bin/env bash
# Reject Swift concurrency bridges from TerminalPTY's production exit ownership path.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$#" -eq 0 ]]; then
    set -- \
        "$ROOT/lib/TerminalPTY/Sources" \
        "$ROOT/app/SwiftTerminalBackend.swift"
fi

PATTERN='^(?![[:space:]]*//).*(Task[[:space:]]*(<|\.|\{|\()|Async(Stream|ThrowingStream)|with(Check|Unsafe)(Throwing)?Continuation|(Checked|Unsafe)(Throwing)?Continuation)'

if rg --pcre2 --glob '*.swift' -n "$PATTERN" "$@"; then
    echo "terminal-exit-concurrency-lint: Swift concurrency bridge in exit-reachable production code" >&2
    exit 1
fi

echo "terminal exit concurrency lint passed"
