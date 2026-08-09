#!/usr/bin/env bash
# Research doc 33, task T16: prove direct arena live-id walks preserve the old result and
# reclamation no longer reaches retained-row materialization.

set -euo pipefail

root=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$root"

swift test --package-path lib/TerminalCore \
  --filter 'packedLiveIdsEqualPaintedRows|reclamationSweepsMaterializeNoRetainedRows'

terminal=lib/TerminalCore/Sources/TerminalCore/Terminal.swift
if sed -n '/private func liveStyleIds/,/private mutating func reclaimDeadStyleEntries/p' \
    "$terminal" | rg 'allPaintedDisplayRows' \
  || sed -n '/private func liveHyperlinkIds/,/private mutating func reclaimDeadHyperlinkTargets/p' \
    "$terminal" | rg 'allPaintedDisplayRows'
then
  echo 'FAIL: a reclamation live-set walk still materializes retained rows' >&2
  exit 1
fi

echo 'PASS: packed live sets equal painted rows; retained rows materialized per sweep: 0'
