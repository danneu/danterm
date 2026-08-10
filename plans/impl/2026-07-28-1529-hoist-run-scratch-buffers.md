# Hoist `drawTextRuns`' per-run scratch collections above the run loop

Candidate **R4** from
[13-live-app-compositing-and-draw-hotspots.md](../../docs/research/13-live-app-compositing-and-draw-hotspots.md),
ranked 4 by D1 and gated until R1 landed. R1 landed in `919838f` (13/F7), so the
gate is open.

## Problem and evidence

`drawTextRuns` allocates thirteen collections fresh on every iteration of
`for run in runs`: the three cell accumulators and seven sprite accumulators
declared at the top of the loop, the glyph buffer, and the two arrays that carry
mapped glyphs and their positions. Every one of them is emptied and discarded at
the end of the iteration and rebuilt from zero capacity on the next, for as many
runs as the frame contains -- an estimated 1,300-4,000 per full frame at 179x66
on btop-shaped output (D1's derivation from the run-breaking rules).

Load-bearing evidence:

- **13/F7, live run 3.** After R1 removed the attributes dictionary, the lines
  that grow these collections are **303 of `drawTextRuns`' 1,670 node samples
  (18.1%)** -- second only to `CTFontDrawGlyphs` (353, 21.1%). R1's removal
  promoted this from F2's ~190 samples to the largest remaining removable block
  in the function.
- **13/F2.** The same lines were already attributed pre-R1, so this is two
  captures, not one, and the composition is stable across them.
- **Doc 9 carries the same work** as an open Phase 5 item ("unreserved array
  growth in `drawTextRuns`, 14% of draw"), seen through a different profile.
  This plan closes that entry rather than opening a second one.

## Decision

Hoist the thirteen collections above the run loop and reset them per iteration,
keeping their capacity, so each buffer is grown at most once per draw.

Behavioral scope: none. Every glyph, sprite, and fallback cell drawn today is
drawn tomorrow, in the same order, with the same geometry. This changes where
storage comes from, not what is written into it.

Decisive constraint: **a hoisted buffer must never carry one run's contents into
the next.** Every hoisted collection is reset at the top of each iteration,
before any statement that could exit the iteration early. That placement stays
correct if a `continue` is ever added to the loop body; an end-of-iteration reset
would not.

## Invariants

- **I1.** Rendered output is unchanged for any sequence of runs, including a run
  that produces sprites followed by one that produces none, and a run that
  produces fallback cells followed by one that produces none.
- **I2.** Each run draws exactly the cells it owns. No collection observed by a
  run carries residue from an earlier run of the same draw.
- **I3.** The damage-clipped draw path stays consistent with the full-frame path.

## Proof obligations

- **PO1** (I1, I2): for **every** category of collection actually hoisted, a
  frame whose runs alternate between producing and not producing that category's
  contents renders identically to frames drawing each run in isolation. The
  categories, each a distinct leak with a distinct visual signature:
  - the shared sprite-rect accumulator and the box-drawing strokes (duplicated
    rects and strokes);
  - **each keyed sprite dictionary separately** -- shaded block elements and
    legacy computing -- since their inner arrays are cleared by a different
    mechanism than the flat accumulators (see `Implementation discretion`);
  - the remaining flat sprite accumulators -- geometric-shape triangles,
    powerline paths, branch-drawing geometries;
  - **the regular glyph pipeline** -- `characters`, `candidateCells`, the glyph
    buffer if hoisted, `mappedGlyphs`, `positions`. A stale-glyph leak here
    either redraws a previous run's text or hands `CTFontDrawGlyphs` a
    glyph/position pair whose counts disagree with what the run owns;
  - fallback cells, which leak as duplicated glyphs on their own code path.
- **PO2** (I2): each PO1 test must fail against the deliberately omitted reset or
  resize for *its own* category. Verify each mutation individually before
  trusting the suite -- a test that only ever draws one run per frame cannot
  detect a leak at all, and a suite that passes with one category's reset removed
  is not proving that category.
- **PO3** (I3): `ExecutorContractTests.damageRedrawMatchesFullFrame` already
  compares the clipped path's bitmap bytes against a full-frame draw.
- **PO4** (I1): the existing bitmap suites (`TextExecutionTests`, the sprite
  geometry tests) must pass unchanged; this change is not entitled to move a
  single pixel.

If a collection is left un-hoisted (see `Implementation discretion`), its PO1
category drops with it -- the obligation tracks what the implementation actually
hoists, not the list of thirteen.

## Deciding the benchmark

- **Baseline acceptance:** resolve and record the pre-change revision *before*
  implementation begins; do not infer it from `HEAD` afterwards. It is
  `919838f` (R1's commit), not `fcfff10`.
- **Decision-bearing instrument:** `just benchmark-quick 919838f content-churn`,
  per doc 13's inherited rule that a directional claim uses
  `benchmark-quick`/`benchmark-confirm` against an explicitly named pre-change
  revision. An inconclusive paired result is recorded as inconclusive; only
  `just benchmark-confirm 919838f` may resolve it. An unpaired headless delta may
  not stand in for it.
- **Mechanism confirmation:** `just benchmark-draw`, run before and after. It
  shows the allocations are gone from the path it exercises; it is not R4's
  verdict. Note when reading it that its fixture routes 100% of cells to sprites
  with zero font candidates and zero fallback cells (13/F5), so it exercises only
  the sprite accumulators -- the glyph and fallback collections are never grown
  in it at all.
- **Prediction:** D1's full-frame band of **-3% to -6%** stands as written.
  Record the actual figure against it. Run 3's 303 samples (up from F2's ~190,
  after R1 removed the competing dictionary) is a reason the result may land
  above the band, not a reason to restate the band as a floor -- that attribution
  came from a different denominator and workload than the synthetic prediction,
  and moving a prediction after seeing new evidence would make AR1's legitimate
  null outcome look anomalous instead of falsifying.
- **This candidate owes its own commit and its own measurement.** It is not
  exempt the way R1b was: at this size a benchmark run can separate it from
  anything else in `drawTextRuns`, so nothing else may edit that function in the
  same commit.

## Recording the result

**13/F9** gets R4's headless and paired-app numbers reported independently,
alongside its verdict. Report R4's headless-delta-to-live-share ratio next to
R1's ~1.9 as descriptive evidence only, and leave the cause of any gap
unresolved.

The two candidates are not exposure-matched, so their ratios cannot establish a
calibration factor or isolate a cause. R4's 18.1% live share spans the glyph and
fallback paths and sprite families the fixture never executes (13/F5: zero font
candidates, zero fallback cells, twelve distinct scalars); its headless delta
spans only what the fixture draws. Agreement between two such ratios would be
coincidence, and disagreement would not localize to dictionary hashing.
Deriving a real calibration needs doc 13's open "count runs per frame in real
btop output" task plus the live route composition -- which stays a separate,
already-listed task, not a branch of this plan.

## Non-goals

- R3 and the CoreAnimation glyph-bounds thrash; still gated until Phase 2 is
  measured, which this plan completes rather than pre-empts.
- Changing which cells route to sprites, to the glyph fast path, or to fallback.
- Building a live run-counter instrument, and deriving any cross-instrument
  calibration factor. Doc 13's open run-density task owns that work.
- Doc 9's other Phase 5 items. Only the `drawTextRuns` array-growth entry is
  closed here.

## Accepted risks

- **AR1.** This is the smallest candidate in D1's ranking and the most likely to
  be absorbed by allocator noise -- doc 9 flagged exactly that about its own
  version of the item. A null result is a legitimate outcome and gets recorded as
  one; it is not a reason to keep tuning until the number moves.
- **AR2.** Hoisted mutable state shared across iterations is a standing hazard,
  not a one-time one: a future collection added to the loop body can be forgotten
  in the reset sweep. Top-of-loop resets make early exits safe, and PO1/PO2 keep
  the residue from being silent, but neither forces a new buffer to join them.
- **AR3.** Run 3's 18.1% is a single capture on one workload shape (btop). The
  two-profile rule is satisfied for the *composition* by F2, not for this exact
  share.

## Rejected ideas

- **RI1. `reserveCapacity(n)` per run with a fixed guess.** It keeps the
  per-run allocation and adds a magic number that is wrong for both the 80x24
  and 179x66 cases. Hoisting removes the allocation outright; capacity then
  converges on the frame's actual maximum with no constant to choose.
- **RI2. Landing this with any other `drawTextRuns` change to save a benchmark
  run.** That is precisely what destroyed nothing so far only because R1b was
  unmeasurable. R4 is measurable, so the attribution is real and worth a commit.

## Implementation discretion

- **The two dictionaries whose values are arrays are worth deciding
  deliberately.** `removeAll(keepingCapacity: true)` on the outer dictionary
  discards every inner array, and the `[key, default: []]` subscript then
  allocates a fresh one -- so the naive hoist buys nothing for those two.
  Clearing each inner array in place and retaining the keys does, and leaves the
  `where rects.isEmpty == false` guards correct. Either choice is admissible;
  choosing the first without noticing is not.
- Whether the glyph buffer is hoisted at all. It needs exactly `characters.count`
  zeroed elements for CoreText to fill, so it is a resize, not a clear, and at 24
  samples it is the weakest member of the group. Dropping it is a reasonable
  simplification if the resize turns out to be fiddlier than the allocation it
  saves.

## Commit progress

- [x] 1. perf(terminal): hoist `drawTextRuns`' per-run scratch buffers
- [x] 2. docs(research): record R4's result as 13/F9

## Follow Up

- Doc 11's Phase 1 item 1 ("Harvest `9/H3` and the unreserved array growth",
  `docs/research/11-render-frame-budget.md:162`) now points at one landed item
  and one open one. Whoever lands `9/H3` should retire that bullet; until then it
  reads as two pieces of pending work when only one is.
- Doc 13's Phase 3 F10 re-capture is now unblocked and **needs the user** -- it
  is a live `sample` of a held-down-arrow btop gesture that must not be scripted,
  and F7's run 3 explicitly may not stand in for it. F7 records the figures it
  should be compared against (queue 1,273, blocked 1,053).
- Doc 13's open Phase 1 task -- counting runs per frame in real btop output --
  gained a second reason to be worth doing: F7 and F9 now have
  headless-delta-to-live-share ratios of ~1.9 and ~0.24-0.50 respectively, and
  nothing measured explains the sizes of either gap.

## Implementation notes

- **The keyed dictionaries clear their inner arrays in place.** Both
  `shadedSpriteRects` and `legacySpriteRects` go through a
  `emptyValuesKeepingCapacity()` helper that walks the dictionary's indices and
  empties each bucket through the mutable `values` view, retaining keys and inner
  storage -- the alternative the plan warned about (`removeAll(keepingCapacity:)`
  on the outer dictionary) would have bought nothing. The helper walks indices
  directly rather than iterating `keys`, which would hold a second reference to
  the dictionary's storage and force a copy on every mutation.
- **The glyph buffer is hoisted, but its reset has no falsifying mutation.**
  `CTFontGetGlyphsForCharacters` overwrites exactly the first `characters.count`
  slots, which is exactly the range the run indexes, so stale contents can never
  be read; omitting the reset only makes the buffer grow without bound. It
  therefore rides along inside the glyph-pipeline PO1 category rather than
  claiming a proof of its own -- PO2 is satisfied for that category by the other
  four members.
- **The glyph pipeline needed two PO1 scenarios, not one.** A consumer run that
  maps no glyphs at all (the sprite-consumer case) cannot detect residue in
  `characters` or `positions`, because it never indexes them; a consumer run that
  maps *fewer* glyphs than its predecessor does. Both scenarios are kept: the
  first covers `candidateCells` and `mappedGlyphs`, the second covers
  `characters` and `positions`.
- **PO2 was run as an explicit mutation pass**, one omitted reset at a time
  across all thirteen buffers, confirming each is detected by its own category's
  test (with the glyph-buffer exception above).
- **`benchmark-quick content-churn` was run twice, not once.** The plan named one
  run as the decision-bearing instrument and reserved `benchmark-confirm` for an
  *inconclusive* result. The first run was not inconclusive -- it was "faster" at
  -15.68%, roughly 3x the top of the predicted band, on the minimum 2 pairs. A
  second independent pair set (-18.10%) was taken because a lone 2-pair result at
  3x the prediction is the shape a sampling artifact makes, and because the
  figure is being *recorded* rather than used only as a direction. `confirm` was
  still not run: the change is confined to the draw path and both runs reported
  plan time equivalent.
- **The `benchmark-draw` baseline was re-measured in the same session**, in a
  throwaway worktree at `919838f`, following F7's precedent rather than reusing
  any previously recorded figure.
- **Doc 11's Phase 1 item 1 bundles doc 9's array-growth entry with `9/H3`** and
  says nothing in that file should start before both land. Only the array-growth
  half landed here, so doc 11 was left untouched -- its sentence is still true
  for `9/H3`. Raised as a follow-up rather than edited, since this plan's
  non-goals scope the doc closure to doc 9's single entry.
