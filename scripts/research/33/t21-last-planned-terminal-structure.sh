#!/usr/bin/env bash
# Research 33 T21: prove the pane planner no longer retains or compares a whole prior Terminal.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SOURCE="$ROOT/lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift"

if rg -n 'lastPlannedTerminal|lastPlannedTheme|requiresCompleteFrame' "$SOURCE"; then
    echo "T21 failed: TerminalPaneSession still retains a redundant planning witness" >&2
    exit 1
fi

rg -q 'guard pendingDamage != \.none else \{ return \}' "$SOURCE" || {
    echo "T21 failed: the independent pending-damage gate is missing" >&2
    exit 1
}
echo "T21 lastPlannedTerminal structure passed"
