#!/usr/bin/env bash
# Self-test for the app GhosttyKit import allowlist.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../terminal-backend-boundary-lint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

mkdir -p "$TMP/allowed" "$TMP/denied"
for file in TerminalView.swift GhosttyApp.swift GhosttyBindingAction.swift GhosttyText.swift main.swift; do
    printf 'import GhosttyKit\n' > "$TMP/allowed/$file"
done
"$LINT" "$TMP/allowed" >/dev/null || fail "allowlisted adapter imports should pass"

printf 'import Cocoa\nimport GhosttyKit\n' > "$TMP/denied/AppRuntime.swift"
if "$LINT" "$TMP/denied" >/dev/null 2>&1; then
    fail "non-allowlisted GhosttyKit import should fail"
fi

printf '// import GhosttyKit\nimport GhosttyKitExtra\n' > "$TMP/denied/AppRuntime.swift"
"$LINT" "$TMP/denied" >/dev/null || fail "comments and longer module names should pass"

echo "terminal backend boundary lint self-test passed"
