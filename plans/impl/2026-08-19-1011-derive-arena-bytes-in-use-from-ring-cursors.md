# Derive arena bytes-in-use from the ring cursors

Source finding: STORE-1 in `docs/scratch/2026-08-18-construction-audit.md`
(its Starter kit collapsible holds the site-by-site walkthrough and is the
implementer's companion to this contract).

## Problem

`Terminal.LogicalLineStore` (`lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift`)
stores `bytesInUse`, the arena term of `chargedBytes` -- the number that
bounds history eviction against the scrollback budget. Twelve mutating
functions (13 statements) add or subtract it by hand, and it is the one
maintained total in the file with no owner and no oracle: the side-table
charge has a `census` recount assert, and the row/content grand totals were
already made derived (commit `1c6bcf1f`).

Two of the twelve paths leak. When the write cursor rewinds to before a
pad record -- `dropTailRecord` on the record preceding a pad, and the
rewind in `reopenTailRecordForTruncation`/`reopenClosedTail` on a
forced-split record ahead of a pad -- the accompanying subtraction covers
only the record's own bytes, not the pad the rewind skipped. Both paths are reachable from `truncateTail(displayRows:)`, which
resize and reflow call. The leaked charge is never recovered short of a
full clear, and the next wrap charges a fresh pad over the same region, so
repeated resizes make history charge more than it holds and evict earlier
than the budget requires.

The premise that makes the fix sound (vetted in the audit, re-verified
against the current tree): every mutator already moves `head` and
`writeCursor` correctly, every seam is covered by a pad, `head` always
names `offsets[0]`'s offset, and both drop paths call `resetToEmptyArena()`
(which zeroes both cursors) when the store empties. So the in-use region
*is* the ring span `[head, writeCursor)`, disambiguated empty-vs-full by
`offsets.count`.

## Decision

Delete the stored `bytesInUse` field and all thirteen of its mutation
statements. Replace it with a computed property that returns the ring
distance from `head` to `writeCursor` (zero when the record index is
empty), and re-spell `writeCursorPrecedesHead` on `offsets.count > 0`
instead of `bytesInUse > 0` (the old spelling would be circular under the
derived form). No public surface moves: `census.arenaBytesInUse`,
`chargedBytes`, and `TerminalMemoryCensus` keep their spelling and
meaning. This continues the direction commit `1c6bcf1f` set for the grand
totals, and is the fix-by-construction: a byte the cursor skips over can
no longer stay charged, because the charge is the cursor distance.

Comments that state the stored-counter contract must not survive it: the
`reopenTailRecord` comment forbidding a rewind past a pad as a
double-charge hazard (the rewind is now safe; the guard is about the
forced-split bit), the `wrapWriteCursorAtSeam` "can never drift" charge
comment, and `dropHeadRecord`'s span-arithmetic comment. `chargedBytes`'s
doc gets its arena term restated as the ring span.

## Invariants

- I1. The arena charge equals the ring span `[head, writeCursor)`: any
  mutation that moves arena bytes without moving their charge is
  unrepresentable.
- I2. An empty store holds `head == writeCursor == 0`, so empty and full
  rings stay distinguishable by record count (`writeCursor == head` with
  records retained reads as a full arena, `arenaCapacity`).
- I3. A tail truncation that rewinds the write cursor across a seam pad
  gives the pad's bytes back: a store that truncates and then readmits
  equivalent rows ends in the state it would hold had it never truncated,
  so its subsequent charge and retention depth match that untruncated
  store's exactly. (Charge parity is claimed only between stores with
  identical physical placement -- seam pads are charged bytes, so two
  stores holding identical content at different arena alignments may
  legitimately differ in charge.)
- I4. Everything already observable is unchanged: `chargedBytes` remains
  the eviction bound, and `census.arenaBytesInUse` reports the same values
  on every non-leaking path as before.

## Proof obligations

- PO1 (I3, the bug -- write these tests first and watch them fail):
  cloned-state round-trip tests in the `Logical-line record arena` suite
  (`lib/TerminalCore/Tests/TerminalCoreTests/TerminalLogicalLineStoreTests.swift`).
  Build a store to just before a targeted seam rewind and copy it (the
  store is a value, so a copy is an assignment); run truncate-and-readmit
  on the subject copy only; then feed identical further rows to both
  copies and compare retained display-row depth and folded scalars. The
  clone pins identical physical placement, so a correct implementation
  must match exactly, while today the subject's leaked pad charge forces
  earlier eviction. The fixture must force divergence under the bug:
  repeat the truncate-and-readmit cycle to accumulate leaked pads (or
  size the pad above the follow-on rows' per-row cost) so the over-charge
  crosses an eviction boundary -- a single small leak under a roomy
  budget passes without failing -- and use plain-cell content so no
  charge outside the arena span (open scratch, side tables) moves. Two
  scenarios are required, one per leak site: `dropTailRecord` on the
  record preceding a pad, and the cursor rewind through
  `reopenTailRecordForTruncation`/`reopenClosedTail` on a forced-split
  record (the guaranteed-pad case), observed through `truncateTail`'s
  cut path. In one scenario -- both run wrapped by construction -- also
  pin the absolute charge: assert `census.arenaBytesInUse` equals a
  value computed from the pinned cost literals at one known-wrapped
  point, because clone comparisons alone cancel a systematic error in
  the derived formula's wrapped branch and no existing exact-byte test
  runs wrapped.
- PO2 (I1, I4): the existing charge suites stay green unchanged --
  `TerminalLogicalLineStoreTests` (budget bound, census decomposition,
  close/reopen charge identity, ring cycling, seam splits, exact retention
  depth), `TerminalScrollbackBudgetTests` (exact per-record byte equality,
  ED 3 reset), `TerminalRegionScrollbackTests` (exact `lineCost`
  equalities). The audit found no existing test that names the private
  field or cursors, so none should need edits. Caution:
  `maintainedChargeAgreesWithARecount` cannot catch arena-term drift (its
  recount reuses the same term); it guards only the side tables and is not
  the safety net here.
- PO3 (I2): covered by existing tests -- `censusSeparatesCapacityFromBytesInUse`
  (0 when fresh), `eraseDisplayThreeResetsBudgetState` (0 after clear) --
  plus a by-hand check of the full-ring edge (`writeCursor == head`,
  records retained) before landing.

## Non-goals

- STORE-2 (delete `PackedRetainedRow`) and STORE-3 (cell-word type) --
  sequenced after this change by the audit; they touch the same file but
  not these expressions.
- The audit's cheaper fallback (keep the field, patch `dropTailRecord`,
  add a recount oracle) -- rejected: it leaves twelve maintenance sites
  and pins only the one bug already found. This plan is the ideal form.

## Rejected ideas

- Keeping `writeCursorPrecedesHead` reading the derived property: the
  derived property is defined in terms of that same disambiguation, so the
  old spelling becomes circular; it must read `offsets.count` directly.

## Accepted risks

- The derived form puts two comparisons and a subtraction on the write
  path (`chargedBytes`, once per admission and once per eviction step)
  where a field load was. Cheaper than the maintenance it replaces, and
  `1c6bcf1f` already made this trade on the same file's other totals.

## Implementation discretion

- The computed property's name (`bytesInUse` unchanged vs.
  `arenaBytesInUse`) and its doc comment, modeled on
  `grandDisplayRowTotal`'s.
- Whether to add a byte-level pin
  (`subject.census.arenaBytesInUse == control.census.arenaBytesInUse`)
  beside PO1's row-depth comparison; between clones it is sound, and the
  row-depth form remains the one that states the user-visible harm.

## Verification

1. Write PO1's two tests, run
   `swift test --package-path lib/TerminalCore --filter TerminalLogicalLineStoreTests`,
   and confirm each fails with the subject retaining fewer rows than its
   clone (the leak, not a fixture error).
2. Make the change; the same filter run goes green, including PO1.
3. `just test` for the full gate.

## Implementation notes

- The computed property keeps the name `bytesInUse`, so `chargedBytes` and
  `census` read exactly as before and the diff is the deletion the plan
  describes plus one new declaration.
- Two parameters died with the arithmetic that used them and were removed:
  `dropTailRecord`'s `record` (only `record.byteLength` used it) and
  `dropHeadRecord`'s `offset` (only the span subtraction used it).
- PO1's two fixtures are tuned to land the rewind on a seam pad, which is a
  property of the geometry rather than of the API: 213 hard-ended eight-cell
  lines at width 16 for the drop path, and 157 soft-wrapped rows at width 12
  for the reopen-and-cut path. Both were found by instrumenting the two leak
  sites with a stored-versus-derived comparison, running the search, and then
  removing the instrumentation. Each test says in a comment why its counts are
  what they are.
- The absolute charge pin asked for by PO1 sits in the drop-path test:
  `arenaBytesInUse == 72 * recordCount + 96` at the wrapped point, where 72 is
  the 8-byte header plus eight 8-byte cells and 96 is the pad that fixture's
  seam remainder leaves.
- PO3's by-hand full-ring check: with records retained and
  `writeCursor == head`, the derived property takes its wrapped branch and
  returns `arenaCapacity - head + writeCursor == arenaCapacity`, and the empty
  store is cut off by the record-count guard above it.
- `reopenTailRecord`'s guard comment was rewritten to the reason that survives
  the change: a forced split's marker already reads as a line that continues,
  so a resumed print has no wrap claim to restore, and clearing the bit would
  only lose that reading.
- `openRecordIfNeeded` now advances the write cursor past the header before
  `appendRecordOffset` names the record. The old order left one statement in
  which a store with one record still held `writeCursor == head`, which the
  derived property reads as a full arena. No caller read the charge there, so
  this changes no behavior; it keeps the ring span honest at every statement
  boundary instead of only where a reader happens to be.
