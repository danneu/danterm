# Render frame budget

Research started: 2026-07-28. **Status: scoped, Phase 1 partially evidenced. No
change proposed yet.**

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

One rule specific to this file:

- **Never quote a draw cost without its geometry and its scenario.** Full-frame
  and damage-clipped differ by more than an order of magnitude (F1), and cost is
  linear in cell count, so a number without both is unreadable.

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
has already shown to be unoptimized -- four `CTFont` constructions per call, no
glyph cache, unreserved array growth. No number here may be read as the cost of
CPU glyph rasterization *in principle*, only as the cost of the current
implementation. That distinction is the entire difference between H2 and H3.

## The instruments

Three exist already; none needed to be built.

- `just benchmark-draw` -- headless, no GUI, no PTY. Draws a **btop-shaped** plan
  into an offscreen sRGB bitmap at `displayScale: 2`, in two scenarios
  (`full-frame`, `damage-clipped`) across two grids (80x24, 160x50), with
  calibration passes so caches are warm and the measurement is steady-state.
  This is the primary instrument for sizing and it is cheap.
- `just benchmark-draw-app` -- fixed-row updates through the real optimized AppKit
  draw path.
- `scripts/terminal-benchmark.sh <workload> <backend>` -- **the backend A/B.**
  It builds and runs the app under `DANTERM_TERMINAL_BACKEND=swift|ghostty`
  against the same fixture workload. This is the instrument that produced the 2x
  observation, and it is the only one that can settle it. Note its asymmetry: the
  final-draw instrumentation records
  `{available: false, reason: "unavailable-for-ghostty-backend"}`, so a backend
  comparison reads total process CPU, not a draw-time delta.

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

### H2 -- the gap is implementation, not architecture

Doc 9 has already attributed large, unexploited inefficiencies inside the CPU
draw path, and none has been harvested:

- `drawTextRuns` constructs **four `CTFont` objects on every call** (`9/H3`).
- There is **no glyph cache**; `CTFontGetGlyphsForCharacters` is 11% of draw
  (`9/F3`).
- Unreserved array growth in `drawTextRuns` is 14% of draw (`9`, open item).

Those are roughly a quarter to a third of draw by doc 9's own attribution, in
work that is constant across draws and therefore cacheable. If harvesting them
brings a full-frame draw at real geometry under the budget, the architecture is
adequate and no rewrite is warranted.

Supporting evidence: the numbers above are doc 9's, measured, and untouched.

Competing explanation: per-cell CoreText glyph rasterization has a floor that no
amount of caching removes, and the fixed costs above are merely the visible part.

Confirmed if doc 9's draw-side backlog lands and F1's full-frame figure falls
below roughly 16 ms extrapolated to 179x66.

### H3 -- the gap is architectural, and compositing has to move to the GPU

libghostty composites a GPU-rendered `IOSurfaceLayer`
(`app/TerminalView.swift`, the `ghostty_surface_*` path). DanTerm's Swift backend
rasterizes glyphs on the CPU per frame. If H2's harvest is insufficient, this is
the remaining explanation and the remaining fix.

Deliberately **not** scheduled first. It is by far the largest change available
and it would be justified by an argument this file has not yet made -- and doc
10's whole arc is a warning about acting on an attribution before the cheap
experiment that could refute it. `10/F8` corrected `10/F4`'s attribution;
`10/F9` corrected `10/F5`'s conclusion. Both corrections cost minutes.

## Candidate direction, pending evidence

**Provisional, and deliberately unambitious: do doc 9's existing work before
opening anything new here.**

1. **Harvest `9/H3` and the unreserved array growth.** Per-draw `CTFont`
   construction and a glyph cache are already attributed, already sized at
   roughly a quarter of draw between them, and belong to a file that is already
   open. Nothing in this file should start before they land.
2. **Re-measure the backend A/B.** One run of
   `scripts/terminal-benchmark.sh content-churn swift|ghostty` replaces a
   remembered "2x" with a current number, and it costs minutes.
3. **Re-run F1 and decide.** Under budget at real geometry closes this file in
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
- [ ] **Re-measure the 2x claim.** It comes from the observation that opened doc
  10 and has not been reproduced since; three feed optimizations have landed in
  the meantime. Run `scripts/terminal-benchmark.sh content-churn swift` against
  `... content-churn ghostty` and compare total process CPU. Until this exists,
  "2x" is a remembered figure, not a current measurement.
- [ ] Confirm the real geometry figure rather than extrapolating: add 179x66 to
  `DrawBenchmarkGrid.standard`, or record why the two standard grids suffice.
- [ ] Establish how often a full-frame draw actually happens in
  `content-churn` and `style-churn`. H1's competing explanation turns on this
  and nothing currently measures it.

### Phase 2 -- direction gate

- [ ] **Gate: harvest doc 9's draw-side backlog before deciding anything here.**
  `9/H3` (per-draw `CTFont` construction, no glyph cache) plus the unreserved
  array growth are cheap, already-attributed, and worth roughly a quarter of
  draw. Deciding H2 versus H3 before they land would be deciding on an
  implementation nobody has tried to make fast.

### Phase 3 -- decide

- [ ] Re-run F1 after the harvest. Under budget at real geometry closes this file
  in H2's favor; still over it promotes H3 to a design question and hands it to a
  design doc rather than a research one.

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
- Next action: the two unchecked Phase 1 items, then the Phase 2 gate.

## Open questions and caveats

- **The 2x figure is not currently measured.** It is inherited from the
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
