#!/usr/bin/env bash
# Self-test for the creation-command usage single-source gate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../creation-usage-single-source-lint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

mkdir -p "$TMP/allowed" "$TMP/denied"
cat > "$TMP/allowed/Args.swift" <<'SWIFT'
let newCommandFlagsUsage = "[--cmd <s>] [--cwd <p>] [--title <s>] [--background] [--foreground]"
let tabNewUsage = "usage: danterm tab new (--group <group-id>) \(newCommandFlagsUsage)"
let paneSplitUsage = "usage: danterm pane split --pane <pane-id> -h|-v \(newCommandFlagsUsage)"
SWIFT
cat > "$TMP/allowed/Parser.swift" <<'SWIFT'
throw CLIParseError(tabNewUsage)
throw CLIParseError("usage: danterm tab close --tab <tab-id>")
SWIFT
"$LINT" "$TMP/allowed" >/dev/null || fail "one composed definition per usage line should pass"

cat > "$TMP/denied/Parser.swift" <<'SWIFT'
throw CLIParseError(tabNewUsage)
throw CLIParseError("usage: danterm tab new (--group <group-id>) \(newCommandFlagsUsage)")
SWIFT
cp "$TMP/allowed/Args.swift" "$TMP/denied/Args.swift"
if "$LINT" "$TMP/denied" >/dev/null 2>&1; then
    fail "a second copy of a creation usage line should fail"
fi

rm -f "$TMP/denied/Parser.swift"
cat > "$TMP/denied/Args.swift" <<'SWIFT'
let tabNewUsage = "usage: danterm tab new (--group <group-id>) [--cmd <s>] [--cwd <p>] [--title <s>] [--background] [--foreground]"
let paneSplitUsage = "usage: danterm pane split --pane <pane-id> -h|-v [--cmd <s>] [--cwd <p>] [--title <s>] [--background] [--foreground]"
SWIFT
if "$LINT" "$TMP/denied" >/dev/null 2>&1; then
    fail "spelling the shared flags out in two usage lines should fail"
fi

echo "creation usage single-source lint self-test passed"
