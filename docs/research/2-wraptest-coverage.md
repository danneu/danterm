# Wraptest coverage comparison

Comparison date: 2026-07-21. Source: wraptest commit
`5409c25131a24c2cf150d42f3b4de5cb9c771d6b`.

DanTerm does not run wraptest in the Milestone 7 real-pane probe gate because
its pending-wrap transitions are already behaviorally covered by native tests:

- `state-wrapping.json` and `state-wrapping-bottom.json` pin ordinary deferred
  wrap, the following print, bottom-row scrolling, and same-position CUP.
- `TerminalQueryTests.queriesArePure` pins CPR and DECRQM preserving pending
  wrap before the next printable character.
- `TerminalStyleTests` pins SGR preserving pending wrap; parser and bell tests
  cover ignored controls without changing it.
- `CSICursorMovementTests` and the scroll/edit fixture families pin the cursor,
  erase, insert, and delete operations that cancel pending wrap.
- `TerminalSavedCursorTests` pins save/restore of pending wrap and independently
  pins the DECAWM interaction.

Wraptest's report would therefore repeat transitions already asserted through
public terminal behavior. Its cross-emulator comparison is informative but is
not a DanTerm contract, and the source has no clear license declaration, so the
pinned source is neither vendored nor made part of the gate.
