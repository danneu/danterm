#!/usr/bin/env bash
# Self-test for scripts/docs-lint.sh. Every invariant is driven in both
# directions against a synthetic repo, because a lint that rejected everything
# would satisfy the negative cases alone and then reject the first correct
# citation someone writes.
#
# The fixture is a real git repository. The lint derives which top-level names
# count as repo-relative from `git ls-files`, so a fixture that is not a repo
# would exercise a different code path than the tree does.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../docs-lint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
passes() { bash "$LINT" "$1" >/dev/null 2>&1; }
expect_pass() { passes "$1" || { bash "$LINT" "$1" >&2 || true; fail "$2"; }; }
expect_fail() { ! passes "$1" || fail "$2"; }
# A lint failure has to name the problem, not just exit non-zero.
expect_message() {
    # The lint exits non-zero here by design, and pipefail would read that as a
    # broken pipeline, so its status is discarded before grep sees the output.
    { bash "$LINT" "$1" 2>&1 || true; } | grep -qF "$2" || fail "$3 (no message matching: $2)"
}

# --- The baseline valid tree. ---
BASE="$TMP/valid"
mkdir -p "$BASE/app" "$BASE/docs/design"
cd "$BASE"
git init -q .
git config user.email t@example.com
git config user.name Test

echo "// a real file" >"$BASE/app/Real.swift"

cat >"$BASE/AGENTS.md" <<'EOF'
# Agents

The accept loop is in `app/Real.swift`. See
[docs/design/index.md](docs/design/index.md).
EOF

cat >"$BASE/docs/design/2026-01-01-old.md" <<'EOF'
# Old Decision

- Status: Superseded
- Date: 2026-01-01
- Superseded by: [New Decision](2026-02-02-new.md)

> **2026-02-02: superseded.** The mechanism is gone.

## Context
EOF

cat >"$BASE/docs/design/2026-02-02-new.md" <<'EOF'
# New Decision

- Status: Accepted
- Date: 2026-02-02
- Supersedes: [Old Decision](2026-01-01-old.md)

## Context

The old code lived in `app/Real.swift`.
EOF

cat >"$BASE/docs/design/index.md" <<'EOF'
# Design Decisions

## Notes

Newest last.

- [2026-01-01: Old Decision](2026-01-01-old.md) -- Superseded by
  [2026-02-02: New Decision](2026-02-02-new.md).
- [2026-02-02: New Decision](2026-02-02-new.md) -- Accepted.
EOF

git add -A
git commit -qm baseline
cd - >/dev/null

expect_pass "$BASE" "the baseline tree should pass"

# Rewrite one file of a fixture in place (BSD and GNU sed disagree on -i).
edit_file() {
    local target="$1" script="$2"
    sed -E "$script" "$target" >"$target.new" && mv "$target.new" "$target"
}
fixture() {
    rm -rf "${TMP:?}/$1"
    cp -R "$BASE" "$TMP/$1"
    echo "$TMP/$1"
}

# --- D1: a backticked repo-relative path must resolve. ---
CASE="$(fixture d1-dangling)"
edit_file "$CASE/AGENTS.md" 's#app/Real\.swift#app/Gone.swift#'
expect_fail "$CASE" "a backticked path that does not exist should fail"
expect_message "$CASE" "AGENTS.md:3: \`app/Gone.swift\` does not exist" \
    "the D1 failure should name the file, the line, and the path"

# The original bug: a design note's References survive a file's move to another
# layer, and keep pointing at the layer it left.
CASE="$(fixture d1-moved-layer)"
edit_file "$CASE/docs/design/2026-02-02-new.md" 's#app/Real\.swift#app/Projections.swift#'
expect_fail "$CASE" "a References path left behind by a cross-layer move should fail"

# The pre-S09 shape: a live document citing a file in a deleted directory. That
# directory is no longer a top-level name, so this is the case DEAD_ROOTS covers.
CASE="$(fixture d1-dead-root)"
edit_file "$CASE/AGENTS.md" 's#app/Real\.swift#plan-terminal-engine/12-testing-conformance.md#'
expect_fail "$CASE" "a citation into the deleted plan-terminal-engine/ should fail"

# A path is not checked unless its first component is a top-level name, so an
# external tree's own paths do not produce false positives.
CASE="$(fixture d1-foreign-path)"
edit_file "$CASE/AGENTS.md" 's#app/Real\.swift#src/apprt/embedded.zig#'
expect_pass "$CASE" "a path rooted outside this repo should not be checked"

# A trailing line span is part of the citation form and must be stripped.
CASE="$(fixture d1-line-span)"
edit_file "$CASE/AGENTS.md" 's#app/Real\.swift#app/Real.swift:8-13,67-101#'
expect_pass "$CASE" "a \`file:lines\` citation should resolve on its path half"

# Fenced blocks are templates, not citations.
CASE="$(fixture d1-fenced)"
# shellcheck disable=SC2016  # literal markdown, not shell expansion
printf '\n```\napp/Gone.swift\n`app/AlsoGone.swift`\n```\n' >>"$CASE/AGENTS.md"
expect_pass "$CASE" "paths inside a fenced code block should not be checked"

# The escape hatch, in both directions.
CASE="$(fixture d1-allow-missing)"
edit_file "$CASE/AGENTS.md" 's#app/Real\.swift#app/Gone.swift#'
printf '\n<!-- docs-lint: allow-missing app/Gone.swift -->\n' >>"$CASE/AGENTS.md"
expect_pass "$CASE" "an allow-missing marker should exempt the path it names"

CASE="$(fixture d1-allow-missing-scoped)"
edit_file "$CASE/AGENTS.md" 's#app/Real\.swift#app/Gone.swift#'
printf '\n<!-- docs-lint: allow-missing app/Other.swift -->\n' >>"$CASE/AGENTS.md"
expect_fail "$CASE" "an allow-missing marker must not exempt a path it does not name"

CASE="$(fixture d1-allow-missing-per-file)"
edit_file "$CASE/AGENTS.md" 's#app/Real\.swift#app/Gone.swift#'
printf '\n<!-- docs-lint: allow-missing app/Gone.swift -->\n' >>"$CASE/docs/design/2026-02-02-new.md"
expect_fail "$CASE" "an allow-missing marker in one file must not exempt another file"

# --- D2: relative markdown links resolve. ---
CASE="$(fixture d2-dangling-link)"
edit_file "$CASE/AGENTS.md" 's#\(docs/design/index\.md\)#(docs/design/gone.md)#'
expect_fail "$CASE" "a markdown link to a missing file should fail"
expect_message "$CASE" "link \`docs/design/gone.md\` does not exist" \
    "the D2 failure should name the link target"

CASE="$(fixture d2-relative-link)"
printf '\nSee [the old note](../design/2026-01-01-old.md).\n' >>"$CASE/docs/design/index.md"
expect_pass "$CASE" "a link that walks up and back down should resolve"

CASE="$(fixture d2-plans-link)"
printf '\nSee [the plan](../../plans/impl/2026-01-01-gone.md).\n' >>"$CASE/docs/design/index.md"
expect_pass "$CASE" "a link into plans/ should not be resolved; plan links are meant to rot"

# --- D3: front matter shape. ---
CASE="$(fixture d3-backticked)"
# shellcheck disable=SC2016  # the backticks are the thing under test
edit_file "$CASE/docs/design/2026-02-02-new.md" 's#^- Status: Accepted#`Status`: Accepted#'
expect_fail "$CASE" "a backticked \`Status\`: field should fail"
expect_message "$CASE" "front matter must open with" "the D3 failure should say what line 3 must be"

CASE="$(fixture d3-date-missing)"
edit_file "$CASE/docs/design/2026-02-02-new.md" 's#^- Date: 2026-02-02#Date: 2026-02-02#'
expect_fail "$CASE" "a bare Date: line should fail"

CASE="$(fixture d3-order)"
python3 - "$CASE/docs/design/2026-02-02-new.md" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().split("\n")
lines[2], lines[3] = lines[3], lines[2]
open(p, "w").write("\n".join(lines))
PY
expect_fail "$CASE" "Date before Status should fail"

# --- D4: the status vocabulary. ---
CASE="$(fixture d4-vocabulary)"
edit_file "$CASE/docs/design/2026-02-02-new.md" 's#^- Status: Accepted#- Status: Current#'
expect_fail "$CASE" "an unknown status word should fail"
expect_message "$CASE" "is not one of Accepted, Superseded, Draft" \
    "the D4 failure should list the allowed words"

# --- D5: Superseded needs a resolvable successor link. ---
CASE="$(fixture d5-no-successor)"
edit_file "$CASE/docs/design/2026-01-01-old.md" '/^- Superseded by: /d'
edit_file "$CASE/docs/design/2026-02-02-new.md" '/^- Supersedes: /d'
expect_fail "$CASE" "Superseded with no successor field should fail"
expect_message "$CASE" "no \`- Superseded by: \` field names the successor" \
    "the D5 failure should say the successor is missing"

CASE="$(fixture d5-successor-outside)"
edit_file "$CASE/docs/design/2026-01-01-old.md" 's#\(2026-02-02-new\.md\)#(../../AGENTS.md)#'
expect_fail "$CASE" "a successor link outside docs/design/ should fail"

# --- D6: a successor link forces Superseded. This is the original bug. ---
CASE="$(fixture d6-accepted-with-successor)"
edit_file "$CASE/docs/design/2026-01-01-old.md" 's#^- Status: Superseded#- Status: Accepted#'
expect_fail "$CASE" "Status: Accepted above a Superseded by field should fail"
expect_message "$CASE" "a note with a successor is Superseded" \
    "the D6 failure should say the status contradicts the field"

# --- D7: a banner forces Superseded or Amended. The pre-S08 state. ---
CASE="$(fixture d7-banner-accepted)"
printf '# Amended Note\n\n- Status: Accepted\n- Date: 2026-03-03\n\n> **2026-04-04: the mechanism is gone.** The rule still binds.\n\n## Context\n' \
    >"$CASE/docs/design/2026-03-03-amended.md"
edit_file "$CASE/docs/design/index.md" 's#^- \[2026-02-02(.*)$#- [2026-02-02\1\n- [2026-03-03: Amended Note](2026-03-03-amended.md) -- Accepted.#'
expect_fail "$CASE" "Status: Accepted under a banner with no Amended field should fail"
expect_message "$CASE" "needs \`Status: Superseded\` or an \`- Amended: \` field" \
    "the D7 failure should name both ways out"

CASE="$(fixture d7-banner-amended)"
printf '# Amended Note\n\n- Status: Accepted\n- Date: 2026-03-03\n- Amended: 2026-04-04 -- the mechanism is gone.\n\n> **2026-04-04: the mechanism is gone.** The rule still binds.\n\n## Context\n' \
    >"$CASE/docs/design/2026-03-03-amended.md"
edit_file "$CASE/docs/design/index.md" 's#^- \[2026-02-02(.*)$#- [2026-02-02\1\n- [2026-03-03: Amended Note](2026-03-03-amended.md) -- Accepted.#'
expect_pass "$CASE" "a banner plus an Amended field should pass"

# --- D8: Supersedes and Superseded by are symmetric. ---
CASE="$(fixture d8-asymmetric)"
edit_file "$CASE/docs/design/2026-02-02-new.md" '/^- Supersedes: /d'
expect_fail "$CASE" "a successor that does not name its predecessor should fail"
expect_message "$CASE" "add \`- Supersedes: \`" "the D8 failure should name the missing field"

CASE="$(fixture d8-two-predecessors)"
printf '# Third Decision\n\n- Status: Superseded\n- Date: 2026-01-15\n- Superseded by: [New Decision](2026-02-02-new.md)\n\n## Context\n' \
    >"$CASE/docs/design/2026-01-15-third.md"
edit_file "$CASE/docs/design/2026-02-02-new.md" \
    's#^- Supersedes: \[Old Decision\]\(2026-01-01-old\.md\)$#- Supersedes: [Old Decision](2026-01-01-old.md)\n- Supersedes: [Third Decision](2026-01-15-third.md)#'
edit_file "$CASE/docs/design/index.md" \
    's#^- \[2026-02-02(.*)$#- [2026-01-15: Third Decision](2026-01-15-third.md) -- Superseded by [New](2026-02-02-new.md).\n- [2026-02-02\1#'
expect_pass "$CASE" "a note may repeat Supersedes for each predecessor it retired"

# --- D9: Date matches the filename. ---
CASE="$(fixture d9-date-mismatch)"
edit_file "$CASE/docs/design/2026-02-02-new.md" 's#^- Date: 2026-02-02#- Date: 2026-02-03#'
expect_fail "$CASE" "a Date that disagrees with the filename should fail"
expect_message "$CASE" "does not match the filename date" "the D9 failure should name both dates"

# --- D10: the index and the directory agree. ---
CASE="$(fixture d10-orphan-note)"
printf '# Lonely\n\n- Status: Accepted\n- Date: 2026-04-04\n\n## Context\n' \
    >"$CASE/docs/design/2026-04-04-lonely.md"
expect_fail "$CASE" "a note with no index row should fail"
expect_message "$CASE" "has no row in the note list" "the D10 orphan-note failure should name the note"

CASE="$(fixture d10-orphan-row)"
printf -- '- [2026-05-05: Ghost](2026-05-05-ghost.md) -- Accepted.\n' >>"$CASE/docs/design/index.md"
expect_fail "$CASE" "an index row for a note that does not exist should fail"

CASE="$(fixture d10-status-mismatch)"
edit_file "$CASE/docs/design/index.md" 's#^- \[2026-02-02: New Decision\]\(2026-02-02-new\.md\) -- Accepted\.#- [2026-02-02: New Decision](2026-02-02-new.md) -- Superseded.#'
expect_fail "$CASE" "an index row whose status contradicts the note should fail"
expect_message "$CASE" "says \`Superseded\` but the note says \`Accepted\`" \
    "the D10 status failure should name both statuses"

CASE="$(fixture d10-no-status)"
edit_file "$CASE/docs/design/index.md" 's#^- \[2026-02-02: New Decision\]\(2026-02-02-new\.md\) -- Accepted\.#- [2026-02-02: New Decision](2026-02-02-new.md)#'
expect_fail "$CASE" "an index row with no status word should fail"

CASE="$(fixture d10-duplicate-row)"
printf -- '- [2026-02-02: New Decision](2026-02-02-new.md) -- Accepted.\n' >>"$CASE/docs/design/index.md"
expect_fail "$CASE" "two rows for one note should fail"

CASE="$(fixture d10-order)"
python3 - "$CASE/docs/design/index.md" <<'PY'
import sys
p = sys.argv[1]
text = open(p).read()
old = "- [2026-01-01: Old Decision](2026-01-01-old.md) -- Superseded by\n  [2026-02-02: New Decision](2026-02-02-new.md).\n"
new = "- [2026-02-02: New Decision](2026-02-02-new.md) -- Accepted.\n"
assert old in text and new in text
open(p, "w").write(text.replace(old + new, new + old))
PY
expect_fail "$CASE" "note rows out of date order should fail"

echo "docs-lint self-test passed"
