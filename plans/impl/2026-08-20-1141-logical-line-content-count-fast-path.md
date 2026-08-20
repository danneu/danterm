# HIST-2: skip the per-cell content-unit walk when the header proves the count

Source: `docs/scratch/2026-08-18-construction-audit.md` finding HIST-2, verified
against `5afabffe` (the quoted code is verbatim; nothing since `33320185` touched it).

## 1. Problem

`Terminal.LogicalLineStore.contentCellCount` (`lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift`)
decodes every cell in its range to classify the kind. The only stored kinds that
are not content units are `.wideTail` and `.spacerHead`, and a record can hold
neither unless its header's `hasWideCells` bit is set. For a record with the bit
clear the answer is `range.count`, so the walk is pure cost. It runs:

- on every eviction step (`evictOneDisplayRow` -> `trimHeadRecord` or
  `dropHeadRecord`), i.e. once per admitted row at steady state on a full scrollback;
- once per earlier record in the block inside `contentRank(of:)`, up to 63 times
  per resolved search coordinate;
- on every tail truncation (`cutTail`).

Four siblings already take exactly this fast path off the same bit with the same
`research/31/DD4` reasoning: `LogicalLineFold.rowCount`, `LogicalLineFold.firstRowCellEnd`
(`LogicalLineRecord.swift`), `LogicalLineStore.foldedRow`, and
`LogicalLineStore.position(ofRecord:cellOffset:)`.

Load-bearing premise (verified): a stored record holds a `.wideTail` or
`.spacerHead` only if `hasWideCells` is set. `appendCells` sets the bit in the
same iteration that stores a `.wideHead`; a `.wideTail` always follows its head
in the same row; `admissionExtent` drops the trailing `.spacerHead` and
`research/31/I1` forbids storing one; the bit is copied on every header rewrite
and never cleared. Today the premise is implicit.

Desired outcome: the content-unit count of a wide-free record costs one header
read, the two derivations of "what does this record contain" (counter and fold)
key off the same bit, and the invariant they share is stated where a future
admission change would break it.

## 2. Decision

Add the fast path to `contentCellCount`: read the record header once and return
`range.count` when `hasWideCells` is false; keep the walk for the wide case.
Unlike the fold siblings, no `width` term belongs in the guard -- content units
are width-free.

State the invariant as a debug assertion at the append site: a stored
`.wideTail` or `.spacerHead` implies the record's `hasWideCells` is already set.

The fast path records no per-cell `Instrument.searchDistanceWork` units. The
instrument's contract is "content units inspected" (`Instruments.swift`), and the
fast path inspects none; the once-per-record unit recorded by `contentRank`'s
loop stays.

Behavioral scope: no public API in `lib/` moves; everything touched is private to
the nested store. No answer changes for any record.

## 3. Invariants

- I1. `contentCellCount` returns the same value for every record and range as the
  full-materialization oracles (`independentContentUnitRecount`,
  `independentContentRank`), wide or not, before and after eviction.
- I2. A stored record never contains a `.wideTail` or `.spacerHead` while its
  `hasWideCells` bit is clear.
- I3. Resolving a nearest-search distance over wide-free history records work
  that does not grow with record length.

## 4. Proof obligations

- PO1 (I1, wide path survives): a store test feeds wide content (copy the
  `RetainedContent.wideClusters` stimulus from `TerminalLogicalLineFoldTests`,
  `String(repeating: "\u{754C}\u{4E16}", count: 3) + "x\(index)\r\n"`) past a
  small budget so eviction trims and drops records holding wide cells, and asserts
  the maintained totals and ranks equal the oracles throughout. No such coverage
  exists today: `contentRanksMatchSearchProjectionUnits` and
  `maintainedTotalsAndContentRanksAgreeWithRecountsAfterEveryMutation`
  (`TerminalLogicalLineStoreTests.swift`) are the safety net but neither combines
  wide cells with eviction.
- PO2 (I3, written first, red today): in `TerminalSearchTests` beside
  `closedHistoryNearestDistanceWorkIsIndependentOfDepthAndGap`, two terminals
  with the same record shape (200 hard-ended lines, two `hit` occurrences at the
  same record indices) but 4- versus 40-character lines; measure
  `Instrument.searchDistanceWork` around `activeSearchMatchRange` with the
  position between the occurrences; both amounts equal and greater than zero.
- PO3 (I2): the debug assertion itself; an admission path that stores a tail or
  spacer without the bit fails the suite rather than miscounting.
- Existing tests that must keep passing and be re-read, not assumed:
  `closedHistoryNearestDistanceWorkIsIndependentOfDepthAndGap` (its recorded
  counts shrink; all assertions are relative), `closedRecordIndexAdvanceAvoidsDisplayProjection`,
  `emptyOpenRecordAtTheSeamNeedsNoSplit`, the whole `TerminalLogicalLineFoldTests`.

## 5. Measurement

`just benchmark-quick baseline=HEAD workload=scrollback-stream`; the number that
can move is the per-arm `drain ... MB/s`. Expect a small effect, possibly under
the 3.5-point A/A floor (short lines, so the head record is ~10 cells). Report it
either way; the change stands on I1-I3, not on the benchmark.

## 6. Non-goals / Accepted risks / Rejected ideas

- Non-goal: `TerminalSearch.swift#recordSearchBoundaryWindow` re-derives a
  record's content-unit count with a full `forEachClosedRecordCell` walk. It is
  bounded by needle length and its boundary term differs; unifying it onto the
  store's counter is a separate, optional change.
- Rejected: storing a per-record content-unit count in the header so every
  contribution is O(1) for wide records too. The header word is full (64 bits,
  `LogicalLineRecord.swift`), so this costs a second header word per record; no
  measured need.
- Rejected: hoisting the chunk pointer and keeping the walk (the audit's
  fallback). Strictly worse than the guard; keep only as the wide-path idiom if
  that walk ever shows up.
- Dependency note: HIST-1 (pending) rewrites `appendCells`; whichever of HIST-1
  and this lands second rebases the one assertion line. No other pending item
  touches `contentCellCount`.

## 7. Verification

1. Write PO2 first; run `swift test --package-path lib/TerminalCore --filter TerminalSearchTests`
   into a file and confirm it fails because the 40-character arm records more work.
2. Write PO1 and confirm it passes before the change (it is characterization).
3. Make the change and add the assertion; both tests pass; run
   `swift test --package-path lib/TerminalCore` in full.
4. `just test` as the gate; `just benchmark-quick baseline=HEAD workload=scrollback-stream`
   and record the drain figure in the commit message.
5. Mark HIST-2 done in the audit checklist with the commit hash, as the other
   landed items do.

## Implementation discretion

- Whether `contentContribution` passes its already-read header down to
  `contentCellCount` or the counter re-reads it.

## Implementation notes

- Per the user's decision, this commit does not update the construction audit or require its
  own commit hash in that file.
