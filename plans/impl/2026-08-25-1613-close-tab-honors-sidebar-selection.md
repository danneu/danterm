# Close Tab honors the sidebar multi-selection

## Problem

The sidebar allows multi-selection (`allowsMultipleSelection = true`,
`app/SidebarView.swift:288`). Every batch-capable Tab action already
acts on that selection: color (`cmd+1`..`cmd+9`), Clear Tab Alerts
(`cmd+.`), and Clear Custom Title all route through
`menubarTabActionMsg` (`lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift:1441`)
with `sidebarView.selectedTabIds()`. The sidebar context menu closes
the whole selection too, using the Finder rule in
`resolveContextTargets` and sending `.requestCloseTabs`
(`app/SidebarView.swift:1194`).

Close Tab is the one action left out. `AppDelegate.closeTab(_:)`
(`app/AppDelegate.swift:546`) ignores the selection and sends
`.requestCloseTab(id: model.selectedTabId)`. So with five tabs
selected, `cmd+1` colors five and `cmd+shift+w` closes one. The
keyboard and the context menu disagree about what "the tabs I picked"
means.

Two premises make the fix cheap, and both are load-bearing:

- The batch reducer path already exists and is covered:
  `.requestCloseTabs` dedups and drops stale ids while keeping the
  caller's order, collapses a one-id batch back to `.requestCloseTab`,
  and otherwise always opens a confirmation
  (`lib/DanTermCore/Sources/DanTermCore/Update.swift:176`). Tests in
  `UpdateTabTests.swift` and `CloseConfirmationTests.swift` pin it.
- Because a multi-tab close always confirms, honoring the selection
  cannot destroy anything without asking. That is what makes the
  simple rule safe.

## Decision

Route `AppDelegate.closeTab(_:)` through the same shared target rule
as the other batch tab actions: sidebar multi-selection first, focused
tab as fallback. `cmd+shift+w` then closes every selected tab, through
the existing confirmation.

Close Pane (`cmd+w`) does not change. Panes are not sidebar rows --
`SidebarItem.Kind` is `group | tab`
(`lib/DanTermCore/Sources/DanTermCore/SidebarItemStore.swift:17`) --
so there is no pane selection to batch over. It keeps targeting the
focused pane of the focused tab.

The target rule is not gated on key focus. Finder gates its
destructive sidebar action on the sidebar being first responder, and
that was the alternative considered. It is not available here: the
sidebar refuses first responder outright (`acceptsFirstResponder =
false` on both `SidebarOutlineView`, `app/SidebarView.swift:178`, and
`SidebarView`, `:1303`), and the model's focus concept
(`PaneFocusClaimant`) has no sidebar case. "The sidebar has focus" is
not a state this app can be in. The always-on confirmation covers the
risk that gating was meant to cover.

## Invariants

- **I1.** A tab-scoped close from the keyboard or the Tab menu targets
  the sidebar's selected tabs when the sidebar contributes a
  selection, and the focused tab otherwise. This is the same rule the
  other batch tab actions use, resolved in one shared place.
- **I2.** A single-tab target behaves exactly as it does today: a tab
  with no warning and one pane closes with no confirmation; anything
  else confirms.
- **I3.** A multi-tab target always confirms before closing, and the
  target set carries the user's visual top-to-bottom row order from
  the sidebar through to the confirmation and the close. Order is
  observable: the confirmation lists the affected running commands in
  it.
- **I4.** Close Pane's target is unchanged by any sidebar selection.

## Proof obligations

- **PO1.** The shared router covers close (I1): the existing
  "for every tab action" pair in
  `lib/DanTermCore/Tests/DanTermCoreTests/MenubarTabActionTests.swift`
  extends to close, for both the multi-selection and the
  fallback-to-focused-tab arms.
- **PO2.** Single-target parity (I2): a close whose resolved target is
  one tab produces today's outcome, both the no-confirmation and the
  confirmation cases.
- **PO3.** Multi-target close (I3), in two parts, because the order
  is produced at the AppKit boundary and consumed in the core:
  - The keyboard close reaches the core carrying the sidebar's
    selection in visible top-to-bottom order. This is a boundary
    proof; the existing context-menu case in
    `tests-ui/SidebarContextMenuTests.swift` is its sibling.
  - Given that order, the reducer keeps it while deduping and
    dropping stale ids, always confirms, and authorizes quit when the
    batch covers every live tab.
- **PO4.** Close Pane (I4): its target does not move when a sidebar
  selection exists.

## Non-goals

- No change to `cmd+w` / `pane.close`.
- No focus gating, and no new focus-location state in the model.
- No count suffix on the Tab menu's "Close Tab" item. The context
  menu shows one ("Close (3 tabs)") because it is built per click;
  retitling menubar items for a live selection is a question about
  all batch tab actions, not this one, and belongs to separate work.
- No change to the `danterm` CLI. `tab close --tab <id>` names its
  target explicitly and never reads the sidebar selection.

## Accepted risks

- **AR1.** A user typing in a terminal, with a selection they made
  earlier still standing in the sidebar, presses `cmd+shift+w` and
  gets a multi-tab confirmation instead of closing one tab. Accepted:
  the confirmation names its subject and cancels cleanly, and this is
  already how `cmd+1` and `cmd+.` behave for that same user.

## Rejected ideas

- **RI1.** Gate the batch on the sidebar holding key focus. See
  Decision -- the sidebar cannot hold key focus, so the gate would
  never open.
- **RI2.** Leave `cmd+shift+w` single and keep multi-close in the
  context menu only. Keeps the keyboard predictable, but leaves the
  keyboard and the context menu disagreeing about the selection, which
  is the reported problem.

## Implementation discretion

- Whether close joins `MenubarTabAction` as another case or reuses the
  rule some other way, so long as one place resolves the target set
  for every batch-capable tab action (I1).

## Verification

- `swift test --package-path lib/DanTermCore` for the reducer and
  router suites, plus `just lint`; `just test` before the commit.
- In the app (`just launch-slot`): select three tabs in the sidebar,
  press `cmd+shift+w`, confirm the dialog names three tabs and all
  three close. Then with one tab selected and a plain shell, press
  `cmd+shift+w` and confirm it closes with no dialog. Then split a
  pane and press `cmd+w` with a multi-selection standing -- only the
  focused pane closes.

## Implementation notes

- Close joined `MenubarTabAction` as a `.close` case (the discretion the
  plan left open). It always builds `.requestCloseTabs`, never
  `.requestCloseTab`: the reducer already collapses a one-id batch, so
  the router does not need a second branch to keep I2.
- PO3's boundary half landed as `tests-ui/MenubarTabCloseTests.swift`,
  which drives `AppDelegate.closeTab` over a real reconciled sidebar.
  A third case -- the fallback to the focused tab with no sidebar
  selection -- was written and then dropped: the outline sets
  `allowsEmptySelection = false`, so an empty sidebar selection is not
  a state the boundary can be put into, and the assertion could not
  tell the fallback apart from a one-row selection. The fallback arm
  stays pinned in the pure router suite.
- PO3's reducer half needed no new test. `UpdateTabTests` already pins
  order preservation, dedup, stale-id pruning, always-confirm, and
  quit authorization for `.requestCloseTabs`. PO2's confirming arm did
  need one, so a single-id-batch parity test was added there.
