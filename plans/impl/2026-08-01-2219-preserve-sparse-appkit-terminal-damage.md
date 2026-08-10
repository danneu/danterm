# Preserve sparse terminal damage through AppKit

## Problem

`SwiftTerminalSessionView` receives sparse `TerminalDamage` from the engine, but
AppKit coalesces multiple `setNeedsDisplay` rectangles into one bounding
`dirtyRect` before `draw(_:)`. Deriving the render rows from that bounding
rectangle turns distant changes into a contiguous redraw. For example, changes
to rows 2 and 33 caused the renderer to process all 34 intervening rows.

The engine has already done the expensive and semantically useful work of
tracking bounded, merged damage. The view must preserve that source damage until
the draw rather than attempt to reconstruct its shape after AppKit has discarded
it.

## Decision

`SwiftTerminalSessionView` retains pending engine damage across frame
publications until the next draw:

- Partial frame damage is expanded by the existing one-row glyph halo and
  unioned into `pendingDisplayDamage`.
- Full-frame, geometry, theme, and benchmark-forced invalidations promote the
  pending damage to `.full` through one `invalidateFullDisplay()` entry point.
- `draw(_:)` consumes the pending engine damage when present. A draw with no
  pending engine damage falls back to AppKit's dirty rectangle so ordinary
  AppKit-driven redraws still work.
- Partial draws clip both the `RenderFramePlan` and the graphics context to the
  sparse row set. Adjacent rows are coalesced into maximal contiguous spans
  before constructing the graphics-context path. This skips background fills
  and glyph runs in the gap between damaged regions without making Core
  Animation represent one clip rectangle per row.

The source damage is authoritative because AppKit invalid-region APIs were also
probed on this layer-backed view and exposed the same unioned region by draw
time. Retaining the engine's damage is therefore simpler and more reliable than
trying to recover sparse topology inside `draw(_:)`.

## Invariants

1. Every partial frame published before a draw contributes to the pending
   damage; a later publication cannot replace or drop earlier damage.
2. A full invalidation dominates any pending partial damage.
3. Every view-owned content change outside partial frame publication uses
   `invalidateFullDisplay()`. A future direct `needsDisplay = true` or full-view
   `setNeedsDisplay` call could otherwise be hidden by pending partial damage.
4. Partial engine damage keeps the existing one-row glyph halo so overhanging
   glyphs remain correct.
5. The sparse clip applies to the whole frame render, including background
   painting, not only glyph drawing.
6. Every partial clip uses the minimum number of exact vertical spans; adjacent
   damaged rows never become separate Core Graphics path rectangles.
7. This change does not alter render scheduling, frame publication cadence, or
   idle behavior.

## Proof obligations

- The UI regression test publishes two partial frames affecting distant rows
  before allowing AppKit to draw, then asserts that the renderer receives only
  the two damage regions plus their glyph halos. It failed against the old
  bounding-rectangle behavior with rows `0...9` and passes with the sparse row
  set `{0, 1, 2, 7, 8, 9}`.
- Full invalidations continue to render the full frame.
- AppKit-driven draws without pending engine damage continue to use the AppKit
  dirty rectangle.
- `just test-ui`, `just test`, `swift build`, and the terminal benchmark harness
  self-test pass.

## Performance impact

A temporary diagnostic workload changed two distant rows per frame in a
179-column by 66-row terminal at scale 2. The optimized AppKit draw-acceptance
harness ran 8 valid batches per arm above its 200 ms draw-work floor, comparing
the parent implementation with this change:

| Metric | Before median | After median | Reduction |
| --- | ---: | ---: | ---: |
| Direct draw time per draw | 2,335,645.4 ns | 343,350.3 ns | 85.30% |
| Whole-process CPU time per draw | 5,800,681.4 ns | 2,916,765.0 ns | 49.72% |

The direct-draw batch ranges were 2,308,921.6-2,398,534.3 ns before and
341,842.7-345,420.0 ns after. Whole-process CPU batch ranges were
5,738,638.5-6,128,020.4 ns before and 2,897,603.0-2,945,608.8 ns after.

Both arms still reported `dirtyRowCount == 34`. That field measures AppKit's
bounding dirty rectangle, not the sparse rows submitted to the renderer. The UI
test's recorded render-plan row set is the behavioral proof that the gap is no
longer drawn.

The normal same-session `terminal-feed` control remained equivalent at +0.42%
symmetric median across two pairs. This diagnostic demonstrates a large CPU
benefit when distant rows change together; it is not a frozen or calibrated
performance verdict. Lower CPU work should reduce energy use for this workload,
but energy consumption was not measured directly and no battery-life claim is
made.

A follow-up live-btop profile found that the original one-rectangle-per-row
implementation regressed whole-process CPU despite improving direct draw. At a
verified 179x66 grid, a controlled automated three-arm comparison measured
parent at 24.17% mean CPU (18.3--25.6%), the uncoalesced implementation at
44.10% (31.7--46.8%), and maximal-span coalescing at 22.94% (19.0--24.7%). The
parent and coalesced ranges overlap, so the supported claim is "equivalent or
better," not that coalescing is faster. Coalescing reduced the regressed Core
Animation clip-construction subtree by 95.5% to 97.6% on this stimulus.

The revised implementation also retained the motivating two-distant-row win in
eight valid 200-draw batches per arm: median direct draw was 0.057 ms/draw
coalesced versus 0.164 parent, and median whole-process CPU was 1.945 ms/draw
versus 2.115. At the halo-limited maximum topology for 66 rows -- 17 disjoint
spans produced by writes every fourth row -- median process CPU was 4.695
ms/draw coalesced versus 4.835 parent. A threshold fallback was therefore
rejected under the rule frozen before that endpoint was measured.

## Non-goals and accepted limits

- Do not change the engine's damage-merging policy or AppKit's scheduling.
- Do not claim an improvement for idle, full-screen, or contiguous-damage
  workloads; those paths do not contain the eliminated gap.
- Do not keep the temporary two-row producer as a permanent benchmark workload.
- The view owns the correctness boundary: any future view-owned full
  invalidation must use `invalidateFullDisplay()` so it composes safely with
  pending partial damage.

## Implementation discretion

The pending-damage storage representation, render-plan filtering mechanism, and
test observation hook may change as long as the invariants and proof obligations
above remain true.
