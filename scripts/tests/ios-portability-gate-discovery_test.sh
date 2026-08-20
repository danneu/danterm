#!/usr/bin/env bash
# Self-test for the half of the iOS portability gate that answers from manifests alone:
# which packages are pinned, and which requests the gate refuses before it compiles.
#
#   1. `--list` reports exactly the pinned set and compiles nothing.
#   2. Discovery follows tracked first-party manifests, so a pinned package anywhere in
#      the tree gets listed and an excluded or untracked one does not.
#   3. `--package` refuses a package that declares no iOS platform.
#   4. An iOS pin on DanTermSupport fails both the sweep and `--list`.
#   5. An empty pinned set fails both the sweep and `--list`, because a gate that finds
#      nothing to build is a gate that proves nothing.
#   6. Discovery that finds no first-party manifest fails and names that invariant.
#
# None of these need an iOS SDK: the gate resolves `xcrun --sdk iphoneos` only after it
# has answered the question above, and every refusal here happens before that point. The
# stub PATH below proves it rather than asserting it -- `xcrun` and `swift` are replaced
# by commands that fail loudly, so a case that compiles anything fails here.
#
# The compiling half lives in scripts/tests/ios-portability-gate_test.sh. The two share
# no fixture directory: each builds its own tree under its own mktemp root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$SCRIPT_DIR/../ios-portability-gate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# The proof that this step needs no SDK. Anything that reaches a compiler reaches these
# instead, and they say so on stderr, which the failing case then prints.
mkdir -p "$TMP/no-toolchain"
for tool in xcrun swift swiftc; do
    cat > "$TMP/no-toolchain/$tool" <<EOF
#!/usr/bin/env bash
echo "ios-portability-gate-discovery_test: this step must never run $tool: \$*" >&2
exit 90
EOF
    chmod +x "$TMP/no-toolchain/$tool"
done
export PATH="$TMP/no-toolchain:$PATH"

# The fixture root mimics the repository's shape: a scripts/ directory beside lib/,
# because the gate resolves the root from its own path when the seam is unset.
mkdir -p "$TMP/root/scripts" "$TMP/root/lib/DanTermSupport"

# `platforms:` is what the gate reads, so the pin is the only difference between a
# package that is checked and one that is not.
write_package() { # name platforms
    local name="$1" platforms="$2"
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
    printf 'import Testing\n@Test func portable() { #expect(1 == 1) }\n' \
        > "$TMP/root/lib/$name/Tests/${name}Tests/FixtureTests.swift"
}

cat > "$TMP/root/lib/DanTermSupport/Package.swift" <<'EOF'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(name: "DanTermSupport", platforms: [.macOS(.v26)])
EOF

track_fixture() {
    [[ -d "$TMP/root/.git" ]] || git init -q "$TMP/root"
    git -C "$TMP/root" add -A
}

run_gate() {
    track_fixture
    IOS_PORTABILITY_GATE_ROOT="$TMP/root" bash "$GATE" "$@" >"$TMP/out" 2>&1
}

run_gate_untracked() {
    IOS_PORTABILITY_GATE_ROOT="$TMP/root" bash "$GATE" "$@" >"$TMP/out" 2>&1
}

# 1. `--list` answers the discovery question on its own, without building anything.
# The gate pool asks for this list to make one step per pinned package, so it has to be
# the same discovery the build uses -- a second list would be a list that drifts.
write_package Portable '.macOS(.v26), .iOS(.v26)'
write_package IOSPortable '.macOS(.v26), .iOS(.v26)'
mkdir -p "$TMP/root/ios"
mv "$TMP/root/lib/IOSPortable" "$TMP/root/ios/IOSPortable"
run_gate --list || { cat "$TMP/out" >&2; fail "--list should succeed on a portable tree"; }
if grep -q 'building ' "$TMP/out"; then fail "--list compiled something; it must only report"; fi
[[ "$(sort "$TMP/out")" == "$(printf 'ios/IOSPortable\nlib/Portable')" ]] \
    || fail "--list did not name exactly the pinned packages: $(cat "$TMP/out")"

# 2. A tracked package outside lib/ and ios/ is part of the same discovery.
write_package Tool '.macOS(.v26), .iOS(.v26)'
mkdir -p "$TMP/root/tools"
mv "$TMP/root/lib/Tool" "$TMP/root/tools/Tool"
run_gate --list || { cat "$TMP/out" >&2; fail "--list should discover tools/ packages"; }
grep -q '^tools/Tool$' "$TMP/out" || fail "--list missed a tracked package outside the old roots"

# A tracked docs package and an untracked ordinary package stay out of enumeration.
write_package DocsOnly '.macOS(.v26), .iOS(.v26)'
mkdir -p "$TMP/root/docs"
mv "$TMP/root/lib/DocsOnly" "$TMP/root/docs/DocsOnly"
run_gate --list || { cat "$TMP/out" >&2; fail "--list should ignore docs packages"; }
write_package Untracked '.macOS(.v26), .iOS(.v26)'
run_gate_untracked --list || { cat "$TMP/out" >&2; fail "--list should ignore untracked packages"; }
if grep -qE 'DocsOnly|Untracked' "$TMP/out"; then
    fail "--list enumerated an excluded or untracked package: $(cat "$TMP/out")"
fi
rm -rf "$TMP/root/docs/DocsOnly" "$TMP/root/lib/Untracked"

# 3. A package that is not pinned must be refused rather than built. Nothing should be
# able to ask for an iOS build of a package that never claimed iOS.
write_package NotPinned '.macOS(.v26)'
if run_gate --package lib/NotPinned; then
    fail "--package accepted a package that declares no iOS platform"
fi
grep -q 'declares no iOS platform' "$TMP/out" \
    || fail "the refusal should say the package is not pinned: $(cat "$TMP/out")"
rm -rf "$TMP/root/lib/NotPinned"

# 4. PO7: pinning DanTermSupport is a gate failure, not something left to inspection.
sed -i '' 's/\[\.macOS(\.v26)\]/[.macOS(.v26), .iOS(.v26)]/' "$TMP/root/lib/DanTermSupport/Package.swift"
if run_gate; then fail "an iOS pin on DanTermSupport must fail the gate"; fi
grep -q 'DanTermSupport carries Mac-host roles only' "$TMP/out" \
    || fail "the DanTermSupport failure should explain the role boundary: $(cat "$TMP/out")"
if run_gate --list; then fail "--list must fail on an iOS pin on DanTermSupport"; fi
grep -q 'DanTermSupport carries Mac-host roles only' "$TMP/out" \
    || fail "the --list failure should also explain the role boundary: $(cat "$TMP/out")"

# 5. A gate that finds nothing to build is a gate that proves nothing. `--list` carries
# this claim too, because the gate pool calls it before it calls anything else: an empty
# set reported quietly would give the fanned-out gate no iOS steps at all, and the gate
# would look like it passed.
rm -rf "$TMP/root/lib/Portable" "$TMP/root/ios/IOSPortable" "$TMP/root/tools/Tool"
sed -i '' 's/, \.iOS(\.v26)//' "$TMP/root/lib/DanTermSupport/Package.swift"
if run_gate; then fail "the gate must fail when no package declares an iOS platform"; fi
grep -q 'checking nothing' "$TMP/out" || fail "an empty pinned set should say so"
if run_gate --list; then fail "--list must fail when no package declares an iOS platform"; fi
grep -q 'checking nothing' "$TMP/out" || fail "--list should say an empty pinned set proves nothing"

# 6. Discovery itself must also reject a repository with no first-party manifest.
mkdir -p "$TMP/root/docs"
mv "$TMP/root/lib/DanTermSupport" "$TMP/root/docs/DanTermSupport"
if run_gate --list; then fail "--list must fail when discovery finds no first-party manifest"; fi
grep -q 'no first-party manifest found by tracked-file discovery' "$TMP/out" \
    || fail "an empty discovery should identify the failed invariant: $(cat "$TMP/out")"

echo "ios portability gate discovery self-test passed"
