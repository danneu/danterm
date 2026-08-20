#!/usr/bin/env bash
# Self-test for the half of the iOS portability gate that actually cross-compiles. It
# builds a fixture tree of tiny packages instead of the engine, so the claims below are
# proved in seconds:
#
#   1. A pinned package whose every target compiles for iOS passes, a pinned package
#      under ios/ is discovered and built, and an unpinned one is not built at all.
#   2. A pinned package with a host-bound TARGET fails -- the case that matters, because
#      SwiftPM would otherwise skip test targets and report success.
#   3. `--package` builds the one package named and no other.
#   4. `--package` builds a package discovery excludes, when a human names it by hand.
#   5. `--package` fails on a host-bound target, exactly as the sweep does.
#
# Claim 2 is the one a cheaper gate gets wrong: `Process()` in a pinned target has to
# fail on the commit that adds it, and only a real compile against the iOS SDK sees that.
# Claims 3 through 5 are what let the gate pool run one step per package without
# weakening any single package's check.
#
# The claims that need no compiler -- discovery, the pinned set, and the refusals the
# gate makes before it resolves an SDK -- live in
# scripts/tests/ios-portability-gate-discovery_test.sh, which runs in a second because it
# never reaches a toolchain. The two files share no fixture directory.
#
# Each case below builds its own fixture root and runs on its own worker, so nothing one
# case writes can reach another's assertion. `--case` is how a worker asks for one; it is
# internal to this file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$SCRIPT_DIR/../ios-portability-gate.sh"

CASES=(sweep package-one package-hatch sweep-host-bound package-host-bound)

fail() { echo "FAIL: $CASE_NAME: $1" >&2; exit 1; }

# Fixture packages. `platforms:` is what the gate reads, so the pin is the only
# difference between a package that is built and one that is skipped.
write_package() { # name platforms sourceBody
    local name="$1" platforms="$2" body="$3"
    mkdir -p "$ROOT/lib/$name/Sources/$name" "$ROOT/lib/$name/Tests/${name}Tests"
    cat > "$ROOT/lib/$name/Package.swift" <<EOF
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "$name",
    platforms: [$platforms],
    targets: [
        .target(name: "$name", path: "Sources/$name"),
        .testTarget(name: "${name}Tests", dependencies: ["$name"], path: "Tests/${name}Tests"),
    ]
)
EOF
    printf 'public func fixtureValue() -> Int { 1 }\n' \
        > "$ROOT/lib/$name/Sources/$name/Fixture.swift"
    printf '%s\n' "$body" > "$ROOT/lib/$name/Tests/${name}Tests/FixtureTests.swift"
}

PORTABLE_TEST='import Testing
@Test func portable() { #expect(1 == 1) }'

# `Process` is the exact symbol that does not exist on iOS, so this fixture fails for the
# same reason a real host-bound target would.
HOST_BOUND_TEST='import Foundation
import Testing
@Test func hostBound() { _ = Process() }'

# The fixture root mimics the repository's shape: a scripts/ directory beside lib/,
# because the gate resolves the root from its own path when the seam is unset.
# DanTermSupport is always present and unpinned, because the gate checks it in every mode.
new_root() {
    mkdir -p "$ROOT/scripts" "$ROOT/lib/DanTermSupport"
    cat > "$ROOT/lib/DanTermSupport/Package.swift" <<'EOF'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(name: "DanTermSupport", platforms: [.macOS(.v26)])
EOF
}

track_fixture() {
    [[ -d "$ROOT/.git" ]] || git init -q "$ROOT"
    git -C "$ROOT" add -A
}

run_gate() {
    track_fixture
    IOS_PORTABILITY_GATE_ROOT="$ROOT" bash "$GATE" >"$OUT" 2>&1
}

# `--package` names a path directly, so it makes no discovery claim and needs no index.
run_gate_untracked() {
    IOS_PORTABILITY_GATE_ROOT="$ROOT" bash "$GATE" "$@" >"$OUT" 2>&1
}

case_sweep() {
    write_package Portable '.macOS(.v26), .iOS(.v26)' "$PORTABLE_TEST"
    write_package IOSPortable '.macOS(.v26), .iOS(.v26)' "$PORTABLE_TEST"
    mkdir -p "$ROOT/ios"
    mv "$ROOT/lib/IOSPortable" "$ROOT/ios/IOSPortable"
    # An unpinned package may hold host-bound code, so the sweep must leave it alone.
    write_package Unpinned '.macOS(.v26)' "$HOST_BOUND_TEST"
    run_gate || { cat "$OUT" >&2; fail "a pinned package whose targets all build for iOS should pass"; }
    grep -q 'building lib/Portable' "$OUT" || fail "the gate should report which packages it built"
    grep -q 'building ios/IOSPortable' "$OUT" \
        || fail "the gate should discover pinned packages under ios/"
    if grep -q 'building lib/Unpinned' "$OUT"; then
        fail "the gate built a package that declares no iOS platform"
    fi
}

case_package_one() {
    write_package Portable '.macOS(.v26), .iOS(.v26)' "$PORTABLE_TEST"
    write_package Other '.macOS(.v26), .iOS(.v26)' "$PORTABLE_TEST"
    run_gate_untracked --package lib/Portable \
        || { cat "$OUT" >&2; fail "--package should build a portable pinned package"; }
    grep -q 'building lib/Portable' "$OUT" || fail "--package did not build the named package"
    if grep -q 'building lib/Other' "$OUT"; then
        fail "--package built a package other than the one named"
    fi
}

# The explicit hatch stays independent of discovery, for a package discovery excludes by
# location and for one it excludes because git does not track it.
case_package_hatch() {
    write_package DocsOnly '.macOS(.v26), .iOS(.v26)' "$PORTABLE_TEST"
    mkdir -p "$ROOT/docs"
    mv "$ROOT/lib/DocsOnly" "$ROOT/docs/DocsOnly"
    write_package Untracked '.macOS(.v26), .iOS(.v26)' "$PORTABLE_TEST"
    run_gate_untracked --package docs/DocsOnly \
        || { cat "$OUT" >&2; fail "--package should build an excluded package named by hand"; }
    run_gate_untracked --package lib/Untracked \
        || { cat "$OUT" >&2; fail "--package should build an untracked package named by hand"; }
}

case_sweep_host_bound() {
    write_package Pinned '.macOS(.v26), .iOS(.v26)' "$HOST_BOUND_TEST"
    if run_gate; then fail "a pinned package with a host-bound test target must fail the gate"; fi
    grep -q 'Do not add an exemption' "$OUT" \
        || fail "the failure should say why an allowlist is not the fix: $(cat "$OUT")"
}

# The case the fan-out rests on: a per-package step is not a weaker check.
case_package_host_bound() {
    write_package Pinned '.macOS(.v26), .iOS(.v26)' "$HOST_BOUND_TEST"
    if run_gate_untracked --package lib/Pinned; then
        fail "--package passed a pinned package with a host-bound test target"
    fi
    grep -q 'Do not add an exemption' "$OUT" \
        || fail "the --package failure should also say why an allowlist is not the fix: $(cat "$OUT")"
}

if [[ "${1:-}" == "--case" ]]; then
    CASE_NAME="${2:?--case needs a case name}"
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    ROOT="$TMP/root"
    OUT="$TMP/out"
    new_root
    case "$CASE_NAME" in
        sweep) case_sweep ;;
        package-one) case_package_one ;;
        package-hatch) case_package_hatch ;;
        sweep-host-bound) case_sweep_host_bound ;;
        package-host-bound) case_package_host_bound ;;
        *) fail "unknown case" ;;
    esac
    exit 0
fi

# The cases are independent, so they run together. Each one is dominated by SwiftPM and
# xcrun startup rather than by compiling, which is why running them in series cost more
# than the fixtures they build. Width follows the CPU tokens this step holds, and each
# case is told to compile at one job, so the whole file asks the machine for exactly the
# tokens the gate gave it. Outside the gate pool nothing sets that, so pick a small width.
width="${DANTERM_SWIFT_JOBS:-4}"
export DANTERM_SWIFT_JOBS=1
printf '%s\n' "${CASES[@]}" | xargs -P "$width" -I {} "$0" --case {}

echo "ios portability gate self-test passed"
