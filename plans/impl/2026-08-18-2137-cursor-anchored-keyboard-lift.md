# Cursor-anchored keyboard lift

## Context

The keyboard-stable placement work (commit a04c80f7) made the keyboard a pure
presentation offset: the drawn grid keeps its keyboard-absent metrics, is
bottom-pinned at the bar's top, and a keyboard show slides the top rows out of
the clip by the full obscured height. That lift is blind to where the content
is. In a fresh pane the prompt sits on row 0, so summoning the keyboard slides
the prompt off the top of the screen while the rows the lift protects at the
bottom are empty.

Desired outcome: the keyboard lifts the drawn content only as far as needed to
keep the cursor row visible above the bar. A fresh prompt stays put; a full
screen of output keeps today's behavior exactly.

Load-bearing premises, verified in code:

- The phone runs a full local replica (`PaneReplica.terminal`, a
  `TerminalCore.Terminal`), and `Terminal.cursorPlacement`
  (`lib/TerminalCore/Sources/TerminalCore/Terminal.swift`) already answers the
  cursor's row in viewport coordinates -- nil when the cursor is outside the
  viewport. It is not nil in every browsing state: a shallow scroll-back can
  keep the cursor inside the window (`browsingCursorCoordinates` in
  `ViewportRenderPlanningTests`), and `PaneReplica` retains its terminal
  while inexact, so anchor eligibility needs more than a non-nil placement.
  No new data has to reach the phone.
- `MobileSurfacePlacement` is already the single source of the drawn
  rectangle for the layer position, the scroll chrome, and gesture-to-cell
  mapping, so changing the lift in that one value moves all three together.
- The bottom bar (`TerminalBottomBarView`) has no background color today; it
  is only ever over empty screen because the full lift pins the drawn bottom
  at its top. A partial lift puts live rows behind it.

## Decision

**D1 -- the lift is the minimum that keeps the cursor row visible.** The
placement's lift becomes `clamp(obscured - slack, 0, obscured)`, where
`slack` is the drawn content below the cursor row's bottom edge. Cursor on
the bottom row: full lift, today's behavior. Cursor high enough that the
keyboard only covers content below it: zero lift, the prompt stays put.
In between: the cursor row's bottom edge lands exactly on the bar's top.
The computation stays a pure `DanTermMobileKit` value with behavioral tests;
the UIKit side only feeds it the cursor's viewport row from the replica.

**D2 -- the anchor is the cursor's position, not its visibility.** Shells and
TUIs wrap redraws in cursor hide/show sequences; a visibility-gated anchor
would flap between zero and full lift on every redraw. Position is stable.
The anchor exists only when all three hold: the replica is exact, its scroll
projection is following, and `cursorPlacement` is non-nil. Otherwise -- no
terminal yet, an inexact replica with a retained terminal, any browsing
window (even one shallow enough to keep the cursor on screen), or a cursor
outside the viewport -- the lift falls back to the full obscured height,
which is today's behavior.

**D3 -- the bar becomes opaque black.** With a partial lift, live rows sit
behind the transparent bar strip. Black over the terminal's black is
visually identical today and keeps I4 without masking machinery.

## Invariants

- I1 (carried from the keyboard-stable plan, unchanged): no keyboard state
  reaches a grid, a claim request, or a frame-store allocation. The cursor
  anchor adds a replica fact to the placement, not a keyboard fact to
  anything else.
- I2: the lift is minimal and clamped -- never negative, never more than the
  obscured height, and when it is nonzero the cursor row's bottom edge sits
  exactly on the bar's top at whole-backing-pixel alignment.
- I3 (carried): the drawn layer, the scroll chrome, and gesture-to-cell
  mapping read one placement and move together; a hit on a visible row
  resolves to that row at any lift.
- I4: no cell ever shows through the bar.
- I5: without an eligible anchor (D2: exact replica, following projection,
  cursor in the viewport), the lift is the full obscured height.

## Proof obligations

Kit-level (existing harnesses; PO1/PO2 in `SurfacePlacementTests`, PO3
wherever the eligibility rule lives as a pure value):

- PO1 (I2, I5): against one content box and obscured height, varying the
  anchor covers: bottom-row cursor gives the full lift; a cursor with slack
  at least the obscured height gives zero; a mid-screen cursor puts its row's
  bottom exactly at the visible floor; no anchor gives the full lift; the
  clamp holds at both ends and the result is whole backing pixels.
- PO2 (I3): at a partial lift, a point over a visible row maps to that row
  through `cell(at:in:)`, and `drawnFrame(in:)` moves by the same lift.
- PO3 (I5, D2): anchor eligibility -- a shallow browsing window whose cursor
  is still on screen yields no anchor (full lift), and so does an inexact
  replica that retains its terminal; the anchor returns when the projection
  follows again and the replica is exact.

View-level (simulator, `scripts/ios-app.sh simulator`, against a live Mac
instance):

- PO4 (D1/D2 wiring): fresh pane -- keyboard show leaves the prompt at the
  top; after enough output the prompt reaches the bottom and rides the bar's
  top; a TUI with a mid-screen cursor lifts partially; scrolled back, the
  full lift returns; typing that moves the cursor across the visible
  boundary slides the content to follow it.
- PO5 (I4): with the keyboard up in a partially-lifted pane, no cells show
  through the bar strip.

## Non-goals

- Resizing the grid for the keyboard, in any form; the keyboard-stable claim
  design stands.
- A user-driven pan of the clipped rows while the keyboard is up.
- Keeping any margin of context below the cursor row; the lift is minimal by
  design.

## Accepted risks

- A TUI that parks its cursor away from the content the user watches (htop
  hides its cursor near the top) anchors there and lets the keyboard cover
  bottom rows the old behavior kept visible. Either anchoring loses some
  rows; dismissing the keyboard restores the full grid.
- The content slides when the cursor crosses the visible boundary or when a
  scroll toggles the no-cursor fallback. This is scroll-to-cursor behavior,
  accepted as a feature.

## Rejected ideas

- Anchoring only when the cursor is visible: redraw-cycle hide/show would
  flap the lift every prompt repaint (D2).
- Anchoring on content extent (last non-empty row): a heuristic the cursor
  answer subsumes, and wrong on alternate-screen TUIs.

## Implementation discretion

- The shape of the anchor input to `MobileSurfacePlacement` (a slack pixel
  count, a cursor row plus metrics, or a helper on `MobileObserveSurface`),
  so long as PO1 tests it as a pure value.
- How the surface view schedules a layout pass when the applied records or a
  viewport scroll move the anchor while the keyboard is up.

## Critical files

- `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileSurfacePlacement.swift`
- `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileObserveSurface.swift`
- `ios/DanTermMobileKit/Tests/DanTermMobileKitTests/SurfacePlacementTests.swift`
- `ios/DanTermMobileApp/Sources/DanTermMobileApp/TerminalSurfaceView.swift`
  (feeds the anchor from `replica.terminal?.cursorPlacement`, invalidates on
  anchor movement)
- `ios/DanTermMobileApp/Sources/DanTermMobileApp/TerminalBottomBarView.swift`
  (opaque background, D3)

## Verification

- TDD: extend `SurfacePlacementTests` first, watch them fail, then change the
  kit value. `swift test --package-path ios/DanTermMobileKit`, then the full
  `just test`.
- Simulator walk of PO4/PO5 with `scripts/ios-app.sh simulator` against a
  live Mac DanTerm instance (the interactive half stays with the user, as in
  the prior keyboard plan).

## Implementation notes

- Anchor input shape (discretion exercised): the placement takes an optional
  slack pixel count (`anchorSlackPixels` on `MobileSurfacePlacement.init`),
  computed by a new `MobileObserveSurface.slackPixels(belowRow:)` helper. The
  D2 eligibility rule lives as `PaneReplica.cursorAnchorRow`, because all
  three of its inputs (exactness, following projection, cursor placement) are
  replica facts; PO3 therefore tests it in `PaneReplicaTests`.
- Layout scheduling (discretion exercised): `TerminalSurfaceView` snapshots
  the anchor slack before `apply(_:)` / `scrollViewport(_:)` and schedules a
  layout pass when it changed, gated on the keyboard being up; keyboard
  show/hide itself is already covered by the `obscuredBottomHeight` setter.

## Follow Up

- Walk PO4/PO5 interactively: `scripts/ios-app.sh simulator` against a live
  Mac instance -- fresh-prompt keyboard show, full-screen output, mid-screen
  TUI cursor, scroll-back fallback, and no cells showing through the opaque
  bar. The plan leaves this half with the user.
