# iOS: a dedicated pane/connection row, and no permanent overlay

## Context

On the phone the status pill floats over the top of the terminal at all times
(`ConnectionStatusPillView`, placed against the top safe area in
`MobileRootViewController.configureConstraints`). It carries two facts with
opposite lifetimes: the pane's location, which is stable and wanted on demand,
and the connection status, which is news only when something is wrong. Both pay
rent on terminal pixels permanently, and the rows behind the pill cannot be
read.

The screen is a small phone, so the fix has to buy the top back without
spending more than it saves.

Desired outcome: while the connection is healthy, no connection status is drawn
over the terminal grid. A fixed row that never moves the terminal names the pane
the user is on, offers the way to the connect sheet, and shows severity at a
glance; the words for a connection that is not healthy come from the pill, which
is on screen only then.

## Decision

Replace the always-on overlay with a dedicated row between the terminal and the
existing bottom bar, and keep a floating pill only for the states that have
something to say.

The row carries exactly two controls:

- A connection dot at the leading edge, colored by status severity, which opens
  the connect sheet.
- The selected pane's name filling the rest, with a trailing disclosure marker,
  which opens the tab/pane picker.

The pane button leaves the bottom bar; the row is now the pane affordance, and
the freed width goes to the key row.

The row shows the pane's own name only -- not `group / tab / pane`. Group and
tab are only actionable inside the picker, which is one tap away, and a short
name does not truncate on a small screen. The projection therefore carries the
selected pane's prepared title, and the composed breadcrumb path
(`MobilePaneBreadcrumb`) goes away rather than being carried unread.

Whether the status has anything to say is decided in `DanTermMobileKit` beside
the line composition, not in the shell. Severity alone cannot decide it:
`connecting` and `disconnected` are `.normal` severity and still need words.
The status is resting only when the connection is serving and no further clause
was appended to the line.

## Invariants

- **I1.** The terminal's bounds do not move in response to connection status,
  pane selection, pane title changes, or the keyboard. The bottom constraint
  reserves the bar and the row as fixed heights.
- **I2.** While the status is resting, no connection-status view is drawn over
  the terminal grid. The arrow pad and the scroll chrome are the user's own and
  are unaffected.
- **I3.** The status is resting only when the connection is serving with no
  further clause to report; every other status is shown as words.
- **I4.** The status line, its severity, and the resting decision are one pure
  value. The shell chooses colors and placement and decides nothing else.
- **I5.** The row holds no session fact of its own: every call states the whole
  row, as the pill does today.
- **I6.** On the terminal screen the connect sheet and the pane picker each have
  exactly one entry point, both in the row. The pill loses its tap: it reports,
  and is not a control.
- **I7.** The arrow pad's allowed region does not change when the pill appears
  or disappears, so the pad does not move when the connection changes.

## Proof obligations

Behavioral tests live in `ios/DanTermMobileKit/Tests/DanTermMobileKitTests/`;
the app target has no tests, so the UIKit half is verified by running it.

- **PO1** (I3, I4). The resting fact is true for a serving connection with
  nothing to add, and false for every other case that reaches the user:
  disconnected, connecting, each failure, and a serving connection carrying a
  stream gap, a refused request, or a pending recovery.
- **PO2** (I5). The projection states the selected pane's prepared title, and
  states nothing when the selected pane has left the roster. This replaces the
  existing breadcrumb assertions in `MobileSessionModelTests`.
- **PO3** (I1, I2, I6, I7). Verified by running the app: see *Verification*.

## Non-goals

- Showing group or tab in the row. The picker is where they mean something.
- Hiding the row while the keyboard is up. It stays, so I1 holds trivially.
- Any change to the pane picker or connect sheet contents.

## Accepted risks

- **AR1.** The row costs a fixed slice of terminal height in every state,
  including healthy ones. Accepted: predictable, reserved space is worth more
  than an overlay that hides live output unpredictably.
- **AR2.** A pane name alone is ambiguous when several panes share a title. The
  picker resolves it in one tap, and the name is the fact that actually changes
  when the user switches panes.
- **AR3.** A shown pill can overlap the arrow pad. Accepted in favour of I7: a
  stationary pad is worth more than a never-occluded one, and the pill is rare.

## Rejected ideas

- **RI1.** Putting the status text in the row's free width beside the pane name,
  deleting the pill entirely. There is not enough width on a small phone for the
  longer failure strings.
- **RI2.** Putting the dot and pane name into the existing bottom bar for zero
  vertical cost. It crowds the key row, where a mis-tap sends a stray key into a
  running process.
- **RI3.** An ephemeral pill that fades after each change. The information is
  gone at the moment the user looks for it, and the fade timer is state the
  current design deliberately does not have.

## Critical files

- `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileStatus.swift` -- the
  resting fact, composed where the line's parts are already joined.
- `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileDisplayText.swift` --
  `MobilePaneBreadcrumb` and `MobilePaneOutline.breadcrumb(for:)` give way to
  the selected pane's title. `MobilePaneEntry.title` already prepares it.
- `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileSessionModel.swift` --
  the projection field.
- `ios/DanTermMobileApp/Sources/DanTermMobileApp/` -- the new row view; the pill
  becomes status-only and shows conditionally; `MobileRootViewController`
  places the row, measures the keyboard obscurity from the topmost
  keyboard-riding chrome rather than from the bar, pins the arrow-pad region's
  top to the safe area, and routes the two taps;
  `TerminalBottomBarView` drops its pane button and the `onPaneList` hook.
- `ios/DanTermMobileKit/Tests/DanTermMobileKitTests/MobileSessionModelTests.swift`.

The sheet comments that justify the medium detent by "the pill above it stays
visible" describe a pill that is now conditional; they need rewording with the
change.

## Verification

- `swift test --package-path ios/DanTermMobileKit` in the red-green loop, plus
  `just lint`.
- `just test` before the commit.
- `scripts/ios-app.sh simulator` to see it, and check by hand:
  - No connection status covers the grid while connected.
  - The grid's row count is unchanged across raising the keyboard, rotating,
    switching panes, and a pane retitling itself (I1).
  - The pill appears on disconnect and while reconnecting, goes away on
    reconnect, does not move the arrow pad, and does nothing when tapped (I7,
    I6).
  - The dot opens the connect sheet and the name opens the picker, and no other
    control on the screen opens either -- the bottom bar has no pane button
    left (I6).

## Implementation discretion

- The row's height, starting near 36pt, with the dot keeping a tap target of at
  least 44pt regardless of the row's visual height.
- How the resting fact is spelled on the status value, and the name and internal
  structure of the new row view.

## Implementation notes

- The row is 44pt, not the 36pt the plan named as a starting point. A shorter
  row can only reach the 44pt tap target the plan also requires by expanding the
  row's own hit area up into the terminal, which then steals grid taps. Sizing
  the row to the target instead removes the conflict: the dot is a 44x44 button
  with small artwork, and no hit-testing reaches outside the row. The cost is
  about half a terminal line beyond the plan's estimate.
- The pill's status text moved from `caption1` to `subheadline`. It is now the
  only thing in the pill, so it takes the size the pane path used to have.
- The pane row's control is a leading-aligned button carrying the name and the
  disclosure marker together, rather than a name filling the width with the
  marker pinned to the trailing edge. The button still spans the row's whole
  free width, so the tap target is the same; only the marker sits beside the
  name instead of far from it.
