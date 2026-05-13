# Tab To-Do List UX changes

## Context

The tab-level to-do popover (Cmd+') currently optimizes for browsing existing
items: opening it focuses the table, and Cmd+Enter on a new item drops focus
into the newly-added row. In practice users open the popover to add several
items in a row, so the cursor keeps escaping the input field. We also have no
visual affordance for "this pane has no todos yet" -- empty pane sections
render just a header with nothing beneath it, which reads as broken.

This plan rewires the tab popover to optimize for the chained-entry flow:
always open in compose mode, stay in compose mode after each submit, make
plain Enter the submit gesture, and add a non-selectable "No todo items"
placeholder row beneath every empty section. The per-pane popover (Cmd+Shift+')
must absorb the focus/submit half of the change in the same pass because both
popovers share `classifyInputAction`; landing them atomically prevents Enter
from regressing to a no-op in Cmd+Shift+' between commits. The "No todo items"
placeholder is tab-popover-only -- the per-pane popover has no section
buckets and its existing centered "No tasks yet" label already covers the
empty case.

## Files

Shared classifier (both popovers):

- `app/TodoInputCommand.swift` -- `classifyInputAction` semantics for Enter / Shift+Enter

Tab popover:

- `app/TabTodoPopoverView.swift` -- focus behavior, input key routing, post-submit state, placeholder row view
- `app/ModelOperations.swift` -- `TabTodoRow` enum, `buildTabTodoRows`, drop resolution

Per-pane popover (must land in same change as classifier):

- `app/TodoPopoverView.swift` -- mirror focus + submit behavior (no placeholder work; the existing centered "No tasks yet" label handles its empty state)

Tests:

- `tests/UpdateTodoTests.swift` -- extend the existing `classifyInputAction` block (line ~289) with the new Enter/Shift+Enter expectations
- `tests/ModelOperationsTests.swift` -- placeholder row construction, placeholder helper semantics, drop targeting (including drop-at-end)
- `tests/UpdateTabTodoTests.swift` -- (no Msg/Update changes expected, but verify nothing regresses)

## Changes

### 1. `classifyInputAction` -- swap Enter / Shift+Enter

`app/TodoInputCommand.swift:63`

```swift
case .enter:
    return .submit
case .shiftEnter:
    return .insertNewline
```

This makes plain Enter the submit gesture in both compose and edit modes.

Both `TodoPopoverView` (per-pane, Cmd+Shift+') and `TabTodoPopoverView` (tab,
Cmd+') run text-view commands through this classifier. The pre-existing
`.submit` branch in each view only handled the edit path
(`saveEditThenReturnToList()` returns false in compose mode). Sections 3-4
extend the tab popover; section 4b (new, below) extends the per-pane popover
in the same change so plain Enter never regresses to a swallowed no-op.

Other branches (Escape, Backspace, Tab, Backtab) are unchanged.

### 2. Tab popover -- always open in compose mode

`app/TabTodoPopoverView.swift:369` (`focusInitialMode`)

Replace the "select first row, focus table" logic with: always focus the
compose input with an empty draft. The user can press Tab/Shift+Tab to jump
into the table once they want to navigate items.

```swift
private func focusInitialMode() {
    focusComposeInput()
}
```

`composeDraft` should already be empty for a fresh popover; the existing
`focusComposeInput()` sets `addInput.string = composeDraft`, so no further
change needed there.

### 3. Tab popover -- stay in compose mode after submit

`app/TabTodoPopoverView.swift:431` (`addTodoThenReturnToList`)

Rename to `addTodoAndStayInCompose` (or inline) and change the post-submit
behavior: send the Msg, clear the input, rebuild rows, then keep focus on the
compose input instead of selecting the new row.

```swift
private func addTodoAndStayInCompose() {
    let text = addInput.string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    runtime?.send(.addTabTodo(tabId: tabId, text: text))
    composeDraft = ""
    addInput.string = ""
    rebuildRows()
    view.window?.makeFirstResponder(addInput.textView)
}
```

Update callers in `performTodoKeyEquivalent` (line ~545 area equivalent) and
the new `.submit` handler in `textView(_:doCommandBy:)`.

### 4. Route `.submit` from input field to the right code path

`app/TabTodoPopoverView.swift` -- in the `textView(_:doCommandBy:)` extension
(equivalent of `TodoPopoverView.swift:579`).

The current `.submit` case calls `saveEditThenReturnToList()`. Expand it to
handle the compose path too:

```swift
case .submit:
    if isEditing {
        _ = saveEditThenReturnToList()
    } else {
        addTodoAndStayInCompose()
    }
    return true
```

Cmd+Enter is currently caught earlier in `performTodoKeyEquivalent` before
reaching the classifier. Update that branch to use the same
`addTodoAndStayInCompose()` helper so plain Enter and Cmd+Enter behave
identically in compose mode (per user clarification).

### 4b. Per-pane popover -- mirror focus + submit (lands in this change)

`app/TodoPopoverView.swift`. Apply the analogous edits so the per-pane popover
behaves identically to the tab popover for focus and submit:

- `focusInitialMode()` (line 264): replace with `focusComposeInput()` only.
- `addTodoThenReturnToList()` (line 328): rename/inline to keep focus on the
  input and clear the field; do not select the newly-added row.
- `textView(_:doCommandBy:)` `.submit` case (line 617): branch on
  `editState.editingTodoId != nil` -- editing calls `saveEditThenReturnToList()`,
  compose calls the new helper.
- Cmd+Enter branch in `performTodoKeyEquivalent` (line 549): route compose-mode
  Cmd+Enter through the same compose helper.

No placeholder/empty-section work for this popover; the existing centered
"No tasks yet" label still handles the all-empty case correctly.

### 5. `TabTodoRow` -- add placeholder case

`app/ModelOperations.swift:464`

```swift
enum TabTodoRow: Equatable {
  case tabSectionHeader
  case tabItem(TodoItem)
  case tabEmptyPlaceholder
  case paneSectionHeader(paneId: PaneId, title: String)
  case paneItem(paneId: PaneId, item: TodoItem)
  case paneEmptyPlaceholder(paneId: PaneId)
}
```

Extend the helper extensions (`isHeader`, `isSelectable`, `editTarget`,
`itemText`, `sectionIdentifier`) so the placeholder rows are:
- `isHeader: false` (not group-row styled)
- `isSelectable: false` (j/k skips over them)
- `editTarget: nil`, `itemText: nil`
- `sectionIdentifier`: matches its owning section (`"tab"` or the `paneId`)

### 6. `buildTabTodoRows` -- emit placeholders for empty sections

`app/ModelOperations.swift:532`

```swift
func buildTabTodoRows(model: AppModel, tabId: TabId) -> [TabTodoRow] {
  guard let tab = tabById(tabId, in: model) else { return [] }
  var rows: [TabTodoRow] = [.tabSectionHeader]
  if tab.todos.isEmpty {
    rows.append(.tabEmptyPlaceholder)
  } else {
    for item in tab.todos { rows.append(.tabItem(item)) }
  }
  for paneId in allPaneIds(tab.rootNode) {
    guard let pane = model.panes[paneId] else { continue }
    rows.append(.paneSectionHeader(paneId: paneId, title: pane.title))
    if pane.todos.isEmpty {
      rows.append(.paneEmptyPlaceholder(paneId: paneId))
    } else {
      for item in pane.todos { rows.append(.paneItem(paneId: paneId, item: item)) }
    }
  }
  return rows
}
```

### 7. Tab popover -- render placeholder row

`app/TabTodoPopoverView.swift:480` (`viewFor`)

Add cases that render a plain `NSTableCellView`-equivalent with secondary-label
text "No todo items", left-aligned with the same inset as item rows. Reuse a
new `TabTodoEmptyRowView` class (small, inline) since headers and items use
distinct row view classes already.

Also update `shouldSelectRow` (line 521) so the new cases return `false`, and
`isGroupRow` (line 546) so they return `false`.

### 8. Drop target -- accept drops onto the placeholder

`app/ModelOperations.swift` (`resolveTabTodoDropTarget`, around line 548)

Extend the `.on` and `.above` switches so dropping on `tabEmptyPlaceholder`
returns `(.tab(tabId), 0)` and dropping on `paneEmptyPlaceholder(paneId)`
returns `(.pane(paneId), 0)`. Dropping `.above` a placeholder also resolves to
index 0 in that bucket.

`tabTodoDestination(for:)` (line 625) also needs the new cases. The
`.above` branch for `proposedRow == rows.count` looks up the destination of
`rows.last`; when the final pane is empty the last row is now a placeholder,
and without these cases drop-at-end would silently fail.

```swift
private func tabTodoDestination(for row: TabTodoRow, tabId: TabId) -> TodoDestination? {
  switch row {
  case .tabSectionHeader, .tabItem, .tabEmptyPlaceholder:
    return .tab(tabId)
  case .paneSectionHeader(let paneId, _), .paneItem(let paneId, _), .paneEmptyPlaceholder(let paneId):
    return .pane(paneId)
  }
}
```

The bucket-aware reorder helper `sectionLocalIndex` (TodoInputCommand.swift:142)
already keys on `sectionIdentifier`, so placeholders sharing the same section
identifier won't break j/k navigation since they're non-selectable.

### 9. Empty-state visibility

`app/TabTodoPopoverView.swift:271` (`rebuildRows`)

The current logic hides the entire `scrollView` and shows a centered "No tasks
yet" label when the global item count is zero. With placeholders we want the
table to remain visible (so users see "This tab: No todo items" and per-pane
placeholders). Remove the `scrollView.isHidden = itemCount == 0` line and
`emptyLabel.isHidden = itemCount > 0` -- always show the table, never show the
"No tasks yet" centered label. The `emptyLabel` field can be removed entirely.

## Verification

Pure unit tests (`just test`):

1. `tests/UpdateTodoTests.swift` -- in the existing `classifyInputAction`
   block (line ~289), flip the Enter/Shift+Enter expectations:
   - `classifyInputAction(.enter, isEditing: false, fieldEmpty: true)` -> `.submit`
   - `classifyInputAction(.enter, isEditing: true,  fieldEmpty: false)` -> `.submit`
   - `classifyInputAction(.shiftEnter, isEditing: false, fieldEmpty: true)` -> `.insertNewline`
   - `classifyInputAction(.shiftEnter, isEditing: true,  fieldEmpty: false)` -> `.insertNewline`
   These live in `todoTests()` which is already registered in `TestHarness.swift`,
   so they run automatically.
2. `tests/ModelOperationsTests.swift` -- `buildTabTodoRows`:
   (a) empty tab + empty panes -> every section header is followed by its
       placeholder row;
   (b) populated tab + one empty pane -> only that pane gets a placeholder;
   (c) ordering -- placeholder always immediately follows its header.
3. `tests/ModelOperationsTests.swift` -- placeholder helper semantics:
   for both `.tabEmptyPlaceholder` and `.paneEmptyPlaceholder(paneId)` assert
   `isHeader == false`, `isSelectable == false`, `editTarget == nil`,
   `itemText == nil`, and `sectionIdentifier` matches the owning section.
4. `tests/ModelOperationsTests.swift` -- `resolveTabTodoDropTarget`:
   - drop `.on` a `paneEmptyPlaceholder(p)` -> `(.pane(p), 0)`
   - drop `.above` a `paneEmptyPlaceholder(p)` -> `(.pane(p), 0)`
   - drop at `proposedRow == rows.count` with `.above` when the final row is
     `.paneEmptyPlaceholder(p)` -> `(.pane(p), 0)` (regression guard for the
     `tabTodoDestination` update).

Manual UI verification (`just build-run`):

1. Cmd+' on a tab with no todos -> popover opens, input field focused, "No
   todo items" rows show under "This tab" and every pane section.
2. Type a tab task, press Enter -> item appears in the "This tab" section,
   input field clears, focus stays on input. Repeat 3-4 times to confirm
   chained entry feels natural.
3. Press Shift+Enter -> a newline appears in the input field (no submit).
4. Press Tab -> focus jumps to the first item in the list. Press Shift+Tab ->
   focus returns to the input.
5. With an item selected in the list, press Enter -> input field shows the
   item text with selection (edit mode). Edit, press Enter -> changes save,
   focus returns to the list with the edited row selected. Press Esc instead
   -> edit cancels.
6. Drag an item from a non-empty pane onto another pane's "No todo items"
   placeholder -> item moves into that pane's bucket and the placeholder
   disappears.
7. Add a todo to an empty pane via terminal command or by moving an existing
   one -> placeholder for that pane disappears.

Per-pane popover (Cmd+Shift+', same change): repeat manual steps 1-5 except
the empty-state shows the existing centered "No tasks yet" label rather than
placeholder rows; drag/drop placeholder check (step 6) is not applicable.
