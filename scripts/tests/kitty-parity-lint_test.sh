#!/usr/bin/env bash
# Self-test for the adapted-kitty citation lint. Every case builds a fixture tree
# and asserts the exit status, so the lint is pinned in both directions -- a lint
# that rejected everything would satisfy the negative cases alone and then reject
# the first legitimate citation.
#
# The three cases the lint exists for are the corrupted hash (I3), the renamed
# upstream test (I1), and the absent `references/kitty` (skip with exit 0). The
# last one is the only failure mode that can break the gate rather than a commit:
# `references/` is gitignored, so a fresh clone and CI have no checkout at all.
#
# The baseline's expected hash is computed here from the fixture text directly,
# not by asking the lint -- a self-test that took the lint's own answer as the
# expectation would pass no matter what the extraction did.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../kitty-parity-lint.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
passes() { "$LINT" "$1" >/dev/null 2>&1; }
expect_pass() { passes "$1" || fail "$2"; }
expect_fail() { ! passes "$1" || fail "$2"; }

# Rewrite one file of a fixture in place (BSD and GNU sed disagree on -i).
edit_file() {
    local target="$1" script="$2"
    sed -E "$script" "$target" > "$target.new" && mv "$target.new" "$target"
}

PIN="2cb1d95c3accadd536bd66ba6bda044973440177"
SWIFT_REL="lib/TerminalCore/Tests/TerminalCoreTests/Fixture.swift"
UPSTREAM_REL="references/kitty/kitty_tests/datatypes.py"

# --- The baseline valid tree. ---
BASE="$TMP/valid"
mkdir -p "$BASE/scripts" "$BASE/references/kitty/kitty_tests" "$BASE/$(dirname "$SWIFT_REL")"

cat > "$BASE/scripts/fetch-references.py" <<EOF
REFERENCES = [
    Reference(
        name="kitty",
        url="https://github.com/kovidgoyal/kitty.git",
        pin="$PIN",
    ),
]
EOF

# The tracked test's body runs from its "def" line to the next "def" at the same
# indentation, so the blank line before that terminator belongs to it. test_other
# exists to put the terminator in the fixture rather than relying on end-of-file.
cat > "$BASE/$UPSTREAM_REL" <<'EOF'
class Rewrap(BaseTest):

    def test_rewrap_narrower(self):
        lb = create_lbuf('123', 'abcde')
        self.assertEqual(lb.is_continued, (False, True))

    def test_other(self):
        pass
EOF

# Same slice, byte for byte, built without the lint's help.
BODY_HASH="$(printf '%s\n' \
"    def test_rewrap_narrower(self):
        lb = create_lbuf('123', 'abcde')
        self.assertEqual(lb.is_continued, (False, True))" | shasum -a 256 | cut -c1-12)"

cat > "$BASE/$SWIFT_REL" <<EOF
struct Fixture {
    func narrowSplitsOnlyTheOverflowingRow() throws {
        // Adapted from kitty_tests/datatypes.py#test_rewrap_narrower
        //   (kitty v0.48.2 ${PIN:0:7}, body sha256:$BODY_HASH).
        //   Divergence: kitty asserts is_continued; we assert isSoftWrapped.
        resize()
    }
}
EOF

expect_pass "$BASE" "the baseline tree (resolvable citation, current pin, matching hash) should pass"

# --- I1: the citation must resolve to a real def in the pinned checkout. ---
CASE="$TMP/i1-renamed-upstream"
cp -R "$BASE" "$CASE"
edit_file "$CASE/$UPSTREAM_REL" 's/def test_rewrap_narrower/def test_rewrap_to_narrower/'
expect_fail "$CASE" "a citation whose upstream test was renamed should fail"

# A near-miss citation line must be an error, not a silent skip: an unparsed
# citation leaves the gate passing while it checks nothing, which is strictly
# worse than having written no citation at all.
CASE="$TMP/i1-malformed-line"
cp -R "$BASE" "$CASE"
edit_file "$CASE/$SWIFT_REL" 's|#test_rewrap_narrower$|#test_rewrap_narrower.|'
expect_fail "$CASE" "a citation line that does not parse should fail rather than be skipped"

CASE="$TMP/i1-missing-file"
cp -R "$BASE" "$CASE"
rm "$CASE/$UPSTREAM_REL"
expect_fail "$CASE" "a citation naming a file absent from the checkout should fail"

# --- I2: the cited commit must be the current pin. A pin bump invalidates every
# recorded hash, so a stale commit is an error even when the hash still matches. ---
CASE="$TMP/i2-stale-commit"
cp -R "$BASE" "$CASE"
edit_file "$CASE/$SWIFT_REL" 's/kitty v0\.48\.2 [0-9a-f]+/kitty v0.48.2 0000000/'
expect_fail "$CASE" "a citation naming a commit other than the pin should fail"

# --- I3: the recorded hash must match the upstream body. ---
CASE="$TMP/i3-corrupt-hash"
cp -R "$BASE" "$CASE"
edit_file "$CASE/$SWIFT_REL" 's/body sha256:[0-9a-f]+/body sha256:deadbeefdead/'
expect_fail "$CASE" "a citation whose recorded hash does not match upstream should fail"

CASE="$TMP/i3-revised-upstream"
cp -R "$BASE" "$CASE"
edit_file "$CASE/$UPSTREAM_REL" "s/\(False, True\)/(True, False)/"
expect_fail "$CASE" "an upstream test revised under an unchanged name should fail"

# A revision *outside* the cited body must not fire: hash churn on every unrelated
# edit to the file would train the reader to re-record without reading.
CASE="$TMP/i3-unrelated-edit"
cp -R "$BASE" "$CASE"
edit_file "$CASE/$UPSTREAM_REL" 's/        pass/        return None/'
expect_pass "$CASE" "an edit to a different test in the same file should not fire I3"

# --- I4: every citation states what we assert instead. ---
CASE="$TMP/i4-no-divergence"
cp -R "$BASE" "$CASE"
edit_file "$CASE/$SWIFT_REL" '/Divergence:/d'
expect_fail "$CASE" "a citation with no Divergence line should fail"

CASE="$TMP/i4-explicit-none"
cp -R "$BASE" "$CASE"
edit_file "$CASE/$SWIFT_REL" 's|Divergence: kitty asserts.*|Divergence: none.|'
expect_pass "$CASE" "an explicit \`Divergence: none\` should satisfy I4"

# --- A citation with no provenance line at all is caught, not silently skipped. ---
CASE="$TMP/no-provenance"
cp -R "$BASE" "$CASE"
edit_file "$CASE/$SWIFT_REL" '/body sha256:/d'
expect_fail "$CASE" "a citation with no provenance line should fail"

# --- The gate case: no checkout means exit 0 with a printed reason. ---
CASE="$TMP/references-absent"
cp -R "$BASE" "$CASE"
rm -rf "$CASE/references"
out="$("$LINT" "$CASE" 2>&1)" || fail "a tree with no references/kitty should exit 0"
grep -q "skipped" <<<"$out" || fail "the references-absent skip should print its reason; got: $out"

echo "kitty-parity lint self-test passed"
