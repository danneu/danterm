# MODEL-5: move per-pane search and notification-throttle state into PaneModel

Audit item: MODEL-5 in docs/scratch/2026-08-18-construction-audit.md (wave 1,
lane J). REDUCE-2 and REDUCE-5 unblock on this; MODEL-1 merges after it in the
same lane.

## Problem

`AppModel` keeps two dictionaries keyed by `PaneId` whose entire lifetime is
the pane's -- `searchState` and `lastNotificationTime` -- outside the split
tree that owns panes. Pruning them is a convention: five pane-destroying paths
in `Update.swift` must each remember to call `clearPaneSideTables`, and
`desiredSearchOverlays` iterates the dictionary, so a missed prune projects a
search overlay for a pane that no longer exists. This is the same dual-ownership
drift the model already eliminated for panes themselves; the pane-access
section header in `Model.swift` states the principle the two dictionaries
violate ("NO stored index is kept").

## Decision

Nested live bucket on `PaneModel` -- audit option 3. This decision is made by
the owner; do not reopen it. Not the flat move, and not the reconcile fallback.

- `PaneModel` gains one nested value holding the pane's live-only state: the
  active search (if any) and the per-kind notification-throttle timestamps.
  The two `AppModel` dictionaries are deleted. Reads and writes go through the
  existing tree-routed pane accessors.
- Why nested rather than flat: LOOKUP-1 must split persisted from live inside
  `PaneModel` and `SessionModel` regardless, because `SessionModel.progress`,
  `processPhase`, `command`, `agent` and `PaneTree.isZoomed` already sit inside
  `groups` and are not persisted. The nested bucket lands that seam early --
  the persisted/live boundary becomes a type instead of twelve "ephemeral --
  excluded from snapshots" line comments -- at the same cost as the flat move.
- Why not the reconcile fallback: the owner accepted roughly 8x the edit
  because a destroyed pane's search overlay or throttle entry must become
  unexpressible, not merely repaired promptly at the end of each message.

**The honest loss, stated plainly: this ideal cannot prune alerts.**
`AlertModel.paneId` is non-optional, but `alerts` is one global ordered list,
so it cannot move onto `PaneModel`. Only a reconcile pass could take alerts in
the same sweep. The alert prune and all five of its teardown call sites
therefore survive this change, with narrowed meaning; the reconcile fallback
would have retired them. After this change the tree-owns-panes invariant
extends to pane live state but still stops short of the alert feed.

## Invariants

- I1: A pane's search state and notification-throttle timestamps have no
  storage independent of the tree leaf that owns the pane. Destroying the pane
  destroys them; no teardown path can forget, because there is nothing left to
  call.
- I2: Live pane state never enters a snapshot or the light-checkpoint
  projection. Persistence keeps enumerating persisted fields and never reads
  the live bucket.
- I3: Observable search and notification behavior is unchanged: the overlay
  projection keys a pane iff its search is active; focus-ownership transitions
  are as today; notifications stay throttled to one per pane per kind per
  throttle interval; live state follows its pane through pane swap and move,
  which carry the whole `PaneModel` payload.
- I4: Alerts for a destroyed pane are still pruned at every pane-destroying
  path (the surviving convention, per the Decision section).

## Behavior narrowing (accepted)

A search or throttle message naming a `PaneId` that no tree leaf owns becomes
a no-op. Today `.searchStarted` would create orphan state for such an id, and
the defensive `.sessionCreationFailed` fallback would clear it. Neither is
reachable from the product. PO5 pins the narrowing with a test written first,
so the change is deliberate rather than incidental.

## Proof obligations

- PO1 (I1): closing a pane with an active search leaves no key for it in the
  overlay projection; closing a pane with a recorded bell time leaves the next
  bell on a fresh pane unthrottled. Existing cleanup tests across closePane /
  closeTab / sessionCreationFailed / deleteGroup are re-expressed through
  projections and pane lookup so they survive the refactor.
- PO2 (I2): the light-checkpoint tests that transient facets (search included)
  leave the projection unchanged, and that persisted pane facets do change it,
  keep passing. This is the real safety net for moving search into the tree.
- PO3 (I3): the existing search suite, the bell and desktop-notification
  throttle tests, the per-pane-per-kind throttle test, and the pane-toolbar and
  container-shape projection tests keep passing.
- PO4 (I4): the existing alert-prune assertions on the pane-destroying paths
  keep passing.
- PO5 (I3, narrowing): a new test sends `.searchStarted` for a `PaneId` no tree
  leaf owns and expects no search overlay in the projection. Write it first and
  watch it fail against today's model, which creates the orphan overlay. This
  is the one behavior this change alters, so it gets the red test rather than
  landing as a side effect.
- PO6 (I3, continuity): the rearrangement tests that today assert payload
  transfer -- `swapLeaves swaps full payloads`, `movePaneToTab carries the
  pane's payload`, and `movePane(.splitRight) threads the moved pane's payload`
  -- seed an active search and a recorded throttle timestamp on the moved pane
  and assert both survive at the destination: the overlay projection still keys
  the pane, and a bell at the same instant is still throttled. Without this,
  a rearrangement path that rebuilt a pane from persisted fields alone would
  drop live state and the suite would stay green.

Apart from PO5, this is a pure refactor: every teardown path already prunes
today, and a test for the move itself would have to assert storage location
rather than behavior.

## Non-goals

- Retiring the alert-prune convention. Making the alert feed derivable
  (per-pane alerts flattened by a projection) is a second, larger change and is
  out of scope.
- LOOKUP-1 itself: the persisted/live split of `SessionModel` and the
  checkpoint compare are untouched. This change only lands the pane-level seam.
- Any persistence or snapshot format change.

## Accepted risks

- AR1: the live bucket's name and boundary are committed ahead of LOOKUP-1's
  planning. If the eventual split lands on a different shape, this is a small
  rename; both fields are unambiguously live under any reading of the pane
  snapshot codec.
- AR2: the overlay projection goes from O(active searches) to O(panes) per
  sweep. The model-driven reconciliation design doc already licenses per-sweep
  tree walks.
- AR3: three tests whose premise is "the prune happened" become tautological
  (state cannot outlive the pane) and lose independent value; their surface
  folds into the behavioral cleanup tests.

## Rejected ideas

- RI1: flat fields on `PaneModel` -- identical cost, but leaves LOOKUP-1 to
  invent the persisted/live seam later. Rejected by the owner.
- RI2: derived reconcile with the dictionaries staying -- roughly one eighth
  the edit and it retires more of the convention (alerts included), but the
  state stays outside the tree, so a stale entry remains representable for the
  duration of one message. Rejected by the owner.

## Implementation discretion

- Whether the five surviving teardown call sites keep a named wrapper for the
  alert prune or call the alert-prune helper directly, now that alerts are the
  only side table left.
