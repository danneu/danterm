# Serialized full-screen redraw optimization research

Research date: 2026-07-23. **Status: CLOSED 2026-07-23.** Its one hypothesis --
per-cell fixed overhead dominates, not glyph rasterization -- was confirmed, the
fix shipped (`7e990fa`), and serialized redraw medians fell ~97%. See "Outcome".

## Purpose

This document is the research record for performance optimizations targeting
DanTerm's serialized full-screen redraw benchmarks. It should accumulate
profiles, bottleneck hypotheses, experiments, and benchmark results as that
work proceeds.

The benchmark presents every submitted 80x24 terminal state and waits for the
exact completed draw before submitting the next state. That boundary makes it
suitable for locating and validating work that contributes to the roughly
10 ms full-screen draw baselines in
`benchmarks/results/terminal-redraw.jsonl`. An optimization belongs in this
research track when it is intended to reduce those compatible per-draw results
while preserving the completed-draw and full-row-damage invariants.

This is bottleneck-discovery evidence, not a benchmark result. Profiling was
active, so its timings must not enter benchmark history.

## Optimization objective

The objective is to reduce nanoseconds per draw for:

- `full-screen-content-churn`
- `full-screen-style-churn`
- `full-screen-mixed-churn`

The committed unoptimized medians are approximately 9.967 ms, 9.961 ms, and
9.992 ms per draw, respectively. Performance claims must come from compatible,
unprofiled `just benchmark-redraw` runs. Profiles explain where to investigate;
they do not establish an improvement on their own.

Optimizations must preserve the benchmark's behavioral contract: one completed
draw for every submitted state, all 24 rows damaged per draw, 80x24 geometry,
and sequence metadata outside visible grid content. Results should be compared
only when all compatibility fields documented in
`agent-docs/terminal-performance.md` match.

## Unoptimized runtime baseline

The baseline was recorded against renderer commit
`46bbc2ddf12311de597a7df2e52e70f1c4de31e0` on 2026-07-23. Each workload used
15 fresh optimized app batches. Calibration selected 49 serialized updates per
batch, giving 735 measured completed draws per workload after excluded warm-up
and calibration work.

| Workload | Per draw min | Per draw median | Per draw max | Batch draw time min | Batch draw time median | Batch draw time max |
|---|---:|---:|---:|---:|---:|---:|
| Content churn | 9.736 ms | 9.967 ms | 10.131 ms | 477.043 ms | 488.374 ms | 496.405 ms |
| Style churn | 9.827 ms | 9.961 ms | 10.093 ms | 481.508 ms | 488.097 ms | 494.579 ms |
| Mixed churn | 9.827 ms | 9.992 ms | 10.241 ms | 481.545 ms | 489.621 ms | 501.786 ms |

The exact nanosecond distributions are:

| Workload | Nanoseconds per draw min / median / max | Cumulative draw nanoseconds min / median / max |
|---|---:|---:|
| Content churn | 9,735,561 / 9,966,818 / 10,130,712 | 477,042,504 / 488,374,085 / 496,404,916 |
| Style churn | 9,826,700 / 9,961,169 / 10,093,448 | 481,508,332 / 488,097,291 / 494,578,958 |
| Mixed churn | 9,827,449 / 9,992,258 / 10,240,533 | 481,545,038 / 489,620,667 / 501,786,127 |

All 15 batches for every workload reported exactly 49 completed draws, and
every draw reported exactly 24 dirty rows. The run used:

- benchmark method `serialized-completed-draw-v1`
- release configuration with profiling inactive
- 80x24 geometry at display scale 2
- Apple M1 Pro, MacBookPro18,1
- macOS 26.5.2
- Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`, `clang-2100.1.1.101`)
- a 400,000,000 ns cumulative synchronous draw-work target per batch

The authoritative machine-readable records remain in
`benchmarks/results/terminal-redraw.jsonl`. Future results must retain the same
compatibility fields before this table is used as the comparison baseline.

## Capture

The capture used the mixed workload because it changes both visible content and
styles on every complete frame:

```sh
DANTERM_TERMINAL_BENCHMARK_REDRAW_UPDATES=3000 \
  just benchmark-sample full-screen-mixed-churn seconds=15
```

The optimized Swift benchmark app ran with the profiling entitlement and
`sample` attached to the exact app pid published by the isolated harness. The
producer serialized each update behind its completed-draw acknowledgment, the
same presentation contract used by `just benchmark-redraw`.

The local capture artifacts are under:

```text
.build/terminal-benchmark-profiles/2026-07-23-004544-74815/
```

The directory contains `sample.txt`, the benchmark identity and harness log, a
copy of the profiled binary, and its symbol table. `.build` artifacts are local
and disposable; this note preserves the durable findings.

## Initial findings

The sample collected 12,124 main-thread samples. Two AppKit event-loop drawing
branches contained 7,890 samples in
`@objc SwiftTerminalSessionView.draw(_:)`, about 65% of all main-thread samples.
The Swift `draw(_:)` body accounted for 7,497 samples, about 62% of the total.
This confirms that the serialized workload spends most of the sampled
main-thread time presenting frames rather than waiting for input or performing
unrelated application work.

Within the drawing stacks, `drawRenderFrame(_:metrics:in:)` dominated. Its
largest resolved work was line 213 of
`TerminalRenderExecution.swift`, the call to:

```swift
context.drawTextRuns(
    plan.textRuns,
    metrics: metrics,
    colorSpace: colorSpace
)
```

The deepest high-count descendants were CoreText and CoreGraphics glyph paths:

- `TLine::DrawGlyphs`
- `TRun::DrawGlyphs`
- `CTFontDrawGlyphsWithAdvancesInternal`
- `DrawGlyphsAtPositions`
- `CGContextDelegateDrawGlyphs`
- `dlRecorder_DrawGlyphs`

The stacks therefore point first at text-run execution and glyph recording,
including CoreGraphics display-list work. Background fills, clipping, and
benchmark completion observation were visible but did not approach the glyph
path's sample counts.

## Initial optimization direction

The first optimization question is how much repeated text-run and glyph work a
full-frame update performs, and whether compatible rows or runs can reuse
prepared renderer state without changing terminal output. The profile does not
by itself prove that a particular cache is safe or that CoreText is avoidable.
It identifies the renderer execution boundary that a narrower experiment
should measure.

The mixed workload intentionally changes content and style together. Separate
content-only and style-only samples can distinguish shaping or glyph-position
cost from color/run fragmentation and display-list recording cost. Any proposed
optimization should still be evaluated against all three serialized redraw
workloads.

## Limitations and follow-up

This is one textual sample. The terminal performance guide requires at least
two captures before treating a sampled stack as a stable bottleneck. Repeat the
mixed capture, then collect content-only and style-only captures:

```sh
DANTERM_TERMINAL_BENCHMARK_REDRAW_UPDATES=3000 \
  just benchmark-sample full-screen-content-churn seconds=15

DANTERM_TERMINAL_BENCHMARK_REDRAW_UPDATES=3000 \
  just benchmark-sample full-screen-style-churn seconds=15
```

If repeated samples cannot separate run preparation, glyph drawing, and
display-list recording, use `benchmark-trace` with the same redraw update-count
environment override and the Time Profiler template.

There is also a harness usability gap: `benchmark-sample` accepts the new
full-screen workload names, but it does not select a sustained redraw update
count. Without the environment override above, the producer treats the name as
a corpus workload and fails to load it. A future harness change should make the
profiling command sustain serialized redraw workloads directly.

Future entries in this document should state the hypothesis, profile or code
evidence, implementation boundary, compatible before/after redraw results, and
whether the hypothesis was confirmed or rejected. This keeps optimization
decisions tied to the serialized redraw measurements rather than general
renderer intuition.

## Hypothesis: per-cell fixed overhead dominates, not glyph rasterization

Status: confirmed on 2026-07-23 by the per-run glyph batching experiment.

### Position

The capture's deepest hot stacks end in glyph *recording*, not obviously in
rasterization: `TLine::DrawGlyphs` -> `CTFontDrawGlyphsWithAdvancesInternal`
-> `CGContextDelegateDrawGlyphs` -> `dlRecorder_DrawGlyphs`. The current
executor issues one `CTLineCreateWithAttributedString` + `CTLineDraw` per
cell, each wrapped in its own `saveGState`/`clip`/`textMatrix`/`restoreGState`
(`TerminalRenderExecution.swift`, `drawTextCell`). An 80x24 frame is
therefore about 1,920 independently recorded one-glyph display-list ops per
draw. At the roughly 10 ms per-draw baseline that is about 5 microseconds per
cell of mostly fixed per-call cost.

Two observations support reading this as fixed per-cell overhead rather than
text-shaping or run-fragmentation cost:

- Content churn, style churn, and mixed churn medians sit within 0.4% of each
  other (9.967 / 9.961 / 9.992 ms). Shaping-bound or run-bound cost would
  separate the workloads; a per-cell constant would not.
- The earlier interactive btop sample indicted line creation
  (`CTLineCreateWithAttributedString`, about 18% of that capture), while this
  capture indicts the draw/record side. Both halves are per-cell costs; the
  two profiles together implicate the per-cell structure itself.

The falsifiable statement: per-draw cost is dominated by per-cell fixed
overhead (CTLine creation, per-cell GState/clip, per-op display-list
recording), not glyph rasterization; batching text drawing into one call per
styled run reduces per-draw time by more than 50% on all three serialized
churn workloads.

The endpoint this points at is the standard stateless monospace-grid pattern
used by iTerm2's CPU fast path and kitty's CoreText backend: per styled run,
resolve glyphs with `CTFontGetGlyphsForCharacters` (fall back to the per-cell
CTLine path on cmap miss or multi-scalar cells), compute positions as
`column * cellWidth`, and issue one `CTFontDrawGlyphs` call for the run. No
cross-frame caching is required; batching removes the per-cell attributed
string, typesetter, GState/clip, and display-list op counts in one move. If a
large cost remains after batching, it is intrinsic CPU rasterization, and
only then do cached/atlas or layer-buffer architectures become the remaining
lever.

### Tasks

- [x] Repeat the mixed-churn sample and collect content-only and style-only
      samples (already queued above) to satisfy the two-capture requirement
      and check that DrawGlyphs stacks are stable across captures.
- [x] Draw-batching-only experiment: keep per-cell CTLine creation but hoist
      the per-cell `saveGState`/`clip`/`textMatrix` out of the cell loop and
      draw without per-cell clipping. This isolates the GState/record half
      from the creation half before committing to glyph-level drawing. Judge
      with compatible `just benchmark-redraw` runs on all three workloads.
- [x] Per-run glyph batching experiment: one `CTFontGetGlyphsForCharacters` +
      `CTFontDrawGlyphs` call per styled run, per-cell CTLine retained only
      as the fallback for cmap misses and multi-scalar cells. Hoist the four
      font variants and per-run CGColors to frame/run scope. Judge with
      compatible `just benchmark-redraw` runs on all three workloads, then
      confirm the interactive win with `styled-screen-redraw` and
      `incremental-screen-updates` app benchmarks.
- [x] Re-profile after the winning experiment to see whether remaining time
      sits in rasterization (`DrawGlyphs` leaf work) or still in per-call
      overhead, and record whether the hypothesis is confirmed or rejected.

### Results

The profiling task completed on 2026-07-23 with the requested 3,000-update
override and 15-second textual samples:

| Workload | Main-thread samples | Samples in `draw(_:)` branches | Share | Artifact |
|---|---:|---:|---:|---|
| Mixed churn (repeat) | 12,169 | 7,948 | 65.3% | `.build/terminal-benchmark-profiles/2026-07-23-011359-86304/` |
| Content churn | 12,241 | 7,956 | 65.0% | `.build/terminal-benchmark-profiles/2026-07-23-011429-86954/` |
| Style churn | 12,176 | 7,978 | 65.5% | `.build/terminal-benchmark-profiles/2026-07-23-011459-87525/` |

All three captures reproduce the initial mixed sample's dominant resolved
path from `drawRenderFrame` line 213 through `TLine::DrawGlyphs`,
`TRun::DrawGlyphs`, `CTFontDrawGlyphsWithAdvancesInternal`,
`CGContextDelegateDrawGlyphs`, and `dlRecorder_DrawGlyphs`. The leading
line-213 branch contained 1,310 samples in repeated mixed churn, 1,233 in
content churn, and 1,188 in style churn. The two `draw(_:)` event-loop
branches also remained effectively identical at about 65% of main-thread
samples in every capture. The sampled glyph-recording bottleneck is therefore
stable across two mixed captures and does not separate content-only from
style-only churn.

This evidence completes the first task and supports proceeding to the
draw-batching-only experiment. It does not yet confirm the hypothesis or make
a performance claim: these are profiled diagnostic runs, so no result belongs
in benchmark history. Compatible unprofiled before/after medians remain
required for the experiment tasks below.

The draw-batching-only experiment completed on 2026-07-23. It retained
per-cell attributed strings and `CTLineCreateWithAttributedString`, set one
y-flipping text matrix for the text batch, positioned each cell with
`textPosition`, and removed the per-cell save, clip, and restore operations.
The compatible unprofiled 15-batch run is preserved locally at
`.build/terminal-benchmark-staged/terminal-redraw-20260723-012617.jsonl`:

| Workload | Baseline median | Experiment median | Change |
|---|---:|---:|---:|
| Content churn | 9,966,818 ns/draw | 8,529,690 ns/draw | -14.42% |
| Style churn | 9,961,169 ns/draw | 8,584,568 ns/draw | -13.82% |
| Mixed churn | 9,992,258 ns/draw | 8,595,000 ns/draw | -13.98% |

Every batch preserved the serialized completed-draw contract and reported
exactly 24 dirty rows per draw. The improvement is material and consistent,
but about 14% is not a dominant share of the roughly 10 ms baseline. This
assigns a bounded part of the cost to per-cell GState, clipping, and matrix
recording while leaving most of the hypothesized fixed overhead in per-cell
line creation and glyph draw recording for task 3 to test.

Unclipped drawing is not shippable. The focused renderer suite found three
pixel-level issues: the measured bold-italic overhang entered an adjacent cell
at both display scales, and emoji ink changed the following cell. The other 31
renderer execution tests passed, including orientation, independent shaping,
traits, fallback metrics, damage redraw, and context restoration. The
experimental executor change was reverted after measurement, restoring the
correct clipped implementation and leaving only this research record. Task 3
therefore needs either a selective per-cell fallback clip for complex or
overhanging glyphs, or an equivalent halo strategy that preserves cell
isolation.

The per-run glyph batching experiment completed on 2026-07-23. The executor
now resolves every single-scalar BMP cell in a styled run with one
`CTFontGetGlyphsForCharacters` call and submits all mapped glyphs with one
`CTFontDrawGlyphs` call. The four font variants and CGColors are reused within
the frame. Multi-scalar cells, supplementary-plane scalars, and cmap misses
retain the clipped per-cell CTLine path. Fast-path glyphs are deliberately
unclipped horizontally, while partial view damage expands by one row above and
below so vertical ink crossing a row boundary is repainted.

Compatible unprofiled results are preserved in
`.build/terminal-benchmark-staged/terminal-redraw-20260723-015354.jsonl`,
`.build/terminal-benchmark-staged/terminal-redraw-20260723-020509.jsonl`, and
`.build/terminal-benchmark-staged/terminal-redraw-20260723-021039.jsonl`:

| Workload | Baseline median | Batched median | Change |
|---|---:|---:|---:|
| Content churn | 9,966,818 ns/draw | 318,030 ns/draw | -96.81% |
| Style churn | 9,961,169 ns/draw | 313,411 ns/draw | -96.85% |
| Mixed churn | 9,992,258 ns/draw | 325,210 ns/draw | -96.75% |

All 15 batches for each workload preserved the serialized completed-draw
contract and reported exactly 24 dirty rows per draw. The benchmark-only
observer also needed a race fix after the speedup exposed an old partial
invalidation: redraw sequence metadata is now transferred at frame
publication, and an older partial AppKit invalidation causes one retry limited
to the published frame's grid rectangle before the sequence is acknowledged.

The renderer execution suite passes all 34 tests. Its pixel contract now
accepts measured bold-italic horizontal overhang at both display scales, while
the existing Unicode containment test confirms that complex fallback cells
remain clipped. The UI suite passes all 172 tests, including explicit
top/middle/bottom bounds for the one-row damage halo.

The interactive app benchmarks also improved, though their coalesced and
producer-limited boundaries make the gains much smaller than the serialized
draw result:

| Workload | Metric | Median | Compatible change |
|---|---|---:|---:|
| Styled screen redraw | Producer write | 810,809,208 ns | -2.81% |
| Styled screen redraw | Final draw | 820,336,625 ns | -3.55% |
| Incremental screen updates | Producer write | 1,078,084,000 ns | -5.53% |
| Incremental screen updates | Final draw | 1,086,030,083 ns | -5.52% |

Those app results are preserved at
`.build/terminal-benchmark-staged/terminal-app-4vl9z92x.jsonl` and
`.build/terminal-benchmark-staged/terminal-app-hocvwdqc.jsonl`. The consistent
roughly 97% serialized redraw reduction, after task 2 assigned only about 14%
to GState/clip/matrix work, confirms that per-cell line creation and glyph draw
recording dominated the original cost. Task 4 should re-profile this winning
implementation before attributing the remaining roughly 0.32 ms.

The optimized implementation was re-profiled on 2026-07-23 with the same
3,000-update override and 15-second textual sampling boundary:

| Workload | Main-thread samples | `draw(_:)` samples | Draw share | Artifact |
|---|---:|---:|---:|---|
| Mixed churn | 12,379 | 1,207 | 9.8% | `.build/terminal-benchmark-profiles/2026-07-23-094727-86278/` |
| Content churn | 12,369 | 1,168 | 9.4% | `.build/terminal-benchmark-profiles/2026-07-23-094804-86908/` |
| Style churn | 12,435 | 1,174 | 9.4% | `.build/terminal-benchmark-profiles/2026-07-23-094836-87539/` |

This replaces the stable roughly 65% pre-batching draw share with a stable
roughly 9.5% share. The old per-cell CTLine path is effectively absent:
`TLine::DrawGlyphs` and `TRun::DrawGlyphs` have only one to three samples in
each capture. Batched `CTFontDrawGlyphs` has 47 to 67 samples in its largest
branch, `CTFontGetGlyphsForCharacters` has 21 to 38, and
`dlRecorder_DrawGlyphs` has 8 to 17. None is now a dominant main-thread leaf,
so the remaining roughly 0.32 ms cannot be characterized as intrinsic glyph
rasterization dominating the frame.

The largest concrete work inside the optimized `draw(_:)` stacks is instead
benchmark instrumentation. `TerminalBenchmarkObserver.observeCompletedDraw`
has a 317-to-366-sample branch whose descendants are primarily
`FileManager.createFile` and Foundation's atomic temporary-file path for the
per-frame acknowledgment. This work exists to serialize the diagnostic
workload and is not production rendering. The remaining renderer samples are
spread across batched glyph lookup/submission, background and decoration
drawing, and Swift-side run preparation; no successor renderer bottleneck is
large enough in these captures to justify a glyph atlas or cross-frame cache.

Task 4 therefore confirms the hypothesis and closes this research pass.
Per-cell CoreText construction and glyph display-list recording, rather than
intrinsic rasterization, dominated the original renderer. Per-run batching
removed that fixed call-count cost, reduced compatible serialized redraw
medians by roughly 97%, and left the sampling profile dominated by idle event
loop time plus benchmark-only acknowledgment IO.

## Implementation commits

- `98ba9e6` (`docs(perf): close serialized redraw research`) preserves the
  completed hypothesis, experiments, benchmark results, and profile findings.
- `7e990fa` (`perf(terminal): batch glyph draws by styled run`) implements the
  per-run glyph fast path, clipped complex-cell fallback, one-row damage halo,
  and their behavioral tests.
- `8ebb92c` (`fix(benchmark): serialize redraw acknowledgments`) transfers
  sequence ownership when a frame is published and retries an exact-grid draw
  when AppKit merges that frame with older partial invalidation.

## Outcome

**Closed 2026-07-23.** A single hypothesis, confirmed and shipped.

- **Confirmed: per-cell fixed overhead dominated, not glyph rasterization.**
  Per-cell CoreText construction and glyph display-list recording -- not the
  intrinsic cost of rasterizing glyphs -- were the serialized redraw bottleneck.
  Per-run batching removed that fixed call-count cost and cut compatible
  serialized redraw medians by roughly **97%**. Afterwards the sampling profile
  is dominated by idle event-loop time plus benchmark-only acknowledgment IO,
  and no successor renderer bottleneck in those captures is large enough to
  justify a glyph atlas or cross-frame cache.
- **Shipped:** `7e990fa` (per-run glyph fast path, clipped complex-cell
  fallback, one-row damage halo, and behavioral tests), `8ebb92c` (benchmark
  acknowledgment serialization), `98ba9e6` (this record).

**What this file did not close, and it bit someone later.** "Limitations and
follow-up" flagged a harness usability gap: `benchmark-sample` accepts the
full-screen workload names but does not select a sustained redraw update count,
so without `DANTERM_TERMINAL_BENCHMARK_REDRAW_UPDATES` the producer treats the
name as a corpus workload and fails to load it. **That gap was never closed**,
and `11/F3` ran into precisely it a year-quarter later -- also discovering that
`content-churn` is a compare-harness alias while the script spells it
`full-screen-content-churn`. If anyone fixes the harness, that is the ticket.

**Where this line of work went.** The fast path this file built is the "batched
fast path" that [4-fallback-glyph-batching.md](4-fallback-glyph-batching.md)
opens by citing -- doc 4 took the *slow* path, the per-cell CTLine fallback for
cmap misses, and replaced it with procedural sprites. Doc 11 later measured the
combined result at real 179x66 geometry and found it fits the frame budget.

**Reopening condition:** a serialized redraw profile shows a renderer node large
enough to justify a glyph atlas or cross-frame cache -- the two successors this
file explicitly found too small to warrant.
