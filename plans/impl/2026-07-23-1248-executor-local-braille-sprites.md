# Executor-local braille sprites

## Problem and desired outcome

The evidence and chosen direction come from
[`docs/research/4-fallback-glyph-batching.md`](../../docs/research/4-fallback-glyph-batching.md).
Braille cells in btop miss DanTerm's primary font and fall through to per-cell
CoreText line construction. A compatible serialized redraw benchmark measures
the btop-shaped symbol workload at 30,003,225 ns/draw, 94.3x the documented
318,030 ns/draw post-fast-path content measurement. That ordinary measurement
was not committed as compatible benchmark history when this plan was written.
An optimized btop probe attributed 284,153 of 284,611 fallback entries (about
99.84%) to width-one braille scalars.

The first sprite increment should remove that dominant fallback cost while
preserving the renderer's grid, color, layering, clipping, and damage
contracts. It should also prove whether procedural terminal glyphs belong in
the existing executor before DanTerm expands sprite coverage.

## Decision

The render executor will recognize only single-scalar U+2800-28FF cells and
draw their specified 2x4 dot patterns procedurally before primary-font lookup.
The existing text runs remain the input and ownership boundary: sprite
classification does not enter the planner or terminal model.

Braille geometry is derived from the cell's pixel-quantized bounds at the
active display scale. A blank braille scalar draws no dots. Dot fills from
compatible cells may be batched within the current draw, but the path remains
stateless across frames.

Bold and italic attributes do not alter procedural braille geometry. Styled
braille uses the same dot pattern as regular braille while retaining the
resolved foreground color.

All cells outside this exact supported set retain the existing mapped-glyph or
CoreText fallback behavior. The experiment is accepted only if compatible
unprofiled benchmarks show that it attacks the btop-shaped regression without
regressing ordinary redraw workloads.

Before the executor changes, compatible current baselines for content, style,
and mixed churn must be recorded in committed benchmark history. Those records,
not the pre-fast-path entries or an uncommitted research measurement, form the
ordinary-workload regression gate.

## Invariants

- I1: Sprite membership is exactly single-scalar U+2800-28FF. Neighboring
  Unicode blocks, multi-scalar cells, and supplementary-plane cells are not
  reclassified.
- I2: Every set braille bit produces its corresponding dot in the Unicode
  Braille 2x4 layout; unset bits and U+2800 produce no sprite ink.
- I3: Sprite ink stays inside its terminal cell and uses pixel-aligned geometry
  at display scales 1 and 2.
- I4: Sprite color is the resolved foreground carried by the text run,
  including selection and visible block-cursor foreground overrides.
- I5: Bold and italic attributes leave braille sprite geometry unchanged.
- I6: Sprites preserve the existing rendering order: backgrounds and selection
  remain behind text, while decorations and non-block cursor overlays remain
  above it.
- I7: Damage-row and dirty-rectangle redraws containing sprites are
  pixel-identical to a fresh full-frame draw.
- I8: Non-sprite text, including primary-font glyphs and fallback-only
  characters, renders unchanged.

## Proof obligations

- PO1: A pure supported-set and dot-layout proof covers the exact scalar
  boundary, the blank pattern, individual dot positions, and the full pattern.
- PO2: Bitmap proofs at display scales 1 and 2 establish dot placement,
  containment, foreground color, isolation from adjacent cells, and identical
  dot geometry across regular, bold, italic, and bold-italic braille.
- PO3: Bitmap proofs establish selection, block cursor, underline cursor, bar
  cursor, and decoration layering for braille cells.
- PO4: Incremental damage-row and dirty-rectangle draws containing braille are
  pixel-identical to full redraws.
- PO5: Existing renderer execution tests continue to prove mapped glyph,
  fallback, trait, Unicode containment, clipping, and context-ownership
  behavior.
- PO6: Compatible `just benchmark-redraw` runs are recorded for the
  btop-shaped symbol workload, the curated sprite-coverage workload, and the
  content, style, and mixed ordinary workloads. The pre-change ordinary runs
  must be committed before implementation. The btop-shaped workload must reach
  at most 636,060 ns/draw; post-change ordinary runs must remain within the
  compatible pre-change variability rather than showing a repeatable
  regression.

## Non-goals

- Box drawing, block elements, geometric shapes, powerline symbols, or other
  procedural glyphs.
- General fallback-font batching or caching.
- A planner-visible sprite run, retained sprite frame, glyph atlas, or Metal
  renderer.
- Reprofiling interactive btop; that is the follow-up after this benchmarked
  experiment lands.

## Accepted risks

- AR1: Procedural braille intentionally differs from AppleBraille typography.
  The Unicode dot pattern, terminal-cell containment, and stable
  pixel-quantized output are the rendering contract.
- AR2: The 636,060 ns/draw target is deliberately aggressive and may reject
  the executor-local approach. Missing it triggers measurement and a design
  decision, not silent expansion into caching or retained rendering.

## Rejected ideas

- RI1: Classifying entire Unicode blocks is rejected because adjacent blocks
  include characters whose appearance is typographic rather than specified
  terminal-cell geometry.
- RI2: Planner-owned sprite runs are rejected for this increment because
  existing text runs already carry every input needed for executor-local
  classification and drawing.
- RI3: Cross-frame caching or a retained sprite layer is rejected until
  profiling or an atlas design demonstrates that the extra ownership and
  invalidation state is necessary.

## Implementation discretion

- The internal representation of dot geometry and the batching strategy for
  fills.
- The exact pixel distribution and inset policy, provided the proof
  obligations and Unicode layout contract hold at both required scales.

## Commit progress

- [x] 1. perf(benchmark): record pre-braille ordinary redraw baselines
- [x] 2. perf(renderer): draw braille cells as executor-local sprites

## Implementation notes

- The compatible pre-change medians are 298,554 ns/draw for content churn,
  325,672 ns/draw for style churn, and 319,840 ns/draw for mixed churn. All
  three records use the `pre-braille-compatible-baseline` comment.
- Braille uses integer backing-pixel 2x4 slots with one centered rectangle per
  enabled dot. The executor batches those rectangles per existing text run,
  converts to point coordinates only at the Core Graphics boundary, and keeps
  classification before cmap lookup.
- The compatible post-change medians are 342,513 ns/draw for btop-shaped
  symbol churn, 12,420,459 ns/draw for curated sprite coverage, 324,141
  ns/draw for content churn, 320,814 ns/draw for style churn, and 331,802
  ns/draw for mixed churn. The btop-shaped workload improved 98.86% and passed
  the 636,060 ns/draw target. The ordinary workload ranges overlap their
  pre-change ranges, so they do not show a repeatable regression.

## Follow Up

- Replace the slot-centered braille geometry in
  `lib/TerminalCore/Sources/TerminalRenderExecution/BrailleSprite.swift` with
  a whole-shape square-dot pixel allocator and odd/tiny-cell behavioral proofs
  before adding another sprite family.
- Reduce the wall time and foreground-input fragility of full 15-batch
  recordings in `scripts/terminal-draw-acceptance.py` while preserving
  independent compatible samples.
