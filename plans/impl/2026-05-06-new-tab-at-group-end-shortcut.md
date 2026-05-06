# Plan: Cmd-Shift-T -> "New Tab at End of Group"

## Context

`Cmd-T` already creates a new tab and inserts it **directly after the
selected tab** in its group (`app/Update.swift:52-58`). The user wants a
second variant that always **appends to the end of the current group**,
regardless of which tab is selected -- useful when you want a fresh tab
parked at the tail of the list rather than wedged between two existing
ones.

The desired binding is `Cmd-Shift-T`, which today is bound to "Toggle Theme
Panel" (`app/AppDelegate.swift:247-249`). That binding needs to move.

**Recommended replacement: `Cmd-Shift-Y`.** Reasoning:

- Free (not used anywhere in the app, no macOS system conflict).
- One key to the right of `T` on QWERTY -- muscle memory transfers
  immediately for users who already know the old chord.
- Runner-up if you'd rather have a mnemonic: `Cmd-Shift-B` ("Browse
  Themes"). One-line swap if you prefer it.

## Approach

Extend the existing `createTab` Msg with an optional position enum so we
**reuse the entire current handler** (group resolution, old-tab defocus,
selection update, MRU reconciliation, checkpoint scheduling, effect
emission) and only branch at the single line that picks the insert index.

This is the same default-associated-value pattern that
`splitPane(paneId: PaneId? = nil, direction:)` already uses in
`app/Msg.swift:28`, so no existing `createTab` call site has to change.

### 1. `app/Msg.swift`

Add a small enum near the other Msg helpers (alongside `TabDirection`,
`SearchDirection`, `MruDirection`):

```swift
// Where a newly-created tab lands within its target group.
// `afterSelected` keeps the new tab next to the current one (Cmd-T).
// `atGroupEnd` always appends, regardless of selection (Cmd-Shift-T).
enum TabInsertPosition {
    case afterSelected
    case atGroupEnd
}
```

Extend the case (line 25) -- default value preserves every caller:

```swift
case createTab(inGroupId: GroupId?, position: TabInsertPosition = .afterSelected)
```

### 2. `app/Update.swift`

In the `.createTab` case (line 32), bind `position` and switch on it for
the insert step only. Everything else in the handler is unchanged.

```swift
case .createTab(let inGroupId, let position):
    // ... existing pane/tab construction, target-group resolution ...

    switch position {
    case .atGroupEnd:
        model.groups[targetGroupIndex].tabs.append(tab)
    case .afterSelected:
        if let selId = model.selectedTabId,
           let selIdx = model.groups[targetGroupIndex].tabs.firstIndex(where: { $0.id == selId }) {
            model.groups[targetGroupIndex].tabs.insert(tab, at: selIdx + 1)
        } else {
            model.groups[targetGroupIndex].tabs.append(tab)
        }
    }

    // ... existing defocus, selectedTabId update, effects, scheduleCheckpoint ...
```

### 3. `app/AppDelegate.swift`

Three targeted edits inside `buildMenu()` and the action-handler section:

a. **Tab menu (around line 256):** add a new item right after "New Tab":

```swift
let newTabAtEndItem = NSMenuItem(
    title: "New Tab at End of Group",
    action: #selector(newTabAtGroupEnd(_:)),
    keyEquivalent: "T"
)
newTabAtEndItem.keyEquivalentModifierMask = [.command, .shift]
tabMenu.addItem(newTabAtEndItem)
```

b. **Action handler (next to `newTab`, around line 372):**

```swift
@objc func newTabAtGroupEnd(_ sender: Any?) {
    runtime.send(.createTab(inGroupId: nil, position: .atGroupEnd))
}
```

c. **View menu (line 247):** change the "Toggle Theme Panel" key from
`"T"` to `"Y"`. Modifier mask stays `[.command, .shift]`.

### 4. `tests/UpdateTabTests.swift`

Two new tests in the same style as `testCreateTabInsertsAfterCurrentTab`:

- **`testCreateTabAtGroupEndAppendsRegardlessOfSelection`** -- create
  three tabs A/B/C in the default group, select B, send
  `.createTab(inGroupId: nil, position: .atGroupEnd)`, assert the new tab
  lands at index 3 (not at index 2 next to B) and is selected.
- **`testCreateTabAtGroupEndUsesSelectedTabsGroupWhenNoneSpecified`** --
  set up default + Work group, select a middle tab in Work, send the same
  Msg, assert the new tab appended to Work and the default group is
  untouched.

Important `makeModel()` quirk discovered in TestHarness.swift:71: the
default "General" group starts **empty** (zero tabs), and `createGroup`
auto-creates a tab in the new group. The second test must assert the
default group has 0 tabs, not 1.

## Why this shape (vs alternatives)

- A separate `createTabAtGroupEnd(inGroupId: GroupId?)` Msg case would
  duplicate ~25 lines of handler (group resolution, defocus, MRU
  reconciliation, checkpoint, effects) or require extracting a private
  helper -- extra complexity for no win.
- Computing the index in the menu handler before sending Msg would
  require the AppDelegate to reach into the model to find "current
  group", which is a layering smell -- the Msg/update split exists
  precisely to keep AppKit handlers thin.

The default-valued associated value keeps blast radius to one switch case
in `Update.swift` and zero changes at the six existing `createTab`
call sites:

- `app/AppRuntime.swift:903, 912`
- `app/SidebarView.swift:895`
- `app/AppDelegate.swift:157, 161, 373`
- `app/Update.swift:942` (inside `.createGroup`)

## Verification

1. **`just test`** -- 721 existing tests must still pass; both new tests
   pass. (TDD: write the failing tests first, run `just test` to confirm
   they fail for the expected reason, then implement.)
2. **`just build`** -- confirms the AppKit menu wiring (`@objc` selector,
   keyEquivalent, modifier mask) compiles cleanly.
3. **Smoke test in `~/Applications/DanTerm Dev.app`:**
   - `Cmd-T` a few times to get tabs A, B, C.
   - Click the middle tab. Press `Cmd-T` -> new tab appears between
     selected and next (unchanged behavior).
   - Click the middle tab again. Press `Cmd-Shift-T` -> new tab appears
     at the **end** of the group, and is selected.
   - Press `Cmd-Shift-Y` -> theme panel toggles open / closed.
   - Create a second group via `Cmd-N`, switch into it, press
     `Cmd-Shift-T` -> new tab appended to that group, not the first.

## Files modified

- `app/Msg.swift` -- add `TabInsertPosition`, extend `createTab` case
- `app/Update.swift` -- branch on `position` in `.createTab` handler
- `app/AppDelegate.swift` -- add menu item + action, move theme-panel key
- `tests/UpdateTabTests.swift` -- two new tests
