# Promote AlertsPopoverView into the tests-ui harness

Intended final home: `plans/todo/harness-alerts-popover.md` (per the original
task brief; move/rename on promotion).

## Context

Third promotion of a real `app/` view into the GhosttyKit-free UI harness,
following the pattern from PaneWrapperView (8da7613) and TabTodoPopoverView
(265ee65, plan at `plans/impl/2026-06-11-tab-todo-popover-ui-harness.md`):
compile the view into `test-ui.sh`'s single swiftc invocation, back it with
the shim `AppRuntime` (`tests-ui/SidebarViewTestShim.swift:5-30`), and pin
behavior with `uiTest` cases asserting on `runtime.sentMessages`.

`app/AlertsPopoverView.swift` (237 lines) is the NSTableView alert feed:
row click activates the originating alert, plus a "Show all" checkbox and a
"Mark All Read" button, all reconciled from `AlertsPopoverProjection` via
`apply(_:)`. It has production-only coverage today.

Feasibility is pre-verified (this plan's investigation phase):

- **Zero GhosttyKit.** The file imports Cocoa only. Its full type closure is
  already in the compile list: `AlertRowProjection` / `AlertsPopoverProjection`
  / `desiredAlertsPopover(in:)` (`lib/DanTermCore/Sources/DanTermCore/Projections.swift:117-152`),
  Msg cases `.activateAlert` / `.setShowAllAlerts` / `.markAllAlertsRead`
  (`Msg.swift:107-110`), `AlertModel` / `AlertId` / `AlertKind`
  (`Model.swift:21-36`), `filteredAlerts` / `alertsEmptyText` / `AlertTab`
  (`ModelOperations.swift:640-654`). The only `AppRuntime` surface it touches
  is `runtime?.send(_:)`, which the shim already records. **No shim code
  changes (comment-only header refresh, see 1b); no production changes.**
  Phase 1 is one line in `test-ui.sh` plus that comment.
- **No pre-phase id-vs-index fix.** `tableViewSelectionDidChange`
  (`app/AlertsPopoverView.swift:136-141`) resolves `selectedRow` to
  `projection.rows[row].id` synchronously and sends the typed `AlertId`;
  no index crosses an async hop.
- **Stale-pane resolution is core's job**, already pinned: `.activateAlert`
  with a dead `paneId` marks read + dismisses, no navigation
  (`Update.swift:881-898`, tested in
  `lib/DanTermCore/Tests/DanTermCoreTests/UpdateAlertTests.swift`). The view's
  stale-row contract is only "still send the typed id".
- **apply-then-apply is a real production path**:
  `Reconcile.reconcileAlertsPopover` (`app/Reconcile.swift:373-382`, fixed by
  d797b50) re-applies changed projections to an open popover. Worth pinning.

Because the view already exists and is simple, Phase 2 is honest
**characterization**: tests are expected green on first compile. TDD rigor
comes from the negative check in Verification (flip an assertion, watch it
fail for the right reason).

## Phase 1 -- Harness enablement

Preflight: run `just test-ui` once BEFORE touching anything to confirm the
baseline is green -- the all-or-nothing compile makes a dirty baseline
indistinguishable from a Phase 1 breakage. Note: the workspace currently
carries uncommitted in-flight harness wiring for a separate TodoPopover
promotion (`test-ui.sh:43,61`, `tests-ui/PaneSplitViewTests.swift:21`,
untracked `tests-ui/TodoPopoverViewTests.swift`); baseline verified green
89/89 with that wiring in place (2026-06-11). If the preflight is red, fix
or stash the in-flight work first -- it is not this plan's scope.

Gate: `just test-ui` compiles and all existing suites stay green. No new test
file yet -- the harness is all-or-nothing (one swiftc invocation,
`test-ui.sh:18-61`), and an empty registered suite buys nothing.

### 1a. Extend the compile list (`test-ui.sh`)

One line: add `"$SCRIPT_DIR/app/AlertsPopoverView.swift" \` at the end of the
app-file group (currently after `app/TodoPopoverView.swift`, `test-ui.sh:43`),
keeping the app-files-before-tests grouping.

### 1b. Refresh the shim file header (comment-only)

`tests-ui/SidebarViewTestShim.swift:1-2` enumerates the views it supports
(now five, after the in-flight TodoPopover wiring appended two more); the
list grows stale with every promotion. Generalize it instead of appending a
sixth name, e.g.: "Minimal test-only symbols (shim AppRuntime, TerminalView)
needed to compile the real app/ views in the UI harness -- see the app-file
section of test-ui.sh's compile list." No code changes.

### 1c. Gate run

`just test-ui` (needs a GUI session; fine from an agent shell in a logged-in
session). This compile-checks the view against the shim `AppRuntime` before
any test exists -- cheap insurance against the all-or-nothing compile. Expect
the existing `N/N passed` output unchanged.

## Phase 2 -- Behavioral tests

New file `tests-ui/AlertsPopoverViewTests.swift` with
`func alertsPopoverViewTests()`:

- Register in `UITestRunner.main` after the last suite call (currently
  `todoPopoverViewTests()`, `tests-ui/PaneSplitViewTests.swift:21`).
- Add `"$SCRIPT_DIR/tests-ui/AlertsPopoverViewTests.swift" \` at the end of
  the tests-ui group (currently after `tests-ui/TodoPopoverViewTests.swift`,
  `test-ui.sh:61`).
- House style: `uiTest`/`uiExpect` (`tests-ui/PaneSplitViewTests.swift:32-52`);
  Intent / Why it exists / Scenario preambles per AGENTS.md where warranted
  (these are spec-first; most need only a descriptive title); file-private
  helpers duplicated per suite (existing convention).

### Fixture

Modeled on `makeTabTodoFixture` (`tests-ui/TabTodoPopoverViewTests.swift:386-454`):

```swift
private struct AlertsFixture {
    let vc: AlertsPopoverViewController
    let runtime: AppRuntime   // fixture holds the strong ref; vc.runtime is weak
    let window: NSWindow
    let model: AppModel
    let paneId: PaneId        // the live pane alerts can point at
    let table: NSTableView    // found by type traversal (private on the vc)
}

private func makeAlertsFixture(alerts: [AlertModel], showAll: Bool = false) -> AlertsFixture
```

- Model: one `GroupModel` / one `TabModel` with a single leaf
  `PaneModel(id: paneId)` via `AppModel(groups:)` so non-stale paneIds
  resolve; set `model.alerts` and `model.showAllAlerts`. Ids via the no-arg
  `TypedId()` init (`tests-ui/TypedIdTestInit.swift`). Alert builder:
  `makeAlert(paneId:title:body:isUnread:ageSeconds:)` with
  `createdAt: Date(timeIntervalSinceNow: -ageSeconds)`.
- Host: `vc.runtime = runtime`, `window.contentView = vc.view` (triggers
  `loadView`), `vc.apply(desiredAlertsPopover(in: model))`,
  `window.layoutIfNeeded()`. `defer { fx.window.close() }` per test.
- **Projection source: always `desiredAlertsPopover(in:)`**
  (`Projections.swift:134`). Every projection field is reachable from settable
  model state (`alerts`, `showAllAlerts`), so hand-built projections add no
  coverage and would drift from the real tab/filter/markAll rules. This also
  makes the apply-twice test exercise the exact payload the d797b50 reconcile
  path delivers.
- Subview access (controls are `private`): table by recursive type traversal
  (copy `findTabTodoTable`, `TabTodoPopoverViewTests.swift:479-485`); buttons
  by title -- "Mark All Read", "Show all" (copy `onlyButton(titled:in:)`,
  `:531-535`); empty label by matching `stringValue` against the expected
  emptyText.
- Row materialization: `view(atColumn: 0, row:, makeIfNecessary: true)` after
  layout (copy `materializeTabTodoRows`, `:471-477`).

### Row inspection strategy

`makeAlertRow` (`app/AlertsPopoverView.swift:143-217`) builds a flat unlabeled
`NSView`; subviews are added in fixed order: icon (`NSImageView`), then three
`NSTextField`s (title, body, time), unread dot (plain `NSView`), separator
(`NSBox`).

- Text fields: `row.subviews.compactMap { $0 as? NSTextField }` yields
  `[title, body, time]` deterministically (flat view; subview order ==
  addSubview order). Assert by index with a comment naming the order. Beats
  font-matching (brittle to styling tweaks) and avoids adding identifiers to
  production views.
- Unread dot: the unique subview whose dynamic type is exactly `NSView`
  (`type(of: $0) == NSView.self`); assert `isHidden == !isUnread`.
- Do not assert icon symbol names or tooltips (ties tests to SF Symbol strings
  for no behavioral value).

### Test cases (~8, all expected green on first run)

Rendering / projection:

1. **apply renders rows in order with title/body/time text and per-row unread
   dots.** Three alerts: unread at age 90s, read at age 7350s (2h2m), unread
   at age 26h -- and `showAll: true`, required for the read middle alert to
   render at all: with `showAllAlerts == false`, `desiredAlertsPopover`
   filters to unread (`Projections.swift:135`) and the row count would be 2.
   Assert row count 3, ordered [title, body] text, time labels
   ["1m", "2h", "1d"], dot hidden only on the read row. relativeTime
   (`AlertsPopoverView.swift:227-236`) reads ambient `Date`, but mid-bucket
   offsets make this flake-free -- millisecond test drift cannot cross a
   bucket boundary. Never assert the "now"/60s boundary.
2. **Empty states show tab-specific text and toggle table/markAll
   visibility.** (a) `alerts: [one read], showAll: false` -> emptyLabel
   visible with "No unread alerts", scrollView hidden, markAllButton hidden
   (no unread anywhere); (b) `alerts: [], showAll: true` -> "No alerts";
   (c) `alerts: [one unread]` -> scrollView visible, emptyLabel hidden,
   markAll visible. Covers zero/one; test 1 covers many.

Click / message routing (assert `runtime.sentMessages`):

3. **Clicking the middle of three rows sends `.activateAlert` with that row's
   id.** Three **unread** alerts (so all three survive the default unread
   filter and row index == alerts index).
   `table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)`
   fires the delegate synchronously despite `selectionHighlightStyle = .none`
   (`AlertsPopoverView.swift:57`). Expect exactly one message carrying
   `alerts[1].id`.
4. **Row deselects after activate; the same row is clickable twice.** After
   test 3's click, `table.selectedRow == -1` (the `deselectRow` at `:140`;
   its re-entrant delegate callback lands with `selectedRow == -1` and is
   eaten by the `row >= 0` guard at `:138`); select row 1 again -> exactly two
   `.activateAlert` messages total. Pins both the reclick affordance and the
   re-entrancy guard.
5. **Stale-pane row still sends `.activateAlert(alertId:)`.** One **unread**
   alert (visible under the default unread filter) whose `paneId` is a fresh
   `PaneId()` in no group. Click it -> `.activateAlert`
   with the alert's id. Preamble must state: resolution (mark read + dismiss,
   no navigation) is core's job, pinned in `UpdateAlertTests.swift`; the
   view's contract is only "always send the typed id".

Controls:

6. **Checkbox syncs from projection and toggling dispatches.** Fixture with
   `showAll: true` -> `state == .on`; `performClick(nil)` -> state `.off` and
   exactly one `.setShowAllAlerts(false)`. (The handler reads
   `checkbox.state` directly, `:219-221`; one dispatch direction suffices --
   the on-direction sync is covered by test 7's resync.)
7. **apply-twice re-renders (the d797b50 reconcile path).** Start
   `[one unread]`, `showAll: false`; build a second model (3 alerts, all
   read, `showAllAlerts = true`) and `vc.apply(desiredAlertsPopover(in:))` ->
   row count 3, checkbox `.on`, markAllButton hidden, and no messages sent
   (render is dispatch-free).
8. **"Mark All Read" sends `.markAllAlertsRead`.** `performClick(nil)` on the
   button found by title -> exactly one message.

Trimmed as low-value: icon symbol/tooltip per `AlertKind`; relativeTime bucket
boundaries; checkbox both-directions dispatch.

## Phase 3 -- Only what the tests force

Expected: empty. Plausible failures and rule-bound responses:

- **Tests 3-5: programmatic selection doesn't fire the delegate** on some
  macOS version. Test-side fix only: select, then invoke
  `vc.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))`
  directly (delegate methods are internal). No production change.
- **Test 1: subview-order assumption breaks.** Switch the helper to font-based
  identification.
- **Rendering tests: rows not materialized** in the bare window. Fix the
  fixture (the wrapper is a fixed 320x400, `AlertsPopoverView.swift:19-25`;
  add `layoutSubtreeIfNeeded` in the materialize helper as TabTodo does).

If a production (`app/`, `lib/`) change ever seems needed, stop and re-plan --
the view is in production use and this task is test-only.

## Files touched

- `test-ui.sh` -- Phase 1: one line ending the app-file group; Phase 2: one
  line ending the tests-ui group
- `tests-ui/SidebarViewTestShim.swift` -- comment-only header generalization (1b)
- `tests-ui/PaneSplitViewTests.swift` -- one line in `main()` after `:20`
- `tests-ui/AlertsPopoverViewTests.swift` -- new (Phase 2)

No shim code changes. No production changes.

## Out of scope (deliberate)

- NSPopover lifecycle: `toggleAlertsPopover` (`app/AppRuntime.swift:~1395`),
  popover delegate, and `reconcileAlertsPopover`'s isShown gating
  (`app/Reconcile.swift:373-382`) -- runtime wiring; the apply-twice test
  pins the payload path it drives.
- `.activateAlert` resolution semantics (mark-read, navigation, stale
  dismiss, alertClearMode) -- core-tested in `UpdateAlertTests.swift`.
- Icon symbol names / tooltips per `AlertKind`; relativeTime bucket
  boundaries.

## Risks / gotchas

- **All-or-nothing compile** (`test-ui.sh:18-61`): a typo in the new test
  file takes down every suite. Mitigated by the Phase 1 gate (app file
  compile-verified before tests exist) and by re-running `just test-ui` right
  after creating the test-file skeleton, before writing test bodies.
- **`selectionHighlightStyle = .none`** (`AlertsPopoverView.swift:57`):
  visually unselectable, but programmatic `selectRowIndexes` still selects
  and fires the delegate. Phase 3 has the fallback if not.
- **Ambient Date in `relativeTime`**: mid-bucket `createdAt` offsets only
  (90s / 7350s / 26h); never assert near a bucket edge.
- **`weak var runtime`** (`AlertsPopoverView.swift:8`): the fixture must hold
  the strong reference or every dispatch silently no-ops and message
  assertions fail confusingly. The fixture struct holds it (same as TabTodo).

## Verification

1. After Phase 1: `just test-ui` -- compiles with the new app file, existing
   suites green, same `N/N passed`. Phase gate.
2. After Phase 2: `just test-ui` -- the AlertsPopover suite runs green
   alongside existing suites, exit 0.
3. `just test` -- stays green (no core/protocol/app changes); run once to
   confirm.
4. Negative check (TDD honesty for characterization tests): in test 3,
   temporarily assert the wrong alert id and confirm the failure names the id
   mismatch; restore. Optionally repeat for test 6 with the inverted bool.

## Implementation notes

- The current harness already had `ThemeBrowserViewTests.swift` after the
  TodoPopover test file, so `AlertsPopoverViewTests.swift` was added at the
  current end of the `test-ui.sh` test-file group while the runner call was
  still appended after the actual last suite call.
- `makeAlertsFixture` accepts an optional `livePaneId` so ordinary tests can
  make alerts point at the fixture's live pane while the stale-pane test can
  keep the alert pane id outside the model.
