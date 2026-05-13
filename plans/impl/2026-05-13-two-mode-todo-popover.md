# Two-Mode Todo Popover Editing

## Summary

Refactor the todo popovers into explicit list and edit modes. List mode shows the
existing todo list plus a permanent bottom compose field for new todos only.
Edit mode replaces the list with a large multiline editor for one selected todo,
then returns to list mode on save or cancel.

This removes the preview-selection behavior and the mouse-focus promotion hook,
leaning on clearer AppKit-style focus and mode transitions.

## Key Changes

- Add explicit popover mode state in both todo controllers: `list` or
  `edit(target)`.
- In list mode, row selection only selects rows; it never copies row text into
  the compose field.
- Remove `isPreviewingSelectedRow`, `enterEditFromInputClick()`, row-preview
  repopulation, the bottom edit label, and the custom mouse-acquire-focus hook
  in `TodoInputView`.
- Keep the bottom compose input as a new-todo field only. It is hidden while
  editing an existing todo.
- Add an edit container with:
  - a context title for pane/tab/pane-rollup todo edits,
  - a larger multiline `TodoInputView`,
  - Save and Cancel buttons.
- Make `TodoInputView` support configurable visible line count, defaulting to
  the current compact compose size and using a larger size in edit mode.
- When opening edit mode, focus the editor and place the caret at the end
  instead of selecting all text.

### Shared pure mode/draft helper

- Replace the per-controller `TodoEditState` + `composeDraft` +
  `isPreviewingSelectedRow` triple with a single shared pure type
  `TodoPopoverState<Target>` used by both popover controllers. Lives in a new
  file `app/TodoPopoverState.swift`. The existing `app/TodoEditState.swift` is
  deleted along with its tests; surviving cases are migrated.
- `Target` is the edit-target generic parameter so the pane popover can use
  `UUID` and the tab popover can use `TabTodoEditTarget` (see
  `app/ModelOperations.swift:473`) without duplicating logic.
- State shape: `mode: .list | .edit(Target)` and `composeDraft: String`. The
  helper is the only place mode and draft transition, so neither controller
  mutates them ad hoc.
- Transition surface (all pure, all behaviorally tested):
  - `selectRow(_:)` — never writes to `composeDraft`.
  - `enterEdit(target:itemText:)` — mode becomes `.edit(target)`; `composeDraft`
    is preserved.
  - `saveEdit(text:)` — trims; if empty, returns a reject signal and leaves
    mode as `.edit(target)` with `composeDraft` unchanged; otherwise returns
    the trimmed text and target, sets mode to `.list`, leaves `composeDraft`
    unchanged.
  - `cancelEdit()` — mode becomes `.list`; `composeDraft` unchanged.
  - `rebuild(targetsAvailable:)` — if the current `.edit(target)` target is no
    longer present, mode falls back to `.list`; `composeDraft` unchanged.
  - `setComposeDraft(_:)` — called from the compose field's text-change
    observer to mirror user edits into the helper.
  - `clearComposeDraft()` — sets `composeDraft = ""`. Used for the two paths
    where the controller programmatically clears the compose field and the
    NSTextView text-change notification does not fire: successful add-submit
    and edit-mode `Cmd+N`. Mode is unchanged. `setComposeDraft` and
    `clearComposeDraft` are the only writers of `composeDraft`; no controller
    mutates `composeDraft` directly.

## Keyboard Behavior

- List mode:
  - `Enter` opens edit mode for the selected row.
  - Double-click opens edit mode for that row.
  - `Tab` / `Shift+Tab` moves focus to the compose field.
  - Existing list shortcuts remain: arrows or `j/k`, `Space`, `Cmd+Backspace`,
    reorder, and tab-popover bucket moves.
  - `Cmd+N` focuses the compose field.
- Compose field:
  - `Enter` creates a new todo.
  - `Shift+Enter` inserts a newline.
  - `Esc` returns focus to the list when possible, otherwise dismisses the
    popover.
  - `Tab` / `Shift+Tab` move focus out of the compose field; they never submit
    or cancel.
  - Adding a todo clears the compose field and keeps compose mode intact.
- Edit mode:
  - `Enter` saves and returns to list mode.
  - `Shift+Enter` inserts a newline.
  - `Esc` cancels and returns to list mode.
  - `Tab` / `Shift+Tab` traverse focus between the editor, Save, and Cancel
    button. They never submit or cancel the edit.
  - `Cmd+N` runs save first via `saveEdit(text:)`. On success, mode becomes
    `.list`, the controller calls `clearComposeDraft()`, then focuses the
    compose field. On reject (empty after trim), mode stays `.edit(target)`,
    `composeDraft` is left untouched, and the editor keeps focus -- no
    compose clear, no compose focus.
  - If the edit text is empty after trimming spaces, save is rejected, edit mode
    stays active, and the editor keeps focus (same rule as Enter).

Classifier impact: `classifyInputAction` in `app/TodoInputCommand.swift:77` is
simplified so `tab` always returns `.moveFocusForward` and `backtab` always
returns `.moveFocusBackward` regardless of `isEditing`. The `isEditing` flag
no longer changes Tab/Backtab semantics; Enter/Esc/buttons fully drive
submit/cancel in both compose and edit modes.

### Controller wiring for focus actions

Both popover controllers currently treat `.moveFocusForward` as "move focus
into the list" and swallow `.moveFocusBackward` (see
`app/TodoPopoverView.swift:655` and `app/TabTodoPopoverView.swift:1019`).
Under two-mode, the controllers must branch on the popover mode:

- **List mode**:
  - `.moveFocusForward` from the compose field: focus the list (existing
    `focusListFromInput()` path).
  - `.moveFocusBackward` from the compose field: focus the list as well
    (compose is the trailing element in list mode, so Shift+Tab loops back
    to the list rather than escaping the popover).
- **Edit mode**:
  - The edit container exposes a key-view loop: `editor.nextKeyView = save`,
    `save.nextKeyView = cancel`, `cancel.nextKeyView = editor`. The loop is
    set up when the edit container is installed and torn down when leaving
    edit mode.
  - `.moveFocusForward` calls `window?.selectNextKeyView(nil)` to walk the
    loop (Editor → Save → Cancel → Editor).
  - `.moveFocusBackward` calls `window?.selectPreviousKeyView(nil)` to walk
    it in reverse.
  - The compose field is hidden in edit mode and is not part of the loop.

These wirings replace the current `.moveFocusForward → focusListFromInput`
and `.moveFocusBackward → return true` handlers in both controllers, in
parallel.

## Edge Cases

- If the edited todo still exists after save/cancel/rebuild, return to list mode
  with that row selected and focused.
- If the edited todo disappears during a rebuild, leave edit mode and return to
  list mode with the nearest available row selected.
- Rebuilds must not refill or overwrite the compose field based on list
  selection.
- Tab-level edits must preserve the existing target distinction between tab todos
  and pane todos, dispatching saves to the correct model update.

## Tests

Tests must lock down the mode/draft contract behaviorally so the old
preview-selection behavior cannot regress while the planned tests pass.

### Pure classifier tests (`tests/UpdateTodoTests.swift`)

- `classifyInputAction(key: .tab, isEditing: false, ...) == .moveFocusForward`.
- `classifyInputAction(key: .tab, isEditing: true,  ...) == .moveFocusForward`.
- `classifyInputAction(key: .backtab, isEditing: false, ...) == .moveFocusBackward`.
- `classifyInputAction(key: .backtab, isEditing: true,  ...) == .moveFocusBackward`.
- `classifyListAction(key: .enter)`  returns `.enterEdit`.
- `classifyListAction(key: .tab)`    returns `.focusInput` (Tab leaves the
  list and lands on the compose field). Update the existing
  `list tab and enter enter edit` test accordingly.
- Existing `tab while editing → submit` and `backtab while editing → cancelEdit`
  tests are deleted, not retained alongside the new behavior.

### Pure mode/draft helper tests (new `tests/TodoPopoverStateTests.swift`)

These exercise the shared helper behaviorally; they must not assert on the
internal field names or call ordering, only on observable transitions and
preserved data:

- Selection-preserves-compose: starting in `.list` with `composeDraft = "abc"`,
  calling `selectRow(...)` leaves `composeDraft == "abc"`.
- Enter-edit-preserves-compose: starting in `.list` with `composeDraft = "abc"`,
  calling `enterEdit(target:itemText:"todo text")` produces
  `mode == .edit(target)` and leaves `composeDraft == "abc"`.
- Save-returns-to-list-and-preserves-compose: from `.edit(target)` with
  `composeDraft = "abc"`, `saveEdit(text: "new")` produces `mode == .list`,
  returns the trimmed save payload, and leaves `composeDraft == "abc"`.
- Cancel-returns-to-list-and-preserves-compose: from `.edit(target)` with
  `composeDraft = "abc"`, `cancelEdit()` produces `mode == .list` and leaves
  `composeDraft == "abc"`.
- Empty-after-trim-save-rejected: from `.edit(target)` with
  `composeDraft = "abc"`, `saveEdit(text: "   ")` returns a reject signal,
  leaves `mode == .edit(target)`, and leaves `composeDraft == "abc"`.
- Rebuild-missing-target-fallback: from `.edit(target)` with
  `composeDraft = "abc"`, calling `rebuild(targetsAvailable: <set without
  target>)` produces `mode == .list` and leaves `composeDraft == "abc"`.
- Rebuild-preserves-draft-on-list: from `.list` with `composeDraft = "abc"`,
  `rebuild(...)` leaves `composeDraft == "abc"` regardless of which targets
  exist.
- Clear-from-list: from `.list` with `composeDraft = "abc"`,
  `clearComposeDraft()` leaves `mode == .list` and `composeDraft == ""`.
  (Models the successful add-submit path.)
- Edit-cmd-n-success: from `.edit(target)` with `composeDraft = "abc"`,
  call `saveEdit(text: "new")` → success, mode becomes `.list`, draft
  preserved as `"abc"`. Then call `clearComposeDraft()` → mode stays `.list`,
  draft becomes `""`. Models the controller-side `Cmd+N` success ordering
  (save first, then clear).
- Edit-cmd-n-rejected: from `.edit(target)` with `composeDraft = "abc"`,
  call `saveEdit(text: "   ")` → reject, mode stays `.edit(target)`, draft
  remains `"abc"`. Assert that the controller does not invoke
  `clearComposeDraft()` on this path (i.e., the test does not call it),
  so the draft survives.

The existing `TodoEditStateTests.swift` cases that survive the refactor are
migrated into this file; the rest are deleted. The helper is parameterized
so tests cover both `Target = UUID` and `Target = TabTodoEditTarget`.

### Test harness registration (`tests/TestHarness.swift`)

`tests/TestHarness.swift:32` currently calls `todoEditStateTests()`. As an
explicit plan step, that call site is replaced with `todoPopoverStateTests()`
so the new suite actually runs. Deleting `TodoEditStateTests.swift` without
updating this line breaks compilation; updating it without adding the new
call lets the new tests compile but never execute under `just test`.

### Test compile list (`test.sh`)

`test.sh:35` explicitly compiles `app/TodoEditState.swift`. As an explicit
plan step, that entry is replaced with `app/TodoPopoverState.swift`. The
existing entry for `app/TodoInputCommand.swift` on `test.sh:36` is unchanged.
Without this step the pure-test target fails to compile (`TodoPopoverState`
unresolved) or silently keeps building against the deleted helper.

### UI tests (`tests-ui/TodoInputViewTests.swift`)

The three focus-hook tests (`programmatic focus...`, `mouse-down on
unfocused...`, `mouse-down on already focused...`) are deleted alongside
`onTextViewMouseDownAcquireFocus`. They are replaced with two mandatory
tests covering the new configurable visible-line-count surface:

- Default `TodoInputView()` reports the existing compact `inputHeight`
  (three lines of `inputFont` plus `inputInsetY * 2`).
- A `TodoInputView` constructed with the larger edit-mode line count reports
  an `inputHeight` strictly greater than the default and equal to
  `lineHeight * N + inset * 2` for that count.

### Commands

- `just test`
- `just test-ui`
- `just build`

## Manual Verification

- Create a multiline todo from the bottom compose field using `Shift+Enter`.
- Confirm rows still show compact one-line summaries while preserving full text
  for editing.
- Open edit mode with `Enter` and double-click.
- Confirm list and compose field are hidden in edit mode.
- Confirm `Shift+Enter`, `Enter`, `Esc`, Save, Cancel, and empty-save rejection
  work.
- Confirm `Tab` / `Shift+Tab` in edit mode traverse focus between the editor,
  Save, and Cancel button without submitting or cancelling.
- Confirm `Tab` from the compose field moves focus into the list (and
  `Shift+Tab` from the list returns focus to compose) without submitting or
  cancelling.
- Confirm `Cmd+N` from edit mode saves then focuses compose, unless the edit is
  empty.
- Confirm delete, toggle, reorder, and tab-popover bucket moves still work from
  list mode.
- Confirm pane-rollup todo edits in the tab popover save to the correct pane
  item.

## Assumptions

- Edit mode does not expose done/delete controls; those remain list-mode actions.
- The compose draft is preserved while moving around list selection.
- Empty edit save is invalid rather than deleting or canceling the todo.
- The implementation should favor deleting obsolete preview-mode code over
  adapting it.
