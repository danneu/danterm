# Step 2: Per-tab persistent content containers

## Context

Step 1 (already shipped) added `effectiveSurfaceVisibility(in:windowVisible:)` in
`app/ModelOperations.swift:61` and `syncSurfaceVisibility()` in
`app/AppRuntime.swift:334`. Per-tab occlusion now fans out correctly via
`ghostty_surface_set_occlusion`: libghostty knows which surfaces are actually
visible and drops the non-visible ones' renderer threads to `.utility` QoS.

What step 1 did NOT fix is the AppKit waste. Today, `rebuildContentView` at
`app/AppRuntime.swift:1406` is a sledgehammer: every tab switch tears down the
entire NSView wrapper hierarchy under `contentArea` and rebuilds it from
scratch. `TerminalView`s persist (they live in `runtime.surfaces`), but every
`SplitContainerView`, `PaneSplitView`, `PaneWrapperView`, search overlay, etc.
is destroyed and re-created. On large trees this is measurable; on small ones
it is structural noise that makes the runtime harder to reason about (state
lives both in the model and in transient view objects).

The fix: treat the view hierarchy as a pure projection of the model. Each tab
gets its own persistent `SplitContainerView` mounted as a sibling under
`contentArea`. Tab switch becomes `isHidden = ...` flips on those siblings
plus a small finalize block. Real rebuilds (splits, zoom, snapshot restore,
pane close) become scoped to a single tab's container instead of the whole
content area.

## Design

```
contentArea
  +- SplitContainerView(tabA)     isHidden = (selectedTabId != A)
  +- SplitContainerView(tabB)     isHidden = (selectedTabId != B)
  +- ...
  +- themeBrowserView (when present, kept on top)
```

- Lazy mount: a tab's container is created the first time the tab becomes
  selected. This preserves snapshot-restore characteristics (only the
  selected tab's panes are attached to the window on launch today) and
  avoids paying view-tree cost for tabs the user never visits.
- On tab switch: lazy-create the new tab's container if needed, flip
  `isHidden` on the old and new containers, then run a small finalize block
  (focus borders, first responder, search overlay rehydration).
- On tab-internal changes (split add/remove, zoom toggle, pane move within
  tab, navigateToPane with zoom clear): rebuild just the affected tab's
  container, in place. Behaves like today's `rebuildContentView`, scoped
  to one tab.
- On tab close (or any tab removal): remove the tab's container from
  `contentArea` and drop the dict entry.

Step 1's pure visibility computation is untouched. It already returns the
right answer for every model state ("only the selected tab's surfaces are
visible, modulo zoom"), and step 2 doesn't change the model.
`syncSurfaceVisibility()` continues to run at the end of every `send()`.

## New effects (pivot: replace `.rebuildContentView`)

Replace the single overloaded `.rebuildContentView` effect with three
explicitly-named effects. Keeping the old name and silently changing its
semantics would let missed migrations slip in as silent visual no-ops; new
names make the intent visible at every emit site and force every caller
to choose deliberately.

`app/Effect.swift`:

- Remove `case rebuildContentView`.
- Add `case showSelectedTab` -- ensure the selected tab is visible
  (lazy-create its container if needed, flip `isHidden` on siblings,
  finalize selection: focus borders, first responder, search overlay,
  toolbars, titlebar, tab-todo badge).
- Add `case rebuildTabContainer(tabId: TabId)` -- tear down and rebuild
  one tab's view tree in place. If that tab is the selected tab, the
  rebuilt container is finalized; if hidden, it stays hidden.
- Add `case removeTabContainer(tabId: TabId)` -- detach and discard a
  tab's view tree.

These three effects can **stack** within a single `Msg`. They are
orthogonal:

- `.removeTabContainer` is about *which containers exist*.
- `.rebuildTabContainer` is about *the contents of one container*.
- `.showSelectedTab` is about *which container is visible*.

## Emission rule (apply to every Update.swift case)

Every `Msg` handler must emit effects according to these three rules, in
any order (the runtime processes them in emit order):

1. If the handler **changes `model.selectedTabId`** -> emit
   `.showSelectedTab`.
2. If the handler **structurally mutates `tab.rootNode`** (leaves
   added, removed, or rearranged), or **flips `tab.isZoomed`**, or
   **changes `tab.focusedPaneId` while the tab is zoomed** for some
   tab T -> emit `.rebuildTabContainer(tabId: T.id)`. Repeat for
   every tab touched. Applies whether T is selected or hidden.

   **Explicit exclusion:** `.splitRatioChanged` at `Update.swift:1189`
   mutates `tab.rootNode` via `setRatio` but only updates a divider
   ratio (no structural change). It must NOT emit
   `.rebuildTabContainer` -- rebuilding during divider drags would
   churn the view tree and interrupt the interaction. The existing
   test at `tests/UpdatePaneTests.swift:86` asserts splitRatioChanged
   emits only `.scheduleCheckpoint`; preserve this.
3. If the handler **removes a tab** T from the model -> emit
   `.removeTabContainer(tabId: T.id)`. Pair with `.destroySurface`
   for **every pane in T**, not just the pane that triggered the
   removal (existing pattern for closeTabBody and deleteGroup; new
   requirement for `surfaceCreationFailed` -- see below). Emit
   `.destroySurface` first, then `.removeTabContainer` (logical
   lifecycle order).

A single handler can emit any subset of the three, and which rules
fire can depend on the runtime branch taken. For example,
`.movePaneToTab` always mutates target rootNode (rule 2) and changes
selectedTabId (rule 1). For the source it depends on survival: if the
source tab keeps other panes it mutates source rootNode (rule 2,
`.rebuildTabContainer(source)`); if the moved pane was the source's
only pane the source tab is removed (rule 3,
`.removeTabContainer(source)`). So the emitted set is either
`.rebuildTabContainer(source) + .rebuildTabContainer(target) +
.showSelectedTab` (source survives) or `.removeTabContainer(source) +
.rebuildTabContainer(target) + .showSelectedTab` (source emptied).

## Update.swift emitter migration

Migrate every existing `.rebuildContentView` emitter (and every tab
removal site) per the emission rule. Line numbers are from current
`app/Update.swift`.

| Line  | Handler                                  | Effects to emit                                                                                                       |
| ----- | ---------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| 111   | `.createTab` non-background              | `.showSelectedTab` (new tab is selected; lazy-create flow handles "no container yet")                                 |
| 215   | `.splitPane`                             | `.rebuildTabContainer(tabId: tab.id)`                                                                                 |
| 264   | `.closePane` (more panes remain)         | `.rebuildTabContainer(tabId: tab.id)`                                                                                 |
| 297   | `.movePane` (within selected tab)        | `.rebuildTabContainer(tabId: model.selectedTabId)`                                                                    |
| 354   | `.movePaneToTab` (source survives)       | `.rebuildTabContainer(sourceTabId) + .rebuildTabContainer(targetTabId) + .showSelectedTab`                            |
| 354   | `.movePaneToTab` (source emptied)        | `.removeTabContainer(sourceTabId) + .rebuildTabContainer(targetTabId) + .showSelectedTab`. Source tab held only the moved pane, so `removeTab(sourceTab.id, ...)` at `Update.swift:337` deletes it (rule 3). NO `.destroySurface` -- the pane lives in target now. Must NOT emit `.rebuildTabContainer(sourceTabId)`: the tab is gone, so that effect would no-op via `rebuildTabContainer`'s `tabById` guard and orphan the source container. |
| 426   | `.movePaneToNewTab` Path A (single-pane) | `.showSelectedTab` only. Source tab is the moved tab; its id persists, rootNode unchanged. No rebuild, no remove.     |
| 426   | `.movePaneToNewTab` Path B (multi-pane)  | `.rebuildTabContainer(sourceTabId) + .showSelectedTab` (new tab's container is lazy-built when shown)                 |
| 520   | `.focusDirection` zoom-clear branch      | `.rebuildTabContainer(tabId: tab.id)`                                                                                 |
| 855   | `.surfaceCreationFailed` (tab removed)   | See "surfaceCreationFailed orphan fix" below. `.destroySurface(paneId:)` for every pane in the failed tab + clean per-pane model state for each + `.removeTabContainer(tabId: failedTabId)`. If the failed tab was the **last** tab in the model: also append `.terminate` (preserves existing behavior at line 870-871). Else if selection moved to a fallback tab: also append `.showSelectedTab`. |
| 1056  | `.deleteGroup` moveTabs:false            | `.removeTabContainer(tabId:)` for **every** removed tab + `.showSelectedTab` (if selection moved)                     |
| 1179  | `.toggleZoomPane` (un-zoom)              | `.rebuildTabContainer(tabId: tab.id)`                                                                                 |
| 1183  | `.toggleZoomPane` (enter zoom)           | `.rebuildTabContainer(tabId: tab.id)`                                                                                 |
| 2309  | `applySelectTab`                         | `.showSelectedTab` (replaces existing `.rebuildContentView`)                                                          |
| 2425  | `navigateToPane` zoom-clear branch       | `.rebuildTabContainer(tabId: currentTab.id)` (in addition to whatever `.showSelectedTab` source applies below)        |
| 2431  | `navigateToPane` unconditional refresh   | Drop the unconditional `.rebuildContentView`. Same-tab path: explicitly emit `.showSelectedTab` (inner `.selectTab` returned `[]`). Cross-tab path: rely on `.showSelectedTab` from the inner `.selectTab`. See navigateToPane detail below. |
| 2626  | `closeTabBody` (closed tab, fallback)    | `.removeTabContainer(tabId: closedTabId)` always + `.showSelectedTab` (if fallback selected)                          |

### Detail on `navigateToPane` (Update.swift:2413)

Today the function calls `update(&model, .selectTab(id: currentTab.id))`
to get selection effects, then unconditionally appends
`.rebuildContentView` because the inner `.selectTab` is a no-op when the
target tab is already selected (`applySelectTab` at line 2296 early-
exits with `guard id != model.selectedTabId else { return [] }`).

**Keep `applySelectTab`'s same-tab no-op.** `.showSelectedTab` runs
`prepareForViewSwap()`, which `cancelPaneDrag`, dismisses pane/tab
todo popovers, and clears `model.todoPopover`. Forcing `applySelectTab`
to emit on the no-op path would change today's user-visible behavior:
clicking the already-selected tab in the sidebar (or sending the same
`.selectTab` via IPC) would suddenly close open popovers and cancel
in-progress drags. That's a regression unrelated to step 2's intent.

Under the new model:

- `applySelectTab` stays a same-tab no-op (returns `[]` when
  `id == model.selectedTabId`). Its only step-2 change is swapping
  `.rebuildContentView` for `.showSelectedTab` on the actual
  selection-change path.
- `navigateToPane` (which DOES want a finalize on the same-tab
  refresh-borders path) explicitly emits `.showSelectedTab` when the
  inner `.selectTab` returned `[]`. Pattern:

  ```swift
  var effects = update(&model, .selectTab(id: currentTab.id))
  let tabSwitched = !effects.isEmpty
  // ... model mutations (focusedPaneId, zoom clear) ...
  if !tabSwitched {
      effects.append(.showSelectedTab)   // same-tab refresh path
  }
  if wasZoomed, paneId != oldFocusedPaneId {
      effects.append(.rebuildTabContainer(tabId: currentTab.id))
  }
  // drop the prior unconditional .rebuildContentView at line 2431
  ```

This isolates the "finalize without a selectedTabId change" need to
the one caller that actually needs it. The emission rule is
unchanged: rule 1 ("selectedTabId changed -> .showSelectedTab") still
holds; `navigateToPane` just appends an extra `.showSelectedTab` on
its same-tab path as a deliberate refresh request.

### Tab removal sites

Audit every model mutation that removes a tab and pair with
`.removeTabContainer`. Sites identified:

- `closeTabBody` at Update.swift:2620 -- `model.groups[groupIdx].tabs.remove(at: tabIdx)`
- `movePaneToTab` at Update.swift:337 -- `removeTab(sourceTab.id, from: &model)` on the source-emptied branch (the moved pane was the source's only pane). Pair with `.removeTabContainer(sourceTabId)`, NOT `.rebuildTabContainer(sourceTabId)` (see the split table row above). No `.destroySurface`: the pane moved to the target tab, it was not closed.
- `surfaceCreationFailed` at 865 -- `model.groups[gi].tabs.remove(at: ti)`
- `.deleteGroup` moveTabs:false at 1048 -- `model.groups.remove(at: idx)` (cascades through all tabs in that group)
- `.movePaneToNewTab` Path A at 387 -- `tabs.remove(at: srcTabIdx)` followed by `tabs.insert(...)` in destination. **Not a removal** -- same tab entity moves between groups. No `.removeTabContainer` needed.

`removeGroupIfEmpty` (called from several sites) only removes empty
groups; it does not remove tabs. No new effects needed there.

### `surfaceCreationFailed` orphan fix

Today, `surfaceCreationFailed` at `Update.swift:855` cleans only the
**failed** pane from `model.panes` / alerts / search / notification
throttle (lines 856-859), then removes the entire containing tab from
the model (line 865) without touching its siblings. If the failed
pane is from a `.splitPane` (so the tab has working sibling panes),
their `ghostty_surface_t` stays in `runtime.surfaces` (no
`.destroySurface` emitted) and their per-pane state stays in
`model.panes` / alerts / search. The surfaces leak; their tokens
linger; `syncSurfaceVisibility` (`AppRuntime.swift:329`) defaults
unmodeled surfaces to visible, so they keep rendering at
`.user_interactive` QoS.

This is a pre-existing bug, but step 2 makes "tab removed via
surfaceCreationFailed" a place we explicitly pair with
`.removeTabContainer`, so we may as well fix the orphan path in the
same change:

- Before removing the tab from the model, collect `allPaneIds(tab.
  rootNode)` for the failed tab.
- For every pane id in that set, emit `.destroySurface(paneId:)` and
  clean `model.panes` / `removeAlertsForPane` / `removePaneSearch
  State` / `lastNotificationTime`. Match the cleanup block that
  `.deleteGroup(moveTabs: false)` already uses
  (`Update.swift:1040-1045`) for consistency.
- Then remove the tab from the model (existing line 865) and emit
  `.removeTabContainer(tabId:)`.
- Preserve the existing "last tab in model" branch
  (`Update.swift:870-871`): if removing this tab leaves
  `model.groups.flatMap(\.tabs)` empty, emit the destroySurface
  block + `.removeTabContainer(tabId:)` + `.terminate`. Do NOT skip
  the cleanup just because the process is exiting -- keeping the
  emission shape uniform avoids ambiguity and lets the test list
  assert one consistent pattern.

### Direct call to `rebuildContentView()` at `app/AppRuntime.swift:1276`

`commitRestoreSession` calls `rebuildContentView()` directly today,
counting on it to (a) tear down all subviews of `contentArea` and
then (b) build the new selected tab's tree. Under step 2,
`showSelectedTab()` does NOT tear down subviews -- it lazy-creates
the selected tab's container and flips `isHidden`. That leaves the
prior session's `SplitContainerView`s mounted under `contentArea`
and tracked in `tabContainers`, where they shadow the new session.

`tearDownCurrentSession()` at `app/AppRuntime.swift:1238` is the
existing teardown helper (closes surfaces, dismisses popovers,
cancels drags, clears `surfaceVisibility`). Extend it to also:

- Call `removeTabContainer(tabId:)` for every entry in `tabContainers`
  (or equivalently, iterate `tabContainers.values`, call
  `removeFromSuperview()`, then `tabContainers.removeAll()`).

After `tearDownCurrentSession()`, `commitRestoreSession` calls
`showSelectedTab()` instead of `rebuildContentView()`. The selected
tab's container is lazy-built fresh from the restored model;
non-selected tabs' containers are lazy and will be built on first
visit. Surfaces remain persistent in the staged `surfaces` dict.

## New AppRuntime helpers

Replace `rebuildContentView()` at `app/AppRuntime.swift:1406` with
`showSelectedTab()` (and friends). Shape:

```swift
private var tabContainers: [TabId: SplitContainerView] = [:]

// Pre-view-swap cleanup shared by showSelectedTab and rebuildTabContainer.
// Both can destroy view anchors (split tree, pane wrappers) that popovers,
// drags, and tab-todo state may have referenced.
private func prepareForViewSwap() {
    cancelPaneDrag()
    dismissTodoPopoverPair()
    dismissTabTodoPopoverPair()
    model.todoPopover = nil
}

private func showSelectedTab() {
    guard let contentArea, let tab = selectedTab(in: model) else { return }
    prepareForViewSwap()

    let browserFocus = themeBrowserView?.captureFocusTarget()

    for (tid, container) in tabContainers where tid != tab.id {
        container.isHidden = true
    }
    let container = ensureTabContainer(for: tab)
    container.isHidden = false

    finalizeTabSelection(tab: tab, container: container, browserFocus: browserFocus)
}

private func ensureTabContainer(for tab: TabModel) -> SplitContainerView {
    if let existing = tabContainers[tab.id] { return existing }
    return buildAndInsertContainer(for: tab)
}

private func buildAndInsertContainer(for tab: TabModel) -> SplitContainerView {
    guard let contentArea else { fatalError() }
    let displayNode: SplitNodeModel = tab.isZoomed ? .leaf(tab.focusedPaneId) : tab.rootNode
    let hasSplits: Bool = { if case .leaf = tab.rootNode { return false } else { return true } }()
    let container = SplitContainerView(
        rootNode: displayNode,
        surfaceLookup: { [weak self] pid in self?.surfaces[pid] },
        runtime: self,
        isZoomed: tab.isZoomed,
        hasSplits: hasSplits,
        frame: contentArea.bounds
    )
    container.autoresizingMask = [.width, .height]
    // Stay below the theme browser so it remains on top across tab switches.
    if let browser = themeBrowserView {
        contentArea.addSubview(container, positioned: .below, relativeTo: browser)
    } else {
        contentArea.addSubview(container)
    }
    container.rebuild()
    tabContainers[tab.id] = container
    return container
}

private func rebuildTabContainer(_ tabId: TabId) {
    guard let tab = tabById(tabId, in: model) else { return }
    guard let existing = tabContainers[tabId] else { return }   // never selected -> nothing to rebuild
    let wasHidden = existing.isHidden
    // Only the visible tree owns popover/drag anchors. Rebuilding a hidden
    // tab (e.g. a background .splitPane via IPC, or the now-hidden source of
    // a cross-tab move) must NOT dismiss the visible tab's popovers or cancel
    // its in-progress drag. A hidden tab can't hold a live popover anyway --
    // it was dismissed when the tab was hidden.
    if !wasHidden { prepareForViewSwap() }
    existing.removeFromSuperview()
    tabContainers.removeValue(forKey: tabId)
    let container = buildAndInsertContainer(for: tab)
    container.isHidden = wasHidden
    if !wasHidden {
        let browserFocus = themeBrowserView?.captureFocusTarget()
        finalizeTabSelection(tab: tab, container: container, browserFocus: browserFocus)
    }
}

private func removeTabContainer(_ tabId: TabId) {
    guard let container = tabContainers.removeValue(forKey: tabId) else { return }
    container.removeFromSuperview()
}
```

`finalizeTabSelection` is the portion of today's `rebuildContentView`
that runs AFTER the SplitContainerView is constructed: focus borders,
first responder, search overlay rehydration,
`refreshPaneToolbars`/`refreshContentTitlebar`/`refreshTabTodoButton`,
theme browser focus restore. Extract as a private helper so both
`showSelectedTab` and `rebuildTabContainer` (selected path) can call it.
Reuse existing helpers (`allPaneIds`, `isFocusedAndVisible`,
`paneHasUnreadAlert`, `setFocusBorder`, `findPaneWrapper(for:in:)`,
`showSearchOverlay`).

**Scope per-pane walks to the tab's container, not `contentArea`.**
Today `refreshPaneToolbars()` walks `forEachPaneWrapper(in: contentArea)`
and the search-overlay rehydration loop calls `findPaneWrapper(for:in:
contentArea)`. That was correct under step 1 because `contentArea` held
exactly one container. Under step 2 `contentArea` holds one sibling per
visited tab, so a `contentArea`-rooted walk would touch hidden tabs'
wrappers on every finalize -- wasted work, and conceptually wrong (a
hidden tab's toolbars/overlays should refresh on its own next show, via
its own finalize). Change `refreshPaneToolbars()` to
`refreshPaneToolbars(in container: NSView)` and have
`finalizeTabSelection` pass the tab's `container`; line 1467 (inside
today's `rebuildContentView`) is its only caller, so the signature change
is local. Likewise root the search-overlay rehydration loop and its
focus-the-search-field `findPaneWrapper` lookup at `container` rather
than `contentArea`. (Both work today only because paneIds are globally
unique; walking just `container` is faster and obviously correct.) Leave
the singular `refreshPaneToolbar(for:)` and the `.showSearchOverlay`
effect arm's `findPaneWrapper(for:in: contentArea)` calls untouched --
those target one globally-unique paneId and still resolve against the
full `contentArea` correctly.

The `perform` arm in `AppRuntime` gains three new cases
(`.showSelectedTab`, `.rebuildTabContainer`, `.removeTabContainer`) and
loses `.rebuildContentView`.

## Constraints / what survives a hidden state

Verified during exploration:

- `SearchOverlayView` is a subview of `PaneWrapperView`
  (`app/PaneWrapperView.swift:296`). Persists across tab switch with
  search text intact. First responder reapplied in
  `finalizeTabSelection` (same logic as today, lines 1481-1483).
- `ScrollableTerminalView` observers are `NotificationCenter`-based
  (`app/ScrollableTerminalView.swift:74`); they fire regardless of
  `isHidden`. State stays coherent.
- `viewDidChangeBackingProperties` fires on every view in the window's
  hierarchy when backing store changes. All tab containers remain in
  the hierarchy under step 2 (just hidden), so they receive these
  notifications and resync content scale. Verify with a Retina toggle
  in QA.
- `viewDidMoveToWindow` does NOT fire on `isHidden` flips. Fine: window
  doesn't change, surface stays attached.
- Layout: AppKit skips layout for `isHidden=true` subtrees. On un-hide,
  layout cascades and `TerminalView.setFrameSize` (`app/TerminalView.swift`)
  calls `ghostty_surface_set_size`. Split ratios survive because
  `NSSplitView` retains divider positions.
- `PaneDragCoordinator`: `cancelPaneDrag()` is in `prepareForViewSwap`,
  so it fires on both `showSelectedTab` and `rebuildTabContainer`.

## Out of scope (flag but do not fix here)

- Multi-monitor display-ID resync. `ghostty_surface_set_display_id`
  is only called from `TerminalView.viewDidMoveToWindow` at
  `app/TerminalView.swift:174`. Broken for hidden tabs today too; step
  2 makes hidden-tab the common case but does not introduce the bug.
  Follow-up: add `NSWindow.didChangeScreenNotification` observer in
  `AppRuntime` that walks `surfaces.values`.
- Theme browser as a child window / sheet. The overlay pattern works
  with step 2 (z-order handled in `buildAndInsertContainer`) but feels
  fragile. Track separately.
- `rebuildTabContainer` is not free -- same cost as today's
  `rebuildContentView` for the affected tab. Only tab switch becomes
  cheap. Acceptable for step 2.

## Files to modify

- `app/Effect.swift` -- remove `rebuildContentView`; add
  `showSelectedTab`, `rebuildTabContainer(tabId:)`,
  `removeTabContainer(tabId:)`.
- `app/Update.swift` -- migrate every `.rebuildContentView` emitter per
  the table above; emit `.removeTabContainer(tabId:)` at every tab-
  removal site; keep `applySelectTab`'s same-tab no-op
  (`Update.swift:2296`) unchanged -- only replace `.rebuildContentView`
  with `.showSelectedTab` on the selection-change path (line 2309);
  in `navigateToPane`, append `.showSelectedTab` explicitly when the
  inner `.selectTab` returned `[]` (same-tab refresh path), and drop
  the unconditional `.rebuildContentView` at line 2431.
- `app/AppRuntime.swift` -- add `tabContainers` field; replace
  `rebuildContentView()` body with `showSelectedTab()`; add
  `prepareForViewSwap`, `ensureTabContainer`, `buildAndInsertContainer`,
  `rebuildTabContainer`, `removeTabContainer`, `finalizeTabSelection`;
  re-scope `refreshPaneToolbars()` to `refreshPaneToolbars(in:)` and root
  the search-overlay rehydration loop at the tab's `container` instead of
  `contentArea`; wire the three new effect arms in `perform`; extend
  `tearDownCurrentSession()` (line 1238) to clear `tabContainers` and
  detach their views before a restored session swap; change the
  direct `rebuildContentView()` call in `commitRestoreSession`
  (line 1276) to `showSelectedTab()`.

No model changes. No changes to `SplitContainerView`, `PaneWrapperView`,
`TerminalView`, `ModelOperations`, or the step-1 visibility code.

## Tests

`tests/test.sh` excludes `GhosttyKit` and `AppKit`, so anything touching
views is manual. The pure update function IS testable.

Add behavioral assertions covering every migrated branch. Each test
fails if the corresponding migration were reverted, satisfying the
"would-fail-if-reverted" bar for non-trivial behavioral changes.

In `tests/UpdatePaneTests.swift`:

- `.splitPane` emits `.rebuildTabContainer(tabId:)`, not
  `.rebuildContentView`.
- `.closePane` (more panes remain) emits `.rebuildTabContainer(tabId:)`.
- `.closePane` (last pane in tab) emits `.removeTabContainer(tabId:)`
  via closeTabBody plus `.showSelectedTab` if fallback selected.
- `.movePane` (within tab) emits `.rebuildTabContainer(tabId:)`.
- `.movePaneToTab` with a **multi-pane source** emits **three** effects:
  `.rebuildTabContainer(sourceTabId)`, `.rebuildTabContainer(targetTabId)`,
  `.showSelectedTab`.
- `.movePaneToTab` with a **single-pane source** (source tab emptied and
  removed) emits `.removeTabContainer(sourceTabId)`,
  `.rebuildTabContainer(targetTabId)`, `.showSelectedTab`. Asserts it does
  NOT emit `.rebuildTabContainer(sourceTabId)` and does NOT emit
  `.destroySurface` for the moved pane. Regression guard for the
  source-container leak (the would-no-op `.rebuildTabContainer` on a
  removed tab).
- `.movePaneToNewTab` Path A (source has only this pane) emits
  `.showSelectedTab`, NOT `.removeTabContainer(sourceTabId)`.
- `.movePaneToNewTab` Path B (source has other panes) emits
  `.rebuildTabContainer(sourceTabId) + .showSelectedTab`.
- `.toggleZoomPane` (un-zoom and enter zoom) both emit
  `.rebuildTabContainer(tabId:)`.
- `.focusDirection` zoom-clear branch emits
  `.rebuildTabContainer(tabId:)`.
- `.splitRatioChanged` STILL emits only `.scheduleCheckpoint` (no
  `.rebuildTabContainer`). Regression guard for the ratio-only
  exclusion in emission rule 2; the existing test at
  `tests/UpdatePaneTests.swift:86` covers this -- ensure it stays
  green.
- `.surfaceCreationFailed` for a **single-pane tab** (with other tabs
  in the model) emits `.destroySurface(paneId:)` for the failed pane
  plus `.removeTabContainer(tabId:)` plus `.showSelectedTab` (selection
  moved to a fallback tab). Does NOT emit `.terminate`.
- `.surfaceCreationFailed` for a **split tab** (the failed pane has
  sibling panes in the same tab) emits `.destroySurface(paneId:)`
  for EVERY pane in the failed tab (including survivors), removes
  each from `model.panes`, then emits `.removeTabContainer(tabId:)`
  plus `.showSelectedTab` if reselected. Regression guard for the
  orphan fix.
- `.surfaceCreationFailed` for the **last remaining tab** emits
  `.destroySurface(paneId:)` for every pane in the tab plus
  `.removeTabContainer(tabId:)` plus `.terminate`. Does NOT emit
  `.showSelectedTab` (no tab left to select). Regression guard for
  the terminate branch at `Update.swift:870-871`.

In `tests/UpdateTabTests.swift`:

- `.selectTab` (selection change) emits `.showSelectedTab`.
- `.selectTab` same-tab path (no selectedTabId change) STILL returns
  `[]` (regression guard: preserves the today behavior at
  `applySelectTab:2296`; clicking the active tab must NOT dismiss
  popovers / cancel drags).
- `.closeTab` emits `.removeTabContainer(tabId:)`; emits
  `.showSelectedTab` only if the closed tab was selected.
- `.deleteGroup(moveTabs: false)` emits `.removeTabContainer(tabId:)`
  for EVERY removed tab; emits `.showSelectedTab` if selection moved.
- `.navigateToPane` to a pane in a **different tab** (cross-tab path)
  emits `.showSelectedTab` once (via inner `.selectTab`) -- NOT a
  duplicate from the outer function. Regression guard for dropping
  the unconditional `.rebuildContentView` at line 2431.
- `.navigateToPane` to a different pane in the **same tab**
  (same-tab path) emits `.showSelectedTab` (from `navigateToPane`'s
  explicit append, since the inner `.selectTab` returned `[]`). When
  the same-tab path also clears zoom, additionally emits
  `.rebuildTabContainer(tabId:)`.

The view-tree mechanics (isHidden swap, lazy create, finalize block,
popover dismissal) are not unit-testable and rely on manual
verification.

## Manual verification

From a `just build-run`:

1. **Tab switch with active search**: open two tabs; in A, cmd-f, type
   a needle, see matches. Switch to B, back to A. Search overlay still
   visible with same text. Focus is in the search field.
2. **Scrollback survives switch**: in A, `seq 1000` and scroll up.
   Switch to B, back to A. Scroll position preserved.
3. **Focus border updates**: tab A has 2 panes, right pane focused
   (cmd-opt arrow). Border on right. Switch to B (single pane, no
   border). Back to A -- border still on right.
4. **Zoom across switch**: tab A two panes, zoom (cmd-shift-enter).
   Switch to B, back to A: still zoomed, correct pane shown. Un-zoom:
   both panes restored.
5. **navigateToPane clears zoom**: tab A with two panes, zoom pane X.
   Trigger a bell on pane Y, click the alert. Pane Y becomes visible
   (both panes shown, focused on Y). Validates the zoom-clear
   `.rebuildTabContainer` emit.
6. **Cross-tab pane drag (movePaneToTab)**: drag a pane from tab A to
   tab B. Target tab B is now selected; the moved pane appears inside
   B's split tree. Switch back to A -- A reflects its post-move tree
   (one fewer pane).
7. **Pane extract to new tab Path A**: single-pane tab A, drag its
   pane out to form a new tab in group X. The moved tab appears in
   group X; A is gone from its original group; the tab id is preserved
   (search field text, color, custom title all persist).
8. **Pane extract to new tab Path B**: two-pane tab A, drag one pane
   out to form a new tab. A now has one pane, new tab is selected
   with the extracted pane. Switch back to A; A reflects the rebuilt
   tree.
9. **Delete group with tabs**: create a group with two tabs; delete
   group with "remove tabs" option. Containers for all removed tabs
   are gone; selection lands on another tab.
10. **Snapshot restore**: with two tabs, quit. Reopen. Selected tab
    shows correctly. Switch to the other tab -- surface still appears
    with restored scrollback.
11. **20 tabs**: open 20 tabs (cmd-t x 20). Switch rapidly via cmd-1..9,
    cmd-shift-arrow, cmd-shift-i MRU cycle. No flicker, no missing
    borders, no surface size mismatch (`tput cols; tput lines` in each).
12. **Cmd-Tab in/out**: deactivate and reactivate. No glitches; focus
    restored.
13. **Close non-selected tab**: B's container disappears, A still
    shown.
14. **Close selected tab**: fallback tab's container shows; closed
    tab's container removed.
15. **Theme browser z-order**: open theme browser, switch tabs.
    Browser stays on top.
16. **Retina scale change**: change display scaling while DanTerm has
    multiple tabs. Switch among them; all panes render crisply.
17. **TODO popover during tab-internal rebuild**: open a pane TODO
    popover, then split that pane (cmd-d). Popover dismisses cleanly
    (validates `prepareForViewSwap` in `rebuildTabContainer`).
18. **Snapshot import over active session**: start a session with
    several tabs (visit a few so they have mounted containers);
    import a different snapshot via `cmd-shift-i` import flow.
    contentArea contains only the new selected tab's container;
    `tabContainers` matches the new model (validates the
    `tearDownCurrentSession` extension). Switching to other tabs in
    the new session lazy-builds containers; no leftover views from
    the previous session.
19. **Split-pane surface creation failure**: hard to provoke
    organically; rely on the unit test `.surfaceCreationFailed` for
    a split tab. As a sanity check in QA, watch Activity Monitor
    after a normal split for any orphaned ghostty surface threads.
20. **Energy comparison vs step 1**: with 10 tabs running idle shells,
    compare Activity Monitor energy impact before/after step 2. Should
    be unchanged (step 1 already dropped non-selected tabs' QoS);
    step 2 wins on tab-switch latency and code clarity.

## Risks / open questions

- **Container leaks**: every model path that removes a tab must emit
  `.removeTabContainer`. The audit covers the four removal sites
  found; spot-check during implementation that no future removal goes
  unpaired.
- **Effect ordering on tab close**: emit `.destroySurface(...)` first,
  then `.removeTabContainer(tabId:)`. Either order works (container
  removal does not free surfaces), but this order matches the logical
  lifecycle.
- **`applySelectTab` same-tab no-op preserved**: today's same-tab
  early-exit at `Update.swift:2296` stays. `.showSelectedTab` runs
  `prepareForViewSwap()` (dismiss popovers, cancel drags), so forcing
  it on same-tab `.selectTab` calls would regress click-active-tab
  behavior. The one caller that needs same-tab finalize
  (`navigateToPane`) appends `.showSelectedTab` explicitly. Test
  coverage asserts both shapes (selectTab same-tab returns `[]`;
  navigateToPane same-tab returns `.showSelectedTab`).
- **`rebuildTabContainer` for a hidden tab**: rebuilds with
  `isHidden=true` preserved; both `prepareForViewSwap()` and finalize
  are skipped. Skipping `prepareForViewSwap` is what keeps a background
  mutation to a hidden tab (background `.splitPane` via IPC, or the
  now-hidden source of a cross-tab move) from dismissing the visible
  tab's popovers / cancelling its drag -- matching today's behavior,
  where a background split into a non-selected tab emits no
  `.rebuildContentView` at all (`Update.swift:214`). The user sees the
  new tree on next switch. Correct.
- **`movePaneToNewTab` Path A**: source tab is the moved tab. No
  `.removeTabContainer` (id persists, container can be reused as-is).
  Verified at `Update.swift:383-394`: the same `tab` value is removed
  from the source group then inserted into the destination group with
  unchanged id and rootNode.

## Implementation notes

- Selection-changing pane moves emit `.showSelectedTab` before scoped container rebuild effects so the old selected container is hidden before the source tab is rebuilt.

## Follow Up

- Add an `NSWindow.didChangeScreenNotification` observer in `app/AppRuntime.swift` that walks `surfaces.values` and resyncs `ghostty_surface_set_display_id`; `app/TerminalView.swift:174` only updates display ID from `viewDidMoveToWindow`.
- Track replacing the `ThemeBrowserView` content-area overlay with a child window or sheet so tab-container z-ordering no longer has to preserve it manually.
