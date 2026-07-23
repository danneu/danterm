# Fallback-glyph batching for symbol-heavy screens

Research date: 2026-07-23.

## Purpose

This document is the research record for the next rendering sweep: reducing
main-thread CPU when the screen is dominated by characters that miss the
primary font's cmap and therefore take the per-cell CTLine fallback path.
It continues the story of
[3-serialized-redraw-optimization.md](3-serialized-redraw-optimization.md),
which batched the fast path (per-run `CTFontGetGlyphsForCharacters` +
`CTFontDrawGlyphs`) and reduced serialized full-screen redraws from ~10 ms to
~0.32 ms per draw. That work deliberately retained the per-cell
`CTLineCreateWithAttributedString` path as the fallback for cmap misses and
multi-scalar cells.

## Motivating observation

After doc 3 shipped, btop scrolls much faster, but holding an arrow key to
scroll its process list still drives DanTerm Dev to roughly 50% CPU in a
release build. A diagnostic `sample` capture (2026-07-23,
`/tmp/danterm-btop-sample.txt`, profiling diagnostic only -- not benchmark
history) of 10,371 main-thread samples shows:

- `SwiftTerminalSessionView.draw(_:)` totals ~5,700 samples (~55% of the main
  thread) across three invalidation subtrees.
- Inside `drawRenderFrame`, ~2,990 samples (~29% of the main thread) sit in
  `CTLineCreateWithAttributedString`. The batched fast path
  (`CTFontDrawGlyphs`) accounts for only ~450 samples.
- The largest stack under CTLine creation is not shaping or rasterization but
  `TFont::NeedsShapingForGlyphs -> TFont::ShapesAnyPreferredLanguage ->
  ICU locale machinery` (`uscript_getCode`, `ulocimp_addLikelySubtags`,
  resource-bundle lookups): ~1,600 samples. CoreText re-answers a
  per-font-per-language question once per cell, per frame.
- Everything else is modest: `FramePlanner.plan`/`textRuns`/`inspectedCells`
  ~800-900 samples, `Terminal.feed` a few hundred, publish plumbing small.

btop paints graphs and meters with braille (U+2800 block) and box-drawing
characters. The working explanation is that these miss the primary font's
cmap, so `CTFontGetGlyphsForCharacters` returns false and nearly every cell
of a btop frame drops to the per-cell CTLine path -- reinstating exactly the
per-cell cost structure doc 3 removed for cells the primary font covers.

## Optimization objective

Reduce the per-draw cost of full screens dominated by fallback-resolved
single-scalar symbols (braille, box drawing, block elements) toward the
~0.32 ms fast-path level established in doc 3, without changing rendered
output. Constraints carried forward from doc 3:

- Stateless within a frame: per-frame hoisting is allowed; cross-frame caches
  remain deferred.
- Correctness net: the renderer execution test suite (34 tests including
  bitmap fixtures) plus the UI harness.
- Performance claims come only from compatible, unprofiled
  `just benchmark-redraw` runs. Profiles locate work; they do not establish
  improvements.

The existing churn workloads do not exercise cmap-miss characters, so this
sweep is currently invisible to `just benchmark-redraw`. A symbol-heavy
serialized workload is a prerequisite for making claims.

## Hypotheses

1. **Cmap miss is the trigger.** btop's braille/box-drawing/block characters
   are absent from the primary font, and that absence -- not multi-scalar
   content or wide cells -- is what routes them to the CTLine fallback.
   Falsifiable by logging which characters fail
   `CTFontGetGlyphsForCharacters` and checking the primary font's coverage
   directly.
2. **Per-cell fixed overhead dominates again, not glyph complexity.** As in
   doc 3, the cost is CTLine construction and its per-cell ICU
   `NeedsShapingForGlyphs` walk, not drawing braille outlines. Falsifiable
   claim: batching fallback cells into per-run `CTFontDrawGlyphs` calls
   against a per-run resolved fallback font reduces per-draw time on a
   symbol-churn workload by more than 80% (from a per-cell-CTLine level near
   the doc 3 baseline toward the fast-path level).
3. **Per-run fallback resolution is cheap enough to stay stateless.** One
   `CTFontCreateForString` (or `CTFontCreateForStringWithLanguage`) per
   fallback run per frame, followed by one `CTFontGetGlyphsForCharacters`
   retry and one `CTFontDrawGlyphs`, costs far less than the per-cell CTLine
   path it replaces. If per-run font resolution turns out to dominate, that
   is evidence for promoting resolution to frame scope (still stateless), and
   only failing that would a cross-frame cache be on the table.

## Tasks

- [ ] **Task 1: verify the trigger.** Instrument or test which btop-emitted
  characters fail `CTFontGetGlyphsForCharacters` against the configured
  primary font (braille U+2800-28FF, box drawing U+2500-257F, blocks
  U+2580-259F expected). Confirm whether the misses are genuine cmap
  absences or a fast-path rejection for another reason (wide-cell or
  multi-scalar conditions). If the font actually covers them and the fast
  path is rejecting them for a fixable reason, the fix is cheaper than
  hypothesis 2's plan; record that and re-plan.
- [ ] **Task 2: add a symbol-churn serialized workload.** Extend the redraw
  suite with a `full-screen-symbol-churn`-style fixture whose grid is
  dominated by braille/box-drawing cells, matching the existing suite's
  contract (one completed draw per submitted state, 24 dirty rows, 80x24,
  sequence metadata in the title). Record its unoptimized baseline with a
  compatible `just benchmark-redraw` run before any renderer change. The
  baseline should confirm the profile's prediction: symbol churn draws far
  slower than the ~0.32 ms content/style/mixed results.
- [ ] **Task 3: per-run fallback-font batching.** In the executor, group
  consecutive cmap-miss cells of a styled run into fallback runs; resolve one
  fallback font per run (`CTFontCreateForString` on the run's text), retry
  `CTFontGetGlyphsForCharacters` on it, and issue one `CTFontDrawGlyphs`.
  Cells that still miss, plus multi-scalar/combining-mark cells, keep the
  clipped per-cell CTLine path. TDD: bitmap fixtures asserting
  fallback-rendered symbols are pixel-identical (or accepted-overhang
  equivalent) before and after. Judge with compatible `just benchmark-redraw`
  runs on symbol churn plus the three existing workloads (which must not
  regress).
- [ ] **Task 4: re-profile btop.** Repeat the arrow-key-hold `sample` capture
  in an optimized build. Expect `CTLineCreateWithAttributedString` and the
  ICU `NeedsShapingForGlyphs` stack to be effectively absent and overall
  DanTerm CPU to drop substantially. Record hypothesis confirmed or rejected.

## Results

Not yet run. Update each task above with its evidence and compatible
before/after medians as it completes, then summarize the verdict on each
hypothesis here.
