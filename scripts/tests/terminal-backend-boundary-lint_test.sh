#!/usr/bin/env bash
# Self-test for the Swift-engine import allowlist: the boundary lint has to
# reject an engine import outside the adapter files and accept one inside them.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../terminal-backend-boundary-lint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

ENGINE_MODULES=(
    PaneProcessLifecycle
    TerminalCore
    TerminalCoreRecording
    TerminalPTYHost
    TerminalPaneSession
    TerminalRenderPlanning
    TerminalRenderExecution
)

mkdir -p "$TMP/allowed" "$TMP/denied"

# Every engine module is importable from every adapter file.
for file in SwiftTerminalSessionView.swift SwiftTerminalBackend.swift ThemeRenderBridge.swift TerminalBenchmark.swift; do
    for module in "${ENGINE_MODULES[@]}"; do
        printf 'import %s\n' "$module" > "$TMP/allowed/$file"
        "$LINT" "$TMP/allowed" >/dev/null \
            || fail "engine import $module should be allowed in $file"
    done
    rm "$TMP/allowed/$file"
done

# The same import from any other app file is a boundary violation.
for module in "${ENGINE_MODULES[@]}"; do
    printf 'import Cocoa\nimport %s\n' "$module" > "$TMP/denied/AppRuntime.swift"
    if "$LINT" "$TMP/denied" >/dev/null 2>&1; then
        fail "non-allowlisted engine import $module should fail"
    fi
done

# An attribute in front of the import must not smuggle it past the check.
printf '@preconcurrency import TerminalCore\n' > "$TMP/denied/AppRuntime.swift"
if "$LINT" "$TMP/denied" >/dev/null 2>&1; then
    fail "attributed engine import should fail"
fi

# The allowlist matches whole file names, not substrings of them.
printf 'import TerminalCore\n' > "$TMP/denied/NotSwiftTerminalBackend.swift"
if "$LINT" "$TMP/denied" >/dev/null 2>&1; then
    fail "a file merely ending in an allowlisted name should not be exempt"
fi
rm "$TMP/denied/NotSwiftTerminalBackend.swift"

printf '// import TerminalCore\nimport TerminalCoreExtras\n' > "$TMP/denied/AppRuntime.swift"
"$LINT" "$TMP/denied" >/dev/null \
    || fail "comments and longer engine module names should pass"

echo "terminal backend boundary lint self-test passed"
