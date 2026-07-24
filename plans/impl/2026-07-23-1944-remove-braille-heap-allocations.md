# Remove heap allocations from `BraillePixelLayout`

## Context

`BraillePixelLayout` (in
`lib/TerminalCore/Sources/TerminalSpriteGeometry/BrailleSpriteGeometry.swift`)
stores its 2-column by 4-row braille dot grid as two `[Int]` arrays
(`xPositions`, `yPositions`). The braille grid is permanently and semantically
2x4, so `[Int]` is the wrong representation: it permits invalid sizes, hides
heap allocation behind a value type, and makes a tiny immutable value look
dynamically shaped.

The material once-per-draw regression is already fixed by the per-draw hoist
(commit d19103f), and this change does **not** touch that hoist. This is a
correctness-of-representation cleanup, not a perf fix: the fixed storage encodes
the 2x4 invariant and removes the allocation, and the hoist independently avoids
recomputing the layout arithmetic ~1,700x per benchmark. Both stay.

## Change

Replace the two arrays with six fixed inline scalar fields, per the design the
user specified.

### `BraillePixelLayout` (BrailleSpriteGeometry.swift:5-19)

- Public `dotSize: Int` stays public.
- Replace `xPositions: [Int]` / `yPositions: [Int]` with private
  `x0, x1, y0, y1, y2, y3: Int`.
- Keep `rect(column:row:)` public; back it with private `xPosition(_:)` /
  `yPosition(_:)` switch helpers that `preconditionFailure` on out-of-range
  column/row (encodes the 2x4 invariant at the boundary).
- `Equatable` + `Sendable` conformances stay (the determinism test relies on
  `==`).

Target shape (from the user):

```swift
public struct BraillePixelLayout: Equatable, Sendable {
    public let dotSize: Int
    private let x0, x1, y0, y1, y2, y3: Int

    public func rect(column: Int, row: Int) -> SpritePixelRect {
        SpritePixelRect(x: xPosition(column), y: yPosition(row),
                        width: dotSize, height: dotSize)
    }
    private func xPosition(_ column: Int) -> Int {
        switch column {
        case 0: x0
        case 1: x1
        default: preconditionFailure("Invalid braille column")
        }
    }
    private func yPosition(_ row: Int) -> Int {
        switch row {
        case 0: y0; case 1: y1; case 2: y2; case 3: y3
        default: preconditionFailure("Invalid braille row")
        }
    }
}
```

Private stored properties make the synthesized memberwise init `private`, which
is fine: the only production constructor (`BrailleSpriteGeometry.layout`) lives
in the **same file**, so it can still initialize the struct directly.

### `BrailleSpriteGeometry.layout` (BrailleSpriteGeometry.swift:83-94)

Drop the `xPositions`/`yPositions` array construction. The layout arithmetic
above (dotSize/margins/spacing) is unchanged; just feed the six scalars into the
struct instead of building arrays:

```swift
let step = dotSize + ySpacing
return BraillePixelLayout(
    dotSize: dotSize,
    x0: xMargin,
    x1: xMargin + dotSize + xSpacing,
    y0: yMargin,
    y1: yMargin + step,
    y2: yMargin + 2 * step,
    y3: yMargin + 3 * step
)
```

### Consumers

No production consumer touches the removed fields:
- The only read is `layout.rect(column:row:)` in
  `TerminalRenderExecution/BrailleSprite.swift:91` — unchanged (`rect` keeps its
  signature).
- The per-draw hoist in `TerminalRenderExecution.swift:422-436` — unchanged.

### Tests

`lib/TerminalCore/Tests/TerminalSpriteGeometryTests/BrailleSpriteGeometryTests.swift`
reads `layout.xPositions` / `layout.yPositions` directly (lines 66-69,
120-137). `@testable import` does not reach `private` members, so these must
route through the public `rect(column:row:)` instead. This is a strict
improvement: the tests assert the same positions through the same public seam
production uses.

- `representativePixelLayouts` (66-69): compare
  `layout.rect(column: i, row: 0).x` against expected `xPositions[i]` and
  `layout.rect(column: 0, row: j).y` against expected `yPositions[j]`. Keep the
  `BrailleLayoutSample` fixture's expected arrays as-is — they are test data,
  not reads of the layout.
- `physicalPixelInvariantMatrix` (118-138): replace the `layout.xPositions[...]`
  / `layout.yPositions` reads with values pulled from `rect(...)`, e.g.
  `let xs = (0..<2).map { layout.rect(column: $0, row: 0).x }` and
  `let ys = (0..<4).map { layout.rect(column: 0, row: $0).y }`, then reuse those
  local arrays for the monotonicity, separation, and equal-gap checks.

## Verification

- `swift test --package-path lib/TerminalCore --filter Braille` — runs both the
  pure geometry proofs (`BrailleSpriteGeometryTests`) and the execution/pixel
  proofs (`BrailleSpriteExecutionTests`). Expected: green, with the geometry
  suite exercising positions through `rect()`.
- `just test` — full local gate (includes core-purity lint) to confirm nothing
  else references the removed fields.

## Out of scope

- The per-draw hoist in `TerminalRenderExecution.swift` — kept as-is.
- The layout arithmetic in `BrailleSpriteGeometry.layout` — byte-for-byte
  identical output; only the return-value packaging changes.

## Implementation notes

- Wrote an explicit `init(dotSize:x0:x1:y0:y1:y2:y3:)` on `BraillePixelLayout`
  rather than leaning on the (now-private) synthesized memberwise initializer.
  Both are same-file-accessible from the factory; the explicit one reads more
  clearly at the single call site and keeps the field order documented.
