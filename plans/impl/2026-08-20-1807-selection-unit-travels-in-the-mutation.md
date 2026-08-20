# Selection granularity travels inside the mutation, and one applier consumes the decision

Source: INTERACT-4 in `docs/scratch/2026-08-18-construction-audit.md`, pivoted
after verification against the current tree.

## 1. Problem, evidence, premises

`TerminalPointerDecision` (`lib/TerminalCore/Sources/TerminalCore/TerminalInteractionPolicy.swift`)
reports a selection as two parallel optionals, `selectionMutation` and
`selectionGranularity`, that must agree. Nothing enforces the pairing:

- Every `.set` producer spells its predicate twice (`pointerDownDecision`,
  `extensionDecision`, both `.move` arms of `decideTerminalPointer`).
- Every consumer re-derives the pair with `?? .character`: the PTY host
  (`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#applyPointer`)
  and the recording replay
  (`lib/TerminalCore/Sources/TerminalCoreRecording/NeutralTerminalRecording.swift#applyNeutralTerminalMouse`).
  A wrong settled granularity is what the next Shift-click inherits, so the
  default would extend by the wrong unit.
- The consumers are the symptom of a larger copy: the "apply a decision's
  terminal-local effects" switches (selection, hover, arm) exist three times --
  host, replay, and a test-local helper in
  `lib/TerminalCore/Tests/TerminalCoreTests/TerminalInteractionPolicyTests.swift`.
  Policy tests that apply a decision's range by hand already drop the
  granularity (`heldDragSelectionNeverFlickersAcrossRepaints`, the WezTerm
  drag helper in `TerminalWezTermAdaptedTests.swift`). Replay-equals-host
  (`TerminalPTYHostTests.capturedShiftSelectionReplays`) holds today only
  because two hand-copied switches happen to match.

Premises checked: every `.set` producer in the tree pairs a correct granularity
(latent, not live); recordings store neutral mouse events, not decisions, so no
fixture changes; no reader of the decision outside `lib/` (app, cli, ios, tools
have none); the design doc pins no decision shape.

## 2. Decision

D1. `TerminalSelectionMutation.set` carries its granularity as payload; the
decision has no separate granularity field. A set-without-unit and a
clear-with-unit become unrepresentable.

D2. `TerminalCore` owns one public applier for a pointer decision's
terminal-local effects (selection, hover, arm) and for a link cancellation's.
The PTY host, the recording replay, and the tests apply decisions through it.
The host keeps only host-owned effects around it: flight-tape record, byte
submission, selection-completed relay, publish, open-link.

Scope: `lib/TerminalCore` (policy, recording target, tests) and `lib/TerminalPTY`
(host). No behavior change for a user; the observable contract is unchanged and
the representable-but-unreached states go away.

## 3. Invariants

I1. A settled selection carries the unit the policy computed for it: a
double-click settles `.terminalToken`, a triple-click `.line`, a character
drag `.character`; the unit survives into the later Shift-extension.

I2. The recording replay and the live host apply the same decision to the
same `Terminal` identically -- replay of a captured pointer stream equals the
host's snapshot, selection unit included.

I3. No consumer of a pointer decision -- production or test -- supplies a
selection unit the decision did not name.

## 4. Proof obligations

PO1 (I1). Through the applier in `TerminalCore`: a double-click decision
applied to a terminal settles `.terminalToken`; a following Shift-click-further
decision applied the same way keeps `.terminalToken` and extends by token. This
is the first failing test -- the applier is new API. Existing
`shiftExtensionInheritsTokenGranularity` / `...TrimmedLineGranularity` and the
`terminal.selectionGranularity` asserts in `TerminalSelectionTests` keep
passing.

PO2 (I2). `TerminalPTYHostTests.capturedShiftSelectionReplays` passes unchanged
before and after -- it is the characterization test for both consumers at once.
`TerminalFixtureTests` and `RenderCorpusPlanningTests` (recorded mouse through
the replay path) pass unchanged.

PO3 (I3). The `?? .character` sites and the test-local apply helpers are gone;
policy tests that apply a decision do so through the applier (the hand-applied
`setSelection(range)` in `heldDragSelectionNeverFlickersAcrossRepaints` and the
WezTerm drag helper included). Tests that *seed* a settled selection before
driving the policy may still call `Terminal.setSelection` directly.

Mechanical fallout, not proof: the `.set(...)` literals and patterns in
`TerminalInteractionPolicyTests.swift` (~45), `TerminalSelectionUnitTests.swift`
(1), `TerminalWezTermAdaptedTests.swift` (1) gain the unit; `expectedMutations`
in the `selectionGranularity` test writes each unit out.

Gate: `swift test --package-path lib/TerminalCore` and
`swift test --package-path lib/TerminalPTY`; `just test` before commit.

## 5. Non-goals / accepted risks / rejected ideas

Non-goals:
- Recording a link-cancellation event in the flight tape; replay handles only
  what the tape carries.
- Removing `Terminal.setSelection(_:)` (the `.character` convenience); it seeds
  settled state in tests and is not a decision consumer.
- INTERACT-6 (pointer-owner storage) -- same file, different lines; either order.

Accepted risks:
- AR1. `TerminalSelectionMutation` is public across the package boundary, so
  both packages must build; one commit carries policy, host, replay, and tests.

Rejected ideas:
- RI1. Enum payload change alone (the audit's fix). Leaves three hand-copied
  apply switches, which is where the next `??` default gets written, and leaves
  the test corpus dropping granularity when it applies decisions by hand.

## 6. Implementation discretion

- Whether the applier is a `mutating` method on `Terminal` or a free function
  in `TerminalCore`, and whether decision and cancellation share one entry
  point or two.
- A test-local helper for writing `.set(range, granularity:)` literals.

## Implementation notes

- The applier is two free functions in a new
  `lib/TerminalCore/Sources/TerminalCore/TerminalInteractionApply.swift`, not methods on
  `Terminal`. Free functions match the shape the other cross-package entry point
  (`applyNeutralTerminalMouse`) already uses, and keeping them out of `Terminal.swift` keeps
  policy consumption separate from grid state. Two entry points rather than one, because a
  link cancellation has no selection half and a shared entry point would need an optional.
- In the PTY host, the completed-selection relay now runs after hover and arm are applied
  instead of between selection and hover. It reads only `terminal.selectedText`, which neither
  link mutation touches, so the order is unobservable.
- The test-local `apply(_ mutation:to:)` arm helper is gone. Its eleven call sites now apply the
  whole decision through `applyTerminalPointerDecision`, which also settles hover -- closer to
  what the host does, and it removes the last hand-copied apply switch.
- The `.set` literals in the policy tests name a unit that the policy computes from click count,
  so a wrong literal fails the test rather than passing silently. Every one of the 43 rewritten
  assertions was confirmed by a green run.
- Non-goal held: sites that call `Terminal.setSelection(_:)` on a throwaway copy only to read
  `selectedText` back keep doing so. They pass a literal range rather than consuming a decision.
