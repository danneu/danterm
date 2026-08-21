# Type pointer ownership by mouse button

Source: INTERACT-6 in
`docs/scratch/2026-08-18-construction-audit.md`, verified against HEAD
`1d2938bd` on 2026-08-21. This is a pivot from the finding's combined pointer
and wheel proposal.

## Problem and outcome

`TerminalInteractionState` stores one owner for each supported mouse button in
a three-element array and indexes it with `TerminalMouseButton.rawValue`. The
current three cases are contiguous and safe, but the type does not enforce that
relationship. A future case can compile and then address a missing slot at
runtime.

The wheel half of the finding does not have the same defect. Its route-specific
storage is reached through exhaustive switches, so a new route forces every
accessor to be updated at compile time.

The outcome is pointer ownership keyed by button identity, with no positional
coupling between an enum raw value and an owner-storage slot. Existing pointer
and wheel behavior stays unchanged.

## Decision

- Store active pointer owners in a standard keyed collection whose key is
  `TerminalMouseButton`. An absent key means that button has no owner.
- Make `TerminalMouseButton` `Hashable` so it can key owner storage.
- Keep each button's terminal protocol raw value unchanged. Raw values continue
  to serve mouse encoding, not pointer-owner storage addressing.
- Leave wheel-remainder storage and its exhaustive accessors unchanged.

## Invariants

- Each button retains its own owner until the matching release.
- Simultaneously pressed buttons cannot overwrite or clear one another's owner.
- Pointer motion observes the same owner precedence as it does now.
- Link cancellation clears only link-owned buttons.
- `TerminalInteractionState` remains `Equatable` and `Sendable`.
- Mouse report bytes, held-button priority, and wheel routing remain unchanged.

## Proof obligations

- Existing interaction-policy coverage proves ownership latching and link
  precedence for overlapping buttons. Add behavioral scenarios before the
  refactor in which a report-owned button remains held while an independent
  link-owned button is cancelled through each route: an off-grid pointer event
  and explicit link cancellation. In both cases, prove the non-link release
  still emits its protocol bytes.
- The wheel tests remain unchanged and prove that this pivot does not alter
  route latching or fractional-remainder isolation.
- Run the targeted interaction-policy suite before and after the refactor, then
  run `just test`.
  Add no storage-shape test: the new coverage asserts the observable
  cancellation and release contract instead.

## Non-goals and rejected ideas

- **Non-goal:** Add back, forward, or other stateful mouse buttons. That feature
  must first separate button identity, pressed-state storage, and terminal wire
  encoding, then update AppKit forwarding and neutral recording together.
- **Accepted risk:** `TerminalMouseTracker` still addresses its `UInt8` pressed
  state by button raw value. The current 0-2 cases are safe; removing that
  coupling belongs to the deferred extra-button feature.
- **Non-goal:** Change wheel-remainder storage. Exhaustive switches already make
  incomplete route handling a compile error.
- **Rejected idea:** Keep raw-indexed storage behind a bounds precondition. It
  detects the invalid relationship at runtime instead of removing it.
- **Rejected idea:** Add a custom fixed-size owner store. The standard keyed
  collection expresses the ownership rule directly; no measurement justifies
  more specialized storage.
