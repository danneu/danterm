#!/usr/bin/env bash
# Compiler-level proof that app capture APIs exist only in characterization builds.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    echo "terminal-capture-api-gate_test: $*" >&2
    exit 1
}

cat >"$TEST_ROOT/initializer-probe.swift" <<'EOF'
import PaneLifecycle
import TerminalPaneSession

@MainActor
func makeCapturingController(
    configuration: TerminalPaneLaunchConfiguration,
    bootstrapExecutable: String
) throws {
    _ = try TerminalPaneSessionController(
        configuration: configuration,
        bootstrapExecutable: bootstrapExecutable,
        captureTransitions: true
    )
}
EOF

cat >"$TEST_ROOT/accessor-probe.swift" <<'EOF'
import TerminalPaneSession

@MainActor
func readRecording(_ controller: TerminalPaneSessionController) {
    _ = controller.capturedRecording(test: "app-client")
}
EOF

typecheck_probe() {
    local modules="$1" source="$2" diagnostics="$3"
    xcrun swiftc -typecheck -swift-version 5 -I "$modules" "$source" 2>"$diagnostics"
}

default_build="$TEST_ROOT/default-build"
swift build --package-path "$REPO_ROOT/lib/TerminalPTY" --build-path "$default_build" >/dev/null
default_bin="$(swift build \
    --package-path "$REPO_ROOT/lib/TerminalPTY" \
    --build-path "$default_build" \
    --show-bin-path)"

for probe in initializer accessor; do
    diagnostics="$TEST_ROOT/default-$probe.err"
    if typecheck_probe \
        "$default_bin/Modules" \
        "$TEST_ROOT/$probe-probe.swift" \
        "$diagnostics"; then
        fail "default app client reached the capture $probe"
    fi
    if [[ "$probe" == "initializer" ]]; then
        expected="extra argument 'captureTransitions' in call"
    else
        expected="inaccessible due to 'package' protection level"
    fi
    if ! grep -qF "$expected" "$diagnostics"; then
        cat "$diagnostics" >&2
        fail "default $probe failed for an unexpected reason"
    fi
done

characterization_build="$TEST_ROOT/characterization-build"
swift build \
    --package-path "$REPO_ROOT/lib/TerminalPTY" \
    --build-path "$characterization_build" \
    -Xswiftc -DDANTERM_TERMINAL_CHARACTERIZATION >/dev/null
characterization_bin="$(swift build \
    --package-path "$REPO_ROOT/lib/TerminalPTY" \
    --build-path "$characterization_build" \
    -Xswiftc -DDANTERM_TERMINAL_CHARACTERIZATION \
    --show-bin-path)"

for probe in initializer accessor; do
    diagnostics="$TEST_ROOT/characterization-$probe.err"
    if ! typecheck_probe \
        "$characterization_bin/Modules" \
        "$TEST_ROOT/$probe-probe.swift" \
        "$diagnostics"; then
        cat "$diagnostics" >&2
        fail "characterization app client could not reach the capture $probe"
    fi
done

echo "terminal capture API gate tests passed"
