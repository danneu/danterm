# Classify sprite cells' ink as the cell band (DRAW-2)

## Problem

The frame planner classifies every single-scalar cell outside printable ASCII
as `.generalText` ink (`lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift:443-452`),
and the reach ledger prices `.generalText` as a full-cell halo above and below
the row -- three rows of pixels
(`lib/TerminalCore/Sources/TerminalRenderPlanning/RenderInkReach.swift:82-84`).
But every cell of the eight sprite families (box drawing, block elements,
braille, geometric shapes, powerline, branch drawing, legacy computing, legacy
computing supplement) is drawn band-contained by the executor: routed away from
the font before the cmap is consulted, emitted as cell-local rects or drawn
under a clip to its own cell. So on exactly the content the terminal renders
fastest -- a TUI made of borders, blocks, and braille -- every damaged row
erases and replans roughly three rows' worth of pixels through
`TerminalFrameBackingStore.apply` where one band would do.

The root cause is two independently written membership answers: the executor's
routing switch plus the eight families' `pattern(for:)` decoders
(`lib/TerminalCore/Sources/TerminalRenderExecution/`), and the planner's
three-branch guess, which cannot ask the families because the decoders live in
a module the planner cannot depend on. The floor constant
`spriteClassificationMinimumScalar` documents its own drift hazard for the same
reason.

Source: DRAW-2 in `docs/scratch/2026-08-26-improvement-audit.md` (impact 3,
confidence 5, cost). Its prerequisites have landed: DRAW-3 (the headless arm
compiles again, as the `HeadlessDrawArm` target) and DRAW-5 (the box-drawing
decode table is total, `f1dab3bd`).

## Decision

Give the sprite vocabulary one home. Move the eight families' exact-membership
decode -- coarse range, scalar-to-pattern mapping, decode tables, and the pure
helpers they need -- from `TerminalRenderExecution` into the dependency-free
`TerminalSpriteGeometry` target, expose one shared scalar-to-decode entry
point there, and have both consumers read it: the executor's routing switch
consumes the decoded pattern instead of re-deriving it, and the planner prices
a decoded cell at its family's declared ink reach instead of guessing.
Membership alone never implies containment: each family in the shared
vocabulary declares its ink reach beside its decode, and all eight current
families declare the band (their geometry is cell-local rects or paths clipped
to the cell). Everything the planner cannot decode keeps `.generalText`.
`TerminalRenderPlanning` gains a dependency on
`TerminalSpriteGeometry` (in `lib/TerminalCore/Package.swift`, plus the allow
list on the `TerminalRenderPlanning` line of `scripts/core-purity-policy.conf`).

The decode move lands behavior-neutral first (executor consumes the shared
entry, no planner change), then the planner change with its pricing proofs, so
the reclassification diff is reviewable against an already-single vocabulary.

The membership question the planner asks is metrics-free by design: exact
scalar membership (`pattern(for:)` non-nil), not the executor's
per-metrics geometry construction. The one divergence -- geometric shapes'
triangle builder refuses at zero cell size and falls to the font -- is
defensively unreachable (`fittedRenderScale` floors cells at one pixel,
`lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderFit.swift:44`)
and prices as zero either way.

`docs/terminal-sprites.md` states the old layering as contract
("Classification stays beside render execution"); it is rewritten in the same
change to state the new one: scalar decode and membership live in
`TerminalSpriteGeometry`, render-state integration and Core Graphics
conversion stay in `TerminalRenderExecution`, and the planner prices sprite
rows by the families' declared reaches because of it. The adding-a-family
checklist points a new family at that declaration: an intentionally
overscanned family (a category the geometry contract permits) declares a
conservative reach there, so the claim appears in its own diff rather than in
a checklist it may never read.

## Invariants

- I1 -- One membership answer: the planner's ink classification and the
  executor's sprite routing consume the same decode, so "the planner believes
  a cell draws through the font while the executor draws it as a sprite" is
  unrepresentable.
- I2 -- Single-scalar ink classification: printable ASCII is `.asciiText`; an
  exact sprite member takes its family's declared ink reach, and every current
  family declares `.band`; every other single scalar -- interior gaps of a
  coarse range, scalars at or above the floor in no family, anything the
  runtime font might reach -- stays `.generalText`. Multi-scalar cells stay
  `.band`. (Gap scalars really do fall to the font, whose extents are
  unmeasured; pricing them as band would be a correctness regression.)
- I3 -- Font-vs-sprite routing behavior is unchanged for every (scalar,
  metrics) pair, the geometric zero-size refusal included.
- I4 -- Ordinary text pays no added per-cell classification cost in either hot
  loop: the below-floor rejection must inline across the module boundary
  (docs/design/2026-07-29-cross-module-value-dispatch.md governs the
  mechanism).
- I5 -- Incremental rendering stays byte-identical to a full redraw when a
  damaged row is erased at its cells' declared reaches; with every current
  family declaring the band, a damaged sprite row erases only its band.
  Reach-declaration violations surface as byte differences, not stale pixels.

## Proof obligations

- PO1 (I2) -- A row of sprite-only cells reaches exactly its band through
  `renderRowReaches`; an interior-gap scalar and an above-floor non-member
  keep the full-cell reach. The sprite case is red today
  (`RenderInkReachTests` is the observing suite; fixtures must contain no
  ASCII or accents, or the union silently widens and the test stops testing).
- PO2 (I2) -- The apply shape for a damaged sprite row shrinks to one band's
  erase span and a correspondingly smaller plan set -- the countable mirror of
  the existing `generalDamagedRowShape` worst case. Red today. This is the
  cost verification: no benchmark can currently resolve the wall-clock win
  (see Accepted risks).
- PO3 (I1, I2) -- A sweep over all eight coarse ranges: the shared entry
  decodes a scalar iff its family's `pattern(for:)` does, every family's
  declared ink reach is the band today, and the floor equals the lowest family
  range start (the relocated guard currently in `SpriteRoutingGuardTests`).
- PO4 (I3, I5) -- A pure-sprite streaming-and-editing scenario through
  `TerminalFrameBackingStore.apply` stays byte-identical to from-scratch full
  renders, with the suite's anti-vacuity applied/shifted counts
  (`FrameBackingStoreTests` is the only suite that exercises the reach ledger
  end to end; the bitmap incremental helpers clip to whole cell bands and
  cannot go red on a mispriced class). Green before and after the planner
  change.
- PO5 (move neutrality) -- The per-family exhaustive mapping tests keep their
  exact assertions after migrating to the geometry test target, and the
  per-family rendered-output suites pass unchanged through the shared entry.

## Non-goals

- No paired benchmark instrument for the apply path. Wall-clock evidence is
  descriptive only (`just benchmark-quick <baseline> incremental-mixed`,
  `just benchmark-draw-app`); building and freezing a new instrument is
  separate work.
- No dedup of `GlyphPreviewLayout.swift`'s hand-written family ranges
  (`lib/TerminalHostTools`, a separate package) -- recorded as a follow-up in
  the audit annotation.
- No decode payload carried in plan rows; the plan stays metrics-free facts
  only.

## Accepted risks

- AR1 -- The audit's stated verification (paired headless draw,
  `--clip-rows 1`) provably cannot observe this change: the arm plans once
  outside the timer, `drawRenderFrame` never reads `inkClass`, and the clip
  band is driver-chosen. The verification is PO2's deterministic shape change
  plus descriptive in-app numbers; the audit mark records this pivot.
- AR2 -- Sprite cells now decode twice per frame (planner membership, executor
  payload) -- a table lookup per sprite cell of new planning work, accepted
  against deleting the duplicated vocabulary; the escape hatch (carry the
  decode in the plan) is deliberately not taken (Non-goals).

## Rejected ideas

- RI1 -- A fourth ink class computed from a copied coarse-range list inside
  `TerminalRenderPlanning` (the audit's cheaper fallback): a third
  transcription of the ranges, and it cannot see interior gaps, so it would
  price genuinely font-bound scalars as band -- a correctness regression, not
  just duplication.
- RI2 -- Deriving the floor from the family ranges at static init: a lazy
  global with cross-module access cost in the hottest reject path; the
  literal-plus-guard-test pairing stays, relocated beside the families it
  restates.

## Implementation discretion

- The shared entry's shape (enum with per-family payloads vs. function) and
  the file placement of the moved decode halves within
  `TerminalSpriteGeometry`.
- Which mapping tests move to `TerminalSpriteGeometryTests` verbatim vs. stay
  beside rendered-output assertions, and the exact sprite fixture strings.

## Verification

- Edit loop: `swift test --package-path lib/TerminalCore --filter
  TerminalSpriteGeometryTests` / `TerminalRenderPlanningTests` /
  `TerminalRenderExecutionTests`, plus `just lint` (which owns the purity
  policy check). `just test` before each commit; `just test-portability` once
  on the package-boundary change (the package pins iOS, and the portability
  gate cross-compiles every target).
- TDD order: PO1/PO2 tests first, failing for the expected reason (full-cell
  reach where band is expected); PO4's scenario is written and run green
  before the planner change so the gate is proven non-vacuous.
- Descriptive wall-clock, no threshold claim: `just benchmark-quick
  <pre-change sha> incremental-mixed` (contains `store.apply`; no frozen rule
  exists) and/or `just benchmark-draw-app` (diagnostic; reports
  dirty rows and draw duration).
- Close-out: tick DRAW-2 in `docs/scratch/2026-08-26-improvement-audit.md`
  with the done sha, the AR1 verification pivot, and the GlyphPreview
  follow-up note, in the ledger's established style.

## Commit progress

- [x] 1. refactor(render): centralize sprite decoding and declared reach
- [x] 2. perf(render): price sprite rows at their declared reach
- [x] 3. docs(audit): mark DRAW-2 complete

## Implementation notes

- The shared entry is `spriteDecode(for:) -> SpriteDecode?` in
  `TerminalSpriteGeometry/SpriteVocabulary.swift`: an enum with one case per
  family carrying that family's pattern, plus `inkReach`. Each family's
  `coarseRange`, `pattern(for:)`, and decode tables moved into its own
  `*SpriteGeometry.swift`, so the decode sits beside the geometry it decodes to.
- `spriteClassificationMinimumScalar` is an `@inlinable` computed global, and
  `spriteDecode(for:)` is `@inlinable` with only the floor guard in it; the
  family switch is a separate `@usableFromInline` function. That is what keeps
  I4's below-floor rejection one inlined comparison across the target boundary
  (docs/design/2026-07-29-cross-module-value-dispatch.md).
- `SpriteInkReach` carries two cases, `.band` and `.beyondBand`. Only `.band` is
  used today; `.beyondBand` exists so the reach is a real declaration a future
  overscanning family can make, which is what the doc's adding-a-family
  checklist now points at.
- A sprite cell now pays one cross-target call into the decode instead of an
  in-module switch. Ordinary text is unaffected (the floor guard inlines).
- The per-family membership and mapping tests moved verbatim into
  `TerminalSpriteGeometryTests/SpriteDecodeTests.swift` (PO5), with
  `XSprite.pattern` renamed to `XSpriteGeometry.pattern`. Braille is the one
  exception: its geometry decode returns the dot bitmask, so the geometry suite
  asserts the bitmask and the execution suite keeps its `BrailleSprite.dots`
  layout tests unchanged. `SpriteRoutingGuardTests` became the floor case of
  `SpriteVocabularyTests` (PO3).
- `docs/terminal-sprites.md` states the new layering without asserting the
  planner already prices sprite rows -- that claim lands with commit 2.

### Commit 2

- The classifier switches on `SpriteInkReach` rather than comparing it, so a
  future third reach cannot be silently priced as a band.
- `spriteDecode(for:)` is consulted only after the printable-ASCII branch, so an
  ordinary text cell reaches no new code at all and every other cell pays one
  inlined floor comparison (I4).
- PO4's pure-sprite scenario was written and run green against the unchanged
  planner first, so the byte-equality gate is proven non-vacuous before it
  starts observing band-priced rows.
- Descriptive wall clock, no verdict claimed: `just benchmark-quick 66ef6b87
  incremental-mixed` read +17.1% and +16.2% on two consecutive runs (2 pairs
  each; the frozen rule for this workload needs 40). The workload's content is
  pure ASCII with no sprite cell in it, so the change has no code path in that
  measurement; the readings were also taken with an agent session on the
  machine. Recorded rather than acted on -- see Follow Up.

## Follow Up

- Re-measure `incremental-mixed` at the ladder's 40-pair count on an idle
  machine (`just benchmark-confirm <sha>`). Two 2-pair `benchmark-quick` runs
  after this change read +16-17% on a workload that contains no sprite cells;
  either the reading is noise at that pair count or a code-layout perturbation
  in `FramePlanner`'s cell loop is real, and only the calibrated pair count can
  tell the two apart.
- `lib/TerminalHostTools/Sources/GlyphPreview/GlyphPreviewLayout.swift` still
  hand-writes the eight families' ranges as `implementedRanges`; it now
  duplicates `TerminalSpriteGeometry`'s vocabulary and can drift from it.

