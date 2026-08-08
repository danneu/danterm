#!/usr/bin/env bash
# Research doc 33, tasks T9 + T20 (rider): the structural half of the claim.
#
# T20's promise is measured as absence, per D1's "a state that can no longer be
# constructed": the damage path carries words end to end, so the per-frame
# Set<Int> constructions, the hash operations behind them, the span sort, and
# the negative-row sanitizer are not zero-count at runtime -- they are gone from
# the source. Each assertion below greps for the deleted apparatus and fails if
# any of it returns; the behavioral half (shift composition, O(1) rows per
# scroll, plan equivalence) lives in TerminalShiftDamageTests,
# TerminalScrollShiftDamageTests, ShiftDamagePlanningTests and
# ExecutorContractTests, and the sizing in t5-scroll-amplification.py.
#
# Usage: scripts/research/33/t9-shift-damage-structure.sh
#
# Assertions grep for literal Swift source text, so single quotes are
# deliberate and SC2016 does not apply.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DAMAGE="$ROOT/lib/TerminalCore/Sources/TerminalCore/TerminalDamage.swift"
CORE="$ROOT/lib/TerminalCore/Sources/TerminalCore"

fail() {
    echo "t9-shift-damage-structure: $1" >&2
    exit 1
}

# The damage representation holds no set and never sorts: rows are words, spans
# and row walks come out canonical from the word scan.
if grep -qE 'Set<|sorted\(' "$DAMAGE"; then
    fail "TerminalDamage.swift reintroduced a set or a sort on the damage path"
fi

# The negative-row sanitizer is deleted, not relocated: no damage code filters
# rows into range, because an out-of-range row fails to construct instead.
if grep -qF 'filter { $0 >= 0 }' "$DAMAGE"; then
    fail "the negative-row sanitizer returned to TerminalDamage.swift"
fi

# The free-function span/halo helpers over Set<Int> are gone with their file;
# consumers reach spans and the halo only through the bounded value's methods.
if [[ -e "$ROOT/lib/TerminalCore/Sources/TerminalRenderPlanning/TerminalDamageSpans.swift" ]]; then
    fail "TerminalDamageSpans.swift is back; spans belong to TerminalDamage itself"
fi
if grep -rqE 'terminalDamageMaximalContiguousSpans|terminalDamageRowsWithGlyphHalo' \
    "$ROOT/lib" "$ROOT/app" --include="*.swift"; then
    fail "a Set<Int>-based span/halo helper is referenced again"
fi

# The scroll site records the translation; the whole-region damage it replaced
# must not come back beside it.
grep -q 'recordScrollDamage' "$CORE/Terminal.swift" \
    || fail "Terminal.swift lost the scroll-site damage funnel"
grep -q 'func recordShift' "$DAMAGE" \
    || fail "TerminalDamage.swift lost the shift composition entry point"

# The value seam carries the shift: the session's coalescer and the planner both
# consume TerminalDamage directly, so the shift must be part of the public type.
grep -q 'public private(set) var shift: TerminalDamageShift?' "$DAMAGE" \
    || fail "TerminalDamage no longer carries the shift on the public seam"

echo "t9-shift-damage-structure: ok"
