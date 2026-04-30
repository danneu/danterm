# Keep focused sidebar tab blue

## Context

The terminal pane is always first responder, which makes the sidebar's
`NSOutlineView` "inactive" and forces selected rows to draw in grey. Now
that multi-tab selection is in flight (`multiselect` branch), the lack of
a blue accent on the currently-viewed tab makes it visually
indistinguishable from the rest of the multi-selection. We want the
focused tab (`AppModel.selectedTabId`) to always draw with AppKit's
native emphasized selection color, while non-focused selected tabs keep
their normal inactive-grey treatment.

The fix uses AppKit's documented extension point: subclass
`NSTableRowView` and override `isEmphasized`. AppKit still does all
selection drawing -- native regular/full-width selection (the sidebar
uses `selectionHighlightStyle = .regular` and `style = .fullWidth`,
`SidebarView.swift:152-153`) -- so we get accent color, dark mode, and
accessibility contrast for free. No custom `drawSelection(in:)`,
no first-responder rewiring, no hard-coded `systemBlue`.

## Approach

1. Add a `SidebarRowView: NSTableRowView` subclass with a
   `forceEmphasizedSelection` flag. `isEmphasized` returns `true` for
   selected rows when the flag is set; otherwise it falls back to
   AppKit's native value (so multi-selected non-focused rows behave
   exactly as today).
2. Add a pure predicate `shouldForceSidebarRowEmphasis(rowTabId:focusedTabId:)`
   in `app/ModelOperations.swift`. It uses only model-level types
   (`TabId?`) so the pure-test target can compile it -- `test.sh` only
   compiles the model/update files plus tests, not view files.
3. Implement `outlineView(_:rowViewForItem:)` in `SidebarView`. Map
   `SidebarItem` -> `TabId?` (nil for group rows), then call the pure
   predicate with `currentModel?.selectedTabId`. Set the result on
   `forceEmphasizedSelection`.
4. No new effect, no new Msg, no changes to selection semantics. Focus
   changes already flow through `applySelectTab` ->
   `Effect.reloadSidebar` -> `SidebarView.reload(model:)` ->
   `outlineView.reloadData()`, which calls `rowViewForItem` for every
   visible row. That single path covers all focus transitions
   (`.selectTab`, `.mruCycleCommitted`, `.createTab`, drag-induced
   reorder, etc.).

## Files

- `app/ModelOperations.swift`
  - Add the pure predicate
    `shouldForceSidebarRowEmphasis(rowTabId: TabId?, focusedTabId: TabId?) -> Bool`.
    Returns `true` iff both ids are non-nil and equal. Lives here
    (rather than in `SidebarView.swift`) because the pure-test target
    in `test.sh` does not compile view files.
- `app/SidebarView.swift`
  - Add `SidebarRowView` class (next to `SidebarOutlineView` near line 47).
  - Add `outlineView(_:rowViewForItem:)` to the
    `NSOutlineViewDelegate` conformance. It extracts a `TabId?` from
    the `SidebarItem` (nil for groups) and calls the pure predicate.
- `tests/ModelOperationsTests.swift`
  - Add tests for `shouldForceSidebarRowEmphasis`. This file already
    hosts pure-function tests with the same harness pattern
    (`test("name") { ... }`).

## Code shape

```swift
// In app/ModelOperations.swift (pure, unit-testable, no Cocoa imports)

func shouldForceSidebarRowEmphasis(
    rowTabId: TabId?,
    focusedTabId: TabId?
) -> Bool {
    guard let rowTabId, let focusedTabId else { return false }
    return rowTabId == focusedTabId
}
```

```swift
// In app/SidebarView.swift

final class SidebarRowView: NSTableRowView {
    var forceEmphasizedSelection = false { didSet { needsDisplay = true } }

    // Override isEmphasized so selected rows always draw with AppKit's
    // emphasized color when forceEmphasizedSelection is set. Falls
    // through to super for non-forced rows so normal first-responder
    // behaviour (e.g. inline rename) still works.
    override var isEmphasized: Bool {
        get { (isSelected && forceEmphasizedSelection) || super.isEmphasized }
        set { super.isEmphasized = newValue }
    }
}

// NSOutlineViewDelegate
func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
    let row = SidebarRowView()
    let rowTabId: TabId? = {
        guard let sidebarItem = item as? SidebarItem,
              case .tab(let tab) = sidebarItem.kind else { return nil }
        return tab.id
    }()
    row.forceEmphasizedSelection = shouldForceSidebarRowEmphasis(
        rowTabId: rowTabId,
        focusedTabId: currentModel?.selectedTabId)
    return row
}
```

Notes:
- The `isSelected && ...` guard is technically redundant (AppKit only
  consults `isEmphasized` for selected rows), but it documents intent
  and is harmless.
- The setter passes through to `super` rather than ignoring writes, so
  the `super.isEmphasized` fallback in the OR keeps tracking AppKit's
  natural state -- important for inline rename, where the field editor
  becoming first responder makes the sidebar genuinely emphasized.
- We skip the `makeView(withIdentifier:)` row-view pool. With at most a
  few dozen visible rows, allocating a fresh `SidebarRowView` per call
  is negligible and avoids registering an identifier.
- Tab cell content does not consult `backgroundStyle`
  (`grep backgroundStyle app/*.swift` only matches `ThemeSwatchViews.swift`),
  so we do not need to push `backgroundStyle` down to subviews when
  `forceEmphasizedSelection` toggles.

## Tests

Pure unit tests in `tests/ModelOperationsTests.swift` covering
`shouldForceSidebarRowEmphasis`:

- equal ids -> `true`
- different ids -> `false`
- `rowTabId == nil` (group row) -> `false`
- `focusedTabId == nil` -> `false`
- both nil -> `false`

Run with `just test`.

## Manual verification

Run `just build-run` and check:

1. With one tab + terminal pane focused: that tab renders in the system
   accent color (not grey).
2. With multiple tabs selected (cmd-click / shift-click) and pane
   focused: only the currently-viewed tab is blue; other selected tabs
   stay grey.
3. Switching the viewed tab updates which selected row is blue.
4. Inline rename (double-click a tab title) still highlights the edited
   row correctly -- when the field editor takes focus the sidebar is
   genuinely emphasized, so all selected rows go blue, matching today's
   behavior.
5. Terminal keyboard input still goes to the pane (sidebar
   `acceptsFirstResponder` is unchanged at `false`, line 104 of
   `SidebarView.swift`).
6. Toggle dark mode and a non-blue accent color (System Settings -> Appearance)
   to confirm the row tracks the system accent rather than a hard-coded blue.

## Out of scope

- Multi-select selection semantics, context-menu targeting, drag/drop,
  group/tab reorder.
- Any change to `acceptsFirstResponder` or focus routing.
- Custom selection drawing. If we later want a different visual style,
  swap `outlineView.selectionHighlightStyle` (e.g. to `.sourceList`)
  rather than overriding `drawSelection(in:)`.
