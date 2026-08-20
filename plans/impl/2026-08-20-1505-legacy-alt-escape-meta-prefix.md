# Legacy Alt+Escape sends ESC ESC, with one Meta-prefix site

## Problem

In legacy (non-kitty) keyboard mode, Alt+Escape sends one byte, `ESC`, the
same as plain Escape. `encodeLegacyKey` in
`lib/TerminalCore/Sources/TerminalCore/TerminalInputEncoding.swift` returns
`[0x1B]` for `.escape` without reading the modifiers, while Return, Tab,
Backspace, and character keys in the same function each add the Meta `ESC`
prefix on their own line. Emacs (`ESC ESC` prefix), vim `<M-Esc>`, and
readline `\e\e` macros see a plain Escape.

Evidence: audit item BUG-23 in
`docs/scratch/2026-08-18-construction-audit.md` (probe reproduced: Alt+Esc =
`[0x1B]`). All three references agree on `ESC ESC`:
`references/kitty/kitty/key_encoding.c#legacy_functional_key_encoding_with_modifiers`,
`references/ghostty/src/input/function_keys.zig` escape table (`alt` ->
`"\x1b\x1b"`), `references/xterm/input.c#Input` (metaSendsEscape prefix). The
bug is reachable from the GUI (`app/SwiftTerminalSessionView.swift#terminalKey(for:)`
maps keyCode 53 to `.escape` and Option to `.alt`) and from `send-keys`. No
test pins legacy Escape, modified or not.

## Decision

Fix Alt+Escape by moving the Meta prefix to one place: the legacy encoder
produces base bytes for the Alt-prefixable family (Return, Tab, Backspace,
Escape, character) and applies `ESC` in front of them once, after the
per-key switch, instead of each key repeating the prefix. A new key in that
family then cannot forget it. Keys that carry Alt as a CSI modifier
parameter (arrows, Home/End, F-keys, Insert/Delete/PageUp/PageDown) and the
keypad keys are unchanged.

The one-line patch (`if alt { insert ESC }` inside `case .escape`) is the
cheap fix; it leaves a fifth copy of the rule and the same hole for the next
key. The structural form is the same size of change, so there is no
trade-off to record.

## Invariants

- I1. Legacy Alt+Escape encodes as `ESC ESC`; plain Escape stays `ESC`.
- I2. The Meta prefix for the Alt-prefixable family is independent of
  terminal modes: application cursor keys, application keypad, and LNM do
  not change whether or where the `ESC` prefix appears.
- I3. Every key that already received the Meta prefix (Return, Tab incl.
  Shift+Tab, Backspace, character, Ctrl+character) keeps its current bytes.
- I4. The kitty-protocol encoder is unaffected: Alt+Escape under flag 1 is
  still `CSI 27;3u`.

## Proof obligations

- PO1 (I1). `encodeTerminalKey(.escape, [.alt], .default) == [0x1B, 0x1B]`
  and `encodeTerminalKey(.escape, [], .default) == [0x1B]` -- the regression
  test, written first and seen to fail on the current code.
- PO2 (I2). Alt+Escape bytes are identical under `.default`, application
  cursor keys, application keypad, and LNM; the existing LNM row table in
  `TerminalKeyEncodingTests.swift#lnmFollowsEveryCarriageReturnWithLineFeed`
  gains an `(.escape, [.alt])` row.
- PO3 (I3). The existing legacy matrix tests
  (`completeLegacyControlKeyMatrix`, `legacyShiftReturnEncodesLineFeed`,
  the legacy control-text test) stay green unchanged, and
  `completeLegacyControlKeyMatrix` gains the combined chord
  `encodeTerminalKey(.tab, [.alt, .shift], .default) == [0x1B, 0x1B, 0x5B, 0x5A]`
  so a rewrite cannot drop either the Meta prefix or Shift+Tab's CSI form
  while every other row still passes.
- PO4 (I4). The kitty flag-1 matrix gains `(.escape, [.alt], "\u{1B}[27;3u")`.

## Non-goals

- Ctrl+Escape and Shift+Escape in legacy mode. kitty sends bare `ESC`,
  ghostty sends `CSI 27;5;27~` / `CSI 27;2;27~`; the references disagree,
  so DanTerm keeps bare `ESC` and no test pins it either way.
- Alt on keypad keys in legacy mode. kitty maps keypad keys to their
  normal-key equivalents first; ghostty uses a separate table; no consensus
  checked. Keypad encoding stays as it is.
- BUG-05 (Ctrl+/ and Ctrl+digit aliases in `legacyControlBytes`) is a
  separate item in the same file.

## Implementation discretion

- How the switch hands its base bytes to the single prefix site (a tuple, a
  helper returning an optional, or a flag) is the implementer's choice; the
  contract is one prefix site for the family named in the Decision.

## Implementation notes

- The prefix site is a single `guard`/`return` pair after the existing switch,
  and the switch assigns a `base` local for the five family cases while every
  other case still returns directly. This keeps one exhaustive switch rather
  than splitting the encoder into a family helper plus a remainder helper,
  and it makes the compiler reject a new family case that forgets to produce
  base bytes. `.character` moved up next to the other family cases so the
  family reads as one block.

## Follow Up

- Mark BUG-23 done in `docs/scratch/2026-08-18-construction-audit.md`; the
  repo marks audit items in their own `docs(audit):` commits.
