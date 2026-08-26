#!/usr/bin/env bash
# Self-test for the engine-publishable gate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../engine-publishable-lint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

CORE='lib/TerminalCore'
PTY='lib/TerminalPTY'
mkdir -p "$TMP/clean/$CORE" "$TMP/clean/$PTY"

cat > "$TMP/clean/$CORE/Package.swift" <<'SWIFT'
targets: [
    .target(name: "TerminalCore", swiftSettings: [.swiftLanguageMode(.v6)]),
]
SWIFT
cat > "$TMP/clean/$PTY/Package.swift" <<'SWIFT'
targets: [
    .target(name: "PaneProcessLifecycle", dependencies: ["TerminalCore"]),
]
SWIFT
ENGINE_PUBLISHABLE_LINT_ROOT="$TMP/clean" "$LINT" >/dev/null \
    || fail "manifests without unsafeFlags should pass"

# Each engine manifest is checked, not just the one that carried the flags: the reuse story
# publishes both packages, and either one can forfeit a versioned dependency on its own.
for manifest in "$CORE" "$PTY"; do
    cp -R "$TMP/clean" "$TMP/denied"
    cat >> "$TMP/denied/$manifest/Package.swift" <<'SWIFT'
    .target(name: "Probe", swiftSettings: [.unsafeFlags(["-Xfrontend", "-warn-long-function-bodies=500"])]),
SWIFT
    if ENGINE_PUBLISHABLE_LINT_ROOT="$TMP/denied" "$LINT" >/dev/null 2>&1; then
        fail "unsafeFlags in $manifest should fail"
    fi
    rm -rf "$TMP/denied"
done

# The rule bans a declaration, not the word: a manifest may keep the history of what it used
# to carry as a comment.
cp -R "$TMP/clean" "$TMP/commented"
cat >> "$TMP/commented/$CORE/Package.swift" <<'SWIFT'
// The budget used to live here as .unsafeFlags; scripts/type-check-budget-gate.sh owns it now.
SWIFT
ENGINE_PUBLISHABLE_LINT_ROOT="$TMP/commented" "$LINT" >/dev/null \
    || fail "a commented mention of unsafeFlags should pass"

# A failing run owes the reader the rule, not just the line it measured.
cp -R "$TMP/clean" "$TMP/rationale"
cat >> "$TMP/rationale/$CORE/Package.swift" <<'SWIFT'
    .target(name: "Probe", swiftSettings: [.unsafeFlags(["-Xfrontend", "-stats-output-dir", "."])]),
SWIFT
ENGINE_PUBLISHABLE_LINT_ROOT="$TMP/rationale" "$LINT" >/dev/null 2>"$TMP/rationale.txt" || true
grep -q 'engine-publishable lint FAILED' "$TMP/rationale.txt" \
    || fail "the failure should print the rationale block"
grep -q 'Move the flags to whatever enforces them' "$TMP/rationale.txt" \
    || fail "the failure should say what to do instead"
grep -q "$CORE/Package.swift:.*-stats-output-dir" "$TMP/rationale.txt" \
    || fail "the failure should name the manifest and the line it measured"

# A manifest the gate cannot find is one it cannot vouch for, so a renamed package must fail
# rather than let the sweep report success over a list it never read.
mv "$TMP/clean/$PTY/Package.swift" "$TMP/clean/$PTY/Renamed.swift"
if ENGINE_PUBLISHABLE_LINT_ROOT="$TMP/clean" "$LINT" >/dev/null 2>&1; then
    fail "a missing engine manifest should fail the sweep"
fi

# The real tree is the point of the gate: both shipped engine manifests are clean today.
"$LINT" >/dev/null || fail "the engine manifests in this repository should pass"

echo "engine publishable lint self-test passed"
