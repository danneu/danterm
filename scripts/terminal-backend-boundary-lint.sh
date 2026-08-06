#!/usr/bin/env bash
# Restrict linked terminal implementations to their dedicated app adapter files.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-$SCRIPT_DIR/../app}"
THEME_RUNTIME_TARGETS=("$TARGET")
if [[ $# -eq 0 ]]; then
    THEME_RUNTIME_TARGETS+=(
        "$SCRIPT_DIR/../lib/DanTermCore/Sources/DanTermCore"
        "$SCRIPT_DIR/../lib/TerminalCore/Sources"
        "$SCRIPT_DIR/../lib/TerminalPTY/Sources"
    )
fi

failed=0
while IFS= read -r file; do
    if grep -nE '^[[:space:]]*(@[^[:space:]]+[[:space:]]+)?import[[:space:]]+GhosttyKit([^[:alnum:]_]|$)' "$file"; then
        echo "GhosttyKit import in a target with no Ghostty backend: $file" >&2
        failed=1
    fi
done < <(find "$TARGET" -name '*.swift' -type f -print)

while IFS= read -r file; do
    case "$(basename "$file")" in
        SwiftTerminalSessionView.swift|SwiftTerminalBackend.swift|ThemeRenderBridge.swift|TerminalBenchmark.swift)
            continue
            ;;
    esac
    if grep -nE '^[[:space:]]*(@[^[:space:]]+[[:space:]]+)?import[[:space:]]+(PaneLifecycle|TerminalCore|TerminalCoreRecording|TerminalPTYHost|TerminalPaneSession|TerminalRenderPlanning|TerminalRenderExecution)([^[:alnum:]_]|$)' "$file"; then
        echo "Swift terminal engine import outside adapter allowlist: $file" >&2
        failed=1
    fi
done < <(find "$TARGET" -name '*.swift' -type f -print)

for theme_target in "${THEME_RUNTIME_TARGETS[@]}"; do
    while IFS= read -r file; do
        if grep -nE 'ghostty/themes|ThemeColorParser' "$file"; then
            echo "Ghostty theme syntax or paths in a target with no Ghostty backend: $file" >&2
            failed=1
        fi
    done < <(find "$theme_target" -name '*.swift' -type f -print)
done

if [[ "$failed" -ne 0 ]]; then
    exit 1
fi
