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
- **Feed like a PTY, not like a file.** Added by `F7`, which cost a finding.
  `Terminal.feed` allocates one action per input token for the whole call, so
  feeding a payload in one shot charges the measurement tens of MB that a real
  session never pays. The probe chunks by default; if you write a new harness,
  chunk it, and check that your census is chunk-invariant.
- **Before believing a memory number, vary something that should not matter.**
  Sawtooth phase, feed chunk size, and column count each exposed a wrong number in
  this file (`F6`, `F7`, and `F7`'s diagnosis respectively). A quantity that moves
  when it should not is measuring the instrument.
- **Size cell-representation changes in malloc buckets, not in stride.** `F7`
  inference 4: rows round up to a bucket, so a shrink that does not cross a
  boundary returns nothing resident even though stride fell. `F10` found the
  effect runs both ways -- it *amplified* a 22% stride cut into a 24% footprint
  cut, by moving the row onto a boundary. Bucket placement is not derivable from
  stride in either direction. Measure it.
- **Before proposing where a field should go, measure what it costs where it
  is.** `F10`: `hyperlinkId` looked like an 8-byte field and was a 16-byte one,
  because `Int?` alignment could not use the padding `TerminalStyle` leaves. A
  two-byte type recovered all of it and made the side map `H2` specified
  unnecessary. Read the offsets before designing the fix.
- **`incremental-mixed` cannot currently decide a ~3% effect.** Its draw metric
  has a paired SD of 6.26% against the 1.85% threshold it is judged by, and
  returns false directional verdicts on byte-identical code -- measured in
  `plans/wip/f7-arm-confound-diagnosis.md` and reproduced by `F10`'s A/A control,
  which read `faster (-3.30%)` with no code difference at all. Run an A/A control
  before believing any `incremental-mixed` verdict under ~5%.

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

### H2 -- `hyperlinkId` should be one bit plus a side map -- **CONFIRMED, by a simpler route (`D3`/`F10`)**

**Taken.** The cell is 72 -> 56 bytes, `scrollback-stream` is 18-19% faster, and
history at 10 MB rises ~810 -> ~1,041 rows. But the side map below was *not*
built: `F10` measured that narrowing the field to `UInt16?` reaches the same
stride, because the cost was the `Int?`'s 8-byte alignment rather than its eight
bytes. See `D3`. The text below is kept as recorded.


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

**`F11` measured it, and it re-specifies this hypothesis.** Writes are 9-23
million per corpus against 1-5 distinct values, so the refcount is the whole
problem and the lookup is nothing: `H3` should sweep a live set the way
`hyperlinkTargets` already does, and charge zero per cell write. Re-sized against
the post-`D3` cell it is worth 16 bytes (stride 56 -> 40), still the largest
single win available, though malloc bucket placement returns some of it.

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

**`F12` measured it and sent it back.** The narrowing works -- stride 48 -- but at
179 columns the row stays in the same malloc bucket, so the eight bytes go to the
allocator and the budget's stride-based arithmetic then admits 15% more rows at
unchanged cost: **+1.8 MB**. At 80 columns the identical change is worth -26%.
`H4`'s cheap half is therefore geometry-dependent on its own and must ride behind
`H3`, which crosses a boundary at every width checked. It also needs the
identity-wrap fix `F12` records.

**`F10` re-sizes it, and softens the objection.** With the link id narrowed,
`contentIdentity` is the last `Int?` in the cell and is now the *only* thing
holding stride at 56: narrowing it to `UInt32?` measures **48**, and removing it
measures 40. So this is worth ~8 bytes per cell, ~14%, and 132K distinct values
fit in 32 bits comfortably -- the width objection `12/F3` raised applies to 16
bits, not to 32. A `UInt32?` is the cheap half of this hypothesis and does not
need the per-run redesign; the redesign is only needed for the other 8 bytes.

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

**Quantified by `F7`, and smaller than `F3/F5` made it look.** Bucket rounding
is a flat **1,488 bytes per row** at 179 columns -- 11.5% of cell bytes, 2.5 MB
at the production budget -- plus ~4 MB of `MALLOC_SMALL` slack. Real, worth
having, and recoverable by fewer-larger-allocations. But it is not the ~2x tax
`F3/F5` reported, so H7 ranks **below** H2 and H3 rather than above them.

`F7` inference 4 is the part that changes how H2 and H3 are estimated: a row at
179 columns is 12,888 bytes inside a 14,336-byte bucket, so a cell shrink that
does not push the row across the boundary below returns nothing resident. Size
every cell-shrink proposal in **bucket** terms and verify it on the probe.

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

**Phase 1 outcome: this ordering stands.** `F3/F5` briefly argued for hoisting
`H7`/`H6` above `H3` on the strength of a ~2x allocator multiplier; `F7` showed
that multiplier was ~1.15x once the probe stopped measuring its own feed call.
Cell bytes are ~85% of the cost of holding a terminal, so shrinking the cell
returns close to face value and the list above needs no reordering. The one
change `F7` forces is arithmetic, not sequence: size cell shrinks in **bucket**
terms (`F7` inference 4), because a row that stays inside its current malloc
bucket returns nothing.

## Task ledger

### Phase 1 -- establish a trustworthy memory baseline

`F6` upgraded the first task below from important to **blocking**: no remaining
hypothesis in this file can be verified on `just benchmark-memory`, so the
headless harness is now the only instrument that can decide any of them.

- [x] Build a headless terminal-state memory harness on the payload matrix
      (empty, full screen, 10K scrollback plain / unicode / styled / mixed),
      measuring **pure `Terminal` state** with no GUI, on the model of
      `scripts/terminal-feed-profile.py`. Record the per-payload resident bytes
      and bytes-per-cell in F2. This is the instrument every later phase reports
      against; nothing else in this file can be verified without it.
      **Done -- `F2`.** `just terminal-memory-probe`, backed by a public
      `Terminal.memoryCensus`, so the grid can be measured without the
      widen-and-revert method that made `12/F1` and `12/F3` unrepeatable.
- [x] Attribute the ~164 MB of `F1` footprint that is not live malloc heap
      (`vmmap` by region, Metal/CoreAnimation vs binary vs allocator). Record in
      F3, and state the resulting **ceiling** on what any cell-representation
      work can move in process terms.
      **Done -- `F3/F5`,** and it reframed the question. Measured headlessly the
      ceiling is stark: cell bytes are only **35-50%** of what the process pays,
      so halving the cell moves ~11 MB of a ~50 MB cost.
- [x] Resolve `F1`'s row-count discrepancy: 3,528 live `[GridCell]` arrays
      against `12/F1`'s ~1,460 budget-admitted scrollback rows plus 66 screen
      rows. Determine whether the excess is render-side copies, damage
      snapshots, multiple `Terminal` instances in the benchmark app, or a
      retention bug. Record in F4. **A retention bug here would outrank every
      hypothesis in this file**, so this task gates the rest of the ledger.
      **Done -- `F4`.** It is a retention bug: `ScrollbackBuffer.removeFirst`
      leaves the evicted row's cells in the vacated slot, so the buffer holds up
      to 2x its live rows. Ungated; `H8` is now the first move.
- [x] Attribute the ~40 MB gap between `MALLOC_SMALL` dirty pages and live heap
      bytes: allocator retention, fragmentation, or bucket rounding. Record in
      F5. Sizes H7 and sets expectations for how much any live-bytes win
      actually returns to the OS.
      **Partially done -- `F3/F5`.** The gap scales with eviction churn, not with
      resident size. Fragmentation, unreturned pages, and genuine retention are
      **not yet separated**; that separation is the next measurement and gates
      acting on `H7`.

- [x] Separate fragmentation from unreturned pages from genuine retention in the
      ~2x multiplier `F3/F5` measured, via `malloc_zone` statistics or a `vmmap`
      at the end of a probe run. Until this lands, do not treat the multiplier as
      a fixed tax, and do not act on `H7`.
      **Done -- `F7`, and the multiplier was largely the instrument.** Feeding
      each payload in one call made `feed` materialize a ~620,000-element action
      array; chunking to PTY-sized reads drops the footprint delta from 64.5 MB to
      25.1 MB with a bit-identical census. What remains splits cleanly: cells
      21.75 MB, bucket rounding 2.5 MB (a flat 1,488 B/row), `MALLOC_SMALL` slack
      ~4 MB, genuine retention **zero**. `H7` is now quantified and demoted.

**Phase 1 is closed.** Every question it opened is answered, and two of its four
answers were corrections to its own instruments (`F6`, `F7`).

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

- [x] Decide whether `scrollbackByteCost` should charge true stride, and what
      the nominal budget becomes if it does. Record in D1. Explicitly a product
      decision about history depth, not only a correctness fix.
      **Split in `D2`.** The accounting half is decided and shipped: charge true
      stride. The nominal-value half is deliberately left open, and now includes a
      third option -- denominate the limit in **lines** rather than bytes, which
      would decouple every remaining hypothesis from a product decision.
- [x] Implement and verify on the Phase 1 harness plus `terminal-feed` and
      `scrollback-stream` for CPU non-regression.
      **Done -- `F9`.** Cell storage 21.75 -> 10.77 MB, footprint 25.02 -> 12.63 MB,
      history 1,704 -> 810 rows. No decided CPU regression on any of the five
      workloads.

- [ ] **Decide the budget's nominal value and its unit** (`D2`'s open question).
      Blocked on nothing technically, but better taken after `H2`/`H3`, which move
      stride and therefore move depth at any fixed byte budget.

### Phase 3 -- shrink the cell (H2, then H3 or H6)

- [x] Take H2 (`hyperlinkId` to one bit plus side map). Verify stride, resident
      bytes, and CPU non-regression.
      **Done -- `D3`/`F10`, and the side map was not needed.** Narrowing the field
      to `UInt16?` reaches the same 56-byte stride, because the cost was the
      `Int?`'s alignment rather than its size. Stride 72 -> 56, per-row bucket
      overhead 1,487 -> 255 bytes, `scrollback-stream` **18-19% faster** across two
      runs. At a fixed budget the win is spent on history (+26% rows), not on
      memory.
- [x] Instrument style **write** traffic before H3 -- `12/F3`'s stated
      uncertainty, and the input that decides whether a refcounted dedup table
      pays. Record in a finding; do not implement H3 first.
      **Done -- `F11`. A refcounted table does not pay; a swept one does.** Stores
      run 9-23 million per corpus while distinct values run 1-5, so the read path
      is free and the *store* path is where a refcount would charge. `H3` should
      reuse the live-set sweep `hyperlinkTargets` already uses. Worth 16 bytes
      (stride 56 -> 40), the largest win left, but the bucket cuts against it this
      time: -28.6% stride buys only ~-20% resident.
- [ ] Gate: compare H3 and H6 against Phase 1 evidence and pick one, or
      establish that they compose. Record in D2.
      **Partly answered by `F12`.** They compose, and ordering is forced: at wide
      geometries a 179-column row costs the same anywhere between ~43 and 56
      bytes, so per-field narrowing below `H3` is spent on the allocator, not on
      the user. `H3` (stride 40) crosses a bucket boundary at every width checked;
      `H4` alone does not.
- [x] **Decide whether the budget should charge the allocated row rather than
      `columns * stride`** (`F12`). This is what makes any further cell shrink
      safe at every geometry: today a cheaper cell can admit more rows than the
      allocator got cheaper, which is how `H4`'s cheap half turned into +1.8 MB
      at 179 columns. Same species as `F9`'s correction; sits next to `D2`'s open
      unit question and should be decided with it.
      **Done -- `D4`/`F13`.** Charges `cells.capacity` rather than `cells.count`,
      which reads the allocator's own rounding instead of modelling it. History
      now lands within ~1% of the configured budget at both 179 and 80 columns,
      against 8-17% over before, at no CPU cost. Depth falls 1.5% at 179 columns
      and 10.7% at 80.

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

### F2 -- the headless probe, and the first exact baseline of what terminal state costs

- Status: recorded. The Phase 1 instrument now exists and has produced its first
  matrix. Closes Phase 1's first task and unblocks the rest of the file.
- Date and investigator: 2026-07-29, Claude (agent).
- Commit and worktree state: `bd0f1c2` plus the probe.
- Instrument: `just terminal-memory-probe`, a headless executable that feeds each
  payload to a fresh `Terminal` -- no GUI, no renderer, no sampling -- and reports
  `Terminal.memoryCensus`. The census is **public API now**, not a widened
  `private` walked once and reverted, which is what makes `12/F1` and `12/F3`
  unrepeatable. Cell bytes are exact `MemoryLayout` stride arithmetic. A
  determinism test asserts two runs produce identical census values.
- Matrix at 179x66, production budget, 10,000 lines per scrollback payload:

  | payload | rows | cells | cell bytes | B/cell | row allocs |
  | --- | ---: | ---: | ---: | ---: | ---: |
  | empty | 66 | 11,814 | 0.81 MB | 72.0 | 66 |
  | full-screen | 201 | 35,979 | 2.47 MB | 72.0 | 201 |
  | scrollback-plain | 1,770 | 316,830 | 21.75 MB | 72.0 | 1,770 |
  | scrollback-unicode | 1,831 | 327,749 | 22.50 MB | 72.0 | 1,831 |
  | scrollback-styled | 1,815 | 324,885 | 22.31 MB | 72.0 | 1,815 |
  | scrollback-mixed | 1,805 | 323,095 | 22.19 MB | 72.0 | 1,805 |

- Content shape, which is what sizes `H2`/`H3`/`H4`:

  | payload | styled cells | distinct styles | multi-scalar | hyperlink | distinct identities |
  | --- | ---: | ---: | ---: | ---: | ---: |
  | empty | 0 | 1 | 0 | 0 | 0 |
  | full-screen | 0 | 1 | 0 | 0 | 35,800 |
  | scrollback-plain | 0 | 1 | 0 | 0 | 90,219 |
  | scrollback-unicode | 0 | 1 | 2,743 | 0 | 39,345 |
  | scrollback-styled | 56,234 | **193** | 0 | 0 | 56,234 |
  | scrollback-mixed | 18,631 | 65 | 903 | 0 | 62,254 |

- Observation 1: **a bounded scrollback costs ~22 MB of cell storage against a
  10 MB budget**, and does so on every payload regardless of content. That is
  `H1`'s ~1.8x under-charge, now measured rather than derived: the budget admits
  ~1,770-1,830 rows and each is a full 179 cells at stride 72. `H1`'s predicted
  magnitude is confirmed.
- Observation 2: **content barely moves the total.** Plain, unicode, styled, and
  mixed all land within 0.75 MB of each other, because the budget is denominated
  in a cost model that content perturbs only slightly, and every row is
  full-width regardless. Memory is a function of the budget, not of what the user
  ran.
- Observation 3, and it is bad news for `H3`: a payload built to *stress* styling
  produces **193 distinct styles**, against the at-most-9 doc `12/F3` found in
  the fixture corpus. `12/F3` flagged exactly this as its uncertainty -- that the
  corpus was less styled than real sessions -- and the flag was justified. 193 is
  still small enough for a 16-bit id, so `H3` is not refuted, but the "trivially
  small table" premise rests on the corpus rather than on anything intrinsic.
- Observation 4: `hyperlinkId` is nil in **100% of cells on every payload**,
  reproducing `12/F3` inference 3 on an independent corpus. `H2` is the
  best-evidenced hypothesis in the file.
- Observation 5: distinct content identities track printed cells almost exactly
  on every payload, independently reproducing the observation that killed
  narrowing the field to 16 bits. `H4`'s "move it out of the cell entirely"
  framing is the only remaining route.
- Inference: within terminal state there is no content-dependent memory problem
  to solve. There is a **budget-accounting** problem (`H1`, ~12 MB over budget)
  and a **per-cell size** problem (`H2`, `H3`, `H6`), and they are independent.
- Uncertainty: the probe measures a `Terminal` in isolation. What the app adds on
  top -- render-side copies, the ~1,300 unexplained row arrays in `F6`'s GUI
  comparison -- is still unaccounted, and the probe cannot see it by design.
- Next action: `F3`/`F5` attribution, below, then `H1`.

### F3/F5 -- cell storage is only ~35-50% of what the process pays to hold it

- Status: **superseded by `F7`. Do not cite the numbers below.** Its method fed
  each payload to `Terminal.feed` in one call, and the resulting transient action
  array -- not the terminal -- is most of the gap it measured. Corrected coverage
  is 0.83-0.87, not 0.35-0.50, and inference 2 below is withdrawn. Kept in full
  because the reasoning was sound given the instrument, and because the way it
  failed is the reusable lesson: it explained a real, reproducible 2x gap with a
  plausible mechanism (eviction churn) that survived a competing-interpretations
  pass, and was still wrong about the cause.
- Status when recorded: partial. Answered Phase 1's remaining two attribution
  tasks well enough to size `H7`, and superseded the framing of both: the question
  is not "footprint minus heap" but "process bytes per cell byte".
- Date and investigator: 2026-07-29, Claude (agent).
- Method: one probe process **per payload** (`--payload NAME`), so the footprint
  delta is attributable. In a full-matrix run the allocator reuses pages the
  previous payload freed and every delta after the first understates its payload
  -- the run that motivated this reported 59.75 MB for `scrollback-plain` and
  0.02 MB for `scrollback-mixed`, which is an artifact, not a result.
- Measurements, fresh process each:

  | payload | cell bytes | process delta | coverage |
  | --- | ---: | ---: | ---: |
  | empty | 0.81 MB | 1.03 MB | 0.79 |
  | full-screen | 2.47 MB | 3.33 MB | 0.74 |
  | scrollback-plain | 21.75 MB | 62.98 MB | **0.35** |
  | scrollback-unicode | 22.50 MB | 44.73 MB | 0.50 |
  | scrollback-styled | 22.31 MB | 49.19 MB | 0.45 |
  | scrollback-mixed | 22.19 MB | 48.47 MB | 0.46 |

- Observation: coverage falls from ~0.75 on shallow payloads to **0.35-0.50** on
  deep ones. A terminal holding 22 MB of cells costs the process 45-63 MB.
- Inference 1: the gap scales with **eviction churn**, not with resident size.
  The shallow payloads never evict; the deep ones append ~10,000 rows and evict
  ~8,200, each a ~12.6 KB malloc and free. `scrollback-plain` is both the most
  churn-heavy and the worst-covered.
- ~~Inference 2, which reorders the file: **the multiplier is worth more than the
  cell.** Halving the cell halves the 22 MB but leaves the ~2x allocator
  multiplier untouched, so it moves ~11 MB of a ~50 MB cost. Fewer, larger, less
  churn-prone allocations attack the multiplier directly. That is `H7` and `H6`,
  and this is the first evidence that either outranks `H3`.~~ **Withdrawn by
  `F7`.** The multiplier is ~1.15x, not ~2x; the cell is ~85% of the cost.
- Competing interpretations, and they are live: this delta includes transient
  feed allocations the allocator has not returned, so "fragmentation",
  "unreturned pages", and "genuine retention" are not yet separated. `malloc_zone`
  statistics or a `vmmap` at the end of a probe run would separate them, and that
  is the obvious next measurement.
- Uncertainty: `phys_footprint` is a process-level quantity; attributing all of
  it to the grid assumes nothing else in the probe allocates materially, which is
  plausible for a headless binary but unverified.
- Next action: separate fragmentation from retention before acting on `H7`. Do
  **not** treat the 2x multiplier as a fixed tax until then.

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

### F7 -- the 2x multiplier was mostly the probe's own feed call; holding a terminal costs ~1.15x its cell bytes, and the rest is malloc bucket rounding

- Status: recorded. Closes Phase 1's last task, **supersedes `F3/F5` inference 2**,
  and substantially weakens `H7`.
- Date and investigator: 2026-07-29, Claude (agent).
- Commit and worktree state: `91f98f3` plus the probe's `--vmmap`, `--chunk`, and
  malloc-zone additions.
- Instrument additions, all shipped: `mallocHeapSnapshot()` (live bytes across
  every zone), `--vmmap` (dirty allocator pages, sampled *while the terminal is
  resident* via a `whileResident` hook -- sampled after `measure` returns it would
  describe a freed grid), and `--chunk N` (feed in PTY-sized slices; default
  4,096).

**The instrument was wrong, and it was wrong by more than the effect.** `F3/F5`
fed each payload to `Terminal.feed` in a single call. `feed` materializes one
action per input token for the whole call (`Terminal.swift:755`), so a 620 KB
payload builds a ~620,000-element action array -- tens of MB of transient LARGE
allocations, freed before the census but still dirty in `phys_footprint`.
Diagnosis path: the excess scaled with `--lines` but was **invariant under
`--columns`** (37.2 MB at both 179 and 716 columns, where live rows differ by
3.4x), which rules out anything per-row, and `vmmap` showed it as
`MALLOC_LARGE (empty)` -- dirty pages in regions with no live allocation at all.

  | `scrollback-plain`, 179x66 | census | footprint delta | coverage | `MALLOC_LARGE (empty)` |
  | --- | ---: | ---: | ---: | ---: |
  | single-shot feed (`F3/F5`'s method) | 21.75 MB | 64.47 MB | 0.35 | 37.2 MB |
  | 4 KB chunks (a real PTY read) | 21.75 MB | **25.06 MB** | **0.87** | **none** |

- Observation 1: the census is **bit-identical** across chunk sizes, so this is
  purely a measurement correction, not a behavior change. A test pins chunk
  invariance at 4,096 and at 7 bytes (which splits UTF-8 and escape sequences
  mid-token).
- Corrected matrix, one fresh process per payload, chunked:

  | payload | cell bytes | bucket rounding | per row | footprint | coverage |
  | --- | ---: | ---: | ---: | ---: | ---: |
  | empty | 0.81 MB | 0.10 MB | 1,488 | 1.05 MB | 0.77 |
  | full-screen | 2.47 MB | 0.29 MB | 1,488 | 3.05 MB | 0.81 |
  | scrollback-plain | 21.75 MB | 2.51 MB | 1,487 | 25.02 MB | 0.87 |
  | scrollback-unicode | 22.50 MB | 2.73 MB | 1,488 | 26.52 MB | 0.85 |
  | scrollback-styled | 22.31 MB | 2.59 MB | 1,488 | 26.08 MB | 0.86 |
  | scrollback-mixed | 22.19 MB | 2.59 MB | 1,488 | 26.64 MB | 0.83 |

- Observation 2: **the three-way split resolves with no residue.** Live heap
  beyond the census is a flat 1,488 bytes per row on every payload. A column
  sweep shows why -- every row allocation lands within ~44 bytes of a clean malloc
  bucket:

  | columns | row bytes | overhead/row | implied bucket |
  | ---: | ---: | ---: | ---: |
  | 179 | 12,888 | 1,488 | 14,336 (14K) |
  | 182 | 13,104 | 1,273 | 14,336 (14K) |
  | 200 | 14,400 | 2,028 | 16,384 (16K) |
  | 256 | 18,432 | 2,091 | 20,480 (20K) |
  | 300 | 21,600 | 3,025 | 24,576 (24K) |

  The ~44-byte residue is the Swift array header. This also independently
  confirms `F1`'s `heap` reading of a "14.0K" bucket, which `F4` inference 2 used
  as 14,000; the true bucket is 14,336, so bucket overhead at 179 columns is
  **11.5%**, not 8.7%.
- Inference 1, and it answers the gating question directly: **there is no second
  retention defect.** Every live byte is either a cell the census walked or
  bucket rounding on the allocation holding it. Fragmentation among live blocks
  and unreturned pages together are the ~4 MB gap between `MALLOC_SMALL` dirty
  (28.6 MB) and live bytes (24.3 MB).
- Inference 2, which reverses `F3/F5`: **cell bytes are ~85% of what the process
  pays to hold a terminal, not 35-50%.** Halving the cell moves close to half the
  cost. `F3/F5`'s "the multiplier is worth more than the cell" was an artifact of
  the single-shot feed and should not be acted on.
- Inference 3, sizing `H7` properly: per-allocation overhead is real but is
  **2.5 MB against 21.75 MB of cells** (11.5%), plus ~4 MB of allocator slack.
  That is worth having and is exactly what fewer-larger-allocations would
  recover, but it does not outrank shrinking the cell, and `H7` should be
  re-ranked below `H2`/`H3` rather than above them.
- Inference 4, new and actionable for `H2`/`H3`: **cell-size wins are quantized
  by the bucket.** At 179 columns a row sits at 12,888 bytes inside a 14,336-byte
  bucket, so ~1.4 KB per row is already paid for and a small cell shrink that does
  not cross the boundary below returns *nothing* in resident terms. Any
  `H2`/`H3` estimate must be computed in bucket terms, not stride terms, and
  verified on the probe rather than derived.
- Competing interpretations considered: that the LARGE churn was
  `ScrollbackBuffer.storage` growth or `compactIfNeeded`'s copy. Ruled out by the
  column sweep -- those scale with row count, and the excess did not move when row
  count changed by 3.4x. The `--chunk` experiment then removed it entirely, which
  a storage-array explanation cannot account for.
- Uncertainty:
  - The ~4 MB `MALLOC_SMALL` dirty-vs-live gap is not further split between
    magazine slack and genuine fragmentation. It is 16% of cell bytes and does not
    change any ranking, so it is not chased.
  - `phys_footprint` deltas still assume nothing else in the probe allocates
    materially. The `--vmmap` breakdown is consistent with that on every run
    inspected.
  - Coverage on the shallow payloads (0.77-0.81) is below the deep ones for
    fixed-cost reasons (parser tables, the payload arrays themselves), not
    anything per-cell.
- Method note worth carrying: **no test in this file asserts on a heap delta.**
  `mallocHeapSnapshot` reads the whole process, and under the parallel test runner
  a neighbouring suite's allocations land inside the before/after window -- a
  draft test read 76 MB of "overhead" from its neighbours. Delta claims belong to
  the probe binary, which owns its process; the test suite asserts only
  single-snapshot invariants and census-derived facts, which are exact.
- Next action: `H1` (Phase 2). The multiplier is no longer a reason to reorder.

### F8 -- `feed` allocates one action per input token for the whole call

- Status: recorded as an observation, not investigated. Spun out of `F7` so it is
  not lost.
- `Terminal.feed` (`Terminal.swift:755`) builds `let actions = inputStream.feed(bytes)`
  -- a fully materialized array over the entire input -- before applying any of
  them. Feeding 620 KB in one call allocated ~37 MB of transient LARGE blocks.
- This is not a steady-state cost and it is invisible at PTY chunk sizes, which is
  why nothing in this file's budget work is affected. It matters only where a
  single large chunk arrives: a large paste, a `cat` of a big file delivered in
  one read, or a session-restore replay.
- Not a memory-footprint problem, so it is **not** taken up here. It belongs to
  the feed-CPU question (doc 10) if anyone picks it up: streaming the actions
  rather than materializing them would remove both the allocation spike and a
  full pass over the array.

### F9 -- correcting the cost model halves both the memory and the history

- Status: recorded. Verification of `D2`. Closes Phase 2's implementation task.
- Date and investigator: 2026-07-29, Claude (agent).
- Commit and worktree state: `e6bb391` plus `D2`'s change.
- Instrument: `just terminal-memory-probe`, one fresh process per payload.

  | `scrollback-plain`, 179x66, 10 MB budget | before | after |
  | --- | ---: | ---: |
  | cell storage | 21.75 MB | **10.77 MB** |
  | process footprint | 25.02 MB | **12.63 MB** |
  | total rows (scrollback + screen) | 1,770 | **876** |
  | scrollback rows | 1,704 | **810** |

  Unicode, styled, and mixed land within 0.05 MB of plain, as `F2` found before.
- Observation: the model now charges `48 + 72 * columns` for an ordinary row
  against a true allocation of 12,888 bytes at 179 columns -- **90% of the real
  cost**, up from 50%. The remaining 10% is the malloc bucket (`F7`), which is
  deliberately not modelled.
- CPU, per `10/F9`. `just benchmark-confirm baseline=HEAD`:

  | workload | verdict |
  | --- | --- |
  | `terminal-feed` | equivalent (-0.22%, 2 pairs) |
  | `scrollback-stream` | inconclusive (+1.47%, 4 pairs) |
  | `content-churn` | equivalent (-0.27%, 4 pairs) |
  | `style-churn` | equivalent (-0.48%, 4 pairs) |
  | `incremental-mixed` | inconclusive (+1.72%, 6 pairs) |

- Nothing is decided-slower. `scrollback-stream` read -1.71%, +1.47%, and -2.15%
  across three runs -- the sign-flip signature `F6` documented, so it is noise.
  `incremental-mixed` did **not** flip: +1.72% at 6 pairs and +2.45% at 2. It
  stays inside "inconclusive", and there is a benign mechanism for a small real
  cost: a budget that admits half as much history starts evicting earlier in the
  run, so more of the measured window does eviction work that the baseline had not
  reached yet. That is the change working, not a defect in it. Recorded rather
  than dismissed, in case a later change makes it decided.
- Uncertainty: the probe measures a `Terminal` in isolation. The app-side row
  count from `F6` is still unaccounted and unaffected by this change.
- Next action: the product decision this finding sets up -- see `D2`'s open
  question. The engineering half is done and is independently correct.

### F10 -- narrowing the link id moves the cell 72 -> 56 bytes, and the malloc bucket pays more than the stride does

- Status: recorded. Verification of `D3`. Closes Phase 3's first task and confirms
  `H2`.
- Date and investigator: 2026-07-29, Claude (agent).
- Commit and worktree state: `99fc4eb` plus `D3`'s change.
- Instrument: `just terminal-memory-probe`, one fresh process per payload, 179x66,
  4 KB chunks. Layout figures are `MemoryLayout` on a replica of `GridCell` built
  from its own (public) component types, since the struct itself is `private`.

**The field's 8 bytes were never the cost; its alignment was.** `GridCell` today
lays out `kind` at 0, `scalars` at 8, `style` at 17 (19 bytes, ending at 36),
`hyperlinkId` at 40, `contentIdentity` at 56 -- size 65, stride 72. An `Int?`
needs 8-byte alignment, so the link id could not sit in the three bytes of
padding that `style`'s odd 19-byte size leaves behind at offset 36; it started a
fresh 16-byte slot instead. Measured across five variants:

  | `hyperlinkId` variant | stride |
  | --- | ---: |
  | `Int?` (before) | 72 |
  | removed from the cell entirely -- `H2` as written | 56 |
  | removed, plus a `Bool` presence flag in the cell | 56 |
  | **`UInt16?`** | **56** |
  | `UInt32?` | 64 |
  | `UInt16?` *and* `contentIdentity: UInt32?` | 48 |
  | both fields removed | 40 |

- Observation 1, and it decided the design: **removing the field and narrowing it
  to two bytes land on the same stride.** The side map `H2` proposed buys nothing
  a type change does not, so `D3` takes the type change. The `Bool` row is the
  same story from the other side -- a presence flag is free, because it also fits
  in padding.
- Observation 2: `UInt32?` is worth only half as much as `UInt16?`. Five bytes at
  4-byte alignment pushes `contentIdentity` to offset 48; three bytes at 2-byte
  alignment does not. The win is quantized by what fits in the gap, not by how
  many bytes are saved.
- Measured effect, before -> after:

  | payload | rows | cell bytes | overhead/row | footprint |
  | --- | ---: | ---: | ---: | ---: |
  | full-screen (fixed row count) | 201 -> 201 | 2.47 -> **1.92 MB** | 1,487 -> **255** | 3.03 -> **2.30 MB** |
  | scrollback-plain | 876 -> **1,107** | 10.77 -> 10.58 MB | 1,486 -> **265** | 12.61 -> 11.95 MB |
  | scrollback-unicode | 872 -> 1,100 | 10.72 -> 10.52 MB | -> 351 | -> 11.94 MB |
  | scrollback-styled | 876 -> 1,107 | 10.77 -> 10.58 MB | -> 265 | -> 11.98 MB |
  | scrollback-mixed | 875 -> 1,104 | 10.75 -> 10.55 MB | -> 306 | -> 12.56 MB |

- Inference 1, and it is the finding: **`F7` inference 4 was right that bucket
  placement decides the outcome, and wrong about which way it would cut here.**
  It warned that a shrink failing to cross a boundary returns nothing. What
  happened is the opposite: per-row overhead beyond cell bytes fell from 1,487
  bytes to 255, **-83%**, because a 179-column row moved from 12,888 bytes --
  badly placed just inside a 14,336-byte bucket -- to 10,024 bytes, which sits
  almost exactly on a boundary. On the fixed-row-count control the footprint fell
  **24.0%** against a 22.2% cut in cell bytes. The rule survives, with its sign
  corrected: **bucket placement can amplify a shrink as easily as erase it, and
  neither is predictable from stride.** Measure, do not derive.
- Inference 2, and it is what a reader should not skip: **at a fixed byte budget
  this is not a memory saving.** `scrollback-plain` holds 10.58 MB where it held
  10.77 MB -- flat -- and spends the entire win on history instead, 876 -> 1,107
  rows (**+26.4%**). The saving is realized only where the row count is fixed
  (the live screen, `full-screen` above) or if the nominal budget is lowered.
  This is exactly the coupling `D2` left open, now with a number attached.
- CPU, per `10/F9`. Two independent `just benchmark-confirm baseline=HEAD` runs,
  then an A/A control:

  | workload | run 1 | run 2 | **A/A control** |
  | --- | --- | --- | --- |
  | `terminal-feed` | faster (-2.62%) | inconclusive (-1.88%) | equivalent (-0.58%) |
  | `scrollback-stream` | **faster (-17.87%)** | **faster (-19.16%)** | equivalent (-0.38%) |
  | `content-churn` | equivalent (+0.75%) | inconclusive (+2.02%) | inconclusive (+1.16%) |
  | `style-churn` | inconclusive (+0.79%) | equivalent (-0.31%) | equivalent (+0.22%) |
  | `incremental-mixed` | slower (+2.84%) | slower (+3.42%) | **faster (-3.30%)** |

- Inference 3: **`scrollback-stream` is 18-19% faster**, reproduced twice against
  an A/A control that reads -0.38% on the same workload. This is by a wide margin
  the largest CPU win recorded in any of these files, and the mechanism is
  ordinary: scrolling moves rows, rows are 22% smaller, so `moveAndFillCells` and
  the eviction path copy 22% less and touch fewer cache lines. Note the contrast
  with `12/F8` -- the POD cell was rejected precisely because it made this
  workload **+6.74% slower**. A memory-motivated change has now moved the same
  workload three times as far in the opposite direction.
- Inference 4, on the one negative reading: **`incremental-mixed`'s +2.84% and
  +3.42% are not attributable to this change**, and the A/A control is why. Run
  with byte-identical code on both arms, in the same session, it returned
  `faster (-3.30%)` -- a false verdict of the same magnitude and the opposite
  sign. That reproduces `plans/wip/f7-arm-confound-diagnosis.md`, which measured
  this metric's paired SD at **6.26% against the 1.85% threshold** it is judged
  by, and 10 false directional verdicts in 24 A/A quartets. There is also no
  mechanism: the workload measures draw time, `GridCell` is not in the draw path,
  and plan time -- which this change *can* touch -- moved -4.95% and -0.16%.
  Recorded rather than dismissed, but it is a fact about the instrument.
- Competing interpretations considered for the memory result: that the row-count
  rise is eviction lagging rather than real depth. Ruled out by the census, which
  counts live rows and is exact, and by `scrollbackByteCount` staying inside the
  budget under the behavioral test that pins it.
- Uncertainty:
  - The probe measures a `Terminal` in isolation; `F6`'s unaccounted app-side row
    arrays are unaffected and still unexplained.
  - Two bytes is now the id space, so the terminal can refuse a link it would
    once have admitted. It takes 65,536 targets alive at once, which the 256 KiB
    metadata cap allows only for URIs averaging four bytes. Bounded and tested,
    but it is a new refusal path that did not exist before.
  - `full-screen`'s overhead/row of 255 bytes is close enough to a boundary that
    a future shrink of a few bytes could land badly. Nothing predicts this from
    stride; re-measure per change.
- Next action: instrument style **write** traffic before `H3`, per Phase 3.

### F11 -- style writes outnumber style *values* by six orders of magnitude, so `H3` should not refcount

- Status: recorded. Answers `12/F3`'s stated uncertainty and unblocks Phase 3's
  `H3`/`H6` gate. Does **not** implement `H3`.
- Date and investigator: 2026-07-29, Claude (agent).
- Commit and worktree state: `d4ad198`, clean.
- Instrument: scratch counters compiled into `GridCell` (`style` made a computed
  property over private storage, so every construction *and* every mutation is
  counted) and into the `currentStyle` pen, driven headlessly at 179x66 over the
  four committed benchmark corpora expanded from
  `benchmarks/fixtures/terminal-app.json`. Reverted after measurement; nothing
  from it is in the tree. Layout and bucket figures are `MemoryLayout` on replica
  cells plus `malloc_good_size`, the same method `F10` used.

**The question `12/F3` could not answer was write traffic, and the answer is that
writes are enormous and values are trivial:**

  | corpus | cell style stores | value switches | pen changes | distinct styles |
  | --- | ---: | ---: | ---: | ---: |
  | `scrollback-stream` (25K lines) | **8,966,786** | 1 | 0 | 1 |
  | `unicode-wrapping` (9K lines) | **5,580,991** | 1 | 0 | 1 |
  | `incremental-screen-updates` (100K cycles) | **23,211,930** | 1 | 0 | 1 |
  | `styled-screen-redraw` (3.5K frames) | 634,880 | 252,001 | 24,500 | 5 |

  "Value switches" counts stores whose style differs from the immediately
  preceding store -- the number of table lookups a dedup design would need with a
  one-entry cache in front of it. "Pen changes" counts SGR sequences that actually
  moved `currentStyle`, which is the lookup count if the pen instead carries its
  resolved id.

- Observation 1: **three of the four corpora are single-style.** Their entire run
  needs *one* lookup. This is not an artifact of unstyled fixtures being unfair to
  `H3` -- it is the ordinary case, and it means the table's read path is free
  almost always.
- Observation 2, on the one styled corpus: even there, 634,880 stores need at most
  252,001 lookups into a **five-entry** table, and only 24,500 if the pen holds its
  id. Against `F2`'s 193 distinct styles on a payload built to stress styling, the
  table is small enough to stay in L1 in every case measured.
- Inference 1, and it is the finding: **`H3` must not refcount.** A refcounted
  table charges on the *store* side, and the store side is 9 to 23 million
  operations per corpus run -- each a random-access counter update on a different
  cache line from the cell being written, and each paid again on overwrite,
  eviction, and every copy-on-write of a row. That is the same shape of per-cell
  bookkeeping `12/F8` rejected the POD cell for, on the same workloads, and the
  traffic numbers above are why it would land the same way.
- Inference 2, the alternative, and it is already in the codebase: **sweep, do not
  count.** `hyperlinkTargets` solves this exact problem with a live-set walk
  (`liveHyperlinkIds` plus `filter`) triggered by a byte cap, and pays *nothing*
  per cell write. With 193 distinct styles as the stress-corpus figure and a
  16-bit id space, the sweep would essentially never run. This makes `H3`'s store
  path a two-byte write -- strictly cheaper than today's 19-byte inline copy.
- Measured effect on the cell, computed the way `F10` requires (buckets, not
  stride). Row = 48-byte array header plus 179 cells; `F10` measured the real row
  at 10,024 against 10,072 here, so read these as +-50 bytes:

  | variant | stride | raw row | malloc bucket | waste/row | 201-row screen | history rows at 10 MiB |
  | --- | ---: | ---: | ---: | ---: | ---: | ---: |
  | before `D3` | 72 | 12,936 | 14,336 | 1,400 | 2.88 MB | 810 |
  | **today** | **56** | 10,072 | 10,240 | **168** | **2.06 MB** | **1,041** |
  | `H3` (16-bit style id) | **40** | 7,208 | 8,192 | 984 | **1.65 MB** | **1,454** |
  | `H3` + `H4`'s cheap half (`UInt32?`) | 32 | 5,776 | 6,144 | 368 | 1.23 MB | 1,815 |
  | `H3` + `contentIdentity` removed | 24 | 4,344 | 5,120 | 776 | 1.03 MB | 2,413 |

- Inference 3: **`H3` is worth 16 bytes, the largest single win left**, and the
  bucket rule cuts against it this time. Stride falls 28.6% but the realized screen
  footprint falls only ~20%, because a 7,208-byte row sits badly inside an
  8,192-byte bucket -- 984 bytes of waste per row, where today's row wastes 168.
  `F10`'s corrected rule holds in both directions: today's cell is unusually
  well-placed, and any further shrink gives some of the win back to the allocator.
- Inference 4, for the `H3`/`H6` gate: `H3` and `H6` **compose rather than
  compete**, and `H3` is the cheaper half. `H3` shrinks every cell including the
  live screen and needs no new representation; `H6` re-represents scrollback rows
  only, and would be applied to cells `H3` has already shrunk. The gate should be
  read as an ordering question, not an either/or -- but the decision belongs to
  the ledger's gate item, not to this finding.
- Competing interpretation considered: that the near-zero switch counts are an
  artifact of the corpora rather than of terminal output generally. Partly true and
  worth stating -- these four fixtures are the CPU corpus, and only one is styled.
  It does not change the inference, because the inference rests on the *store*
  side, which is corpus-independent (every printed cell stores a style regardless
  of what that style is) and which is where a refcount would charge.
- Uncertainty:
  - Stores were counted with instrumentation compiled in, so the absolute counts
    are exact but say nothing about the *cost* of a store. No CPU number here.
  - The draw path would gain an id-to-style indirection per cell that it does not
    have today. Small (a 193-entry, ~3.7 KB table) but real, and it is the one
    place `H3` could regress. It has to be verified on `style-churn` and
    `styled-screen-redraw`, not just on `terminal-feed`/`scrollback-stream`.
  - The strides above are replica measurements. `F10`'s lesson applies to `H3`
    too: re-measure the real struct after the change rather than trusting the
    prediction.
- Next action: the `H3`/`H6` gate, per Phase 3's remaining ledger item.

### F12 -- the same 8-byte cell shrink saves 26% at 80 columns and *costs* memory at 179, because the budget charges stride and the allocator charges buckets

- Status: recorded. Sizes `H4`'s cheap half, and the change was **implemented,
  measured, and reverted** -- nothing from it is in the tree. Blocks `D4`.
- Date and investigator: 2026-07-29, Claude (agent).
- Commit and worktree state: `5ae0140`, clean.
- Instrument: `just terminal-memory-probe`, one fresh process per payload, at both
  179x66 and 80x66. Bucket placement across geometries is `malloc_good_size`,
  which matched the measured per-row overhead within ~100 bytes everywhere it was
  checked.

Narrowing `contentIdentity` to `UInt32?` reaches stride **48**, as `F10`
predicted. What it costs and saves does not follow from that number at all:

  | payload | 179x66, stride 56 -> 48 | 80x66, stride 56 -> 48 |
  | --- | --- | --- |
  | `full-screen` footprint (fixed rows) | 2.30 -> **2.38 MB** | 1.27 -> **0.94 MB** |
  | `scrollback-plain` footprint | 11.95 -> **13.75 MB** | 14.88 -> **11.38 MB** |
  | `scrollback-plain` history rows | 1,107 -> 1,279 | 2,381 -> 2,762 |
  | per-row overhead beyond cells | 265 -> **1,690 B** | 678 -> **203 B** |

- Observation 1, and it explains the whole table: **at 179 columns the row never
  leaves its malloc bucket.** Cells plus overhead come to ~10,289 bytes at stride
  56 and ~10,282 at stride 48 -- the same allocation, to within the array header.
  The eight bytes per cell were removed from the cell and handed straight back to
  the allocator.
- Observation 2: 179 is a **dead zone specific to this shrink**, not a general
  law. Bucket placement of a `48 + columns * stride` row:

  | columns | stride 56 | stride 48 | stride 40 | stride 32 |
  | ---: | ---: | ---: | ---: | ---: |
  | 80 | 5,120 | **4,096** | 3,584 | 3,072 |
  | 100 | 6,144 | **5,120** | 4,096 | 3,584 |
  | 120 | 7,168 | **6,144** | 5,120 | 4,096 |
  | **179** | 10,240 | **10,240** | 8,192 | 6,144 |
  | 200 | 12,288 | **10,240** | 8,192 | 7,168 |
  | 240 | 14,336 | **12,288** | 10,240 | 8,192 |

  Every width checked except 179 crosses a boundary. The benchmark geometry is
  the unlucky one.
- Inference 1, and it is the finding: **the loss at 179 is not caused by the cell
  shrink -- it is caused by the budget's cost model.** `scrollbackByteCost`
  charges `columns * stride`, so a cheaper cell makes a row look cheaper and the
  budget admits 15% more rows. Those rows each cost what they always did, because
  the allocation did not shrink. The result is +1.8 MB of real memory bought with
  accounting that `F9` corrected once already, for exactly this class of reason.
  `F9` made the budget charge true *stride*; it still does not charge true
  *allocation*, and the size of that error grows as the cell shrinks -- ~1.6% at
  stride 56, ~16% at stride 48.
- Inference 2, on where the lever now is: **between roughly 43 and 56 bytes, a
  179-column row costs the same.** The cell is no longer the unit that decides
  resident memory at that width; the row allocation is. This is the first
  measurement in this file that argues for `H7`/`H6` (amortize or re-represent
  the row) over any further per-field narrowing at wide geometries.
- Inference 3, for `H3`: it survives this, and the geometry table is why. Stride
  40 crosses a boundary at **every** width listed, 179 included (10,240 ->
  8,192). `H4`'s cheap half rides along once `H3` has moved the row: at stride 32
  the row falls again at every width. So the ordering is not free-choice --
  `H4` alone is a coin flip on geometry, `H3` then `H4` is not.
- Competing interpretation considered: that the 179 regression is probe noise.
  Ruled out by the mechanism being independently visible in the row count (1,107
  -> 1,279, an exact consequence of the budget arithmetic) and by the per-row
  overhead moving 265 -> 1,690, which is a census quantity rather than a
  footprint sample.
- One design result worth keeping even though the change was reverted: **a 32-bit
  identity is exhaustible in minutes, and a wrap silently weakens link
  activation.** The counter issues one identity per printed cell, so 2^32 is a
  few minutes of maximal output, and past the wrap a reissued identity lets a
  run reprinted since pointer-down satisfy the check `linkArmTracksRunIdentity`
  exists to enforce. The fix is small and was written and tested against a
  failing test: drop the armed link at the wrap, skip identity zero (which
  `activationIdentity` already reads as "none"). Whoever takes `H4` should take
  that with it rather than rediscover it.
- Uncertainty:
  - Widths were sampled, not swept. A width not in the table could sit in its own
    dead zone for any given stride; the rule is to check placement per geometry,
    not to trust any single measurement as general.
  - Panes are not all one width, and a split layout mixes them. The probe measures
    one geometry per process, so "what a real window costs" is still unmeasured.
- Next action: `D4` -- whether the budget should charge the allocated row rather
  than the stride sum, which is what makes `H4` safe at every width. That is a
  cost-model question of the same species `F9`/`D2` handled, and it lands next to
  the budget's open unit question.

### F13 -- charging reserved storage closes the budget's last systematic gap, and costs no CPU

- Status: recorded. Verification of `D4`. Shipped.
- Date and investigator: 2026-07-29, Claude (agent).
- Commit and worktree state: `f53c9ac` plus `D4`'s change.
- Instrument: `just terminal-memory-probe`, one fresh process per payload, at
  179x66 and 80x66; `just benchmark-confirm baseline=HEAD` for CPU.

Live heap against the configured 10.00 MB budget, before -> after:

  | geometry | history rows | cell bytes | live heap | overshoot |
  | --- | ---: | ---: | ---: | ---: |
  | 179x66 | 1,107 -> 1,090 | 10.58 -> 10.42 MB | 10.86 -> **10.70 MB** | 8.6% -> 7.0% |
  | 80x66 | 2,381 -> **2,126** | 10.17 -> **9.08 MB** | 11.68 -> **10.48 MB** | 16.8% -> **4.8%** |

- Observation 1: the residual overshoot is the **live screen**, which the budget
  has never claimed to cover. Subtracting it (66 rows at the same reserved cost)
  leaves history at 10.02 MB and 10.14 MB -- within ~1% of the configured 10 MB at
  both widths, against 8-17% before.
- Observation 2, and it is why this mattered more at 80 columns than at 179: the
  under-charge is bucket placement, so it varies by width rather than being a
  constant. `F7` reported ~11.5% from a single geometry and it read as a constant;
  it is 2% at one width and 17% at another.
- Inference 1: **`F9`'s correction was two thirds of a fix.** It moved the charge
  from a modelled 40 bytes to true stride and closed a 120% error. The remaining
  error had the same cause one level down -- charging what a row *occupies*
  instead of what it *reserves* -- and it is the error `F12` turned into a 1.8 MB
  regression. The budget now means what it says at every width measured.
- Inference 2, and it is the part worth reusing: **the allocator will answer
  questions about itself.** `F7` declined to model bucket rounding because size
  classes are a platform detail this code cannot portably encode. That was right,
  and it made the gap look unfixable. `Array.capacity` is the same number without
  the model -- Swift sets it from the block malloc actually returned -- so the
  rounding is charged without anyone predicting it. Verified against
  `malloc_good_size` at four widths and two strides before being relied on.
- CPU, per `10/F9`. `just benchmark-confirm baseline=HEAD`:

  | workload | verdict |
  | --- | --- |
  | `terminal-feed` | equivalent (-0.52%) |
  | `scrollback-stream` | faster (-3.28%) |
  | `content-churn` | inconclusive (+0.89%) |
  | `style-churn` | equivalent (+0.37%) |
  | `incremental-mixed` | faster (-4.89%) |

  A preceding 2-pair quick run read `scrollback-stream` at **+1.48%**, and the
  confirm reads -3.28%. The sign flip is the noise signature `15/F6` describes, so
  the honest reading is "no regression" rather than "3% faster". The mechanism for
  a small real gain exists (fewer retained rows means less eviction and copying)
  but is not separable from the instrument at this size.
- Competing interpretation considered: that fewer retained rows is itself the
  regression -- the user loses history. True and intended: those rows were never
  affordable, and `F12` showed that admitting them is how a cell shrink turns into
  a memory *increase*. What the budget should be set *to* is `D2`, still open.
- Uncertainty:
  - `capacity` is read at charge time and assumed stable while a row sits in
    history. Scrollback rows are not mutated after append, and
    `expectValidGrid`'s existing `scrollbackByteCount == recomputedScrollbackByteCount`
    assertion would catch drift, but nothing states the invariant directly.
  - Charged cost now depends on how a row's array was built. Every row goes
    through the same `(0..<columns).map` construction today, and `map` and
    `Array(repeating:)` were measured to agree; a future third construction path
    could charge two identical rows differently.
  - Spill allocations for multi-scalar clusters are still charged at `count`, not
    capacity. They are 0.61% of cells at their worst (`F2`), so this is known and
    left.

## Decision log

### D4 -- charge history the storage a row reserves, not the storage its cells occupy

- Status: **decided and implemented.** Verified in `F13`.
- Date: 2026-07-29.
- Context: `F12` measured `H4`'s cheap half as a 1.8 MB *regression* at 179
  columns despite removing 8 bytes from every cell. The cause was not the cell: a
  row's cell array is allocated in a malloc bucket, the narrower row landed in the
  same bucket, and `scrollbackByteCost` -- charging `count * stride` -- concluded
  the row got cheaper and admitted 15% more of them.

**Decision: charge `cells.capacity`, not `cells.count`.**

Rejected alternatives:

1. **Model the malloc size classes.** A table of allocator buckets is a platform
   implementation detail, would be guessed rather than known, and would rot on an
   OS update. This is why `F7` declined to model rounding at all.
2. **Leave the model and accept the under-charge.** It is what `F7` chose, on the
   grounds that ~11.5% was small next to the 120% error `F9` fixed. `F12`
   withdrew that: the error is 17% at 80 columns, it varies by width, and it
   converts any future cell shrink into an admission of more rows rather than a
   saving.
3. **Charge a fixed padding factor.** Arbitrary, wrong at every width but one,
   and it would need re-tuning after each stride change -- the exact maintenance
   burden this file keeps finding in derived constants.

`Array.capacity` is the allocator's own answer, so option 1's objection does not
apply to it: nothing is predicted, only read. The cost is that the charge is no
longer arithmetic a test can restate from a column count, which is why
`historyRowCost` now asks the engine (`Terminal.blankScrollbackRowByteCost`)
rather than multiplying, and why `retainedScrollbackAllocationBytes` re-derives
the same total by a second route for the test that holds it against the budget.

Consequence to carry into `D2`: history depth falls again, 1.5% at 179 columns
and **10.7% at 80**. Both nominal-value discussions in this file have now been
had against a cost model that was under-charging; this is the first one that
would be had against an accurate one.

### D3 -- narrow the cell's link id rather than move it to a side map

- Status: decided and implemented. Takes `H2`, by a different route than `H2`
  proposed.
- Date and investigator: 2026-07-29, Claude (agent).
- Evidence used: `F10`'s layout table (removal and narrowing reach the same
  stride), `12/F3` inference 3 and `15/F2` observation 4 (the field is nil in
  100% of cells across two independent corpora).
- What `H2` proposed, following libghostty (`page.zig:145`, `page.zig:1994`): one
  bit in the cell plus a page-level map. What landed instead: `hyperlinkId` is a
  `UInt16?` rather than an `Int?`, and nothing else about the cell changes.
- Why the simpler answer wins here, which is this file's standing rule about
  libghostty techniques: the side map costs a per-row structure that reflow,
  resize, scroll, and eviction all have to maintain in step with the cells --
  every one of them a place a link can silently detach -- and `F10` shows it buys
  **exactly the same 56-byte stride** as a two-byte field. That is complexity for
  nothing. libghostty needs the map because a Zig page is a packed byte arena
  where a bit is genuinely cheaper than a field; a Swift struct has three bytes of
  alignment padding sitting unused, and a field that fits there is free.
- The cost, stated plainly: **the id space is now finite.** An unbounded counter
  cannot collide; a 16-bit one wraps after 65,536 distinct targets and would
  overwrite a live entry, showing an old cell some newer link's URI. So
  allocation had to change with the type: `allocateHyperlinkId` scans from a
  rotating cursor for an id absent from the table, and refuses when the space is
  full -- the same refusal the byte cap already performs, reaching the same
  caller path.
- Why recycling is sound, and it rests on one invariant: **every id held by a
  cell is a key of `hyperlinkTargets`.** Targets are only ever dropped by
  `filter { live.contains($0.key) }`, and `liveHyperlinkIds` walks scrollback,
  the active grid, the inactive primary screen, and the pen -- which was verified
  to be every place a cell lives (the alternate screen is discarded on exit, not
  retained). So an id absent from the table is absent from the grid.
- Tests: a behavioral test drives 70,000 distinct targets past the 65,536-id
  space while holding one link pinned on a cell that never scrolls, and asserts
  that cell still resolves to *its own* URI. Confirmed to have teeth: against a
  deliberately monotonic allocator it fails reading `https://h65535.test/...`
  where `https://pinned.test` belongs -- the wraparound collision, exactly. An
  earlier version of the test checked only the newest link and passed against
  that same broken allocator; it was rewritten rather than trusted.
- Test-suite consequence: only two places encoded the old stride --
  `historyRowCost` and the deliberately literal-pinned cost fixtures. `D2`'s
  centralization did its job.
- Consequence for the budget, and it is `D2`'s open question getting sharper: at
  10 MB, history rises from ~810 to ~1,041 scrollback rows (`F10`). The memory
  number barely moves. Anyone deciding the nominal budget should now assume
  stride 56, and that `H3` may take it lower still.

### D2 -- charge history's true size, and leave the budget's nominal value open

- Status: decided and implemented for the accounting half. **The product half --
  what the nominal budget should be, and whether it should even be denominated in
  bytes -- is deliberately left open.**
- Date and investigator: 2026-07-29, Claude (agent).
- Evidence used: `12/F1` observation 3 (the model charges 40 bytes for a cell
  whose stride is 72), `F2` (a 10 MB budget really held ~22 MB), `F7` (the true
  per-row cost, and that bucket rounding adds a further ~11.5%).
- What changed: `scrollbackByteCost` now charges the row's slot, its cell-array
  header, its cells at **stride**, and one spill allocation per multi-scalar cell
  -- `48 + 72 * columns` for an ordinary row at 179 columns, against a real
  allocation of 12,888 bytes. It was `16 + 40 * columns`.
- What deliberately did **not** change: malloc bucket rounding is not modelled,
  though `F7` measured it at a further ~11.5%. Bucket size classes are an
  allocator implementation detail that varies by platform and request size, and
  this model has to be deterministic and portable -- its tests pin it to literals
  for that reason. The budget therefore still under-charges, by ~10% instead of
  by ~120%.
- Consequence, and it is the point: at a fixed 10 MB budget, history depth falls
  from ~1,704 rows to ~810 (`F9`). **This is a correctness fix that costs the
  user history**, which is exactly the coupling this file's investigation rules
  warn about ("a cell-size change is a scrollback-depth change", in reverse).
- Tests: the change is pinned by a behavioral test that feeds 20,000 lines at
  production geometry and asserts that the cell storage history *actually holds*
  fits the budget -- measured from `memoryCensus`, not from `scrollbackByteCount`,
  which is the thing under test. Every prior budget test checked the model against
  itself and so could not have caught this.
- Test-suite consequence worth recording: a dozen budgets across six suites were
  magic numbers encoding "two rows at four columns" under the old model, and had
  to be reverse-engineered to be rescaled. They are now expressed as
  `historyRowCost(columns:) * n` from one shared helper, so the next model change
  edits one function. One of them (`TerminalHyperlinkTests.identityCarry`) also
  had to be sized at the *widest* geometry the test reaches rather than its
  starting geometry -- a byte budget that holds a row at 5 columns holds none at
  6, which is itself a small illustration of why byte-denominated budgets are
  surprising.
- **Open, and it belongs to the product, not to this file:** whether the nominal
  budget stays at 10 MB (halving history), rises to ~22 MB (preserving history and
  making the number honest), or whether the limit should be denominated in
  **lines** instead of bytes.
  - Verified against `.ghostty-src/`: Ghostty limits by **bytes**
    (`src/config/Config.zig:1365` -- "The size of the scrollback buffer in bytes";
    `:1385` -- `@"scrollback-limit": usize = 10_000_000`), and its `PageList`
    rounds the limit to whole pages and may "slightly exceed max_size"
    (`src/terminal/PageList.zig:346-351`). So DanTerm matches Ghostty today, and
    Ghostty is itself approximate.
  - tmux (`history-limit`), xterm (`saveLines`), and iTerm2 all limit by lines, so
    Ghostty is the outlier among terminals generally.
  - The argument for lines that is specific to this file: with a byte budget,
    **every** memory optimization silently changes user-visible history depth, so
    `H2`, `H3`, and `H6` each force a fresh product decision. With a line limit
    plus a byte ceiling as a safety net, representation work becomes a pure memory
    win and stops needing one.
  - Deferred on purpose: `H2` and `H3` may take stride from 72 toward ~44, which
    buys back most of the depth this decision spends. Decide the nominal value
    once, after them, rather than twice.

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

Investigation in progress. **Phase 1 is complete, Phase 2's engineering half is
shipped, and Phase 3's first item is taken.** Findings F1 through F12 are
recorded; the next free ID is **F14**. Decisions D1 through D4 are recorded and
implemented; the next free ID is **D5**.

`D4`/`F13` then closed the budget's last systematic gap. `scrollbackByteCost`
charged what a row's cells *occupy*; it now charges what the row *reserves*, by
reading `Array.capacity` -- the allocator's own answer to the bucket-rounding
question `F7` correctly refused to model. History lands within ~1% of the
configured 10 MB at both 179 and 80 columns, against 8-17% over before, with no
CPU cost. It also removes the trap `F12` fell into: a narrower cell can no longer
admit more rows than the allocator actually made cheaper.

`F12` is the one to read before shrinking anything else. Narrowing
`contentIdentity` to `UInt32?` (`H4`'s cheap half) reaches stride 48 and was
implemented, measured, and reverted: at 80 columns it is worth **-26%**, and at
179 it **costs 1.8 MB**, because the row never leaves its malloc bucket while the
budget -- which charges `columns * stride` -- believes it got cheaper and admits
15% more rows. Between roughly 43 and 56 bytes a 179-column row costs the same,
so at wide geometries the cell has stopped being the lever and the row allocation
has become it. `H3` still clears the bar (stride 40 crosses a boundary at every
width checked); `H4` alone does not.

`F11` then answered the question `12/F3` left open and re-specified `H3` without
implementing it: **style writes run 9-23 million per corpus against 1-5 distinct
values**, so a refcounted dedup table would charge on the only side that is hot,
and `H3` should instead sweep a live set the way `hyperlinkTargets` already does.
It is worth 16 more bytes (stride 56 -> 40) -- the largest win left -- but the
malloc bucket runs the other way this time and returns roughly a third of it.

`D3` took `H2` and the cell is now **56 bytes, down from 72**. It got there by a
different route than `H2` specified: the link id's cost was its `Int?` alignment,
not its eight bytes, so narrowing it to `UInt16?` recovered the whole 16 bytes
and the side map libghostty uses was never built (`F10`). Two results are worth
carrying forward. **`scrollback-stream` is 18-19% faster** -- the largest CPU win
in any of these files, reproduced twice against an A/A control, and notable
because `12/F8` rejected the POD cell for making that same workload 6.7% slower.
And **at a fixed byte budget the change buys history, not memory**: cell bytes
stayed at ~10.6 MB while history rose from 876 to 1,107 rows. That is `D2`'s open
question getting harder to defer, not easier.

`D2` corrected the accounting: a 10 MB budget now holds ~10.8 MB of cells instead
of ~22 MB, and history at that budget falls from ~1,704 rows to ~810 (`F9`). The
number the user configures finally means roughly what it says -- within ~10%,
which is unmodelled malloc bucket rounding. What the number *should be*, and
whether it should be denominated in bytes at all, is left open in `D2` on purpose:
`H2` and `H3` both move stride, and moving stride moves depth at any fixed byte
budget, so the value is worth deciding once at the end rather than twice.

`F4` closed Phase 1's gating task and changed the plan: the largest defect found
so far is a scrollback retention bug (`H8`), not a representation problem, and
it is the only item here that costs the user nothing. Phase 1.5 shipped it
(`D1`) -- ~22 MB of already-evicted rows at peak, released, with no CPU cost on
any of the five routine workloads.

`F6` then changed the plan a second time. **`just benchmark-memory` cannot
measure representation work.** Asked to confirm a ~22 MB saving it reported the
fixed build as *larger*, because one memgraph samples one arbitrary point on a
sawtooth and because GUI IOSurface churn is twice the size of the effect. It
remains a good leak detector, which is what `F1` used it for.

So Phase 1 is now complete, on a new instrument. `just terminal-memory-probe`
(`F2`) measures pure terminal state headlessly and exactly, backed by a public
`Terminal.memoryCensus` -- which also retires the widen-a-private-and-revert
method that left `12/F1` and `12/F3` unrepeatable. Any agent can now re-derive
those numbers in one command.

**What it found should be read before picking up any hypothesis here:**

1. A bounded scrollback holds **~22 MB against a 10 MB budget**, on every
   payload. `H1` is confirmed in magnitude, not merely derived.
2. Content barely matters. Plain, unicode, styled, and mixed land within 0.75 MB
   of each other, because rows are full-width regardless. Memory is a function of
   the budget, not of what the user ran.
3. **Cell bytes are ~85% of what the process pays to hold a terminal** (`F7`).
   `F3/F5` reported 35-50% and argued that the allocator multiplier outranked the
   cell; that was the probe measuring its own feed call, and it is withdrawn.
   Holding 21.75 MB of cells costs ~25 MB: cells, plus 2.5 MB of malloc bucket
   rounding (a flat 1,488 B/row), plus ~4 MB of allocator slack, plus **zero**
   genuine retention.
4. `H3`'s "trivially small style table" premise is weaker than doc 12 thought: a
   payload built to stress styling produces **193** distinct styles against the
   at-most-9 the fixture corpus produced. Still fits 16 bits; no longer trivial.
5. `H2` is reconfirmed on an independent corpus -- `hyperlinkId` nil in 100% of
   cells, everywhere.
6. **Size cell shrinks in malloc buckets, not in stride** (`F7` inference 4). A
   row at 179 columns is 12,888 bytes inside a 14,336-byte bucket, so a shrink
   that does not cross the boundary below returns nothing resident. `F10` then
   showed the effect is not one-directional: the same quantization *amplified* a
   22% stride cut into a 24% footprint cut, by landing the row on a boundary.
7. **A field's cost is its alignment, not its width** (`F10`). `hyperlinkId`
   presented as 8 bytes and cost 16, because `Int?` could not sit in the three
   bytes of padding `TerminalStyle`'s 19-byte size leaves behind. Read the
   offsets before designing any cell change -- it is what made `H2`'s side map
   unnecessary, and it is what makes `H4`'s cheap half worth 8 more bytes.

`F7` also closed Phase 1's last question -- no second retention defect exists --
and left one observation for someone else: `Terminal.feed` materializes one
action per input token for the entire call (`F8`). Irrelevant at PTY chunk sizes,
which is why it does not appear anywhere in this file's budget work.

The theme of Phase 1 is worth stating plainly, because it cost two findings:
**every memory instrument this file has used was wrong in a way that produced a
confident, plausible number.** `benchmark-memory` reported a fixed build as
larger (`F6`); the headless probe attributed its own parse spike to resident
state (`F7`); `heap`'s bucket sizes were read as allocation sizes (`F1`). In each
case the error was found by varying something that should not have mattered --
sawtooth phase, chunk size, column count -- and seeing the number move.
