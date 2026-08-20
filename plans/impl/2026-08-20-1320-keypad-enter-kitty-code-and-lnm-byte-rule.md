# Keypad Enter encoding: kitty functional code and LNM as a byte rule

Closes BUG-28 and BUG-34 in
`docs/scratch/2026-08-18-construction-audit.md` as one task. Both live in
`lib/TerminalCore/Sources/TerminalCore/TerminalInputEncoding.swift`, tests in
`lib/TerminalCore/Tests/TerminalCoreTests/TerminalKeyEncodingTests.swift`.

## 1. Problem

Keypad Enter is encoded by two key-name special cases that each miss the rule
the references actually implement:

- Kitty (flag 1): the keypad branch returns the key's legacy text for every
  unmodified keypad key. For keypad Enter that text is CR, so it is
  byte-identical to Return and a program that negotiated disambiguation cannot
  tell `<kEnter>` from `<CR>`.
- Legacy: LNM (mode 20) is consulted only inside the Return case. Numeric-mode
  keypad Enter emits CR while Return emits CR LF, so a line-oriented program
  under LNM hangs on one Enter key and works on the other.

Both reproduce on HEAD (audit probes, verdict `reproduced`).

**Evidence.** kitty `references/kitty/kitty/key_encoding.c#encode_glfw_key_event`
and `#encode_function_key`: with disambiguate set, a keypad key stays a keypad
key, a key whose text starts with an ASCII control byte has no text, and the
only bare-CR shortcut names the main Enter key, so KP_ENTER serializes as
`CSI 57414 u`. ghostty `references/ghostty/src/input/key_encode.zig#kitty`
agrees (`.enter` shortcut only; plain text path rejects control UTF-8; table
entry `numpad_enter, 57414, 'u'`). xterm `references/xterm/charproc.c#unparseputc`
appends LF to every CR it emits while LNM is set, and
`references/xterm/input.c#Input` sends numeric-keypad bytes and ordinary text
bytes (including Ctrl+M) through that same function. kitty and ghostty do not
implement LNM for keys at all, so xterm is the only authority.

## 2. Decision

Replace the two special cases with the two rules:

- D1 (kitty): an unmodified keypad key sends its legacy text only when that
  text is printable; otherwise it sends its kitty functional code. The
  printable/control distinction is the rule, not the key's name.
- D2 (legacy): LNM is a property of the emitted bytes, not of a key. After the
  legacy encoder has chosen a key's bytes, every CR in them is followed by LF
  while LNM is set. The per-key LNM branch in Return goes away.

Scope is the legacy and kitty key encoders only. Both are pure `TerminalCore`
functions with no app, CLI, or protocol surface.

## 3. Invariants

- I1. Under kitty flag 1, unmodified keypad Enter encodes as `ESC [ 57414 u`;
  modified keypad Enter keeps its `ESC [ 57414 ; m u` form.
- I2. Under kitty flag 1, unmodified Return still encodes as CR, and an
  unmodified printable keypad key (for example keypad 5) still sends its text.
- I3. Under LNM in numeric keypad mode, keypad Enter encodes as CR LF and is
  byte-identical to unmodified Return.
- I4. Under LNM with application keypad mode, keypad Enter is `ESC O M`
  (no CR, so LNM does not touch it).
- I5. Under LNM, every legacy key whose bytes contain CR gains LF after it:
  Alt+Return is `ESC CR LF`; Ctrl+M is `CR LF`. Keys without CR are unchanged,
  in particular Shift+Return stays LF (its "insert a line feed, not submit"
  contract survives).
- I6. With LNM off, no legacy key changes its bytes.
- I7. The kitty encoder still ignores legacy modes (LNM, DECKPAM, DECCKM) as
  it does today.

## 4. Proof obligations

TDD in `TerminalKeyEncodingTests.swift`; each new test fails on HEAD for the
stated reason before the code change.

- PO1 (I1, I2): kitty flag 1 -- keypad Enter unmodified and modified,
  Return unmodified, a printable keypad key unmodified. Run the two
  unmodified keypad cases twice: once with DECKPAM, DECCKM, and LNM off,
  once with all three on, expecting the same kitty bytes both times. Without
  the modes-on run, a regression that consulted DECKPAM only on the changed
  unmodified path would still pass.
- PO2 (I3, I4): LNM on -- keypad Enter numeric equals Return's bytes;
  keypad Enter application mode unchanged (the existing assertion at
  `applicationModes` already pins I4; keep it).
- PO3 (I5): LNM on -- Ctrl+M is CR LF; Alt+Return is ESC CR LF (already
  pinned in `completeLegacyControlKeyMatrix`); Shift+Return stays LF under
  LNM (already pinned in `legacyShiftReturnEncodesLineFeed`).
- PO4 (I5, I6): a table-driven differential test over representative legacy
  key families -- Tab, an arrow key, a function key, printable text, a
  control key, and a keypad key -- encoding each with LNM off and LNM on.
  A row's two encodings must be identical unless the LNM-off bytes contain
  CR, in which case the LNM-on bytes are the LNM-off bytes with LF after
  each CR. The existing keypad table, control-key matrix, and text matrix
  tests (all LNM off) keep passing unchanged, which is I6 alone; the
  differential test is what proves the LNM-on half of I5.
- PO5 (I7): the existing `kittyFlagOneMatrix` (built with application modes
  on) keeps passing; add one row showing kitty Return under LNM is still CR.

Update the `lineFeedNewLine` doc comment on `TerminalInputModes` to state the
byte rule rather than "legacy Return".

## 5. Non-goals / Accepted risks

- Non-goal: modifier handling for legacy keypad keys (Alt+keypad5,
  Shift+keypad Enter in application mode). Same branch, separate audit item.
- Non-goal: LNM under the kitty protocol. No reference applies it there.
- AR1: Ctrl+M under LNM changes from CR to CR LF. This follows from D2 and
  matches xterm; no known program in DanTerm's use depends on the old bytes.

## 6. Implementation discretion

- Whether D2 is a post-pass over the encoder's result or an emit helper is
  the implementer's call; the contract is I3-I6.

## Merge notes

Open audit items BUG-05 (`legacyControlBytes`) and BUG-23 (legacy
Alt+Escape) edit the same function in distinct hunks and append tests to the
same test file; expect a trivial test-file rebase if they land in parallel.

## Verification

`swift test --package-path lib/TerminalCore --filter TerminalKeyEncodingTests`,
then `just test`. The byte-level encoder tests are the whole proof: a live
`cat -v` check cannot see these bytes, because the PTY line discipline
(`ICRNL`, canonical mode) rewrites and buffers CR and LF before `cat` reads
them.

## Implementation notes

- D2 is a post-pass over the legacy encoder's result in `encodeTerminalKey`,
  not an emit helper threaded through every branch: LNM then reaches keys the
  encoder builds from tables (keypad) and from control arithmetic (Ctrl+M)
  without either branch reading the mode.
- The kitty printable test reads the first scalar of a keypad key's legacy
  text, matching kitty's `startswith_ascii_control_char` rather than testing
  the whole string. Every keypad text is one scalar today, so the two agree.
- `kittyFlagOneMatrix` now builds its modes with LNM on as well, so every row
  in it -- not only the new Return row -- states that the kitty encoder
  ignores legacy modes.

## Follow Up

- Mark BUG-28 and BUG-34 done in `docs/scratch/2026-08-18-construction-audit.md`,
  including the summary table rows at the top; the entries name the commit hash,
  so the tick cannot land in the same commit.
