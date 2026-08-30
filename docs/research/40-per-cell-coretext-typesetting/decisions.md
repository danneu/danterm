# Decisions -- auditable decision log

Rejections made during scoping (a language attribute as the fix, `CTTypesetter`
reuse, moving the draw off the main thread) are in [README.md](README.md)
`## Rejected`, with their reasons; none rests on a measurement this file
would own.

## D1 -- Freeze the `fallback-shaped` decision rule

DECIDED 2026-08-30: freeze `F2`'s proposed rule as written. **`fallback-shaped`
decides on `realEffectPercent` from one `--both-directions` invocation at 8
rounds per direction, at +/-1.00%. The verdict is valid only when that
invocation's `orderBiasPercent` is below 2.5%; a run above it is invalid and is
re-run, never read.** A single-direction run of this arm -- what
`just benchmark-headless-draw` still produces with no candidate checkout --
decides nothing at any magnitude: it is descriptive, and it is not quoted as
a verdict even above `F2`'s +/-2.70% figure, because that figure is a 5%-effect
cell and the rule here is the two-direction one.

The evidence is `F2`: ten A/A `--both-directions` invocations hold
`realEffectPercent` inside +/-0.69% at SD 0.25% and mean +0.20%, so +/-1.00% is
3.2 SD above the A/A mean and 1.46x the worst A/A magnitude seen; the guard is
1.5x the worst `orderBiasPercent` observed (+1.68%) on an arm whose bias never
crossed zero in ten runs; and the interleaved `text-shaped` control (bias
+0.07% mean) shows the asymmetry is the workload's, not the session's. This is
the step a script must not take (`39/D2`): `terminal-headless-draw-compare.py`
reports statistics and takes `--threshold` from its caller, and the act here is
a human reading `F2` and accepting it.

### Which caveat is accepted

`F2` raises two, and asks the freezer to name one. This decision accepts the
**first: the threshold is a floor argued from A/A spread plus the instrument's
documented ~0.5-1% revision-pair resolution, and not a screened cell with a
measured detection rate.** It does not accept the second reading, that the arm
has been screened for detection the way `39/F5` screened the `kitten-feed-*`
arms: no injected-effect series exists for this arm, so the rule bounds false
positives and bounds detection not at all.

That is acceptable here for one reason, and it limits what the rule may be used
for. Every candidate `D2` weighs is priced by `F1` at 1.8x to 7x on the frame,
which on this arm is a `realEffectPercent` of -45% to -85%. Detection at that
magnitude is not in question; what the rule must do is refuse to call a
change-free pair `faster`, which is exactly what ten A/A invocations bound.
So: **the rule decides a change on this path whose expected effect is large.
For a claim under about 3% -- a tuning of the fix, a cache-cap change read as
a speed claim -- the rule is not calibrated, and the reading is descriptive
until a screened cell exists.** Freezing at a floor is the honest cell for a
gate that must exist before Phase 2 can ship (`T1`); a screened cell, if the
arm ever needs to resolve a small effect, is a later task with its own finding.

Two further conditions bind a verdict run, taken from the instrument's own
rules rather than from `F2`'s numbers:

- The host must be idle (`agent-docs/terminal-performance.md`). `F2` was
  collected at load average 1.8-2.2; its A/A spread is therefore an upper
  bound on an idle host, which is the safe direction for a false-positive
  floor, but a verdict run does not inherit that allowance.
- `text-shaped` is run beside it at the same parameters as the fast-path
  control, read for `slower`; and `content-churn` and `style-churn` must not
  read `slower` on `confirm` (README `## Investigation rules`). The
  fast path is what those measure and what this doc must not disturb.

Rejected alternative: leave the arm unfrozen and read Phase 2 descriptively,
with the frame-rate log as the claim. `F1` is one unpaired run per condition
and says so; a fix that reaches the panel's cap on the frame-rate log has
merely hit a ceiling that hides its remaining cost, which is `H5`'s whole
point. The headless bracket is the only instrument that sees the per-frame
cost below the cap.

Not decided here: whether the rule enters `DECISION_RULES` in
`scripts/terminal-benchmark-calibration.py` beside the GUI ladder's. The
headless compare is its own script with its own report shape and no rule
table; where the frozen number lives in code -- a default `--threshold` for
this workload, or a rule table the script grows -- is the implementer's, and
the plan under `D2` requires that the script print the frozen rule and its
guard beside the verdict so a report cannot be read without them.

## D2 -- Shape fallback cells once per (face, cluster) and submit them the way ASCII cells are submitted

DECIDED 2026-08-30: build the ideal from the README's `## Candidate direction`:
**a bounded cache keyed by (face identity, cluster scalars) holds the result
of one typesetting -- the `CTFont` CoreText's cascade chose and the glyph ids
with their positions -- and `drawTextRuns` submits fallback cells from it in
batches per (fallback font, colour), never through `CTLineCreateWithAttributedString`
or `CTLineDraw` on a cache hit.** The cache is born with the metrics' font
set and dies with it, so a font change replaces it the way it replaces the
swapchain. The ligature attribute leaves the attributed string and goes
nowhere: a one-cluster string cannot form a ligature and the fast path never
shapes, so the policy design doc `H6` states (ligatures disabled) is enforced
by the submission structure, not by an attribute or a descriptor feature. No
language attribute is set (`H3` stays rejected as a fix; the miss path pays
the preferred-language walk once per cluster instead of once per cell per
frame, which is bounded by the cache's cap). Plan:
[plans/wip/plan-shape-once-fallback-cells.md](../../../plans/wip/plan-shape-once-fallback-cells.md).

### The three shapes, beside each other

`F1` prices them on the kitten `unicode` arm at 179x66 frontmost: baseline
20-22 renders per second at 100% main thread.

| | Cheap: drop `kCTLigatureAttributeName` (`H2`) | Middle: cross-frame `CTLine` memo (`H1`) | Ideal: shape-once cache + batched glyph submission (`H1`+`H5`) |
| --- | --- | --- | --- |
| `F1` reading | 35-41 renders/s, main 100% | 95-103 renders/s (panel cap), main 61% | not run; `F1`'s memo profile puts `drawTextCell`'s per-cell `saveGState`/`clip`/`CTLineDraw`/`restoreGState` at 42% of the remaining thread, which is what this removes |
| Per-cell work on a steady-state frame | one typesetting, no font copy | dictionary probe, one `CTLineDraw` inside a clip | dictionary probe, glyph ids appended to a per-font batch |
| Ligatures | none formed (one-cluster string); policy stays a string attribute at default | none formed; attribute kept or dropped | none formed; no attribute anywhere; the fast path already shapes nothing |
| Combining marks, ZWJ, variation selectors | shaped per cell per frame, as today | shaped once per (cluster, colour), drawn from the line | shaped once per (face, cluster); every glyph of the cluster with its position is in the entry, drawn in the batch |
| Colour emoji | `CTLineDraw` handles it | `CTLineDraw` handles it | the entry records the run's font; the batch for that font goes through `CTFontDrawGlyphs`, never `showGlyphs`, so `sbix`/`COLR` faces draw as they do today |
| Fallback font selection | CoreText's cascade, per cell per frame | the cascade, once per key | the cascade, once per key; the entry stores the font it chose, so the choice is identical to today's for the same face and cluster |
| Colour changes | free | a second key per colour; the entry count multiplies by the palette in use | colour is not in the key; it is the batch's fill, as on the fast path |
| Memory | none | unbounded in `F1`'s experiment; a cap holds `CTLine` objects, which are large and opaque | a cap on small value entries (font reference, glyphs, positions); sized on `T2`'s streams, bounded regardless |
| Font change | nothing to invalidate | keyed on face identity, or dies with the font set | dies with the font set |
| Per-cell clip (doc 3's containment rule) | kept | kept | kept as an invariant, not as a `saveGState` per cell: an entry records at fill time whether its ink stays inside the cell span, and only an overflowing entry takes the clipped path |
| What it cannot fix | the core is still spent; 100% main thread at twice the frame rate | `H5`: `CTLineDraw` per cell, 42% of a 61% thread | the full-frame fill (`39/F13` `ascii`, doc 18 `L6`), which this doc does not take |

### Why the ideal, and what is wrong with it

The cheap fix is a one-line change that halves the cost and leaves the
mechanism intact: a typesetting per fallback cell per frame. It is the first
half of the ideal's miss path anyway, so it is not an alternative to it, only
a stopping point. The middle shape reaches the panel's cap, and the cap is
what hides its remaining cost: 61% of a core for `CTLineDraw` per cell plus
the fill, and an entry per colour. Both leave the fallback path as a third
kind of draw with its own per-cell state changes, which is the maintenance
cost doc 18's `D6` named.

The ideal puts a fallback cell on the submission path an ASCII cell already
takes -- glyph ids and positions, one call per (font, colour) batch -- so the
per-cell cost on a hit is a probe and an append, and the fast path's own
improvements (doc 18's `L5`/`L6`) reach fallback cells for free. That is the
structure in which the problem cannot recur: shaping happens at most once per
(face, cluster), and a frame of repeated CJK does no typesetting at all.

What is wrong with it, stated so the choice is a choice:

- It is the largest of the three. The miss path must extract glyphs, positions
  and the run font from the line (`CTRunGetGlyphs`, `CTRunGetPositions`, the
  run's `kCTFontAttributeName`), handle a cluster whose line has more than one
  run (a base from one fallback font and a mark from another is drawn as two
  batches), and record containment. Ghostty's CoreText shaper does exactly
  this extraction (`references/ghostty/src/font/shaper/coretext.zig`,
  `getGlyphRuns` -> `getGlyphs`/`getPositions`/`getStringIndices`), so the
  shape is known, not novel.
- A synthesized-italic fallback font carries a non-identity matrix, and
  `CTFontDrawGlyphs` applies it and leaves the context's font state modified
  (the `directDrawFont` note in `TerminalRenderExecution.swift`). Every
  fallback batch goes through `CTFontDrawGlyphs`, and the text matrix is reset
  per submission as the fast path already does; this is a discipline the fast
  path already carries, not a new one.
- It needs mutable state beside the draw. `TerminalFace` is immutable and
  `Sendable` by design (its own comment refuses a memo inside it), and
  `drawRenderFrame` is a free function with no state. So the cache is a
  reference-typed object the swapchain (and the headless harness, and a test)
  owns for the life of one metrics value and hands to the draw. That is one
  new parameter on a public entry point and one new owner; it is the price
  of not putting mutable state in a `Sendable` value.
- Its cap is a number nobody has measured against a real stream. `T2` is
  open. The plan sizes the cap by the arithmetic of a full 179x66 frame of
  distinct clusters plus headroom, and records that `T2` may move it; a cap
  too small degrades to the miss cost per cell, which is today's cost, never
  worse.

None of that is a reason it cannot be built. It is the cost of building it,
and the cheap and middle shapes each leave a core or half a core on the
table that this one removes. Chosen.

Beside it, for design input, not authority (`agent-docs/reference-sources.md`):
Ghostty caches shaped cells per run hash in a 256x8 LRU
(`references/ghostty/src/font/shaper/Cache.zig`) and sets ligature policy on
the font descriptor once (`kCTFontFeatureSettingsAttribute`,
`coretext.zig:141`); kitty re-shapes with HarfBuzz per run and caches the
rasterized sprite per (font, glyphs) (`references/kitty/kitty/fonts.c`,
`sprite_position_for`); iTerm2 caches the `CTLine` per attributed string,
which is the middle shape. None typesets per cell per frame.

### Confirmation criteria

The decision is confirmed when all hold:

1. `fallback-shaped` reads `faster` under `D1`'s rule, both directions, on an
   idle host. The expected magnitude is `F1`'s: at least the memo's 7x on the
   frame, i.e. `realEffectPercent` beyond -80%.
2. On a steady-state kitten `unicode` frame, `sample` shows no
   `CTLineCreateWithAttributedString` and no `CTLineDraw` under `drawTextRuns`;
   a frame-presence reading, not a share (`39/D5` criterion 2 says why).
3. `F1`'s reading re-taken (Phase 3): renders per second at the panel's rate
   and the main thread under half a core on `unicode`, frontmost, 179x66.
4. `text-shaped` not `slower` on the headless arm; `content-churn` and
   `style-churn` not `slower` on `confirm`; the render snapshot suite
   unchanged on CJK, emoji, ZWJ, combining-cluster and bold-italic fallback
   cells.

### The cap, measured (2026-08-30)

`T2` and `T3` are closed and the shipped cap of 16,384
(`ShapedClusterCache.defaultCapacity`) **holds unchanged**. `F4` and `F5`
measure the working set of every stream available:

| stream | distinct clusters | against the 16,384 cap |
| --- | ---: | --- |
| `cat` of 5,624 distinct characters of classical Chinese | 5,420 | 3.0x headroom |
| a held key in `less` over the same corpus | 1,649 | 9.9x headroom |
| kitten `unicode` | 327 | 50x headroom |
| kitten `unique_unicode`, 14 s | 252,795 | clears about 15 times |

So the arithmetic the plan sized the cap by -- one full 179x66 frame of
distinct clusters plus headroom -- is validated by the streams rather than
merely unrefuted: the largest real working set measured is a third of the cap,
and a stream large enough to reach it would have to hold more distinct
clusters than two classical novels put together. No code change follows, and
none is proposed: raising the cap would buy nothing measured, and lowering it
would trade headroom for memory nobody is short of.

What would move it: a stream whose distinct clusters exceed 16,384 in one font
set. `unique_unicode` is that stream and is synthetic; the real candidate is a
long CJK session that also carries a large emoji or ZWJ set, which nothing here
has measured. `AR1` still stands for it -- past the cap the cache clears and a
cell falls back to per-cell typesetting, which is the pre-`T4` cost and never
worse.

Not decided here: the cache's owner type, which the
plan reserves to implementation; and whether `T2`'s streams, once measured,
justify a language attribute resolved from the user's preferences (`H3`),
which stays rejected until a miss-path profile on a real stream says the
preferred-language walk matters at cache-fill rate. `F4` answers the second:
on the fastest real stream the whole miss path is 1.3% of the main thread
(`shapeCluster` 0.9%, `CTLineCreateWithAttributedString` 0.4%), so the
preferred-language walk inside it decides nothing and `H3` stays rejected.

## D3 -- The typesetter's reported positions are the placement contract, and `CTLineDraw`'s flip-time mark handling is not

Decided by the user during `T4`, on evidence found while implementing `D2`.

The draw submits a cluster's glyphs at the positions the typeset line reports
for them. Where `CTLineDraw` puts them somewhere else, DanTerm follows the
typesetter. This is a rendering change, scoped to clusters whose runs carry a
nonzero cross-stream glyph origin; every other fallback cell is pixel-identical
to what shipped before.

### What forced the choice

`D2`'s cache replays a cluster from `CTRunGetPositions`. Under the executor's
y-flipped text matrix those positions and `CTLineDraw` disagree. A run can carry
a per-glyph cross-stream **origin**, readable with
`CTRunGetBaseAdvancesAndOrigins` and already folded into `CTRunGetPositions`.
Unflipped, a `CTLineDraw` and a replay at those positions are pixel-identical.
Flipped, `CTLineDraw` applies the origin's y component with the opposite sign
and moves an attached mark by -2*origin.y from the line's own typeset position.

That offset is not reverse-engineerable. `e` + acute + macron is a single run
with nonzero origins whose draw matches the plain positions and *breaks* under
the adjustment; `U+6F22` + hook-above + dot-below is matched by no per-glyph
combination of origin adjustments. So "reproduce `CTLineDraw` exactly" was not
an option that could be built, only one that could be approximated.

### Why following the typesetter is also the fix

The pre-change rendering is itself defective. For `U+6F22` + U+0323 -- combining
dot *below* -- `CTLineDraw` under the flip drew the dot from the baseline row
upward, over the base glyph's own ink, on the wrong side of its base. Following
the typeset positions puts it a row below the baseline, clear of the base. The
nearly invisible above-accent is the same defect in the other direction: the
acute on a wide base sat inside the base's ink instead of above it.

Both CoreText cell-grid terminals in `references/` place fallback text this way
-- glyphs extracted per run and submitted at the run's own positions, never
`CTLineDraw`: ghostty at
`references/ghostty/src/font/shaper/coretext.zig:422-424`, iTerm2 at
`references/iterm2/sources/iTermCoreTextLineRenderingHelper.m:58` and
`references/iterm2/sources/iTermRegularCharacterSource.m:234,257`.

### What it costs

Two of `PO1`'s parity cases give up their bitmap pin against the pre-change
path, because that path is what they are being moved away from. They are pinned
instead by where the mark lands: an above-mark's ink entirely above the base
glyph's topmost ink row, a below-mark's entirely below the baseline row, the
base glyph itself on exactly the pixels a base-only render puts it on, and the
three draw shapes (miss, repeat, later frame) identical to each other. Those
assertions fail against the pre-change placement, which is the point.

All zero-origin content -- CJK, kana, emoji, ZWJ sequences, variation selectors,
every styled face -- keeps its parity pin and is unchanged.
