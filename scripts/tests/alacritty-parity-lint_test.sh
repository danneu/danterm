#!/usr/bin/env bash
# Self-test for the Alacritty inline-test ledger and citation lint. Every case builds a
# fixture tree and asserts the exit status, so the lint is pinned in both directions -- a
# lint that rejected everything would satisfy the negative cases alone and then reject the
# first legitimate citation.
#
# The cases the lint exists for are the incomplete ledger (L1), the stale hash or renamed
# upstream test (I3, I1), and the absent `references/alacritty` (skip with exit 0). That
# last one is the only failure mode that can break the gate rather than a commit:
# `references/` is gitignored, so a fresh clone and CI have no checkout at all.
#
# The baseline's expected hash is computed here from the fixture text directly, not by
# asking the lint -- a self-test that took the lint's own answer as its expectation would
# pass no matter what the extraction did.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../alacritty-parity-lint.py"
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

PIN="852e971cddfabe222d2d5bcda466e130f53af207"
SWIFT_REL="lib/TerminalCore/Tests/TerminalCoreTests/Fixture.swift"
UPSTREAM_REL="references/alacritty/alacritty_terminal/src/term/search.rs"
MANIFEST_REL="lib/TerminalCore/Tests/TerminalCoreTests/Fixtures/alacritty-inline-manifest.json"

# --- The baseline valid tree. ---
BASE="$TMP/valid"
mkdir -p "$BASE/scripts" "$BASE/$(dirname "$UPSTREAM_REL")" \
         "$BASE/$(dirname "$SWIFT_REL")" "$BASE/$(dirname "$MANIFEST_REL")"

cat > "$BASE/scripts/fetch-references.py" <<EOF
REFERENCES = [
    Reference(
        name="alacritty",
        url="https://github.com/alacritty/alacritty.git",
        pin="$PIN",
    ),
]
EOF

# Three `#[test]` functions, exercising the inventory scanner's real obligations: an extra
# attribute between `#[test]` and `fn`, and a brace inside a char literal that must not be
# counted toward the body's balance.
cat > "$BASE/$UPSTREAM_REL" <<'EOF'
#[cfg(test)]
mod tests {
    #[test]
    fn ported() {
        let term = mock_term("x");
        let brace = '{';
        assert_eq!(term.search("x"), Some(brace));
    }

    #[test]
    #[cfg(not(windows))]
    fn attributed() {
        assert!(true);
    }

    #[test]
    fn untouched() {
        assert!(true);
    }
}
EOF

# The same slice, byte for byte, built without the lint's help: the `fn` line through its
# balanced closing brace.
# No trailing newline: the body ends at its closing brace.
BODY_HASH="$(printf '%s' \
"    fn ported() {
        let term = mock_term(\"x\");
        let brace = '{';
        assert_eq!(term.search(\"x\"), Some(brace));
    }" | shasum -a 256 | cut -c1-12)"

cat > "$BASE/$SWIFT_REL" <<EOF
struct Fixture {
    func wideMatchCoversBothColumns() throws {
        // Adapted from alacritty_terminal/src/term/search.rs#ported
        //   (alacritty ${PIN:0:8}, body sha256:$BODY_HASH).
        //   Divergence: upstream asserts an inclusive range; we assert a half-open one.
        search()
    }
}
EOF

write_manifest() {
    cat > "$1/$MANIFEST_REL" <<EOF
{
  "source": "alacritty",
  "pin": "$PIN",
  "tests": [
    {
      "test": "alacritty_terminal/src/term/search.rs#ported",
      "disposition": "adapted",
      "rationale": "Pins the wide match range.",
      "destination": "$SWIFT_REL"
    },
    {
      "test": "alacritty_terminal/src/term/search.rs#attributed",
      "disposition": "superseded",
      "rationale": "Already covered by DanTerm's own suite."
    },
    {
      "test": "alacritty_terminal/src/term/search.rs#untouched",
      "disposition": "implementation-coupled",
      "rationale": "Specifies Alacritty's internal representation."
    }
  ]
}
EOF
}
write_manifest "$BASE"

expect_pass "$BASE" "the baseline tree (complete ledger, resolvable citation, matching hash) should pass"

# --- L1: the ledger must list exactly the pinned inventory, in both directions. ---
# A test upstream has but the ledger does not is the failure this whole file exists for:
# it is the one a group rationale ("all storage cases are internal") hides.
CASE="$TMP/l1-missing-entry"
cp -R "$BASE" "$CASE"
edit_file "$CASE/$MANIFEST_REL" '/"alacritty_terminal\/src\/term\/search.rs#untouched"/,+2d'
expect_fail "$CASE" "a pinned test with no ledger entry should fail"

# An entry for a test upstream no longer has is equally wrong: it is a disposition that
# nothing supports, and it would mask the fact that upstream deleted the scenario.
CASE="$TMP/l1-stale-entry"
cp -R "$BASE" "$CASE"
edit_file "$CASE/$UPSTREAM_REL" 's/fn untouched/fn renamed_upstream/'
expect_fail "$CASE" "a ledger entry the pinned checkout no longer has should fail"

CASE="$TMP/l1-duplicate-entry"
cp -R "$BASE" "$CASE"
edit_file "$CASE/$MANIFEST_REL" 's/#attributed/#untouched/'
expect_fail "$CASE" "a name listed twice in the ledger should fail"

# The scanner must find a test whose `#[test]` is separated from its `fn` by another
# attribute. If it silently skipped those, the inventory would shrink and L1 would pass
# against a ledger missing exactly those names.
CASE="$TMP/l1-attribute-between"
cp -R "$BASE" "$CASE"
edit_file "$CASE/$MANIFEST_REL" '/"alacritty_terminal\/src\/term\/search.rs#attributed"/,+2d'
expect_fail "$CASE" "a cfg-attributed test must still be inventoried and required in the ledger"

# --- L2: the ledger must be pinned and use the declared vocabulary. ---
CASE="$TMP/l2-stale-pin"
cp -R "$BASE" "$CASE"
edit_file "$CASE/$MANIFEST_REL" "s/\"pin\": \"$PIN\"/\"pin\": \"0000000000000000000000000000000000000000\"/"
expect_fail "$CASE" "a ledger recording a pin other than the current one should fail"

CASE="$TMP/l2-unknown-disposition"
cp -R "$BASE" "$CASE"
edit_file "$CASE/$MANIFEST_REL" 's/"disposition": "superseded"/"disposition": "probably fine"/'
expect_fail "$CASE" "a disposition outside the declared vocabulary should fail"

CASE="$TMP/l2-empty-rationale"
cp -R "$BASE" "$CASE"
edit_file "$CASE/$MANIFEST_REL" 's/"rationale": "Already covered by DanTerm.s own suite."/"rationale": "  "/'
expect_fail "$CASE" "an entry with a blank rationale should fail"

# --- L3: the ledger and the citations must agree about what was ported. ---
CASE="$TMP/l3-adapted-without-citation"
cp -R "$BASE" "$CASE"
edit_file "$CASE/$MANIFEST_REL" 's/"disposition": "implementation-coupled"/"disposition": "adapted"/'
expect_fail "$CASE" "an \`adapted\` entry that no Swift test cites should fail"

CASE="$TMP/l3-citation-without-adapted"
cp -R "$BASE" "$CASE"
edit_file "$CASE/$MANIFEST_REL" 's/"disposition": "adapted"/"disposition": "superseded"/'
expect_fail "$CASE" "a cited test not marked \`adapted\` in the ledger should fail"

CASE="$TMP/l3-missing-destination"
cp -R "$BASE" "$CASE"
rm "$CASE/$SWIFT_REL"
expect_fail "$CASE" "an \`adapted\` entry whose destination file is gone should fail"

# --- I1: the citation must resolve to a real fn in the pinned checkout. ---
CASE="$TMP/i1-renamed-upstream"
cp -R "$BASE" "$CASE"
edit_file "$CASE/$UPSTREAM_REL" 's/fn ported/fn ported_elsewhere/'
expect_fail "$CASE" "a citation whose upstream test was renamed should fail"

# A near-miss citation line must be an error, not a silent skip: an unparsed citation
# leaves the gate passing while it checks nothing, which is strictly worse than having
# written no citation at all.
CASE="$TMP/i1-malformed-line"
cp -R "$BASE" "$CASE"
edit_file "$CASE/$SWIFT_REL" 's|#ported$|#ported.|'
expect_fail "$CASE" "a citation line that does not parse should fail rather than be skipped"

# --- I2: the cited commit must be the current pin. A pin bump invalidates every recorded
# hash, so a stale commit is an error even when the hash still matches. ---
CASE="$TMP/i2-stale-commit"
cp -R "$BASE" "$CASE"
edit_file "$CASE/$SWIFT_REL" 's/alacritty [0-9a-f]{8}/alacritty 00000000/'
expect_fail "$CASE" "a citation naming a commit other than the pin should fail"

# --- I3: the recorded hash must match the upstream body. ---
CASE="$TMP/i3-corrupt-hash"
cp -R "$BASE" "$CASE"
edit_file "$CASE/$SWIFT_REL" 's/body sha256:[0-9a-f]+/body sha256:deadbeefdead/'
expect_fail "$CASE" "a citation whose recorded hash does not match upstream should fail"

CASE="$TMP/i3-revised-upstream"
cp -R "$BASE" "$CASE"
edit_file "$CASE/$UPSTREAM_REL" 's/mock_term\("x"\)/mock_term("y")/'
expect_fail "$CASE" "an upstream test revised under an unchanged name should fail"

# A revision *outside* the cited body must not fire: hash churn on every unrelated edit to
# the file would train the reader to re-record without reading.
CASE="$TMP/i3-unrelated-edit"
cp -R "$BASE" "$CASE"
edit_file "$CASE/$UPSTREAM_REL" 's/fn untouched\(\) \{/fn untouched() { \/\/ note/'
expect_pass "$CASE" "an edit to a different test in the same file should not fire I3"

# --- I4: every citation states what we assert instead. ---
CASE="$TMP/i4-no-divergence"
cp -R "$BASE" "$CASE"
edit_file "$CASE/$SWIFT_REL" '/Divergence:/d'
expect_fail "$CASE" "a citation with no Divergence line should fail"

CASE="$TMP/i4-explicit-none"
cp -R "$BASE" "$CASE"
edit_file "$CASE/$SWIFT_REL" 's|Divergence: upstream asserts.*|Divergence: none.|'
expect_pass "$CASE" "an explicit \`Divergence: none\` should satisfy I4"

# --- A citation with no provenance line at all is caught, not silently skipped. ---
CASE="$TMP/no-provenance"
cp -R "$BASE" "$CASE"
edit_file "$CASE/$SWIFT_REL" '/body sha256:/d'
expect_fail "$CASE" "a citation with no provenance line should fail"

# --- Nested agent worktrees are not this branch's source. ---
# `.claude/worktrees/<name>` is a full checkout of the same repository on someone else's
# branch. Reading it would let an in-progress citation there fail the gate here, for a file
# that is not on this branch -- and its ledger would disagree with this one besides.
CASE="$TMP/worktree-ignored"
cp -R "$BASE" "$CASE"
mkdir -p "$CASE/.claude/worktrees/other/$(dirname "$SWIFT_REL")"
cat > "$CASE/.claude/worktrees/other/$SWIFT_REL" <<EOF
struct InProgress {
    func halfWritten() throws {
        // Adapted from alacritty_terminal/src/term/search.rs#ported
        //   (alacritty 00000000, body sha256:deadbeefdead).
        // (no Divergence line yet -- still being written on another branch)
        search()
    }
}
EOF
expect_pass "$CASE" "a citation inside .claude/worktrees should not be linted from the main checkout"

# The mirror image, and the reason the skip test must run on paths *relative to* the root:
# linting a worktree directly means the root itself sits under `.claude/worktrees`. If the
# skip matched absolute components it would skip every file and report a vacuous pass.
CASE="$TMP/lint-from-inside-a-worktree"
mkdir -p "$CASE/.claude/worktrees"
cp -R "$BASE" "$CASE/.claude/worktrees/self"
expect_pass "$CASE/.claude/worktrees/self" "linting a worktree checkout directly should still work"

# ...and must still catch a real problem there, rather than passing because it saw nothing.
CASE="$TMP/worktree-root-still-checked"
mkdir -p "$CASE/.claude/worktrees"
cp -R "$BASE" "$CASE/.claude/worktrees/self"
edit_file "$CASE/.claude/worktrees/self/$SWIFT_REL" 's/body sha256:[0-9a-f]+/body sha256:deadbeefdead/'
expect_fail "$CASE/.claude/worktrees/self" "a bad citation in a directly-linted worktree should still fail"

# --- Build products are not source. ---
# `.build` holds tens of thousands of Swift files from SwiftPM checkouts. The walk prunes
# it, so this case also proves the pruning did not stop at the top level.
CASE="$TMP/build-products-ignored"
cp -R "$BASE" "$CASE"
mkdir -p "$CASE/.build/checkouts/other-package/Sources"
cat > "$CASE/.build/checkouts/other-package/Sources/Vendored.swift" <<'EOF'
// Adapted from alacritty_terminal/src/term/search.rs#no_such_fn_at_all
EOF
expect_pass "$CASE" "a Swift file under .build should not be linted"

# --- A new file is linted before it is committed. ---
# This is why discovery walks the tree instead of asking git for tracked files: the file
# whose citation most needs checking is the one still being written.
CASE="$TMP/untracked-file-linted"
cp -R "$BASE" "$CASE"
git -C "$CASE" init --quiet
git -C "$CASE" add -A
git -C "$CASE" -c user.name=test -c user.email=test@example.com commit --quiet -m baseline
cat > "$CASE/lib/TerminalCore/Tests/TerminalCoreTests/Untracked.swift" <<'EOF'
// Adapted from alacritty_terminal/src/term/search.rs#ported.
EOF
expect_fail "$CASE" "a malformed citation in an uncommitted file should still fail"

# --- The gate case: no checkout means exit 0 with a printed reason. ---
CASE="$TMP/references-absent"
cp -R "$BASE" "$CASE"
rm -rf "$CASE/references"
out="$("$LINT" "$CASE" 2>&1)" || fail "a tree with no references/alacritty should exit 0"
grep -q "skipped" <<<"$out" || fail "the references-absent skip should print its reason; got: $out"

echo "alacritty-parity lint self-test passed"
