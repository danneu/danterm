#!/bin/bash
# Checks the iOS app runner's public command contract without invoking Apple tooling.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

set +e
OUTPUT="$("$ROOT/scripts/ios-app.sh" invalid 2>&1)"
STATUS=$?
set -e

if [ "$STATUS" -eq 0 ]; then
  echo "ios-app.sh accepted an invalid target" >&2
  exit 1
fi
if [ "$OUTPUT" != "usage: ios-app.sh [simulator|device] [target-id]" ]; then
  echo "unexpected usage output: $OUTPUT" >&2
  exit 1
fi
