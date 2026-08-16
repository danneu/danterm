# Model-owned pane layout

## Context

Splitting a pane makes DanTerm tell the child process a grid size the model
never produced. A pane running Claude Code was permanently garbled by it.

Evidence, from the pane's flight tape and a scripted reproduction on `master`:

- Window 179x66 cells, tab holding a 2x2 pane grid, model reporting `ratio:
  0.5` on both splits.
- The split pushed `TIOCSWINSZ 119x32`, then `89x32` 4.7 ms later. The child
  coalesced the two `SIGWINCH`s, cached 119 columns, and repainted its whole
  static region with absolute column positioning (`\x1b[105G`, `\x1b[113G`).
  Those clamp to column 89 on an 89-wide grid and autowrap. The corruption is
  written into scrollback and cannot be repaired.
- Scripted on latest: `split -h` gives a correct 89x66; a following `split -v`
  leaves the pane at 119x32. In a background tab the wrong value is never
  corrected at all; in a visible tab it is corrected about 5 ms later, which is
  the transient pair above.
- 119:59 is exactly AppKit's proportional redistribution over stale frames. A
  new split view is created at the container's full width and attached beside a
  surviving 89-wide wrapper.

Load-bearing premises, each checked in the tree:

- A pane wrapper's frame today has many producers. `NSSplitView.adjustSubviews`
  runs on attach; the model ratio is imposed afterward by a separate deferred
  pass, and that pass runs only when a tab is made visible. A hidden tab
  therefore keeps AppKit's opinion indefinitely.
- Every frame assignment reaches the child synchronously:
  `SwiftTerminalSessionView.setFrameSize` calls `synchronizeGeometry()`, which
  submits the grid. There is no settle step anywhere on the path.
- AppKit geometry is currently an *input* to the model. The split view reports
  its observed ratio back as a message, and three private flags exist only to
  break the resulting cycle. That is a denylist, so any path nobody enumerated
  writes AppKit's opinion into the model.
- Because that write-back reads a position the 100pt min/max clamp already
  moved, shrinking a window past the clamp permanently rewrites stored ratios.
  This is a second live defect on the same path.
- `swift test --package-path lib/DanTermCore` runs in the gate;
  `test-ui.sh` does not. Layout arithmetic left in the view layer is arithmetic
  CI never checks.
- This class was recorded once already.
  [docs/design/2026-03-05-display-scaling.md](../../docs/design/2026-03-05-display-scaling.md)
  notes that split rebuilds can hand a terminal view a zero frame, and answers
  it with a zero-frame guard. That guard catches degenerate geometry. It cannot
  catch geometry that is merely wrong, which is what 119x32 is.

Desired outcome: a pane's size on screen and the size its child is told are the
same number, derived once from the model, in every tab whether visible or not.

## Decision

Pane geometry becomes a pure function of the model, and the container view goes
**flat**.

- A new pure layout function in `lib/DanTermCore` maps container bounds, the
  split tree with its ratios, and the zoomed pane to a rect per pane plus a
  placement per divider. Its inverse maps a dragged divider position back to a
  ratio, so the clamp is decided once and tested once.
- `app/SplitContainerView.swift` becomes a plain `NSView` whose direct subviews
  are the pane wrappers and the divider strips. It assigns each frame from the
  layout function, and only when the value differs from the current one.
- `app/PaneSplitView.swift` is deleted. A new divider view draws the separator,
  owns the cursor rect, runs the drag, and keeps the existing double-click reset
  to an even split. It holds no ratio and never moves itself: a gesture sends a
  ratio change and waits for the layout to come back.
- A ratio change reconciles immediately. Today it defers the view sweep, on the
  written grounds that the container shape drops ratios so the sweep is an empty
  diff. This work inverts that premise: the shape carries the layout tree, so a
  deferred sweep would leave the divider lagging the mouse by the coalescing
  interval. The storm the deferral guarded against was AppKit emitting ratio
  messages during a window resize, which I3 removes.
- Zoom becomes a case in the layout function rather than a detach-and-pin
  presentation.
- The keyed tree-patch projection in `lib/DanTermCore/.../Projections.swift`
  is deleted. It exists to preserve wrapper identity across reparenting, and a
  flat container never reparents a wrapper within a tab.

Why flat rather than a nested view tree that obeys the model: the bug needed a
stale sibling to redistribute against. With no nested split views there is no
sibling, no reparenting, and no intermediate frame that was never any pane's
real size. Imposing the model ratio onto a nested `NSSplitView` narrows the
class; removing the nesting removes it.

The child's grid keeps being derived from the terminal view's own bounds. The
terminal area is the pane rect minus chrome the views draw, so moving the grid
into the core would mean the pure core modelling AppKit chrome, with the
constants free to drift from the views that own them. Once the wrapper frame has
one pure producer, bounds is a faithful derivation of the model rect through
compile-time constants, and a test pins that.

Critical files: `app/SplitContainerView.swift`, `app/PaneSplitView.swift`
(deleted, replaced by a divider view), `app/Reconcile.swift`,
`lib/DanTermCore/Sources/DanTermCore/Projections.swift`, a new pure layout file
under `lib/DanTermCore/Sources/DanTermCore/`, `tests-ui/SplitContainerViewTests.swift`,
`tests-ui/PaneSplitViewTests.swift`, and `test-ui.sh`.

`tests-ui/PaneSplitViewTests.swift` also hosts the UI-suite entry point and the
shared assertion helpers. Only its pane-split cases die; the runner and helpers
survive the deletion. The container tests likewise pin behavior that is not
geometry -- first-responder survival across structural edits, wrapper identity
across tab moves, search-field responder survival -- and those pins carry
through the rewrite, adapted to the flat container.

## Invariants

- **I1** A pane wrapper's frame has exactly one producer: the container's layout
  pass, which is a pure function of container bounds, the layout tree, and the
  zoomed pane.
- **I2** No grid a child receives is derived from a rect that was not some
  pane's true current rect.
- **I3** Geometry is an input to the model only during a user divider gesture.
  No layout pass, structural change, zoom, reveal, or window resize emits a
  ratio change.
- **I4** Layout is total and idempotent. The same inputs give the same rects,
  and re-applying a layout writes no frame and submits no grid.
- **I5** A hidden tab lays out identically to a visible one. Visibility never
  affects geometry.
- **I6** A split's two children and its divider tile their box exactly, and a
  child's box derives from its parent's rect, never from the container's.
- **I7** The minimum pane extent applies uniformly to drags, to ratios restored
  from a snapshot, and to windows shrunk below it -- in every box that can hold
  two of them plus the divider. In a box that cannot, the minimum yields for
  both children rather than being met for one at the other's expense, so no pane
  is laid out at zero extent. Clamping is presentational: it never rewrites the
  stored ratio.
- **I8** A divider exposes splitter accessibility: role, orientation, and a
  value that tracks the split.

## Proof obligations

Pure core tests (in the gate):

- **PO1** (I6, I4) Rects tile their box exactly at every nesting level, are
  pairwise disjoint, and stay inside bounds across a table of trees and sizes.
- **PO2** (I6) At the incident's geometry, splitting one column yields children
  the width of that column, not of the container. Name the incident.
- **PO3** (I4, I7) A dragged position converted to a ratio and laid out again
  reproduces identical rects, including when the clamp moved it.
- **PO4** (I7) In a box too small for two minimum extents, both children are
  laid out at a non-zero extent and still tile: neither pane can be squeezed
  away to satisfy the other's minimum. In an ordinary box, an extreme restored
  ratio lays out clamped, leaves the stored ratio untouched, and returns to its
  intended proportion when the box grows back.
- **PO5** (I1) Zoom is total: the zoomed pane fills the bounds, every other pane
  is reported hidden, no divider is placed, and unzooming restores the previous
  rects exactly.
- **PO6** (I5) A ratio-only model change produces one layout update for its tab,
  reaches a background tab, and is not deferred. It is still not reported as a
  structural edit, so a divider drag does not cancel a pane drag. This replaces
  the existing pin that a ratio is excluded from the container shape.

AppKit tests (`just test-ui`):

- **PO7** (I2) Regression for the incident. At the reported geometry, splitting
  a pane in a column submits exactly one grid for the affected pane, equal to
  the model's slot, submits none for the untouched sibling, and never submits a
  container-wide column count. Name the incident.
- **PO8** (I5) The same sequence in a tab that is never revealed produces the
  same rects and the same single submission.
- **PO9** (I3, I7) Any sequence of structural change, zoom, reveal, and
  container resize emits no ratio change, including a resize that shrinks a
  split below the minimum extent and back. That case is today's second live
  defect: the clamped position is written back and the stored ratio never
  returns. A synthesized divider drag emits one clamped ratio per event, moves
  no frame until the layout returns, and does move it within that same
  round trip. A double-click on a divider emits an even ratio and likewise
  moves nothing on its own.
- **PO10** (I4) Applying the same layout twice submits no further grid, and a
  newly added pane submits exactly one grid, never a placeholder first.
- **PO11** (I1) Zooming submits no grid for the panes it hides.
- **PO12** (I8) The divider reports splitter role and the orientation of its
  split, and hit-testing resolves the divider inside its strip and the pane
  just outside it. Its accessibility value follows the position the model
  produced, across both a ratio change and a layout the clamp moved.
- **PO13** (I2) A wrapper at a known rect yields the grid that rect implies
  after chrome. This is what licenses deriving the grid from bounds: it fails if
  chrome ever becomes content-dependent, instead of the terminal corrupting.

End-to-end check, driven by the CLI rather than the GUI: build a 2x2 tab in a
dev slot with `danterm pane split`, follow each pane's tape, and confirm every
pane receives exactly one resize equal to its model slot, in a background tab as
well as the selected one. This is the reproduction that found the bug.

## Non-goals

- Suppressing geometry during a live window resize. A stream of true sizes is
  correct, and a child that coalesces signals converges on the last one. The
  defect was one size that was a lie, not many that were true.
- Deriving the child's grid inside the pure core.
- The sidebar split view. Its output is the container's bounds, which this work
  turns into consistent pane rects, so no pane geometry can be stale-derived
  through it today. Record the trigger: adding a third subview there, or
  detaching and re-attaching the content area, reopens the same class one level
  up.

## Accepted risks

- **AR1** Hand-written splitter accessibility may be worse than what AppKit
  supplied for free. Mitigated by PO12, which pins role, orientation, and hit
  area but cannot pin the full experience.
- **AR2** Divider drag feel is tuned by hand and is not unit-testable. AppKit's
  hysteresis and its wider-than-visual hit area are being replaced by an
  explicit strip.
- **AR3** Ratio changes meaning: it becomes the fraction of usable space rather
  than of the whole box, and the minimum extent now applies to restored and
  shrunk layouts. Persisted layouts shift by under a point, and a previously
  stored extreme ratio renders clamped rather than as stored. The stored value
  survives, per I7, so this also fixes the clamp write-back that mangles ratios
  today.
- **AR4** This supersedes the incremental container reconciliation work. The
  flat container has no view tree to rebuild, so structural edits do less work,
  not more, but the earlier latency argument is being retired rather than
  re-measured.

## Rejected ideas

- **RI1** A settle or provisional-geometry gate on the grid submission. It would
  have hidden this bug and leaves the background-tab case wrong, where the bad
  value is the settled one.
- **RI2** A debounce or value history in the pane session or the resize
  coalescer. The coalescer answers one question about submission order and holds
  no dimensions by design; a "was this transient?" heuristic there destroys the
  invariant it exists to encode, and no principled threshold exists.
- **RI3** Correcting the new split view's initial frame or its holding
  priorities. That fixes the starting condition of a stateful proportional
  algorithm while leaving the algorithm in charge, so every other path that can
  leave a stale frame reopens it.
- **RI4** Applying the stored ratio unconditionally after every structural
  change. The wrong frame is still produced first, so the transient survives;
  and correctness would again rest on every mutation path remembering to call
  the fixer, which is the property that failed here.
- **RI5** Keeping the nested split views and imposing the model ratio on them.
  It establishes the same invariant but keeps AppKit's proportional pass alive
  underneath, and leaves the arithmetic outside the CI gate.

## Implementation discretion

- Whether the layout function returns rects keyed by pane or a richer result
  carrying divider placements and hidden panes, and how the container's
  coordinate flippedness is expressed.
- How the reconciler delivers the layout to a container: a diffed op or an
  idempotent push each sweep, given that re-applying an unchanged layout is
  already required to write nothing.

## Delivery order

Four slices, each green on its own. Re-slice with `/slice-plan` before
implementing.

1. The pure layout function and its core tests, with no caller.
2. The flat container, the divider view, the deletion of the split view, the
   ratio-change reconcile reclassification, and the rewritten AppKit tests. The
   behavioral fix lands here, so the divider must track the mouse from this
   slice onward.
3. The deletion of the keyed tree-patch projection and its tests.
4. An ADR recording the invariant, the rounding and thickness contract, the
   accessibility trade, and the sidebar trigger; registered in the design index
   and the AGENTS.md table.

## Commit progress

- [x] 1. feat(layout): add pure pane layout engine
- [ ] 2. fix(layout): derive pane frames from the model
- [ ] 3. refactor(core): remove container tree patches
- [ ] 4. docs(layout): record model-owned pane geometry

## Implementation notes

- The pure core uses `PaneLayoutRect` instead of importing CoreGraphics. The
  AppKit boundary will convert it to `NSRect` when commit 2 adopts the layout.
- The first child extent rounds to the nearest whole point after ratio
  multiplication, and the second child receives the exact remainder. Layout and
  drag inversion share this rule, so a model round trip cannot move a divider by
  a floating-point epsilon.
