# Pane Drag-to-Split and Center-Swap v1

## Context

DanTerm's split pane layout is currently static after creation — users can split
and close panes but cannot rearrange them. This feature adds drag-and-drop pane
rearrangement: drag a pane's toolbar onto another pane to split-insert or swap.

## Scope and Defaults

- Drag starts only from the pane toolbar, not terminal content.
- Limited to the selected tab. No cross-tab or cross-window moves.
- Zoomed tabs and single-pane tabs do not allow dragging.
- Edge zones: outer 25% of target pane → split-insert.
- Center zone: remaining interior → swap panes.
- Corners resolve to nearest edge (never center).
- Drop on source pane or outside any pane → no-op.
- No drag image, no animation. Overlay preview is the only visual feedback.
- No surface creation/destruction — existing surfaces are reused.

---

## Implementation Steps

### Step 1: Pure tree operations (ModelOperations.swift)

Add two functions after existing `removeLeaf` (~line 108):

**`swapLeaves`** — Replace two leaf IDs with each other throughout the tree.
Recursively walk; when a `.leaf(firstId)` is found, return `.leaf(secondId)` and
vice versa. Preserve all split IDs and ratios. Return nil if either ID is missing.

```swift
func swapLeaves(_ node: SplitNodeModel, _ a: PaneId, _ b: PaneId) -> SplitNodeModel?
```

**`moveLeaf`** — Remove source from tree, then split-insert it at target.

```swift
func moveLeaf(
    _ node: SplitNodeModel,
    source: PaneId,
    target: PaneId,
    direction: SplitNodeModel.Direction,
    insertFirst: Bool
) -> SplitNodeModel?
```

Implementation: two-step on immutable intermediates:
1. Call `removeLeaf(node, source)` → get tree with source removed.
2. On that new tree, find the `target` leaf and replace it with a new
   `.split(id: SplitId(), direction, first/second, ratio: 0.5)` containing
   both source and target as leaves, ordered by `insertFirst`.

This works because `removeLeaf` may collapse the source's parent split but
the target leaf is still identifiable by its PaneId. Use a helper like
`splitLeaf` but parameterized to place an existing pane (not a new one).

Add a private helper `insertAtLeaf` that replaces a target leaf with a split
containing both source and target:

```swift
private func insertAtLeaf(
    _ node: SplitNodeModel,
    at targetId: PaneId,
    inserting sourceId: PaneId,
    direction: SplitNodeModel.Direction,
    insertFirst: Bool
) -> SplitNodeModel?
```

### Step 2: Drop intent type (new in Model.swift or Msg.swift)

```swift
enum PaneDropIntent {
    case splitTop, splitBottom, splitLeft, splitRight, swap
}
```

Maps to tree operation parameters:
- `splitTop` → vertical, source first
- `splitBottom` → vertical, source second
- `splitLeft` → horizontal, source first
- `splitRight` → horizontal, source second
- `swap` → call `swapLeaves`

### Step 3: New message (Msg.swift)

```swift
case movePane(source: PaneId, target: PaneId, intent: PaneDropIntent)
```

### Step 4: Update handler (Update.swift)

Add a case in the main switch after `closePane` (~line 181):

```swift
case .movePane(let source, let target, let intent):
```

Guard checks (all return `[]`):
- `source == target`
- No selected tab
- Tab is zoomed

Apply transform:
- If `intent == .swap`: call `swapLeaves(tab.rootNode, source, target)`
- Else: map intent to `(direction, insertFirst)`, call
  `moveLeaf(tab.rootNode, source:, target:, direction:, insertFirst:)`

On success, update tab:
- `tab.rootNode = newRoot`
- `tab.focusedPaneId = source`
- `tab.isZoomed = false`

Return `[.rebuildContentView]`.

### Step 5: Zone resolution (new file or in PaneDragCoordinator.swift)

Pure geometry function, no AppKit dependency needed for the logic itself.
Returns nil for invalid inputs (zero-sized pane, cursor outside pane bounds).

```swift
func resolveDropZone(
    cursorInPane: NSPoint,  // cursor position relative to pane bounds
    paneSize: NSSize
) -> PaneDropIntent?
```

Logic:
- Return nil if `paneSize.width <= 0` or `paneSize.height <= 0`
- Return nil if cursor is outside `(0,0)-(width,height)`
- Compute fractional position: `fx = cursor.x / width`, `fy = cursor.y / height`
- Edge bands: 0.25 threshold
- If in a corner (both x and y in edge bands), pick the axis where the cursor
  is closer to the edge (compare `min(fx, 1-fx)` vs `min(fy, 1-fy)`).
  On exact ties, horizontal wins (splitLeft/splitRight).
- If in single edge band: return corresponding split intent
- Otherwise: return `.swap`

Callers treat a nil return as "no valid target" (same as cursor outside all panes).

### Step 6: Drag overlay view (new: PaneDragOverlayView.swift)

Simple NSView subclass:
- `var highlightRect: NSRect?` and `var intent: PaneDropIntent?`
- `draw(_:)`: fill `highlightRect` with semi-transparent color
  - Split intents: blue-ish tint (e.g. `NSColor.controlAccentColor.withAlphaComponent(0.25)`)
  - Swap intent: visually distinct (e.g. different color or dashed border)
- `hitTest(_:)` returns `nil` always — transparent to mouse events
- Public `update(rect:intent:)` and `clear()` methods that set state + `needsDisplay = true`

### Step 7: Drag coordinator (new: PaneDragCoordinator.swift)

Managed by AppRuntime (stored as `private var dragCoordinator: PaneDragCoordinator?`).
The coordinator is a dumb helper — it never mutates `AppRuntime.dragCoordinator`
directly. AppRuntime is the sole owner: every exit path (drop, escape, resign,
rebuild) goes through an AppRuntime method that calls coordinator teardown and
then sets `dragCoordinator = nil`.

```swift
class PaneDragCoordinator {
    let sourcePaneId: PaneId
    let overlayView: PaneDragOverlayView

    private(set) var currentTarget: PaneId?
    private(set) var currentIntent: PaneDropIntent?

    // Callback fired by escape key monitor or app-resign observer.
    // AppRuntime sets this to its own cancelPaneDrag() method.
    var onCancel: (() -> Void)?
}
```

Methods:
- `init(sourcePaneId:, contentView:, paneFrameProvider:)` — create overlay, add
  to content view on top of split container, install local event monitors
- `updateDrag(locationInWindow: NSPoint)` — hit-test pane frames, compute zone,
  update overlay
- `teardown()` — remove overlay from superview, remove event monitors, clear state.
  Does NOT nil out AppRuntime's reference (that's the runtime's job).
- `currentDrop() -> (PaneId, PaneId, PaneDropIntent)?` — return current params
  if a valid target+intent exists, else nil

**Escape cancellation:** On `init`, install a local key-event monitor via
`NSEvent.addLocalMonitorForEvents(matching: .keyDown)`. If Escape is pressed,
call `onCancel?()` and return nil to swallow the event. Remove the monitor in
`teardown()`. This works regardless of which view is first responder.

**App-resign cancellation:** Also install a notification observer for
`NSApplication.didResignActiveNotification` in `init`, calling `onCancel?()`.
Remove in `teardown()`.

Both monitors are scoped to the coordinator's lifetime and cleaned up in
`teardown()`.

**Pane frame provider:** The coordinator takes a closure `(PaneId) -> NSRect?`
for looking up pane frames in window coordinates, rather than holding a weak
ref to the runtime. AppRuntime provides this closure at init time, iterating
`surfaces` and converting PaneWrapperView frames. Excludes source pane.

**AppRuntime ownership contract:**

```swift
// Every exit path follows this pattern:
func cancelPaneDrag() {
    dragCoordinator?.teardown()
    dragCoordinator = nil
}

func completePaneDrag() {
    guard let result = dragCoordinator?.currentDrop() else {
        cancelPaneDrag()
        return
    }
    cancelPaneDrag()  // teardown before dispatching msg
    send(.movePane(source: result.0, target: result.1, intent: result.2))
}
```

### Step 8: Toolbar drag initiation (PaneWrapperView.swift)

Add a dedicated drag-handle subview inside the toolbar that acts as the event
source. This avoids AppKit routing ambiguity — the drag handle is a concrete
NSView that owns mouse tracking, so clicks on the menu button and unzoom button
are never intercepted.

**Drag handle view:** A new `ToolbarDragHandleView` (NSView subclass) that fills
the toolbar area. Layering order in the toolbar (bottom to top):
1. `toolbarLabel` — set to non-hit-testing via `toolbarLabel.hitTestDisabled = true`
   (or wrap in a container that returns nil from `hitTest`)
2. `ToolbarDragHandleView` — fills toolbar bounds, receives mouse events
3. Buttons (menu, unzoom) — sit on top, receive clicks normally

The label must not intercept hits because it covers most of the toolbar area.
Making it non-hit-testing lets the drag handle underneath receive mouse events
while the label remains visually on top for text rendering.

```swift
class ToolbarDragHandleView: NSView {
    weak var runtime: AppRuntime?
    var paneId: PaneId?
    private var dragOrigin: NSPoint?
    private var isDragging = false
}
```

Override `mouseDown`, `mouseDragged`, `mouseUp`:

- `mouseDown`: record `dragOrigin = event.locationInWindow`. Do NOT call super
  (prevents the event from propagating to the toolbar or wrapper).
- `mouseDragged`: if not yet dragging, check distance from `dragOrigin` > 5pt.
  On threshold crossing, call `runtime?.startPaneDrag(paneId:)` and set
  `isDragging = true`. While dragging, call `runtime?.updatePaneDrag(event:)`.
- `mouseUp`: if dragging, call `runtime?.completePaneDrag()`. Reset state.

Guard: do not start if tab is zoomed or tab has only one pane (check via runtime).

The drag handle does NOT need to handle Escape — that is handled by the drag
coordinator (see Step 7).

### Step 9: Runtime integration (AppRuntime.swift)

Add property:
```swift
private var dragCoordinator: PaneDragCoordinator?
```

Add methods (all follow the ownership contract from Step 7):
- `startPaneDrag(paneId:)` — create coordinator with pane frame provider
  closure, set `coordinator.onCancel = { [weak self] in self?.cancelPaneDrag() }`
- `updatePaneDrag(event:)` — forward `event.locationInWindow` to coordinator
- `completePaneDrag()` — read `currentDrop()`, teardown + nil coordinator,
  dispatch `Msg.movePane` if result was valid
- `cancelPaneDrag()` — teardown + nil coordinator, no msg dispatch

In `rebuildContentView()`: call `cancelPaneDrag()` at the top if a drag is
active (the view hierarchy is being rebuilt, so the drag context is invalid).

### Step 10: Window/app deactivation cancel

The coordinator's `didResignActiveNotification` observer calls `onCancel?()`,
which routes to `AppRuntime.cancelPaneDrag()` (teardown + nil). This follows
the same ownership contract as every other exit path — the coordinator never
nils itself out of the runtime.

As a defensive backstop, also call `cancelPaneDrag()` in `AppRuntime.send(_:)`
when processing `.appResignedActive` effects, in case the notification observer
fires out of order.

---

## Files Modified

| File | Change |
|------|--------|
| `app/ModelOperations.swift` | Add `swapLeaves`, `moveLeaf`, `insertAtLeaf` |
| `app/Model.swift` or `app/Msg.swift` | Add `PaneDropIntent` enum |
| `app/Msg.swift` | Add `movePane` case |
| `app/Update.swift` | Add `movePane` handler |
| `app/PaneWrapperView.swift` | Add `ToolbarDragHandleView` as toolbar subview behind buttons |
| `app/AppRuntime.swift` | Add drag coordinator property + start/update/complete/cancel methods; cancel in `rebuildContentView` |
| `app/PaneDragOverlayView.swift` | **New file** — transparent overlay view |
| `app/PaneDragCoordinator.swift` | **New file** — transient drag state + zone resolution |
| `tests/ModelOperationsTests.swift` | Add `moveLeaf` and `swapLeaves` tests |
| `tests/UpdatePaneTests.swift` | Add `movePane` update tests |
| `tests/DropZoneTests.swift` | **New file** — zone resolution geometry tests |
| `tests/TestHarness.swift` | Wire `dropZoneTests()` into test runner |

---

## Existing Code to Reuse

- `removeLeaf()` in `ModelOperations.swift:78` — first step of moveLeaf
- `splitLeaf()` in `ModelOperations.swift:51` — pattern for insertAtLeaf
- `allPaneIds()` in `ModelOperations.swift:24` — validate pane presence
- `findPaneWrapper(for:in:)` in `AppRuntime.swift:249` — pane frame discovery
- `forEachPaneWrapper(in:_:)` in `AppRuntime.swift:260` — iterate all panes
- `rebuildContentView()` in `AppRuntime.swift:272` — where overlay cleanup goes
- Existing `splitPane` handler in `Update.swift:131` — pattern for movePane handler

---

## Test Plan

### Pure tree tests (ModelOperationsTests.swift)

Write these first (TDD):
- `moveLeaf` left/right/top/bottom in a 2-pane tree → correct new split
- `moveLeaf` from nested tree → old parent collapses, unaffected structure preserved
- `moveLeaf` creates fresh SplitId and ratio 0.5 at insertion point
- `moveLeaf` source == target → returns nil
- `moveLeaf` missing source or target → returns nil
- `swapLeaves` in nested tree → IDs swapped, all splits/ratios preserved
- `swapLeaves` with missing pane → returns nil

### Update tests (UpdatePaneTests.swift)

- `movePane` with split intent → updates rootNode, focuses source, clears zoom, emits `.rebuildContentView`
- `movePane` with swap intent → same
- `movePane` source == target → no-op (empty effects)
- `movePane` no selected tab → no-op
- `movePane` zoomed tab → no-op

### Zone resolution tests (new: tests/DropZoneTests.swift)

- Each edge band (top/bottom/left/right 25%) → correct split intent
- Center region → `.swap`
- Corner tie-breaks: cursor closer to top edge than left → `.splitTop`, etc.
- Corner tie-breaks: cursor equidistant → horizontal axis wins (splitLeft/splitRight)
- Cursor exactly on boundary between edge and center → edge wins (≤ 0.25)
- Zero-width pane → returns nil
- Zero-height pane → returns nil
- Cursor outside pane bounds → returns nil
- Normal-sized pane, cursor at exact center → `.swap`

### Manual acceptance

- Drag pane A onto B's top/bottom/left/right edges → verify layout
- Drag pane A onto B's center → verify swap
- Drag across panes → overlay follows cursor correctly
- Release outside panes → no change
- Press Escape during drag → no change
- Click menu/unzoom buttons → no drag starts
- File/URL drag-drop into terminal → still works after feature
- Zoomed tab → toolbar drag does not start

---

## Implementation Order

1. `PaneDropIntent` enum
2. `swapLeaves` + tests
3. `moveLeaf` (with `insertAtLeaf` helper) + tests
4. `Msg.movePane` + Update handler + tests
5. `resolveDropZone` function + tests (DropZoneTests.swift)
6. `PaneDragOverlayView` (new file)
7. `PaneDragCoordinator` (new file, uses `resolveDropZone`, owns escape/resign monitors)
8. `ToolbarDragHandleView` in PaneWrapperView.swift
9. `AppRuntime` integration (coordinator lifecycle, rebuild cancel, resign backstop)
10. Manual testing pass
