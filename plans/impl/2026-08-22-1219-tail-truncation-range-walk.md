# Make a tail truncation one traversal, and give range reads one walk

Source: HIST-4 in `docs/scratch/2026-08-18-construction-audit.md`, verified
2026-08-22 against `e36bca38`. This is a pivot from the finding's proposal:
the per-row `locate` it names is the smaller half of the waste, and the fix
it implies belongs in one shared walk rather than one more hand-rolled loop.

## 1. Problem

`LogicalLineStore.truncateTail(displayRows:)` (the height-grow and
widen-reflow pull of history back into the live grid) derives every pulled
row's boundary from scratch twice:

- The read pass calls `paintedDisplayRow(at:)` per row, so each row pays a
  `locate` (block binary search plus a scan of up to 63 records) where the
  store's own stated rule is one locate and then `advance`.
- The cut pass calls `removeLastDisplayRow()` per row, and each call folds
  the *whole* tail record from cell 0 (`lastRowRange` ->
  `LogicalLineFold.enumerateRows`, one arena read per cell, no arithmetic
  shortcut). Pulling N rows from one long record is O(N x cells). This fold
  records no instrument, so nothing can see it.

Since `a5b70a2b` (HIST-3) a `DisplayRowCursor` carries exactly what the cut
pass re-derives: the row's cell range and its position within the record.
A tail cut never moves an earlier row's boundary, so the cursors the read
pass produces are valid for the cut pass.

The same per-row-locate loop exists in two `Terminal.swift` readers
(`encodeStateSynchronization`, whole history; `presentedRows`, one
viewport), while `primaryProjectionRows` and `allPaintedDisplayRows` each
hand-roll the correct walk. "Which reads may spend a locate per row" is a
per-call-site judgement today.

Evidence: the loop is unchanged since `9ad7cc55`; HIST-3, HIST-1, STORE-3
and STORE-5 (HIST-4's stated prerequisites) are all committed; no wip plan
touches this path. No ladder workload resizes, so the win is by
construction, not by benchmark (see AR1).

## 2. Decision

D1. `truncateTail` locates the first pulled row once, advances through the
range collecting each row's painted cells and its cursor, then cuts from the
back using those cursors: a row that is its record's first row drops the
record; any other row cuts the record down to that row's start. The cut
pass folds nothing.

D2. The store grows one range read -- every painted display row in a
half-open range, oldest first, walked as one locate plus advances. It is the
single implementation behind the whole-history read, `truncateTail`'s read
pass, `primaryProjectionRows`' mid-history case, `encodeStateSynchronization`
and the retained part of `presentedRows`.

D3. Any row-boundary fold that starts at a record's first cell records
`Instrument.rowBoundaryCellWalk` (that is the instrument's stated meaning;
`lastRowRange` does not record it today). `lastRowRange` keeps its
`setWidth` caller and stops serving truncation.

Scope: `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift`,
`lib/TerminalCore/Sources/TerminalCore/Terminal.swift`, their tests, and the
HIST-4 checklist line in the audit (mark done with the commit hash, as the
other items are).

## 3. Invariants

I1. `truncateTail(displayRows: n)` spends exactly one display-row locate for
the whole pulled range, independent of `n` and of history depth.

I2. The cut pass of a truncation performs no row-boundary fold over record
cells: pulling `n` rows out of one record costs one row-boundary walk
through that record, not `n`.

I3. The rows `truncateTail` hands back are, cell for cell, the rows an
indexed read of the same display rows returned before the cut -- across a
record boundary, a forced-split seam, a wide record whose last column is a
deferred spacer, and a trimmed head -- and the rows cut are exactly the rows
handed back (the grand row total drops by the handed-back count).

I4. Truncate-and-readmit remains a no-op on retained content and arena
charge (the existing round-trip property), for multi-row pulls too.

I5. Every range read of retained painted rows spends three separately
countable things: at most one locate for the whole range, at most one
row-boundary walk through each record the range touches (the walk the
opening locate already pays inside the first record counts as that record's
one walk), and one painted-cell visit for each cell it returns.
`stateSynchronization(historyBudgetBytes: nil)` and `viewportText` over a
deep history cost the same locates and the same boundary walks as over a
shallow one.

I6. Indexed single-row reads keep their meaning: `paintedDisplayRow(at:)`,
`scrollbackRow(at:)`, the projection subscript and `viewportStreamRow(at:)`
still answer one row with one locate.

## 4. Proof obligations

PO1 (I1). One locate per truncation, with a `>= 1` calibration guard so a
disconnected counter cannot pass. Fixture spans a record boundary, a
forced-split seam and a wide record. Fails today at `n` locates.

PO2 (I2, D3). Boundary-walk count for an `n`-row pull from one wide record
is exactly one, for every `n` the record spans. Needs D3 first so the test
fails for the expected reason today.

PO3 (I3). Handed-back rows equal the pre-cut indexed reads for each named
shape; the store's row total drops by exactly the handed-back count. The
existing exact-row truncation tests (`TerminalLogicalLineStoreTests` at the
record-boundary, forced-split, pending-margin and wide-spacer cases;
`TerminalLogicalLineFoldTests` height-grow) pass unchanged.

PO4 (I4). The existing truncate-and-readmit round trip, plus one multi-row
variant over wide and forced-split records.

PO5 (I5). Locate count and boundary-walk count are both depth-invariant
(shallow vs deep, same shape as
`TerminalFrameLocateTests.locatesForOneFrame`) for `stateSynchronization(
historyBudgetBytes: nil)` and for `viewportText` scrolled to the top of
history, each calibrated by the row count the read returns; the boundary-walk
count also equals the number of records the range touches.

PO6 (I6). Existing indexed-read tests pass unchanged; no new test.

## 5. Non-goals / Accepted risks / Rejected ideas

Non-goals:
- Backward walkers (`boundedHistoryStart`, `alignedHistoryStart`) -- there
  is no backward cursor step and these read a few rows.
- Changing indexed single-row readers or the search/selection paths that
  address rows by index on purpose.
- A benchmark claim.

Accepted risks:
- AR1. No ladder workload or probe exercises resize, so no number moves;
  the proof is the locate and boundary-walk counts, not time.

Rejected ideas:
- RI1. Give `lastRowRange` a narrow-record arithmetic shortcut and keep
  the per-row cut: keeps two derivations of one boundary when the cursor
  already holds it, and leaves the wide-record O(n x cells) in place.
- RI2. Fix only `truncateTail` and leave the `Terminal.swift` loops: the
  store's traversal rule would still hold at most call sites rather than
  all, which is the per-site judgement the finding set out to end.

## 6. Implementation discretion

- Whether the range read records `Instrument.retainedRowMaterialization`
  for partial ranges or only the whole-history entry point does; whichever
  is chosen, the instrument's doc comment says so and the existing `== 0`
  proofs (census, reclamation sweeps) keep holding.
- Whether the pulled rows' pending-margin and wide-wrap margin resolution
  stays in `truncateTail` or moves with the read; behavior is pinned by
  PO3.

## Verification

`swift test --package-path lib/TerminalCore --filter TerminalLogicalLineStoreTests`
and `--filter TerminalFrameLocateTests` in the loop; `just test` before the
commit. No app launch needed: every claim is an instrument count or an exact
row comparison.

## Commit progress

- [x] 1. perf(core): count the record-start row-boundary fold
- [ ] 2. perf(core): make a tail truncation one traversal
- [ ] 3. perf(core): give retained-history range reads one walk
