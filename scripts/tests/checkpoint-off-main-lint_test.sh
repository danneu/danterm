#!/usr/bin/env bash
# Self-test for the checkpoint payload-placement gate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../checkpoint-off-main-lint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

mkdir -p "$TMP/allowed" "$TMP/denied"
cat > "$TMP/allowed/Runtime.swift" <<'SWIFT'
let capture = CheckpointCapture(snapshot: toSnapshot(model), scrollbackReads: reads)
Self.checkpointWriter.write(to: url, async: true, encode: capture.encoder())
if hasCheckpointableScrollback(text) { note() }
// graftScrollback(onto:) and JSONEncoder() belong to the deferred encoder, not here.
SWIFT
"$LINT" "$TMP/allowed" >/dev/null || fail "capture-and-defer should pass"

cat > "$TMP/allowed/MultiLine.swift" <<'SWIFT'
Self.checkpointWriter.write(
    to: url,
    async: async,
    encode: capture.encoder(prettyPrinted: true)
)
SWIFT
"$LINT" "$TMP/allowed" >/dev/null || fail "an encoder passed as an argument should pass"

for construct in \
    'let enriched = graftScrollback(onto: snapshot, scrollbackByPaneId: reads)' \
    'let kept = truncateScrollback(text, keeping: .checkpoint)' \
    'let initFile = toInitFile(snapshot: enriched)' \
    'let encoder = JSONEncoder()' \
    'let encode = capture.encoder(prettyPrinted: true)'
do
    printf '%s\n' "$construct" > "$TMP/denied/Runtime.swift"
    if "$LINT" "$TMP/denied" >/dev/null 2>&1; then
        fail "payload assembly should fail: $construct"
    fi
done


# --- a lint that cannot find its subject must fail -------------------------
# A rename that outruns the target list has to go red naming the path, not report
# "passed" over nothing. `rg` exits non-zero on a missing path and `if rg` reads any
# non-zero status as "no violations", so the targets have to be resolved before the
# sweep rather than handed to the search.
assert_checked_nothing() {
    local label="$1"; shift
    local message
    if message="$("$LINT" "$@" 2>&1)"; then
        fail "$label should fail"
    fi
    case "$message" in
        *"checked nothing"*) ;;
        *) fail "$label should say the lint checked nothing: $message" ;;
    esac
    case "$message" in
        *"$1"*) ;;
        *) fail "$label should name the path: $message" ;;
    esac
}

assert_checked_nothing "a missing target" "$TMP/never-created"

# An existing directory holding no Swift file is the same hole with the path still in
# place: the subject moved out from under a name that survives an existence check.
mkdir -p "$TMP/empty"
assert_checked_nothing "a target directory holding no Swift file" "$TMP/empty"

echo "checkpoint off-main lint self-test passed"
