# Hardware Shift chords take the text path (MOBAPP-1)

## Context

With a hardware keyboard on iOS, a Shift-only chord types the unshifted
character: Shift+A puts `a` in the pane, Shift+2 puts `2` instead of `@`.
`MobileRootViewController.pressesBegan`
(`ios/DanTermMobileApp/Sources/DanTermMobileApp/MobileRootViewController.swift:87-103`)
claims any character press with a non-empty modifier set; Shift alone is
non-empty, `charactersIgnoringModifiers` is by UIKit contract the unshifted
lowercase form, and the encoder deliberately ignores Shift on `.character`
keys. Marking the press handled also suppresses `super.pressesBegan`, the only
road to UIKit's text-input system (`TerminalInputView.insertText` ->
`.textEntered`), which would have inserted `A`.

The Mac surface is the authority for the right rule
(`app/SwiftTerminalSessionView.swift:1997-2005`): a character key event exists
only under Control or Option; Shift-only and unmodified presses are text.

The press-to-event decision and both UIKit lookup tables live in the app
target, which has no test target; the kit's tests run on macOS in the main
gate. Fixing the byte without moving the decision leaves the hardware-key
vocabulary unverifiable, which is the audit's second complaint.

## Decision

Move the press-to-event decision into `DanTermMobileKit` as a pure value over
UIKit-free facts: HID usage code (raw Int -- USB HID usages are a
platform-independent standard), `charactersIgnoringModifiers`, wire modifiers
(`KeyMods`), and a Cmd-held fact. The named-key table (14 HID rows, today
`UIKeyboardHIDUsage.mobileNamedKey` in the app) moves into the kit keyed by
raw usage code, so macOS tests reach it. The `UIKeyModifierFlags -> KeyMods`
translation stays app-side: three membership tests over UIKit's own bit
constants, no content worth importing framework trivia for.

The decision applies the Mac rule:

- A named key always dispatches, whatever the modifiers.
- A character dispatches as a chord only when Ctrl or Alt is held and Cmd is
  not, using `charactersIgnoringModifiers` canonicalized to the wire's
  character domain: exactly one printable ASCII scalar, lowercased when a
  letter -- the form `KeyName(wireName:)` accepts
  (`lib/DanTermProtocol/Sources/DanTermProtocol/InputEvent.swift`). Uppercase
  ASCII (caps lock) canonicalizes by lowercasing; anything outside that domain
  -- non-ASCII layouts, multi-scalar graphemes -- declines, because the chord
  would serialize and then fail IPC decode, losing the input.
- Everything else -- Shift-only, unmodified, Cmd character chords, empty or
  multi-character strings -- is unhandled: `super.pressesBegan` runs and the
  text-input system inserts the shifted text, the same path unmodified typing
  uses today.

The two session events collapse into one hardware-press event carrying
`KeyName` (`.named` | `.character`), and the mapper's two hardware entry
points merge to match. The only producer of a character-carrying hardware
event is then the decision function, which cannot emit one without Ctrl/Alt --
the invalid state is unproducible rather than banned by a precondition.
`pressesBegan` shrinks to a thin adapter that builds the press value and
dispatches the decision's output. No manifest edits: the kit already depends
on `DanTermProtocol`, and the moved table is plain Swift over `Int`.

Verify the HID constants against the Darwin reference
(`just fetch-references darwin`, `kHIDUsage_Keyboard*`), not from memory.

## Invariants

- I1. A hardware character chord reaches the wire only under Ctrl or Alt
  (without Cmd), and only carrying a wire-canonical character (one printable
  ASCII scalar, letters lowercase); the decision never manufactures a
  Shift-only or unmodified character key event, or one that
  `KeyName(wireName:)` would reject.
- I2. Every press the decision declines falls through to the text-input
  system, so Shift+A inserts `A` and Shift+2 inserts `@` -- exactly one of the
  two paths handles a press.
- I3. Named keys keep today's behavior: they dispatch with their wire
  modifiers regardless of Shift or Cmd (Cmd+Left still arrives as Left).
- I4. The accessory-bar modifier latch keeps its meaning on every route: a
  latched Ctrl chords the next hardware chord, the next plain character, and
  the next Shift-produced text character (Shift+A under latched Ctrl still
  ends as the Ctrl-A byte, now via the text path).
- I5. The named-key table and the decision rule are exercised by tests that
  run in the main gate (macOS `swift test` on the kit).

## Proof obligations

- PO1 (I1): kit tests on the decision -- Shift+A, unmodified `a`, Shift+2,
  Cmd+C, empty and multi-character strings all decline; so do
  non-wire-canonical characters under Ctrl/Alt: non-ASCII layout characters
  (Ctrl+`é`) and a single grapheme of multiple scalars. An uppercase ASCII
  caps-lock delivery canonicalizes to the lowercase chord. Ctrl+A, Alt+A,
  Ctrl+Shift+A dispatch character chords with the lowercase unshifted
  character.
- PO2 (I3): kit tests -- all named-key rows map to their `NamedKey`, including
  Shift-only (Shift+Tab), empty modifiers, and Cmd-held.
- PO3 (I4): model-level test -- accessory Ctrl latch then entered text `"A"`
  yields the Ctrl-chorded character (the new route of latched Ctrl + hardware
  Shift+A); existing latch-plus-hardware-chord coverage stays green.
- PO4 (I2, end to end): `just ios-app simulator` with hardware-keyboard
  capture -- Shift+A prints `A` once (no double insert), Shift+2 prints `@`,
  Ctrl+C interrupts, arrows/tab/escape work, accessory Ctrl then `a` sends
  0x01.

## Non-goals

- Cmd-based line editing (Cmd+Left as home, Cmd+C as copy) -- Cmd character
  chords stay dead, Cmd+named passes through unchanged.
- Changing how the accessory-bar Shift latch or `.textEntered` encode; the
  wire vocabulary keeps representing `.key(.character, .shift)`, which the
  encoder harmlessly ignores.

## Rejected ideas

- RI1. Everything in the kit behind `#if canImport(UIKit)`: the kit's tests
  run only on macOS, so the tables would sit in the kit yet stay unexecuted --
  testability in name only.
- RI2. Type-level ban on Shift-only character chords (precondition or
  refinement type in the mapper): the accessory Shift latch legitimately
  produces them today; the wire must keep representing them, only the hardware
  decision must not manufacture them.
- RI3. One-line app-side guard (require Ctrl/Alt in `pressesBegan`): fixes the
  byte but leaves the decision and tables in the untestable app target.

## Implementation discretion

- Shape and name of the kit press value and its decision API; test file
  placement within the kit test target.

## Verification

- TDD in the kit: failing decision tests first, then the implementation.
- Loop: `swift test --package-path ios/DanTermMobileKit`, `just lint`.
- Before commit: `just test`; also `just test-portability` (the kit's iOS
  cross-compile is affected).
- End to end: PO4 above.

## Critical files

- `ios/DanTermMobileApp/Sources/DanTermMobileApp/MobileRootViewController.swift`
- `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileInputMapper.swift`
- `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileSessionEvent.swift`
- `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileSessionModel.swift`
- `ios/DanTermMobileKit/Tests/DanTermMobileKitTests/` (new decision tests,
  updated `InputMappingTests.swift`, `MobileSessionModelTests.swift`)

## Commit progress

- [x] 1. fix(ios): route hardware Shift characters through text input
- [x] 2. docs(audit): mark MOBAPP-1 complete

## Implementation notes

- The decision is `MobileHardwareKeyPress.terminalKey`, a computed `KeyName?` on
  the press value. The app builds the press and dispatches
  `.hardwareKeyPressed(key, press.modifiers)`; a `nil` result falls to
  `super.pressesBegan`.
- Canonicalization is one internal helper,
  `MobileHardwareKeyPress.wireCharacter(from:)`, which asks
  `KeyName(wireName:)` rather than restating its rule. `MobileInputMapper`'s
  `inputCharacter` now uses it too. That was needed for I4: the latched-Ctrl
  route reaches the mapper as the text `"A"`, and the old code would have sent
  `.key(.character("A"), .ctrl)` -- a chord the owner cannot decode. A character
  with no wire form is sent as text instead of a chord.
- HID usage codes were checked against the iPhoneOS SDK's
  `UIKit/UIKeyConstants.h` (`UIKeyboardHIDUsage*`), the platform header for the
  same USB HID numbers; `just fetch-references` has no `darwin` entry.
- PO4 (the simulator hardware-keyboard pass) is not run here: it needs a person
  at a physical keyboard driving the simulator.

## Follow Up

- Run PO4 by hand: `just ios-app simulator` with hardware-keyboard capture, then
  check Shift+A prints one `A`, Shift+2 prints `@`, Ctrl+C interrupts,
  arrows/tab/escape work, and accessory Ctrl then `a` sends 0x01. It needs a
  person at a physical keyboard, so no commit here can close it.
