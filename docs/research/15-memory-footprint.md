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

## Candidate direction, pending evidence

Provisional, and deliberately ordered by evidence-per-unit-risk rather than by
bytes:

1. **H1**, because it is an accounting correction rather than a design change,
   its predicted effect is precise, and it validates the harness.
2. **H2**, because `12/F3` already proved the field is unused in 100% of census
   cells and doc 12 already named it the best first move.
3. **H6 or H3**, whichever Phase 1 says is larger -- they attack the same bytes
   from opposite ends (H3 shrinks every cell; H6 re-represents the rows that
   hold most of them), and doing both may be redundant.

H4, H5, H7 are not scheduled.

## Task ledger

### Phase 1 -- establish a trustworthy memory baseline

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
- [ ] Resolve `F1`'s row-count discrepancy: 3,528 live `[GridCell]` arrays
      against `12/F1`'s ~1,460 budget-admitted scrollback rows plus 66 screen
      rows. Determine whether the excess is render-side copies, damage
      snapshots, multiple `Terminal` instances in the benchmark app, or a
      retention bug. Record in F4. **A retention bug here would outrank every
      hypothesis in this file**, so this task gates the rest of the ledger.
- [ ] Attribute the ~40 MB gap between `MALLOC_SMALL` dirty pages and live heap
      bytes: allocator retention, fragmentation, or bucket rounding. Record in
      F5. Sizes H7 and sets expectations for how much any live-bytes win
      actually returns to the OS.

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

- **The row-count discrepancy is the largest single unknown** and could
  invalidate the ordering of every hypothesis here. If 3,528 live row arrays
  reflect retention rather than budget, the fix is a bug fix worth more than any
  representation change.
- Whether resident rows are dominated by scrollback or by render-side copies
  decides H6's value, and is not yet known.
- The census underlying `12/F3` is of DanTerm's four fixture workloads, which
  are markedly less styled than plausible real sessions. That weakens confidence
  in H3's table staying small under real use, and doc 12 flagged it too.
- Whether any live-bytes win actually returns pages to the OS is unestablished;
  `F1`'s 40 MB dirty-vs-live gap suggests the return rate is not 1:1.
- No production memory target exists. This file measures and reduces; it does
  not know what "enough" is, and should not invent one.

## Outcome

Investigation in progress. Findings F1 is recorded; the next free ID is **F2**.
