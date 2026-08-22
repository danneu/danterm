# Keep Count Badges Content-Sized

## Problem

Collapsed sidebar groups show their tab count in a badge. In the observed group
row, a visible count of `2` expanded across the unused width of a wide sidebar.
The row constrains the title and accessory stack as one horizontal chain, but the
badge has only a minimum width and default content-hugging priority. The layout
can therefore assign the badge the chain's surplus width. The model already
supplies the correct count and collapsed state.

## Decision

Replace the generic text-field factory with a shared badge component that owns
its intrinsic size. Its intrinsic width is the rendered text width plus symmetric
horizontal padding, floored at 14 points; its intrinsic height is 14 points. The
component must hold that width against both expansion and compression, while an
adjacent title remains flexible.

This rule applies to every badge made by the shared component, including group
tab counts, alert counts, pane badges, and toolbar badges.

## Invariants

- A badge's width is a pure function of its displayed count: symmetric padded
  text width with a 14-point floor.
- Unused horizontal space goes to the adjacent flexible content, not a badge.
- Multi-digit counts remain readable, retain padding on both sides, and produce a
  wider pill when necessary.
- Existing badge colors, visibility rules, count values, and collapse behavior do
  not change.

## Proof Obligations

- Prove that collapsed group badges remain content-sized with short and long
  titles, one- and multi-digit counts, and visible or hidden alert badges.
- Prove that expand, collapse, and recycled-row repaint paths preserve compact
  badge sizing.
- Prove that a pane toolbar badge remains content-sized at narrow pane widths and
  leaves the remaining width to the truncating toolbar label.
- Run the targeted sidebar AppKit tests and lint during development, then run the
  full UI suite for final verification.

## Non-goals

- Do not change the model, sidebar projection, reconciliation, CLI, or count
  semantics.
- Do not impose a fixed width that prevents badges from growing with their count.

## Accepted Risks

- A multi-digit window-toolbar bell badge can grow left past its fixed-size button;
  this static overlay has no flexible sibling to displace, so it does not warrant
  a separate layout test.

## Implementation Discretion

- The exact padding value and behavioral test scenarios are implementation choices
  as long as they prove the sizing invariants above.
