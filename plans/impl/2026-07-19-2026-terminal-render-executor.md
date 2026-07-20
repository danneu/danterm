# Milestone 4 slice 2: minimal AppKit CoreText/CoreGraphics executor

Milestone 4 (the interactive viability slice, plan-terminal-engine/14-roadmap.md:117-130)
lands in four slices (plans/impl/2026-07-19-1837-deterministic-render-planning.md:8-12):
(1) pure render planning -- shipped, (2) minimal AppKit CoreText/CoreGraphics
executor, (3) session adapter over the backend seam, (4) viability harness and
gate closure. This plan covers slice 2 only.

## Problem

Slice 1 produces complete, canonical, deterministic `RenderFramePlan` values in
grid-cell coordinates with concrete sRGB colors, but nothing turns a plan into
pixels. Doc 09 assigns exactly that to execution: CoreText/CoreGraphics resolve
and execute the system-specific glyph and drawing operations, with 13 pt
regular-weight monospaced system font, ligatures disabled, line height derived
from font metrics, and Retina-correct geometry (plan-terminal-engine/09-renderer.md:15-31).
Without an executor, slice 3 has nothing to put in a view, and doc 09's proof
obligation that "focused AppKit snapshots prove glyph placement and
display-scale behavior" (09-renderer.md:49-51) stays open. The executor must
preserve the property the plan was designed around: the terminal grid is
decided before drawing begins, so font fallback, face changes, and display
scale can change ink but never geometry.

Load-bearing evidence (verified):

- `lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift:106-116`:
  the planner overrides the cursor-spanned cells' resolved colors (background
  := theme cursor, foreground := theme cursor-text) before run coalescing, so
  the background/text/decoration runs already contain the finished frame
  including the cursor block. With the baked dark theme (cursor 229/229/229 vs
  default background 0/0/0, `TerminalRenderPlanning.swift:44-67`) the block
  always surfaces as a background run. Slice 1 RI6 already rejected
  executor-side cursor overlays. There is no fourth drawing pass; `plan.cursor`
  is informational this slice.
- `lib/TerminalCore/Sources/TerminalRenderPlanning/TerminalRenderPlanning.swift`:
  every plan struct's memberwise init is internal; only `RenderColor` (:18),
  `RenderPresentation` (:94), and `RenderTheme.dark` (:44) are publicly
  constructible. `planFrame` (`RenderFramePlanner.swift:7-12`) is the only
  public plan source, protecting the canonical-form invariant.
- `lib/TerminalCore/Tests/TerminalRenderPlanningTests/RenderFramePlanningTests.swift`:
  the established fixture idiom -- `Terminal(columns:rows:)`, `feed` with escape
  sequences, `planFrame(for:presentation:)` -- uses only public API. Executor
  tests can obtain every needed plan this way.
- `justfile:32` runs `swift test --package-path lib/TerminalCore` unfiltered,
  so new library + test targets in that package join the gate with zero
  justfile changes. `justfile:36-39` scopes the purity lints to
  `Sources/TerminalCore` and `Sources/TerminalRenderPlanning` only, and
  `scripts/terminal-backend-boundary-lint.sh` polices `app/` only, so an
  AppKit-importing sibling target is not lint-blocked.
- `lib/TerminalCore/Package.swift`: the same-package multi-target precedent
  (`TerminalCoreRecording`, `TerminalRenderPlanning`), Swift 6 language mode,
  macOS 26.
- plan-terminal-engine/09-renderer.md:36-37 "Font fallback changes glyph choice
  without changing grid geometry"; :52-53 Spanish/Chinese/emoji/fallback render
  without neighboring-cell corruption; :73-76 glyph caching, batching, and
  drawing primitives are implementation discretion.
- plan-terminal-engine/12-testing-conformance.md:94-95 renderer tests
  distinguish semantic grid failures from pixel-placement failures; :111-112
  pixel snapshots vary with system fonts and stay narrowly scoped to claims
  logical snapshots cannot prove.
- plan-terminal-engine/13-power-performance.md:11-13,35-37: event-driven, no
  permanent display link; correctness over throughput for this renderer.
- docs/design/2026-03-05-display-scaling.md: backing-pixel size and content
  scale are one invariant; zero-frame guards return nil for non-positive
  dimensions.
- `.github/workflows/ci.yml`: CI builds the app only and never runs
  `just test`; the gate runs on the developer's Mac.

## Decision

Build the executor as a new library target in the `lib/TerminalCore` package
(working name `TerminalRenderExecution`), depending on `TerminalRenderPlanning`,
importing AppKit/CoreText/CoreGraphics, with a matching Swift Testing test
target. User-confirmed choices: same-package target (not a new package),
executor-only (no NSView this slice), glyph ink clipped to its cell rect, and
programmatic pixel-probe tests (no golden images).

### Placement: same-package target, not a new package

Slice 1 RI3 rejected a separate package because "a package boundary buys
nothing until an executor exists." The executor's AppKit dependency does not
change that calculus: the purity boundary is directory + lint scoped
(justfile:36-39), so an AppKit sibling target cannot contaminate the planner --
the planner's import allowlist still mechanically excludes it. The same-package
target matches the existing multi-target precedent and joins the `just test`
gate with zero wiring. No lint changes.

### Executor shape: metrics value + pure draw over a caller-provided context

Two public surfaces (exact names and signatures discretion):

- A metrics value constructed from an explicit display scale, with the 13 pt
  regular-weight monospaced system font baked inside. It exposes the quantized
  cell size, baseline offset, and decoration geometry, and returns nil outside
  the accepted scale domain below (the display-scaling ADR's zero-guard shape).
- A frame-drawing operation taking (plan, metrics, CGContext) that draws the
  complete frame. The contract pins the coordinate convention: the context is
  in point space with row 0 at the top edge and a CTM mapping points to backing
  pixels at the metrics' scale -- exactly what AppKit hands a flipped view's
  `draw(_:)` and exactly what a test builds with a scaled CGBitmapContext. A
  size-derivation helper maps (plan grid, metrics) to the frame's point/pixel
  size; that is slice 3's view-sizing seam.

In a top-left convention the y axis points down, while CoreText composes its
text matrix with the CTM, so the executor explicitly compensates: glyphs render
upright with ascenders above the baseline and row 0 above row 1. Omitting or
inverting that compensation is a wrong visible frame that ink-presence and
containment probes alone accept, so PO11 pins orientation directly.

Drawing is a postcondition-preserving borrow of the caller's context: the CTM,
clip, and text matrix are the caller's again when it returns. Per-cell clipping
already forces save/restore internally (without it the second cell inherits the
first cell's clip), and `CGContextSaveGState` does not cover the text matrix,
which `CTLineDraw` mutates -- so the text matrix is captured and restored
explicitly. This keeps slice 3's view free to draw after the frame.

No NSView ships this slice. A view adds nothing provable in the headless gate,
and its real obligations -- backing-scale change notifications, visibility,
teardown per 09-renderer.md:42-43 and the AppKit lifetime ADR -- arrive with
slice 3's session seam. The executor never reads `NSScreen` or any ambient
state; scale is always an explicit input.

### Grid-to-pixel metrics and Retina scaling

- Cell width derives from the regular face's monospaced glyph advance; cell
  height from ascent + descent + leading. Both are quantized to whole device
  pixels at the given scale, rounding up so the nominal advance always fits
  inside the cell (glyphs are clipped to cells, below). Quantized values are
  exposed in points as exact multiples of 1/scale.
- Cell (row, column) maps to origin (column x cellWidth, row x cellHeight).
  All run rects are products of the quantized values, so every cell edge lies
  on a device-pixel boundary. That -- not any property of SF Mono's fractional
  13 pt advance -- is why adjacent background runs tile with no seams or cracks
  at 1x and 2x.
- Wide cells span exactly 2 x cellWidth. Metrics come from the regular base
  face only; bold/italic faces and every fallback font reuse them unchanged
  (09-renderer.md:36-37 discharged at the executor).
- Per-scale quantization is independent: the invariant is pixel integrality
  and identical grid mapping at each scale, not cross-scale proportionality.
  The accepted domain is finite positive scales whose derived cell dimensions
  are themselves finite and representable as whole pixel counts; the
  size-derivation helper additionally refuses grids whose pixel extent would
  overflow. Zero, negative, NaN, infinite, and overflowing inputs refuse with
  nil -- a bare positivity guard admits infinity, and converting a non-finite
  or out-of-range derived size to an integer pixel count traps.
- Colors resolve in one fixed color space (sRGB) end to end, so solid fills
  round-trip to exact bytes and probe tests can use exact equality.

### Text drawing: per-cell shaping so fallback cannot move neighbors

Each text-run cell is shaped and drawn independently at its grid-computed
origin: the cell's exact scalar sequence becomes one attributed string with the
selected face and ligatures disabled, shaped as one CoreText line, drawn at
(cell origin, baseline). Positioning never accumulates advances across cells,
so a fallback glyph with a different advance (CJK, emoji, symbols) structurally
cannot shift any neighbor. Multi-scalar cells (combining marks, ZWJ emoji) are
shaped as one cluster by CoreText -- no manual glyph mapping.

Bold and italic faces derive from the base font by symbolic traits (regular,
bold, italic, bold-italic); an unavailable trait variant degrades to regular
without touching metrics.

Every text cell's ink is clipped to its cell-span rect (columnWidth x
cellWidth wide, one row tall). "No neighboring-cell corruption"
(09-renderer.md:52-53) becomes structural rather than empirical, and it
pre-pays Milestone 6 damage correctness (unclipped overhang becomes smearing
residue under partial redraw). The trimming cost is AR3.

### Decorations

Drawn after text, spanning the whole run as continuous primitives:

- underlineSingle: one bar at the base font's underline position/thickness
  below the baseline, thickness snapped to at least one device pixel.
- underlineDouble: two parallel bars (gap discretion, probe-pinned once chosen).
- underlineCurly: a wave stroked at underline thickness; amplitude/period
  discretion. Wave phase anchors to grid x = 0, so a color change that splits
  one visual underline into two runs cannot reset the wave mid-word.
- strikethrough: one bar near mid-x-height (offset formula discretion,
  probe-pinned).

All decoration ink is clamped to the run's row band, so tight line heights
cannot bleed decorations into the next row.

### Drawing order and the cursor

Fixed order: fill the whole frame rect with `defaultBackground` (opaque) ->
background runs -> text runs -> decoration runs. There is no cursor pass: the
planner bakes cursor colors into the runs before coalescing (evidence above).
The executor does not read `plan.cursor` for drawing this slice; the field
remains for later slices (IME caret geometry, non-block shapes, focus
treatment). Tests still prove the cursor block by probing the cursor cell.

`RenderCursor`'s public documentation currently reads "Filled block to draw"
(`TerminalRenderPlanning.swift:121`), which invites exactly the double-draw
this decision rejects. That doc comment is corrected in this slice to say the
runs already contain the rendered block and the record carries geometry
metadata only.

### Test strategy: programmatic pixel probes, no golden images

Tests render planner-produced plans into headless CGBitmapContexts (sRGB,
CTM scaled per the metrics) and probe exactly the behavioral claims:

- Exact-color probes for solid geometry (clear, background runs, cursor block,
  decoration bars): byte equality at chosen device pixels, valid because fills
  are opaque sRGB rects on pixel boundaries.
- Ink probes for glyphs (rasterization is OS-owned): "ink" = pixels differing
  from the local background; assert presence inside the expected cell rect,
  absence outside it, and cross-frame byte-identity of unrelated cells.

Plans are obtained exclusively through the `Terminal` + `feed` + `planFrame`
idiom -- the internal plan inits stay internal, the planner remains the only
plan constructor (canonical form stays a theorem), and every executor test
doubles as planner-to-pixels integration evidence. The 12-testing-conformance
split holds: these tests assert placement and geometry only, never re-asserting
planner semantics.

### Concurrency

The executor is nonisolated value-and-function code: no globals, no shared
mutable state, no ambient reads; every input is a parameter. CoreText objects
are immutable and confined to the metrics value and per-call locals, so Swift 6
strict concurrency is clean without `@MainActor` or `@unchecked Sendable`.
`@MainActor` enters only with the slice-3 view.

## Invariants

- I1: Drawing is a pure consumer of (plan, metrics, context): no ambient reads
  (screen, scale, time, preferences), identical inputs produce byte-identical
  raster within a process, and the caller's CTM, clip, and text matrix are
  restored on return.
- I2: Grid geometry is content-independent: cell (r, c) maps to the same pixel
  rect regardless of glyph choice, fallback font, or bold/italic face; all
  metrics derive from the regular 13 pt base face plus the explicit scale.
- I3: At every supported scale, cell edges lie on device-pixel boundaries and
  adjacent run rects tile exactly -- no seams, gaps, or overlaps.
- I4: All ink is contained: text is clipped to its cell-span rect and
  decorations to their run's row band; no primitive can mark a neighboring
  cell or row.
- I5: Layer order is fixed (clear -> backgrounds -> text -> decorations); the
  executor draws runs only, and `plan.cursor` is not a drawing input this
  slice.
- I6: Ligatures are disabled and each cell's cluster is shaped independently;
  cross-cell ligatures are structurally impossible.
- I7: Scales outside the finite-positive domain with representable derived
  dimensions -- and degenerate target dimensions -- produce refusal (nil / no
  drawing), never a trap.
- I8: The executor API is warning-free under Swift 6 strict concurrency with no
  shared mutable state.
- I9: The full executor suite runs headless inside `just test` -- no
  WindowServer dependency, no NSView/NSWindow/NSApplication use in the target
  or its tests.

## Proof obligations

- PO1 (I2, I3): Metrics -- cell width/height are pixel-integral at 1x, 2x, and
  a representative fractional scale, cell height reflects ascent + descent +
  leading, wide span = exactly 2 x width, and metrics are identical when
  derived before and after rendering frames containing bold, italic, CJK, and
  emoji content.
- PO2 (I3, I5): Background geometry -- a frame with distinct erased regions
  probes exact run colors inside runs and `defaultBackground` outside; a
  scanline across two adjacent same-row runs contains only the two run colors
  (no clear-color crack), at 1x, 2x, and the fractional scale.
- PO3 (I2, I4, I6): Text placement -- a glyph fed to a known cell via cursor
  addressing has ink inside that cell rect and none elsewhere; repeated at 1x
  and 2x with the same grid mapping. Adjacent `f` and `i` cells are
  byte-identical to independently rendered controls carrying each glyph alone
  at the same grid positions, so no cross-cell ligature can form.
- PO4 (I2): Faces -- regular vs bold and regular vs italic frames differ in ink
  within the target cell while all other cells stay byte-identical.
- PO5 (I2, I4): Unicode and fallback -- Spanish text (accented vowels, enye),
  CJK, emoji, and a fallback scalar each place all ink within their own one- or
  two-column span; a trailing ASCII glyph's cell pixels are byte-identical
  between "wide or fallback glyph then X" and a control frame with X at the
  same column, proving fallback cannot shift neighbors. A combining-mark cell
  draws as one cluster in one cell. The fallback case first proves substitution
  actually happened and produced a usable glyph -- the scalar is absent from the
  base face, and the shaped line's run reports a different font that maps the
  scalar to a real glyph -- so a `.notdef` box cannot satisfy the containment
  and neighbor checks by accident.
- PO6 (I4, I5): Decorations -- each kind (single, double, curly, strikethrough)
  produces decoration-colored ink in its expected band; double shows two
  separated bars; curly shows varying y across x; a decorated space cell still
  shows decoration ink; decoration drawn over glyph ink proves order; all
  decoration ink stays within the run's row band.
- PO7 (I5): Cursor -- a visible-cursor plan renders the cursor cell in exact
  theme cursor color with cursor-text glyph ink, purely from runs; nothing in
  the executor consumes `plan.cursor`.
- PO8 (I1): Determinism and context hygiene -- rendering the same plan twice
  into fresh identically-configured bitmaps yields byte-identical buffers; CTM
  and text matrix are unchanged across a draw call; and clip restoration is
  proven behaviorally, not by bounding box: a context carrying a nonrectangular
  caller clip is drawn through, then the same sentinel is drawn through it and
  through an untouched control context holding the identical clip, and the two
  buffers must be byte-identical.
- PO9 (I7): Degenerate inputs -- zero, negative, NaN, infinite, and
  cell-size-overflowing scales refuse metrics construction (nil); with accepted
  metrics whose cell dimensions are individually representable but whose
  product with the minimum 2x1 grid overflows, size derivation returns nil and
  drawing performs no work; and size derivation and drawing never trap on any
  planner-reachable plan, including that minimum 2x1 grid (`Terminal.init`
  requires columns >= 2, `Terminal.swift:115`).
- PO10 (I9): Headless gate -- the suite runs green under `just test` with no
  WindowServer-dependent API, verified once in a non-GUI session (e.g. over
  ssh) before the slice closes.
- PO11 (I2, I4): Orientation -- in the top-left convention, a glyph whose ink
  sits high in the em box (an apostrophe) leaves ink only in its cell's upper
  band while a low glyph (an underscore) leaves ink only in the lower band, and
  a glyph in row 0 renders above the same glyph in row 1. Repeated at 1x and
  2x. Inverting the text matrix or the row axis fails this and only this
  obligation.

## Non-goals

- The NSView subclass, backing-change notifications, visibility handling, and
  the `TerminalBackend`/`AppDelegate` session seam (slice 3).
- Damage/partial redraw, selection, search/hyperlink presentation, scrollback
  presentation (Milestone 6).
- Cursor blinking, application-requested shapes, focus-dependent cursor
  treatment (deferred with slice 1).
- Glyph caching, batching, or any performance work beyond correctness
  (09-renderer.md:73-76; doc 13 correctness-first).
- Golden image files or any image-snapshot infrastructure.
- Configurable fonts, sizes, or themes.

## Accepted risks

- AR1: Pixel probes assert coarse behavioral claims, so an OS font update that
  changes SF Mono's advance silently changes cell metrics; geometry claims are
  relative (integrality, containment, tiling), never absolute point values.
  This is the intended narrow scoping from 12-testing-conformance.md:111-112.
- AR2: Per-cell CoreText shaping every frame is the slow-but-correct choice;
  caching is later discretion.
- AR3: Cell clipping trims legitimate overhang -- italic slant, oversized
  fallback ink, and 13 pt color emoji that exceed their span are cut, not
  scaled. Revisit alongside Milestone 6 damage work.
- AR4: Executor behavior on non-canonical plans is unspecified; such plans are
  unconstructible outside the planner (internal inits), which is the
  protection, not a validation pass.
- AR5: In-process determinism of CoreText/color-emoji rasterization is assumed;
  PO8 falsifies it if wrong.

## Rejected ideas

- RI1: Golden PNG snapshots -- brittle across macOS font revisions and assert
  thousands of unclaimed pixels; probes assert exactly the slice's claims.
- RI2: Making plan memberwise inits public for test fabrication -- forfeits the
  canonical-form guarantee for a convenience the `planFrame` idiom already
  provides.
- RI3: A separate SwiftPM package for the executor -- the purity boundary is
  directory-scoped, so the package boundary buys nothing while costing gate
  wiring; slice 1 RI3's calculus survives the AppKit dependency.
- RI4: Advance-accumulating layout (one CTLine per run) -- fallback advances
  would shift neighbors, violating 09-renderer.md:36-37; per-cell positioning
  is the whole point of cells carrying widths.
- RI5: A cursor drawing pass from `plan.cursor` -- double-draws what the runs
  already contain and contradicts slice 1 RI6 (the plan fully determines
  drawing).
- RI6: Shipping the NSView this slice -- unprovable in the headless gate; its
  real obligations belong with slice 3's wiring.
- RI7: Reading display scale ambiently inside the executor -- breaks I1 and the
  display-scaling ADR's size/scale pairing.
- RI8: Unquantized fractional cell advances -- fractional edges antialias into
  seams between runs; pixel-integral cells are the Retina contract.
- RI9: Low-level glyph-mapping APIs (`CTFontGetGlyphsForCharacters` + manual
  cascade) for executor layout -- reimplements font fallback and breaks on
  multi-scalar clusters. Read-only use of the same APIs in tests, to assert
  which font shaping selected, is not layout and is what PO5 relies on.

## Implementation discretion

- All type, member, and file names; whether metrics store CoreText font objects
  or recreate them.
- Baseline pixel snapping; horizontal placement of narrow ink within wide
  spans; curly amplitude/period; double-underline gap; strikethrough offset --
  each probe-pinned once chosen.
- Bitmap harness structure, probe helper design, and ink thresholds.
- Commit slicing, provided every commit is green and failing-test-first (repo
  TDD rule).

## Files

- Modify `lib/TerminalCore/Package.swift` -- add the `TerminalRenderExecution`
  library target + product (deps: `TerminalRenderPlanning`) and the
  `TerminalRenderExecutionTests` test target (deps: executor, planner,
  `TerminalCore`), Swift 6 mode.
- Create `lib/TerminalCore/Sources/TerminalRenderExecution/` -- metrics +
  frame-drawing sources (file split discretion).
- Create `lib/TerminalCore/Tests/TerminalRenderExecutionTests/` -- bitmap/probe
  harness + the PO suites.
- Modify `lib/TerminalCore/Sources/TerminalRenderPlanning/TerminalRenderPlanning.swift`
  -- correct `RenderCursor`'s "Filled block to draw" doc comment (:121) to state
  that the runs already contain the rendered block and the record supplies
  geometry metadata only. Doc-only; no behavior or lint change.
- No changes to `justfile`, `scripts/core-purity-lint.sh`, or any lint.

## Verification

`just test` is the acceptance gate: `swift test --package-path
lib/TerminalCore` (justfile:32) picks up the new targets with no justfile
edits; all existing purity-lint lines stay green untouched, proving the
executor landed outside the pure directories. PO10's one-time headless check
(non-GUI session, e.g. ssh) closes the slice.

## Commit progress

- [x] 1. Establish pixel-quantized metrics, safe frame sizing, and background execution
- [x] 2. Add per-cell CoreText shaping, traits, clipping, and orientation
- [x] 3. Add decorations and complete executor gate coverage
