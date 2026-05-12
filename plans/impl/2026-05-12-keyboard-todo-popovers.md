# Keyboard-driven to-do popovers

## Context

The pane and tab to-do popovers are mouse-first today: clicking a row
enters edit mode, drag-and-drop reorders, the "Clear completed" button
is click-only, and toggling done requires hitting the checkbox. With the
new Cmd+' / Cmd+Shift+' hotkeys, opening the popover is keyboard-driven,
but everything *inside* still requires the mouse.

Goal: make the popovers fully operable without leaving the keyboard.
Add a vim-flavored interaction model (j/k nav, Tab-cycle, Cmd+Enter to
commit) plus a couple of macOS-native gestures (Cmd+Backspace to delete,
Cmd+N to focus the input). Also extend the tab popover to allow
*editing* pane rollup items in place — they're currently read-only.

No Msg / Update / Effect / Model changes are needed. Every CRUD op
already has a Msg (add, edit, toggle done, delete, reorder,
clear-completed) for both pane and tab scopes. This is purely
view-layer key plumbing and a small reshape of the tab popover's
rollup-section behavior.

## Focus model

Three modes. The bottom input field is **always populated** to reflect
the active mode; the distinction between "selected" and "actively
editing" is purely *who's first responder* plus the visibility of
the "Editing" hint strip.

| State | Field text | Field is first responder | "Editing" hint |
|---|---|---|---|
| **A. Input (compose new)** | `composeDraft` (per-popover-session string, lives on the view controller) | yes | no |
| **B. List, row N selected** | row N's stored text (live preview) | no — table is first responder | no |
| **C. Edit, editing row N** | edit-in-progress | yes | yes |

Selection changes (j/k, arrows, mouse click) **populate the field**
with the new row's text but do **not** transfer first responder. The
field becomes a live preview in mode B; pressing Tab or Enter on the
selected row is what shifts focus into the already-populated field
to actually edit it. This intentionally replaces the current
selection-enters-edit behavior in `TodoPopoverView.swift:237` and
`TabTodoPopoverView.swift:345`, and the unconditional
`makeFirstResponder(addInput.textView)` at
`TabTodoPopoverView.swift:217-220` / the pane equivalent.

### View-local state

Two new view-controller fields beyond the existing `editState` /
`TabTodoEditTarget`:

- `composeDraft: String = ""` — what the user has typed in mode A
  but not yet committed. Kept live (`textView.textDidChange` writes
  to it whenever mode A is active) so leaving and re-entering mode A
  restores the in-progress text.
- The table's `selectedRow` is **not cleared** when leaving mode B
  for mode A. Defocusing the table dims the selection visually
  (NSTableView native behavior) but `selectedRow` persists, so
  Esc-from-A or any later focus return restores the same row.

### Default on open

- Selectable items present → **mode B, first selectable row selected**.
- No selectable items → **mode A, input focused**.

"Selectable" means `tableView(_:shouldSelectRow:)` returns true —
which (see Implementation) returns false for section header rows in
the tab popover. The pane popover is flat, so its first row is
trivially selectable.

## Key map

| Key | A. Input | B. List | C. Edit |
|---|---|---|---|
| `j` / `↓` / `k` / `↑` | literal text | move selection — target computed via `nextSelectableRow(...)`, then `selectRowIndexes(...)` + `scrollRowToVisible(...)`; headers skipped; no wrap; field re-populates with new row's text | literal text |
| `Tab` | → B (row currently bound to input, else first selectable) | → C (focus input; input is already populated) | save, → B on edited row |
| `Shift+Tab` | no-op | → A via `focusComposeInput()` (defocus table, set input to `composeDraft`, focus input; `selectedRow` retained for later Esc restore) | cancel, → B on edited row |
| `Enter` | newline | → C (focus the already-populated input) | newline |
| `Cmd+Return` | save new, → B on new row | (no-op) | save edit, → B on edited row |
| `Esc` | → B (defocus input; selection restored) | close popover | 1st: cancel, → B; 2nd: close |
| `Space` | literal | toggle done on selected row (selection stays; field text unchanged) | literal |
| `Cmd+Backspace` | native `deleteToBeginningOfLine:` (NOT swallowed by popover) | delete row → next selectable (or prev if last); field re-populates with new selected row | native `deleteToBeginningOfLine:` (NOT swallowed) |
| `Shift+J` / `Shift+K` | literal `J` / `K` | reorder down / up (no wrap; bounded by section in tab popover) | literal |
| `Cmd+N` | no-op (already in input) | → A via `focusComposeInput()` | → A via `saveEditThenFocusCompose()` (commits the in-progress edit first) |

Notes:

- `Shift+J`/`Shift+K` only matter in mode B; in input/edit they're
  literal capitals, which is exactly what users would expect.
- `Cmd+N` is the global "New Group" shortcut today
  (`AppDelegate.swift:267`). Inside an open popover, the popover's
  `performKeyEquivalent` claims it before AppKit routes it to the
  menu — known context-sensitive override. No menu change.
- `Cmd+Backspace` in NSTextView is `deleteToBeginningOfLine:`, NOT
  word-delete (which is `Option+Backspace`). The popover's
  `performKeyEquivalent` must return `false` for `Cmd+Backspace`
  whenever the table is **not** first responder so the chord falls
  through to NSTextView's native handling.

## Tab popover specifics

Pane rollup rows become **fully editable** from the tab popover. j/k
traverses them; Space/Tab/Cmd+Backspace/Shift+J|K all work the same
as on tab rows. Two behavioral differences from the pane popover:

### Scoped edit target

The current `editState.editingTodoId: UUID?` is scope-blind, and
`submitField()` in `TabTodoPopoverView.swift:259-270` unconditionally
dispatches `.editTabTodoText` while `rebuildRows()` at line 222-247
only checks deletion against `tabItems`. Editing a pane row under
that scheme would either dispatch to the wrong scope or be canceled
as "deleted" on every rebuild.

Replace the scope-blind id with a view-local target:

```swift
enum TabTodoEditTarget: Equatable {
    case tab(todoId: UUID)
    case pane(paneId: PaneId, todoId: UUID)
}
```

Route all five edit-mode code paths through that target:

1. **Enter edit** — populate target with `.tab(...)` or `.pane(...)`
   based on the selected row's enum case.
2. **Submit** (`submitField()`) — dispatch `.editTabTodoText` for
   `.tab`, `.editTodoText(paneId:, ...)` for `.pane`.
3. **Cancel** (Esc / Shift+Tab) — restore draft, clear target.
4. **Dirty-switch autosave** — if the user starts editing row A,
   types changes, then navigates to row B and presses Tab, the
   existing flow needs to autosave A using A's target (not B's).
5. **Rebuild reselection / deletion detection** —
   `editingTodoWasDeleted` must look up the right collection:
   tab.todos for `.tab` targets, `pane.todos` for `.pane` targets.
   Selection restoration must search the right row variant.

The pane popover (`TodoPopoverView.swift`) is single-scope and
doesn't need this enum — its existing `editingTodoId: UUID?` is
fine.

### Section-local index for reorder

`.reorderTabTodo(tabId:, todoId:, toIndex:)` expects `toIndex` to be
an index into the tab's `todos` array; `.reorderTodo(paneId:,
todoId:, toIndex:)` expects an index into that pane's `todos`
array. The table view sees flat row indices including headers and
multiple sections, so a table-row index is the wrong unit.

Helper to translate:

```swift
// Returns the index of `row` within its enclosing section's todo
// array, or nil if `row` is a header.
func sectionLocalIndex(of row: Int) -> Int?
```

Shift+J on row N computes `sectionLocalIndex(of: N+1)` (the
neighbor row's local index) for the destination, clamped to the
section's bounds. Reorder is contained to one section: Shift+J on
the last row of a pane section is a no-op (does NOT spill into the
next section or the tab list).

## Critical files

- `app/TodoPopoverView.swift` — pane popover. Owns `tableView`,
  `addInput` (a `TodoInputView` wrapping `NSTextView`), `editState`.
  Where most key wiring lands.
- `app/TabTodoPopoverView.swift` — tab popover. Same shape but with
  rollup sections (`buildRows()` at lines 96-113; `editingTodoWasDeleted`
  check at line 233; `submitField()` at lines 259-270; default-focus
  at lines 217-220). Needs the `TabTodoEditTarget` enum and pane-row
  dispatch.
- `app/TodoInputCommand.swift` — pure command classifier. Extended
  with `classifyListAction`, `firstSelectableRow`,
  `nextSelectableRow`, and `sectionLocalIndex`; existing
  `classifyInputAction` is reshaped (Enter, Tab, Backtab cases).
- `tests/UpdateTodoTests.swift:291-336` — existing classifier tests;
  Enter/Tab/Backtab cases rewritten. New `classifyListAction` and
  `sectionLocalIndex` tests added inside the existing `todoTests()`
  function (the harness in `tests/TestHarness.swift` only invokes
  test functions it knows by name).
- `app/Msg.swift:136-156` — existing Msgs for both scopes (no change).
- `app/Update.swift:1196-1235` — existing toggle / mutual-exclusion
  logic (no change).
- `app/AppDelegate.swift:560-568` — existing `openTodo` /
  `toggleTabTodoPopover` actions (no change).

## Implementation approach

Architectural shape: lean on AppKit's built-in mechanisms wherever
they exist (header skipping, arrow navigation, Esc, Tab key-view
loop) and keep the custom layer as thin glue. Pure helpers carry
only what AppKit doesn't give us.

### Lean-on inventory (what AppKit gives us for free)

| Concern | AppKit mechanism | What we add |
|---|---|---|
| Group-row visual styling for headers | `tableView(_:isGroupRow:)` returning `true` for header rows | The delegate method |
| Headers can't be selected by mouse click | `tableView(_:shouldSelectRow:)` returning `false` for headers | The delegate method |
| Header skipping in keyboard nav | **Not contract-guaranteed.** Apple docs `shouldSelectRow:` as selection permission and `isGroupRow:` as styling — neither promises that `moveDown:` / `moveUp:` will skip vetoed rows | Pure `nextSelectableRow(...)` helper; our `keyDown` for `j`/`k`/`↑`/`↓` calls it explicitly and sets the new selection |
| `Esc` handling | `NSResponder.cancelOperation(_:)` walks the responder chain | Implement `cancelOperation(_:)` per responder layer |
| Tab cycling input ↔ list | **Insufficient on its own.** `nextKeyView` only moves first responder; mode A → B requires also seeding selection + populating preview, and mode B → A requires also restoring `composeDraft`. The key-view loop doesn't carry that state | Explicit `focusListFromInput()` / `focusComposeInput()` helpers (see "View-side wiring"); intercept `Tab`/`Shift+Tab` in both the table subclass and the input delegate and route through these |
| Multiline newline on `Enter` | NSTextView's native `insertNewline:` | Nothing; don't override `Enter` |
| `Cmd+Backspace` in text view | NSTextView's `deleteToBeginningOfLine:` | Make sure `performKeyEquivalent` does **not** consume it while the text view is first responder |

### Key-event routing

AppKit dispatches Cmd-key chords through `performKeyEquivalent(with:)`
walking the view hierarchy *before* falling back to `keyDown(with:)`
on the first responder (Apple's "Cocoa Event Handling Guide" /
`NSResponder` docs). `Cmd+N` is the global "New Group" shortcut
(`AppDelegate.swift:267`), so the popover *must* claim it before
AppKit routes it to the menu.

Split key handling along three boundaries:

1. **`performKeyEquivalent(with:)` on the popover's root view** —
   intercepts Cmd-chords. Disposition depends on current mode:
   - `Cmd+Return`: always consume. Mode A → `addTodoThenReturnToList()`.
     Mode C → `saveEditThenReturnToList()`. Mode B → no-op (the
     key map shows `(no-op)` in mode B).
   - `Cmd+N`: always consume. Mode A → no-op (already in input).
     Mode B → `focusComposeInput()`. Mode C →
     `saveEditThenFocusCompose()`.
   - `Cmd+Backspace`: **only consume when the table is first
     responder** (mode B), and only then to delete the selected
     row. Otherwise return `false` so NSTextView's native
     `deleteToBeginningOfLine:` fires unchanged.
   - All other chords: return `false`.
2. **`keyDown(with:)` on an NSTableView subclass** — handles
   non-command keys when the table is first responder:
   `j` / `↓` / `k` / `↑` (compute next index via
   `nextSelectableRow(...)`, set selection, `scrollRowToVisible`),
   `Tab` (call `enterEditForSelectedRow()`), `Enter` (same),
   `Space` (toggle done on selected row), `Shift+J` / `Shift+K`
   (reorder), `Shift+Tab` (call `focusComposeInput()`). Anything
   not in that set calls `super`.
3. **Input text view (`TodoInputView`)** — implements
   `NSTextViewDelegate.textView(_:doCommandBy:)` for:
   - `insertTab(_:)` → if in mode C, call
     `saveEditThenReturnToList()`; if in mode A, call
     `focusListFromInput()` (seeds selection + populates preview).
   - `insertBacktab(_:)` → if in mode C, call
     `cancelEditAndReturnToList()`; if in mode A, no-op (mode A
     Shift+Tab is a no-op per the key map).
   Plain `Enter`, plain `Backspace`, `Cmd+Backspace`, and all
   literal typing flow through to native NSTextView behavior. The
   delegate also keeps `composeDraft` in sync via `textDidChange`
   whenever the controller is in mode A.
4. **`cancelOperation(_:)` (Esc)** — implemented on each layer.
   Always routes through the named helpers; never directly mutates
   first responder.
   - **Text view, mode C** (`editState` / `TabTodoEditTarget` is
     active): call `cancelEditAndReturnToList()`. This reverts
     `addInput.string` to the edited row's stored text, hides the
     hint, reselects the edited row, and makes the table first
     responder.
   - **Text view, mode A**: call `focusListFromInput(...)`. This
     preserves `composeDraft`, populates `addInput.string` from
     the selected row's stored text (or seeds selection via
     `firstSelectableRow(...)` if none was set), and makes the
     table first responder. Second Esc on the table closes the
     popover.
   - **Table view, mode B**: dispatch the popover-close Msg
     (`toggleTodoPopover` / `toggleTodoPopoverForTab` — these
     already exist and toggle off when called while the same
     popover is open).
   No global state machine, no Esc counter; the two-stage effect
   falls out of `cancelOperation` hopping between responders.

### Pure helpers (testable)

Extend `app/TodoInputCommand.swift` with three families:

```swift
/// Resolved command for a row-mode (mode B) keystroke. Computed from
/// pure inputs so it's unit-testable without AppKit.
enum ListAction: Equatable {
    case moveSelection(delta: Int)        // j/k/arrows
    case enterEdit                        // Tab, Enter
    case toggleDone                       // Space
    case deleteRow                        // Cmd+Backspace
    case reorder(delta: Int)              // Shift+J/K
    case focusInput                       // Cmd+N, Shift+Tab
    case unhandled
}

func classifyListAction(key: ListKey, modifiers: KeyModifiers) -> ListAction

/// First selectable row index in `rows`, or nil if none. Used for
/// open-time selection and for landing selection on input → list
/// transitions when no row was previously selected.
func firstSelectableRow<R>(in rows: [R], canSelect: (R) -> Bool) -> Int?

/// Next selectable row from `from` in direction `delta` (+1 or -1),
/// skipping rows where `canSelect` returns false. Returns nil if no
/// selectable row exists in that direction (no wrap).
func nextSelectableRow<R>(in rows: [R], from: Int, delta: Int,
                          canSelect: (R) -> Bool) -> Int?

/// Section-local index for tab-popover reorder. Returns nil for headers.
/// `sectionId(row)` is some Hashable that identifies the row's section
/// (e.g. nil for tab items, the paneId for pane items).
func sectionLocalIndex<R>(rows: [R], at: Int,
                          isHeader: (R) -> Bool,
                          sectionId: (R) -> AnyHashable?) -> Int?
```

Note: `Esc` isn't in `ListAction` — Esc is handled by
`cancelOperation(_:)` per responder, not classified.

The nav helpers (`firstSelectableRow`, `nextSelectableRow`) are
restored to the plan — relying on `moveDown:`/`moveUp:` to skip
non-selectable rows is undocumented behavior. With these helpers we
compute the target index ourselves, then call
`tableView.selectRowIndexes(...)` + `scrollRowToVisible(...)`.

### Updates to `classifyInputAction`

The current classifier (`TodoInputCommand.swift:29-47`) needs three
changes:

- `.enter` → **`.insertNewline`** (always; multiline is the new
  default).
- `.shiftEnter` → `.insertNewline` as well; the enum case is kept
  for backward compatibility but Cmd+Return is the new save chord
  (handled outside the classifier via `performKeyEquivalent`).
- `.tab` and `.backtab` → reshape:
  - `.tab` when `isEditing=true` → `.submit` (Tab from edit mode
    saves and returns to list; consumer calls
    `saveEditThenReturnToList()`).
  - `.tab` when `isEditing=false` → `.moveFocusForward` (mode A
    Tab; consumer calls `focusListFromInput(...)` — never
    `nextKeyView` / key-view loop, since the helper also seeds
    selection and populates the preview).
  - `.backtab` when `isEditing=true` → `.cancelEdit` (Shift+Tab
    from edit cancels and returns to list with the edited row
    reselected; consumer calls `cancelEditAndReturnToList()`).
  - `.backtab` when `isEditing=false` → `.unhandled` (mode A
    Shift+Tab is a no-op per key map).

### View-side wiring — named transitions

All mode-changing transitions go through small, named helpers on the
view controller. They are the only places that move first responder
or mutate `editState` / `composeDraft`.

5. **`focusListFromInput(seeding:)` (mode A → mode B).** Save the
   current `addInput.string` to `composeDraft` (`textDidChange`
   keeps this live, but write once more here for safety). If a
   row is already selected, keep it; otherwise select
   `firstSelectableRow(...)`. Set `addInput.string` to the selected
   row's stored text (the selection-changed hook in step 7 will do
   this automatically when selection actually changes, but we set
   it explicitly here for the "selection-unchanged" case).
   `makeFirstResponder(tableView)`. Called by: text-view delegate's
   `insertTab(_:)` when not editing; Esc from mode A (via
   `cancelOperation`).
6. **`focusComposeInput()` (mode B → mode A).** `selectedRow` is
   **not** cleared (defocusing the table is enough; selection
   visually dims, persists for later Esc restore). Set
   `addInput.string = composeDraft`. `makeFirstResponder(addInput.textView)`.
   Called by: table subclass's `Shift+Tab` keyDown; Cmd+N when not
   editing (via `performKeyEquivalent`).
7. **Selection-changed populates input (live preview).** In
   `tableViewSelectionDidChange(_:)`, replace today's
   `makeFirstResponder(addInput.textView)` + edit-mode entry
   (`TodoPopoverView.swift:237`, `TabTodoPopoverView.swift:345`)
   with: read the newly-selected row, look up its current text, set
   `addInput.string` to that text, and do nothing else — no
   responder change, no `editState` mutation, no hint label. The
   field is a passive preview in mode B.
8. **`enterEditForSelectedRow()` (mode B → mode C).** Sets
   `editState` (or the new `TabTodoEditTarget`) based on the
   currently-selected row's enum case. Shows the edit hint.
   `makeFirstResponder(addInput.textView)`. The input is already
   populated (from step 7), so no text copy is needed. Called by:
   table keyDown for `Tab` / `Enter`; double-click handler.
9. **`saveEditThenReturnToList()` (mode C → mode B, commit).**
   Reads `addInput.string`, dispatches the appropriate edit Msg
   per the `editState` / `TabTodoEditTarget` scope, clears the
   target, hides the hint, sets `addInput.string` to the saved
   text (so live-preview is in sync), selects the edited row,
   `makeFirstResponder(tableView)`. Replaces the current
   `tableView.deselectAll(nil)` at `TabTodoPopoverView.swift:255`.
   Called by: Cmd+Return in mode C (via `performKeyEquivalent`);
   `insertTab(_:)` in mode C.
9a. **`addTodoThenReturnToList()` (mode A → mode B, add).**
    Reads `addInput.string`, trims whitespace, dispatches the
    appropriate add Msg (`addTodo(paneId:, text:)` for the pane
    popover; `addTabTodo(tabId:, text:)` for the tab popover —
    tab popover always adds to the tab section, not to a pane
    rollup), clears `composeDraft` and `addInput.string`, rebuilds
    rows, locates the newly-appended row by id, selects it
    (which triggers the live-preview hook to repopulate the
    input), and `makeFirstResponder(tableView)`. If the trimmed
    text is empty, no-op (don't add an empty row, don't change
    focus). Called by: Cmd+Return in mode A (via
    `performKeyEquivalent`). Replaces the in-place add behavior
    of the current `submitField()` at
    `TodoPopoverView.swift` and `TabTodoPopoverView.swift:259-270`
    for the keyboard path; mouse-driven add via the existing
    button can continue using `submitField()` or migrate.
10. **`cancelEditAndReturnToList()` (mode C → mode B, revert).**
    Clears `editState` / target, hides the hint, sets
    `addInput.string` back to the edited row's stored text,
    selects that row, `makeFirstResponder(tableView)`. Called by:
    text view's `cancelOperation(_:)` (Esc) in mode C;
    `insertBacktab(_:)` in mode C.
11. **`saveEditThenFocusCompose()` (mode C → mode A, "Cmd+N saves
    first").** Calls `saveEditThenReturnToList()` to commit the
    edit, then immediately calls `focusComposeInput()`. Single
    named atom so the key map's "Cmd+N from C saves edit before
    going to A" contract is impossible to violate at the call
    site. Called by: Cmd+N in mode C (via `performKeyEquivalent`).
12. **Open-time focus.** Override `viewDidAppear()` to replace the
    current unconditional `makeFirstResponder(addInput.textView)`
    at `TabTodoPopoverView.swift:217-220` (and the equivalent in
    the pane popover). Compute
    `firstSelectableRow(in: rows, canSelect: { !isHeader($0) })`;
    if non-nil, select that row and `makeFirstResponder(tableView)`;
    if nil, `makeFirstResponder(addInput.textView)` (mode A with
    empty `composeDraft`).
13. **Tab popover edit target.** Replace `editState.editingTodoId:
    UUID?` with `TabTodoEditTarget` (see "Tab popover specifics").
    Route submit/cancel/dirty-switch/rebuild through it. The pane
    popover keeps its single-scope `editingTodoId`.
14. **Tab popover row dispatch.** When acting on the focused row,
    branch on the `TabTodoRow` enum case: tab-scoped Msg for
    `.tabItem`, pane-scoped Msg with `paneId` for `.paneItem`.
    Reorder uses `sectionLocalIndex(...)` to compute the
    destination inside the originating pane's `todos` array;
    section boundaries → no-op.
15. **Tab popover `shouldSelectRow:` allows `.paneItem`.** The
    delegate currently makes pane rows non-selectable so they
    appear read-only. Flip that: return `true` for `.tabItem` and
    `.paneItem`, `false` only for `.tabSectionHeader` and
    `.paneSectionHeader`. Also implement `isGroupRow:` returning
    `true` for headers (for the macOS group-row visual styling
    only — header skipping in keyboard nav is handled by our
    `nextSelectableRow` helper, not by relying on undocumented
    `moveDown:`/`moveUp:` behavior).
16. **Update the editing hint strip.** `editLabel.stringValue` from
    "Editing — Esc to cancel" to "Editing — Esc to cancel · ⌘⏎ to
    save" in both popovers.

## What is NOT changing

- `Msg.swift`, `Update.swift`, `Model.swift`, `Effect.swift`,
  `AppRuntime.swift` — no new Msgs, no new state.
- Drag-and-drop reorder — still works.
- The "Clear completed" button — stays clickable, no keyboard
  shortcut for v1.
- Cmd+' / Cmd+Shift+' global hotkeys — already wired by the prior
  commit (205b315).
- The tab popover's overall layout / sectioning — only dispatch
  behavior changes.

## Tests

The Msg layer is unchanged, so the existing Msg tests in
`tests/UpdateTodoTests.swift` and `tests/UpdateTabTodoTests.swift`
remain valid. The pure command classifier changes shape, and we
add coverage for one new helper (`sectionLocalIndex`).

All new tests go inside the existing `todoTests()` function in
`tests/UpdateTodoTests.swift` so the harness in `TestHarness.swift`
(which manually calls each test function) picks them up. A separate
file would compile but not run.

### Updates to existing `classifyInputAction` tests

`tests/UpdateTodoTests.swift:291-336`:

- `enter → submit` (291-294) → rewrite to `enter → insertNewline`
  (Cmd+Return is now the save chord; plain Enter is always newline).
- `shiftEnter → insertNewline` (296-299) → keep; behavior is the
  same.
- `tab → moveFocusForward` (324-327) → split:
  - `tab while editing → submit` (save edit, return to list; the
    consumer calls `saveEditThenReturnToList()`).
  - `tab while not editing → moveFocusForward` (mode A; the
    consumer calls `focusListFromInput(...)`, NOT `nextKeyView` —
    the helper seeds selection and populates the preview).
- `backtab → moveFocusBackward` (329-331) → replace with two cases:
  - `backtab while editing → cancelEdit` (Shift+Tab from mode C
    cancels and returns to list).
  - `backtab while not editing → unhandled` (mode A Shift+Tab
    no-op).
- `escape while editing → cancelEdit` / `escape while not editing →
  dismiss` (301-309) → keep, but note these are now consumed by
  `cancelOperation(_:)` at the view layer; the classifier output
  still reflects intent and tests intent.
- `backspace on empty field in edit mode → cancelEdit` (311-313)
  and the two paired cases (315-322) → keep. Cmd+Backspace is the
  primary delete-row gesture (mode B); plain Backspace on an empty
  edit-mode field as a fallback "cancel" is harmless.

### New tests for `classifyListAction`

Added inside `todoTests()`:

- `j`/`↓` → `moveSelection(delta: 1)`; `k`/`↑` → `moveSelection(delta: -1)`.
  *(Note: the runtime path resolves the target index via
  `nextSelectableRow(...)` and calls `selectRowIndexes(...)` +
  `scrollRowToVisible(...)` directly. The classifier exists for
  test surface + symmetry with other actions.)*
- `Tab` → `enterEdit`; `Enter` (no Cmd) → `enterEdit`.
- `Space` → `toggleDone`.
- `Cmd+Backspace` → `deleteRow`; plain `Backspace` → `unhandled`.
- `Shift+J` → `reorder(delta: 1)`; `Shift+K` → `reorder(delta: -1)`.
- `Cmd+N` → `focusInput`.
- Unmodified letters and digits → `unhandled` (no swallowing).
- `Esc` is **not** classified (handled by `cancelOperation(_:)`);
  no test for it.

### New tests for `firstSelectableRow` / `nextSelectableRow`

Added inside `todoTests()`:

- `firstSelectableRow`:
  - Empty list → `nil`.
  - All-non-selectable (e.g. all headers) → `nil`.
  - Header-then-items → returns the first item index, not 0.
  - Pure items (pane popover shape) → returns 0.
- `nextSelectableRow`:
  - From a selectable row, delta `+1` into a header → skips the
    header to the next item.
  - From a selectable row, delta `+1` past the last item → `nil`
    (no wrap).
  - Delta `-1` symmetric (skip headers in reverse; `nil` past the
    top).
  - Header-item-header-item layout (tab popover) → moves across
    section boundaries item-to-item, skipping every intervening
    header.

### New tests for `sectionLocalIndex`

Added inside `todoTests()`:

- Returns `nil` for header rows.
- For an in-section row, returns its 0-based position within that
  section's item run (not the global table-row index).
- Single-section table (pane popover shape) → equivalent to row
  index minus header offset.
- Multi-section table (tab popover shape: tab section + pane
  sections) → indices reset per section.
- Reorder destination clamp: in a 3-item pane section, computing
  the destination one slot past the last item returns the clamped
  in-section index (no spill into the next section).

### What we explicitly DON'T test

- First-responder transitions, label visibility, key-event delivery,
  `cancelOperation` behavior, `nextKeyView` chain — all AppKit, all
  manual-verification.

## Verification

Build and launch dev app: `just build-run`.

### Pane popover

1. **Open with items present:** focus a pane with several todos.
   Cmd+Shift+' → popover opens, row 0 selected (table is first
   responder, no caret in input). The input field shows row 0's
   text as a live preview; the "Editing" hint is **not** visible.
2. **j/k nav populates preview:** press j → row 1 selected, input
   field text updates to row 1's text. j again → row 2 + preview
   update. k, k → back to row 0. k on row 0 → no-op (no wrap).
   Throughout, focus stays on the table (no caret in input).
3. **Space toggle:** Space on row 1 → checkbox toggles, selection
   stays on row 1, row does not visually move, input preview text
   unchanged.
4. **Tab to edit, Cmd+Return to save:** with row 1 selected and
   input previewing row 1's text, press Tab → caret appears in
   input (input is now first responder), "Editing — Esc to
   cancel · ⌘⏎ to save" hint visible. Type a change, Cmd+Return →
   focus back to table, row 1 shows new text, row 1 still
   selected, input still shows row 1's (now-updated) text.
5. **Tab + Esc to cancel:** Tab on row 2 → edit mode. Type junk,
   Esc → focus back to table, input reverts to row 2's stored
   text, row 2 unchanged.
6. **Cmd+Backspace delete:** Cmd+Backspace on row 1 → row removed,
   what was row 2 is now row 1 and selected, input preview updates
   to the new row 1's text. Cmd+Backspace on the last row →
   previous row selected (preview updates).
7. **Shift+J / Shift+K reorder:** Shift+J on a middle row → moves
   down one position, selection follows. Shift+K → back up.
   Shift+J on bottom row → no-op. Input preview tracks the moved
   row's text (which doesn't change, since reorder doesn't edit).
8. **Cmd+N preserves compose draft:** from list mode (row 2
   selected), Cmd+N → input focused (mode A), input shows the
   `composeDraft` (initially empty). Type "buy milk", press Esc →
   back to table, row 2 still highlighted (selection persisted
   through the visit to mode A), input shows row 2's text again.
   Press Cmd+N again → input focused with "buy milk" restored from
   `composeDraft`. Cmd+Return → row added at the end with text
   "buy milk", selected; `composeDraft` is cleared.
9. **Cmd+N from edit mode saves first:** Tab on row 3 to enter
   edit mode, change "task three" to "task three updated",
   Cmd+N → `saveEditThenFocusCompose()` fires: row 3 is updated
   on disk (verify via toggle popover closed/reopen), then mode A
   is entered with `composeDraft` populating the input.
10. **Two-stage Esc from input:** with row 2 selected (mode B,
    preview shown), Cmd+N → mode A. Esc → focus back to table,
    row 2 highlighted (`selectedRow` was never cleared, just
    dimmed), input shows row 2's text again. Esc again →
    popover closes.
11. **Empty list open:** open popover on a pane with no todos →
    input focused, no row selected (no preview possible). Type,
    Cmd+Return → list now has 1 row, selected, table first
    responder, input shows that row's text as preview.
12. **Cmd+Backspace inside the input does NOT delete a row:**
    in mode A or C, Cmd+Backspace fires NSTextView's native
    `deleteToBeginningOfLine:` — deletes from cursor to start of
    line within the input. No row is removed.
13. **Mouse still works:** click a row → mode B on that row
    (selection + preview, no edit). Double-click → mode C
    (edit). Drag-reorder unchanged.

### Tab popover

Repeat 1-13 against the tab popover (Cmd+'), then specifically:

14. **Open lands on first selectable row, not header.** Tab popover
    opens with at least one tab item present → `firstSelectableRow(...)`
    returns the first tab item's index, not the `.tabSectionHeader`
    row above it. Open with no tab items but pane items →
    `firstSelectableRow(...)` returns the first pane item, skipping
    both headers. ↑/↓ and j/k navigation skip header rows via the
    explicit `nextSelectableRow(...)` lookup — selection never lands
    on or flickers through a `.tabSectionHeader` or
    `.paneSectionHeader` row.
15. **Pane rollup edit:** with a pane that has todos, open tab
    popover. j/k lands on a pane rollup row, input previews that
    pane todo's text. Tab → edit, change text, Cmd+Return → pane
    todo text updated (verify by opening the pane popover for that
    pane and seeing the change).
16. **Pane rollup toggle:** Space on a pane rollup row → that pane's
    todo's done state toggles (verify via pane popover).
17. **Pane rollup delete:** Cmd+Backspace on a pane rollup row →
    pane todo removed (verify via pane popover).
18. **Pane rollup reorder stays within section:** Shift+J on a pane
    item only moves within its own pane's section; never crosses
    into the tab-list section or another pane's section. Shift+J on
    the last item of a section is a no-op.
19. **Edit-target survives rebuild:** start editing a pane rollup
    row, then toggle done on a tab item via mouse (forcing a
    rebuild). The pane edit must remain active with its target row
    re-selected, not be canceled-as-deleted.
20. **Headers are group-styled:** header rows render with the
    macOS group-row visual style (slightly inset, bold, system
    background) — confirms `isGroupRow:` is returning true for
    them.

### Regression

21. `just test` — existing Msg tests still pass; the rewritten
    `classifyInputAction` tests pass; the new `classifyListAction`
    and `sectionLocalIndex` tests pass (all inside `todoTests()`
    in `tests/UpdateTodoTests.swift`).
22. Click-to-edit on rows still works (double-click → mode C).
23. Drag-to-reorder still works (and now coexists with Shift+J/K).
24. "Clear completed" button still works.
25. Other Cmd-chords in the input still work natively:
    `Cmd+A` (select all), `Cmd+C` / `Cmd+V`, `Option+Backspace`
    (word-delete). The popover root's `performKeyEquivalent`
    returns `false` for these.
