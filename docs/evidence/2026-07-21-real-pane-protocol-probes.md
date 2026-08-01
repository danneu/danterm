# Real-Pane Protocol Probe Evidence - 2026-07-21

> Historical Milestone 7 result. The expanded 14-case esctest2 and
> three-session vttest gate is recorded in
> [the 2026-07-31 Milestone 9 evidence](2026-07-31-external-terminal-gate.md).

## Judgment

DanTerm's supported Milestone 7 black-box protocol and capability tranche passes
through the production `TerminalPaneSessionController` and PTY ownership path.
The selected external probes confirm stateful cursor-position and mode-query
replies without expanding the native capability contract.

## Reproduction

Both required gates passed on 2026-07-21:

```sh
just test
just test-terminal-protocol-probes
```

The live run used esctest2 commit
`664be3cf2c1e3f06bc93a8bafb48a0db83c607db` on macOS 26.5.2 arm64. All 11
selected cases passed with no known bugs or failures. Teardown reported the pane
session, child, PTY owner, descriptors, and dispatch sources released.

## Selected behavior

- Five CUP cases cover defaulted, independently omitted, zero-valued, and
  out-of-bounds coordinates. esctest2 observes each result through CPR, proving
  the terminal-generated reply traverses the real pane and PTY path.
- Six DECRQM cases cover the advertised ANSI IRM and LNM modes plus DEC DECCKM,
  DECOM, DECAWM, and DECTCEM. Each case queries, changes, and re-queries the
  implemented mode through the public protocol.

The explicit case list and group rationales live in
[`scripts/terminal-protocol-probes-allowlist.txt`](../../scripts/terminal-protocol-probes-allowlist.txt).
DSR, DA1, XTVERSION, identity replies, and other unadvertised behavior remain
excluded.

## Native regressions and wraptest

The external run exposed no DanTerm defect, so no native regression fixture was
promoted.

Pinned wraptest commit `5409c25131a24c2cf150d42f3b4de5cb9c771d6b`
adds no uncovered pending-wrap transition and is therefore omitted. The
behavioral comparison is recorded in
[`docs/research/2-wraptest-coverage.md`](../research/2-wraptest-coverage.md).

This evidence closes only the final Milestone 7 black-box item. Milestone 8
remains untouched.
