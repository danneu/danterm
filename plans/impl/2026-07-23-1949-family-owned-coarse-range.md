# Family-owned `coarseRange` for sprite classification routing

## Context

`TerminalRenderExecution.drawTextRuns(...)` routes each single-scalar cell to
one of eight sprite families via a `switch scalar.value` (introduced in
a785d45, "route sprite classification by scalar range"). Today each `case`
label repeats a literal scalar range that is *also* stated inside the family's
own `pattern(for:)` guard -- the ranges are duplicated between the router and
the family, so the router can silently drift from the family it dispatches to.

Goal: make each family own its coarse routing span as a
`static let coarseRange: ClosedRange<UInt32>` and have the router reference
that constant, eliminating the duplication while preserving exact rendering
behavior. `coarseRange` is only the *routing* span; **exact membership stays
inside each family's `pattern(for:)`**, so scalars in interior gaps of a sparse
family still return `nil` and fall through to the font path unchanged.

## Files

All under `lib/TerminalCore/Sources/TerminalRenderExecution/`:

- `TerminalRenderExecution.swift` -- the router switch (lines 384-484)
- The eight family files: `BoxDrawingSprite.swift`, `BlockElementSprite.swift`,
  `GeometricShapeSprite.swift`, `BrailleSprite.swift`, `PowerlineSprite.swift`,
  `BranchDrawingSprite.swift`, `LegacyComputingSupplementSprite.swift`,
  `LegacyComputingSprite.swift`

## Change

### 1. Add `coarseRange` to each family

Add a `static let coarseRange: ClosedRange<UInt32>` to each family enum, using
the exact span the router currently hardcodes:

| Family | `coarseRange` |
|---|---|
| BoxDrawingSprite | `0x2500...0x257F` |
| BlockElementSprite | `0x2580...0x259F` |
| GeometricShapeSprite | `0x25E2...0x25FF` |
| BrailleSprite | `0x2800...0x28FF` |
| PowerlineSprite | `0xE0B0...0xE0D4` |
| BranchDrawingSprite | `0xF5D0...0xF60D` |
| LegacyComputingSupplementSprite | `0x1CC1B...0x1CEAF` |
| LegacyComputingSprite | `0x1FB00...0x1FBEF` |

Give each a one-line `///` doc noting it is the *coarse routing span* and that
exact membership lives in `pattern(for:)` (important for the four sparse/
discontiguous families -- Geometric, Powerline, and both Legacy families --
whose `coarseRange` deliberately spans interior gaps that `pattern(for:)`
rejects).

For `LegacyComputingSupplementSprite`, derive nothing from the existing
`implementedRanges` array beyond noting that `coarseRange` is its
`lowerBound...upperBound` envelope; keep `implementedRanges` as-is (it is used
elsewhere for enumeration).

### 2. Reference `coarseRange` in the router switch

Replace each literal `case` label with the family's constant. Swift evaluates
`case` expression patterns via `~=`, and `ClosedRange<UInt32> ~= UInt32`
exists, so this compiles and keeps the switch structure identical:

```swift
case BoxDrawingSprite.coarseRange:        // was: case 0x2500...0x257F
...
case BlockElementSprite.coarseRange:      // was: case 0x2580...0x259F
...
case GeometricShapeSprite.coarseRange:    // was: case 0x25E2...0x25FF
...
case BrailleSprite.coarseRange:           // was: case 0x2800...0x28FF
...
case PowerlineSprite.coarseRange:         // was: case 0xE0B0...0xE0D4
...
case BranchDrawingSprite.coarseRange:     // was: case 0xF5D0...0xF60D
...
case LegacyComputingSupplementSprite.coarseRange:  // was: case 0x1CC1B...0x1CEAF
...
case LegacyComputingSprite.coarseRange:   // was: case 0x1FB00...0x1FBEF
```

Keep the existing routing comment block (lines 372-381) and the "coarse ranges
spanning each multi-range family" comment (lines 458-459); they still describe
the behavior accurately.

### 3. (Optional, low priority) collapse contiguous families' own guards

The four fully-contiguous families (Box, Block, Braille, Branch) currently open
`pattern(for:)` with a literal range guard equal to their `coarseRange`. These
guards *may* be rewritten as `guard coarseRange.contains(value) else ...` to
remove the last duplicate literal. Do **not** touch the guards of the sparse/
discontiguous families -- their exact membership is finer than `coarseRange`
and must stay literal. This step is purely cosmetic; skip it if it complicates
review.

## Non-goals

- No behavior change: exact per-scalar membership and pattern decoding are
  untouched; gaps still fall through to the font path.
- No new structure-coupled tests (per instruction). The existing per-family
  execution tests already pin exact membership and mapping.

## Verification

1. `just test` -- runs the TerminalRenderExecution suites (per-family execution/
   bitmap tests + `ExecutorContractTests` + incremental-vs-full-redraw
   equivalence). All must pass with no changes; a green run confirms membership
   and rendering output are unchanged.
2. Paired redraw benchmarks (AC power, optimized build) for the two
   sprite-sensitive workloads, confirming no regression vs. the pre-change
   baseline in `benchmarks/results/terminal-redraw.jsonl`:
   - `just benchmark-redraw workload=full-screen-symbol-churn`
   - `just benchmark-redraw workload=full-screen-sprite-coverage-churn`

   Since this is a source-identical dispatch (constant range vs. literal range,
   same `~=` comparison), draw-time should be within run-to-run noise.
