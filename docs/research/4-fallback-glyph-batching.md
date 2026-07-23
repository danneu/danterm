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
  resource-bundle lookups): ~1,600 samples. The per-cell CTLine path
  repeatedly enters CoreText's font/language shaping checks; `sample` gives
  time-in-stack, not invocation counts, so confirming the per-cell invocation
  frequency requires instrumentation (task 1).
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
   are absent from the configured font's cmap, and that absence -- not
   multi-scalar content or wide cells -- is what routes them to the CTLine
   fallback. The configured font is itself evidence: record the PostScript
   name of all four trait variants (regular, bold, italic, bold-italic) and
   attribute each miss to a `(font variant, scalar)` pair, since a symbol may
   map in the regular face but miss in a synthesized trait variant.
   Falsifiable by task 1's categorized miss counters plus a direct coverage
   check of the primary font.
2. **Per-cell fixed overhead dominates again, not glyph complexity.** As in
   doc 3, the cost is CTLine construction and its per-cell ICU
   `NeedsShapingForGlyphs` walk, not drawing braille outlines. Falsifiable
   claim: after batching fallback cells into per-run `CTFontDrawGlyphs` calls,
   `CTLineCreateWithAttributedString` falls below 5% of main-thread samples in
   the task 4 re-profile, and symbol churn falls from its 30,003,225 ns/draw
   baseline to at most 636,060 ns/draw (within 2x the compatible 318,030
   ns/draw ordinary content-churn result). That requires a reduction of at
   least 97.88% from the symbol baseline.
3. **Per-run fallback resolution is cheap enough to stay stateless.** One
   `CTFontCreateForString` (or `CTFontCreateForStringWithLanguage`) per
   fallback run per frame, followed by one `CTFontGetGlyphsForCharacters`
   retry and one `CTFontDrawGlyphs`, costs far less than the per-cell CTLine
   path it replaces. If per-run font resolution turns out to dominate, that
   is evidence for promoting resolution to frame scope (still stateless), and
   only failing that would a cross-frame cache be on the table.

## Pivot (2026-07-23): DanTerm-owned sprite glyphs

Task 1's distribution and the Ghostty reference changed the chosen mechanism.
The fallback population is entirely spec-defined geometry (braille, with box
drawing/blocks/geometric shapes as the adjacent ranges), and these ranges are
specified shapes -- a fixed 2x4 dot grid, edge-connecting lines, cell fills --
not typography. Ghostty, kitty, Alacritty, and iTerm2 all draw them
procedurally, checked before any font lookup
(`.ghostty-src/src/font/sprite/`), because procedural drawing is both faster
than any font path (no CoreText at all) and more correct (exact cell fit, no
hairline gaps between adjacent cells, no dependence on installed fallback
fonts).

DanTerm adopts the same approach: a sprite path for braille, box drawing,
block elements, and geometric shapes, resolved before font lookup in the
executor. Consequences for this document:

- Tasks 3a/3b (per-run fallback-font batching) are superseded, not deleted.
  Their design notes remain below as the deferred general-case mechanism,
  with an explicit revival trigger: a profiled real workload dominated by
  non-sprite cmap misses (for example CJK-heavy screens in a non-covering
  font) showing per-cell CTLine hot again.
- Task 2's workload pivots to v2: the btop-weighted mix overfits the yardstick
  to braille, while the regression question ("is btop fixed?") is already
  answered by task 4's real-btop re-profile. The standing benchmark should
  instead churn all sprite-candidate ranges so a partial sprite
  implementation cannot ace it. The committed btop-mix baseline stays in
  `benchmarks/results/terminal-redraw.jsonl` as a closed historical record.
- Hypothesis 2's grounded target must be re-based on the v2 workload's
  font-rendered baseline once recorded; the 94.3x fallback-cost evidence from
  the v1 baseline stands on its own.
- Sprite output intentionally differs from font-rendered output for these
  ranges (better cell fit). Existing bitmap fixtures containing these
  characters get deliberately re-baselined, and new sprite fixtures become
  the rendering contract.

## Tasks

- [x] **Task 1: verify the trigger.** Instrument the executor with aggregate
  counters (not per-cell logging, which drowns the signal) that classify
  every fallback entry by one mutually exclusive reason:
  - BMP cmap miss
  - multi-scalar cell
  - supplementary-plane scalar

  Record styled font variant and cell width (one or two columns) as
  cross-cutting dimensions. For each unique `(font variant, BMP scalar)` cmap
  miss, resolve a fallback font once while diagnostics are enabled and record
  its PostScript name plus whether that resolved font returns a nonzero glyph;
  failure after fallback resolution is a secondary outcome, not an entry
  reason in today's renderer. Bound the scalar report to the hottest entries
  and emit compact cumulative summaries periodically rather than writing from
  every cell.

  Gate the probe behind an opt-in environment variable so ordinary rendering
  and benchmark runs do not pay for it. Record the PostScript names of the
  four primary trait variants alongside the counters, and cross-check the hot
  scalars (braille U+2800-28FF, box drawing U+2500-257F, blocks U+2580-259F
  expected) against those exact fonts directly. Run the probe in an optimized
  build while scrolling btop's process list. This is a diagnostic run; its
  numbers never enter benchmark history.

  Pivot criteria: if the symbols are covered by the primary font and the fast
  path rejects them for a fixable reason, fix that instead; if the symbols
  resolve through a stable already-available cascade font, batch by resolved
  font; if the dominant fallback reason is multi-scalar content, supplementary
  content, or wide cells, pivot away from BMP cmap-miss batching because the
  proposed mechanism would not attack the observed cost.

  **Result (2026-07-23): confirmed.** An optimized Swift-backend btop run
  scrolled the process list while an opt-in executor probe accumulated 480
  drawn frames. Its final report counted 5,426,258 examined text cells and
  284,611 fallback entries (5.25%). Every fallback was a width-one BMP cmap
  miss: 284,153 regular and 458 bold, with zero multi-scalar,
  supplementary-plane, or wide-cell entries.

  The configured primary faces were
  `.AppleSystemUIFontMonospaced-Regular`,
  `.AppleSystemUIFontMonospaced-Semibold`,
  `.AppleSystemUIFontMonospaced-RegularItalic`, and
  `.AppleSystemUIFontMonospaced-SemiboldItalic`. The hot misses were braille:
  U+28C0 alone accounted for 252,836 entries, followed by U+28FF (8,246),
  U+2880 (4,809), U+28E4 (4,784), and other U+2800-28FF scalars. Every
  observed regular braille miss resolved to `AppleBraille` and returned a
  nonzero glyph. The only material non-braille miss in the top entries,
  bold U+21B5 (458), resolved to `Menlo-Bold` and also mapped successfully.

  This rules out the multi-scalar, supplementary-plane, and wide-cell pivots
  for the captured workload. It also establishes the favorable batching
  shape: btop's dominant fallback population resolves through one stable font
  (`AppleBraille`), with a much smaller styled population resolving through a
  second font. The temporary probe was removed after recording this evidence;
  `/tmp/danterm-fallback-glyphs.txt` remains a diagnostic artifact, not
  benchmark history.
- [x] **Task 2: add a symbol-churn serialized workload.** Extend the redraw
  suite with a `full-screen-symbol-churn`-style fixture whose grid is
  dominated by braille/box-drawing cells, matching the existing suite's
  contract (one completed draw per submitted state, 24 dirty rows, 80x24,
  sequence metadata in the title). Record its unoptimized baseline with a
  compatible `just benchmark-redraw` run before any renderer change. The
  baseline should confirm the profile's prediction: symbol churn draws far
  slower than the ~0.32 ms content/style/mixed results.

  **Result (2026-07-23): confirmed.** The committed-history workload identity
  is `full-screen-symbol-churn-v1-btop-symbol-mix-80x24`. Every 80x24 frame
  uses all 79 safely writable columns: 1,706 braille cells (90%) and 190
  box-drawing cells (10%). Symbols change deterministically with each
  sequence while row styles stay fixed, and the sequence marker remains in
  the terminal title. Contract tests pin the Unicode cell count, symbol mix,
  content churn, fixed styling, no scrolling/autowrap, and workload selection.

  The compatible unprofiled run used 15 fresh optimized app batches and 17
  serialized completed draws per batch (255 measured draws total):

  | Metric | Minimum | Median | Maximum |
  |---|---:|---:|---:|
  | Nanoseconds per draw | 29,450,703 | 30,003,225 | 30,533,931 |
  | Cumulative draw time per batch | 500,661,959 | 510,054,832 | 519,076,836 |

  Every batch reported exactly 17 completed draws and every draw damaged all
  24 rows. The result is saved in
  `benchmarks/results/terminal-redraw.jsonl` with comment
  `unoptimized-fallback-glyph-baseline`. Its 30.003 ms median is 94.3x the
  compatible 318,030 ns/draw ordinary content-churn result, decisively
  confirming that the workload exposes the fallback path rather than the
  existing fast path. The Hypothesis 2 target is therefore grounded at
  636,060 ns/draw (at most 2x ordinary content churn), a required 97.88%
  reduction.

  **Pivot note (2026-07-23):** the v1 btop-mix workload and its baseline are
  now a closed record (see the pivot section). Task 2v2 below replaces it as
  the standing symbol benchmark.
- [ ] **Task 2v2: pivot the symbol workload to a generic sprite-range mix.**
  Replace the btop-weighted generator with a curated deterministic churn
  across all sprite-candidate ranges -- box drawing (U+2500-257F), block
  elements (U+2580-259F), geometric shapes (U+25A0-25FF), and braille
  (U+2800-28FF) -- under a new fixture identity (for example
  `full-screen-symbol-churn-v2-geometric-sprite-mix-80x24`). Re-pin the exact
  scalar set, cell counts, content churn, fixed styling, and identity in
  contract tests. Record the v2 font-rendered baseline with a compatible
  unprofiled `just benchmark-redraw` run before any renderer change, then
  re-ground hypothesis 2's target against it (same form: at most 2x ordinary
  content churn, CTLine below 5% of main-thread samples).
- [ ] **Task 3: sprite glyph path.** Draw braille, box drawing, block
  elements, and geometric shapes procedurally in the executor, classified
  before font lookup so sprite ranges never enter
  `CTFontGetGlyphsForCharacters` or the CTLine fallback. Geometry generation
  is pure and unit-testable; fills batch per run. Mine
  `.ghostty-src/src/font/sprite/draw/` for the pixel-snapping and
  line-weight details (adjacent cells must join without seams at scale 1 and
  scale 2). TDD: sprite bitmap fixtures at both scales become the new
  rendering contract, replacing font-rendered expectations for these ranges;
  add a randomized full-screen pressure test (seeded, deterministic) that
  churns cells across every implemented sprite scalar and asserts the
  executor's invariants hold. Judge with compatible `just benchmark-redraw`
  runs on symbol churn v2 plus the three existing workloads (which must not
  regress). Detailed sprite-system planning happens in its own plan file
  before implementation.
- ~~**Task 3a: metric-equivalence characterization test.**~~
  **Superseded by the sprite pivot.** The CTLine-equivalence question no
  longer gates anything: sprite output is intentionally different rendering,
  pinned by its own fixtures. Original text kept for the record below.
  Before touching
  the executor, add a focused test comparing CTLine's resolved glyph, font,
  and placement against the proposed direct path (resolved fallback font +
  existing baseline offset + `CTFontDrawGlyphs`) for braille, box drawing,
  and block elements at scale 1 and scale 2. CTLine may apply the fallback
  font's own metrics or baseline behavior that direct drawing does not
  reproduce automatically; this test decides whether pixel-identical is an
  achievable contract for task 3b's fixtures or whether a documented
  placement delta must be accepted instead.
- ~~**Task 3b: per-run fallback-font batching.**~~ **Superseded by the
  sprite pivot; deferred, not deleted.** Revival trigger: a profiled real
  workload dominated by non-sprite cmap misses (for example CJK-heavy
  screens in a non-covering font) showing per-cell CTLine hot again. The
  design below stays ready for that case. In the executor, group
  cmap-miss cells of a styled run into fallback runs: resolve a fallback
  font from the first unresolved cell (`CTFontCreateForString`), then extend
  the batch only while that font maps subsequent cells -- one resolved font
  must not be assumed to cover the whole styled run, and original column
  positions must be preserved when batching across resolved/unresolved gaps.
  Issue one `CTFontDrawGlyphs` per fallback run. Cells that still miss, plus
  multi-scalar/combining-mark cells, keep the clipped per-cell CTLine path.
  TDD: bitmap fixtures asserting fallback-rendered symbols match the
  contract task 3a established. Judge with compatible `just benchmark-redraw`
  runs on symbol churn plus the three existing workloads (which must not
  regress).
- [ ] **Task 4: re-profile btop.** Repeat the arrow-key-hold `sample` capture
  in an optimized build after the sprite path lands. Expect
  `CTLineCreateWithAttributedString` and the ICU `NeedsShapingForGlyphs`
  stack to be effectively absent and overall DanTerm CPU to drop
  substantially. This closes the loop on the motivating regression that the
  retired v1 btop-mix workload modeled. Record hypothesis confirmed or
  rejected.

## Results

- **Hypothesis 1 -- confirmed for the captured btop workload.** Its fallback
  traffic is entirely width-one BMP cmap misses, overwhelmingly regular
  braille resolving to `AppleBraille`; multi-scalar and supplementary-plane
  content do not explain the hot CTLine path.
- **Hypothesis 2 -- fallback cost confirmed; target pending re-grounding.**
  The v1 baseline proved symbol churn is 94.3x ordinary content churn, so
  per-cell fallback cost (not glyph complexity) dominates. The mechanism
  pivoted from fallback batching to the sprite path; the concrete target
  moves to the task 2v2 baseline once recorded (same form: at most 2x
  ordinary content churn, CTLine below 5% of main-thread samples).
- **Hypothesis 3 -- mooted by the pivot for sprite ranges.** Sprite drawing
  needs no fallback resolution at all. The stateless-resolution question
  only returns if the deferred task 3b revival trigger fires.
