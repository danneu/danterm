# Configurable macOS Option as Terminal Alt

## Problem and desired outcome

DanTerm currently gives macOS text input first claim on Option-modified keys. This preserves native Option characters and dead keys, but users cannot choose to send a physical Option key as terminal Alt. Kitty and Ghostty expose that choice and distinguish the left and right Option keys.

DanTerm should keep native macOS handling by default and let the user assign terminal Alt to the left Option key, the right Option key, or both. The choice should be available in configuration and Preferences, and should apply to open panes without replacing their sessions.

## Decision

Add this optional v1 configuration field:

```json
{
  "keyboard": {
    "optionAsAlt": "left"
  }
}
```

The stored values are `"left"`, `"right"`, and `"both"`. Omission means native macOS handling. Preferences presents the same policy as `[Native | Left | Right | Both]` under General Settings.

For a text-producing key on a side assigned to terminal Alt, DanTerm uses macOS keyboard translation without Option to identify the intended character, then sends that character with the terminal Alt modifier. It removes only Option during translation, so the other held modifiers keep their existing effects. This avoids native Option symbols and dead-key behavior on that side while preserving the active terminal keyboard protocol. Native sides continue through the existing macOS text-input path. Fixed and non-text keys keep the current behavior in every policy: a physically held Option key is terminal Alt.

The policy is model-owned configuration. Session reconciliation sends changes to existing panes, and new panes receive the current value when they are created.

## Invariants

- I1: Missing, invalid, or wrongly typed `keyboard.optionAsAlt` data behaves as native handling.
- I2: Saving native handling omits `optionAsAlt`; saving another choice writes its documented value without losing unknown configuration data, including unknown `keyboard` fields.
- I3: Text-producing keys on a native Option side preserve the current Unicode, dead-key, and input-method behavior.
- I4: For text-producing keys, a terminal-Alt choice affects only the selected physical Option side. If both Option keys are held, any held side assigned to terminal Alt is sufficient to select terminal Alt. An Option event without side information follows the left-side policy.
- I5: Terminal Alt uses the active terminal keyboard protocol: legacy input sends the Alt escape form, while Kitty keyboard input sends its Alt modifier form.
- I6: Fixed and non-text keys retain their existing terminal key identity and carry Alt whenever Option is physically held, on either side and under every policy.
- I7: On a terminal-Alt side, only Option is removed for character translation. Shift and Caps Lock still select the character, and Shift and Control remain terminal modifiers.
- I8: A preference change affects existing and future panes without recreating a terminal session.
- I9: The setting changes terminal child input only. It does not change DanTerm shortcuts or Command-key behavior.

## Proof obligations

- PO1: Configuration tests prove all stored choices, the omitted and invalid fallbacks, native omission on save, and preservation of unknown nested data. Covers I1 and I2.
- PO2: Pure core tests prove that Preferences projects and edits all four choices and that the choice participates in the desired configuration of every pane. Covers I8.
- PO3: Preferences UI tests prove that each choice is shown correctly and that each user selection produces the corresponding saved preference. Covers the public settings behavior.
- PO4: Tests in the normal gate prove the routing result for left-only, right-only, both-side, dual-held-side, and unsided Option events. Covers I4.
- PO5: AppKit input tests prove native text, dead-key, and input-method behavior and the wiring from sided Option events to the routing policy. Covers I3 and I4.
- PO6: Input-selection tests prove that terminal-Alt translation preserves Shift and Caps Lock character selection and carries Shift and Control as terminal modifiers. They also prove that fixed keys such as Option+Left and Option+Backspace retain Alt under the native policy. Together with the existing protocol encoder coverage and a legacy Alt-character case, these tests cover I5, I6, and I7 without duplicating the encoder matrix.
- PO7: A live-session test proves that a policy change affects the next relevant key event without session replacement. Covers I8.
- PO8: Existing shortcut and Command-key tests remain green. Covers I9.

## Non-goals

- Changing Command-key handling or exposing Command as terminal Super.
- Adding a stored `"native"` or `"none"` value. Native behavior is represented by omission.
- Changing the terminal engine's public key model or the `danterm` CLI.
- Migrating the configuration schema beyond version 1.

## Implementation discretion

- Internal type names, event-translation helpers, and the placement of AppKit-only tests are implementation choices.
- Multi-scalar commits and active composition may remain on the committed-text path when they cannot represent one modified terminal key without losing text-input behavior.

## Implementation notes

- The implementation amends terminal-engine decisions G1, G2, and H7 because their live text explicitly ruled out Option-as-Alt and listed a schema that predated the new keyboard field.
