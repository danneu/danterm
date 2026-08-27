#!/usr/bin/env bash
# Compiler-level proof that app capture APIs exist only in characterization builds.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${DANTERM_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
source "$SCRIPT_DIR/../lib/build-paths.sh"
SWIFT="${DANTERM_SWIFT:-swift}"
XCRUN="${DANTERM_XCRUN:-xcrun}"
CORE_PACKAGE="$REPO_ROOT/lib/TerminalCore"
PTY_PACKAGE="$REPO_ROOT/lib/TerminalPTY"
CACHE_ROOT="$(danterm_gate_build_path "$REPO_ROOT" terminal-capture-api)"
DEFAULT_BUILD="$CACHE_ROOT/default"
CHARACTERIZATION_BUILD="$CACHE_ROOT/characterization"
STAMP="$CACHE_ROOT/terminal-core.sha256"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    echo "terminal-capture-api-gate_test: $*" >&2
    exit 1
}

if [[ "${1:-}" == "--list-build-paths" ]]; then
    printf 'terminal-capture-default\tgate\t%s\n' "$DEFAULT_BUILD"
    printf 'terminal-capture-characterization\tgate\t%s\n' "$CHARACTERIZATION_BUILD"
    exit 0
fi

terminal_core_fingerprint() {
    (
        cd "$CORE_PACKAGE"
        find Package.swift Sources -type f -print | LC_ALL=C sort | while IFS= read -r path; do
            printf '%s\0' "$path"
            shasum -a 256 "$path" | awk '{print $1}'
        done
    ) | shasum -a 256 | awk '{print $1}'
}

cat >"$TEST_ROOT/public-probe.swift" <<'EOF'
import TerminalPaneSession

@MainActor
func readPublicAPI(_ controller: TerminalPaneSessionController) {
    _ = controller.currentPlan
}
EOF

cat >"$TEST_ROOT/initializer-probe.swift" <<'EOF'
import PaneProcessLifecycle
import TerminalPTYHost
import TerminalPaneSession

@MainActor
func makeCapturingController(
    configuration: TerminalPaneLaunchConfiguration,
    bootstrapExecutable: String
) throws {
    let host = try TerminalPTYHost(
        launchInput: configuration.launchInput,
        initialGridPinned: configuration.initialGridPinned,
        bootstrapExecutable: bootstrapExecutable,
        productIdentity: configuration.productIdentity,
        recordsCompleteTape: true
    )
    _ = TerminalPaneSessionController(host: host)
}
EOF

cat >"$TEST_ROOT/accessor-probe.swift" <<'EOF'
import TerminalPaneSession

@MainActor
func readRecording(_ controller: TerminalPaneSessionController) {
    _ = controller.capturedRecording(test: "app-client")
}
EOF

# A Swift module in this package may depend on a C target (the bootstrap ABI
# header both ends of the status pipe read), and SwiftPM writes that target's
# module map beside its objects rather than into `Modules`. The probe compiles
# outside SwiftPM, so it has to be told where those maps are. Discovered rather
# than named, so a C target added later needs no edit here.
clang_module_map_flags() {
    local bin="$1" map
    while IFS= read -r map; do
        printf ' -Xcc -fmodule-map-file=%s' "$map"
    done < <(find "$bin" -name module.modulemap -maxdepth 2 2>/dev/null | LC_ALL=C sort)
}

typecheck_probe() {
    local modules="$1" source="$2" diagnostics="$3"
    local map_flags
    read -r -a map_flags <<<"$(clang_module_map_flags "$modules/..")"
    "$XCRUN" swiftc -typecheck -swift-version 5 -I "$modules" \
        "${map_flags[@]}" "$source" 2>"$diagnostics"
}

fingerprint="$(terminal_core_fingerprint)"
recorded_fingerprint=""
if [[ -f "$STAMP" ]]; then
    recorded_fingerprint="$(cat "$STAMP")"
fi

if [[ "$fingerprint" != "$recorded_fingerprint" ]]; then
    rm -rf "$DEFAULT_BUILD" "$CHARACTERIZATION_BUILD"
fi

"$SWIFT" build --package-path "$PTY_PACKAGE" --build-path "$DEFAULT_BUILD" >/dev/null
default_bin="$("$SWIFT" build \
    --package-path "$PTY_PACKAGE" \
    --build-path "$DEFAULT_BUILD" \
    --show-bin-path)"

public_diagnostics="$TEST_ROOT/default-public.err"
if ! typecheck_probe \
    "$default_bin/Modules" \
    "$TEST_ROOT/public-probe.swift" \
    "$public_diagnostics"; then
    cat "$public_diagnostics" >&2
    fail "default app client could not reach an ordinary public API"
fi

for probe in initializer accessor; do
    diagnostics="$TEST_ROOT/default-$probe.err"
    if typecheck_probe \
        "$default_bin/Modules" \
        "$TEST_ROOT/$probe-probe.swift" \
        "$diagnostics"; then
        fail "default app client reached the capture $probe"
    fi
done

"$SWIFT" build \
    --package-path "$PTY_PACKAGE" \
    --build-path "$CHARACTERIZATION_BUILD" \
    -Xswiftc -DDANTERM_TERMINAL_CHARACTERIZATION >/dev/null
characterization_bin="$("$SWIFT" build \
    --package-path "$PTY_PACKAGE" \
    --build-path "$CHARACTERIZATION_BUILD" \
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

mkdir -p "$CACHE_ROOT"
temporary_stamp="$(mktemp "$CACHE_ROOT/.terminal-core.sha256.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"; rm -f "$temporary_stamp"' EXIT
printf '%s\n' "$fingerprint" > "$temporary_stamp"
mv "$temporary_stamp" "$STAMP"
trap 'rm -rf "$TEST_ROOT"' EXIT

echo "terminal capture API gate tests passed"
