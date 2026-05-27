# Plan: Reconcile the open alerts popover

## Context

The alerts popover (`app/AlertsPopoverView.swift`, `AlertsPopoverViewController`)
only reloads its table in `viewWillAppear` (line 109) and in its own control
handlers `showAllToggled` / `markAllRead` (lines 230, 235). While the popover
stays open, `model.alerts` is mutated by many `send()`-driven paths that never
touch the popover, so its contents go stale:

- Background bell arrival inserts an alert (`app/Update.swift:783`) with zero
  user interaction.
- OSC 777 desktop notification inserts an alert (`app/Update.swift:813`).
- Focus-clear read-marking flips `isUnread` when `alertClearMode == .focus`
  (`markAlertsReadForPane` at `app/Update.swift:239/416/519/...`).
- `clearAlertsForTabs` from menu/sidebar/IPC (`app/Update.swift:461`).

The popover is `.transient` (`app/AppRuntime.swift:1382`), but background alerts
and IPC-driven focus changes do not dismiss it. Result: stale unread dots,
missing new rows, and a wrong "Mark All Read" button state
(`app/AlertsPopoverView.swift:128`).

Outcome: the open popover updates live on every alert change, via the same
reconciler the rest of the UI already uses.

## Root cause (verified)

The app reconciles derived UI from the model after every `send()`:
`AppRuntime.send` -> `update(&model, msg)` -> `reconcile()`
(`app/AppRuntime.swift:228-247`, `app/Reconcile.swift:73`). The current pass
order is surface existence -> pane config -> containers -> focus/chrome ->
mount-time focus -> sidebar/window chrome -> switcher -> quit confirmation ->
preferences -> occlusion (`app/Reconcile.swift:73-88`). The alert paths above do
not opt into reconcile coalescing (`coalescesReconcile` is `true` only for
`.surfaceTitle/.surfaceCwd/.surfaceProgress`, `app/Msg.swift:192-199`), so each
runs `reconcile()` synchronously. The only reason the popover goes stale is that
`reconcile()` has no pass that touches it. Adding one fixes every path at once,
with no per-call-site changes.

Alerts are not the same shape as the current preferences panel:
`reconcilePreferencesPanel()` is model-owned via `model.preferencesDraft` and
`desiredPreferencesPanel(in:)` (`app/Reconcile.swift:332-352`,
`app/ModelOperations.swift:43-81`). The alerts popover remains an AppKit-owned
popover handle (`alertsPopover`) with model-owned contents. The new pass should
therefore render into the popover only when that AppKit handle is shown, while
the rows/buttons/empty text are still a pure projection of `AppModel`.

## Approach

Add a `reconcileAlertsPopover` pass that follows the current reconciler template:
a pure Equatable projection, a single-optional cache, and a thin executor that
gates on whether the AppKit popover handle is shown before pushing the projection
via `apply(_:)`. Slot it into the current `reconcile()` tail after
`reconcilePreferencesPanel()` and before `syncSurfaceVisibility()`. Refactor the
VC to render purely from the pushed projection (like `PreferencesPanel.apply` and
`SwitcherPanel.apply`, which never read `runtime.model`).

### 1. Pure projection -- `app/ModelOperations.swift` (after `alertsEmptyText`, ~line 997)

Non-optional, because "open" is AppKit state, not model state, so the projection
is always computable and the open/closed gate lives in the executor. This differs
from the current preferences panel, whose optional projection is model-owned via
`model.preferencesDraft`. Reuse the existing pure helpers `AlertTab` (line 983),
`filteredAlerts` (985), and `alertsEmptyText` (992).

```swift
// One alert row as a value -- the fields makeAlertRow reads today
// (AlertsPopoverView.swift:154-228). id is load-bearing: it is the click target
// for .activateAlert, so render and click must share this same list.
struct AlertRowProjection: Equatable {
    let id: AlertId
    let kind: AlertKind        // icon name + tooltip
    let title: String
    let body: String
    let createdAt: Date        // relativeTime() formats this at render
    let isUnread: Bool         // unread dot
}

struct AlertsPopoverProjection: Equatable {
    let rows: [AlertRowProjection]   // already filtered by tab
    let showAll: Bool                // checkbox state
    let markAllVisible: Bool         // "Mark All Read" visibility
    let emptyText: String?           // nil => show table; non-nil => show empty label
}

func desiredAlertsPopover(in model: AppModel) -> AlertsPopoverProjection {
    let tab: AlertTab = model.showAllAlerts ? .history : .unread
    let displayed = filteredAlerts(model.alerts, tab: tab)
    return AlertsPopoverProjection(
        rows: displayed.map { AlertRowProjection(id: $0.id, kind: $0.kind,
            title: $0.title, body: $0.body, createdAt: $0.createdAt, isUnread: $0.isUnread) },
        showAll: model.showAllAlerts,
        // preserves line 128's existing full-alerts predicate (NOT the filtered
        // list): in show-all view the button must still hide once nothing is unread.
        // 128 was never a logic bug -- it just was not re-run on background changes
        // (staleness), which the live reconcile now fixes.
        markAllVisible: model.alerts.contains(where: \.isUnread),
        emptyText: displayed.isEmpty ? alertsEmptyText(tab: tab) : nil
    )
}
```

A dedicated `AlertRowProjection` (rather than reusing the already-Equatable
`AlertModel`) matches the `SwitcherRow` precedent (`app/ModelOperations.swift`
~2039) and makes "the VC renders only from the projection" explicit. Keep
`createdAt` as a `Date` (format in the view) -- see Out of scope.

### 2. Reconcile cache + pass -- `app/Reconcile.swift`

Add the cache field beside `preferencesPanel` / `switcher` in `ReconcilerCaches`
(~line 54). It resets for free via `tearDownCurrentSession` re-init.

```swift
// Single-value alerts-popover cache: the last projection apply()'d into the open
// AlertsPopoverViewController. The load-bearing gate is the executor's isShown
// check (never applies while closed), NOT this cache's nil-ness -- the two
// reconcile-less close paths (toggleAlertsPopover self-close; delegate
// popoverDidClose) leave a stale non-nil value here until the next reconcile
// clears it. toggleAlertsPopover may apply the first projection directly for
// first-show rendering, but does not seed this cache; the first
// reconcileAlertsPopover pass owns and updates the cached value.
var alertsPopover: AlertsPopoverProjection? = nil
```

Add the executor in the `extension AppRuntime` (beside `reconcilePreferencesPanel`)
and call it in `reconcile()` right after `reconcilePreferencesPanel` and before
`syncSurfaceVisibility` (`app/Reconcile.swift:87-88`). Order is independent of
the other passes (no shared host), but keeping it in the late AppKit projection
cluster matches the current pass shape.

```swift
func reconcileAlertsPopover() {
    let shown = alertsPopover?.isShown ?? false
    let new: AlertsPopoverProjection? = shown ? desiredAlertsPopover(in: model) : nil
    guard caches.alertsPopover != new else { return }
    if let proj = new,
       let vc = alertsPopover?.contentViewController as? AlertsPopoverViewController {
        vc.apply(proj)
    }
    caches.alertsPopover = new
}
```

Gating on `isShown` (not just `!= nil`) keeps the gate honest during the window
between a click-away close and `popoverDidClose` firing. On close (click-away ->
adapter nils `alertsPopover`; or `.dismissAlertsPopover`, which runs in the
pre-reconcile command phase, `app/AppRuntime.swift:236`), `new` becomes nil and
the cache clears.

### 3. Render-from-projection VC -- `app/AlertsPopoverView.swift`

Make the VC a pure renderer of pushed state. This also fixes a latent click
correctness bug: `tableViewSelectionDidChange` (line 146) currently reads the
live model for the clicked row's alert id, which can mismatch what was drawn if
the model changed since render. Binding both render and click to
`projection.rows` makes "what you see is what you click" structural.

- Add `private var projection = AlertsPopoverProjection(rows: [], showAll: false,
  markAllVisible: false, emptyText: "No unread alerts")` and a `func apply(_:)`
  that stores it and renders: set `showAllCheckbox.state`, the empty/scroll
  visibility from `emptyText`, `markAllButton.isHidden = !markAllVisible`, then
  `tableView.reloadData()`.
- Repoint `numberOfRows` (134), `viewFor` (140), and `tableViewSelectionDidChange`
  (146) at `projection.rows` instead of `displayedAlerts`. The click handler
  sends `.activateAlert(alertId: projection.rows[row].id)`.
- Change `makeAlertRow` (154) param type from `AlertModel` to `AlertRowProjection`
  (mechanical: it already reads only `kind/title/body/createdAt/isUnread`).
- Delete `alertTab` (16), `displayedAlerts` (20), `rebuildRows` (115), and the
  `viewWillAppear` override (109) -- `apply` subsumes them.
- In `showAllToggled` (230) and `markAllRead` (235), keep the `runtime?.send(...)`
  call but drop the trailing `rebuildRows()`: the `send` runs `reconcile` ->
  `reconcileAlertsPopover` -> `apply`, same as `PreferencesPanel`'s action
  handlers.

### 4. First-show apply + delegate -- `app/AppRuntime.swift`

`toggleAlertsPopover` (1371) shows imperatively without `send()`, so `reconcile()`
will not run on open. Push the initial projection before `show()` (no empty
flash), but do not seed `caches.alertsPopover` here. The read-only reconciler ADR
prefers model events/generation values over imperative cache pokes when external
state changes what a pass should apply (`docs/design/2026-05-27-read-only-reconciler.md:87-90`);
this cache write would only skip the first post-open diff, so let
`reconcileAlertsPopover()` own the cache update. The first post-open `send()` may
therefore re-apply an identical projection once, which is harmless and keeps the
cache write inside the reconcile pass.

Also add an `NSPopoverDelegate` so a click-away `.transient` close nils the
reference (today it lingers non-nil with `isShown == false`). The delegate is
cleanup for eager dealloc and a tidy reopen, not required for correctness: the
executor's `isShown` gate already prevents applying to a closed popover, and
`toggleAlertsPopover` already guards reopen with its own `isShown` check.

`apply` calls `reloadData()`, which is meaningless until `loadView` has installed
the table column, set `dataSource`/`delegate`, and wired `scrollView.documentView`
(`AlertsPopoverView.swift:24-73`). Those run lazily on first `view` access. Since
`viewWillAppear` is being removed and opening the popover does not run
`reconcile()`, a pre-`loadView` `apply` would leave the popover blank until a
later model change. So force the load first with `loadViewIfNeeded()`.

```swift
let vc = AlertsPopoverViewController()
vc.runtime = self
vc.loadViewIfNeeded()          // ensure loadView wired the table/dataSource/scrollView
let proj = desiredAlertsPopover(in: model)
vc.apply(proj)                 // render before show (table is now wired)
let popover = NSPopover()
popover.contentViewController = vc
popover.behavior = .transient
popover.delegate = alertsPopoverDelegate
popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
alertsPopover = popover
```

```swift
// Beside TodoPopoverDelegateAdapter (~line 1391). No Msg needed: the alerts
// popover has no model state, so just nil the AppKit reference on close. Needs an
// explicit init -- Swift does not synthesize memberwise inits for classes (the
// TODO adapter at AppRuntime.swift:1391 follows the same pattern).
private final class AlertsPopoverDelegateAdapter: NSObject, NSPopoverDelegate {
    weak var runtime: AppRuntime?
    init(runtime: AppRuntime?) { self.runtime = runtime }
    func popoverDidClose(_ notification: Notification) { runtime?.alertsPopover = nil }
}
// On AppRuntime: private lazy var alertsPopoverDelegate = AlertsPopoverDelegateAdapter(runtime: self)
```

## Tests (TDD -- write first, expect red, then green)

All meaningful tests target the pure `desiredAlertsPopover`; the executor / VC /
first-show / delegate wiring is manual-QA, matching how `reconcileSwitcher` and
`reconcilePreferencesPanel` are covered (`app/Reconcile.swift:1-13`). Add a
`// MARK: - desiredAlertsPopover` block to `tests/ModelOperationsTests.swift`,
mirroring the `desiredSwitcher` test (~line 907): build with `makeModel()`, seed
`model.alerts` with `AlertModel(...)` literals, call the projection, assert on the
Equatable result with `expect` / `expectEqual` (`tests/TestHarness.swift`).

1. **Filtering**: unread tab shows only unread; flipping `showAllAlerts` shows all;
   `proj.showAll` carries the flag.
2. **markAllVisible**: true with an unread alert; false after the last unread is
   marked read -- including the show-all case where rows remain but
   `markAllVisible == false`. Guards that the projection uses the full (not
   filtered) alerts -- matching line 128's existing predicate -- against a future
   naive refactor.
3. **emptyText**: `"No unread alerts"` (unread tab, empty), `"No alerts"`
   (show-all, empty), `nil` when rows are present.
4. **Regression proof**: capture `proj0`, insert a background unread alert (as
   `surfaceBell` does), capture `proj1`; assert `proj0 != proj1`,
   `proj1.rows.first?.id` is the new alert, `proj1.markAllVisible == true`. This
   is what guarantees the `guard caches != new` diff fires and re-applies.

## Out of scope / known limitations

- **Relative-timestamp staleness** ("now" -> "1m"): `relativeTime`
  (`AlertsPopoverView.swift:240`) is computed from `createdAt` at render. A
  value-diffed projection only re-applies on model change, so a popover left open
  will not tick. Fixing it needs a periodic refresh timer -- deliberately not
  done here. (Putting the formatted string in the projection would be wrong: it
  would make the projection non-deterministic and defeat the diff.)
- **Scroll position on reload**: `apply` calls `reloadData()`, which can reset
  scroll to top if a background alert arrives while scrolled into history. This
  matches today's `rebuildRows` behavior and is acceptable for a transient,
  100-capped list. The per-row `Equatable` rows leave a future row-op diff
  upgrade mechanical if it ever matters.
- **TODO / Tab-TODO popovers** (`TodoPopoverView`, `TabTodoPopoverView`) share the
  same root cause and are likewise absent from `reconcile()`. They are a separate,
  riskier follow-up: they carry in-flight edit/selection/reorder state (they
  already use `rebuildRows(preservingSelectedId:)`), so a projection push must
  preserve it. Not in this change.

## Verification

- `just test` -- the four `desiredAlertsPopover` tests pass (after they first fail
  to compile/assert without the projection).
- `just build` -- compiles.
- Manual QA (`just build-run`):
  - First-show: with alerts already present (ring a bell, then do nothing),
    open the popover -> the existing rows render immediately, before any `send()`.
    (Guards the `loadViewIfNeeded` ordering: a blank popover here means `apply`
    ran before the table was wired.)
  - Open popover, ring a bell in a background pane -> new row + dot appear live;
    "Mark All Read" appears.
  - With one unread, click "Mark All Read" -> list empties to "No unread alerts",
    button hides, no flicker.
  - Toggle "Show all" -> read alerts appear; button still hides if nothing unread.
  - With `alertClearMode == .focus`, change focus via IPC/menu -> the focused
    pane's dot clears live.
  - Click a row right after a background bell arrives -> the correct alert
    activates (WYSIWYG click).
  - Click away to dismiss, reopen -> contents correct, no stale rows.

## Critical files

- `app/ModelOperations.swift` -- `AlertRowProjection`, `AlertsPopoverProjection`,
  `desiredAlertsPopover` (reuses `AlertTab` / `filteredAlerts` / `alertsEmptyText`).
- `app/Reconcile.swift` -- `ReconcilerCaches.alertsPopover` + `reconcileAlertsPopover`
  + `reconcile()` wiring.
- `app/AlertsPopoverView.swift` -- render-from-projection refactor.
- `app/AppRuntime.swift` -- `toggleAlertsPopover` initial apply + `AlertsPopoverDelegateAdapter`.
- `tests/ModelOperationsTests.swift` -- failing-first `desiredAlertsPopover` tests.

## Follow Up

- Add projection-driven reconcile paths for `TodoPopoverView` and `TabTodoPopoverView` that preserve edit, selection, and reorder state while open (`app/TodoPopoverView.swift`, `app/TabTodoPopoverView.swift`, `app/Reconcile.swift`).
