#!/usr/bin/env bash
# Self-test for the iOS portability gate. It builds a fixture tree of tiny packages
# instead of the engine, so the claims below are proved in seconds:
#
#   1. A pinned package whose every target compiles for iOS passes.
#   2. A pinned package with a host-bound TARGET fails -- the case that matters,
#      because SwiftPM would otherwise skip test targets and report success.
#   3. An unpinned package is not built at all, so it may stay host-bound.
#   4. An iOS pin on DanTermSupport fails, which is the check the design asks for.
#   5. A pinned package under ios/ is discovered and built.
#   6. `--list` reports the pinned set and compiles nothing.
#   7. `--package` builds the one package named and no other.
#   8. `--package` refuses a package that declares no iOS platform.
#   9. `--package` fails on a host-bound target, exactly as the sweep does.
#
# Claim 2 is the one a cheaper gate gets wrong: `Process()` in a pinned target has
# to fail on the commit that adds it, and only a real compile against the iOS SDK
# sees that. Claims 6 through 9 are what let the gate pool run one step per package
# without weakening any single package's check.
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

# 5. Product packages under ios/ are part of the same package-level claim.
write_package IOSPortable '.macOS(.v26), .iOS(.v26)' "$PORTABLE_TEST"
mkdir -p "$TMP/root/ios"
mv "$TMP/root/lib/IOSPortable" "$TMP/root/ios/IOSPortable"
run_gate || { cat "$TMP/out" >&2; fail "a portable ios/ package should pass"; }
grep -q 'building ios/IOSPortable' "$TMP/out" \
    || fail "the gate should discover pinned packages under ios/"

# 6. `--list` answers the discovery question on its own, without building anything.
# The gate pool asks for this list to make one step per pinned package, so it has to
# be the same discovery the build uses -- a second list would be a list that drifts.
run_gate_args() {
    IOS_PORTABILITY_GATE_ROOT="$TMP/root" bash "$GATE" "$@" >"$TMP/out" 2>&1
}

run_gate_args --list || { cat "$TMP/out" >&2; fail "--list should succeed on a portable tree"; }
if grep -q 'building ' "$TMP/out"; then fail "--list compiled something; it must only report"; fi
[[ "$(sort "$TMP/out")" == "$(printf 'ios/IOSPortable\nlib/Portable')" ]] \
    || fail "--list did not name exactly the pinned packages: $(cat "$TMP/out")"

# 7. `--package` builds the one package it is given, which is what a fanned-out gate
# step runs. Splitting the loop across steps must not weaken any single package's check.
run_gate_args --package lib/Portable \
    || { cat "$TMP/out" >&2; fail "--package should build a portable pinned package"; }
grep -q 'building lib/Portable' "$TMP/out" || fail "--package did not build the named package"
if grep -q 'building ios/IOSPortable' "$TMP/out"; then
    fail "--package built a package other than the one named"
fi

# 8. A package that is not pinned must be refused rather than built. Nothing should be
# able to ask for an iOS build of a package that never claimed iOS.
write_package NotPinned '.macOS(.v26)' "$PORTABLE_TEST"
if run_gate_args --package lib/NotPinned; then
    fail "--package accepted a package that declares no iOS platform"
fi
grep -q 'declares no iOS platform' "$TMP/out" \
    || fail "the refusal should say the package is not pinned: $(cat "$TMP/out")"
rm -rf "$TMP/root/lib/NotPinned"

# 3. Unpinned packages are not built, so host-bound code in one is fine.
write_package Unpinned '.macOS(.v26)' "$HOST_BOUND_TEST"
run_gate || { cat "$TMP/out" >&2; fail "an unpinned package must not be built for iOS"; }
if grep -q 'building lib/Unpinned' "$TMP/out"; then fail "the gate built a package that declares no iOS platform"; fi

# 2. A host-bound test target inside a pinned package fails the gate.
write_package Pinned '.macOS(.v26), .iOS(.v26)' "$HOST_BOUND_TEST"
if run_gate; then fail "a pinned package with a host-bound test target must fail the gate"; fi
grep -q 'Do not add an exemption' "$TMP/out" \
    || fail "the failure should say why an allowlist is not the fix"

# 9. The same host-bound target fails when the gate is asked for that package alone.
# This is the case the fan-out rests on: a per-package step is not a weaker check.
if run_gate_args --package lib/Pinned; then
    fail "--package passed a pinned package with a host-bound test target"
fi
grep -q 'Do not add an exemption' "$TMP/out" \
    || fail "the --package failure should also say why an allowlist is not the fix"
rm -rf "$TMP/root/lib/Pinned"

# 4. PO7: pinning DanTermSupport is a gate failure, not something left to inspection.
sed -i '' 's/\[\.macOS(\.v26)\]/[.macOS(.v26), .iOS(.v26)]/' "$TMP/root/lib/DanTermSupport/Package.swift"
if run_gate; then fail "an iOS pin on DanTermSupport must fail the gate"; fi
grep -q 'DanTermSupport carries Mac-host roles only' "$TMP/out" \
    || fail "the DanTermSupport failure should explain the role boundary"
if run_gate_args --list; then fail "--list must fail on an iOS pin on DanTermSupport"; fi

# A gate that finds nothing to build is a gate that proves nothing.
rm -rf "$TMP/root/lib/Portable" "$TMP/root/lib/Unpinned" "$TMP/root/ios/IOSPortable"
sed -i '' 's/, \.iOS(\.v26)//' "$TMP/root/lib/DanTermSupport/Package.swift"
if run_gate; then fail "the gate must fail when no package declares an iOS platform"; fi
grep -q 'checking nothing' "$TMP/out" || fail "an empty pinned set should say so"

# --list carries the whole-tree claims too, because the gate pool calls it before it
# calls anything else. If it reported an empty set quietly, the fanned-out gate would
# have no iOS steps at all and would look like it passed.
if run_gate_args --list; then fail "--list must fail when no package declares an iOS platform"; fi
grep -q 'checking nothing' "$TMP/out" || fail "--list should say an empty pinned set proves nothing"

echo "ios portability gate self-test passed"
