# Per-cell CoreText typesetting on the render thread

Research started: 2026-08-30.
Continues: [39-kitten-render-benchmark/README.md](../39-kitten-render-benchmark/README.md)
(`39/H7`, `39/F13`, `39/F16`, `39/F22`) and
[4-fallback-glyph-batching.md](../4-fallback-glyph-batching.md) (`4/H3`'s
revival trigger).

- [findings.md](findings.md) -- the evidence chain. `F1` is the baseline reading
  of the render thread on the kitten `unicode` arm with a frame counter beside
  it, plus three throwaway experiments that price each layer of the cost. `F2`
  is the headless `fallback-shaped` draw arm `T1` asked for: its absolute
  per-frame cost, its A/A control, and the decision rule proposed for it.
- [decisions.md](decisions.md) -- the decision log. `D1` freezes the
  `fallback-shaped` rule `F2` proposed; `D2` chooses the shape-once cache with
  batched glyph submission over the ligature-only and `CTLine`-memo shapes.

## Purpose

Research 39 closed with DanTerm ahead of Ghostty on every kitten arm, but it
left one mechanism unowned: on the two Unicode arms DanTerm's main thread draws
at a full core beside the parse (`39/F22`: 2.00 process cores, main at 100%),
and `39/F13` read three quarters of that thread as `CTLineCreateWithAttributedString`.
Inside it, half is not shaping at all -- CoreText constructs a font object and
asks the preferences system for the user's languages, per call, per frame.
`39/D9` deferred the item because it moves no MB/s (`39/F16`), and it maps to no
ladder arm: every `kitten-feed-*` arm is headless, and both serialized draw
workloads draw printable ASCII, which never reaches this path.

This doc owns that mechanism: what the render thread does per cell that the
base font cannot map, why that costs about a core, which cache layer DanTerm
lacks against the terminals it is measured against, and a measurement route
on which a fix can be decided. The metric is main-thread CPU per frame and per
cell, never MB/s -- `39/F16` settled that drawing decides no feed rate at HEAD.
The user-observable claims are two: a frame rate that is set by the draw
rather than the display (`F1`: 21 frames per second where the panel offers
120), and a core of heat and battery for as long as CJK or cluster-heavy text
streams.

## Investigation rules

- The deciding quantity is main-thread CPU per rendered frame, read as
  `renders` per second from the frame-rate log (`DANTERM_FRAME_RATE_LOG`,
  `app/TerminalFrameRateSampler.swift`) beside the main thread's `%CPU` from
  `ps -M`, and as the per-frame draw bracket on a headless arm once one exists.
  A kitten MB/s figure is context, never a verdict here; `39/F16` shows it
  cannot move.
- `sample` ranks frames inside a thread and undercounts a dispatch workloop
  (`39/F3`). Every share below names the tool it came from and the thread it is
  a share of.
- Record the window state and the pane grid with every number (`39/F16`'s
  rules bind: an occluded slot draws, a hidden one is App-Nap-throttled).
- A sample share is not recoverable time: doc 11 measured the discount at
  about 3x (`11/F2`, `11/F4`). Size a fix on a paired per-frame reading, not on
  the share it removes.
- The two shipped draw workloads are the regression gate for the fast path:
  a change here ships only with `content-churn` and `style-churn` not `slower`
  on `confirm`, because the fast path (`CTFontGetGlyphsForCharacters` plus
  `showGlyphs`, docs 3 and 18) is what those two measure and what this doc
  must not disturb.
- Read [agent-docs/terminal-performance.md](../../../agent-docs/terminal-performance.md)
  and [agent-docs/measurement-discipline.md](../../../agent-docs/measurement-discipline.md)
  before planning against any figure here. "A profile share is not a trigger":
  this doc's trigger is the frame rate and the core, not the share.
- Every experiment in `F1` was a throwaway on an uncommitted tree and was
  reverted. None of them is a design; `D2` decides the shape.

## Trigger and current evidence

### What research 39 left

`39/F13` (HEAD `0e1dc83b`, `sample`, main thread, kitten `unicode` and
`unique_unicode`, frontmost, 66x179): `drawTextRuns` 96-99% of the main thread,
`CTLineCreateWithAttributedString` 74-81%; under `TGlyphEncoder::EncodeChars`
(66-70%), `TAttributes::CopyOfFontWithLigatureSetting` ->
`CTFontCreateCopyWithAttributes` -> `TFont::TFont` 23%, `TFont::SetExtras` ->
`CFLocaleCopyPreferredLanguages` 11%, `TFont::ShapesAnyPreferredLanguage` ->
`IsAnyLangSysTagInPreferredLanguages` 24%; `TLine::DrawGlyphs` 6-7%. On `ascii`
the same thread is `CGContextFillRect` memset 48% and `CGSColorMaskCopyARGB8888`
22%. `39/F16`: the arms read the same MB/s with the main thread idle. `39/F22`:
DanTerm 2.00 cores with main at 100%; Ghostty 1.82 with a renderer worker at 86%.

### What the code does (HEAD `606708cc`)

`CGContextRef.drawTextRuns` (`lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift`)
walks each planned text run -- a run breaks on any change of foreground, bold
or italic and never spans rows (`13/D1`) -- and sorts every cell into one of
three paths:

1. **Sprites**: single scalars in the eight procedural families, drawn as
   geometry ([docs/terminal-sprites.md](../../terminal-sprites.md)). No font.
2. **The fast path**: printable ASCII from the face's eager glyph table
   (`18/L2`), any other single BMP scalar through one batched
   `CTFontGetGlyphsForCharacters` per run, then one `showGlyphs` (or
   `CTFontDrawGlyphs`) per run (`3`, `18/L12`). No typesetting, no
   attributed string, and the four styled `CTFont`s are built once per metrics
   (`11/F4`).
3. **The fallback path**, `drawTextCell`: every multi-scalar cluster, every
   scalar above `UInt16.max`, and every scalar the base face's cmap does not
   map (glyph zero). Each such cell builds a `String`, an
   `NSAttributedString` with three attributes -- the run's `CTFont`, its
   `CGColor`, and `kCTLigatureAttributeName: 0` -- calls
   `CTLineCreateWithAttributedString`, saves state, clips to the cell,
   `CTLineDraw`s, restores. Nothing is kept between cells or frames.

The default font is the monospaced system font at 13 pt (design doc `H6`),
which maps no CJK; so on the `unicode` arm every cell is a fallback cell, and
on `unique_unicode` every cell is one because it is a four-scalar cluster.
`39/F13`'s "per text run" is therefore per *cell*: `drawTextCell` is inlined
into `drawTextRuns` in the release object, and the chain it read is the
per-cell one.

### Frame cadence

`TerminalPaneSessionController.consume` sets the next fence no earlier than one
display refresh interval after this one, so publishes are capped at the
panel's rate; but a publish presents synchronously
(`TerminalFrameSwapchain.presentPending` -> `drawRenderFrame`) and the next
fence cannot run until the draw returns. When a frame takes longer than a
refresh, the draw is the cadence. `F1` reads it: **21 renders per second** on
the `unicode` arm at 66x179 with the main thread at 100%, so one frame costs
about 47 ms, and every frame is a full-viewport redraw -- at 123 MB/s the
stream rewrites the 66-row alternate screen a few hundred times between two
frames, so the folded damage is `.full`. That is 5,874 fallback cells per frame
(66 rows x 89 wide cells), about 8 us per cell, of which `F1`'s experiments
attribute roughly 7 us to `CTLineCreateWithAttributedString` and 1 us to
drawing the line.

### What the references do

Grepped under `references/` (ghostty, kitty, iTerm2; alacritty and wezterm are
engine-only sparse checkouts and hold no renderer). None of the three typesets
a line per cell per frame, and each keeps up to three cache layers:

| Layer | Ghostty | kitty | iTerm2 | DanTerm |
| --- | --- | --- | --- | --- |
| Font object per style | `src/font/shaper/coretext.zig#Shaper.getFont` caches the attribute dictionary holding the `CTFont` per collection index | `kitty/fonts.c#FontGroup` index array | `sources/FontTable.swift#fontForCharacter`, bold/italic on `PTYFontInfo` | `TerminalFontSet`, once per metrics (`11/F4`) -- **has it** |
| Shaped run (text, style) -> glyphs | `src/font/shaper/Cache.zig#Cache`, keyed by run hash, 256x8 LRU buckets | none; re-shapes with HarfBuzz, caches the sprite below | `CTLine` cache keyed by attributed string: generational per frame in `iTermTextDrawingHelper.m#drawTextOnlyAttributedStringWithoutUnderline`, a 10,000-entry LRU in `iTermMetalPerFrameState.m` | **none** for fallback cells; the fast path has no shaping at all |
| Rasterized glyph per (font, glyph id) | `src/font/SharedGrid.zig#GlyphKey` atlas, unbounded | `kitty/glyph-cache.c#sprite_pos_map_hash` per font | `iTermTexturePageCollection.h#TexturePageCollection` | none -- CoreGraphics rasterizes per draw, and its own glyph cache sits off-thread (`17/D7`, `18/L9`) |

Ghostty's CoreText shaper also builds the `CTFont` with its feature settings
once and never puts a ligature attribute on the string; Gecko does the same
(`kCTFontFeatureSettingsAttribute` on the descriptor, cached per feature
flag). iTerm2 puts `kCTLigatureAttributeName: @0` on every attributed string --
DanTerm's exact shape -- and caches the resulting `CTLine` instead. No
reference terminal sets `kCTLanguageAttributeName`; WebKit sets it per font
for correctness, not speed. Apple documents none of the internal costs; the
ligature-copy and preferred-language mechanisms are read from the frames in
`39/F13` and `F1`, not from a contract.

### What this project already measured on this path

- Doc 3 built the fast path and kept the per-cell clipped `CTLine` as the
  fallback deliberately, because unclipped fallback glyphs bled into
  neighbouring cells; it declined a glyph atlas or cross-frame cache until "a
  serialized redraw profile shows a renderer node large enough to justify"
  one. `F1` is that profile.
- Doc 4 saw this exact chain on btop -- `CTLineCreateWithAttributedString` 29%
  of the main thread, most of it `TFont::NeedsShapingForGlyphs ->
  ShapesAnyPreferredLanguage` -- and found every fallback was a braille or
  arrow cmap miss, which the sprite families then removed. Its `H3`, batching
  fallback-font resolution per run, was never built, with the revival trigger
  "non-sprite cmap misses dominating real output (CJK-heavy output in a
  non-covering font)". The kitten `unicode` arm is that stimulus.
- Doc 11 sized the fast path at 4.06 ms for a full 179x66 text frame and closed
  on "it fits the 60Hz budget". That figure is the fast path; the fallback path
  at 47 ms per frame (`F1`) is outside it by 3x, so the budget claim does not
  cover CJK or cluster text.
- Docs 13, 14 and 18 own the fast path's remaining cost (`CTFontDrawGlyphs`
  display-list recording, color and fill batching, `L5`/`L6` gated on `18/D7`)
  and measured the fallback path at 4% of `drawTextRuns` on btop (`13/F2`).
  `18/F1` inventories `CTLineCreateWithAttributedString` as "fallback path
  only" and no doc 18 lead targets it. This doc defers everything on the fast
  path to doc 18 and takes only the fallback path.
- The draw-workload gate is ASCII: `scripts/terminal-benchmark-producer.py`'s
  `redraw_screen` writes letters, digits and dots, so `content-churn` and
  `style-churn` never enter `drawTextCell`, and neither does
  `benchmark-headless-draw`'s `text-shaped` fixture. `T1` added
  `benchmark-headless-draw`'s `fallback-shaped` workload (`F2`), which is the
  only arm that reaches the path; no *frozen rule* covers it yet.

## Current hypotheses

### H1 -- The whole core is the per-cell `CTLineCreateWithAttributedString`, and a cross-frame memo of its result removes it -- CONFIRMED by `F1`

Mechanism: each fallback cell typesets a one-cluster attributed string from
scratch, and on a full-viewport frame of CJK that is 5,874 typesettings per
frame. The result depends only on (face, cluster scalars, colour), which is a
small, repeating set. Evidence (`F1`): `CTLineCreateWithAttributedString` 75%
of the main thread at 21 frames per second; memoizing the `CTLine` per (text,
face, colour) across frames with no other change took the frame rate to
96-103 per second -- the panel's cap -- with the main thread 63% busy, so the
frame fell from about 47 ms to about 6 ms. Competing explanation: the cost is
the draw or the attributed-string allocation rather than typesetting -- rejected
by the same run, where `TLine::DrawGlyphs` stays at 22% of a much smaller
thread and `NSAttributedString` construction is under 1%. What the memo
leaves is `H5`.

### H2 -- `kCTLigatureAttributeName` on the string makes CoreText copy the font per cell -- CONFIRMED by `F1`

Mechanism: a ligature setting on the attributed string is a font attribute in
CoreText's model, so `TTypesetterAttrString::Initialize` calls
`TAttributes::CopyOfFontWithLigatureSetting` -> `CTFontCreateCopyWithAttributes`
-> `TFont::TFont` -> `TFont::SetExtras` for every string carrying one, and the
new font's `SetExtras` asks `CFLocaleCopyPreferredLanguages`. Evidence
(`39/F13`, `F1`): 23% of the main thread under `TFont::TFont` and 11-15% under
`SetExtras`; removing the attribute (leaving ligatures at CoreText's default,
which a one-cluster string cannot form anyway) took `TFont::TFont` from 19% to
1%, removed `CopyOfFontWithLigatureSetting` and `SetExtras` entirely, and moved
the frame rate 21 -> 36-41 per second. Competing explanation: the copy is
triggered by the colour or the font attribute -- rejected, since those stayed
and the copy left. The ideal shape bakes the ligature policy into the face
once (`kCTFontFeatureSettingsAttribute` on the descriptor, Ghostty's and
Gecko's shape), which `D2` must weigh against the base font's own ligature
behaviour on the fast path (design doc `H6`: ligatures disabled).

### H3 -- An explicit language attribute short-circuits the preferred-language walk -- PARTIALLY CONFIRMED by `F1`, insufficient alone

Mechanism: with no language on the string, CoreText asks the preferences
system which languages the user prefers, per typesetting, to decide whether
the font shapes any of them. Evidence (`F1`): `kCTLanguageAttributeName: "en"`
removed `TFont::NeedsShapingForGlyphs` (24% -> 0%) and halved
`CFLocaleCopyPreferredLanguages` (11.5% -> 5.7%), frame rate 21 -> 22-25. But
`ShapesAnyPreferredLanguage` survives at 12-20% inside
`TOpenTypeMorph::TOpenTypeMorph` -- the shaping engine asks it again for the
*fallback* font it chose -- and `H2`'s font copy still asks it in
`SetExtras`. So the attribute buys a fifth of the frame and only the memo
(`H1`) removes the rest. Open question: a fixed `"en"` may change Han glyph
selection against the user's locale preferences; the value would have to be
the user's first preferred language, resolved once. Not a candidate on its
own.

### H4 -- The draw sets the frame cadence, so a draw fix is a frame-rate fix and not an MB/s fix

Mechanism: the delivery fence is paced at one display refresh, but it waits on
the synchronous present, so a draw longer than a refresh is the pace. Evidence
(`F1`): 21 renders per second at 100% main thread, 36-41 after `H2`, 96-103
after `H1`, with MB/s flat at 121-124 across all four runs and the process
falling from 2.0 to 1.6 cores. Competing explanation: the frame counter
counts publishes rather than presented frames -- rejected, `renders` is the
count of `presentPending` returning a store, and `publishes` matches it in
every window. What a user sees: a CJK stream that repaints 21 times a second
where an ASCII one repaints at the panel rate, and a core of heat for the
duration. This is the claim `39/D9` said was missing; it is measured now.

### H5 -- After the memo, the remaining draw is per-cell `CTLineDraw` plus the full-frame fill, and glyph-id batching per fallback font takes the first

Mechanism: a cached `CTLine` still draws one cell at a time inside its own
`saveGState`/`clip`/`restoreGState`, and `CTLineDraw` re-enters CoreText's run
walk per cell. Evidence (`F1`, cached run): `drawTextCell` 42% of a 63%-busy
main thread, `TLine::DrawGlyphs` 22%, `CTFontDrawGlyphs` 18%,
`CGContextFillRect` 26%. The fast path already shows the shape that removes the
first: glyph ids and positions gathered per run, one `showGlyphs` per (font,
colour) batch. Extracting `CTRunGetGlyphs` and the run's font from the cached
line on a miss, and batching the draw by fallback font, would put fallback
cells on the same submission path as ASCII. The fill is `39/F13`'s `ascii`
finding (memset of the whole frame per full-viewport frame) and doc 18's `L6`;
this doc does not take it. Distinguishing experiment: `T4` -- the shaped-glyph
cache in place of the `CTLine` cache, read on the headless arm; confirmed if
`CTLineDraw` leaves the profile and the per-frame bracket falls further with
`content-churn` unmoved.

### H6 -- The real-workload exposure is bounded by how many fallback cells a frame repaints, and no evidence yet says it is large outside kitten

Mechanism: kitten repaints 5,874 fallback cells per frame; a CJK `cat`, a
Japanese man page, or a Chinese TUI repaints fewer rows per frame and idles
between keystrokes, and the memo hits on repeated characters. Evidence: none
either way -- `4/T1` found 5% fallback cells on btop, all of them since taken
by sprites. Competing explanation: any scrolling CJK stream is a full-viewport
repaint per frame at any speed above one screen per refresh, so the kitten
figure is the ordinary case for `cat` on a CJK file. Distinguishing
experiment: `T2` -- the frame-rate log on a real CJK stream and on a CJK TUI,
read for renders per second and main-thread `%CPU`; confirmed bounded if a
real stream reaches the panel rate with the main thread under a quarter of a
core at HEAD.

## Candidate direction, pending evidence

Written ahead of `D2`, which chose the ideal below; the text stands as the
record of the options. The ideal structure is the one in which the cost
cannot recur: **a cell's fallback shaping is resolved at most once per (face,
cluster)**, and after that a fallback cell is submitted the way an ASCII cell
already is -- glyph ids and positions, batched per (font, colour) into
`showGlyphs`/`CTFontDrawGlyphs`. Concretely:

1. The face carries its ligature policy in its descriptor
   (`kCTFontFeatureSettingsAttribute`), and the attributed string carries no
   `kCTLigatureAttributeName` (`H2`). The language, if one is set at all, is
   resolved once from the user's preferences, not pinned to a literal (`H3`).
2. A bounded cache keyed by (face identity, cluster scalars) holds the shaped
   result of one typesetting: the fallback `CTFont` CoreText chose and the
   glyph ids with their advances, extracted with `CTRunGetGlyphs` and the run's
   `kCTFontAttributeName`. Colour stays out of the key -- it is a draw-time
   fill, as on the fast path -- so the memo is per cluster and not per
   (cluster, colour). Face identity is the metrics' font set, so a font change
   replaces the cache the way it replaces the swapchain.
3. `drawTextRuns` submits fallback cells from the cache in batches per fallback
   font, clipped as a batch to their union rect rather than per cell, keeping
   doc 3's containment rule (the span clip is the final boundary) without a
   `saveGState` per cell.

What is wrong with the ideal, stated so `D2` can weigh it: it is the largest
of the shapes, it adds a third submission path beside the fast path and the
sprite path where doc 18's `D6` already called two "the real maintenance
cost", and it must get colour glyphs (emoji through `CTFontDrawGlyphs` with the
fallback font, never `showGlyphs`), variation selectors and ZWJ sequences
(one cluster, one cache key, so these are fine), and a synthesized-italic
fallback font with a non-identity matrix (the `directDrawFont` refusal applies)
right. Its memory is bounded by the cache's cap, which must be chosen. None of
that is a reason it cannot be built; it is the cost of building it.

The cheap shape beside it: `H2` alone, one attribute removed from a dictionary
literal and the policy moved into the face, priced at 21 -> 38 frames per
second by `F1`. It halves the cost and leaves a per-cell typesetting in place,
so the core is still spent, only half as fast. The middle shape is `H1`'s
`CTLine` memo as the experiment ran it, which reaches the panel rate but keeps
`CTLineDraw` per cell (`H5`) and a colour in the key. This is a trade-off, and
`D2` records which one is chosen and why.

## Task ledger

### Phase 1 -- reproduce and attribute on a frame metric

- [x] Reproduce `39/F13`'s chain with a frame counter beside it, and price
  each layer with a throwaway. `F1`: 21 renders per second at 100% main
  thread, 5,874 fallback cells per frame; the language attribute alone
  22-25, the ligature attribute removed 36-41, the cross-frame memo 96-103
  with the main thread at 63%. All three reverted. DONE
- [x] `T1` -- a headless draw arm for the fallback path: a third
  `DrawBenchmarkWorkload` in
  `lib/TerminalCore/Sources/TerminalDrawBenchmarkSupport/TerminalDrawBenchmarkSupport.swift`
  (`fallback-shaped`: CJK rows and multi-scalar clusters at 179x66, styles at
  token boundaries like `text-shaped`) so `just benchmark-headless-draw`
  brackets `drawRenderFrame` per frame on exactly this path, paired, at
  ~0.5-1% resolution. Record its A/A control in `F2`. This is the gate for
  Phase 2; nothing ships without it, because no frozen arm sees the path.
  DONE, committed at `3538b7b5`. `F2`: 130.5 ms per full 179x66 frame against
  `text-shaped`'s 3.06 ms (42.6x at equal columns, 19.6 us per fallback cell);
  ten A/A `--both-directions` invocations hold `realEffectPercent` inside
  +/-0.69% at SD 0.25%, and the proposed rule is +/-1.00% on that quantity with
  an `orderBiasPercent` guard at 2.5%. Frozen by `D1` as a floor, not a
  screened cell. The arm carries a +1.0 to +1.7% slot bias the ASCII arm does
  not, so a single-direction run of it decides nothing.
- [ ] `T2` -- the real-workload exposure (`H6`): the frame-rate log and
  `ps -M` on an optimized slot during a CJK `cat` of a large file, a CJK man
  page under `less` with the key held, and a CJK TUI if one is to hand. Record
  renders per second and main-thread `%CPU` at HEAD in `F3`. Decides how the
  user-observable claim is worded, not whether `T1` is built. RESEARCH
- [ ] `T3` -- confirm the fallback set is what this doc says it is: instrument
  a throwaway counter of fallback reasons (cmap miss, multi-scalar, non-BMP)
  on the `unicode` and `unique_unicode` arms and on `T2`'s streams, the way
  `4/T1` did, so `D2`'s key design covers the cells that occur. RESEARCH

### Phase 2 -- decide and fix, gated on `T1`

- [x] `D1` -- freeze the `fallback-shaped` rule: `realEffectPercent` from one
  `--both-directions` 8-round invocation, +/-1.00%, valid only with
  `orderBiasPercent` under 2.5%; accepted as a floor argued from A/A spread,
  not a screened detection cell, so it decides large effects only. DONE
- [x] `D2` -- choose the shape: the ideal shaped-cluster cache keyed by (face,
  cluster) with batched per-(font, colour) submission, over `H2` alone and the
  `CTLine` memo; the ligature policy lives in neither a string attribute nor a
  descriptor feature, because a one-cluster string cannot ligate and the fast
  path never shapes. Plan:
  [plans/wip/plan-shape-once-fallback-cells.md](../../../plans/wip/plan-shape-once-fallback-cells.md). DONE
- [ ] `T4` -- implement `D2`'s shape. Gate: `benchmark-headless-draw` on
  `fallback-shaped` in both directions under `D1`'s rule; `text-shaped` not
  `slower`; `just benchmark-confirm` with `content-churn` and `style-churn`
  not `slower`; a frame-presence check that no
  `CTLineCreateWithAttributedString` or `CTLineDraw` remains under
  `drawTextRuns` on a steady-state `unicode` frame; and `F1`'s frame-rate
  reading re-taken on the `unicode` arm as `F3`. TODO
- [ ] `T5` -- pixel equivalence: the fallback path is the one doc 3 kept
  clipped because glyphs bled. Any batch clip in `T4` needs the existing
  rendering snapshot tests to pass unchanged on a CJK, an emoji, a ZWJ
  sequence and a bold-italic fallback cell. TODO

### Phase 3 -- close

- [ ] Re-take `F1`'s reading on the shipped tree: renders per second and
  main-thread `%CPU` on both Unicode arms, frontmost, at one recorded grid,
  with `39/F22`'s method for the window state; and a whole-process core count
  beside `39/F22`'s 2.00. Close when the frame rate sits at the panel's rate
  and the main thread is under half a core on `unicode`. TODO

## Rejected

- **A language attribute as the fix.** `F1`: `kCTLanguageAttributeName` buys
  about a fifth of the frame and leaves `ShapesAnyPreferredLanguage` inside the
  shaping engine's own run. Kept only as a component of `D2`'s shape, and only
  with a value resolved from the user's preferences, because a literal can
  change Han glyph selection.
- **`CTTypesetter` reuse.** The typesetter's saved state pays off when several
  lines are cut from one string; a one-cluster string per cell gets one line
  and the same `TTypesetterAttrString::Initialize`. No gain to measure.
- **Moving the fallback draw off the main thread.** It relocates the core; it
  does not remove it, and doc 17 established that no instrument here can
  decide an off-thread cost (`17/F16`). The memo removes the work.

## Open questions and caveats

- `F1` is one session, one slot, one arm, `sample` at 1 ms for 6 s per run,
  and each experiment is a single run. The frame-rate deltas are 1.8x and 4.7x,
  far above any run-to-run spread seen in research 39, but they are not paired
  readings and carry no verdict; `T1` is where a verdict comes from.
- The default slot font is the monospaced system font. A user font that covers
  CJK (many Nerd Font builds do not, most CJK monospace fonts do) sends those
  cells down the fast path, and the cost moves to whichever scalars that font
  lacks. The mechanism is per fallback cell, not per CJK cell; `T3` names the
  set.
- The `unicode` arm's corpus is a fixed Chinese lorem ipsum plus a short
  miscellany repeated 1,024 times (`references/kitty/tools/cmd/benchmark/main.go#unicode`),
  so its distinct-cluster set is a few hundred and the memo's hit rate is near
  100% after the first frame. Real CJK text has thousands of distinct
  characters; the cache cap in `D2` should be sized on `T2`'s streams, not on
  kitten.
- Colour glyphs: `showGlyphs` through `CGContext` draws outlines only; emoji
  and other `sbix`/`COLR` faces need `CTFontDrawGlyphs` with the fallback
  `CTFont`. The ideal's batch submission must route on the font, as the fast
  path already routes on `directDrawFont`.
- The experiments ran with the tree at `606708cc` and no other change; the
  cached run's cache was unbounded, which is fine for a 15 s run and not for
  a design.
- Nothing here changes the parse thread or any `kitten-feed-*` verdict;
  `39/F22`'s table stands.

## Outcome

Investigation in progress.
