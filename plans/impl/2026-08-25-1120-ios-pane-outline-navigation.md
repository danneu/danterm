# The phone navigates by tab, then by pane

## Context

The phone reaches every pane through one flat list
(`ios/DanTermMobileApp/Sources/DanTermMobileApp/PaneSheetViewController.swift`).
Each row is a pane, titled with the pane and subtitled `group / tab`. The list
has no structure: a Mac with four groups of tabs of panes arrives as one run of
rows that all look alike, and the only way to find "the tab I was working in" is
to read subtitles.

On the Mac the user navigates in two steps -- pick a tab, land on the pane that
tab last focused; switch panes inside the tab separately. The phone should do
the same, and the facts it needs are already on the wire.

Load-bearing premises, with evidence:

- **The roster already states each tab's focused pane.**
  `lib/DanTermCore/Sources/DanTermCore/PaneRosterProjection.swift` sets
  `isFocused: pane.id == tab.paneTree.focusedPaneId` -- focus *within a tab*, not
  app focus, exactly as `PaneRoster.swift` documents it. The phone already
  depends on this to pick its first pane
  (`MobileSessionModel.swift`, the `isSelectedTab && isFocused` fallback).
- **The roster is already ordered group, then tab, then split tree**, and
  `paneRoster(in:)` emits it that way in one pass. A group's panes are
  contiguous and a tab's panes are contiguous inside them, so an outline is a
  grouping of runs and needs no sort and no comparator.
- **The roster is pushed, not polled.** `PaneRosterNotification` replaces the
  whole list on any change (`MobileSessionModel.swift`), and the open sheet is
  already repainted from every redraw
  (`MobileRootViewController.render`).
- **The app target has no test target**, stated in
  `MobileSessionModel.swift`'s header and again in `TerminalInputView.swift`.
  Anything decided in the UIKit shell is decided unproven, so the navigation
  structure has to be a pure value in `DanTermMobileKit`.
- **Switching panes costs a full reconnect.** `.paneSelected` routes through
  `selectPane` -> `reconnect(.targetReused)` -> `.disconnect` + `.connect`. Pane
  switching is therefore a deliberate act, not a flick.

Outcome: one sheet that shows the Mac's real shape -- groups, their tabs, and a
tab's panes -- where picking a tab lands on the pane that tab last focused, and
the phone always says where it is.

## Decision

Replace the flat pane list with a hierarchical outline projected in the kit, and
keep the single bottom-bar button that opens it.

- The sheet is sectioned by group. Its rows are tabs. A tab with more than one
  pane expands inline to its panes; a tab with one pane does not expand at all.
- Picking a tab row selects the pane the roster marks focused in that tab.
  Picking a pane row selects that pane. Both raise the existing `.paneSelected`
  event -- no new event, no new server method, no new roster field.
- The phone reads the Mac's per-tab focus and keeps no memory of its own. One
  owner of "which pane is this tab's", which the phone already trusts at
  connect.
- The whole outline, and the breadcrumb naming where the phone is, are computed
  in `DanTermMobileKit` and replace the projection's flat `panes` list. The
  sheet paints what it is given and reports the row that was tapped, which is
  what its own header already says it does.
- The status pill names the selected pane's group, tab, and pane. A hierarchy
  takes away the orientation every flat row used to carry; the pill gives it
  back.

Critical files:
`ios/DanTermMobileKit/Sources/DanTermMobileKit/{MobileSessionModel,MobileDisplayText}.swift`,
`ios/DanTermMobileApp/Sources/DanTermMobileApp/{PaneSheetViewController,MobileRootViewController,ConnectionStatusPillView}.swift`,
`ios/DanTermMobileKit/Tests/DanTermMobileKitTests/MobileSessionModelTests.swift`.

## Invariants

- **I1 -- The outline is the roster's own order, grouped.** Groups, tabs within
  a group, and panes within a tab appear in roster order. Nothing sorts,
  re-ranks, or de-duplicates; a group or tab whose panes are not contiguous in
  the roster is not something the projection invents structure to repair.
- **I2 -- Every pane in the roster is reachable from the sheet.** No pane is
  addressable only by being its tab's focused one.
- **I3 -- A tab row selects that tab's focused pane.** When the roster marks no
  pane focused in a tab, the row selects that tab's first pane rather than
  refusing the tap.
- **I4 -- Expansion is offered only where it means something.** A tab holding
  one pane offers no expansion and no second row. Whether a tab may expand is a
  projection fact, not a count the sheet re-derives.
- **I5 -- The sheet opens showing where the phone already is.** When the
  selected pane's tab holds more than one pane, the projection names that tab as
  the one expanded on appearance, so the user sees their position without a tap.
  It names no tab when the selected pane's tab holds one pane, or when the
  selected pane is not in the roster.
- **I6 -- Which tabs are expanded right now is the sheet's own transient
  state.** It lives only as long as the sheet. Across a roster replacement the
  sheet keeps an expansion only while its tab is still in the roster and still
  expandable, and drops every other. So a pane opened or closed on the Mac does
  not collapse a tab the user opened, a tab that has left the roster is not left
  expanded, and a tab the Mac has reduced to one pane loses an expansion I4 says
  it can no longer offer.
- **I7 -- The breadcrumb names the selected pane's group, tab, and pane**, from
  the same prepared display text the rows use. When the roster no longer holds
  the selected pane the breadcrumb is absent, as the pane title is today, rather
  than showing a stale or partial path.
- **I8 -- The shell decides nothing about the roster.** Grouping, ordering,
  which pane a row selects, which tabs may expand, which tab starts expanded,
  and the breadcrumb text are all read from the projection. The one thing the
  sheet owns is I6's transient set.

## Proof obligations

- **PO1 (I1)** -- A roster spanning several groups, each with several tabs and
  split panes, projects to an outline whose groups, tabs, and panes are in the
  order the roster listed them.
- **PO2 (I2)** -- Every pane in the roster appears exactly once as a pane entry
  under its own tab. Tab rows' selection targets are not pane entries and do not
  count here: a multi-pane tab's focused pane is both its tab row's target and
  its own pane entry, which is the intended shape, not a duplicate.
- **PO3 (I3)** -- A tab row names the pane the roster marked focused in that
  tab, and names the tab's first pane when the roster marked none.
- **PO4 (I4)** -- A tab with one pane is projected as offering no expansion; a
  tab with two or more is projected as offering it.
- **PO5 (I5)** -- The outline names the tab to expand on appearance when the
  selected pane's tab holds more than one pane, and names none when that tab
  holds one pane or when the selected pane is absent from the roster.
- **PO6 (I7)** -- The breadcrumb reports the selected pane's group, tab, and
  pane as prepared display text, and reports nothing when the selected pane is
  not in the roster.
- **PO7 (I3, I8)** -- Every tab row and every pane row states the pane id it
  selects, and raising `.paneSelected` with that id produces the effects
  selecting that pane produces today. This is the kit half only: that a tapped
  cell reaches its row's stated target is PO8's.
- **PO8 (I2, I6, and the hosting half of I3 and I8)** -- In the running app:
  rows are grouped under group headers; the selected pane's tab is expanded on
  open; a collapsed tab row selects that tab's focused pane; an expanded tab's
  pane row selects a pane that is *not* its tab's focused pane; and a roster
  change with the sheet open -- a pane added, a pane closed, a two-pane tab
  reduced to one pane, and a whole tab closed -- keeps the expansions of
  surviving expandable tabs and drops the rest.
  This is the manual simulator check in `## Verification`:
  `ios/DanTermMobileApp` has no test estate and this change does not add one.

## Non-goals

- Swiping between a tab's panes. It is the right gesture and it stays on the
  table, but a page turn today would tear down and re-dial the connection. It
  belongs after pane switching is cheap, not before.
- Making pane switching cheap -- re-targeting the tape follow on the live
  socket instead of reconnecting. That reaches the serving lifecycle, the claim,
  and the replica checkpoint, and is its own change.
- Moving the Mac's focus from the phone. Selecting a pane on the phone attaches
  the phone's stream and nothing more, as it does today.
- Collapsing, reordering, or renaming groups and tabs from the phone.
- Any change to the roster wire shape, `paneRoster(in:)`, or the macOS sidebar.

## Accepted risks

- **AR1 -- Pane switching gets easier to reach while still costing a
  reconnect.** A structured sheet invites more switching than a flat list did,
  and every switch is a disconnect and re-dial. The disposition is to leave the
  cost visible in the status pill, which already reports reconnecting, rather
  than to hide it behind a cheaper-looking gesture. The fix is the non-goal
  above.
- **AR2 -- The phone follows the Mac's per-tab focus, not its own history.**
  Focusing a different pane in a tab on the Mac changes where the phone lands
  next time it picks that tab, which can surprise a user driving both machines.
  This is the deliberate choice: one owner of the fact, and no second focus
  state to go stale when the Mac reshapes a tab.

## Rejected ideas

- **RI1 -- Two bottom-bar buttons, one for tabs and one for panes.** The pane
  button lists a single row for the single-pane tabs that dominate a phone
  session, and reaching a background pane in another tab becomes two sheets and
  four taps -- worse than the flat list it replaces for the case that matters
  most, an agent pane wanting attention.
- **RI2 -- A tabs-only sheet with no pane expansion.** Strictly cheaper, and it
  makes any pane that is not its tab's focused one unreachable from the phone.
  Violates I2.
- **RI3 -- The phone remembers its own last-viewed pane per tab.** A second
  owner of focus state that has no answer when the Mac closes or moves the pane
  it remembers, in exchange for a difference the user sees only when driving
  both machines at once.

## Implementation discretion

- **D1** -- How the table renders sections and expansion, and how the pill lays
  out three path components in the width it has.

## Verification

- `swift test --package-path ios/DanTermMobileKit` -- PO1 through PO7.
- `just test` -- the above plus the iOS portability gate, which cross-compiles
  the kit and the app for the device triple.
- End to end, discharging PO8: `just launch-slot`, then on that instance build
  at least two groups, with a three-pane tab, a two-pane tab, and a single-pane
  tab spread across them. `scripts/ios-app.sh simulator`, connect, open the sheet.
  - Rows are tabs under group headers, and the tab the phone is attached to is
    already expanded.
  - Tap a collapsed tab: the phone lands on the pane that tab last focused on
    the Mac, and the pill names group, tab, and pane.
  - Reopen the sheet, expand the *other* multi-pane tab, and tap a pane row that
    is not that tab's focused pane. The phone lands on that pane -- the tap that
    establishes I2.
  - With the sheet open and both multi-pane tabs expanded, on the Mac: split a
    pane in a three-pane tab (the new pane appears under its tab, both stay
    expanded), close a pane from that same tab while it still holds three (the
    row goes, the tab stays expanded), close panes until one of the two tabs
    holds a single pane (it collapses and stops offering expansion), then close
    the other tab outright (its rows go, and nothing else collapses).
