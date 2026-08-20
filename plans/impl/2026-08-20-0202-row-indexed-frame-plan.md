# FRAME-1: publish the frame plan row-indexed

Source: `docs/scratch/2026-08-18-construction-audit.md` FRAME-1, with DRAW-2's
correction folded in. Three decisions are already made by the user and are not
open for review: option C (test-target-local flat accessors), deleting
`clipFramePlan` with the row restriction moving into `drawRenderFrame`, and
the damage-clipped benchmark rider (AR1). Lane H owns
`lib/TerminalCore/Sources/TerminalRenderPlanning`. DRAW-1 and FRAME-3 follow
this item.

## Problem

The planner keeps its reusable state per row (`RetainedFrameRows` holds
row-major arrays) but publishes a flat whole-viewport plan: four
`Array(...joined())` flattens per published frame copy every run in the
viewport, including runs of rows that were only copied forward. Every
row-scoped consumer then undoes the flattening -- `clipFramePlan` filters all
four arrays with a per-run row predicate once per incremental apply. A frame
with 4 damaged rows out of 66 pays O(runs in the whole viewport) three times:
copy forward, flatten, filter. Copying a `RenderTextRun` also retains its
`cells` array, so the flatten is a refcount operation per text run per frame.

All audit quotes verified against the current tree (`RenderFramePlanner.swift`,
`TerminalFrameBackingStore.swift#apply`). `RetainedFrameRows`' own doc already
states the principle the published plan discards.

## Decision

Make the row the plan's unit of publication, and make the retained reuse state
and the published plan one representation.

- `RenderFramePlan` publishes `rows: [RenderPlanRow]`, where a row value owns
  that row's background, overlay, text, and decoration runs. No flat per-layer
  array exists anywhere in a library target.
- The viewport-height field currently named `rows: Int` is renamed `rowCount`
  and is derived from the row array, so a plan whose height disagrees with its
  rows is not representable.
- The planner hands the same row values to the plan and to its retained state.
  Reusing an undamaged row is a per-row value copy, not a per-run copy.
- `clipFramePlan` is deleted, not made cheaper. A value shaped like a complete
  frame plan but holding only some rows stops being representable.
  `drawRenderFrame` takes an optional row restriction instead and preserves
  the global layer order (backgrounds, overlays, block-cursor fill, text,
  decorations, cursor overlay). A restricted draw draws only the named rows'
  runs, folds a carried shift into row damage the way the clip did, and draws
  the cursor only when its row is named.
- The executor's text and decoration passes take the row-indexed shape
  directly. Rebuilding a flat array to call them would reintroduce the copy
  being removed, and their hoisted per-draw scratch stays hoisted across the
  whole draw, not per row.
- Flat per-layer accessors (`textRuns` etc.) exist only as an extension file
  duplicated inside each of the five test targets that index them:
  `TerminalRenderPlanningTests`, `TerminalRenderExecutionTests`,
  `TerminalDrawBenchmarkSupportTests`, `TerminalBenchmarkMarkersTests`, and
  `TerminalPaneSessionTests` (in `lib/TerminalPTY`). Never in a library
  target: a productless library target is still reachable from every target
  in its package, which is most of the flatten's blast radius.
- The benchmark marker scanner and the browse-benchmark cell coverage walk
  rows then runs, as concrete non-generic calls over `RenderFramePlan`
  (`docs/design/2026-07-29-cross-module-value-dispatch.md` binds here).

## Invariants

- I1 (pixel identity): drawing the row-indexed plan paints byte-identical
  pixels to drawing today's flat plan of the same content, for full draws and
  for the incremental apply path.
- I2 (canonical rows): `plan.rows[i]` holds exactly row i's runs; every run's
  `row` field equals its index; within-row ordering and coalescing maximality
  are unchanged. Cross-row ordering is now the representation itself.
- I3 (restricted draw): a row-restricted draw paints, on the named rows,
  exactly the pixels a whole-frame draw paints there, and touches nothing
  outside them beyond the frame-wide background clear the caller clips.
- I4 (height): `plan.rowCount` always equals `plan.rows.count`.
- I5 (marker text): the scanned text stays defined as the text runs' scalars
  concatenated in plan order with `"\n"` between every pair of runs -- not
  between rows -- and rows excluded by a scan restriction still contribute
  their runs' separators.
- I6 (reuse-by-damage): planning with per-row reuse under recorded damage
  still lands on the same plan as a from-scratch replan, across the whole
  recording corpus.

## Proof obligations

- PO1 (I1): the two characterization tests pass with no assertion edits:
  `FrameBackingStoreTests` "below-budget streaming stays byte-identical
  through applied shifts" and `ShiftDamagePlanningTests` "below-budget
  streaming plans identically through translated reuse".
- PO2 (I3): new behavioral tests in `TerminalRenderExecutionTests` suite
  `ExecutorContractTests`, written first, all at the pixel level: a
  row-restricted draw paints on the named rows exactly the pixels a
  whole-frame draw paints there, and touches nothing outside them. One plan
  over a 3-row grid whose rows differ (plain ASCII / colored background plus
  underline / wide glyph), carrying an overlay run and a visible block cursor
  so every layer in the global order is exercised. Four restrictions, each
  compared against the whole-frame bitmap: the full restriction (identical
  frame, cursor drawn), the empty restriction (nothing drawn), an ordinary
  subset (row 1's band identical, rows 0 and 2 untouched, cursor drawn only
  when its row is named), and a subset naming out-of-range rows alongside a
  proper subset -- `[0, 1, rowCount]` on a 3-row plan -- which must still omit
  row 2 rather than being treated as full coverage. That last case is the
  successor to the deleted clip test that pinned the same mistake, and it is
  the one an incorrect count-based full-coverage shortcut fails. They fail
  today for a concrete reason: no row-restricted draw entry point exists, so
  they do not compile.
- PO3 (I2): `RenderPlanAssertions.assertCanonical` rewritten per row,
  including the new run-row-equals-index check; the corpus sweep applies it
  to every fixture event.
- PO4 (I5): the existing `TerminalBenchmarkMarkersTests` pin against the
  transcribed reference implementation passes unchanged, and
  `scripts/tests/terminal-benchmark-harness_test.sh` stays green (its literal
  grep for `plan.rows` in `app/TerminalBenchmark.swift` must move with the
  rename).
- PO5 (I6): `RenderCorpusPlanningTests.everyNeutralEventOverlaysDamage` keeps
  both consumers: the reuse planner unchanged, and the overlay consumer
  rewritten as per-row selection (damaged rows from the new plan, other rows
  retained) that must still equal the from-scratch plan.
- PO6: the four planning tests that exist to pin `clipFramePlan`'s filtering
  are deleted, not rewritten as assertions about plan-row contents. Their
  contract is restricted drawing, which PO2 now covers behaviorally; a
  structural assertion about which runs sit in which plan row would test
  planning instead, and could not catch a wrong full-coverage shortcut in the
  draw. The one exception is the search-match clip assertion, whose surviving
  contract -- overlay runs take part in the restriction like every other layer
  -- is carried by PO2's overlay layer.
- I4 needs no test: it holds by construction when the height is derived.

## Measurement

Per `agent-docs/measurement-discipline.md`, run after the change:

- `just benchmark-quick baseline=HEAD workload=content-churn`: the calibrated
  plan line must go down; the flatten is pure overhead on a full replan.
- `just benchmark-quick baseline=HEAD workload=incremental-mixed`: plan line
  is descriptive-only; report its per-draw plan number, expected to fall.
- The draw half (the removed clip scan) has no calibrated instrument; report
  it as measured-but-undecidable, not as a win.
- `just benchmark-headless-draw`: rerun to establish the new damage-clipped
  baseline (see AR1).

## Blast radius

Consumers that must move in the same change (inventory verified; no
per-file scripting implied):

- Planning: `TerminalRenderPlanning.swift`, `RenderFramePlanner.swift`
  (planner, retained state, translated-reuse helpers, delete `clipFramePlan`
  and its stale doc claim about consumers that no longer exist),
  `PaneFramePlanner.swift` (doc names `clipFramePlan`), `RenderInkReach.swift`.
- Execution: `TerminalRenderExecution.swift` (draw entry point, text and
  decoration passes), `TerminalFrameBackingStore.swift` (`apply` passes the
  plan damage to the draw; `renderFull` unrestricted), `TerminalFrameSwapchain.swift`
  (height rename).
- Benchmarks: `TerminalBenchmarkMarkers.swift`, `TerminalBrowseBenchmarkSupport.swift`,
  `TerminalDrawBenchmarkSupport.swift` (AR1), `scripts/terminal-headless-draw-arm.swift`
  (AR1), `app/TerminalBenchmark.swift` (height rename plus a comment naming
  `clipFramePlan`; compiles only under `DANTERM_TERMINAL_BENCHMARK` -- see AR3),
  prose in `scripts/damage-prize-sweep.py` and
  `scripts/terminal-headless-draw-compare.py` claiming the clip sits outside
  the timed bracket (false after AR1).
- App and harnesses: `app/SwiftTerminalSessionView.swift` (height rename),
  `lib/TerminalHostTools/Sources/GlyphPreview/main.swift`,
  `tests-ui/SwiftTerminalSessionViewTestShim.swift` (fake plan's height field),
  `scripts/research/33/t5-scroll-amplification-probe.swift` and
  `t3-damage-round-trips-probe.swift` (both probes have been maintained
  through prior engine refactors, so they move too).
- Tests: the five flat-accessor extension files; height-rename touches in
  planning, execution, and pane-session tests; `BitmapTestSupport`'s two
  clip call sites become row-restricted draws.
- Docs: `docs/design/2026-07-27-damage-render-benchmark-routing.md` (AR1's
  record, and its coverage table names `clipFramePlan` as an instrumented
  question -- that row must be amended deliberately; nothing lints symbols).

## Non-goals

- DRAW-1 (per-row ink reach computed in the planner) and FRAME-3: follow-ups,
  not this change.
- Removing the per-run `row` fields: runs keep them; the translated-reuse
  helpers still need them, and dropping them is separate work.
- Repairing `incremental-mixed`'s degraded verdict: routing ADR D2 stands.

## Accepted risks

- AR1 (user-accepted rider): the `damageClipped` arm of the headless draw
  benchmark can no longer pre-clip. The arm stores the row set and passes it
  into the timed `drawRenderFrame` call, so row selection -- O(damaged rows)
  on a row-indexed plan -- moves inside the timed region. The arm still
  measures drawing rather than filtering, but the number moves:
  `docs/design/2026-07-27-damage-render-benchmark-routing.md` must record
  that `benchmark-headless-draw`'s damage-clipped baseline is reset by this
  change rather than comparable across it, so a later regression cannot hide
  behind this commit.
- AR2: nested per-row iteration is less cache-friendly than one flat array,
  and a layer pass now visits empty rows. `content-churn` and `style-churn`
  calibrated lines are the watch.
- AR3: `app/TerminalBenchmark.swift` is invisible to `just test`; the change
  includes an explicit benchmark-configuration build to prove it compiles.

## Rejected ideas

- RI1: keep flat arrays and add per-layer row-start offsets (DRAW-2's shape,
  FRAME-1's stated fallback) -- removes the clip scan but keeps the flatten
  and two representations that can disagree.
- RI2: keep `clipFramePlan` but make it cheap -- re-permits the partial-plan
  value only the executor knows how to read, which this change exists to
  remove.
- RI3: serve tests a generic or lazy flat projection from the library --
  SwiftPM does not specialize a library's generics for another module
  (`docs/design/2026-07-29-cross-module-value-dispatch.md`), and a concrete
  library accessor re-permits the copy on production paths.

## Implementation discretion

- The concrete Swift shape of `RenderPlanRow`, the row-restriction parameter
  type on the draw entry point, and how a selection is materialized for the
  layer passes -- constrained only by I1/I3 and the no-flatten rule above.
- The exact rewrite of the corpus overlay helper, constrained by PO5.
