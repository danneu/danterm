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
invisible: a program would receive a claim DanTerm never committed to.

`docs/terminal-capabilities.md` stays canonical and human-readable, and the
engine carries a *generated projection* of it rather than an independently
authored table. `TerminalCore` has no resource bundle and `swift build` has no
prebuild step, so the projection is committed Swift, and a script pair in
`scripts/` regenerates it from the document and fails the gate when the two
disagree -- the same shape `generate-terminal-unicode-tables.py` and
`generated-unicode-tables-lint.py` already use for generated engine data. That
keeps one authored source, makes drift a build failure instead of a wrong answer
to a program, and leaves `I3`'s two-baseline check governing the document.

The document is today a *documentation* contract; answering XTGETTCAP makes it a
*wire* contract, and a documentation contract is under-specified for that job.
Before the projection can exist the document has to state, per row, the exact
query names it accepts, the value kind, and one runtime value -- see `I2`.

Behavioral scope: DCS `+ q` (XTGETTCAP) and DCS `$ q` (DECRQSS). Every other DCS
sequence keeps today's behavior -- absorbed and ignored, with no reply.

## Invariants

- **I1.** A DCS sequence DanTerm does not route is absorbed and produces no
  reply and no grid change, exactly as today. "Exactly as today" includes cost:
  the route is selected from the header, before any body byte arrives, and an
  unrouted DCS accumulates no payload. A sequence the engine ignores must not
  become a way to make it allocate.
- **I2.** XTGETTCAP answers a capability if and only if
  `docs/terminal-capabilities.md` claims it. A capability the contract does not
  claim gets the invalid-request reply, never a guessed value. For that to be
  decidable, the contract states for every row: the accepted query name or names
  (terminfo, and the termcap alias where one is accepted), the value kind
  (boolean, number, string), and exactly one runtime value -- so `pairs`, whose
  two baselines disagree, either resolves to one number or leaves the answerable
  set. The contract also states the pseudo-capabilities it accepts (`TN`/`name`,
  `Co`/`colors`, `RGB`) or denies, each with the same three facts.
- **I3.** DECRQSS reports exactly SGR, DECSTBM, DECSCUSR, and DECSCA. Every
  other request, including DECSLRM and DECSACE, gets the invalid-request reply.
  The roster is stated rather than derived because "every setting DanTerm
  models" does not pick a set: DanTerm models DECSCA protection as well as the
  three settings the problem names, and the two peers' four-item rosters differ
  from each other. Whether `"q` draws a valid reply is observable, so it is
  contract, not discretion.
- **I4.** The status string a DECRQSS reply carries re-establishes the same
  state. The reply is itself DCS-framed (`DCS 1 $ r <status> ST`) and is inert
  when fed back verbatim; the round trip is over the status string prefixed with
  CSI, which is the setting sequence a program would replay. Treating a reply as
  an executable request would be wrong protocol behavior, not a stronger
  property. This is what makes readback useful and is the property that a
  hand-built reply string most easily breaks.
- **I5.** An invalid query is never echoed back in the reply body. Echoing an
  attacker-supplied query is CVE-2008-2383; kitty's changelog records inheriting
  the fix from xterm, and the shape is identical here. This is a deliberate
  divergence at one point: xterm emits the failing name's request bytes before it
  stops (`references/xterm/misc.c:5169`), so DanTerm's prefix reply under `PO2`
  ends after the last valid pair and drops the name that missed.
- **I6.** Replies are 7-bit framed, consistent with the existing XTVERSION reply
  and with ADR `I5` keeping 8-bit replies denied.
- **I7.** A DCS body larger than the engine's bound is ignored outright rather
  than truncated and answered. A truncated query answered as if whole is a wrong
  answer; silence is a missing answer.
- **I8.** Chunk-boundary invariance holds across the new seam: a DCS sequence
  split at any byte boundary produces the same reply as the whole sequence.
- **I9.** A routed DCS body is matched verbatim. Today `EscapeAbsorber` drops
  every byte `>= 0x80` inside a non-OSC control string
  (`EscapeAbsorber.swift:295`), which was invisible while bodies were discarded;
  once a body decides a reply, that elision would turn `c\u{90}olors` into a
  valid `colors` query and answer a malformed request. A body byte outside the
  routed protocol's alphabet makes the query invalid. It is never dropped so
  that the rest can match.

## Proof obligations

- **PO1.** (I1) An unrouted DCS sequence, including one whose final byte and
  intermediates are close to the routed pair, leaves the grid unchanged and
  emits nothing.
- **PO2.** (I2) Every capability row in the contract table is answerable under
  every query name it accepts, and a capability outside the table draws the
  invalid reply. The generator/lint pair is the other half: adding a row to the
  document without regenerating the projection fails the gate, and editing the
  projection by hand fails it too. Multi-name requests are covered as their own
  obligation, in three cases, because xterm's semantics are prefix semantics
  rather than all-or-nothing (`references/xterm/misc.c:5180`): the reply's
  valid/invalid digit is decided by the *first* name alone, then name/value pairs
  stream in request order until a name misses, and processing stops there. So an
  all-valid list returns every pair; a list whose first name is invalid returns
  the invalid reply; and a list whose Nth name is invalid returns the valid reply
  carrying the first N-1 pairs. `Co;<unknown>;TN` answers `Co` and never reaches
  `TN`.
- **PO3.** (I3, I4) For each of the four reported settings, extracting the reply's
  status string, prefixing it with CSI, and feeding that to a fresh terminal of
  the same geometry reaches the same observable setting state. Round-trip, not
  string equality -- a string assertion would pin the spelling and miss the
  property. DECSLRM and DECSACE draw the invalid reply.
- **PO4.** (I5) An invalid query containing distinctive bytes produces a reply
  containing none of them.
- **PO5.** (I6) Replies use 7-bit framing under every mode that affects reply
  framing elsewhere in the engine.
- **PO6.** (I7) An over-long DCS body produces no reply, and the terminal
  accepts the next valid sequence normally -- recovery, not just silence.
- **PO7.** (I8, I9) The ADR `K5` chunk-split proof is extended to both routed DCS
  families, fed whole, one byte at a time, and split at every interior boundary
  of the header/body/terminator seam. Today's coverage cannot stand in: DCS
  produces no event, so no existing case can observe a body or a reply. The cases
  carry opaque high bytes in the body, cancellation and restart mid-sequence, and
  recovery to a later valid query.
- **PO8.** (I1) An unrouted DCS carrying a long body does not grow the engine's
  allocation, so the seam adds no resource-exhaustion surface to sequences it
  ignores.

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
- **RI2.** A hand-authored capability table inside the engine. It is the obvious
  implementation and it is the one that fails silently, per the Decision above.
  What `RI2` rejects is an *unchecked* second list, not a second representation:
  the committed generated projection is admissible precisely because the lint
  makes disagreement a build failure.
- **RI3.** Reviving a machine-readable capability manifest as a v2 artifact to
  serve as the canonical source. `docs/terminal-capabilities.md` permits one, but
  it would add a third representation -- JSON, Markdown, Swift -- and re-introduce
  the byte-comparison gates the repository deliberately retired on 2026-07-22.
  Generating the Swift projection straight from the Markdown table gets the same
  no-drift guarantee with one fewer authored artifact.

## Deliverables that travel with the behavior

- ADR `I5` in `docs/design/2026-08-06-swift-terminal-engine.md`: DECRQSS and
  XTGETTCAP move out of the denied list; DA2 and 8-bit replies stay.
- `docs/terminal-capabilities.md`: the denied list in "Queries and semantic
  protocols" loses the same two, and the section states the reply forms, the
  multi-name and invalid-name semantics, and the invalid-request behavior. The
  terminfo claims table gains the per-row facts `I2` requires -- accepted query
  names, value kind, one runtime value -- and resolves `pairs`. Accepted and
  denied pseudo-capabilities are listed. DECRQCRA joins the denied list, so `RI1`
  survives as a contract statement rather than only as plan history.
- `scripts/`: the generator that renders the engine's capability projection from
  the document, and the lint that fails the gate when the committed projection
  and the document disagree.
- The two external-corpus manifests whose classifications this change falsifies:
  `libvterm-manifest.json` and `windows-terminal-manifest.json` both say DanTerm
  answers no DECRQSS. libvterm already carries applicable SGR, DECSTBM, DECSCUSR,
  and DECSCA cases, which are adapted rather than left as ready-made evidence on
  the floor. Cases for settings DanTerm does not model (DECSLRM, DECSACE) stay
  out of scope, with the rationale corrected to name the missing setting rather
  than the missing dispatch.
- `docs/research/36-windows-terminal-corpus-census/README.md`: the Phase 4 DCS
  item records the decision taken and points here. Doc 36 stays closed; its
  reopening condition names this decision, so reclassifying the seven declined
  cases -- if anyone ever wants them -- is a new doc, not an edit to that one.

## Implementation discretion

- Where the completed-DCS value is shaped and how the absorber hands it over,
  bounded by `I1`: the route is chosen from the header and only a routed header
  collects a body.
- The generated projection's Swift shape and the generator's language, bounded by
  `PO2`.

## Commit progress
- [x] 1. feat(terminal): route DCS to a dispatch seam, and answer DECRQSS
- [ ] 2. feat(terminal): answer XTGETTCAP from the generated capability projection

## Implementation notes

- The commit structure was chosen here, not by the plan: the seam plus DECRQSS
  first, then XTGETTCAP off the generated projection. DECRQSS is the consumer
  that needs no new authored artifact, so it proves the seam on its own, and it
  leaves commit 2 as one cohesive contract-and-codegen change.
- The parser collects one control-string buffer for OSC and routed DCS instead
  of two. Their states are mutually exclusive, so a second 2 MiB buffer would
  never hold anything the first one did not, and `pending-control-string` is
  already the one bound the contract names for both.
- `TerminalSettingReport` holds each reported setting's CSI spelling once, and
  the state-synchronization encoder now reads from it. `I4` says a DECRQSS
  status string has to re-establish the state; the encoder already had to emit
  exactly that sequence for the same settings, so one spelling makes the report
  and the replay identical by construction rather than by two authors agreeing.
- A `$ q` header carrying a parameter is routed and then rejected, rather than
  left unrouted. `I1`'s cost clause is about bodies, and the header is still the
  DECRQSS header, so the invalid reply is the honest answer -- silence would
  claim the parser did not recognize the family.
- `PO5` asks for 7-bit framing under every mode that affects reply framing
  elsewhere in the engine. There is no such mode: DanTerm implements no `S8C1T`
  and no 8-bit reply switch, so the test asserts the framing bytes and the
  absence of any C1 byte across every request instead of enumerating modes.
