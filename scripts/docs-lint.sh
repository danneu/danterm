#!/usr/bin/env bash
# Machine-checks two things about DanTerm's living documentation: that the code
# and doc paths it cites still exist, and that a design note's front matter says
# what the note actually is.
#
# Both failures were observed. A rename moved Projections.swift and
# ModelOperations.swift from `app/` into `lib/DanTermCore/`, and the design note
# that lists them as its References kept pointing at `app/` -- telling every
# later reader that view projections are app-layer code when they are pure core,
# which is the one distinction core-purity-lint.sh exists to protect. Separately,
# four notes read `Status: Accepted` directly above a block quote saying they had
# been superseded, and one of those named no successor at all.
#
# Checked invariants:
#
#   D1  Every repo-relative path cited in backticks resolves to a real file or
#       directory. A path is repo-relative when its first component is a
#       top-level entry of this repo (derived from git, so it needs no upkeep)
#       or one of DEAD_ROOTS below.
#   D2  Every relative markdown link resolves. This subsumes intra-docs/ and
#       intra-docs/design/ links; they are relative links like any other.
#   D3  Every `docs/design/*.md` except `index.md` carries `- Status: ` on line 3
#       and `- Date: ` on line 4, as bullets, in that order. `` `Status`: `` and
#       a bare `Status:` are rejected: the index's format section fixes one
#       spelling, and three were in the tree before it did.
#   D4  `Status` is Accepted, Superseded, or Draft.
#   D5  `Status: Superseded` carries a `- Superseded by: ` field whose markdown
#       link resolves to another note in `docs/design/`.
#   D6  A `Superseded by` field requires `Status: Superseded`. This is the check
#       that would have caught the original bug: the successor link was there and
#       the status still said the note bound.
#   D7  A note with a `> **` banner in its first 20 lines carries either
#       `Status: Superseded` or an `- Amended: ` field. A banner means something
#       below it is dead, and the front matter has to say which kind of dead.
#   D8  `Supersedes` and `Superseded by` are symmetric. If A supersedes B, B
#       names A.
#   D9  `Date` matches the note filename's date prefix.
#   D10 `index.md`'s note list and the directory agree exactly -- one row per
#       note, no orphan rows -- each row's status word matches the note's
#       `Status`, and the rows run newest last, as the list's own heading says.
#
# Scope. D1 and D2 read AGENTS.md, CLAUDE.md, docs/**, and agent-docs/**, minus
# docs/scratch/. They deliberately skip plans/ and docs/scratch/: those are dated
# records whose links are meant to rot, so linting them would either falsify a
# historical record or need an allowlist as long as the tree. docs/evidence/ and
# docs/research/ are dated too, but they are cited from live documents by stable
# id, so a reader follows their paths and has to be able to trust them; they are
# in, and the few paths they name as gone carry a marker. Fenced code blocks
# are skipped everywhere, because a path inside one is a template, not a
# citation. Link targets under plans/, references/, and .build/ are not resolved,
# for the same reason plus the fact that the last two are not tracked.
#
# Escape hatch. A document sometimes names a deleted file on purpose -- a
# supersession banner exists to say "this is gone". Such a document declares the
# paths it means to leave dangling:
#
#     <!-- docs-lint: allow-missing app/TerminalView.swift -->
#
# The marker may list several paths, may repeat, and may sit anywhere in the
# file. It exempts only those exact targets and only in the file that declares
# them, so a fresh dangling citation in the same file still fails. A whole-file
# or whole-section escape was the alternative; it hides every later mistake in
# its range, and a reader of the file cannot see what it forgave.
#
# Two things it deliberately does not check. A backticked token with no
# directory in it: `Model.swift` names no location, so resolving it would mean
# guessing which one. And the identifier half of the `file#identifier` form:
# resolving that means parsing Swift, Python, shell, and markdown headings, and
# a miss there is a false positive on a correct citation -- worse than the drift
# it would catch, so only the path half is resolved. It also does not judge
# whether a citation names the *right* file, or whether a banner's prose is
# accurate.
#
# The self-test (scripts/tests/docs-lint_test.sh) drives every invariant in both
# directions.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${1:-$SCRIPT_DIR/..}"
ROOT="$(cd "$ROOT" && pwd)"
DESIGN="$ROOT/docs/design"
INDEX="$DESIGN/index.md"

# Top-level names that no longer exist but are still worth catching. Live roots
# come from git, so a citation into a directory that was deleted wholesale would
# otherwise stop being checked at the moment it went stale -- which is exactly
# when it starts lying. plan-terminal-engine/ was deleted on 2026-08-12.
DEAD_ROOTS=(plan-terminal-engine)

# Targets under these prefixes are never resolved, because nothing in the repo
# promises they are there. plans/ links are meant to rot (AGENTS.md: plan ids are
# not stable and are not cited); references/ holds gitignored external checkouts
# that may not be materialized; .build/ is build output. Anything else that is
# gone uses an allow-missing marker, so the document says so where a reader can
# see it.
UNRESOLVED_ROOTS='^(plans/|references/|\.build/)'

BAD=0
violation() {
    echo "docs-lint: $1" >&2
    BAD=1
}

[[ -d "$DESIGN" ]] || { echo "docs-lint: missing $DESIGN" >&2; exit 2; }
[[ -f "$INDEX" ]] || { echo "docs-lint: missing $INDEX" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cd "$ROOT"

# --- Inventory: the documents in scope, and the roots a citation may name. ---
git ls-files -z >"$TMP/tracked.z"

SCOPED="$TMP/scoped.txt"
tr '\0' '\n' <"$TMP/tracked.z" \
    | grep -E '\.md$' \
    | grep -Ev '^(plans|references|docs/scratch)/' \
    | grep -E '^(AGENTS\.md|CLAUDE\.md|docs/|agent-docs/)' \
    | sort >"$SCOPED"

ROOTS="$TMP/roots.txt"
{
    tr '\0' '\n' <"$TMP/tracked.z" | awk -F/ 'NF { print $1 }'
    printf '%s\n' "${DEAD_ROOTS[@]}"
} | sort -u >"$ROOTS"

SCOPED_FILES=()
while IFS= read -r f; do SCOPED_FILES+=("$f"); done <"$SCOPED"
if [[ "${#SCOPED_FILES[@]}" -eq 0 ]]; then
    echo "docs-lint: no documents in scope under $ROOT" >&2
    exit 2
fi

# Collapse `a/b/../c` and `./` without touching the filesystem, so a link is
# judged by what it names rather than by what happens to resolve today.
normalize() {
    local path="$1" part out=()
    local IFS=/
    for part in $path; do
        case "$part" in
            ''|.) ;;
            ..) if [[ "${#out[@]}" -gt 0 && "${out[-1]}" != ".." ]]; then unset 'out[-1]'; else out+=(".."); fi ;;
            *) out+=("$part") ;;
        esac
    done
    printf '%s' "${out[*]}"
}

# --- D1, D2: extract citations and allow-missing markers. ---
#
# awk does the extraction and the shape filtering; the shell resolves the
# results, because deciding existence per candidate is what a shell is for. The
# awk program is single-quoted, so $0/FNR are awk's (SC2016 is expected).
# shellcheck disable=SC2016
CANDIDATES="$TMP/candidates.tsv"
awk '
function emit(kind, target) { printf("%s\t%s\t%d\t%s\n", kind, FILENAME, FNR, target) }
# A backticked citation may carry a trailing line span (`file.swift:8-13,67-101`)
# or an identifier (`file.swift#name`); both are stripped down to the path.
function pathOf(t) {
    sub(/#.*$/, "", t)
    sub(/:[0-9][0-9,-]*$/, "", t)
    sub(/[.,;:)]+$/, "", t)
    return t
}
FNR == 1 { fenced = 0 }
/^[ \t]*(```|~~~)/ { fenced = !fenced; next }
fenced { next }
{
    line = $0

    # The escape hatch, read before anything else on the line.
    if (match(line, /<!--[ \t]*docs-lint:[ \t]*allow-missing[ \t]/)) {
        rest = substr(line, RSTART + RLENGTH)
        sub(/-->.*$/, "", rest)
        n = split(rest, words, /[ \t]+/)
        for (i = 1; i <= n; i++)
            if (words[i] != "") printf("allow\t%s\t0\t%s\n", FILENAME, words[i])
    }

    # Markdown links. Bare `[text](target)`; a title after the target is not a
    # form this tree uses, so a space ends the target.
    rest = line
    while (match(rest, /\]\([^)( \t]*\)/)) {
        target = substr(rest, RSTART + 2, RLENGTH - 3)
        rest = substr(rest, RSTART + RLENGTH)
        if (target == "") continue
        if (target ~ /^[A-Za-z][A-Za-z0-9+.-]*:/) continue   # scheme
        if (target ~ /^[#\/]/) continue                      # anchor or absolute
        sub(/#.*$/, "", target)
        if (target != "") emit("link", target)
    }

    # Backticked paths.
    rest = line
    while (match(rest, /`[^`]+`/)) {
        token = substr(rest, RSTART + 1, RLENGTH - 2)
        rest = substr(rest, RSTART + RLENGTH)
        if (token ~ /[ \t*]/) continue
        if (token ~ /\.\.\./) continue                       # elided middle
        if (token !~ /^[A-Za-z0-9_.\/+-]+$/) continue
        token = pathOf(token)
        if (token == "") continue
        emit("backtick", token)
    }
}
' "${SCOPED_FILES[@]}" >"$CANDIDATES"

declare -A ALLOWED=()
while IFS=$'\t' read -r kind file _line target; do
    [[ "$kind" == "allow" ]] || continue
    ALLOWED["$file|$target"]=1
done <"$CANDIDATES"

declare -A IS_ROOT=()
while IFS= read -r r; do IS_ROOT["$r"]=1; done <"$ROOTS"

while IFS=$'\t' read -r kind file line target; do
    case "$kind" in
        allow) continue ;;
        backtick)
            # A bare `Model.swift` does not say where it lives, so only a token
            # with a directory in it is treated as a citation, and only when
            # that directory is a top-level name of this repo.
            first="${target%%/*}"
            [[ -n "$first" && "$first" != "$target" ]] || continue
            [[ -n "${IS_ROOT[$first]:-}" ]] || continue
            resolved="$target"
            label="\`$target\`"
            ;;
        link)
            dir="$(dirname "$file")"
            resolved="$(normalize "$dir/$target")"
            label="link \`$target\`"
            ;;
        *) continue ;;
    esac

    [[ "$resolved" =~ $UNRESOLVED_ROOTS ]] && continue
    [[ -n "${ALLOWED["$file|$target"]:-}" ]] && continue
    [[ -e "$ROOT/${resolved%/}" ]] && continue
    violation "$file:$line: $label does not exist"
done <"$CANDIDATES"

# --- D3 through D9: one note at a time. ---
declare -A NOTE_STATUS=()
declare -A NOTE_SUPERSEDES=()
declare -A NOTE_SUPERSEDED_BY=()
NOTES=()

for note in "$DESIGN"/*.md; do
    name="$(basename "$note")"
    [[ "$name" == "index.md" ]] && continue
    rel="docs/design/$name"
    NOTES+=("$name")

    line3="$(sed -n '3p' "$note")"
    line4="$(sed -n '4p' "$note")"

    if [[ ! "$line3" =~ ^-\ Status:\  ]]; then
        violation "$rel:3: front matter must open with \`- Status: <word>\` on line 3, not \"$line3\""
        continue
    fi
    has_date=1
    if [[ ! "$line4" =~ ^-\ Date:\  ]]; then
        violation "$rel:4: \`- Date: YYYY-MM-DD\` must be the line after Status, not \"$line4\""
        has_date=0
    fi

    status="${line3#- Status: }"
    status="${status%%[[:space:]]*}"
    NOTE_STATUS["$name"]="$status"
    case "$status" in
        Accepted|Superseded|Draft) ;;
        *) violation "$rel:3: Status \`$status\` is not one of Accepted, Superseded, Draft" ;;
    esac

    # D9 is only meaningful once line 4 is a Date bullet; otherwise the shape
    # violation above is the whole story and a second message would bury it.
    if [[ "$has_date" -eq 1 ]]; then
        date_line="${line4#- Date: }"
        date_field="${date_line%%[[:space:]]*}"
        file_date="${name:0:10}"
        if [[ "$date_field" != "$file_date" ]]; then
            violation "$rel:4: Date \`$date_field\` does not match the filename date \`$file_date\`"
        fi
    fi

    for field in "Superseded by" "Supersedes"; do
        while IFS= read -r hit; do
            [[ -n "$hit" ]] || continue
            n="${hit%%:*}"
            text="${hit#*:}"
            if [[ ! "$text" =~ \]\(([^\)]+)\) ]]; then
                violation "$rel:$n: \`$field\` must be a markdown link to another design note"
                continue
            fi
            target="${BASH_REMATCH[1]}"
            target="${target%%#*}"
            if [[ "$target" == */* || ! -f "$DESIGN/$target" ]]; then
                violation "$rel:$n: \`$field\` links \`$target\`, which is not a note in docs/design/"
                continue
            fi
            # A note may retire more than one predecessor, so both fields hold a
            # space-separated set rather than a single value.
            if [[ "$field" == "Superseded by" ]]; then
                NOTE_SUPERSEDED_BY["$name"]="${NOTE_SUPERSEDED_BY[$name]:-} $target"
            else
                NOTE_SUPERSEDES["$name"]="${NOTE_SUPERSEDES[$name]:-} $target"
            fi
        done < <(grep -n "^- $field: " "$note" || true)
    done

    if [[ "$status" == "Superseded" && -z "${NOTE_SUPERSEDED_BY[$name]:-}" ]]; then
        violation "$rel:3: Status is Superseded but no \`- Superseded by: \` field names the successor"
    fi
    if [[ "$status" != "Superseded" && -n "${NOTE_SUPERSEDED_BY[$name]:-}" ]]; then
        violation "$rel:3: a \`Superseded by\` field is present but Status is \`$status\`; a note with a successor is Superseded"
    fi

    banner="$(sed -n '1,20p' "$note" | grep -n '^> \*\*' | head -1 || true)"
    if [[ -n "$banner" && "$status" != "Superseded" ]]; then
        if ! grep -q '^- Amended: ' "$note"; then
            violation "docs/design/$name:${banner%%:*}: a banner says something here is dead, so the note needs \`Status: Superseded\` or an \`- Amended: \` field"
        fi
    fi
done

# D8: symmetry, checked once both directions are known.
names_include() { [[ " $1 " == *" $2 "* ]]; }
for name in "${NOTES[@]}"; do
    for successor in ${NOTE_SUPERSEDED_BY[$name]:-}; do
        names_include "${NOTE_SUPERSEDES[$successor]:-}" "$name" && continue
        violation "docs/design/$successor: does not name \`$name\`, which says it is superseded by this note; add \`- Supersedes: \`"
    done
    for predecessor in ${NOTE_SUPERSEDES[$name]:-}; do
        names_include "${NOTE_SUPERSEDED_BY[$predecessor]:-}" "$name" && continue
        violation "docs/design/$predecessor: does not name \`$name\`, which says it supersedes this note; add \`- Superseded by: \`"
    done
done

# --- D10: the index and the directory say the same thing. ---
declare -A ROW_SEEN=()
previous_date=""
while IFS= read -r hit; do
    n="${hit%%:*}"
    text="${hit#*:}"
    [[ "$text" =~ \]\(([^\)]+)\) ]] || continue
    target="${BASH_REMATCH[1]}"
    if [[ ! -f "$DESIGN/$target" ]]; then
        violation "docs/design/index.md:$n: row links \`$target\`, which is not a note in docs/design/"
        continue
    fi
    if [[ -n "${ROW_SEEN[$target]:-}" ]]; then
        violation "docs/design/index.md:$n: \`$target\` already has a row at line ${ROW_SEEN[$target]}"
        continue
    fi
    ROW_SEEN["$target"]="$n"

    if [[ -n "$previous_date" && "${target:0:10}" < "$previous_date" ]]; then
        violation "docs/design/index.md:$n: \`$target\` breaks the newest-last order of the note list"
    fi
    previous_date="${target:0:10}"

    # The row runs to the end of its (possibly wrapped) entry: read from the row
    # line up to the next row or the end of file, then look for the status word.
    row="$(sed -n "${n},\$p" "$INDEX" | awk 'NR > 1 && /^- \[/ { exit } { print }' | tr '\n' ' ')"
    want="${NOTE_STATUS[$target]:-}"
    # A note whose front matter is already reported as malformed has no status
    # to compare against; that violation stands on its own.
    [[ -n "$want" ]] || continue
    found=""
    for word in Accepted Superseded Draft; do
        [[ "$row" == *" -- $word"* ]] && found="$word"
    done
    if [[ -z "$found" ]]; then
        violation "docs/design/index.md:$n: row for \`$target\` names no status; it must read \`-- $want\`"
    elif [[ "$found" != "$want" ]]; then
        violation "docs/design/index.md:$n: row for \`$target\` says \`$found\` but the note says \`$want\`"
    fi
    # Only the `## Notes` list holds rows. Scoping to it keeps a bullet link
    # somewhere else in the index from being read as a row.
done < <(awk '/^## Notes[ \t]*$/ { in_notes = 1; next }
              /^## / { in_notes = 0 }
              in_notes && /^- \[/ { printf("%d:%s\n", FNR, $0) }' "$INDEX")

for name in "${NOTES[@]}"; do
    [[ -n "${ROW_SEEN[$name]:-}" ]] && continue
    violation "docs/design/index.md: \`$name\` has no row in the note list"
done

if [[ "$BAD" -ne 0 ]]; then
    cat >&2 <<'EOF'

=======================================================================
docs lint FAILED. Two contracts are checked here:

  Dangling citation -- a live document names a path that is gone. Fix
    the path. If the document names it as deliberately deleted (a
    supersession banner does exactly that), declare it in that file:
    <!-- docs-lint: allow-missing the/path -->

  Design note front matter -- lines 3 and 4 are `- Status: ` and
    `- Date: `, Status is Accepted / Superseded / Draft, a superseded
    note links its successor and the successor links back, a banner
    means Superseded or Amended, and docs/design/index.md lists every
    note once with the same status the note itself carries.
=======================================================================
EOF
    exit 1
fi

echo "docs lint passed"
