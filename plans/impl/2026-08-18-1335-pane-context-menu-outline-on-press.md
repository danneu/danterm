# Pane context menu: native outline, opened on press

## Problem and evidence

Right-clicking a pane gives no sign of which pane the menu acts on, and the
menu arrives late. The sidebar and theme browser have neither problem: they
route their built menu through `NSTableView.menu(for:)`
(`app/TableContextMenuHighlight.swift`), so AppKit outlines the clicked row and
pops the menu synchronously inside `rightMouseDown`.

A pane is a plain `NSView`, so it gets no outline. Its menu is late for two
independent reasons, both confirmed in the source:

- **It opens on release, not press.** `pointerOwner` in
  `lib/TerminalCore/Sources/TerminalCore/TerminalInteractionPolicy.swift`
  already decides the pane-menu arm at press time, from the button, the
  modifiers, and the mouse-tracking mode. The menu cell is nonetheless minted
  only in the release branch. The cost is however long the button is held.
- **The request then leaves the main thread and comes back.** The press is
  forwarded to the engine's serial queue, decided there, and delivered back
  through a main-queue hop. Under output load it queues behind engine work, so
  the lateness is variable.

`SwiftTerminalSessionView.menu(for:)` returns nil today: the terminal view opts
out of AppKit's menu path entirely.

Load-bearing premises verified against the tree:

- The main side already holds a whole `Terminal` value refreshed on every
  consumed update (`TerminalPaneSession.swift`), and already answers a
  menu-time question from it without fencing: `hasSelection`, whose call site
  `validateMenuItem` records the rule that menu tracking must not block on the
  render owner.
- Mouse tracking is the only terminal-owned condition. The rest of the
  right-button decision is the event's own shift modifier. Alternate screen,
  selection, and link arming play no part in it.
- Menu-on-release is a **pinned decision**, not an oversight:
  `tests-ui/SwiftTerminalSessionViewTests.swift` states its rationale as
  AppKit's down-time menu lookup racing child mouse-capture modes. This plan
  overturns it deliberately; see AR1.
- On a control-click, AppKit asks for the menu *before* delivering the mouse
  lifecycle. Both Ghostty's `SurfaceView_AppKit.swift#menu(for:)` and this
  repo's own control-click UI test say so.

## Decision

Two independent changes to the same gesture.

**D1 — outline the pane under its context menu.** An overlay pinned to the pane
wrapper's full bounds draws the system focus ring while the menu tracks, added
and removed on the menu's own open/close callbacks. It is installed by the
single shared menu builder, so the terminal right-click, the "..." toolbar
button, and the drag-handle right-click all get it.

The ring is drawn by AppKit's own focus-ring machinery rather than stroked by
hand, so it tracks the accent color and the Increase Contrast setting without
this code naming a color. It is purely additive: the focus/bell border lives on
a different view inside the terminal's reserved gutter and is untouched.

**D2 — decide the pane menu on the main thread, at press time.** The view
answers "does the terminal want this right-click?" from the already-cached
terminal value plus the event's modifiers, and hands AppKit the menu from
`menu(for:)`. AppKit then pops it on press, positioned natively at the pointer.

D2 is a net deletion. AppKit becomes the sole owner of the local pane-menu
gesture, so the engine keeps no menu-related state or work: the menu cell, its
callback through the host and the session, the view's async menu seam, both
queue hops, the hand-rolled cell-origin positioning, and the pane-menu arm of
pointer policy itself all go away. An unclaimed right-button event that still
reaches the engine — which happens only in the AR1 window — is ignored, the
same as the middle button; a claimed one still reports. Keeping an arm named
for a menu it can no longer open would be the more complex outcome, not the
safer one.

Rejected alternative, kept on the record per the design bar: publishing the
tracking mode as a new field on the view-facing session state. It reaches the
same behavior but adds a channel and a fresh invalidation question, where
reading the cached terminal reuses a question this codebase has already
answered.

## Invariants

- **I1.** While a pane's context menu is tracking, that pane and no other draws
  the outline; it is gone when the menu closes, by either dismissal or
  selection.
- **I2.** The outline does not disturb the focus/bell border, pane layout, or
  hit testing.
- **I3.** All three pane-menu entry points show the outline.
- **I4.** A right-click the terminal application has claimed reports mouse bytes
  and opens no menu. Shift overrides the claim: it opens the menu and reports
  nothing.
- **I5.** An unclaimed right-click opens the menu on press.
- **I6.** Control-click both opens the menu and gives the pane focus, on a pane
  that did not already have it.
- **I7.** No right-button press is forwarded to the engine without its matching
  release, so the engine's button ownership cannot be left held by a gesture
  AppKit consumed for menu tracking.

## Proof obligations

One entry per invariant; a single test may discharge several.

- **PO1** (I1, I3): the outline appears for each entry point and is removed on
  close.
- **PO2** (I2): mounting and unmounting the outline changes neither the pane's
  layout nor which view answers a hit test.
- **PO3** (I4): with tracking claimed, a right-click yields report bytes and no
  menu; with shift held, a menu and no bytes.
- **PO4** (I5): an unclaimed right press yields a menu without waiting for the
  release.
- **PO5** (I6): a control-click reports the pane-focus event and offers the
  menu. This is the regression the change most easily hides, because the menu
  half keeps working when the focus half breaks.
- **PO6** (I7): no forwarded press is left unpaired. The failure this rules out
  is a latched owner swallowing a later right-click that the terminal does
  claim.
- **PO7** (AR1, I4): at the session layer rather than through a view test — the
  claim query reflects a mouse-mode change once the update carrying it has been
  consumed, and answering it fences no host. The UI tests cannot discharge this:
  their shim answers from immediate state, so an implementation that fenced the
  host, or that read state which never refreshes, would pass them while
  restoring the latency or routing clicks against a stale mode.

Existing coverage this plan invalidates rather than satisfies: the UI tests
pinning menu-on-release, the pointer-policy assertions that the menu cell is
absent on press, the host test pinning that an uncaptured pane menu is returned
only after right-button release, and the pane-menu arm of the controller's
application-exit fence test. They encode behavior being deleted or overturned,
so they change with it; the shim's menu synthesis moves to the press event. The
exit-fence test keeps its remaining contract over frame, link, search, and
selection deliveries — only its pane-menu arm goes.

End-to-end check beyond the suites: run `just launch-slot`, split a tab into
three panes, and confirm on a live pane that the outline names the pane under
the pointer, that the menu appears on press, and that control-clicking an
unfocused pane both focuses it and opens the menu. Confirm I4 in an application
that claims the mouse.

## Non-goals

- Changing what the pane menu contains, or the menus of the sidebar and theme
  browser.
- Changing left-button selection, link activation, or wheel routing.

## Accepted risks

- **AR1.** The cached tracking mode can lag the engine by at most one consumed
  update, so a right-click landing within roughly one display interval of an
  application toggling mouse reporting may be decided against the previous
  mode. Accepted: the toggle rode bytes that raced the click, so the gesture is
  ambiguous under any design that does not block; both directions cost one
  click. This is the explicit overturn of the pinned menu-on-release decision.
- **AR2.** The outline overlaps a few points of pane content while it is up,
  rather than reserving a gutter. Accepted: it is transient, and reserving
  space would reflow the grid on every right-click.

## Rejected ideas

- **RI1.** Fencing the engine at click time for a non-stale answer. It blocks
  the main thread on a busy engine, which is the latency this plan removes, and
  contradicts the no-fence rule already recorded at `validateMenuItem`.
- **RI2.** Minting the menu cell on press while keeping the async delivery
  path. It fixes only the press-versus-release half, keeps both hops, and still
  overturns the pinned test — the full cost for part of the benefit.
- **RI3.** Synthesizing a right-button press in the control-click path, as
  Ghostty does. Ghostty's capture protocol needs that press; the local arm here
  emits no bytes, and an unpaired press would violate I7.

## Implementation discretion

- Ring geometry — inset, corner radius, and whether the overlay covers the pane
  toolbar as well as the terminal area.
- How the view is given its menu, and the shape of the test seam that replaces
  the async one. `ToolbarDragHandleView` in `app/PaneWrapperView.swift` already
  carries a menu-provider closure for exactly this purpose.

## Critical files

- `app/PaneWrapperView.swift` — the shared menu builder, the menu delegate, and
  the ring overlay.
- `app/SwiftTerminalSessionView.swift` — `menu(for:)`, the right-button and
  control-click paths, and the removal of the async menu seam.
- `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift` — the
  cached-terminal answer for whether the terminal claims the button, and the
  removal of the menu callback.
- `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift` — removal of
  the menu callback threaded through the pointer path.
- `lib/TerminalCore/Sources/TerminalCore/TerminalInteractionPolicy.swift` — the
  pane-menu arm is removed.
- `tests-ui/SwiftTerminalSessionViewTests.swift` and its shim — the overturned
  menu-timing tests and the new control-click focus coverage.
- `lib/TerminalPTY/Tests/` — the host's menu-on-release test, the controller's
  exit-fence pane-menu arm, and the new session-layer claim-query coverage.

## Commit progress
- [x] 1. Outline the pane under its context menu (D1)
- [ ] 2. Open the pane context menu on press, decided on the main thread (D2)

## Implementation notes

- Commit structure: the plan prescribed none, so D1 and D2 were sliced into two
  commits. D1 is additive and leaves the tree green on its own; D2 is the
  cross-layer deletion. Splitting them keeps the deletion reviewable against a
  tree where the outline already works.
- Ring geometry (plan discretion): the overlay covers the whole wrapper,
  toolbar included, inset 3pt with a 4pt corner radius. The inset is what keeps
  the exterior ring AppKit draws around the filled path inside the overlay's
  own bounds instead of clipped away.
- PO1 is discharged through `NSMenuDelegate` rather than real menu tracking: a
  UI test cannot enter AppKit's nested tracking loop, so the tests call
  `menuWillOpen`/`menuDidClose` on the built menu's delegate. A third test
  renders the overlay into a bitmap, because the mount/unmount pair would pass
  against an overlay that draws nothing.
- The plan's live end-to-end check was not run for this slice. Driving a
  right-click into another application needs posted CG events and the
  accessibility grant that goes with them; the check is better run once against
  the finished gesture after D2.
