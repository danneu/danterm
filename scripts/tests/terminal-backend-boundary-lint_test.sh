#!/usr/bin/env bash
# Self-test for the app's GhosttyKit ban and Swift-engine import allowlist.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../terminal-backend-boundary-lint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

mkdir -p "$TMP/allowed" "$TMP/denied"

printf 'import Cocoa\nimport GhosttyKit\n' > "$TMP/denied/AppRuntime.swift"
if "$LINT" "$TMP/denied" >/dev/null 2>&1; then
    fail "any GhosttyKit import should fail"
fi

printf '// import GhosttyKit\nimport GhosttyKitExtra\n' > "$TMP/denied/AppRuntime.swift"
"$LINT" "$TMP/denied" >/dev/null || fail "comments and longer module names should pass"

rm -rf "$TMP/allowed" "$TMP/denied"
mkdir -p "$TMP/allowed" "$TMP/denied"
for file in SwiftTerminalSessionView.swift SwiftTerminalBackend.swift ThemeRenderBridge.swift; do
    for module in PaneLifecycle TerminalCore TerminalCoreRecording TerminalPTYHost TerminalPaneSession TerminalRenderPlanning TerminalRenderExecution; do
        printf 'import %s\n' "$module" > "$TMP/allowed/$file"
        "$LINT" "$TMP/allowed" >/dev/null \
            || fail "engine import $module should be allowed in $file"
    done
done

printf 'import Cocoa\nimport TerminalPaneSession\n' > "$TMP/denied/AppRuntime.swift"
if "$LINT" "$TMP/denied" >/dev/null 2>&1; then
    fail "non-allowlisted engine import should fail"
fi

printf 'import Cocoa\nimport TerminalCoreRecording\n' > "$TMP/denied/AppRuntime.swift"
if "$LINT" "$TMP/denied" >/dev/null 2>&1; then
    fail "non-allowlisted recording import should fail"
fi

printf '// import TerminalCore\nimport TerminalCoreExtras\n' > "$TMP/denied/AppRuntime.swift"
"$LINT" "$TMP/denied" >/dev/null \
    || fail "comments and longer engine module names should pass"

printf 'let path = "ghostty/themes"\n' > "$TMP/denied/ThemeCatalog.swift"
if "$LINT" "$TMP/denied" >/dev/null 2>&1; then
    fail "DanTerm runtime theme paths should fail"
fi

rm "$TMP/denied/ThemeCatalog.swift"

echo "terminal backend boundary lint self-test passed"
