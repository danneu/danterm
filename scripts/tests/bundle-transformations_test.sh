#!/usr/bin/env bash
# Behavioral tests for the two bundle transformations: signing and ZIP round-trip.
#
# Both wrappers exist so a transformation cannot be performed without re-verifying
# the transformed bundle. These tests execute them against real Mach-O fixtures --
# scripts cannot carry an embedded signature through a ZIP -- rather than reading
# the workflow text that calls them.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    echo "bundle-transformations_test: $*" >&2
    exit 1
}

# shellcheck source=../lib/bundle-layout-tool.sh
source "$ROOT_DIR/scripts/lib/bundle-layout-tool.sh"
bundle_layout_tool_init "$ROOT_DIR" "$TEST_ROOT/layout-tool-build"
bundle_layout_tool release > "$TEST_ROOT/release.json"

# Distinct exit codes give each product distinct bytes, which the layout verifier
# requires of the GUI and CLI pair.
mkdir -p "$TEST_ROOT/products"
status=0
for product in DanTerm DanTermCLI PTYSessionBootstrap; do
    printf 'int main(void) { return %d; }\n' "$status" \
        | cc -x c -o "$TEST_ROOT/products/$product" -
    status=$((status + 1))
done

assemble() {
    "$ROOT_DIR/scripts/assemble-app-bundle.sh" \
        "$1" "$TEST_ROOT/release.json" "$ROOT_DIR" \
        --version 0.0.0-test \
        --product "DanTerm=$TEST_ROOT/products/DanTerm" \
        --product "DanTermCLI=$TEST_ROOT/products/DanTermCLI" \
        --product "PTYSessionBootstrap=$TEST_ROOT/products/PTYSessionBootstrap"
}

sign() {
    "$ROOT_DIR/scripts/sign-app-bundle.sh" \
        "$1" "$TEST_ROOT/release.json" "$ROOT_DIR" -
}

unpack() {
    "$ROOT_DIR/scripts/unpack-app-zip.sh" \
        "$1" "$2" "$TEST_ROOT/release.json" "$ROOT_DIR"
}

# Intent: signing produces a bundle that passes deep signature checks, and every
#   nested helper carries its own signature rather than only the container's.
# Why it exists: a container signed before its nested code seals a signature that
#   the later nested signing invalidates, which Gatekeeper rejects after download.
# Scenario: the release and CI workflows ad-hoc or Developer ID sign a bundle.
BUNDLE="$TEST_ROOT/DanTerm.app"
assemble "$BUNDLE"
sign "$BUNDLE" > "$TEST_ROOT/sign.out" 2> "$TEST_ROOT/sign.err" \
    || fail "signing a valid bundle failed: $(cat "$TEST_ROOT/sign.err")"
codesign --verify --deep --strict "$BUNDLE" \
    || fail "signed bundle does not pass deep strict verification"
codesign --display "$BUNDLE/Contents/Helpers/danterm" > /dev/null 2>&1 \
    || fail "nested CLI helper carries no signature of its own"
codesign --display "$BUNDLE/Contents/Helpers/PTYSessionBootstrap" > /dev/null 2>&1 \
    || fail "nested PTY bootstrap helper carries no signature of its own"

# Intent: signing re-verifies the layout, so a signer cannot report success on a
#   bundle that no longer matches its declaration.
# Why it exists: the producer's verification happens before signing, so only a
#   check inside the signing step can catch a bundle mutated in between.
# Scenario: an undeclared file is dropped into Contents/Helpers before signing.
STRAY_BUNDLE="$TEST_ROOT/Stray.app"
assemble "$STRAY_BUNDLE"
: > "$STRAY_BUNDLE/Contents/Helpers/undeclared"
if sign "$STRAY_BUNDLE" > "$TEST_ROOT/stray-sign.out" 2> "$TEST_ROOT/stray-sign.err"; then
    fail "signing accepted a bundle with an undeclared helper"
fi
grep -qF 'Contents/Helpers/undeclared' "$TEST_ROOT/stray-sign.err" \
    || fail "signing failure did not name the undeclared entry"

# Intent: unpacking a distributed ZIP re-verifies both the signature and the layout.
# Why it exists: ZIP transport is the last thing that touches a released bundle,
#   and a bundle that loses a file or a signature in transit still unzips cleanly.
# Scenario: the release workflow round-trips the ZIP it is about to publish.
( cd "$TEST_ROOT" && zip -qr "DanTerm.zip" "DanTerm.app" )
unpack "$TEST_ROOT/DanTerm.zip" "$TEST_ROOT/roundtrip" \
    > "$TEST_ROOT/unpack.out" 2> "$TEST_ROOT/unpack.err" \
    || fail "round-tripping a signed bundle failed: $(cat "$TEST_ROOT/unpack.err")"
[[ -d "$TEST_ROOT/roundtrip/DanTerm.app" ]] \
    || fail "round-trip did not leave the bundle in the destination"

( cd "$TEST_ROOT" && zip -qr "Stray.zip" "Stray.app" )
if unpack "$TEST_ROOT/Stray.zip" "$TEST_ROOT/stray-roundtrip" \
    > "$TEST_ROOT/stray-unpack.out" 2> "$TEST_ROOT/stray-unpack.err"; then
    fail "round-trip accepted a bundle with an undeclared helper"
fi
grep -qF 'Contents/Helpers/undeclared' "$TEST_ROOT/stray-unpack.err" \
    || fail "round-trip failure did not name the undeclared entry"

# Intent: the round-trip refuses an archive that does not hold exactly one bundle.
# Why it exists: the destination bundle is found rather than named, so an archive
#   with two apps -- or none -- must fail instead of verifying an arbitrary one.
# Scenario: a packaging change zips a staging directory instead of the app.
( cd "$TEST_ROOT" && zip -qr "Both.zip" "DanTerm.app" "Stray.app" )
if unpack "$TEST_ROOT/Both.zip" "$TEST_ROOT/both-roundtrip" \
    > "$TEST_ROOT/both.out" 2> "$TEST_ROOT/both.err"; then
    fail "round-trip accepted an archive holding two bundles"
fi
grep -qF 'exactly one app bundle' "$TEST_ROOT/both.err" \
    || fail "two-bundle failure did not name the ambiguity"

echo "bundle transformation tests passed"
