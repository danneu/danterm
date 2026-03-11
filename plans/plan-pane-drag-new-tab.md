# Native Sidebar Insert Markers For Pane Drags

## Context

DanTerm lets users drag panes onto sidebar tab rows to merge into existing tabs. The user wants to also support dropping *between* tab rows to create a new tab — with native macOS insertion markers. These markers only appear during a real `NSDraggingSession`, so we must convert pane drag from manual mouse tracking to AppKit's drag session system.

## Key Design Decisions

1. **Drive pane overlay from `draggingSession(_:movedTo:)`** on the NSDraggingSource, not by making the overlay a NSDraggingDestination. The coordinator continues to manage split/swap previews over the content area.

2. **Complete pane drops in `draggingSession(_:endedAt:operation:)`** — if the sidebar already accepted the drag, just tear down; otherwise complete the pane split/swap if one is active.

3. **When the dragged pane is the only pane in its source tab**, move the existing tab entity (preserving custom title/color/identity) instead of destroying + recreating it.

4. **Adjust insertion index** when the source tab is moved within the same group and its removal shifts the target position.

## Files to Modify

| File | Change |
|------|--------|
| `app/Msg.swift` | Add `movePaneToNewTab` message |
| `app/Update.swift` | Handle `movePaneToNewTab` (two paths: move tab vs create tab) |
| `app/PaneWrapperView.swift` | Convert `ToolbarDragHandleView` to `NSDraggingSource` |
| `app/PaneDragCoordinator.swift` | Remove sidebar hit-testing + event monitors |
| `app/SidebarView.swift` | Register `paneDragType`, handle in `validateDrop`/`acceptDrop`, remove old highlight code |
| `app/AppRuntime.swift` | Simplify drag lifecycle (remove `updatePaneDrag`/`completePaneDrag`) |
| `tests/UpdatePaneTests.swift` | Tests for `movePaneToNewTab` |

## Implementation Steps

### Step 1: New message + update handler + tests

**`app/Msg.swift`** — Add:
```swift
case movePaneToNewTab(paneId: PaneId, inGroupId: GroupId, atIndex: Int)
```

**`app/Update.swift`** — Two-path handler:

*Path A — Source tab has only this pane (move the tab entity):*
1. Find source tab, verify it has only one leaf pane
2. Remove source tab from its group, note its original index
3. Adjust target `atIndex` if source was in the same group and before the insertion point
4. Insert the existing tab into target group at adjusted index
5. Tab keeps its ID, custom title/color, all metadata preserved
6. Select the tab, emit rebuild + reload effects

*Path B — Source tab has other panes (create new tab):*
1. `removeLeaf(sourceTab.rootNode, paneId:)` to extract the pane
2. Update source tab's rootNode and focusedPaneId
3. Create new `TabModel(id: TabId(), focusedPaneId: paneId, rootNode: .leaf(paneId))`
4. Apply `deriveTabChrome(from:)` (`ModelOperations.swift:358`)
5. Adjust target index if source tab removal shifts position (shouldn't happen since source tab still exists, but handle edge)
6. Insert new tab into target group at `atIndex` (clamped)
7. `markAlertsReadForPane` (matching `movePaneToTab` line 256)
8. Select new tab, emit: defocus old panes, `.rebuildContentView`, `.reloadSidebar`, `selectionSyncEffects`, `.makeFirstResponder(paneId)`

Guard: if moving would leave app with zero tabs (single pane, single tab, no other tabs), return `[]`.

No `.createSurface`/`.destroySurface` — surface is reused.

**`tests/UpdatePaneTests.swift`** — Tests:
- Split tab → drag one pane to create new tab before/after
- Cross-group insertion
- Same-group insertion index adjustment when source tab is removed (Path A)
- Source tab with multiple panes stays alive with correct next focus (Path B)
- Source tab with one pane preserves tab metadata when moved (Path A)
- Selected tab + focused pane effects correct
- No surface destruction for moved panes
- Single-pane-single-tab guard (no-op)
- Chrome derivation for Path B

### Step 2: Convert ToolbarDragHandleView to NSDraggingSource

**`app/PaneWrapperView.swift`** — Define pasteboard type:
```swift
static let paneDragType = NSPasteboard.PasteboardType("com.danterm.pane")
```

Rewrite `ToolbarDragHandleView`:
- `mouseDown`: Store the event (needed for `beginDraggingSession`) and origin
- `mouseDragged`: After 5px threshold + eligibility guards (unchanged):
  1. Call `runtime.startPaneDrag(paneId:)` — installs overlay + coordinator
  2. Create `NSPasteboardItem` with pane ID string on `paneDragType`
  3. Create `NSDraggingItem(pasteboardWriter:)`, set `draggingFrame` to toolbar bounds
  4. Call `self.beginDraggingSession(with: [item], event: storedMouseDownEvent, source: self)`
  5. Set `isDragging = true`
- Remove `mouseUp` override (system handles after session starts)
- Conform to `NSDraggingSource`:
  - `draggingSession(_:sourceOperationMaskFor:)` → `.move` for `.withinApplication`
  - `draggingSession(_:movedTo:)` → convert screen point to window coords, call `runtime.updatePaneDrag(screenPoint:)` to drive coordinator overlay
  - `draggingSession(_:endedAt:operation:)`:
    - **First**, call `runtime.updatePaneDrag(screenPoint:)` with the final `screenPoint` so the coordinator reflects the exact release location (a fast release can outrun the last `movedTo`)
    - If `operation != []` (sidebar accepted) → just `runtime.endPaneDrag()`
    - If `operation == []` AND coordinator has valid pane drop → send `.movePane`, then `runtime.endPaneDrag()`
    - Otherwise → `runtime.endPaneDrag()` (cancelled)
- Set `session.animatesToStartingPositionsOnCancelOrFail = false` after `beginDraggingSession` returns (to prevent snap-back on pane drops)

### Step 3: Simplify PaneDragCoordinator

**`app/PaneDragCoordinator.swift`** — Remove:
- `sidebarTabFrameProvider`, `allSidebarTabIds`, `currentSidebarTabTarget`
- `onSidebarHighlight` callback
- All sidebar hit-testing in `updateDrag` (lines 82-102)
- `currentSidebarDrop()` method
- Escape key monitor and app resign monitor — tentatively remove (NSDraggingSession should handle both natively). Retain as implementation note: verify during manual testing that escape and app-deactivate fully tear down the overlay. If the session lifecycle doesn't cover a path, re-add the monitors.

Keep: pane frame provider, `updateDrag` (pane-only hit-testing + overlay), `overlayView`, `teardown`, `currentDrop()`.

Simplified init:
```swift
init(sourcePaneId: PaneId, contentView: NSView,
     paneFrameProvider: @escaping (PaneId) -> NSRect?, targetPaneIds: [PaneId])
```

### Step 4: Update SidebarView for pane drops

**`app/SidebarView.swift`** — Add pasteboard type:
```swift
private static let paneDragType = NSPasteboard.PasteboardType("com.danterm.pane")
```

Register in `setup()`:
```swift
outlineView.registerForDraggedTypes([...existing..., SidebarView.paneDragType])
```

**`validateDrop`** — Add pane type handling:

| Proposed drop | Action | Visual |
|---------------|--------|--------|
| Single-group: `item=nil, index>=0` | Accept `.move` | Insertion marker between root tabs |
| Multi-group: `item=group, index>=0` | Accept `.move` | Insertion marker between group's tabs |
| Multi-group: `item=group, index=DropOnItem` | `setDropItem(item, dropChildIndex: childCount)`, accept `.move` | Insertion marker at group end |
| `item=tab, index=DropOnItem` | Accept `.move` | Row highlight (move pane into tab) |
| Everything else | Return `[]` | Rejected |

**`acceptDrop`** — Read pane ID from `paneDragType`:
- `item=tab, index=DropOnItem` → `runtime.send(.movePaneToTab(paneId:targetTabId:))`
- Otherwise → resolve `groupId` from item/mode, `runtime.send(.movePaneToNewTab(paneId:inGroupId:atIndex:))`

**Remove old manual highlight code:**
- `dropHighlightedTabId` property
- `tabRowFrame(for:)` method (line 279)
- `highlightTabForDrop(_:)` method (line 287)
- Background color in `makeTabCell` (lines 818-821)

### Step 5: Simplify AppRuntime

**`app/AppRuntime.swift`**:
- `startPaneDrag(paneId:)`: Remove sidebar providers. Just create coordinator with pane frame provider + target pane IDs.
- `updatePaneDrag(screenPoint:)`: Convert screen point → window coords, call `coordinator.updateDrag(locationInWindow:)`. (Replaces old `updatePaneDrag(event:)`)
- **Remove** `completePaneDrag()` — pane drops handled in `endedAt`, sidebar drops handled by `acceptDrop`
- **Add** `endPaneDrag()` — tears down coordinator via `cancelPaneDrag()`
- `cancelPaneDrag()`: Keep, remove cursor management (system manages cursor during drag session)

## Verification

1. `just test` — all existing + new tests pass
2. `just build-run` — manual tests:
   - Split a pane, drag one pane between sidebar tabs → native blue insertion marker, new tab created at that position
   - Drag single-pane tab between others → tab moves (preserving title/color), insertion marker shows position
   - Drag pane onto existing sidebar tab → pane merges into that tab (existing behavior)
   - Drag pane onto another pane in content area → split/swap overlay works (existing behavior)
   - Press Escape during drag → cancelled cleanly, overlay removed
   - App deactivated during drag → cancelled cleanly, overlay removed (verify session handles this; if not, re-add resign monitor)
   - Single-pane single-tab → drag doesn't initiate
   - Multi-group mode → insertion markers within groups, drop on collapsed group appends
