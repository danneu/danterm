# Expand a group when the selection moves into it

## Context

Closing a tab can hand the selection to a tab inside a collapsed group. The
group stays collapsed, so the selected tab has no row on screen. The sidebar
then shows *no* selected row at all: `applyRestoreSelection` finds no row for
the hidden tab and clears the visible selection outright
(`app/SidebarView.swift:664`, whose comment already names the case -- "The
target can be hidden inside a collapsed group").

The close path is only the reported symptom. The selected tab ends up inside a
collapsed group from many directions, and none of them consider collapse:

- `closeTabRemoval`'s predecessor-then-successor fallback, computed over
  `model.groups.flatMap(\.tabs)` (`Update.swift:1966`).
- `reconcileTabState`'s repair to the most-recently-used survivor
  (`ModelOperations.swift:1198`), reached from `sessionCreationFailed`
  (`Update.swift:752`) among others.
- `.selectTab` / `applySelectTab`, which `danterm focus` / `danterm pane focus`
  (IPC `pane.focus` -> `navigateToPane`) and MRU cycle commit route through.
- `.selectAdjacentTab`, which deliberately wraps into collapsed groups
  (pinned by a test at `UpdateTabTests.swift:591`).
- `movePaneToTab` / `movePaneToNewTab`, which jump to the target tab
  (`Update.swift:340`, `Update.swift:384`).
- **`.moveTabs` (`Update.swift:1017`) and `deleteGroup(moveTabs: true)`, which
  relocate the selected tab entity into another group while `selectedTabId`
  never changes** -- a sidebar drag of the selected tab into a collapsed group
  hides it exactly like the close path does.
- Restore, which resolves a persisted `selectedTabId` with no regard for the
  persisted `isCollapsed` (`Model.swift:1246`).

Nothing anywhere clears `isCollapsed` on a selection change: the only writer in
`lib/` or `app/` is `.toggleGroupCollapse` (`Update.swift:1107`), plus decode.
Jump mode is the one selection path that is already safe -- it is seeded from
`visibleTabIdsInRowOrder()`, which NSOutlineView's row enumeration limits to
mounted rows (`app/SidebarView.swift:1065`).

So this is a missing model invariant, not one bad fallback computation. The
outcome we want: the selected tab always has a visible row, except when the
user hid it themselves.

## The rule

**When the selected tab comes to sit in a collapsed group, that group expands.**

The trigger is a change in *where the selection is*, not just which tab it is:
the transition key is the selected tab's id together with the id of the group
holding it. A tab that moves under a stationary selection counts as a move.

It is a transition rule, not an absolute invariant. An explicit
`.toggleGroupCollapse` on the group that holds the selection still collapses
it -- the user asked for that, and a disclosure triangle that does nothing
reads as a broken control. (`testToggleGroupCollapse` at
`UpdateGroupTests.swift:459` already pins this case, since `.createGroup`
selects into the group it then collapses.)

Restore expands too, so the app never opens with an invisible selection, even
though "explicit collapse wins" lets the user save that state.

## Requirements

1. **One pure expansion operation** in the core: given a model, expand the
   group holding the selected tab. Idempotent; no-op when there is no selection
   or its group is already expanded.
2. **Live transitions are detected at `update()`**, the documented single
   chokepoint every path that mutates tab membership or `selectedTabId` reaches
   (`Update.swift:12-19`). Detection compares the selected tab's (id, group id)
   on entry against the same pair after the mutation.
3. **Expansion runs after tab reconciliation.** `reconcileTabState` can itself
   move the selection, and that move must expand.
4. **Restore normalizes the same way**, so a restored model never opens with the
   selection hidden. Restore does not pass through `update()`, so it calls the
   expansion operation directly.

`update()` is re-entrant (`navigateToPane`, `.selectAdjacentTab`,
`.extractTabsToNewGroupInteractively` call it recursively). The expansion
operation is idempotent, so a nested frame that already expanded is simply seen
again by the outer one.

This is the first core reconcile that needs a before-value -- the other five are
pure invariants over the post-mutation model. That snapshot is what buys
"explicit collapse wins"; it is the price of the choice, not an accident.

## Rejected ideas

- **RI1: Derive the rendered collapse state as `isCollapsed && !containsSelection`,
  leaving the stored flag a pure preference.** It re-collapses the group when the
  selection leaves, but it makes the disclosure triangle a no-op on the group
  holding the selection -- a control that visibly does nothing -- with no stored
  state to point at.
- **RI2: A `didSet` on `AppModel.selectedTabId`.** Hides selection behavior in a
  property observer, fights `reconcileTabState`'s own repair mid-mutation, misses
  the tab-moves-under-the-selection case entirely, and still needs an explicit
  call on restore (a `didSet` does not fire from an initializer).
- **RI3: Hook `applySelectTab` instead of the chokepoint.** It already
  edge-detects, but `closeTabRemoval`'s fallback, `reconcileTabState`'s repair,
  `movePaneToTab`, `.moveTabs`, and foreground `.createTab` all bypass it.

## No view work

The model change flows out on its own: `desiredSidebar` copies `isCollapsed`
into the projection (`Projections.swift:930`), `computeSidebarRowOps` diffs it
into `.setGroupCollapsed(collapsed: false)` (`Projections.swift:1053`), and
`SidebarView` applies every row op *before* `applyRestoreSelection` runs
(`app/SidebarView.swift:400-424`), so the row exists by the time the selection
is reapplied and `scrollRowToVisible` can reach it. The `expandItem` this
triggers fires `outlineViewItemDidExpand`, but that handler returns early under
the `isReloading` guard (`app/SidebarView.swift:869`), so no
`.toggleGroupCollapse` feeds back into the model.

## Tests

TDD, all behavioral -- each asserts model or restore state, never the shape of
a helper. Run the targeted core suite plus `just lint` in the loop, `just test`
before the commit.

1. Closing the selected tab, where the fallback lands in a collapsed group,
   leaves that group expanded and the selection on the fallback tab.
2. Selecting a tab in a collapsed group expands it -- covers `danterm focus`
   and MRU-commit, which both reduce to `.selectTab`.
3. Moving the selected tab into a collapsed group (`.moveTabs`, the sidebar
   drag) expands the destination, even though `selectedTabId` never changes.
   This is the test that fails if the transition is keyed on id alone.
4. Removing the selected tab so that `reconcileTabState` repairs the selection
   to an MRU survivor inside a collapsed group (via `sessionCreationFailed`)
   expands that group. This is the test that fails if expansion runs before
   reconciliation.
5. Moving the selection between two *other* groups leaves an unrelated
   collapsed group collapsed -- the rule does not over-expand.
6. An init file whose `selectedTabId` names a tab in a group saved with
   `isCollapsed: true` restores with that group expanded, and with the other
   collapsed groups untouched.

"Explicit collapse wins" needs no new test: `testToggleGroupCollapse`
(`UpdateGroupTests.swift:459`) already collapses the group `.createGroup`
selected into. Reword its title/preamble to name the rule it now pins, so the
boundary is legible.

Three test preambles state the now-false rule that the model never consults
collapse: `UpdateTabTests.swift:165-166` ("collapse is a view concern"),
`UpdateTabTests.swift:594-596`, and `UpdatePaneTests.swift:485-487` ("collapse
is purely a view concern -- it does not gate model mutations"). The narrower
claim each one actually pins stays true (alerts clear, wrap reaches collapsed
groups, a pane closes) -- reword them to say that.

Two existing tests move the selection into a collapsed group and will now
expand it. Both assert only selection and alert state, so both stay green:
`UpdateTabTests.testSelectTabFocusModeMarksAlertReadInCollapsedGroup` (`:159`)
and `UpdateTabTests.testPrevTabWrapsIntoCollapsedGroup` (`:591`).

## Implementation discretion

- Where the expansion operation lives, and what it is called.
- How the entry snapshot is threaded into the reconcile step.
- Which existing test files the new tests join.

## Verification

1. Targeted core suite and `just lint` in the loop; `just test` before the
   commit.
2. End to end in the app: `just launch-slot`, then with the `danterm` CLI --
   create a second group with two tabs, collapse it, select a tab in the first
   group, close tabs until the fallback lands in the collapsed group, and
   confirm the group is open with the tab selected and scrolled into view.
   Repeat with `danterm pane focus <id>` aimed at a pane in a collapsed group,
   and by dragging the selected tab into a collapsed group in the sidebar.
   Then collapse the group holding the selected tab by hand and confirm it
   stays collapsed. `just stop-slot <n>` when done.

## Non-goals / accepted risks

- **AR1: No "holds the selected tab" indicator on the group header.** Under
  "explicit collapse wins" the user can still deliberately hide the selection,
  and the header will not say so. It is a state the user created on purpose and
  can undo with one click; a badge is a separate design question.

## Commit progress

- [x] Expand a group when the selection moves into it (expansion operation,
      chokepoint transition, restore, tests).

## Implementation notes

- The expansion operation and the transition key live in
  `ModelOperations.swift` next to `reconcileTabState`, as `SelectionSite` /
  `selectionSite(in:)` / `expandGroupHoldingSelection(_:)`. The entry snapshot
  is a plain `let entrySite = selectionSite(in: model)` above `update()`'s
  `defer`, and the comparison runs inside the `defer` right after
  `reconcileTabState`.
- All six new tests live in one new file,
  `Tests/DanTermCoreTests/SelectionVisibilityTests.swift`, so the rule and its
  boundary read together. The "explicit collapse wins" boundary stays where the
  plan put it, in `UpdateGroupTests.testToggleGroupCollapse`.
- Verification step 2 (end to end in the app) is not done. The `danterm` CLI
  has no command that collapses a group, so the setup for every scenario needs
  a mouse click on the disclosure triangle. `just test` and the targeted core
  suite are green.

## Follow Up

- The `danterm` CLI cannot collapse or expand a group; `ls` only reports
  `isCollapsed` (`integrations/danterm/SKILL.md:336`). Add a `group collapse` /
  `group expand` command so this rule, and anything else that reads collapse
  state, can be driven and checked end to end from the shell.
