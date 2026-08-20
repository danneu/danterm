# Truncate an over-long CSI parameter list instead of dropping the sequence

Source: BUG-15 in `docs/scratch/2026-08-18-construction-audit.md`.

## Problem

`EscapeAbsorber` caps a CSI at 24 parameters. Past the cap it does not keep
the parameters that fit; it drops the whole sequence and dispatches nothing.
A 25-parameter SGR leaves the previous pen in force; a 25-mode `CSI ?...h`
sets no mode.

Evidence:

- `lib/TerminalCore/Sources/TerminalCore/EscapeAbsorber.swift#dispatchCSI`
  returns nil when the parameter count has reached the cap.
  `CSIParserTests/parameterCapacity` ("dispatches 24 values and drops 25")
  pins the drop and is green on master.
- The drop was ported from ghostty (`references/ghostty/src/terminal/Parser.zig#csi_dispatch`,
  test "csi: sgr beyond our max drops it"). The references disagree with each
  other, so none of them settles the policy:
  - vte also drops. `references/vte/src/parser.hh#params_overflow` moves to
    `CSI_IGNORE` when a parameter arrives past `VTE_PARSER_ARG_MAX` (32), so
    the whole sequence is discarded.
  - xterm executes, but not as a clean first-N truncation.
    `references/xterm/charproc.c#CASE_ESC_SEMI` and `#CASE_ESC_COLON` stop
    adding parameters past `NPARAM` (`references/xterm/ptyx.h#NPARAM`, 30),
    while `#CASE_ESC_DIGIT` keeps folding later digits into the last retained
    parameter -- so the 30th parameter can end up carrying digits that
    belonged to the 31st and beyond.
  Truncation to the first 24 is therefore DanTerm's own policy, chosen for the
  reasons in **Decision**, not a copy of a reference.
- The same file already truncates intermediates without dropping the
  dispatch (`CSIParserTests/intermediateCapacity`). Parameters are the odd
  one out.
- DanTerm's own state-synchronization stream is at the edge:
  `Terminal.swift#styleSequence` emits exactly 24 parameters in its worst
  case (reset, every attribute, colon underline style, RGB foreground,
  background and underline colour), and `TerminalPTYHost` feeds that stream
  back into `TerminalCore`. One more attribute in the model would make
  DanTerm silently drop its own resync.

Load-bearing premise: the SGR interpreter already tolerates a short trailing
colour group (`Terminal.swift#semicolonColor` / `#colonColor` return nil and
advance), so a truncated SGR applies what it can without new handling.

## Decision

The parser never drops a CSI for length. Parameters past the cap are ignored;
the sequence dispatches with the first 24, each holding exactly the digits
written for it.

Rationale, since the references disagree:

- Bounded state. The cap is a storage bound, and ignoring the overflow keeps
  it one without adding state -- the same shape the same file already uses for
  intermediates (`CSIParserTests/intermediateCapacity`), where truncation does
  not drop the dispatch. Parameters are the odd one out.
- Degrade, don't cliff. DanTerm's cap (24) is below xterm's 30 and vte's 32, so
  DanTerm meets the overflow path on sequences both of them handle in full.
  Applying the first 24 lands closer to what those terminals do than dispatching
  nothing does.
- Clean truncation over xterm's digit folding: a retained parameter that
  silently absorbs digits from a dropped one produces a wrong value, which is
  worse than a missing one.

The cap stays at 24. It is a by-construction storage bound (inline storage,
commit `0ede91de`); once overflow degrades instead of cliffs, the value of the
bound is a separate, measured decision.

Scope: `EscapeAbsorber` CSI dispatch and its tests; one state-synchronization
round-trip test. No change to DCS or OSC handling, the SGR interpreter, or the
`CSIParameters` type.

## Invariants

- I1. A CSI with more than 24 parameters dispatches with exactly its first 24
  parameters and their colon separators; the rest, including any digits still
  accumulating when the final byte arrives, are discarded. The parser never
  traps on overflow.
- I2. The dispatched value of an over-long CSI is identical to the value
  dispatched for the same sequence cut after its 24th parameter.
- I3. Existing behavior kept: a CSI with 24 or fewer parameters dispatches
  unchanged; a fifth intermediate is dropped without dropping the dispatch;
  parsing is invariant under chunk splits.
- I4. DanTerm's worst-case `styleSequence` output fits the cap: a cell and pen
  carrying every attribute plus RGB foreground, background and underline
  colour round-trips through `stateSynchronization` unchanged.

## Proof obligations

- PO1 (I1, I2): `CSIParserTests/parameterCapacity` flips intent from "drops
  25" to "truncates to 24", covering overflow with digits pending at the
  final, overflow ending on a separator, and a colon-bearing overflow.
- PO2 (I1): Terminal-level -- an over-long SGR applies its first 24
  parameters (e.g. the 1st parameter's colour is applied, the 25th's is not).
- PO3 (I3): existing `CSIParserTests` (`intermediateCapacity`,
  `chunkBoundaryInvariance`) stay green; the 25-parameter chunk fixture now
  proves a truncated dispatch is split-invariant.
- PO4 (I4): new case in `TerminalStateSynchronizationTests` round-tripping
  the fully loaded style.

## Non-goals / Rejected ideas

- Non-goal: changing the OSC overflow policy (`dispatchOSC` drops an
  over-long OSC). An OSC payload is opaque, so truncating it changes meaning;
  a truncated CSI parameter list does not.
- Non-goal: DCS parameter handling.
- RI1: raise the cap to 30 (xterm) or 32 (vte) in this change. Rejected for
  now: the fix removes the cliff; widening the inline storage is a measured
  perf decision under `agent-docs/measurement-discipline.md`, and I4 pins
  that the current worst case fits.
- RI2: reject (drop) an over-long sequence as "malformed". Rejected: it is the
  status quo cliff the plan exists to remove -- a single extra parameter turns
  a whole SGR or mode set into a no-op. That vte drops too (`params_overflow`)
  does not rescue it, because DanTerm's cap is smaller, so DanTerm would drop
  sequences vte executes.

## Implementation discretion

- How `dispatchCSI` handles the pending accumulator at the cap (discard vs.
  never-accumulate past the cap), as long as I1/I2 hold and nothing traps.

## Verification

- `swift test --package-path lib/TerminalCore --filter CSIParserTests`
- `swift test --package-path lib/TerminalCore --filter TerminalStateSynchronizationTests`
- `swift test --package-path lib/TerminalCore --filter TerminalStyleTests`
- `just test` before commit.

## Follow Up

- Mark BUG-15 done with this commit's hash in
  `docs/scratch/2026-08-18-construction-audit.md` (row 169 and the `### BUG-15`
  section), following the repo's separate `docs(audit): mark ... done` commit
  pattern.
