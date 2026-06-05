# Right-click pane toolbar to open the pane menu

## Context

Every pane toolbar has an always-visible `...` button (`ellipsis.circle`) that
opens a pane menu (Split Right / Split Down / Copy cwd / Zoom / Close Pane). The
button keeps the actions discoverable, but for a power user, hunting for a 16pt
button is slower than a right-click. We want right-clicking anywhere on the pane
toolbar to open that same menu, so the button stays as the discoverable affordance
while right-click becomes the fast path.

This should reuse the exact same menu (same items, same dynamic enable/title
state) and must not interfere with the existing left-drag-to-split behavior the
toolbar already supports.

## Approach

Use AppKit's built-in contextual-menu seam: override `menu(for event:)` on the
view the user actually right-clicks. AppKit's default `rightMouseDown` (and
control+left-click) calls `menu(for:)` and pops up the returned menu at the click
location -- no manual `rightMouseDown`/`popUp` plumbing. This matches the existing
right-click menus in `TerminalView.swift:285` and `SidebarView.swift:54`.

The view that fills the toolbar is `ToolbarDragHandleView` (`PaneWrapperView.swift:405`),
constrained to the full bar (`PaneWrapperView.swift:207-211`), layered above the
label/badge but below the buttons. It overrides only the *left* mouse path
(`mouseDown`/`mouseDragged`/`mouseUp`) for drag-to-split, so the right-click path
is untouched and the two cannot collide.

The pane menu is built dynamically (Copy-cwd enablement depends on the model's
cwd; the zoom item title flips on `isZoomed`), so it must be rebuilt by
`PaneWrapperView` on each open. Two steps:

1. Extract the menu construction out of `showPaneMenu()` into a reusable
   `makePaneMenu() -> NSMenu`. The `...` button keeps calling it + `popUp`.
2. Give `ToolbarDragHandleView` a callback the owner sets, and forward
   `menu(for:)` to it. Use a closure provider (not a `weak var paneWrapper`
   back-reference) to match the existing `PaneSplitView.onRatioChanged` idiom and
   keep the drag handle decoupled from `PaneWrapperView`'s concrete type (it
   already holds only `runtime`/`paneId`/`alertBadge`, never the wrapper).

## Changes

All in `app/PaneWrapperView.swift`.

### 1. Extract `makePaneMenu()` (refactor `showPaneMenu`, lines 333-368)

Move the body of `showPaneMenu()` (everything that builds `menu`) into a new
method, returning the menu instead of popping it up:

```swift
/// Builds the pane context menu fresh each call so dynamic item state
/// (copy-cwd enablement, zoom/unzoom title) reflects the current model.
/// Shared by the toolbar `...` button and the toolbar right-click menu.
func makePaneMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    // ... unchanged item-building from the current showPaneMenu body ...
    return menu
}

@objc private func showPaneMenu() {
    let menu = makePaneMenu()
    let point = NSPoint(x: 0, y: menuButton.bounds.height + 2)
    menu.popUp(positioning: nil, at: point, in: menuButton)
}
```

This is behavior-preserving for the button (pure extraction).

### 2. Add a menu provider + `menu(for:)` to `ToolbarDragHandleView` (class at line 405)

```swift
/// Supplies the pane context menu for right-click / control-click on the toolbar.
/// A closure (rather than a back-reference to the owning view) keeps this view
/// decoupled and matches the `onRatioChanged` callback idiom used elsewhere.
var paneMenuProvider: (() -> NSMenu?)?

// NSView: AppKit calls this on right-click / control-click and pops up the result.
override func menu(for event: NSEvent) -> NSMenu? {
    paneMenuProvider?()
}
```

### 3. Wire it where the drag handle is configured (near `PaneWrapperView.swift:171-173`)

Alongside the existing `dragHandle.runtime = ...` / `dragHandle.paneId = ...`:

```swift
dragHandle.paneMenuProvider = { [weak self] in self?.makePaneMenu() }
```

`[weak self]` is required: the superview chain retains the drag handle
(`PaneWrapperView` -> `toolbar` stored prop -> `dragHandle` subview), so a strong
capture of `self` here would form a retain cycle.

## Deliberate non-goals

- **Right-clicking the `...` / TODO / unzoom buttons themselves** won't open the
  menu -- those NSButtons sit above the drag handle and consume their own clicks.
  The empty bar + label + badge area (where users naturally aim) is covered. The
  `...` button still left-click-opens the same menu, so there is no lost
  functionality. Not worth the staleness of a static `menuButton.menu`.
- **Control+left-click** will also open the menu (free with `menu(for:)`). That is
  the standard macOS contextual-menu gesture and is desirable; no special-casing
  needed (unlike `TerminalView`, the drag handle has nothing to forward to
  Ghostty).

## Tests

No new automated test. Manual verification (below) is the proportionate gate,
consistent with how the codebase already treats `menu(for:)` plumbing --
`TerminalView.swift:285` and `SidebarView.swift:54` both override `menu(for:)`
with no automated test.

Why no UI-harness test (verified against the harness, not assumed):

- `test-ui.sh` deliberately does **not** compile the real `PaneWrapperView.swift`
  (it imports `GhosttyKit`). `tests-ui/SidebarViewTestShim.swift` stubs
  `AppRuntime`, `TerminalView`, `PaneWrapperView`, and `paneDragType` instead.
- A harness test of `ToolbarDragHandleView.menu(for:)` could only assert the new
  *forwarding* one-liner (`menu(for:) -> paneMenuProvider?()`). The part that can
  actually regress -- the `dragHandle.paneMenuProvider = { [weak self] in
  self?.makePaneMenu() }` wiring and its weak capture -- lives in
  `PaneWrapperView`, which the harness can't compile. So no harness test can ever
  guard the valuable half; it would pin the trivial half only.
- Compiling the production `ToolbarDragHandleView` into the harness would also
  require mirroring `AppRuntime`'s drag API in the stub -- the class calls
  `startPaneDrag`/`updatePaneDrag`/`endPaneDrag`/`currentPaneDrop`
  (`AppRuntime.swift:981-1020`), none of which exist on the shim. That is
  structure-sensitive scaffolding the project's test rubric discourages, bought
  for a guard on a one-line override.

**No new core tests** either: the menu's resulting messages (`.splitPane`,
`.requestClosePane`, `.toggleZoomPane`) are already covered in
`lib/DanTermCore/Tests/DanTermCoreTests/UpdatePaneTests.swift`; this change adds
no new `Msg` and no model logic. `makePaneMenu()` is a behavior-preserving
extraction, still exercised by the existing `...` button.

Considered and rejected (the reviewer's proposed coverage path): extract
`ToolbarDragHandleView` + `paneDragType` into a Cocoa-only
`app/ToolbarDragHandleView.swift`, extend the shim `AppRuntime` with the four
no-op drag methods, drop the shim's now-duplicate `paneDragType`, and add both
files to `test-ui.sh`. Rejected because the resulting test guards only the
trivial forwarding line (the wiring stays un-compilable in the harness) while
adding stub surface that tracks the production drag API. If a regression guard is
wanted later, this is the path -- but it is not worth it for this change.

## Verification

1. `just build-run` (or `just build` then launch `DanTerm Dev.app`).
2. Open a tab; right-click on the pane toolbar's empty area / title label ->
   the pane menu appears at the cursor with the same items as the `...` button.
3. Confirm dynamic state matches the button: "Copy cwd" disabled when the pane
   has no cwd; "Zoom Pane" / "Unzoom Pane" title tracks the zoom state; "Copy
   cwd" enabled after `cd` into a directory.
4. Confirm each item works (Split Right/Down, Close Pane, Zoom) -- same actions
   as the button.
5. Regression: left-click-drag on the toolbar still initiates pane drag-to-split
   (drag a pane in a split layout); the `...` button still opens the menu;
   clicking the alert badge still clears alerts.
6. `just test-ui` still passes unchanged (this change adds no harness sources).
7. `just test` passes (no core/protocol surface changed).
