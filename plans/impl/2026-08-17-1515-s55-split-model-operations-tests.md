# S55: Split ModelOperationsTests along the boundary its name claims

Audit finding S55 in `docs/scratch/2026-08-11-simplification-audit.md`.

## Problem

`lib/DanTermCore/Tests/DanTermCoreTests/ModelOperationsTests.swift` is one
3,274-line `@Suite` holding 156 tests across 35 MARK sections. The name claims
ModelOperations.swift, but the content spans three source files: 12 sections
test functions defined in Projections.swift (`isFocusedAndVisible`, every
`desired*` projection, the TODO-popover projections, the alert-tally overload
wiring), and 2 sections test TabTodo.swift (`buildTabTodoRows`,
`resolveTabTodoReorderStep`). A reader looking for a projection's coverage
cannot guess the file, and failure output blames `ModelOperationsTests` for
projection regressions. Several MARK headings still carry stage numbers from a
finished migration, and the file header describes that migration. The MARK
headings are also not a reliable inventory: the three `desiredConfirmation`
(close/quit confirmation) tests sit inside the `desiredSwitcher` section with
no heading of their own.

Corrections to the audit finding, verified against the current tree
(the finding was written 2026-08-11 and has drifted):

- The file is now 3,274 lines / 156 tests; two tests left with S49
  (`e7e30252`).
- `resolveContextTargets`, `resolveReloadSelection`,
  `shouldForceSidebarRowEmphasis`, `resolveColorForBatch`, `tabTodoRollup`,
  `assignJumpKeys`, and the switcher/jump input classifiers are defined in
  ModelOperations.swift, not Projections.swift. Their tests are correctly
  housed and stay.
- Conversely, `isFocusedAndVisible` is defined in Projections.swift and is
  mis-housed today.
- The audit's "fold the dedicated subject files" instruction mostly
  dissolves. AlertPresentationTests, SidebarItemStoreTests,
  TodoPopoverStateTests, and ChipKindTests each cover a source file of the
  same name and are already correctly placed. SwitcherEventTests (23 tests)
  and UnreadAlertTallyTests (3 tests) cover ModelOperations.swift subjects
  under coherent, truthful names; folding them back would re-grow the
  monolith this finding shrinks. The one genuinely mixed file is
  PaneToolbarTests.swift: it holds two suites -- `PaneToolbarTests` (5 tests
  of `formatToolbarLabel`, which moved to PaneLifecycleConsumers.swift in
  `db7a6456`) and `PaneToolbarCompositionTests` (9 tests of the
  `desiredPaneToolbar` projection, defined in Projections.swift).

## Decision

Split by defining source file, the directory's dominant convention (a test
file is named for the source file it covers; only Update.swift, tested
through the `Msg` surface, splits by subject into `UpdateXxxTests`).

- `ProjectionsTests.swift` (new) receives the 12 Projections.swift sections:
  isFocusedAndVisible, desiredAlertsPopover, desiredSwitcher (including the
  three `desiredConfirmation` tests embedded in that section, which get
  their own MARK heading), the TODO-popover projections, desiredThemeBrowser,
  the alert-projection tally overloads, desiredFocusBorders,
  desiredPaneToolbar, desiredSearchOverlays, desiredPaneConfig,
  desiredSidebar, desiredWindowChrome. It also receives the 9
  `PaneToolbarCompositionTests` tests of `desiredPaneToolbar` from
  PaneToolbarTests.swift.
- `TabTodoTests.swift` (new) receives the 2 TabTodo.swift sections:
  `buildTabTodoRows` row building and `resolveTabTodoReorderStep`.
  (UpdateTabTodoTests is not the home: it tests through the `Msg` surface;
  these sections call TabTodo.swift functions directly.)
- `ModelOperationsTests.swift` keeps the 21 sections whose subjects live in
  ModelOperations.swift.
- `PaneToolbarTests.swift` dissolves by suite: the 5 `formatToolbarLabel`
  tests move into `PaneLifecycleConsumerTests.swift` (the file named for
  their subject's source file), the 9 `PaneToolbarCompositionTests` tests
  move into `ProjectionsTests.swift`, and the file is deleted, removing the
  name collision with the projection.
- Stage numbers ("Stage 3" ... "Stage 7") disappear from MARK headings.
  Every touched file gets a header that truthfully says what it holds and
  what does not belong (AGENTS.md file-header rule); the migration-era
  header prose (legacy-harness migration notes, inventory-parity notes) does
  not survive on touched files.
- The file-private fixture used by sections landing in two different files
  (the two-pane tab-todo model builder) graduates to TestSupport.swift
  beside the existing cross-suite MRU fixture.

Pure test reorganization; no file under `Sources/` changes. After landing,
tick S55's Status row in the audit with the commit hash (table row only,
finding prose untouched; the corrections above go in the commit body, per
the S49 convention).

## Invariants

- I1: Every test body and expectation is unchanged. The diff is moves plus
  MARK-heading, suite-name, file-header, and fixture-visibility edits.
- I2: No test is dropped or duplicated: the package-wide executed-test count
  is identical before and after.
- I3: Every test in the affected files exercises a subject defined in the
  source file its file name claims (or, for PaneLifecycleConsumerTests, a
  subject its header names).
- I4: A projection failure reports as `ProjectionsTests/...` in test output.

## Proof obligations

- PO1 (I1, I2): `swift test --package-path lib/DanTermCore` passes before
  and after with the same executed-test total; `just test` gate green.
- PO2 (I3): re-verify each moved section's subject against `func`
  definitions in the current tree at implementation time -- definitions have
  moved twice this week (`e7e30252`, `db7a6456`), and the mapping above is
  only as fresh as its derivation.

## Non-goals

- Splitting ModelOperations.swift itself. The source file is its own
  grab-bag (tree ops, MRU, input classifiers, sidebar resolvers, tally, jump
  keys); that smell stays on the table but is not S55.
- Folding SwitcherEventTests, UnreadAlertTallyTests, ChipKindTests,
  AlertPresentationTests, SidebarItemStoreTests, or TodoPopoverStateTests
  (see corrections above).
- S25 (compute a tab's chrome once per sidebar row). Interaction only: any
  future S25 tests belong in ProjectionsTests.swift.

## Rejected ideas

- RI1: The audit's cheaper fallback -- keep one file, nest `@Suite` types
  per subject. It fixes the failure-output label but keeps the 3,274-line
  file and the two-plausible-files ambiguity against the dedicated files.
  The split is small; the fallback saves almost nothing.
- RI2: Applying "one test file per source file" to the whole directory
  (folding the dedicated files). The directory's convention permits
  subject-named files with truthful headers; enforcement for its own sake
  re-grows monoliths.

## Implementation discretion

- Whether ProjectionsTests is one flat suite with MARK sections or nested
  per-projection suites, and section ordering within each file.

## Implementation notes

- PO2's re-verification changed the split for one MARK section. "TODO Popover
  Projections" mixes two source files: `desiredPaneTodoPopover` and
  `desiredTabTodoPopover` (4 tests) come from Projections.swift, while
  `resolveTabTodoEditTarget`, `newlyAddedTabTodoTarget`,
  `resolveTabTodoDropTarget`, and `resolveTabTodoBucketStep` (20 tests) come
  from TabTodo.swift. I3 routes by defining source file, so TabTodoTests
  receives 5 sections rather than the 2 the plan named, and only the 4
  `desired*` tests go to ProjectionsTests.
- The plan noted that the MARK headings are not a reliable inventory. A second
  instance turned up beside the embedded `desiredConfirmation` tests:
  `assignJumpKeysCapsAtSequenceCount` sat at the end of the
  `resolveTabTodoReorderStep` section. It moved up under the existing
  `Tab Jump Mode` heading with its two siblings.
- The 9 `PaneToolbarCompositionTests` tests land as a flat MARK section inside
  `ProjectionsTests`, not a nested suite, so a failure reports as
  `ProjectionsTests/...` per I4. That suite's doc comment survives as the
  section's comment, because it explains why the composed strings are asserted
  here instead of through a window.
- I1 was verified mechanically rather than by eye: every `@Test` block was
  extracted from the before and after trees and compared by name and body. All
  175 blocks match byte for byte, with no drops and no duplicates. Final split:
  ModelOperationsTests 86, ProjectionsTests 45, TabTodoTests 34,
  PaneLifecycleConsumerTests 10.
- PO1: `swift test --package-path lib/DanTermCore` reports 1270 tests in 61
  suites both before and after; the `just test` gate passes all 91 steps.

## Follow Up

- Tick S55's Status row in `docs/scratch/2026-08-11-simplification-audit.md`
  (the table row for S55) with this commit's hash, per the plan's post-landing
  step and the S49 convention. It cannot go in this commit, which would have to
  name its own hash.
