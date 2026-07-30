# CPU renderer optimization leads

Research started: 2026-07-29. **Status: OPEN -- survey complete; two of the five
tier-1 leads taken and confirmed (`L3`/`F10`, `L2`/`F11`), the bracket re-captured
the remainder re-ranked (`F12`, `D4`), and `L1` taken and rejected
(`F13`, `D5`) -- the rest still gated.**
Deliverable is the API inventory (`F1`), the decomposition of the one decidable
renderer bracket (`F4`-`F8`, superseded in its shares by `F12`), the ranked lead
list (`D1`, re-ordered by `D4`), and the paired-benchmark verdict for each lead as
it lands (`F10` onward). Together the two taken leads cut the draw bracket roughly
in half on all three draw workloads -- **confirmed independently at -42.8% on-CPU
by `F12`** -- which also halved the denominator every remaining lead is quoted in.
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

**Opened by user direction on 2026-07-29 for `L3`, then `L2`.** Each entry is one
commit-sized candidate with its own paired benchmark. The first two were taken in
`D1`'s order; everything after the re-capture is in `D4`'s. Everything still
unchecked remains gated.

- [x] **`L3` -- guard the sprite switch** (`>= 0x2500`). ~5% of the bracket.
      First because it is a few lines, its guarding test outlives it, and its
      verdict tells us whether the draw rule can see a change of that size at
      all -- information every later lead needs. **Done -- `F10`. Landed as
      `spriteClassificationMinimumScalar` + `SpriteRoutingGuardTests`;
      `content-churn` `faster` -6.76%, `style-churn` `faster` -6.08%.**
- [x] **`L2` -- memoize character-to-glyph mapping** per face. 10-14%. Largest
      low-risk item; correctness comes from `F2`'s header text, not a measurement.
      **Done -- `F11`. Landed as an eager, immutable printable-ASCII table on each
      styled face (no per-draw memo, so no synchronization decision).
      `confirm`: `content-churn` -49.43%, `style-churn` -53.16%,
      `incremental-mixed` -42.95%. Four times the estimate, because a table hit
      also skips the intermediate buffers -- see `F11`.**

**Order below is `D4`'s.** `D3` ordered these too, on `F12`'s first grouping, and
that grouping had an attribution bug; `D4` corrects both the sizes and the order.

- [x] Capture at HEAD, both churn workloads. **Done -- `F12`. Retired every share
      in `F4`, confirmed the bracket is ~60% CoreGraphics entry recording, and
      re-ranked the remainder.**
- [x] **`L1` -- batch glyph submission** by (face, color) across the damaged region.
      **Done, and REJECTED -- `F13`, `D5`. `slower` +30.67% (`content-churn`) and
      +31.55% (`style-churn`), reverted.** `CTFontDrawGlyphs` enumerates its glyph
      array and calls the context delegate once per non-overlapping sub-run, so our
      call count never controlled the entry count. `F9`'s prediction fired against it:
      both workloads moved together, which `F9` named in advance as refuting the
      mechanism. Tests kept as `MultiStyleFrameTests`.
- [ ] **`L12` -- bypass `CTFontDrawGlyphs`** for the mapped-glyph path: cache `CGFont`
      per face, `setFont` + `setFontSize`, then `showGlyphs(_:at:)`. Promoted out of
      "Pre-rejected" by `D5`. `F13` measures `EnumerateOverlappingGlyphs` at **385 ms =
      35.8% of the bracket**; if the lower-level entry point reaches the recorder
      without it, this is the largest item on the text path. **If it does the same
      enumeration internally, this is worth zero** -- which is why it goes first: one
      commit and one `quick` run re-rank everything after it.
- [ ] **`L4` -- write into pre-sized buffers** instead of per-element `Array.append`.
      **24.5%** of the live bracket -- `isUniquelyReferenced` plus its stub is
      8.9-10.9% of it. Tier 1 now that `F8`'s precondition is met (`F11`, `F12`).
      `L1`'s rejection removes the reason it was sequenced second, so it is blocked
      only on `L12`, which may change the buffer shape it should pre-size.
- [ ] **`L5` -- intern `CGColor`s and hoist the color space.** Floor ~5.5% (our own
      construction), ceiling whatever of the dedup block `L6` leaves. Its stronger
      form rests on a `CGColorCompare` pointer fast path the SDK does not document
      (`D3`) -- do not pitch the big number.
- [ ] **`L6` -- batch fills by color.** 7-19% inclusive and sharply
      content-dependent (`F12`): 18.6% of the `content-churn` bracket, 7.0% of
      `style-churn`'s. Size it from the inclusive figure, not `F12`'s entry row.
      **Its premise survives `F13` where `L1`'s did not:** `fill(rect)` maps one call
      to one display-list entry, and 71 ms of the dedup block sits under fill entries
      rather than glyph entries.
- [ ] Optional tooling, not a decision rule: the per-draw run-count and
      glyph-call counters `F9` asks for, which would make `L1`/`L6` predictable
      in advance instead of only measurable afterwards.
- [x] The capture above was originally listed here as **not** a precondition, on
      the grounds that `TerminalRenderExecution` was unchanged since the `4ecb032`
      trace. `F10` and `F11` voided that justification and the item was inverted
      into a requirement, then done. **Recorded because the reasoning failed in a
      reusable way:** the bullet was true when written and became false without
      anything editing it, because it asserted a fact about HEAD inside a document
      whose whole purpose was to change HEAD. Any claim of the form "no fresh
      measurement needed, because the code has not moved" expires the moment a lead
      lands. `F12` found the bracket had halved and two leads had changed rank.

The remaining tier 2 and tier 3 leads (`L9`-`L13` minus `L4`, plus `L14`-`L15`) are
deliberately absent from this ledger. `L4` is present because `D3` promoted it to
tier 1 on `F12`'s evidence (`D4` keeps it there, second); the rest of tier 2 is available but unranked against
tier 1 until tier 1 is spent, and tier 3 has no instrument that can score it and
would need a new decision rule first.

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

**`F4`-`F8` describe the renderer at `4ecb032`, before `L3` and `L2` landed. Their
percentages are superseded by `F12`, which re-captured the bracket at HEAD; read
them as history and take live sizes from `F12`.** `F6`'s internal decomposition of
`dlRecorder_DrawGlyphs` is the exception -- `L2` did not touch that node.

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

### F11 -- `L2` landed at roughly -50%, four times its estimate, because it also removed the intermediate buffers

- Status: confirmed by the `confirm` schedule on all five workloads. Second
  `L`-lead implemented.
- Method: `just benchmark-confirm baseline=HEAD` with baseline `40637fe` (the `L3`
  commit) and candidate tree `b024c3f`, after two `quick` runs agreed
  (`content-churn` -52.23%, `style-churn` -50.95%, 2 pairs each).
- Change: `TerminalFace` now pairs each styled `CTFont` with its printable-ASCII
  glyphs, resolved once in `init` (`TerminalRenderExecution.swift:110-146`), and
  the run loop submits a table hit straight into `mappedGlyphs`/`positions`
  instead of routing it through `characters` -> `CTFontGetGlyphsForCharacters` ->
  `glyphs` -> `candidateCells` (`:560-580`). The table is immutable, so no
  synchronization decision was needed and `TerminalFontSet` stays a `Sendable`
  value -- the mutable per-draw memo `D1` contemplated was never built.
- Measurements (`confirm`, per-workload pair counts as frozen):
  - `content-churn`: **`faster` -49.43%** (4 pairs)
  - `style-churn`: **`faster` -53.16%** (4 pairs, 3 flagged outliers retained)
  - `incremental-mixed`: **`faster` -42.95%** (6 pairs)
  - `terminal-feed`: `equivalent` +0.00% -- correct; it never draws.
  - `scrollback-stream`: `inconclusive` +1.28% -- PTY-bound, as `17` found.
  - Plan time moved between -0.52% and +2.02% across runs, all descriptive.
- Observation: the estimate was **10-14%** (`F7`'s cmap share) and the measurement
  is ~4x that. The estimate was not wrong about the cmap; the change was bigger
  than the change that was proposed.
- Inference: a table hit skips three things at once, and only the first was
  sized. It skips the cmap lookup (`F7`, 16% of the bracket); it skips the
  `characters`/`candidateCells`/`glyphs` append traffic, which `F4` measured as
  `_ArrayBuffer.beginCOWMutation` 14.3% plus `Array.replaceSubrange` 11.3%; and
  it skips the `repeatElement` growth of `glyphs` plus the second pass over
  `candidateCells`. Those add to roughly the observed figure.
- **This answers `F8`'s open question, and by a better route than the ablation
  `F8` asked for.** `F8` attributed ~27% to array growth via an inlining
  attribution and demanded confirmation before the number could be quoted. What
  ran is a confirmation of the right kind: the arrays were *deleted* from the ASCII
  path and the bracket was re-measured. That is not the parent-minus-child
  inference `17/D5` retired a candidate for. `F12`'s fresh capture then supplies
  the split directly, because the cmap is now **absent** from the trace rather than
  merely smaller: of the 804 ms the bracket lost, `L3` accounts for 94 ms and the
  cmap for 301 ms, leaving **409 ms = 22.9% of the post-`L3` bracket** for the
  buffer traffic plus the second correlation pass. See `F12` for the arithmetic
  and its caveat.
- So `F8`'s 27% is **corroborated but not exceeded**: 22.9% measured on the
  profiler, or ~28% if the paired benchmark's larger total (-49.43% versus the
  profile's -39.8%) is the truer one. An earlier draft of this finding claimed the
  residue *exceeded* 27%; that was arithmetic across two disagreeing instruments --
  it took the paired benchmark's total and the profiler's cmap share -- and it is
  withdrawn. `F8`'s figure is quotable now, as an estimate that landed, and should
  be cited to `F12` rather than to `F4`'s attribution.
- The split is cheap to settle if anyone needs the number: benchmark a throwaway
  variant that consults the table but still pushes each hit through
  `characters`/`glyphs` as before. The difference between that and this commit is
  the buffer share. Nothing currently queued depends on the answer, which is why
  it was not run.
- **`content-churn` and `style-churn` moving together here is expected and is not
  evidence against `F9`.** Like `L3` (`F10`), `L2`'s mechanism keys on character
  repertoire, which the two corpora share; `F9`'s divergence prediction keys on
  *run counts*, which they differ on sharply. Two leads have now moved both
  workloads symmetrically, which makes this worth stating explicitly: do not read
  the accumulated symmetry as `F9`'s prediction having already failed. It remains
  unfired and still belongs to `L1` alone.
- Uncertainty: the three draw workloads' corpora are ASCII-dominated, so the
  table's hit rate there is near 100%. A CJK-heavy or emoji-heavy session keeps
  the old path for most cells and would see far less. The win is real but its size
  is a property of the content, exactly as `F9` warned for `L1` and `L6`.
- `style-churn` carried 3 flagged outlier pairs, retained in the estimate per the
  frozen rule. Its verdict agrees with the other two draw workloads within a few
  points, so the outliers do not change the reading.
- Competing interpretation considered and rejected: that the change renders less.
  `AsciiGlyphTableTests` checks every table entry against a fresh
  `CTFontGetGlyphsForCharacters` on all four faces, and the mixed table/cmap
  alignment test compares each cell against an isolated control, so glyphs are
  neither dropped nor displaced. The whole existing bitmap suite (97 tests) is
  unchanged and green.

### F12 -- the bracket re-captured at HEAD: half the size, a different composition, and the two churn workloads are no longer interchangeable

- Status: recorded. **Two fresh captures, and the first `style-churn` trace this
  project has ever decomposed.** These supersede every *share* in `F4`.
- Artifacts (**disposable**, per this section's provenance rule; every
  decision-bearing number is transcribed below):
  `.build/terminal-benchmark-profiles/2026-07-29-234114-17411` (`content-churn`,
  16,818 ms on-CPU) and `.../2026-07-29-234237-18718` (`style-churn`, 17,191 ms).
  Regenerate a folded view of either with `just benchmark-report <dir>`.
- Method: `just benchmark-trace full-screen-content-churn "Time Profiler" 30` and
  the same for `full-screen-style-churn`, at HEAD `b9e77fe` (post-`L3`, post-`L2`).
  Both sustained and frame-capped at ~119 draws/s, matching `17/F16`. Leaf
  attribution is used for ranking because leaf weight *partitions* the bracket and
  can therefore be compared across mechanisms; `F4`'s inclusive shares overlap and
  cannot.

**The bracket, then and now (`content-churn`):**

| | `4ecb032` (`F4`) | HEAD (`F12`) | change |
| --- | ---: | ---: | ---: |
| workload on-CPU total | 18,008 ms | 16,818 ms | -6.6% |
| **draw bracket** | **1,879 ms** | **1,075 ms** | **-42.8%** |
| bracket as % of workload | 10.43% | 6.39% | -- |
| workload minus bracket | 16,129 ms | 15,743 ms | -2.4% |

- The last row is what licenses comparing the absolute millisecond figures at all:
  non-draw work held to within 2.4% across the two captures, so the bracket's
  804 ms loss is the bracket's, not a shorter capture's.
- **-42.8% here versus -49.43% from the paired benchmark on the same workload
  (`F11`).** Two independent instruments -- on-CPU sampled milliseconds versus
  wall-clock `drawNanosecondsPerDraw` -- agreeing on direction and magnitude while
  disagreeing by ~6.6 points. Neither is corrected against the other. Anywhere this
  file needs the difference between two mechanisms, that ~6.6-point spread is the
  floor on what it can resolve, which is why `F11`'s withdrawn "exceeds 27%" claim
  was unsound.

**Where the 804 ms went, and the `F8` split `F11` said was unmeasured:**

- `CTFontGetGlyphsForCharacters` and `TFormat4UTF16cmapTable::MapT` are **entirely
  absent from HEAD's trace** -- 301 ms and 261 ms respectively at `4ecb032`, and no
  sample at all now. `L2` did not shrink the cmap path; it removed it.
- The despecialized `RangeExpression.contains` protocol witness fell 98 ms -> 4 ms,
  and what remains appears as an *inlined* `specialized ClosedRange.contains` leaf
  (11 ms / 20 ms). `L3`'s mechanism is likewise confirmed at the profile level: the
  witness dispatch is gone, not merely called less.
- Arithmetic: 804 ms lost = 94 ms (`L3`) + 301 ms (cmap) + **409 ms residual**.
  Against the post-`L3` bracket of 1,785 ms that residual is **22.9%**, and it is
  the buffer traffic plus the second pass over `candidateCells`. This is the number
  `F11` said nothing queued needed; the capture supplied it for free.
- Caveat on that split: it assumes `L3`'s and `L2`'s savings are independent and
  that no third thing changed between the two commits. Both commits are small and
  touch disjoint code, so the assumption is cheap, but it is an assumption.

**Bracket weight partitioned by which code owns it.** Every sample is charged to
the nearest ancestor that names a mechanism, walking up past generic frames
(`memmove`, `malloc`, retain/release, allocation lambdas, `shared_ptr`
constructors). That walk is what makes this table trustworthy and the first
version of it wrong -- see the correction below.

| owner | `content-churn` | `style-churn` |
| --- | ---: | ---: |
| **CoreGraphics display-list entry recording** (`L1`, `L5`, `L6`) | 639 ms **59.4%** | 592 ms **58.4%** |
| **Swift array / COW traffic in our run loop** (`L4`) | 264 ms **24.6%** | 247 ms **24.4%** |
| our own Swift loop bodies (`L3`, `L13`, classification) | 88 ms 8.2% | 104 ms 10.3% |
| other | 84 ms 7.8% | 70 ms 6.9% |

Inside that 59%, what each entry costs:

| mechanism | `content-churn` | `style-churn` |
| --- | ---: | ---: |
| per-entry color + state dedup (`L5` shrinks the cost, `L1` the count) | 287 ms **26.7%** | 276 ms **27.2%** |
| glyph entry recording incl. payload copy (`L1`) | 202 ms **18.8%** | 219 ms **21.6%** |
| fill entry recording (`L6`) | 12 ms 1.1% | 5 ms 0.5% |
| entry + state allocation | the balance | the balance |

- The dedup row's contents: `CGColorCompare` (5.4% / 4.0% as a leaf),
  `CompareEntryStateDrawing`, red-black-tree inserts, `__CFStringEqual`,
  `getEntryFillState`, `getEntryDrawingState`, `colorResourceForColor`,
  `CGColorGetContentHeadroom`, `pow`, `CGColorSpaceCopyFlexGTCInfo`, `create_color`.
- **`L6` reads at ~1% here but 7-19% inclusive** (`CGContextFillRect` 200 ms =
  18.6% on `content-churn`, 71 ms = 7.0% on `style-churn`), because `fill(rect)`'s
  cost lands inside the recorder and is charged to the entry rows above. Size `L6`
  from the inclusive figure and read this row as "batching fills buys entry work,
  not `fill` calls."
- **Correction, recorded rather than quietly fixed, because the wrong version was
  committed as `7faad34` and a decision was taken on it.** The first grouping
  assigned each leaf by its own symbol name. That charged `_platform_memmove`
  (6.7% / 7.5% of the bracket) to Swift array growth -- but its callers are
  `DisplayListEntryGlyphs::setGlyphsAndPositions` (3.6% / 5.2%) and `CGColorCompare`
  (2.1% / 2.2%): CoreGraphics copying the glyph payload and comparing colors, with
  only 0.4% actually array growth. It also stranded 5.2% / 3.7% of display-list
  entry allocation in an "unattributed" bucket because the leaf was an allocator
  lambda. Fixing the walk moved `L4` **down** from 25-28% to 24.5% and `L1`'s own
  share **up** from 11.8% to 18.8-21.6%, which reversed the ranking (`D3` -> `D4`).
  The lesson is `F6`'s and `F8`'s one level down: **a generic leaf names an
  operation, not a mechanism, and grouping by leaf symbol silently charges shared
  primitives to whichever mechanism you listed first.**

**Four things this changes.**

1. **The bracket is a display-list recording cost, not a Swift cost.** Nearly 60%
   of it is CoreGraphics building display-list entries, against 24.5% for all Swift
   array and COW traffic in our run loop and 8-10% for our own loop bodies. `F5`
   asserted that cost is per-entry rather than per-pixel; this is the first
   measurement that *partitions* the bracket that way, and it means the three leads
   that reduce entry count or per-entry cost (`L1`, `L5`, `L6`) collectively address
   more than the rest of the bracket combined.
2. **`L4` is not spent, but it is not the largest either.** `F11` and an earlier
   revision of this ledger said `L4` was "mostly spent" because `L2` removed the
   ASCII glyph buffers. That was wrong -- Swift array and COW traffic is still
   24.5%, with `swift_isUniquelyReferenced_nonNull_native` plus its DYLD stub at
   8.9% / 10.9% and `Array._getElement` / `_checkSubscript` / `append` /
   `_reserveCapacityAssumingUniqueBuffer` behind it, because `L2` removed three
   arrays from one path and the rest of the run loop still appends per element. But
   the first version of this finding then over-corrected and called it the largest
   item, which it is not (see the correction above). `L4`'s precondition is met
   (`F8`, `F11`) so it is tier 1; it is not first.
3. **`L1` and `L5` are one mechanism, and this says which half is which.** The
   26.7% / 27.2% dedup block is not generic bookkeeping: `CGColorCompare`,
   `CompareEntryStateDrawing`, red-black-tree inserts, `__CFStringEqual`,
   `getEntryFillState`, `getEntryDrawingState`, `CGColorGetContentHeadroom`, `pow`,
   `CGColorSpaceCopyFlexGTCInfo`. That is CoreGraphics **deduplicating each entry's
   color and state against the resources it already recorded, by value comparison**.
   `F1` item 3 says DanTerm hands it a freshly allocated `CGColor` per color per
   run, so every entry forces a full component compare and colorimetry. **`L1`
   reduces how many entries pay it; `L5` reduces what each payment costs** -- and
   `pow` + `CGColorGetContentHeadroom` + `CGColorSpaceCopyFlexGTCInfo` appearing at
   all is direct evidence that per-draw `CGColor` construction repeats colorimetric
   work an interned color would do once.
4. **`content-churn` and `style-churn` are no longer interchangeable, so
   `17/F4`'s assumption is now false where `F9` needs it most.** Their bracket
   *totals* are close (1,075 vs 1,013 ms), which is why `17/F4` read them as
   indistinguishable, but their *composition* diverges sharply: `drawTextRuns` is
   68.4% of the bracket on `content-churn` and **81.3%** on `style-churn`, while
   fill submission is 18.6% and **7.0%**. `dlRecorder_DrawGlyphs` is 30.8% versus
   **43.1%** inclusive. This is exactly the load-bearing assumption the caveats
   section flagged, and taking the capture retired it: `L1` must now be read
   against two workloads known to differ in composition, not two assumed to match.

- **`L9`'s target has grown relative to everything decidable.**
  `TGlyphOutlineDictionaryCache` is 10.84% / 10.20% of the workload inclusive --
  now **1.7x the entire draw bracket**, where at `4ecb032` it was comparable to it.
  Nothing about `17/D7` changes: it is still off-thread and still unscoreable. But
  the honest summary of this capture is that the two landed commits shrank the one
  region this project can decide, and thereby made the undecidable region the
  dominant one. Read `D1`'s remaining tier 1 as optimizing 6% of the workload.
- Uncertainty: one capture per workload, no replicate -- doc 9's two-profile rule
  is satisfied across *workloads* but not within one. Loop profiling still forces
  full-viewport redraw (`17`, caveats), so run counts sit at maximum and `L6`'s and
  `L1`'s sizes remain content-dependent per `F9`.
- Uncertainty, and the reason `F4`'s per-node absolute figures were not carried
  forward: several individual nodes moved in directions no code change explains
  (`RenderColor.cgColor` 77 -> 203 ms, `_createNewBuffer` 28 -> 361 ms,
  `TerminalScalars.Storage` 63 -> 712 ms inclusive) while the bracket containing
  them fell 43%. With the cmap call gone, more of `drawTextRuns` inlines and the
  symbolizer re-attributes; this is `F8`'s hazard appearing again from the other
  side. **Do not compare a single node's absolute weight across these two
  captures.** Compare the bracket total, and compare mechanism groups within one
  capture.

### F13 -- `L1` implemented and rejected: batching made the draw ~31% *slower*, because `CTFontDrawGlyphs` re-splits a call into entries itself

- Status: **confirmed slower by paired benchmark on both draw workloads, cause
  identified by capture, change reverted.** This refutes the mechanism `L1`, `L12`,
  and part of `D1`'s tier-1 rationale rested on.
- Method: implemented batching by (face, colour) across the whole damaged region --
  one accumulator per key for the entire draw, one `CTFontDrawGlyphs` per key after
  the run loop, sprites and fills left per-run exactly as `D1`'s "smallest first
  experiment" specified. Baseline `927c0ee`, candidate tree `352fb074731b`. Then
  `just benchmark-trace full-screen-content-churn "Time Profiler" 30` on the
  candidate to find the cause.
- Measurements:
  - `content-churn`: **`slower` +30.67%** (2 pairs). Plan time +2.39%, `inconclusive`.
  - `style-churn`: **`slower` +31.55%** (2 pairs). Plan time +1.24%, `inconclusive`.
  - Capture, candidate versus HEAD, same workload and denominator: bracket
    **1,075 -> 1,294 ms (+20.4%)**, agreeing in direction with the paired benchmark.
- **The cause, and it is a documented-behaviour error, not an implementation one.**
  Every stage of the CoreText submission chain grew, and the *delegate* grew with it:

| chain node (inclusive, ms) | HEAD | batched | delta |
| --- | ---: | ---: | ---: |
| `CTFontDrawGlyphs` | 431 | 576 | **+145** |
| `DrawGlyphsAtPositions` | 407 | 557 | +150 |
| `EnumerateOverlappingGlyphs` | 385 | 529 | **+144** |
| `CGContextDelegateDrawGlyphs` | 600 | 706 | **+106** |
| `dlRecorder_DrawGlyphs` | 331 | 460 | **+129** |
| `colorResourceForColor` under `dlRecorder_DrawGlyphs` | 92 | 119 | +27 |

- Inference: **one `CTFontDrawGlyphs` call is not one display-list entry.** The
  wrapper enumerates the glyph array and invokes the context delegate once per
  *non-overlapping sub-run* -- that is what `EnumerateOverlappingGlyphs` is for. So
  collapsing 66 row-sized calls into a handful of frame-sized ones does not reduce
  the number of entries CoreGraphics records; the enumeration re-derives roughly the
  same split from geometry. What batching does change is that the enumeration now
  runs over ~11,800 glyphs per call instead of ~179, and the per-entry dedup work it
  was supposed to eliminate went *up* rather than down. Add the Swift-side cost of
  accumulators that grow to full-frame size every draw -- allocator traffic and
  `beginCOWMutation` both rose visibly -- and the result is ~31% slower.
- **`F6` had this evidence and read it backwards, which is the finding's real
  lesson.** `F6` saw the chain `CTFontDrawGlyphs -> DrawGlyphsAtPositions (95.3%) ->
  EnumerateOverlappingGlyphs (93.2%) -> ... -> CGContextDelegateDrawGlyphs (99.4%)`
  and concluded "over 85% of the wrapper's time *reaches the context delegate*. The
  wrapper is a pass-through, not the cost." The percentages are right and the
  conclusion does not follow: time reaches the delegate because the enumeration
  **calls the delegate repeatedly**, which is the opposite of a pass-through. A
  frame name containing "Enumerate" was the clue, and `F6` spent its scepticism on
  the size of the node rather than on what the node does.
- What survives: `F5` (the context is a recorder) and `F12`'s partition (~59% of the
  bracket is entry recording) are both untouched -- entries are still where the cost
  is. What is refuted is that *our call count* controls the entry count on the text
  path. It does not; glyph geometry does.
- Also measured, and it bears on `L6`: fill-side work went *down* slightly
  (`dlRecorder_DrawRects` 168 -> 141 ms, `CGContextFillRect` 200 -> 176 ms) purely
  as a side effect of the text path getting slower and the frame-capped workload
  drawing the same number of frames. Read it as noise, not as evidence about `L6`.
  But note that `colorResourceForColor` sits **71 ms under `dlRecorder_DrawRects`
  versus 92 ms under `dlRecorder_DrawGlyphs`** at HEAD: a large minority of the
  dedup block is fill entries, and `fill(rect)` *does* map one call to one entry.
- Uncertainty: 2 pairs each, the `quick` schedule. No `confirm` was run, because two
  independent `slower` verdicts 31% deep and a corroborating capture answer the
  question, and `confirm` on a rejected candidate spends 20 minutes to sharpen a
  number nobody will quote.
- Competing interpretation considered and rejected: that the regression is my
  accumulator's per-draw growth rather than the enumeration. Growth is real and
  visible in the capture, but it cannot be the main term --
  `EnumerateOverlappingGlyphs` alone grew +144 ms of the bracket's +219 ms, and it
  contains no Swift code at all.
- The tests written for the change were kept and renamed (`MultiStyleFrameTests`).
  They pin whole-frame parity across faces, truecolor, sprites, and the fallback
  path, which is the executor's contract rather than the candidate's, and they pass
  on the reverted renderer.

## Decision log

### D1 -- the ranked lead list

- Status: **recommendation. `L3` (`F10`) and `L2` (`F11`) have since been taken and
  confirmed; every other lead below is still a recommendation with nothing
  implemented.**
- Ranking axis: expected reduction in `drawNanosecondsPerDraw` per unit of risk,
  with decidability as a hard gate -- tier 1 is decidable by an existing
  calibrated rule, tier 2 is decidable but small or uncertain, tier 3 is not
  decidable by any instrument this project has.

**Tier 1 -- inside the draw bracket, decidable by the frozen draw verdict.**

| # | Lead | Size (% of bracket) | Risk | Smallest first experiment |
| --- | --- | ---: | --- | --- |
| `L1` | **REJECTED by `F13`/`D5`: +31% slower on both draw workloads, reverted.** ~~Batch glyph submission.~~ Accumulate glyphs and positions across *all* rows into one buffer per (face, color) for the whole draw; issue one `CTFontDrawGlyphs` per batch instead of one per row per style. Attacks the per-entry color-resource and fill-state construction in `F6`, plus the wrapper and antialias-style lookups. | **~11%** of `F4`'s bracket (`F6`) = **~20-22% of the post-`F11` bracket**, since `L2` left this node untouched while halving the denominator; it also cuts CA-side replay entries | Medium. Draw order changes: all text of one color is submitted before another color's. Text runs do not overlap by construction -- one glyph per cell at a cell-quantized position (`F1` item 1 for the run shape, `TerminalRenderExecution.swift:649-653` for the position derivation) -- so the composite result is identical, but that invariant must be asserted, not assumed. Decorations and cursor must stay ordered after text. | Batch by (face, color) only, keep the existing per-row loop for sprites and fills. Snapshot-test a frame containing every style combination, then run `just benchmark-quick` and read `content-churn` against `style-churn` per `F9`'s prediction. |
| `L2` | **Taken; `faster` on all three draw workloads at ~4x the estimate -- see `F11`. Memoize character-to-glyph mapping** per face: 128-entry direct array for ASCII plus a dictionary tail, built lazily, owned by `TerminalFontSet` (`TerminalRenderExecution.swift:111-141` -- immutable after `init` and already `@unchecked Sendable`, so adding mutable state to it is a synchronization decision, not a free change; prefer per-draw-thread ownership over a lock). | **10-14%** (`F7`); measured -49% to -53% | Low. `F2` proves purity from the header. Behavior-preserving by construction. | Cache only the ASCII range first; measure; extend to the dictionary tail only if the residue justifies it. Test: a run of every BMP scalar the fixtures cover maps identically with and without the cache. |
| `L3` | **Guard the sprite switch** with `scalar.value >= 0x2500` before the eight-arm range match. **Taken; `faster` on both draw workloads -- see `F10`.** | **~5%** (`F8`); measured -6.76% / -6.08% | Very low. Pure control flow; the guard's bound is verifiable against the eight constants in one grep. | Add the guard plus a test that asserts every family's `coarseRange.lowerBound >= 0x2500`, so the guard cannot silently outlive the constant that justifies it. This is the file's recommended *first* commit regardless of what else is taken. |
| `L6` | **Batch fills by color.** Background, selection, and search-match runs each call `fill(rect)` per run; group by color and issue one `fill(rects)` per color per draw, and merge vertically adjacent equal-color spans. Each avoided call is also an avoided display-list entry with its own `colorResourceForColor` + `getEntryFillState` (`F6`). | up to **~14%** (`F4`, `CGContextFillRect`/`FillRects`); content-dependent per `F9` | Low. Fills are opaque and non-overlapping within a layer; the three layers keep their existing relative order. | Backgrounds only, grouped by color. `fill(rects)` is already used by the sprite path, so the idiom is established. |
| `L5` | **Intern `CGColor`s across draws** in the metrics (or a renderer-owned cache) instead of per draw, and build them in the destination color space rather than constructing `CGColorSpace(name:)` per draw. Removes `RenderColor.cgColor` (4.1%), the per-draw dictionary traffic (1.4%), and `CGColorSpaceCreateWithName` (0.2%). | **~5.5%** (`F4`; call sites at `F1`'s last three rows) | Low, with one real trap: interning must be keyed on the full color *and* the color space, and an unbounded cache on truecolor input is a leak. Bound it. | Hoist the color space to `TerminalRenderMetrics`; add a bounded (e.g. 256-entry) intern table; verify identical rendering on a truecolor fixture. |

**Tier 2 -- decidable, but smaller or resting on uncertain attribution.**

| # | Lead | Size | Note |
| --- | --- | ---: | --- |
| `L4` | **Replace per-element `Array.append` in the run loop with writes into pre-sized unsafe buffers.** | was 27% of `F4`'s bracket, unconfirmed; **now confirmed and measured at 24.5% of the live bracket** | **Promoted to tier 1 by `D3`, and to second position by `D4`.** It sat here only because `F8`'s inlining attribution was the shape `17/D5` retired a candidate for. `F11` met that precondition by deletion-and-measure and `F12` measured what remains: the largest cost we own, though smaller than the CoreGraphics entry work `L1` targets. |
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

- Recommended order **as written on 2026-07-29 before any lead landed; see `D4`
  for the order in force**: `L3`, then `L2`, then `L1`, then `L6`/`L5`. `L3` first
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

### D3 -- re-ranked against `F12`'s live bracket; `L1`'s ordering risk is no longer worth paying first

- Status: **supersedes `D1`'s recommended order for everything not yet taken.**
  `D1`'s tier assignments and risk notes stand; its *sizes* and its *sequence* are
  re-derived here against `F12` rather than `F4`.
- Why re-rank at all: `D1` ordered by size against a denominator that `L3` and `L2`
  then halved, and it sized every lead from overlapping inclusive shares. `F12`
  measures the same leads as additive leaf groups against the bracket that exists
  today, and two of them changed rank.

| lead | `D1`'s size (`F4`) | `F12`'s size (live bracket) | risk | rank |
| --- | ---: | ---: | --- | ---: |
| `L4` pre-sized buffers instead of per-element `append` | 27%, unconfirmed, tier 2 | **25-28%**, confirmed | Low-Medium | **1st** |
| `L5` intern `CGColor`s + hoist the color space | ~5.5% | **up to ~23%**, shared with `L1` | Low | **2nd** |
| `L1` batch glyph submission by (face, color) | ~11% | **~12% own + the same ~23% `L5` shares** | Medium | **3rd** |
| `L6` batch fills by color | up to ~14% | **7-19%**, content-dependent | Low | 4th |

- **`L4` first.** It is now the largest single mechanism, its `17/D5`-shaped
  precondition has been met by deletion-and-measure rather than by attribution
  (`F11`, `F12`), and it changes no draw order and no output -- the same properties
  that made `L3` the right first commit. It was tier 2 only because it was
  unconfirmed, and it no longer is.
- **`L5` before `L1`, reversing `D1`.** `F12` finding 2 shows they attack one 23%
  block from opposite ends: `L1` reduces the number of display-list entries that
  pay for color and state dedup, `L5` reduces what each payment costs. `L5` is Low
  risk and touches no ordering; `L1` is the only tier-1 lead with a real ordering
  risk. Taking the low-risk half of a shared mechanism first is the same reasoning
  that put `L3` before `L2`, and it has the same payoff: `L1` is then read against a
  bracket where the cheap half of its win is already banked, so an `equivalent`
  verdict on it means something.
- **How firm that reversal is.** `L5`'s *floor* is `F4`'s ~5.5% -- the `CGColor`
  construction and color-space creation DanTerm performs itself, which interning
  removes whatever CoreGraphics does downstream. Its *ceiling* is the 23% block, and
  reaching it depends on an assumption the SDK cannot confirm (next bullet). So the
  reversal is justified by risk and by cheapness, **not** by `L5` having a larger
  expected win than `L1`: on floors alone `L1` (~12% of its own) is bigger. Anyone
  who would rather take the bigger floor first and accept the ordering risk should
  take `L1` second instead -- that is a defensible reading of the same table, and
  `L4` is first either way.
- **Pre-registered prediction for `L5`, since `F12` gives it one for the first
  time:** if the 23% dedup group is dominated by *value* comparison of freshly
  allocated `CGColor`s, then interning them so CoreGraphics sees pointer-identical
  colors should collapse `CGColorCompare`, `CGColorGetContentHeadroom`, and `pow`
  together. If `L5` lands as `equivalent` while those three frames survive at their
  current weight, the mechanism attributed in `F12` finding 2 is wrong and `L1`'s
  entry-count reduction is the only route to that 23%.
- **The assumption underneath that prediction is unverified, and the headers cannot
  settle it.** The prediction's strong form needs `CGColorCompare` to short-circuit
  on pointer equality. `CGColor.h:110-112` documents `CGColorEqualToColor` as only
  "Return true if `color1' is equal to `color2'; false otherwise" -- no statement
  about identity, and `CGColorCompare` is not public at all. Checked so nobody
  re-checks: **this is not answerable from the SDK.** Treat `L5` as sized at "up to
  23%" with a floor of `F4`'s own ~5.5% (the `CGColor` construction DanTerm does
  itself, which interning removes regardless of how CG compares), and let the
  paired benchmark decide the rest. Do not pitch the 23% as `L5`'s expected win.
- **`F9`'s divergence prediction still belongs to `L1` alone** and is unaffected by
  this reordering. `L4` and `L5` are per-cell and per-color costs, not per-run, so
  both should move both workloads together -- as `L3` and `L2` did (`F10`, `F11`).
  `F12` finding 3 sharpens the test: the two workloads are now known to differ in
  composition, so `L1`'s read is against measured baselines rather than an assumed
  shared one.
- `L4`, `L5`, `L1`, and `L6` all overlap somewhere. **Their sizes remain
  non-additive**, and `F12` does not change `D1`'s instruction to re-read the
  bracket between them rather than pitching a combined number. What `F12` adds is
  that re-reading is now cheap and mandatory: the last two commits moved the
  denominator by half, and nobody noticed until the capture.

### D4 -- `L1` first after all, and the sequencing reason is structural, not just size

- Status: **in force. Supersedes `D3`, which was decided on `F12`'s flawed first
  grouping** (`memmove` charged to Swift array growth, entry allocation stranded as
  unattributed). `D3` is left in place because the correction is instructive, not
  because its order should be followed.
- Corrected sizes, from `F12`'s caller-aware partition:

| lead | `D3` said | `F12` corrected | risk | rank |
| --- | ---: | ---: | --- | ---: |
| `L1` batch glyph submission by (face, color) | ~12% own, 3rd | **18.8-21.6% own, plus most of the 26.7% dedup block it also shrinks** | Medium | **1st** |
| `L4` pre-sized buffers instead of per-element `append` | 25-28%, 1st | **24.5%** | Low | **2nd** |
| `L5` intern `CGColor`s + hoist the color space | up to 23%, 2nd | floor ~5.5%, ceiling the dedup block `L1` does not take | Low | 3rd |
| `L6` batch fills by color | 7-19% | 7-19% inclusive, 1% as entry work | Low | 4th |

- **`L1` first on size:** it is the only lead that reduces the *number* of
  display-list entries on the text path, so it takes its own 18.8-21.6% and a
  proportional share of the 26.7% dedup block and the entry allocation behind it.
  Nothing else in tier 1 reaches half that.
- **`L1` first on structure, which is the stronger reason.** `L4` pre-sizes the
  run loop's buffers; `L1` *replaces* them, accumulating across all rows into one
  buffer per (face, color) for the whole draw instead of one buffer per run. Taking
  `L4` first means optimizing a buffer topology `L1` then deletes -- the work would
  be thrown away and the second commit would be harder to review against the first.
  **`L1` decides the buffer shape; `L4` pre-sizes whatever shape survives.** That
  ordering is forced regardless of the sizes.
- **`L5` moves after `L4`** because `L1` will already have collapsed most of the
  entries whose per-entry color cost `L5` targets. Re-read the bracket before
  pitching it; on `F12`'s evidence its floor is `F4`'s ~5.5% of *our own* `CGColor`
  construction and its ceiling depends on how much dedup `L1` leaves behind.
- **`F9`'s prediction is now live and this is the commit that fires it.**
  `content-churn` must improve materially and `style-churn` little or not at all;
  the two *disagreeing* is the expected result. `F12` finding 4 makes the read
  sharper than `F9` could: the two workloads are now known to differ in composition
  (`drawTextRuns` 68.4% vs 81.3%), so the baselines are measured rather than
  assumed. If both move together by similar amounts, the entry-count mechanism
  attributed across `F5`, `F6`, and `F12` is wrong and `D1`'s whole tier-1 rationale
  needs re-examining, not just this lead.
- Risk, restated from `D1` and unchanged by the re-ranking: draw order changes, so
  all text of one color is submitted before another color's. Text runs do not
  overlap by construction -- one glyph per cell at a cell-quantized position -- so
  the composite is identical, **but that invariant must be asserted by a test, not
  assumed**, and decorations and the cursor must stay ordered after text.

### D5 -- `L1` rejected; `F9`'s prediction fired and the mechanism it tested is dead

- Status: **decided by measurement (`F13`). `L1` is closed. `D4`'s order is void for
  `L1` and survives for the rest.**
- `L1` is not "not yet worth taking" -- it is **wrong**. It reduces a call count that
  does not control the cost it was aimed at, and it costs ~31% to do so. Do not
  reopen it without new evidence that `EnumerateOverlappingGlyphs`'s split can be
  influenced by how glyphs are submitted.
- **`F9`'s pre-registered prediction fired, and the result is the one `F9` named as
  fatal.** `F9` said `content-churn` must improve materially and `style-churn` little
  or not at all, and that "if instead both move together, the mechanism attributed
  here is wrong." Both moved together (+30.67%, +31.55%) -- same direction, within a
  point of each other -- while the two workloads' run counts differ by a large
  factor. The prediction was honoured exactly as written: the mechanism is wrong.
  Recording this because a pre-registered test that fires against the file's own
  favourite lead is the strongest evidence this method produces, and it only counts
  if it is allowed to.
- **`L12` is un-pre-rejected, and it is now the most interesting remaining lead.**
  The "Pre-rejected" entry below dismissed bypassing `CTFontDrawGlyphs` as "a
  ~2.7%-of-bracket pass-through and a strict subset of `L1`". Both halves are void:
  `L1` is dead so nothing can be a subset of it, and the 2.7% came from
  `F6`'s subtraction `359 - 284 - 24`, which is the parent-minus-child sizing
  `17/D5` retired. `F13` measures the enumeration directly at **385 ms = 35.8% of
  the HEAD bracket**. If `CGContextShowGlyphsAtPositions` reaches the recorder
  without it, that is the largest single item this file has found on the text path.
  **This is a hypothesis, not a size:** the lower-level API may perform the same
  overlap handling internally, in which case `L12` is worth nothing. It is cheap to
  settle -- one commit, one `quick` run -- and it is the natural next candidate.
- Order in force for the remainder, unchanged from `D4` except for `L1`'s removal
  and `L12`'s promotion: **`L12` (measure the enumeration hypothesis first, since it
  is cheap and would re-rank everything), then `L4` (24.5%), then `L6`, then `L5`.**
  `L6` rises relative to `D4`: `F13` found `fill(rect)` does map one call to one
  entry, and 71 ms of the dedup block sits under fill entries, so `L6`'s premise
  survives `F13` intact where `L1`'s did not.
- What every remaining lead now has to answer before implementation: **does the API
  I am calling fewer times map my calls to display-list entries one-for-one?** For
  `fill(rect)` -> `fill(rects)` the answer is yes and it is visible in `F1`'s
  inventory. For `CTFontDrawGlyphs` it was no, and nothing in this file asked the
  question until a benchmark did.

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

- ~~**Bypassing `CTFontDrawGlyphs` as a standalone candidate.**~~ **VOID -- see
  `D5`.** This entry read: "`F6`: the wrapper is a ~2.7%-of-bracket pass-through and
  a strict subset of `L1`." Both halves failed. `L1` is rejected (`F13`), so nothing
  is a subset of it, and the 2.7% came from `F6`'s `359 - 284 - 24` subtraction --
  the parent-minus-child sizing `17/D5` retired. The wrapper's enumeration measures
  385 ms, 35.8% of the bracket. `L12` is a live lead and goes first.
- **Sizing any glyph-drawing candidate per glyph.** `F6` measured the split:
  59% per-call, ~15% per-glyph. A pitch that multiplies a per-glyph cost by the
  cell count is wrong by roughly 4x in the direction that makes it look good.
- **Quoting `F8`'s 27% array-growth figure *as an inlining attribution*.** It
  rested on exactly the parent-minus-child reading `17/D5` retired a candidate
  for. `F11` has since met the precondition by deletion-and-measure and bounded
  the figure from below at ~30%, so the number is now quotable -- but cite `F11`
  for it, not `F4`'s attribution.

## Open questions and caveats

- **Every share in `F4` is now stale.** All of them are re-analysis of one
  existing 30-second `content-churn` trace at `4ecb032` (`17/F1`), taken before
  `F10` and `F11` roughly halved the bracket. The *absolute* millisecond figures
  and `F6`'s internal decomposition of the recorder node still describe HEAD's
  unmodified code paths; the *percentages* describe a denominator that no longer
  exists. Convert before pitching (the second investigation rule), and take the
  capture the ledger now requires before `L1`. Doc 9's two-profile rule is still
  unsatisfied.
- **Loop profiling mode forces a full-viewport redraw**, so the bracket was
  measured at maximum glyph count. The ratios in `F4` are more robust to this
  than absolute shares would be, but `L1`'s and `L6`'s wins scale with the run
  count the stimulus produces, and `F9` shows the two churn workloads sit at
  opposite ends of that. Neither reflects a real TUI.
- **`F8`'s array attribution is confirmed from below** by `F11`: at least ~30% of
  `F4`'s bracket, measured by deletion rather than by frame subtraction. What
  remains unmeasured is the exact cmap/buffer split, and `L4`'s residue now applies
  only to the non-ASCII cells that still traverse the buffers.
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
- **`style-churn` has now been decomposed (`F12`) and the assumption it inherited
  was false.** `17/F4` found it CPU-indistinguishable from `content-churn` at rest,
  and this file assumed the bracket decomposition matched. Totals do match within
  6%; composition does not (`drawTextRuns` 68.4% vs 81.3%, fills 18.6% vs 7.0%).
  `L1`'s `F9` read is against measured baselines now, not assumed-identical ones.
- **`terminal-feed` still has no on-CPU mode** (`17/F2`), and nothing in this
  file needs it: every lead is in the draw path.
- Untracked `notes.md` and `plans/wip/*` were present in the tree during the
  original capture and are still present now. They do not enter the build, but
  they **do** enter a paired comparison's candidate tree; read the printed path
  list before believing any benchmark run that follows from this file.

## Outcome

**Survey complete; ranked; `L3` (`F10`) and `L2` (`F11`) implemented and confirmed;
bracket re-captured and the remainder re-ranked (`F12`, `D4`); the rest of Phase 4
still gated.** Fifteen leads, five of them decidable today by the frozen draw
verdict, three pre-rejections added, one reading corrected before it reached code
(`F6`), and one corrected after (`F11`'s withdrawn bound).

The two landed commits cut the draw bracket from 1,879 ms to 1,075 ms of on-CPU
time on `content-churn` (-42.8%, `F12`) -- corroborating the paired benchmark's
-49.4% on an independent instrument -- and the bracket is now ~60%
CoreGraphics display-list entry recording, which is what makes `L1` (18.8-21.6%
plus the dedup block it shrinks) the largest remaining lead, ahead of `L4` (24.5%),
`L5`, and `L6` -- non-additively.

Ten results are worth more than the ranking:

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
6. **An estimate can be low without being wrong** (`F11`). `F6`'s lesson was that
   the obvious reading of a profile node oversizes a lead. `L2` is the mirror: the
   10-14% was an honest size for *the change proposed* (memoize the cmap), and the
   change actually built skipped the surrounding buffer traffic too, so it
   measured ~4x larger. Both failures come from the same habit -- sizing a node
   instead of sizing the code path a specific edit removes.
7. **A ranked lead list decays as soon as you start spending it** (`F12`, `D4`).
   Two commits halved the bracket, and with it every share the ranking was built
   from -- promoting `L4` from unconfirmed tier 2 into tier 1, re-sizing `L1`
   upward, and falsifying an inherited assumption that the two churn
   workloads decompose alike. None of that was visible without a capture, and the
   ledger had explicitly argued a capture was unnecessary. **Re-measure the
   denominator after every landed lead, not after the last one.**
8. **A pre-registered prediction fired against this file's own favourite lead, and
   was allowed to kill it** (`F9`, `F13`, `D5`). `L1` was ranked first in `D1` and
   again in `D4`, and `F9` had written down in advance that `content-churn` and
   `style-churn` moving *together* would mean the mechanism was misattributed. They
   moved together, 31% in the wrong direction. The mechanism -- that our
   `CTFontDrawGlyphs` call count controls the display-list entry count -- was false:
   the wrapper enumerates and re-splits by geometry. `F6` had the evidence and read
   "time reaches the delegate" as "the wrapper is a pass-through" when it meant "the
   wrapper calls the delegate repeatedly."
9. **The question every batching lead has to answer, which this file did not ask
   until a benchmark asked it for us:** does the API I intend to call fewer times map
   my calls one-for-one onto display-list entries? For `fill(rect)` yes; for
   `CTFontDrawGlyphs` no. Reducing call counts is only a proxy for reducing entries,
   and a proxy is not a mechanism.
10. **The decidable region is now the small one.** The draw bracket is 6% of the
   workload and `TGlyphOutlineDictionaryCache` alone is 10% -- 1.7x the bracket,
   off-thread, and unscoreable by any rule this project has (`17/D7`, `L9`).
   Tier 1's remaining leads are real and worth taking, and they optimize 6% of the
   process. That framing belongs in any future decision about whether to keep
   grinding the CPU path or to reopen `L14`/`L15`.
