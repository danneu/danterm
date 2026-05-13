# Show "Editing" info line when input is mouse-focused on a row preview

## Context

In both todo popovers (tab-level and pane-level), double-clicking an existing
todo enters edit mode: the input field is populated with the item's text, the
info line "Editing - Esc to cancel - Enter to save" appears above the field,
and submitting the field edits the row.

Single-clicking a row also populates the field with the row's text (preview),
but if the user then clicks the field to focus it manually, no info line
appears and submitting creates a NEW todo instead of editing the selected one.
The visible state looks identical to edit mode, but the actual behavior
diverges -- a UX trap.

Desired behavior: when the user mouse-clicks into the input and that click
makes the field the first responder while the field is currently displaying
the selected row's preview, enter full edit mode for that row -- set
`editTarget`/`editingTodoId`, show the info line. Submitting will then edit
the row, matching the double-click flow.

Programmatic focus paths (Cmd+N, "New" button, focusing the input after a
save) must NOT trigger this. Mouse focus after a compose path that leaves a
stale row selected (e.g. Cmd+N or `addTodoAndStayInCompose`, both of which
keep the prior row selected but replace the field with compose/empty text)
must also NOT promote -- the field no longer mirrors the row.

## Approach

Two pieces:

1. **Mouse-acquired-focus hook** on the input text view (distinguishes a
   real click from programmatic `makeFirstResponder`).
2. **Explicit preview-mode marker** on each popover controller -- set only
   when `addInput.string` is assigned from a selected row's text, cleared
   on every compose/empty/typing path. Promotion to edit mode requires
   both `(mouse-acquired focus)` AND `(preview mode active)`.

### 1. `app/TodoInputView.swift`

- Add a private `TodoInputTextView: NSTextView` subclass that overrides
  `mouseDown(with:)`. It records whether the view was already first
  responder before `super.mouseDown(...)`, then calls
  `onMouseDownAcquireFocus` only when the mouseDown transitioned the view
  from not-focused to focused.
- Instantiate `textView` as `TodoInputTextView` (keep the public property
  type as `NSTextView` so existing callers are unaffected).
- Expose `var onTextViewMouseDownAcquireFocus: (() -> Void)?` on
  `TodoInputView`. The subclass forwards into it.

### 2. `app/TabTodoPopoverView.swift`

Add controller state:

```swift
// True iff addInput's current contents reflect the selected row's text
// (i.e. were assigned from a row preview). Gates promotion from
// passive preview to active edit on mouse-acquired focus.
private var isPreviewingSelectedRow = false
```

In `loadView()` (alongside `addInput.textView.delegate = self`):

```swift
addInput.onTextViewMouseDownAcquireFocus = { [weak self] in
    self?.enterEditFromInputClick()
}
```

Add:

```swift
// Mouse click acquired focus on the input while it was showing a row
// preview. Promote the preview into a real edit so submit will edit
// the row (and the info line reflects that).
private func enterEditFromInputClick() {
    guard !isEditing else { return }
    guard isPreviewingSelectedRow else { return }
    guard let target = selectedEditTarget() else { return }
    editTarget = target
    editLabel.isHidden = false
}
```

Set `isPreviewingSelectedRow = true` immediately after every
`addInput.string = <row text>` assignment:

- `populateInputFromSelection()` -- after `addInput.string = text`.
- `tableViewSelectionDidChange(_:)` -- both branches that assign
  `addInput.string = newText`.
- `saveEditThenReturnToList()` -- after `addInput.string = text` (the
  field now shows the saved row's text).

Set `isPreviewingSelectedRow = false` in every path that puts non-preview
content in the field:

- `focusComposeInput()` -- after `addInput.string = composeDraft`.
- `addTodoAndStayInCompose()` -- after `addInput.string = ""`.
- `enterEditForSelectedRow()` -- after `addInput.string = item.text`
  (we're transitioning into active edit, not passive preview).
- `textDidChange(_:)` -- when the user types in the field (preview by
  definition mirrors the row; user keystrokes diverge from it).

**Maintain the marker across `rebuildRows()`** so it can't survive a
row-removal that leaves stale text in the field (delete button, Clear
completed, drag-out moves, etc.) but also can't clobber a deliberate
compose path that called `rebuildRows()` from an already-cleared marker
(e.g. `addTodoAndStayInCompose()`). The rebuild must distinguish
"preview was active before this rebuild" from "a row happens to still be
selected." Snapshot the marker at entry, then reset it:

```swift
let wasPreviewingSelectedRow = isPreviewingSelectedRow
isPreviewingSelectedRow = false
```

In the existing post-reload non-editing branch where `selectedTarget`
still resolves to a new index, after `selectRowIndexes(...)` call
`populateInputFromSelection()` only when `wasPreviewingSelectedRow` was
true. That helper re-assigns `addInput.string = item.text` and sets the
marker back to true, keeping field and marker in sync across reorders /
done-toggles / partial deletes. When `wasPreviewingSelectedRow` was
false (the rebuild was triggered from compose, e.g.
`addTodoAndStayInCompose()` cleared the marker just before calling
`rebuildRows()`), the surviving selection is left visually selected but
the field is NOT repopulated, so the compose-empty state and
`marker = false` are preserved.

If `selectedTarget` no longer resolves, the marker remains false (the
field may show stale text, but a later mouse-acquired focus will not
promote). The was-editing branches are unaffected: the `isEditing` guard
in `enterEditFromInputClick()` already suppresses promotion while
editing, and the existing `saveEdit...` / `cancelEdit...` exits
re-establish the marker through their existing `addInput.string` /
`populateInputFromSelection()` calls.

Notes:
- We do not reassign `addInput.string` or call `selectAll(nil)` inside
  `enterEditFromInputClick()` -- the field already shows the row text
  (gated by the marker), so the caret position from the click is
  preserved.
- Existing flows (selection change auto-save, Esc cancel, double-click
  enter-edit) remain unchanged; the marker is purely additive.

### 3. `app/TodoPopoverView.swift`

Same shape, mirroring the pane popover's existing edit assignments:

```swift
private var isPreviewingSelectedRow = false
```

Wire the callback in `loadView()`:

```swift
addInput.onTextViewMouseDownAcquireFocus = { [weak self] in
    self?.enterEditFromInputClick()
}
```

Add:

```swift
private func enterEditFromInputClick() {
    guard !isEditing else { return }
    guard isPreviewingSelectedRow else { return }
    guard let item = selectedTodo() else { return }
    editState.editingTodoId = item.id
    editLabel.isHidden = false
}
```

Mark `isPreviewingSelectedRow = true` after row-text assignments in:
`populateInputFromSelection()`, both branches of
`tableViewSelectionDidChange(_:)`, `saveEditThenReturnToList()`.

Mark `isPreviewingSelectedRow = false` in:
`focusComposeInput()`, `addTodoAndStayInCompose()`,
`enterEditForSelectedRow()`, `textDidChange(_:)`.

In `rebuildRows()`, snapshot `wasPreviewingSelectedRow =
isPreviewingSelectedRow` at entry and reset the marker to false. In the
existing not-editing branch that reselects a still-resolvable id, add a
`populateInputFromSelection()` call after `selectRowIndexes(...)` only
when `wasPreviewingSelectedRow` was true (same shape as the tab
popover's `rebuildRows()` change). The was-editing branches re-establish
the marker through their existing exits.

(Mirroring the existing `editState.editingTodoId` direct-assignment
style; we intentionally bypass `editState.beginEditing` since the
existing `enterEditForSelectedRow` also bypasses it.)

## Why this is the right shape

- **Mouse-only hook** cleanly distinguishes user click from programmatic
  focus without flags on the focus call sites.
- **Transition guard** (`!wasFirstResponder && nowFirstResponder`)
  prevents re-triggering when the user clicks the already-focused field.
- **Preview marker** is the explicit truth about "the field currently
  mirrors a row." It is set exactly where row text is assigned and
  cleared exactly where compose / empty / user-typed content enters the
  field. This closes the failure modes the review flagged:
  - After `Cmd+N`, marker = false even though the row remains selected.
  - After `addTodoAndStayInCompose`, marker = false (field empty).
  - After the user types in compose, marker = false.
  - After a row is removed by delete / Clear completed / drag-out,
    `rebuildRows()` clears the marker by default and only re-sets it
    via `populateInputFromSelection()` when the prior target still
    resolves to a row AND the marker was true at rebuild entry
    (so a compose-initiated rebuild like `addTodoAndStayInCompose`
    never clobbers the field with stale row text).
- **No new abstractions** beyond a single bool per controller.

## Critical files

- `app/TodoInputView.swift` -- `TodoInputTextView` subclass + callback
  property.
- `app/TabTodoPopoverView.swift` -- `isPreviewingSelectedRow` state, set
  and clear sites, wire callback, add `enterEditFromInputClick()`.
- `app/TodoPopoverView.swift` -- same pattern as tab popover.
- `tests-ui/TodoInputViewTests.swift` (new) -- regression coverage for
  the mouse-acquire hook (see below).
- `test-ui.sh` -- add `TodoInputView.swift` and
  `TodoInputViewTests.swift` to the compile list; compile/link the local
  `DanTermProtocol` module first (matching `test.sh`, because the UI
  script already compiles `Msg.swift`); add the new test function call in
  `tests-ui/PaneSplitViewTests.swift`'s `@main` (where
  `paneSplitViewTests()` / `sidebarBadgeTests()` are dispatched).

## New test: `tests-ui/TodoInputViewTests.swift`

Pure AppKit, no GhosttyKit. Builds a `TodoInputView` and a host window so
the text view can become first responder. Cases:

1. **Programmatic `makeFirstResponder` does NOT fire the callback.**
   Set `onTextViewMouseDownAcquireFocus` to increment a counter; call
   `window.makeFirstResponder(input.textView)`; assert counter == 0.

2. **Synthesized left-mouse-down on the unfocused text view DOES fire
   the callback exactly once.** Force-resign first responder, then post
   `NSEvent.mouseEvent(.leftMouseDown, ...)` to the text view via
   `mouseDown(with:)`; assert counter == 1.

3. **Mouse-down on the already-focused text view does NOT fire the
   callback.** Make the text view first responder programmatically,
   then dispatch a mouseDown; assert counter unchanged.

Verifies the *hook contract* (mouse-acquired-only). Controller-level
preview/edit promotion is observable through these contracts plus the
existing controller logic; integration is covered manually by the
verification steps below.

Wire-up: append `todoInputViewTests()` to the `@main` runner in
`PaneSplitViewTests.swift` alongside the existing test entries, and add
`TodoInputView.swift` + `TodoInputViewTests.swift` to `test-ui.sh`'s
`swiftc` argument list.

## Verification

1. `just test` -- pure tests still pass.
2. `just test-ui` -- new `TodoInputView` tests pass; existing UI tests
   still pass.
3. `just build` -- compiles cleanly.
4. `just build-run` and manually verify in the Tab todo popover:
   - **Single-click an existing row, then click the input field**:
     info line "Editing - Esc to cancel - Enter to save" appears.
     Modify text, press Enter -> the existing row is updated (not a
     new row created).
   - **Esc from the field** -> info line hides, list focuses, item
     unchanged.
   - **Cmd+N with a row selected** -> info line stays hidden, field
     shows compose draft, Enter creates a new todo. Clicking the field
     after focus has left it (e.g. clicking a row that re-fires
     selectionDidChange and re-populates the field, or clicking the
     field after Cmd+N + tab-out) does the right thing in each case:
     compose if the field shows compose text, edit if the field shows
     row text.
   - **After `addTodoAndStayInCompose` (Cmd+Enter from compose)**:
     field clears, row selection is preserved, and the field is NOT
     refilled with that row's text by the post-add rebuild. Click the
     field again -> NO promotion to edit mode (marker is false). Field
     stays in compose; typing + Enter creates another new todo.
   - **Tab from list to field** (`focusComposeInput`) -> info line
     stays hidden (programmatic focus + marker false).
   - **Click the field while already focused** (mid-compose) -> no
     state change.
   - **Double-click a row** -> existing behavior unchanged (info line,
     selectAll, Enter saves edit).
   - **Delete the previewed row via its X button**: select row A so the
     field shows A's text (preview), then click the X on row A. After
     the rebuild the field may still contain A's stale text, but
     clicking back into the field must NOT promote to edit mode (marker
     cleared by `rebuildRows()`).
   - **Clear completed while previewing a completed row**: select a
     completed row so the field shows its text, then click "Clear
     completed". Same expectation: clicking the field after the rebuild
     does not promote.
   - **Reorder/drag with a preview active**: previewed row stays
     selected at its new index; clicking the field still promotes to
     edit mode for that same row (marker is re-set via
     `populateInputFromSelection()` in the rebuild path).
5. Repeat the manual checks in a pane-level todo popover.
