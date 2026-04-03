# Per-Pane TODO System (v0.0.1)

## Context

While working in a terminal pane, you often think of things to do later ("once the agent finishes, run this command"). This adds an ultra-minimal per-pane TODO list that lives in the pane toolbar, persists across restarts, and stays out of the way when not in use.

## Design Decisions

- **Per-pane scope**: TODOs live on `PaneModel.todos` (not a separate dict). Cleanup is automatic when a pane is removed.
- **Ephemeral popover state**: `AppModel.todoPopoverPaneId: PaneId?` tracks which pane's popover is open (excluded from snapshot).
- **Close confirmation**: All explicit "Close Pane" user actions (pane menu, main menu Cmd+W, terminal context menu) go through `requestClosePane`. Natural shell exit (`surfaceClosed`) bypasses the TODO check.
- **Split**: New child pane starts with empty todos (no inheritance).
- **Plain UUID for TodoItem.id**: No phantom type needed — TODO IDs are pane-local and never participate in cross-domain uniqueness checks.

## Implementation

### 1. Model (`app/Model.swift`)

**Add `TodoItem` struct** (after `SearchModel`, ~line 53):
```swift
struct TodoItem: Equatable, Codable {
    let id: UUID
    var text: String
    var isDone: Bool
}
```

**Add `todos` to `PaneModel`** (line 66, after `remoteThemeOverride`):
```swift
var todos: [TodoItem] = []
```

**Add ephemeral popover state to `AppModel`** (line 132, after `showAllAlerts`):
```swift
var todoPopoverPaneId: PaneId? = nil  // ephemeral — excluded from snapshots
```

**Add `TodoSnapshot`** (before `PaneSnapshot`, ~line 223):
```swift
struct TodoSnapshot: Codable {
    let id: String
    let text: String
    let isDone: Bool
}
```

**Add `todos` field to `PaneSnapshot`** (after `theme`, line 229). Since `PaneSnapshot` is a struct with no custom init, adding a stored property changes the memberwise initializer and breaks all existing callsites (~12 in ModelOperations, AppRuntime, CheckpointTests, SnapshotTests, UpdateThemeTests). To avoid touching every callsite, add it as a `var` with a default:
```swift
var todos: [TodoSnapshot]? = nil  // nil for backward compat
```
This keeps all existing `PaneSnapshot(id:title:cwd:launch:scrollback:theme:)` callsites compiling. The `toSnapshot()` callsite sets it explicitly after construction.

**Update `validateAndBuildDetailed`** (~line 248): when building `PaneModel` from snapshot, restore todos:
```swift
if let todoSnaps = ps.todos {
    paneModel.todos = todoSnaps.compactMap { ts in
        guard let uuid = UUID(uuidString: ts.id) else { return nil }
        return TodoItem(id: uuid, text: ts.text, isDone: ts.isDone)
    }
}
```

### 2. Messages (`app/Msg.swift`)

Add after the Search section (~line 111):
```swift
// TODO
case toggleTodoPopover(paneId: PaneId)
case todoPopoverClosed(paneId: PaneId)
case addTodo(paneId: PaneId, text: String)
case toggleTodoDone(paneId: PaneId, todoId: UUID)
case editTodoText(paneId: PaneId, todoId: UUID, text: String)
case deleteTodo(paneId: PaneId, todoId: UUID)
case reorderTodo(paneId: PaneId, todoId: UUID, toIndex: Int)
case clearCompletedTodos(paneId: PaneId)
case requestClosePane(paneId: PaneId)
```

### 3. Effects (`app/Effect.swift`)

Add after search effects (~line 54):
```swift
// TODO
case showTodoPopover(paneId: PaneId)
case dismissTodoPopover
case showClosePaneConfirmation(paneId: PaneId, uncompletedCount: Int)
```

### 4. Snapshot serialization (`app/ModelOperations.swift`)

**`toSnapshot()`** (~line 562): convert `pane.todos` to `[TodoSnapshot]?`:
```swift
let todoSnapshots: [TodoSnapshot]? = pane.todos.isEmpty ? nil : pane.todos.map {
    TodoSnapshot(id: $0.id.uuidString, text: $0.text, isDone: $0.isDone)
}
```
Pass `todos: todoSnapshots` to `PaneSnapshot` init.

**`mergeCheckpoints()`**: carry `todos` from light snapshot through to merged result.

### 5. Update logic (`app/Update.swift`)

Add a `// MARK: - TODO` section:

- **`toggleTodoPopover`**: If already open for this pane, set `todoPopoverPaneId = nil` + `[.dismissTodoPopover]`. Otherwise set it + `[.showTodoPopover(paneId:)]`.
- **`todoPopoverClosed(paneId:)`**: Only clear if `model.todoPopoverPaneId == paneId` (guards against race when closing pane A's popover while B's is already open). Return `[]`.
- **`addTodo`**: Trim whitespace, reject empty. Append `TodoItem(id: UUID(), text:, isDone: false)`. Return `[.scheduleCheckpoint]`.
- **`toggleTodoDone`**: Find by UUID, toggle `.isDone`. Return `[.scheduleCheckpoint]`.
- **`editTodoText`**: Find by UUID, update text (reject empty). Return `[.scheduleCheckpoint]`.
- **`deleteTodo`**: Remove by UUID. Return `[.scheduleCheckpoint]`.
- **`reorderTodo`**: Guard that `todoId` exists and `toIndex` is in `0...todos.count`. No-op if position unchanged. Remove from old index, insert at clamped new index. Return `[.scheduleCheckpoint]`.
- **`clearCompletedTodos`**: `removeAll { $0.isDone }`. Return `[.scheduleCheckpoint]`.
- **`requestClosePane`**: Count uncompleted. If > 0, return `[.showClosePaneConfirmation(...)]`. Else delegate to `update(&model, .closePane(paneId:))`.

**Modify `closePane`** (~line 202): add popover cleanup:
```swift
if model.todoPopoverPaneId == paneId {
    model.todoPopoverPaneId = nil
    effects.append(.dismissTodoPopover)
}
```

**`surfaceClosed` stays unchanged** — natural shell exit bypasses TODO check.

### 6. TodoToolbarButton (`app/TodoToolbarButton.swift` — new file)

Custom `NSButton` subclass for the pane toolbar. Layout: `[countLabel iconView]` inside the button.

- `countLabel`: `NSTextField` showing remaining count (e.g. "2") or "✓" when all done.
- `iconView`: SF Symbol `checklist` (12pt).
- Yellow `contentTintColor` when incomplete, green when all complete.
- Hidden when `totalCount == 0`.

Public API:
```swift
func update(totalCount: Int, uncompletedCount: Int)
```

Size: fits within the 22pt toolbar height. Width auto-sizes to content.

### 7. TodoPopoverView (`app/TodoPopoverView.swift` — new file)

`TodoPopoverViewController` (NSViewController) following `AlertsPopoverViewController` pattern.

- Preferred content size: `320 × 400`
- `NSVisualEffectView` with `.hudWindow` material
- Header: "TODOs" label + "Clear completed" button (hidden when none completed)
- `NSScrollView` + `NSTableView` for task list
  - Each row: checkbox + editable `NSTextField` + delete (✕) button
  - Done items: strikethrough + dimmed
  - Drag reorder via `NSTableViewDataSource` drag/drop methods → sends `.reorderTodo`
  - Inline edit: `controlTextDidEndEditing` → sends `.editTodoText`
  - Checkbox click → sends `.toggleTodoDone`
  - Delete click → sends `.deleteTodo`
- Footer: `NSTextField` placeholder "Add a task…". On Enter → sends `.addTodo`, clears field.
- Holds `weak var runtime: AppRuntime?` and `let paneId: PaneId`.
- Reads from `runtime?.model.panes[paneId]?.todos` on `viewWillAppear` and on rebuild.

### 8. PaneWrapperView integration (`app/PaneWrapperView.swift`)

**Add `todoButton: TodoToolbarButton`** property. Init alongside other buttons.

**Add to toolbar trailing area**, to the left of `[unzoomButton?, menuButton]`:
```
[leadingStack ............ todoButton unzoomButton? menuButton]
```

Update `stackTrailingAnchor` to use `todoButton.leadingAnchor`.

**Update `updateToolbar` signature**:
```swift
func updateToolbar(title:, cwd:, progress:, isRemote:, unreadAlertCount:,
                   totalTodoCount: Int = 0, uncompletedTodoCount: Int = 0)
```
Call `todoButton.update(totalCount:uncompletedCount:)`.

**Add to pane dropdown menu** (`showPaneMenu`, ~line 281): "Open TODOs" item with `checklist` SF Symbol, before the close section.

**Wire `closePaneAction`** to send `.requestClosePane(paneId:)` instead of calling `ghostty_surface_request_close` directly.

**Expose** `var todoButtonView: NSView { todoButton }` for popover anchoring.

### 8b. TerminalView context menu (`app/TerminalView.swift`)

**Wire `contextClosePane`** (line 375) to send `.requestClosePane(paneId:)` instead of calling `ghostty_surface_request_close` directly. This ensures the terminal's right-click "Close Pane" also triggers TODO confirmation.

### 9. AppDelegate keybinding (`app/AppDelegate.swift`)

Add to the Pane menu (~line 341, before "Close Pane"):
```swift
let todoItem = NSMenuItem(title: "Open TODOs", action: #selector(openTodo(_:)), keyEquivalent: "t")
todoItem.keyEquivalentModifierMask = [.command, .option]
```

Note: Cmd+Shift+T is taken by "Toggle Theme Panel" (line 247). Using **Cmd+Option+T** instead.

Add action:
```swift
@objc func openTodo(_ sender: Any?) {
    guard let tab = selectedTab(in: runtime.model) else { return }
    runtime.send(.toggleTodoPopover(paneId: tab.focusedPaneId))
}
```

**Change `closePane(_:)`** (line 465) to send `.requestClosePane` instead of calling ghostty directly.

### 10. AppRuntime effect handling (`app/AppRuntime.swift`)

**Add `var todoPopover: NSPopover?`** property.

**Handle new effects in `perform()`**:

- **`showTodoPopover(paneId:)`**: Dismiss existing. Find pane wrapper, anchor to `todoButtonView`. Create `TodoPopoverViewController`, show NSPopover with `.transient`. Set `AppRuntime` as `NSPopoverDelegate`.
- **`dismissTodoPopover`**: `todoPopover?.performClose(nil); todoPopover = nil`.
- **Popover close delegate**: `AppRuntime` is not an `NSObject` and cannot directly conform to `NSPopoverDelegate`. Use a small adapter class:
  ```swift
  private class TodoPopoverDelegate: NSObject, NSPopoverDelegate {
      weak var runtime: AppRuntime?
      let paneId: PaneId
      func popoverDidClose(_ notification: Notification) {
          runtime?.send(.todoPopoverClosed(paneId: paneId))
      }
  }
  ```
  Store the delegate alongside the popover (`var todoPopoverDelegate: TodoPopoverDelegate?`) so it stays alive. Set `popover.delegate = delegate` when showing. This syncs model state on click-away, programmatic close, etc. The paneId guard in update prevents clobbering when switching between panes.
- **`showClosePaneConfirmation(paneId:, uncompletedCount:)`**: NSAlert sheet modal. On confirm: `ghostty_surface_request_close(surface)` (which triggers the standard `surfaceClosed → closePane` path).

**Popover lifecycle — dismiss on rebuild and teardown**: The TODO popover anchors to a pane wrapper view. Rebuilds (`rebuildContentView`, line 938) destroy and recreate all pane wrappers, and `tearDownCurrentSession` (line 786) tears down everything. Both paths must dismiss the TODO popover to avoid stale anchors:
- In `rebuildContentView()`: add `todoPopover?.performClose(nil); todoPopover = nil` alongside the existing `cancelPaneDrag()` call.
- In `tearDownCurrentSession()`: add `todoPopover?.performClose(nil); todoPopover = nil` alongside the existing alerts popover teardown (line 788).
- Reset `model.todoPopoverPaneId = nil` in both paths.

**Update `refreshPaneToolbar(for:)` and `refreshPaneToolbars()`** (~lines 895-912): compute todo counts from `model.panes[paneId]?.todos` and pass to `updateToolbar`.

**Refresh pane toolbar after TODO mutations**: In the effect-performing or post-`send()` logic, refresh the toolbar for the affected pane after any TODO message.

### 11. Tests (`tests/UpdateTodoTests.swift` — new file)

Register `todoTests()` in `TestRunner.main()` (`tests/TestHarness.swift`).

Test cases:
1. `addTodo` creates item with correct text, `isDone: false`, emits `.scheduleCheckpoint`
2. `addTodo` trims whitespace
3. `addTodo` rejects empty/whitespace-only text
4. `toggleTodoDone` flips `isDone`, emits checkpoint
5. `editTodoText` updates text, rejects empty
6. `deleteTodo` removes the correct item
7. `reorderTodo` moves item to correct position
8. `clearCompletedTodos` removes only done items
9. `requestClosePane` with uncompleted TODOs emits `.showClosePaneConfirmation` (pane not removed)
10. `requestClosePane` with 0 uncompleted (all done or empty) proceeds to `closePane`
11. `closePane` clears `todoPopoverPaneId` + emits `.dismissTodoPopover` when popover was open
12. `toggleTodoPopover` opens/closes correctly
13. `todoPopoverClosed` for stale pane does not clobber active popover: set `todoPopoverPaneId = paneB`, send `.todoPopoverClosed(paneId: paneA)`, assert `todoPopoverPaneId` is still `paneB`
14. `splitPane` starts child with empty todos

Add snapshot round-trip test to `tests/SnapshotTests.swift`:
14. Snapshot with todos encodes and restores correctly
15. Snapshot without `todos` field decodes with empty array (backward compat)

## File Summary

| New files | Purpose |
|-----------|---------|
| `app/TodoToolbarButton.swift` | Pane toolbar button: `[2 ☐]` / `[✓ ☐]` |
| `app/TodoPopoverView.swift` | NSPopover: task list, add, edit, reorder, delete |
| `tests/UpdateTodoTests.swift` | Pure update/model tests |

| Modified files | Changes |
|----------------|---------|
| `app/Model.swift` | `TodoItem`, `PaneModel.todos`, `todoPopoverPaneId`, `TodoSnapshot`, `PaneSnapshot.todos`, `validateAndBuild` |
| `app/Msg.swift` | 9 new cases |
| `app/Effect.swift` | 3 new cases |
| `app/Update.swift` | TODO section + `requestClosePane` + cleanup in `closePane` |
| `app/ModelOperations.swift` | `toSnapshot` + `mergeCheckpoints` |
| `app/PaneWrapperView.swift` | button, menu item, `closePaneAction` → `requestClosePane`, `updateToolbar` signature |
| `app/TerminalView.swift` | `contextClosePane` → `requestClosePane` |
| `app/AppRuntime.swift` | `todoPopover`, 3 effects, toolbar refresh, popover lifecycle in rebuild/teardown |
| `app/AppDelegate.swift` | keybinding (Cmd+Option+T), `closePane` → `requestClosePane` |
| `tests/TestHarness.swift` | Register `todoTests()` |
| `tests/SnapshotTests.swift` | 2 snapshot round-trip tests |

## Build Order

1. Model + Msg + Effect + ModelOperations (compiles, no view code)
2. Update.swift handlers (compiles, testable)
3. Tests (run `just test` to verify pure logic)
4. TodoToolbarButton + TodoPopoverView (new view files)
5. PaneWrapperView + AppRuntime + AppDelegate integration
6. `just build` to verify full compilation
7. `just build-run` to manually verify popover, badge, persistence, close confirmation

## Verification

- `just test` — all new tests pass, no regressions
- `just build` — compiles clean
- Manual: add tasks, check badge shows `[2 ☐]` yellow → complete all → `[✓ ☐]` green → close all → button hides
- Manual: Cmd+Option+T toggles popover, click-away dismisses
- Manual: right-click terminal → "Close Pane" with uncompleted TODOs → modal alert appears
- Manual: close pane with uncompleted tasks → modal alert appears → cancel preserves pane → confirm closes
- Manual: quit and relaunch → TODOs restored from snapshot
- Manual: split pane → new pane has empty todo list
