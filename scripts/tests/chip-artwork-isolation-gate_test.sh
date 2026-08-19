#!/usr/bin/env bash
# Self-test for the chip-artwork isolation gate: it has to accept a pair of files
# that name CoreGraphics alone, and reject both ways the isolation can be lost --
# an extra import, and a reference to a type that lives elsewhere in the package.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$SCRIPT_DIR/../chip-artwork-isolation-gate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

write_pair() {
    local artwork_extra="$1" renderer_extra="$2"
    mkdir -p "$TMP/fixture"
    printf 'import CoreGraphics\n%s\nlet chipFill: CGFloat = 0.7\n' \
        "$artwork_extra" >"$TMP/fixture/ChipArtwork.swift"
    printf 'import CoreGraphics\n%s\nfunc chipBox() -> CGRect { CGRect(x: 0, y: 0, width: chipFill, height: 1) }\n' \
        "$renderer_extra" >"$TMP/fixture/ChipRenderer.swift"
}

write_pair "" ""
"$GATE" "$TMP/fixture" >/dev/null || fail "a CoreGraphics-only pair should pass"

# An import of anything else is the first way the loose compile breaks.
write_pair "import Foundation" ""
if "$GATE" "$TMP/fixture" >/dev/null 2>&1; then
    fail "an extra import should fail"
fi

# An attribute in front of the import must not smuggle it past the check.
write_pair "" "@preconcurrency import Foundation"
if "$GATE" "$TMP/fixture" >/dev/null 2>&1; then
    fail "an attributed extra import should fail"
fi

# A sibling type needs no import inside a module, so only the compile catches it.
write_pair "" "let kind = ChipKind.terminal"
if "$GATE" "$TMP/fixture" >/dev/null 2>&1; then
    fail "a reference to a type from elsewhere in the package should fail"
fi

# A file the gate names but cannot find is a failure, not a silent pass.
write_pair "" ""
rm "$TMP/fixture/ChipRenderer.swift"
if "$GATE" "$TMP/fixture" >/dev/null 2>&1; then
    fail "a missing file should fail"
fi

echo "chip artwork isolation gate self-test passed"
