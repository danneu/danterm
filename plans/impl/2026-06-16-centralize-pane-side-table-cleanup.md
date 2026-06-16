# Plan: Unify per-pane side-table cleanup into `clearPaneSideTables`

## Context

When a pane is destroyed, three id-keyed side tables in `AppModel` must be
pruned for it: `alerts` (filtered by `paneId`), `searchState`, and
`lastNotificationTime`. Today that cleanup is an identical three-line triplet
copy-pasted verbatim at all five pane-destruction sites in
`lib/DanTermCore/Sources/DanTermCore/Update.swift`:

```swift
removeAlertsForPane(pid, in: &model)
removePaneSearchState(pid, from: &model)
model.lastNotificationTime.removeValue(forKey: pid)
```

There is **no present bug** -- all five sites are currently correct and
identical. The cost is future: the triplet is the complete set of pane-keyed
model side tables (verified against `Model.swift:191-193`; the other
`[PaneId: ...]` maps are pure projections or runtime-side caches torn down by
reconcile), so the day a fourth pane-keyed table is added, whoever adds it must
remember to patch all five sites or silently leak that table's entries on every
pane close. This refactor collapses the triplet into one helper,
`clearPaneSideTables(_:in:)`, so a new side table is added in exactly one place.

This was confirmed via `/verify-issue` (action: **refactor** -- finding correct,
proposed fix is the right shape). The user chose the *cohesive* home: co-locate
all per-pane cleanup primitives plus the composite in `ModelOperations.swift`,
the documented home for pure model-mutation helpers.

### Out of scope (deliberately)

- **The `todoPopover` dismissal** at `.closePane` and `closeTabBody` is **not**
  part of the triplet and stays exactly as-is. It is a single optional slot plus
  an emitted AppKit `Command` (not an id-keyed table), and the two destruction
  paths that omit it (`.surfaceCreationFailed`, `.deleteGroup`) are already
  covered by the post-update `reconcileTodoPopover` strand mechanism
  (`Update.swift:13-16`, `ModelOperations.swift:902`). No change there.
- **Pane/tab *move* sites** (`.movePane`, `.movePaneToTab`, cross-group tab
  moves) correctly do **not** clean side tables -- the pane survives and keeps
  its state. They must remain untouched.

## The change

### 1. Co-locate the cleanup primitives in `ModelOperations.swift`

Rename the existing `// MARK: - Search Cleanup` section
(`ModelOperations.swift:28-33`) to `// MARK: - Pane side-table cleanup` and grow
it to hold all three:

- **Move** `removeAlertsForPane` out of `Update.swift` (currently `private`,
  `Update.swift:2511-2514`) into this section, demoting `private` -> internal
  (file-scoped `private` would block the cross-file move; internal matches its
  new sibling `removePaneSearchState`). Body is unchanged:
  `model.alerts.removeAll { $0.paneId == paneId }`.
- **Keep** `removePaneSearchState` where it is.
- **Add** the composite:

```swift
/// THE single place that prunes every per-pane id-keyed side table when a pane
/// is destroyed. Every pane-destruction path calls this; adding a new pane-keyed
/// table to `AppModel` means adding one line here, not patching five call sites.
func clearPaneSideTables(_ paneId: PaneId, in model: inout AppModel) {
    removeAlertsForPane(paneId, in: &model)
    removePaneSearchState(paneId, from: &model)
    model.lastNotificationTime.removeValue(forKey: paneId)
}
```

Use the `in:` label (matches `removeAlertsForPane` / `markAlertsReadForPane`;
the helper mutates the whole model rather than removing from one named
container). Keep it internal so the test target (`@testable import DanTermCore`)
can call it directly.

Update the two primitives' doc comments so they no longer claim to be the
destruction-path entry point (that role now belongs to `clearPaneSideTables`):
- `removeAlertsForPane`: "Remove all alerts for a pane being destroyed. Called
  via `clearPaneSideTables`."
- `removePaneSearchState`: drop "Called from all pane-destruction paths."

### 2. Rewrite the five call sites in `Update.swift`

Replace each verbatim triplet with a single `clearPaneSideTables` call. The
surrounding code (loops, comments about reconcile owning surface teardown, the
`todoPopover` dismissal blocks) stays:

| Site | Location | Form |
| --- | --- | --- |
| `.closePane` | `Update.swift:223-225` | `clearPaneSideTables(paneId, in: &model)` |
| `.surfaceCreationFailed` sibling loop | `Update.swift:822-824` | `clearPaneSideTables(pid, in: &model)` |
| `.surfaceCreationFailed` defensive fallback | `Update.swift:843-845` | `clearPaneSideTables(paneId, in: &model)` |
| `.deleteGroup` | `Update.swift:1011-1013` | `clearPaneSideTables(pid, in: &model)` |
| `closeTabBody` | `Update.swift:2548-2550` | `clearPaneSideTables(pid, in: &model)` |

The per-site "keep the id-keyed side-table cleanup here" comments can be trimmed
to reference the helper (e.g. "side-table cleanup via `clearPaneSideTables`"),
since the *why* (reconcile owns surface teardown, this owns model state) still
belongs at the call site.

### 3. Strengthen the per-site tests, then add the helper invariant test

The existing `update()`-path tests are structure-insensitive and survive the
refactor, but each currently asserts only a *subset* of the triplet for its path,
so they do not by themselves prove every call site performs the *full* cleanup.
A partial or wrong call-site rewrite (clears alerts but not searchState, say, or
misses a site) could still pass every named test. Today's per-path coverage:

| Destruction path | Existing test | Currently asserts |
| --- | --- | --- |
| `.closePane` | `testClosePaneRemovesAlertsAndCleansUpThrottle` (`UpdateAlertTests.swift:334`) | alerts, lastNotificationTime |
| `closeTabBody` (`.closeTab`) | `testCloseTabRemovesAlertsForAllPanes` (`UpdateAlertTests.swift:358`) | alerts only |
| `.surfaceCreationFailed` (pane in a tab) | `testSurfaceCreationFailedRemovesAlerts` (`UpdateAlertTests.swift:386`) + `surfaceCreationFailedInSplitRemovesTabAndCleansSiblings` (`TreeOwnsPanesTests.swift:253`) | alerts + lastNotificationTime (single) / searchState + lastNotificationTime (siblings) |
| `.surfaceCreationFailed` defensive fallback (pane in no tree, `Update.swift:843-845`) | `surfaceCreationFailedForUnknownPaneIsNoop` (`TreeOwnsPanesTests.swift:306`) | structure only -- seeds nothing, asserts model byte-equal; does **not** exercise the branch's side-table clear |
| `.deleteGroup` | `deleteGroupCleansUpSearchState` (`UpdateSearchTests.swift:231`) | searchState only |

Close the gap so the suite enforces the centralization claim -- every site clears
all three:

- **Extend each per-path test** to seed `alerts`, `searchState`, AND
  `lastNotificationTime` for a destroyed pane and assert all three are cleared.
  Concretely: add searchState + lastNotificationTime to
  `testCloseTabRemovesAlertsForAllPanes`; add searchState to
  `testClosePaneRemovesAlertsAndCleansUpThrottle` and
  `testSurfaceCreationFailedRemovesAlerts`; add alerts + lastNotificationTime to
  `deleteGroupCleansUpSearchState`. Keep the existing assertions; only add the
  missing tables. (These live across `UpdateAlertTests.swift` and
  `UpdateSearchTests.swift`; `TreeOwnsPanesTests.swift:253` already covers the
  sibling cascade and needs no change.)
- **Add a fallback *cleanup* test** complementing the existing structural no-op
  (`surfaceCreationFailedForUnknownPaneIsNoop`, `TreeOwnsPanesTests.swift:306`,
  which seeds nothing and asserts the model is unchanged): dispatch
  `.surfaceCreationFailed(paneId:)` for a pane id that is in no tab (hits the
  `Update.swift:843-845` defensive branch) with all three tables seeded for it,
  and assert all three clear. This is the one fallback branch whose *side-table
  cleanup* is unasserted today -- the no-op test can't catch a dropped clear
  because it seeds nothing. (Place it near the existing no-op test, or in the
  helper-test peer.)
- **Add one direct helper test** that calls `clearPaneSideTables` directly: seed
  all three, call it, assert all three cleared in one place -- the canonical
  statement that "these three are the complete set," so a future fourth table
  added to the helper but forgotten here is visible.

Give any new test a `//` preamble (Intent / Why it exists / Scenario) per the
test-style gate; spec-first, so the Scenario is the user-facing behavior, not an
invented incident.

## Critical files

- `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift` -- new
  `clearPaneSideTables`, moved `removeAlertsForPane`, renamed section, doc tweaks.
- `lib/DanTermCore/Sources/DanTermCore/Update.swift` -- remove
  `removeAlertsForPane`'s definition; rewrite the five call sites.
- `lib/DanTermCore/Tests/DanTermCoreTests/` -- extend the per-path tests in
  `UpdateAlertTests.swift` (`testClosePaneRemovesAlertsAndCleansUpThrottle`,
  `testCloseTabRemovesAlertsForAllPanes`, `testSurfaceCreationFailedRemovesAlerts`)
  and `UpdateSearchTests.swift` (`deleteGroupCleansUpSearchState`) to assert the
  full triplet; add the `.surfaceCreationFailed` no-tree fallback test and the
  direct `clearPaneSideTables` helper test (e.g. in `UpdateAlertTests.swift` or a
  small `ModelOperationsTests` peer).

## Verification

1. `just test` -- the local gate (core Swift Testing + protocol XCTest + support
   + core-purity lint + shell self-tests). Must stay green; after the Step 3
   strengthening, each destruction-path test seeds and asserts all three tables,
   so they are the behavioral guard that every site prunes the full triplet.
2. Targeted run while iterating:
   `swift test --package-path lib/DanTermCore` (optionally
   `--filter UpdateAlertTests` and the new test's name).
3. Confirm the refactor is purely mechanical -- every cleanup primitive is now
   reached only through the helper:
   - `git grep -n "removeAlertsForPane"` -> defined once (in
     `ModelOperations.swift`), called only from `clearPaneSideTables`; zero hits
     in `Update.swift`.
   - `git grep -n "removePaneSearchState"` -> defined once (in
     `ModelOperations.swift`), called only from `clearPaneSideTables`; zero hits
     in `Update.swift`. (This primitive already lived in `ModelOperations.swift`,
     so the check guards against a leftover direct call in `Update.swift`.)
   - `git grep -n "lastNotificationTime.removeValue"` -> only inside
     `clearPaneSideTables`; zero hits in `Update.swift`.
   - `git grep -n "clearPaneSideTables(" -- '*/Update.swift'` -> exactly the five
     call sites. The trailing `(` matches the call form only, so the comment
     mentions of the helper that Step 2 allows at call sites don't inflate the
     count.
4. core-purity lint passes automatically (the helper is a pure dictionary/array
   mutation with no IO or ambient `Date()`/`UUID()` reads).
