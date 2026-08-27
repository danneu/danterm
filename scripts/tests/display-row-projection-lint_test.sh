#!/usr/bin/env bash
# Self-test for the display-row projection gate: a hand copy of the seam outside the
# projector fails; the projector, the store's declaration, and comments pass.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../display-row-projection-lint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

mkdir -p "$TMP/allowed" "$TMP/denied"
cat > "$TMP/allowed/DisplayRowProjector.swift" <<'SWIFT'
pendingMargin = history.openTailPendingMarginCell
let cell = Self.projectedMarginCell(stored: stored, follower: follower)
SWIFT
cat > "$TMP/allowed/LogicalLineStore.swift" <<'SWIFT'
        var openTailPendingMarginCell: Terminal.GridCell? {
            pendingMarginStyleId.map { Terminal.GridCell(kind: .padding, styleId: $0) }
        }
SWIFT
cat > "$TMP/allowed/Terminal.swift" <<'SWIFT'
// The seam is derived from `openTailPendingMarginCell` by the projector, never here.
let row = projector.project(stored, projector.facts(forHistoryRow: index))
SWIFT
"$LINT" "$TMP/allowed" >/dev/null \
    || fail "the projector, the store's declaration, and a comment should pass"

for construct in \
    'fillsMissingWrapSpacer: history.store.openTailPendingMarginCell != nil,' \
    'let margin = Self.projectedMarginCell(stored: nil, follower: first)' \
    'let pending = history.openTailPendingMarginCell  // read once'
do
    printf '%s\n' "$construct" > "$TMP/denied/Terminal.swift"
    if "$LINT" "$TMP/denied" >/dev/null 2>&1; then
        fail "a seam read outside the projector should fail: $construct"
    fi
done

printf '%s\n' 'let margin = Self.projectedMarginCell(stored: nil)' > "$TMP/denied/Terminal.swift"
set +e
explanation="$("$LINT" "$TMP/denied" 2>&1 >/dev/null)"
set -e
case "$explanation" in
    *DisplayRowProjector*) ;;
    *) fail "a failure should name the projector that owns the rule" ;;
esac

if "$LINT" "$TMP/no-such-directory" >/dev/null 2>&1; then
    fail "a missing scan target should fail rather than report a clean scan"
fi

echo "display row projection lint self-test passed"
