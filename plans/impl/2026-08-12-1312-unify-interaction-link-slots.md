# Unify the hover/arm interaction-link pair behind one slot-keyed path

## Context

Verifying audit finding S34 (docs/scratch/2026-08-11-simplification-audit.md)
confirmed real duplication in `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`:
`setHoveredLink` and `setArmedLink` are near-copies (same activatable-URI +
byte-cost guard, same `admittedHyperlinkTargets` admission, same anchor
ordering and normalization), `canAdmitArmedLink` restates the guard a third
time, and five lifecycle passes (`refreshHasContentInspectionState`,
`clearInspection`, `invalidateInspection(inAbsoluteRows:)`,
`handleEviction(of:)`, `softReset`) each hand-enumerate both link slots with
identical per-slot policy. A missed enumeration produces a stale anchor over
evicted or overwritten rows. The verified pivot: unify only the hover/arm
pair -- S34's full five-anchor registry was rejected (see RI3), and the
optional anchor-kind exhaustiveness enum was explicitly descoped by the user.

## Decision

Behavior-preserving refactor of the hover/arm machinery only:

- Keep the two stored properties (`hoveredLinkState`, `armedLinkState`) with
  their `didSet` observers. Their asymmetry (hover bumps the revision
  counter; arm does not) stays structural, not conventional.
- Route slot access through one private slot-keyed accessor over the existing
  `InteractionLinkSlot` enum, so each lifecycle pass states its policy once
  and iterates the slots.
- Collapse the three spellings of the admission guard + commit into one
  shared path used by `setHoveredLink`, `setArmedLink`, and
  `canAdmitArmedLink`. Damage bracketing stays in the public hover wrapper,
  outside the shared writer (see RI2).
- Public and internal API surface unchanged: `setHoveredLink`, `setArmedLink`,
  `clearHoveredLink`, `clearArmedLink`, `hoveredLink` (public) and
  `canAdmitArmedLink`, `armedLink` (internal) keep their signatures and
  semantics. External callers (TerminalPTYHost, TerminalInteractionPolicy,
  NeutralTerminalRecording, RenderFramePlanner) need no edits.

Critical files:

- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`
- `lib/TerminalCore/Tests/TerminalCoreTests/TerminalHyperlinkInteractionTests.swift`

## Invariants

- I1: Every write to the hovered-link slot advances the hover revision
  counter, including a write that stores an equal value; armed-link writes
  never advance it. (Contract documented at the counter's declaration; the
  damage diff relies on over-reporting.)
- I2: Setting or clearing the hovered link records damage for the link's
  rows; setting or clearing the armed link records no damage.
- I3: The content-identity wrap drops the armed link and preserves the
  hovered link.
- I4: Eviction drops a link whose range starts before the first retained
  row; overwrite invalidation drops a link whose range intersects the
  overwritten rows. The two predicates are distinct policies and both apply
  identically to the hover and arm slots.
- I5: `canAdmitArmedLink` returning true implies `setArmedLink` succeeds for
  the same link in the same state (one spelling of the admission
  arithmetic).
- I6: Both link slots keep participating in `Terminal`'s synthesized value
  equality; the revision counter stays equality-neutral.

## Proof obligations

Pin-first: each new test is written before the refactor and must pass on the
current code. A characterization test that has never been seen to fail proves
nothing, so each one is also shown to be effective: temporarily break the
behavior it names in the production code, confirm the test fails for that
reason, then restore the behavior before refactoring. All go in
`TerminalHyperlinkInteractionTests` following its existing helpers
(`activatableLink(at:)`, `drainDamage()`).

- PO1 (I2): arming and disarming a link records no damage.
- PO2 (I4): scrollback eviction drops an armed link (hover eviction is
  already pinned by `evictionClearsHover`).
- PO3 (I3): the content-identity wrap drops the armed link while a live
  hover on the same text survives (existing wrap tests never set a hover, so
  a loop that cleared both slots would pass the current suite).
- PO4 (I1): re-hovering the identical link still damages its rows (guards
  against an equality early-out in a unified writer; no existing test pins
  the equal-value case).
- Existing coverage discharges the rest: `TerminalHyperlinkInteractionTests`
  (hover damage, revision on target change, reflow restatement, overwrite
  invalidation, resets, cap sweep, hover eviction),
  `TerminalBatchRegressionTests` (I5 at the byte cap),
  `TerminalInteractionPolicyTests` and `TerminalASCIIRunTests` (wrap drops
  arm), `TerminalHistoryGenerationTests` (hover ops are presentation-only).

## Non-goals

- Selection, search, and viewport anchor handling stay hand-written; their
  policies are singular and documented in place.
- The `WidthChangeAnchor` capture/restate reflow register is untouched.
- The wrap sites keep their direct arm-only clears; they are single-slot by
  design.
- No anchor-kind exhaustiveness enum across the lifecycle passes (descoped
  by the user for this change).

## Rejected ideas

- RI1: Replacing the two stored properties with dictionary/keyed storage.
  A keyed store cannot express the per-slot `didSet` asymmetry (I1) without
  reintroducing the hand-written branching this change removes.
- RI2: Moving damage bracketing inside the shared writer. `DamageActionSnapshot`
  carries no armed fields, so bracketing arm writes would be a behavioral
  no-op that still pays a snapshot capture per write and hides the I2 policy.
- RI3: S34's five-anchor policy registry. Selection, search position, and
  browsing top have heterogeneous storage and mutually different policies;
  a registry relocates hand-written policy behind type erasure and loses the
  typed properties whose observers maintain the revision counter and the
  inspection-state cache.

## Implementation discretion

- Shape of the private slot accessor (subscript vs. function pair) and of
  the shared admission/commit helper.
- Whether the duplicate `hoveredLink`/`armedLink` computed properties and the
  two byte-cost summations consolidate onto the same slot path.

## Verification

1. Pin tests first:
   `swift test --package-path lib/TerminalCore --filter TerminalHyperlinkInteractionTests`
   -- all pass before any production edit.
2. After the refactor, targeted:
   `swift test --package-path lib/TerminalCore --filter "TerminalHyperlinkInteractionTests|TerminalInteractionPolicyTests|TerminalASCIIRunTests|TerminalHistoryGenerationTests|TerminalBatchRegressionTests"`
3. Full package: `swift test --package-path lib/TerminalCore`
4. Local gate: `just test` (covers the external callers in TerminalPTY and
   render planning).
