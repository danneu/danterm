# DCS dispatch: XTGETTCAP and DECRQSS

## Problem and desired outcome

`TerminalCore` has no DCS dispatch. `EscapeAbsorber` runs the full DCS state
machine -- entry, parameter, intermediate, passthrough, ignore -- and then
discards everything, so every DCS sequence a program sends is silently
swallowed. Two consequences matter:

- **Terminfo queries go unanswered.** A program that asks XTGETTCAP what this
  terminal can do gets nothing back and must fall back to whatever
  `TERM=xterm-256color` implies, which ADR `I2` says is an
  advertised identity rather than a promise.
- **Style readback goes unanswered.** A program that asks DECRQSS for the
  current SGR, scroll region, or cursor shape cannot recover state it did not
  set itself.

Desired outcome: DanTerm answers both families, and answers them from the
capability contract it already publishes rather than from a second list.

### Load-bearing premises

- Both peers ship exactly this pair and little else. ghostty routes three DCS
  commands (`ghostty/src/terminal/dcs.zig#Handler.hook`): XTGETTCAP, DECRQSS
  over four settings, and tmux control mode. kitty routes four
  (`kitty/kitty/vt-parser.c#dispatch_dcs`): XTGETTCAP, DECRQSS over four
  settings, the DCS-form synchronized output toggle, and its own protocol.
  Neither implements any VT420 report sequence.
- `docs/terminal-capabilities.md` already states DanTerm's terminfo claims as a
  table with per-capability evidence. It is the only list of what DanTerm
  promises, and it is checked against two pinned terminfo baselines (ADR `I3`).
- ADR `I5` currently declares DECRQSS and XTGETTCAP unsupported,
  and `docs/terminal-capabilities.md` repeats that in its denied list. This plan
  reverses both rows; 8-bit replies stay denied.
- Mode 2026 synchronized output is already handled through CSI
  (`Terminal.swift:824`), so kitty's DCS-form toggle has nothing to add here.

## Decision

Give the absorber a way to hand a completed DCS sequence -- its parameters,
intermediates, final byte, and body -- to the terminal, and route two handlers
off it. The seam is the point of the change: the reason a whole family of
sequences is unreachable is one missing structure, not many missing features.

The direction that makes the answers trustworthy is that **XTGETTCAP replies are
derived from the published capability contract, not from a parallel table in the
engine.** A second list would drift from the first, and the drift would be
invisible: a program would receive a claim DanTerm never committed to. One
source, one set of answers, and `I3`'s baseline check keeps governing both.

Behavioral scope: DCS `+ q` (XTGETTCAP) and DCS `$ q` (DECRQSS). Every other DCS
sequence keeps today's behavior -- absorbed and ignored, with no reply.

## Invariants

- **I1.** A DCS sequence DanTerm does not route is absorbed and produces no
  reply and no grid change, exactly as today. Adding the seam changes nothing
  for unrouted sequences.
- **I2.** XTGETTCAP answers a capability if and only if
  `docs/terminal-capabilities.md` claims it. A capability the contract does not
  claim gets the invalid-request reply, never a guessed value.
- **I3.** DECRQSS reports a setting if and only if DanTerm models that setting.
  An unmodelled or unrecognized setting gets the invalid-request reply.
- **I4.** A DECRQSS reply re-establishes the same state when fed back to the
  terminal as a control sequence. This is what makes readback useful and is the
  property that a hand-built reply string most easily breaks.
- **I5.** An invalid query is never echoed back in the reply body. Echoing an
  attacker-supplied query is CVE-2008-2383; kitty's changelog records inheriting
  the fix from xterm, and the shape is identical here.
- **I6.** Replies are 7-bit framed, consistent with the existing XTVERSION reply
  and with ADR `I5` keeping 8-bit replies denied.
- **I7.** A DCS body larger than the engine's bound is ignored outright rather
  than truncated and answered. A truncated query answered as if whole is a wrong
  answer; silence is a missing answer.
- **I8.** Chunk-boundary invariance holds across the new seam: a DCS sequence
  split at any byte boundary produces the same reply as the whole sequence.

## Proof obligations

- **PO1.** (I1) An unrouted DCS sequence, including one whose final byte and
  intermediates are close to the routed pair, leaves the grid unchanged and
  emits nothing.
- **PO2.** (I2) Every capability row in the contract table is answerable, and a
  capability outside the table draws the invalid reply. This obligation is what
  keeps the contract and the engine from separating; it should fail if a row is
  added to the table without the engine following.
- **PO3.** (I3, I4) For each reported setting, feeding the reply back to a fresh
  terminal reaches the same state the reply described. Round-trip, not string
  equality -- a string assertion would pin the spelling and miss the property.
- **PO4.** (I5) An invalid query containing distinctive bytes produces a reply
  containing none of them.
- **PO5.** (I6) Replies use 7-bit framing under every mode that affects reply
  framing elsewhere in the engine.
- **PO6.** (I7) An over-long DCS body produces no reply, and the terminal
  accepts the next valid sequence normally -- recovery, not just silence.
- **PO7.** (I8) The existing chunk-split invariance proof (ADR `K5`) covers the DCS
  routed forms.

## Non-goals

- The seven VT420 report sequences doc 36 declined: DECTABSR, DECCIR, DECDLD,
  DECAUPSS, DECRQUPSS, DECDMAC, and DECRQPSR. Neither peer implements any of
  them, and DECCIR and DECTABSR report state DanTerm would have to agree it
  models first.
- tmux control mode, kitty's DCS protocol, sixel, and the DCS-form synchronized
  output toggle.
- The DCS body's use as a passthrough channel. The shell integration's tmux
  passthrough (ADR `I9`) is unaffected and stays outside this seam.

## Accepted risks

- **AR1.** Answering XTGETTCAP makes DanTerm's capability claims consumable by
  programs at runtime, so a wrong row in the contract table becomes a wrong
  answer to a program rather than a documentation error. This is the intended
  trade: `PO2` ties the two together so the table cannot quietly disagree with
  the engine, and ADR `I3`'s two-baseline check already governs the table.
- **AR2.** DECRQSS readback exposes engine state that was previously
  unobservable, so a modelling gap that never mattered becomes visible. `I3`
  contains this by reporting only what DanTerm models.

## Rejected ideas

- **RI1.** DECRQCRA. Its request is CSI (`references/xterm/ctlseqs.txt:1830`)
  and only its reply is DCS-framed, so it needs a CSI handler and a rectangle
  checksum, not this seam -- the two were bundled in doc 36's Phase 4 and are
  separate decisions. Declined on 2026-08-25: neither ghostty nor kitty
  implements it, and the 215 esctest2 cases it would unblock are one suite's
  authorship bias, since esctest2 is xterm's and uses DECRQCRA as its instrument
  for reading back the grid. The count measures how those tests were written,
  not how many behaviors are missing.
- **RI2.** A capability table inside the engine, separate from the published
  contract. It is the obvious implementation and it is the one that fails
  silently, per the Decision above.

## Deliverables that travel with the behavior

- ADR `I5` in `docs/design/2026-08-06-swift-terminal-engine.md`: DECRQSS and
  XTGETTCAP move out of the denied list; DA2 and 8-bit replies stay.
- `docs/terminal-capabilities.md`: the denied list in "Queries and semantic
  protocols" loses the same two, and the section states the reply forms and the
  invalid-request behavior. DECRQCRA joins that denied list, so `RI1` survives
  as a contract statement rather than only as plan history.
- `docs/research/36-windows-terminal-corpus-census/README.md`: the Phase 4 DCS
  item records the decision taken and points here. Doc 36 stays closed; its
  reopening condition names this decision, so reclassifying the seven declined
  cases -- if anyone ever wants them -- is a new doc, not an edit to that one.

## Implementation discretion

- The concrete roster of DECRQSS settings, bounded by `I3`.
- Where the completed-DCS value is shaped and how the absorber hands it over.
