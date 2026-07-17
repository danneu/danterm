#!/usr/bin/env bash
# Restrict GhosttyKit imports to the linked Ghostty adapter and process entry point.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-$SCRIPT_DIR/../app}"

failed=0
while IFS= read -r file; do
    case "$(basename "$file")" in
        TerminalView.swift|GhosttyApp.swift|GhosttyBindingAction.swift|GhosttyText.swift|main.swift)
            continue
            ;;
    esac
    if grep -nE '^[[:space:]]*(@[^[:space:]]+[[:space:]]+)?import[[:space:]]+GhosttyKit([^[:alnum:]_]|$)' "$file"; then
        echo "GhosttyKit import outside terminal adapter allowlist: $file" >&2
        failed=1
    fi
done < <(find "$TARGET" -name '*.swift' -type f -print)

if [[ "$failed" -ne 0 ]]; then
    exit 1
fi
