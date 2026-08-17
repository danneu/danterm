# Delete the dead unread-alert helpers; make the tally the only definition

## Context

Unread alerts are counted five ways in `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift`, and a comment there instructs future readers to keep the five numerically equivalent by hand. Four of them -- `paneHasUnreadAlert`, `unreadAlertCount(for:alerts:)`, `groupUnreadAlertCount`, `totalUnreadAlertCount` -- have no production caller. Every render path reads `unreadAlertTally` instead (`Projections.swift` at the four `desired*` entry points, `app/Reconcile.swift`, `app/SidebarReconcileDriver.swift`), and the tally's `total` feeds the window chrome.

Audit finding S49 in `docs/scratch/2026-08-11-simplification-audit.md` names three of the four. It is understated: it treats `unreadAlertCount` as still live via the sidebar context menu, but `247f8dc8` ("paint every row from its own projection") moved that call site to `SidebarTabProjection.unreadAlertCount`, a field the reconciler already fills from the tally. So the fourth is dead too.

The four survive only because tests call them. `UnreadAlertTallyTests` asserts the tally equals the helpers, and two tests in `ModelOperationsTests` exercise the helpers directly. That means the suite checks one implementation against another rather than against stated behavior -- which is what forces the hand-sync comment to exist.

Outcome: one definition of "how many unread alerts", and tests that state the counts instead of comparing two implementations.

## Decision

Delete all four helpers and the equivalence comment. `unreadAlertTally` becomes the sole definition. Convert every assertion that referenced a deleted helper into a literal expected count on the tally, carrying over the counts the deleted tests already pinned.

No production code changes: nothing outside `lib/DanTermCore/` calls the four, so this is a source deletion plus a test rewrite.

If a cross-check implementation is still wanted for the tally, it belongs in the test file as a `private func`, not in `Sources/` -- the precedent is `lib/TerminalCore/Tests/TerminalBenchmarkMarkersTests/`, which keeps its reference implementation inside the test target.

## Invariants

- **I1.** The tally's `total` counts every unread alert in the model, including alerts whose pane no longer appears in any split tree.
- **I2.** `byTab` and `byGroup` are tree-restricted: they count only unread alerts on panes reachable from that tab's or group's pane tree, so a stale-pane alert reaches `total` but no tab or group bucket.
- **I3.** Every live tab and group gets a key in `byTab` / `byGroup`, including a zero-valued one; projections must not have to distinguish "absent" from "zero".
- **I4.** Read alerts contribute nothing; repeated unread alerts on one pane sum.
- **I5.** Sidebar badges, pane toolbar badges, and window chrome show the same numbers after the change as before.

I1-I4 are already stated on the `UnreadAlertTally` doc comment, so no new prose is needed there -- only the "must stay numerically equivalent to ..." comment goes.

## Proof obligations

- **PO1 (I1, I2).** A model with one unread alert on a pane absent from every tree: `total` is 1, the tab and group buckets are 0. Already covered by the stale-pane test once its helper comparison is dropped.
- **PO2 (I2, I4).** A hand-built model with known alerts across split tabs, leaf tabs, two groups, and read/unread/repeated alerts: assert the per-pane, per-tab, per-group, and total counts as literals.
- **PO3 (I3).** An empty model and a model where one tab has no alerts: the zero-valued tab and group keys are present.
- **PO4 (I5).** `just test` passes, and `just test-ui` passes -- the sidebar UI tests are what would catch a badge regression.

PO2 absorbs the two `ModelOperationsTests` helper tests; their tab-level (2) and group-level (1) expectations move over as tally assertions rather than being lost.

## Non-goals

- Changing what any badge displays. This is a delete-and-restate pass with no behavior change.
- Touching the todo rollup that sits beside the alert tally in the same projections.

## Accepted risks

- **AR1.** Deleting `paneHasUnreadAlert` leaves the "Alert Helpers" section holding only `filteredAlerts` and `alertsEmptyText`. Acceptable: the section still names what it holds.

## Rejected ideas

- **RI1.** Keep one helper as a test oracle in `Sources/`. Rejected: production code with only test callers is what created this finding, and a test-target-local helper serves the same purpose without the hand-sync obligation.

## Implementation discretion

- Whether PO2 and PO3 stay as separate `@Test` functions or merge, and how the fixture models are built.

## Verification

1. `swift test --package-path lib/DanTermCore --filter UnreadAlertTallyTests` -- the rewritten tally tests.
2. `swift test --package-path lib/DanTermCore --filter ModelOperationsTests` -- confirms the two deleted helper tests left no dangling reference.
3. `just test` -- the gate; also proves the app target still builds with the four symbols gone.
4. `just test-ui > .build/ui.log 2>&1`, then grep the log -- the sidebar badge coverage for PO4.
5. Live check for I5: `just launch-slot`, run a command that rings the bell in a background pane, confirm the tab and group badges show the count and clear on read, then `just stop-slot <n>`.

## Final task

After the implementation lands, mark S49 complete in the Status column of
`docs/scratch/2026-08-11-simplification-audit.md`. Use the landed implementation
commit hash, following the existing `docs(scratch): mark SNN landed` convention.

## Implementation notes

- The PO2 fixture was reshaped so the two deleted `ModelOperationsTests`
  expectations survive as literals rather than being folded into the old
  model: a split tab carrying one unread alert on each pane rolls up to 2,
  and a two-tab group where only the second tab has an alert rolls up to 1.
  The old fixture happened to reach 2 through two alerts on one pane, which
  would not have carried the split-tab sum over.
- The `UnreadAlertTally` doc comment said `byTab` and `byGroup` were
  tree-restricted "matching the tab/group helper semantics". With the helpers
  gone that clause pointed at nothing, so it now states I2 and I3 directly.
- Verification step 5 ran as far as the CLI reaches: a background tab rang
  the bell in dev slot 1, the app stayed responsive through the alert and
  logged no crash. The badge numbers were not read visually -- there is no
  CLI query for alert counts, and this commit leaves `app/` untouched, so
  every badge render path is byte-identical to the pre-change one.

## Follow Up

- Mark S49 landed in the Status column of
  `docs/scratch/2026-08-11-simplification-audit.md`, citing this commit's
  hash, per the plan's Final task. It needs the hash, so it cannot ride in
  this commit.
- The "Shared Pure Helpers" section comment in
  `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift` says each member
  "has a caller outside the projection cluster (Update / AppRuntime / a view)
  as well as inside it". Its one remaining member, `formatToolbarLabel`, has a
  single caller -- `PaneLifecycleConsumers.swift#paneCommandChromeText`, which
  is itself a projection -- so the "outside" half is false. The staleness
  predates this commit (the three helpers deleted here had no callers at all),
  so it was left alone rather than drifting outside the plan.
