# Adjacent count badges own the gap between them

## Problem and evidence

In a collapsed sidebar group row that has unread alerts, the red alert pill and
the gray tab-count pill render with no visible gap between them (user
screenshot, 2026-08-28).

Both pills are arranged by the group row's accessory stack
(`app/SidebarCellViews.swift`, `SidebarGroupCellView.init`), whose single
`spacing` value serves two different adjacencies: pill-to-pill and
pill-to-caret. The value is tuned for the caret, whose chevron glyph carries its
own inset inside a 16pt box, so 2pt reads fine there. Two capsules are flat-sided
at their vertical midline, so the same 2pt reads as touching.

The collapsed group row is the only place two badges appear side by side today
(`BadgeLabel` is otherwise used one at a time: the tab row, the pane toolbar, the
bell toolbar button). Nothing stops the next multi-badge row from repeating this.

## Decision

Move the gap between adjacent count pills into the badge module, so no row
chooses it. Add a badge strip view next to `BadgeLabel` that holds an ordered
list of badges, owns the spacing between them, and withdraws from its row's
layout entirely when every badge it holds is hidden. The group row arranges one
strip plus the caret, and keeps its own caret spacing unchanged.

The row keeps deciding *which* counts show and what they say; only the geometry
between pills moves.

## Invariants

- I1. Two adjacent visible count pills are separated by a gap of at least 4
  points, and that gap comes from the badge module, not from the row that
  arranges the strip.
- I2. Badge visibility rules are unchanged: a collapsed group shows the tab count
  and shows the alert count only when it is nonzero; an expanded group shows
  neither.
- I3. A hidden badge leaves no gap behind it. With one badge visible the row's
  trailing geometry matches the single-badge case. With none visible the strip
  leaves the row's layout rather than shrinking to zero width, so it draws no
  spacing from the row either: the accessory lane holds only the caret, and the
  title-to-caret gap equals what an expanded group row shows today.
- I4. The caret stays the trailing accessory at its current inset from the row's
  trailing edge, in every collapse and rename-recycle state.
- I5. Pills stay content-sized through repaints: one digit holds the intrinsic
  floor, more digits widen the pill, and a recycled row repainted back to one
  digit returns to the floor.
- I6. The group cell keeps naming its two badges, so existing row-projection and
  selection-cache tests can still read each one's visibility and string.

## Proof obligations

Extend the existing UI-harness coverage in `tests-ui/BadgeLabelTests.swift`,
which already builds a real `SidebarGroupCellView` and lays it out.

- PO1 (I1). A collapsed group row with a nonzero alert count and a tab count
  lays out with both pills visible and a gap between their frames at or above the
  floor.
- PO2 (I2, I3). Across the collapsed / expanded / recycled repaint sequence the
  existing assertions on visibility and compact width still hold, plus two
  geometry assertions: with the alert badge hidden, the accessory lane is exactly
  the visible tab-count pill plus the caret and their gap; with both badges hidden
  (expanded group), the lane is the caret alone and the title's trailing edge sits
  where it does before this change -- a phantom gap of any size fails.
- PO3 (I4, I5, I6). Covered by tests that already exist and must keep passing
  unchanged in intent: the badge-width assertions in `BadgeLabelTests.swift`, the
  group caret and badge-string assertions in
  `tests-ui/SidebarProjectionRowTests.swift`, and the caret trailing-inset
  assertions across sidebar widths and rename recycling in
  `tests-ui/SidebarRenameRecycleTests.swift`.

## Non-goals

- Restyling badges (color, height, radius, typography) or the caret.
- Adopting the strip in the single-badge sites (tab row, pane toolbar, bell
  button). They may adopt it later; nothing about this fix requires it.
- Unifying how the two group badges get their text. The tab count sets its string
  directly instead of going through the shared count update, so it would render
  "0" for an empty group; an empty group cannot exist, and the difference is
  unrelated to the gap.

## Rejected ideas

- RI1. `setCustomSpacing(_:after:)` on the row's accessory stack. Correct today
  and a smaller diff, but it leaves the pill-to-pill gap as an adjacency rule the
  row must remember, which is the defect this plan removes.
- RI2. Moving badge visibility into `SidebarGroupProjection.Rendered` as an
  ordered badge list, so the core decides which pills a row shows. A real
  simplification of the view-side `isCollapsed` branching, but it does not
  prevent the spacing defect and is a separate change.

## Implementation discretion

- The strip's construction shape (badges passed in at init versus described by a
  value) and the exact spacing constant above the 4pt floor.

## Files

- `app/BadgeLabel.swift` -- the strip lives here; the file already owns shared
  badge construction and painting.
- `app/SidebarCellViews.swift` -- `SidebarGroupCellView` arranges strip + caret.
- `tests-ui/BadgeLabelTests.swift` -- PO1, PO2.

## Verification

1. `just test-ui` (needs a WindowServer; it is outside `just test`).
2. `just test` before the commit.
3. `just launch-slot`, create a group with a tab that raises an alert, collapse
   it, and confirm the two pills read as separate; `just stop-slot <n>` after.

## Implementation notes

- The user explicitly waived new tests for this trivial layout change. The
  implementation changes production code only and relies on the existing gate
  and AppKit UI suite.
