# Model-Owned Pane Geometry

- Status: Accepted
- Date: 2026-08-16

## Context

A pane frame is not only presentation state. `SwiftTerminalSessionView`
synchronously derives the child process grid from its bounds when its frame
changes. Every frame assigned to a pane can therefore become a `TIOCSWINSZ`
submission.

The old pane container nested `NSSplitView` instances. During a structural
change, AppKit could redistribute a new split against stale sibling frames
before DanTerm reapplied the model ratios. In the 2026-08-16 Claude Code
incident, a pane in one column of a 179-column window received 119 columns and
then 89 columns. The child coalesced the resulting signals, rendered for the
false width, and wrote permanent corruption into scrollback. A hidden tab kept
the false geometry because ratio correction ran only when the tab became
visible.

The same feedback path also reported AppKit's minimum-size clamp as a new model
ratio. Shrinking a window could therefore replace the stored ratio permanently.
Guards against zero frames cannot reject either defect because both false
frames are positive.

## Decision

D1. **The model tree and container bounds have one pure geometry projection.**

`paneLayout(in:tree:zoomedPaneId:)` in `DanTermCore` returns every pane frame,
every divider placement, and the set of hidden panes. It recursively partitions
each split's own parent rectangle. Zoom is another input to this function, not
a separate detach-and-pin presentation path.

`SplitContainerView` is a flat `NSView`. Pane wrappers and divider strips are
its direct children. It applies the pure result and assigns a pane frame only
when that frame changed. No nested AppKit layout object can produce an
intermediate pane frame, and hidden and visible tabs use the same layout path.

D2. **Pane geometry flows from the model to AppKit.**

A container layout, tree edit, zoom change, tab reveal, or window resize does
not report a ratio to the model. Only a user divider gesture sends
`splitRatioChanged`. The model transition reconciles immediately, and the
divider waits for that round trip instead of moving itself.

This rule makes the container layout pass the only producer of pane wrapper
frames. The terminal view can continue to derive its grid from its own bounds
because those bounds now descend from one true pane rectangle. Reapplying the
same layout changes no frame and submits no grid.

D3. **The ratio describes usable space, and layout and drag share one rule.**

The standard separator is 1pt. A split first removes that thickness from its
axis, then applies the stored ratio to the remaining usable extent. The first
child extent rounds to the nearest whole point, with ties away from zero. The
second child receives the exact remainder. Divider drag inversion uses the same
calculation, so a model round trip cannot move the divider by a floating-point
remainder.

Each child has a 100pt preferred minimum. When the usable extent cannot hold
both minima, the minimum yields equally for both children. For an extremely
small positive box, the divider thickness also yields so both children remain
positive. These clamps affect only the presented layout. They do not replace
the stored ratio, so the intended proportion returns when the box grows.

D4. **A divider has an explicit AppKit interaction and accessibility surface.**

`PaneDividerView` draws the 1pt separator inside a 7pt interaction strip. It
reports splitter role, reports the orientation of the divider, and exposes the
effective ratio from the model-produced placement. Its accessibility value
therefore follows a ratio change and also follows a presentational clamp.

This is an accepted trade: a hand-written divider may provide less assistive
behavior than `NSSplitView` supplied. The explicit role, orientation, value,
cursor, hit area, drag, and double-click reset are the supported contract.

D5. **The sidebar split remains outside this geometry owner until its shape
changes.**

The sidebar `NSSplitView` currently produces only the whole pane container
bounds. The pure layout derives every pane below that boundary, so the sidebar
cannot redistribute one pane against a stale sibling. Adding a third sidebar
subview, or detaching and reattaching the content area, reopens the false-frame
class. Either change must first establish a single model-owned producer for the
content bounds.

D6. **A core decision that needs current pixels uses a command and message
round trip.**

The core emits a command naming the model entity whose arranged geometry it
needs. AppKit reads that entity's current model-derived layout, applies the pure
decision function, and sends the result back as a message. The model never
stores the rectangle. Autosplit is the first use: it measures the named tab
without zoom, chooses the largest splittable pane and its longer axis, then
re-enters the ordinary pane-split dispatch with the original request id.

## Consequences

- Pane geometry and divider drag clamping are deterministic core behavior with
  tests in the normal local gate.
- Structural reconciliation sends each surviving tab its current model root.
  It preserves wrapper identity without a keyed view-tree patch because a flat
  container never reparents a wrapper within a tab.
- A stream of true sizes during live window resize remains valid. DanTerm does
  not debounce or suppress those grid changes.
- Terminal chrome stays owned by AppKit. The pure core does not calculate the
  final row and column count; focused AppKit tests pin the conversion from a
  known wrapper rectangle to the submitted grid.
- The old zero-dimension guard remains necessary for display scaling, but it is
  no longer the pane-layout correctness boundary.

## References

- [2026-05-27-model-driven-view-reconciliation.md](2026-05-27-model-driven-view-reconciliation.md)
  -- the general model-to-view rule and reconcile ordering that this decision
  applies to the flat pane container.
- [2026-03-05-display-scaling.md](2026-03-05-display-scaling.md) -- the scale,
  pixel-size, and non-positive-dimension invariant downstream of pane layout.
- `lib/DanTermCore/Sources/DanTermCore/PaneLayout.swift` -- the pure layout,
  rounding, minimum, and drag-inversion rules.
- `app/SplitContainerView.swift` -- the flat AppKit host and sole pane-frame
  producer.
- `app/PaneDividerView.swift` -- divider presentation, gestures, and
  accessibility.
