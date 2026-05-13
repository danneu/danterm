# Plan: Select newly-added todo row when submitting from tab popover compose

## Context

In the tab-level todo popover (`TabTodoPopoverView`), when the user is typing
in the "Add a tab task..." input and submits with Enter, the new item is
appended and focus stays in the input so they can keep adding items. This
behavior is correct.

However, the table's selection is not updated to point at the newly inserted
row. As a result, when the user later presses Tab to move focus from the
input into the list, `focusListFromInput()` finds no valid selection and
falls back to `firstSelectableRow(...)` -- the first item under "This tab"
-- rather than the item the user just added.

Desired behavior: each submit should select the just-added row in the
background (without stealing focus from the compose input). Then Tab from
the input lands on the new item, matching the user's mental model.

### Root cause (already diagnosed)

`addTodoAndStayInCompose()` in `app/TabTodoPopoverView.swift` (lines 455-463):

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

Nothing in this path touches `tableView.selectedRow`. The Update case
`.addTabTodo` (`app/Update.swift:1237-1243`) appends to `t.todos`, so the
new item is always the last entry. After `rebuildRows()` the table's
`selectedRow` is still `-1` (no row was selected because focus was on the
text view). When Tab is later pressed, the textView delegate routes to
`.moveFocusForward` -> `focusListFromInput()` (lines 404-416), which sees
the invalid index and falls back to `firstSelectableRow` -- the first
tab item.

## Change

Set the table selection to the newly inserted todo's row right after
`rebuildRows()`, before leaving focus in the compose input. Use the
existing `rowIndex(for:)` lookup (lines 353-355) and the existing
`setSelectedRow(_:)` helper (lines 357-363), which already wraps the
update in `isSyncingTableSelection` so the side-effect-y
`tableViewSelectionDidChange` doesn't fire and overwrite the compose
input.

### Critical file

- `app/TabTodoPopoverView.swift` -- only `addTodoAndStayInCompose()`
  needs to change.

### Implementation

Replace `addTodoAndStayInCompose()` body with:

```swift
private func addTodoAndStayInCompose() {
    let text = addInput.string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    runtime?.send(.addTabTodo(tabId: tabId, text: text))
    composeDraft = ""
    addInput.string = ""
    rebuildRows()
    // Pre-select the new item so a subsequent Tab from the compose input
    // lands on it instead of falling back to the first row.
    if let newId = tab?.todos.last?.id,
       let row = rowIndex(for: .tab(todoId: newId)) {
        setSelectedRow(row)
    }
    view.window?.makeFirstResponder(addInput.textView)
}
```

Rationale for `tab?.todos.last?.id`: `Update.swift:1241` does
`t.todos.append(...)`, so the most recently added item is always the
last entry. Using id-based lookup (rather than "last selectable row")
keeps it robust if `buildTabTodoRows` layout ever changes.

`setSelectedRow(_:)` already handles `isSyncingTableSelection`, so this
will not trigger `tableViewSelectionDidChange` and won't disturb the
compose input contents or focus. Focus remains on `addInput.textView`
because we still call `makeFirstResponder` on it after the selection
change.

### Reused utilities (no new helpers needed)

- `rowIndex(for:)` -- `app/TabTodoPopoverView.swift:353`
- `setSelectedRow(_:)` -- `app/TabTodoPopoverView.swift:357`
- `tab` computed property -- `app/TabTodoPopoverView.swift:176`
- `TabTodoEditTarget.tab(todoId:)` -- `app/ModelOperations.swift:474`

## Out of scope

- The pane-level `TodoPopoverView` is not changed. The user's report is
  specifically about the tab popover; touching the pane popover would
  be unrelated scope.
- No changes to `Update.swift`, `Msg.swift`, or `ModelOperations.swift`.
- No changes to the keyboard classifiers in `TodoInputCommand.swift`.

## Verification

This behavior is driven by `NSTableView` state, so it isn't reachable
from pure unit tests. Verify manually:

1. `just build-run`
2. Open the tab todo popover via the chrome button (or its shortcut).
3. Compose focus is in the "Add a tab task..." input by default.
4. Type "first" and press Enter. The list now shows "first"; the
   input is empty; focus stays in the input.
5. Press Tab. Selection should land on "first" (the row just added),
   not on whatever was there previously.
6. Press Shift+Tab (or Cmd+N) to return to compose, type "second",
   press Enter, then Tab. Selection should land on "second".
7. Repeat with a third item to confirm the new row is always the
   pre-selected one.
8. Sanity check: with focus in the input and the field empty, press
   Tab without first submitting anything -- selection should still
   fall back to `firstSelectableRow` (the existing default behavior is
   preserved for the no-submit case).
9. Sanity check: existing flows are unaffected --
   - Edit a row via Enter/Tab from list, save with Enter; selection
     stays on the edited row.
   - Esc dismisses; Cmd+Backspace deletes selected row.
