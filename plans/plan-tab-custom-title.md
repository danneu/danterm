# Custom Tab Titles — Implementation Plan

## Context

Tabs derive their title from the focused pane's terminal title (set by shell escape sequences). When a tab has multiple panes, the title flips on focus change. Users should be able to set a custom title that sticks regardless of pane focus.

## Step 1: Model — `app/Model.swift`

**TabModel** (~line 47): Add field and computed property:

```swift
var customTitle: String?
var displayTitle: String { customTitle ?? title }
```

**TabSnapshot** (~line 91): Add `let customTitle: String?`

**validateAndBuildDetailed** (~line 268): Pass `customTitle: ts.customTitle` when constructing TabModel.

## Step 2: Msg — `app/Msg.swift`

Add: `case renameTab(id: TabId, name: String?)`

## Step 3: Update — `app/Update.swift`

### New helper: `selectionSyncEffects`

```swift
private func selectionSyncEffects(for model: AppModel) -> [Effect] {
    guard let tab = selectedTab(in: model) else { return [] }
    return [.setWindowTitle(windowTitle(for: tab))]
}
```

### New handler: `.renameTab`

- Trim whitespace; treat empty as nil
- Set `tab.customTitle`
- Emit `.reloadSidebarRow(tabId:)`
- Only if `id == model.selectedTabId`: also emit `selectionSyncEffects(for: model)`

### Fix `windowTitle(for:)` (~line 478)

Change all 3 occurrences of `tab.title` to `tab.displayTitle` (including the `subtitle != tab.title` comparison).

### Fix `.requestCloseTab` (~line 86)

Change `tab.title` → `tab.displayTitle` in the confirmation effect.

### Add `.setWindowTitle` to selection-changing paths

- `.createTab` (~line 49): append `selectionSyncEffects(for: model)`
- `.selectTab` (~line 74): append `selectionSyncEffects(for: model)`
- `.closeTab` (~line 124, inside `if id == model.selectedTabId`): append `selectionSyncEffects(for: model)`
- `.deleteGroup` (~line 403, inside selection-fix block): append `selectionSyncEffects(for: model)`
- `.movePaneToTab` (~line 269): after selecting `targetTabId`, append `selectionSyncEffects(for: model)`
- `.surfaceCreationFailed` (~line 432, when the failed tab was selected and selection falls back): append `selectionSyncEffects(for: model)`

### Selection-sync rule

Apply `selectionSyncEffects(for: model)` to every path that mutates `model.selectedTabId`, not just the tab-management handlers above.

### No changes needed to:

- `.surfaceTitle`, `.surfaceCwd` — already emit `.setWindowTitle`, just keep writing to `tab.title`
- `.paneBecameFirstResponder` — already emits `.setWindowTitle`

## Step 4: Snapshot export — `app/ModelOperations.swift`

`toSnapshot()` (~line 322): Add `customTitle: tab.customTitle` to TabSnapshot construction.

## Step 5: SidebarView — `app/SidebarView.swift`

- **Cell rendering** (~line 699): `tab.title` → `tab.displayTitle`

- **RenameTargetBox**: New class wrapping `.tab(TabId)` or `.group(GroupId)` — replaces fragile `textField.tag = hashValue` routing. Stored as associated object on NSTextField.

- **`beginRenaming(item:)`**: Unified entry point for context menu, double-click, and keyboard shortcut. Sets `renameTarget`, makes field editable, selects text.

- **`beginRenamingTab(_:)` / `beginRenamingGroup(_:)`**: Thin wrappers that look up item cache and delegate to `beginRenaming(item:)`.

- **Tab context menu** (~line 489): Add "Rename Tab" (and "Clear Custom Title" when `customTitle != nil`) before "Close Tab".

- **NSTextFieldDelegate** (~line 719): Rewrite to read `textField.renameTarget`:
  - `.tab`: dispatch `.renameTab` — empty string clears custom title
  - `.group`: dispatch `.renameGroup` — reject empty (existing behavior)
  - Always clean up: set `renameTarget = nil`, `isEditable = false`

- **Double-click**: Set `outlineView.doubleAction = #selector(outlineViewDoubleClicked)` in `setup()`. Handler calls `beginRenaming(item:)`.

- **AssociatedKeys**: Add `static var renameTarget: UInt8 = 0`

## Step 6: Menu shortcut — `app/AppDelegate.swift`

Add "Rename Tab" to Shell menu with Cmd+Shift+R. Action calls `sidebarView.beginRenamingTab(tabId)`.

## Step 7: Tests (TDD) — `tests/UpdateTabTests.swift`, `tests/UpdateGroupTests.swift`, `tests/UpdatePaneTests.swift`, `tests/ExportTests.swift`, `tests/SnapshotTests.swift`

Write tests first (before each implementation step), verify they fail, then implement.

### UpdateTabTests

- **testRenameTab** — `.renameTab(id:, name: "My App")` sets `customTitle`, emits `.reloadSidebarRow` + `.setWindowTitle`
- **testRenameTabClear** — `.renameTab(id:, name: nil)` clears `customTitle`, emits sidebar/window effects
- **testRenameTabEmptyStringClearsTitle** — empty/whitespace name treated as nil
- **testDisplayTitlePrefersCustom** — `customTitle = "X"`, `title = "vim"` → `displayTitle == "X"`
- **testDisplayTitleFallback** — no `customTitle` → `displayTitle == title`
- **testSurfaceTitleDoesNotOverrideCustom** — `.surfaceTitle` updates `tab.title` but `customTitle` stays; emitted `.setWindowTitle` uses custom title
- **testPaneFocusDoesNotOverrideCustom** — focus change updates `tab.title` but `customTitle` stays
- **testSetWindowTitleUsesDisplayTitle** — set `customTitle = "X"`, send `.surfaceTitle` for focused pane, assert `.setWindowTitle` value contains "X" (behavioral test — `windowTitle(for:)` is private)
- **testCloseConfirmUsesDisplayTitle** — `.requestCloseTab` uses `displayTitle` in confirmation
- **testSelectTabEmitsSetWindowTitle** — `.selectTab` emits `.setWindowTitle` with new tab's title
- **testCloseSelectedTabEmitsSetWindowTitle** — closing selected tab emits `.setWindowTitle` for fallback tab
- **testCreateTabEmitsSetWindowTitle** — `.createTab` emits `.setWindowTitle`

### UpdateGroupTests

- **testDeleteGroupEmitsSetWindowTitle** — delete a group that contains the selected tab (forcing selection fallback), assert `.setWindowTitle` is emitted for the newly selected tab

### UpdatePaneTests

- **testMovePaneToTabEmitsSetWindowTitle** — moving a pane to another tab selects the target tab and emits `.setWindowTitle` for that destination tab

### ExportTests

- **testToSnapshotPreservesCustomTitle** — `toSnapshot()` includes `customTitle`
- **testToSnapshotCustomTitleRoundTrip** — export, encode JSON, decode, rebuild, verify `customTitle` survives round-trip

### SnapshotTests

- **testSnapshotCustomTitleOmitted** — JSON without `customTitle` decodes to nil (backward compat)

## Verification

1. `just test` — all new and existing tests pass
2. `just build-run` — manual tests:
   - Right-click tab → "Rename Tab" → type name → sticks
   - Double-click tab title → inline edit
   - Cmd+Shift+R → inline edit on selected tab
   - Switch panes in renamed tab → custom title persists
   - Switch tabs → window title bar updates correctly
   - Close selected tab → window title updates to fallback tab
   - Create new tab → window title updates
   - Clear custom title → falls back to auto title
   - Close tab confirmation shows custom title
   - Quit and relaunch → custom title persists from snapshot
