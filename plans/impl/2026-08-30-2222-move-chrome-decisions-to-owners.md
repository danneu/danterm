# Move three chrome decisions back to their owners (CHROME-5, CHROME-6, CHROME-4)

Wave 12 items from `docs/scratch/2026-08-26-improvement-audit.md` (anchors
`chrome-5`, `chrome-6`, `chrome-4`). Three separable moves in the macOS shell,
one commit each. CHROME-5 and CHROME-6 land sequentially -- both edit
`PaneToolbarRender`, `desiredPaneToolbar`, `applyToolbarRender`, and their
fixtures. CHROME-4 is independent of both and may land in any order relative
to them. A final docs-only commit ticks the three audit boxes with the
resulting hashes.

## Problem

The AppKit shell decides things the projections own:

1. **Badges (CHROME-5).** `BadgeLabel.updateBadge` decides visibility
   (hide-zero), and `SidebarGroupCellView.apply`
   (`app/SidebarCellViews.swift:223-226`) overwrites `isHidden` on the next
   line with a different rule, while driving the tab-count badge past the
   badge's own update method entirely. One flag, two writers, correctness by
   statement order. No live bug; a latent order hazard plus a show/hide rule
   stated in an untested AppKit cell.
2. **Drag eligibility (CHROME-6).** `ToolbarDragHandleView.mouseDragged`
   (`app/PaneWrapperView.swift:750-753`) re-derives "may this pane start a
   drag" from the model's *selected* tab, and `startPaneDrag`
   (`app/AppRuntime.swift:1357-1361`) repeats the selected-tab substitution to
   find the container. Sound today only because a hidden tab's drag handle
   cannot receive events; the assumption is load-bearing in two places and the
   eligibility rule lives in an event handler instead of the pure projection
   the wrapper already applies.
3. **Applied-projection record (CHROME-4).** `SidebarReconcileDriver` and
   `SidebarView` each store a field named `appliedProjection` for the same
   pass, deliberately holding different values (merged vs raw new). The only
   reader that can observe the divergence is the tab context menu
   (`SidebarView.swift:1095`), which reads per-tab values from the view's raw
   copy -- and the audit's vetted correction shows the original "view stores
   the merge" fix would feed that reader the staler value. The fix that
   survives: move the menu onto the model, then collapse the two records.

## Decision

One commit per item.

**CHROME-5** -- The projection states each badge as `Int?` (`nil` = not
shown), and `BadgeLabel` gets one `apply(_ count: Int?)` as its sole update
method; `updateBadge(count:)` is deleted everywhere (including
`BellToolbarButton`). Fields:

- `SidebarGroupProjection.Rendered`: `alertBadge: Int?` and
  `tabCountBadge: Int?` replace `unreadAlertCount`/`tabCount`
  (`isCollapsed` stays -- it drives disclosure). The alert rule
  (`count == 0 || !isCollapsed` -> nil) and the tab-count rule
  (`!isCollapsed` -> nil) move into `desiredSidebar`.
- `SidebarTabProjection`: `alertBadge: Int?` replaces `unreadAlertCount`
  (hide-zero moves into the projection). The tab context menu's
  "any selected tab has alerts" test becomes `alertBadge != nil`.
- `PaneToolbarRender`: `alertBadge: Int?` replaces `unreadAlertCount`.
- `WindowChromeProjection`: `unreadBadge: Int?` replaces `unreadCount`;
  the bell and the dock badge both read it (dock label is the mapped count).

**CHROME-6** -- `PaneToolbarRender` gains `canDrag`, computed in
`desiredPaneToolbar` as `hasSplits || totalTabCount > 1` (the walk already has
both facts). The wrapper forwards it to the drag handle in
`applyToolbarRender`; the handle's model-reading guard block is deleted.
`startPaneDrag` resolves the container through
`tabForPane(paneId, in: model)` (`ModelOperations.swift:587`) instead of
`selectedTab(in:)`.

**CHROME-4** -- `contextMenu(forTabId:clickedRow:)` builds from a fresh
`desiredSidebar(in: runtime.model)` (cold path; the view holds `runtime`)
instead of the stored projection. Then the two records collapse into one field
on the view: `applySidebarOps` keeps writing the raw new projection at the top
of the pass, the driver overwrites that same field with the merged
(`advanceSidebarCache`) value at the end of the pass and deletes its own copy,
and the next pass's `old:` reads the view's field. `SidebarReconcileResult`
keeps reporting the merged projection.

## Invariants

- I1. A `BadgeLabel`'s text and visibility are set together by one method;
  every show/hide rule for a badge is stated in a pure projection.
- I2. `apply(nil)` hides the badge, so `ToolbarDragHandleView`'s
  `!badge.isHidden` press test keeps its current meaning (CHROME-5 must not
  change when the pane alert badge is visible).
- I3. Drag eligibility is decided by the projection of the pane's own tab,
  not the selected tab; a wrapper that has never been reconciled fails closed
  (no drag).
- I4. `startPaneDrag` names the pane's own tab's container.
- I5. The tab context menu reflects the model's current state, including for
  a row whose deferred paint left stale content on screen.
- I6. Exactly one stored applied-sidebar-projection record exists after
  CHROME-4; at rest (between passes) it equals the merged projection the
  driver reports, so deferred rows are still retried on the next pass.
- I7. Mid-pass readers of the view's projection (row emphasis during
  `reloadData`, selection-change dispatch) observe the new pass's top-level
  values, exactly as today -- the end-of-pass merge overwrite must not change
  what any reader sees, since raw and merged differ only in per-tab/rendered
  slots whose sole reader I5 moved to the model.

## Proof obligations

- PO1 (I1, CHROME-5): `DanTermCore` projection tests -- an expanded group
  with unread alerts projects `alertBadge == nil` and `tabCountBadge == nil`;
  collapsed projects both counts; a tab/pane/chrome projection with zero
  alerts projects nil, nonzero projects the count.
- PO2 (I1, I2): `tests-ui` (`just test-ui`) -- driving
  `SidebarGroupCellView.apply` from the projection alone yields matching
  badge `isHidden`; existing `BadgeLabelTests` updated to `apply(_:)`.
- PO3 (I3): projection tests -- lone pane in the only tab projects
  `canDrag == false`; same pane once a second tab exists projects `true`; a
  split pane projects `true` either way.
- PO4 (I3): `tests-ui/PaneWrapperViewTests.swift` -- a drag past the 5pt
  threshold on a wrapper whose applied render says `canDrag == false` does
  not reach `startPaneDrag`.
- PO8 (I3, I4): `tests-ui` -- a drag past the threshold on a wrapper whose
  applied render says `canDrag == true` does reach `startPaneDrag`; and for
  a pane whose tab is not the selected tab, `startPaneDrag` installs the
  coordinator on that pane's own tab's container.
- PO5 (I5): `tests-ui/SidebarContextMenuTests.swift` -- with a row whose
  cell paint was deferred, the tab menu's state (color checkmark, Clear
  Alerts presence) reflects the model's latest values, not the painted ones.
- PO6 (I6): `tests-ui` `SidebarSelectionCacheTests` style -- a pass with a
  visible row whose cell is not materialized leaves the view's stored
  projection equal to `SidebarReconcileResult.appliedProjection`, and the
  existing second-pass repaint of the deferred row keeps passing.
- PO7 (I7): existing sidebar selection/emphasis suites keep passing
  unchanged; no new test needed beyond that.

## Non-goals / accepted risks

- Non-goal: making the single-writer property compiler-enforced.
  `stringValue` overrides an open `NSTextField` property and `isHidden` is
  inherited from `NSView`, so neither can be restricted; the payoff is the
  rule stated once in tested pure code, by convention at the call sites.
- Non-goal: the sidebar tab cell's `jumpBadge` -- a plain `NSTextField`, not
  a `BadgeLabel`; out of scope.
- Non-goal: moving the *group* context menu or the view's other projection
  readers off the stored record; none of them can observe the raw/merged
  divergence.
- Accepted risk (CHROME-4): the single record is written twice within one
  pass (raw at top, merged at end) by one call chain. This is the price of
  I7; the record has one owner and one value at rest.

## Implementation discretion

- How the wrapper hands `canDrag` to the drag handle (stored var set in
  `applyToolbarRender` vs a provider closure like `paneMenuProvider`), as
  long as I3's fail-closed default holds.
- Whether the driver's end-of-pass write goes through a dedicated setter or
  the existing apply path.

## Verification

Per commit: targeted suite for the touched package
(`swift test --package-path lib/DanTermCore --filter Projections`) plus
`just lint` in the loop; `just test` before each commit; `just test-ui`
for PO2, PO4, PO5, PO6, PO8 (WindowServer required, excluded from the gate).
After all three land: a fourth, docs-only commit ticks the three `- [ ]`
boxes at `docs/scratch/2026-08-26-improvement-audit.md:396-398` with the
commit hashes.

## Commit progress

- [x] 1. refactor(chrome): project badge visibility
- [x] 2. refactor(chrome): project pane drag eligibility
- [x] 3. refactor(sidebar): keep one applied projection record
- [ ] 4. docs(audit): mark CHROME-4/5/6 complete
