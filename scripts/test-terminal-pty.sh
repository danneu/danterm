#!/usr/bin/env bash
# Runs TerminalPTY tests only after invalidating artifacts built against changed
# TerminalCore inputs, while preserving SwiftPM's warm cache when inputs match.
# Compiling and running are separate steps here so the lane deadline covers only
# the run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${DANTERM_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SWIFT="${DANTERM_SWIFT:-swift}"
TEST_TIMEOUT_SECONDS="${DANTERM_PTY_TEST_TIMEOUT_SECONDS:-180}"
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

# Built once, ahead of both lanes and outside their deadline. The deadline below
# exists to bound a wedged test process; a compile folded into it makes the
# number a function of how much else the machine is compiling, so a slow
# compiler reports as a PTY hang. The gate's CPU-token pool already bounds how
# much compiling happens at once, which is what this build answers to instead.
# The clean above means this is a cold compile whenever TerminalCore changed.
"$SWIFT" build --build-tests --package-path "$PTY_PACKAGE"

python3 "$SCRIPT_DIR/run-with-deadline.py" \
    "$TEST_TIMEOUT_SECONDS" "TerminalPTY test lane" \
    "$SWIFT" test --package-path "$PTY_PACKAGE" --skip-build \
    --skip rapidCloseStressLeavesNoResources "$@"
# Process-wide fd census: needs a process to itself, since parallel suites
# legitimately hold /dev/ptmx descriptors across its baseline.
python3 "$SCRIPT_DIR/run-with-deadline.py" \
    "$TEST_TIMEOUT_SECONDS" "TerminalPTY fd-census lane" \
    "$SWIFT" test --package-path "$PTY_PACKAGE" --skip-build \
    --filter rapidCloseStressLeavesNoResources

mkdir -p "$STAMP_DIR"
temporary_stamp="$(mktemp "$STAMP_DIR/.terminal-core.sha256.XXXXXX")"
trap 'rm -f "$temporary_stamp"' EXIT
printf '%s\n' "$fingerprint" > "$temporary_stamp"
mv "$temporary_stamp" "$STAMP"
trap - EXIT
