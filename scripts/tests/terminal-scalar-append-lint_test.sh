#!/usr/bin/env bash
# Self-test for the scalar-append gate: what it must reject, and the three things
# it must not (per-scalar appends, array appends, and a marked bounded site).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../terminal-scalar-append-lint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

mkdir -p "$TMP/allowed" "$TMP/denied"
cat > "$TMP/allowed/Projection.swift" <<'SWIFT'
// Scalar at a time, not `unicodeScalars.append(contentsOf:)` -- the generic overload copies.
for scalar in unit.scalars { result.unicodeScalars.append(scalar) }
bytes.append(contentsOf: encodeTerminalMouse(event))
rows.append(contentsOf: packed.rows)
uri.unicodeScalars.append(contentsOf: scalars[start..<end])  // scalar-append: bounded-single-append
SWIFT
"$LINT" "$TMP/allowed" >/dev/null \
    || fail "per-scalar appends, array appends, and a marked bounded site should pass"

for construct in \
    'result.unicodeScalars.append(contentsOf: unit.scalars)' \
    'result.unicodeScalars.append( contentsOf: unit.scalars)' \
    'accumulator.unicodeScalars.append(contentsOf: run)  // bounded, honest' \
    'accumulator.unicodeScalars.append(contentsOf: run)  // scalar-append: allow'
do
    printf '%s\n' "$construct" > "$TMP/denied/Projection.swift"
    if "$LINT" "$TMP/denied" >/dev/null 2>&1; then
        fail "generic-sequence scalar append should fail: $construct"
    fi
done

if "$LINT" "$TMP/no-such-directory" >/dev/null 2>&1; then
    fail "a missing scan target should fail rather than report a clean scan"
fi

echo "terminal scalar append lint self-test passed"
