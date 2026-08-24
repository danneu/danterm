# A trivially copyable live cell in the arena's word encoding (ROW-2 pivot)

## 1. Problem and evidence

`Terminal.GridCell` (`lib/TerminalCore/Sources/TerminalCore/Terminal.swift:213`)
is not trivially copyable, and `TerminalScalars.Storage.spill([Unicode.Scalar])`
is the only reason. Every cell copy is an outlined copy with a conditional
retain and every overwrite a conditional release, paid on the print path,
the frame read, and every in-row move, for a case (multi-scalar clusters)
measured at 0% of cells on three of four corpora and under 1% on the fourth
(`research/12/F3`, doc 28: 0.12% of rows).

Measured cost on the current tree: `outlined copy of TerminalScalars.Storage`
is 4.6% self time on `incremental-screen-updates` (audit FEED-4 profile);
`research/17/H4` put copy+consume at 4.45% of `scrollback-stream`.

The live grid and the arena already encode the same cell two ways. The arena
holds one `Terminal.CellWord` per cell (`LogicalLineRecord.swift:237-258`:
21-bit scalar or spill index, 3-bit kind, spill bit, 32-bit style) with spills
in a per-record side table that is evicted and charged with its record
(`LogicalLineStore.swift:369-423`). Admission (`appendCells`,
`LogicalLineStore.swift:2828`) re-encodes each `GridCell` into that word.

### The prior attempt, and why the cost model has changed

A POD cell was implemented (`31c2f8e`, plan
`plans/impl/2026-07-28-1321-despill-cell-clusters.md`) and reverted
(`94a1528`): `terminal-feed` -8.83%, but `scrollback-stream` **+6.74% slower**
at `confirm` (`research/12/F8`). The diagnosis: cluster storage moved onto
`GridRow` (16 -> 32 bytes, a second refcounted field), and `scrollback-stream`
then moved rows constantly -- `moveAndFillRows` was its second-hottest app
frame. F8's closing inference: retry only when "row-move traffic stops being
hot on `scrollback-stream`, or cluster scalars find an owner that does not
enlarge the row."

Both halves have since moved:

- `ed9a7f5f` (FEED-1) made the viewport a `Deque` ring; a whole-viewport
  scroll advances the head instead of moving every survivor row. Measured at
  `confirm`: `scrollback-stream` -9.21%. The frame F8 blamed is gone.
- Doc 31 replaced per-row scrollback with the arena. Scrollback append and
  budget eviction no longer move or free any `GridRow`.

This is the materially different cost model F8 required, not another attempt
at the same one. It is a premise, and P1 below is its proof obligation.

### Load-bearing premises

- **P1.** Per-line `GridRow` traffic on `scrollback-stream` is now one move
  and one drop, not one per viewport row, so a wider `GridRow` no longer
  charges that workload.
- **P2.** `contentIdentity` never legitimately holds 0: `nextContentIdentity`
  starts at 1 and wraps to 1 (`Terminal.swift:869, 7415, 7830`); the arena
  already decodes 0 as absent (`LogicalLineStore.swift:2723`). Hyperlink ids
  are different: today `allocateHyperlinkId` issues 0 like any other id, and
  the suite asserts it (`TerminalHyperlinkTests` recycles into 0 after the
  wrap, and saturates at 65,536 live targets). Reserving 0 is therefore a
  deliberate representation change, not an existing property, and it narrows
  the usable id space to 65,535.
- **P3.** Stride 16 divides 64, so the cache-line straddle that reverted
  stride 24 (`research/16/D1`, `agent-docs/terminal-performance.md:714-748`)
  does not apply. The malloc-bucket rule still binds: check 80 and 179
  columns.

## 2. Decision

A live cell is the arena's cell word plus two sentinel-0 ids, and a row owns
its own spills.

- `GridCell` holds a `CellWord` (scalar or spill index, kind, spill flag,
  style), a `HyperlinkId` where 0 means none, and a `ContentIdentity` where 0
  means none. It has no reference-counted member. Expected `MemoryLayout`
  stride: 16. Measure it; do not reason about it.
- Reserving hyperlink id 0 as the absent sentinel is part of the change: the
  allocator stops issuing it, so the space is 1...65,535 and saturation
  arrives one target earlier. Public hyperlink behavior does not change -- a
  cell reports the target it was written with, recycling still walks back
  into low ids after the wrap, and a saturated space still refuses further
  opens instead of spinning.
- Multi-scalar payloads live in storage owned by the `GridRow`, indexed by
  the cell's spill index. The row is the unit that moves and dies whole, so
  the storage is freed exactly when the row is and needs no cross-row
  reclamation. Rows without a cluster allocate nothing extra.
- The public census prices that storage exactly, so I4 is observable: the
  live term of `cellStorageBytes` is the cells at their stride *plus* each
  live row's spill storage at its allocated capacity, and
  `multiScalarAllocationCount` counts live row spill allocations. Counting
  allocations alone cannot see one allocation whose capacity grows without
  bound, which is the shape I4 forbids.
- Admission into the arena copies the word and transfers the row's spills
  into the record's side table, remapping indices; it no longer decodes
  `TerminalScalars` per cell.
- `TerminalScalars` stays the public read-boundary type, materialized from
  `(row, cell)` only where a caller needs a value that outlives the grid
  (`cell(row:column:)`, `forEachViewportRow`, text projections, search, the
  state-synchronization encoder, `LastPrintedCluster`).
- A cell's spill index resolves only against its owning row. Every path that
  constructs a cell under a different row owner must carry the cluster
  content across: primary-screen reflow, alternate-screen resizing, the
  last-column narrow-to-wide cluster upgrade that lands on the next row, and
  the arena's decode into a live row.

Both halves (trivial word, sentinel ids) land together: with optional ids the
packed cell sits at stride 24, which is the exact stride doc 16 reverted.

### Scope

`lib/TerminalCore` only: `Terminal.swift` (cell, row, print, erase, move,
reflow, resize, read boundary, census), `LogicalLineStore.swift` (admission,
decode), `LogicalLineRecord.swift` (`CellWord` becomes the shared type), the
state-synchronization encoder and search read sites, `TerminalMemoryCensus`
(the live term of `cellStorageBytes` and the meaning of
`multiScalarAllocationCount`), and the memory probe support that hardcodes
stride 32. No control sequence, projection text, damage contract, render-plan
type, or arena record format changes.

### Measurement gate

The change is decided at `benchmark-confirm`, never at `quick`, against a
named pre-change revision, at both 179x66 and 80x24 for the memory probe:

- `scrollback-stream` and `terminal-feed` must not read `slower`;
  `incremental-mixed` must not read `slower` (the stride workload).
- `retained-browse` is the control and must read `equivalent`: history bytes
  do not change.
- `just terminal-memory-probe --payload full-screen --json`:
  `cellStrideBytes` reads 16; the live-screen cell term of `cellStorageBytes`
  halves; `multiScalarAllocationCount` does not rise on any payload.

Before the full sweep, a `research/12/F4`-style spike (trivial cell, clusters
truncated, ~one hour) on the current tree measures the ceiling on
`scrollback-stream` and `incremental-mixed` at `confirm`. If the ceiling does
not clear, record the numbers beside `12/F8` and stop; the sweep is not
started. A spike that elides work bounds removing the case, not implementing
it (F8's methodological inference), so a passing spike admits the work, it
does not decide it.

### Spike result: passed on 2026-08-24

The deliberately incorrect spike replaced the live cell with the arena's
`CellWord` plus sentinel-0 hyperlink and content-identity fields. It retained
only the first scalar of a cluster. The public census measured a 16-byte cell
stride. `benchmark-confirm baseline=b813e144` compared that candidate with the
pre-spike revision in one machine session (artifact
`.build/terminal-benchmark-comparisons/confirm/6f8add5d65e0-0000`):

- `scrollback-stream`: **faster, -27.99%** symmetric median of 4 pairs.
- `incremental-mixed`: **-0.16%** symmetric median of 6 pairs, descriptive and
  uncalibratable under the current harness. There is no regression signal.
- `terminal-feed`: **faster, -36.65%** symmetric median of 2 pairs.

This clears the spike's admission gate, so the full implementation is worth
attempting. The run also reported `retained-browse` **slower, +2.28%**. That
workload is outside the spike gate, but it is the final gate's control and must
return `equivalent`; keep the result as a risk to explain or remove rather than
discounting it. The spike code was removed after measurement.

## 3. Invariants

- **I1.** `GridCell` has no reference-counted member; copying one is a
  memory copy.
- **I2.** Cluster content survives, scalar-exact, every path that relocates a
  cell: scrolling, admission into the arena, eviction, reflow in both
  directions, alternate-screen resizing, insert/delete within a row, wide and
  narrow cluster re-classification including the last-column wrap onto the
  next row, and decode from the arena back into a live row.
- **I3.** The cell representation imposes no cluster-length limit of its own.
  `Terminal.graphemeClusterByteLimit` (256 UTF-8 bytes, `Terminal.swift:917`)
  stays the only bound, unchanged: content up to it is retained, scalars past
  it are dropped exactly as today.
- **I4.** A row's spill storage stays proportional to the cluster cells it
  currently holds, however many times its cells are rewritten; nothing
  reclaims it by scanning the grid. A cell's spill index is a position in that
  live storage, so it is bounded by the row's cluster count and never a
  handle from a counter that only goes up -- the word gives it 21 bits, and a
  monotonic allocator would run past them and alias one cluster onto another.
- **I5.** Terminal, screen, and row equality is content equality: two grids
  holding identical content reached by different routes (different feed
  order, state-sync replay, reflow) compare equal regardless of spill
  layout. `TerminalScalars` keeps its element-wise `==`.
- **I6.** A hyperlink id or content identity of 0 is never minted, and a cell
  reports "no hyperlink" / "no identity" exactly when it did before. Hyperlink
  ids range over 1...65,535; recycling after the wrap, refusal at saturation,
  and every reported URI stay as they are.
- **I7.** Live and retained cells share one word encoding: a cell admitted
  to the arena and read back holds the same scalar, kind, and style.

## 4. Proof obligations

- **PO1** (I1): an automated check fails if the cell regains a non-trivial
  member (the stdlib's `_isPOD`, as `31c2f8e` did), and the census pins
  `cellStrideBytes == 16` (`TerminalMemoryCensusTests`; the probe-support
  tests that hardcode 32 follow).
- **PO2** (I2): the relocation suites pass unchanged
  (`TerminalGraphemeTests`, `TerminalGraphemeRetentionTests`,
  `TerminalGraphemeWidthTests`, `TerminalRetainedHistoryFidelityTests`,
  `TerminalResizeTests`), plus the three cross-row-owner cases from
  `31c2f8e`'s `TerminalCellRepresentationTests` (recover from git), each of
  which caught a deliberate bare-cell copy. A cluster surviving as its first
  scalar must fail.
- **PO3** (I3): a cluster at the 256-byte retention limit round-trips intact
  through the live grid and the arena, and `TerminalGraphemeRetentionTests`
  passes unchanged, so scalars past the limit are still dropped.
- **PO4** (I4): overwriting one cluster cell N times in one row leaves that
  row's storage bounded by its live clusters, asserted as a *byte* bound
  through the public census -- `cellStorageBytes` must not grow with N -- not
  as an allocation count and not through internals. The census arithmetic and
  the probe tests that equate live storage with `rows * columns *
  cellStrideBytes` (`TerminalMemoryCensusTests:318, 340`,
  `TerminalRetainedRowProbeSupport`'s `derivedStorageBytes` equality) change
  with it. N exceeds the 21-bit spill-index space, and the case also reads the
  cluster back scalar-exact, so an allocator that recycles bytes but not
  indices fails here rather than aliasing clusters in a long-lived pane.
- **PO5** (I5): the 35 whole-terminal `==` assertions across the suite
  (`TerminalFixtureTests:545` bytewise-vs-authored is the canonical one)
  pass unchanged; one new case feeds the same clusters in two orders that
  leave different spill layouts and asserts equality. `TerminalScalarsTests`
  passes unchanged.
- **PO6** (I6, P2): `TerminalContentIdentityShapeTests` passes unchanged.
  `TerminalHyperlinkTests` keeps every behavioral assertion -- the pinned
  target survives recycling, the newest target reads back, the table stays
  bounded, a saturated space refuses further opens and keeps the pen -- and
  its three representation-level assertions move to the 65,535-id space: the
  wrap case expects the recycled set to reach 1 and `HyperlinkId.max` and to
  exclude 0, and the saturation case expects `retainedHyperlinkCount ==
  Int(HyperlinkId.max)`. The `primeHyperlinkId*ForTesting` seams follow. A
  new case asserts no cell ever reports id 0 as a link.
- **PO7** (I7): `TerminalCellWordTests` extends to the live cell;
  `TerminalLogicalLineStoreTests` admission suite passes unchanged.
- **PO8** (P1, P3, the gate): the spike record and the final
  `benchmark-confirm` and memory-probe readings, at both widths, written into
  the commit and into `agent-docs/terminal-performance.md`'s "Before you
  shrink `GridCell`" section beside the doc-16 and 12/F8 entries -- whichever
  way they decide.

## 5. Non-goals, accepted risks, rejected ideas

Non-goals:

- **N1.** Changing the render plan's `TerminalScalars` or `RenderTextCell`.
  `research/12/F8` notes part of F4's projected win is unreachable while the
  public type stays; accepted.
- **N2.** Reflow efficiency. It is off every profiled path; I2 binds, cost
  does not.
- **N3.** Moving hyperlink or identity into per-row tables to match the
  arena's per-record tables. Inline sentinel ids reach stride 16 already.

Accepted risks:

- **AR1.** `GridRow` gains a field. Accepted on P1: the per-line row traffic
  that made this fatal in `12/F8` is gone, and PO8 measures it on the workload
  that rejected it.
- **AR2.** The cross-row-owner contract is a permanent invariant every future
  relocation path must honor. Accepted because PO2's mutation-caught cases
  make a violation a test failure, not a silent corruption.
- **AR3.** A row wider than 2,097,152 columns could exhaust the 21-bit spill
  index. Accepted: `columns` reaches `Terminal` from a `winsize` field that is
  `UInt16`, the widest configuration any test builds is 70,000, and I4 already
  binds the index to live cluster positions -- a geometry guard would fence a
  case nothing can reach.
- **AR4.** ~50 `.scalars` read sites change shape. Accepted; the sweep must
  not run concurrently with other `Terminal.swift` work.

Rejected ideas:

- **RI1.** A `Terminal`-owned spill array indexed by cell word (the audit's
  original ROW-2 shape). Overwriting a cell has no reclamation trigger, so the
  table needs refcounting or a grid scan; the row owner gets reclamation free.
- **RI2.** Sentinel ids alone, or the trivial word alone. The first leaves the
  cell non-POD; the second lands at stride 24, the reverted stride.
- **RI3.** A fixed inline capacity of N scalars. It cannot cover the
  256-byte retention limit without an overflow path anyway, so the capacity
  only enlarges every cell for nothing.
- **RI4.** Deciding at `benchmark-quick terminal-feed`. That is how `12/F7`
  passed and `12/F8` failed.

## 6. Implementation discretion

- The row's spill storage shape, and the compaction trigger that satisfies I4
  (`31c2f8e` used a threshold re-armed at `max(32, 2 * live)`).
- Whether `GridCell` keeps a synthesized `Equatable` for word-level comparison
  and row `==` resolves spills, or drops `Equatable` as `31c2f8e` did; I5
  binds either way.

## Commit progress

- [x] 1. refactor(terminal): reserve hyperlink id 0 for absent links
- [ ] 2. perf(terminal): share the arena word with live grid cells
