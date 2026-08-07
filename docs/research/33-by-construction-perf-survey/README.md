# By-construction performance survey

Research started: 2026-08-06.
Continues: [18-cpu-renderer-optimization-leads.md](../18-cpu-renderer-optimization-leads.md) (`18/D7`),
[28-retained-row-optimizations/README.md](../28-retained-row-optimizations/README.md) (`28/D10`),
[31-logical-line-scrollback/README.md](../31-logical-line-scrollback/README.md) (`31/D5`).

- [findings.md](findings.md) -- the append-only evidence chain; F1-F8 are the
  survey's directly verified code-reads and probes.
- [decisions.md](decisions.md) -- the auditable decision log; currently holds
  the three standing tensions this survey inherited rather than resolved.
- [2026-08-07-stale-wrap-claim-line-fusion.md](2026-08-07-stale-wrap-claim-line-fusion.md) -- session notes
  for the stale-wrap-claim scrollback fusion found and fixed while this
  survey ran: the ablated bug, the two refuted fix designs, and the shipped
  `marginErased` gate (`01cf1eb8`) plus the `pane rows`/`pane zoom` tooling
  built to find it (`00ab639d`). Not survey evidence -- an incident record that
  happens to share the campaign.

## Purpose

This doc owns one question: **where does DanTerm still do work at the
granularity of iteration when its inputs vary at the granularity of change, and
what is the structure in which that work cannot happen?**

It exists because the previous performance docs each decomposed one bracket
(doc 10 the feed, docs 11/18 the draw, doc 17 the whole-app CPU map, docs 15/28
memory, doc 31 scrollback) and each closed against the instrument that could
decide its own bracket. Nothing had swept the whole pipeline looking for the
one structural smell in
[agent-docs/perf-granularity-mismatch.md](../../../agent-docs/perf-granularity-mismatch.md),
which had by then produced two shipped wins (`fba5012b`, `2b4e1604`) and a
written detection rubric.

The survey was run on 2026-08-06 as six parallel read-only agents, one per
vertical: PTY/IO delivery, parse and feed, grid/cell/scrollback storage, frame
planning, draw execution and the AppKit surface, and the app runtime and Elm
loop. No agent could see another's work. Findings named by more than one
vertical independently are marked as such, and that convergence is the survey's
strongest signal -- four separate agents independently named the damage
representation.

**What this doc must preserve:** the distinction between *observed* and
*proposed*. `findings.md` holds only what was read in the tree or measured with
a contention-free probe. Everything else is a ledger task with an explicit
falsification gate. A plausible mechanism must not silently become a selected
fix.

## Investigation rules

Inherited from docs 17, 18 and 28 and non-negotiable here:

- **Every task ships its own one-off verification script**, written before the
  change and run on both sides of it. The script is the task's primary gate.
  Put it in `scripts/research/33/` with the task's id in the filename, commit it
  with the change, and record its before/after output in the task's finding. A
  task whose script cannot be written is a task whose claim is not yet stated
  precisely enough to work on -- that is the gate doing its job.
- **Prefer a deterministic counter to a timing.** Most items in this doc are
  invisible to the calibrated ladder (see `F8`), so a wall-clock verdict cannot
  decide them. An allocation count, a call count, a `MemoryLayout.stride`, a
  published-frame count, or a damaged-row count is exact, needs no idle machine,
  and cannot be shopped for. `19/D4` set this precedent as the "countable
  claim"; this doc adopts it as the default rather than the fallback.
- **A complexity win is a win.** `D1` settles this for the whole doc: a task may
  be justified by a measured speed or memory improvement, **or** by deleting a
  class of possible wrong states or a body of compensating scaffolding, and a
  task that does only the latter is not second-tier. The granularity rubric says
  to report the mismatch even where current cost is acceptable, because the
  flatten/compute/re-coalesce code and its dedup, memo and optional-array
  scaffolding disappear with the fix -- "that scaffolding is the structure
  apologizing". What a task may not do is claim a speed win it did not measure.
  Each task states which of the two it claims, and its script proves that one:
  for a complexity claim the script measures the structure -- call sites
  deleted, allocations reached zero, a state that can no longer be constructed
  -- not the wall clock.
- **The paired benchmark is the non-regression check, not the win.** Where a
  workload genuinely contains the cost, run
  `just benchmark-quick baseline=<pre-change revision> workload=<w>` and record
  the decision-bearing values. Where it does not, say so and do not run it --
  an `equivalent` on a workload that cannot contain the mechanism is not
  evidence, and `31/F18` shows three of the six workloads returning directional
  verdicts on byte-identical source.
- **Read [agent-docs/terminal-performance.md](../../../agent-docs/terminal-performance.md)
  before quoting any number in it.** Several figures this survey inherited are
  dated and one is corrected here (`F4`).
- **Pivoting is expected.** The ledger is a set of hypotheses with gates, not a
  plan. A task whose script shows the mechanism is absent, or smaller than
  predicted, is closed `REJECTED` with the measurement inline -- that is a
  result, not a failure. Re-scope freely; the phases are an evidence funnel, not
  a schedule.
- **No implementation before the direction gate** in each phase, per
  `agent-docs/terminal-performance.md`'s "Investigate and report before
  optimizing".

## Trigger and current evidence

No user-visible symptom triggered this. The trigger is structural: the
granularity-mismatch rubric landed in `agent-docs/` on 2026-08-06 with a worked
example (`fba5012b`, `2b4e1604`) and had never been applied as a sweep. The
survey asked each vertical to find work eliminated *by construction* rather than
memoized, explicitly ranking caches and fast paths below representation changes.

What the survey established directly is in `findings.md`. In brief:

- The parser materializes one 32-byte enum per input token before the grid is
  touched (`F1`, stride measured), and `F9` sized that in situ per corpus.
- The frame planner builds a whole-viewport geometry projection above its own
  damage-scoped reuse check, to read one field that is already in the packed
  word (`F4`) -- which corrects `17/F5`.
- Damage is held as a bitset, published as a `Set<Int>`, and re-coalesced into
  spans by every consumer (`F2`).
- A one-row scroll marks the entire scroll region damaged (`F5`).
- On the shipped font, no printable-ASCII ink escapes a cell upward at all, so
  one of the glyph halo's two extra rows is provably unnecessary (`F6`).
- `PackedRetainedRow`'s encode/decode surface has no production caller (`F7`).
- Seven of the nine app-runtime items are invisible to every ladder workload
  (`F8`).

## Current hypotheses

### H1 -- the pipeline's remaining cost is concentrated at representation seams, not inside any one bracket

Each prior doc optimized within a bracket and hit a floor. The survey found the
largest untaken items sitting *between* brackets: parser-to-grid (`F1`),
live-grid-to-retained (`F3`), engine-to-consumer damage (`F2`),
terminal-to-planner geometry (`F4`), planner-to-drawer plan shape. Each seam
flattens a coarse representation and the far side re-derives it.

Supports: `F1`, `F2`, `F3`, `F4` are all seam crossings. Competing explanation:
seams are simply where a reader notices cost, because they are where types
change -- the interior of a bracket may hold equal cost that is harder to see.
Distinguishing experiment: the per-task counters in Phase 1; if seam removal
moves the countable quantities but not any timing, H1 is about complexity, not
speed, and the doc should say so plainly.

**First test, and it is a partial refutation.** `F15` removed the
parser-to-grid seam (`F1`) and the countable quantities all moved -- allocations
to zero, the parse spike from 31 MB to 0 -- while the clock moved the *wrong
way*, +1.7% to +5.4% on the drain. So a seam's flattening is not by itself a
cost: this one traded array traffic in a reused allocator bucket for a call per
token, and the call was dearer. The lesson for the remaining seam tasks (`T9`,
`T11`, `T12`, `T13`, `T20`) is that the granularity the far side works at, not
the fact of the flattening, is what decides whether removing it pays.

### H2 -- publish rate, not per-frame cost, sets the app's streaming CPU

`23/F5` measured 78 published-frame charges in one `scrollback-stream` block
(~165 ms) carrying 80.6 ms of cumulative fence stall -- roughly 470 publishes/s
against at most 120 draws/s. If that ratio holds live, then every per-frame cost
in the planner and the delivery path is multiplied by ~8x more than it needs to
be, and the cheapest global win is to bound the rate rather than shrink any
frame.

Supports: `23/F5`, and now `F12`, which measured it live and confirmed the
direction while correcting the size: a real `cat` publishes 594 frames/s against
120 draws/s, so the multiplier is **4.96x, not 8x**. Competing explanation: much
of the fence stall is main waiting for parsing that must happen regardless, so
the recoverable part is only the plan + copy-on-write + set churn between
fences. That one is still open -- `F12` counts frames, not the CPU inside them.
Distinguishing experiment: `T4`'s publish counter, live rather than in a
benchmark block. **Done, in `F12`.**

### H3 -- a scroll is the worst case in the whole system, and it is the common case

A one-line scroll damages every row of the scroll region (`F5`), so streaming
output re-plans, re-classifies, re-submits and lets Core Animation re-measure
the entire screen's glyphs to express a translation of one row. Every other
finding in the draw and planning verticals is multiplied by this.

Supports: `F5`, plus `17/F6`'s off-main-thread per-glyph bounds cost scaling
with glyph occurrences submitted. `F11` measured it and it is stronger than
stated: a scroll does not damage the region's rows, it escalates to `.full`,
which also refuses the planner's row reuse -- and at the live 16 KiB delivery
size that is 100% of the frames on both plain-text streaming corpora. `F13` then
sized it under a synthetic scroll: 66 damaged rows to express 1, and 11,570
submitted glyph occurrences to express 178 changed cells. Competing explanation:
the retained-row reuse in `PaneFramePlanner` may already absorb most of the
planning half, leaving only the submission half. **Refuted by `F13`** -- the
planner re-inspects all 66 rows and 11,814 cells on every scrolling frame,
because `reusable` is `nil` whenever `damage.isFull`, against 1 row and 179 cells
on the non-scrolling control. Remaining qualifier, also from `F13`: the
amplification is a function of delivery size and reaches 1.0x once a delivery
scrolls the whole screen, so live lines-per-delivery sets the win's real size and
is not yet measured.

### H4 -- the app-runtime vertical has real cost and no instrument, so it has never been ranked

Seven of nine runtime findings cannot be seen by any ladder workload (`F8`).
That is not evidence they are small; it is evidence they are unmeasured. Doc 21
hit the identical wall for pointer gestures and answered it with a purpose-built
probe, which then found a 13.6 ms -> 5.5 us win that no workload would have
surfaced.

Supports: `F8`, `21`'s precedent. Competing explanation: these costs are
genuinely negligible at the pane and tab counts one user runs, and the
instrument would prove it. That is a perfectly good outcome and the probe should
be built to be capable of returning it. **`F14` built it and the competing
explanation won, for the one item it covers.** The first half of `H4` stands --
nothing on the ladder could have produced any of `F14`'s numbers, so the coverage
gap is real -- but the reconcile sweep, the largest of the nine, costs **61 us
per message at 3 tabs and 169 us at 8 tabs / 16 panes**: 0.08% and 0.23% of one
core at the 75 ms coalescing rate. `H4` is therefore **answered for the sweep and
still open for the rest**: checkpoint capture, IPC encode, snapshot construction
and the key monitor remain uninstrumented.

## Candidate direction, pending evidence

Provisional, and deliberately ordered by *confidence times reach* rather than by
predicted percentage:

1. Delete the parser's intermediate action array and print ASCII runs in bulk
   (`T7`, `T8`). Highest confidence, deterministic proof available before any
   benchmark, and it sits on the drain that is ~96% of `scrollback-stream`.
   **Corrected by `F15`:** these are one change, not two. Deleting the array on
   its own is deterministic and costs 1.7-5.4% on the drain, because a call per
   token is dearer than the array traffic it removes; only the run granularity
   `T8` introduces makes the deletion pay. The confidence was in the wrong half.
2. Give damage a shift component so a scroll is a translation (`T9`). Highest
   ceiling, highest risk, and it is the change that makes the damage-bitset
   question (`T20`) worth answering.
3. Bound publish rate by consumer demand (`T10`). Removes a multiplier on
   everything downstream and retires the 16 KiB read-cap's reason to exist.

Items 2 and 3 interact: bounding publish rate without shift damage still redraws
whole screens, just fewer times; shift damage without rate bounding still fences
main ~470 times a second. Either alone is a win; the order above is chosen so
each is independently verifiable.

Running alongside them, and **not ranked below them**, is a set of tasks whose
justification is structural under `D1` -- they delete a class of wrong states or
the scaffolding that compensates for one, and no calibrated rule can score them
either way:

- `T20` damage carries words end to end: an out-of-range row becomes
  unrepresentable, so `init(rows:)`'s sanitizer, the test pinning it, the
  `sorted()`, and three redundant set constructions all delete.
- `T11` geometry off the frame path: deletes a whole-viewport traversal from a
  damage-scoped path, and retires a duplicated spacer-head rule.
- `T12` fused planner passes: deletes `colorized` and `DecorationCandidate`
  rather than optimizing them -- compute-then-dedupe scaffolding.
- `T17` inline CSI storage: `keepingCapacity: true` currently does nothing by
  construction, which is the structure apologizing in one line.
- `T18` exact fills: over-draw stops being a thing the clip must prevent.
- `F3`'s `PackedRetainedRow` retirement: a 643-line file describing a
  representation the engine no longer uses.

These are cheap, independently revertible, and each is a legitimate commit on
its own evidence. Several are also the precondition that makes a Tier-1 item
expressible -- `T20` is how `T9` states shift damage at all.

## Task ledger

Each task names the file it touches, the by-construction claim, the
verification script that gates it, and the finding that will record the result.
Scripts live in `scripts/research/33/`.

### Phase 1 -- prove the mechanisms exist and size them, without changing behavior

These are all counters. None requires an idle machine, a paired run, or a
direction gate; several may kill their own follow-on task, which is the point.

- [x] `T1` DONE -- **Size the parser's intermediate action array in situ.**
  Script: feed each committed corpus through `TerminalInputStream.feed` and
  report, per corpus, token count, peak `[TerminalStreamAction]` capacity, total
  bytes allocated, and the reallocation count. `F1` establishes stride 32 by
  layout probe; this establishes the live magnitude per corpus rather than by
  extrapolation. Record in a new finding. Gate for `T2`: if plain-text corpora
  do not show token counts within ~1x of their byte counts, the ASCII-run
  premise is wrong.
  **Result in `F9`, script `scripts/research/33/t1-action-array-size.py`. The
  gate passed:** `scrollback-stream` produces exactly 1.000 tokens per byte and
  the two other plain-ish corpora sit at 0.86, so the ASCII-run premise holds.
  The array is confirmed live in an `-O` build -- 275,355 of 275,355 feed calls
  returned the predicted capacity -- and the parser hands the allocator 60-80x
  the corpus's own byte count in total array bytes.
- [x] `T2` DONE -- **Count per-printed-cell bookkeeping.** Script: instrument
  `Terminal.print`/`printNarrow` call counts for
  `terminalUnicodeClassification`, `invalidateInspection`,
  `rememberOpenCluster`, `searchMatchCache.invalidate`, and
  `damageActionSnapshot` construction, over the four corpora. This sizes the
  bulk-run win in `T8` before it is written (the ledger originally said `T4`,
  which is now the publish-rate counter). Expected shape: each is called once per
  printed character while its inputs are constant across a run within one row.
  **Result in `F10`, script `scripts/research/33/t2-print-bookkeeping.py`. The
  expected shape held exactly:** `terminalUnicodeClassification` and
  `rememberOpenCluster` equal the print count to the unit in all five corpora,
  and `invalidateInspection` from `printNarrow`/`printWide`, `contentIdentity`
  and `currentStyleId` equal the printed-cell count. ASCII runs are 8.3 to 44.8
  characters long, so those sites collapse **3.9x to 36x** under `T8` and the
  per-action `damageActionSnapshot` falls 2.5x to 16.9x. One caveat for `T8`:
  `currentStyleId` misses its cache once per corpus on the plain-text workloads,
  so hoisting it saves a call, not an interning.
- [x] `T3` DONE -- **Count damage-representation round trips per frame.**
  Script: per published frame, report damaged-row count, `Set<Int>` allocations
  (drain + `init(rows:)` + halo + union), hash operations, and whether the
  emitted spans were already sorted before `sorted()` ran. Feeds `T20` (the
  ledger originally said `T10`, which is now the publish-rate task) and supplies
  the diff-shape evidence `30/D2` asked for.
  **Result in `F11`, script `scripts/research/33/t3-damage-round-trips.py`.**
  A row-damaged frame costs **exactly 4 `Set` allocations, 3 array allocations**
  and 386 to 721 hash operations, of which **198 = 3 x 66** are the planner's
  membership lookups -- three per row, not two, because the padding sweep asks
  the `replanning` predicate a second time. The spans were **never** already
  sorted (0 to 2 calls out of 5,438), and they coalesce to one span per frame
  anyway. The larger result is the one the task did not ask for: at the live
  16 KiB delivery size, `scrollback-stream` and `unicode-wrapping` publish
  `.full` on **every** frame, all of it from `recordDamage(from:to:)`'s
  `topRow` guard, so the streaming corpora never execute this apparatus and
  never get row-scoped drawing either. `T20` therefore stays a complexity claim
  and a rider on `T9`; `T9` gains Phase 1's strongest evidence.
- [x] `T4` DONE -- **Count published frames per second, live.** Script or
  small patch: expose `TerminalPaneFenceMetrics.delivery.count` on a sampling
  surface (this is doc 25's `T3`, still unbuilt) and report publishes/s and
  draws/s during a real `cat` of a large file, not a benchmark block. Gate for
  `T10` (the ledger originally said `T7`, which is now the parser-streaming
  task): `H2` predicts a ratio near 8:1; if it is near 1:1 live, `T10` is dead
  and should be closed with the number.
  **Result in `F12`, script `scripts/research/33/t4-publish-rate.sh`. The gate
  passes and `T10` stays open:** a real `cat` publishes **594 frames/s against
  120 draws/s, a ratio of 4.96:1**, reproduced to 0.2% across two runs. So the
  direction of `H2` is confirmed and its size is corrected from ~8x to 4.96x.
  Two method results come with it. A **debug** build reads 1.07:1 -- exactly the
  reading that would have wrongly closed `T10` -- because per-frame cost, not
  delivery rate, binds when the app is unoptimized, so any publish-rate reading
  must be release configuration. And an **occluded** pane publishes and draws
  nothing at all, so the script has to put the slot's window on screen. The
  sampler this added is the in-app surface doc 25's `T3` asked for, so that task
  is unblocked -- it still wants the visibility tagging and the hidden flood.
- [x] `T5` DONE -- **Count damaged rows per scroll event.** Script: feed N
  newlines at the bottom of a full screen and report damaged rows per published
  frame, plus the glyph occurrences the resulting plan submits. `F5` establishes
  the code path; this establishes the amplification factor. Gate for `T9`.
  **Result in `F13`, script `scripts/research/33/t5-scroll-amplification.py`. The
  gate passes with Phase 1's largest margin, so `T9` is unblocked:** at one line
  per delivery a scroll damages **66 rows to express 1**, and a line of text plus
  a newline submits **11,570 glyph occurrences to express 178 changed cells --
  65x**. The probe measures its own denominator rather than assuming one: it
  diffs the viewport across the `topRow` shift, so the ideal is the damage `T9`'s
  shift component would actually publish. `F11`'s correction holds under a
  synthetic scroll -- 100% of the escalation is the `topRow` guard, the damage
  `Set` receives **zero** rows across 1,800 scrolling frames, and the planner
  re-inspects all 66 rows and 11,814 cells because `reusable` is `nil` under
  `.full`. The control settles `F5`'s open question: the same 178 cells rewritten
  *without* moving the viewport damage 1 row, inspect 179 cells and submit 356
  glyphs. Two bounds ride along: the amplification decays to **1.0x** at 91 lines
  per delivery (one 16 KiB read turn), so live lines-per-delivery is the number
  that places production on the curve, and the control's residual 2.0x on glyphs
  is `F6`'s halo, which `T14` owns and `T9` cannot remove.
- [x] `T6` DONE -- **Build the per-`Msg` work counter the runtime vertical has
  no instrument for.** Script: a headless `DanTermCore` harness reporting, per
  `Msg`, the number of panes visited, projection calls, `allPanes` walks,
  `containerShapeNode` allocations, and `liveTabIds` set constructions. This is
  doc 21's answer applied to `H4`, and it is the gate on `T23`. (An earlier
  version of this entry named `T14`-`T16`; a renumbering turned those into
  draw-side tasks, and the runtime task this actually gates is `T23`.) It is
  legitimate for this to report "negligible at 3 tabs" -- build it so it can.
  **Result in `F14`, script `scripts/research/33/t6-msg-work.py`. It reported
  exactly that, and it reported the mechanism as total:** the sweep visits every
  pane **4 times**, runs all **12** projections, and rebuilds every tab's
  `ContainerShapeNode` tree, with **byte-identical counters for seven different
  messages** -- including `splitRatioChanged`, whose diff is empty by
  construction. `liveTabIds` is the one quantity the ledger over-counted: it is
  built **once per message**, in `update()`'s `reconcileMru` defer, not per
  projection. And the absolute cost at the sizes one user runs is **61 us per
  message at 3 tabs / 3 panes and 169 us at 8 tabs / 16 panes**, which is
  **0.08% and 0.23% of one core** at the 75 ms coalescing rate; 480 panes reaches
  4.1%. So `T23`'s mechanism is confirmed and its speed justification is not --
  see `F14`'s inference, which measures the reconciliation ADR's own
  "concrete high-pane report" bar and fails it.

### Phase 2 -- the three highest-reach structural changes, each behind its Phase 1 gate

Direction gate: do not start any of these until its Phase 1 counter has run and
its number is recorded. Each needs a `decisions.md` entry before implementation.

- [x] `T7` **LANDED as the second half of `T8`** (rejected as a standalone
  change first: `F15`, `D5`; re-gated and landed on top of the run granularity:
  `F17`, `D6`) -- **Stream the parser: delete `[TerminalStreamAction]`.**
  `TerminalInputStream.feed` returns an eager array; `Terminal.feed` iterates it.
  Ideal: the parser pushes each action into the grid reducer as it is
  recognized, so the array never exists. Both types are in the same module, so
  no cross-module dispatch is introduced. Verification: `T1`'s script must
  report zero intermediate allocations; independently,
  `just terminal-memory-probe --payload scrollback-plain --chunk 0` must go from
  today's 64.47 MB / coverage 0.35 / 37.2 MB `MALLOC_LARGE (empty)` to a
  chunk-invariant footprint near the chunked figure -- a deterministic proof
  that needs no benchmark discipline. Then `benchmark-confirm` on `terminal-feed`
  and `scrollback-stream` as the non-regression check. **Carry forward:**
  `Terminal.feed`'s comment justifying the carried-forward damage snapshot
  currently argues "the parser is not interleaved with the loop"; under
  streaming that argument must be replaced with the stronger true one (parser
  state lives in `inputStream`/`absorber`, which `damageActionSnapshot` does not
  read), or the next reader will believe the invariant was violated.
  **Result in `F15`, script `scripts/research/33/t7-streaming-parser.py`,
  implementation parked in `t7-streaming-parser.patch`. Both halves of the gate
  ran and they disagree:** the by-construction claim holds exactly -- the token
  stream is F9's to the unit at three chunkings, no action is ever collected, and
  the single-shot footprint falls from 103.72 MB to 72.61 MB, which is
  **chunk-invariant to 0.00 MB** and takes `15/F7`'s 37.2 MB of
  `MALLOC_LARGE (empty)` down to 6.2 MB. The non-regression check fails:
  `benchmark-confirm` reads **`slower` +5.43% on `scrollback-stream`** (+1.66%
  headless on an idle machine), because the per-token call boundary costs more
  than the array traffic it saves -- a call, an indirect 32-byte return, and a
  defensive 1,273-byte copy of `Terminal` before each damage snapshot, at ~106 ns
  per token. The spike this deletes is not paid at the 16 KiB delivery size and
  the drain cost is. `D5` re-scopes this as the second half of `T8`, whose runs
  of 8.3 to 44.8 characters (`F10`) amortize exactly the boundary that costs here.
  **Re-gated on top of `T8` in `F17` and landed (`D6`): the sign inverted.**
  Streaming is now **4.4% to 11.2% faster** than the eager array on four
  fixtures, largest on the two corpora with the *shortest* runs, and the pair
  reads `faster -69.32%` on `scrollback-stream`. `F17` also corrects why this
  task existed: **`T8` alone already deleted the 31 MB parse spike**, taking the
  single-shot footprint difference from 30.95 MB to 0.12 MB, because an array
  holding one action per 44.8-character run is 36x smaller and is not a spike.
  So `F15`'s memory table is not `T7`'s case; a measured drain win and `D1`'s
  complexity claim are.
- [x] `T8` **LANDED, with `T7` (`D6`)** --
  **Print ASCII runs in bulk.** **Carried `T7`** (`D5`): the streaming parser is
  built and gated but costs 1.7-5.4% on the drain at per-token granularity, and
  this task is what changes that granularity. An ASCII printable is
  narrow and grapheme-break-`.other` *by construction from the generated table*,
  so a run of them can neither join a cluster nor be wide. One damage record,
  one `invalidateInspection`, one content-identity range, one style id, one
  `rememberOpenCluster`, one snapshot/diff per run. `F10` sizes it: runs average
  8.3 to 44.8 characters, so the per-character sites collapse 3.9x to 36x and the
  per-action snapshot 2.5x to 16.9x. Subsumes doc 10's parked
  `H1(a)` without its cursor-repaint trap, since the run's start and end rows are
  both still diffed. Cuts the run at row end, insert mode, wide-cell overwrite,
  the content-identity wrap, an open Prepend cluster, and any non-ASCII byte.
  **Result in `F16`, script `scripts/research/33/t8-bulk-ascii-runs.py`. Both
  gates pass and the second one by far more than the doc predicted:** every
  counter falls to **exactly `F10`'s predicted count, to the unit, on all five
  corpora** -- 36.0x on `scrollback-stream`, 3.9x on the worst corpus, and the
  Unicode table is read **zero** times on `incremental-screen-updates`. Printed
  characters, cursor, scrollback depth and screen text are identical between the
  arms, and the full suite passes including the 67-fixture 7-byte-split replay.
  `scrollback-stream` reads **`faster` -71.08%**, its drain falling 153.2 ->
  70.5 ms, and `terminal-feed`'s raw blocks -32.8%. Three results ride along.
  `benchmark-confirm` **cannot issue a verdict on a change this fast**: it
  calibrates `terminal-feed`'s batch on the baseline arm and the candidate then
  fails the 1-second block floor, invalidating the whole invocation, so the
  per-workload readings are `benchmark-quick`. The two churn workloads report a
  calibrated plan-metric `slower` of +4.1% to +7.1%, reproduced five times,
  against a **~7x fence-stall reduction and 13-16% less process CPU** in the same
  blocks -- ~1.7 ms of planning given up for ~33 ms of stall recovered; `F16`
  records the mechanism as measured and unexplained. And `T10` gets *more* to
  recover, not less: the faster drain raised the delivery count 6% in three of
  five invocations.
- [ ] `T9` VETTING -- **Give damage a shift component.** `moveAndFillRows` marks
  the whole scroll region damaged (`F5`). Ideal: damage carries
  `(region, delta, newlyFilledRows)`; the view realizes the shift as a
  backing-store translation and draws only the newly filled rows plus rows whose
  content actually changed. A whole-viewport redraw for a translation becomes
  unrepresentable. Verification: `T5`'s script must show damaged rows per scroll
  fall to O(1); plus a bitmap-equivalence assertion that an incrementally
  scrolled screen is byte-identical to a full redraw of the same state.
  **Risks, all named:** damage escalating to `.full` on scroll is currently what
  makes row reuse sound (the damage-aware planning plan lists this as an explicit
  deferred non-goal); selection, search-match, cursor and hover overlays are not
  row-local under a shift and must be re-derived after it; `scrollRect(_:by:)`
  on a layer-backed view needs verifying against the backing store. A wrong
  shift shows as a torn screen, not a slow one.
- [ ] `T10` VETTING -- **Bound publish rate by consumer demand.** `T4`'s gate is
  passed: `F12` measured 594 publishes/s against 120 draws/s live, so five of
  every six published frames are overwritten before any display pass sees them.
  The consumer holds a deadline and will not fence again until
  `lastDelivery + refreshInterval`, arming exactly one one-shot timer while
  damage is pending -- so no damage means no timer and no wakeup, and doc 25's
  "no display link, no poll on the hot path" (`25/F1`) survives. Verification:
  `T4`'s counter must show publishes/s fall to the display rate;
  `cumulativeFenceStallNanoseconds` must fall by roughly the same factor. **Must
  not reintroduce** the failure doc 25 named when it rejected an occluded
  urgent-only tier: semantic events, clipboard, child exit and
  `onPrimaryHistoryMutation` reach the runtime only through delivery and must
  bypass the deadline as a separate small payload, not a full frame publish.

### Phase 3 -- well-scoped, independently landable

Each is small enough to verify with one script and revert cleanly. No ordering
constraint among them except where noted.

- [ ] `T11` VETTING -- **Take `terminal.geometry` off the frame path.** Verified
  in `F4`. Add `kind` to `forEachViewportRow`'s per-cell callback (free: same
  packed word, one shift and mask) and a small cursor-placement accessor; the
  planner then never constructs a `TerminalGeometry`. Verification: a script
  asserting `presentedRowGeometry` is called zero times per `planFrame`, plus a
  row-allocation count per frame. `TerminalGeometry` survives as the test
  projection it now is. **Also correct `9`'s Phase 5 note and `17/F5` when this
  lands** -- both imply this was retired with `9/H2`, and `F4` shows it was not.
- [ ] `T12` VETTING -- **Fuse the planner's five per-row passes into one.**
  `inspectedCells` materializes a `[PlannedCell]` per row that four further
  passes re-read, then `colorized` rebuilds every text run it touches. Ideal:
  four open-run accumulators inside the single existing cell visit; text runs
  come out already pushed and already coalesced, so `colorized` and
  `DecorationCandidate` are deleted rather than optimized. Verification: per-row
  allocation count and passes-per-row count. **Heed `31/F13`:** the accumulators
  must be locals of the row body, not captures re-read per column -- that
  mistake cost 60% of a browsing regression once.
- [ ] `T13` VETTING -- **Resolve cell style at style-run granularity.**
  `forEachViewportRow` already holds `lastId`/`lastStyle` and hands the same
  `TerminalStyle` to every column of a run, then discards that knowledge at the
  callback boundary; `resolveCellStyle` re-derives it ~11,800 times per full
  frame. Ideal: the visit yields `(columns: Range<Int>, style:)` segments.
  Verification: `resolveCellStyle` call count per frame must fall to the
  distinct-style-run count. Predicts a *divergence* between `content-churn` and
  `style-churn`, which is the mechanism confirming itself.
- [ ] `T14` VETTING -- **Derive the glyph halo from font ink extents.** `F6`
  measured that no printable-ASCII ink escapes a cell upward on the shipped font,
  so `row+1` need never be planned or submitted -- 3N haloed rows become 2N plus
  a sub-pixel band. Verification: `sparse-spans-max`'s topology contract must
  report 34 drawing rows where it reports 50 today, at the same 17 spans; plus
  bitmap redraw-equivalence. **Must union over every contributing face** (four
  styled faces, the packaged symbols face at cell-width point size, and the
  `CTLine` fallback whose extents are not tabulated) and fall back to today's
  full-row halo whenever any face fails containment, so the worst case is
  current behavior.
- [ ] `T15` VETTING -- **Build sprite cell geometry once per metrics.** Geometry
  is a pure function of `(pattern, cellWidth, cellHeight, strokeWidth)` over a
  closed finite pattern domain, recomputed and reallocated per cell per draw.
  The file's own `brailleLayout` hoist is the precedent. Verification:
  allocation count under `BoxDrawingSpriteGeometry.geometry` per draw must reach
  zero. Check first that the corpora actually contain sprites, or the workload
  cannot contain the mechanism.
- [ ] `T16` VETTING -- **Scan arena words for the style and hyperlink sweeps.**
  `liveStyleIds`/`liveHyperlinkIds` call `allPaintedDisplayRows`, materializing
  every retained display row as a `GridRow` with full cell construction, to
  collect a 4-byte field the arena already holds packed (`F7` context). Ideal:
  `forEachStyleId` scanning words directly. Verification: rows materialized per
  sweep must reach zero, plus an equality test that the word-walk live set equals
  the `allPaintedDisplayRows`-derived one.
- [ ] `T17` VETTING -- **Inline the CSI/escape sequence collections.** Capacities
  are already compile-time constants (24 parameters, 4 intermediates), yet
  `clearCollection`'s `removeAll(keepingCapacity: true)` reallocates all three
  buffers per sequence because copy-on-write sees them non-uniquely referenced --
  so `keepingCapacity` does nothing by construction. Inline storage makes the
  types POD and the eight array-literal intermediate comparisons in `dispatchCSI`
  collapse to one integer switch. Verification: allocations per CSI must reach
  zero. Preserve the parameter-overflow drop and saturating `.max` verbatim.
- [ ] `T18` VETTING -- **Make the fills exact.** Two full-surface background
  fills per draw (one in `draw(_:)`, one in `drawRenderFrame`), correct only
  because both are clipped, while the exact span rects sit on the stack one line
  above. Verification: fill-rect area per draw compared against damaged area.
  Sequence before any fill-batching lead, since this decides the fill topology.

- [ ] `T24` VETTING -- **Own the `benchmark-confirm` block floor.** `F16`
  discovered that `confirm` calibrates `terminal-feed`'s fixed execution batch
  on whichever arm runs first, so a candidate that finishes the batch under the
  1-second block floor self-invalidates the whole invocation and no workload
  gets a verdict -- which is why the largest win in this doc carries only
  `quick` digits. Ideal: calibrate the batch per arm (each arm fills its own
  floor) or size the batch on the faster arm, so a big win lengthens the
  baseline's block instead of invalidating the candidate's. Verification: an
  A/A run on byte-identical arms must still read `equivalent` with unchanged
  thresholds, and a re-run of `F16`'s pair (`63c693da` against `90731fdc`) must
  issue a `confirm` verdict for all six workloads. Harness change, so
  `31/F18`'s directional-verdict-on-identical-source check is the regression
  gate.

### Phase 4 -- gated reopens and larger bets

Each of these reopens something a prior doc closed. None may start without a
`decisions.md` entry that states the prior decision, quotes its written
reopening condition, and argues that condition is met.

- [ ] `T19` RESEARCH -- **POD `GridCell` via a terminal-owned spill table.**
  `TerminalScalars.Storage.spill` is the only non-trivial member, so every
  `[GridCell]` operation is a per-element value-witness loop instead of a
  `memcpy`, and `appendCells` decodes and re-encodes each cell at the
  live-to-retained seam. Ideal: `GridCell` holds the C1 word verbatim -- the
  layout `PackedRetainedRow.Header` already defines and `LogicalLineStore`
  already reads -- with multi-scalar payloads in a `Terminal`-owned table, the
  same swept-live-set discipline already shipped for `styleTable`. **Prior
  decision:** `12/F8` implemented and reverted this at +6.74% on
  `scrollback-stream`. Its written reopening clause is *"either row-move traffic
  stops being hot on `scrollback-stream`, or cluster scalars find an owner that
  does not enlarge the row"* -- and the survey argues both now hold, because
  `9ad7cc5` deleted `[GridRow]` scrollback and a terminal-owned table adds no
  refcounted field to the row. Verification: assert `MemoryLayout<GridCell>.stride`
  rather than reasoning about it (`15/F15`), and check the malloc bucket at
  **both** 80 and 179 columns (`15/F12`) before predicting anything. Watch
  `incremental-mixed`, since `16/F3`'s revert was a scattered-read effect.
  **Do not pitch this as "a smaller cell"** -- `28/D10` and `16/D1` settled
  stride-for-its-own-sake, and this competes with `28/H8`, which moves *when* the
  encode runs where this deletes *what* it encodes.
- [ ] `T20` RESEARCH -- **Damage carries words end to end.** Named independently
  by four of six verticals (`F2`). Claims **complexity, not speed**, and that is
  sufficient under `D1`: a width-bounded bitset makes an out-of-range row
  unrepresentable, so `init(rows:)`'s `filter { $0 >= 0 }`, the test that pins
  it, the `sorted()` in `terminalDamageMaximalContiguousSpans`, and three
  redundant `Set` constructions per frame all delete; the halo becomes
  `w | w<<1 | w>>1` and spans come out canonical from a word scan. Verification
  is structural, not timed: `T3`'s counters must reach zero allocations and zero
  hash operations on the damage path, and a `TerminalDamage` holding a row
  outside the grid must fail to compile or fail to construct. **Prior
  decision:** `30/D2` rejected exactly this and wrote *"do not reopen this for
  the sort"*, reopening only *"if the damage representation is being changed for
  another reason and the ordered form falls out for free"* -- so sequence it as
  a rider on `T9` or `T14`, which do exactly that. Do not claim a percentage:
  `17/F5` measured `clipFramePlan` at 0.05% and 0.00%, and `31/F18` rates
  `incremental-mixed` at 4.9 points. See `D2`.
- [ ] `T21` RESEARCH -- **Stop retaining `lastPlannedTerminal`.** `planIfNeeded`
  runs a deep whole-`Terminal` equality one line after `pendingDamage != .none`,
  and retaining the previous generation holds a second reference to every arena
  chunk, so the next in-place append finds it non-uniquely referenced and copies.
  **Split the task:** deleting the *retention* is cheap and safe; replacing the
  *check* with a generation token is what `31/DD52` declined, for its
  silent-wrong-answer (torn frame) mode. Verification: first, an assertion under
  the benchmark recording whether the equality check ever disagrees with
  `pendingDamage != .none` -- if it never does, the check is provably redundant
  and its deletion is evidence-backed rather than argued.
- [ ] `T22` RESEARCH -- **Push, don't poll, for `pane tape --follow`.** A 50 ms
  repeating timer fences the terminal owner queue per tick per subscription
  regardless of pane activity, so a silent pane costs the same as a flooding one
  (~20 main-thread wakeups/s against Apple's ~1/s idle target). The tape
  recorder already has an append point to signal from; keep the existing
  one-in-flight rule as the rate limit. Verification: idle wakeups with one
  subscription open on a silent pane, per doc 25's `T1` shape. **Add this to doc
  25's ledger** -- its `F1` idle survey concluded no periodic timer exists on the
  render path, which is true and missed this one.
- [ ] `T23` RESEARCH -- **Scope the reconcile sweep.** Gated on `T6`. Every
  sweep rebuilds the whole model's view state for an event that named one pane,
  up to 13 Hz under shell-driven title/cwd/progress messages, and boxes a fresh
  `ContainerShape` tree per tab to compare it. Ideal: `update()` returns a
  change set produced *inside* the existing mutation chokepoints, and structural
  identity becomes a revision counter bumped by the setter. **The reconciliation
  ADR explicitly forbids** a shared precomputed `allPanes` context bag absent a
  concrete high-pane report, so this must be pitched as scoped passes and must
  clear that same bar. Verification: `T6`'s counter, plus a debug-only assertion
  that scoped projections equal full projections after every `Msg`.
  **`T6`'s gate has run and this fails it as a speed task (`F14`).** The
  mechanism is confirmed exactly -- 4 whole-model pane walks, 12 projections and
  a rebuilt shape forest per message, identical across seven messages -- and the
  bar the ADR set is a concrete high-pane report, which 61 us at 3 tabs (0.08% of
  a core at the coalesced rate) is not. Keep this only as a **complexity claim
  under `D1`**, ranked below every item with measured evidence, and do not write
  a percentage into it. Two smaller items `F14` surfaced are independent of the
  scoping and much cheaper: `TabModel.derivedChrome` is recomputed 2-4 times per
  tab per sweep (each one a tree walk plus two `NSHomeDirectory()` calls) and is
  half the sweep at the realistic size, and `sessionBell`'s `tabForPane` scan is
  the only `update()` half whose cost grows with the model.

## Rejected

Carried from the survey so they are not re-litigated. Each names the doc that
settled it.

### Batching glyph submission by face and colour

`18/L1`: implemented, **+31% slower** on both draw workloads, reverted
(`18/F13`, `18/D5`). `CTFontDrawGlyphs` re-splits a call into display-list
entries by geometry, so our call count never controlled the entry count.

### Stride 24 (and 20) for `GridCell`

`16/D1`, `16/F3`: implemented, worth +19% history at 179 columns and +49% at 80,
and reverted because `incremental-mixed` came back `slower` twice. At stride 32 a
64-byte line holds exactly two cells and every cell is line-aligned. Treat 32 as
a resting point; a candidate stride that does not divide 64 needs the paired
benchmark before anything else.

### Pre-sized unsafe buffers for the draw run loop

`18/L4`, `18/D7`: measured `faster` (-2.98%, -2.49%) and reverted anyway, because
`showGlyphs`' exact-count requirement makes the safe version impossible. Do not
re-propose.

### Read-side PTY throttling while hidden, parse-side deferral, a separate occluded urgent-only tier, a standing App Nap assertion

All four rejected in doc 25 with mechanisms recorded. The occluded-tier rejection
is the one `T10` must actively avoid reintroducing: primary-history mutation
reaches the runtime only through delivery.

### A stored `[PaneId: ...]` index on `AppModel`

`Model.swift` "Pane Access": deliberately absent because it reintroduced
dual-write drift. If pane lookup ever matters, the answer is scoping (`T23`),
not an index.

### Deque/BitSet/OrderedSet at the twelve surveyed container sites

`27/D1`, `27/D2`: all twelve failed the adoption bar, including the damage
accumulator's internals. `T20` is a different change -- the public seam type,
not the accumulator's internals -- and must say so explicitly rather than read
as re-litigating `27/D2`.

### Hybrid or viewport-adjacent lazy reflow of history

`28/H7`, with its reopening condition **exhausted** by `31/F16` (+0.94%). A
future reopening needs a new rule against new evidence.

## Open questions and caveats

- **`18/D7`'s variance measurement is still unbuilt and still gates several draw
  items.** Three captures of one unchanged build, no code change. Doc 18 ranks it
  above its own remaining leads because the profiler contradicted the calibrated
  benchmark in opposite directions twice. `T14`, `T15` and `T18` all rest on
  profiler-sourced shares; treat their sizes as unscored until this exists.
- **Two candidates are unscoreable by any rule this project owns.** An
  `updateLayer`-owned bitmap (`18/L14`) would score `slower` on the only
  calibrated instrument while reducing total process CPU, and `18/L9`'s subpixel
  work is entirely off-thread. Neither should be attempted without a new
  decision rule screened first, and `29/F8` warns the CPU quantity may refuse to
  calibrate again.
- **The churn workloads are frame-rate-capped at ~119-120 draws/s** (`17/F16`),
  so a CPU reduction there is battery and thermal headroom, not throughput. Say
  which one a task is claiming.
- **`19/C2`/`C3`/`C5` reopen together past ~4x doc 15's history depth**, and
  nobody has checked that gate against today's arena, which retains far past that
  depth at the 16 MiB budget. Not this doc's vertical, but it is unowned.
- **`sparse-spans-max` and `synchronized-frames` issue no verdict** (`29/D3`,
  `23/D4`). Their topology and coverage checks are still useful for diagnosis;
  their CPU differences are not decision-bearing.
- The survey was read-only. No benchmark and no profile was run, because six
  concurrent agents would have poisoned any measurement. The only measurement
  taken is `F6`'s font ink-extent probe, which is a static query with no timing
  and no contention.

## Outcome

Investigation in progress. **Phase 1 is complete: `T1` through `T6` have all
run. Phase 2 has begun: `T8` and `T7` have both landed as one change (`F16`,
`F17`, `D6`), and `T9` and `T10` remain.** `T1` sized the parser's
action array in situ (`F9`) and passed `T2`'s gate, and `T2` then sized the
per-printed-cell bookkeeping (`F10`) and found the expected shape exactly --
every named site runs once per printed character, and ASCII runs are long enough
for `T8` to collapse them 3.9x to 36x. So `T7` and `T8` are the two tasks whose
mechanism is now measured rather than argued.

`T3` (`F11`) counted the damage round trips and returned two answers. The one it
was asked for confirms `F2` and sizes it small: 4 `Set` allocations, 3 array
allocations and 386-721 hash operations per row-damaged frame, on a set bounded
by 66 -- so `T20` stays a complexity claim under `D1`, exactly as `30/D2`
concluded on the numbers. The one it was not asked for is bigger: at the live
16 KiB delivery size the two plain-text streaming corpora publish `.full` damage
on every frame, entirely because a scroll changes `topRow`, so they never reach
the damage set *or* row-scoped planning and drawing. That makes `T9` -- shift
damage -- the best-evidenced structural item in the doc, and it makes `T5` a
confirmation rather than a discovery.

`T4` (`F12`) then counted the live publish rate and passed `T10`'s gate. A real
`cat` in a real pane publishes 594 frames a second and draws 120 -- a 4.96:1
ratio that reproduces to 0.2% -- so `H2` is confirmed in direction and corrected
in size, from the ~8x it inferred from `23/F5` to a measured 4.96x. Deliveries
and publishes match to within two frames across 7,000, so nothing coalesces
before the publish; the only coalescing in the pipeline is the one AppKit does
between publish and draw, after every per-frame cost has already been paid. Two
method results ride along and both would have inverted the verdict: a debug
build reads 1.07:1, because per-frame cost rather than delivery rate binds when
the app is unoptimized, and an occluded pane publishes nothing at all. `T10` is
therefore live with its multiplier measured, and `T4`'s script is its
before/after gate.

`T5` (`F13`) then confirmed the scroll amplification and put numbers on both of
its halves. Feeding one line per delivery at the bottom of a full screen, a
scroll damages **66 rows to express 1** and submits **11,570 glyph occurrences to
express 178 changed cells -- 65x** -- and the probe measures its own denominator
by diffing the viewport across the `topRow` shift, so the ideal is the damage
`T9` would actually publish rather than an assumed one. Both halves of the
amplification are total: the planner re-inspects all 66 rows and 11,814 cells,
which refutes `F5`'s hope that row reuse absorbs the planning side, and the
drawer receives the whole screen's text. The non-scrolling control -- the same
178 cells rewritten in place -- damages 1 row, inspects 179 cells and submits 356
glyphs, so the row-scoped path is not broken; a scroll is what disables it. Two
bounds came with it. The amplification decays with delivery size and is **1.0x**
at 91 lines per delivery, which is one 16 KiB read turn, so the single most
useful measurement before `T9` starts is live lines-per-delivery -- it places
production somewhere on a 66x-to-1x curve. And the control's residual 2.0x on
glyphs is the glyph halo from `F6`, which `T14` owns and `T9` cannot remove.

`T6` (`F14`) then built the per-`Msg` runtime counter `H4` asked for and closed
the phase. It is the one Phase 1 task whose result is a *negative*, and it is the
one the ledger explicitly said to build so it could be. The mechanism is
confirmed and is more total than the ledger claimed: a message naming one pane
walks every pane **four times**, runs **all twelve** projections, and rebuilds
every tab's `ContainerShapeNode` tree, and **seven different messages produce
byte-identical counters** -- including `splitRatioChanged`, whose diff is empty
by construction. The sweep does not vary with the message at all. But the
absolute cost is **61 us at 3 tabs / 3 panes and 169 us at 8 tabs / 16 panes** --
**0.08% and 0.23% of one core** at the 75 ms coalescing rate -- and only reaches
4.1% at an unrealistic 60 tabs / 480 panes. The reconciliation ADR had already
accepted this rebuild and named its reopening bar as a concrete high-pane report;
this is the measurement that bar asked for, and it fails it. So `T23` is
**closed as a speed task** and survives, if at all, only as a complexity claim
under `D1`. One correction rides along: `liveTabIds` is built **once per
message**, in `update()`'s `reconcileMru` defer, not once per projection, so the
ledger over-counted it. And two cheaper items the counter surfaced are not
`T23` at all -- `TabModel.derivedChrome` is recomputed 2-4 times per tab per
sweep, each time a tree walk plus two `NSHomeDirectory()` calls, which is half
the sweep at the realistic size; and `sessionBell`'s `tabForPane` scan is the
only `update()` half whose cost grows with the model.

**Phase 2 has started with `T7` (`F15`), and its result is a correction to this
doc's own ranking.** Streaming the parser does exactly what it claimed
structurally: the token stream is F9's to the unit, nothing collects an action,
and the single-shot footprint becomes chunk-invariant -- 103.72 MB to 72.61 MB,
with `15/F7`'s 37.2 MB of `MALLOC_LARGE (empty)` down to 6.2 MB. It also costs
**+5.43% on `scrollback-stream` under `benchmark-confirm`** and +1.66% headless,
because a per-token call boundary is dearer than the array traffic it deletes:
the array is 1.5 MB into reused allocator buckets per 16 KiB turn, read back from
L1, while the streaming shape pays a call, an indirect 32-byte return and a
defensive 1,273-byte copy of `Terminal` on every one of ~1.5 M tokens. The spike
it deletes is not paid at production's delivery size; the drain cost is. So `T7`
is **parked in `t7-streaming-parser.patch` and re-scoped as the second half of
`T8`** (`D5`), whose 8.3-to-44.8-character runs (`F10`) amortize precisely that
boundary. The doc's first candidate direction listed `T7` and `T8` as two
independently confident items; they are one change, and the confidence was in the
wrong half.

So Phase 1 leaves three tasks with measured mechanisms and one closed. `T9` is
unblocked with the largest margin in the phase (66x rows, 65x glyphs), `T10` with
a measured 4.96x publish multiplier, and `T7`/`T8` with the parser's array and
its per-character bookkeeping sized per corpus. `T23` is the phase's one
rejection, and `H4` is answered for the reconcile sweep and still open for the
other eight runtime items `F8` named.

**`T8` then landed (`F16`) and it is the largest measured win in the doc.** The
by-construction premise held exactly: a printable ASCII scalar is narrow and
grapheme-break-`.other` in the generated table, and Prepend is the only class an
`.other` scalar does not break from, so one comparison decides whether a run's
head could join an open cluster and nothing in a run can be wide. Every site
`F10` counted collapsed to **exactly `F10`'s predicted count, to the unit, on all
five corpora** -- two independently built counters agreeing on five workloads --
and `terminalUnicodeClassification` does better than the prediction because the
bulk path never consults the table at all: on `incremental-screen-updates` it is
read **zero** times against 2,500,025 before. The clock moved much more than this
doc expected: `scrollback-stream` reads **`faster` -71.08%** with its drain
falling 153.2 ms to 70.5 ms and its throughput 10.0 to 21.6 MB/s, and
`terminal-feed`'s raw blocks read -32.8%. `F10` had claimed no wall-clock share
at all, correctly, and the reason the share turns out to be this large is that the
collapsed sites are eight rather than one, and the two biggest are
`damageActionSnapshot` and its diff -- which carry `F15`'s 1,273-byte defensive
copy of `Terminal` with them, so deleting 96.8% of the snapshots deletes 96.8% of
those copies.

Three results ride along and two of them are about the instrument rather than the
change. **`benchmark-confirm` cannot issue a verdict on a change this fast.** It
calibrates `terminal-feed`'s fixed execution batch on whichever arm runs first,
which is the baseline, and the candidate then completes that batch in under the
harness's 1-second block floor, so the invocation self-invalidates and reports
nothing for any of the six workloads. `confirm` is all-or-nothing by design, so
every per-workload verdict in `F16` is a 2-pair `benchmark-quick`. That floor is
now a live limitation for any feed-path change of this size and nothing in the
ladder owns it. Second, the two churn workloads return a **calibrated
plan-metric `slower` of +4.1% to +7.1%, reproduced five times**, so it is not
noise -- against a ~7x fence-stall reduction (37-39 ms to 4.5-6.5 ms) and 13-16%
less process CPU in the same blocks. `T8` touches no planner code and hands the
planner a byte-identical grid; in three of five invocations the delivery count
rose 6% and plan time rose in lock step with plan-per-delivery flat, and in the
other two it did not, so `F16` records the mechanism as measured and unexplained
rather than resolving it. Third, `T10` now has slightly *more* to recover: a
faster drain does not change the 4.96:1 publish ratio and in three invocations it
raised the delivery count, so `T8` and `T10` are complements.

**`T7` was then re-gated on top of that and landed with it (`F17`, `D6`), and its
sign inverted.** `D5` had predicted the run granularity would amortize the
per-token call boundary and turn a cost into a win; it did, by more than
break-even. Streaming is now **4.4% to 11.2% faster** than the eager array on
four fixtures, against the +1.66% it cost before, and the pair reads
**`faster -69.32%`** on `scrollback-stream`. The gain is *largest on the two
corpora with the shortest runs* -- -11.2% and -10.2% against -4.4% where runs are
44.8 characters -- which is the opposite of what pure amortization predicts and
says the win is not only the boundary: those two corpora are CSI-heavy, so their
token count stays high under `T8` and the array they no longer build stays large.

**The churn plan-metric question `F16` left open is closed by ablation
(`F18`).** Thread CPU inside the plan bracket equals its wall time on both arms
of every block, so the planner is never off-CPU and the contention hypothesis is
refuted; the `slower` is composition -- the candidate plans 55-63% more frames
per draw at 30-35% less per frame, because the faster drain publishes more
often, and `planNanosecondsPerDraw` charges that as slowness. The extra plans
are exactly what `T10` would delete. Alongside it, the landed pair was hardened
after review: the identity-wrap straddle decline gained its missing test
(`7b9c1d06`), and `printBulkASCII` and `printNarrow` now share one narrow-cell
writer (`50595488`) -- gated by the counter script reading 1.0x arm-to-arm with
`F16`'s run structure reproduced to the unit, a fully inlined `-O` disassembly,
and a paired `equivalent` -0.28% on `scrollback-stream`.

`F17` also corrects why `T7` existed at all. **`T8` alone had already deleted the
31 MB parse spike**, taking the single-shot footprint difference from 30.95 MB to
0.12 MB, because one 32-byte action per 44.8-character run is 36x smaller than one
per character and is no longer a spike. So `F15`'s memory table is not `T7`'s
case; `T7` is justified by a measured 4-11% drain win and by `D1`'s complexity
claim -- no chunk size can make the intermediate token representation large,
because it does not exist. One method caveat rides along and is the reverse of
this project's usual ordering: `T7`'s marginal sign comes from the headless A/B,
because `benchmark-confirm` cannot run on a change this fast and
`benchmark-quick` returns disagreeing signs on a 4% drain effect inside a block
that is mostly not drain.
