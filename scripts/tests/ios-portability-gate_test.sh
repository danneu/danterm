#!/usr/bin/env bash
# Self-test for the iOS portability gate. It builds a fixture tree of tiny packages
# instead of the engine, so the four claims below are proved in seconds:
#
#   1. A pinned package whose every target compiles for iOS passes.
#   2. A pinned package with a host-bound TARGET fails -- the case that matters,
#      because SwiftPM would otherwise skip test targets and report success.
#   3. An unpinned package is not built at all, so it may stay host-bound.
#   4. An iOS pin on DanTermSupport fails, which is the check PO7 asks for.
#
# Claim 2 is the one a cheaper gate gets wrong: `Process()` in a pinned target has
# to fail on the commit that adds it, and only a real compile against the iOS SDK
# sees that.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$SCRIPT_DIR/../ios-portability-gate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# The fixture root mimics the repository's shape: a scripts/ directory beside lib/,
# because the gate resolves the root from its own path when the seam is unset.
mkdir -p "$TMP/root/scripts" "$TMP/root/lib/DanTermSupport"

# Fixture packages. `platforms:` is what the gate reads, so the pin is the only
# difference between Portable and Unpinned.
write_package() { # name platforms sourceBody
    local name="$1" platforms="$2" body="$3"
    mkdir -p "$TMP/root/lib/$name/Sources/$name" "$TMP/root/lib/$name/Tests/${name}Tests"
    cat > "$TMP/root/lib/$name/Package.swift" <<EOF
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
        > "$TMP/root/lib/$name/Sources/$name/Fixture.swift"
    printf '%s\n' "$body" > "$TMP/root/lib/$name/Tests/${name}Tests/FixtureTests.swift"
}

PORTABLE_TEST='import Testing
@Test func portable() { #expect(1 == 1) }'

# `Process` is the exact symbol that does not exist on iOS, so this fixture fails
# for the same reason a real host-bound target would.
HOST_BOUND_TEST='import Foundation
import Testing
@Test func hostBound() { _ = Process() }'

cat > "$TMP/root/lib/DanTermSupport/Package.swift" <<'EOF'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(name: "DanTermSupport", platforms: [.macOS(.v26)])
EOF

run_gate() { IOS_PORTABILITY_GATE_ROOT="$TMP/root" bash "$GATE" >"$TMP/out" 2>&1; }

# 1. Pinned and portable, test target included.
write_package Portable '.macOS(.v26), .iOS(.v26)' "$PORTABLE_TEST"
run_gate || { cat "$TMP/out" >&2; fail "a pinned package whose targets all build for iOS should pass"; }
grep -q 'building lib/Portable' "$TMP/out" || fail "the gate should report which packages it built"

# 3. Unpinned packages are not built, so host-bound code in one is fine.
write_package Unpinned '.macOS(.v26)' "$HOST_BOUND_TEST"
run_gate || { cat "$TMP/out" >&2; fail "an unpinned package must not be built for iOS"; }
if grep -q 'building lib/Unpinned' "$TMP/out"; then fail "the gate built a package that declares no iOS platform"; fi

# 2. A host-bound test target inside a pinned package fails the gate.
write_package Pinned '.macOS(.v26), .iOS(.v26)' "$HOST_BOUND_TEST"
if run_gate; then fail "a pinned package with a host-bound test target must fail the gate"; fi
grep -q 'Do not add an exemption' "$TMP/out" \
    || fail "the failure should say why an allowlist is not the fix"
rm -rf "$TMP/root/lib/Pinned"

# 4. PO7: pinning DanTermSupport is a gate failure, not something left to inspection.
sed -i '' 's/\[\.macOS(\.v26)\]/[.macOS(.v26), .iOS(.v26)]/' "$TMP/root/lib/DanTermSupport/Package.swift"
if run_gate; then fail "an iOS pin on DanTermSupport must fail the gate"; fi
grep -q 'DanTermSupport carries Mac-host roles only' "$TMP/out" \
    || fail "the DanTermSupport failure should explain the role boundary"

# A gate that finds nothing to build is a gate that proves nothing.
rm -rf "$TMP/root/lib/Portable" "$TMP/root/lib/Unpinned"
sed -i '' 's/, \.iOS(\.v26)//' "$TMP/root/lib/DanTermSupport/Package.swift"
if run_gate; then fail "the gate must fail when no package declares an iOS platform"; fi
grep -q 'checking nothing' "$TMP/out" || fail "an empty pinned set should say so"

echo "ios portability gate self-test passed"
