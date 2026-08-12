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

echo "checkpoint off-main lint self-test passed"
