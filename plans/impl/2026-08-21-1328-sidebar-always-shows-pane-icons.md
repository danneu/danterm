# Sidebar Always Shows Pane Icons

## Problem

A sidebar tab row changes its second line based on pane count. A single-pane
tab shows its working directory, while a split tab shows its pane icons. This
makes the same part of the row carry two unrelated meanings.

The sidebar should always show the pane icon list. A single-pane tab should
show a one-icon list, and a split tab should continue to show all of its panes.

## Decision

- Make the pane icon list the only sidebar tab-row content on the second line.
- Project every pane into that list, including the sole pane of a single-pane
  tab.
- Remove the working-directory subtitle from the sidebar projection and row.
  A working-directory-only update should no longer repaint the sidebar row.
- Keep working-directory state and every non-sidebar use unchanged, including
  window chrome, launch behavior, persistence, and copy actions.

## Invariants

- Every valid tab row shows at least one pane icon.
- Pane icons remain in tree order and identify the focused pane.
- Pane-specific alert and agent state remains visible for both single-pane and
  split tabs.
- The row height, pane icon artwork, fitting behavior, and overflow behavior do
  not change.
- The leading focused-pane chip remains. A single-pane row therefore shows the
  pane in both the leading chip and the second-line pane list.

## Proof Obligations

- Prove that a single-pane tab with a known working directory renders one
  visible, focused pane icon and does not render the working directory in the
  sidebar row.
- Prove that a working-directory-only session update leaves the sidebar
  projection unchanged and does not reload the tab row.
- Prove through the sidebar projection that alert and agent-state changes for
  a single-pane tab repaint that pane's icon.
- Preserve the existing proofs for split-pane ordering, focus, alert state,
  agent state, fitting, and overflow.
- Re-home the hostile working-directory flatness proof to the window title, so
  the remaining display boundary still proves that the value is single-line.
- Prove that working-directory display still works on its retained non-sidebar
  surfaces.
- Follow TDD: observe the new single-pane behavior test fail for the expected
  reason before changing production code, then run the focused core tests, the
  AppKit UI suite, and the full local gate.

## Non-goals

- Do not change working-directory storage, reporting, persistence, or launch
  inheritance.
- Do not redesign the pane icon artwork, sidebar row geometry, or leading chip.

## Implementation Discretion

- The exact internal cleanup of obsolete subtitle fields and constraints is
  left to implementation, provided no hidden working-directory branch remains
  in the sidebar row.
