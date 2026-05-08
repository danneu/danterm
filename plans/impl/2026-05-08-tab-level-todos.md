# Tab-level to-do lists

## Context

Each pane currently has its own to-do list, surfaced via a `TodoToolbarButton`
in the pane toolbar with a popover (`TodoPopoverView`). This plan adds a
parallel to-do list at the **tab** level: every tab gets its own list of
to-dos, and a new toolbar button on the right side of `WindowChromeView`
opens a popover that shows the active tab's items plus a read-only,
check-only roll-up of every pane's items in that tab.

Why: tab-level to-dos let the user track work that spans the panes inside a
tab without having to pick a "primary" pane to attach them to. The right-side
toolbar surface keeps the active tab's status visible at all times,
mirroring the per-pane affordance one level up.

## Decisions locked in

- **Independent tab to-do list** with read-only sub-sections per pane in the
  popover. Pane items are check/uncheck only from the tab popover; rename /
  delete / reorder still happen in the pane's own popover.
- **Toolbar icon = active tab + roll-up.** Counts shown in the right-side
  button cover `TabModel.todos` plus every pane's `todos` in that tab.
- **Mutually exclusive popovers.** Opening one closes the other. Encoded by
  collapsing `AppModel.todoPopoverPaneId: PaneId?` into a single enum slot.
- **Same checklist SF Symbol** as the pane button.
- **Persisted** alongside pane to-dos in the snapshot file (no separate store).

## Model changes (`app/Model.swift`)

```swift
struct TabModel {
    ...existing fields...
    var todos: [TodoItem] = []                 // NEW
}

enum TodoPopoverScope: Equatable {             // NEW
    case pane(PaneId)
    case tab(TabId)
}

struct AppModel {
    ...
    // REPLACE: var todoPopoverPaneId: PaneId? = nil  (line 179)
    var todoPopover: TodoPopoverScope? = nil
    ...
}
```

Snapshot (write+read backward compatible):

```swift
struct TabSnapshot {
    ...existing fields...
    var todos: [TodoSnapshot]? = nil            // optional, like PaneSnapshot.todos
}
```

`validateAndBuild` (`Model.swift:300`+) decodes `TabSnapshot.todos` into
`TabModel.todos` exactly as it does for `PaneSnapshot.todos` at line 451-455.

## Msg (`app/Msg.swift`)

Append next to the existing pane TODO block (line 135-144):

```swift
case toggleTodoPopoverForTab(tabId: TabId)
case todoPopoverForTabClosed(tabId: TabId)
case addTabTodo(tabId: TabId, text: String)
case toggleTabTodoDone(tabId: TabId, todoId: UUID)
case setTabTodoDone(tabId: TabId, todoId: UUID, isDone: Bool)
case editTabTodoText(tabId: TabId, todoId: UUID, text: String)
case deleteTabTodo(tabId: TabId, todoId: UUID)
case reorderTabTodo(tabId: TabId, todoId: UUID, toIndex: Int)
case clearCompletedTabTodos(tabId: TabId)
```

Pane checkbox toggles dispatched from inside the tab popover keep firing the
existing `setTodoDone(paneId:todoId:isDone:)` — no new message. Single
source of truth.

## Effect (`app/Effect.swift`)

```swift
case showTodoPopoverForTab(tabId: TabId)
case dismissTodoPopoverForTab
```

## Update (`app/Update.swift`)

Mirror handlers next to the existing pane todo block (lines 1183-1240):

- `toggleTodoPopoverForTab(tabId)`: if `model.todoPopover == .tab(tabId)` -> set nil + emit `dismissTodoPopoverForTab`. Else: set `.tab(tabId)`, emit `dismissTodoPopover` and `dismissTodoPopoverForTab` to clear whatever was open, then `showTodoPopoverForTab(tabId)`.
- `todoPopoverForTabClosed(tabId)`: if `model.todoPopover == .tab(tabId)` clear it.
- The existing `toggleTodoPopover(paneId)` handler is updated to use the new scope enum analogously (clear other scope, set `.pane(paneId)`).
- `addTabTodo` / `toggleTabTodoDone` / `setTabTodoDone` / `editTabTodoText` / `deleteTabTodo` / `reorderTabTodo` / `clearCompletedTabTodos` follow the pane handlers verbatim, mutating the matching `TabModel.todos` via a small `withTab(_ id:)` helper. All return `[.scheduleCheckpoint]`.

The existing `closePane` cleanup that nils the popover scope (search for `todoPopoverPaneId` at AppRuntime.swift:1024-1027 and 1185-1188) extends to the tab variant: when the active tab is removed, clear `model.todoPopover` if it's a `.tab(removedId)`.

**Close-tab confirmation gates on the full roll-up (tab todos + all pane todos in the tab).** `requestClosePane` (`Update.swift:1240-1246`) already gates on uncompleted pane todos for non-last-pane closes. Tab-level closes destroy *everything* in the tab, so the gate should match what the right-side toolbar badge already advertises: the `tabTodoRollup` count. If we gated only on `TabModel.todos`, a single-pane tab whose chrome badge reads "3 unfinished" would still close silently when the user hits Close Tab, because all 3 items live on the pane.

Changes:
- Extend `Effect.showCloseTabConfirmation` (`Effect.swift:43`) with a single new field `uncompletedTodoCount: Int` (deliberately generic — it covers the roll-up of tab todos + all pane todos in the tab; not named `uncompletedTabTodoCount`).
- Update `emitCloseTabConfirmation` (`ModelOperations.swift:432-443`) to take + forward the new count.
- In `requestCloseTab` handler: compute `let uncompletedTodos = tabTodoRollup(id, in: model).uncompleted` and emit confirmation when `paneCount > 1 || uncompletedTodos > 0`.
- The AppRuntime-side sheet wording surfaces the count when non-zero (e.g. "Close tab \"foo\"? It has 2 panes and 3 unfinished tasks." — exact copy is up to the implementation).

**Last-pane close path also gates on the roll-up.** `closePane` (`Update.swift:207-229`) falls through to `update(&model, .closeTab(id: tabId))` when `newTree == nil`. That call goes straight to the no-confirmation `.closeTab` branch, bypassing the new `requestCloseTab` gate — a user closing the only pane in a tab via Pane > Close Pane (or the pane context menu / kbd shortcut) would silently destroy uncompleted items.

Fix in `requestClosePane` (`Update.swift:1240-1246`): if the target pane is the sole pane of its tab (`allPaneIds(tab.rootNode).count == 1`) and the tab roll-up has any uncompleted items (`tabTodoRollup(tabId, in: model).uncompleted > 0`), emit `emitCloseTabConfirmation` (the same effect `requestCloseTab` uses). For non-last-pane closes, keep the existing `pane.todos` gate. The roll-up subsumes the per-pane check at the last-pane boundary, so there's no double-prompt: the close-tab sheet always wins when the pane being closed is the only one.

## ModelOperations (`app/ModelOperations.swift`)

Reuse:
- `allPaneIds(_ node: SplitNodeModel) -> [PaneId]` (line 51-58)
- `tabById(_ tabId: TabId, in model: AppModel) -> TabModel?` (line 331-334)

Add one new pure helper for the toolbar count + roll-up popover footer:

```swift
/// Total + uncompleted count for a tab's to-dos plus all pane to-dos
/// inside that tab. Pure — same input always yields same output.
func tabTodoRollup(_ tabId: TabId, in model: AppModel) -> (total: Int, uncompleted: Int)
```

`toSnapshot(_ model:)` (`ModelOperations.swift:585-639`): mirror the pane
todos write at lines 603-605 for tabs, populating `TabSnapshot.todos` with
nil when empty.

## Toolbar button (`app/WindowChromeView.swift`)

- Add `let tabTodoButton: TodoToolbarButton` as a stored property, added as a subview alongside the other buttons.
- Constrain only `tabTodoButton.trailingAnchor` to `trailingAnchor` with a small inset (`-8`) and `centerYAnchor` to chrome center. **Do not add an external height constraint** — `TodoToolbarButton` self-pins its height to 16pt at `TodoToolbarButton.swift:40`. Adding a 28pt constraint like `addTabButton` does would create an Auto Layout conflict. This matches how the pane toolbar already uses the button.
- **Update the existing title constraint** at `WindowChromeView.swift:151` from `titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)` to `titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: tabTodoButton.leadingAnchor, constant: -8)` so a long title or narrow window can't draw under the button.
- Reuse the existing `TodoToolbarButton` class — same icon, same colors, same `update(totalCount:uncompletedCount:)` API.
- Always shown (the trailing edge is visible in both sidebar-expanded and sidebar-collapsed states).

## Toolbar button wiring (`app/AppDelegate.swift`)

The other chrome buttons are wired via target/action in `AppDelegate.swift:65-72` (toggleButton, bellButton, addTabButton, addGroupButton). Mirror that pattern — not in `AppRuntime`. Add right after the `addGroupButton` wiring:

```swift
chromeView.tabTodoButton.target = self
chromeView.tabTodoButton.action = #selector(toggleTabTodoPopover(_:))
```

And add the action method on `AppDelegate`:

```swift
@objc func toggleTabTodoPopover(_ sender: Any?) {
    guard let tabId = runtime.model.selectedTabId else { return }
    runtime.send(.toggleTodoPopoverForTab(tabId: tabId))
}
```

## Tab todo popover

New file `app/TabTodoPopoverView.swift`:

- Class: `TabTodoPopoverViewController`, takes `tabId: TabId, runtime: AppRuntime`.
- One `NSTableView` driven by a row enum:
  ```swift
  enum TabTodoRow {
      case tabSectionHeader            // "This tab" + (uncompleted/total)
      case tabItem(TodoItem)
      case paneSectionHeader(paneId: PaneId, title: String, total: Int, uncompleted: Int)
      case paneItem(paneId: PaneId, item: TodoItem)
  }
  ```
- Tab items reuse `TodoRowView` from `TodoPopoverView.swift:15-87` (extract it to its own file `app/TodoRowView.swift` so both popovers can import it without circular dependency).
- Pane items use a new `PaneTodoCheckRowView` — checkbox + label only, no delete button, not editable. Toggling the checkbox dispatches `setTodoDone(paneId:todoId:isDone:)`.
- Header rows are non-selectable, render bold/secondary label.
- Reuse `TodoInputView` (`app/TodoInputView.swift`) verbatim for the "Add tab task" input — already generic, takes a placeholder.
- Reuse `TodoEditState` (already paneId-agnostic, just operates on UUIDs) for tab-item edit transitions.
- Selection-based edit mirrors `TodoPopoverView.swift:315` for tab items only; pane items don't enter edit mode on selection.

**Drag reorder for tab items only.** The pane popover supports drag-to-reorder (`TodoPopoverView.swift:153, 347-368`); tab items must too, since `reorderTabTodo` is otherwise unreachable from the UI. Implement:
- `tableView.registerForDraggedTypes([tabTodoRowDragType])` in `viewDidLoad`.
- `pasteboardWriterForRow`: return a pasteboard item only when the row is `.tabItem`; return nil for headers and `.paneItem` so those rows aren't draggable.
- `validateDrop`: clamp the proposed drop row to the contiguous tab-items range (between the tab-section header and the first pane-section header). Reject drops outside that range so a tab item can't be dragged into a pane section.
- `acceptDrop`: translate the table row index to a tab-todo array index (subtract the tab-section-header row offset), then dispatch `.reorderTabTodo(tabId:todoId:toIndex:)`.

Use a distinct UTI from the pane drag type (`tabTodoRowDragType`) so a drag started in one popover can't be dropped in the other.

## AppRuntime (`app/AppRuntime.swift`)

- Add `var tabTodoPopover: NSPopover?` and `private var tabTodoPopoverDelegate: TabTodoPopoverDelegateAdapter?` next to the existing pane equivalents (line 28-29).
- New effect handlers `showTodoPopoverForTab` / `dismissTodoPopoverForTab` (mirror lines 564-585), anchored to `chromeView?.tabTodoButton` (the runtime property is `chromeView`, not `windowChrome`; see `AppRuntime.swift:26`).
- New `TabTodoPopoverDelegateAdapter` (mirror `TodoPopoverDelegateAdapter` at line 1295-1310) to send `.todoPopoverForTabClosed(tabId)` on close.

**Lifecycle teardown — must mirror the pane popover at every site that tears it down:**

- `tearDownCurrentSession()` at `AppRuntime.swift:1056-1063` already closes `todoPopover` and clears `todoPopoverDelegate` + `model.todoPopoverPaneId`. Add the parallel three lines for `tabTodoPopover` / `tabTodoPopoverDelegate`. Since the popover-open state is collapsing into the single `model.todoPopover` enum, the existing `model.todoPopoverPaneId = nil` line becomes `model.todoPopover = nil`.
- `rebuildContentView()` at `AppRuntime.swift:1220-1225` does the same teardown. Apply the same edits there.
- The Update-side cleanup on tab removal must emit `.dismissTodoPopoverForTab` (in addition to clearing `model.todoPopover`) when the cleared scope is `.tab(removedId)`, so AppRuntime closes the floating NSPopover even though no `todoPopoverForTabClosed` will fire.

**Refresh logic** — extend the case block at `AppRuntime.swift:233-240` so the right-side button stays in sync:

```swift
case .surfaceTitle(let paneId, _), ...,
     .addTodo(let paneId, _), .toggleTodoDone(let paneId, _),
     .setTodoDone(let paneId, _, _),
     .editTodoText(let paneId, _, _), .deleteTodo(let paneId, _),
     .reorderTodo(let paneId, _, _), .clearCompletedTodos(let paneId):
    refreshPaneToolbar(for: paneId)
    if paneIsInActiveTab(paneId) { refreshTabTodoButton() }

case .addTabTodo(let tabId, _), .toggleTabTodoDone(let tabId, _),
     .setTabTodoDone(let tabId, _, _),
     .editTabTodoText(let tabId, _, _), .deleteTabTodo(let tabId, _),
     .reorderTabTodo(let tabId, _, _), .clearCompletedTabTodos(let tabId):
    if tabId == model.selectedTabId { refreshTabTodoButton() }
```

`refreshTabTodoButton()` calls `tabTodoRollup(selectedTabId, in: model)` and pushes the counts into `chromeView?.tabTodoButton.update(totalCount:uncompletedCount:)`. When `model.selectedTabId == nil`, call `update(totalCount: 0, uncompletedCount: 0)` so the button renders neutral (no badge) instead of stale.

**Also called from `rebuildContentView()`** at `AppRuntime.swift:1283`, right after the existing `refreshPaneToolbars()` call. This is the path session restore takes: `commitRestoreSession()` (`AppRuntime.swift:1083`) bypasses `update()` and goes straight to `rebuildContentView()`. Without this hook, a restored active tab with persisted `TabModel.todos` would render a neutral right-side badge until the user triggered another refresh-emitting message. Also called whenever `selectedTabId` changes.

## Files modified / added

Modified:
- `app/Model.swift` — `TabModel.todos`, `TabSnapshot.todos`, `TodoPopoverScope`, replace `todoPopoverPaneId`. Update `validateAndBuild`.
- `app/Msg.swift` — 9 new tab-todo cases.
- `app/Effect.swift` — 2 new tab-todo effects; add `uncompletedTodoCount` field to `showCloseTabConfirmation` (rolls up tab + all panes in the tab).
- `app/Update.swift` — mirror 9 handlers for tab variants; update existing pane handlers to use new scope enum; cleanup on tab removal; extend `requestCloseTab` to confirm when uncompleted tab todos exist; extend `requestClosePane` to route the last-pane case through close-tab confirmation when the tab has uncompleted tab todos.
- `app/ModelOperations.swift` — add `tabTodoRollup`; encode `TabModel.todos` in `toSnapshot`; extend `emitCloseTabConfirmation` signature with the new count.
- `app/AppRuntime.swift` — popover slot, effect handlers, refresh trigger extension, scope cleanup on selectedTabId changes / tab close; mirror tab popover teardown in `tearDownCurrentSession()` and `rebuildContentView()`; surface the new uncompleted-tab-todo count in the close-tab confirmation sheet copy.
- `app/AppDelegate.swift` — wire `chromeView.tabTodoButton` target/action; add `toggleTabTodoPopover(_:)` action method.
- `app/WindowChromeView.swift` — `tabTodoButton` on trailing edge; tighten `titleLabel.trailingAnchor`.
- `app/TodoPopoverView.swift` — extract `TodoRowView` so the new popover can reuse it; rewrite popover-scope read/writes against the new enum slot.
- `tests/TestHarness.swift` — register the new test bundle in `TestRunner.main()` (e.g. `updateTabTodoTests()`).

Added:
- `app/TabTodoPopoverView.swift` — `TabTodoPopoverViewController` + `PaneTodoCheckRowView`.
- `app/TodoRowView.swift` — extracted from `TodoPopoverView.swift:15-87`.

## Tests (TDD — write first, fail, then implement)

Added to `tests/`:

1. `UpdateTabTodoTests.swift` (mirror `UpdateTodoTests.swift`):
   - `addTabTodo` appends to the right tab's list, leaves panes and other tabs untouched.
   - `toggleTabTodoDone` flips the right item only.
   - `setTabTodoDone` sets explicit value.
   - `editTabTodoText` trims and replaces text.
   - `deleteTabTodo` removes by id.
   - `reorderTabTodo` clamps to bounds; permutation is correct.
   - `clearCompletedTabTodos` removes all `isDone` items.
   - `toggleTodoPopoverForTab(t)` while `.pane(p)` is open: ends with `.tab(t)` and emits dismiss-pane + show-tab effects.
   - `toggleTodoPopoverForTab(t)` while `.tab(t)` is open: ends nil + emits dismiss.
   - **`toggleTodoPopover(p)` while `.tab(t)` is open**: ends with `.pane(p)` and emits dismiss-tab + show-pane effects (covers the inverse direction since the existing pane handler is being rewritten against the new scope enum).
   - `toggleTodoPopover(p)` while `.pane(p)` is open: ends nil + emits dismiss (regression coverage for the existing path now that it uses the scope enum).
   - Removing the active tab while `.tab(activeId)` is open clears the scope **and emits `dismissTodoPopoverForTab`** so AppRuntime closes the floating popover.
   - **`requestCloseTab` on a single-pane tab with no todos anywhere**: returns `closeTab` directly (no confirmation). Regression for current behavior.
   - **`requestCloseTab` on a single-pane tab with uncompleted tab todos only**: emits `showCloseTabConfirmation` with `paneCount: 1` and `uncompletedTodoCount` matching the count.
   - **`requestCloseTab` on a single-pane tab with uncompleted pane todos only (no tab todos)**: emits `showCloseTabConfirmation` with `uncompletedTodoCount > 0`. This is the case where the chrome badge advertises "N unfinished" but the items live on the pane — the rollup gate catches it.
   - **`requestCloseTab` on a multi-pane tab with mixed uncompleted todos (some on tab, some across panes)**: emits `showCloseTabConfirmation` with `uncompletedTodoCount` equal to the full rollup.
   - **`confirmCloseTab` on a tab with uncompleted todos**: clears `pendingConfirmation` and proceeds to `closeTab` (the protection is the prompt, not a hard block).
   - **`requestClosePane` on the last pane of a tab with uncompleted tab todos**: emits `showCloseTabConfirmation` instead of falling through to `closePane` -> `closeTab`. Regression for the data-loss path through Pane > Close Pane.
   - **`requestClosePane` on a non-last pane of a tab with no pane todos but uncompleted tab todos**: closes silently (no confirmation). Tab todos survive non-last-pane closes; only tab-level destruction warns.
   - **`requestClosePane` on the last pane with BOTH uncompleted pane todos AND uncompleted tab todos**: emits exactly `showCloseTabConfirmation` (with `uncompletedTodoCount > 0`) and not `showClosePaneConfirmation`. Asserts precedence: a stronger warning wins.
   - **`requestClosePane` on the last pane with only uncompleted pane todos (no tab todos)**: still emits `showCloseTabConfirmation` because the rollup is non-zero — closing the last pane closes the tab and would destroy the pane todos. The existing per-pane sheet only fires for non-last-pane closes.

The new test bundle must be registered: add `updateTabTodoTests()` to `TestRunner.main()` in `tests/TestHarness.swift:5-38` next to the existing `todoTests()` call (line 27). Without this, the file compiles but no tests run.

2. Extend `SnapshotTests.swift`:
   - Tab snapshot with `todos` round-trips encode -> decode.
   - Tab snapshot without `todos` (legacy) decodes to empty list.
   - `toSnapshot` emits nil when `TabModel.todos` is empty.

3. Extend `ModelOperationsTests.swift`:
   - `tabTodoRollup` returns sum of tab + all pane todos in the tab; ignores other tabs' panes; `(0, 0)` for an empty tab.

4. **Update existing destructuring patterns** for `Effect.showCloseTabConfirmation` — adding `uncompletedTodoCount` is a breaking change for these sites:
   - `tests/UpdateTabTests.swift:382` — `(let tid, _, let count, let last)` -> `(let tid, _, let count, let last, _)` (or `, let todos` if the test wants to assert on it).
   - `tests/UpdateTabTests.swift:401, 436` — bare `case .showCloseTabConfirmation` patterns are unaffected.
   - `tests/CustomTitleTests.swift:167` — `(_, let tabTitle, _, _)` -> `(_, let tabTitle, _, _, _)`.

   The two `if case .showCloseTabConfirmation = $0` lines (`UpdateTabTests.swift:364, 436` and `CustomTitleTests.swift:163`) need no change.

No view-level tests — pane popover doesn't have any either, and AppKit views aren't unit-testable in this setup.

## Verification

End-to-end manual checks after implementation:

1. `just test` — all unit tests green.
2. `just build-run` — app launches.
3. Click the new right-side toolbar button: popover opens, shows "This tab" header with empty list and per-pane sections.
4. Add a tab to-do: count badge updates to yellow `1`.
5. Open a pane's own todo popover, add an item; the right-side tab badge increments to `2`.
6. From the tab popover, check the pane item: pane popover (re-opened) reflects it; tab badge drops to yellow `1`.
7. Complete the tab item: badge turns green `✓`.
8. Open pane todo popover -> tab popover dismisses (and vice versa).
9. Quit and relaunch: both tab and pane to-dos persist.
10. Switch tabs: right-side badge updates to reflect the newly active tab.
11. Close the active tab while its tab popover is open: popover dismisses cleanly, no dangling state.
12. Init-file written before this change still loads (no `todos` on `TabSnapshot`).
