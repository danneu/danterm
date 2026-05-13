# Plan: Cross-bucket TODO moves in the Tab to-do popover

## Context

The Tab to-do popover (`app/TabTodoPopoverView.swift`) shows the active tab's
own to-dos at the top and a roll-up section per pane below. Today the user
cannot move an item between buckets:

1. **Symptom reported**: starting a drag on a pane to-do row inside the tab
   popover dismisses the popover.
   **Root cause**: `pasteboardWriterForRow` only returns a writer for
   `.tabItem` rows (TabTodoPopoverView.swift:616-621), so pane rows never
   start an `NSDraggingSession`. With no drag session, the mouseDown +
   mouse-move out of the popover is treated as a click outside, and
   `popover.behavior = .transient` (AppRuntime.swift:690) closes the popover.
2. **Secondary observation from the user**: pane sections are hidden when
   `pane.todos.isEmpty` (TabTodoPopoverView.swift:180-187), so empty panes
   cannot be drop targets.
3. **Missing model support**: there is no `Msg` for moving a to-do between
   buckets. Only `reorderTabTodo` and `reorderTodo` exist (Msg.swift:143, 155),
   both within-bucket only.
4. **Drop validation**: `validateDrop` only allows `.above` drops inside
   `tabItemRange()` (TabTodoPopoverView.swift:623-630).

Adds drag-and-drop AND a `Cmd-Shift-H/L` keybinding for moving a to-do
between any pair of buckets in `[tab, pane0, pane1, ...]` (pane order
follows the existing `allPaneIds` tree traversal in `ModelOperations.swift`).

## Decisions (locked via Q&A)

- Move methods: **both** drag-and-drop and keyboard.
- Directions: **all** of tab<->pane and pane<->pane.
- Empty pane sections: **always show the header**, no placeholder row.
- New Msg shape: **one unified** `moveTodo(from:, todoId:, to:, atIndex:)`,
  alongside the existing `reorderTabTodo` / `reorderTodo` (kept).
- Drop geometry: `.above` between items, `.on` a header to append.
- Pasteboard payload: single existing type `com.danneu.danterm.tab-todo-row`,
  JSON-encoded `{ source, todoId }`.
- Keybinding: **Cmd-Shift-H / Cmd-Shift-L**. Stops at the ends, no wrap.
- Landing spot via keybinding: **top (index 0)** of the destination section.
- Mid-edit move: **save edit first, then move**.
- Single-pane `TodoPopoverView`: **unchanged**.
- Single feature commit, Conventional Commits style.

## Critical files

- `app/Msg.swift` -- add `TodoSource`, `TodoDestination`, `case moveTodo(...)`.
- `app/Update.swift` -- add `moveTodo` branch.
- `app/AppRuntime.swift` -- post-update switch case for `.moveTodo`
  (badge + toolbar refreshes).
- `app/ModelOperations.swift` -- move the `TabTodoRow` / `TabTodoEditTarget`
  types out of `TabTodoPopoverView.swift` into here; add pure helpers
  `buildTabTodoRows`, `resolveTabTodoDropTarget`, `resolveTabTodoBucketStep`.
- `app/TabTodoPopoverView.swift` -- delegate row build + drop math +
  bucket-step math to the pure helpers; widen `pasteboardWriterForRow`,
  `validateDrop`, `acceptDrop`; add the Cmd-Shift-H/L key equivalent; fix
  the empty-state visibility math.
- `tests/UpdateTabTodoTests.swift` -- new tests appended inside
  `updateTabTodoTests()` (do NOT create a new test file; `TestHarness`
  manually registers each suite function, so a new file would silently
  not run).
- `tests/ModelOperationsTests.swift` -- one test for `buildTabTodoRows` plus
  tests for `resolveTabTodoDropTarget` and `resolveTabTodoBucketStep`.

## Implementation steps

### 1. Msg + Update

Add to `app/Msg.swift`:

```swift
enum TodoSource: Equatable {
    case tab(TabId)
    case pane(PaneId)
}
enum TodoDestination: Equatable {
    case tab(TabId)
    case pane(PaneId)
}
// in enum Msg:
case moveTodo(from: TodoSource, todoId: UUID, to: TodoDestination, atIndex: Int)
```

Add the Update branch in `app/Update.swift` (mirroring the
`return [.scheduleCheckpoint]` pattern used by every other todo-mutating
branch, e.g. `reorderTabTodo` at Update.swift:1279-1289):

- Preflight every endpoint before mutating the model:
  - Resolve the source bucket, source owning tab, source item, and source
    item index. `.tab(tabId)` requires `tabById(tabId, in: model)` and a
    matching `todoId`; `.pane(paneId)` requires `model.panes[paneId]`, a
    matching `todoId`, and `tabForPane(paneId, in: model)`.
  - Resolve the destination bucket, destination owning tab, and current
    destination count. `.tab(tabId)` requires `tabById(tabId, in: model)`;
    `.pane(paneId)` requires `model.panes[paneId]` and
    `tabForPane(paneId, in: model)`.
  - If any source/destination endpoint is missing, if the `todoId` is not in
    the source, if the source bucket equals the destination bucket, or if the
    source and destination owning tab ids differ, return `[]`.
- Only after that preflight succeeds, remove the captured item from the
  source bucket, clamp `atIndex` to `0...destinationCount`, insert the item
  into the destination bucket, and return `[.scheduleCheckpoint]`.
  This preserves atomic no-op behavior for stale destinations: a failed move
  never deletes the source item.
- Keep the only success effect as `[.scheduleCheckpoint]`. **Do not**
  invent a refresh effect --
  `Effect` has no `refreshTabTodoButton` case, and existing todo-mutating
  branches don't return one either; the chrome badge and pane toolbars are
  refreshed in `AppRuntime` post-update (next step).

### 2. AppRuntime post-update wiring

In `AppRuntime.swift` around line 234-264 (the existing switch that
mirrors todo-affecting Msgs to badge / toolbar refreshes), add a new case:

```swift
case .moveTodo(let from, _, let to, _):
    // Refresh toolbars for any pane endpoint of the move.
    if case .pane(let paneId) = from { refreshPaneToolbar(for: paneId) }
    if case .pane(let paneId) = to { refreshPaneToolbar(for: paneId) }
    // Refresh the chrome's tab-todo badge if the affected tab is selected.
    let movedTabId: TabId? = {
        switch (from, to) {
        case (.tab(let t), _), (_, .tab(let t)): return t
        case (.pane(let pid), _): return tabForPane(pid, in: model)?.id
        }
    }()
    if let t = movedTabId, t == model.selectedTabId { refreshTabTodoButton() }
```

Both source and destination always live in the same tab (the tab popover
only shows one tab), so a single `movedTabId` is sufficient.

### 3. Extract `TabTodoRow`, `TabTodoEditTarget`, and pure helpers to ModelOperations

Move `TabTodoRow` and `TabTodoEditTarget` from `app/TabTodoPopoverView.swift`
to `app/ModelOperations.swift` (they're pure data shapes; the view consumes
but doesn't own them once tests need them).

Add these pure functions in `app/ModelOperations.swift`:

```swift
enum TabTodoDropOperation: Equatable {
    case on
    case above
}

// Always emit a section header for every pane in the tab so empty panes
// are visible drop targets (the user-visible change vs the current
// buildRows in TabTodoPopoverView.swift:173-189, which skips empty panes).
func buildTabTodoRows(model: AppModel, tabId: TabId) -> [TabTodoRow]

// Resolves a table drop into a destination bucket and an insertion index
// local to that bucket. Keep this Cocoa-free so ModelOperations remains in
// the headless test target.
//
// Semantics (covers the one-past-end and header-`.on` cases that were
// brittle in earlier drafts):
//
//   .on row N:
//     - if rows[N] is .tabSectionHeader -> (.tab(tabId), tab.todos.count)
//     - if rows[N] is .paneSectionHeader -> (.pane(paneId), pane.todos.count)
//     - otherwise -> nil
//
//   .above row N where N < rows.count:
//     - rows[N] is .tabSectionHeader -> nil (ambiguous: above row 0)
//     - rows[N] is .paneSectionHeader -> previous section append:
//         the section that contains rows[N-1] gets insertion at its
//         current item count
//     - rows[N] is an item -> dest = that item's bucket; insertion
//         index = count of items in that bucket appearing in rows
//         strictly before index N. (This is the section-local index of
//         that item; correct for "insert above this item".)
//
//   .above row N where N == rows.count (one-past-end):
//     - dest = bucket of rows[rows.count - 1]
//     - insertion index = count of items in that bucket (append)
//
// Returns nil for anything else.
func resolveTabTodoDropTarget(
    rows: [TabTodoRow],
    model: AppModel,
    tabId: TabId,
    proposedRow: Int,
    dropOperation: TabTodoDropOperation
) -> (destination: TodoDestination, atIndex: Int)?

// Given the currently selected edit target and the tab's pane traversal
// order, returns the destination bucket one step in `delta` direction
// through [tab, pane0, pane1, ...]. Returns nil at the ends (no wrap).
func resolveTabTodoBucketStep(
    current: TabTodoEditTarget,
    paneOrder: [PaneId],
    tabId: TabId,
    delta: Int
) -> TodoDestination?
```

Do not import AppKit in `ModelOperations.swift`. Convert
`NSTableView.DropOperation` to `TabTodoDropOperation` only inside
`TabTodoPopoverView.swift`; any operation other than `.on` / `.above`
should validate as no drop.

In `TabTodoPopoverViewController.buildRows()`, replace the inline loop
with `buildTabTodoRows(model:, tabId:)`.

### 4. Empty-state visibility

In `TabTodoPopoverViewController.rebuildRows()` (TabTodoPopoverView.swift:310-341):

Replace `emptyLabel.isHidden = totalRows > 1` /
`scrollView.isHidden = totalRows <= 1` with logic based on real item
count, computed via a small helper added in ModelOperations:

```swift
func tabTodoItemCount(_ tabId: TabId, in model: AppModel) -> Int
```

(`tab.todos.count + sum of pane.todos.count for panes in tab`).

### 5. Pasteboard schema

Keep the type:

```swift
private let tabTodoRowDragType = NSPasteboard.PasteboardType("com.danneu.danterm.tab-todo-row")
```

New payload (file-private in `TabTodoPopoverView.swift`):

```swift
private struct TabTodoDragPayload: Codable {
    enum Source: Codable, Equatable {
        case tab
        case pane(UUID)
    }
    let source: Source
    let todoId: UUID
}
```

`pasteboardWriterForRow`:

- `.tabItem(let item)` -> `{ source: .tab, todoId: item.id }`.
- `.paneItem(let paneId, let item)` -> `{ source: .pane(paneId.rawValue), todoId: item.id }`.
- Headers -> `nil`.

Encode as UTF-8 JSON; `setString(_:forType: tabTodoRowDragType)`.

### 6. `validateDrop` and `acceptDrop`

`validateDrop` calls `resolveTabTodoDropTarget` (with the controller's
`TabTodoDropOperation` mirror); if it returns a target, `.move`,
otherwise `[]`.

`acceptDrop`:

- Decode the JSON payload to `(source, todoId)`.
- Compute `(destination, atIndex)` via `resolveTabTodoDropTarget`.
- Map `source` to a concrete `TodoSource`:
  - `.tab` -> `.tab(self.tabId)`
  - `.pane(uuid)` -> `.pane(PaneId(rawValue: uuid))`
- If source bucket equals destination bucket, dispatch the existing
  `reorderTabTodo` / `reorderTodo` to keep within-bucket logic
  unchanged. Otherwise dispatch `moveTodo`.
- `rebuildRows()`.

### 7. Keyboard: Cmd-Shift-H / Cmd-Shift-L

Routing fix: the existing `handleListKeyDown` only fires while the
*table* is first responder. During edit, `addInput.textView` is first
responder, so a keybinding that needs to work mid-edit (per decision
"save-and-move") must run from
`performTodoKeyEquivalent(with:)`, which fires regardless of first
responder (NSWindow `performKeyEquivalent` traversal).

In `performTodoKeyEquivalent`:

- Detect `h` / `l` (case-insensitive via `event.charactersIgnoringModifiers?.lowercased()`)
  with modifiers `[.command, .shift]`.
- Gate: only act when the table is first responder OR `isEditing == true`.
  (In compose mode -- input first responder, not editing -- the shortcut
  is inactive so it doesn't grab focus state by surprise.)
- If `isEditing`, call `saveEditThenReturnToList()` first; if it returns
  false (empty input), proceed with the move using the previously
  selected target.
- Determine `current: TabTodoEditTarget` via `selectedEditTarget()`.
  If nil, no-op.
- `paneOrder = allPaneIds(tab.rootNode)`.
- `dest = resolveTabTodoBucketStep(current:, paneOrder:, tabId:, delta:)`.
  If nil (at end of cycle), no-op (return true so AppKit doesn't beep
  pass-through).
- Construct `source` from `current`; dispatch
  `moveTodo(from: source, todoId: <selected>, to: dest, atIndex: 0)`.
- `rebuildRows()`; reselect the moved item via the new `TabTodoEditTarget`
  (`.tab(todoId)` or `.pane(destPaneId, todoId)`) using `selectTarget`;
  keep focus on the table.

### 8. Header click-to-focus stays as-is

No change to `shouldSelectRow` for `.paneSectionHeader`. `shouldSelectRow`
fires on mouseDown only. During a drag, `acceptDrop` fires on mouseUp
from an active `NSDraggingSession`, so a drag started on an item and
released on a header does *not* trigger focus-and-close.

## Tests (all inside existing test suite functions)

`tests/UpdateTabTodoTests.swift` -- append to `updateTabTodoTests()`:

1. `moveTodo pane -> tab inserts at index and removes from pane`
2. `moveTodo tab -> pane inserts at index and removes from tab`
3. `moveTodo pane -> pane removes from source pane and inserts into dest pane`
4. `moveTodo with atIndex > destination.count clamps to count (append)`
5. `moveTodo with atIndex < 0 clamps to 0`
6. `moveTodo where source == destination is a no-op (returns [])`
7. `moveTodo with unknown todoId is a no-op`
8. `moveTodo with missing destination pane is a no-op and leaves source intact`
9. `moveTodo across different tabs is a no-op and leaves source intact`
10. `moveTodo returns [.scheduleCheckpoint] on success`

`tests/ModelOperationsTests.swift` -- append to its existing suite function:

11. `buildTabTodoRows emits a header for every pane regardless of pane.todos.isEmpty`
12. `resolveTabTodoDropTarget .on tabSectionHeader -> (.tab, tab.todos.count)`
13. `resolveTabTodoDropTarget .on paneSectionHeader -> (.pane, pane.todos.count)`
14. `resolveTabTodoDropTarget .above first tabItem -> (.tab, 0)`
15. `resolveTabTodoDropTarget .above between two tabItems -> (.tab, that local index)`
16. `resolveTabTodoDropTarget .above paneSectionHeader -> append to previous section`
17. `resolveTabTodoDropTarget .above one-past-end -> append to last section`
18. `resolveTabTodoDropTarget .above tabSectionHeader (row 0) -> nil`
19. `resolveTabTodoBucketStep tab + delta=+1 -> pane0`
20. `resolveTabTodoBucketStep pane0 + delta=-1 -> tab`
21. `resolveTabTodoBucketStep tab + delta=-1 -> nil (stops at start)`
22. `resolveTabTodoBucketStep lastPane + delta=+1 -> nil (stops at end)`

Tests stay pure (no GhosttyKit, no Cocoa) and run under `just test`.

## Verification

1. `just test` -- new and existing tests green.
2. `just build` -- compiles.
3. `just build-run` -- launches the dev build.
4. Smoke test in the running app:
   - Open a tab with at least two panes; add a few pane to-dos and a
     tab to-do.
   - Open the tab to-do popover via Cmd+' or the chrome button.
   - **Drag pane to-do -> tab section** (drop above an existing tab item or
     onto the tab header). Popover stays open; item moves; chrome badge
     updates.
   - **Drag tab to-do -> pane section** (drop onto a pane header). Popover
     stays open; item lands in that pane; pane toolbar badge updates.
   - **Drag pane to-do -> different pane section**. Item moves; both pane
     toolbars update.
   - **Empty pane visible**: with a pane that has zero to-dos, confirm its
     header renders and that dropping `.on` it inserts the item there.
   - **One-past-end drop**: drag an item below the last item in a section;
     confirm it appends rather than no-oping or inserting before the last.
   - **Within-section reorder unchanged**: drag a tab item between two
     other tab items; existing `reorderTabTodo` path still works.
   - **Keyboard Cmd-Shift-L/H**: select an item, press Cmd-Shift-L to push
     it through `[tab, pane0, pane1, ...]`. Stops at the last bucket;
     Cmd-Shift-H walks it back; no wrap.
   - **Mid-edit move**: enter edit on an item, type a change, press
     Cmd-Shift-L. The edit saves first, then the item moves.
   - **Empty-state label**: with zero to-dos anywhere in the tab, "No
     tasks yet" still shows; with zero tab items but a pane that has
     items, the label stays hidden.

## Commit message

```
feat(todos): allow moving todos between tab and panes

- Add Msg.moveTodo(from:todoId:to:atIndex:) handled atomically in Update;
  AppRuntime refreshes the tab badge and any pane toolbars touched
- Tab to-do popover: pane items become drag sources, headers accept drops
  (.above between items, .on header to append), drop dispatches moveTodo
  across buckets or the existing reorder Msgs within a bucket
- Cmd-Shift-H/L moves the selected item to the previous/next bucket in
  [tab, pane0, pane1, ...], stops at the ends, saves any in-progress edit
  first (routed via performTodoKeyEquivalent so it works mid-edit)
- Always render a section header for every pane in the tab so empty panes
  are visible drop targets
- Extract TabTodoRow + row/drop/bucket-step builders to ModelOperations
  for headless test coverage
```
