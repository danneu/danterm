# CPU renderer optimization leads

Research started: 2026-07-29. **Status: OPEN -- survey complete, no code
candidate started.** Deliverable is the API inventory (`F1`), the decomposition
of the one decidable renderer bracket (`F4`-`F8`), and the ranked lead list
(`D1`). Nothing here has been implemented or benchmarked.
Continues: [17-cpu-profile-sweep.md](17-cpu-profile-sweep.md) (`17/F2`, `17/F3`,
`17/F6`, `17/F17`, `17/D8`), [11-render-frame-budget.md](11-render-frame-budget.md)
(`11/F7`, `11/F8`, `11/F10`).

## Purpose

Doc 17 re-took the project's whole-workload CPU map on an on-CPU instrument and
closed every candidate it ranked. Its headline result was structural, not a fix:
**the draw verdict brackets ~10.4% of a churn workload while Core Animation's
replay of that same draw costs ~23%** (`17/F2`, `17/F6`), and the largest node in
that blind spot turned out to be 29.3x smaller under a realistic stimulus
(`17/F17`), so `17/D8` closed it.

That leaves the question doc 17 did not ask. Doc 17 ranked *the whole app* and
the renderer lost, so the renderer was never decomposed. This file owns that
decomposition: **what exact API surface does DanTerm's CPU renderer use, what do
Apple's own docs and outside practice say about that surface, and what inside it
is worth taking.**

The strategic reason to look here rather than anywhere else in doc 17's map is
one doc 17 established but did not exploit: `drawNanosecondsPerDraw` is a frozen,
calibrated decision rule and it brackets **exactly** `clipFramePlan` +
`drawRenderFrame` (`agent-docs/terminal-performance.md`;
`app/SwiftTerminalSessionView.swift:143-168`). Doc 17's best candidate died
because no instrument here could decide it (`17/D7`, `17/F15`). Every lead in
`D1`'s top tier lands inside that bracket, so each one is decidable by a rule
that already exists and already has calibrated thresholds.

## Investigation rules

Inherited from doc 17 and non-negotiable:

- **On-CPU instrument only for ranking.** A `sample`-derived number may be cited
  as history, never as a size.
- **Convert a share to the deciding benchmark's own denominator before
  predicting a win** (`17/F9`, `17/F10`). Every size in `D1` is quoted as a
  percentage of the `drawRenderFrame` region, because that region is the draw
  verdict's denominator.
- **Frame subtraction ("region X minus region Y") is unsound when the callee is
  partially inlined** (`17/D5`). Where this file relies on parent/child
  attribution that inlining could distort, it says so in the finding.
- **No implementation of a code candidate before a user direction gate**, per
  `agent-docs/terminal-performance.md`.

Added here:

- **Never assert an API's behavior from memory.** Every claim about a CoreText,
  CoreGraphics, or AppKit API in `F1`-`F3` is quoted from the local SDK headers
  in `$(xcrun --show-sdk-path)` or from an Apple session transcript, with the
  header path recorded. This follows AGENTS.md's "Don't guess" boundary.
- **A candidate that lands outside the draw bracket must say which rule would
  decide it, or be ranked below every candidate inside it.** Doc 17 spent three
  findings and a calibration screen discovering that an off-bracket candidate is
  undecidable here (`17/F12`, `17/F15`, `17/D7`). That cost is not paid twice.
- **Batching leads must be sized per-call, not per-glyph.** `F6` is this file's
  own correction of an earlier reading in this same investigation: a lead that
  looked like 34% of the text path is ~7% once the per-glyph part is separated
  out, and the *real* per-call cost turned out to be somewhere else entirely.

## Task ledger

### Phase 1 -- inventory the surface before ranking it

- [x] Record the exact API the renderer calls, with call sites, and separate
      per-draw calls from once-per-metrics calls. **Done -- `F1`.**
- [x] Read what Apple's own headers and sessions constrain about that surface,
      from local SDK sources rather than memory. **Done -- `F2`.**
- [x] Survey outside practice and record what of it transfers. **Done -- `F3`.
      Its most useful output is negative: nothing found online sizes or names the
      display-list path `F5` measures.**

### Phase 2 -- decompose the one decidable bracket

- [x] Decompose `drawRenderFrame` against its own denominator. **Done -- `F4`,
      plus the self-frame census that sources every whole-process figure here.**
- [x] Establish what kind of work the bracket actually contains. **Done --
      `F5`, and it changes the unit of cost from pixels to display-list entries.**
- [x] Split per-call from per-glyph cost inside glyph drawing before sizing any
      batching candidate. **Done -- `F6`, which corrected this file's own first
      reading by ~4x and swapped the candidate it pointed at.**
- [x] Size the cmap path and the Swift-side costs. **Done -- `F7`, `F8`.**
- [x] Record what this workload cannot decide about run counts, with a
      pre-registered prediction. **Done -- `F9`.**

### Phase 3 -- rank and pitch

- [x] Rank by decidability first, size second; name each lead's risk and its
      smallest first experiment. **Done -- `D1`.**
- [x] Record what not to propose, and what this file deliberately declines.
      **Done -- `D2` and "Pre-rejected".**

### Phase 4 -- code-candidate direction gate

**Opened by user direction on 2026-07-29 for `L3` only.** Listed in `D1`'s
recommended order; each entry is one commit-sized candidate with its own paired
benchmark. Everything still unchecked below `L3` remains gated.

- [x] **`L3` -- guard the sprite switch** (`>= 0x2500`). ~5% of the bracket.
      First because it is a few lines, its guarding test outlives it, and its
      verdict tells us whether the draw rule can see a change of that size at
      all -- information every later lead needs. **Done -- `F10`. Landed as
      `spriteClassificationMinimumScalar` + `SpriteRoutingGuardTests`;
      `content-churn` `faster` -6.76%, `style-churn` `faster` -6.08%.**
- [ ] **`L2` -- memoize character-to-glyph mapping** per face. 10-14%. Largest
      low-risk item; correctness comes from `F2`'s header text, not a measurement.
- [ ] **`L1` -- batch glyph submission** by (face, color) across the damaged
      region. ~11%, and the only tier-1 lead whose *mechanism* the benchmark can
      confirm or refute, via `F9`'s prediction that `content-churn` and
      `style-churn` must diverge.
- [ ] **`L6` -- batch fills by color**, then **`L5` -- intern `CGColor`s and
      hoist the color space.** Sizes overlap `L1`'s; re-read the bracket between
      them rather than pitching a combined number.
- [ ] **Prerequisite for `L4`, not `L4` itself:** confirm or refute `F8`'s
      inlining attribution by ablation. `17/D5` retired a candidate sized exactly
      this way. Until this is done, 27% is a precondition and not a size.
- [ ] Optional tooling, not a decision rule: the per-draw run-count and
      glyph-call counters `F9` asks for, which would make `L1`/`L6` predictable
      in advance instead of only measurable afterwards.
- [ ] A fresh capture is **not** a precondition for the leads above, and here is
      why: `git diff --stat 4ecb032..HEAD -- lib/TerminalCore app` touches only
      `app/TerminalBenchmark.swift`, `TerminalCore/Terminal.swift`, and one test
      file. **`TerminalRenderExecution` and `TerminalRenderPlanning` are
      unchanged since the trace**, so `F4`'s bracket decomposition describes
      HEAD's renderer exactly. Take a capture when a lead's *own* prediction
      needs re-reading after it lands, or a `style-churn` capture if `L1` is
      taken (`F9`) -- not before starting.

Tier 2 and tier 3 leads (`L9`-`L15`) are deliberately absent from this ledger.
Tier 2 is available but unranked against tier 1 until tier 1 is spent; tier 3 has
no instrument that can score it and would need a new decision rule first.

## The renderer's exact API surface

### F1 -- API inventory

- Status: recorded. Verified by reading the source, not inferred.
- Date and investigator: 2026-07-29, Claude (agent).
- Commit: `8e9f538`.

DanTerm's CPU renderer is an immediate-mode CoreText/CoreGraphics executor that
draws inside `NSView.draw(_:)` on a layer-backed view. The complete API surface:

| API | Where | Role |
| --- | --- | --- |
| `NSFont.monospacedSystemFont(ofSize:weight:)` | `TerminalRenderExecution.swift:47` | base face selection |
| `CTFontCreateWithName` | `:48`, `:118` | face construction, once per metrics |
| `CTFontCreateCopyWithSymbolicTraits` | `:148` | bold / italic / bold-italic derivation |
| `CTFontGetAscent` / `Descent` / `Leading` / `XHeight` / `UnderlineThickness` / `UnderlinePosition` | `:55-89` | cell geometry, once per metrics |
| `CTFontGetAdvancesForGlyphs` | `:54` | cell width from `M`, once per metrics |
| `CTFontGetGlyphsForCharacters` | `:51`, `:635` | **per draw, per text run**: cmap character-to-glyph mapping |
| `CTFontDrawGlyphs` | `:659` | **per draw, per text run**: glyph submission |
| `CTLineCreateWithAttributedString` + `CTLineDraw` | `:884`, `:901` | fallback path only (multi-scalar clusters, non-BMP, unmapped glyphs) |
| `CGContext.fill(_ rect:)` | background / selection / search-match / decoration / cursor | one call per run |
| `CGContext.fill(_ rects:)` | sprite families | batched per color per run |
| `CGContext.setFillColor` / `setStrokeColor` / `setBlendMode` / `saveGState` / `restoreGState` / `clip(to:)` | throughout | state |
| `CGContext.textMatrix` | `:657` | y-flip for the flipped view |
| `CGColor(colorSpace:components:)` | `:326-338` | one allocation per color per run |
| `CGColorSpace(name: .sRGB)` | `:241` | **per draw** |
| `CGContext.beginPath` / `move` / `addLine` / `closePath` / `strokePath` | sprite geometry | box drawing, powerline, geometric shapes |

Structural facts that decide what the leads can be:

1. **A text run is per-row and per-(foreground, bold, italic)**
   (`TerminalRenderPlanning.swift:243-261`: `RenderTextRun` carries one `row`,
   one `startColumn`, one `foreground`, and `bold`/`italic` flags). So the number
   of `CTFontGetGlyphsForCharacters` + `CTFontDrawGlyphs` call pairs per draw is
   *rows x distinct styles per row*, not *distinct fonts*.
2. **No glyph cache exists.** Every draw re-maps every character through the
   font's cmap.
3. **No cross-draw color cache exists.** `drawTextRuns` builds a
   `[UInt32: CGColor]` dictionary per draw; the background, selection, and
   search-match loops have no cache at all and allocate a `CGColor` per run.
4. **The view is layer-backed** (`wantsLayer = true`,
   `SwiftTerminalSessionView.swift:99`) and does **not** override `isOpaque`,
   `wantsDefaultClipping`, or `layerContentsRedrawPolicy`, and does not call
   `getRectsBeingDrawn(_:count:)`.
5. **Invalidation is already per-row** (`:688-698`, one
   `setNeedsDisplay(NSRect)` per damaged row with a one-row halo), but `draw(_:)`
   consumes only the single union `dirtyRect`.
6. **The background is filled twice per draw.** `draw(_:)` fills `dirtyRect`
   (`:146-148`), then `drawRenderFrame` fills the *entire* frame rect
   (`TerminalRenderExecution.swift:250-251`) -- clipped by the `clip(to: dirtyRect)`
   at `:163`, so it is correct, but it is a second full-coverage fill entry.

### F2 -- what Apple's own documentation constrains

- Status: recorded. Quoted from local SDK headers; paths given so a reader can
  re-read them rather than trust this table.
- Source: `$(xcrun --show-sdk-path)/System/Library/Frameworks/`.

**`CoreText.framework/Headers/CTFont.h:1607-1633` (`CTFontDrawGlyphs`)** -- "This
function will modify the CGContext's font, text size, and text matrix if
specified in the CTFont. These attributes will not be restored." And: "The given
glyphs should be the result of proper Unicode text layout operations (such as
CTLine). Results from CTFontGetGlyphsForCharacters (or similar APIs) do not
perform any Unicode text layout."

  Two consequences. First, DanTerm is deliberately using this API against its
  documented guidance, and that is correct for a terminal: the grid *is* the
  layout, and `05-unicode-grid-scrollback.md` fixes cell advance from the grid,
  not from shaping. Second, the "will not be restored" clause is why
  `drawRenderFrame` saves and restores `textMatrix` by hand (`:244`, `:248`).

**`CTFont.h:820-846` (`CTFontGetGlyphsForCharacters`)** -- "This function only
provides the nominal mapping as specified by the font's Unicode cmap (or
equivalent)". A nominal cmap mapping is a **pure function of (face, UTF-16 code
unit)**. Nothing in the header makes it context-, position-, or state-dependent.
That is the entire correctness argument for memoizing it (lead `L2`).

**`CoreGraphics.framework/Headers/CGContext.h:860-863`
(`CGContextShowGlyphsAtPositions`)** -- "Draw `glyphs', an array of `count'
CGGlyphs, at the points specified by `positions'". This is the lower-level
alternative to `CTFontDrawGlyphs`, reached via `setFont(CGFont)` +
`setFontSize`. `F6` sizes what skipping the CoreText wrapper is actually worth.

**`CGContext.h:957-993`** -- four separate switches govern glyph positioning:
`ShouldSubpixelPositionFonts` and `ShouldSubpixelQuantizeFonts` are graphics
state; `AllowsFontSubpixelPositioning` and `AllowsFontSubpixelQuantization` are
not. Both halves of a pair must be true for the behavior to occur. A terminal
places every glyph at an integral pixel multiple by construction
(`TerminalRenderMetrics` quantizes cell width, height, and baseline to whole
pixels, `TerminalRenderExecution.swift:69-82`), so the subpixel machinery is
computing variants DanTerm cannot use. Same structure for
`ShouldSmoothFonts` / `AllowsFontSmoothing` at `:938-955`.

**`AppKit.framework/Headers/NSView.h:95-97, 239-263`** -- `getRectsBeingDrawn:count:`,
`needsToDrawRect:`, `wantsDefaultClipping`, `layerContentsRedrawPolicy`,
`wantsUpdateLayer`, `updateLayer`, `canDrawSubviewsIntoLayer` all exist and are
unavailable-free on the macOS 26 deployment target (`Package.swift:6`).

### F3 -- outside practice, and what of it applies

- Status: recorded. Survey, not evidence. Nothing here sizes a DanTerm node.

- **WWDC 2013 session 215, "Optimizing Drawing and Scrolling on OS X"**
  ([transcript](https://asciiwwdc.com/2013/sessions/215)) is the closest thing to
  an authoritative checklist for exactly DanTerm's configuration (layer-backed
  `NSView` with a `draw(_:)` implementation). Four of its items are unadopted
  here and map to `F1`'s items 4-6: enumerate `getRectsBeingDrawn:count:` rather
  than redrawing the union; return `YES` from `isOpaque` (it "transfers directly
  to the backing Core Animation layer"); override `wantsDefaultClipping` to `NO`
  when all drawing is already constrained to the requested rects; set
  `layerContentsRedrawPolicy` to `NSViewLayerContentsRedrawOnSetNeedsDisplay`.
- **iTerm2's own documentation** states that ligature rendering goes "through
  CoreText, which is significantly slower than Core Graphics"
  ([iTerm2 fonts docs](https://iterm2.com/documentation-fonts.html)), i.e. the
  same CoreText-wrapper-versus-`CGContextShowGlyphsAtPositions` distinction
  `F2` names. iTerm2's answer to CPU text cost was ultimately a Metal renderer
  ([iTerm2 news](https://iterm2.com/news.html)), with its author quoted at "over
  150ms to draw a single frame for a 4k display" on the CoreText path.
- **Every fast terminal named in the survey answers this with a GPU glyph
  atlas** -- rasterize each (glyph, style) once into a texture atlas, then draw
  textured quads
  ([GPU-accelerated terminals](https://datadaily.news/modern-terminal-emulators-gpu-accelerated/),
  [Warp on glyph atlases](https://www.warp.dev/blog/adventures-text-rendering-kerning-glyph-atlases)).
  This is `09-renderer.md`'s explicitly deferred option, and it is not a lead in
  this file. What *is* transferable is the atlas's underlying insight, and it is
  the one thing all of `D1`'s top tier has in common: **per-glyph work that does
  not depend on the frame should not be repeated per frame.**
- Nothing found online sizes or even names CoreGraphics' display-list recording
  path (`F5`), which is where a large share of this renderer's cost actually is.
  Two searches returned only generic CALayer material. Treat `F5`-`F7` as
  original to this file and verify them before trusting them.

## Findings log

Provenance for every number in `F4`-`F8`: re-analysis of the **existing**
`full-screen-content-churn` Time Profiler artifact from `17/F1`
(`.build/terminal-benchmark-profiles/2026-07-29-175854-23359/profile-folded.txt`,
18,008 ms on-CPU, taken at `4ecb032`). No new capture was taken. Shares are
inclusive weight of stacks containing the named frame. **The artifact directory
is disposable**; every decision-bearing number is transcribed here.

Two inherited caveats bind all of it. First, one capture, no replicate
(`17/F1`). Second, loop profiling mode forces a republished full-viewport redraw,
so per-frame glyph counts sit at maximum (`17`, caveats). The second caveat is
weaker here than in doc 17 because these findings are **ratios inside the draw
bracket**, and the bracket's own contents scale together with glyph count -- but
`L6`'s and `L7`'s sizes do depend on the run-count distribution the stimulus
produces, and `F9` says so.

### F4 -- the draw bracket, decomposed

- Status: recorded. This is the file's baseline table.
- Denominator: the `drawRenderFrame` region = **1,879 ms**, 10.43% of the
  workload's on-CPU total. This is the draw verdict's own denominator, minus
  `clipFramePlan`, which is 0.00% on this workload because damage is full.

| node | ms | % of draw bracket | % of workload |
| --- | ---: | ---: | ---: |
| **`drawRenderFrame` (whole bracket)** | **1,879** | **100.0%** | **10.43%** |
| `drawTextRuns` | 1,049 | 55.8% | 5.84% |
| &nbsp;&nbsp;`CTFontDrawGlyphs` (all inclusive) | 359 | 19.1% | 2.01% |
| &nbsp;&nbsp;`CTFontGetGlyphsForCharacters` | 301 | 16.0% | 1.67% |
| &nbsp;&nbsp;&nbsp;&nbsp;cmap `TFormat4UTF16cmapTable::MapT` | 261 | 13.9% | 1.45% |
| &nbsp;&nbsp;`RangeExpression.contains` protocol witness | 98 | 5.2% | 0.54% |
| &nbsp;&nbsp;`RenderColor.cgColor(in:)` | 77 | 4.1% | 0.43% |
| &nbsp;&nbsp;`TerminalScalars.Storage` copy + consume | 63 | 3.4% | 0.35% |
| &nbsp;&nbsp;`Dictionary` set + get (the per-draw color cache) | 26 | 1.4% | 0.14% |
| `_ArrayBuffer.beginCOWMutation` (attributed directly to the bracket) | 269 | 14.3% | 1.49% |
| `CGContextFillRect` / `FillRects` | 261 | 13.9% | 1.45% |
| `Array.replaceSubrange` (attributed directly to the bracket) | 213 | 11.3% | 1.18% |
| `Array._createNewBuffer` | 28 | 1.5% | 0.16% |
| `CGGStateSetFillColor` | 19+8 | 1.4% | 0.15% |
| `CGColorSpaceCreateWithName` | 4 | 0.2% | 0.02% |

- Observation: the bracket's cost is **not** dominated by rasterization -- there
  is none in it, because the layer's context is a recorder (`F5`). It is
  dominated by four things: per-run CoreText calls (35% of the bracket), Swift
  array growth (27%), fill submission (14%), and color construction (5.5%).
- Inference: this is a renderer paying per-frame for work whose inputs did not
  change between frames. That framing, not any single node, is what `D1` ranks.
- **Companion self-frame census, same artifact.** Leaf-attributed weight over the
  whole workload, which is where every "% of the whole process" figure quoted
  later in this file comes from. The top app-relevant entries:
  `TGlyphOutlineDictionaryCache<>::Copy` **4.86%** (the largest single self frame
  in the app, and it is CA-side -- `L9`), `outlined consume of
  TerminalScalars.Storage` 2.09%, `Terminal.feed` 2.06%,
  `Terminal.recordDamage` 1.78%, `initializeWithCopy for DamageActionSnapshot`
  1.57%, `swift_isUniquelyReferenced_nonNull_native` **1.54%** (`L4`), cmap
  `MapT` 1.43% (`L2`), `CFRetain` 1.13% / `CFRelease` 1.00% /
  `___CFBasicHashFindBucket_Linear` 1.14%, `CGRectUnion` 0.81% and
  `CGRectApplyAffineTransform` 0.80% (display-list bbox accumulation -- `F5`),
  `CA::CG::DrawGlyphs::compute_dod_` 0.62% self, `TFPFont::GetGlyphIdealBounds`
  0.58% self. The inclusive shares for the CA-side nodes (`FillGlyphs` 3.47%,
  `OGL::GlyphCache` 2.12%, `TGlyphOutlineDictionaryCache` 10.05% inclusive) are
  **not re-derived here** -- they are `17/F3`'s, on this same artifact, and
  `17/F17` retired their magnitude as stimulus-inflated.

### F5 -- the layer's context is a display-list recorder, and that changes what "drawing" means here

- Status: **recorded and mechanically confirmed.** Original to this file.
- Method: frame-name census of the same folded profile.
- Measurements: the trace contains `CGDisplayListDrawInContextDelegate` (115
  occurrences), `DisplayList::executeEntries` (115), `DisplayListEntry` (308),
  `DisplayListResourceColor` (264), `DisplayListRecorder::getPathColorResources...`
  (44), `DisplayListEntryStateFill` (88). `CGDisplayListDrawInContextDelegate` is
  1.36% of the workload inclusive; `DisplayList::executeEntries` is 1.34%.
- Observation: the `CGContext` AppKit hands `draw(_:)` for a layer-backed view
  **records a CoreGraphics display list**; the list is replayed later, on Core
  Animation's thread pool, which is where `17/F6`'s glyph-bounds node lives.
  DanTerm's draw therefore does no rasterization at all: it *records*.
- Inference 1: this is the mechanism behind `17/F1`'s structural surprise (53.6%
  of on-CPU time off the main thread) and behind `17/F2`'s "the largest region in
  the app is in no benchmark bracket". Doc 17 observed both and named neither
  cause.
- Inference 2: **inside the bracket, cost is per display-list entry, not per
  pixel.** `F6` and `F7` are the two measurements that follow from taking that
  seriously, and they are what makes call-count reduction (`L1`, `L6`) the
  leading lead rather than a micro-optimization.
- Uncertainty: whether CoreGraphics chooses the recorder unconditionally for
  layer-backed views on macOS 26, or heuristically per draw. Not established. If
  heuristic, the ratio in `F6` could differ on a draw that takes the
  rasterizing path. **A candidate resting on `F5` should assert the mechanism in
  a test that does not depend on which context CG picked** -- for `L1` and `L6`
  that is easy, because both are also plain call-count reductions.

### F6 -- 59% of glyph-drawing cost is per-call, not per-glyph -- and the earlier reading of this node was wrong

- Status: recorded. **This finding is a correction made inside this
  investigation, before any code was written.** It is recorded rather than
  quietly fixed because the discarded reading is the obvious one and a future
  agent will re-derive it.
- The discarded reading: `CTFontDrawGlyphs` is 34.1% of `drawTextRuns`, and
  `CGContextShowGlyphsAtPositions` is 0.011% of the workload, so "CoreText's
  wrapper is ~34% of the text path and bypassing it is the top lead."
- Why it is wrong: the wrapper's chain is
  `CTFontDrawGlyphs` -> `DrawGlyphsAtPositions` (95.3%) ->
  `EnumerateOverlappingGlyphs` (93.2%) -> block (97.6%) -> `draw_glyphs` (98.2%)
  -> `CGContextDelegateDrawGlyphs` (99.4%). Over 85% of the wrapper's time
  *reaches the context delegate*. The wrapper is a pass-through, not the cost.
  `CGContextShowGlyphsAtPositions` reads as ~0 because the recorder path enters
  the delegate directly, bypassing the public symbol -- **not** because glyph
  submission is free.
- Measurements, restricted to stacks containing `drawTextRuns` (subtree 1,049 ms):
  `dlRecorder_DrawGlyphs` 284 ms (27.0% of `drawTextRuns`);
  `CGFontRenderingGetCustomAntialiasingStyle` 24 ms (2.3%). Residual CoreText
  wrapper overhead is therefore about 359 - 284 - 24 = **51 ms, ~4.9% of
  `drawTextRuns`** and ~2.7% of the bracket.
- Then, decomposing the 284 ms recorder call itself:

  | child of `dlRecorder_DrawGlyphs` | % of its 284 ms | per what |
  | --- | ---: | --- |
  | `DisplayList::colorResourceForColor(CGColor*)` | 29.2% | per entry |
  | `DisplayListEntryGlyphs::setGlyphsAndPositions` | 19.4% | **per glyph** |
  | `DisplayList::getEntryFillState` | 12.3% | per entry |
  | `DisplayList::getEntryDrawingState` | 7.0% | per entry |
  | `appendEntry` + bbox/stroke adjust + misc | ~7.6% | per entry |
  | recursion / unattributed | 24.3% | -- |

- Observation: **48.5% of the recorder's cost is per-entry color and state
  construction; 19.4% is the glyph payload copy.** Adding the wrapper residual
  and the antialiasing-style lookup, the per-call component of glyph drawing is
  roughly 51 + 24 + 138 = **213 ms of 359 ms = 59%**, or **11.3% of the draw
  bracket**. The per-glyph component is roughly 55 ms.
- Inference: `L1` (batch glyph submission by (face, color) across the whole
  damaged region instead of once per row per style) attacks a number about **4x
  larger** than bypassing CoreText does, and bypassing CoreText is a strictly
  smaller subset of the same win. Take the batching; leave the wrapper alone
  unless the batching leaves a measurable residue.
- Uncertainty: the "recursion / unattributed" 24.3% is the folded profile's
  self-recursive `dlRecorder_DrawGlyphs` frame and cannot be split further
  without a second capture at greater depth. Read the 59% as 50-65%.

### F7 -- the cmap lookup is 16% of the bracket and 87% of it is one table search

- Status: recorded.
- Measurements: `CTFontGetGlyphsForCharacters` 301 ms inclusive, 16.0% of the
  bracket. Its dominant child is
  `TFormat4UTF16cmapTable::MapT<false, unsigned short>` at 261 ms -- **86.7% of
  the call**, and 1.43% of the entire process's on-CPU time. `CFRetain` /
  `CFRelease` / `___CFBasicHashFindBucket_Linear` appear at 1.13% / 1.00% /
  1.14% of the workload as self frames, partly under this path.
- Observation: DanTerm re-runs a format-4 cmap binary search for every character
  of every text run of every draw. On a full-screen 179x66 redraw that is ~11,800
  searches per frame, for a character repertoire that in practice is dominated by
  ASCII.
- Inference: `L2`. `F2` established from the header that the mapping is a pure
  function of (face, UTF-16 code unit), so a per-face memo table is
  behavior-preserving by construction rather than by empirical agreement. A
  128-entry direct-index array per face covers ASCII with a single load and no
  hashing; a dictionary handles the tail.
- Competing interpretation: CoreText may already cache internally, making the
  measured 261 ms the *cached* cost. That does not weaken the lead -- 261 ms of
  measured work is 13.9% of the bracket whether or not something cheaper exists
  inside CoreText -- but it does mean the win could come in below a naive
  "eliminate 16%" prediction. Predict 10-14%, not 16%.

### F8 -- two Swift-side costs inside the bracket that are not CoreText's

- Status: recorded. The second is attribution-uncertain; read the caveat.
- **The sprite classification switch is despecialized.**
  `specialized protocol witness for RangeExpression.contains(_:) in conformance
  ClosedRange<A>` is 98 ms, **5.2% of the bracket** and the third-largest child
  of `drawTextRuns`. Its origin is the eight-arm
  `switch scalar.value { case SomeSprite.coarseRange: ... }` at
  `TerminalRenderExecution.swift:479-568`: each arm is a `ClosedRange<UInt32>`
  pattern match that goes through a protocol witness instead of an inlined
  comparison (the switch runs from `:479` to its `default: break` at `:577-578`).
  Every non-sprite cell pays up to eight of them.
  **All eight coarse ranges start at or above `0x2500`** (verified: `0x2500`,
  `0x2580`, `0x25E2`, `0x2800`, `0xE0B0`, `0xF5D0`, `0x1FB00`, `0x1CC1B`), so a
  single `scalar.value >= 0x2500` guard is a total-function-preserving skip for
  every ASCII and Latin-1 cell. This is `L3`, and it is the cheapest lead in the
  file.
- **Array growth is 27% of the bracket, and its attribution is uncertain.**
  `_ArrayBuffer.beginCOWMutation` (269 ms) and `Array.replaceSubrange` (213 ms)
  plus `_createNewBuffer` (28 ms) are attributed *directly* to
  `drawRenderFrame`, not to `drawTextRuns`. `drawRenderFrame`'s own body contains
  no array mutation, so the only consistent reading is that
  `drawTextRuns` is partially inlined into it and the symbolizer charges the
  inlined appends to the outer frame. The appends themselves are visible in the
  source: `characters`, `glyphs`, `mappedGlyphs`, `positions`, `candidateCells`,
  `fallbackCells` are all per-element `append` on hoisted `Array`s
  (`:582-589`, `:633`, `:645-649`), each carrying a uniqueness check --
  `swift_isUniquelyReferenced_nonNull_native` is 1.54% of the whole process as a
  self frame, the 9th largest in the app.
  **This is exactly the shape `17/D5` retired a candidate for**, so it is ranked
  as `L4` with an explicit precondition: confirm by ablation or by a build with
  the inlining disabled *before* sizing it. Do not quote 27% until then.

### F9 -- what this workload cannot tell us about run counts

- Status: recorded. A caveat with a number attached, not a finding about the app.
- `L1`'s and `L6`'s wins are proportional to `(runs before) / (runs after)`, and
  that ratio is a property of the *content*, not of the renderer. This
  workload's stimulus is `full-screen-content-churn`: 179x66, text changes every
  frame, **style frozen** (`agent-docs/terminal-performance.md`). Frozen style
  means few distinct (foreground, bold, italic) tuples, so batching by (face,
  color) collapses ~66 rows x few styles into a handful of calls -- a large ratio.
  `full-screen-style-churn` freezes text and varies **truecolor** fg/bg every
  frame, so distinct colors per row are many and the same batching collapses
  almost nothing.
- **Pre-registered prediction for `L1`:** `content-churn` improves materially,
  `style-churn` improves little or not at all, and the two verdicts *disagreeing*
  is the expected result rather than evidence of a bad measurement. `17/F4`
  found the two workloads CPU-indistinguishable at rest; if `L1` is what this
  file claims, it is the first change that should separate them. If instead both
  move together, the mechanism attributed here is wrong.
- No run-count instrument exists. `TerminalBenchmarkObserver` sees plans and
  draws, not run or call counts. Adding a per-draw "text runs" and
  "glyph-submission calls" counter to the existing observer is the smallest
  tooling step that would make `L1` and `L6` predictable in advance instead of
  only measurable afterwards. It is cheap and it is not a decision rule, so it
  does not need calibration.

### F10 -- `L3` landed: -6.76% and -6.08%, and the draw rule can see a 5% mechanism

- Status: confirmed by paired benchmark. First `L`-lead implemented.
- Method: `just benchmark-quick baseline=HEAD workload=content-churn` and the
  same for `style-churn`, baseline `8e9f538` (candidate tree `d602e10`), each the
  frozen 2-pair position-balanced schedule. Both arms built from immutable
  snapshots; the candidate arm's captured path list included only this change
  plus untracked notes/plans.
- Change: `spriteClassificationMinimumScalar` (`= 0x2500`) at
  `TerminalRenderExecution.swift:483`, tested before entering the eight-arm
  family switch at `:493`. The switch body is otherwise untouched, so the
  fall-through-to-font-path behavior `F4` measured is unchanged for every scalar
  at or above the floor.
- Measurements:
  - `content-churn`: **`faster` -6.76%** symmetric median of 2 pairs.
    Plan time -0.32% (`equivalent`) -- the change is in the draw path, and the
    planner correctly did not move.
  - `style-churn`: **`faster` -6.08%** symmetric median of 2 pairs. Plan time
    +1.04% (`inconclusive`).
  - Process CPU: +0.11% and -0.80%. Descriptive only per `17/D6`; recorded so
    nobody reads a directional claim into it later.
- Observation: both draw workloads moved, by nearly the same amount.
- Inference, and this is the finding's real content: **the frozen draw verdict
  resolves a mechanism sized at ~5% of the bracket.** That was the reason to
  spend the first commit here rather than on the largest item, and it is now
  established rather than assumed for `L2`, `L1`, `L6`, and `L5`, whose estimates
  are all quoted in the same units. It also means an `equivalent` verdict on a
  later tier-1 lead is evidence against that lead's mechanism, not evidence that
  the instrument is too coarse.
- The two workloads agreeing is the *expected* result here and is not the `F9`
  divergence test. `L3` removes per-cell classification work, and cell count is
  identical in both workloads; only `L1`'s batching is style-sensitive. `F9`'s
  prediction remains unfired and still belongs to `L1`.
- Measured -6.76%/-6.08% against an estimate of ~5%: the estimate came from
  `F4`'s `RangeExpression.contains` witness line (98 ms, 5.2% of the bracket)
  alone. The excess is consistent with the guard also skipping the switch's own
  dispatch and the eight `static let` range loads, which `F4` never attributed
  to a separate line. Not worth a capture to confirm -- it does not change any
  decision -- but do not read the overshoot as the estimate having been low by
  method.
- Uncertainty: 2 pairs is the `quick` schedule, not `confirm`'s. A `confirm` run
  would tighten the interval and add `incremental-mixed`, which `L3` should also
  help and which is the noisiest workload. Not run, because two independent
  `faster` verdicts on the two workloads that contain the mechanism already
  answer the question this lead was taken to answer.
- Competing interpretation considered: that the win is the compiler
  re-optimizing the whole loop around the new early exit rather than the skipped
  range tests. Indistinguishable here and not worth separating -- the mechanism
  attribution matters for `L1`, where the prediction is directional, and not for
  a guard whose only claim is "do less per cell".

## Decision log

### D1 -- the ranked lead list

- Status: **recommendation. `L3` has since been taken and confirmed (`F10`); every
  other lead below is still a recommendation with nothing implemented.**
- Ranking axis: expected reduction in `drawNanosecondsPerDraw` per unit of risk,
  with decidability as a hard gate -- tier 1 is decidable by an existing
  calibrated rule, tier 2 is decidable but small or uncertain, tier 3 is not
  decidable by any instrument this project has.

**Tier 1 -- inside the draw bracket, decidable by the frozen draw verdict.**

| # | Lead | Size (% of bracket) | Risk | Smallest first experiment |
| --- | --- | ---: | --- | --- |
| `L1` | **Batch glyph submission.** Accumulate glyphs and positions across *all* rows into one buffer per (face, color) for the whole draw; issue one `CTFontDrawGlyphs` per batch instead of one per row per style. Attacks the per-entry color-resource and fill-state construction in `F6`, plus the wrapper and antialias-style lookups. | **~11%** (`F6`), and it also cuts CA-side replay entries | Medium. Draw order changes: all text of one color is submitted before another color's. Text runs do not overlap by construction -- one glyph per cell at a cell-quantized position (`F1` item 1 for the run shape, `TerminalRenderExecution.swift:649-653` for the position derivation) -- so the composite result is identical, but that invariant must be asserted, not assumed. Decorations and cursor must stay ordered after text. | Batch by (face, color) only, keep the existing per-row loop for sprites and fills. Snapshot-test a frame containing every style combination, then run `just benchmark-quick` and read `content-churn` against `style-churn` per `F9`'s prediction. |
| `L2` | **Memoize character-to-glyph mapping** per face: 128-entry direct array for ASCII plus a dictionary tail, built lazily, owned by `TerminalFontSet` (`TerminalRenderExecution.swift:111-141` -- immutable after `init` and already `@unchecked Sendable`, so adding mutable state to it is a synchronization decision, not a free change; prefer per-draw-thread ownership over a lock). | **10-14%** (`F7`) | Low. `F2` proves purity from the header. Behavior-preserving by construction. | Cache only the ASCII range first; measure; extend to the dictionary tail only if the residue justifies it. Test: a run of every BMP scalar the fixtures cover maps identically with and without the cache. |
| `L3` | **Guard the sprite switch** with `scalar.value >= 0x2500` before the eight-arm range match. **Taken; `faster` on both draw workloads -- see `F10`.** | **~5%** (`F8`); measured -6.76% / -6.08% | Very low. Pure control flow; the guard's bound is verifiable against the eight constants in one grep. | Add the guard plus a test that asserts every family's `coarseRange.lowerBound >= 0x2500`, so the guard cannot silently outlive the constant that justifies it. This is the file's recommended *first* commit regardless of what else is taken. |
| `L6` | **Batch fills by color.** Background, selection, and search-match runs each call `fill(rect)` per run; group by color and issue one `fill(rects)` per color per draw, and merge vertically adjacent equal-color spans. Each avoided call is also an avoided display-list entry with its own `colorResourceForColor` + `getEntryFillState` (`F6`). | up to **~14%** (`F4`, `CGContextFillRect`/`FillRects`); content-dependent per `F9` | Low. Fills are opaque and non-overlapping within a layer; the three layers keep their existing relative order. | Backgrounds only, grouped by color. `fill(rects)` is already used by the sprite path, so the idiom is established. |
| `L5` | **Intern `CGColor`s across draws** in the metrics (or a renderer-owned cache) instead of per draw, and build them in the destination color space rather than constructing `CGColorSpace(name:)` per draw. Removes `RenderColor.cgColor` (4.1%), the per-draw dictionary traffic (1.4%), and `CGColorSpaceCreateWithName` (0.2%). | **~5.5%** (`F4`; call sites at `F1`'s last three rows) | Low, with one real trap: interning must be keyed on the full color *and* the color space, and an unbounded cache on truecolor input is a leak. Bound it. | Hoist the color space to `TerminalRenderMetrics`; add a bounded (e.g. 256-entry) intern table; verify identical rendering on a truecolor fixture. |

**Tier 2 -- decidable, but smaller or resting on uncertain attribution.**

| # | Lead | Size | Note |
| --- | --- | ---: | --- |
| `L4` | **Replace per-element `Array.append` in the run loop with writes into pre-sized unsafe buffers.** | claimed 27% of the bracket, **unconfirmed** | `F8`. Blocked on confirming the inlining attribution first; `17/D5` retired a candidate sized exactly this way. Confirm, then it is arguably tier 1. |
| `L10` | **Multiple dirty rects.** Use `getRectsBeingDrawn(_:count:)` instead of the union `dirtyRect`, so damage on rows 3 and 60 stops repainting rows 3-60. | 0% on this workload; potentially large on real incremental output | `F1` item 5 + `F3`. Invisible to all three churn workloads (full-viewport damage) -- it would be decided by `incremental-mixed`, whose draw verdict is real but whose trace is ~1/6 instrument (`17/F2`). Correctness-positive regardless. |
| `L11` | **View/layer configuration:** `isOpaque = true`, `wantsDefaultClipping = false`, `layerContentsRedrawPolicy = .onSetNeedsDisplay`, and drop one of the two background fills (`F1` item 6). | unmeasured; individually small | `F3`'s WWDC checklist. Cheap, low-risk, and each item is independently revertible. `isOpaque` has a visual precondition: the view must genuinely paint every pixel of its bounds, which `F1` item 6 says it does. |
| `L12` | **Bypass the CoreText wrapper** for the common path: cache `CGFont` per face, `setFont` + `setFontSize` once, then `showGlyphs(_:at:)`. | ~2.7% of the bracket (`F6`) | **Strictly a subset of `L1`'s win.** Do not take it before `L1`; reconsider only if `L1` leaves a measurable wrapper residue. Loses CTFont matrix/variation handling, which DanTerm does not currently use but which a future font feature might. |
| `L13` | **Borrow rather than copy `TerminalScalars.Storage`** in the classification loop (`TerminalRenderExecution.swift:477-478`, where each cell's `scalars` is read to classify it). | 3.4% of the bracket (`F4`; 2.09% of the whole process as a self frame per `F4`'s census) | Adjacent to `17`'s candidate B (which shipped) and to the twice-rejected POD cell (pre-rejected). Read both before touching it. |

**Tier 3 -- no instrument here can decide it. Documented, not recommended.**

| # | Lead | Why it is here |
| --- | --- | --- |
| `L9` | **Disable subpixel positioning and quantization** (`F2`), reducing the number of distinct glyph raster variants CG and CA must cache, rasterize, and upload. Targets `TGlyphOutlineDictionaryCache::Copy` -- 4.86% of the *whole process* and the single largest self frame in the app (`F4`'s census) -- plus `CA::CG::FillGlyphs` (3.47%) and `CA::OGL::GlyphCache` (2.12%), both inclusive shares taken from `17/F3` rather than re-derived here, and both with magnitudes `17/F17` retired as stimulus-inflated. | Every node it targets is **off** the main thread and therefore outside the draw verdict, in the blind spot `17/D7` proved undecidable: the churn workloads are frame-rate-capped (`17/F16`), and `processCPUNanosecondsPerDraw` was screened and refused a verdict (`17/F15`, `17/D6`). It also has a visual consequence that needs a human eye, not a test. Cheap to try, impossible to score. |
| `L14` | **Rasterize into an owned bitmap and hand the layer a `CGImage`** via `wantsUpdateLayer`/`updateLayer`, eliminating display-list recording and CA's replay entirely, and enabling a scroll to become a blit of the previous frame. | The architectural answer to `F5`, and the only lead that could remove `17/F6`'s node rather than shrink it. It moves rasterization onto DanTerm's thread, so it would make the draw verdict *larger* while making total process CPU smaller -- i.e. it is scored `slower` by the only calibrated rule available. Needs a new decision rule before it can be attempted honestly. |
| `L15` | **Metal glyph atlas.** | `09-renderer.md` defers it by design (`plan-terminal-engine/09-renderer.md:35, 62, 75`), and `F3` notes it is what every fast terminal did. Out of scope for a *CPU renderer* file; recorded so the ranking is not mistaken for a claim that the CPU path can win outright. |

- Recommended order: **`L3`, then `L2`, then `L1`, then `L6`/`L5`.** `L3` first
  because it is a few lines, has a test that outlives it, and its ~5% is real:
  it establishes whether the draw verdict can see a change of that size at all,
  which is information every later lead needs. `L2` second because it is the
  largest low-risk item and its correctness argument comes from a header rather
  than from a measurement. `L1` third because it is the largest item overall but
  the only tier-1 lead with a real ordering risk, and because `F9`'s prediction
  makes it the one lead whose *mechanism* the benchmark can confirm or refute.
- `L1`, `L5`, and `L6` overlap: all three reduce per-display-list-entry color and
  state work. **Their sizes are not additive.** Take them in sequence, re-reading
  the bracket after each, rather than pitching a combined number.

### D2 -- what this file deliberately does not propose

- Status: recorded.
- **No new instrument, no new workload, no new decision rule.** Doc 17 spent its
  Phase 4 on instrument work and concluded with one metric permanently
  descriptive (`17/D6`). Tier 1 is decidable with what exists today, and that is
  the whole reason it is tier 1. The single exception offered is `F9`'s run-count
  counter, which is a diagnostic and not a rule.
- **No re-litigation of the compositing question.** `17/D8` closed candidate A
  and `17`'s pre-rejected list forbids using `F6`-style shares to reopen the
  compositing stall. `F5` explains the *mechanism* behind those shares and `L14`
  records the only lead that would address them, in tier 3, unscored.

## Pre-rejected

Inherits doc 17's list in full. Re-proposing anything there needs the kind of
evidence that section names. Two of its entries bear directly on this file:

- **"Cheaper Swift-side preparation of draw rects"** (`11/F10`, `17`). This file
  does *not* reopen it: `L3`, `L4`, `L5`, `L13` are Swift-side costs in the
  **text** path measured at 5.2%, 27%(unconfirmed), 5.5% and 3.4% of the draw
  bracket, whereas the rejected candidate was rect preparation on the **sprite**
  path, where 71.5% of the work is inside `CGContextFillRects`. Different path,
  different denominator. Anyone rejecting `L3` by citing that entry should
  re-read both.
- **The POD `GridCell` and sub-32 strides.** `L13` sits next to both. It is a
  borrow-instead-of-copy change at one call site, not a representation change.

Added by this file:

- **Bypassing `CTFontDrawGlyphs` as a standalone candidate.** `F6`: the wrapper
  is a ~2.7%-of-bracket pass-through and a strict subset of `L1`. Taking it first
  would spend a paired benchmark on the small half of the same win. Reopen only
  as `L1`'s residue.
- **Sizing any glyph-drawing candidate per glyph.** `F6` measured the split:
  59% per-call, ~15% per-glyph. A pitch that multiplies a per-glyph cost by the
  cell count is wrong by roughly 4x in the direction that makes it look good.
- **Quoting `F8`'s 27% array-growth figure.** It rests on an inlining
  attribution that `17/D5` specifically retired a candidate for. It is a
  precondition, not a size.

## Open questions and caveats

- **No new capture was taken.** Every number here is re-analysis of one existing
  30-second `content-churn` trace at `4ecb032` (`17/F1`), and HEAD is now
  `8e9f538`. Doc 9's two-profile rule is unsatisfied. A candidate should get its
  own capture at HEAD before it is benchmarked.
- **Loop profiling mode forces a full-viewport redraw**, so the bracket was
  measured at maximum glyph count. The ratios in `F4` are more robust to this
  than absolute shares would be, but `L1`'s and `L6`'s wins scale with the run
  count the stimulus produces, and `F9` shows the two churn workloads sit at
  opposite ends of that. Neither reflects a real TUI.
- **`F8`'s array attribution is unconfirmed** and is the largest single number in
  `F4`. Everything downstream of it (`L4`) is blocked on an ablation.
- **`F6`'s 24.3% recursive residual** is unsplit; the 59% per-call figure should
  be read as a 50-65% band.
- **`F5`'s recorder path may be conditional.** If CoreGraphics picks the
  rasterizing context for some draws, the per-entry costs `L1`/`L5`/`L6` target
  would shrink on those draws. Both leads survive as call-count reductions
  either way, but the *predicted size* would not.
- **`L9`'s targets are the largest self frames in the app and cannot be scored.**
  `TGlyphOutlineDictionaryCache::Copy` alone is 4.86% of process on-CPU time --
  larger than any node in the draw bracket -- and every instrument this project
  has is blind to it (`17/D7`). This is the same trap `17` fell into with
  candidate A; the difference is that here it is labelled tier 3 up front.
- **`style-churn` was not re-analyzed.** `17/F4` found it CPU-indistinguishable
  from `content-churn` at rest, so its bracket decomposition is assumed to match.
  `F9` predicts the two must *diverge* under `L1`, which means that assumption
  is load-bearing exactly where it is least tested. Capture it if `L1` is taken.
- **`terminal-feed` still has no on-CPU mode** (`17/F2`), and nothing in this
  file needs it: every lead is in the draw path.
- Untracked `notes.md` and `plans/wip/*` were present in the tree during the
  original capture and are still present now. They do not enter the build, but
  they **do** enter a paired comparison's candidate tree; read the printed path
  list before believing any benchmark run that follows from this file.

## Outcome

**Survey complete; ranked; `L3` implemented and confirmed (`F10`); the rest of
Phase 4 still gated.** Fifteen leads, five
of them decidable today by the frozen draw verdict and together covering roughly
35-45% of the draw bracket (non-additively), three pre-rejections added, and one
reading corrected before it reached code (`F6`).

Four results are worth more than the ranking:

1. **DanTerm's draw does not rasterize -- it records a CoreGraphics display
   list** (`F5`). That single fact reframes the whole bracket: inside `draw(_:)`,
   cost is per display-list entry, and an entry costs more in color and state
   construction (48.5%) than in glyph payload (19.4%). It is also the mechanism
   behind `17/F1`'s off-main-thread surprise and `17/F2`'s unbracketed region,
   neither of which doc 17 explained.
2. **The renderer's dominant costs are all per-frame repetitions of work whose
   inputs did not change between frames** -- cmap lookups (`F7`), `CGColor`
   construction, per-run display-list state (`F6`). That is the same insight a
   GPU glyph atlas is built on (`F3`), available on the CPU path without a new
   renderer.
3. **This file's leads are decidable and doc 17's best one was not.** `17/D7`
   and `17/D6` established that an off-main-thread candidate has no rule here.
   Tier 1 was constructed to sit inside the one bracket that has a calibrated
   rule, which is why the ranking's axis is decidability first and size second.
4. **`F6` is a worked example of the sizing rule this project keeps
   rediscovering.** The obvious reading of a profile node was 4x too generous and
   pointed at the wrong fix; separating per-call from per-item cost inside the
   node changed both the size and the candidate. `17/F14` learned the same lesson
   by spending a benchmark. This time it cost one `awk` pass.
5. **The draw verdict resolves a 5%-of-bracket mechanism** (`F10`). Establishing
   that was the point of taking the smallest tier-1 lead first rather than the
   largest. Every remaining tier-1 estimate is quoted in the same units, so an
   `equivalent` verdict on one of them now argues against that lead's mechanism
   instead of against the instrument.
