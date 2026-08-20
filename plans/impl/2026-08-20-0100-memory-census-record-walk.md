# Memory census prices history by walking records

## Context

`Terminal.memoryCensus` (`lib/TerminalCore/Sources/TerminalCore/Terminal.swift#memoryCensus`)
prices retained history by calling `history.store.allPaintedDisplayRows()`:
one `GridRow` with its own `[GridCell]` allocation per retained display row
(~6,756 rows at the production budget), concatenated with a flattened copy of
both screens. This runs inside the memory probe's measured window
(`TerminalMemoryProbeSupport#measure` reads `processPhysicalFootprintBytes()`
right after the census), and `settleAllocator()` is inert on macOS 26, so the
transient rows land in the footprint delta the probe attributes to retained
cost -- the instrument perturbs the quantity it measures. Audit item HIST-5 in
`docs/scratch/2026-08-18-construction-audit.md`.

The audit left one decision open: do the per-cell census fields keep counting
*painted* cells (fold output: trailing fill and spacer heads included,
width-dependent) or become counts of *stored* cells (arena content,
width-free)? Pricing against every consumer settled it -- **stored cells**:

- The census's own contract already says stored. `TerminalMemoryCensus.cellCount`
  is documented "Cells physically stored across the whole grid"; the
  `censusReportsCompactRetainedRows` test intent says the census "must report
  the storage actually held". The painted count contradicts both.
- No consumer needs painted. `bytesPerCell` divides stored bytes by the
  painted count today (synthesized cells deflate it); `OccupancyReport.cellCount`
  is descriptive; the retained-row probe cross-checks only arena fields.
- The painted fold also *double-counts* a real stored cell at forced-split
  seams and lets spacer heads inherit the head's style/link/identity, so the
  painted numbers were never a coherent census of anything.
- `research/31/R16` already names the target shape: census as a walk of records.

## Decision

Redefine the retained half of the four per-cell census fields (`cellCount`,
`styledCellCount`, `hyperlinkCellCount`, `contentIdentityCellCount`) as counts
over stored cells, and reimplement `memoryCensus`'s history pricing as a
per-record walk of the store -- no whole-history materialization. Live-screen
counting is unchanged. Independently, reorder `TerminalMemoryProbeSupport#measure`
so the closing allocator settle, heap snapshot, footprint read, and the
`whileResident` hook (which is where `vmmap` samples the process) all run before
`terminal.memoryCensus`, with the terminal still alive. The terminal does not
change between the samples and the census, so the census still describes the
sampled state, and no future census implementation can contaminate it. The hook
takes no census argument once it runs first; its only caller ignores that
argument today.

Store reads to build on (`lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift`):

- `forEachStyleId` -- already covers every record including the open tail and
  emits the per-record trailing fill style separately; its loop shape (cell
  words via `CellWord`, chunk hoisted per record) is the template.
- `forEachHyperlinkId` -- already correct, including the open branch over
  `openHyperlinks` and the `retainedStart` window on a trimmed record 0.
- The spill bit: `CellWord.isSpilled` is exactly "multi-scalar", for open and
  closed records alike, so no `TerminalScalars` materialization is needed and
  `forEachClosedRecordCell`'s open-record gap does not have to be worked around.
- Content identities are the one missing read: a new store walk mirroring the
  private `contentIdentity(record:at:keyOffset:)` decoder (per-cell u32 table
  vs run entries behind `record.identityPerCell`; `openIdentityRuns` for the
  tail; side-table keys are pre-trim coordinates, clipped to the retained
  window as `forEachHyperlinkId` does).

`recordSummary(at:)` folds a display-row count per record, so the existing
`retainedStoredCellCount` loop should also be absorbed into the record walk.

## Invariants

- I1: Every retained per-cell census term counts stored cells only -- cells
  occupying arena words, open tail record included. Fold-synthesized cells
  (trailing fill, deferred spacer heads) and the forced-split seam duplicate
  are not counted. A wide cluster counts as its two stored cells (head + tail).
- I2: `cellCount` equals the live screens' cell count plus
  `retainedStoredCellCount`; its retained half is width-free (a resize moves
  `scrollbackRowCount` but not `cellCount`).
- I3: Must-not-move set -- byte-identical to today for any fixture: every
  arena-denominated field (`retainedStoredCellCount`, `retainedArenaBytesInUse`,
  `retainedArenaCapacityBytes`, `retainedIndexBytes`, `retainedSideTableBytes`,
  `cellStorageBytes`, and derived `retainedChargedBytes` /
  `retainedBytesPerStoredCell`), plus `distinctStyleCount`,
  `distinctContentIdentityCount`, `multiScalarCellCount`,
  `multiScalarAllocationCount`, `scrollbackRowCount`, `scrollbackRecordCount`,
  `screenRowCount`, `rowStorageAllocationCount`.
- I4: `memoryCensus` materializes zero retained display rows
  (`Instrument.retainedRowMaterialization` reads 0 across a census).
- I5: The trailing fill style still enters `distinctStyleCount` but contributes
  nothing to `styledCellCount`.
- I6: Docs state the semantics where readers will meet them: the field docs for
  all four redefined counts in `TerminalMemoryCensus.swift` (`cellCount`,
  `styledCellCount`, `hyperlinkCellCount`, `contentIdentityCellCount`), each
  saying the same stored-cell retained-history semantics, and the type-level
  comment that still says "whole grid"; the
  `memoryCensus` doc comment (currently "Walks the whole grid" / "O(cells)"),
  and one sentence in `agent-docs/terminal-performance.md` saying the retained
  per-cell counts are stored-cell counts and width-free.
- I7: The probe's closing heap, footprint, and `vmmap` samples are taken before
  `memoryCensus` runs, so census-internal allocation cannot enter the footprint
  delta the probe reports. This is the invariant that makes the instrument
  honest; the record walk only lowers how much it would have cost to violate.

## Proof obligations

- PO1 (I4): New test in `TerminalMemoryCensusTests`, written first and failing
  today: deep history, then `Instrument.retainedRowMaterialization.measure { _ = terminal.memoryCensus } == 0`.
  Precedent: `TerminalStyleTableTests#reclamationSweepsMaterializeNoRetainedRows`.
  Note its honest scope: it proves no whole-history materialization, not that
  the record walk landed -- the census-value tests carry that.
- PO2 (I1, I5): `coloredErasePaddingIsNotCompacted`'s census assertion moves
  from `8 + 8` to `8 + 3`; its history-visibility assertions
  (`scrollbackRow(at:)` fill cell present, styled red) stay unchanged. The same
  scenario also asserts both style fields: the fill's style is counted in
  `distinctStyleCount`, and no synthesized fill column contributes to
  `styledCellCount`.
- PO3 (I1): The counted terms are proved present for the shapes most likely to
  silently read zero: an open tail record's styled/spill/hyperlink/identity
  cells; content identities under both encodings (contiguous run vs fragmented);
  a head-trimmed record 0. Undercount-reads-as-zero is the failure mode
  `agent-docs/measurement-discipline.md` warns about, so presence is asserted,
  not assumed.
- PO4 (I2, I3): The existing suite is the safety net and must pass unchanged:
  `TerminalMemoryCensusTests` (all but the PO2 line), `TerminalResetTests`,
  `TerminalMemoryProbeSupportTests` (notably `cellStorageIsExact`,
  `unicodePayloadSpills`, `chunkedFeedMatchesSingleShotFeed`,
  `matrixIsDeterministic`), `TerminalPackedRetainedRowTests`,
  `TerminalRetainedRowProbeSupportTests` (`derivationMatchesCensus`).
- PO5 (I7): The ordering is a structural contract, not a runtime assertion, and
  the plan adds no seam to assert it: `whileResident` loses its
  `TerminalMemoryCensus` parameter, so nothing on the sampling path can depend on
  census output, and the samples read plainly as preceding the census. The
  existing `TerminalMemoryProbeSupportTests` must pass unchanged, proving the
  reorder moves no reported census value. The probe runs
  (`just terminal-memory-probe --payload scrollback-plain` and
  `--payload scrollback-mixed`) are descriptive evidence only: report the
  footprint delta, confirm every I3 field is byte-identical, and confirm the four
  redefined fields move only down or stay equal. A single pre/post footprint pair
  is not a pass/fail gate -- `agent-docs/measurement-discipline.md` rejects a
  two-point comparison with no contemporaneous control, in both directions: a
  non-falling sample would reject a correct change, and a falling one would not
  establish cause.
- PO6 (I1, I2): The exclusions that separate stored from painted semantics are
  proved by behavior, because an implementation can keep half the fold and still
  pass every test above. Behavioral scenarios assert stored counts across a
  deferred spacer and across a forced-split seam (the seam head is counted once,
  not twice), that a wide cluster contributes two cells, and that `cellCount` is
  unchanged across a resize that moves `scrollbackRowCount`.

## Non-goals / Rejected ideas

- RI1: Painted semantics with a streaming fallback (walk
  `paintedDisplayRow(at:)` one row at a time). Rejected: removes the peak but
  keeps the width-dependent fold, the seam double-count, and the contradiction
  with the census's documented contract; no consumer needs the painted number.
- RI2: INTERACT-1's history-access wrapper rename is out of scope; if both
  land the same week, this lands first (it changes what the census reads,
  INTERACT-1 only how it is spelled).
- Non-goal: no change to `bytesPerCell`'s formula (its denominator becoming
  stored cells is what makes it coherent), to arena accounting, or to any
  probe's reported fields. The `whileResident` hook does lose its census
  argument (I7), which is a call-signature change, not a reporting change.

## Implementation discretion

- Whether the census composes the existing reads (`forEachStyleId`,
  `forEachHyperlinkId`, plus the new identity walk) or adds one unified
  per-record cell-word walk; naming and shape of the new store read(s).
- Sequential table decode vs per-cell binary search inside the identity walk.

## Verification

- TDD order: PO1's instrument test first (red), then the walk, then the PO2
  expectation change and the PO3 / PO6 additions. The probe reorder (I7) is
  independent of the walk and can land first or last.
- `swift test --package-path lib/TerminalCore --filter TerminalMemoryCensusTests`,
  then `--filter TerminalMemoryProbeSupportTests`, then the full
  `swift test --package-path lib/TerminalCore`; `just test` as the gate.
- PO5's probe runs, comparing against a pre-change run of the same payloads,
  recorded as evidence rather than treated as the gate.
- Mark HIST-5 done in the audit checklist in the closing chore commit, per the
  existing `chore(audit)` pattern.

## Commit progress

- [x] 1. Count retained census fields by walking stored records
- [x] 2. Sample probe memory before census and close HIST-5
