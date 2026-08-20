# STORE-5: one record-range accessor for the block ring

## Context

Audit finding STORE-5 (`docs/scratch/2026-08-18-construction-audit.md`),
verified against the current tree on 2026-08-19. The mapping from a block
number to the retained record indices it covers is the store's trickiest
arithmetic: the first block must be clamped against `firstRecordSequence`
because the head block is partially evicted, and the last against
`offsets.count`. That mapping, and its inverse (record index to block
index), are hand-copied across `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift`:

- The full range pair appears verbatim in `recomputeIndex` and in the test
  oracle `independentContentBlockTotalsForTesting`.
- The clamped-first half recurs in `contentRank(of:)`, `firstDisplayRow(ofRecord:)`,
  and `locate(displayRow:)`.
- The inverse conversion (`sequence / Self.blockSize - firstBlockNumber`)
  is written independently in `contentRank`, `firstDisplayRow`, and
  `addContentUnits(_:toBlockContaining:)`.

Any reader that forgets the head-block clamp mis-attributes rows or content
units for a partially evicted head block. No live defect exists today; the
fix removes the class. This is the head of a serial lane: HIST-3 (fold
cursor) builds on the accessor this plan adds, and HIST-4 follows HIST-3.

## Decision

Add two private accessors on the store -- one giving the block index that
owns a retained record, one giving the record-index range a block covers --
and route every production reader of the block ring through them, so the
head-block partial-eviction clamp is written exactly once in production
code. This is the audit's ideal fix; it vetted small (one production file,
plus one characterization test extension per PO1) with no cheaper fallback
worth naming.

Sites to route: `recomputeIndex`, `firstDisplayRow(ofRecord:)`,
`contentRank(of:)`, `locate(displayRow:)`, and
`addContentUnits(_:toBlockContaining:)`.

## Invariants

- I1: The block-to-record-range conversion, including the head-block clamp,
  has exactly one production definition; no production reader spells the
  clamp inline.
- I2: `independentContentBlockTotalsForTesting` keeps its own spelled-out
  copy of the conversion and does not call the shared accessor, with a
  comment stating why: routing it through the accessor would make the
  oracle check the code with itself.
- I3: Pure refactor -- no observable behavior changes. In particular,
  `locate(displayRow:)` keeps its current scan bound (`offsets.count`, not
  the block's end), so a stale index degrades exactly as it does today.

## Proof obligations

- PO1 (I3): Existing coverage discharges behavior equivalence for the
  clamped-first half and stays green:
  `independentContentBlockTotalsForTesting` against
  `contentBlockTotalsForTesting`, `independentDisplayRowRecount` against
  `grandDisplayRowTotal`, and the `locate` / `position(ofRecord:cellOffset:)`
  round-trip expectations in `TerminalLogicalLineStoreTests`.
- PO2 (I3): Existing coverage does *not* reach the full block-to-record-range
  conversion in `recomputeIndex`. Every `setWidth` call in the suite runs with
  one block and no retired record, so neither the head clamp nor the
  `offsets.count` upper bound is load-bearing in a passing run today. Extend
  the behavioral characterization coverage to reach it: build a store holding
  more than `blockSize` records, retire at least one record while its block is
  still retained, then change width and compare the maintained row total and
  every addressable row against the independent recounts. The test is
  structure-insensitive, asserts no private accessor, and must pass before the
  refactor as well as after.
- PO3 (I1, I2): Inspection at review -- after the change, the clamp
  expression appears in exactly two places in the file: the shared accessor
  and the oracle.

## Non-goals

- Do not push the accessor across the `RecordTextPosition` boundary or into
  `TerminalSearch.swift` (the audit's STORE-4 discussion already rules this
  out).
- Do not touch the forward-direction block-number computations in
  `memoryGrowth` and the block-append path: they compute the block of a
  sequence *about to be appended*, not the range of an existing block, and
  the accessor pair does not apply.
- Do not collapse the remaining structural similarity between `contentRank`
  and `firstDisplayRow` (block prefix value, then a per-record scan) beyond
  the shared range arithmetic -- that traversal is HIST-3's subject.

## Implementation discretion

- Accessor names and signatures, including whether the record-to-block
  accessor returns an optional or asserts, matching each caller's current
  out-of-range handling (guard-return in `contentRank` /
  `firstDisplayRow`, `precondition` in `addContentUnits`).

## Verification

`swift test --package-path lib/DanTermCore` is not the home of these tests;
run the engine suite: `swift test --package-path lib/TerminalCore --filter
TerminalLogicalLineStoreTests`, then `just test` as the full gate.
