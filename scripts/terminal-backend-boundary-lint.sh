#!/usr/bin/env bash
# Confine the Swift terminal engine's modules to the app's adapter files.
#
# The engine (PaneProcessLifecycle, TerminalCore, TerminalPTYHost, ...) is DanTerm's
# implementation detail, not its app-wide vocabulary. Only the handful of
# adapter files below may name those modules; everything else in the app talks
# to the engine through the backend protocol. Without this check, engine types
# leak into view controllers, models, and menus one convenient import at a
# time, and the seam that makes the app testable without a live terminal is
# gone before anyone notices.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-$SCRIPT_DIR/../app}"

# Files permitted to import the engine: the backend adapter, its view, the
# theme bridge that translates DanTerm colors into engine colors, the link
# converter that asks the engine's activation gate before building a URL, and
# the benchmark harness that drives the engine directly on purpose.
ADAPTER_ALLOWLIST='SwiftTerminalSessionView.swift|SwiftTerminalBackend.swift|ThemeRenderBridge.swift|TerminalLinkURL.swift|TerminalBenchmark.swift'
ENGINE_MODULES='PaneProcessLifecycle|TerminalCore|TerminalCoreRecording|TerminalPTYHost|TerminalPaneSession|TerminalRenderPlanning|TerminalRenderExecution'

failed=0
while IFS= read -r file; do
    if [[ "$(basename "$file")" =~ ^($ADAPTER_ALLOWLIST)$ ]]; then
        continue
    fi
    if grep -nE "^[[:space:]]*(@[^[:space:]]+[[:space:]]+)?import[[:space:]]+($ENGINE_MODULES)([^[:alnum:]_]|\$)" "$file"; then
        echo "Swift terminal engine import outside adapter allowlist: $file" >&2
        failed=1
    fi
done < <(find "$TARGET" -name '*.swift' -type f -print)

if [[ "$failed" -ne 0 ]]; then
    exit 1
fi
