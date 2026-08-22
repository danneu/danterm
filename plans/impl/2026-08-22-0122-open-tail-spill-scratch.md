# Hold the open tail's spills in scratch, not in the closed-record table

Source: HIST-1 in `docs/scratch/2026-08-18-construction-audit.md`, pivoted to
its spill half per the audit's own Correction. The header half is rejected
below (RI1).

## 1. Problem, evidence, premises

**Problem.** The open tail record's multi-scalar spill payloads live in
`SequenceKeyedSideTables.spillsBySequence`, the dictionary that otherwise
holds only closed records. Each admitted row that stores a spill reads the
record's whole spill array out of the dictionary, appends, and writes it back
(`LogicalLineStore.swift` `appendCells`, `:2797`/`:2873`); the write path
re-prices the whole array twice (`setSpills` -> `spillCost`, `:404-413`,
`:483-492`), and the append copy-on-writes the outer array because the
dictionary still references it. A logical line that accumulates S spills pays
O(S) per spill-bearing row and O(S^2) per record, up to the 65,536-cell forced
split cap. Tail truncation (`cutTail`, `:1262-1265`) repeats the same
read-modify-write.

**Evidence.** The quoted code is live on `master` (`9b958843`). The open
tail's other side tables already live in scratch (`openHyperlinks`,
`openIdentityRuns`, `:334-336`) and are flushed once at close
(`flushOpenTables`, `:2884`) and reloaded on reopen (`loadOpenScratch`,
`:2928`); spills are the one open-record table that does not follow that
design.

**Premises.**
- P1: spills are addressed by position in the record's spill array
  (`CellWord.spillIndex`), so a head trim never renumbers them
  (`trimHeadRecord` leaves leading dead entries, `:1040-1067`); moving the
  open array does not change any index.
- P2: the open tail is always the last record; the only path that drops it as
  the *head* record is the single-record case, which resets the arena and
  clears the open scratch (`dropHeadRecord` -> `resetToEmptyArena`,
  `:1101-1104`, `:1120-1128`).
- P3: `chargedBytes` (`:643`) is the single quantity `31/I2` bounds; the open
  scratch already contributes to it (`openScratchBytes`, `:683`) and to
  `census.sideTableBytes` (`:662`).

**Outcome.** Admission work per row is independent of how many spills the
open line already holds, the quadratic is unrepresentable, and every reader
still sees every spill.

## 2. Decision

D1: the open tail's spills are one scratch array beside `openHyperlinks` /
`openIdentityRuns`, with the same lifecycle: appended in place during
admission, trimmed by tail truncation, written into the sequence-keyed table
exactly once when the record closes (close or forced split), moved back out
of the table when a closed tail reopens (either reopen path), and cleared
wherever the other open scratch is cleared. The sequence-keyed spill table
holds closed records only.

One home means one allocation: close and reopen *transfer* the outer
spill-array storage between scratch and the table rather than copying it, so
neither side keeps a duplicate buffer. Unlike `openHyperlinks` /
`openIdentityRuns`, the spill scratch is not cleared with retained capacity
after a flush -- a retained 65,536-entry outer array would be a charged
megabyte of dead scratch.

Behavioral scope: storage-internal. No public API, CLI, or on-screen change.

The header half of HIST-1 (a decoded open record in scratch, arena header
written once at close) is out of scope -- RI1.

## 3. Invariants

- I1: every spill payload of the open tail reads back through every reader
  that decodes cells -- `displayRow`, `paintedDisplayRow`, `recordCells`,
  `LogicalLineStore.==`, and the renderer's own borrowed-cell path
  `withPaintedCells` (`:2098-2107`), which reads the spill table directly and
  is not reached through any of the others -- exactly as it does for a closed
  record, at every point in the record's life: while open, after close, after reopen, after a
  forced split, after a tail truncation.
- I2: the sequence-keyed spill table never holds an entry for the open tail;
  the open scratch holds no spills when no record is open, and no leftover
  spill-array allocation either.
- I3: the charge invariant holds unchanged -- `chargedBytes` includes the open
  spills' bytes, `census`'s recount agrees with the maintained side-table
  charge, and `chargedBytes <= capacityBytes` after every admission -- and
  maintaining that charge does not walk the open spills per row.
- I4: admission work per row does not grow with the number of spills the open
  line already holds (the quadratic is gone), and neither does tail
  truncation's per-row work.
- I5: two stores fed identical rows compare equal, and a difference in one
  open-tail spill payload makes them unequal.

## 4. Proof obligations

- PO1 (I1, I5): an open line of many soft-wrapped rows, each carrying a
  multi-scalar cluster, reads back every cluster while still open, after
  close, after `reopenTailRecord` + another spill row + close, and after a
  forced split with spills on both sides of the cut. Readback runs through
  `withPaintedCells` (via its `forEachPaintedCell` test seam) as well as the
  `GridRow` readers, at each of those points. Two stores fed the same
  sequence are `==`; varying one open-tail spill makes them `!=`. Existing
  oracles must keep agreeing: `independentDisplayRowRecount()`,
  `independentContentUnitRecount()`, `census`.
- PO2 (I1, I2, P1): `truncateTail` over rows that hold spills on an open tail,
  and on a closed tail that truncation reopens, followed by further spill rows,
  reads back correctly -- the spill indices stay continuous. Separately, a head
  trim on an open record that drops one spill-bearing row while another
  survives, then admits a third spill row, reads back the surviving and the new
  payloads: cell words keep their original spill indices, so the open array is
  never trimmed or rebased at its head (P1).
- PO3 (I3): a long open line of spill rows at a small budget keeps
  `chargedBytes <= capacityBytes` and passes `census`'s recount assertion;
  `sideTableChargeDecidesRetentionDepth` and `spillTableChargesWhatItAllocated`
  are re-run deliberately (the open scratch's allocation is now charged, so a
  pinned depth may move by a row and must be re-justified, not silently
  re-pinned). One scenario proves I2's single-allocation half, inside a single
  store and against its own earlier state. Admit a large multi-row record that
  holds exactly one spill in the whole record; close it, evict it, leave a plain
  suffix so the store stays non-empty, and read `census.sideTableBytes`. Then
  admit a record identical in length and in every non-spill attribute but
  carrying a spill on every row, close it, reopen it, close it again, evict it,
  and read the charge again. The two readings must be
  equal. Round one has already grown the retained identity-run scratch and the
  spill dictionary's bucket storage to their steady size -- both survive
  eviction by design (`spillTableChargesWhatItAllocated`) -- so the only term
  that can differ in round two is a spill buffer left behind in scratch, which
  `openScratchBytes` charges by array *capacity* (`:683`).
- PO4 (I4): a work-shape proof in the repo's `Instrument` idiom
  (`closedHistoryNearestDistanceWorkIsIndependentOfDepthAndGap` is the model):
  recorded spill work for admitting one spill row is the same whether the
  open line already holds 1 or ~1,000 spills. Wall-clock is not a proof
  (`agent-docs/test-timing.md`).
- PO5 (P2): a single-record store whose open tail is evicted to empty, then
  fed a new spill line, reads back only the new line's spills.

## 5. Non-goals / Accepted risks / Rejected ideas

- NG1: no benchmark gate. No calibrated workload feeds sustained
  multi-scalar clusters (`just benchmark-quick` cannot see this path); the
  proof is PO4, not a number.
- NG2: the per-row header decode count on the admit path (8-9 per row) is
  untouched here. A decode-once-and-thread pass through `admit` is a separate,
  optional item.
- AR1: readers of the open tail gain one branch (open -> scratch, closed ->
  table), the same shape `hyperlinkId`/`contentIdentity` already have. The
  risk is a reader that forgets the branch; PO1/PO2 cover every reader,
  `withPaintedCells` included (I1).
- RI1: HIST-1's header half (open record decoded in scratch, arena written
  once at close). Rejected: the header slot must still be reserved at open, so
  the arena keeps a placeholder anyway; every tail reader and five mutating
  operations plus both reopen paths gain an "is this the open tail" branch;
  and the audit's own measurement section concedes the win sits under
  scrollback-stream's A/A floor. State it on its own merits if it recurs.

## 6. Implementation discretion

- Whether PO4's counter is a new `Instrument` or an existing one repurposed.
- How the open spills' charge is maintained incrementally (I3 fixes the
  contract: charged, recount-consistent, no per-row walk).

## Files

- `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift` -- open
  scratch declaration and charge (`:328-336`, `:683`), `appendCells`,
  `cutTail`, `closeOpenRecord` / `forceSplitOpenRecord` /
  `flushOpenTables`, `reopenClosedTail` / `loadOpenScratch`,
  `clearOpenScratch`, the three spill readers (`:2098-2107`, `:2620-2623`,
  `==` at `:1897-1902`).
- `lib/TerminalCore/Tests/TerminalCoreTests/TerminalLogicalLineStoreTests.swift`
  -- PO1-PO3, PO5; PO4 lands here or beside the `Instrument` tests in
  `TerminalSearchTests.swift`.
- `lib/TerminalCore/Sources/TerminalCore/Instruments.swift` only if PO4 needs
  a new counter.

## Verification

1. Red first: PO4's work-shape test fails on `master` (work grows with the
   spills already held); PO1's open-tail readback passes today and must keep
   passing.
2. `swift test --package-path lib/TerminalCore --filter TerminalLogicalLineStoreTests`
   and `--filter TerminalSearchTests` into a file; grep for failures.
3. `just lint`, then `just test` before commit.
