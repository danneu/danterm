# UTF-8-safe terminal control strings

## Problem and evidence

In the Swift terminal-engine pane, fish reports `UTF-8`, encodes U+2733 as
`e2 9c b3`, and measures it as one visible cell. Writing those bytes directly
renders correctly, but using the literal character in a command can leave
U+FFFD and stale command text on screen.

The configured fish integration emits the command text inside an OSC 0 title
sequence. While absorbing that sequence, DanTerm interprets the U+2733
continuation byte `0x9c` as the 8-bit ST control. It terminates the OSC early,
then parses `0xb3` and the remaining title bytes as terminal input. This
explains both the replacement character and leaked text. It also disproves the
locale and character-width hypotheses for this incident.

## Decision

DanTerm's UTF-8 input mode will treat active control-string payloads as opaque
encoded bytes until an unambiguous 7-bit terminator or cancellation arrives.

- OSC ends on BEL or `ESC \`.
- DCS, APC, PM, and SOS end on `ESC \`.
- CAN and SUB keep their existing cancellation behavior.
- An ESC inside any control string begins terminator-or-restart handling. If
  the next byte is not `\`, the string is cancelled without OSC dispatch and
  the ESC-initiated sequence continues under the existing escape-restart
  behavior.
- Raw C1 bytes `0x80...0x9f`, including `0x9c`, never act as controls while a
  control-string payload is active.
- OSC preserves every non-C0, non-DEL payload byte, including
  `0x80...0x9f`, and counts it against the existing payload limit. Semantic
  consumers retain their field-level validation: invalid OSC 8 URI bytes and
  invalid decoded OSC 52 text apply nothing, while malformed OSC 8 parameter
  bytes may discard the optional ID and still produce an anonymous link for a
  valid URI.

Outside active control strings, existing parsing behavior remains unchanged:
raw C1 input in ground remains malformed UTF-8, 7-bit controls keep their
current meaning, and existing limits and recovery rules remain in force.
Tests and provenance that accidentally promise raw `0x9c` as an 8-bit ST in
UTF-8 mode will be corrected to match this contract.

## Invariants

1. Valid UTF-8 bytes inside a control string cannot trigger a control
   transition, print a glyph, or leak into subsequent terminal input.
2. Supported terminators complete strings, and only successfully terminated
   OSC payloads dispatch. CAN, SUB, and ESC restart cancel without OSC
   dispatch. These outcomes are independent of input chunk boundaries.
3. Oversized payloads remain bounded and do not dispatch. OSC 8 and OSC 52
   retain their existing field-level validation and apply-none boundaries.
4. Raw C1 behavior outside control strings is unchanged.
5. The observed fish workflow renders exactly the program's intended U+2733,
   with no U+FFFD or stale title bytes.

## Proof obligations

1. Add a parser regression for an OSC 0 payload containing the exact U+2733
   bytes. It must preserve the exact payload and print nothing, whether sent as
   one chunk, one byte at a time, or at every split point.
2. Cover printable scalars whose UTF-8 continuation bytes span
   `0x80...0x9f`, including U+0400 through U+041F. Verify exact OSC payloads
   with BEL and `ESC \`, and verify that all five control-string families do
   not exit early on those bytes.
3. For all five control-string families, verify that ESC followed by a byte
   other than `\` cancels without dispatch and resumes the existing escape
   parser behavior. Preserve the OSC and DCS recovery outcomes in the neutral
   parser fixture.
4. Update OSC 8 and OSC 52 terminator coverage so BEL and `ESC \` are the
   supported endings and raw `0x9c` is payload, not ST. Preserve OSC 8's
   anonymous-link result for malformed parameter bytes with a valid URI, its
   apply-none result for invalid URI bytes, and OSC 52's apply-none result for
   invalid decoded text. Preserve coverage for ground-state malformed C1
   input, payload limits, cancellation, and recovery.
5. Add a DanTerm-owned neutral recording that models the configured fish title
   hook, command execution, program output, and following prompt. Replay it as
   authored, bytewise, and across split points; the grid must contain exactly
   the intended U+2733 output with no U+FFFD or leaked title text.
6. Write the regressions first and confirm they fail because `0x9c` currently
   exits the string. Then run the targeted TerminalCore and TerminalPTY tests,
   `just test`, and `just build`. Manually verify the configured fish and
   Starship session in a Swift-engine pane.

## Documentation

Update the normative terminal parser and control-string contract to state the
UTF-8-mode rules. Correct the incident research note and fixture provenance so
8-bit ST and S8C1T cases are explicitly out of scope rather than presented as
supported behavior.

## Non-goals

- Changing locale selection or launch-environment policy.
- Changing Unicode width data, ground-state UTF-8 decoding, grid layout, or
  rendering.
- Editing `/Users/dan/world`, suppressing shell title hooks, or changing the
  Starship prompt as a workaround.
- Adding OSC title events or UI title handling.
- Supporting raw 8-bit C1 controls or S8C1T mode.

## Accepted risks

The original pane's raw PTY stream was not captured. The causal sequence is
nevertheless reproducible from the exact shell hook and byte sequence, and the
neutral recording will preserve that complete behavioral case in-repository.

## Rejected ideas

- A locale fix is not appropriate: fish already reports UTF-8 and direct UTF-8
  bytes render correctly.
- A prompt or fish-hook workaround would hide a parser violation triggered by
  valid UTF-8 input.
- A U+2733 width override would not affect the premature OSC termination.

## Implementation discretion

- The internal state or helper arrangement may change as long as active string
  states own high payload bytes and all invariants remain observable.
- The neutral fixture's serialization and capture-marker details may follow
  existing repository conventions.

## Implementation notes

- The pre-existing OSC parser had a narrow lead-byte workaround that already
  preserved U+2733 (`e2 9c b3`) in OSC. The required failing regression instead
  exposed the same C1-range continuation bug in DCS, APC, PM, and SOS; the
  implementation replaces the OSC workaround with the uniform active-string
  rule specified by this plan.
