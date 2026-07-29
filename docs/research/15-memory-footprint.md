# Memory footprint

Research started: 2026-07-29. **Status: LIVE.**

This file takes up the reopening condition doc 12 recorded when it closed:
*"a scrollback-depth or memory-footprint goal becomes live"*. It is now live.
Doc 12 answered what a cell costs and rejected the CPU-motivated rewrite of it;
this file owns the memory goal that doc 12 declined to pursue without one, plus
the runtime footprint question doc 12 never covered.

## Purpose

This file owns **how many bytes DanTerm holds at runtime and how to reduce
them** -- per cell, per row, and in aggregate -- and it must hold itself to
measured before/after evidence for every claim.

It inherits rather than repeats. Doc 12 measured the cell (`12/F1`), took a
census of resident grid state across all four workloads (`12/F3`), sized four
memory hypotheses, and rejected two directions with reasons. **None of that is
re-derived here.** Read `12/F1` and `12/F3` before proposing anything; this file
starts from them.

| Question | Owned by |
| --- | --- |
| What a cell costs, and whether its layout costs CPU | doc 12 (**closed**) |
| `Terminal.feed` CPU cost | doc 10 (closed) |
| Plan and draw allocation hotspots | doc 9 (closed) |
| **What the process holds, and how to hold less** | **this file** |

The distinction from doc 12 is the unit of measurement. Doc 12 reasoned in
`MemoryLayout` stride and asked whether layout showed up in a CPU benchmark.
This file reasons in resident bytes of a running process and asks whether a
change shows up in a memory measurement -- which is a different question with a
different instrument, and one that only became answerable today (`F1`).

## Investigation rules

- **Measure terminal state, not the GUI process, for any representation
  claim.** `F1` shows only ~26% of the benchmark app's footprint is the malloc
  heap at all; the rest is Metal, CoreAnimation, and AppKit. A cell-layout win
  measured against total process footprint will look small for reasons that have
  nothing to do with the change. Report both, and say which one the claim rests
  on.
- **Never derive per-type bytes from `heap` output.** `heap` reports malloc
  bucket sizes, not allocation sizes -- its "14.0K" per row array is a rounded
  bucket. Per-type bytes come from `MemoryLayout` stride (`12/F1`), and the
  bucket rounding is itself a cost worth accounting separately.
- **A representation change is a CPU claim as much as a memory claim.** Carried
  forward verbatim from doc 12: any proposal must state its effect on
  `moveAndFillCells`, `eraseCells`, and COW traffic, and must be verified on
  `terminal-feed` and `scrollback-stream` per `10/F9`.
- **A cell-size change is a scrollback-depth change.** Also carried forward. The
  budget is denominated in bytes, so shrinking the cell silently buys the user
  more history at the same nominal budget. Say what happens to depth in every
  proposal, and decide it deliberately rather than as a side effect.
- **libghostty is a source of techniques, never of numbers.** Verify any claim
  about it against `.ghostty-src/` with file and line, per doc 12's rule. Where
  a simpler answer fits a Swift value-type engine better than libghostty's, take
  the simpler one -- doc 12's `12/F4` is the precedent, and this file's `H6` is
  a candidate for it.
- **Do not re-litigate doc 12's rejections.** The POD cell (`12/F8`) and
  libghostty's page allocator are closed with recorded reasons; see "Rejected".

## Trigger and current evidence

Two things opened this file on the same day.

**The tooling.** `just benchmark-memory` (commit `1afed54`) did not exist when
doc 12 closed. Doc 12's memory hypotheses were sized structurally -- by walking
the grid and by `MemoryLayout` -- because there was no way to observe resident
bytes of a running DanTerm. There is now: a footprint curve, per-category
growth, and a `heap --diffFrom` class table. `F1` is the first measurement it
produced.

**The goal.** A memory-reduction goal is now stated, which is exactly the
condition doc 12 parked on. Its four parked hypotheses become this file's
starting candidates rather than backlog.

The original trigger, doc 12's, was a post by libghostty's author describing an
8-byte cell and row against Alacritty's 24-byte cell. That post is quoted and
verified in `12/F2`; it is not re-quoted here. Its useful residue for this file
is one methodological idea rather than any technique: **it measures pure
terminal state across a payload matrix** -- empty, full screen, 10K scrollback
in plain text, unicode, heavy styling, and mixed -- inside one binary, so that
embedder overhead is not attributed to the engine. DanTerm has no equivalent
harness. Building one is Phase 1.

### What `F1` establishes

| layer | bytes | share |
| --- | ---: | ---: |
| process footprint | 222.0 MB | -- |
| `MALLOC_SMALL` dirty | 98.4 MB | 44% of footprint |
| live malloc heap | 57.6 MB | 26% of footprint |
| `[GridCell]` row storage | 48.2 MB | **84% of live heap** |

Three consequences, in order of how much they should change anyone's plans:

1. **Within the heap, there is exactly one thing to optimize.** Grid row storage
   is 84% of live bytes; every other class -- CFString, dictionaries, Metal,
   AppKit -- is rounding error. Doc 12's cell hypotheses point at the right
   target.
2. **Outside the heap, the cell is not the story.** ~164 MB of the 222 MB is not
   live malloc at all. A change that halves the cell moves ~11% of process
   footprint, not ~50%. Attributing the rest is a Phase 1 task, not an
   assumption.
3. **Dirty malloc pages exceed live bytes by ~40 MB.** Some of that is normal
   allocator retention; how much is fragmentation, bucket rounding, or
   unreturned pages is unknown and worth one measurement before it is theorized
   about.

## Current hypotheses

IDs are local to this file. Where a hypothesis continues one of doc 12's, the
mapping is stated -- doc 12's IDs are **not** reused, to keep cross-file
citations unambiguous.

### H1 -- the scrollback budget under-charges, so the product holds ~1.8x the memory it promises

`12/F1` observation 3: `scrollbackByteCost` charges `16 + cells * (32 + 8 *
scalars)`, i.e. **40 bytes for an ordinary single-scalar cell against a true
stride of 72**. At the 10 MB production budget and 179 columns, the model admits
~1,460 rows whose actual cell storage is ~18.8 MB, before per-row allocation
overhead.

This is not a representation change and needs no layout work. It is an
accounting bug with a user-visible consequence: a user who configures a 10 MB
scrollback budget gets ~19 MB of scrollback. Correcting the model is a handful
of lines.

**It is also the only hypothesis here whose fix reduces memory without changing
any data structure**, which makes it the natural first move and a clean test of
the measurement harness: the predicted effect is precise (~8.8 MB at 179
columns) and any harness that cannot see it is not sensitive enough for the rest
of the file.

Note the interaction: correcting the accounting *reduces retained history* at a
fixed budget, and every later hypothesis that shrinks the cell *increases* it
again. Decide the budget's nominal value once, after both.

Confirmed if resident scrollback bytes fall to the budget and the harness
measures it.

### H2 -- `hyperlinkId` should be one bit plus a side map

Continues `12/H2`'s first half, which `12/F3` inference 3 sharpened: nil in
**100% of cells across all four workloads**. Eight bytes plus a discriminator,
in every cell, for a feature the corpus never exercises. libghostty spends one
bit with the id in a page-level map (`page.zig:1994`, `hyperlink_set` at
`page.zig:145`).

Doc 12 named this "the best first move" of its parked set. Nothing in `F1`
contradicts that.

Removes ~9 of 72 stride bytes. Confirmed if stride falls, resident bytes fall
proportionally, and `terminal-feed` / `scrollback-stream` do not regress.

### H3 -- the style should be a 16-bit ID into a deduplicated table

Continues `12/H1`. `TerminalStyle` is 19 bytes stored inline in every cell and
is the single largest field; `12/F3` found **at most 9 distinct styles** in any
workload, so the dedup table stays trivially small.

Removes ~19 of 72 stride bytes -- the largest single win available -- but it is
the most invasive of the cheap options, and `12/F3`'s uncertainty is live: the
census counted *resident* styles, not style *writes*, and write traffic is what
a refcounted table would charge for. Measure write traffic before committing.

### H4 -- `contentIdentity` should not be in the cell at all

Continues `12/H2`'s second half, but proposes a different answer than doc 12
considered. `12/F3` inference 3 killed the obvious fix: it is a monotonic
counter issued per printed cell, with 132K distinct values in one workload, so
16 bits overflows by 2x and narrowing needs a wrap or reuse policy.

The DanTerm-specific question doc 12 did not ask: **why is it per cell?** Its job
is to let link activation verify that a printed run still exists. A run is the
natural unit of that identity, and runs are already a structure the engine has.
If identity can live per run rather than per cell, the field leaves the cell
entirely -- 9 bytes -- with no width, wrap, or reuse policy to design.

This is speculative and needs the link-activation path read before it is
credible. It is stated here because it is the kind of answer doc 12's rules ask
for: DanTerm's own simpler solution rather than a narrower version of the
existing one.

### H5 -- rows should carry content-class skip flags

Continues `12/H4`. Cheap, independent of H1-H4. `12/F3` inference 4 already
sized it: a `styled` bit skips essentially every row on three of four workloads;
a `grapheme` bit is much blunter, skipping only ~41% of rows on the one workload
it targets, because 58.8% of `unicode-wrapping` rows contain at least one spill
cell despite spills being 0.61% of cells.

Primarily a draw-path win rather than a memory win. Carried here so it is not
lost, not because it reduces bytes.

### H6 -- scrollback rows are immutable and could be stored compactly

The one hypothesis with no antecedent in doc 12, and the one that follows most
directly from `F1`.

Rows in scrollback are **never mutated** -- they are appended, read, and
eventually evicted. Nothing requires them to keep the same representation as the
live screen, which must support arbitrary in-place cell writes. A compact
immutable form (packed scalars plus run-length styles, or similar) would apply
to the large majority of the 48.2 MB.

This is where libghostty's compression sits in its own design, and where doc
12's rule about taking DanTerm's simpler answer applies hardest: the goal is a
compact immutable row, not a port of a Zig arena. The cost is a conversion on
eviction from the screen and a decode on scrollback read, both of which need
measuring against the scroll and search paths before this is more than an idea.

Blocked on Phase 1: worth designing only if scrollback rather than the live
screen dominates resident rows, which `F1` suggests but does not establish (see
its uncertainty about the row count).

### H7 -- per-row allocation overhead and bucket rounding are a real fraction of the waste

`12/F1`: every row is a **separate heap allocation**. `F1` counted 3,528 of them
live. Each pays an allocation header, malloc bucket rounding, and its share of
the ~40 MB gap between dirty malloc pages and live bytes.

Distinct from doc 12's rejected page allocator, which was rejected as
non-transferable to a Swift COW-array engine. The narrow version -- fewer,
larger allocations for the immutable scrollback only, where rows are never
individually mutated -- does not require manual memory control and composes with
H6.

Unquantified. Needs the dirty-vs-live gap attributed first.

### H8 -- evicted scrollback rows are retained, and releasing them costs nothing

**Confirmed by `F4`**, and promoted to the head of the queue. `ScrollbackBuffer`
evicts by advancing an index without clearing the vacated slot, so it holds up
to 1x its live row count in rows the budget has already dropped -- ~19 MB at the
production budget, averaging half that, on a sawtooth.

This is the only item in this file that is **strictly free**: it is a bug fix,
not a tradeoff. It costs no scrollback depth (`H1` costs depth), no cell layout
change (`H2`, `H3`, `H6`), and no CPU -- clearing one slot is O(1) against a
front eviction that is already O(1), and it *removes* work from the periodic
compaction rather than adding any.

The remaining question is shape, not whether. Clearing `cells` on eviction is
the minimal change and is what `F4` confirmed. Eagerly compacting instead would
also fix it but reintroduces the O(n) copy the current threshold exists to
amortize. The decision belongs in `D1`.

## Candidate direction, pending evidence

Provisional, and deliberately ordered by evidence-per-unit-risk rather than by
bytes:

1. **H8**, because `F4` confirmed it, it is a defect rather than a design
   choice, and it is the only change here the user pays nothing for.
2. **H1**, because it is an accounting correction rather than a design change,
   its predicted effect is precise, and it validates the harness. Note that `F4`
   changes how to talk about it: the product currently over-retains for *two*
   independent reasons, and only one of them is the deliberate under-charge `H1`
   describes.
3. **H2**, because `12/F3` already proved the field is unused in 100% of census
   cells and doc 12 already named it the best first move.
4. **H6 or H3**, whichever Phase 1 says is larger -- they attack the same bytes
   from opposite ends (H3 shrinks every cell; H6 re-represents the rows that
   hold most of them), and doing both may be redundant.

H4, H5, H7 are not scheduled.

## Task ledger

### Phase 1 -- establish a trustworthy memory baseline

`F6` upgraded the first task below from important to **blocking**: no remaining
hypothesis in this file can be verified on `just benchmark-memory`, so the
headless harness is now the only instrument that can decide any of them.

- [ ] Build a headless terminal-state memory harness on the payload matrix
      (empty, full screen, 10K scrollback plain / unicode / styled / mixed),
      measuring **pure `Terminal` state** with no GUI, on the model of
      `scripts/terminal-feed-profile.py`. Record the per-payload resident bytes
      and bytes-per-cell in F2. This is the instrument every later phase reports
      against; nothing else in this file can be verified without it.
- [ ] Attribute the ~164 MB of `F1` footprint that is not live malloc heap
      (`vmmap` by region, Metal/CoreAnimation vs binary vs allocator). Record in
      F3, and state the resulting **ceiling** on what any cell-representation
      work can move in process terms.
- [x] Resolve `F1`'s row-count discrepancy: 3,528 live `[GridCell]` arrays
      against `12/F1`'s ~1,460 budget-admitted scrollback rows plus 66 screen
      rows. Determine whether the excess is render-side copies, damage
      snapshots, multiple `Terminal` instances in the benchmark app, or a
      retention bug. Record in F4. **A retention bug here would outrank every
      hypothesis in this file**, so this task gates the rest of the ledger.
      **Done -- `F4`.** It is a retention bug: `ScrollbackBuffer.removeFirst`
      leaves the evicted row's cells in the vacated slot, so the buffer holds up
      to 2x its live rows. Ungated; `H8` is now the first move.
- [ ] Attribute the ~40 MB gap between `MALLOC_SMALL` dirty pages and live heap
      bytes: allocator retention, fragmentation, or bucket rounding. Record in
      F5. Sizes H7 and sets expectations for how much any live-bytes win
      actually returns to the OS.

Sequencing note from `F4`: the two remaining Phase 1 attribution tasks (F3, F5)
measure quantities the `H8` sawtooth perturbs by up to 19 MB depending on when
the sample lands. **Take Phase 1.5 first**, then re-take them on a stable
baseline.

### Phase 1.5 -- release the retained rows (H8)

- [x] Decide the shape: clear the vacated slot's `cells` on eviction (minimal,
      what `F4` confirmed) versus eager compaction (also correct, but restores
      the O(n) copy the threshold exists to amortize). Record in D1.
      **Done -- `D1`**: reset the whole vacated slot, and hoist the `lastEvicted`
      row out of `enforceScrollbackBudget`. The ring buffer is deferred, not
      rejected -- see `D1`'s candidate 2.
- [x] Write the behavioral test first, per the project's TDD rule. It must pin
      the **observable** invariant -- that resident cell storage stays
      proportional to live scrollback rows across sustained front eviction -- and
      not the `storageStart`/`compactIfNeeded` internals, which are an
      implementation detail this file may later want to change for `H6`/`H7`.
      **Done.** `TerminalScrollbackRetentionTests`, against an internal
      `retainedCellStorageRowCount` phrased as the invariant. Fails at
      `worstExcess == 1023` before the fix, passes after.
- [x] Implement, then verify no CPU regression on `terminal-feed` and
      `scrollback-stream` per `10/F9`. The expectation is neutral-to-positive:
      one O(1) store added per eviction, less to copy on compaction.
      **Done -- `F6`.** All five routine workloads equivalent or inconclusive,
      none slower.
- [x] Re-run `just benchmark-memory scrollback-stream` and record the change in
      process footprint and in `_ContiguousArrayStorage<GridCell>` node count
      against `F1`'s artifact. Predicted: node count flat at ~1,783 instead of
      sawtoothing to ~3,500.
      **Done, and it failed as an experiment -- `F6`.** The instrument cannot
      resolve the change: one memgraph samples one arbitrary point on the
      sawtooth, and GUI IOSurface churn (50.6 MB) dwarfs the effect. The fix is
      verified by the behavioral test instead. **This promotes `F2` from "first
      Phase 1 task" to a hard blocker on every remaining hypothesis.**

### Phase 2 -- correct the accounting (H1)

- [ ] Decide whether `scrollbackByteCost` should charge true stride, and what
      the nominal budget becomes if it does. Record in D1. Explicitly a product
      decision about history depth, not only a correctness fix.
- [ ] Implement and verify on the Phase 1 harness plus `terminal-feed` and
      `scrollback-stream` for CPU non-regression.

### Phase 3 -- shrink the cell (H2, then H3 or H6)

- [ ] Take H2 (`hyperlinkId` to one bit plus side map). Verify stride, resident
      bytes, and CPU non-regression.
- [ ] Instrument style **write** traffic before H3 -- `12/F3`'s stated
      uncertainty, and the input that decides whether a refcounted dedup table
      pays. Record in a finding; do not implement H3 first.
- [ ] Gate: compare H3 and H6 against Phase 1 evidence and pick one, or
      establish that they compose. Record in D2.

### Backlog -- not scheduled, kept so it is not lost

- [ ] **Replace `ScrollbackBuffer`'s index-and-compact scheme with a true ring
      buffer** (`D1` candidate 2). Deferred, *not* rejected. It is the
      structurally pure answer -- it makes the dead prefix unrepresentable rather
      than merely empty, and removes the amortized compaction copy entirely.
      It was deferred only because `D1` recovers ~700x of the waste (19 MB ->
      27 KB) in one line, and the compaction copy that a ring buffer additionally
      eliminates **has never been measured as a cost**. The price is real: the
      buffer's capacity is dynamic (the budget is denominated in bytes and row
      cost varies with width), so growth still needs a path, and `asArray`,
      `suffix(from:)`, `indices`, and `Equatable` all acquire wraparound cases in
      a struct whose current surface is small and well covered.
      **Reopen when** any of: `F5` or `H7` shows compaction copying is a
      measurable share; `H6`'s compact immutable rows change the cost of a row
      move; or profiling attributes real time to `compactIfNeeded`. `D1`'s
      invariant-shaped test is deliberately written to survive this swap.

### Phase 4 -- close

- [ ] Final measurement on the Phase 1 harness across the full payload matrix,
      against the same matrix captured before any change.
- [ ] Record what the scrollback depth became at the chosen budget, and where
      the settled work graduated to.

## Findings log

### F1 -- 84% of the live heap is grid row storage, but the live heap is only a quarter of the process

- Status: recorded. Composition measurement of a running benchmark app.
- Date and investigator: 2026-07-29, Claude (agent).
- Commit and worktree state: working tree at `b645a22` plus the then-uncommitted
  memory profiler now at `1afed54`. The measured binary is the optimized
  benchmark app that harness built.
- Commands: `just benchmark-memory scrollback-stream 60 15`, then
  `heap -s -H <run>/final.memgraph` on the artifact it left.
- Result artifacts:
  `.build/terminal-benchmark-profiles/2026-07-29-112827-50226/`
  (`memory-report.json`, `baseline.memgraph`, `final.memgraph`,
  `heap-diff.txt`).
- Measurements:

  | quantity | value |
  | --- | ---: |
  | footprint, baseline -> final | 221.9 MB -> 222.0 MB |
  | growth over 42 s after 15 s warmup | 0.1 MB, 3.0 KB/s fitted |
  | `MALLOC_SMALL` dirty, baseline | 98.4 MB |
  | live heap | 57.6 MB in 72,838 nodes |
  | `_ContiguousArrayStorage<GridCell>` | 3,528 nodes, 48.2 MB |
  | next largest live class | 4.2 MB ("non-object", 30,373 nodes) |

- Observation 1: the workload is **flat**. Growth is 0.1 MB over 42 measured
  seconds, which for a workload continuously replaying a 25,000-line fixture
  means the scrollback bound holds. This file is therefore about **steady-state
  size, not a leak**.
- Observation 2: grid row storage is 48.2 MB of a 57.6 MB live heap. Everything
  else in the process's heap is rounding error against it.
- Observation 3: live heap is 57.6 MB of a 222.0 MB footprint. ~164 MB is
  outside the malloc heap entirely.
- Inference 1: doc 12's parked hypotheses point at the right bytes. Within the
  heap there is one target and it is the grid.
- Inference 2: process-level footprint is the wrong instrument for judging a
  cell change -- it dilutes the effect by roughly 4x. Phase 1's harness exists to
  avoid attributing that dilution to the change.
- Competing interpretations: the benchmark app is a GUI app driving Metal and
  CoreAnimation, so its non-heap footprint is not evidence about a headless
  embedder, and may not be evidence about production DanTerm either. This is
  what makes the Phase 1 attribution task worth doing rather than assuming.
- Uncertainty, and it is substantial:
  - **The 3,528 row count does not reconcile.** `12/F1` computes ~1,460 rows
    admitted by the 10 MB budget at 179 columns, plus 66 screen rows. The excess
    is unexplained and is Phase 1's gating task.
  - `heap`'s per-node "14.0K" is a **malloc bucket**, not an allocation size. No
    per-cell byte figure may be derived from it; `12/F1`'s stride of 72 is the
    authoritative number. An earlier reading of this artifact that divided the
    bucket by the column count to get "~80 bytes per cell" was wrong for exactly
    this reason.
  - A second run (`2026-07-29-113113-53056`, 30 s / 10 s warmup) recorded a
    **273.2 MB peak against a 222.7 MB baseline**. Unexplained; possibly the
    memgraph capture perturbing the target, possibly real transient allocation.
    Not chased.
- Next action: Phase 1, all four tasks. The row-count discrepancy first.

### F4 -- the row count does not reconcile because evicted scrollback rows keep their cells, so the buffer holds up to 2x its live rows

- Status: recorded, and the mechanism is confirmed by a controlled fix. Resolves
  `F1`'s gating uncertainty and `12/F1`'s implied row arithmetic.
- Date and investigator: 2026-07-29, Claude (agent).
- Commit and worktree state: `6170672`, tracked tree clean. Measured with a
  temporary internal probe (`scrollbackRetentionProbe`) on `ScrollbackBuffer`
  returning three `Int`s -- the same disposable-widening method as `12/F1` and
  `12/F3`. The probe and its test were reverted immediately; the tracked tree is
  unchanged.
- Method: a fresh `Terminal(columns: 179, rows: 66)` at
  `productionScrollbackBudgetBytes`, fed 40,000 lines of the actual
  `scrollback-stream` fixture template
  (`DANTERM-SCROLLBACK-%05d sustained plain-text output payload\n`,
  `scrollback-stream-v1-25000-lines`), sampled every 500 lines. The probe counts
  live rows, dead slots, and -- the number that matters -- **dead slots whose
  `cells` array is still populated**, which is what a `[GridCell]` allocation
  actually is.
- Mechanism: `ScrollbackBuffer.removeFirst` (`Terminal.swift:207`) returns
  `storage[storageStart]` and advances `storageStart`, but never clears the
  vacated slot. The evicted `GridRow` -- and the separate heap allocation its
  `cells` array owns (`12/F1` observation 1) -- stays reachable until
  `compactIfNeeded` rebuilds the array. Compaction requires
  `storageStart >= 1_024 && storageStart * 2 >= storage.count`, i.e. dead slots
  must reach the live count before anything is released. **The retention is
  therefore bounded at exactly 1x the live row count, and averages 0.5x.**
- Measurements:

  | quantity | value |
  | --- | ---: |
  | live scrollback rows, steady state | **1,717** (flat from ~iteration 1,500 on) |
  | model byte usage vs budget | 10,480,680 / 10,485,760 |
  | populated `[GridCell]` allocations, trough -> peak | **1,717 -> 3,431** measured (3,434 analytic) |
  | plus the 66 screen rows | **1,783 -> 3,497** |
  | `F1`'s `heap` count | **3,528** |
  | same probe with the one-line fix | **1,717, flat; peak 1,717** |

- Observation 1: the reconciliation is essentially exact at both ends. The
  trough, 1,783, is `12/F3`'s recorded resident row count for this workload **to
  the row**. The peak, 3,497, is within 31 of `F1`'s 3,528 -- 0.9%, and the
  residue is comfortably render-side and transient. `F1` happened to capture near
  the top of the sawtooth.
- Observation 2: a synthetic control of full-width 179-column lines pins live
  rows at **1,461**, which is `12/F1`'s ~1,460 budget arithmetic to the row. The
  budget bound is behaving exactly as documented; nothing was wrong with the
  arithmetic in `12/F1`. What it did not model is that the buffer holds rows the
  budget has already evicted.
- Observation 3: the waste is a sawtooth, not a plateau. Dead-cell count climbs
  linearly to the live count, then drops to zero on compaction. Any single
  footprint sample lands somewhere on that ramp, which is one plausible
  contributor to `F1`'s unexplained 273.2 MB peak against a 222.7 MB baseline.
- Inference 1, and it is the finding: **this is a retention bug, and it is the
  largest single memory defect found so far.** Roughly a third of resident
  `[GridCell]` allocations at any moment, and half at peak, are rows the terminal
  has already evicted, are unreachable by any user-visible operation, and return
  no scrollback depth. It is invisible to `scrollbackByteCount`, which counts
  only live rows -- which is why the budget looked healthy.
- Inference 2, sizing it, without deriving per-type bytes from `heap` per this
  file's rule. **Corrected 2026-07-29; the first version of this inference was
  wrong and is struck below.** Rows are *not* trimmed to their content -- a
  scrollback row carries a full `columnCount` of cells, which the cost model
  confirms: `16 + 179 * 32` is 5,744, and the observed average row cost of ~6,104
  bytes leaves ~45 scalars, consistent with a ~58-character line on a 179-column
  grid. At the true stride of 72 a row is therefore `179 * 72` = **12,888 bytes**,
  so 1,717 live rows are **~22.1 MB of real cell storage**, with an equal amount
  held dead at peak. `heap`'s 14.0K bucket against a 12,888-byte allocation puts
  bucket overhead at **~8.7%**, not the ~25% first computed.
  - ~~Superseded: "~262,000 cells, ~153 per row, ~11.0 KB per row, ~18.9 MB
    live, ~25% bucket overhead."~~ That derivation divided total model cost by
    rows while ignoring the model's `8 * scalars` term, which inflated the
    implied per-cell charge and so deflated the implied cell count. The error
    understated the waste by ~15%.
- Inference 2b: the corrected figure is what `H8` is worth -- **~22 MB at peak,
  ~11 MB on average**, at the production budget and 179 columns.
- Inference 3, on ordering: this displaces `H1` as the first move. `H1` corrects
  an accounting model and *reduces retained history* to do it; `H8` returns the
  same order of magnitude of bytes and costs the user nothing at all.
- Controlled confirmation: adding `storage[storageStart].cells = []` immediately
  before the `storageStart += 1` pins populated allocations at 1,717 flat, with
  the peak equal to the trough. This is stated as mechanism confirmation, not as
  the proposed patch -- see `H8` for why the shape still needs deciding.
- Competing interpretations: considered and eliminated. Not render-side copies,
  not damage snapshots, and not multiple `Terminal` instances -- the discrepancy
  reproduces in a **single headless `Terminal` with no GUI, no renderer, and no
  damage tracking**, and its trough and peak bracket `F1`'s count. Those three
  can at most account for the residual 31.
- Uncertainty:
  - The residual 31 allocations between 3,497 and 3,528 are not attributed. They
    are 0.9% and do not change any conclusion, but they are also the only part of
    `F1`'s count that is still unexplained.
  - The sawtooth means the *phase* at which any footprint sample is taken matters
    by up to 19 MB. Every measurement in this file taken before the fix lands
    carries that as noise, including `F1` itself.
  - `removeLast` and `removeAll(keepingCapacity:)` were read and do not have this
    problem; `removeLast` shrinks `storage` and `removeAll` drops it. Only the
    front-eviction path leaks, which is also the only path the budget uses.
- Next action: `H8`, and it should precede the remaining Phase 1 tasks --
  `F3` and `F5` both measure quantities this bug perturbs by up to 19 MB.

### F6 -- the fix is CPU-neutral, and the GUI memory benchmark cannot see it at all

- Status: recorded. Verification of `D1`, and a negative result about the
  instrument that matters more than the verification does.
- Date and investigator: 2026-07-29, Claude (agent).
- Commit and worktree state: baseline `22a08b1`; candidate is that tree plus
  `D1`'s two edits.

**CPU: no regression.** `just benchmark-quick baseline=HEAD` on `terminal-feed`,
then `just benchmark-confirm baseline=HEAD` across all five routine workloads:

  | workload | verdict |
  | --- | --- |
  | `terminal-feed` | equivalent (-0.61%, 2 pairs) |
  | `scrollback-stream` | inconclusive (-0.86%, 4 pairs) |
  | `content-churn` | inconclusive (-1.46%, 4 pairs) |
  | `style-churn` | equivalent (-0.62%, 4 pairs) |
  | `incremental-mixed` | inconclusive (-0.81%, 6 pairs) |

- Nothing is slower, and every magnitude is under 1.5%. Worth recording as
  method: an earlier 2-pair `benchmark-quick` on `scrollback-stream` read
  **+1.05%**, which the 4-pair confirm run flipped to **-0.86%**. The sign
  reversal is what a noise reading looks like; a 2-pair "inconclusive" is not a
  weak regression signal and should not be reported as one.

**Memory: the instrument could not resolve it.** Two `just benchmark-memory
scrollback-stream 60 15` runs, same binary and geometry (179x66), differing only
by `D1`:

  | | footprint baseline -> final (peak) | `[GridCell]` nodes | bytes |
  | --- | --- | ---: | ---: |
  | with `D1` | 192.9 -> 193.0 MB (243.5) | **3,287** | 44.9 MB |
  | without `D1` | 222.8 -> 273.3 MB (273.3) | **3,096** | 42.3 MB |

- Observation: the fixed build reports **more** row arrays than the unfixed one.
  The measurement is not merely insensitive, it is directionally wrong.
- Inference 1: this is exactly the sawtooth `F4` warned about. A memgraph is one
  sample at one arbitrary point on a ramp that spans 1,717 to 3,431 allocations,
  so a single capture of each arm compares two unrelated phases. Nothing about
  these two numbers is comparable, and the ~200-node difference is phase, not
  effect.
- Inference 2: a second, independent confound. The unfixed run grew **50.6 MB of
  IOSurface** over 42 s while its `MALLOC_SMALL` stayed flat at 0.0 MB. That is
  GUI compositing, has nothing to do with the terminal, and is more than twice
  the size of the effect being measured. It also retroactively explains `F1`'s
  unattributed "273.2 MB peak against a 222.7 MB baseline" -- same magnitude,
  same workload, and it is IOSurface rather than anything on the heap.
- Inference 3, and the one that should change plans: **`just benchmark-memory`
  is a leak detector, not a measurement instrument for representation work.** It
  was built to answer "is this growing without bound", which `F1` used it for
  correctly. It cannot answer "did this change reduce resident cell bytes", which
  is the question the rest of this file asks. `H1` anticipated this in the
  abstract -- "any harness that cannot see it is not sensitive enough for the
  rest of the file" -- and this is the concrete demonstration.
- Inference 4: Phase 1's headless harness (`F2`) is therefore not merely the
  cleanest way to measure the remaining hypotheses, it is the **only** way. It
  should be built before `H1`, `H2`, `H3`, or `H6` is attempted, and it must
  either sample the allocation curve over time or drive the terminal to a
  deterministic phase, because a single snapshot of a sawtoothing quantity is not
  a measurement.
- How `D1` is verified instead: deterministically and headlessly. The behavioral
  test drives >1,024 evictions and asserts the retained-vs-live excess **at every
  step**, giving 1,023 on the old code and 0 on the new. That is a stronger proof
  than any footprint delta would have been, and it is immune to both confounds
  above.
- Competing interpretations: it remains possible that the GUI app holds row
  arrays this file has not accounted for -- both arms report ~3,100-3,300 where
  the headless terminal peaks at ~3,500 and would now sit at ~1,783. The
  candidate arm should have dropped to roughly 1,783 + screen if `Terminal` were
  the only owner. Either the sawtooth phase explains it, or something else in the
  app retains rows. **This is not resolved**, and it is the live question below.
- Uncertainty: the whole memory comparison is uninformative rather than
  negative -- it neither confirms nor refutes the ~22 MB saving. The saving rests
  on `F4`'s deterministic headless numbers, which are solid, plus arithmetic.
- Next action: `F2`, and treat it as blocking for every remaining hypothesis.
  Then re-take `F3` and `F5` on it rather than on `benchmark-memory`.

## Decision log

### D1 -- release evicted scrollback rows by resetting the vacated slot, and defer the ring buffer

- Status: decided, pending implementation. Phase 1.5.
- Date and investigator: 2026-07-29, Claude (agent).
- Evidence used: `F4` (mechanism, sizing, and controlled confirmation), plus a
  read of the three call sites that constrain the change:
  - `enforceScrollbackBudget` (`Terminal.swift:2818`) computes
    `scrollbackByteCost(of: evicted)` on the **returned** row, so the fix must
    not disturb it. It does not: `removeFirst` returns a value copy holding its
    own reference to the cells array.
  - `storage` is already uniquely referenced on the hot path --
    `appendToScrollback` mutates it immediately before eviction -- so an in-place
    slot write triggers no COW copy of the array.
  - `damageActionSnapshot` holds no rows, so the per-action snapshot does not
    share `storage` either. The only whole-`Terminal` copy is
    `withUnlimitedScrollbackForTesting`.
- Candidate solutions:

  | | Approach | Peak dead bytes | Cost per eviction | Verdict |
  | --- | --- | ---: | --- | --- |
  | 1 | Reset the vacated slot | ~27 KB (row shells only) | O(1) store | **selected** |
  | 2 | True ring buffer | 0 | O(1), no compaction at all | **deferred, not rejected** |
  | 3 | Compact on every eviction | 0 | **O(n)** | rejected |
  | 4 | Tighten the threshold to 8x | ~2.4 MB | O(1) amortized, 4x more copying | rejected |
  | 5 | `[GridRow?]`, nil the slot | ~27 KB | O(1) store | rejected |

- Why 3 and 4 need no measurement to reject. Candidate 3 turns a per-line
  eviction into a full-array copy per line at steady state on
  `scrollback-stream`, which is exactly what `compactIfNeeded`'s threshold exists
  to amortize. Candidate 4 is **strictly dominated** by candidate 1 on both axes:
  it leaves ~2.4 MB of waste standing *and* quadruples compaction copying.
  Candidate 5 buys nothing over 1 while paying an optional discriminator in every
  live slot and an unwrap in the hot subscript.
- Selected direction: reset the whole slot rather than only emptying `cells`.

  ```swift
  let row = storage[storageStart]
  storage[storageStart] = GridRow(cells: [])   // a slot below storageStart owns nothing
  storageStart += 1
  ```

  Same cost as clearing `cells` alone, but it states the invariant -- *a slot
  below `storageStart` owns nothing* -- instead of leaving a slot that has no
  cells yet still claims a `isSoftWrapped` / `semanticPrompt` identity. Verified
  safe against the rest of the struct: `==` compares only `lhs[i]` over live
  `indices`, and `asArray` / `suffix(from:)` read only from `storageStart`
  onward, so no dead slot is ever observed. `removeLast` and
  `removeAll(keepingCapacity:)` already release their rows and are untouched.
- Folded into the same change: `enforceScrollbackBudget` holds
  `var lastEvicted: GridRow?` across the whole eviction loop and until scope
  exit, purely to read `.isSoftWrapped` afterward. That pins one full row's cells
  (~11 KB) for no reason. Hoist the `Bool` instead. Same defect class, same
  function, free.
- Tradeoffs and correctness risks: the invariant ends up expressed in one line
  and nothing structurally prevents a future eviction path from omitting it.
  That is the whole reason the behavioral test below is worth its cost. There is
  no correctness risk to observable behavior -- dead slots are unreachable
  through every accessor.
- Consequence worth noting: after this lands, `compactIfNeeded`'s threshold is
  trading copy work against **16 bytes** per dead slot rather than ~11 KB, so it
  becomes a pure CPU decision and could reasonably be *raised* to copy less. Not
  proposed here; recorded so the threshold is not over-tuned on the old premise.
- This does not touch `scrollbackByteCount`, which was always correct about live
  rows. `H1` remains independent.
- Outcome: implemented and verified. Both edits landed as described. The
  behavioral test fails on the old code at `worstExcess == 1023` -- exactly
  `compactIfNeeded`'s floor -- and passes after. Full `just test` gate green
  (645 core tests, one pre-existing unrelated known issue). CPU verified in `F6`;
  the memory verification did **not** go as planned, also `F6`.
- Behavioral verification: see the Phase 1.5 ledger. The invariant is not
  observable through the public API, so the test needs an internal accessor; it
  must express the **invariant** (`retainedCellStorageRowCount` -- rows for which
  the buffer still owns cell storage) rather than the **mechanism**
  (`storageStart`, `storage.count`). A mechanism probe would be coupled to
  exactly the layout candidate 2, `H6`, and `H7` may later replace; an invariant
  probe survives all three, since a ring buffer would answer it with `count`.
- Quantitative verification: ~~`_ContiguousArrayStorage<GridCell>` node count flat
  near 1,783 instead of sawtoothing to ~3,500, against `F1`'s artifact.~~
  **This prediction was correct but unmeasurable on the instrument named.** See
  `F6`: `just benchmark-memory` cannot resolve the change, because a single
  memgraph samples one arbitrary point on the sawtooth and GUI-side IOSurface
  churn is an order of magnitude larger than the effect. The fix is verified
  deterministically instead, headlessly, by the behavioral test.

## Rejected

Inherited from doc 12, with its evidence. Neither may be reopened here without
new evidence of the kind each names.

### The POD cell (`12/F4` -> `12/F7` -> `12/F8`)

Implemented and reverted in `94a1528`. Delivered -8.83% on `terminal-feed` but
**+6.74% slower** on `scrollback-stream`, decided, with no outlier pairs, at the
price of a permanent invariant (a cell's scalars resolve only against its owning
row). Reopening needs a materially different cost model, not another attempt.

Note the asymmetry that makes this file different from doc 12: that rejection
was made on **CPU** grounds against a candidate whose motivation was CPU. A
memory-motivated change that happens to make the cell trivial would have to
clear the same `scrollback-stream` bar, but it would be bought for a different
reason. `12/F8` records precisely what would have to change.

### libghostty's page allocator

Explicitly not proposed by doc 12: it depends on Zig's manual memory control and
does not transfer to a Swift value-type engine with COW arrays. H7's narrow
version -- fewer, larger allocations for immutable scrollback only -- is a
different proposal and is not covered by this rejection.

## Open questions and caveats

- ~~The row-count discrepancy is the largest single unknown~~ **Resolved by
  `F4`**, and it resolved the way this entry feared: 3,528 reflects retention,
  not budget, and the fix is a bug fix worth more than any representation change.
  It is now `H8` and heads the queue.
- Resident rows are dominated by scrollback, not by render-side copies -- `F4`
  reproduced `F1`'s count in a headless `Terminal` with no renderer at all. That
  is the precondition `H6` was blocked on, so **`H6` is unblocked**.
- Every memory measurement taken before `H8` lands carries up to ~19 MB of
  sawtooth-phase noise, `F1` included. Do not compare a pre-`H8` footprint
  against a post-`H8` one and attribute the whole delta to a later change.
- The census underlying `12/F3` is of DanTerm's four fixture workloads, which
  are markedly less styled than plausible real sessions. That weakens confidence
  in H3's table staying small under real use, and doc 12 flagged it too.
- Whether any live-bytes win actually returns pages to the OS is unestablished;
  `F1`'s 40 MB dirty-vs-live gap suggests the return rate is not 1:1.
- No production memory target exists. This file measures and reduces; it does
  not know what "enough" is, and should not invent one.

## Outcome

Investigation in progress. Findings F1, F4, and F6 are recorded; the next free
IDs are **F2**, **F3**, **F5**, and then **F7**. Decision D1 is recorded and
implemented; the next free ID is **D2**.

`F4` closed Phase 1's gating task and changed the plan: the largest defect found
so far is a scrollback retention bug (`H8`), not a representation problem, and
it is the only item here that costs the user nothing. Phase 1.5 shipped it
(`D1`) -- ~22 MB of already-evicted rows at peak, released, with no CPU cost on
any of the five routine workloads.

`F6` then changed the plan a second time, and this is the more important of the
two for whoever picks this up. **`just benchmark-memory` cannot measure
representation work.** Asked to confirm a ~22 MB saving it reported the fixed
build as *larger*, because one memgraph samples one arbitrary point on a
sawtooth and because GUI IOSurface churn is twice the size of the effect. It
remains a good leak detector, which is what `F1` used it for. It is not a
measurement instrument. So Phase 1's headless harness (`F2`) is no longer the
first task among four -- it is a hard blocker on `H1`, `H2`, `H3`, and `H6`
alike, and `F3` and `F5` should be taken on it rather than on
`benchmark-memory`. Build it next.
