# Pin the selection drag anchor to rows eviction cannot renumber

## Context and problem

Dragging a selection in a pane that is scrolled up, while output streams into a
saturated scrollback, makes the selection's fixed end walk downward through the
text -- roughly one row per evicted row. Observed live with
`./scripts/saturate-scrollback.sh --stream 2`: press on a row, move the pointer a
few pixels, and the selection's far edge has descended eight rows. The drift
accrues with elapsed time, not pointer distance; moving the pointer only forces
the selection to be recomputed, which is why it reads as "lines per pixel".

`TerminalTextPosition.row` is projection-local: it counts from the oldest
*retained* row, so every eviction shifts it by one. Such a value is valid only at
the instant it is computed.

Every long-lived coordinate inside `Terminal` is therefore stored against
absolute rows and resolved on read -- selection, search occurrence, hovered link,
armed link, browsing viewport top. The in-flight drag anchor is the sole
exception: the pointer policy captures it as a raw `TerminalTextRange` at
mouse-down and never re-resolves it. The moving end *is* recomputed correctly on
every move, so the union of the two drags the fixed end downward. It is the only
cross-time holder of projection-local coordinates in the repo.

## Decision

- The drag anchor stays owned by the pointer policy, but becomes an opaque value
  that only `Terminal` can mint and only `Terminal` can resolve. The policy
  cannot do coordinate arithmetic on it, so it cannot restate -- or drift from --
  the rules `Terminal` already enforces.
- Resolution applies `Terminal`'s own eviction rule, not a re-derived one: a
  partially evicted anchor clamps forward to the oldest retained row, exactly as
  a settled selection does.
- The opaque value carries an epoch, so events that make absolute rows mean
  something else -- a hard reset, a width reflow, a screen replacement --
  invalidate it rather than resolving it to plausible wrong text. Hard reset is
  the case that makes a bare counter unsalvageable: it returns the eviction count
  to zero, so a stale anchor would resolve to a wrong-*but-in-range* position. A
  soft reset does not renumber the primary screen's rows and so does not
  invalidate on its own.
- `decideTerminalPointer` stays self-contained: it keeps its by-value terminal,
  and its correctness must not depend on the caller having applied any previous
  decision. This is an existing property -- `lineDragTrimsOuterEdgesOnly` moves
  without applying the prior mutation -- and it is load-bearing.
- Nothing new becomes public. The policy and `Terminal` are the same module.

## Invariants

- I1: while a drag is in progress, its anchored end stays on the text it was
  placed on across any number of appends, scrolls, and evictions -- mutations
  that renumber rows without rewriting the anchored cells. Rewriting those cells
  in place is governed by I5 instead.
- I2: the endpoint under the pointer tracks the text under the pointer, in a
  following viewport and a browsing one alike. (Existing behavior; the fix must
  not regress it.)
- I3: when the anchored text is partially evicted, that edge clamps forward to
  the oldest retained row and the drag keeps extending -- the rule a settled
  selection already follows.
- I4: after a hard reset, a width reflow, or a screen replacement, the drag stops
  extending rather than resolving its anchor against renumbered rows. Mutations
  that leave absolute rows meaning the same thing do not stop it: a height-only
  resize, and a soft reset taken on the primary screen. A soft reset taken from
  the alternate screen stops the drag, but through the screen replacement it
  performs, not through being a reset.
- I5: output that rewrites the anchored cells in place does not end the drag; the
  anchor stays at that position and the drag keeps extending from it, even though
  the text there is now different. This diverges deliberately from what
  `Terminal` does to a settled selection: the button is still held and the user
  is actively re-selecting, so position wins over content.
- I6: the anchor is not readable as coordinates outside `Terminal`. No caller can
  hold a projection-local position across a terminal mutation.

## Behavioral scope

- Applies to all three drag granularities. The anchor is a whole unit, not a
  boundary: dragging past it must preserve the entire unit at the far edge, and
  reversing direction across it must restore that unit -- which is why the
  selection's current endpoints cannot serve as the anchor, since the union has
  already consumed the far boundary.
- The character-granularity suppression of a not-yet-extended drag survives:
  a press with no pointer movement still selects nothing, and eviction alone does
  not count as extending.
- No change to what a click or drag selects in a quiescent pane.

## Proof obligations

- PO1: a drag whose pointer does not move, across enough streamed output to evict
  rows from a saturated scrollback, keeps selecting the same text (I1). Prove it
  across more than one eviction burst, so a one-shot rebase cannot pass.
- PO2: the moving endpoint tracks the pointed text under a browsing viewport and
  under a following one (I2). This premise is why the fix targets only the
  anchor, and it is currently unpinned.
- PO3: an anchor whose text is partially evicted clamps to the oldest retained
  row and the drag keeps extending (I3).
- PO4: a token or line drag preserves its whole anchored unit when the drag
  reverses direction across it after an eviction.
- PO5: hard reset, width reflow, and screen replacement each stop the drag; a
  height-only resize and a primary-screen soft reset do not, and a soft reset
  issued from the alternate screen does (I4).
- PO6: clearing the scrollback drops an anchor held in scrollback and preserves
  one held in the viewport.
- PO7: rewriting the anchored cells in place leaves the drag extending from that
  position, now covering the replacement text (I5), recorded as a decision rather
  than an omission.
- PO8: a press that never moves still selects nothing, even after eviction, and
  extends normally afterward.
- PO9: minting an anchor and resolving it back reproduces the exact selection
  unit, for every granularity and across a wide cell, a hard line end, and a
  trimmed blank line. The equality checks that drive both `hasExtended` and the
  no-movement suppression compare the resolved anchor against a freshly computed
  unit, so a non-identity round trip would silently misfire both.

## Non-goals and accepted risks

- Non-goal: no new persisted or serialized state, and no on-disk format change.
  Recordings already store viewport-relative pointer coordinates.
- Non-goal: the four hand-duplicated anchor-repair blocks in `Terminal`
  (eviction, overwrite, reflow, clear) are not generalized here. This fix adds no
  fifth member to them, so the duplication does not grow. Revisit only if a
  future anchored member must survive reflow.
- Accepted risk: the drag anchor and a settled selection diverge on an in-place
  rewrite of the anchored cells (I5). Accepted because the policy layer has no signal for a cell
  rewrite, and aborting a drag under a held button is the worse behavior; a test
  names the choice.
- Rejected: exposing the eviction count and rebasing the anchor by a delta. The
  resolution rule is a subtraction *plus* the eviction clamp *plus* the retention
  window check, all of which already exist inside `Terminal`; restating them
  outside is where the next drift bug comes from, and it cannot express the
  reset hazard at all.
- Rejected: re-deriving the anchor from the current selection plus a remembered
  fixed end. It has nothing to derive from after a character-granularity press,
  it would require callers to apply mutations before the next event, and it
  cannot restore a whole-unit anchor once a direction flip has consumed that
  boundary.

## Critical files

- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` -- the opaque pinned
  range, its mint/resolve pair beside the existing coordinate conversions, and
  the epoch bumped at the sites that renumber absolute rows.
- `lib/TerminalCore/Sources/TerminalCore/TerminalInteractionPolicy.swift` --
  the drag anchor's type and the resolve-or-stop branch on move.
- `lib/TerminalCore/Tests/TerminalCoreTests/TerminalInteractionPolicyTests.swift`
  -- all new tests. Saturated fixtures follow `lineSelectionTrimsWhitespace`,
  using `historyRowCost` from `TerminalGridAssertions.swift`, with row-distinct
  content so a one-row drift shows up in the text.

Existing `lineDragTrimsOuterEdgesOnly` and `browsingSelectionCoordinates` must
pass unmodified; that they move without applying the prior mutation is what keeps
the fix caller-independent.

## Commit progress

- [x] Pin the drag anchor against eviction: the opaque range, its mint/resolve
      pair carrying the eviction clamp, and the policy switchover. Discharges
      PO1-PO4, PO8, PO9. Independently shippable -- it fixes the reported
      incident on its own.
- [x] Invalidate the anchor when absolute rows stop meaning the same thing: the
      epoch, its bump sites, and the stop-extending branch. Discharges PO5-PO7.

## Verification

- `swift test --package-path lib/TerminalCore`, then the full `just test` gate.
- Manually: `./scripts/saturate-scrollback.sh --stream 2`, scroll up, then drag.
  The selection must extend only where the pointer goes and hold still when the
  pointer does. Repeat with double-click and triple-click drags, and while
  reversing direction back across the anchored word.

## Implementation notes

- `resolvedRange` is `Optional` from its first commit, because it delegates to
  `publicRange`, which already answers nil for a range outside the retained
  stream -- and plain eviction can retire an anchor entirely. So commit 1 carries
  a minimal stop-extending branch (return a selection-owned decision with no
  selection mutation) rather than inventing a fallback position. Commit 2's epoch
  extends that same branch instead of adding a second one.
- `TextAnchor` and `TextAnchorRange` moved from `private` to `fileprivate` so the
  pinned range can store one. Both are nested in `Terminal` inside a single file,
  so this widens nothing beyond `Terminal.swift`.
- `PinnedTextRange` spells out its `==` because a synthesized one would inherit
  the stored property's `fileprivate` access, which leaves `SelectionDrag`'s
  `Equatable` conformance unsatisfiable from the policy file.

- The epoch is a counter in a wrapper whose `==` answers true, the same shape
  `ObservationGeneration` already uses, so it stays out of `Terminal`'s value
  equality: two terminals holding identical screen state must remain equal
  however each got there, and dozens of suites compare whole terminals. The pin
  therefore stores the raw `UInt64`, not the wrapper -- storing the wrapper would
  make every stale pin compare equal and resolve as current.
- Bump sites: `hardReset`, `resizeWidth`, both replacing branches of
  `switchAlternateScreen`, and `selectPrimaryScreen` after its guard. That guard
  is what makes a soft reset stop the drag only when it is taken from the
  alternate screen. `resizeHeight` is deliberately untouched: it moves rows
  between viewport and scrollback in stream order, so absolute numbers survive.
- Commit 2 changed no policy code. The stop-extending branch landed in commit 1
  for the reason recorded above, and the epoch reaches it through the same
  `resolvedRange` nil.

## Implementation discretion

- How the epoch is represented and where it is bumped, provided every event that
  renumbers absolute rows invalidates outstanding anchors and the events that
  preserve them (height-only resize, primary-screen soft reset) do not.
- Whether the drag stops by dropping its state or by suppressing extension,
  provided the button stays selection-owned so no bytes reach the child and
  release still ends the gesture cleanly.
