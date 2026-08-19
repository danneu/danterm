# Pane toolbar zoom button

## Problem

A zoomed pane carries a blue unzoom button in its toolbar, but there is no
matching way to *enter* zoom from the toolbar. Zoom is only reachable from the
pane menu, a keyboard shortcut, and the CLI. A pane that can be zoomed should
say so in the same place the zoomed pane offers its exit.

Making the button visible on every pane exposes a targeting defect that is
latent today. `.toggleZoomPane(paneId:)` uses its `paneId` only to find the
*tab*; the zoom itself lands on that tab's focused pane
(`lib/DanTermCore/Sources/DanTermCore/Update.swift` `toggleZoomPane`,
`PaneTree.toggleZoom` in `Model.swift`, which documents "leaves focus
unchanged"). Today the only visible unzoom button belongs to the zoomed pane,
which is the focused pane by construction, so nothing shows it. Put a button on
every pane and clicking pane B while pane A is focused zooms A. The pane context
menu's "Zoom Pane" item and `danterm pane zoom --pane <id> on` already carry the
same defect -- and `integrations/danterm/SKILL.md` already promises the behavior
the code does not deliver ("the tab renders only the target pane").

Desired outcome: any pane in a split tab can be zoomed from its own toolbar in
one click, and every zoom request zooms the pane it names.

## Load-bearing premises

- The pane-toolbar projection already carries both facts the button needs.
  `PaneToolbarRender` in `lib/DanTermCore/Sources/DanTermCore/Projections.swift`
  has `isZoomed` (already defined per pane, as `tree.isZoomed && focusedPaneId ==
  pane.id`) and `hasSplits`, and `app/Reconcile.swift` pushes both on every pass.
  `hasSplits` flips exactly on the 1 -> 2+ pane transition, so no new projection
  field, message, or reconcile wiring is needed for visibility.
- The container reconcile already keys on which pane is zoomed
  (`ContainerShape.zoomedLeaf`), so moving focus inside a zoomed tab already
  re-renders the correct pane.
- Real key focus already follows the model. `reconcilePaneFocus` repairs the
  first responder from `desiredPaneFocus(in:)` on every sweep, so a reducer that
  moves `focusedPaneId` needs no accompanying focus command. It is
  selected-tab-only, which is why a background tab's focus move is a model fact
  with no responder consequence.
- The toolbar button's action already sends `.toggleZoomPane`, so it is already a
  two-way toggle; only its presentation is one-way.

## Decision

Two changes, landed in this order so the button is never wrong.

**1. Zoom targets the pane it names.** `.toggleZoomPane(paneId:)` focuses the
named pane in its own tab and then applies zoom to it. The pane-level zoom
predicate -- a pane is zoomed when its tab is zoomed and the pane is that tab's
focused pane -- becomes the single definition every path resolves against: the
reducer, the pane menu, the toolbar button, and IPC `pane.zoom` -- and the one
scripted replies report per pane. `paneId: nil` keeps its selected-tab,
focused-pane meaning for the menubar path.

**2. The toolbar button covers both directions.** The existing button is
retained and generalized rather than joined by a second one: it is visible
whenever the pane is zoomed or its tab has splits, and its icon, tooltip,
accessibility description, and fill state which direction the click goes.
Un-zoomed it is a quiet secondary-label glyph; zoomed it keeps the accent fill.
Accent stays reserved for "you are in a non-default state, here is the exit", so
it does not become permanent furniture on every multi-pane toolbar.

Touched: `lib/DanTermCore/Sources/DanTermCore/Update.swift`,
`lib/DanTermCore/Sources/DanTermCore/Model.swift` (the `PaneTree` zoom API stops
implying focus is someone else's business),
`lib/DanTermCore/Sources/DanTermCore/IpcDispatch.swift` (`paneZoom` resolves
`on`/`off`/`toggle` against the pane predicate, not the tab flag),
`lib/DanTermCore/Sources/DanTermCore/IpcEntityEncoder.swift` (the pane-level zoom
field), `app/PaneWrapperView.swift`, and `integrations/danterm/SKILL.md` (the
pane-level field, and the focus move `pane zoom` now performs).

## Invariants

- **I1** A pane's zoom button is visible exactly when the pane is zoomed or its
  tab has splits, and it tracks pane count changes live: splitting a lone pane
  reveals it, closing back down to one pane hides it.
- **I2** The button states the pane's current zoom state -- direction icon,
  tooltip, accessibility description, and accent fill -- and changes with that
  state without the pane wrapper being rebuilt.
- **I3** After a zoom request naming pane P succeeds, P is its tab's zoomed pane
  and its focused pane. No zoom request unzooms a pane other than the one it
  names (or, for the `nil` form, the selected tab's focused pane); a zoom request
  for a pane whose tab is already zoomed on a different pane moves the zoom to
  the named pane rather than leaving the tab.
- **I4** Zoom normalization on the paths this change does not touch is unchanged:
  navigating to a different pane in a zoomed tab still unzooms it, and closing,
  splitting, swapping, moving, or adopting a pane still clears the tab's zoom.
  I3 constrains zoom requests only.
- **I5** A pane-scoped zoom request acts on the named pane's own tab and never
  changes which tab is selected, so a stale context menu still zooms the tab it
  was built for.
- **I6** A zoom request that moves focus within the selected tab marks the newly
  focused pane's alerts read under the focus alert-clear mode; the same request
  aimed at a background tab leaves that pane's alerts unread.
- **I7** A single-pane tab cannot be zoomed by any path.
- **I8** Every scripted reply that describes a pane reports whether *that pane*
  is zoomed, so one reply answers where the zoom landed. The tab-level zoom fact
  stays where it is; this adds the pane-level one beside the pane it describes.

## Proof obligations

Core tests in `lib/DanTermCore/Tests/DanTermCoreTests/`, view tests in
`tests-ui/PaneWrapperViewTests.swift` (which already exercises the button's
collapse-to-zero-width behavior and the pane menu's zoom item).

- **PO1** (I3) Zooming a non-focused pane zooms and focuses that pane, not the
  previously focused one. Zooming a second pane in an already-zoomed tab moves
  the zoom instead of unzooming. Unzoom by name clears it.
- **PO2** (I4) The existing zoom-normalization behavior survives: navigating to
  a different pane in a zoomed tab unzooms it (the go-to-alert unzoom test in
  `UpdateAlertTests.swift` is the standing backstop), and a shape change clears
  the tab's zoom.
- **PO3** (I5) The existing pane-scoped/selected-tab targeting test
  (`toggleZoomPanePaneScoped` in `UpdatePaneTests.swift`) still holds: a request
  naming a background tab's pane leaves tab selection alone, and `nil` still acts
  on the selected tab.
- **PO4** (I6) Both legs -- selected tab clears, background tab does not.
- **PO5** (I7) Every path refuses zoom on a single-pane tab.
- **PO6** (I1) Projection-driven visibility across the transitions: single pane
  hidden, split visible, zoomed visible, back to single hidden.
  `desiredPaneToolbarTracksSplitAndZoomAffordances` in `ProjectionsTests.swift`
  already covers most of this.
- **PO7** (I2) The presentation flips with projected state, in both directions.
- **PO8** (I3, I8 via the scripted path) `pane.zoom` with `on`, `off`, and
  `toggle` resolves against the named pane -- including `on` for a pane whose tab
  is already zoomed on another pane -- and the reply's pane-level zoom field is
  what the assertion reads.

## Non-goals and accepted risks

- No new zoom entry points: no hover-only affordance, no per-pane keyboard
  shortcut, no change to the menubar or existing shortcut.
- No decoupling of zoom target from focus. Zoom hides the other panes, so a
  zoomed pane that does not hold focus would send keystrokes to a hidden pane;
  the coupling is the invariant, and I3 is what makes it explicit.
- **AR1** `pane zoom` on a selected tab's pane now moves key focus, so a script
  that zooms a pane to inspect it takes the caret away from the pane the user is
  typing in. Forced by the non-goal above -- a zoomed pane that does not hold
  focus would swallow keystrokes into a hidden pane -- so the disposition is to
  document it in `SKILL.md`, which today describes `pane zoom` purely as a resize
  stimulus.

## Rejected ideas

- **RI1** Showing the button only on the focused pane. It would sidestep the
  targeting defect without fixing it, leaving a message whose `paneId` parameter
  does not mean what its name says, and it would drop the useful gesture of
  zooming a pane you are not currently in.
- **RI2** Reusing `navigateToPane` for the focus half. It selects the pane's tab,
  which contradicts I5.

## Implementation discretion

- How the view test locates the button once its tooltip is state-dependent (it
  matches on tooltip text today).
- How the pane-level zoom fact reaches the pane encoder, which does not hold the
  owning tab today. I8 fixes what is reported, not the plumbing.

## Verification

- `just test` for the core, protocol, and lint gates; `just test-ui` for the
  pane-wrapper tests.
- End to end against a slot: `just launch-slot | tail -1`, then with an explicit
  `--socket`, `pane split` to make a second pane, `pane zoom --pane <the
  non-focused pane> on`, and confirm from the reply's own pane-level zoom field
  that the named pane is the one zoomed. Confirm the button's
  appearance and both click directions in the running slot, then `just
  stop-slot <n>`.

## Commit progress
- [x] 1. feat(pane): zoom the pane a zoom request names
- [ ] 2. feat(pane): let the toolbar button enter zoom as well as leave it

## Implementation notes

- `PaneTree.toggleZoom()` is replaced by `zoom(_ paneId:)` rather than given a
  parameter. A toggle whose target may differ from the current zoom has two
  meanings a caller cannot see apart, so the tree offers only the two directed
  mutators, `zoom(_:)` and `unzoom()`, and the reducer picks between them.
- `PaneTree.zoomedPaneId` is added and the four places that had spelled the
  predicate out -- the toolbar projection, `containerShape`,
  `effectivePaneVisibility`, and `AppRuntime`'s container mount -- now read it,
  so Decision 1's "single definition" is a fact in the code and not a
  convention.
- The pane-level `isZoomed` is emitted on every encoded pane, `ls` included,
  which contradicted `SKILL.md`'s standing "`ls` does not report it" sentence.
  I8 says every reply that describes a pane reports it, so the sentence was
  corrected rather than the field withheld from `ls`.
- `CheckpointCaptureTests.transientModelFacetsLeaveProjectionUnchanged` now
  zooms the tab's own focused pane. Zoom itself is still transient, but a zoom
  request that has to move focus writes `focusedPaneId`, which is persisted --
  so the old call no longer isolated the facet it names.
