#!/usr/bin/env bash
# Machine-checks the docs/research/ index contract, so the format's failure modes
# surface as test failures instead of as drift nobody notices. Both failures it
# guards were observed empirically: individual index rows grew from ~100 to
# >10,000 characters once a doc got too long for its own `## Outcome` to be
# trusted as the summary, and new docs kept being born as single flat files that
# then grew unboundedly. A documented-only cap is what existed before this lint;
# it did not hold.
#
# Checked invariants (IDs match the plan that introduced them):
#
#   I1  Every research doc has exactly one index row across both tables, and
#       every row's Doc cell is a markdown link to that doc's canonical path
#       (`N-topic.md` flat, `N-topic/README.md` folder). No orphans either way.
#   I2  The index is exactly two tables, `## Live` and `## Closed`, each unbroken
#       and in ascending doc-number order.
#   I3  No index cell exceeds 100 characters.
#   I4  Every Result cell in `## Closed` opens with a fixed vocabulary word.
#   I5  Only the frozen set of grandfathered docs (FLAT_ALLOWLIST below) may be a
#       flat `N-topic.md`; every new doc is a folder. The set is enumerated
#       rather than a numeric range because the number line has a hole in it
#       (there is no doc 5), and a range would silently admit `5-topic.md`.
#   I6  Every markdown file in a doc folder other than `README.md` is linked from
#       that `README.md` with a one-line blurb.
#   I7  The portable/project seam: below the `## Contract` heading no markdown
#       link resolves outside `docs/research/`. Everything below that heading is
#       generic research prose destined for a portable skill, so a project-local
#       link there is what makes the skill unextractable. Vocabulary is not
#       policed -- only outbound links.
#
# What it deliberately does not check: row *quality* (a short uninformative row
# passes), and which number a new doc claims (`5-topic/` passes -- I5 governs
# storage form, not number allocation). The self-test
# (scripts/tests/research-index-lint_test.sh) pins every case in both directions.
set -euo pipefail

# The frozen flat set: the docs that existed when the folder form landed. This
# list never grows -- a new entry here would be a new flat doc, which is exactly
# what I5 exists to refuse.
FLAT_ALLOWLIST=(
    1-external-tests.md
    2-wraptest-coverage.md
    3-serialized-redraw-optimization.md
    4-fallback-glyph-batching.md
    6-sprite-classification-regression.md
    7-fast-performance-benchmarks.md
    8-benchmark-variance-regression.md
    9-plan-render-allocation-hotspots.md
    10-terminal-feed-hotspots.md
    11-render-frame-budget.md
    12-cell-representation.md
    13-live-app-compositing-and-draw-hotspots.md
    14-live-scroll-workload-profile.md
    15-memory-footprint.md
    16-cell-padding.md
    17-cpu-profile-sweep.md
    18-cpu-renderer-optimization-leads.md
    19-owner-queue-occupancy.md
    20-pty-throughput-and-interactive-stimulus.md
    21-selection-gesture-cost.md
    22-application-exit-job-corruption.md
    23-pty-benchmark-alignment.md
)

if [[ "${1:-}" == "--print-flat-allowlist" ]]; then
    printf '%s\n' "${FLAT_ALLOWLIST[@]}"
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${1:-$SCRIPT_DIR/..}"
DIR="$ROOT/docs/research"
INDEX="$DIR/README.md"

BAD=0
violation() {
    echo "research-index-lint: $1" >&2
    BAD=1
}

[[ -d "$DIR" ]] || { echo "research-index-lint: missing $DIR" >&2; exit 2; }
[[ -f "$INDEX" ]] || { echo "research-index-lint: missing $INDEX" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
DOCS="$TMP/docs.tsv"
: > "$DOCS"

# --- Inventory the docs, and check I5 (storage form) while we are here. ---
for entry in "$DIR"/*; do
    name="$(basename "$entry")"
    [[ "$name" =~ ^[0-9]+- ]] || continue
    number="${name%%-*}"
    if [[ -f "$entry" ]]; then
        [[ "$name" == *.md ]] || continue
        printf '%s\t%s\n' "$number" "$name" >> "$DOCS"
        allowed=0
        for frozen in "${FLAT_ALLOWLIST[@]}"; do
            [[ "$name" == "$frozen" ]] && { allowed=1; break; }
        done
        if [[ "$allowed" -eq 0 ]]; then
            violation "docs/research/$name is a new flat doc; new docs are folders ($number-topic/README.md)"
        fi
    elif [[ -d "$entry" ]]; then
        if [[ ! -f "$entry/README.md" ]]; then
            violation "docs/research/$name/ is a doc folder with no README.md"
            continue
        fi
        printf '%s\t%s/README.md\n' "$number" "$name" >> "$DOCS"

        # --- I6: every other markdown file in the folder is linked with a blurb. ---
        for support in "$entry"/*.md; do
            [[ -f "$support" ]] || continue
            support_name="$(basename "$support")"
            [[ "$support_name" == "README.md" ]] && continue
            blurbed=0
            while IFS= read -r line; do
                stripped="$(printf '%s' "$line" \
                    | sed -E 's/\[[^]]*\]\([^)]*\)//g; s/[^[:alnum:]]+/ /g; s/^ +| +$//g')"
                if [[ "${#stripped}" -ge 10 ]]; then blurbed=1; break; fi
            done < <(grep -F "]($support_name)" "$entry/README.md" || true)
            if [[ "$blurbed" -eq 0 ]]; then
                violation "docs/research/$name/$support_name is not linked with a blurb from its folder README.md"
            fi
        done
    fi
done

if [[ ! -s "$DOCS" ]]; then
    echo "research-index-lint: no numbered research docs found under $DIR" >&2
    exit 2
fi

# --- I1, I2, I3, I4, I7 all read the index, and I1 cross-reads the inventory.
# The awk program is single-quoted on purpose: $0/FNR/NR are awk's, not the
# shell's (SC2016 is expected here). ---
# shellcheck disable=SC2016
awk -v index_label="docs/research/README.md" '
function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
function err(ln, msg) {
    if (ln > 0) printf("research-index-lint: %s:%d: %s\n", index_label, ln, msg) > "/dev/stderr"
    else        printf("research-index-lint: %s: %s\n", index_label, msg) > "/dev/stderr"
    bad = 1
}
# A link target escapes docs/research/ if it names a scheme, is absolute, or
# walks up past the directory it starts in. A bare `N-topic.md` placeholder and a
# `#anchor` both stay inside and are portable prose.
function escapes(t,   parts, n, i, depth) {
    sub(/#.*$/, "", t)
    if (t == "") return 0
    if (t ~ /^[A-Za-z][A-Za-z0-9+.-]*:/) return 1
    if (t ~ /^\//) return 1
    n = split(t, parts, "/")
    depth = 0
    for (i = 1; i <= n; i++) {
        if (parts[i] == "" || parts[i] == ".") continue
        if (parts[i] == "..") { if (--depth < 0) return 1 } else depth++
    }
    return 0
}
BEGIN {
    bad = 0
    nvocab = split("Shipped,No change,Rejected,Declined,Superseded,Tooling", vocab, ",")
}
FNR == NR { split($0, f, "\t"); canonical[f[1]] = f[2]; next }
{
    line = $0
    if (line ~ /^## /) {
        section = trim(substr(line, 4))
        if (section == "Contract") below_seam = 1
        if (section == "Live") seen_live++
        if (section == "Closed") seen_closed++
    }
    if (below_seam) {
        rest = line
        while (match(rest, /\]\([^)]*\)/)) {
            target = substr(rest, RSTART + 2, RLENGTH - 3)
            rest = substr(rest, RSTART + RLENGTH)
            if (escapes(target))
                err(FNR, "link `" target "` below the ## Contract seam resolves outside docs/research/")
        }
    }
    if (line !~ /^\|/) next

    known = (section == "Live" || section == "Closed")
    if (!known) {
        if (!reported[section]++)
            err(FNR, "table under `## " section "` -- the index is exactly ## Live and ## Closed")
    } else if (count[section] > 0 && FNR != last_line[section] + 1) {
        err(FNR, "the ## " section " table is split; it must be one unbroken block of rows")
    }
    last_line[section] = FNR
    idx = ++count[section]

    if (line !~ /\|[ \t]*$/) { err(FNR, "table row does not end with `|`"); next }
    ncell = split(line, cells, "|")
    # Cap every cell the row actually has before judging its shape, so a
    # malformed index still reports which rows are oversized -- that is the
    # diagnosis a reader needs first. (No apostrophes in this awk block: it is
    # a single-quoted shell string.)
    for (i = 2; i < ncell; i++) {
        cells[i] = trim(cells[i])
        if (length(cells[i]) > 100)
            err(FNR, "cell " (i - 1) " is " length(cells[i]) " characters; the cap is 100")
    }
    if (ncell != 6) { err(FNR, "table row has " (ncell - 2) " cells; the index has exactly 4"); next }
    if (!known) next

    if (idx == 1) {
        want = (section == "Live") ? "Next" : "Result"
        if (cells[2] != "#" || cells[3] != "Doc" || cells[4] != "Owns" || cells[5] != want)
            err(FNR, "## " section " header must be `# | Doc | Owns | " want "`")
        next
    }
    if (idx == 2) {
        if (line !~ /^\|[ \t:|-]*$/) err(FNR, "expected the table separator row here")
        next
    }

    number = cells[2]
    if (number !~ /^[0-9]+$/) { err(FNR, "doc-number cell `" number "` is not a number"); next }
    if (previous[section] != "" && number + 0 <= previous[section] + 0)
        err(FNR, "doc " number " breaks the ascending order of the ## " section " table")
    previous[section] = number
    if (row_line[number] != "")
        err(FNR, "doc " number " already has an index row at line " row_line[number])
    row_line[number] = FNR

    if (match(cells[3], /\]\([^)]+\)/) == 0) {
        err(FNR, "the Doc cell for doc " number " is not a markdown link to the doc")
    } else {
        target = substr(cells[3], RSTART + 2, RLENGTH - 3)
        if (!(number in canonical))
            err(FNR, "index row " number " names no doc under docs/research/")
        else if (target != canonical[number])
            err(FNR, "row " number " links `" target "` but doc " number " lives at `" canonical[number] "`")
    }

    if (section == "Closed") {
        ok = 0
        for (v = 1; v <= nvocab; v++) {
            word = vocab[v]
            if (index(cells[5], word) == 1) {
                after = substr(cells[5], length(word) + 1, 1)
                if (after == "" || after !~ /[A-Za-z]/) { ok = 1; break }
            }
        }
        if (!ok)
            err(FNR, "Result cell for doc " number " must open with Shipped/No change/Rejected/Declined/Superseded/Tooling")
    }
}
END {
    if (!seen_live) err(0, "missing the `## Live` table")
    if (!seen_closed) err(0, "missing the `## Closed` table")
    if (count["Live"] < 2) err(0, "the ## Live table has no header and separator")
    if (count["Closed"] < 2) err(0, "the ## Closed table has no header and separator")
    # Orphan docs are only meaningful once both tables exist; reporting all of
    # them on a structurally broken index would bury the structural diagnosis.
    if (seen_live && seen_closed)
        for (n in canonical)
            if (row_line[n] == "")
                err(0, "doc " n " (`" canonical[n] "`) has no index row")
    exit (bad ? 1 : 0)
}
' "$DOCS" "$INDEX" || BAD=1

if [[ "$BAD" -ne 0 ]]; then
    cat >&2 <<'EOF'

=======================================================================
research-index lint FAILED. The docs/research/ index is two capped
tables over a doc set that is folders from doc 24 onward:

  Over-cap cell -- the row is doing the doc's job. A row carries the
    number, a linked title, one clause on what the doc owns, and one
    clause on what changed (## Closed) or what it waits on (## Live).
    A row that will not fit means the doc's own `## Outcome` is
    underwritten -- fix it there, not in the index.

  New flat doc -- a new research doc is a folder: N-topic/README.md
    plus findings.md and decisions.md, with anything else that grows
    promoted to its own file and linked from the README with a blurb.

  Link below the ## Contract seam -- everything under `## Contract` is
    portable research prose. Project-local links belong above it.
=======================================================================
EOF
    exit 1
fi

echo "research index lint passed"
