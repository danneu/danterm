# Draw only damaged rows, with a btop-shaped draw micro benchmark

## Context

Sampling an optimized Swift-backend build while holding an arrow key in btop
shows ~62% of main-thread time in `SwiftTerminalSessionView.draw(_:)` and ~18%
of the whole capture in `CTLineCreateWithAttributedString`. The session layer
already computes per-row damage and invalidates per-row rects, but `draw(_:)`
discards that and executes the full `RenderFramePlan` every time, so every
keystroke pays full-screen CoreText cost. btop's arrow-key case damages only a
few rows per frame.

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
2. **Backing-store format opt-out.** The view opts out of AppKit's automatic
   layer backing-store format (per-view `contentsFormat`), which on modern
   macOS otherwise delivers full-bounds dirty rects and would neuter the win.
   Verified empirically (temporary dirtyRect logging during a btop run) before
   the change is considered landed; the app-wide
   `NSViewUsesAutomaticLayerBackingStores` default is the fallback if the
   per-view knob proves insufficient.
3. **Micro benchmark.** New standalone executable + testable support library in
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
     Output is JSON to stdout via a new `just benchmark-draw` recipe. Not wired
     into `terminal-app.jsonl` committed history for now.

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
  in a dev build during a btop arrow-hold run confirms row-granular rects
  arrive after the contentsFormat change; logging removed before commit.
- PO5 (I5): Covered by running the app benchmark (`just benchmark-one
workload=styled-screen-redraw backend=swift`) after the change -- the harness
  fails to produce a final-draw result if draw accounting breaks.

## Verification

1. Before the view change: record baselines -- `just benchmark-one
workload=styled-screen-redraw backend=swift`, `just benchmark-one
workload=incremental-screen-updates backend=swift`, and the new
   `just benchmark-draw` JSON.
2. After: rerun all three plus a manual btop arrow-hold `sample` of the
   optimized dev build; expect `CTLineCreateWithAttributedString` share to
   collapse in the incremental case and the damage-clipped micro scenario to
   beat the full-frame scenario roughly in proportion to rows drawn.
3. `just test` (repository gate) and `just test-ui` (AppKit harness) green.

## Non-goals

- No CoreText path changes (per-run `CTFontDrawGlyphs`, CTLine batching) --
  that is the separate next optimization this benchmark will also serve.
- No caching or cross-frame memoization anywhere.
- No suite/schema integration of the micro benchmark into
  `terminal-app.jsonl`; revisit once the draw path stabilizes.
- No reuse of the python-side `styled-screen-redraw` fixture bytes in the Swift
  executable; the workload is a Swift generator (fidelity is validated against
  real btop samples in verification instead).

## Accepted risks

- AR1: `dirtyRect` may still arrive full-bounds despite the contentsFormat
  opt-out on some macOS versions. Consequence is status quo performance, never
  corruption (I2); the fallback default is the documented escape hatch.
- AR2: The clip-filter now runs per draw on the hot path (O(runs) set filter).
  The damage-clipped benchmark scenario times it; a full-span fast path keeps
  full redraws at today's cost.
- AR3: A generated workload is a proxy for real btop output; if micro numbers
  diverge from real-btop samples, revisit the workload rather than trusting it.

## Implementation discretion

- Names, module placement of the row-range helper, benchmark target names, the
  large-grid dimensions, and the damaged-row count in the clipped scenario.
- Where `contentsFormat` is applied (init vs the existing geometry
  synchronization path) so long as layer recreation is covered.

## Critical files

- app/SwiftTerminalSessionView.swift -- draw path, contentsFormat.
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
- [ ] 2. Draw only the rows intersecting `dirtyRect`, with the layer
      backing-store format opt-out, then rerun every benchmark from slice 1 plus a
      btop arrow-hold `sample` and compare against the recorded baselines.

## Implementation notes

- Pre-change baseline on 2026-07-22, Apple M1 Pro, macOS 26.5.2, display scale
  2, Swift 6.3.3:
  - Draw micro benchmark, five duration-stable samples per case: 80x24
    full-frame 50.65-53.40 ms and four-row damage-clipped 9.07-9.21 ms; 160x50
    full-frame 214.00-227.40 ms and four-row damage-clipped 18.30-26.65 ms.
  - Optimized app `styled-screen-redraw`: producer-write median 810.31 ms,
    final-draw median 823.98 ms.
  - Optimized app `incremental-screen-updates`: producer-write median 1,050.85
    ms, final-draw median 1,062.41 ms.
  - Core `styled-screen-redraw`: feed median 835.90 ms.
  - Core `incremental-screen-updates`: feed median 1,009.76 ms.
