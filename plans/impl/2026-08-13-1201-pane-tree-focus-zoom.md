# A tab's focus and zoom belong to its tree

## Context

Audit finding S05 in `docs/scratch/2026-08-11-simplification-audit.md`, verified
against the current tree. It is a symptom of the audit's largest theme: one fact
kept in two places, held together by convention instead of by a type.

## Problem

`TabModel` stores `rootNode`, `focusedPaneId`, and `isZoomed` as three
independent fields, so two rules that the tree owns -- "the focused pane is a
leaf of this tree" and "zoom dies when the shape changes" -- are conventions
every tree-editing arm must re-honour by hand.

Evidence, all current:

- Six arms of `update()` repeat the same ritual inside an `updateTab` closure:
  assign `rootNode`, re-anchor `focusedPaneId`, clear `isZoomed`
  (`Update.swift`, the `.splitPane`, `.closePane`, `.movePane`, both
  `.movePaneToTab` halves, and `.movePaneToNewTab` arms).
- The ritual is already inconsistent. `.closePane` re-anchors focus to the
  removed pane's neighbour unconditionally; `.movePaneToTab` and
  `.movePaneToNewTab` re-anchor only when the pane leaving held focus. So
  closing a background pane in a split steals focus from the pane the user is
  looking at, and in `focus` alert-clear mode silently marks the neighbour's
  unread alerts read. Nothing in the types says which of the two rules is
  intended.
- `removeLeaf` (`ModelOperations.swift`) hands back a `nextFocus` that nothing
  forces the caller to apply.
- Read code compensates for a focus that could dangle: `tabChrome` falls back to
  `("Terminal", nil)`, `tabChipKind` falls back to `.none`, and the restore path
  re-checks focus against the tree's leaf set.
- The zoom rule "a lone leaf is never zoomed" is enforced only inside the
  `.toggleZoomPane` arm, and separately re-established by six unrelated arms
  clearing zoom on any shape change.

## Desired outcome

A tab's focused pane and zoom state cannot disagree with its tree, because they
are not separately writable. Every structural edit is one call that leaves the
tab consistent, and the read sites that guard against a dangling focus are
deleted rather than maintained.

## Decision

Replace the three fields with one `PaneTree` value owning the split tree, the
focused pane, and zoom, with focus and zoom settable only through its own
mutators. The mutators are the structural operations the reducer already
performs -- split, remove, swap, move, adopt a pane from another tab, focus,
zoom, and the shape-neutral rebuilds -- each of which re-establishes focus and
zoom from its own result. `TabModel` holds one `PaneTree`.

The existing free tree functions in `ModelOperations.swift` (`splitLeaf`,
`removeLeaf`, `moveLeaf`, `swapLeaves`, `setRatio`, `nearestLeaf`,
`updatePaneInNode`, `firstLeafId`, `allPaneIds`) stay and become the mutators'
bodies. This plan does not rewrite tree algorithms; it moves the ownership of
focus and zoom to the value that already owns the shape.

Two decisive constraints, because the current arms are deliberately not uniform:

- **Focus moves are zoom-neutral.** Three callers change focus with three
  different zoom policies -- directional focus swallows the move and unzooms
  instead, a pane becoming first responder leaves zoom alone, and pane
  navigation unzooms only when focus actually moved. Zoom policy stays at the
  call site.
- **Shape-neutral rebuilds touch neither focus nor zoom.** Mutating a pane's
  payload, mutating the session a pane owns, and changing a split ratio all
  rebuild the tree's spine while preserving its leaf set and shape. They must
  not travel through the shape mutators, and `.splitRatioChanged` must keep
  preserving zoom.

Closing a pane adopts the guarded rule the cross-tab moves already use: focus
moves only when the pane that held it left. This is a deliberate behavior
change, taken because the alternative rule cannot be justified on its own terms.

## Invariants

- **I1.** A tab's focused pane is always a leaf of that tab's tree. No API can
  name a focus that is not.
- **I2.** A tab whose tree is a single leaf is never zoomed.
- **I3.** Removing a pane from a tab changes that tab's focus only when the
  removed pane held it. The focus-mode alert clearing that follows a close
  applies only when focus actually moved, and only in the selected tab.
- **I4.** Every operation that changes a tab's tree shape leaves that tab
  unzoomed. Changing a split ratio, mutating a pane's payload, and mutating a
  pane's session leave both focus and zoom unchanged.
- **I5.** Changing which pane is focused never changes zoom. The reducer arms
  that unzoom on a focus move keep doing so explicitly.
- **I6.** Restoring a session normalizes rather than rejects: a snapshot whose
  focused pane is absent, unparseable, or omitted restores focused on the tree's
  first leaf, and a restored tab is never zoomed. A snapshot with a structurally
  invalid tree or a duplicate id is still rejected as it is today.
- **I7.** The on-disk snapshot and the IPC JSON keep their current shape: a
  `focusedPaneId` UUID string, an `isZoomed` boolean in tab and pane replies, and
  no persisted zoom. `danterm` output does not change.

## Proof obligations

The suites in `lib/DanTermCore/Tests/DanTermCoreTests/` already carry most of
this contract; the refactor keeps them green without weakening their assertions.

- **PO1** (I1): focus lands on a leaf of the tab's own tree after each of split
  foreground, split background, close, swap, move within a tab, move to another
  tab, and move to a new tab -- `UpdatePaneTests`. Add a direct check that the
  non-optional focused-pane accessor agrees with the tree for every mutator.
- **PO2** (I3): a new test -- closing a non-focused pane in a split leaves focus
  where it was, and leaves the survivor's unread alert unread in `focus`
  alert-clear mode. The existing background-tab close tests
  (`closePaneBackgroundTabPreservesSuccessorAlert`) stay green.
- **PO3** (I2): zoom cannot be raised on a single-pane tab, and a close that
  reduces a split tab to one pane leaves it unzoomed -- `UpdatePaneTests`,
  `UpdateIpcTests` (`pane.zoom` on an unsplit tab).
- **PO4** (I4): each shape change clears zoom; `.splitRatioChanged` preserves it;
  a session report and a pane-payload edit leave focus and zoom untouched --
  `UpdatePaneTests`, `ReconcileTests`, `SessionReportTests`.
- **PO5** (I5): directional focus while zoomed unzooms without moving focus; a
  pane becoming first responder leaves zoom alone; pane navigation unzooms only
  when focus moved -- `UpdatePaneTests`, `UpdateAlertTests`,
  `UpdateLifecycleTests`.
- **PO6** (I6): restore with an omitted focus falls back to the first leaf
  (`SnapshotTests` covers this arm today); add the two uncovered arms -- a
  well-formed focus UUID naming no pane in the tree, and a malformed focus
  string. Zoom is not persisted -- `CheckpointTests`.
- **PO7** (I7): the IPC tab and pane replies keep their current keys and values
  -- `UpdateIpcTests`; the on-disk round trip is unchanged -- `SnapshotTests`,
  `ExportTests`, `CheckpointTests`.

## Non-goals

- Per-pane search and notification side tables. Nesting those in `PaneModel` is
  a separate audit finding with its own ADR to amend, and folding it in here
  doubles the test-fixture churn in one pass.
- Rewriting any tree algorithm. `removeLeaf`'s sibling promotion, `moveLeaf`'s
  insertion rule, and `nearestLeaf`'s directional search keep their current
  behavior.
- Retiring the whole-`AppModel` golden snapshot. It is re-recorded here, not
  deleted; deleting it is a separate finding.
- Any change to the CLI surface or `integrations/danterm/SKILL.md`.

## Accepted risks

- **AR1.** The golden snapshot dumps `TabModel`'s members, so it must be
  re-recorded. A re-record can absorb a real regression. The mitigation is a
  review rule, not a test: the only permitted delta is the nesting of the three
  members under the new value. Any id, ordering, or boolean change in the
  re-recorded file is a bug to investigate, not to accept.
- **AR2.** Roughly sixty fixture sites across the core tests, the AppKit UI
  tests under `tests-ui/`, and one research probe under `scripts/research/`
  construct a tab by naming `focusedPaneId`. The UI tests are outside `just
  test` and the probe is outside every target, so both can rot silently; they
  are part of this change, not follow-up.

## Rejected ideas

- **RI1. Keep the three fields and funnel every edit through one
  `replaceTree(_:focusHint:)` on `TabModel`.** It removes the copy-paste but not
  the defect class: the invariant still holds only for callers who choose the
  right function, and the read sites still have to guard. The audit lists this
  as the cheap fallback; it is not what makes the dangling focus
  unrepresentable.
- **RI2. Make the restoring construction failable.** Today a snapshot focus that
  names a missing pane is repaired, not rejected, and repairing is the right
  behavior for a file the user may have hand-edited. Rejection would lose a
  session over a recoverable field.

## Implementation discretion

- Whether the migration commit is staged internally behind temporary forwarding
  accessors on `TabModel` to keep the reviewable diff small. Any such accessor
  is deleted within the same commit series.
- The exact mutator signatures, and whether the split mutator takes a
  "focus the new pane" parameter or is two entry points.

## Commit progress

Each commit leaves the tree building and `just test` green.

- [x] **1. Closing a pane stops stealing focus.** Apply I3 to the `.closePane`
  arm on the existing fields, with the PO2 test. Isolated so the one
  user-visible change in this plan is bisectable on its own, and so the suite is
  already green under the new semantics before the refactor starts.
- [ ] **2. Introduce `PaneTree` and migrate every writer and reader.** The new
  type with its own unit tests covering the focus/zoom outcome of each mutator,
  the six ritual sites, the three shape-neutral rebuild sites, the focus and
  zoom arms, the three production constructions, the persistence and restore
  paths, and every fixture in the core tests, `tests-ui/`, and the research
  probe. Re-record the golden under AR1's review rule. Update the sentence in
  `docs/design/2026-05-27-model-driven-view-reconciliation.md` that names the old
  field.
- [ ] **3. Delete the compensating reads.** Drop the dead pane-missing arms in
  `tabChrome` and `tabChipKind` and adopt the non-optional focused-pane accessor
  where a tab is already in hand. Foldable into commit 2 if that diff stays
  reviewable.
- [ ] **4. Record the finding as closed.** Put the commit hashes in the Status
  column of the S05 row in `docs/scratch/2026-08-11-simplification-audit.md`,
  matching the convention the closed rows already use.

## Verification

- `just test` after each commit. `swift test --package-path lib/DanTermCore` for
  the tight loop.
- `just test-ui` at least once in commit 2, since the `tests-ui/` fixtures are
  outside the gate. Run it into a file and grep the file.
- Drive the real app for the behavior change and the zoom rules that only show
  up on screen: `just launch-slot`, then use `danterm --socket <slot>` to open a
  tab, split it, zoom, close the unfocused pane, and confirm from `pane info`
  that focus did not move and zoom is where it should be. Stop the slot when
  done.
