# Merge TerminalDamageAccumulator into TerminalDamage (INTERACT-3)

## Context

`lib/TerminalCore/Sources/TerminalCore/TerminalDamage.swift` implements the
scroll-shift composition rule twice: once in `TerminalDamage.applyShift`
(run by `formUnion` on every publish and by the value's `recordShift`), and
once in `TerminalDamageAccumulator.recordShift` (run by `Terminal` on every
scroll). The two structs hold the same three fields (`isFull`, `shift`,
`bits`) with two hand-written `==` and two drain-time state machines.
They have already drifted: the value type preconditions the shift region
against the grid height; the accumulator only documents that requirement in
a comment, and an out-of-grid region there reaches
`TerminalDamageRowBits.translate`, which writes `words[index]` with no
bounds check. The accumulator's collapse branch (summed same-region shifts
reaching the region height) is unreachable from a single scroll --
`Terminal.recordScrollDamage` early-returns when one scroll's amount covers
the region -- and no test drives it through the summing path.

Source finding: INTERACT-3 in `docs/scratch/2026-08-18-construction-audit.md`
(vetted there; the "shipped rule is untested" premise was retracted --
what stands is the duplication, the missing bounds check, and the
uncovered collapse branch). FRAME-3 and FRAME-4 in the same audit are
written against this landing first.

## Decision

Delete `TerminalDamageAccumulator`. `Terminal` stores a `TerminalDamage`,
which becomes both the producer accumulator and the drained value.
The producer surface it gains (construction at a grid height, reset,
drain, change-reporting recording, viewport-coverage check) is internal
to `TerminalCore`, so the module's public surface does not change.

The shift contract itself (research/33 T9) and the word-backed
representation (research/33 T20) are unchanged; only the number of
implementations drops to one.

## Invariants

- I1: The shift-composition rule has one body, shared by producer
  recording and `formUnion`: same-region shifts sum; a sum at or past the
  region height collapses to region-wide rows with no shift; a region
  mismatch escalates to full; full absorbs everything.
- I2: Escalation to full, and drain, both preserve the live grid height:
  damage recorded afterward for any row in the current grid is accepted
  and surfaces in the next drain. (The static `.full`/`.none` values carry
  a zero-height bitset, and `TerminalDamageRowBits.insert` silently
  refuses rows at or past its height, so an escalation or drain spelled as
  `self = .full` / `= .none` in the producer would silently end all damage
  recording.)
- I3: The shipped producer path rejects a shift region outside the grid
  before it reaches word storage -- the bounds check the value type
  already has applies to the code `Terminal` runs.
- I4: Recording reports whether it changed pending damage, and
  `Terminal` bumps the consumer-work generation only on a reported
  change. This now includes `recordShift`, whose value-type spelling
  returns nothing today.
- I5: The consumer-facing surface and semantics of `TerminalDamage` are
  unchanged: `isFull`, `isEmpty`, `shift`, `rowIndices`, `forEachRow`,
  `maximalContiguousSpans`, `withGlyphHalo`, `expandingShift`,
  `formUnion`, and width-independent semantic `==`.

## Proof obligations

- PO1 (I1, the uncovered collapse branch -- write this first): a
  characterization test through the production path: same-region scrolls
  summing to the region height, fed without an intervening drain, drain
  as region-wide rows with no shift (DECSTBM region, assert on
  `terminal.drainDamage()`). Expected to PASS against today's tree; if it
  fails, the two copies have real behavioral drift -- stop and report
  before merging them.
- PO2 (I2): damage recorded after a full-escalation-and-drain cycle and
  after a plain drain still surfaces. The existing `TerminalDamageTests`
  drain/re-arm cases pin the plain-drain leg. The escalation leg needs a
  new production-path test that escalates through the shared
  region-mismatch branch, not through `recordFull`: record shifts for two
  different regions with no intervening drain, observe `.full`, drain,
  then record ordinary row damage and require the next drain to surface
  it. Without this leg an implementation can spell the mismatch branch
  `self = .full`, discard the grid-sized bitset, and silently stop
  recording every later row.
- PO3 (I3): the existing out-of-range exit test only constructs a value
  from out-of-range rows; it never calls `recordShift`. Extend it with
  out-of-grid shift regions on a grid-sized `TerminalDamage` -- one below
  the lower bound and one past the upper bound -- so the shift
  precondition is proved rather than assumed. Without this the merge can
  drop the precondition with every named test still green, letting
  `translate` index outside `words`.
- PO4 (I4, I5): the existing `TerminalShiftDamageTests` (both suites,
  including the scroll-driven `TerminalScrollShiftDamageTests`) and
  `TerminalDamageTests` pass without assertion changes. One test comment
  names the deleted type and may be reworded. Those suites inspect
  drained damage, so they do not reach the `recordShift` change-reporting
  contract; add a production-path test that isolates a shift as the only
  newly represented change -- vacated and cursor rows already pending --
  and requires `pendingConsumerWorkGeneration` to advance, plus a
  negative leg where a shift absorbed into pending damage leaves the
  generation alone.
- PO5 (accepted risk AR1): `just benchmark-quick baseline=HEAD
  workload=scrollback-stream` before and after; per
  `agent-docs/measurement-discipline.md` and the noise table in
  `agent-docs/terminal-performance.md`, distrust differences under 3.5
  points on this workload.

## Non-goals

- FRAME-3's public predicates: the viewport-coverage check stays
  internal; promoting it to the public surface is FRAME-3's decision.
- FRAME-4's inline row storage.
- Any change to what damage consumers observe or to the shift contract.

## Accepted risks

- AR1: The accumulator's word-storage reuse across drains is believed
  notional (draining hands the words to the returned value, so the
  subsequent clear copies on write anyway), but this is measured (PO5),
  not argued. A real regression on `scrollback-stream` reopens the
  design.

## Rejected ideas

- RI1: Keep the accumulator as a thin wrapper holding a `TerminalDamage`.
  Leaves two types and a second home for future members, so the drift
  this fix removes stays representable.
- RI2: Keep both types and share only a bitset-level composition helper.
  Leaves two `==`, two `isFull`/`shift` pairs, and two drain state
  machines.

## Implementation discretion

- Naming and exact spelling of the internal producer members (e.g.
  whether `Terminal.hasPendingConsumerWork` keeps a `hasDamage` spelling
  or reads `isEmpty == false`).

## Critical files

- `lib/TerminalCore/Sources/TerminalCore/TerminalDamage.swift` -- the
  merge; `TerminalDamageRowBits` is untouched except possibly gaining the
  coverage query the accumulator's viewport check currently spells by
  poking `words` directly.
- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` -- the stored
  `damage` property and its eight touch points (init, reset, drain,
  record/recordFull/recordShift, coverage check, pending-work query).
- `lib/TerminalCore/Tests/TerminalCoreTests/TerminalShiftDamageTests.swift`
  -- gains PO1; its out-of-range exit test gains PO3's shift regions.
- `lib/TerminalCore/Tests/TerminalCoreTests/TerminalDamageTests.swift`
  -- home for PO2's escalation leg and PO4's generation test; one comment
  names the deleted type.

## Verification

1. Write PO1, run it against the unmodified tree, confirm it passes
   (characterization, not TDD-red -- a failure is a drift finding, not a
   step).
2. `swift test --package-path lib/TerminalCore` green after the merge.
3. `just test` for the full gate.
4. PO5 benchmark comparison; report the numbers either way.

## Implementation notes

- PO1 passed against the unmodified tree on the first run, so the two copies
  had no behavioral drift on the collapse branch and the merge is a pure
  deduplication.
- I2 is carried by one private `escalateToFull()` that sets the flag and clears
  the words in place, replacing both `self = .full` sites in `formUnion` and
  `applyShift`. Drained and unioned full values now keep their grid height
  instead of dropping to a zero-height bitset. Nothing observes that: every
  consumer path either short-circuits on `isFull` or compares rows through the
  width-independent `==`.
- I3 is met by keeping the value type's shift precondition on the merged
  `recordShift`, which the accumulator never had. `Terminal` only ever passes
  `activeScrollRegion`, which `setScrollRegion` clamps to the grid.
- PO2 and PO4 were each confirmed non-vacuous by ablation: spelling
  `escalateToFull()` as `self = .full` fails PO2, and returning `false` from
  `recordShift` fails PO4.
- `hasDamage` is gone; `Terminal.hasPendingConsumerWork` now reads
  `damage.isEmpty == false`, which is the same predicate.
- The accumulator's hand-rolled viewport scan moved to
  `TerminalDamageRowBits.covers(rowCount:)`, so the check no longer reaches
  into `words` from outside the bitset.
- PO5 measured, `just benchmark-quick baseline=HEAD workload=scrollback-stream`:
  the clean-tree A/A control read -3.24% (inconclusive) and the merged tree read
  -3.27% (inconclusive). The two are 0.03 points apart and both sit well under
  the 3.5-point noise floor for this workload, so AR1's word-reuse regression
  did not appear.
