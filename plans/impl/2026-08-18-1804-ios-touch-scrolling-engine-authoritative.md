# iOS touch scrolling: engine-authoritative scroll with UIScrollView chrome

## Problem

A swipe on the phone scrolls exactly one line, only when the gesture ends, with
no momentum, no distance sensitivity, and no scroll indicator. The pan handler
(`ios/DanTermMobileApp/Sources/DanTermMobileApp/MobileRootViewController.swift`,
`scrolled(_:)`) reads only the sign of the translation on `.ended` and
dispatches one `.scrolled(direction)` event, which `MobileInputMapper.scroll`
turns into a single one-row step. No UIScrollView exists, so nothing draws an
indicator.

Load-bearing premises, verified in source:

- The replica's `Terminal` is fully local on the phone
  (`PaneReplica.terminal`), so the phone can compute the whole scroll
  projection itself: `Terminal.scrollProjection` gives
  `{totalRows, topRow, windowRows, isFollowing}`, degenerate on the alternate
  screen. `Terminal.scroll(toTopRow:)` clamps, no-ops on the alternate screen,
  and re-enters `.following` when the request lands on the maximum top row.
- The macOS pattern (`app/ScrollableTerminalView.swift`) already solved the
  ownership problem: the scroll view is chrome and drag input only; the engine
  is the one scroll authority; a live-scroll latch keeps programmatic
  reflection from fighting the user; pinned-to-bottom falls out of the
  projection, not view state.
- `IpcPaneInput.events([InputEvent])` already carries an array, and the Mac
  applies one row per remote `.wheel` event, routed server-side through
  `TerminalInteractionPolicy.wheelRoute` (mouse report vs arrow-key fallback).
  A proportional alternate-screen flick therefore needs no wire change.
- Remote viewport navigation records replay into the replica
  (`PaneReplica.applyEvent`, `.viewport` case), and a resync rebuilds the
  terminal `.following` -- so the viewport can move under the view without a
  local gesture.
- `MobileSurfaceFacts` (the alternate-screen bit included) refreshes on every
  applied record, not only on layout: `TerminalSurfaceView.apply` fires
  `didChangeReplicaState`, whose controller handler re-reports the surface
  facts. The model therefore learns a screen-mode flip no later than the
  scroll driver does.
- The app package `DanTermMobileApp` has no test target by design; every
  decidable piece must live in `DanTermMobileKit` to be testable.

## Decision

Transpose the macOS structure to iOS. The engine stays the only scroll
authority; a UIScrollView is pure chrome -- gesture physics, momentum,
rubber-banding, and the system scroll indicator. The terminal surface view is
not embedded in it.

- A transparent, non-interactive UIScrollView overlays the terminal; its
  `panGestureRecognizer` is installed on `TerminalInputView` so tap-to-focus
  and long-press are untouched. It replaces the current one-shot pan
  recognizer. Its scrollable viewport is the exact drawn grid rectangle --
  the drawn origin and `windowRows * rowHeight` from the scroll-facts seam,
  not the terminal view's bounds: the fitted grid is bottom-pinned and can be
  shorter than the view, and an oversized viewport makes UIKit's maximum
  offset fall short of the engine's maximum top row, so the indicator could
  never reach the bottom and idle reflection could never converge.
- A pure scroll-geometry type in `DanTermMobileKit` owns every decision:
  projection -> content size and offset (top-origin: content height is
  `totalRows * rowHeight`, offset is `topRow * rowHeight`); user offset ->
  clamped absolute top row with per-row dedupe; a fractional-point delta
  accumulator for the alternate screen; and mode selection (projected /
  delta / inert).
- Scroll gestures stay session events routed through the model -- a gesture
  becomes a session event, the model decides local-versus-remote on
  replicated state, and the view never encodes bytes or picks the
  destination itself -- in the two meanings a scroll actually has:
  - absolute `.scrolled(toTopRow:)` from projected mode -> local
    `.scrollViewport` effect -> `PaneReplica` -> `Terminal.scroll(toTopRow:)`;
    dropped on the alternate screen.
  - relative `.scrolled(byRows:)` from delta mode -> on the alternate screen,
    one `.send` whose pane input is `.events` with one `.wheel` event per row;
    on the primary screen (mode-change race), a local relative scroll.
  Each event category has a safe meaning under either replicated mode, so a
  stale mode in the view can never produce a wrong-category action.
- Delta-mode recentering is an atomic baseline reset: when the
  infinite-content offset is re-centered, the accumulator's baseline moves
  with it and no gesture delta is emitted. The reset is an internal
  bookkeeping move, not a programmatic scroll, so it is exempt from the
  interaction latch (I5) and may happen mid-drag or mid-deceleration.
- Reflection is one-directional and latched: while the user is tracking,
  dragging, or decelerating, nothing programmatic moves the scroll view; when
  idle, every replica change (applied record, local scroll, reset, layout)
  re-derives content size and offset from the projection. This is also the
  whole answer to remote viewport yanks: idle reflection shows them, and a
  live gesture's next absolute row overrides them.
- The wheel events carry the gesture's grid cell (from the surface's
  bottom-pinned drawn origin and fitted cell size) instead of the current
  hardcoded 0,0, so server-side mouse reporting sees a real position.
- `TerminalSurfaceView` gains one read-only scroll-facts seam (projection,
  row height in points, drawn origin, alternate-screen bit) and a
  `scrollViewport(toTopRow:)` mirror of the existing relative entry point.

Why not the native shape (surface embedded in a UIScrollView): UIKit would
become the scroll authority, but the renderer holds only `windowRows` of
pixels, and replicated viewport records plus `.following` re-entry would fight
UIKit for ownership of the offset. Why not hand-rolled pan physics: it
rediscovers momentum and indicator work UIScrollView already does.

## Invariants

- I1: The engine is the only scroll authority. UIScrollView state is a
  projection of `scrollProjection`; it is read back only during user
  interaction, and then only to produce gesture facts.
- I2: Primary-screen scrolling is phone-local (no wire traffic);
  alternate-screen scrolling is wire-only, as `.wheel` events the Mac routes
  through its own wheel policy. The model makes the split from replicated
  state.
- I3: Clamping, pinned-to-bottom, and following re-entry are the engine's;
  new output while following keeps the view at the bottom, new output while
  browsing keeps the user's reading position.
- I4: A scroll row may cross the view-model boundary only as a transient
  event payload; scroll position is never stored in `MobileSurfaceFacts` or
  any persistent model state, and handling a scroll event produces no
  `.redraw`.
- I5: While the user interacts, nothing programmatic moves the scroll view;
  on interaction end, exactly one reflect reconciles chrome with engine
  truth. The delta-mode baseline reset is exempt: it moves offset and
  baseline together and emits no gesture delta.
- I6: The scroll indicator is visible and proportional exactly when the
  projection is non-degenerate; it is hidden and inert on the alternate
  screen and with no scrollback.
- I7: Within a gesture's routed mode, motion maps proportionally to rows
  (fractional remainders accumulate across callbacks; whole rows are never
  discarded), and finger-down motion moves toward history on both screens.
  Motion routed under a screen mode the replica has since left may go inert
  -- the Mac latches a wheel gesture's route at its start and applies zero
  local rows on the alternate screen, and residual momentum must not turn
  into key input for a full-screen app that appeared mid-flick.

## Proof obligations

Swift Testing, in `ios/DanTermMobileKit/Tests/DanTermMobileKitTests`, TDD
order: geometry, then routing, then the replica seam.

- PO1 (I1, I3): geometry round-trip -- projection to content height/offset and
  offset back to a clamped top row, including bounce past both ends;
  following implies offset equals content height minus viewport height. Must
  cover a fitted grid shorter than its terminal view: the viewport height is
  the drawn grid's, and the maximum offset reaches the engine's maximum top
  row.
- PO2 (I6): mode selection -- alternate screen selects delta mode, degenerate
  primary is inert, scrollback selects projected mode with the indicator on.
- PO3 (I4, I5): an offset stream crossing one row boundary emits one fact
  (per-row dedupe), and scroll events return no redraw effect. Must also
  prove the interaction latch as pure driver state: projection changes
  arriving during tracking, dragging, and deceleration produce no reflection,
  and the transition to idle produces exactly one.
- PO4 (I7): the delta accumulator turns fractional points into whole rows with
  remainder preserved, both signs, correct direction. A baseline reset during
  a drag or deceleration emits no delta, and motion across the reset still
  maps to the same total rows.
- PO5 (I2): model routing -- absolute event on primary yields the local
  effect and no send; absolute on alternate yields nothing; relative on
  alternate yields one send with the right count, direction, and carried
  cell; relative on primary yields a local relative scroll; no selected pane
  yields nothing.
- PO6 (I1, I3): `PaneReplica.scrollViewport(toTopRow:)` guards non-exact and
  alternate screen, moves the viewport, and restores following at the maximum
  top row.
- PO7 (I7): point-to-cell mapping honors the bottom-pinned drawn origin and
  fitted cell size and clamps to the grid.

The gate is `just test`. End-to-end: `just launch-slot` a Mac instance, run
the iOS app in the simulator against it, fill scrollback (e.g. `seq 1 500`),
and verify: a flick scrolls proportionally with momentum and an indicator;
output while at bottom stays pinned; output while browsing does not yank; in
`less` (alternate screen) a swipe moves proportionally and shows no
indicator.

## Non-goals

- Sub-row pixel smoothness (over-scan frame stores plus fractional layer
  offset). Row-quantized stepping matches the engine's row-addressed viewport
  and macOS behavior; smoothness is additive later without changing this
  structure.
- Any wire protocol change (proven unnecessary).
- Horizontal scrolling, scrollbar dragging as a distinct affordance, hardware
  page keys, and any Mac-side behavior.
- Reconciling remote viewport records beyond the interaction latch.
- Persisting the browse position across reconnects or pane switches (a resync
  legitimately restarts following).

## Rejected ideas

- RI1: Embedding the surface in a UIScrollView -- makes UIKit the scroll
  authority and forces scrollback tile rendering; the ownership fight with
  replicated viewport records is the bug class this design exists to prevent.
- RI2: Reusing `DanTermCore/ScrollbarMath.swift` -- internal, macOS-only,
  bottom-origin AppKit math; the top-origin iOS math is trivial and belongs
  beside the other pure mobile types in `DanTermMobileKit`.
- RI3: One mode-independent gesture event carrying delta, optional absolute
  row, and the replica's alternate-screen bit, routed by the model on the
  carried bit. Rejected: the staleness it targets does not exist -- every
  applied record refreshes `MobileSurfaceFacts` through
  `didChangeReplicaState` before the driver can reconfigure, so the model
  learns a mode flip no later than the view -- and re-routing a gesture's
  residual motion into the new mode contradicts the Mac's per-gesture route
  latching (I7): it would inject leftover flick momentum as arrow keys into
  a just-opened full-screen app.

## Implementation discretion

- Names of the new types and whether the root view controller or the session
  controller wires the driver callbacks.
- Infinite-content recentering constants for delta mode, and bounce
  configuration in projected mode.

## Critical files

- `ios/DanTermMobileKit/Sources/DanTermMobileKit/` -- new pure scroll-geometry
  type; `MobileInputMapper.swift`, `MobileSessionModel.swift`,
  `MobileSessionEvent.swift`, `MobileSessionEffect.swift`,
  `PaneReplica.swift`.
- `ios/DanTermMobileApp/Sources/DanTermMobileApp/` -- new scroll-driver view;
  `TerminalSurfaceView.swift` (scroll-facts seam),
  `MobileRootViewController.swift`, `MobileSessionController.swift`.

## Commit progress
- [x] 1. Pure scroll geometry, mode selection, and the interaction latch in `DanTermMobileKit`
- [ ] 2. Scroll routing through the session model and the replica's absolute-scroll seam
- [ ] 3. UIScrollView chrome driving the phone's terminal scroll

## Implementation notes

- Commit 1: I7's "motion routed under a screen mode the replica has since left may go
  inert" is enforced in the driver rather than left to the model. When a replica change
  flips the mode kind while the latch is held, the driver marks the gesture stale and the
  rest of it emits nothing. The model's own safe meaning for each event category (the
  Decision's mode-change race) still stands as the second line of defence.
- Commit 1: the delta accumulator's reset takes both the old and the new offset
  (`recenter(from:to:)`) rather than only the new one. Shifting the baseline by the same
  distance the offset moved is what keeps the fraction still pending, which is what PO4's
  "motion across the reset maps to the same total rows" asks for.
- Commit 1: `MobileObserveSurface` answers the point-to-cell question (PO7) rather than a
  new type, because it already owns the fitted cell size, and the grid is recoverable from
  its pixel extent. Its `drawnFrame(in:)` is also the bottom-pinned rectangle
  `TerminalSurfaceView` positions its layer at today, so commit 3 can read one value where
  there are now two.
- Commit 1: delta mode's constants are 100,000 points of content, parked at the middle,
  recentered once the offset is more than a fifth of that from it.
