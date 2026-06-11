# Promote TodoPopoverView into the tests-ui harness

## Context

Two promotions of real views into the GhosttyKit-free UI harness have landed
and define the pattern: PaneWrapperView (8da7613) and TabTodoPopoverView
(265ee65, plan: `plans/impl/2026-06-11-tab-todo-popover-ui-harness.md`).
`app/TodoPopoverView.swift` -- the PANE-scoped todo popover
(`TodoPopoverViewController`), distinct from the already-promoted tab-scoped
one -- is now the largest untested view at exactly 880 lines: NSTableView todo
list with row checkboxes, delete, drag-reorder, compose/edit modes, and a
first-responder restoration matrix in `apply(_:)`.

A verification pass confirmed:

- The file imports only Cocoa; its full dependency closure is GhosttyKit-free.
- Every `Msg` it sends is id-scoped (`paneId` fixed at init, `todoId` carried
  per row): `.addTodo`, `.editTodoText`, `.toggleTodoDone`, `.deleteTodo`,
  `.reorderTodo`, `.clearCompletedTodos`, `.toggleTodoPopover`. No ambient
  selected-state resolution, so no pre-phase production fix is needed.
- The TabTodo promotion already pulled the entire shared closure into
  `test-ui.sh`: `TodoInputView`, `TodoRowView`/`todoRowId`,
  `TodoShortcutHelpView` helpers, `TodoPopoverState`, `TodoInputCommand`
  (classifiers + `firstSelectableRow`/`nextSelectableRow`), `TodoShortcutCatalog`,
  `Projections.swift` (`PaneTodoPopoverProjection`,
  `desiredPaneTodoPopover(paneId:in:)` at
  `lib/DanTermCore/Sources/DanTermCore/Projections.swift:89`), `Model.swift`.
- Only two enablement gaps remain: the view itself isn't in the compile list,
  and the shim `AppRuntime` lacks `todoPopover` (read at
  `app/TodoPopoverView.swift:634` by `showShortcutHelpPopover`).

Production code needs zero changes; this is a pure test-infrastructure
addition. Coverage here also de-risks a plausible future unification of the
two popover controllers (they duplicate compose/edit/focus machinery).

Scope decisions:

- **Focus restoration: IN scope** (user-confirmed). The TabTodo plan excluded
  first-responder assertions as environment-sensitive with "revisit if it
  proves stable" -- this is the revisit. The pane popover's distinguishing
  logic is exactly the focus machinery (`restoreFirstResponder`,
  `focusListFromInput`, `selectNearestSelectableRow`,
  `saveEditThenFocusCompose`). Keep these in a contained test group; if an
  individual case proves flaky in the harness, demote just that case to
  selection/visibility assertions and note it in the test preamble.
- Mirror the user-confirmed TabTodo exclusions otherwise: skip
  `acceptDrop`/`validateDrop` (needs an `NSDraggingInfo` fake; reorder logic
  is core-tested), skip the full keyboard classification surface (core-tested
  in `TodoInputCommand`), skip shortcut-help popover lifecycle
  (`TodoShortcutHelpViewController` compiles in regardless).
- Keep harness house style: per-file `private` helpers, duplicated from
  `tests-ui/TabTodoPopoverViewTests.swift` rather than extracted to a shared
  support file (the single-module compile makes file-private isolation the
  established convention; don't touch existing suites).

## Phase 1 -- Harness enablement

Gate: `just test-ui` compiles and all existing suites stay green. No new test
cases yet.

### 1a. Extend the shim (`tests-ui/SidebarViewTestShim.swift`)

Add to the test `AppRuntime`, next to the existing `tabTodoPopover`:

```swift
var todoPopover: NSPopover?    // read by TodoPopoverViewController.showShortcutHelpPopover
var onSend: ((Msg) -> Void)?   // test hook: invoked from send(_:) after recording
```

and invoke the hook at the end of `send(_:)`. Rationale: production
`AppRuntime.send` (`app/AppRuntime.swift:231`) runs `update` + reconcile
synchronously inside the call, so by the time a controller's post-send
selection-restore line runs, the table has already been re-applied with the
mutated projection. The recording-only shim never disturbs the rows, which
would make selection-preservation assertions vacuous. Tests that assert
selection restoration set `onSend` to re-`apply` the post-message projection
(mirroring production timing, including the reentrancy of `apply` running
inside `send`).

Update the file-header comment (currently "SidebarView, PaneWrapperView, and
TabTodoPopoverView") to mention TodoPopoverView.

### 1b. Extend the compile list (`test-ui.sh`)

Add one line, after `app/TabTodoPopoverView.swift`:

- `app/TodoPopoverView.swift` -- the view under test

Everything else it references is already compiled (see Context).

## Phase 2 -- Behavioral tests

New file `tests-ui/TodoPopoverViewTests.swift` with suite function
`func todoPopoverViewTests()`; register it in `UITestRunner.main`
(`tests-ui/PaneSplitViewTests.swift`), and add the file to the `test-ui.sh`
compile list.

These are spec-first characterization tests of existing behavior, so they
should pass once written; the TDD "fails for the right reason" obligation is
discharged by the negative check in Verification step 4 (same approach the
TabTodo plan used). House style: `uiTest`/`uiExpect` helpers, AGENTS.md
preambles (Intent / Why it exists / Scenario) only where non-trivial.

### Fixture

`PaneTodoFixture`, modeled directly on `TabTodoFixture`
(`tests-ui/TabTodoPopoverViewTests.swift:373-454`), with these deltas:

- Controller: `TodoPopoverViewController(paneId:runtime:)`; model needs only
  one group / one tab / a single leaf `PaneModel` carrying `pane.todos`
  (parameterized; default e.g. two open + one done). No-arg `TypedId()` init
  from `tests-ui/TypedIdTestInit.swift`.
- Projection via the real builder: `desiredPaneTodoPopover(paneId:in:)`;
  tests call `vc.apply(_:)` directly (the reconciler's open-popover gating at
  `app/Reconcile.swift:388` is runtime wiring, out of scope).
- Host window: `.titled`, `window.contentView = vc.view`, layout, materialize
  rows; `defer { fx.window.close() }` per test. Reuse (copy) the traversal
  helpers: find-table-by-type, `allSubviews(of:)`, `isEffectivelyHidden`,
  `visibleTodoInput`, button-by-title, row materialization,
  `expectSingleMessage`.
- Row model is simpler than the tab popover: a flat list of `TodoRowView`s
  only -- no header/placeholder row kinds. Empty state is the `emptyLabel`
  ("No tasks yet") with `scrollView` hidden, not a placeholder row.
- Drag type is the literal
  `NSPasteboard.PasteboardType("com.danneu.danterm.todo-row")` (the constant
  is file-private at `app/TodoPopoverView.swift:9`); the payload is a bare
  UUID string, not JSON.
- Key synthesis: Return on the table (keyCode 36) enters edit via
  `classifyListAction -> .enterEdit`. The classifier is modifier-strict
  (`classifyListAction`, `lib/DanTermCore/Sources/DanTermCore/TodoInputCommand.swift:89`):
  delete is Cmd-Backspace (keyCode 51 + `modifierFlags: [.command]`; plain
  Backspace is unhandled), reorder is Shift-J / Shift-K (characters "j"/"k" +
  `[.shift]`; Cmd-J is unhandled). Deliver these via `table.keyDown(with:)`
  so they route through `handleListKeyDown`. Escape paths go through
  `cancelOperation`/`doCommandBy` rather than raw key events.
- Focus assertions read `fx.window.firstResponder`; compare against
  `addInput.textView` / `editInput.textView` (via `visibleTodoInput().textView`)
  and the table.

### Test cases

Rendering / projection:

1. `apply` renders one `TodoRow` per item, in projection order, with matching
   titles (assert via materialized views' `identifier?.rawValue == "TodoRow"`
   and `TodoRowView.textField`).
2. Empty list shows `emptyLabel` and hides the scroll view; "Clear completed"
   is hidden when `hasCompleted` is false and visible after re-`apply` with a
   done item.

Button-driven actions (performClick, assert `runtime.sentMessages`):

3. Row checkbox sends `.toggleTodoDone(paneId:todoId:)` for that row's item,
   and the previously selected row stays selected (the
   `selectedIdBeforeMutation` re-select at `app/TodoPopoverView.swift:573-581`).
   Use the shim `onSend` hook to `apply` the post-toggle projection inside
   `send` -- otherwise the rows never change and the preservation assertion is
   vacuous.
4. Row delete button sends `.deleteTodo(paneId:todoId:)`.
5. "Clear completed" sends `.clearCompletedTodos(paneId:)`.

Compose (via `vc.textView(_:doCommandBy: #selector(insertNewline(_:)))`):

6. Non-empty submit sends `.addTodo(paneId:text:)` with trimmed text and
   clears the field.
7. Whitespace-only submit sends nothing.

Edit mode (select row, Return keyDown to enter edit):

8. Entering edit shows `editContainer`, hides scroll view and bottom stack,
   prefills the edit input with the item's text, and focuses
   `editInput.textView`.
9. Save sends `.editTodoText(paneId:todoId:text:)` with trimmed text, returns
   to list mode, re-selects the edited row, and focuses the table.
10. Whitespace-only save is rejected: no message, stays in edit mode, focus
    returns to the edit input.
11. Cancel sends nothing, returns to list mode, re-selects the former edit
    target.
12. `apply` mid-edit preserves the in-progress draft when the target todo
    survives in the new projection (`popoverState.reconcileEditTarget`, the
    e7d4576 behavior class on the pane side).
13. `apply` mid-edit exits edit mode when the target is gone, and selects the
    nearest remaining row (`selectNearestSelectableRow(near:focus:false)`).

List keyboard and dismissal:

14. Cmd-Backspace on a selected row sends `.deleteTodo` and moves selection
    to the nearest selectable row (covers `deleteSelectedTodo` +
    `selectNearestSelectableRow`; plain Backspace is unhandled by the
    classifier). Use the `onSend` hook to `apply` the post-delete projection
    so the nearest-row selection is exercised against a genuinely shrunken
    list.
15. Shift-J on a selected row sends `.reorderTodo(paneId:todoId:toIndex:)`
    with destination `row + 1` (covers `reorderSelectedTodo`; Cmd-J is
    unhandled by the classifier; drop-side `acceptDrop` stays out of scope).
16. Escape in list mode (`cancelOperation` on the table) sends
    `.toggleTodoPopover(paneId:)` -- the dismissal path.
17. Escape in compose with a non-empty list focuses the list
    (`focusListFromInput`: selection set, table becomes first responder, no
    message); with an empty list it sends `.toggleTodoPopover(paneId:)`
    instead (the `.dismiss` branch at `app/TodoPopoverView.swift:805-809`).

Drag payload:

18. `tableView(_:pasteboardWriterForRow:)` writes the row item's UUID string
    for the literal type `"com.danneu.danterm.todo-row"`.

Focus restoration across `apply` (the contained group; demote individual
flaky cases to selection/visibility assertions if needed):

19. `apply` while the compose input is first responder keeps it first
    responder (with the draft preserved via `setComposeDraft`).
20. `apply` while the table is first responder keeps table focus when the
    selected item survives; when the list empties, focus falls back to the
    compose input (the `restoreFirstResponder` table branch at
    `app/TodoPopoverView.swift:374-380`).
21. Cmd-N while editing saves the edit (message sent), clears the compose
    draft, and focuses the compose input (`saveEditThenFocusCompose` via
    `performTodoKeyEquivalent`; deliver the event through
    `vc.view.performKeyEquivalent(with:)` so the root view's
    `handleKeyEquivalent` hook is exercised).

## Phase 3 -- Production changes

Only whatever the tests force. Expected: none -- the verification pass found
no GhosttyKit references, no ambient-state messages, and no
compile-blocking visibility issues. If a test exposes a real defect, fix it
in a separate commit after the coverage lands, with its own regression
preamble.

## Files touched

- `tests-ui/SidebarViewTestShim.swift` -- `todoPopover` property, `onSend` hook + header comment (1a)
- `test-ui.sh` -- two compile-list lines: the view (1b) + the new test file (Phase 2)
- `tests-ui/PaneSplitViewTests.swift` -- one line: register the new suite
- `tests-ui/TodoPopoverViewTests.swift` -- new

No production (`app/`, `lib/`) files change.

## Out of scope (deliberate)

- `acceptDrop`/`validateDrop` routing (needs an `NSDraggingInfo` fake; the
  drop-side selection re-select mirrors the checkbox path already covered).
- Full keyboard classification surface (space/j/k/h/l/?/n) -- core-tested in
  `TodoInputCommand`; only the routing cases above are exercised.
- Shortcut-help popover show/dismiss (popover lifecycle; compiles in via the
  shim's `todoPopover` property regardless).
- Any controller unification with `TabTodoPopoverViewController` -- this
  coverage is what makes that future refactor safe, but it is not this change.

## Verification

1. After Phase 1 (before any new tests): `just test-ui` -- compiles, all
   existing suites green. This is the phase gate.
2. After Phase 2: `just test-ui` -- new `TodoPopoverView` suite runs and
   passes alongside existing suites (runner prints `N/N passed`, exit 0).
3. `just test` -- unaffected (no core/protocol/app changes), run once to
   confirm.
4. Negative check on one message assertion (e.g. case 3): temporarily flip
   the expected `Msg` and confirm the suite fails with the right message,
   then restore -- verifies the assertions actually bite.
5. Focus-group stability check: run `just test-ui` three times in a row; if
   a focus case (19-21) flickers, demote that case per the scope decision
   and note the demotion in its preamble.

## Follow Up

- `app/TodoPopoverView.swift:1` starts with a top-of-file `///` doc comment; convert it to a `//` file header in a production-comment cleanup so it matches the repo's Swift file-header rule.
