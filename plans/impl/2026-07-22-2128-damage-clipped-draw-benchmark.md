# Draw only damaged rows, with a btop-shaped draw micro benchmark

## Context

Sampling an optimized Swift-backend build while holding an arrow key in btop
shows ~62% of main-thread time in `SwiftTerminalSessionView.draw(_:)` and ~18%
of the whole capture in `CTLineCreateWithAttributedString`. The session layer
already computes per-row damage and invalidates per-row rects, but `draw(_:)`
discards that and executes the full `RenderFramePlan` every time, so every
small update pays full-screen CoreText cost. Live inspection later established
that btop itself can damage nearly the whole grid during its refresh loop, so
the deterministic clipped scenario, rather than btop arrow input, isolates the
optimization's benefit.

This plan delivers the first (cheapest, stateless) fix from the rendering
investigation -- honor damage at draw time -- plus a deterministic micro
benchmark that reproduces the dense-styled-grid CoreText load so the fix and
future CoreText work can be baselined and measured without automating btop.

## Decision

1. **Damage-clipped drawing.** `draw(_:)` derives the row range intersecting
   `dirtyRect` from the frame metrics and draws only those rows, reusing the
   existing production `clipFramePlan(_:to:)`
   (lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift)
   and `TerminalDamage(rows:)`. Rows come from `dirtyRect`, never from a stored
   damage set: AppKit may widen or union invalidated rects, and everything
   inside `dirtyRect` must be repainted. The row-range-from-rect computation is
   a pure function in the render-execution library so it is unit-testable
   without AppKit.
2. **Production-path acceptance benchmark.** Add an optimized real-app workload
   that repeatedly updates 1-4 fixed rows without scrolling or full-screen
   repaint commands. Ensure updates become separate published frames and draws
   rather than one coalesced final frame. The benchmark records cumulative
   synchronous time inside the real `SwiftTerminalSessionView.draw(_:)`, draw
   count, and the grid rows represented by every delivered `dirtyRect`;
   end-to-end elapsed time remains a secondary diagnostic. Calibrate an excluded
   warm-up, then collect 15 duration-stable batches with at least 400 ms of
   measured draw work per batch. Record the baseline while production still
   performs a full-frame draw for every dirty rect.
3. **Backing-store format is a separate experiment.** Do not bundle
   `contentsFormat` or `NSViewUsesAutomaticLayerBackingStores` changes with row
   clipping. Test a per-view backing-store change only if the production-path
   benchmark shows that AppKit expands localized invalidations, and accept that
   change only after its own A/B benchmark demonstrates a benefit.
4. **Micro benchmark.** New standalone executable + testable support library in
   lib/TerminalCore, mirroring the existing
   `TerminalCoreBenchmark`/`TerminalCoreBenchmarkSupport` split and reusing its
   duration-stable timing policy. The workload is a self-contained
   deterministic Swift generator of btop-like ANSI bytes (box drawing, braille,
   per-cell color changes that fragment text runs, bold toggles) fed through a
   real `Terminal` + `planFrame`, never a hand-built plan. Scenarios, each at
   two grids (80x24 for corpus parity, and a large realistic grid approximating
   a full-screen btop window):
   - full-frame draw (current behavior; the target for future CoreText work),
   - damage-clipped draw of a few rows, including the clip-filter cost
     (post-change per-keystroke cost).
     Each scenario calibrates an excluded warm-up batch, then records 15 fixed-
     size batches that each run for at least 400 ms. Per-draw normalization
     keeps fast cases measurable, while the 15 batch values provide enough
     spread to distinguish modest local changes. Compare the median first and
     use the range to diagnose noisy runs. Output is raw JSON to stdout via a
     new `just benchmark-draw` recipe; this plan records its before/after
     medians and ranges rather than adding premature benchmark-history schema.

## Invariants

- I1: A damage-clipped draw is pixel-identical to a full-frame draw of the same
  plan over the damaged region; no pixel outside `dirtyRect` is altered, and no
  pixel inside `dirtyRect` is left stale.
- I2: When the dirty region spans the full grid (resize, metrics change,
  `isFull` damage, or worst-case full-bounds dirty rects), drawing degrades to
  exactly today's full-frame behavior -- correctness never depends on partial
  dirty rects arriving.
- I3: Row selection from a rect includes every row the rect partially overlaps
  and no row it merely abuts (a rect edge landing exactly on a cell boundary
  does not pull in the adjacent row).
- I4: The benchmark workload generator is deterministic, and its generated plan
  actually exercises per-cell CoreText pressure (styled text runs fragment at
  cell granularity across the grid) -- otherwise the benchmark measures the
  wrong thing.
- I5: The `DANTERM_TERMINAL_BENCHMARK` app harness's final-draw accounting
  still observes one completed draw per published frame after the change.
- I6: The acceptance workload proves that localized updates reach separate real
  AppKit draws and reports cumulative time spent synchronously executing those
  draws; parser/feed time cannot conceal a draw-path regression or improvement.

## Proof obligations

- PO1 (I1, I2): Extend the executor contract tests: damage rows derived from a
  synthesized dirty rect (unioned per-row rects as `publish` emits them),
  rendered via the clipped path, is byte-identical to a fresh full-frame
  bitmap. Full-span rect variant proves the degraded case. Builds on the
  existing `damageRedrawMatchesFullFrame` recipe in
  lib/TerminalCore/Tests/TerminalRenderExecutionTests/.
- PO2 (I3): Unit tests for the row-range helper at exact cell-edge boundaries,
  partial overlap, out-of-grid rects, empty rects, and full-grid rects, at
  displayScale 2 (non-integral point-space cell heights).
- PO3 (I4): Support-library tests: generator emits identical bytes across
  calls; the resulting plan's text-run count exceeds a density threshold at
  both grid sizes; both scenarios execute against a real offscreen surface.
- PO4 (I2 empirically): Manual verification step -- temporary dirtyRect logging
  and live frame inspection in a dev build distinguish the terminal's requested
  row damage from AppKit's delivered dirty rect; logging is removed before
  commit.
- PO5 (I5): Covered by running the app benchmark (`just benchmark-one
workload=styled-screen-redraw backend=swift`) after the change -- the harness
  fails to produce a final-draw result if draw accounting breaks.
- PO6 (I6): Benchmark harness contract tests pin the localized workload's ANSI
  shape, its frame/draw separation, and the reported draw-count, dirty-row, and
  cumulative-draw-time fields. A baseline run on the unchanged full-frame
  production draw path must complete before row clipping is reapplied.

## Verification

1. Before the view change: run `just benchmark-draw` with its default 15
   duration-stable batches and record each scenario's median and range. Add and
   run the production-path localized-update benchmark against the unchanged
   full-frame `draw(_:)`; its cumulative synchronous draw-time median and batch
   range are the acceptance baseline. Also record `just benchmark-one
workload=styled-screen-redraw backend=swift` and `just benchmark-one
workload=incremental-screen-updates backend=swift` as regression controls. Do
   not save redundant JSONL history for unchanged code.
2. Apply dirty-rect row clipping alone and rerun the localized-update acceptance
   benchmark. Accept the patch only if cumulative draw time improves materially
   outside the baseline batch ranges, full-frame draw performance does not
   regress, and the pixel-equivalence tests pass. Use end-to-end elapsed time
   and the existing app workloads as secondary diagnostics, not as substitutes
   for the direct draw measurement.
3. If localized invalidations arrive expanded, A/B test the per-view
   backing-store format separately and retain it only if the same acceptance
   benchmark demonstrates an additional improvement.
4. `just test` (repository gate) and `just test-ui` (AppKit harness) green.

## Non-goals

- No CoreText path changes (per-run `CTFontDrawGlyphs`, CTLine batching) --
  that is the separate next optimization this benchmark will also serve.
- No caching or cross-frame memoization anywhere.
- No persistent history, compatibility schema, significance testing, or
  cross-machine comparison for the draw micro benchmark. It exists to make the
  local before/after decision for this plan.
- No acceptance of a production performance change based only on modeled
  full-vs-clipped microbenchmark scenarios; the real AppKit draw path is the
  required gate.
- No reuse of the python-side `styled-screen-redraw` fixture bytes in the Swift
  executable; the workload is a Swift generator (fidelity is validated against
  real btop samples in verification instead).

## Accepted risks

- AR1: `dirtyRect` may arrive full-bounds on some macOS versions or an
  application may itself damage most rows. Consequence is status quo
  performance, never corruption (I2); the acceptance benchmark reports the
  delivered dirty rows so this cannot be mistaken for a clipping win.
- AR2: The clip-filter now runs per draw on the hot path (O(runs) set filter).
  The damage-clipped benchmark scenario times it; a full-span fast path keeps
  full redraws at today's cost.
- AR3: A generated workload is a proxy for real btop output; if micro numbers
  diverge from real-btop samples, revisit the workload rather than trusting it.

## Implementation discretion

- Names, module placement of the row-range helper, benchmark target names, the
  large-grid dimensions, and the damaged-row count in the clipped scenario.
- The localized-update workload's exact fixed rows and update cadence, provided
  the harness proves separate real draws and accumulates at least 400 ms of draw
  work per measured batch.

## Critical files

- app/SwiftTerminalSessionView.swift -- production draw path and benchmark
  instrumentation.
- app/TerminalBenchmark.swift -- production-path timing and delivered-dirty-row
  reporting.
- lib/TerminalCore/Sources/TerminalRenderExecution/ -- row-range helper.
- lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift --
  reused `clipFramePlan` (no changes expected).
- lib/TerminalCore/Package.swift -- new benchmark executable + support +
  test targets.
- lib/TerminalCore/Tests/TerminalRenderExecutionTests/ -- PO1/PO2; offscreen
  surface recipe to port for the benchmark (BitmapTestSupport.swift).
- justfile -- `benchmark-draw` recipe.

## Commit progress

- [x] 1. Add a btop-shaped draw micro benchmark (executable + support library +
      tests + `just benchmark-draw`), then record the full baseline set on
      unmodified draw code: `just benchmark-draw`, `just benchmark-one
workload=styled-screen-redraw backend=swift`, `just benchmark-one
workload=incremental-screen-updates backend=swift`, and core microbench
      records via `just benchmark-core` for the same workloads.
- [x] 2. Add the production-path localized-update acceptance benchmark,
      including harness contract tests and cumulative draw-time, draw-count, and
      delivered dirty-row reporting; refine the draw microbenchmark to 15
      duration-stable 400 ms batches, then record both baselines while the real
      view still performs full-frame drawing.
- [ ] 3. Apply dirty-rect row clipping without a backing-store change, prove it
      with pixel-equivalence tests, and retain it only if the localized-update
      acceptance benchmark improves materially outside the baseline ranges
      without regressing full-frame drawing.
- [ ] 4. Only if benchmark evidence shows AppKit expands localized dirty rects,
      A/B test a per-view backing-store format change as a separate commit and
      retain it only if it adds a measured acceptance-benchmark improvement.

## Implementation notes

- Pre-change baseline on 2026-07-22, Apple M1 Pro, macOS 26.5.2, display scale
  2, Swift 6.3.3. The original five-sample draw run was superseded by the
  agreed 15-batch methodology before production drawing changed:
  - Draw micro benchmark, median (range): 80x24 full-frame 53.82 ms
    (52.23-54.61 ms), four-row damage-clipped 9.03 ms (8.63-9.12 ms); 160x50
    full-frame 223.83 ms (215.83-226.21 ms), four-row damage-clipped 18.07 ms
    (17.41-18.39 ms).
  - Optimized app `styled-screen-redraw`: producer-write median 810.31 ms,
    final-draw median 823.98 ms.
  - Optimized app `incremental-screen-updates`: producer-write median 1,050.85
    ms, final-draw median 1,062.41 ms.
  - Core `styled-screen-redraw`: feed median 835.90 ms.
- Core `incremental-screen-updates`: feed median 1,009.76 ms.
- Live btop inspection on the optimized Swift backend found one representative
  refresh marked `isFull = false` but carrying 41 damaged rows in a 43-row
  grid. This explains why btop commonly delivered an effectively full-height
  dirty rect and prevents treating that workload as the isolated small-damage
  proof.
- Production-path localized-update baseline on unchanged full-frame drawing:
  an excluded warm-up calibrated 27 fixed-row updates per batch; all 15 batches
  delivered exactly 27 separate draws and every `dirtyRect` represented exactly
  one grid row. Cumulative synchronous draw time had a 489.49 ms median
  (481.62-500.95 ms), or 18.13 ms per draw (17.84-18.55 ms across batch means).
  Each batch exceeded the 400 ms direct-draw-work floor; end-to-end time was
  recorded only as a secondary diagnostic.
