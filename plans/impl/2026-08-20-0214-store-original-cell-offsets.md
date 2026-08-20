# STORE-4: one key base for the open tail's scratch tables

Implements STORE-4 from `docs/scratch/2026-08-18-construction-audit.md`.
Lane E: this lands in `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift`
before HIST-2 and HIST-3; HIST-1 unblocks on it. The audit's "decide first"
question is decided: the typed one-field `OriginalCellOffset`, not a
comment-plus-rebase and not the precondition fallback.

## Problem

A cell offset that keys a record's side tables (hyperlink entries,
content-identity runs) has two possible bases: **original** -- the offset the
cell had when first written, which a head trim never rebases (the rule stated
on `LogicalLineRecord.identityEntryCount`) -- and **retained** -- the offset
among the cells still held, which a head trim rebases by `headTrimmedCells`.
Nothing in the types says which base a given `Int` carries, and the sites
disagree:

- `appendCells` keys new scratch entries at `record.cellCount + index` --
  retained base, because `trimHeadRecord` decrements `cellCount`.
- `cutTail` bounds the scratch against a retained-base cell count.
- `loadOpenScratch` refills the scratch original-base from the arena, and the
  readers (`cell(recordIndex:...)` adding `headTrimmedCells` for record 0,
  then `hyperlinkId`/`contentIdentity` binary-searching) query original-base.

The bases diverge exactly when the open record is also the head record and has
been trimmed (`offsets.count == 1`, `headTrimmedCells > 0`). That state is
reachable: `makeRoom` calls `evictOneDisplayRow` when it cannot find
contiguous room, and `evictOneDisplayRow` trims the sole open record through
`trimHeadRecord` with no guard. Once there, new appends write keys that
collide with surviving originals, the scratch stops being key-sorted (the
binary searches assume it), and cells read back nil or another cell's
hyperlink id / content identity.

**Verified divergence from the audit's starter kit.** The kit claims
`flushOpenTables` "becomes correct by construction" once the scratch is
original-base. True for the hyperlink and run encodings (they write the key
value through), false for the per-cell identity branch, which is positional:
it zero-fills `0..<record.cellCount`, guards writes by `run.start + step <
record.cellCount`, and stamps `identityEntryCount = record.cellCount` -- all
retained-base sizes. The closed-record reader indexes per-cell tables by
original offset and bounds by `identityEntryCount`, which is documented as the
original count. So closing (or force-splitting) a record that was trimmed
while open must write a per-cell table sized to the original count, and the
encoding choice plus `projectedTableBytes` must price that size.

**Second verified consequence: the reservation, not the key width.**
`projectedTableBytes` sizes the per-cell identity branch from
`openRecordCellCount` -- the retained count. That is the number the seam test
uses to keep "close the open record here" a move that always fits. Once the
flush writes an original-sized per-cell table, a trimmed-then-regrown open
record reserves less than it will write, so closing it near a region end
writes past the reserved room. The projection has to price the original span
too.

**The 16-bit key fields are not at risk.** A record never straddles a backing
chunk, chunks are capped at 512 KiB (`maximumChunkByteShift`), and the 8-byte
header sits inside that region, so one record's physical extent holds fewer
than 65,536 cells at any budget. A head trim moves the header forward but
never moves the physical end, and original offsets are measured from the
original cell base, which stays inside the same region. The existing seam
split therefore bounds every key and run extent below `UInt16.max` already.

## Decision

Introduce a one-field `OriginalCellOffset` struct, private to
`LogicalLineStore`, and give it to everything that stores or takes a
side-table key: `HyperlinkEntry.offset`, `IdentityRun.start` (`extent` stays a
plain count), the `keyOffset` parameters of `hyperlinkId`/`contentIdentity`,
the `cutTail` bound, and `forEachHyperlinkId`'s retained window. One private
accessor is the sole meeting point of the two bases: it converts a
retained-relative offset in a given record to its original key (add
`headTrimmedCells` for record 0, else 0). `appendCells`, `cutTail`,
`cell(recordIndex:...)`, and `forEachHyperlinkId` obtain keys through it;
`loadOpenScratch` and the closed-branch readers wrap arena-read values
directly, because in-arena keys are already original-base.

By construction: passing a retained-relative `Int` where a key is expected
stops compiling. That is what retires the defect class -- the file holds nine
hand-written `headTrimmedCells` conversions, and without the type each remains
free to feed the wrong base into a key parameter.

Decisive constraints (set by the user; do not reopen):

- **C1.** The type stays inside `LogicalLineStore`. `RecordTextPosition.cellOffset`
  remains `Int`, and the sites serving that boundary (`recordTextPosition`,
  `position(of:)`, `contentRank`, `independentContentRank`,
  `closedContentUnitTotal`, `closedRecordScan`, the `recordsEqual` trim
  branch) keep their `Int` conversions. Crossing the boundary inflates the
  change toward seventeen sites and puts a wrapper inside a coordinate whose
  two-word storage `recordCoordinateStaysTwoWords` pins.
- **C2.** No `precondition(headTrimmedCells == 0 || offsets.count > 1)` in any
  form. The state it would trap on is legitimately reachable (see Problem),
  so it would convert a latent misread into a live process trap, and PO1's
  test would trap instead of fail.
- **C3.** No arena rebase in `trimHeadRecord`. Original keys exist to keep
  coordinates stable across a trim (`recordCoordinateSurvivesHeadTrim`), and
  rebasing costs per-eviction work proportional to the identity table.

## Invariants

- **I1.** Every side-table key -- open-tail scratch and in-arena, hyperlink
  and identity, run and per-cell encodings alike -- is an original-base cell
  offset, in every state including a head-trimmed open record.
- **I2.** Retained-to-original conversion happens at exactly one place in the
  store; every other site either carries the type or (per C1) converts for the
  `RecordTextPosition` boundary only.
- **I3.** A closed per-cell identity table is indexed by original offset and
  sized and bounded by the record's original cell count
  (`identityEntryCount`), including when the record was trimmed while open.
  The per-cell-versus-runs encoding choice and the table-byte reservation
  price that size, on both close and forced split.
- **I4.** The scratch arrays stay key-sorted: original-base keys are
  append-monotone even across a trim, restoring the ordering the binary
  searches assume.
- **I5.** Behavior in every untrimmed configuration is unchanged: zero edits
  to existing tests.

## Proof obligations

All in `TerminalLogicalLineStoreTests` (suite "Logical-line record arena"),
spec-first. TDD order: PO1's test is written first and must fail for the
predicted reason before any store change. The audit's safety net must stay
green unmodified: `sideTablesSurviveEveryRecordOperation`,
`truncatingIntoAForcedSplitRecordKeepsItsSideTablesReadable`,
`fragmentedIdentityFallsBackPerCellWithoutLoss`,
`equalitySeesEverySideTableValue`, `headTrimPreservesHeadRecordIdentity`,
`recordCoordinateSurvivesHeadTrim`, `recordCoordinateStaysTwoWords`,
`contentRanksUseOnlyBlockMetadata`,
`maintainedTotalsAndContentRanksAgreeWithRecountsAfterEveryMutation`,
`trimmedHeadReadsAsAContinuation`,
`trimmedHeadOfAnUnmarkedLineCarriesNoMark`, `headTrimKeepsTheTrailingFill`.

- **PO1** (I1, I4) -- an open line head-trimmed while open keeps the hyperlink
  and identity of every cell printed after the trim. Budget `1 << 16`, width
  4; admit two soft-wrapped rows of cells stamped `hyperlinkId: 7` and
  stepping `contentIdentity` (record 0 open with 8 cells); call
  `evictOneDisplayRow()` once (trims 4; `headTrimmedCells == 4`); admit one
  more such soft-wrapped row; `recordCells(at: 0)!` has 8 cells, each with
  `hyperlinkId == 7`, identities the contiguous run the admissions supplied.
  Fails today: the new entries are keyed 4..7 (retained base) where the
  surviving originals already sit, so the new cells read back nil and the old
  cells answer for their offsets.
- **PO2** (I1 across a close, run encoding) -- PO1's setup, then a hard-ended
  row so the record closes; every retained cell reads back the same hyperlink
  and identity through the closed-record path. Also fails today (the flush
  writes the mixed keys through).
- **PO3** (I3, per-cell encoding, and `loadOpenScratch`) -- the trim-while-open
  setup with fragmented identities (alternating identity and none) so the
  flush picks the per-cell encoding; after close, every retained cell reads
  back its identity; then reopen through a tail truncation (drives
  `loadOpenScratch`'s per-cell reconstruction), append again, and the reads
  still agree.
- **PO4** (I3, reservation) -- a near-seam version of PO3. Trim a fragmented
  open head, then keep admitting until the region's physical end forces the
  record closed at the seam. Every retained cell still reads back its identity
  and hyperlink, and no admission traps or corrupts the record that follows the
  seam. Fails when the flush is corrected to the original span but
  `projectedTableBytes` still prices the retained one: the close writes past
  the room the seam test reserved. Choose the budget so the seam is reached by
  a small number of admissions.

## Non-goals

- HIST-1 (moving the open tail's header and spills into the open scratch)
  builds on this item and is not started here.
- Pruning stale scratch entries when an open head is trimmed. Entries keyed
  below the trim base stay in the scratch and get flushed into the closed
  table. They are unreachable to every reader -- exact-match and windowed
  reads all query at or above the base -- and cost only bytes. **Accepted
  risk**: a bounded byte cost in a rare state, taken instead of per-trim
  scratch work of exactly the kind C3 rejects.

## Rejected ideas

- **RI1.** The audit's cheaper fallback, `precondition(headTrimmedCells == 0
  || offsets.count > 1)` -- banned by C2; it guards a reachable state.
- **RI2.** Rebasing the arena tables down to the trimmed base in
  `trimHeadRecord` -- banned by C3; simplest on paper, but the original base
  is what keeps coordinates stable across a trim, and it adds per-eviction
  work.
- **RI3.** A bare key-base accessor without the type -- removes the
  duplication but leaves every conversion site free to hand a retained
  `Int` to a key parameter, which is the move that produced this defect.
- **RI4.** Pushing the type through `RecordTextPosition` -- banned by C1.

## Implementation discretion

- The operator surface of `OriginalCellOffset` (Comparable, offset-plus-count,
  key difference) -- whatever the call sites need; nothing is public.
- PO4's fixture shape: the budget, the width, and how the identities are
  fragmented, as long as the record is trimmed while open and then closed by
  the region seam rather than by a hard line end.
