# One record of which button a forwarded press was reported as (PANE-3)

Source: `docs/scratch/2026-08-18-construction-audit.md` PANE-3. INTERACT-2
(`f6d6435f..c854be73`) has landed, so the C8 ordering is satisfied.

## 1. Problem

`app/SwiftTerminalSessionView.swift` encodes "this physical button has a
forwarded press outstanding, reported to the engine as button X" three
different ways:

- `controlClickIsActive` -- left physical button; remembers only whether the
  press was reported as `.right` (control-click). `mouseUp` forwards a release
  unconditionally.
- `rightButtonForwarded` -- right physical button; remembers only that the
  press was claimed. It is set *before* `forwardPointerDown`, so despite its
  name it does not record that the press reached the controller.
- Middle -- nothing.

`forwardPointerDown` drops a press when the view has no resolved geometry yet
(`normalizedCell` is nil before the first layout pass), but each release path
still forwards. So a release can reach the controller for a press the engine
never saw, and the three encodings admit states no gesture can be in.

**Load-bearing premises (checked against the tree):**

- P1. The engine already ignores an ownerless release: `decideTerminalPointer`
  `.up` with no owner yields `.ignored` and `encodeTerminalMouse` `.up` returns
  no bytes for an unpressed button. The only observable effect of the stray
  release today is an unpaired `.up` on the flight tape (and its replica
  replay). This is a structure and tape-honesty fix, not an engine bug.
- P2. `displayedCellSize` is assigned once geometry resolves and is never
  reset, so "press forwarded, release dropped" is unreachable from the view;
  "press dropped, release forwarded" (first click before layout) is the
  reachable case.
- P3. The comment on `rightButtonForwarded` attributes to an unpaired
  *release* a hazard (latching the engine's button owner) that belongs only to
  an unpaired *press*. The fix corrects the comment.

## 2. Decision

Replace both booleans with one per-physical-button record of the reported
`TerminalMouseButton`, written by `forwardPointerDown` only when the press
actually reached the controller, and consumed by `forwardPointerUp` to decide
both whether to send a release and which button it names. The three
`*MouseUp` overrides then share one release path and pass no button of their
own.

Per physical button, not one optional: AppKit can deliver a left press and a
right press before the left release, and one slot would let the second press
overwrite the first record.

Scope: `app/SwiftTerminalSessionView.swift` only. No engine, protocol, tape,
or shim change.

## 3. Invariants

- I1. A release reaches the controller only for a press that reached the
  controller from the same physical button.
- I2. A release names the button its press was reported as, even when the
  modifier that chose that button (Control) was released mid-click.
- I3. Distinct physical buttons pressed together pair independently: each
  release names its own press's reported button, in the order released.
- I4. `.clickedToFocus` on a left press stays ungated by the forward: a click
  whose press is dropped for lack of geometry still names its pane (existing
  behavior, preserved).
- I5. A menu-owned right press (unclaimed) still forwards nothing, and a
  claimed one still forwards its down and up as a pair (existing behavior,
  preserved).

## 4. Proof obligations

UI harness, `tests-ui/SwiftTerminalSessionViewTests.swift`; the shim
controller already records `pointerEvents` and exposes `claimsMouseButtons`.
An unmounted `SwiftTerminalSessionView(controller:)` has no geometry;
`makeMountedPane` / `mountInTestWindow` resolves it.

- PO1 (I1, I4). Press before geometry, then mount, then release: no pointer
  event reaches the controller; the left case still reports `.clickedToFocus`.
  Cover all three physical buttons -- left, a claimed right press (right
  presses in the harness must be claimed -- an unclaimed one pops a real
  AppKit menu, see the disabled tests near line 1166), and middle. Middle is
  required, not optional: it enters through the separate `otherMouseDown` /
  `otherMouseUp` overrides behind a `buttonNumber == 2` guard, so left and
  right coverage cannot show that path pairs its press and release.
- PO2 (I2). Claimed control-press with Control, release without Control: the
  controller sees `.down(.right, ...)` then `.up(.right, ...)`.
- PO3 (I3). Left down, claimed right down, left up, right up: events name
  `.left, .right, .left, .right`.
- PO4 (I5). Existing tests keep passing unchanged: "pointer callbacks
  normalize cells buttons modifiers and click counts", "an unclaimed
  control-click both focuses the pane and offers the menu", "only a click
  that takes key focus reports pane focus", the Cmd-click link tests.

Run: `just test-ui > .build/ui.log 2>&1`, then grep the log.

## 5. Non-goals / Accepted risks

- Non-goal: changing how the engine treats an unpaired press or release
  (INTERACT-6 and the policy are untouched).
- Non-goal: re-enabling the two disabled right-button tests; that waits on
  the pane menu being presented by its owner.
- AR1. Two physical buttons both reported as `.right` (control-left plus
  claimed right) still share one engine owner slot; pre-existing and out of
  scope.

## 6. Implementation discretion

- Key of the record (AppKit `buttonNumber` vs. the entry point's own
  physical-button enum) and its container type.
- How the middle-button events in PO1 are synthesized: `NSEvent.mouseEvent(with:
  .otherMouseDown ...)` does not carry button number 2, so the case needs a
  CGEvent-backed event (the wheel-event helper in the same file is precedent).

## Implementation notes

- The record is keyed by a private `PhysicalPointerButton` enum nested in the
  view, not by AppKit's `buttonNumber`: only three physical buttons ever reach
  these entry points, and each entry point already knows which one it is, so a
  raw number would be a wider key than the code can produce.
- `forwardPointerUp` consumes the record before the teardown and geometry
  guards. A torn-down or geometry-less pane therefore forgets the press rather
  than keeping it outstanding, which is the safer of the two: the release the
  view could not send will never arrive a second time.
- PO1 gained a companion test, "the middle button forwards its press and
  release as a pair". PO1's middle arm proves only that nothing is sent; on its
  own it would also pass if the middle path forwarded nothing at all, so the
  positive pair pins what the empty result means.
- The middle-button events need a CGEvent, and a source-less CGEvent is created
  carrying the modifier keys physically held at that moment and a location in
  the primary display's top-left origin space. The test helper states the flags
  and undoes the flip; without the flags line the test read the keyboard of
  whoever was at the machine while the suite ran, which a negative-control run
  caught.
