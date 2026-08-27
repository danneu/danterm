#!/usr/bin/env bash
# Keep the display-row seam rule in one place: `Terminal.DisplayRowProjector`.
#
# The last retained display row is stored one column short of the spacer a wide glyph at the
# fold would put at its margin, and the reader re-derives that margin from the grid's first
# cell (`openTailPendingMarginCell` is the blank it shows when that cell is not a wide head).
# While the alternate screen is active the active stream severs that seam. Before the projector
# existed the rule was hand-written at ten sites, three of them restating a disjunct the row
# already knew, and one reader applied no seam at all -- each a place the rule could drift by
# one column (audit Wave 6, GRID-2).
#
# So no source file outside `DisplayRowProjector.swift` may name `openTailPendingMarginCell`
# or `projectedMarginCell`. The store's own declaration is the one exception: it hands the
# margin across a type boundary, which is why an access level cannot enforce this and a lint
# does. Comment lines are ignored so the rule can be explained where it is applied.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/lint-targets.sh
source "$SCRIPT_DIR/lib/lint-targets.sh"
# shellcheck source=lib/lint-rationale.sh
source "$SCRIPT_DIR/lib/lint-rationale.sh"

ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ "$#" -eq 0 ]]; then
    set -- "$ROOT/lib/TerminalCore/Sources"
fi

fail() {
    echo "display-row-projection-lint: $1" >&2
    exit 1
}

# A gate that cannot find its target must fail, not pass: `rg` exits 2 on a missing path and
# 1 on a clean scan, and an `if` would read both as "no match".
lint_resolve_targets "display-row-projection-lint" '*.swift' "$@"

OWNER='DisplayRowProjector.swift'
SCAN_FILES=()
for file in "${LINT_TARGET_FILES[@]}"; do
    [[ "$(basename "$file")" == "$OWNER" ]] && continue
    SCAN_FILES+=("$file")
done

if [[ "${#SCAN_FILES[@]}" -eq 0 ]]; then
    echo "display row projection lint passed"
    exit 0
fi

# Not a comment line, and not the store's `var openTailPendingMarginCell` declaration.
PATTERN='^(?![[:space:]]*//)(?![[:space:]]*(?:public |internal |private |fileprivate )?var[[:space:]]+openTailPendingMarginCell\b).*\b(openTailPendingMarginCell|projectedMarginCell)\b'

set +e
rg --pcre2 -n "$PATTERN" "${SCAN_FILES[@]}"
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
    lint_rationale <<'TEXT'
display-row-projection-lint: the display-row seam rule has one owner.

Only `Terminal.DisplayRowProjector` (lib/TerminalCore/Sources/TerminalCore/DisplayRowProjector.swift)
may read `openTailPendingMarginCell` or call `projectedMarginCell`. A reader that needs the last
retained row's margin, its wrap, or a whole projected row asks a projector instead:

    let projector = activeDisplayRows          // or primaryDisplayRows
    let facts = projector.facts(forHistoryRow: index)   // or facts(forGridRow:)
    projector.project(row, facts) / projector.margin(of: row, facts) / projector.margin(stored:, facts)

The active stream severs the seam while the alternate screen is up; the primary stream never
does. Pick the stream, not the flag.
TEXT
    exit 1
elif [[ "$status" -ne 1 ]]; then
    fail "rg failed with status $status"
fi

echo "display row projection lint passed"
