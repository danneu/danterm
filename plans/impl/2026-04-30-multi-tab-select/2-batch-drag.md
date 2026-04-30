# Fix multi-tab sidebar drag (only the topmost tab moves)

## Context

Multi-select shipped (see `plans/wip/yes-plan-the-migration-quirky-kite.md`),
but dragging a multi-tab selection only moves the topmost tab. The
"Move to New Group" context-menu action still works correctly because it
goes through `extractTabsToNewGroup` with the full id list; the bug is
isolated to drag-and-drop.

**Root cause** (verified): `pasteboardWriterForItem` is invoked once per
dragged row and correctly produces N pasteboard items, but `acceptDrop`
at `app/SidebarView.swift:574-589` reads `pb.string(forType:)` — which
returns the string from the *first* matching pasteboard item, not all.
`pb.pasteboardItems` is the canonical path; the codebase already uses
that pattern in `.cmux-src/Sources/TerminalController.swift`.

## Design decisions

- **New atomic `Msg.moveTabs(tabIds: [TabId], toGroupId: GroupId, atIndex: Int)`**
  — same shape as the existing `.moveTab` and `.extractTabsToNewGroup`
  primitives. One checkpoint per drop; pure & unit-testable; ids
  deduped/validated in one place; one `.reloadSidebar` regardless of
  N. Keep the old `.moveTab` case (used by tests and as a primitive
  inside `extractTabsToNewGroup`).
- **Multi-tab insertion semantics (Finder-style)**: the dropped
  selection lands contiguously starting at the visual drop position,
  preserving its visual (input) order. Implementation:
  1. Compute `removedBeforeAnchor` = count of moved tabs in the
     destination group whose pre-removal index is `< atIndex`.
  2. Remove all selected tabs from their source groups (no pruning yet).
  3. Re-look-up the destination group index (it does not shift from
     tab-only removals; we keep the look-up defensively).
  4. `adjustedIndex = clamp(atIndex - removedBeforeAnchor, 0,
     dstTabsCountAfterRemoval)`.
  5. Insert the moved tabs in input order at `adjustedIndex`.
  6. Prune empty source groups via `removeGroupIfEmpty` (excluding the
     destination, which now has tabs again).
- **Order**: trust the input order (already top-to-bottom because
  `pasteboardWriterForItem` is invoked in row order).
- **Single-tab fast path**: not added. A single dragged tab still
  produces one pasteboard item; the new handler treats N=1 correctly
  and matches the existing `.moveTab` semantics for that case.
- **`validateDrop` is untouched.** It only needs to know the drag *is*
  a tab drag (vs group / pane); reading the first pasteboard item's
  type is sufficient signal. Groups are not selectable
  (`shouldSelectItem` at `app/SidebarView.swift:427-430`), so a
  multi-row drag is always all-tabs.

## Files to modify

### 1. `app/Msg.swift`

Add one case directly after `.moveTab` (~line 33):

```swift
case moveTabs(tabIds: [TabId], toGroupId: GroupId, atIndex: Int)
```

### 2. `app/Update.swift`

Add a handler near `.moveTab` (~line 916) that returns
`[.reloadSidebar, .scheduleCheckpoint]` on success or `[]` on no-op:

```swift
case .moveTabs(let tabIds, let toGroupId, let atIndex):
    var seen = Set<TabId>()
    let validIds = tabIds.filter { id in
        guard !seen.contains(id), tabLocation(id, in: model) != nil
        else { return false }
        seen.insert(id); return true
    }
    guard !validIds.isEmpty,
          let dstGroupIdx = model.groups.firstIndex(where: { $0.id == toGroupId })
    else { return [] }

    // Pre-removal: how many of the moved tabs sit above atIndex in dst?
    // Their removal will shift the anchor left.
    let validIdSet = Set(validIds)
    let dstTabsPre = model.groups[dstGroupIdx].tabs
    let prefixCount = max(0, min(atIndex, dstTabsPre.count))
    let removedBeforeAnchor = dstTabsPre.prefix(prefixCount)
        .filter { validIdSet.contains($0.id) }.count

    // Collect the actual TabModel values in input order, then remove
    // from each source. Track source group ids for later pruning
    // (excluding dst — we'll re-insert into it).
    var movedTabs: [TabModel] = []
    var sourceGroupIdsToPrune: [GroupId] = []
    for id in validIds {
        guard let (gIdx, tIdx) = tabLocation(id, in: model) else { continue }
        let srcGroupId = model.groups[gIdx].id
        let tab = model.groups[gIdx].tabs.remove(at: tIdx)
        movedTabs.append(tab)
        if srcGroupId != toGroupId
           && !sourceGroupIdsToPrune.contains(srcGroupId) {
            sourceGroupIdsToPrune.append(srcGroupId)
        }
    }

    // Re-resolve dst index defensively (tab-only removals don't change
    // group ordering, but keep the lookup cheap & safe).
    guard let newDstGroupIdx = model.groups.firstIndex(where: { $0.id == toGroupId })
    else { return [] }

    let dstCount = model.groups[newDstGroupIdx].tabs.count
    let adjustedIndex = max(0, min(atIndex - removedBeforeAnchor, dstCount))

    for (offset, tab) in movedTabs.enumerated() {
        model.groups[newDstGroupIdx].tabs.insert(
            tab, at: adjustedIndex + offset)
    }

    // Prune empty source groups (dst always has tabs after insertion).
    for sgid in sourceGroupIdsToPrune {
        removeGroupIfEmpty(sgid, from: &model)
    }

    return [.reloadSidebar, .scheduleCheckpoint]
```

Notes:
- Generalizes the single-tab `if srcGroupIdx == dstGroupIdx && tabIdx <
  atIndex { adjustedIndex -= 1 }` adjustment from `.moveTab` (line
  922-925): `removedBeforeAnchor` is exactly that count over the batch.
- Reuses `tabLocation` (`app/ModelOperations.swift`) and
  `removeGroupIfEmpty` (`app/Update.swift:1201`) — same primitives the
  existing `.moveTab` and `.extractTabsToNewGroup` handlers use.

### 3. `app/SidebarView.swift`

Replace the single-id read in `acceptDrop` (~line 574-589) with a
multi-item read. Since `validateDrop` already accepted `.move` based on
the pasteboard signaling tab drag, we know all items are tab items.

```swift
func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                 item: Any?, childIndex index: Int) -> Bool {
    let pb = info.draggingPasteboard

    // Multi-row drags put one NSPasteboardItem per row on the
    // pasteboard. Read them all, not just the first.
    let tabIds: [TabId] = (pb.pasteboardItems ?? []).compactMap { pbItem in
        guard let str = pbItem.string(forType: SidebarView.tabDragType),
              let raw = UUID(uuidString: str) else { return nil }
        return TabId(rawValue: raw)
    }
    if !tabIds.isEmpty {
        let targetGroupId: GroupId
        if isSingleGroupMode {
            guard let model = currentModel else { return false }
            targetGroupId = model.groups[0].id
        } else if let sidebarItem = item as? SidebarItem,
                  case .group(let group) = sidebarItem.kind {
            targetGroupId = group.id
        } else {
            return false
        }
        runtime?.send(.moveTabs(
            tabIds: tabIds, toGroupId: targetGroupId, atIndex: index))
        return true
    }

    // group / pane branches unchanged below ...
}
```

The group-drag (`groupDragType`) and pane-drag (`paneDragType`)
branches in this same function are unchanged — groups aren't multi-
selectable, and pane drags originate from a single source view.

### 4. `tests/UpdateGroupTests.swift`

Append. Each test asserts both model state and the exact effect array:

- `testMoveTabsCrossGroup` — selection from group A into group B
  (existing tabs in B), drop in the middle. Verify order, src group
  state, dst group state, effects = `[.reloadSidebar, .scheduleCheckpoint]`.
- `testMoveTabsIntraGroupShiftDown` — same group, drop *after* the
  selection. Verifies `removedBeforeAnchor` adjustment.
  Example: `[a, b, c, d]`, move `{b, c}` to atIndex=4 → `[a, d, b, c]`.
- `testMoveTabsIntraGroupShiftUp` — same group, drop *before* the
  selection. Example: `[a, b, c, d]`, move `{c, d}` to atIndex=0 →
  `[c, d, a, b]`.
- `testMoveTabsIntraGroupAnchorBetweenSelected` — selection straddles
  the anchor. Example: `[a, b, c, d]`, move `{a, c}` to atIndex=3 →
  verify the documented Finder-style result.
- `testMoveTabsCrossGroupEmptiesSourceAndPrunes` — selection covers
  every tab in the source group; source is pruned, destination has
  the new tabs in order.
- `testMoveTabsDedupesAndIgnoresStaleIds` — duplicates collapsed,
  unknown ids dropped; remaining ids still moved.
- `testMoveTabsAllStaleIdsIsNoop` — all ids stale → returns `[]`,
  groups unchanged.
- `testMoveTabsClampedAtIndex` — `atIndex` past the destination end
  clamps to append; negative `atIndex` clamps to 0.

No new pure helpers introduced — `removedBeforeAnchor` is computed
inline in the handler and is already exercised through these tests.
The existing pure-helper tests (`resolveReloadSelection`,
`resolveContextTargets`) remain unchanged.

## Out of scope

- A drag-out-of-sidebar gesture that creates a new group (existing
  out-of-scope item from the prior plan; still out of scope).
- Reordering whole groups via multi-row drag (groups aren't selectable).

## Verification

1. `just test` — new tests must pass; the full suite (currently
   627/627 + the 7 new = 634) stays green.
2. `just build-run`.
3. Manual end-to-end:
   - **Cross-group multi-drag** (the bug repro): with two groups,
     cmd-click 3 tabs in group A, drag to a position inside group B.
     All 3 tabs move and land contiguously at the drop position in
     visual (top-to-bottom) order. The active terminal pane is
     unchanged.
   - **Intra-group reorder, dropping below the selection**: select
     `{tab2, tab3}` of `[tab1, tab2, tab3, tab4]`, drop after `tab4`.
     Result `[tab1, tab4, tab2, tab3]`.
   - **Intra-group reorder, dropping above the selection**: select
     `{tab3, tab4}`, drop before `tab1`. Result `[tab3, tab4, tab1, tab2]`.
   - **Source group drained**: in a 2-group setup where group A has
     exactly the selected tabs, drag them all into group B. Group A
     disappears (pruned).
   - **Single-tab drag still works**: drag one tab between groups.
     Behaves as before (the new handler degrades correctly to N=1).
   - **Multi-selection survives the drop**: after the drop, the moved
     tabs remain selected at their new positions (driven by the
     existing `resolveReloadSelection` in `reload(model:)`, which
     preserves the prior selection set when it still contains the
     focused tab).
