# Shape a fallback cell once per (face, cluster) and submit it like an ASCII cell

Research: [docs/research/40-per-cell-coretext-typesetting](../../docs/research/40-per-cell-coretext-typesetting/README.md)
(`F1`, `F2`, `D1`, `D2`).

## 1. Problem

Every cell the base face cannot map -- CJK under the default font, any
multi-scalar cluster, any scalar above the BMP -- builds an attributed string
and a `CTLine` and draws it inside its own clip, per cell, per frame. Nothing
is kept between cells or frames. On a full-viewport frame of CJK that is
5,874 typesettings per frame.

Evidence: the kitten `unicode` arm repaints at 20-22 frames per second with the
main thread at 100% where the panel offers 120, and the process holds two cores
(`F1`); a full 179x66 `fallback-shaped` frame costs 130.5 ms against 3.06 ms
for the same columns of ASCII, 42.6x (`F2`). Three throwaways price the layers:
removing the ligature attribute alone 35-41 frames per second, a cross-frame
`CTLine` memo 95-103 (the panel's cap) at 61% main thread, with `CTLineDraw`
per cell and the frame fill as the remainder (`F1`).

Load-bearing premises about existing behavior:

- A fallback glyph's ink never leaves its cell span. Doc 3 kept the per-cell
  clip because unclipped fallback glyphs bled into neighbouring cells; the
  sprite and symbols suites pin adjacency isolation the same way
  (`BranchDrawingSpriteExecutionTests`, `NerdFontSymbolsExecutionTests`).
- Rendering fallback content leaves the regular face's metrics unchanged
  (`ExecutorContractTests.renderingDoesNotAlterMetrics`).
- A draw restores the CTM, text matrix, clip and colour spaces it found
  (`ExecutorContractTests`), and a dirty-rect redraw is pixel-identical to a
  full frame.
- A default-text variation base gets its presentation selector appended before
  shaping and nothing else is transformed. The gate's policy -- which scalars are
  transformed and which are left alone -- is pinned by `UnicodePresentationTests`.
  That the draw path calls the gate is not observable on macOS: the host resolves
  the base to the same text face with and without U+FE0E, so no bitmap here can
  see the append (`PresentationSelectorExecutionTests` says so in its header). iOS
  shows a regression on sight.
- Fallback cells leave no residue in a later sprite run
  (`RunScratchResidueTests`).
- The fast path is what `content-churn`, `style-churn` and the headless
  `text-shaped` arm measure; it never enters the fallback path.

Desired outcome: a fallback cell is typeset at most once per (face, cluster)
per cache residency, so once for the life of a font set whenever the active
working set fits the cap, and on every later frame it costs a lookup and either
a glyph appended to a batch (an ordinary entry) or a replay from cached glyphs
with no typesetting (an exceptional one); `fallback-shaped` reads `faster` under `D1`'s rule;
a real CJK stream repaints at the panel's rate with the main thread under half
a core; every pixel is unchanged.

## 2. Decision

Build `D2`'s ideal. A **shaped-cluster cache**, keyed by (face identity,
cluster scalars), holds what one typesetting of that cluster produced: the
line's runs **in line order**, and for each run the font CoreText's cascade
chose, the glyph ids, their positions relative to the cell origin, and the run's
own text matrix; plus whether the cluster's ink stays inside its cell span. On a
miss the draw typesets the cluster as it does today (minus the ligature
attribute), extracts that result from the line, stores it, and draws from the
entry. On a hit no `CTLine` is created or drawn.

An entry is **ordinary** when it is contained, has exactly one run, and that
run's text matrix is the identity. `drawTextRuns` submits ordinary entries in
batches per (font, colour) through `CTFontDrawGlyphs`, the way it submits mapped
ASCII glyphs, with the cell's text matrix re-set per submission. Every other
entry -- overflowing ink, more than one run, or any run CoreText marked as
needing its own matrix (`kCTRunStatusHasNonIdentityMatrix`) -- is replayed from
its cached glyphs alone, in run order, inside its own clip, with each run's
matrix concatenated onto the cell's. Batching cannot express run order or a
per-run matrix, and both change pixels, so entries that need either never enter
a batch. The common CJK cell is ordinary, so the batched path carries the
measured win.

The cache is a reference-typed object created with a metrics value and owned
for exactly its lifetime by whatever owns the draw -- the swapchain in the app,
the harness in the headless benchmark, the test in a test -- and handed to the
draw entry point. It is never stored in a `Sendable` render value, and it is
never global.

Colour is not part of the key: it is the batch's fill. No `kCTLigatureAttributeName`
and no `kCTLanguageAttributeName` is placed on the string; ligatures cannot
form in a one-cluster string, and the fast path shapes nothing, so design doc
`H6`'s policy holds structurally.

The cache is bounded. Its cap is at least one full 179x66 frame of distinct
clusters with headroom, so the kitten arms and any single screen hit after the
first frame; `T2` may move it. Past the cap, eviction returns a cluster to
today's per-cell typesetting on its next miss, plus the cache's own extraction
and insertion work (`AR1`).

`D1`'s rule is the gate and the headless compare must print it: a
`fallback-shaped` report states the frozen threshold and the order-bias guard
beside its verdict, and reports a single-direction run as descriptive.

## 3. Invariants

- I1. Pixel equivalence with today: for every fallback cell -- CJK, colour emoji,
  a ZWJ sequence, a base with combining marks, a variation-selector cluster, a
  bare scalar the presentation gate transforms, and each of the four styled faces
  including a synthesized-italic fallback -- the rendered bitmap is identical to
  what the pre-change attributed-string-plus-`CTLineDraw` path renders, whether
  the cluster is drawn on a miss, on a hit in the same frame, or on a hit in a
  later frame. Miss and hit agreeing with each other is not enough: they can
  agree and both be wrong.
- I2. Containment: a fallback glyph's ink never leaves its cell span, and the
  cells beside it hold their own background.
- I3. Colour independence: the same cluster drawn in two foreground colours
  draws in each colour, and the second colour does not create a second shaping.
- I4. Font-set lifetime: after a metrics change the draw renders exactly what a
  fresh draw with the new metrics renders; no entry from the old font set is
  read.
- I5. Boundedness: the entry count never exceeds the cap however many distinct
  clusters are drawn, and drawing past the cap still renders correctly.
- I6. Steady state does no typesetting: on a frame whose every fallback cluster
  is cached, no `CTLine` is created or drawn.
- I7. The fast path is untouched: mapped ASCII and single-BMP-scalar cells take
  the same submission they take today, and every existing render test passes
  unchanged.
- I8. Draw hygiene holds: CTM, text matrix, clip and colour spaces are restored,
  metrics are unaltered, no residue reaches a later run, and a dirty-rect
  redraw matches a full frame.

## 4. Proof obligations

Tests first, red for the expected reason, then the change. Every assertion is
on a rendered bitmap, a count the cache reports, or a ladder verdict; none on
the shape of a helper.

- PO1 (I1). A test-only reference renderer reproduces the pre-change path --
  attributed string, `CTLineCreateWithAttributedString`, per-cell clip,
  `CTLineDraw` -- and is the parity target. A snapshot suite renders the named
  cluster set once, twice in one frame, and across two frames with one cache, and
  requires every one of those bitmaps to equal the reference renderer's bitmap.
  The synthesized-italic case uses a family with no true italic so a fallback
  font with a matrix is actually exercised. The presentation-gate case cannot
  fail on macOS (see the premise above); it is carried so iOS binds it.
  The set is not chosen by expectation: the suite asserts, per case, which of the
  three exceptional conditions the typeset line actually carries -- more than one
  run, `kCTRunStatusHasNonIdentityMatrix`, ink outside the cell span -- and the
  suite fails if any of the three is unclaimed by every case. A case chosen for a
  condition it turns out not to produce is replaced, not assumed.
- PO2 (I2). Each cluster of the set is rendered between two plain cells and the
  neighbours are required to hold only background; a deliberately oversized
  fallback glyph (a large emoji in a narrow cell) is the overflow case.
- PO3 (I3). One cluster in two colours: both colours present in their cells,
  and the cache reports one entry.
- PO4 (I4). Render with one font set, replace the metrics, render again; the
  bitmap equals a fresh render with the second font set.
- PO5 (I5). Drawing more distinct clusters than the cap leaves the entry count
  at or below the cap and the last frame pixel-identical to a fresh render.
- PO6 (I6). The cache reports its miss count; a second frame over the same
  clusters adds no misses. The frame-presence check in `D2` criterion 2
  (`sample` on a steady-state kitten `unicode` frame, no
  `CTLineCreateWithAttributedString` or `CTLineDraw` under `drawTextRuns`) is
  the live confirmation and is recorded in `F3`.
- PO7 (I7, I8). The existing `TerminalRenderExecutionTests` suite passes
  unchanged; `text-shaped` on the headless arm is not `slower`;
  `content-churn` and `style-churn` are not `slower` on `just benchmark-confirm`.
- PO8 (the gate). `just benchmark-headless-draw 8 <pre-change TerminalCore>
  --workload fallback-shaped` -- `--both-directions`, the recipe's form with a
  candidate -- reads `faster` at +/-1.00% with `orderBiasPercent` under 2.5%,
  on an idle host. Expected magnitude is beyond -80%. A run above the guard is
  re-run, not read.
- PO9 (the real stream). `F1`'s method re-taken on an optimized slot, frontmost,
  179x66, `kitten __benchmark__ --render --repetitions 1000 unicode`: renders
  per second from `DANTERM_FRAME_RATE_LOG` and main-thread `%CPU` from `ps -M`,
  recorded with window state and grid. Confirmed when renders per second sit at
  the panel's rate and the main thread is under half a core; `unique_unicode`
  is recorded beside it. This is a sanity check on the frame-rate claim, not a
  verdict; the verdict is PO8.
- PO10 (`D1` in the report). The headless compare's `fallback-shaped` report
  carries the frozen rule and guard, and a single-direction run of that
  workload is labelled descriptive; a tooling test pins both.

## 5. Non-goals / Accepted risks / Rejected ideas

Non-goals:

- The full-frame background fill (`39/F13` `ascii`, doc 18 `L6`). Not this
  plan's mechanism.
- Cross-cell ligatures. Never rendered; `H6` and `H13` keep them out.
- A language attribute. Rejected in the README; revisit only if a miss-path
  profile on `T2`'s streams shows the preferred-language walk mattering at
  cache-fill rate.
- A rasterized glyph atlas. CoreGraphics' own glyph cache sits off-thread
  (`17/D7`, `18/L9`); no evidence asks for one here.

Accepted risks:

- AR1. The cap is sized by arithmetic, not by a measured stream (`T2` is open).
  A working set above the cap thrashes: a cluster is re-shaped on each residency,
  and each miss costs today's typesetting plus extraction, insertion and
  eviction, so a thrashing frame is somewhat worse than HEAD, not equal to it.
  Accepted because the cap is sized above a full 179x66 frame of distinct
  clusters, which no real stream is expected to exceed, and `T2` will measure it.
- AR2. `F2`'s A/A series ran on a loaded host; `D1` accepted its threshold as a
  floor, not a screened cell. The expected effect is far beyond the floor, so
  the gate's false-positive bound is what matters and it is bounded.
- AR3. A multi-run or non-identity-matrix cluster is replayed per entry rather
  than batched, so it keeps a clip and a submission of its own and gains less
  than an ordinary entry. Accepted: it still shapes once, and these clusters are
  rare next to CJK. PO1 names which of its cases reach the path by inspection,
  not by assumption.

Rejected ideas:

- RI1. Drop the ligature attribute and stop (`D2`'s cheap shape): halves the
  cost and keeps a typesetting per cell per frame; the core is still spent.
- RI2. Memoize the `CTLine` per (text, face, colour) (`D2`'s middle shape):
  reaches the panel's cap and hides 61% of a core in `CTLineDraw` per cell and
  an entry per colour.
- RI3. A memo inside `TerminalFace` or a process-global dictionary: mutable
  state in a `Sendable` value, or state that outlives the font set it was
  shaped for.
- RI4. Batch-clipping to the row's union of fallback cells instead of
  per-entry containment: lets one fallback glyph bleed into the next, which is
  the defect doc 3's clip exists to prevent.

## 6. Implementation discretion

- The cache's type, its eviction policy, its exact cap, and the parameter by
  which the draw entry point receives it.
- Where the frozen `D1` rule lives in `scripts/terminal-headless-draw-compare.py`
  (a per-workload default threshold or a rule table), provided the report
  prints it.

## Commit progress

- [x] 1. Freeze the `fallback-shaped` decision rule in the headless draw report (PO10)
- [x] 2. Pin fallback-cell rendering against a test-only reference renderer (PO1, PO2)
- [ ] 3. Shape a fallback cell once per (face, cluster) and submit it batched (PO3-PO9)

## Implementation notes

- Commit 1 took the rule-table form of the discretion in section 6 rather than a
  per-workload default `--threshold`, because a default threshold cannot carry
  the order-bias guard, the round count, or the "single direction decides
  nothing" clause -- and the report has to print all of them. `FROZEN_RULES` in
  `scripts/terminal-headless-draw-compare.py` holds one entry per workload that
  has a rule; a workload with none still gets a `decision` block that says so, so
  an absent block can never read as no opinion.
- A run that missed the frozen cell reads `invalid`, not a verdict: wrong mode,
  a round count other than 8 per direction, or an order bias at or above 2.5%.
  A reading inside the threshold reads `inconclusive` rather than `equivalent`,
  because the freeze bounds false positives and does not bound detection.
- The caller-supplied `--threshold` reading moved from the report's `decision`
  key to `callerThreshold`, so the frozen reading owns `decision` in both modes
  and the two can never be confused for each other.
- The report envelope was extracted into `both_directions_report` and
  `single_direction_report` so a test can assert the emitted report carries its
  decision block without building an arm. Verified by mutation: deleting the
  `decision` key turns four tests red.
- `agent-docs/terminal-performance.md` said "No decision rule is frozen for it",
  which the same change makes false. Rewritten in the same commit rather than
  left to contradict the script.

- Commit 2 could not build `PO1`'s synthesized-italic case as written. No
  installed family yields a matrix from the trait copy the executor uses: asking
  CoreText for the italic trait of a family with no designed italic returns the
  upright face unchanged rather than synthesizing a slant, and a sweep of every
  installed family found none whose derived italic or bold-italic carries a
  matrix. A run is marked `kCTRunStatusHasNonIdentityMatrix` only when the base
  face carries one, because the cascade hands the fallback font the base font's
  matrix. Following `PO1`'s own rule -- a case chosen for a condition it turns
  out not to produce is replaced, not assumed -- the case is now the base face
  copied with an oblique matrix, through the metrics' file-backed-face
  initializer, which does produce the condition. The four styled faces stay
  covered by the bold, italic and bold-italic CJK cases.
- Commit 2 added a case for a wide base with a combining mark: it is the only cluster
  in the set whose line CoreText splits into more than one run. The Latin
  base-with-marks case shapes as a single run.
- The reference renderer is driven by the plan rather than by a hand-written cell
  list, and refuses a plan carrying a background run, an overlay, a decoration or
  a cursor. It reproduces the frame clear and the fallback text pass and nothing
  else, so it can never compare against a frame with a layer silently missing.
- The suite was verified by mutation, since it is green against today's
  executor: shifting the executor's text-matrix baseline by one point turns every
  parity case red, and deleting its per-cell clip turns the containment proof red
  for the emoji and heart cases.
