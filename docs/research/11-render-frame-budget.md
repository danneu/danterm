# Render frame budget

Research started: 2026-07-28. **Status: scoped, Phase 1 partially evidenced. No
change proposed yet. Doc 13 closed on 2026-07-28 and handed over its evidence
(see "Evidence handed over from doc 13"), which corrects this file's only sizing
measurement and adds a whole cost this file had never measured.**

**Two things a fresh reader should know before anything else.** Profile share
overstated recoverable time by ~3x on the one node where that has been tested
(F2), so the sums in the hypotheses below are soft. And the backend A/B -- the
instrument this file calls the only one that can settle the 2x claim -- does not
currently run (F3).

## Purpose

This file owns one question:

> Can DanTerm's CPU CoreText draw path meet the frame budget at real terminal
> geometry -- and if not, is that a property of the *implementation* or of the
> *architecture*?

It exists because [10-terminal-feed-hotspots.md](10-terminal-feed-hotspots.md)
closed by eliminating the alternative. That file removed roughly a quarter of the
byte-consumption path and its two render-bound workloads moved **+0.03%** and
**+0.63%**, on calibrated `equivalent` verdicts (`10/F9`, `10/D5`). Feed cost is
not what makes render-bound work slow, so the remaining explanation for the
whole-app comparison that opened doc 10 -- the Swift backend using roughly twice
the CPU of the libghostty backend -- lies on the draw path.

Scope split from the two adjacent files:

| Question | Owned by |
| --- | --- |
| `Terminal.feed` cost | doc 10 (**closed**) |
| Per-cell / per-draw allocation hotspots in `planFrame` and `drawRenderFrame` | doc 9 |
| Costs visible only in a live-app profile under real input | doc 13 (**closed**) |
| **Does the draw path fit the frame budget, and optimize-or-replace** | **this file** |

The distinction from doc 9 is deliberate and narrow. Doc 9 asks *where the draw
path spends time and how to spend less*. This file asks *whether the resulting
number is small enough*, and owns the architectural decision that follows. Doc 9
stays authoritative for draw hotspots; nothing here duplicates its hypotheses,
and this file's first gate is explicitly "go finish doc 9's".

## Investigation rules

Inherited from doc 10, because they were earned there and none is specific to
feed:

- **Sample shares are attribution, not timings.** Name the inclusive root and the
  artifact.
- **A directional claim uses `benchmark-confirm`, not `benchmark-quick`.**
- **Verify a change on a workload that can see it.** Doc 10 recorded its largest
  win as unproven for a day because it was verified on `content-churn`, which
  cannot register feed work (`10/F9`). The mirror-image trap applies here:
  `terminal-feed` and `scrollback-stream` are the workloads that *cannot* see
  draw work. Use `content-churn` and `style-churn`.
- **A finding's attribution can be wrong even when its measurement is right**
  (`10/F4` versus `10/F8`). When a node survives an experiment, the experiment
  has excluded only what it actually varied.

Two rules specific to this file:

- **Never quote a draw cost without its geometry and its scenario.** Full-frame
  and damage-clipped differ by more than an order of magnitude (F1), and cost is
  linear in cell count, so a number without both is unreadable.
- **A profile share is an upper bound on what removing the work recovers, not an
  estimate of it.** Earned here: removing per-draw font construction *entirely*
  recovered about a third of its measured share (F2). Never total up unharvested
  shares and compare the sum to the frame budget -- that is this file's central
  question and the arithmetic does not support it.

## Trigger and current evidence

Two observations, one inherited and one measured here.

**Inherited, and explicitly not current.** The whole-app comparison that opened
doc 10 showed the Swift backend using roughly twice the CPU of the libghostty
backend on the same interactive workload. That figure predates three shipped
feed optimizations and has not been reproduced since. It is the reason this
question exists and it is **not** evidence for anything until Phase 1 re-measures
it.

**Measured, 2026-07-28 (F1).** A btop-shaped full-frame draw costs 15.6 ms at
160x50 and scales linearly with cell count, implying about 23 ms at DanTerm's
real 179x66 geometry against a 16.7 ms frame interval. Damage-clipped draws of
the same content cost 1.36 ms.

**The evidence boundary this file must preserve:** F1 measures a draw path doc 9
has already shown to be unoptimized -- at the time, four `CTFont` constructions
per call, no glyph cache, unreserved array growth. No number here may be read as
the cost of CPU glyph rasterization *in principle*, only as the cost of the
current implementation. That distinction is the entire difference between H2 and
H3. (Two of those three have since landed; the glyph cache has not.)

**Third observation, added 2026-07-28 (F2), and it is about the evidence rather
than the app.** Removing per-draw font construction outright recovered roughly a
third of what its profile share predicted. Since every remaining estimate on
either side of the H2/H3 split is a profile share, this file's arithmetic is
softer than it reads.

## Evidence handed over from doc 13

[13-live-app-compositing-and-draw-hotspots.md](13-live-app-compositing-and-draw-hotspots.md)
closed on 2026-07-28 and handed its evidence here, per its own Phase 3 task. It
owns costs that appear only when the **real app** is profiled under **real user
input**; it explicitly does not own the optimize-or-replace decision and did not
make it. Four live `sample` captures of a person holding down-arrow in btop, plus
one deterministic fixture probe.

Two of the four items change what this file already believed. The other two are
additive.

**1. `13/F5` corrects this file's only sizing measurement, and the correction is
material.** `benchmark-draw`'s fixture routes **every** cell to a sprite family
and reaches the font path **zero** times: `CTFontGetGlyphsForCharacters`,
`CTFontDrawGlyphs` and `drawTextCell` are never called, at either grid. All
twelve of its distinct scalars are box-drawing, braille or block-element, and all
three families are total over their coarse ranges, so routing cannot fall
through. **F1's 15.6 ms and the ~23 ms extrapolation therefore contain no glyph
rasterization at all** -- they are sprite fills plus per-run dictionary
construction plus planning overhead. This is not a caveat about synthetic
fixtures; it is a hole in the middle of the number, and it lands directly on the
H2/H3 split, because H3 is precisely the claim that *CPU glyph rasterization has
a floor*. See F1's caveats below, now amended.

**2. `13/F10` adds a cost this file has never measured: the compositing stall.**
F1 draws into an offscreen bitmap, so it observes no CoreAnimation and no window
server by construction. In the live app the main thread **blocks 1,224 samples --
31.3% of its busy time -- inside `CABackingStoreGetFrontTexture`**, synchronously
waiting on a secondary `CA::CG::Queue` thread to replay the previous display
list. That is not CPU; it is wait, and no instrument in "The instruments" below
can see it. Across doc 13's three comparable captures the main-thread *draw*
subtree fell 30% while this stall **grew**, from 25.0% to 31.3% of busy.

**3. `13/H3` attributes that stall, and the attribution is stable.** The queue
thread's dominant cost is `DrawGlyphs::compute_dod_` -> `get_glyph_bboxes` ->
`FPFontGetGlyphIdealBounds` -> `TFPFont::CopyGlyphPath` -> a 64-entry outline
cache: **CoreAnimation copying glyph outline paths purely to compute bounding
boxes, and missing its cache while doing it.** Bounds computation costs 3.4x
actual rasterization (644 samples versus 189). The share held at 42.2% of the
queue thread against 41.6% in the first capture, through a profile in which
everything upstream of it moved -- which is why doc 13 treats it as stable rather
than a one-profile artifact. **`13/H3` is nonetheless still open**: confirming it
needs an experiment that varies the `DrawGlyphs` op count or the distinct-glyph
count per frame, and doc 13 never ran one.

**4. `13/F8` is procedural evidence, not draw evidence.** It records a change
decided on the strength of a single workload and the stricter instrument that
checked it. It is here because this file's Investigation rules already inherit
that discipline from doc 10; it bears on *how* this file decides, not on what it
decides.

**What the hand-over does not license.** Doc 13's own inference is that R3 -- the
glyph-bounds thrash -- is the largest remaining item on the draw path and did not
inherit the effect of the three landed optimizations. That is an input to the H2
versus H3 question, **not an answer to it**, and doc 13 kept R3 research-only for
exactly that reason. Two limits travel with the evidence and must not be dropped:
the live workload is unthrottled key repeat, so a faster main thread produces more
frames per second and "more compositing work" is an equally good reading of the
stall's growth (`sample` cannot count frames); and every live figure is a single
capture, human-paced, with the magnitudes held at medium uncertainty by doc 13
itself.

## The instruments

Three exist already; none needed to be built.

- `just benchmark-draw` -- headless, no GUI, no PTY. Draws a **btop-shaped** plan
  into an offscreen sRGB bitmap at `displayScale: 2`, in two scenarios
  (`full-frame`, `damage-clipped`) across two grids (80x24, 160x50), with
  calibration passes so caches are warm and the measurement is steady-state.
  This is the primary instrument for sizing and it is cheap. **Read `13/F5`
  before quoting it**: its fixture draws no glyphs, so it sizes the sprite path
  and not the font path.
- `just benchmark-draw-app` -- fixed-row updates through the real optimized AppKit
  draw path.
- `scripts/terminal-benchmark.sh <workload> <backend>` -- **the backend A/B, and
  as of F3 it does not run.** It builds and runs the app under
  `DANTERM_TERMINAL_BACKEND=swift|ghostty` against the same fixture workload.
  This is the instrument that produced the 2x observation, and it is the only
  one that could settle it -- but its ghostty arm hangs before the pane's shell
  starts, and the three `full-screen-*` redraw workloads have no ghostty code
  path at all. **Read F3 before attempting it**: the workload name in this file
  is an alias the script does not accept, and the redraw workloads need
  `DANTERM_TERMINAL_BENCHMARK_REDRAW_UPDATES=50`. Note also its asymmetry: the
  final-draw instrumentation records
  `{available: false, reason: "unavailable-for-ghostty-backend"}`, so a backend
  comparison reads total process CPU, not a draw-time delta. The swift arm works
  and is reproducible (0.788 s and 0.768 s total process CPU on
  `full-screen-content-churn`, ~4.2 s wall).

**The gap doc 13 documents, restated as an instrument fact:** none of the three
observes CoreAnimation, the `CA::CG::Queue` replay thread, the backing-store
stall, or the window server. The first draws into a bitmap; the other two read
process CPU. A cost worth 31.3% of live main-thread busy (`13/F10`) is invisible
to every instrument this file has. The only thing that has ever seen it is a
human-driven `sample` capture, which is not repeatable on demand. Doc 13's Phase
4 owns the open question of whether a scripted live-compositing instrument is
worth building; `13/F10` sharpened it by producing a frame-count confound that
only such an instrument could close.

## Current hypotheses

### H1 -- the CPU draw path exceeds the 60Hz frame budget on a full-frame redraw at real geometry

`makeBtopShapedPlan` at 160x50 costs **15.6 ms per full-frame draw** (F1). Cost
is linear in cell count, and DanTerm's real geometry is 179x66 = 11,814 cells
against 160x50's 8,000, so the same draw extrapolates to roughly **23 ms** --
about **1.4x the 16.7 ms budget** at 60Hz, on the main thread.

Supporting evidence: F1, and the fact that the extrapolation is a straight line
rather than a guess -- 4.17x the cells produced 4.18x the time.

Competing explanation: real full-frame redraws may be rarer than the btop-shaped
fixture implies, in which case the damage-clipped figure (1.36 ms at 160x50,
about 1.5 ms extrapolated) is the number that governs felt performance and the
budget is met with room to spare. This is exactly the case for `content-churn`
being unmoved by feed work while ordinary typing feels fine.

Confirmed if an app profile on a redraw-shaped workload at real geometry shows
draw time at or above the frame interval.

**Doc 13's captures are that app profile, at that geometry, and they neither
confirm nor refute H1 as written.** Four live samples at 179 columns under a real
held-key scroll (`13/F1`, `13/F10`) put `drawTextRuns` at 46.3% of main-thread
busy falling to 35.7% after three optimizations landed -- an *attribution*, not a
timing. `sample` reports shares of busy samples and cannot produce milliseconds
per draw, so the one number H1 turns on is exactly the one a live capture cannot
give. What the captures do establish is that the question is not academic: on the
same workload the main thread *also* blocks 31.3% of its busy time waiting on
compositing (`13/F10`), a cost H1's framing does not contain at all.

### H2 -- the gap is implementation, not architecture

Doc 9 has already attributed large, unexploited inefficiencies inside the CPU
draw path, and none has been harvested:

- ~~`drawTextRuns` constructs **four `CTFont` objects on every call** (`9/H3`).~~
  **Landed 2026-07-28** (`5d32054`), result in F2. It moved the right way and
  **by much less than its share predicted** -- see below.
- There is **no glyph cache**; `CTFontGetGlyphsForCharacters` is 11% of draw
  (`9/F3`). **Still open**, and the same `9/H3` entry. Blocked on the
  glyph-bearing fixture (`13/F5`), and F2 predicts it will underperform its
  share.
- ~~Unreserved array growth in `drawTextRuns` is 14% of draw.~~ **Landed
  2026-07-28** as doc 13's R4 (`07dd81f`), result in `13/F9`, doc 9's Phase 5
  entry closed. Thirteen per-run collections hoisted above the run loop.

**Part of this hypothesis has now been tested, and it moved the right way.**
Three of the inefficiencies H2 names have landed -- R4 above, plus `13/R1` (the
per-run attributes dictionary, 18.3% of live `drawTextRuns`, now reading **zero**
samples in the live tree) and `13/R2`. On the live workload `drawTextRuns` fell
from 46.3% to 35.7% of main-thread busy (`13/F10`), roughly a 30% reduction in
the draw subtree. That is H2's mechanism working as advertised, at roughly the
size H2 predicted, and it is the strongest evidence this hypothesis has.

**What it does not settle.** H2's claim is not "the draw path can be made
faster" -- that is now demonstrated -- but "made fast *enough*", and the harvest
is not finished: `9/H3`'s glyph cache remains, and it is the half that bears on
glyph work specifically. More importantly, `13/F10` showed the compositing stall
did **not** shrink alongside the draw subtree; it grew. Whatever H2's remaining
harvest is worth, it is worth it against a main thread where a third of busy time
is a wait H2's mechanism does not touch.

**And F2 has now weakened H2's arithmetic.** Every estimate of what remains here
is a `sample` share, and the one node whose share has been tested against its
actual removal recovered about a third of what the share implied. H2's remaining
headroom is therefore smaller than the profiles read, by an unknown factor that
is at least not zero. This does not refute H2 -- the three landed changes really
did take `drawTextRuns` from 46.3% to 35.7% -- but it means "add up the
unharvested shares and compare to the budget" is not a valid way to decide this
hypothesis, and that was the implicit method.

Supporting evidence: doc 9's original attributions, plus `13/F9` and `13/F10`
for the part that landed.

Competing explanation: per-cell CoreText glyph rasterization has a floor that no
amount of caching removes, and the fixed costs above are merely the visible part.
`13/F5` sharpens this into a real problem rather than a rhetorical one -- the
only measurement backing either side of the H2/H3 split never rasterizes a glyph,
so *nobody has yet measured the floor H3 posits*.

Confirmed if doc 9's draw-side backlog lands and F1's full-frame figure falls
below roughly 16 ms extrapolated to 179x66 -- **on a fixture that reaches the font
path**, which per `13/F5` the current one does not.

### H3 -- the gap is architectural, and compositing has to move to the GPU

libghostty composites a GPU-rendered `IOSurfaceLayer`
(`app/TerminalView.swift`, the `ghostty_surface_*` path). DanTerm's Swift backend
rasterizes glyphs on the CPU per frame. If H2's harvest is insufficient, this is
the remaining explanation and the remaining fix.

**Doc 13's hand-over cuts both ways here, and the two directions should not be
collapsed.**

*Toward H3.* The stall `13/F10` measures is a genuinely architectural cost, and
it is one this file had never counted: the main thread waits 31.3% of its busy
time on a CoreAnimation queue replaying a CPU display list. A GPU-composited
surface does not build that display list and would not produce that wait. It
survived three draw-path optimizations untouched -- indeed it grew while they
shrank the CPU above it -- which is exactly the shape H3 predicts and H2 does
not.

*Against H3, or at least against reading the above as support.* `13/H3` attributes
the stall not to rasterization but to CoreAnimation **computing glyph bounding
boxes by copying outline paths**, missing a 64-entry cache while doing so, at 3.4x
the cost of the rasterization itself. That is a cache-shaped problem inside the
compositor, not a floor under CPU rasterization -- which makes it, on its face, an
H2-shaped finding wearing H3's clothes. Doc 13 kept it research-only (its R3) and
never ran the experiment that would confirm the attribution. And `13/F5` means
the sizing number this file would weigh against it has never rasterized a glyph.

The honest position: **the compositing stall is now the largest single item on
the live main thread, and nobody knows yet whether it is architectural or a cache
miss.** That is a question to answer, not a verdict to record.

Deliberately **not** scheduled first. It is by far the largest change available
and it would be justified by an argument this file has not yet made -- and doc
10's whole arc is a warning about acting on an attribution before the cheap
experiment that could refute it. `10/F8` corrected `10/F4`'s attribution;
`10/F9` corrected `10/F5`'s conclusion. Both corrections cost minutes.

## Candidate direction, pending evidence

**Provisional, and deliberately unambitious: do doc 9's existing work before
opening anything new here.**

1. **Harvest `9/H3`.** *(Per-draw `CTFont` construction landed 2026-07-28,
   `5d32054`, F2. The glyph cache is what remains, and it is now **gated behind
   item 3** -- the fixture cannot execute it, so it cannot be measured first.)*
2. **Re-measure the backend A/B.** ~~One run of
   `scripts/terminal-benchmark.sh content-churn swift|ghostty` replaces a
   remembered "2x" with a current number, and it costs minutes.~~ **It does not
   cost minutes and that command does not run** (F3). Either repair the ghostty
   arm, retire it, or take the figure from a human-paced `sample` capture and
   accept doc 13's limits on it.
3. **Fix the fixture before re-running F1.** `13/F5` established that
   `benchmark-draw`'s plan reaches the font path zero times, so re-running F1
   after a *glyph-cache* harvest would measure a change the fixture cannot
   execute -- the same class of error doc 10 made when it verified feed work on
   `content-churn` (`10/F9`), which this file's Investigation rules already
   forbid. Either add a glyph-bearing scenario or record why the sprite-only
   figure is the one that governs.
4. **Re-run F1 and decide.** Under budget at real geometry closes this file in
   H2's favour. Still over it, and H3 becomes a design question -- at which point
   it graduates to `docs/design/`, because "replace CoreText rasterization with
   GPU compositing" is an architecture decision, not a research task.

What this ordering is guarding against: H3 is the interesting hypothesis and
would be the largest change in the app's history. Doc 10 corrected two of its own
attributions with experiments that cost minutes each (`10/F8` correcting
`10/F4`, `10/F9` correcting `10/F5`). Committing to a renderer rewrite on the
strength of a single sizing measurement of an admittedly unoptimized path would
repeat exactly the error those corrections caught.

## Task ledger

### Phase 1 -- size the problem

- [x] Measure the CPU draw path headlessly, both scenarios, both grids. Result:
  F1.
- [ ] **Re-measure the 2x claim. BLOCKED on instrument repair -- see F3.** It
  comes from the observation that opened doc 10 and has not been reproduced
  since; three feed optimizations have landed in the meantime. Until this
  exists, "2x" is a remembered figure, not a current measurement.
  - Attempted 2026-07-28. **The command as written above cannot be run**:
    `content-churn` is a compare-harness alias, the script spells it
    `full-screen-content-churn`, and that workload needs
    `DANTERM_TERMINAL_BENCHMARK_REDRAW_UPDATES=50`. The swift arm then works
    (0.788 s / 0.768 s process CPU). The **ghostty arm does not run at all** --
    the redraw workloads have no ghostty code path, and on corpus workloads the
    pane's shell hangs in `/usr/bin/login`. F3 records what was eliminated;
    don't re-derive it.
  - Next concrete step: `sudo sample` the hung root-owned `login` pid, or
    decide to retire the arm. A human-paced `btop`/`sample` capture is the
    available substitute for the figure itself.
- [ ] Confirm the real geometry figure rather than extrapolating: add 179x66 to
  `DrawBenchmarkGrid.standard`, or record why the two standard grids suffice.
- [ ] Establish how often a full-frame draw actually happens in
  `content-churn` and `style-churn`. H1's competing explanation turns on this
  and nothing currently measures it.
- [ ] **Give `benchmark-draw` a scenario that reaches the font path**, or record
  why the sprite-only fixture is the right one. `13/F5` proved the current plan
  routes every cell to a sprite family and calls `CTFontDrawGlyphs` zero times,
  so F1's figure omits glyph rasterization entirely. Until this is settled no
  re-run of F1 can test H2's glyph-cache half or H3's floor.
- [ ] **Decide what to do with the compositing stall (`13/F10`, `13/H3`).** It is
  31.3% of live main-thread busy, no instrument here can see it, and it is
  unattributed between "architectural" and "a 64-entry cache miss inside
  CoreAnimation". Doc 13 handed it over as its R3, deliberately unstarted.

### Phase 2 -- direction gate

- [ ] **Gate: harvest doc 9's draw-side backlog before deciding anything here.**
  **Partially satisfied as of 2026-07-28.** The unreserved array growth landed
  (doc 13's R4, `13/F9`), as did two changes doc 13 found independently
  (`13/R1`, `13/R2`); together they took live `drawTextRuns` from 46.3% to 35.7%
  of main-thread busy (`13/F10`). Per-draw `CTFont` construction landed too
  (`5d32054`, F2). **The missing glyph cache is the whole of what remains, and
  it is the half that bears on glyph work.** Deciding H2 versus H3 before it
  lands would still be deciding on an implementation nobody has tried to make
  fast, and on a fixture that cannot execute the change (`13/F5`).
  - **What F2 changed about this gate.** The gate was written assuming the
    harvest's value could be read off the profile shares. It cannot: removing
    the one node that has been tested recovered ~3x less than its share. So
    satisfying this gate now requires *measuring* the glyph cache after the
    fixture exists, not estimating it -- and a small measured result would be a
    real result, not a failure to harvest properly.

### Phase 3 -- decide

- [ ] Re-run F1 after the harvest. Under budget at real geometry closes this file
  in H2's favor; still over it promotes H3 to a design question and hands it to a
  design doc rather than a research one. **Two conditions on this task that did
  not exist when it was written:** the re-run needs a glyph-bearing fixture
  (`13/F5`), and "under budget" must now account for a compositing stall the
  instrument does not measure (`13/F10`) -- a draw that fits 16.7 ms of CPU still
  misses the frame if the main thread then blocks a third of its time waiting on
  the compositor.

## Findings log

### F1 -- a full-frame CPU draw costs 15.6 ms at 160x50, and scales linearly with cell count

- Status: recorded. Sizing measurement. Not a comparison and not a verdict.
- Date and investigator: 2026-07-28, Claude (agent).
- Commit and worktree state: `6c878f0`, tracked tree clean; untracked
  `notes.md` / `plans/wip/*` enter no build.
- Command: `just benchmark-draw` (15 iterations, 400 ms target block).
- Measurements -- nanoseconds per single draw, the median of 15 stable
  iterations. `drawDurationNanoseconds` is `total / batchCount`
  (`TerminalDrawBenchmarkSupport.swift:137`), so these are per-draw, not
  per-batch:

  | Grid | Cells | Scenario | Per draw |
  | --- | ---: | --- | ---: |
  | 80x24 | 1,920 | full-frame | **3.73 ms** |
  | 80x24 | 1,920 | damage-clipped | **0.73 ms** |
  | 160x50 | 8,000 | full-frame | **15.6 ms** |
  | 160x50 | 8,000 | damage-clipped | **1.36 ms** |

- Repeatability: the 15 iterations span 3.70-3.79 ms, 0.723-0.733 ms,
  15.46-15.82 ms, and 1.344-1.360 ms respectively -- under 2.5% in every cell.
  This is a far tighter instrument than either benchmark harness.
- Observation 1: **full-frame cost is linear in cell count.** 4.17x the cells
  (1,920 to 8,000) produced 4.18x the time (3.73 to 15.6 ms). That linearity is
  what makes extrapolation to other geometries legitimate rather than a guess:
  179x66 = 11,814 cells implies about **23 ms per full-frame draw**, against a
  16.7 ms budget at 60Hz.
- Observation 2: **damage clipping is worth more than 11x** at 160x50, and it
  scales sublinearly (1.86x for 4.17x the cells) because the clipped region
  tracks changed rows rather than the whole grid. Extrapolated to 179 columns it
  is roughly 1.5 ms. This is presumably why ordinary use feels fine while a
  full-screen redraw does not, and it is the same full-frame-versus-localized
  split doc 10 found on the feed side.
- Inference: supports H1 directly and supplies the mechanism for `10/F9`'s
  otherwise bare null -- `content-churn` and `style-churn` did not move for a
  quarter of the feed path because a full-frame draw at real geometry plausibly
  costs more than the entire frame interval on its own.
- **Competing interpretation, and it is a strong one:** this measures a draw
  path that doc 9 has already shown to be unoptimized -- four `CTFont`
  constructions per call, no glyph cache, unreserved array growth (`9/H3`,
  `9/F3`). So 15.6 ms is what *this implementation* costs, not what CPU
  rasterization costs. Reading it as an argument for GPU compositing would be
  exactly the attribution error `10/F8` corrected. That is why Phase 2 gates on
  doc 9's backlog.
- Uncertainty: low on the measurement, low on the linearity, **high on the
  interpretation** until the harvest lands and the 2x claim is re-measured.
- Caveats on the fixture: btop-shaped and synthetic, `displayScale: 2`, drawing
  into an offscreen bitmap rather than through AppKit's real surface. The first
  is appropriate (it is the shape that opened both files); the third means the
  absolute figure omits whatever compositing costs the window server adds.
- **Amendment, 2026-07-28, from `13/F5` and `13/F10`. Both of the caveats above
  understated their case, and neither is a matter of degree.**
  1. "btop-shaped and synthetic" does not say what the probe found: the fixture
     routes **every cell to a sprite family** and reaches
     `CTFontGetGlyphsForCharacters` / `CTFontDrawGlyphs` / `drawTextCell`
     **zero times**, at both grids. All twelve distinct scalars are box-drawing,
     braille or block-element, and all three families are total over their coarse
     ranges. So 15.6 ms and the ~23 ms extrapolation are **sprite fills plus
     per-run dictionary construction plus planning overhead, with glyph
     rasterization entirely absent** -- and `CTFontDrawGlyphs` was 17.8% of
     `drawTextRuns` in the live capture that measured it (`13/F2`). The fixture
     is defensible for what it was built for (run fragmentation and sprite
     geometry); the error is reading its output as "the cost of a btop-shaped
     draw".
  2. "omits whatever compositing costs the window server adds" is now quantified,
     and it is not a rounding term: in the live app the main thread blocks
     **1,224 samples, 31.3% of busy**, waiting on the CoreAnimation replay queue
     (`13/F10`). The offscreen bitmap does not merely omit a small addend -- it
     omits the largest single item on the live main thread.

  Neither amendment touches the measurement. F1's numbers are correct for what
  they measure; what they measure is narrower than the finding claimed.
- Next action: the unchecked Phase 1 items -- which `13/F5` has now grown by one,
  the glyph-bearing fixture -- then the Phase 2 gate.

### F2 -- removing per-draw `CTFont` construction entirely recovered under a third of its profile share

- Status: recorded. Directional comparison, confirmed by non-overlapping repeat
  runs on two of four scenarios. **Its value is calibration, not the speedup.**
- Date and investigator: 2026-07-28, Claude (agent).
- Commit and worktree state: `5d32054` (the change itself); measured as working
  tree versus `git stash` of the same tree, so the two arms differ only by this
  change. `docs/research/README.md` was modified and untracked `notes.md` /
  `plans/wip/*` were present in both arms; none enters the build.
- Change measured: `9/H3`'s first half. `drawTextRuns` built four `CTFont`
  objects per call via `metrics.font(bold:italic:)`; the faces now live on
  `TerminalRenderMetrics` as a `TerminalFontSet` built once per geometry sync.
  A draw now constructs no fonts at all -- this is removal, not reduction, which
  is what makes the comparison a clean test of the profile share.
- Command: `just benchmark-draw 25`, **three runs per arm**, arms interleaved
  A/B/B/A to spread thermal drift. Per-draw microseconds, median of 25
  iterations within each run.

  | Grid | Scenario | Baseline (3 runs) | Candidate (3 runs) | Median delta |
  | --- | --- | --- | --- | ---: |
  | 80x24 | full-frame | 13.85 13.93 14.31 | 13.47 13.60 14.07 | -2.4%, overlaps |
  | 80x24 | damage-clipped | 0.663 0.666 0.693 | 0.602 0.610 0.621 | **-8.4%** |
  | 160x50 | full-frame | 241.6 247.0 247.6 | 233.8 244.4 245.3 | -1.1%, overlaps |
  | 160x50 | damage-clipped | 2.118 2.128 2.212 | 2.005 2.051 2.068 | **-3.6%** |

- Repeatability: on both damage-clipped scenarios every candidate run is below
  every baseline run, so the direction holds without needing the medians. Both
  full-frame scenarios overlap and get **no verdict**. The repeat capture was
  taken specifically because a single pair put the smaller delta inside
  run-to-run drift, which was 4% on the first pairing -- larger than the effect.
- Observation 1: **the shape matches `9/F3` exactly.** Font construction was a
  fixed per-draw cost, so removing it is invisible on a large draw and visible
  on a small one. `9/F3` predicted this in words ("small when a draw does a lot
  of glyph work, dominant when it does little") and the split across the four
  scenarios is that prediction reproducing.
- Observation 2: **the magnitude does not match.** `9/F3` put
  `CTFontCreateCopyWithSymbolicTraits` + `CTFontCreateWithName` at **19.5% +
  4.6% and 20.3% + 5.5%** of draw across two incremental profiles -- a tight
  repeat. Removing that work outright recovered **3.6-8.4%** on the comparable
  scenarios. The gap is roughly **3x**.
- Inference, and it is the reason this finding exists: **profile share
  overstated recoverable time by about 3x on this node.** `9/F3` recorded
  precisely this as its competing interpretation -- "CoreText may already cache
  internally, in which case the observed cost is the wrapper and the retain
  traffic rather than real font construction" -- and this measurement is the
  first evidence that decides it. `9/F3` argued against its own competing
  reading on the grounds that `TFont::TFont` and
  `TDescriptor::CreateMatchingDescriptor` appear in the subtree; that argument
  is now known to be insufficient, because construction being real does not
  make it the part that dominates.
- **Consequence for this file, which is larger than the change.** Six draw-path
  optimizations have been selected and justified by profile share. If share
  systematically overstates recoverable time on this path, then H2's remaining
  headroom is smaller than the profiles imply, and every unharvested estimate in
  H2 -- notably `CTFontGetGlyphsForCharacters` at 9-12% across four profiles --
  should be read with a discount rather than at face value. That cuts toward H3
  on the optimize-or-replace question, without settling it.
- **Scope of the calibration, stated so it is not over-applied.** One node, one
  instrument, one fixture. It does not license a 3x discount on every share in
  doc 9 or doc 13. It does establish that the discount is not zero, which is
  what nobody had shown. Note also that the two instruments differ: `9/F3`'s
  shares come from live `sample` captures, F2's deltas from headless
  `benchmark-draw`, and `13/F5` means that fixture reaches no glyphs -- so part
  of the gap could be the fixture rather than the attribution.
- Absolute magnitude, for honesty about the change itself: **~0.07-0.14 us saved
  per damage-clipped draw**, against a 16.7 ms frame budget. It is unmeasurable
  in use. The change earns its place by removing a 20-25% node from future draw
  profiles, sharpening attribution for everything measured after it -- not by
  the time it saves.
- Uncertainty: low on the direction (non-overlapping runs), medium on the 3x
  factor (two instruments, and `13/F5`'s fixture limitation applies to one of
  them), low on the conclusion that the discount is real and non-zero.
- Next action: `9/H3`'s second half, the glyph cache, still needs the
  glyph-bearing fixture before it can be measured at all. When it is measured,
  F2 predicts it will underperform its 9-12% share.

### F3 -- the backend A/B instrument does not currently run, and its invocation is not what this file records

- Status: recorded. **Negative result about an instrument, not about the app.**
  Logged under this file's inherited rule to record inconclusive attempts, so
  the next agent does not re-derive it.
- Date and investigator: 2026-07-28, Claude (agent).
- Commit and worktree state: `8ce4f52` plus the working tree described in F2.
- What was attempted: Phase 1's 2x re-measure, exactly as this file prescribes
  it -- `scripts/terminal-benchmark.sh content-churn swift` against `...
  content-churn ghostty`, comparing total process CPU.
- **Three durable harness facts, none of them recorded anywhere before:**
  1. **`content-churn` is not a script workload name.** It is the
     `benchmark-quick`/`benchmark-confirm` alias; `terminal-benchmark.sh`'s
     closed workload set spells it `full-screen-content-churn` (likewise
     `full-screen-style-churn`, `full-screen-incremental-mixed-churn`). Anything
     outside that set must be a corpus key. The command as written in Phase 1
     and in "Candidate direction" cannot be run verbatim.
  2. **The three `full-screen-*` workloads need
     `DANTERM_TERMINAL_BENCHMARK_REDRAW_UPDATES=50` in the environment.** The
     script defaults it to `0`, and at `0` the producer takes its corpus branch
     and exits `unknown benchmark workload: full-screen-content-churn`. The
     canonical invocation is in `scripts/terminal-benchmark-validation.py`
     (~lines 934 and 1071). Setting it for a *corpus* workload breaks that arm
     instead, so it must be gated on the workload name.
  3. **The three redraw workloads are structurally swift-only.** The producer's
     redraw branch (`scripts/terminal-benchmark-producer.py`, ~lines 311-380)
     unconditionally awaits `start-ack`, `start-draw-ack`, `ready-draw-ack`,
     per-frame `localized-draw-NNNNNN` and `final-draw` -- all Swift-backend
     acks, with **no ghostty branch**. Only the corpus path (`run_workload`)
     branches on backend. So `full-screen-content-churn ghostty` cannot work by
     construction; it dies at the 20 s ack timeout. This is a harness gap, not a
     backend behavior.
- **The ghostty arm is separately broken, on corpus workloads too.** The pane's
  shell never starts: libghostty's Darwin spawn wraps the shell in
  `/usr/bin/login -q -flp <user> /bin/bash --noprofile --norc -c 'exec -l <shell>'`
  (`.ghostty-src/src/termio/Exec.zig:1500`, unconditional on Darwin when the
  passwd lookup succeeds), and that process sits in `Ss` indefinitely with euid
  0. Typed text echoes only via the tty line discipline, because nothing reads
  it.
- **Eliminated as causes** -- each of these cost time and none needs repeating:
  the isolated `HOME`/`TMPDIR`/`ZDOTDIR`; the launch method (direct child and
  `open -n --env` hang identically); the CLI and IPC layers (all three
  `pane.input` routes -- key events, paste with newline, paste plus separate
  Enter -- arrive and echo, verified by window screenshot); libghostty and the
  machine (the same `login` line works under a pty from an ordinary process and
  from the installed Developer-ID-signed `DanTerm.app`); the
  `com.apple.security.get-task-allow` entitlement (an ad-hoc rebuild without it
  hangs the same way); and the crash-restore modal, which **never appears in the
  harness path** -- the ephemeral isolated `HOME` has no checkpoint, so
  `AppDelegate.swift:182` takes the `createTab` branch. The hung app was
  confirmed to have one standard window, zero sheets, and a created pane.
- Remaining suspects, untested: this branch's ghostty spawn path versus the
  bundle signature (production is Developer ID + hardened runtime, the benchmark
  bundle is ad-hoc). **The cheap next step is a `sudo sample` of the hung
  `login` pid** -- it is root-owned, so it cannot be sampled without
  privileges, which is where this stopped.
- Inference: **Phase 1's 2x re-measure is blocked on instrument repair, not on
  measurement time.** This file describes the backend A/B as "the only one that
  can settle it"; right now it settles nothing. A human-paced `btop`/`sample`
  capture is the available substitute and carries doc 13's limits (single
  capture, cannot count frames).
- Uncertainty: none on facts 1-3 or on the eliminations -- all were observed
  directly. High on the root cause of the `login` hang.
- Next action: either the `sudo sample`, or a decision to retire the ghostty arm
  rather than repair it. The arm's shelf life is short: this branch exists to
  remove libghostty, so a repeatable backend A/B is an asset that expires.

## Open questions and caveats

- **Profile share overstates recoverable time on this draw path** (F2). One node
  measured at roughly 3x. Every unharvested estimate quoted from a `sample`
  share -- in this file, doc 9, or doc 13 -- should carry that discount as a
  possibility until a second node is measured the same way.
- **The 2x figure is not currently measured** -- and as of F3 it is not
  currently *measurable*, because the backend A/B's ghostty arm does not run.
  It is inherited from the
  observation that opened doc 10, before three feed optimizations landed. It may
  have moved; `terminal-feed` improved 24% in the interim. Nothing in this file
  should lean on "2x" until Phase 1 re-measures it.
- **This file must not become a rewrite proposal by momentum.** Its Phase 2 gate
  exists precisely because H3 is the expensive, exciting hypothesis and H2 is the
  boring one that would make H3 unnecessary. Doc 10 corrected two of its own
  attributions with experiments that cost minutes; the same discipline applies.
- **`benchmark-draw`'s grids do not include real geometry.** Everything about
  179x66 here is extrapolation from a verified straight line, which is defensible
  but is not a measurement.
- **`benchmark-draw`'s fixture draws no glyphs** (`13/F5`). This is the single
  most important caveat in this file and it is younger than F1, so anything
  written before 2026-07-28 that quotes 15.6 ms or 23 ms should be read with it
  in hand. It does not make F1 wrong; it makes F1 narrower than the sentence
  "a full-frame CPU draw costs 15.6 ms" suggests.
- **A third of live main-thread busy time is invisible to every instrument
  here** (`13/F10`). The blocked wait on CoreAnimation is not CPU and not draw
  time; it will not appear in `benchmark-draw`, `benchmark-draw-app`, or a
  backend CPU comparison. Any statement of the form "the draw path now fits the
  budget" that rests only on those instruments is unsupported on the live
  workload.
- **`13/H3` is unconfirmed and this file must not launder it.** The glyph-bounds
  attribution is stable across four captures and doc 13 believes it, but the
  experiment that would confirm it -- varying the `DrawGlyphs` op count or the
  distinct-glyph count and showing both nodes move together -- has never been
  run. Doc 13 kept it research-only. Inheriting it as settled would be exactly
  the attribution error `10/F8` corrected, which is the error this file's Phase 2
  gate exists to prevent.
