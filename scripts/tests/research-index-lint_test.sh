#!/usr/bin/env bash
# Self-test for the docs/research/ index contract lint. Every case builds a
# fixture tree and asserts the exit status, so the lint is pinned in both
# directions -- a lint that rejected everything would satisfy the negative cases
# alone and then reject the first legitimate folder doc.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../research-index-lint.sh"
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
edit_index() { edit_file "$1/docs/research/README.md" "$2"; }

# --- The baseline valid tree: a live flat doc, a closed flat doc, and a closed
# folder doc, so PO4 "a tree mixing the two forms passes" is the baseline. ---
BASE="$TMP/valid"
BASE_INDEX="$BASE/docs/research/README.md"
mkdir -p "$BASE/docs/research/24-later-topic"
echo "# External tests" > "$BASE/docs/research/1-external-tests.md"
echo "# Wraptest coverage" > "$BASE/docs/research/2-wraptest-coverage.md"
echo "# Later topic" > "$BASE/docs/research/24-later-topic/README.md"
cat > "$BASE_INDEX" <<'EOF'
# docs/research/ -- living research files

## Live

| # | Doc | Owns | Next |
| --- | --- | --- | --- |
| 1 | [External tests](1-external-tests.md) | Which external suites to adopt | A decision on adoption |

## Closed

| # | Doc | Owns | Result |
| --- | --- | --- | --- |
| 2 | [Wraptest coverage](2-wraptest-coverage.md) | Whether wraptest belongs here | Declined -- redundant |
| 24 | [Later topic](24-later-topic/README.md) | Some later topic | Shipped -- a thing |

## Project notes

- The contract lives in [FORMAT.md](FORMAT.md).
EOF
cat > "$BASE/docs/research/FORMAT.md" <<'EOF'
# Research doc format

- Files are numbered and never renumbered; see the placeholder [N-topic.md](N-topic.md).
- Claims cite the benchmark and commit that produced them.
EOF

expect_pass "$BASE" "the baseline tree (flat and folder docs, both links correct) should pass"

# --- PO1: one row per doc, and the Doc cell links to the canonical path. ---
CASE="$TMP/po1-orphan-doc"
cp -R "$BASE" "$CASE"
echo "# Serialized redraw" > "$CASE/docs/research/3-serialized-redraw-optimization.md"
expect_fail "$CASE" "a doc with no index row should fail"

CASE="$TMP/po1-orphan-row"
cp -R "$BASE" "$CASE"
awk '/^\| 24 \|/ { print "| 9 | [Nine](9-plan-render-allocation-hotspots.md) | A thing | Shipped -- a thing |" } { print }' \
    "$BASE_INDEX" > "$CASE/docs/research/README.md"
expect_fail "$CASE" "an index row naming no doc should fail"

CASE="$TMP/po1-both-tables"
cp -R "$BASE" "$CASE"
awk '{ print }
     /^\| 1 \| \[External/ { print "| 2 | [Wraptest coverage](2-wraptest-coverage.md) | Whether it belongs | Waiting |" }' \
    "$BASE_INDEX" > "$CASE/docs/research/README.md"
expect_fail "$CASE" "a doc appearing in both tables should fail"

CASE="$TMP/po1-unlinked"
cp -R "$BASE" "$CASE"
edit_index "$CASE" 's/\[Wraptest coverage\]\(2-wraptest-coverage\.md\)/Wraptest coverage/'
expect_fail "$CASE" "an unlinked Doc cell should fail"

CASE="$TMP/po1-missing-path"
cp -R "$BASE" "$CASE"
edit_index "$CASE" 's/\(2-wraptest-coverage\.md\)/(2-nonexistent.md)/'
expect_fail "$CASE" "a Doc cell linking a nonexistent path should fail"

CASE="$TMP/po1-wrong-doc"
cp -R "$BASE" "$CASE"
edit_index "$CASE" 's/\(2-wraptest-coverage\.md\)/(1-external-tests.md)/'
expect_fail "$CASE" "a Doc cell linking a different doc should fail"

# --- PO2: each table is one unbroken block in ascending order. ---
CASE="$TMP/po2-split"
cp -R "$BASE" "$CASE"
awk '/^\| 24 \|/ { print "" } { print }' "$BASE_INDEX" > "$CASE/docs/research/README.md"
expect_fail "$CASE" "a table split by a blank line should fail"

CASE="$TMP/po2-order"
cp -R "$BASE" "$CASE"
awk '/^\| 2 \| \[Wraptest/ { held = $0; next }
     /^\| 24 \|/ { print; print held; next }
     { print }' "$BASE_INDEX" > "$CASE/docs/research/README.md"
expect_fail "$CASE" "rows out of ascending order should fail"

# --- PO3: the cell cap and the Result vocabulary. ---
CASE="$TMP/po3-over-cap"
cp -R "$BASE" "$CASE"
OVERSIZED="$(printf 'x%.0s' $(seq 101))"
edit_index "$CASE" "s/Whether wraptest belongs here/$OVERSIZED/"
expect_fail "$CASE" "an over-cap cell should fail"

CASE="$TMP/po3-vocabulary"
cp -R "$BASE" "$CASE"
edit_index "$CASE" 's/Declined -- redundant/Closed -- redundant/'
expect_fail "$CASE" "a Result cell outside the fixed vocabulary should fail"

CASE="$TMP/po3-live-free-text"
cp -R "$BASE" "$CASE"
edit_index "$CASE" 's/A decision on adoption/Nothing that reads like a result word/'
expect_pass "$CASE" "the Live table final column is free text and should pass"

# --- PO4: storage form. The frozen flat set passes as flat files; a new flat doc
# does not, including one claiming an unused historical number. The allowlist is
# read from the lint so the two never drift apart. ---
FROZEN="$TMP/frozen"
mkdir -p "$FROZEN/docs/research"
{
    printf '# docs/research/\n\n## Live\n\n'
    printf '| # | Doc | Owns | Next |\n| --- | --- | --- | --- |\n\n'
    printf '## Closed\n\n| # | Doc | Owns | Result |\n| --- | --- | --- | --- |\n'
} > "$FROZEN/docs/research/README.md"
while IFS= read -r frozen_doc; do
    echo "# ${frozen_doc%.md}" > "$FROZEN/docs/research/$frozen_doc"
    echo "| ${frozen_doc%%-*} | [Doc](${frozen_doc}) | A thing | Shipped -- a thing |" \
        >> "$FROZEN/docs/research/README.md"
done < <("$LINT" --print-flat-allowlist)
printf '\n## Project notes\n\n- The contract lives in [FORMAT.md](FORMAT.md).\n' \
    >> "$FROZEN/docs/research/README.md"
printf '# Research doc format\n\n- Portable prose only.\n' > "$FROZEN/docs/research/FORMAT.md"
expect_pass "$FROZEN" "every doc in the frozen flat set should pass as a flat file"

CASE="$TMP/po4-new-flat"
cp -R "$BASE" "$CASE"
rm -rf "$CASE/docs/research/24-later-topic"
echo "# Later topic" > "$CASE/docs/research/24-later-topic.md"
edit_index "$CASE" 's|\(24-later-topic/README\.md\)|(24-later-topic.md)|'
expect_fail "$CASE" "a new flat doc should fail even with a correct index row"

CASE="$TMP/po4-unused-number"
cp -R "$BASE" "$CASE"
echo "# Five" > "$CASE/docs/research/5-topic.md"
awk '/^\| 24 \|/ { print "| 5 | [Five](5-topic.md) | A thing | Shipped -- a thing |" } { print }' \
    "$BASE_INDEX" > "$CASE/docs/research/README.md"
expect_fail "$CASE" "a new flat doc claiming an unused historical number should fail"

# --- PO5: supporting files in a folder doc are reachable. The positive case is
# required -- a lint that rejected every supporting file would pass the negative
# case and stay green against an all-flat tree. ---
BLURBED="$TMP/po5-blurbed"
cp -R "$BASE" "$BLURBED"
echo "# Findings" > "$BLURBED/docs/research/24-later-topic/findings.md"
echo "# Decisions" > "$BLURBED/docs/research/24-later-topic/decisions.md"
cat >> "$BLURBED/docs/research/24-later-topic/README.md" <<'EOF'

- [findings.md](findings.md) -- the append-only evidence chain for this topic.
- [decisions.md](decisions.md) -- the auditable decision log for this topic.
EOF
expect_pass "$BLURBED" "a folder whose README links and blurbs its supporting files should pass"

CASE="$TMP/po5-unlinked-support"
cp -R "$BLURBED" "$CASE"
edit_file "$CASE/docs/research/24-later-topic/README.md" '/\[decisions\.md\]/d'
expect_fail "$CASE" "a supporting file that nothing links should fail"

CASE="$TMP/po5-linked-without-blurb"
cp -R "$BLURBED" "$CASE"
edit_file "$CASE/docs/research/24-later-topic/README.md" \
    's|^- \[decisions\.md\]\(decisions\.md\).*$|- [decisions.md](decisions.md)|'
expect_fail "$CASE" "a supporting file linked with no blurb should fail"

# --- PO6: the seam is a file boundary -- FORMAT.md carries no outbound link,
# README.md may carry any. The third case is what proves the rule is about the
# file and not about links in general. ---
CASE="$TMP/po6-outbound"
cp -R "$BASE" "$CASE"
printf -- '- See [the perf doc](../../agent-docs/terminal-performance.md).\n' \
    >> "$CASE/docs/research/FORMAT.md"
expect_fail "$CASE" "an outbound link in FORMAT.md should fail"

CASE="$TMP/po6-portable-prose"
cp -R "$BASE" "$CASE"
# shellcheck disable=SC2016  # the backticks are literal markdown, not a subshell
printf -- '- Cite `9/F3`, name the benchmark, and link [N-topic.md](N-topic.md).\n' \
    >> "$CASE/docs/research/FORMAT.md"
expect_pass "$CASE" "portable prose and placeholder links in FORMAT.md should pass"

CASE="$TMP/po6-index-link"
cp -R "$BASE" "$CASE"
printf -- '- See [the perf doc](../../agent-docs/terminal-performance.md).\n' \
    >> "$CASE/docs/research/README.md"
expect_pass "$CASE" "a project link in README.md should pass"

# --- PO7: the contract file exists and the index reaches it. ---
CASE="$TMP/po7-missing-format"
cp -R "$BASE" "$CASE"
rm "$CASE/docs/research/FORMAT.md"
expect_fail "$CASE" "a tree with no FORMAT.md should fail"

CASE="$TMP/po7-unlinked-format"
cp -R "$BASE" "$CASE"
edit_index "$CASE" 's|\[FORMAT\.md\]\(FORMAT\.md\)|FORMAT.md|'
expect_fail "$CASE" "a FORMAT.md nothing links should fail"

echo "research index lint self-test passed"
