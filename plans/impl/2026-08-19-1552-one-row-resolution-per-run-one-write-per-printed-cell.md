# One row resolution per run, one write per printed cell

FEED-2 and ROW-4 from the construction audit
(docs/scratch/2026-08-18-construction-audit.md), verified current on
2026-08-19 after the charset gate landed on the same path.

## Problem

Two costs sit on the innermost loop of the hot print path in
`lib/TerminalCore/Sources/TerminalCore/Terminal.swift`:

- **FEED-2.** `writeNarrowCells` stores each cell through
  `screen.rows[row].cells[column + offset]`, and `printBulkASCII`'s
  pre-scan reads each cell's kind the same way. Both are two-level
  array subscripts inside a per-cell loop, so every cell pays a
  copy-on-write uniqueness check on the row array and another on the
  cell array. The ASCII-run granularity exists to make everything else
  per-run; this is the one per-cell cost left. `scrollback-stream`
  alone pushes ~1.4 million cells through it.
- **ROW-4.** `printNarrow` calls `clearCellAndPair` at the cursor and
  then `writeNarrowCells` overwrites the same column. For the common
  case (narrow over narrow/padding/spacerHead) the first store is
  dead: an extra `GridCell` construct, an extra two-subscript store,
  and an extra destroy per printed character. The same dead-store
  pattern sits in `printWide` (three calls, all targets overwritten
  immediately after).

The repo already names and fixes this exact cost once: `eraseCells`
carries the COW-cost comment and writes through
`withUnsafeMutableBufferPointer`.

**Load-bearing premises** (verified against the working tree):

- `writeNarrowCells` has three call sites; all three scalar suppliers
  are self-free (two read a caller-owned byte buffer, one returns a
  local; the charset supplier calls `TerminalCharset.translate`, a
  pure switch over a static table).
- Bounds are guaranteed before the loops: `printBulkASCII` checks
  `screen.rows[row].cells.count == columnCount` and cuts `count` at
  `columnCount - column`.
- The effects of `clearCellAndPair` that must survive the ROW-4 split
  all reach *other* cells: `.wideHead` blanks `column + 1`,
  `.wideTail` blanks `column - 1`, and `clearPreviousSpacer` reaches
  the previous row's last column plus the scrollback-seam repair at
  row 0.
- Wide pairs are consistent: a `.wideHead` is always followed by a
  `.wideTail` and a `.wideTail` always preceded by a `.wideHead`.
  D2 needs this, because preparation reads the kind of the cell
  *outside* the range where `clearCellAndPair` read the one inside it,
  and the two agree only under pair consistency.
  `repairHorizontalMove` sweeps after every horizontal move and
  `repairClippedCells` after every resize, so no lone half survives a
  statement boundary.
- The audit's starter kit predates the charset gate (`e0d2e80c`,
  `d61c196e`): `printBulkASCII` now also guards
  `pendingSingleShift == nil` and branches on the active charset
  before choosing a scalar supplier. Neither blocks the change.

## Decision

Two refactors, FEED-2 first (it creates the seam ROW-4's edit lands
on), each a pure refactor with byte-identical grid behavior.

**D1 -- row-cells accessor (FEED-2).** Make "a loop over one row's
cells" a thing `Terminal` vends: a private mutating accessor that
resolves `screen.rows[row].cells` once and hands the loop body a
mutable buffer, plus a non-mutating read counterpart for scans.
Placing the mutating accessor on `Terminal` (not `ScreenState`) is
deliberate: the closure then cannot touch any part of `self`, which is
the by-construction guarantee that the borrow is exclusive. Route
every per-cell loop over a row's cells through it -- `writeNarrowCells`,
`printBulkASCII`'s pre-scan (read form), `eraseCells` (move its COW
comment onto the accessor), `clearPromptCells`,
`repairHorizontalMove`, and `moveAndFillCells` (accessor nests outside
`moveInPlace`). `repairHorizontalMove` holds a `let cells =
screen.rows[row].cells` binding across its write loop today, so its
first repair write copies the whole row; the accessor removes that
copy, which is a second (cold-path) win PO4 should not read as noise. Single-cell reads and single-field row writes stay
open-coded; a buffer accessor makes those worse, and the honest ideal
is "one seam that owns every *loop*", not all 95 subscripts.

**D2 -- prepare a destination range, don't clear cells (ROW-4).** A
print's obligation to the grid before it writes belongs to the whole
destination range, not to each column separately: a wide pair that
straddles the range boundary must stop claiming its partner, and the
previous row's spacer must be cleared once. Express that as a single
range preparation step (`prepareDestination(row:columns:)`-shaped)
that writes only *outside* the range -- it blanks a `.wideHead` at
`columns.lowerBound - 1` and a `.wideTail` at `columns.upperBound`,
and makes the one `clearPreviousSpacer` call. Cells inside the range
are left untouched, because the print path is about to store every
one of them.

Preparation carries today's `clearsPreviousSpacer` flag, because one
caller must not clear: a wide glyph that wrapped off the right margin
wrote the previous row's spacer itself, so preparing its `0..<2`
destination must preserve it. `printWide`'s post-wrap path and
`upgradeClusterToWide`'s two post-wrap calls keep passing false.

Each of the print path's three destination writes (the narrow cell,
the wide head/tail pair, the wrap spacer at the last column) prepares
its own range and then owns its stores, so every printed cell is
stored exactly once. A per-column repair could not give that: printing
a wide glyph onto an aligned wide glyph would sever the old head, and
that sever writes the old tail's column -- which is the new tail's
column too, and gets stored again.

`clearCellAndPair` survives for the caller whose target blank is live
(`upgradeClusterToWide`), reimplemented as prepare-range + blank the
range + optional spacer clear, so there is one spelling of the partner
rule, not two.

Ordering constraint: land D1 before D2.

## Invariants

- **I1.** The refactor is observationally pure: for any fed byte
  stream, at any chunking, the resulting terminal (screen text,
  cursor, viewport cells, scrollback) is byte-identical to before.
- **I2.** Wide-glyph overwrite semantics are unchanged: printing a
  narrow character over a wide head blanks both columns, over a wide
  tail blanks the head, and a spacer before a wrapped wide glyph is
  cleared when column 0 or 1 is written -- including the
  scrollback-seam repair when row 0 is written. The one exception
  stands: the wrapped wide glyph that created the spacer preserves
  it while writing columns 0 and 1.
- **I3.** On the print path, each printed cell's column is stored
  exactly once -- nothing writes inside a print's destination range
  before that range's final stores -- and a row's storage is resolved
  (and its uniqueness proved) once per run, not once per cell.
- **I4.** A declined bulk run must not force a copy of shared row
  storage: the pre-scan is a borrowing read.
- **I5.** Nothing that runs while a row's cell buffer is borrowed
  reads or writes any part of `self` -- the loop body and the scalar
  supplier alike. The supplier keeps running inside the borrow; that
  is what lets it produce scalars lazily instead of materializing
  them into an array first.

## Proof obligations

- **PO1 (I1).** `TerminalASCIIRunTests.runsAreChunkInvariant`
  (`equivalenceScenarios` at every chunking, compared as
  byte-identical terminals) and the full TerminalCore suite pass
  unchanged, before and after each commit. No new test: a test that
  could distinguish the implementations would assert structure, not
  behavior. This net does not reach D2's wide paths -- `printBulkASCII`
  declines every wide character, so both arms of the comparison run
  the same `printWide`. PO2 is what covers D2.
- **PO2 (I2).** Passing unchanged, and named because they are the
  only net over D2's restructured geometry:
  `TerminalTests.wideOverAdjacentPairs` -- its `columns: 2` arm prints
  a wide glyph aligned onto a wide pair, and its `columns: 6` arm
  prints one straddling two pairs, so a preparation that blanks
  neither boundary, or only one, fails it;
  `TerminalTests.wideAtRightEdge` (the preserved wrapped-wide
  spacer); `TerminalGraphemeWidthTests`, `TerminalEditingTests`,
  `CSIEraseTests`, `TerminalStaleWrapClaimTests`. All assert grid
  content through `TerminalGridAssertions` and `expectValidGrid`,
  never structure.
- **PO3 (I3, I4, I5).** Three checks at review; the grep covers only
  the first.
  (a) *(I3, row resolution)* No two-level
  `screen.rows[row].cells[...]` subscript remains inside a per-cell
  loop in Terminal.swift (grep).
  (b) *(I3, write count)* Read the preparation step and each print
  path: preparation writes no column inside the range it is given, and
  each print path issues exactly one store per column of its
  destination range. A grep cannot see a helper writing a destination
  column ahead of the final store, so this half is a reading
  obligation.
  (c) *(I4, I5)* Both scan sites go through a form declared
  non-mutating on `Terminal`, so routing a scan through the mutating
  accessor -- which would force a copy of shared row storage on every
  declined run -- is a compile error, not a review miss. The self-free
  property is read, not compiled: the mutating accessor's placement on
  `Terminal` makes a self-touching closure fail to compile, but the
  non-mutating read form does not, and neither form constrains the
  scalar supplier. Confirm by reading that the loop bodies and all
  three suppliers touch no part of `self`.
- **PO4 (payoff, not a gate).** `just benchmark-quick baseline=HEAD
  workload=terminal-feed` reading `feedDurationNanoseconds`, run per
  commit against the pre-change revision; escalate to
  `just benchmark-confirm` if inconclusive. For D2 also read
  `scrollback-stream`'s per-arm drain MB/s.
  `just benchmark-feed-sample` is the diagnostic if a verdict needs
  explaining (the uniqueness-check frames should leave the
  `writeNarrowCells` stack). Follow
  agent-docs/measurement-discipline.md before acting on any delta.

## Non-goals / Accepted risks / Rejected ideas

- **Non-goal:** giving `upgradeClusterToWide` the one-write-per-cell
  property. Its three sequential `clearCellAndPair` calls re-read
  kinds the earlier calls just blanked, so range-based rewrites there
  need case reasoning a cold path does not earn. It keeps
  `clearCellAndPair` (now the prepare + blank composition).
- **Non-goal:** any change to `GridCell`'s shape or the run predicate
  (ROW-2 / UNI-2 territory; the audit sequences those separately).
- **Accepted risk:** unsafe buffer access turns an off-by-one into
  memory corruption instead of a trap. Mitigated by the existing
  bounds guards at the call sites, the `eraseCells` precedent, and
  PO1's chunk-invariance net.
- **Rejected idea (the deeper ideal, named per the design bar):**
  storing wide glyphs as a head with a width and deriving the tail,
  so a stale partner is unrepresentable and no repair pass exists.
  Rejected here because it changes what a cell is: it touches every
  `.wideTail` consumer (erase expansion, reflow's
  `repairClippedCells`, the packers, the render plan) and the audit
  downgraded its payoff to speculative (ROW-2, wave 5). It stays on
  the table as ROW-2's plan, not this one's.

**Rejected idea:** flat screen storage (one `[GridCell]` with a
`columnCount` stride, `GridRow` reduced to its flags), which would
make the two-level subscript unrepresentable. It removes one COW
check of two -- `Array` subscript assignment still checks uniqueness
per store, so the buffer accessor is still needed afterwards -- and it
turns the row-array rotation `moveAndFillRows` does today into a
memmove per scroll.

## Implementation discretion

- Exact accessor names/signatures, and whether the read form is one
  method or a `withUnsafeBufferPointer` at the two scan sites.
- How `moveAndFillCells` nests the accessor around `moveInPlace`; if
  the borrow genuinely cannot be expressed there, dropping that one
  site from the sweep needs only a note, not a re-plan.

## Verification

1. `swift test --package-path lib/TerminalCore` green before starting
   (baseline), after D1, and after D2.
2. PO4's benchmark runs per commit.
3. `just test` as the final gate.

## Closeout

Final task, after both refactors land: mark FEED-2 and ROW-4 done in
docs/scratch/2026-08-18-construction-audit.md -- check their boxes in
the wave checklists (the `- [ ] **[FEED-2](#feed-2)**` /
`- [ ] **[ROW-4](#row-4)**` entries). Precedent:
`5a79764c docs(audit): mark CHROME-1 done`.

## Commit progress
- [x] 1. D1 -- row-cells accessor (FEED-2)
- [ ] 2. D2 -- prepare a destination range (ROW-4)
- [ ] 3. Mark FEED-2 and ROW-4 done in the construction audit

## Implementation notes

- The accessors hand `body` the buffer pointer by value rather than as
  `inout`. `moveAndFillCells` nests `Self.moveInPlace`'s closure inside the
  borrow, and that inner closure cannot capture an `inout` parameter; a
  by-value buffer pointer writes through the same storage and closes over
  cleanly.
- `repairHorizontalMove` returns early when it found nothing to repair.
  Without that guard, a row needing no repair would still enter the mutating
  accessor, and proving uniqueness there would copy shared row storage --
  a cost the old two-level write loop never paid on an empty repair list.
- D1's benchmark (PO4): `just benchmark-quick baseline=HEAD
  workload=terminal-feed` reports `terminal-feed` 16.92% faster (symmetric
  median of 2 pairs).
