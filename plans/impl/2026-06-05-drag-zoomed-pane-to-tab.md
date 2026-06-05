# Allow dragging a zoomed pane to another tab

## Context

Bug: when a pane is zoomed (maximized within its tab), dragging its toolbar to
the sidebar to move the pane into another tab does nothing -- no drop visuals,
and releasing doesn't move the pane. It only works after un-zooming.

Root cause: a stale guard in the drag-source. `ToolbarDragHandleView.mouseDragged`
bails out before it ever starts the drag when the tab is zoomed:

```swift
// app/PaneWrapperView.swift:584-589
// Don't start drag if tab is zoomed, or single-pane with no other tabs
guard let tab = selectedTab(in: runtime.model) else { return }
guard !tab.isZoomed else { return }          // <- line 586: kills the drag while zoomed
let hasSplits: Bool
if case .split = tab.rootNode { hasSplits = true } else { hasSplits = false }
guard hasSplits || totalTabCount(runtime.model) > 1 else { return }
```

Because it returns before `beginDraggingSession` (line 599), no `NSDraggingSession`
is created and nothing is written to the pasteboard. The sidebar's drop visuals
and its `acceptDrop` move both ride on that native session
(`PaneDragCoordinator.swift:3-4`: "Sidebar drops are handled natively by
NSOutlineView via the NSDraggingSession started in ToolbarDragHandleView"), so
no session means no visuals and no move.

Git archaeology shows why the guard exists and why it's now wrong:
- `72ada4c` "impl drag and drop to move/swap panes" (body: "Only works in the
  same tab for now.") -- back then drag only did in-tab split/swap against
  sibling panes; while zoomed there are no visible siblings, so blocking was
  correct.
- `4a76201` "impl dragging pane into another tab" -- added cross-tab moves via
  the sidebar and relaxed the *single-pane* guard, but left the *zoom* guard
  untouched. It now also blocks the legitimate cross-tab move of a zoomed pane.

Intended outcome (confirmed with the user): you can drag a zoomed pane to move
it. Since the other panes in its tab aren't visible while zoomed, the only
meaningful drops are sidebar drops -- onto another tab, or into a gap to make a
new tab. In-tab split/swap drops stay naturally inert (their targets aren't
mounted while zoomed).

## The fix (AppKit only)

`app/PaneWrapperView.swift`, in `ToolbarDragHandleView.mouseDragged`: delete the
`guard !tab.isZoomed else { return }` line and update the comment. Keep the
`guard let tab = ...` (still used by the `hasSplits` check below it) and keep the
`hasSplits || totalTabCount > 1` guard.

After the change:

```swift
// Allow the drag unless there's nowhere to drop: a single pane in the only tab.
// A zoomed pane always has splits, so hasSplits is true and the drag starts; the
// sidebar can then move it to another tab. In-tab split/swap targets aren't mounted
// while zoomed, so those drops stay inert (PaneDragCoordinator skips nil frames).
guard let tab = selectedTab(in: runtime.model) else { return }
let hasSplits: Bool
if case .split = tab.rootNode { hasSplits = true } else { hasSplits = false }
guard hasSplits || totalTabCount(runtime.model) > 1 else { return }
```

This is the whole behavioral fix. The toolbar and its `ToolbarDragHandleView` are
mounted unconditionally (`PaneWrapperView.swift:222-229`); `isZoomed` only toggles
the unzoom button. So on a zoomed pane the drag handle is present and already
receiving `mouseDown`/`mouseDragged` -- the guard was the sole blocker.

## Why the pure core needs no change (verified)

A zoomed tab always has splits -- `toggleZoomPane` only sets `isZoomed = true`
when `case .split = tab.rootNode` (`Update.swift:1139`). So dragging a zoomed
pane always lands on the multi-pane code paths, which already normalize state:

- `.movePaneToTab` (`Update.swift:282-337`): clears `isZoomed = false` on the
  target (302) and on the surviving source (310), repoints the source's
  `focusedPaneId` off the departed pane (311-313), and removes the source tab
  outright if it empties (317).
- `.movePaneToNewTab` Path B / multi-pane source (`Update.swift:373-392`): clears
  source `isZoomed = false` (381), repoints focus (382-383), and the new tab is
  built fresh with the default `isZoomed = false` (388).
- `.movePaneToNewTab` Path A / single-pane source (`Update.swift:360-372`) moves
  the whole tab entity and preserves its state -- safe, because a single-pane
  tab is a `.leaf` and can never be zoomed (per the `Update.swift:1139`
  invariant), so a zoomed pane never reaches Path A.

This mirrors the established close-while-zoomed precedent
(`.closePane`, `Update.swift:238-240`: unzoom + repoint focus). No new core code.

## Resulting behavior

- Drop a zoomed pane onto another tab row: pane merges into that tab (target
  unzooms, focuses the moved pane). The source tab unzooms and shows its
  remaining panes with focus on a survivor; if it had exactly 2 panes it becomes
  a single unzoomed leaf; if it somehow empties it is removed.
- Drop into a sidebar gap: pane is extracted into a new unzoomed tab; source
  unzooms the same way.
- Drop back onto the zoomed pane's own area (the only mounted pane): no in-tab
  target exists, so it's a clean no-op and the pane stays zoomed.

Note the deliberate consequence: moving a zoomed pane out un-zooms the source
tab, because the thing that was zoomed is gone -- consistent with closing a
zoomed pane today.

## Tests

The behavioral change is in AppKit (`NSDraggingSession` gating), which the pure
core can't exercise; verify that part manually (below). What the new capability
*relies on* is a pure-core contract that is currently correct but untested for a
zoomed source. Add two spec/contract tests to lock it down so a future refactor
of the move handlers can't silently re-break zoomed-pane drags.

File: `lib/DanTermCore/Tests/DanTermCoreTests/UpdatePaneTests.swift` (alongside
the existing `testMovePaneToTabTargetZoomCleared` at ~line 1127 and the
`movePaneToNewTab` Path B test at ~line 1151). Use the existing helpers
(`makeModel()`, `createTab(&model)`, `update(&model, .splitPane(...))`,
`allPaneIds`, `tabById`) and the three-line Intent/Why/Scenario preamble
convention used throughout that file.

1. `movePaneToTab` with a zoomed source: build a source tab with 2 panes, zoom
   it (`update(&model, .toggleZoomPane)`) with the focused/zoomed pane being the
   one to move, create a second tab as target, `update(&model,
   .movePaneToTab(paneId: zoomedPane, targetTabId: target))`, then assert the
   source tab has `isZoomed == false` and `focusedPaneId` equals the surviving
   pane, and the moved pane is in the target.
2. `movePaneToNewTab` with a zoomed source (exercises Path B): same zoomed
   2-pane source, `update(&model, .movePaneToNewTab(paneId: zoomedPane,
   inGroupId: group, atIndex: ...))`, then assert the source tab is unzoomed with
   focus on the survivor, and a new tab exists holding the moved pane with
   `isZoomed == false`.

These should pass on the unmodified core (they characterize/pin existing
behavior); their job is regression protection for the feature, not to drive a
core change.

## Out of scope / non-goals

- No auto-unzoom on drag start. An alternative is to un-zoom the moment a drag
  begins so in-tab split/swap targets reappear; rejected per the user's stated
  expectation (zoomed -> move-to-another-tab only) and to keep zoom state from
  changing as a side effect of a drag the user might cancel.
- No defensive `isZoomed = false` in `movePaneToNewTab` Path A. It's unreachable
  with a zoomed source (single-pane tabs can't be zoomed); adding it would be
  dead code and would wrongly mutate a relocated tab's state.

## Verification

1. `just build-run` (Dev bundle).
2. Manual drag check:
   - Open a tab, split it into 2+ panes, zoom one (its toolbar unzoom button
     confirms zoom). Open a second tab.
   - Drag the zoomed pane's toolbar over the sidebar's other tab row -> the
     native insertion/merge highlight should now appear; release -> the pane
     moves into that tab and the source tab un-zooms to show its remaining panes.
   - Repeat dropping into a gap between sidebar tabs -> a new tab is created with
     the moved pane.
   - Drag the zoomed pane and release back over its own area -> nothing moves,
     pane stays zoomed (clean no-op).
   - Sanity: un-zoomed drag-to-move still works as before.
3. `just test` (runs the core Swift Testing suite incl. the two new tests, plus
   protocol/support/lint/shell self-tests).
