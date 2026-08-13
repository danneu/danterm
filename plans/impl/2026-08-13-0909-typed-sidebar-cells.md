# Typed sidebar cell views

## Problem

Every sidebar row is a bare `NSTableCellView` whose children are found again at
paint time by matching `NSUserInterfaceItemIdentifier` strings against
`cell.subviews`. Each lookup is an `if let ... as? T` whose failure path is
silence: a renamed or restructured subview does not fail to compile and does not
throw, it just stops painting that part of the row.

The same strings are re-declared in `app/SidebarView.swift#makeTabCell` and
`#configureTabCell` (eight ids, twice), again in `#configureGroupCell` and
`#applyGroupCollapseState`, again in `app/BadgeLabel.swift#visibleAlertBadge`,
and again across four UI test files -- eleven-plus sites for one cell layout.
This is the substrate that produced the incidents already commented in the file:
the blank 2pt title from a recycled editable field, and the dropped badge
repaints.

Two consequences are live today:

- `applyGroupCollapseState` duplicates the accessory branch of
  `configureGroupCell` and casts the caret to plain `NSButton`, so it silently
  skips the group-identity refresh that the other path performs. It is latent
  rather than a visible bug only because every materialization reconfigures the
  cell, so the skipped write always equalled the value already there.
- `tests-ui/SidebarBadgeTests.swift` builds its own `NSTableCellView` carrying
  the literal strings instead of a real cell, so renaming the ids in
  `SidebarView` would break alert-badge clicks with the test still green.

**Outcome:** a missing or misnamed subview stops being representable, and the
row's identity comes from the row rather than from a copy stored in a view.

## Decision

Replace both cell kinds with `final class` subclasses of `NSTableCellView` that
own their children as stored `let` properties and expose one `apply` method
each. Delete every subview identifier. The two cell reuse identifiers stay --
`makeView(withIdentifier:)` keys its pool on them.

The configurators become straight-line assignments with no optionals and no
silent-nil paint paths, so `configureTabCell`, `configureGroupCell`, and
`makeJumpModeBadge` all disappear into the cells.

Three decisions settled with the user:

- **D1. The caret resolves its group from the row it lives in.**
  `SidebarGroupCaretButton` and its stored `groupId` are deleted; the click
  handler uses `outlineView.row(for: sender)` and reads the `SidebarItem`. This
  is the repo's existing idiom (`app/TodoPopoverView.swift#tableView`,
  `app/TabTodoPopoverView.swift`). No view stores a group id, so the
  `applyGroupCollapseState` divergence cannot recur -- and no escaping closure
  is introduced to replace it.
- **D2. `applyGroupCollapseState` becomes a call to the same `apply`**, passing
  a projection copy whose `isCollapsed` is overridden with the delegate's
  argument. The second parallel path through the same four subviews stops
  existing.
- **D3. The jump badge becomes a stored subview, hidden when `jumpKey` is nil**,
  instead of being inserted into and removed from the leading stack on each
  paint. Hidden arranged subviews collapse in `NSStackView`, so the painted
  result is unchanged.

Whether the title is being edited stays an explicit parameter to `apply`, not
something the cell derives from `currentEditor()`. `finishInlineRename` runs
from `control(_:textShouldEndEditing:)` while AppKit is still tearing the field
editor down, so a self-derived flag would skip exactly the repaint that path
exists to perform.

Both cells keep `NSTableCellView.textField` pointing at their title field.
AppKit and row accessibility read that property.

## Invariants

- **I1. Every child a configurator paints is reachable as a stored property.**
  No sidebar code matches a subview identifier to find a child, in production or
  in tests. The identifiers that survive are structural rather than lookups: the
  two cell reuse identifiers, which stay distinct, and the outline view's
  table-column identifier.
- **I2. Painting is total.** Applying a projection paints every field it
  carries; there is no path that skips a field because a lookup returned nil.
  The single exception is the title lane during an active rename (I6).
- **I3. One apply path per cell kind.** Collapse and expand, in-place row
  updates, materialization, and rename teardown all paint through the same
  method. A per-row fact cannot be refreshed by one path and skipped by another.
- **I4. Group identity is read from the outline row, never from a view.**
- **I5. The title field instance is stable for the cell's life.** The inline
  rename session compares field identity (`session.textField === textField`), so
  the field is a `let`, never reassigned and never rebuilt by `apply`.
- **I6. Title-lane suppression during rename is caller-stated.** `apply` takes
  the editing state as a parameter. While it is set, the cell repaints neither
  the title nor the jump badge: they share the lane the field editor occupies,
  so painting the badge mid-edit would resize that lane under the user's cursor.
  This matches the behavior today. Everything outside the lane, including the
  chip, still paints.
- **I7. The reuse boundary still scrubs stranded rename state.** A dequeued cell
  cannot arrive with `isEditable == true` or a live field editor.
- **I8. Layout is unchanged.** Row geometry, insets, and truncation behavior
  match the current build at every sidebar width.

## Proof obligations

Each entry names a claim, not the cases that establish it. The UI harness
(`just test-ui`) is the vehicle; it needs a WindowServer and is excluded from
`just test`.

- **PO1 (I8).** Accessory trailing inset and cell fill hold across the sidebar
  width sweep already exercised by `tests-ui/SidebarRenameRecycleTests.swift`,
  for both cell kinds. These assertions must be ported to the typed accessors,
  not dropped -- they are the only guard on the moved constraint set.
- **PO2 (I8).** The tab title's painted frame still precedes the alert badge's.
- **PO3 (I5, I7).** Rename commit, cancel, click-away, and a cell recycled out
  of a live rename all leave a title of normal width and a non-editable field.
- **PO4 (I3, I4).** Clicking the caret toggles the group it visually belongs to,
  including after the cell has been recycled onto a different group.
- **PO5 (I2).** A materialized row paints title, subtitle, chip, pane strip,
  alert badge, jump badge, and color stripe from its projection; the group cell
  paints title, separator, caret symbol, alert badge, and tab count.
- **PO6.** `SidebarOutlineView.tabForBadgeHit(at:)` returns the tab whose visible
  badge was clicked, and nil when the badge is hidden. **This path has no test
  today.** It is the real consumer that `SidebarBadgeTests` gave the illusion of
  covering, and it lands first (see Commit progress).
- **PO7 (I8).** The sidebar's single-line label contract still holds for tab
  title, tab subtitle, and group title.
- **PO8 (D3, I6, I8).** Turning jump mode off gives the title lane its space
  back: after `jumpKey` goes from present to nil the badge must reserve no
  width, which is the whole premise of storing it permanently instead of
  inserting and removing it. The same transition arriving during an active
  rename must leave the lane untouched until the rename ends. Assert on the
  painted lane, not on the badge's `isHidden` -- a visibility-only check passes
  in exactly the case this obligation exists to catch.

Beyond the harness: run the app in a dev slot and drive the sidebar by hand --
collapse and expand a group, rename a tab and a group, turn jump mode on and
off, click an alert badge, and drag the sidebar width across the range PO1
covers.

## Non-goals

- Changing what the sidebar paints. This is a change of how a cell reaches its
  children; every projection field keeps its current meaning and appearance.
- Touching the reconcile pipeline (`computeSidebarRowOps`,
  `guardSidebarRenameOps`, `advanceSidebarCache`) or the projection types.
- Typing `SidebarRowView.resizeHostedCells`. Its claim really is "whatever cell
  this row hosts follows the row's bounds", it fishes nothing by name, and it is
  not the failure mode this change is about.

## Accepted risks

- **AR1. The constraint set moves verbatim, and a transcription slip there is
  the one thing that can regress silently.** The pane strip's trailing anchor is
  `equalTo`, not `lessThanOrEqualTo`, because the strip has no intrinsic width
  and fits itself to whatever it is given; carry that constraint together with
  its comment. PO1 and PO2 are the guard, which is why they must be ported.
- **AR2. Colliding reuse identifiers would degrade quietly** -- `makeView`
  would hand a group cell to a tab-cell cast, the cast would fail, and a fresh
  cell would be built for every row. A view leak, not a crash. The two literals
  keep their current values.
- **AR3. The UI harness compiles `app/` and `tests-ui/` as one module from an
  explicit file list in `test-ui.sh`.** A new or deleted file that is not
  reflected there fails to compile, so this is loud rather than silent -- but it
  is easy to forget when the change is otherwise green locally.

## Rejected ideas

- **RI1. Hoist the identifier strings into one shared enum and assert on nil in
  debug builds.** It makes the six sites agree but keeps the silent-nil paint
  path and the untyped lookups, so it does not remove the class of bug.
- **RI2. Store the group id on the cell and forward the caret click through a
  stored closure.** It keeps identity duplicated in a view and adds an escaping
  closure whose lifetime must be managed, to solve a problem D1 solves by
  removing the stored copy.

## Test rewiring

The typed accessors make these tests more structure-insensitive, not less.
`cell.subviews.first { $0.identifier?.rawValue == "bellDot" }` asserts three
things at once -- a badge exists, it is a direct subview, it carries a string --
and only the first is behavior. `cell.alertBadge` asserts the first alone.

- **`tests-ui/SidebarBadgeTests.swift` is deleted**, along with its entry in
  `test-ui.sh` and its call in the runner. Its badge-visibility claims are
  already asserted against real cells in `SidebarProjectionRowTests` and
  `SidebarSelectionCacheTests`; what it did not cover is PO6, which replaces it.
- **`findRenameRecycleDescendant`** -- a recursive by-string descendant search in
  `tests-ui/SidebarRenameRecycleTests.swift` -- is deleted with its last caller.
  It is the same fragile lookup this change removes from production and should
  not survive in the tests.
- The remaining sidebar test files reach cells through typed accessors:
  `SidebarRenameRecycleTests`, `SidebarProjectionRowTests`,
  `SidebarSelectionCacheTests`, `SingleLineLabelTests`. Their cell-fetch helpers
  become generic over the cell type. Assertions that existed only to reach a
  view through a string go away; the behavioral claims above them stay.
- The test-only seam that exists solely to reach a private configurator is
  deleted, because `apply` is internal and the test calls it directly. The
  rename-reset seam stays, retyped.

## Critical files

- `app/SidebarView.swift` -- the configurators, `applyGroupCollapseState`, the
  caret handler, `refreshHostedPaneStrips`, and the rename and row-update paths.
- The new file holding both cell classes (add it to `test-ui.sh`).
- `app/BadgeLabel.swift` -- the free `visibleAlertBadge` is deleted; the
  `NSTextField` badge extension stays. Revise the file header, which currently
  promises more than the file will hold.
- `test-ui.sh` -- one entry added, one removed.
- `tests-ui/SidebarRenameRecycleTests.swift` -- the largest rewiring.

## Implementation discretion

- Whether the two cell classes share a small protocol for the rename paths, or
  each rename call site switches on the cell kind.
- Whether both classes live in one new file or two.

## Commit progress

- [x] **1. Cover the badge click path.** Add PO6 to
  `tests-ui/SidebarProjectionRowTests.swift`, which already drives a real
  sidebar in a window. Green against unmodified production code -- the point of
  the separate commit is that this assertion is proven to be asserting something
  real before the lookup it depends on is replaced.
- [x] **2. The refactor.** Cell classes, `SidebarView`, `BadgeLabel`,
  `test-ui.sh`, and all test rewiring. The UI harness compiles production and
  test files as one module, so this cannot be sliced smaller and stay green.

## Implementation notes

- Live slot verification covered row creation, group and tab rename repainting,
  alert-badge rendering, and the resulting sidebar geometry. The control API
  does not expose caret clicks, jump mode, badge clicks, or divider drags, so
  the AppKit harness covered those interactions instead of expanding this
  refactor into new IPC commands.
