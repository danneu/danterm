# Extract `presentTransientPopover` in AppRuntime

## Context

Three arms in `app/AppRuntime.swift` each present a `.transient` `NSPopover`
anchored to a chrome button, and each repeats the identical five-line
config-and-show block:

```swift
let popover = NSPopover()
popover.contentViewController = vc
popover.behavior = .transient
popover.delegate = <delegate>
popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
```

The arms:

- `showTodoPopover` -- `app/AppRuntime.swift:665-680`
- `showTodoPopoverForTab` -- `app/AppRuntime.swift:685-699`
- `toggleAlertsPopover` -- `app/AppRuntime.swift:1388-1405`

Everything around that block already differs per arm (VC type, anchor view,
fresh-vs-member delegate, the projection `guard ... else { return }`, the alerts
toggle-close branch, and which retained handles get assigned). Only the
construct + configure + show sequence is byte-identical.

This is a pure readability dedup -- no behavior changes, no correctness exposure.
The goal is one shared presenter; the lifetime-owning retained-handle
assignments stay at each call site so each arm keeps owning its own
`NSPopover` / delegate member lifetimes (which `dismiss*Pair()` /
`popoverDidClose` rely on).

## Scope boundary (do NOT fold these in)

The shortcut-help child popovers at `app/TodoPopoverView.swift:636-652` and
`app/TabTodoPopoverView.swift:924-940` use `behavior = .applicationDefined` and
**mutate the parent popover's behavior** to coordinate dismissal. They are a
different pattern, live in view files (not AppRuntime), and are out of scope.
The helper is named `presentTransientPopover` precisely to exclude them.

## The helper

Add one small `@MainActor` method to `AppRuntime`. It captures exactly the
shared block and returns the shown popover so the caller assigns it to the
correct retained handle:

```swift
/// Build, configure, and show a transient popover anchored to `anchor`, returning
/// it so the caller can store it in the retained handle that owns its lifetime.
/// Callers do their own pre-show VC setup (loadViewIfNeeded + apply) and keep the
/// retained-handle assignment, since each popover's handle/delegate lifetime differs.
private func presentTransientPopover(
    _ contentViewController: NSViewController,
    delegate: NSPopoverDelegate?,
    from anchor: NSView,
    preferredEdge: NSRectEdge = .minY
) -> NSPopover {
    let popover = NSPopover()
    popover.contentViewController = contentViewController
    popover.behavior = .transient
    popover.delegate = delegate
    popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: preferredEdge)
    return popover
}
```

**Placement:** put it next to the symmetric dismiss helpers
`dismissTodoPopoverPair()` / `dismissTabTodoPopoverPair()` at
`app/AppRuntime.swift:283-296`, so present/dismiss read together.

**What stays at the call site (do not move into the helper):** the dismiss of any
prior popover, the anchor lookup, VC construction, `vc.loadViewIfNeeded()`, the
projection `guard ... else { return }`, `vc.apply(...)`, and the retained-handle
assignment. `loadViewIfNeeded` + `apply` must still run before the helper call
(the helper shows immediately), and the projection guards must be able to early-
return before any popover is shown -- both reasons they can't live in the helper.

## Call-site rewrites

Each arm collapses its five-line block to a single assignment from the helper.
Ordering is preserved: the handle is still assigned after `show` returns, exactly
as today.

**`showTodoPopover` (665-680):**

```swift
case .showTodoPopover(let paneId):
    dismissTodoPopoverPair()
    guard let wrapper = findPaneWrapper(for: paneId) else { return }
    let vc = TodoPopoverViewController(paneId: paneId, runtime: self)
    let delegate = TodoPopoverDelegateAdapter(paneId: paneId, runtime: self)
    vc.loadViewIfNeeded()
    guard let projection = desiredPaneTodoPopover(paneId: paneId, in: model) else { return }
    vc.apply(projection)
    todoPopover = presentTransientPopover(vc, delegate: delegate, from: wrapper.todoButtonView)
    todoPopoverDelegate = delegate
```

**`showTodoPopoverForTab` (685-699):**

```swift
case .showTodoPopoverForTab(let tabId):
    dismissTabTodoPopoverPair()
    guard let anchor = chromeView?.tabTodoButton else { return }
    let vc = TabTodoPopoverViewController(tabId: tabId, runtime: self)
    let delegate = TabTodoPopoverDelegateAdapter(tabId: tabId, runtime: self)
    vc.loadViewIfNeeded()
    guard let projection = desiredTabTodoPopover(tabId: tabId, in: model) else { return }
    vc.apply(projection)
    tabTodoPopover = presentTransientPopover(vc, delegate: delegate, from: anchor)
    tabTodoPopoverDelegate = delegate
```

**`toggleAlertsPopover` (1388-1405):** keeps its toggle-close branch; the
delegate is the long-lived `alertsPopoverDelegate` member (`app/AppRuntime.swift:40`),
and there is no separate delegate handle to assign:

```swift
func toggleAlertsPopover() {
    if let popover = alertsPopover, popover.isShown {
        popover.performClose(nil)
        alertsPopover = nil
        return
    }
    guard let anchor = chromeView?.bellButton else { return }
    let vc = AlertsPopoverViewController()
    vc.runtime = self
    vc.loadViewIfNeeded()
    vc.apply(desiredAlertsPopover(in: model))
    alertsPopover = presentTransientPopover(vc, delegate: alertsPopoverDelegate, from: anchor)
}
```

## Why this is the right shape

- `delegate: NSPopoverDelegate?` unifies all three: arms 1-2 pass a freshly built
  adapter, arm 3 passes the lazy `alertsPopoverDelegate` member -- the helper is
  agnostic.
- `preferredEdge` defaults to `.minY` (identical in all three today) but stays a
  parameter so a future non-`.minY` caller doesn't have to fork the helper.
- The helper touches no `self` state, so it could be `static`; an instance method
  is fine and matches the call sites. Keep it `private`.

## Tests

None to add. The presentation arms have no direct test coverage today; the pure
core only tests that `update()` emits `.showTodoPopover` /
`.showTodoPopoverForTab` (`lib/DanTermCore/Tests/DanTermCoreTests/UpdateTodoTests.swift:323`,
`UpdateTabTodoTests.swift:384`), and those Commands are unchanged. This is a
behavior-preserving extraction, so the existing emission tests already pin the
upstream contract; a test asserting the helper's internal `NSPopover` config
would be structure-sensitive and is not warranted.

## Verification

1. `just build` -- compiles clean (the only real gate for a type-checked Swift
   extraction; a wrong signature or moved early-return fails here).
2. `just test` -- run the local gate; confirms the pure-core emission tests and
   core-purity lint still pass (no core files touched, so purity is unaffected).
3. `just build-run`, then manually exercise each popover to confirm
   present + click-away dismiss + re-open still work:
   - per-pane TODO button -> opens, click outside dismisses;
   - tab-level TODO button -> opens, dismisses;
   - bell/alerts button -> toggles open and closed (verifies the toggle-close
     branch and the lazy `alertsPopoverDelegate` path).
4. (optional) `just test-ui` -- the popover view harness
   (`TodoPopoverViewTests`, `TabTodoPopoverViewTests`, `AlertsPopoverViewTests`)
   still passes; it exercises the VCs the arms construct, so it catches any
   accidental change to VC setup order.
