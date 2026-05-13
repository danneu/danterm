# Tab todo: shortcut cleanup + header "New" button

## Context

The tab-scoped todo popover (`TabTodoPopoverView`) shows a single tab's todos
on top followed by per-pane todo sections. Today its row-mode hotkeys are:

- `shift-j` / `shift-k` reorder the focused todo up/down **within its section**
  only; at a section boundary the keystroke is a no-op.
- `cmd-shift-h` / `cmd-shift-l` move the focused todo to the previous/next
  bucket (tab <-> pane), inserting at index 0 of the new bucket.
- `cmd-N` focuses the compose input to add a new todo, but this is not
  discoverable from the UI -- the header only shows a "Clear completed" button
  (which itself only appears when something is completed).

Three problems:

1. `cmd-shift-h/l` is a four-finger chord, and the rest of the row-mode
   shortcuts are plain shift-modified. Inconsistent.
2. To move an item from tab into the first pane, the user has to stop pressing
   shift-j and reach for a different chord. The two sections are visually one
   list -- the keystroke should treat them as one list.
3. `cmd-N` (focus compose) has no visible affordance in the header.

Goals:

1. Rebind bucket movement from `cmd-shift-h/l` to plain `shift-h/l`.
2. Make `shift-j/k` cross section boundaries: at the bottom of a section,
   shift-j lands the item at index 0 of the next section; at the top, shift-k
   lands it at the end of the previous section. At the very top/bottom of the
   continuous list, it is still a no-op.
3. Add a header "New (⌘N)" button (right side, mirroring the existing
   "Clear completed" button) that focuses the compose input. The chord
   glyph in the title teaches the hotkey.

Scope of (1) and (2): only `TabTodoPopoverView`. The pane-scoped
`TodoPopoverView` has a single section, so neither shortcut change applies
there. Scope of (3): only `TabTodoPopoverView` for now.

## Approach

### 1. New pure helper for the continuous-reorder decision

Add to `app/ModelOperations.swift` (next to `resolveTabTodoBucketStep`):

```swift
enum TabTodoReorderStep: Equatable {
  case reorderInSection(toIndex: Int)
  case moveToBucket(destination: TodoDestination, atIndex: Int)
}

// Resolves a Shift-J/K keystroke into either an intra-section reorder or a
// cross-section move, treating the tab section and per-pane sections as one
// continuous list. Pure: returns the intended target; the caller is
// responsible for dispatching the matching Msg.
func resolveTabTodoReorderStep(
  current: TabTodoEditTarget,
  paneOrder: [PaneId],
  tabId: TabId,
  currentIndex: Int,
  currentSectionCount: Int,
  destinationSectionCount: (TodoDestination) -> Int,
  delta: Int
) -> TabTodoReorderStep?
```

Rules:

- `delta == +1`, `currentIndex + 1 < currentSectionCount` -> `.reorderInSection(currentIndex + 1)`
- `delta == +1`, at last index -> use `resolveTabTodoBucketStep(.., delta: +1)`;
  if it returns a destination, emit `.moveToBucket(dest, atIndex: 0)`;
  otherwise return `nil` (already at end of continuous list).
- `delta == -1`, `currentIndex > 0` -> `.reorderInSection(currentIndex - 1)`
- `delta == -1`, at first index -> use `resolveTabTodoBucketStep(.., delta: -1)`;
  if it returns a destination, emit `.moveToBucket(dest, atIndex: destinationSectionCount(dest))`
  (append to end of previous section); otherwise return `nil`.

This composes the existing `resolveTabTodoBucketStep` and reuses
`TabTodoEditTarget` / `TodoDestination`.

### 2. Extend the pure key classifier

In `app/TodoInputCommand.swift`:

- Add `case h` and `case l` to `ListKey`.
- Add `case moveBucket(delta: Int)` to `ListAction`.
- Extend `classifyListAction`: under the `.shift` (not `.command`) branch,
  return `.moveBucket(-1)` for `.h` and `.moveBucket(+1)` for `.l`.
- No change to plain `.h`/`.l` (returns `.unhandled` -- falls through, so
  uppercase typing in fields is unaffected; row-mode just ignores it).

### 3. Map characters in both popovers' key extractors

- `tabListKey` in `app/TabTodoPopoverView.swift` (around line 982): add
  `"h" -> .h`, `"l" -> .l` to the character switch.
- `listKey` in `app/TodoPopoverView.swift` (matching helper): add the same.
  This keeps `classifyListAction` exhaustive in both call sites.

### 4. Wire the new action in TabTodoPopoverView

`app/TabTodoPopoverView.swift`:

- `handleListKeyDown` (around line 801): add
  `case .moveBucket(let delta): return moveSelectedTodoToAdjacentBucket(delta: delta)`.
- `reorderSelectedTodo(delta:)` (around line 729): replace the existing
  "same-section only" guard with a call to `resolveTabTodoReorderStep`.
  On `.reorderInSection(toIndex)`: emit `.reorderTabTodo` or `.reorderTodo`
  exactly like today.
  On `.moveToBucket(destination, atIndex)`: emit `.moveTodo` and re-select the
  moved item in its new bucket (the same selection-restore pattern that
  `moveSelectedTodoToAdjacentBucket` uses today).
  On `nil`: no-op.
- `performTodoKeyEquivalent` (around line 827): replace the
  `[.command, .shift] h/l` branch's body with `return true`. The keystroke is
  no longer a valid bucket-move action (now bound to plain `shift-h/l`), but
  it must still be swallowed: `cmd-shift-H` / `cmd-shift-L` are bound to
  "Focus Left" / "Focus Right" at `app/AppDelegate.swift:342-354`, and per
  Apple's key-equivalent dispatch an unhandled `performKeyEquivalent` falls
  through to the menu, which would shift terminal-pane focus while the
  popover is open. Swallowing returns the visible behavior the verification
  step expects ("nothing happens"). Plain `shift-h/l` now flows through
  `handleListKeyDown` -> `classifyListAction` -> `.moveBucket`.

### 5. Header "New (⌘N)" button

`app/TabTodoPopoverView.swift`:

- Add a private `newButton = NSButton(title: "New (\u{2318}N)", target: nil, action: nil)`
  next to the existing `clearButton` declaration (line 149). Style to match
  clearButton: `.accessoryBarAction` bezel, small system font.
  ASCII-only-policy exception: the user explicitly asked for the glyph; the
  rest of the codebase doesn't yet use Unicode key glyphs, but the macOS HIG
  uses them and the user proposed `⌘N`. No `keyEquivalent` is set on the
  button itself -- AppKit's `performKeyEquivalent` dispatch on
  `TabTodoPopoverRootView` already handles cmd-N, and setting both would
  risk double-firing.
- Wire `newButton.target = self`, `newButton.action = #selector(focusComposeAction)`.
  Add a private `@objc func focusComposeAction(_ sender: Any?)` that runs the
  same branch as the cmd-N handler in `performTodoKeyEquivalent`:
  `if isEditing { saveEditThenFocusCompose() } else { focusComposeInput() }`.
  Extract that two-line branch into a private helper (e.g.
  `focusComposeFromShortcut`) and call it from both the cmd-N case and the
  button action so there is one source of truth.
- Layout: replace the standalone `clearButton.trailingAnchor` constraint
  (line 260) with a horizontal `NSStackView` containing
  `[clearButton, newButton]`, `spacing: 6`, `detachesHiddenViews = true`,
  anchored `centerY` to `headerLabel.centerYAnchor` and `trailing` to
  `container.trailingAnchor` constant `-8`. With `detachesHiddenViews`, the
  stack collapses cleanly when `clearButton.isHidden` toggles (the existing
  toggle in `rebuildRows` stays untouched).
- `newButton` is always visible; no rebuildRows changes needed for it.

### 6. Wire the no-op in TodoPopoverView

`app/TodoPopoverView.swift handleListKeyDown` (line 508): add
`case .moveBucket: return false`. Pane popover has one section; the action
is meaningless there and the key should fall through.

### Files to modify

- `app/TodoInputCommand.swift` -- enum cases + `classifyListAction`
- `app/ModelOperations.swift` -- new `TabTodoReorderStep` + `resolveTabTodoReorderStep`
- `app/TabTodoPopoverView.swift` -- `tabListKey`, `reorderSelectedTodo`,
  `handleListKeyDown`, `performTodoKeyEquivalent`, new `newButton` + header
  stack layout + `focusComposeAction`
- `app/TodoPopoverView.swift` -- `listKey` (h/l mapping), `handleListKeyDown`
  switch (`.moveBucket` no-op)

### Reused helpers

- `resolveTabTodoBucketStep` (`app/ModelOperations.swift:630`) -- existing
  bucket-step logic; composed by the new helper.
- `allPaneIds(tab.rootNode)` -- already used by `moveSelectedTodoToAdjacentBucket`.
- `moveSelectedTodoToAdjacentBucket` -- reused as-is for shift-h/l.

## Tests

Pure unit tests only -- no view tests needed.

### classifyListAction (in `tests/UpdateTodoTests.swift`, near line 368)

- `list shift h moves bucket left` -> `.moveBucket(-1)`
- `list shift l moves bucket right` -> `.moveBucket(+1)`
- `list cmd shift h is unhandled` -> regression test confirming the old
  chord no longer triggers bucket movement at this layer
- `list plain h is unhandled` -> guards typing semantics

### resolveTabTodoReorderStep (new section in `tests/ModelOperationsTests.swift`)

Build a synthetic input pattern (paneOrder of 2 panes, supplied counts):

- middle of tab section, delta=+1 -> `.reorderInSection(currentIndex + 1)`
- middle of tab section, delta=-1 -> `.reorderInSection(currentIndex - 1)`
- last item of tab, delta=+1, pane0 has items -> `.moveToBucket(.pane(pane0), atIndex: 0)`
- last item of tab, delta=+1, pane0 empty -> `.moveToBucket(.pane(pane0), atIndex: 0)`
- first item of pane0, delta=-1, tab has 3 items -> `.moveToBucket(.tab(tabId), atIndex: 3)`
- first item of pane0, delta=-1, tab empty -> `.moveToBucket(.tab(tabId), atIndex: 0)`
- last item of pane0, delta=+1, pane1 has 2 items -> `.moveToBucket(.pane(pane1), atIndex: 0)`
- first item of pane1, delta=-1, pane0 has 4 items -> `.moveToBucket(.pane(pane0), atIndex: 4)`
- first item of tab, delta=-1 (top of continuous list) -> `nil`
- last item of last pane, delta=+1 (bottom of continuous list) -> `nil`

These tests are structure-insensitive (operate on the public return type) and
behavioral.

## Verification

1. `just test` -- pure tests pass.
2. `just build-run` -- launches DanTerm Dev.
3. Manual smoke (in the running app):
   - Open a tab todo popover (`cmd+'`), add 3 tab todos and 2 pane todos.
   - In row mode, press `shift-j` from middle tab item: reorders within tab.
   - Press `shift-j` from last tab item: item jumps to top of first pane,
     selection follows it.
   - Press `shift-k` from first pane item: item lands at end of tab section,
     selection follows.
   - Press `shift-h` / `shift-l` from a row: item moves to adjacent bucket at
     index 0 (same as old `cmd-shift-h/l`).
   - Press `cmd-shift-h` / `cmd-shift-l`: nothing happens (binding removed).
   - Focus compose input, type a capital `H` and capital `L`: characters are
     entered normally (no interception).
   - Double-click a todo to enter edit mode; type capital `H` / `L`: entered
     normally.
   - Header shows "New (⌘N)" button on the right. Click it: focus moves to
     compose input. Press `cmd-N`: same effect. Open with completed items
     present: both "Clear completed" and "New (⌘N)" buttons visible, packed
     right; clear button hides cleanly when nothing is completed.
