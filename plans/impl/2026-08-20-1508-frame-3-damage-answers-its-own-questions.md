# FRAME-3 pivot: damage answers its own questions, and travels as itself

Source: FRAME-3 in `docs/scratch/2026-08-18-construction-audit.md`, re-verified
against HEAD after INTERACT-3 (`d7f541e9`), FRAME-1 (`3bea76c5`) and DRAW-1
(`82e5acf1`) landed.

## Problem

Two per-frame hot paths build throwaway copies to ask `TerminalDamage` simple
questions.

- `TerminalFrameSwapchain.publish` decides whether a publish installs the
  whole-frame convergence barrier with
  `damage.expandingShift().damagedRowCount == plan.rowCount`. On every
  scroll publish that copies the word storage to fold the shift in, then
  popcounts it.
- `TerminalFrameBackingStore.apply` asks "which rows" with `damage.rowIndices`
  (an `[Int]` the type's own doc reserves for tests and diagnostics), hands it
  to `renderApplyShape(damagedRows: [Int])`, which builds two `[Bool]` arrays
  and an `[Int]` of planned rows and wraps those in a `TerminalDamage`; `apply`
  then turns that damage back into `[Int]` (`.expandingShift().rowIndices`,
  the fold being identity) for `drawRenderFrame(rows: [Int]?)`, which copies
  the matching `RenderPlanRow`s into one more array and checks the cursor row
  with a linear scan.

The same information crosses the seam as damage -> array -> damage -> array.
FRAME-1 created the round trip when it chose `[Int]?` for the executor's row
restriction while `RenderApplyShape.planDamage` stayed a `TerminalDamage`.

Load-bearing premises, verified in the tree:

- The internal `TerminalDamage.coversViewport(rowCount:)` is rows-only on
  purpose. `Terminal.swift#recordScrollDamage`'s flood fast path uses it to
  escalate to `.full` once every viewport row is already pending. A
  shift-aware reading there would be wrong: a whole-viewport scroll region
  plus one pending row "covers" trivially, so every second scroll would
  escalate and the translation path would vanish. The audit's "half of
  FRAME-3 arrives free from INTERACT-3" therefore does not hold; the
  swapchain needs a second predicate with fold semantics.
- DRAW-1 made `renderRowReaches(of:)` O(rows) via per-row ink classes. `apply`
  still computes it whole-plan once per apply, and must: `renderApplyShape`
  reads new reaches at the neighbours of every erase span. It is not part of
  this problem.
- `RenderApplyShape.planDamage` is always shift-free.
- `apply` has no second production caller yet: the phone calls only
  `renderFull` (`ios/.../TerminalSurfaceView.swift`). MOBILE-2 is ordered after
  this change for that reason. `drawRenderFrame`'s row restriction does have
  two more callers, and both migrate with the seam:
  `TerminalDrawBenchmarkSupport.swift#draw` (its `damage-clipped` scenario
  passes a four-row `[Int]?`, its `full-frame` scenario passes nil) and
  `GlyphPreview/main.swift` (nil for the whole grid, otherwise the visible row
  range).

## Decision

Let the damage value answer both questions without materializing anything,
and let it travel unchanged from the store into the executor.

1. `TerminalDamage` gains a public viewport-coverage predicate with fold
   semantics: true exactly when a consumer that folds the shift would see
   every row of `0..<rowCount` damaged (or the value is `.full`). It is a word
   scan that ORs the shift region in; it copies nothing. The existing
   rows-only internal predicate stays, renamed so the two cannot be confused,
   with a comment saying why it must ignore the shift. The swapchain's barrier
   check calls the public one.
2. The apply seam carries damage end to end. `renderApplyShape` takes the
   damage value (not a row array) and walks it; `drawRenderFrame`'s row
   restriction is a (shift-free) damage value, not `[Int]?`; `apply` passes
   `planDamage` straight through and updates its reach ledger by walking the
   damage. `rowIndices` leaves the hot path. The store's "damage names a row
   the store does not have" refusal stays, answered without allocating.
3. `rowIndices` and `expandingShift()` remain as test/diagnostic conveniences.
   Their measurement-bracket callers (`app/TerminalBenchmark.swift`,
   `TerminalBenchmarkDamageTopology.swift`) are untouched.

Behavior is unchanged at the pixel level, and unchanged at the barrier for
every plan/damage pair the live path produces, where the damage is sized to
the plan's grid: this is a simplification, measured as such (see
Verification). Public values whose own row count disagrees with the queried
`rowCount` follow the new prefix-coverage contract (I1) rather than today's
count check, which the live path never reaches.

## Invariants

- I1. The public coverage predicate is true exactly when every row of
  `0..<rowCount` is damaged once the shift is folded in logically, and it is
  true for `.full`. Prefix coverage is the definition, not a row count: a
  value whose damaged rows number `rowCount` but leave a row of
  `0..<rowCount` clean is not covering. It holds over empty, `.full`, rows
  only (saturated, partial), a shift whose region alone spans the viewport,
  shift region plus rows jointly covering, region plus rows leaving a gap,
  and viewports taller than one storage word. For non-full damage built for
  the same `rowCount`, the predicate matches
  `expandingShift().damagedRowCount == rowCount`; that equality is a
  cross-check on those values only, and it is not the contract.
- I2. The scroll site's flood fast path still ignores the shift: a
  whole-viewport-region scroll with pending rows composes into a summed shift
  across a drain and does not escalate to `.full`.
- I3. A publish whose damage folds to whole-viewport coverage installs the
  swapchain's whole-frame barrier (every buffer must render again before the
  swapchain reports all buffers current); a publish whose damage does not
  fold to full coverage does not.
- I4. Incremental application stays byte-identical to a from-scratch render
  across applied shifts, row-only damage, mixed sprite/accent/ASCII rows,
  DECSTBM regions, and stride-padded surfaces.
- I5. Under the caller's clip, drawing a plan restricted to a set of rows
  produces exactly the pixels a whole-frame draw produces within that clip,
  including the cursor. The executor prefills the whole frame with the default
  background whatever the restriction says, so "nothing elsewhere" is the
  clip's job, not the restriction's; the store installs that clip before it
  calls the executor.
- I6. `apply` refuses, with the store untouched, `.full` damage, a grid
  mismatch, and damage naming a row outside the store's grid.

## Proof obligations

- PO1 (I1): new cases in `TerminalDamageTests` / `TerminalShiftDamageTests`
  asserting the predicate over the listed value shapes, with at least one grid
  above 64 rows, `.full` true, and a case whose damaged-row count equals
  `rowCount` while a row of `0..<rowCount` stays clean (predicate false).
- PO2 (I2): existing `TerminalShiftDamageTests -- "two scrolls in one drain
  compose into one summed shift"` and `"an active selection rides a
  whole-viewport push scroll as a shift"` discharge it; they must stay green
  unedited.
- PO3 (I3): new `FrameSwapchainTests` cases publishing a shift-carrying damage
  whose region spans the viewport (barrier installed) and one whose region is
  partial with few rows (no barrier); today only `.full`/`.none` are
  exercised.
- PO4 (I4): existing `FrameBackingStoreTests` byte-identical suite stays green
  unedited.
- PO5 (I5): existing `ExecutorContractTests -- "Row-restricted drawing matches
  the same rows of a whole-frame draw"` adopts the new restriction type;
  assertions unchanged. It already installs the row clip on the context before
  both draws, which is the comparison I5 states.
- PO6 (I6): existing `"full damage and grid mismatch are refused with the
  store untouched"` plus one added case: damage sized to a taller grid naming
  a row the store lacks is refused and the pixels still equal the last frame.
- `RenderInkReachTests`' `renderApplyShape` cases adopt the damage-typed
  parameter; their shape assertions are unchanged.
- PO7: `TerminalDrawBenchmarkSupport` adopts the damage-typed restriction with
  its two scenarios unchanged -- `full-frame` draws every row, `damage-clipped`
  draws the same four rows -- and its `drawnRunCount` / `drawnCellCount`
  census still counts exactly the rows the restriction selects.
  `TerminalDrawBenchmarkSupportTests` stays green unedited except for the
  restriction type.

## Non-goals / Accepted risks / Rejected ideas

- Non-goal: inline word storage for the bitset (FRAME-4). Land this first so
  FRAME-4 spells one more word scan, not the reverse.
- Non-goal: narrowing `renderRowReaches` to damaged rows; DRAW-1 made it
  O(rows) and the apply shape needs neighbours anyway.
- Non-goal: changing the meaning of the whole-frame barrier. On same-grid
  plan/damage pairs -- everything the live path publishes -- the predicate
  reproduces today's fold semantics exactly.
- Accepted risk AR1: no benchmark cell on the ladder can see a handful of
  small allocations per presented frame (`agent-docs/measurement-discipline.md`).
  Report it as unmeasurable; a `scrollback-stream` quick run is a
  no-regression sanity check, not evidence of a win.
- Rejected idea RI1: one shared predicate used at both the scroll site and
  the swapchain. Rows-only breaks the barrier (misses viewport-wide shifts);
  shift-aware breaks the flood fast path (I2). They are two questions.
- Rejected idea RI2: keep `[Int]?` at `drawRenderFrame` and only swap
  `rowIndices` for spans. It leaves the damage -> array -> damage -> array
  round trip and a linear cursor check in place.

## Implementation discretion

- How the executor iterates plan rows under a damage restriction
  (`forEachRow` over `plan.rows` vs `contains(row:)` per row), and how the
  store answers "damage fits this grid" without allocating.
- Whether `renderApplyShape` builds `planDamage` through a `[Bool]` or records
  rows directly; only the absence of a materialized row array crossing the
  seam is contract.

## Critical files

- `lib/TerminalCore/Sources/TerminalCore/TerminalDamage.swift` -- the two
  predicates.
- `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalFrameSwapchain.swift`
  -- `publish`'s barrier check.
- `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalFrameBackingStore.swift`
  -- `apply`.
- `lib/TerminalCore/Sources/TerminalRenderPlanning/RenderInkReach.swift` --
  `renderApplyShape` / `RenderApplyShape`.
- `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift`
  -- `drawRenderFrame`'s restriction.
- `lib/TerminalCore/Sources/TerminalDrawBenchmarkSupport/TerminalDrawBenchmarkSupport.swift`
  and `lib/TerminalHostTools/Sources/GlyphPreview/main.swift` -- the other two
  callers of that restriction.
- Tests named under Proof obligations; `Terminal.swift#recordScrollDamage`
  only for the rename.

## Verification

- `swift test --package-path lib/TerminalCore --filter TerminalDamage`
- `swift test --package-path lib/TerminalCore --filter FrameSwapchain`
- `swift test --package-path lib/TerminalCore --filter FrameBackingStore`
- `swift test --package-path lib/TerminalCore --filter ExecutorContract`
- `swift test --package-path lib/TerminalCore --filter RenderInkReach`
- `swift test --package-path lib/TerminalCore --filter TerminalDrawBenchmarkSupport`
- `just test` once green locally.
- Optional sanity: `just benchmark-quick baseline=HEAD workload=scrollback-stream`;
  no directional claim is made from it (AR1).

## Commit progress
- [x] 1. damage answers viewport coverage with the shift folded in, and the swapchain barrier asks it
- [ ] 2. the apply seam carries damage end to end

## Implementation notes
- The fold-aware predicate reuses `TerminalDamageRowBits.covers` with an
  optional region rather than adding a second word scan: the shift region is
  ORed into each word as the scan reads it, so both predicates share one body
  and neither copies the storage.
- The two predicates are `coversViewportFoldingShift(rowCount:)` (public, the
  swapchain's) and `coversViewportIgnoringShift(rowCount:)` (internal, the
  scroll site's).
- One edge the old expression answered differently: a zero-row plan. The old
  count check read `0 == 0` and installed the barrier; prefix coverage of an
  empty viewport is false. The live path never publishes a zero-row plan.
