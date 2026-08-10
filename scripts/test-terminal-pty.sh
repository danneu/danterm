#!/usr/bin/env bash
# Runs TerminalPTY tests only after invalidating artifacts built against changed
# TerminalCore inputs, while preserving SwiftPM's warm cache when inputs match.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${DANTERM_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SWIFT="${DANTERM_SWIFT:-swift}"
CORE_PACKAGE="$REPO_ROOT/lib/TerminalCore"
PTY_PACKAGE="$REPO_ROOT/lib/TerminalPTY"
STAMP_DIR="$REPO_ROOT/.build/test-terminal-pty"
STAMP="$STAMP_DIR/terminal-core.sha256"

terminal_core_fingerprint() {
    (
        cd "$CORE_PACKAGE"
        find Package.swift Sources -type f -print | LC_ALL=C sort | while IFS= read -r path; do
            printf '%s\0' "$path"
            shasum -a 256 "$path" | awk '{print $1}'
        done
    ) | shasum -a 256 | awk '{print $1}'
}

fingerprint="$(terminal_core_fingerprint)"
recorded_fingerprint=""
if [[ -f "$STAMP" ]]; then
    recorded_fingerprint="$(cat "$STAMP")"
fi

if [[ "$fingerprint" != "$recorded_fingerprint" ]]; then
    "$SWIFT" package --package-path "$PTY_PACKAGE" clean
fi

"$SWIFT" test --package-path "$PTY_PACKAGE" \
    --skip rapidCloseStressLeavesNoResources "$@"
# Process-wide fd census: needs a process to itself, since parallel suites
# legitimately hold /dev/ptmx descriptors across its baseline.
"$SWIFT" test --package-path "$PTY_PACKAGE" \
    --filter rapidCloseStressLeavesNoResources

mkdir -p "$STAMP_DIR"
temporary_stamp="$(mktemp "$STAMP_DIR/.terminal-core.sha256.XXXXXX")"
trap 'rm -f "$temporary_stamp"' EXIT
printf '%s\n' "$fingerprint" > "$temporary_stamp"
mv "$temporary_stamp" "$STAMP"
trap - EXIT
