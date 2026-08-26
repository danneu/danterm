#!/usr/bin/env bash
# Self-test for the type-check budget gate.
#
# Every case drives the gate with a canned-output runner instead of a compiler, so
# the verdict is proven without a build and without turning on how fast anything
# ran. The runner also records the argv it was handed, which is how the flags the
# gate supplies are checked -- observed on the command, not read off the source.
#
# The fixture package is tiny and local; nothing here names a real package, which
# also keeps this file from reading to scripts/gate-test-coverage-lint.py as a
# second test lane for lib/TerminalCore.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$SCRIPT_DIR/../type-check-budget-gate.sh"
# `pwd -P`: the gate classifies a diagnostic by comparing its path against the
# resolved package root, and mktemp hands back a path through a symlink on macOS.
# A fixture built on the unresolved spelling would look like a foreign package.
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- fixtures --------------------------------------------------------------

# A runner that records its argv and replays canned compiler output, then exits
# with a chosen code.
runner() {
    cat > "$TMP/canned-runner" <<RUNNER
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TMP/argv"
cat <<'OUTPUT'
$1
OUTPUT
exit ${2:-0}
RUNNER
    chmod +x "$TMP/canned-runner"
}

# The package under measurement. Its manifest carries no budget: the gate is the
# only thing that arms one now, so the manifest has nothing to say about it.
mkdir -p "$TMP/pkg"
cat > "$TMP/pkg/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Fixture",
    targets: [
        .target(
            name: "Fixture",
            path: "Sources/Fixture",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
SWIFT

# Both breach lines reproduce what the toolchain printed on a real build of
# lib/TerminalCore: an absolute source path, and -- for a dependency -- a path
# under the scratch tree's `checkouts`, which is where SwiftPM puts a resolved
# package's sources.
OWN_BREACH="$TMP/pkg/Sources/Fixture/Slow.swift:12:17: warning: instance method 'slow()' took 710ms to type-check (limit: 500ms) [debug_long_function_body]"
DEP_BREACH="$TMP/scratch/checkouts/swift-collections/Sources/DequeModule/Deque.swift:88:5: warning: instance method 'append(_:)' took 710ms to type-check (limit: 500ms) [debug_long_function_body]"
# The compiler renders each diagnostic with a source excerpt underneath, and the
# marker line repeats the message and its identifier. Those lines are indented,
# and the gate must not read them as a second breach in an unknown package.
CARET_TAIL='   |          `- warning: instance method '"'"'slow()'"'"' took 710ms to type-check (limit: 500ms) [debug_long_function_body]'

drive() { "$GATE" "$TMP/canned-runner" --package-path "$TMP/pkg" --scratch-path "$TMP/scratch"; }

# --- the gate arms the build it runs ----------------------------------------

runner "Test run with 3 tests passed after 0.4 seconds." 0
drive > "$TMP/out" 2>&1 || fail "a clean build under budget should pass"

grep -qx -- '-warn-long-function-bodies=500' "$TMP/argv" \
    || fail "the gate must hand the command the limit it enforces"
grep -qx -- '-debug-diagnostic-names' "$TMP/argv" \
    || fail "the gate must ask for the identifier it keys on"
grep -qx -- '-Xfrontend' "$TMP/argv" || fail "the frontend flags must be marked as such"
grep -qx -- "--scratch-path" "$TMP/argv" || fail "the caller's own arguments must survive"

# --- the verdict on compiler output ----------------------------------------

runner "$OWN_BREACH" 0
if drive > "$TMP/out" 2>&1; then
    fail "an over-budget body in the measured package should fail the step"
fi
grep -q "slow()" "$TMP/out" || fail "the failure must name the function"
grep -q "Slow.swift:12" "$TMP/out" || fail "the failure must name the location"
grep -q "710ms" "$TMP/out" || fail "the failure must name the measured cost"

# The identifier is what the gate keys on, so a reworded warning still fails.
runner "$TMP/pkg/Sources/Fixture/Slow.swift:12:17: warning: body is slow to check [debug_long_function_body]" 0
if drive > "$TMP/out" 2>&1; then
    fail "a reworded warning carrying the identifier should still fail"
fi

# ...and prose alone is not what it keys on, so a warning that merely reads like
# one cannot arm the gate by accident either.
runner "note: took 710ms to type-check (limit: 500ms), which is a lot" 0
drive > "$TMP/out" 2>&1 || fail "prose without the diagnostic identifier is not a breach"

# --- the budget is the measured package's ------------------------------------

# The flags reach every target the build compiles, dependencies included. A body
# in someone else's sources is not this package's budget to enforce, so the step
# stays green -- and says which diagnostics it left alone.
runner "$DEP_BREACH" 0
drive > "$TMP/out" 2>&1 || fail "a breach in a dependency's sources must not fail the step"
grep -q "Deque.swift" "$TMP/out" || fail "the step must report the diagnostic it did not judge"

runner "$(printf '%s\n%s' "$DEP_BREACH" "$OWN_BREACH")" 0
if drive > "$TMP/out" 2>&1; then
    fail "an own-package breach must fail even when a dependency also breached"
fi

# The excerpt under a diagnostic repeats the identifier on an indented line.
runner "$(printf '%s\n%s' "$OWN_BREACH" "$CARET_TAIL")" 0
if drive > "$TMP/out" 2>&1; then
    fail "the breach should still fail the step"
fi
if grep -q "did not judge" "$TMP/out"; then
    fail "an excerpt line is part of a diagnostic, not an unjudged one"
fi

# --- a failing test run is still a failing step -----------------------------

runner "Test run with 3 tests failed: expectation was not fulfilled." 1
if drive > "$TMP/out" 2>&1; then
    fail "a failing test run should fail the step even with no budget warning"
fi
grep -q "expectation was not fulfilled" "$TMP/out" \
    || fail "the underlying output must survive into what the gate replays"

# --- preconditions -----------------------------------------------------------

runner "Test run with 3 tests passed after 0.4 seconds." 0
if "$GATE" "$TMP/canned-runner" --package-path "$TMP/missing" --scratch-path "$TMP/scratch" \
    > "$TMP/out" 2>&1; then
    fail "a package path with no manifest should fail"
fi

# The measurement window is required: without a tree of its own the gate would
# hand the recompile, and with it the measurement, to whoever built first.
if "$GATE" "$TMP/canned-runner" --package-path "$TMP/pkg" > "$TMP/out" 2>&1; then
    fail "the gate must refuse to run with no scratch path"
fi
grep -q "no --scratch-path" "$TMP/out" \
    || fail "the refusal must say the scratch path is what is missing"

if "$GATE" > "$TMP/out" 2>&1; then
    fail "the gate must refuse to run with no command"
fi

echo "type-check budget gate self-test passed"
