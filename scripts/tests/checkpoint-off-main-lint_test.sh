#!/usr/bin/env bash
# Self-test for the checkpoint payload-placement gate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../checkpoint-off-main-lint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# The lint takes the runtime tree it sweeps and, inside it, the one file that captures.
# The fixture mirrors that: `Runtime.swift` is the capture site, `Elsewhere.swift` is any
# other runtime file.
TREE="$TMP/app"
SITE="$TREE/Runtime.swift"
ELSEWHERE="$TREE/Elsewhere.swift"
mkdir -p "$TREE"

reset_tree() {
    cat > "$SITE" <<'SWIFT'
let capture = CheckpointCapture(snapshot: toSnapshot(model), scrollbackReads: reads)
Self.checkpointWriter.write(to: url, async: true, encode: capture.encoder())
if hasCheckpointableScrollback(text) { note() }
// graftScrollback(onto:) and JSONEncoder() belong to the deferred encoder, not here.
SWIFT
    cat > "$ELSEWHERE" <<'SWIFT'
func describe() -> String { "nothing to do with checkpoints" }
SWIFT
}

reset_tree
"$LINT" "$TREE" "$SITE" >/dev/null || fail "capture-and-defer should pass"

cat > "$ELSEWHERE" <<'SWIFT'
Self.checkpointWriter.write(
    to: url,
    async: async,
    encode: capture.encoder(prettyPrinted: true)
)
SWIFT
"$LINT" "$TREE" "$SITE" >/dev/null || fail "an encoder passed as an argument should pass"

# The rule is about a place, not a file. A capture site that moves to a sibling file has
# to stay in view, so the stage spellings and the encoder-handoff rule sweep the tree.
for construct in \
    'let enriched = graftScrollback(onto: snapshot, scrollbackByPaneId: reads)' \
    'let kept = truncateScrollback(text, keeping: .checkpoint)' \
    'let initFile = toInitFile(snapshot: enriched)' \
    'let encode = capture.encoder(prettyPrinted: true)'
do
    for planted in "$SITE" "$ELSEWHERE"; do
        reset_tree
        printf '%s\n' "$construct" > "$planted"
        if message="$("$LINT" "$TREE" "$SITE" 2>&1)"; then
            fail "payload assembly in $(basename "$planted") should fail: $construct"
        fi
        case "$message" in
            *"$(basename "$planted")"*) ;;
            *) fail "the failure should name $(basename "$planted"): $message" ;;
        esac
    done
done

# `JSONEncoder(` is the one spelling the runtime uses for unrelated reasons, so it stays
# scoped to the capture site. Banning it tree-wide would fail on JSON that has nothing to
# do with a checkpoint.
reset_tree
printf '%s\n' 'let encoder = JSONEncoder()' > "$SITE"
"$LINT" "$TREE" "$SITE" >/dev/null 2>&1 && fail "JSONEncoder at the capture site should fail"

reset_tree
printf '%s\n' 'let encoder = JSONEncoder()' > "$ELSEWHERE"
"$LINT" "$TREE" "$SITE" >/dev/null || fail "unrelated JSON encoding elsewhere should pass"

reset_tree

# --- a lint that cannot find its subject must fail -------------------------
# A rename that outruns the target list has to go red naming the path, not report
# "passed" over nothing. `rg` exits non-zero on a missing path and `if rg` reads any
# non-zero status as "no violations", so the targets have to be resolved before the
# sweep rather than handed to the search.
assert_checked_nothing() {
    local label="$1" named="$2"
    shift 2
    local message
    if message="$("$LINT" "$@" 2>&1)"; then
        fail "$label should fail"
    fi
    case "$message" in
        *"checked nothing"*) ;;
        *) fail "$label should say the lint checked nothing: $message" ;;
    esac
    case "$message" in
        *"$named"*) ;;
        *) fail "$label should name the path: $message" ;;
    esac
}

assert_checked_nothing "a missing runtime tree" "$TMP/never-created" \
    "$TMP/never-created" "$SITE"

# The capture site is the half that still names a single file, so it is the half a rename
# can disarm. It has to go red the same way.
assert_checked_nothing "a missing capture site" "$TMP/Gone.swift" \
    "$TREE" "$TMP/Gone.swift"

# An existing directory holding no Swift file is the same hole with the path still in
# place: the subject moved out from under a name that survives an existence check.
mkdir -p "$TMP/empty"
assert_checked_nothing "a target directory holding no Swift file" "$TMP/empty" \
    "$TMP/empty" "$SITE"

echo "checkpoint off-main lint self-test passed"
