# Hotkeys for pane/tab to-do list panels

## Context

The tab-level to-do list (commit 41fae4b) and the pane-level to-do list both
exist as `NSPopover`s anchored to their respective toolbar buttons. The pane
popover is reachable via the Pane menu's "Open TODOs" item (Cmd+Option+T); the
tab popover has no menu item at all — it can only be opened by clicking the
chrome button.

We want consistent, ergonomic hotkeys for both:

- **Cmd+'** → toggle tab to-do list (new) — tab is the "default" scope since
  it rolls up pane todos
- **Cmd+Shift+'** → toggle pane to-do list (replaces existing Cmd+Option+T binding)

No Model / Msg / Update / Effect changes are needed. The toggle logic
(including mutual exclusion between pane and tab popovers) already exists
in `Update.swift` at lines 1196-1235, and both `@objc` action handlers
(`openTodo(_:)` and `toggleTabTodoPopover(_:)`) already exist in
`AppDelegate.swift` at lines 560-568.

## Changes

### 1. `app/AppDelegate.swift` — rebind pane menu item

Lines 367-369. Update the existing `todoItem`:

- Title: `"Open TODOs"` → `"Toggle To-do List"`
- `keyEquivalent`: `"t"` → `"'"`
- `keyEquivalentModifierMask`: `[.command, .option]` → `[.command, .shift]`

Reuses the existing `@objc func openTodo(_:)` handler at line 560.

### 2. `app/AppDelegate.swift` — add Tab menu item

Add a new item in the Tab menu, placed just before the
`NSMenuItem.separator()` on line 313 (so it sits with the discoverability
items above "Close Tab"). Plain Cmd+' (no shift):

```swift
let tabTodoItem = NSMenuItem(title: "Toggle To-do List", action: #selector(toggleTabTodoPopover(_:)), keyEquivalent: "'")
tabTodoItem.keyEquivalentModifierMask = [.command]
tabMenu.addItem(tabTodoItem)
```

Reuses the existing `@objc func toggleTabTodoPopover(_:)` handler at line 565.

### 3. `README.md` — update Keybinds table

Insert two new rows in the table at lines 302-327. Place them next to the
alert-clear rows so the pane/tab scope-by-Shift symmetry is visible:

```
| Toggle Tab To-do List          | ⌘'       |
| Toggle Pane To-do List         | ⇧⌘'      |
```

Recommended insertion point: immediately after `Clear Pane Alerts | ⇧⌘.`
(matches the menu grouping).

## Key files

- `app/AppDelegate.swift:311-319` — Tab menu construction (insertion point)
- `app/AppDelegate.swift:367-369` — existing pane todo menu item (rebind)
- `app/AppDelegate.swift:560-568` — existing action handlers (no change)
- `app/Update.swift:1196-1235` — existing toggle + mutual-exclusion logic (no change)
- `README.md:302-327` — Keybinds table

## What is NOT changing

- `Msg.swift`, `Update.swift`, `Model.swift`, `Effect.swift`, `AppRuntime.swift`
- Toolbar buttons (`WindowChromeView.swift`, `PaneWrapperView.swift`)
- Popover view files (`TodoPopoverView.swift`, `TabTodoPopoverView.swift`)
- Any test files — the toggle Msgs are already covered in
  `tests/UpdateTabTodoTests.swift:140-225` and `tests/UpdateTodoTests.swift`,
  and AppDelegate menu wiring is not unit-tested.

## Verification

1. `just test` — existing Update tests still pass (no test changes expected).
2. `just build-run` — launch dev build.
3. With focus in a pane:
   - Press **Cmd+'** → tab to-do popover opens at the window chrome button.
   - Press **Cmd+'** again → popover dismisses.
4. While tab popover is open, press **Cmd+Shift+'** → tab popover closes,
   pane popover opens anchored to the focused pane's toolbar todo button
   (verifies mutual exclusion from `Update.swift:1196-1235`).
5. Press **Cmd+Shift+'** again → pane popover dismisses.
6. Confirm **Cmd+Option+T** no longer does anything (binding removed).
7. Inspect menus: Tab menu shows "Toggle To-do List ⌘'", Pane menu shows
   "Toggle To-do List ⇧⌘'".
