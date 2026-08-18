#!/usr/bin/env bash
# Self-test for the type-check budget gate.
#
# Every case drives the gate with a canned-output runner instead of a compiler, so
# the verdict is proven without a build and without turning on how fast anything
# ran. The fixture manifests are tiny and local; nothing here names a real package,
# which also keeps this file from reading to scripts/gate-test-coverage-lint.py as
# a second test lane for lib/TerminalCore.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$SCRIPT_DIR/../type-check-budget-gate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- fixtures --------------------------------------------------------------

# A runner that replays canned compiler output and exits with a chosen code.
runner() {
    cat > "$TMP/canned-runner" <<RUNNER
#!/usr/bin/env bash
cat <<'OUTPUT'
$1
OUTPUT
exit ${2:-0}
RUNNER
    chmod +x "$TMP/canned-runner"
}

# A manifest carrying the shared budget setting on every target.
mkdir -p "$TMP/good"
cat > "$TMP/good/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription

let typeCheckBudget: SwiftSetting = .unsafeFlags([
    "-Xfrontend", "-warn-long-function-bodies=500",
    "-Xfrontend", "-debug-diagnostic-names",
])

let package = Package(
    name: "Fixture",
    targets: [
        .target(
            name: "Fixture",
            path: "Sources/Fixture",
            swiftSettings: [.swiftLanguageMode(.v6), typeCheckBudget]
        ),
        .testTarget(
            name: "FixtureTests",
            dependencies: ["Fixture"],
            path: "Tests/FixtureTests",
            swiftSettings: [.swiftLanguageMode(.v6), typeCheckBudget]
        ),
    ]
)
SWIFT

# The same manifest with the FIRST target -- `Fixture` -- quietly opting out, so a
# run has to distinguish the target that skipped the budget from the one that did not.
mkdir -p "$TMP/opted-out"
awk '!dropped && /typeCheckBudget\]/ { sub(/, typeCheckBudget/, ""); dropped = 1 } { print }' \
    "$TMP/good/Package.swift" > "$TMP/opted-out/Package.swift"

# A manifest with no budget definition at all.
mkdir -p "$TMP/no-budget"
cat > "$TMP/no-budget/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Fixture",
    targets: [
        .target(name: "Fixture", path: "Sources/Fixture"),
    ]
)
SWIFT

# A manifest that budgets every target but never asks for diagnostic names.
mkdir -p "$TMP/no-names"
grep -v 'debug-diagnostic-names' "$TMP/good/Package.swift" > "$TMP/no-names/Package.swift"

BREACH='/x/Tests/FixtureTests/SlowTest.swift:12:17: warning: instance method '"'"'slow()'"'"' took 710ms to type-check (limit: 500ms) [debug_long_function_body]'

drive() { "$GATE" "$TMP/canned-runner" --package-path "$1" --scratch-path "$TMP/scratch"; }

# --- the verdict on compiler output ----------------------------------------

runner "Test run with 3 tests passed after 0.4 seconds." 0
drive "$TMP/good" > "$TMP/out" 2>&1 || fail "a clean build under budget should pass"

runner "$BREACH" 0
if drive "$TMP/good" > "$TMP/out" 2>&1; then
    fail "an over-budget body should fail the step"
fi
grep -q "slow()" "$TMP/out" || fail "the failure must name the function"
grep -q "SlowTest.swift:12" "$TMP/out" || fail "the failure must name the location"
grep -q "710ms" "$TMP/out" || fail "the failure must name the measured cost"

# The identifier is what the gate keys on, so a reworded warning still fails.
runner "/x/S.swift:12:17: warning: body of '\''slow()'\'' is slow to check [debug_long_function_body]" 0
if drive "$TMP/good" > "$TMP/out" 2>&1; then
    fail "a reworded warning carrying the identifier should still fail"
fi

# ...and prose alone is not what it keys on, so a warning that merely reads like
# one cannot arm the gate by accident either.
runner "note: took 710ms to type-check (limit: 500ms), which is a lot" 0
drive "$TMP/good" > "$TMP/out" 2>&1 \
    || fail "prose without the diagnostic identifier is not a breach"

# --- a failing test run is still a failing step -----------------------------

runner "Test run with 3 tests failed: expectation was not fulfilled." 1
if drive "$TMP/good" > "$TMP/out" 2>&1; then
    fail "a failing test run should fail the step even with no budget warning"
fi
grep -q "expectation was not fulfilled" "$TMP/out" \
    || fail "the underlying output must survive into what the gate replays"

# --- the manifest is the gate's own precondition ----------------------------

runner "Test run with 3 tests passed after 0.4 seconds." 0
if drive "$TMP/opted-out" > "$TMP/out" 2>&1; then
    fail "a target without the shared setting should be rejected"
fi
grep -qx "    Fixture" "$TMP/out" || fail "the rejection must name the target that opted out"
if grep -q "FixtureTests" "$TMP/out"; then
    fail "the rejection must not name a target that carries the budget"
fi

if drive "$TMP/no-budget" > "$TMP/out" 2>&1; then
    fail "a manifest with no budget definition should fail as a broken gate"
fi
grep -q "no shared SwiftSetting" "$TMP/out" \
    || fail "a missing budget definition must read as a broken gate, not a test failure"

if drive "$TMP/no-names" > "$TMP/out" 2>&1; then
    fail "a budget without -debug-diagnostic-names should fail as a broken gate"
fi

if "$GATE" "$TMP/canned-runner" --package-path "$TMP/missing" --scratch-path "$TMP/scratch" \
    > "$TMP/out" 2>&1; then
    fail "a package path with no manifest should fail"
fi

# --- the measurement window is required -------------------------------------

if "$GATE" "$TMP/canned-runner" --package-path "$TMP/good" > "$TMP/out" 2>&1; then
    fail "the gate must refuse to run with no scratch path"
fi
grep -q "no --scratch-path" "$TMP/out" \
    || fail "the refusal must say the scratch path is what is missing"

if "$GATE" > "$TMP/out" 2>&1; then
    fail "the gate must refuse to run with no command"
fi

echo "type-check budget gate self-test passed"
