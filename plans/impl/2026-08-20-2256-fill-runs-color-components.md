# Fill runs as color components, not CGColor objects (DRAW-3)

Source: `docs/scratch/2026-08-18-construction-audit.md` DRAW-3.

## 1. Problem and evidence

`drawRenderFrame` (`lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift`)
turns a `RenderColor` -- three bytes -- into a heap `CGColor` (built from a
Swift array literal) once per filled run: the default background, every
background run, every overlay run, the block cursor, the cursor overlay,
and two to three times per decoration run (`setFillColor` and
`setStrokeColor` from the same value, plus the strikethrough color). Only
the text path memoizes, and only the text path genuinely needs an object
(`copy(alpha:)` for shaded sprites, `kCTForegroundColorAttributeName` in
the fallback attribute dictionaries).

Premises checked against the tree at `c6336f47`:

- FRAME-1/FRAME-3 changed the loop shape (`for row in rows { for run in
  row.backgroundRuns ... }`, `restrictedTo:` damage) but not one color call
  site. MOBILE-2 routed the phone through the same `drawRenderFrame` into
  an sRGB store, so there is no second color path to fix.
- `drawRenderFrame` hardcodes an sRGB `CGColorSpace` for the colors while
  `TerminalFrameBackingStore` draws into the window's space; CoreGraphics
  converts per fill. That conversion is correct and stays.
- `CGContextSetFillColorSpace` / `CGContextSetFillColor(components)` and
  their stroke twins exist in the macOS SDK.

Desired outcome: a non-text fill reaches CoreGraphics as numbers, so there
is nothing to allocate and nothing to memoize, and the rendered pixels are
byte-identical on every destination space.

## 2. Decision

Declare the context's fill and stroke color space as sRGB once per
`drawRenderFrame`, inside the graphics state it already saves and
restores, and pass every non-text color as components from stack storage.
The text path keeps its `CGColor` and its per-draw memo. Helpers that no
longer need a color space stop taking one.

Scope: `TerminalRenderExecution.swift` only; the public
`drawRenderFrame` signature and every caller are unchanged.

Rejected: adopting the destination's space for the color values (RI1). It
changes pixels on a wide-gamut display; per-fill conversion was never the
cost.

## 3. Invariants

- I1. Rendered output is byte-identical to today on an sRGB destination and
  on a wide-gamut destination: the declared space of every color stays
  sRGB, and `RenderColor` values are interpreted exactly as before.
- I2. No `CGColor` is created for a background, overlay, cursor, or
  decoration fill; a `CGColor` exists only where a consumer needs an
  object (text foreground).
- I3. The caller's graphics state is untouched after the draw, including
  the fill and stroke color spaces.

## 4. Proof obligations

- PO1 (I1, sRGB): the existing exact-pixel suites in
  `lib/TerminalCore/Tests/TerminalRenderExecutionTests` --
  `BackgroundExecutionTests`, `SelectionExecutionTests`,
  `SearchMatchExecutionTests`, `DecorationExecutionTests` (including the
  curly stroke path and strikethrough), `ExecutorContractTests` cursor
  cases -- pass unchanged. Run them before the change to confirm green.
- PO2 (I1, wide gamut): new test. Render a plan carrying a truecolor
  background run, an overlay run, a decoration run with a stroke kind and
  strikethrough, and a block cursor into a `displayP3` destination (the
  pattern in `FrameSwapchainTests` around `CGColorSpace.displayP3`), and
  compare bytes against the same rects filled with reference sRGB
  `CGColor` objects in an identical context. Also assert the truecolor
  pixel differs from its raw components, so the test fails if the
  destination's space is ever adopted without conversion.
- PO3 (I3): the existing caller-state contract test in
  `ExecutorContractTests` (CTM, text matrix, clip survive the draw) stays
  green, and it grows a color-space arm: its sentinel currently sets an
  sRGB `CGColor` object, which carries its own space and so cannot witness
  a leaked one. Give the subject and control contexts a `displayP3` fill
  space and stroke space before the draw, then after `drawRenderFrame`
  fill and stroke sentinel shapes from raw components without re-declaring
  either space, and compare pixels. A declaration that escapes the saved
  graphics state reinterprets those components as sRGB and the bytes
  diverge.
- I2 is an allocation property with no pixel witness; it is verified by
  reading the diff (no `CGColor(` outside the text path) and, as a
  non-gating signal, `just benchmark-quick baseline=HEAD
  workload=style-churn` plus a `btop-scroll` Time Profiler trace where
  `CGColorCreate` frames should leave `drawRenderFrame`. Per
  `agent-docs/terminal-performance.md`, style-churn may read `equivalent`
  (the fixture holds ~66 background runs); make no directional claim
  without `benchmark-confirm`.

## 5. Non-goals / accepted risks

- Non-goal: touching the text memo or `drawTextRuns`' color handling
  (DRAW-4 edits that function; keeping the hunks disjoint avoids a
  conflict).
- Non-goal: changing which space the store's context uses.
- Accepted risk AR1: the benchmark cannot resolve the win; the change is
  justified by removing pure overhead, not by a measured number.

## 6. Implementation discretion

- How `RenderColor` becomes components (tuple, helper on `RenderColor`,
  inline) and whether `drawDecorationRuns` re-asserts the fill space on
  entry. `saveGState` inherits the current spaces, so one declaration at
  the top of `drawRenderFrame` is sufficient; a re-assert is harmless.
