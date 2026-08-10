# Sidebar Accessory Row Alignment

## Problem and desired outcome

Sidebar alert badges can sit beside the title instead of at the row's trailing
edge. Dragging the sidebar does not reliably move them, and ending inline rename
can either preserve or lose the correct alignment.

An AppKit probe reproduces the failure: the existing cell-frame override returns
the outline width when AppKit asks for placement, but an already-materialized
cell keeps its old width after its row grows. Removing that override and making
the row resize its hosted cell on layout makes the cell follow the row across
the same width change. This identifies stale cell placement, rather than title
or badge constraints, as the load-bearing cause.

Every sidebar cell should occupy the scroll view's visible content width. Tab
badges and group accessories should align to that visible content area's
trailing edge regardless of title length, sidebar width, scroller style, or
rename state.

## Decision

The full-width sidebar row owns the complete frame of its hosted cell views. On
every row layout pass it stretches those cells from its leading edge through
its trailing edge, so initial placement, divider movement, and rename teardown
all converge through one authority.

The existing outline-view cell-frame override is removed. The existing outline
and column autoresizing that keeps rows aligned with the scroll view's visible
content area remains unchanged; only the row owns placement of cells within
those bounds.

Badge and accessory layout remains relative to the cell's trailing edge. Once
the cell width is a row-level invariant, title layout and inline editing cannot
move the accessory lane.

## Invariants

**I1. Full-width cells.** Each tab and group cell covers the scroll view's
visible content bounds from leading edge through trailing edge throughout the
supported expanded sidebar range of 200 through 300 points.

**I2. Stable accessory alignment.** Visible tab badges and group accessories
remain at their intended inset from the visible content area's trailing edge in
display mode, during inline rename, and after rename commit or cancellation.

**I3. Title independence.** Short, long, custom, and changing titles do not
determine the accessory position. Titles continue to truncate before they
overlap the accessory lane.

**I4. Single geometry owner.** The row view alone establishes hosted cell width.
Rename completion does not repair alignment with delayed work, explicit
repainting, column refitting, or badge-specific repositioning.

## Proof obligations

**PO1 (I1, I2).** UI-harness coverage compares cells and accessories against
the scroll view's visible content bounds in a common coordinate space. It
proves both cell edges and the accessory trailing edge stay aligned when the
sidebar is initially shown and at both the 200-point and 300-point expanded
width limits, including when a vertical scroller consumes content width.

**PO2 (I2, I3).** UI-harness coverage proves short and long titles preserve
trailing alignment before, during, and after rename commit and cancellation,
including after a complete layout pass and after the edited cell is recycled
for a different item.

**PO3 (I3).** UI-harness coverage proves constrained titles truncate without
overlapping or displacing visible accessories.

## Rejected ideas

- **Rejected idea:** invalidate or delay layout only when rename ends. The bug
  also appears during ordinary sidebar resizing, and rename timing should not
  own row geometry.
- **Rejected idea:** position badges directly from sidebar coordinates. This
  duplicates the cell layout system and would leave group accessories and
  future trailing controls exposed to the same defect.
- **Rejected idea:** make column fitting the cell-width authority. Existing
  outline and column autoresizing still makes rows follow the visible viewport;
  routing cell placement through the column adds an AppKit-owned intermediate
  authority.

## Implementation discretion

- The internal iteration used to identify a row's hosted cell views and the UI
  harness seam are discretionary provided the row remains the sole cell-width
  authority and the proof obligations use real AppKit layout.

## Implementation notes

- The production screenshot disproved the plan's claim that stale cell width
  was the only load-bearing cause. Live hierarchy inspection showed a full-width
  row and cell, but the trailing accessory stack had expanded into the title
  lane and kept its visible controls at the stack's leading edge. The tab and
  group accessory stacks now resist both horizontal expansion and compression,
  and the UI tests compare the actual badge and caret against the clip edge
  instead of accepting the stack's trailing frame as proof.
- `NSOutlineView` can change a materialized row through `setFrameSize(_:)`
  without scheduling `layout()`. `SidebarRowView` enforces the hosted-cell
  invariant in that synchronous resize hook as well as during layout.
