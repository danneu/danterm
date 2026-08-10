# Fallback-glyph batching for symbol-heavy screens

Research date: 2026-07-23. **Status: CLOSED 2026-07-28. All four tasks done.**
The chosen direction -- DanTerm-owned procedural sprites rather than batched
fallback glyphs -- shipped across eight families and removed the CTLine path
from the motivating btop workload entirely (confirmed by `13/F1`). H3, stateless
fallback batching, was never needed and keeps its revival trigger. See
"Outcome"; read [6-sprite-classification-regression.md](6-sprite-classification-regression.md)
and doc 11's Outcome for what the sprite path cost.

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
~0.32 ms fast-path level established in doc 3, without compromising terminal
rendering correctness. Constraints carried forward from doc 3:

- Stateless within a frame: per-frame hoisting is allowed; cross-frame caches
  remain deferred.
- Correctness net: the renderer execution test suite (34 tests including
  bitmap fixtures) plus the UI harness.
- Performance claims come only from compatible, unprofiled
  `just benchmark-redraw` runs. Profiles locate work; they do not establish
  improvements.

The redraw suite now carries two symbol workloads with separate questions:

- `full-screen-symbol-churn-v1-btop-symbol-mix-80x24` is the standing
  regression for the measured btop case.
- `full-screen-sprite-coverage-churn-v1-curated-candidates-80x24` is the
  broader coverage workload for explicit sprite candidate sets.

Neither identity replaces the other. The first answers whether DanTerm fixed
the motivating workload; the second prevents broad sprite work from being
judged only against braille.

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
   claim: after the braille sprite increment,
   `CTLineCreateWithAttributedString` falls below 5% of main-thread samples in
   the btop re-profile, and the standing btop-shaped workload falls from its
   30,003,225 ns/draw baseline to at most 636,060 ns/draw (within 2x the
   compatible 318,030 ns/draw ordinary content-churn result). That requires a
   reduction of at least 97.88% from the btop-shaped baseline. The generic
   coverage workload retains its own compatible baseline and is not a
   substitute for this regression target.
3. **Per-run fallback resolution is cheap enough to stay stateless.** One
   `CTFontCreateForString` (or `CTFontCreateForStringWithLanguage`) per
   fallback run per frame, followed by one `CTFontGetGlyphsForCharacters`
   retry and one `CTFontDrawGlyphs`, costs far less than the per-cell CTLine
   path it replaces. If per-run font resolution turns out to dominate, that
   is evidence for promoting resolution to frame scope (still stateless), and
   only failing that would a cross-frame cache be on the table.

## Chosen direction: DanTerm-owned sprite glyphs

Task 1's distribution and the Ghostty reference changed the chosen mechanism.
The measured fallback traffic is overwhelmingly width-one braille: specified
2x4 dot geometry rather than typography. Box drawing and block elements have
the same terminal-cell property, while only a curated subset of the adjacent
geometric-shapes block is suitable for procedural drawing. Ghostty's own
implementation explicitly warns that full U+25A0-25FF coverage is not its
goal.

DanTerm will therefore recognize an explicit supported-scalar set before font
lookup and draw those scalars procedurally. It must never classify an entire
neighboring Unicode block merely because some members are viable sprites.
Ordinary mapped text, non-sprite cmap misses such as the observed bold U+21B5,
multi-scalar cells, and supplementary-plane content retain the font paths.

The first increment is executor-local braille classification. Existing
`RenderTextRun` values already carry the row, columns, resolved foreground,
and exact cell scalars needed to choose between:

```text
supported sprite scalar -> procedural draw
ordinary mapped scalar  -> CTFontDrawGlyphs
everything else         -> CTLine fallback
```

This attacks about 99.84% of the observed btop fallback entries without adding
a retained sprite layer, a planning-module dependency, or new clip/equality
state. A separate sprite layer remains a future option only if profiling or
an atlas design demonstrates that it earns those architectural costs.

Box drawing and block elements are the next correctness-oriented increment:
procedural geometry makes adjacent cells meet exactly at their edges.
Geometric shapes remain a curated later extension. Sprite output intentionally
differs from font-rendered output for supported scalars, so focused bitmap
fixtures become the rendering contract for each increment.

General fallback-font batching is deferred. Its revival trigger is a profiled
real workload dominated by non-sprite cmap misses, such as CJK-heavy output in
a non-covering font, with per-cell CTLine construction hot again.

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

  This remains the standing deterministic regression for the measured btop
  problem. The real-btop profile closes the loop, but does not replace this
  repeatable workload.
- [x] **Task 2b: add and baseline a distinct generic sprite-coverage workload.**
  Add `full-screen-sprite-coverage-churn` under fixture identity
  `full-screen-sprite-coverage-churn-v1-curated-candidates-80x24`. Its four
  equally represented candidate sets are box drawing, block elements,
  braille, and the explicit geometric-shape subset U+25E2-25E5,
  U+25F8-25FA, and U+25FF. The set is deliberately enumerated; it does not
  claim that all of U+25A0-25FF belongs on the sprite path. Contract tests pin
  both symbol workloads independently so coverage work cannot replace the
  btop regression again.

  **Result (2026-07-23): complete.** The compatible unprofiled run used 15
  fresh optimized app batches and 25 serialized completed draws per batch
  (375 measured draws total):

  | Metric | Minimum | Median | Maximum |
  |---|---:|---:|---:|
  | Nanoseconds per draw | 20,458,081 | 20,745,788 | 21,255,291 |
  | Cumulative draw time per batch | 511,452,042 | 518,644,707 | 531,382,295 |

  Every batch reported exactly 25 completed draws and every draw damaged all
  24 rows. The result is saved in
  `benchmarks/results/terminal-redraw.jsonl` with comment
  `font-rendered-sprite-coverage-baseline`.

  The earlier
  `full-screen-symbol-churn-v2-geometric-sprite-mix-80x24` result remains
  closed history: it exercised the entire U+25A0-25FF block and therefore
  cannot serve as the baseline for this corrected fixture.
- [x] **Task 3: executor-local braille sprites. SHIPPED.** Recognize U+2800-28FF
  inside existing text runs before primary-font lookup and draw their 2x4 dot
  geometry procedurally. Unsupported scalars continue unchanged through the
  mapped-glyph or CTLine paths. Geometry generation is pure and unit-testable;
  fills batch per run. TDD: bitmap fixtures at scale 1 and scale 2 establish
  dot placement, clipping, foreground, selection, cursor, and damage
  correctness; an explicit supported-set test prevents accidental
  whole-block classification elsewhere. Judge with compatible
  `just benchmark-redraw` runs on both symbol workloads plus the three
  ordinary workloads, which must not regress.

  **Result: landed, and the architecture generalized further than this task
  scoped.** The executor-local sprite path now covers **eight families**, not
  just braille -- box drawing, block elements, braille, powerline, geometric
  shapes, branch drawing, legacy computing, and legacy computing supplement --
  each with pure geometry in `lib/TerminalCore/Sources/TerminalSpriteGeometry`
  and behavioral suites in `TerminalSpriteGeometryTests` +
  `TerminalRenderExecutionTests`, exactly the split this task asked for. The
  contract is documented in [docs/terminal-sprites.md](../terminal-sprites.md).

  **Read [6-sprite-classification-regression.md](6-sprite-classification-regression.md)
  before touching this path.** The series shipped two performance regressions
  that took a full investigation to find: per-cell classification walking an
  eight-family chain for sprite-free text (fixed by single-scalar routing,
  `a785d45`), and a `BraillePixelLayout` refactor allocating two `[Int]` arrays
  per braille cell (fixed by building it lazily once per draw, `d19103f`). Both
  are the cost of the generality above.
- [x] **Task 3b: seamless box-drawing and block-element sprites. SHIPPED** as
  part of the same series -- see Task 3's result. Plan this
  correctness-oriented increment separately after braille proves the
  executor-local architecture. Mine `.ghostty-src/src/font/sprite/draw/` for
  pixel snapping and line-weight details; adjacent cells must join without
  seams at scale 1 and scale 2. Scope is an explicit supported-scalar set.
  Curated geometric shapes are a later extension, not a prerequisite.
- [x] **Task 4: re-profile btop. DONE, and the hypothesis is CONFIRMED.** Repeat
  the arrow-key-hold `sample` capture in an optimized build after the sprite
  path lands. Expect `CTLineCreateWithAttributedString` and the ICU
  `NeedsShapingForGlyphs` stack to be effectively absent and overall DanTerm CPU
  to drop substantially. This closes the loop on the motivating regression that
  the standing btop-shaped workload models. Record hypothesis confirmed or
  rejected.

  **Result: the exact capture this task specifies was taken by
  [13-live-app-compositing-and-draw-hotspots.md](13-live-app-compositing-and-draw-hotspots.md)**
  -- `sample` for 20 s in an optimized build while a person held the down-arrow
  scrolling btop's process list (`13/F1`). **The prediction holds:
  `CTLineCreateWithAttributedString` and `NeedsShapingForGlyphs` do not appear
  anywhere in that profile.** The per-cell CTLine fallback path this file was
  opened to remove is gone from the motivating workload.

  **What replaced it is the part this task could not have predicted, and it is
  why the loop closes here rather than continuing.** With CTLine gone, the btop
  draw is dominated by `drawTextRuns` -- and doc 13's Phase 2 optimizations then
  cut that subtree by 30% without the main thread getting faster, because the
  binding constraint had moved to CoreAnimation compositing (`13/F10`). Doc 11
  finished the accounting: at real 179x66 geometry a full-frame sprite draw is
  ~8.5 ms against a 16.7 ms budget, **71.5% of it inside `CGContextFillRects`**
  (`11/F10`) -- i.e. rasterizing the sprite rects this file's chosen direction
  introduced. That is a good trade and it is also the new floor. See doc 11's
  Outcome before proposing further work on this path.

## Results

- **Hypothesis 1 -- confirmed for the captured btop workload.** Its fallback
  traffic is entirely width-one BMP cmap misses and overwhelmingly regular
  braille resolving to `AppleBraille`; multi-scalar and supplementary-plane
  content do not explain the hot CTLine path. The smaller bold U+21B5
  population remains an ordinary non-sprite fallback.
- **Hypothesis 2 -- fallback cost confirmed; sprite result pending.** The
  btop-shaped baseline proved symbol churn is 94.3x ordinary content churn,
  so per-cell fallback cost dominates. That workload remains the grounded
  performance target. The generic coverage workload has a separate baseline
  and guards breadth rather than replacing the motivating regression.
- **Hypothesis 3 -- deferred for non-sprite fallback.** Supported sprites need
  no fallback-font resolution. Stateless fallback batching returns only if a
  later profile finds non-sprite cmap misses dominating real output.

## Outcome

**Closed 2026-07-28. All four tasks are done and every hypothesis is
resolved.** The file asked how to cut main-thread CPU when the screen is
dominated by characters the primary font's cmap misses. The answer was not to
batch fallback glyphs but to stop needing them: DanTerm draws those characters
itself.

- **H1 confirmed** (Task 1). btop's fallback traffic is *entirely* width-one BMP
  cmap misses -- 284,611 entries over 5.4M examined cells, zero multi-scalar,
  zero supplementary-plane, zero wide. U+28C0 alone was 252,836 of them. That
  census is what ruled out three of the four pivots this file had prepared, and
  it cost one instrumented run.
- **H2 confirmed** on cost, then **superseded on remedy.** Symbol churn measured
  94.3x ordinary content churn, so per-cell fallback cost did dominate. The
  chosen direction -- DanTerm-owned procedural sprites -- shipped across eight
  families and removed the CTLine path from the motivating workload outright
  (Task 4).
- **H3 rejected in practice, with its revival trigger intact.** Stateless
  fallback batching was never built and is not needed: supported sprites require
  no fallback-font resolution at all. It returns only if a profile finds
  *non-sprite* cmap misses dominating real output. Nothing since has.

**The follow-on cost is real and is documented elsewhere, not here.** Procedural
sprites introduced two performance regressions (doc 6) and moved the draw path's
dominant cost into `CGContextFillRects` rasterizing the rects they emit -- 71.5%
of a full-frame sprite draw (`11/F10`). Doc 11 established that this still fits
the frame budget with room. Anyone revisiting the sprite/fallback tradeoff
should start at doc 11's Outcome and doc 6, not at this file.

**Reopening condition:** a profile shows non-sprite cmap misses dominating real
output -- H3's stated trigger, unchanged.

## Stopping point

**Historical -- this section records the state at 2026-07-23, when the file
paused before implementation. All of it has since happened; see Outcome.**

Research and benchmark contracts now support the next decision without
committing to a broad sprite subsystem:

- the btop regression and generic coverage workloads coexist under distinct
  names and immutable fixture identities;
- sprite membership is explicit, with no whole-geometric-block assumption;
- the first implementation experiment is executor-local braille drawing;
- a new retained frame layer requires future profiling or atlas evidence;
- general fallback-font batching remains available behind a concrete revival
  trigger.

The next work is a focused plan for task 3, not implementation from this
research document. **That happened: task 3 was planned, implemented, and
generalized to eight sprite families. See Outcome above.**
