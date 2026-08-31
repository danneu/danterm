# Walk the tree in the per-pane projections instead of materializing `allPanes`

Source finding: MODEL-6 in `docs/scratch/2026-08-26-improvement-audit.md`
(1x5, small, cost -- rescored to a tidy-up, not a cost win).

## Problem

Four projections in
`lib/DanTermCore/Sources/DanTermCore/Projections.swift` --
`desiredFocusBorders` (:579), `desiredSearchOverlays` (:717),
`desiredPaneConfig` (:779), and `desiredConfirmation`'s quit rollup
(:1462) -- iterate `model.allPanes`, which flattens every tab's split tree
into a fresh `[PaneModel]` of whole value copies. The first three run on
every reconcile sweep. The non-allocating shape already exists one function
away: `desiredPaneToolbar` (:651) and `effectivePaneVisibility`
(`ModelOperations.swift:251`) walk `forEachPane(in: tab.paneTree.root)`.

Comments that name the old shape are stale or become stale:
`Projections.swift:488` still claims "pane toolbar ... still walk
`model.allPanes`" (false since `desiredPaneToolbar` moved to the tree
walk), `Projections.swift:572` documents `desiredFocusBorders` as keyed
through `allPanes`, and `Model.swift:758-761` documents the per-sweep
rebuild.

Sweep cadence is per-`Msg`, coalesced to ~75 ms -- so this is a tidy-up
that removes an unnecessary materialization, compatible with the "Projection
Scan Cost" rule in
`docs/design/2026-05-27-model-driven-view-reconciliation.md` (it removes a
materialization; it does not add a precomputed context bag).

## Decision

Add one model-level walk, `forEachPane(in: AppModel, _ body:)`, next to the
node-level `forEachPane` in `ModelOperations.swift`, convert all four
projections to it, and delete `AppModel.allPanes` from production code.
`desiredConfirmation` appends running commands during the walk -- it needs
an ordered command list, not an intermediate pane array. Deleting the
production materializer makes the reconcile-sweep issue unable to recur
through a future caller, which is why this beats converting only the three
sweep projections.

Tests that still want a pane array get a test-only `allPanes` convenience
in `lib/DanTermCore/Tests/DanTermCoreTests/TestSupport.swift`.

`desiredPaneToolbar` and `effectivePaneVisibility` keep their inline
group/tab loops: they need per-tab facts the plain walk does not carry.

The three stale comments above are corrected in the same change to
describe the post-change traversal without naming `allPanes`.

## Invariants

- I1: Each converted projection returns the same result, key for key and
  value for value (and for the quit rollup, in the same tab-then-tree
  order), as before the change.
- I2: Production code materializes no whole-model pane array;
  `AppModel.allPanes` does not exist outside test support.

## Proof obligations

- PO1 (I1): the existing projection tests (focus borders, search overlays,
  pane config) and the quit-confirmation test, which already proves
  app-wide command collection and pane order, stay green unchanged.
- PO2 (I2): carried by the deletion itself -- production code referencing
  `allPanes` no longer compiles.

## Non-goals

- Any measurement or benchmark -- the audit's rescore already adjudicated
  this as a tidy-up needing none.

## Rejected ideas

- RI1: Keep `AppModel.allPanes` in production for `desiredConfirmation` --
  rejected: that caller needs only the running-command list, and keeping
  the property leaves the materialization one convenient call away for
  future projections.

## Verification

- `swift test --package-path lib/DanTermCore` (projection and
  quit-confirmation suites cover PO1).
- `just lint` in the edit loop; `just test` before the commit.

## Commit progress

- [x] 1. refactor(core): walk app pane trees without materializing `allPanes`
- [x] 2. docs(audit): mark MODEL-6 complete
