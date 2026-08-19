# Resolve the pane drop target from the model layout

Source finding: PANE-1 in `docs/scratch/2026-08-18-construction-audit.md`
(verified against the tree 2026-08-19; every cited line still holds).

## Context

Pane drag-and-drop is the last pane-geometry consumer that derives geometry
from live AppKit view frames instead of the model. `AppRuntime.startPaneDrag`
(app/AppRuntime.swift:1699) hands `PaneDragCoordinator` a frame provider built
on `wrapper.convert(wrapper.bounds, to: nil)` plus a target list from
`allPaneIds`, and neither consults hiddenness. Under zoom the pure layout
(`lib/DanTermCore/Sources/DanTermCore/PaneLayout.swift:53-58`) frames only the
zoomed pane and puts every sibling in `hiddenPaneIds`; the container
(`app/SplitContainerView.swift:87-93`) hides those wrappers but never reframes
them, so they keep stale rectangles that still tile the whole container. A drag
started while a pane is zoomed therefore highlights and drops onto invisible
panes. The comment at `app/PaneWrapperView.swift:701-704` claims those targets
"aren't mounted while zoomed" -- a premise the flat container invalidated.

Reconcile already cancels an in-flight drag on any visible-tab tree or zoom
edit (`app/Reconcile.swift:107-116` via `containerOpsEditVisibleTree`), so tree
and zoom are stable for a drag's whole lifetime; only container bounds can
change mid-drag.

The drop-target path has no test coverage today: nothing constructs a
`PaneDragCoordinator`, calls `updateDrag`, or asserts on `currentPaneDrop`.

## Decision

Make drop-target resolution a projection of the same pure `PaneLayout` the
container applies, aligned with the model-owned-pane-geometry direction
(docs/design/2026-08-16-model-owned-pane-geometry.md).

- Add a pure resolver to `DanTermCore` (beside `DropZone.swift` /
  `PaneLayout.swift`): given a layout-space point, a `PaneLayout`, and the
  source pane, return an optional drop -- target pane plus `PaneDropIntent` as
  one value -- by walking `layout.paneFrames` and delegating the in-pane zone
  decision to the existing `resolveDropZone`
  (`lib/DanTermCore/Sources/DanTermCore/DropZone.swift`).
- `PaneDragCoordinator` (app/PaneDragCoordinator.swift) drops the frame
  provider and target-id list. It resolves against the visible tab's
  `SplitContainerView`: the container answers each query by deriving a layout
  from its bounds at that moment (the same `paneLayout(in: bounds, tree:,
  zoomedPaneId:)` call `applyModelLayout` makes), and coordinate conversion
  between window, container, and overlay space uses AppKit's own
  `NSView.convert` -- no hand-rolled
  transform. The parallel `currentTarget` / `currentIntent` optionals collapse
  into the single drop value.
- `AppRuntime.startPaneDrag` passes the container
  (`tabContainers[selectedTabId]`, app/AppRuntime.swift:159) to the coordinator
  instead of building a provider; `findPaneWrapper` loses its geometry consumer.
- Rewrite the stale comment in `ToolbarDragHandleView.mouseDragged`
  (app/PaneWrapperView.swift:701-704) to state the real mechanism: the resolver
  sees only panes the model displays. The guard logic there does not change.

## Invariants

- I1: A pane the model hides is never a drop target. The resolver can only see
  the frames the pure layout produced, and a hidden pane has none -- the bug
  becomes unrepresentable rather than filtered out.
- I2: A drop target without an intent, or an intent without a target, is
  unrepresentable: both live in one optional value.
- I3: In-pane zone semantics (edge bands, corner tie-break, center swap) are
  unchanged; `resolveDropZone` stays the single decider.
- I4: Every drag update resolves against a layout derived from the container's
  bounds at that moment. Tree and zoom are drag-stable (reconcile cancels the
  drag on visible-tab edits), and bounds are read live on each query, so a
  bounds change mid-drag cannot leave resolution on old pane rectangles -- not
  even while an AppKit layout pass is still pending.
- I5: The source pane is never its own drop target, and with no other visible
  pane in the tab there is no in-tab drop target at all (the sidebar drop path
  is unaffected).

## Proof obligations

Pure-core tests in `lib/DanTermCore/Tests/DanTermCoreTests/` (new suite beside
`DropZoneTests.swift`). TDD: the first test below must fail before the resolver
exists.

- PO1 (I1, I5 -- write first): over a zoomed two-pane layout, every point in
  bounds resolves to the zoomed pane or to nothing, never to the hidden
  sibling; with the zoomed pane as the drag source, no point yields a drop.
- PO2 (I3): over an unzoomed split layout, a point in a target pane's edge band
  yields the matching split intent and a center point yields swap -- the same
  answers `resolveDropZone` gives for that pane's local coordinates. Existing
  `DropZoneTests` (all 14) must keep passing unchanged.
- PO3 (I5): a point inside the source pane's own frame yields no drop; a point
  on a divider or outside every pane frame yields no drop.
- PO4 (premise): existing `PaneLayoutTests` pin the zoom branch the resolver
  relies on (frames only for the zoomed pane, siblings hidden) and must keep
  passing unchanged.

Manual smoke (I4 and the AppKit conversion glue): in a slot
(`just launch-slot`), build splits, drag a pane over each zone and confirm
highlight and drop match; resize the window mid-drag and confirm the next
highlight follows the new pane rectangles, not the old ones; zoom a pane, start
a drag from it, confirm no in-tab highlight appears anywhere and a sidebar drop
still works.

## Non-goals

- Promoting `app/PaneDragCoordinator.swift` into the `test-ui` compile list to
  drive the drag from the UI harness. After this change the coordinator is thin
  conversion-and-overlay glue over the pure resolver; the pure tests carry the
  behavior, and the manual smoke covers the glue.
- The neighboring audit findings PANE-2, LOOKUP-4, RECON-1. They touch the same
  files but none blocks this; whichever lands second gets a smaller diff.
- Any change to the drag-start guard (`hasSplits || totalTabCount > 1`) or to
  the sidebar's native NSDraggingSession drop path.

## Accepted risks

- AR1: The coordinator's AppKit glue (view-space conversion, overlay highlight)
  stays without automated coverage, as today. Rationale: the glue shrinks under
  this change, uses `NSView.convert` rather than arithmetic, and the manual
  smoke exercises it directly.

## Rejected ideas

- RI1: Cheaper fallback from the audit -- keep the frame provider but return
  nil for hidden panes. Removes the zoom bug but keeps the second geometry
  source, so the next zoom-like presentation state reopens the class.
- RI2: Snapshot the layout and a container-to-window transform at drag start.
  A mid-drag bounds change (e.g. an IPC-driven resize) would strand the
  snapshot, and a hand-rolled transform is the one place an error shifts every
  highlight. Reading the container's current layout and converting through
  AppKit removes both.

## Implementation discretion

- Whether `currentDrop()`'s public tuple shape `(source, target, intent)` stays
  or becomes the new value type; if it changes, `app/PaneWrapperView.swift:745`
  and `tests-ui/SidebarViewTestShim.swift:40` follow.
- The layout-space point type: reuse `DropZonePoint` or add one beside
  `PaneLayoutRect` (which may want a containment helper either way).

## Implementation notes

- `currentDrop()` keeps its `(source, target, intent)` tuple shape, so
  `app/PaneWrapperView.swift` and `tests-ui/SidebarViewTestShim.swift` are
  untouched. The collapsed `PaneDrop` value is the coordinator's stored state,
  which is where the parallel-optionals hazard actually lived.
- The layout-space point reuses `DropZonePoint` rather than a new type, and
  `PaneLayoutRect` gains a `contains(_:)` helper. Containment is half-open on
  the far edges: `paneFrames` is a dictionary, so the walk order is not fixed,
  and half-open keeps two boxes that touch (a divider the layout shrank to
  nothing) from both claiming the same point.
- `PaneDragCoordinator` holds the `SplitContainerView` weakly. The container
  belongs to the tab, and reconcile already cancels the drag on any visible-tab
  edit, so a nil container means the drag is over.
- `SplitContainerView.applyModelLayout` now calls the new `currentPaneLayout()`,
  so the presented layout and the queried layout are literally the same call.
- Runtime check: a dev slot built, launched, split, zoomed, and unzoomed
  cleanly. The drag gesture itself needs a real mouse and was not exercised.

## Follow Up

- The plan's manual drag smoke is still unperformed -- it needs a human mouse
  drag: drop into each zone, resize the window mid-drag, and start a drag from
  a zoomed pane to confirm no in-tab highlight appears.
- `init(_ rect: PaneLayoutRect)` on `NSRect` is duplicated as a private
  extension in `app/PaneDividerView.swift:138` and
  `app/SplitContainerView.swift:135`, and `app/PaneDragCoordinator.swift` now
  spells the same conversion inline. One shared conversion would retire all
  three.
