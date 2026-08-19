# STORE-3: one encode/decode type for the 8-byte cell word

From `docs/scratch/2026-08-18-construction-audit.md` STORE-3, verified
2026-08-19. Both prerequisites have landed: STORE-1 (3354fd46, derived
`bytesInUse`) and STORE-2 (863a81f4, dead `PackedRetainedRow` deleted). The
plan below targets the post-STORE-2 tree.

## Problem

STORE-2 gave the cell word its single declaration: `CellWord` in
`LogicalLineRecord.swift` carries the bit diagram and the five layout
constants (`scalarMask`, `kindShift`, `kindMask`, `spillBit`, `styleShift`).
But it is a constants-only namespace, and the encode/decode arithmetic is
still hand-inlined across `LogicalLineStore.swift`: the kind decode appears
five times, the style extraction four, the scalar-plus-spill pair three,
the write side twice (`appendCells`, `appendBlankCells`), and `cutTail`
tests the spill bit raw. A layout change must be applied at every site by
hand, and a site with one wrong shift decodes plausible garbage instead of
failing to compile. The constants have no consumer outside
`LogicalLineStore.swift` -- no test or app code reads them.

## Decision

Convert `CellWord` from a constants namespace into a value type over the
raw `UInt64`, keeping its current home and its layout doc comment. It
carries construction from a cell's fields (kind, style id, and either an
inline scalar, a spill index, or no payload) and accessors for kind, style
id, scalar field, and the spill flag. Every encode and decode site in
`LogicalLineStore` routes through it; the layout constants become private
to the type. The store's `cellWord(recordAt:cell:)` accessor returns a
`CellWord`; the borrowed-pointer read loops keep loading the raw `UInt64`
from the chunk and wrap it in place.

This is a pure refactor: no stored byte changes, no behavior changes, no
public API changes (everything involved is internal to `TerminalCore`, so
no `@inlinable`/`@usableFromInline` concerns arise).

## Invariants

- I1: The cell-word layout -- constants and the arithmetic that applies
  them -- is expressed in exactly one type; no code outside it shifts or
  masks a cell word.
- I2: No observable behavior change -- every retained read walk reports the
  same kind, style, scalar, and spill resolution per cell, and one cell
  still costs one 8-byte word whose fields never overlap.
- I3: No measurable regression on the frame path: `withPaintedCells` and
  `forEachClosedRecordCell` are what `retained-browse` measures
  (`agent-docs/terminal-performance.md`), so the wrapper must cost nothing
  that workload can resolve.

## Proof obligations

- PO1 (I2): the existing suites -- `TerminalRetainedRowReadPathTests`,
  `TerminalLogicalLineStoreTests`, `TerminalRetainedHistoryFidelityTests`
  -- stay green with no test edits; `just test` passes.
- PO2 (I2): a new `CellWord` test, written before the type exists, pins
  that the fields do not interfere at their extremes: every kind, a style
  id at the top of its field, an inline scalar at the top of the Unicode
  range, a spill index at the top of its field, and the no-payload case
  each decode back to exactly what was encoded. This catches a
  mis-transcribed shift that makes two fields overlap, which is the
  mistake an encoder and a decoder sharing it cannot hide.
- PO3 (I3): paired `just benchmark-quick baseline=<pre-change revision>
  workload=retained-browse`. `equivalent` or `faster` discharges it;
  `inconclusive` escalates to `just benchmark-confirm`; `slower` rejects
  the change or sends it back for revision. Read
  `agent-docs/measurement-discipline.md` before acting on the numbers.
- PO4 (I1): no reference to a shift or mask constant, and no raw shift or
  mask of a cell word, remains outside the `CellWord` type; the constants
  are private to it.

## Non-goals

- Changing the word layout itself (field widths, positions, meanings).
- Wrapping the record *header* word, which is a different 8-byte format
  with its own accessors on `LogicalLineRecord`.
- AR1: a golden test pinning the raw `UInt64` bit positions. PO2 catches a
  layout mistake that makes fields overlap; AR1 accepts a coordinated move
  of a field into spare bits, which PO2 cannot see. No consumer interprets
  a raw bit position: the arena is never serialized or sent, and the one
  raw-word reader, `LogicalLineStore`'s byte-equality oracle, compares two
  stores inside one build, so it needs the encoding to be canonical (one
  encoder gives it that) and not any particular field position. A golden
  word would pin private structure and break on a later legitimate layout
  change.

## Implementation discretion

- Initializer and accessor naming, whether the payload is one initializer
  or several, `@inline(__always)` placement, and how the raw `UInt64` is
  exposed for chunk storage.

## Verification

`just test` for PO1 and PO2. PO4 is a source audit, not a lint --
`core-purity-lint.sh` has no cell-word rule and never will: read
`LogicalLineStore.swift` and grep the tree for `>>`, `<<`, `&` against a
cell word and for the five constant names, and confirm the only hits are
inside `CellWord`. Then the paired `just benchmark-quick` run for PO3.

## Final task: mark STORE-3 done in the audit

After the refactor commit lands and `just test` is green, record it in
`docs/scratch/2026-08-18-construction-audit.md` as its own docs-only commit
(the pattern STORE-1 and STORE-2 used -- see `8a527500`):

- Flip the STORE-3 checklist entry (line 1168, the "two hops out" wave) from
  `- [ ]` to `- [x]` and append the refactor commit's
  short hash after a ` -- ` separator, in backticks. That entry is the only STORE-3 checkbox in the file; the
  cross-reference lines elsewhere stay as they are.
- Write the commit body against the item's own claims: state that the cell
  word's encode/decode arithmetic now lives in one type, report PO3's
  benchmark verdict, and name anything the item asked for that the change did
  not do.

## Implementation notes

- `CellWord` exposes flat accessors (`kind`, `styleId`, `isSpilled`,
  `spillIndex`, `inlineScalar`) rather than a `Payload` enum. The decode sites
  keep the exact branch shape they had -- spill first, then inline scalar, then
  empty -- so the frame path gains no new switch, and `inlineScalar` folds the
  old "field is non-zero and a valid scalar" test into one optional.
- PO3: `just benchmark-quick baseline=cf022c76 workload=retained-browse` reported
  `retained-browse: equivalent (+0.51% symmetric median of 2 pairs)`. The host was
  loaded during the run (load 8.87 at invocation across 10 processors, mostly
  other agents), which the tool reports as descriptive rather than a verdict.

## Commit progress
- [x] 1. refactor(core): route every cell-word encode and decode through CellWord
- [ ] 2. docs(audit): mark STORE-3 done
