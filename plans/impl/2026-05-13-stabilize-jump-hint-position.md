# Stabilize Jump Hint Position Beside Tab Titles

## Summary

Make the sidebar tab hint/title stack use one fixed x-position regardless of
whether the tab has a color stripe. The color stripe should be visual-only:
visible when colored, hidden when uncolored, but never participating in text or
hint layout.

## Key Changes

- In `app/SidebarView.swift`, remove the dynamic `tabLeadingStackLeading`
  constraint and the per-tab `8` vs `12` constant update.
- Constrain `tabLeadingStack.leadingAnchor` to `cell.leadingAnchor + 12` in
  `makeTabCell(for:)`.
  - This directly expresses the desired fixed hint/title position.
  - With the existing 5pt stripe, colored rows still have a 7pt visual gap
    between the stripe and the hint badge.
  - When the stripe is hidden, the hint/title stack stays at the same x-position
    because stripe visibility no longer affects layout.
- Keep the existing jump badge stack behavior unchanged: badge inserts at index
  0 before the title, subtitle stays aligned to `textField.leadingAnchor`, and
  trailing bell badge remains in `tabAccessoryStack`.

## Test Plan

- Run `just build`.
- Run `just test`.
- Manual check in the dev app:
  - Compare jump-mode rows with and without tab colors; hint badges should align
    vertically in the same x-position.
  - Toggle a tab color on/off while jump mode is active; hint/title/subtitle
    should not shift horizontally.
  - Verify colored rows still show visible space between the 5pt stripe and the
    hint badge.
  - Verify title truncation still works with jump hint plus trailing alert badge.

## Assumptions

- The desired stable position is the current colored-row position: 12pt from the
  row leading edge.
- Uncolored rows should keep the same 12pt hint/title inset rather than
  reclaiming the stripe area.
- This remains a UI-layout-only fix; no model, jump-mode key map, or badge
  styling changes.
