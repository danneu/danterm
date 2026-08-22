# Refactor Pane-Tree Queries and Layout Roster

## Summary

Replace pane-tree materialization used for membership, counting, and iteration
with purpose-specific traversals. Make `PaneLayout` the complete pane roster
through one exhaustive placement map. This replaces the roster, visibility,
and geometry sources that currently answer one presentation decision, and
makes a pane that is both hidden and framed -- or neither -- unrepresentable.

This is an internal, behavior-preserving refactor. It does not claim a
benchmark-visible speedup.

## Key Changes

- Add allocation-free tree operations for pane membership, single-pane
  detection, and direct leaf iteration.
- Rewrite ordered pane-ID and pane-model collection to append into one result
  buffer while preserving left-to-right tree order.
- Convert all production membership, count-only, and iteration-only callers to
  the narrow operation they need. Keep materialized arrays and sets only where
  callers require ordering, indexing, repeated membership, or returned
  collections.
- Replace `PaneLayout`'s parallel `paneFrames` and `hiddenPaneIds` fields with
  one map from pane ID to an exhaustive placement: visible with a frame, or
  hidden.
- Keep the existing `paneLayout(in:tree:zoomedPaneId:)` input contract. An
  unknown zoom ID must continue to produce the normal unzoomed layout.
- Update drop targeting, autosplit, drag highlighting, and `SplitContainerView`
  to consume placements. The container must use the placement-map keys as its
  desired pane roster and must not flatten its stored tree.
- Preserve wrapper identity, avoid frame assignments to hidden panes, and keep
  the pure layout as the sole pane-frame producer.
- Update the model-owned pane geometry ADR to describe the exhaustive placement
  map.

## Invariants

- Every layout produced by `paneLayout` places each tree leaf exactly once.
- A placement cannot be both hidden and framed, or neither.
- Normal layout marks every pane visible and preserves all current geometry and
  divider rules.
- Valid zoom marks exactly the named pane visible at full bounds, hides every
  sibling, and emits no dividers.
- Unknown zoom IDs retain the current unzoomed fallback.
- Ordered pane collections retain left-to-right tree order.
- Membership and single-pane queries return the same answers as the current
  flattened-array expressions.
- AppKit applies only the geometry returned by the pure layout and never derives
  a second pane roster from the tree.

## Test Plan

- Add characterization coverage for the complete layout roster in normal,
  valid-zoom, and unknown-zoom cases before changing the representation. State
  the assertions through representation-independent visible-frame and
  hidden-ID observations, so the assertions remain unchanged when the layout
  representation changes.
- Cover tree queries on a root leaf, nested splits, present IDs, absent IDs, and
  stable left-to-right collection order.
- Keep reducer coverage green for foreign-pane focus/search rejection, move
  failures, close-last-pane behavior, restore focus repair, and TODO-popover
  eligibility.
- Update pane-drop and autosplit tests to prove that only visible placements
  participate.
- Update `SplitContainerView` UI coverage to prove mounting and removal follow
  layout membership, zoom hides without reframing siblings, unzoom restores
  frames, wrapper identity survives tree edits, and missing wrappers are
  retried.
- Run the targeted DanTermCore suite and `just lint` during the edit loop. Run
  `just test`, then `just test-ui`, before handoff.

## Assumptions and Non-goals

- RECON-1, PANE-1, and PANE-2 are already present and require no prerequisite
  work.
- No wire format, persisted model, CLI surface, or external API changes.
- Do not redesign container reconciliation or merge tree and zoom operations;
  this refactor changes the layout result and tree-query surfaces only.
- Do not add allocation-sensitive tests or a benchmark threshold. Confirm the
  architectural result through code inspection: no recursive array
  concatenation, no membership/count checks on freshly materialized pane
  arrays, and no `SplitContainerView` tree flatten.

## Commit progress

- [x] 1. Add direct pane-tree queries and migrate narrow callers
- [x] 2. Replace parallel layout fields with exhaustive placements
- [x] 3. Reconcile AppKit from placements and update UI coverage and ADR

## Implementation notes

- Commit 2 keeps temporary read-only `paneFrames` and `hiddenPaneIds`
  projections so the AppKit target remains buildable between slices. Commit 3
  removes them after it migrates the remaining AppKit consumers to placements.

## Follow Up

- Restore the iOS portability gate by passing the required `searchReadout`
  argument to `PaneFramePlanner.planFrame` in
  `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileFramePresenter.swift:135`.
- Repair the `PreferencesPanelTests.swift:65` keybinding-table assertion that
  `just test-ui` reports as failed even though the recipe exits successfully.
