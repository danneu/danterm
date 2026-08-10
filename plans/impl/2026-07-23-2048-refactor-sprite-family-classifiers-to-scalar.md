# Refactor sprite-family classifiers to `pattern(for scalar:)`

## Context

The per-cell classifier loop in `TerminalRenderExecution.swift` already establishes
that a cell is a sprite candidate only when `cell.scalars.count == 1`, and it
extracts that single `scalar` to pick the family via `coarseRange`. But it then
passes the *whole* `cell.scalars` array into each family's
`pattern(for scalars: [Unicode.Scalar])`, which redundantly re-checks
`scalars.count == 1` and re-extracts `.first`. The array is only ever length 1 at
that call site, so the array parameter is dead surface area: it invites the
mistaken belief that a family might receive multi-scalar input and forces every
family plus its tests to carry the count-guard boilerplate.

This change narrows the eight family classifiers to take a single
`Unicode.Scalar`, passing the already-extracted `scalar` directly. Exact Unicode
membership and scalar-to-pattern decoding stay inside each family. Multi-scalar
cells (e.g. a geometric shape + variation selector) keep taking the existing
font/fallback path via the loop's non-single-scalar branch -- they must never be
reduced to their first scalar and drawn as a procedural sprite. We add a behavioral
executor test to lock that guarantee, since it is currently only proven at the
`pattern(for:)` unit level (which the refactor makes structurally impossible to
even express).

## Contract

The eight family enums in `lib/TerminalCore/Sources/TerminalRenderExecution/`
(`BoxDrawingSprite`, `BlockElementSprite`, `GeometricShapeSprite`, `BrailleSprite`,
`PowerlineSprite`, `BranchDrawingSprite`, `LegacyComputingSupplementSprite`,
`LegacyComputingSprite`) each expose `pattern(for scalar: Unicode.Scalar)` instead
of `pattern(for scalars: [Unicode.Scalar])`:

- Each family retains its own exact Unicode membership check and scalar-to-pattern
  decoding. Only the redundant `count == 1` / `.first` guard is dropped, since the
  caller now supplies exactly one scalar.
- The executor's per-cell loop in `TerminalRenderExecution.swift` remains the sole
  single-scalar gate: it already tests `cell.scalars.count == 1`, binds the scalar,
  and routes multi-scalar (and empty) cells to the font/fallback path. That gate
  and its fallback branch are unchanged; the loop passes the bound scalar to the
  selected family.
- Any internal helper that forwarded a collection to `pattern(for:)` (e.g.
  `BrailleSprite.dots`/`rects`) forwards the single scalar instead.

## Tests

Family unit tests in `lib/TerminalCore/Tests/TerminalRenderExecutionTests/` pass a
single scalar rather than a collection. Assertions that exercised the deleted
collection-input guard -- empty arrays and multi-scalar/variation-selector arrays
returning nil -- are obsolete under the scalar-only API and are removed. Every
membership-boundary case that a single scalar can still express (in-range and
out-of-range single scalars) is retained as a scalar call, preserving each family's
exhaustive membership and mapping coverage.

## New behavioral test

The removed multi-scalar unit assertions were the only coverage proving a
variation-selector grapheme is not reduced to its first scalar and drawn as a
sprite. That guarantee lives at the executor level (the `count == 1` gate) and has
no executor-level test today. Add a characterization test before the refactor, in
`GeometricShapeSpriteExecutionTests.swift` (its harness already imports
`renderBitmap`, `makePlan`, `cellRect`, `Pixel`, `RenderTheme`):

- Contract: a cell whose grapheme is a geometric-shape scalar plus a variation
  selector (`"\u{25E2}\u{FE0F}"`) renders differently from the bare scalar
  (`"\u{25E2}"`), which produces the procedural corner triangle -- proving the
  multi-scalar cell takes the font/fallback path and is not reduced to its first
  scalar.
- Assertion (structure-insensitive): render both and `#expect` the two cell bitmaps
  differ.

It passes on current code and must keep passing after the refactor. To confirm it
actually detects first-scalar reduction rather than passing vacuously, temporarily
mutate the executor to route the multi-scalar cell through its first scalar and
verify the test fails; revert the mutation before proceeding.

## Verification

1. `swift test --package-path lib/TerminalCore --filter TerminalRenderExecutionTests`
   -- focused sprite/render suites green.
2. `just test` -- full local gate (includes core-purity lint).
3. Paired redraw benchmarks per `agent-docs/terminal-performance.md`: run the
   redraw benchmark before and after on the same machine/build config and confirm
   no regression (the change removes per-cell array boilerplate; expect neutral or
   slightly better).
