# Print wide scalars as runs, and let the printer keep the REP memory instead of rebuilding it

Research: [docs/research/39-kitten-render-benchmark](../../docs/research/39-kitten-render-benchmark/README.md)
(`F13`, `D8`).

## 1. Problem

Two per-scalar costs, one per arm.

The stream yields a bulk run only for narrow scalars, so every wide scalar --
every CJK character -- is its own action and its own single-cell print. Each
one pays the per-action work (dispatch, damage snapshot, damage record), a
second classification, the whole cluster-join guard chain, and the single-cell
print's per-call work (two inspection invalidations, a two-column destination
prepare with both neighbour probes, one identity, one erase style, two
copy-on-write-checked cell stores, a fresh cluster context, a read-back for
the REP memory). Evidence (`F13`): about 80% of the `unicode` PTY-host thread;
DanTerm feeds the arm at 37 MB/s against Ghostty's 111. A prototype that
yields a run of same-width independent scalars and stamps wide pairs per row
segment read `kitten-feed-unicode: faster (-62.40% symmetric median of 2
pairs)` with `unique-unicode` equivalent (`D8`).

The REP memory is refilled after every printed scalar by reading the cell
back and copying its whole cluster out, so a cluster of `k` scalars is copied
`k` times with growing length, into a heap buffer retained and released
around each copy. Evidence (`F13`): 26.7% of the `unique_unicode` thread on
that one function, with all of the arm's retain/release under it. A prototype
that extends the memory by the scalar that just joined read
`kitten-feed-unique-unicode: faster (-21.84% symmetric median of 2 pairs)`
with `unicode` equivalent (`D8`).

Load-bearing premises about existing behavior:

- A run of scalars of break class `.other` without the emoji properties is
  safe to stamp as independent cells: none joins the scalar before it, and
  the scalar after the run can only join by extending the run's last cell,
  which the run leaves open (`TerminalASCIIRunTests`). This does not depend
  on width.
- A wide scalar that does not fit before the right margin leaves a spacer and
  wraps with DECAWM on, or backs onto the last two columns with DECAWM off;
  insert mode shifts the row; a latched wrap wraps first
  (`TerminalGraphemeWidthTests`, `TerminalKittyAdaptedTests`).
- REP repeats the last printed cluster with its width, and the memory
  survives the loss of the cell it was printed into, cursor motion, CR, LF and
  any CSI (`TerminalRepeatTests`). A scalar the segmenter or the byte limit
  refuses changes neither the cell nor the memory; a width change the printer
  refuses leaves both unchanged.
- The synchronization stream sets the memory and the cluster context
  directly and independently, so one chunk can restore a memory and a context
  that name different cells, and the encoder reads the memory
  (`TerminalStateSynchronizationTests`).

Desired outcome: a run of wide independent scalars costs per-segment work once
per row segment, not once per cell; joining a scalar to a cluster the printer
opened costs one memory append, not a cluster copy; every observable result is
unchanged;
`kitten-feed-unicode` and `kitten-feed-unique-unicode` read `faster`.

## 2. Decision

**Bulk eligibility is a property of the scalar, not of its width.** The stream
yields a run of independent scalars of one width, cut where the width changes,
and the printer stamps a wide run segment by segment as it stamps a narrow one:
per segment one destination prepare over the whole range, one damage record,
one inspection invalidation, one identity range, the cells, the cluster
context on the last head, one memory refresh, and the cursor advance with the
wrap latch. Whatever the segment declines -- the pair that would straddle the
margin, a latched wrap, insert mode, an armed single shift, an open prepend
context -- goes through the single-cell print for exactly that cell, and the
run re-enters. The cut rules stay where the narrow run's are.

**The REP memory is a mirror the printer maintains from what it places, read
back from the grid only where it cannot yet mirror.** A fresh cell sets it; a scalar that joins the
open cluster extends it and updates its width; a refused scalar leaves it
alone. The mirror holds only for a cluster context the printer itself opened.
A context adopted from anywhere else -- recovered from the grid, or restored by
the synchronization stream -- does not mirror, so a scalar the join path accepts
for it copies the target cell into the memory, as today, including when the byte
limit or a refused width change accepts the scalar without changing the cell.
The bulk writers, which stamp many cells, remember the last one as they do now.

Both are the ideals `D8` names, and `D8` records the lazy-position memory and
the shared-decode stream as the alternatives it priced and did not take. Two
commits, wide runs first.

## 3. Invariants

- **I1** Feeding any byte sequence leaves the grid, cursor, wrap latch,
  soft-wrap flags, margin provenance, content identities and cluster context
  equal to feeding it one scalar at a time. In particular for a run of wide
  scalars across the right margin with DECAWM on and off, in insert mode,
  with a wrap latched at entry, over a row already holding wide pairs, and
  mixed with narrow scalars in either order.
- **I2** A scalar that joins after a run -- Extend, ZWJ, a variation
  selector, a spacing mark -- joins the run's last cell only, and a width
  change it forces or refuses matches the single-scalar path.
- **I3** The damage a fed run records is equivalent to the damage the
  scalar-at-a-time feed records: the drained damage and the inspection state
  after each are the same.
- **I4** A run of `n` independent wide scalars performs its per-call work --
  damage record, inspection invalidation, identity allocation, destination
  preparation -- a number of times bounded by the row segments it fills plus
  the cells the bulk path declines, never `n` times, on a plain same-row fill.
- **I5** After every print that opens a cell or that the join path accepts,
  the REP memory equals the scalars and width of the cell the cluster context
  targets, whether the scalar opened a cell, joined a cluster, was refused by
  the byte limit or a width change it could not make, joined a context the
  printer did not open -- recovered from the grid, or restored by the
  synchronization stream to a cell the memory does not name -- or changed the
  cell's width. A print the segmenter refuses outright, which opens no cell,
  changes neither the cell nor the memory, as today.
- **I6** REP after a joined cluster, after CR, LF, a scroll that recycles the
  source row, a resize, an erase of the source cell, and after the
  synchronization stream set the memory, repeats what it repeats today.
  Count 0 means 1 and the ceiling stays 65535.
- **I7** Joining a scalar to a cluster the memory already mirrors performs no
  read of the cell and no copy of the cluster into the memory, and allocates
  only what the arena append allocates.

## 4. Proof obligations

Behavioral and structure-insensitive; a refactor that keeps the behavior
keeps these passing.

- **PO1 (I1)** A whole-terminal equivalence between a fed run and the same
  bytes fed one scalar at a time, over the cases I1 names, for wide runs and
  for runs that mix narrow and wide scalars. The existing narrow-run
  equivalence cases stay green.
- **PO2 (I2)** For each joining class after a wide run and after a mixed
  run, the cell content, width and cursor match the scalar-at-a-time feed;
  a VS16 after a run whose last scalar is not a variation base does not
  widen it.
- **PO3 (I3)** For each PO1 case, draining damage after the fed run yields
  the same rows or full-damage state as after the scalar-at-a-time feed, and
  an inspection anchor in a stamped row is retired by both.
- **PO4 (I4)** A cost invariant that no shipped surface counts, so it is
  proved by the frame-presence reading in the benchmark gate, not by a test.
  The behavioral half -- a run that wraps over `k` rows damages `k` rows --
  is PO3.
- **PO5 (I5)** After each of the paths I5 names, the memory read back
  through REP equals the target cell: a fresh narrow and wide cell, a cluster
  of several marks, a mark refused by the byte limit, a width upgrade and a
  refused upgrade, a mark joining a context recovered after cursor motion back
  to an existing cluster, and a mark joining a synchronization-restored context
  whose cell the restored memory does not name -- appended, refused by the byte
  limit, and refused by a width change.
- **PO6 (I6)** The existing `TerminalRepeatTests` cases stay green, plus REP
  after a synchronization stream that set the memory and the context to
  different clusters.
- **PO7 (I7)** The existing arena allocation bound holds for a row of
  multi-scalar cells, and the frame-presence reading in the gate shows no cell
  read-back or cluster copy under the join path of a mirroring context.
- **PO8 (arena round-trip)** A row stamped by a wide run reads back through
  every reader -- cell accessor, encoder, search, render geometry -- with the
  same scalars, kinds, styles and identities as the scalar-at-a-time feed.

## 5. Benchmark gate

Frozen rules from `research/39/D2`; conditions from
[agent-docs/terminal-performance.md](../../agent-docs/terminal-performance.md).
Note the pre-change revision before starting. Each commit is gated on its own
pre-change revision.

1. `just benchmark-quick baseline=<pre-change> workload=kitten-feed-<arm>` on
   all four arms after each commit: the commit's target arm (`unicode`
   +/-1.80% for the first, `unique-unicode` +/-1.60% for the second) must read
   `faster`; `ascii` (+/-1.70%), `csi` (+/-1.45%) and the other Unicode arm
   must not read `slower`. A direction on an arm the commit cannot reach is
   read against `F7`'s change-free control. A miss is recorded, not hidden.
2. `just benchmark-confirm baseline=<pre-change>` before either performance
   claim is recorded anywhere durable; `content-churn` and `retained-browse`
   are read against `F7`'s control, per `D4`. `retained-browse` is the named
   cell for the second commit: `D6`'s first shape cost it 10.3% through the
   payload type's width.
3. Confirmation of each hypothesis, after the ladder verdict, read by **which
   frames are present**, against a pre-change sample of the same stimulus
   (an empty subtree is "not measured", not "measured zero"). For the wide
   run, on the headless `unicode` feed: no per-cell `print`, `printWide`,
   `appendToOpenClusterIfJoined`, per-cell identity allocation or per-cell
   inspection invalidation on the CJK path; only the segment stamp and one
   prepare, record and invalidation per segment. For the memory, on the
   headless `unique-unicode` feed: no cluster copy and no retain/release
   under the join path, and the read-back present only under a bulk writer or
   an adopted context. Subtree sample counts are recorded on both trees. The
   external confirmation is the kitten `unicode` and `unique_unicode` MB/s
   figures moving, recorded with window state and geometry, with the other
   arms beside them.
4. Record the decision-bearing values -- mode, workload, both tree
   identities, the median symmetric estimate, the classification -- in each
   commit, and add the outcome to
   `docs/research/39-kitten-render-benchmark/findings.md` as a finding.

`just test`, `just lint`, and the `TerminalCore` suite before each commit.

## 6. Non-goals

- The stream's own decode and classification, which remain about a third of
  the `unicode` thread after the run engages, and the printer's second decode
  of the run. `D8` names them; neither has a hypothesis.
- `H6`'s blank fill, and the per-action damage snapshot.
- REP in insert mode, or any change to what REP repeats.
- A lazy REP memory that reads the grid when REP fires. Priced and rejected
  in `D8`.

## 7. Accepted risks

- **AR1** The wide run's safety rests on the run's scalars being break class
  `.other` and free of the emoji properties, which the stream guarantees by
  the same predicate the narrow run uses. Accepted because the predicate is
  one table read per scalar and PO2 pins the joiners that must still join.
- **AR2** A supplier closure that is stored rather than passed boxes the
  decoder state and puts a dynamic exclusivity check on every read; `D8`'s
  first cut lost 58 points of its gain to exactly that. Accepted because the
  benchmark gate reads it directly.
- **AR3** Extending the memory on the join path is only correct while the
  memory already mirrors the target cell, which holds only for a context the
  printer opened. A context recovered from the grid and one restored by the
  synchronization stream are both adopted, and the synchronization stream can
  restore a memory and a context that name different cells. Accepted because
  PO5 and PO6 fail if either provenance is missed.

## 8. Rejected ideas

- Widening the bulk predicate and letting the narrow writer refuse wide
  scalars per cell: every wide scalar falls out of the run one cell at a time,
  which is today's cost. Priced in `D8`.
- A stream that yields decoded scalars so the printer does not decode again:
  an array per action, which the stream's design refuses
  (`research/33/F9`).
- One writer over a cell template for both widths: `D7` measured the narrow
  writer's inline store as the narrow arm's whole gain and kept two writers.

## 9. Implementation discretion

- Whether the run action carries its scalar count and width or the printer
  re-scans for them, and whether the wide writer is a sibling of the narrow
  one or shares its prologue.
- Where on the join path the memory is extended, and how the printer records
  that a context is adopted rather than one it opened, provided I5 holds on
  every path I5 names.
- Whether an adopted context stops copying once the memory mirrors it, or keeps
  copying on every accepted join. Both satisfy I5, and neither is on a measured
  path: the benchmark arms only ever join contexts the printer opened.

## Commit progress

- [x] 1. perf(terminal): print runs of wide independent scalars segment by segment
- [ ] 2. perf(terminal): extend the REP memory on join instead of rebuilding it

## Implementation notes

- The run action carries its width (`printScalarRun(Range<Int>, isWide: Bool)`)
  rather than letting the printer re-scan for it. The stream already reads the
  classification that answers the question, so re-deriving it in the printer
  would put back the per-scalar table read the run exists to amortize. The
  stream fixes the width from the first admitted scalar and cuts the run where
  it changes.
- `isBulkPrintable` now says `cellWidth != .zero` instead of
  `cellWidth == .narrow`, so it no longer implies narrowness. `repeatLastPrintedCluster`
  used that implication to route a one-scalar memory to `repeatNarrowScalar`,
  and now asks for `.narrow` separately. That keeps REP's routing exactly what
  it was.
- The wide writer is a sibling of the narrow one, not a shared prologue:
  `printBulkWide` beside `printBulkNarrow`, and a new `writeWideCells` that
  `printWide` (count 1) and `printBulkWide` (a whole segment) share, mirroring
  how `writeNarrowCells` is shared. The two bulk writers differ in their cut
  rules -- the narrow one refuses a destination cell it cannot simply replace,
  the wide one does not need to, because its range store covers every pair it
  severs -- so folding them would have to restate both rules anyway.
- `printBulkWide` invalidates with `affectsPreviousProjection: column <= 1`,
  matching what `printWide` passes for its own first cell. At column 1 that is
  a damage superset no shipped surface distinguishes; it is kept so the segment
  and the per-scalar path pass the same flag.

## Follow Up

- `lib/TerminalCore/Tests/TerminalCoreTests/TerminalASCIIRunTests.swift` is now
  the pin for narrow *and* wide bulk runs, and its name and struct name still
  say ASCII. Rename the file and `struct TerminalASCIIRunTests` to something
  width-neutral (`TerminalBulkRunTests`).
- `Terminal.printScalarRun` decodes the run's bytes a second time, after the
  stream already decoded them to classify. `research/39/D8` names it as a
  non-goal with no hypothesis; the frame table in `F14` now puts
  `nextAction` at 36% of the `unicode` thread, so it is the arm's largest
  single item.
