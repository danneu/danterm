# Promote TabTodoPopoverView into the tests-ui harness

## Context

The pane-context-menu unification (8da7613) established the promotion pattern:
compile a real `app/` view into the GhosttyKit-free UI harness (`test-ui.sh`),
back it with the shim `AppRuntime` in `tests-ui/SidebarViewTestShim.swift`, and
pin its behavior with `uiTest` cases asserting on `runtime.sentMessages`.

`app/TabTodoPopoverView.swift` is the richest untested view: row checkboxes,
inline editing with save/cancel, delete, clear-completed, compose submit, and
projection-driven reconcile (e7d4576 "reconcile open popover contents" is
pinned nowhere). A feasibility check confirmed the file imports only Cocoa,
its full dependency closure is GhosttyKit-free, and every `Msg` it sends is
id-scoped (tabId fixed at init, paneIds carried in row payloads -- no ambient
selected-state resolution). Production code needs zero changes; this is a
pure test-infrastructure addition.

Scope decisions (user-confirmed):
- Drag/drop: test `pasteboardWriterForRow` payload encoding only; skip
  `acceptDrop`/`validateDrop` (would need a hand-rolled `NSDraggingInfo`
  fake; drop resolution is already core-tested via `resolveTabTodoDropTarget`).
- Keyboard: minimal `NSEvent` synthesis -- only what's needed to enter edit
  mode and submit compose. Full key surface (`classifyListAction` /
  `classifyInputAction`) is already core-tested.

## Phase 1 -- Harness enablement

Gate: `just test-ui` compiles and all existing suites stay green. No test
cases yet.

### 1a. Extend the shim (`tests-ui/SidebarViewTestShim.swift`)

Add to the test `AppRuntime` (mirrors the inert `startPaneDrag` family):

```swift
var tabTodoPopover: NSPopover?              // read by showShortcutHelpPopover
var focusedPaneSurfaces: [PaneId] = []      // recorder for assertions

func focusPaneSurface(_ paneId: PaneId) {
    focusedPaneSurfaces.append(paneId)
}
```

Update the file-header comment (it currently says "SidebarView and
PaneWrapperView") to mention TabTodoPopoverView.

### 1b. Extend the compile list (`test-ui.sh`)

Add three core files (all pure -- already covered by `core-purity-lint.sh`),
grouped with the existing core files:

- `lib/DanTermCore/Sources/DanTermCore/TodoPopoverState.swift` -- `TodoPopoverState`, `TodoPopoverSaveResult`
- `lib/DanTermCore/Sources/DanTermCore/TodoInputCommand.swift` -- `classifyListAction`, `classifyInputAction`, `ListKey`, `InputKey`, `KeyModifiers`, `firstSelectableRow`, `nextSelectableRow`, `sectionLocalIndex`
- `lib/DanTermCore/Sources/DanTermCore/TodoShortcutCatalog.swift` -- `TodoShortcutScope`/`Section`/`Item`, `todoShortcutSections`

Add three app files (all pure Cocoa), after `app/TodoInputView.swift`:

- `app/TodoRowView.swift` -- `TodoRowView`, `todoRowId`
- `app/TodoShortcutHelpView.swift` -- `TodoShortcutHelpViewController`, `makeTodoShortcutHintLabel`, `configureTodoShortcutHelpButton`
- `app/TabTodoPopoverView.swift` -- the view under test

(Everything else the view references is already compiled: `Model.swift`,
`Msg.swift`, `TabTodo.swift`, `Projections.swift`, `TodoInputView.swift`,
shim `AppRuntime`.)

## Phase 2 -- Behavioral tests

New file `tests-ui/TabTodoPopoverViewTests.swift` with suite function
`func tabTodoPopoverViewTests()`; register it in `UITestRunner.main`
(`tests-ui/PaneSplitViewTests.swift:4-22`), and add the new test file to the
`test-ui.sh` compile list.

Follow the harness house style: `uiTest`/`uiExpect` helpers
(`tests-ui/PaneSplitViewTests.swift:27-50`), test preambles per AGENTS.md
(Intent / Why it exists / Scenario; these are spec-first characterization
tests, most need only a descriptive title).

### Fixture

Model builder + window-hosted controller, modeled on `makePaneMenuFixture`
(`tests-ui/PaneWrapperViewTests.swift:216-229`) and the sidebar harness
(`tests-ui/SidebarSelectionCacheTests.swift:168-177`):

```swift
private struct TabTodoFixture {
    let vc: TabTodoPopoverViewController
    let runtime: AppRuntime
    let window: NSWindow
    let tabId: TabId
    let paneIds: [PaneId]      // panes in rootNode order
    let table: NSTableView     // found by traversal
}
```

- Build `AppModel`: one `GroupModel`, one `TabModel` with `tab.todos`
  (parameterized: e.g. two open + one done) and a `rootNode` of two leaf
  `PaneModel`s, each with optional `pane.todos`. Use the no-arg `TypedId()`
  init from `tests-ui/TypedIdTestInit.swift`.
- Derive the projection with the real builder:
  `desiredTabTodoPopover(tabId:in:)`
  (`lib/DanTermCore/Sources/DanTermCore/Projections.swift:105`). Tests call
  `vc.apply(_:)` directly -- the reconciler's popover-open gating
  (`app/Reconcile.swift:406`) is runtime wiring, out of scope here.
- Host: `NSWindow(styleMask: [.titled], ...)`, `window.contentView = vc.view`,
  `window.layoutIfNeeded()`, `defer { window.close() }` in each test.
- Subview access: the controller's subviews are `private`, so find them by
  traversal (precedent: `findSidebarOutlineView`): the `NSTableView` by type;
  `Save`/`Cancel`/`Clear completed` buttons by title; the two `TodoInputView`s
  by order/visibility (compose lives in `bottomStack`, edit in
  `editContainer`). Row subviews (`TodoRowView.checkbox`/`.deleteButton`) are
  internal -- reachable once rows are materialized.
- Row materialization helper, copied from `materializeSidebarRows`
  (`tests-ui/SidebarSelectionCacheTests.swift:211-217`): layout, then
  `view(atColumn:row:makeIfNecessary: true)` + `rowView(atRow:...)` per row.
- Minimal key synthesis helper: `NSEvent.keyEvent(with: .keyDown, ...)`
  delivered via `table.keyDown(with:)` (keyCode 36 = Return). Needed because
  `tableRowDoubleClicked` guards on `clickedRow >= 0`, which only a real
  click sets; Return on a selected row routes through `classifyListAction ->
  .enterEdit` to the same `enterEditForSelectedRow`.
- Private-symbol constraint: `TabTodoHeaderRowView`, `TabTodoEmptyRowView`,
  `tabTodoRowDragType`, `TabTodoDragPayload`, and the row-identifier
  constants are all file-`private` in `app/TabTodoPopoverView.swift:9-140`.
  Tests must not name them. Assert through AppKit-observable state instead:
  - Row kinds via `view.identifier?.rawValue` (`"TabTodoHeader"`,
    `"PaneTodoHeader"`, `"TabTodoEmptyRow"`, `"TodoRow"`) plus
    `is TodoRowView` for item rows (internal, in `app/TodoRowView.swift`).
  - Row titles via recursive `NSTextField` lookup in the materialized view.
  - The drag type as a literal
    `NSPasteboard.PasteboardType("com.danneu.danterm.tab-todo-row")`.
  - The drag payload by decoding the pasteboard JSON string with
    `JSONSerialization` (or a test-local mirror struct), asserting on the
    `kind`/`paneId`/`todoId` fields -- never the private `TabTodoDragPayload`
    type.

### Test cases

Rendering / projection:
1. `apply` renders the expected row sequence for a populated model: tab
   header, tab items, pane headers, pane items (assert via row count plus
   each materialized view's `identifier?.rawValue` / `is TodoRowView`, and
   titles via `NSTextField` lookup -- the row view classes are
   file-private, see Fixture).
2. Empty tab section renders the `tabEmptyPlaceholder` row; "Clear completed"
   is hidden when `tabHasCompleted` is false and visible when true.

Button-driven actions (performClick, assert `runtime.sentMessages`):
3. Tab-row checkbox sends `.toggleTabTodoDone(tabId:todoId:)` for that row's
   item.
4. Pane-row checkbox sends `.setTodoDone(paneId:todoId:isDone: !item.isDone)`
   with the row's own paneId.
5. Tab-row delete button sends `.deleteTabTodo(tabId:todoId:)`; pane-row
   delete sends `.deleteTodo(paneId:todoId:)`.
6. "Clear completed" sends `.clearCompletedTabTodos(tabId:)`.

Compose (via `vc.textView(_:doCommandBy: #selector(insertNewline(_:)))` on the
compose text view -- with no `NSApp.currentEvent` this classifies as plain
Enter -> submit):
7. Non-empty compose submit sends `.addTabTodo(tabId:text:)` with trimmed
   text and clears the field.
8. Whitespace-only compose submit sends nothing.

Edit mode (select row, Return keyDown to enter edit):
9. Entering edit shows `editContainer`, hides the list and compose stack;
   edit input is prefilled with the item's text.
10. Save button sends `.editTabTodoText(tabId:todoId:text:)` for a tab item
    / `.editTodoText(paneId:todoId:text:)` for a pane item, with trimmed
    text, and returns to list mode.
11. Whitespace-only save is rejected: no message sent, stays in edit mode.
12. Cancel button sends nothing and returns to list mode.
13. `apply` mid-edit preserves the in-progress edit draft when the target
    todo still exists in the new projection (the e7d4576 reconcile behavior).
14. `apply` mid-edit exits edit mode when the target todo is gone.

Delegate paths (call the `NSTableViewDelegate` methods directly on `vc`):
15. `tableView(_:shouldSelectRow:)` on a pane section header records the
    header's paneId in `runtime.focusedPaneSurfaces` and returns false;
    item rows return true; headers/placeholders return false.
16. `tableView(_:pasteboardWriterForRow:)` writes a payload with `.tab`
    source for tab rows and `.pane(paneId)` for pane rows; returns nil for
    header and placeholder rows. Read the string for the literal pasteboard
    type `"com.danneu.danterm.tab-todo-row"` and decode the JSON with
    `JSONSerialization`/a test-local mirror (the `TabTodoDragPayload` type
    is file-private).

## Files touched

- `tests-ui/SidebarViewTestShim.swift` -- shim additions (1a)
- `test-ui.sh` -- compile-list additions (1b) + new test file (Phase 2)
- `tests-ui/PaneSplitViewTests.swift` -- one line: register the new suite
- `tests-ui/TabTodoPopoverViewTests.swift` -- new

No production (`app/`, `lib/`) files change.

## Out of scope (deliberate)

- `acceptDrop`/`validateDrop` routing (needs an `NSDraggingInfo` fake;
  resolution logic core-tested).
- Full keyboard surface (space/backspace/cmd-j/k/h/l/N//) -- classification
  is core-tested in `TodoInputCommand` tests.
- Shortcut-help popover show/dismiss (popover lifecycle is flaky headless-ish
  territory; `TodoShortcutHelpViewController` compiles in regardless).
- First-responder restoration assertions in `restoreFirstResponder` -- focus
  behavior in a bare test window is environment-sensitive; revisit if it
  proves stable.
- The observation that `runtime?.focusPaneSurface(paneId)`
  (`app/TabTodoPopoverView.swift:751`) bypasses Msg dispatch -- worth a
  follow-up discussion, not this change.

## Verification

1. After Phase 1 (before any new tests): `just test-ui` -- compiles, all
   existing suites green. This is the phase gate.
2. After Phase 2: `just test-ui` -- new `TabTodoPopoverView` suite runs and
   passes alongside existing suites (runner prints `N/N passed`, exit 0).
3. `just test` -- unaffected (no core/protocol/app changes), run once to
   confirm.
4. Negative check on one test (e.g. case 3): temporarily flip an expected
   Msg in the assertion and confirm the suite fails with the right message,
   then restore -- verifies the assertions actually bite.
