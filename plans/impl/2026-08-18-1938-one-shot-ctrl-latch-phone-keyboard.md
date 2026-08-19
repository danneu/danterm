# One-shot Ctrl latch for the phone keyboard

## Problem

On iOS, tapping the accessory row's Ctrl key latches a modifier, but typing a
letter on the software keyboard then sends the plain letter: the latch is read
only by the accessory row (`MobileInputMapper.accessory(_:)`), and `text(_:)`,
`deleteBackward()`, and the hardware paths never consult it. So Ctrl-F to accept
a fish suggestion is unreachable from the virtual keyboard. Termius and its
peers treat the latched Ctrl as a one-shot modifier applied to the next key.

Desired outcome: latch Ctrl, press `f`, and the pane receives the Ctrl-F chord;
the latch and its button highlight then clear.

## Decision

The Ctrl latch becomes a one-shot modifier owned by `MobileInputMapper`: it
applies to the next key-shaped input from any source and is consumed by it.
User decisions already made: one-shot everywhere (accessory keys lose today's
sticky behavior), and backspace participates.

The Ctrl button's highlight is rendered from the session projection on the
redraw path, like every other session fact the bar shows. The tap-return
channel (`onAccessoryKey`'s Bool answer) that currently carries the latch to
the button goes away; the bar keeps holding no session fact of its own.

Encoding stays owner-side: the client still emits `InputEvent` intent
(`.key(.character(c), .ctrl)`), never terminal bytes.

## Invariants

- I1: With the latch armed, a single-character keyboard commit reaches the wire
  as a Ctrl character chord, not text.
- I2: With the latch armed, backspace reaches the wire as bspace with Ctrl.
- I3: With the latch armed, an accessory key or a hardware key event carries
  Ctrl in addition to its own modifiers.
- I4: Every input covered by I1-I3 clears the latch; a multi-character commit
  (autocorrect, dictation, IME) and a paste send their text unchanged and also
  clear it, so a stale latch can never chord a later keystroke.
- I5: With the latch off, every path behaves exactly as today.
- I6: Whenever an input changes the latch, the model emits a redraw, and the
  Ctrl button's highlight always shows the projection's latch state -- including
  after a consuming input that is not a Ctrl tap.

## Proof obligations

- PO1 (I1-I5): mapper-level tests in
  `ios/DanTermMobileKit/Tests/DanTermMobileKitTests/InputMappingTests.swift`,
  extending the existing latch cases; the current sticky-latch expectations in
  `accessoryRowMapping` are updated to one-shot.
- PO2 (I5, I6): model-level tests covering every latch-consuming event
  category -- text, paste, backspace, accessory key, hardware named key,
  hardware character. Each armed case asserts the outgoing intent, the cleared
  projection latch, and the redraw effect; each unarmed counterpart asserts
  today's intent and redraw behavior are unchanged.
- Manual: run the iOS app against a Mac instance, type a partial command in
  fish, tap Ctrl, tap `f`, and see the suggestion accepted with the Ctrl
  button unlit afterward.

## Non-goals

- No client-side byte encoding; the owner keeps encoding chords.
- No additional latches (Alt, Shift) and no long-press-to-lock behavior.
- No change to the accessory row's set of keys.

## Implementation discretion

- How the redraw path carries the latch to the button (a bar setter in the
  existing redraw hook vs. reconfiguring in place), provided the bar stores no
  session fact.

## Critical files

- `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileInputMapper.swift`
- `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileSessionModel.swift`
- `ios/DanTermMobileApp/Sources/DanTermMobileApp/MobileRootViewController.swift`
- `ios/DanTermMobileApp/Sources/DanTermMobileApp/TerminalBottomBarView.swift`
- `ios/DanTermMobileKit/Tests/DanTermMobileKitTests/InputMappingTests.swift`

## Verification

- `swift test --package-path ios/DanTermMobileKit` (TDD: new tests first, watch
  them fail for the expected reason).
- Manual live check per the fish Ctrl-F scenario on device or simulator.

## Implementation notes

- The scroll entry points do not consume the latch: they are not key-shaped
  input, so an armed Ctrl survives a scroll and chords the next key, per the
  Decision's "next key-shaped input" wording.
- An accessory tap keeps its unconditional redraw. I5 pins today's behavior for
  unarmed paths, and today every accessory tap redraws; armed taps are covered
  by the same unconditional redraw, so `accessoryKeyPressed` stays outside the
  latch-change redraw helper.

## Follow Up

- Run the plan's manual live check: iOS app against a Mac instance, partial
  command in fish, tap Ctrl then `f`, confirm the suggestion is accepted and
  the Ctrl key unlights. This session had no device/simulator user to drive
  the tap sequence.
