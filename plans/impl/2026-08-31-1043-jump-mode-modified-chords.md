# Jump mode: stop swallowing modified chords, drop the dead flagsChanged case

Source finding: INPUT-7 in `docs/scratch/2026-08-26-improvement-audit.md`
(verified live against master c6859367).

## Problem

While tab jump mode is active, the local NSEvent monitor
(`app/AppRuntime.swift`, `installSwitcherEventMonitor`) classifies every
`keyDown` by `charactersIgnoringModifiers` alone. A local monitor sees the
event before menu key-equivalent dispatch, so `Cmd+Q`, `Cmd+W`, or any other
modified chord with a printable base character is consumed as a jump label and
the real command never runs.

In the same handler, the `.flagsChanged` arm calls `classifyJumpInput` and
discards the answer, because `JumpInputKind.flagsChanged` can only ever return
`.passthrough` -- a case that exists solely to be ignored.

A third, quieter defect: `JumpAction.cancel` is interpreted differently by its
two callers -- the keyDown arm consumes the event, the mouse arm passes it
through -- so the consume decision lives in the AppKit handler, not the pure
classifier that exists to hold it.

## Decision

Give `classifyJumpInput` the modifiers and let the pure classifier own the
whole answer, including whether the event is consumed. Delete
`JumpInputKind.flagsChanged` and the monitor arm that feeds it. This is the
finding's ideal fix, with two refinements:

- A modified chord cancels jump mode *and* passes the event through
  (user-confirmed), matching the existing mouse-click precedent
  (`handleJumpModeMouseDown`) rather than the audit body's plain passthrough
  -- the key map is frozen at activation, so letting a close command run while
  jump mode stays up would leave stale labels.
- Exception: any of the jump command's effective chords (default
  `Cmd+Shift+F`; every chord in the effective `tab.jump` binding list, since
  secondary chords stay live as hidden menu items) cancels and is *consumed*,
  making the command a toggle. Passing it through cannot work: the monitor's
  cancel lands synchronously before AppKit dispatches the menu action, so
  `jumpToTab` would re-activate an already-nil jump mode and the net state
  would be active, violating I1. The monitor resolves the effective chords
  (`effectiveBindings` + `commandDescriptor(.jump)`) and hands the classifier
  the digested match fact; the reducer stays untouched.

Chord matching gets one canonical seam. The monitor's existing
`event(_:matches:modifiers:)` compares `charactersIgnoringModifiers` against a
menu key-equivalent string, while binding capture derives chords by key code
plus `characters(byApplyingModifiers: [])` (`KeybindingCaptureField.chord(from:)`,
`app/PreferencesPanel.swift`). Two conversions means a chord captured under
one semantics can fail the other (e.g. Ctrl+punctuation), so a second press of
such a jump binding would cancel, pass through, and reactivate -- violating
I1. Fix by construction: one shared NSEvent-to-`KeyChord` conversion, used by
binding capture and by the monitor's matching alike (jump and MRU arms), with
matching done by `KeyChord` equality; the divergent string-comparison matcher
is deleted, not extended.

Scope: `classifyJumpInput` / `JumpInputKind` / `JumpAction` in
`lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift`, the jump-mode arm
and event-to-chord matching of the monitor in `app/AppRuntime.swift`, the
shared conversion's current home in `app/PreferencesPanel.swift`, and tests in
`lib/DanTermCore/Tests/DanTermCoreTests/SwitcherEventTests.swift`. The
held-MRU switcher *classifier* is untouched; the MRU arm's event matching
moves onto the shared conversion.

## Invariants

- I1: A keyDown carrying Command, Control, or Option during jump mode cancels
  jump mode and the event continues to its original target (menus included),
  except a keyDown matching any effective jump-command chord, which cancels
  and is consumed -- so pressing any jump binding (primary or secondary)
  while jump mode is active ends it (toggle), never restarts it.
- I2: A bare printable key during jump mode still commits that character;
  Shift alone does not block a commit (the monitor lowercases, so Shift+A
  commits "a" as today).
- I3: A modifier-only press (flagsChanged) during jump mode is a no-op that
  passes through, and the classifier's input vocabulary cannot express a
  question whose answer the caller must ignore.
- I4: Whether the monitor consumes an event is decided by the classifier, not
  re-interpreted per call site; the mouse-click behavior (cancel + pass
  through) is unchanged.
- I5: Bare Escape, bare non-printing keys, and inactive-mode passthrough
  behave as today. Modified Escape is an ordinary modified chord under I1
  (today it is consumed; that changes).
- I6: One NSEvent-to-`KeyChord` conversion exists; a chord that binding
  capture records is the chord the monitor recognizes for the same physical
  press.

## Proof obligations

Pure tests in `DanTermCoreTests` (SwitcherEventTests.swift):

- PO1 (I1): Cmd, Ctrl, and Opt chords over a printable key classify as
  cancel-with-passthrough, and so does modified Escape when it matches no
  jump chord; a keyDown flagged as matching a jump-command chord -- including
  a secondary configured chord -- classifies as cancel-with-consume.
- PO2 (I2): bare key commits; Shift-only chord commits.
- PO3 (I3): delete the test pinning the dead flagsChanged case along with the
  case itself; the type change makes the obligation structural.
- PO4 (I4): mouse down still classifies as cancel-with-passthrough; a bare
  non-printing key still cancels while consuming.
- PO5 (I5): existing bare-escape / inactive tests keep passing.
- PO6 (I6): capture-to-match round trip -- the chord derived from a
  Ctrl+punctuation key event (the case where the two old conversions
  diverged) matches itself through the monitor's matching path. Lives
  wherever NSEvent construction is testable (`just test-ui` if it needs a
  WindowServer); placement is discretion, the round-trip claim is not.

I1's end-to-end half (local monitor ordering vs. menu dispatch) rests on
AppKit and is not unit-testable; covered by the manual steps under
Verification.

## Non-goals

- No change to the held-MRU switcher classifier (`classifySwitcherInput`) or
  its observable stepping/commit behavior; only its event-to-chord matching
  moves onto the shared conversion.
- No change to which characters are valid jump labels.

## Implementation discretion

- The shape of the consume distinction on `JumpAction` (associated value vs.
  separate cases).

## Verification

- `swift test --package-path lib/DanTermCore --filter SwitcherEventTests`
- `just lint`, then `just test` before commit.
- Manual: `just launch-slot`, enter jump mode, press Cmd+Shift+W (Close Tab)
  -> tab closes, jump labels gone; enter jump mode, press Cmd+Shift+F again
  -> jump mode ends and does not restart; press a bare label key -> jumps as
  before.

## Commit progress

- [x] 1. refactor(input): unify configurable chord recognition
- [ ] 2. fix(jump): pass modified chords through jump mode
- [ ] 3. docs(audit): mark INPUT-7 complete
