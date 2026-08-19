# Carry measured insideness in the pointer event (INTERACT-2)

## Context

`terminalCell(at:)` measures whether a pointer's raw point fell inside the
grid and returns it as `TerminalViewportCell.isInsideGrid`. But
`TerminalPointerEvent` carries only loose `column`/`row`/`offsetX` scalars,
so `app/SwiftTerminalSessionView.swift` drops the bit at the event boundary
and compensates with a second, separately ordered
`controller.cancelLinkInteraction()` message: send-then-cancel on down,
cancel-then-send on up, send-then-cancel on move, each held together by a
hand-written ordering comment and one UI test. Meanwhile the policy
re-derives insideness via `isViewportPosition` over coordinates that
`terminalCell` already clamped into range, so that guard can never reject a
live off-grid pointer.

The recording layer has the same hole one layer out:
`NeutralTerminalMouseEvent` carries no insideness, and
`ios/.../PaneReplica.swift#applyEvent` feeds tape mouse events straight into
`applyNeutralTerminalMouse`, which mutates the replica terminal's hover and
arm state. An off-grid Cmd-press that arms nothing on the Mac replays on the
phone as an on-grid press and arms a link the pane never armed. No test can
catch that today because the fact the assertion needs was never recorded.

This is audit item INTERACT-2
(docs/scratch/2026-08-18-construction-audit.md), with its Correction,
Sharper ideal, and decide-first decision (recorded insideness on the tape)
already adjudicated there. It is a hard prerequisite of PTY-3
(plans/wip/plan-the-ideal-fix-async-parasol.md), which needs the neutral
mouse record to be lossless before it unifies the capture buffers, and
constraint C8 orders it before PANE-3.

Supersession: plans/impl/2026-08-18-1059-cell-insideness-and-swapchain-inputs.md
invariant I2 states the two-message ordering rule this change deletes. I2 was
the correct rule for a two-message design; this change removes the second
message, so the outcome I2 protected now falls out of one decision. That
plan's I1 -- insideness is read at ask time, never stored from an earlier
event -- survives: the cell travels inside one event, which is not storage.

Verified against the current tree (after `a0ce2d8f`): the event shape, the
three ordered cancels, the four `isViewportPosition` call sites, and the
insideness-free `NeutralTerminalMouseEvent` are all still as the audit
describes. One thing moved: `a0ce2d8f` deleted the policy-minted
`paneMenuCell`, so `terminalCell` is now the only production producer of
`TerminalViewportCell` -- after this change every production cell is either
measured or decoded from a recorded measurement.

## Decision

- All three `TerminalPointerEvent` cases carry the `TerminalViewportCell`
  whole, in place of the loose `column`/`row`/`offsetX` scalars. `.up`
  included, even though it never reads `offsetX`: one shape for all three
  cases is what keeps coordinates and measured insideness from separating
  again.
- `decideTerminalPointer` treats an event as off-grid for link purposes when
  either test fails: the cell's measured `isInsideGrid`, or
  `isViewportPosition` against the current geometry. These are two different
  facts -- "the point was on the grid the view measured" and "these
  coordinates address this terminal" -- and the policy needs both.
  `isViewportPosition` stays: a tape replayed at a different geometry
  supplies genuinely out-of-range coordinates
  (`TerminalWezTermAdaptedTests#characterDragSnapsWideCellsAndClampsOutOfBounds`
  documents that an unclamped row there is an out-of-bounds index, not a
  wrong answer).
- Off-grid handling stays scoped to link interaction (arm, hover, open).
  Selection keeps its clamped-edge semantics unchanged.
- The view's three ordered `cancelLinkInteraction()` calls and their
  ordering comments are deleted; the off-grid clears become part of the one
  pointer decision. `cancelTerminalLinkInteraction` survives with exactly
  one production caller, `mouseExited` -- the genuine exit-with-no-event
  case -- and its doc comment says so.
- `NeutralTerminalMouseEvent` gains a recorded `isInsideGrid` (default
  `true`), in the same "recordings captured before this was carried decode
  to the default" style as `offsetX`. Capture records what the view
  measured; replay builds the cell from the recorded bit instead of minting
  an insideness nobody measured. The JSON codec treats the key as optional,
  so old tapes decode as inside.

Rejected (adjudicated in the audit's decision section; restated so review
does not re-raise them):

- **RI1:** replay mints `isInsideGrid: true` and leans on `isViewportPosition`
  alone -- reopens the pane/replica divergence this item exists to close, and
  leaves `isInsideGrid == true` meaning "measured inside" or "nobody
  measured" depending on producer.
- **RI2:** record the raw point and cell size and re-derive insideness at
  replay -- the neutral schema is deliberately geometry-normalized so a tape
  replays at a different grid; carrying point-space breaks that.

## Invariants

- **I1.** An off-grid press, release, or move arms no link, opens no link,
  and clears hover and arm state -- decided inside the single pointer
  decision, with no second cancellation message left to order.
- **I2.** Coordinates that do not address the current terminal geometry are
  off-grid for link purposes regardless of the cell's claimed insideness.
- **I3.** Selection behavior at off-grid coordinates is unchanged: a drag
  leaving the grid still selects out to the edge it left through.
- **I4.** A capture records the insideness the view measured, and a replay
  at matching geometry reproduces the pane's link decision -- a replica
  cannot arm a link the pane never armed. A tape recorded before the field
  existed decodes as inside.
- **I5.** Insideness for hover chrome is still re-derived at ask time
  (surviving I1 of the landed cell-insideness plan): a grid that shrinks
  under a parked pointer drops the hover chrome without a new pointer event.
- **I6.** Leaving the view still clears hover and arm state through the
  surviving `mouseExited` cancel path.

## Proof obligations

- **PO1** (I1, policy level -- the write-first failing test): in
  `TerminalInteractionPolicyTests`, press, move, and release each get a
  measured-off-grid case whose coordinates are in range for the current
  geometry and land on an activatable link, so `isViewportPosition` alone
  cannot make them pass. Each starts from seeded hover and arm state, and
  each asserts the one decision arms nothing, opens nothing, and clears both
  hover and arm state. Fails today because the event cannot carry the bit and
  `isViewportPosition` accepts the clamped coordinates.
- **PO2** (I1, end to end): the existing tests-ui pin "an off-grid press or
  release cannot open a link" keeps its scenario and both assertions; only
  its Why-it-exists preamble is rewritten, from delivery ordering to the
  one-decision design. Do not delete it -- it is the only end-to-end proof.
- **PO3** (I2): the existing "Cmd moves set hover while release exit and
  out-of-bounds transitions clear it" test keeps asserting the same clears
  when the out-of-range coordinates now travel inside a cell.
- **PO4** (I3): the existing "a drag leaving the grid selects out to the
  edge it left through" test passes with the off-grid cell traveling in the
  event. This is the test that fails if off-grid handling over-reaches
  beyond the link arms.
- **PO5** (I4): capture, codec, and replay each get a proof. Capture: a
  pointer event whose cell reports `isInsideGrid == false`, delivered through
  the session that produces the neutral record, is captured with
  `isInsideGrid == false` -- without this an implementation can add the field
  and still record the default for every live off-grid press. Codec: a
  `NeutralTerminalMouseEvent` round-trip preserves `isInsideGrid`, and the
  existing raw-JSON old-tape decode coverage in
  `NeutralTerminalRecordingTests` gains the missing-key-decodes-inside case.
  Replay: a replayed off-grid Cmd-press over a link at matching geometry arms
  nothing.
- **PO6** (I5): the existing tests-ui pin "a grid that shrinks under a
  parked pointer drops the hover chrome" stays green.
- **PO7** (I6): existing `mouseExited` coverage stays green.

Existing tests that must keep passing untouched beyond mechanical literal
rewrites: the link-ownership suite in `TerminalInteractionPolicyTests`, "a
normalized cell reports whether its point fell inside the grid", "point
normalization floors clamps and rejects degenerate geometry", and the
WezTerm-adapted drag tests.

## Non-goals / accepted risks

- **Non-goal:** any change to selection semantics, wheel events, or the
  mouse-report encoding vocabulary (`TerminalMouseEvent` /
  `encodeTerminalMouse` -- a separate type; its literals in
  `TerminalKeyEncodingTests` are untouched).
- **Non-goal:** PANE-3's rewrite of the view's forwarding functions; it
  lands after this per C8.
- **Non-goal:** fixture regeneration. The only mouse-bearing fixtures are
  two decode-only libvterm tapes; the danterm fixture tree has none, and
  `integrations/danterm/SKILL.md` documents no mouse record keys, so the CLI
  contract needs no edit.
- **Accepted risk:** a tape recorded before the field replays an off-grid
  press as on-grid (it decodes to the `true` default). Scoped to old tapes;
  `isViewportPosition` still rejects coordinates that miss the replay
  geometry.

## Critical files

- `lib/TerminalCore` -- `TerminalInteractionVocabulary.swift` (the event
  enum, and `TerminalViewportCell.isInsideGrid`'s doc comment, whose "minted
  from a policy decision" producer no longer exists) and
  `TerminalInteractionPolicy.swift` (the `isViewportPosition` call sites
  become the two-input predicate; `cancelTerminalLinkInteraction` narrowed).
- `app/SwiftTerminalSessionView.swift` -- the pointer forwarding functions
  lose their cancels; `mouseExited` unchanged.
- `lib/TerminalCore/.../NeutralTerminalRecording.swift` -- the field, the
  codec, and replay.
- `lib/TerminalPTY/.../TerminalPaneSession.swift` -- the capture mapping.
- Mechanical rewrites of pointer-event literals across the test targets. The
  UI harness compiles the real vocabulary file, so there is no shim copy to
  keep in sync.

## Implementation discretion

- How the test targets spell the ~150 rewritten pointer-event literals.

## Verification

- TDD order: PO1 first, verified failing for the stated reason, then the
  vocabulary/policy/view change, then PO5's recording tests with the field.
- `swift test --package-path lib/TerminalCore --filter InteractionPolicy`,
  then the full `lib/TerminalCore` and `lib/TerminalPTY` suites.
- `just test-ui > .build/ui.log 2>&1` for PO2, PO6, and PO7 (needs a GUI
  session; excluded from the gate).
- `just test` for the whole gate.

## Commit progress
- [x] 1. Carry the measured cell in every pointer event and decide off-grid links once
- [x] 2. Record measured insideness on the neutral mouse tape

## Implementation notes

- The single decision is spelled as a wrapper: `decideTerminalPointer` computes
  `onGrid` once from the cell's measured insideness and the geometry test, runs
  the arm that owns the event, and then, when the event is off-grid, overrides
  the result's hover, arm, and open fields and drops link ownership. The arm
  still runs for an off-grid event, which is what keeps selection's clamped-edge
  semantics (I3) intact without a second code path.
- Consequence of I1 that the plan did not spell out: an off-grid Cmd press no
  longer takes the link arm at all, so under mouse tracking it now reports the
  press to the child like any other off-grid press. Before, whether the press
  was swallowed depended on whether a link happened to sit at the clamped cell,
  and the follow-up cancel threw the arm away anyway.
- PO3's test (`commandHoverAndCancellation`) needed one assertion changed
  besides the literal rewrite: the release after an out-of-bounds move is now
  `.ignored` rather than `.link`, because the move gives up link ownership
  inside its own decision. The view's separate cancel already did this in
  production, so the old policy-level expectation described a state the app
  never reached.
- PO5's capture proof rides on the existing controller capture-equality test rather
  than a new test of its own. `capturedRecording` only answers after the child
  session ends, so a dedicated proof would have to spawn and exit a shell to assert
  one recorded bit; that test already spawns one and already sends pointers, so it
  gains one measured-off-grid move and the assertion that the tape kept the bit.
