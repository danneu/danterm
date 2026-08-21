# Mode-independent VT last-column state

## Problem

BUG-24 and BUG-27 are reproduced in the current tree. HTS, valid TBC forms,
ANSI mode changes, and DECAWM changes clear DanTerm's deferred last-column
state even though they do not move the cursor. The next printable scalar then
overwrites the margin instead of following the terminal's wrap rules. The same
shared clearing path also discards the open grapheme attachment target.

The references establish one coherent compatibility model:

- xterm tab-stop and mode handlers leave `do_wrap` untouched
  (`references/xterm/charproc.c#CASE_HTS`, `#CASE_TBC`, `#srm_DECAWM`).
- Ghostty tab-stop and mode handlers leave `pending_wrap` untouched
  (`references/ghostty/src/terminal/Terminal.zig#tabSet`, `#tabClear`,
  `references/ghostty/src/terminal/modes.zig#ModeState.set`).
- Both terminals record arrival at the right margin independently from
  DECAWM and consult DECAWM when a later printable scalar could wrap
  (`references/xterm/charproc.c#dotext`,
  `references/ghostty/src/terminal/Terminal.zig#print`).

The two bugs therefore form one TerminalCore implementation lane. Fixing only
the reported clearing calls would leave DanTerm's deeper mode-gated
last-column model inconsistent during printing, cursor restore, resize, and
state synchronization.

## Decision

Model `isPendingWrap` as the VT last-column flag, independent from DECAWM.
DECAWM decides whether a later ordinary positive-width print consumes that
flag by soft-wrapping; it does not decide whether output at the margin records
the flag.

State-only controls must preserve both the last-column flag and the open
grapheme context. Operations that move the cursor or replace its surrounding
grid state continue to end that print continuation. This separates mode and
tab state changes from cursor/grid side effects instead of adding exceptions
around the current generic clearing behavior.

No public type signature changes. Update the public meaning of
`TerminalCursor.isPendingWrap` to describe the last-column flag and its
conditional interaction with DECAWM.

## Invariants

- **I1 - Margin writes:** Every positive-width write that ends at the right
  margin arms the last-column flag, including narrow, bulk ASCII, wide,
  width-upgrade, and bounded REP output, regardless of DECAWM.
- **I2 - Print-time wrap:** An ordinary positive-width print with the flag set
  soft-wraps first only when DECAWM is enabled. With DECAWM disabled it
  overwrites the right margin and leaves the flag armed for the resulting
  margin write. A wide print keeps DanTerm's existing placement across the
  final two columns and arms the flag afterward.
- **I3 - Grapheme ordering:** A scalar that joins an open grapheme cluster is
  resolved before deferred-wrap handling and does not consume the
  last-column flag. State-only tab and mode controls preserve that attachment
  target.
- **I4 - Control ownership:** HT when it clamps at the right margin, HTS,
  valid TBC, IRM, LNM, and DECAWM changes do not end print continuation.
  DECOM does because setting or resetting it homes the cursor. Mode parameters
  retain left-to-right behavior, and malformed or unsupported forms remain
  no-ops.
- **I5 - Stored state:** Live and saved last-column flags survive restore,
  height-only resize, and state synchronization whenever their cursor remains
  at the right margin. A cursor parked on the right-margin tail of a
  margin-filling wide cell remains on that tail with the flag armed; ordinary
  wide-tail demotion does not apply to that pending state. A geometry change
  that removes the margin relationship clears the flag.
- **I6 - Existing boundaries:** Cursor motion, editing, erasure, reset, and
  screen replacement continue to clear the live print continuation according
  to their existing contracts. When REP places at least one cluster, it
  remains bounded to that row. When REP starts with the flag armed and DECAWM
  enabled, its first cluster wraps and the requested repeats fill no farther
  than the destination row's margin. With DECAWM disabled, REP performs one
  margin overwrite using I2's narrow or wide placement and leaves the flag
  armed.

## Proof obligations

- **PO1 - Tab and mode preservation:** Through public byte ingestion, prove
  that right-margin HT and every in-scope HTS, TBC, ANSI mode, and DECAWM
  set/reset form preserve deferred-wrap behavior and grapheme attachment.
  Prove DECOM still homes and clears both, including ordered multi-parameter
  mode sequences.
- **PO2 - DECAWM-off printing:** Prove each load-bearing print route arms the
  flag at the margin while DECAWM is off, overwrites without wrapping while it
  stays off, and wraps on the next ordinary printable after DECAWM is enabled.
- **PO3 - Stored and reconstructed state:** Prove narrow and wide pending
  states survive save/restore, valid resize operations, and synchronization of
  both live and saved cursors. Feed continuation bytes to source and replica
  and require identical observable behavior.
- **PO4 - Existing behavior:** Prove real cursor/grid mutations still clear
  continuation, invalid controls remain inert, chunking does not affect mode
  ordering, and narrow and wide REP started with the flag armed obey I6 under
  both DECAWM states.
- **PO5 - Existing expectations:** Re-pin every existing expectation that
  encodes mode-gated arming, including bulk ASCII margin overwrite,
  armed REP under either DECAWM state, mode and tab continuation, and the
  adapted libvterm wrapping fixture. The upstream fixture observes the same
  visible cursor and does not expose this internal flag, so it needs no
  recorded deviation.

Write the failing behavioral tests first and confirm they fail for the expected
old clearing or mode-gating reason. Run the focused TerminalCore suites, then
run the full `just test` gate.

## Dependencies and integration

- This work is confined to TerminalCore. It needs no AppKit, PTY, CLI,
  dependency, migration, or synchronization wire-format change.
- BUG-33 overlaps print ordering and grapheme tests. Its zero-width fallback
  must remain before positive-width deferred-wrap handling.
- BUG-30 overlaps resize normalization and tests. Preserve both its row
  wrap-claim behavior and this cursor last-column invariant when rebasing.
- BUG-31 overlaps tab-stop tests and reset behavior but has an independent
  DECSTR contract. Do not fold BUG-30, BUG-31, or BUG-33 into this lane.
- After the implementation commit lands, mark BUG-24 and BUG-27 done in the
  construction audit with that commit hash. No design-record amendment is
  required.

## Implementation discretion

- Private naming and decomposition are free choices if continuation-clearing
  ownership remains explicit at cursor/grid operations.
- Test file placement and scenario factoring are free choices if every proof
  obligation is covered through observable behavior.

## Follow Up

- Mark BUG-24 and BUG-27 done in
  `docs/scratch/2026-08-18-construction-audit.md` with this implementation
  commit hash.
