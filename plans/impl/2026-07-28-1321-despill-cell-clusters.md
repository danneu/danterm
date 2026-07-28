# De-spill cell clusters so `GridCell` is trivially copyable

## Problem and evidence

`Terminal.GridCell` is not POD, and `TerminalScalars` is the sole reason: its
storage enum holds an array for multi-scalar grapheme clusters. Every other
member is trivial. Because the cell is non-POD, every grid shift and every cell
blank goes through outlined copy/destroy machinery instead of a memory move.

Evidence, from [docs/research/12-cell-representation.md](../../docs/research/12-cell-representation.md):

- F4 measured a POD spike (clusters deliberately truncated) at **-21.5%** on
  `incremental-screen-updates` and **-9.7%** on `scrollback-stream`, with the
  four outlined-copy symbols disappearing from the profile entirely and
  `memmove` rising in their place.
- F3 measured cluster frequency on the committed corpora: **0%** of cells on
  three of four workloads and **0.61%** on `unicode-wrapping`. The case the cell
  pays for on every copy is the case it almost never holds.
- F4's inference 3: the win requires only that the cell be **POD**, not that it
  be small. Cell size is a separate question owned by that file's H1-H3.

Desired outcome: `GridCell` becomes trivially copyable while multi-scalar
clusters remain exactly correct and unbounded in length.

## Decision

A cell stores its first scalar inline and, for a cluster, a trivial reference to
cluster storage **owned by the row**.

The row is the right owner because rows are already the unit that moves and dies
whole: scrolling moves `GridRow` values, scrollback entry appends them, budget
eviction drops them from the front. Cluster storage attached to a row therefore
needs no reclamation logic for any of those paths -- it is freed exactly when the
row is. `GridRow` is already heap-backed, so this adds no allocation to rows that
hold no clusters.

Because the reference is row-local, it is only meaningful against the row that
owns it. The contract that follows: **any operation that constructs a cell under
a different row owner must materialize or remap that cell's cluster content**;
copying the bare reference across rows resolves it against the wrong storage.
Three existing paths do this today, and each is bound by that contract:

- Primary-screen reflow, which carries whole `GridCell` values through transient
  units and re-packs them into fresh rows.
- Alternate-screen resizing, which builds fresh `GridRow` values from cells
  copied out of the old rows (`resizedRectangle`).
- A narrow cluster upgraded to wide at the last column with autowrap on, which
  rebuilds the cell at column 0 of the following row (`upgradeClusterToWide`).

## Invariants

- **I1** `GridCell` contains no reference-counted member; copying one is a
  trivial memory copy.
- **I2** Cluster content is preserved exactly across every path that relocates a
  cell: scrolling, entry into scrollback, eviction of earlier rows, reflow in
  both directions, alternate-screen resizing, insertion/deletion within a row,
  and wide/narrow cluster re-classification including the last-column
  narrow-to-wide upgrade that wraps the cluster onto the next row.
- **I3** Cluster length is unbounded.
- **I4** A row's cluster storage stays proportional to the cluster cells that row
  currently holds, however many times the row is rewritten.
- **I5** `TerminalScalars` keeps its present value semantics: it presents as a
  collection of scalars and compares equal by content, independent of how that
  content is stored. The render plan is `Equatable` and compared as a value, so
  identical content reaching a cell by different routes must compare equal.

## Proof obligations

- **PO1** (I1) An automated check fails if the cell regains a non-trivial member.
- **PO2** (I2) Cluster content survives each relocation path named in I2,
  asserted scalar-exact. The three cross-row-owner paths -- primary reflow,
  alternate-screen resizing, and the last-column narrow-to-wide wrap -- each get
  their own case; a multi-scalar cluster that survives as a single replacement
  scalar must fail.
- **PO3** (I3) A cluster longer than any inline capacity round-trips intact.
- **PO4** (I4) Repeatedly overwriting a row's cluster cells leaves that row's
  storage proportional to its live clusters rather than to the rewrite count.
- **PO5** (I5) The existing `TerminalScalars` collection and equality suites
  continue to pass unchanged.

## Verification

`just benchmark-quick baseline=<pre-change revision> workload=terminal-feed`
decides the change. F4's -21.5% is a ceiling measured on one corpus with clusters
skipped entirely; the combined stream includes `unicode-wrapping`, where correct
cluster storage costs something the spike did not pay.

## Non-goals

- Style deduplication, narrowing the two side-table keys, row skip flags, and
  packing the cell into a word. Those are the memory question and stay with
  docs/research/12's H1-H4.
- `scrollbackByteCost`'s accuracy and its cost (12/F5, incidental finding).
- Reflow's cost. Resize is not on the feed path and appears in none of the
  profiles behind 12/F4-F6, so cluster handling there may take the simplest
  correct approach with no regard for its efficiency. I2 still binds: reflow must
  preserve cluster content exactly.

## Accepted risks

- **AR1** The cell may not shrink, and could grow slightly. Accepted: F4 showed
  the CPU win needs triviality alone, and cell size is a separate decision.
- **AR2** The cross-row-owner paths gain a step, including reflow, already the
  most intricate code in the file. Accepted because each may be naive: the two
  resize paths are off the feed path entirely, and the last-column wrap fires
  only for a cluster that both widens and lands in the final column, well inside
  the under-1% of cells F3 measured as clusters at all. All three may therefore
  materialize cluster content while rebuilding the cell rather than translating
  storage between rows.

## Rejected ideas

- **RI1** A per-terminal cluster table. Overwriting a cell has no natural
  reclamation trigger, so the table needs refcounting or scanning that per-row
  storage gets for free from row eviction.
- **RI2** libghostty's page arena with base-relative offsets. It assumes manual
  memory control and does not transfer to a Swift value-type engine with COW
  arrays.
- **RI3** A fixed inline capacity of N scalars with no side table. Correctness
  requires unbounded clusters, so an overflow path is needed regardless; inline
  capacity only enlarges every cell to serve a case F3 measured at under 1%.

## Implementation discretion

- The representation of the row's cluster storage and the width of the cell's
  reference into it.
- The compaction trigger that satisfies I4.

## Implementation notes

- **Reference width and storage shape** (discretion point 1). A row owns a flat
  `[Unicode.Scalar]`; a cell's payload is a three-case trivial enum -- `empty`,
  `single(Unicode.Scalar)`, `cluster(start: Int32, count: Int32)` -- so the
  single-scalar case, which F3 measured as effectively all of them, still needs
  no row storage at all. `Int32` rather than `Int` keeps the payload at eight
  bytes; a `precondition` guards the range on intern.
- **Compaction trigger** (discretion point 2). Interning compacts when storage
  would exceed a threshold re-armed at `max(32, 2 * live)` after each
  compaction, which is amortized constant per scalar. Assembling an open cluster
  takes a separate path: when the cluster being extended is the last one
  interned -- the normal case while a cluster is still arriving -- the scalar is
  appended in place, so an N-scalar cluster costs N slots rather than N copies.
- **`GridCell` lost `Equatable`, and `GridRow` gained a hand-written `==`.** A
  cell's payload is row-relative, so cells only compare meaningfully through the
  rows that resolve them. `Terminal`'s public `Equatable` conformance rests on
  row equality, and tests compare whole terminals that reached the same content
  by different routes, so row equality had to stay content-based rather than
  become sensitive to storage layout.
- **Reflow materializes one cluster per unit, not per cell.** A `ReflowUnit`
  carries `headScalars` only: both construction sites build the unit from a
  single source cell, and a wide unit's second cell is a synthesized `.wideTail`
  that can hold no content.
- **Alternate-screen resizing inherits the source row's storage and compacts**
  rather than materializing each cell. Every cell in a rebuilt row comes from
  exactly one source row, so copying that row's storage keeps the references
  valid, and the compaction pass then drops whatever the column clip left dead.
- **PO1 uses the stdlib's underscored `_isPOD`.** There is no public spelling of
  triviality, and the alternative -- asserting on `MemoryLayout` -- would not
  actually test the property. It is reached through an internal
  `Terminal.isGridCellTriviallyCopyable` so the underscored call has one site.
- **Verification.** `just benchmark-quick baseline=HEAD workload=terminal-feed`
  decided the change faster, -9.43% symmetric median. That is short of F4's
  -21.5% ceiling, as expected: the spike skipped clusters entirely and the
  combined stream includes `unicode-wrapping`, where correct cluster storage
  costs something the spike did not pay.

## Follow Up

- A row erased in full keeps its cluster storage until the next intern compacts
  it -- `eraseCells` in
  `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` blanks the cells but
  leaves the backing scalars in place. The residue is bounded per row by the
  compaction threshold, so I4 holds, but a range covering the whole row could
  release the storage outright.
