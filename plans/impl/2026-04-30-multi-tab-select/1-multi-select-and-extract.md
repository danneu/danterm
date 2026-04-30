# Multi-select tabs in sidebar + Extract to New Group

## Context

The sidebar's `NSOutlineView` is single-select today: clicking a tab focuses
it and that's the only selection notion. We want:

1. Multi-selection of tabs (cmd-click, shift-click) via
   `allowsMultipleSelection`.
2. A right-click action — "Move to New Group" — that takes the selected
   tabs, creates a fresh group, moves them into it (visual order), and
   begins inline rename of the new group, mirroring `Cmd+N`'s flow.

The "one terminal pane is active" invariant still holds: the focused tab
follows AppKit's `selectedRow` (the most recently selected row in
multi-select mode — see Apple's *Table View Programming Guide*, "Selecting
and Editing"). Multi-selection is a sidebar UI state for batch ops.

## Design decisions

- **New atomic `Msg` case**, not N `.moveTab`s from the view layer. One
  checkpoint per action; pure & unit-testable; ids deduped/validated in
  one place.
- **Default new group name**: `"New group"`, then begin inline rename
  immediately — matching `AppDelegate.newGroup` at
  `app/AppDelegate.swift:372`.
- **Tab order**: visual order in the sidebar, computed from
  `selectedRowIndexes` (which iterates ascending).
- **Selection after extract**: leave `model.selectedTabId` untouched; the
  focused tab still exists, just under a new group.
- **Context-menu target rule (Finder/Mail)**: a single helper resolves
  `[TabId]` from `clickedRow` + `selectedRowIndexes`. If clicked row is
  in the selection, target = all selected tab rows. Else target =
  clicked row only.
- **Reload preserves multi-selection only when consistent with model
  focus.** Today `reload(model:)` snaps to a single row at
  `app/SidebarView.swift:266`. The new rule (extracted as a pure helper):
  preserve the prior multi-selection iff its live subset contains the
  model's `selectedTabId`; otherwise collapse to just `selectedTabId`.
  This lets the user keep a multi-selection across incidental reloads
  while still letting external focus changes (`createTab`, MRU,
  `selectAdjacentTab`, alert navigation) collapse the selection. Live
  ids are computed from `model.groups.flatMap(\.tabs).map(\.id)`, not
  from `tabItemCache` (which is not pruned during `reconcile` and would
  carry stale entries from closed tabs).
- **Extracting every live tab is a no-op.** If the selection covers
  every tab in the model — whether from one group or spanning many —
  the action would prune every source group, leaving the new group as
  the sole group. That's destructive of existing structure *and*
  triggers single-group mode (`isSingleGroupMode` hides group rows), so
  the promised inline rename has no row to edit. Guard with
  `validIds.count == totalTabs` in both `update` (defensive no-op) and
  the menu (skip appending the item).

## Files to modify

### 1. `app/Msg.swift`

Add one case near the existing group/tab cases (~line 30–35):

```swift
case extractTabsToNewGroup(tabIds: [TabId], groupName: String)
```

### 2. `app/Update.swift`

Add a handler that returns exactly `[.reloadSidebar, .scheduleCheckpoint]`
on success, or `[]` on no-op:

```swift
case .extractTabsToNewGroup(let tabIds, let groupName):
    var seen = Set<TabId>()
    let validIds = tabIds.filter { id in
        guard !seen.contains(id), tabLocation(id, in: model) != nil
        else { return false }
        seen.insert(id); return true
    }
    guard !validIds.isEmpty else { return [] }

    // No-op: extracting every live tab (whether from one group or
    // across many) would prune every source group and leave the new
    // group as the sole group, collapsing existing structure and
    // triggering single-group mode where inline rename has no row to
    // edit. Silently skip rather than churn.
    let totalTabs = model.groups.reduce(0) { $0 + $1.tabs.count }
    if validIds.count == totalTabs {
        return []
    }

    let newGroupId = GroupId()
    model.groups.append(GroupModel(id: newGroupId, name: groupName))

    // Reuse .moveTab for tabLocation lookup, index clamping, and
    // removeGroupIfEmpty pruning. Discard nested effects — we emit
    // exactly one reloadSidebar + scheduleCheckpoint at the end.
    for (idx, tabId) in validIds.enumerated() {
        _ = update(&model, .moveTab(
            tabId: tabId, toGroupId: newGroupId, atIndex: idx))
    }
    return [.reloadSidebar, .scheduleCheckpoint]
```

Notes:
- Do **not** reuse `.createGroup` — it auto-creates a tab
  (`app/Update.swift:858-862`), which we don't want.
- `removeGroupIfEmpty` (`app/Update.swift:1201`) inside each nested
  `.moveTab` prunes any source group that loses its last tab.
- New group is appended at the end of `model.groups`, matching
  `.createGroup`.

### 3. `app/SidebarView.swift`

**a. Enable multi-select in `setup()` (~line 154):**
```swift
outlineView.allowsMultipleSelection = true
```

**b. `outlineViewSelectionDidChange` (~line 387):** dispatch `.selectTab`
only when the last-selected tab differs from `currentModel?.selectedTabId`,
to avoid spamming during shift-click range selection:

```swift
func outlineViewSelectionDidChange(_ notification: Notification) {
    guard !isReloading else { return }
    let row = outlineView.selectedRow
    guard row >= 0,
          let item = outlineView.item(atRow: row) as? SidebarItem,
          case .tab(let tab) = item.kind else { return }
    if tab.id != currentModel?.selectedTabId {
        runtime?.send(.selectTab(id: tab.id))
    }
}
```

**c. Pure selection-restore rule** — add to `app/ModelOperations.swift`
so `test.sh`'s existing file list (which already includes
`app/ModelOperations.swift`) compiles it without further script
changes:

```swift
/// Decide which tab rows the sidebar should select after a reload.
/// Preserves the prior multi-selection IFF it still contains the
/// model's focused tab; otherwise collapses to the focused tab alone.
/// Stale ids (closed tabs) are dropped via `liveTabIds`.
func resolveReloadSelection(
    priorSelectedTabIds: Set<TabId>,
    liveTabIds: Set<TabId>,
    selectedTabId: TabId?
) -> Set<TabId> {
    let livePrior = priorSelectedTabIds.intersection(liveTabIds)
    if let sel = selectedTabId,
       liveTabIds.contains(sel),
       livePrior.contains(sel) {
        return livePrior
    }
    if let sel = selectedTabId, liveTabIds.contains(sel) {
        return [sel]
    }
    return []
}
```

**d. Use it in `reload(model:)`** (~line 242):

```swift
func reload(model: AppModel) {
    isReloading = true
    defer { isReloading = false }

    // Snapshot the user's multi-selection by tab id BEFORE reconcile.
    let priorSelectedTabIds: Set<TabId> = Set(
        outlineView.selectedRowIndexes.compactMap { row in
            guard let item = outlineView.item(atRow: row) as? SidebarItem,
                  case .tab(let tab) = item.kind else { return nil }
            return tab.id
        })

    reconcile(model: model)
    outlineView.reloadData()

    // Restore collapse state (unchanged from current code) ...
    if !isSingleGroupMode { /* same as today */ }

    // Liveness derived from the model — NOT tabItemCache, which
    // isn't pruned in reconcile and could carry closed tabs.
    let liveTabIds: Set<TabId> = Set(
        model.groups.flatMap(\.tabs).map(\.id))
    let restoreSet = resolveReloadSelection(
        priorSelectedTabIds: priorSelectedTabIds,
        liveTabIds: liveTabIds,
        selectedTabId: model.selectedTabId)

    // Restore in two phases so AppKit's `selectedRow` (the last
    // selected row, per docs) ends up on `model.selectedTabId` —
    // important for shift-click range start and arrow-key behavior.
    var nonFocusRows = IndexSet()
    var focusRow: Int? = nil
    for id in restoreSet {
        guard let item = tabItemCache[id] else { continue }
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { continue }
        if id == model.selectedTabId {
            focusRow = row
        } else {
            nonFocusRows.insert(row)
        }
    }
    if let f = focusRow {
        if nonFocusRows.isEmpty {
            outlineView.selectRowIndexes(
                IndexSet(integer: f), byExtendingSelection: false)
        } else {
            outlineView.selectRowIndexes(
                nonFocusRows, byExtendingSelection: false)
            outlineView.selectRowIndexes(
                IndexSet(integer: f), byExtendingSelection: true)
        }
    } else {
        outlineView.selectRowIndexes(
            nonFocusRows, byExtendingSelection: false)
    }

    // Scroll the model's currently-selected tab into view (unchanged).
    if let sel = model.selectedTabId,
       let item = tabItemCache[sel] {
        let row = outlineView.row(forItem: item)
        if row >= 0 { outlineView.scrollRowToVisible(row) }
    }
}
```

`isReloading` (already set in the current code) suppresses the
`outlineViewSelectionDidChange` callback during this restore, so no
spurious `.selectTab` is dispatched.

**e. Single context-menu target resolver:**

```swift
/// Finder/Mail rule: if the right-clicked row is part of the current
/// selection, the menu targets the whole selection; otherwise just the
/// clicked row. Returns tab ids in visual (row) order.
private func contextTargetTabIds(clickedRow: Int) -> [TabId] {
    let selected = outlineView.selectedRowIndexes
    let rows: [Int] = selected.contains(clickedRow)
        ? selected.sorted()
        : [clickedRow]
    return rows.compactMap { row in
        guard let item = outlineView.item(atRow: row) as? SidebarItem,
              case .tab(let tab) = item.kind else { return nil }
        return tab.id
    }
}
```

**f. Wire the helper into `SidebarOutlineView.menu(for:)` and the tab
context menu**:

In `SidebarOutlineView.menu(for:)` (~line 50), pass `clickedRow` into a
new `sidebarView?.contextMenu(forTabRowAt:)`. That single entry point
calls `contextTargetTabIds(clickedRow:)` to decide whether to act on a
multi-selection or a single row, and builds the menu using the existing
`contextMenu(for tab:)` content as a base. The "Move to New Group" item
is appended *only if* the action would not be a no-op (i.e. not the
"all tabs in only group" case from the update guard):

```swift
let targetIds = contextTargetTabIds(clickedRow: clickedRow)
let totalTabs = currentModel?.groups.reduce(0) { $0 + $1.tabs.count } ?? 0
let isAllLiveTabs = totalTabs > 0 && targetIds.count == totalTabs
if !targetIds.isEmpty && !isAllLiveTabs {
    let title = targetIds.count > 1
        ? "Move \(targetIds.count) Tabs to New Group"
        : "Move to New Group"
    let extractItem = NSMenuItem(
        title: title, action: #selector(contextExtractTabs(_:)),
        keyEquivalent: "")
    extractItem.target = self
    extractItem.representedObject = TabIdsBox(ids: targetIds)
    menu.addItem(extractItem)
}
```

Where `TabIdsBox` is a tiny `NSObject` carrier (mirrors the existing
`SetTabColorInfo` pattern at `app/SidebarView.swift:1078-1085`):

```swift
private class TabIdsBox: NSObject {
    let ids: [TabId]
    init(ids: [TabId]) { self.ids = ids }
}
```

**g. Action handler — dispatch + begin inline rename** (mirrors
`AppDelegate.newGroup` at `app/AppDelegate.swift:372-381`):

```swift
@objc private func contextExtractTabs(_ sender: NSMenuItem) {
    guard let box = sender.representedObject as? TabIdsBox,
          !box.ids.isEmpty else { return }
    let existingIds = Set(currentModel?.groups.map(\.id) ?? [])
    runtime?.send(.extractTabsToNewGroup(
        tabIds: box.ids, groupName: "New group"))
    // currentModel is updated by the .reloadSidebar effect during send.
    if let newGroup = currentModel?.groups.first(
        where: { !existingIds.contains($0.id) }) {
        let groupId = newGroup.id
        DispatchQueue.main.async { [weak self] in
            self?.beginRenamingGroup(groupId)
        }
    }
}
```

### 4. `tests/UpdateGroupTests.swift`

Mirror the patterns at `testCreateGroupAndMoveTab` (lines 6–23) and
`testMoveTabLeavingEmptyGroupRemovesIt` (lines 312–325). Each test
asserts **both model state and the returned effect array**:

- `testExtractSingleTabToNewGroup` — one tab, source group survives.
  Effects: `[.reloadSidebar, .scheduleCheckpoint]` (exactly).
- `testExtractMultipleTabsSameGroup` — order preserved as given;
  source group survives.
- `testExtractMultipleTabsAcrossGroups` — selection spans groups; new
  group has all in given order; emptied source group is pruned via
  `removeGroupIfEmpty`.
- `testExtractAllTabsFromOnlyGroupIsNoop` — extracting every tab from
  the sole group: returns `[]`, `model.groups` unchanged. Documents the
  rename-impossible/single-group-mode constraint.
- `testExtractAllTabsAcrossMultipleGroupsIsNoop` — multi-group setup
  (e.g. 2 groups, 2 tabs each); selection covers every live tab.
  Returns `[]`, `model.groups` unchanged (no group destruction, no
  collapse to single-group mode).
- `testExtractDedupesAndIgnoresStaleIds` — duplicates collapsed; unknown
  ids dropped; remaining ids still extracted.
- `testExtractAllStaleIdsIsNoop` — *all* input ids stale → returns `[]`,
  `model.groups` unchanged (no empty group created).
- `testResolveContextTargets*` (added to `tests/ModelOperationsTests.swift`
  alongside `resolveContextTargets` itself) — pure function over
  `(clickedRow, selectedRows, tabIdAtRow:)` validating the Finder rule:
    - clicked row in selection → returns selection in row order
    - clicked row not in selection → returns `[clickedRow]` only
    - clicked group row → returns `[]`
- `testResolveReloadSelection*` (also in `tests/ModelOperationsTests.swift`)
  covering:
    - prior multi-selection that contains the focused tab → preserves
      the live subset (drops stale ids)
    - external focus change to a tab outside the prior selection →
      returns `[selectedTabId]`
    - all prior ids stale → returns `[selectedTabId]`
    - `selectedTabId` is itself stale (defensive) → returns `[]`
    - no `selectedTabId` → returns `[]`

To keep the resolver testable without AppKit, extract the row→id mapping
as a parameter:

```swift
func resolveContextTargets(
    clickedRow: Int,
    selectedRows: IndexSet,
    tabIdAtRow: (Int) -> TabId?
) -> [TabId]
```

Place this pure helper in `app/ModelOperations.swift` (the same module
that hosts `resolveReloadSelection`); `test.sh` already compiles that
file. The view-side method calls into it. This keeps risky predicates
unit-tested rather than relying on manual UI verification, and avoids
the need to edit `test.sh` to add a new file.

## Out of scope

- Menu-bar item / keyboard shortcut for "Move to New Group". A follow-up
  can add it under the `Tab` menu (`app/AppDelegate.swift:256-260`),
  using the `[.command, .shift]` modifier convention.
- Drag-out-of-sidebar to create a new group.
- Multi-select for group rows (groups are not selectable today;
  `shouldSelectItem` filters them at `app/SidebarView.swift:381`).

## Verification

1. `just test` — new `UpdateGroupTests` cases must pass, including the
   effect-array assertions; `resolveContextTargets` cases pass.
2. `just build-run` — launch the dev build (`com.danneu.danterm-dev`).
3. Manual end-to-end:
   - One group + several tabs: cmd-click two tabs, right-click in the
     selection → menu reads "Move 2 Tabs to New Group". Choose it. A
     new group named "New group" appears at the bottom containing
     exactly those two tabs in their visual order; the existing group
     keeps the rest; the active terminal pane is unchanged; the new
     group's name is in inline-rename mode.
   - Multiple groups: select tabs spanning two groups; extract. Order
     follows top-to-bottom of the sidebar; any source group that loses
     its last tab disappears.
   - Right-click a row that is **not** in the multi-selection: action
     targets only that row (Finder semantics).
   - Single-row right-click (no extra selection): menu reads "Move to
     New Group" (singular).
   - Shift-click range select: focused terminal updates only when the
     last-selected row (`outlineView.selectedRow`) actually changes,
     i.e. `.selectTab` is not re-fired for already-focused tabs.
   - Multi-selection survives an unrelated reload: with a multi-selection
     that includes the focused tab, trigger something that causes
     `reload(model:)`. Selection is preserved.
   - `selectedRow` stays on the focused tab after multi-selection
     restore: select rows {row 0, row 1, row 2}, with the focused tab
     at row 1. After a reload, `outlineView.selectedRow` returns 1
     (not 2 — this verifies the two-phase non-focus-then-focus restore
     ordering). Sanity-check by then issuing a shift-Down arrow and
     confirming the range extends from row 1.
   - External focus change collapses multi-selection: with a
     multi-selection, fire `Cmd+]` (`.selectAdjacentTab`) so the model
     focuses a tab outside the selection. After reload, only the new
     focused tab is highlighted (no stale rows).
   - Extracting every live tab is rejected — both shapes:
     - One group containing all open tabs, select them all → "Move to
       New Group" menu item is hidden.
     - Multiple groups, select every tab across them → menu item is
       still hidden (no group structure destruction).
   - Inline rename of the new group via right-click → Rename Group
     still works (regression sanity check).
