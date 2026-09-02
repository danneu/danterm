# A retained record is one whole logical line

## Problem

`LogicalLineStore` cuts a logical line into pieces in two places, and every
cut is a display-row boundary at the admitting width only:

- `admit` closes the open record with the forced-split bit when the next row
  would push it past `forcedSplitCellCap`, 1/32 of the budget
  (`lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift:763-769`,
  `research/31/I10`, `research/31/DD3` at
  `docs/research/31-logical-line-scrollback/decisions.md:1655`).
- `wrapWriteCursorAtSeam` closes the open record with the same bit and writes
  a header-only pad when the next row would cross a chunk boundary or the
  arena's physical end (`LogicalLineStore.swift:3170-3205`, `DD14` and `DD20`
  at `decisions.md:1683-1741`, `D5` at `decisions.md:3106`).

The fold is a function of (record, width). At any width that does not divide
the cut, the piece's last display row ends short of the margin while
`isSoftWrapped(at:)` still reports it as continuing
(`LogicalLineStore.swift:2304-2308`).
`TerminalStateSynchronizationEncoder.swift:647-651` holds
`precondition(..., "a projected soft-wrapped row must reach its margin")`, so a
remote client claiming a pane that holds such a line trapped the Mac app
(DanTerm 0.1.25, 2026-09-01). The same shape shows in scrollback as a premature
line break at every seam after a resize.

The cut's reasons are gone or traded away. `DD3` bounded eviction undershoot
and the wide-cell scan to one record (`findings.md:599-660`). Eviction is now
display-row granular through `trimHeadRecord`
(`LogicalLineStore.swift:978-1043`), so the undershoot reason is gone. The scan
bound is real, and this plan gives it up on purpose: a giant wide line is walked
whole by `locate`, the pull-back, and reopen, at the cost AR1 measures. The
chunk-seam cut exists so hot loops hoist one chunk pointer
(`decisions.md:3106-3112`); that is copy granularity, not line structure. The
forced-split and pad bits reach no wire, recording, or protocol type: they live
in the store, the record header, `TerminalSearch`'s three "record ends a line"
reads (`TerminalSearch.swift:279,651,707`), and test accessors.

Desired outcome: a retained record is always one whole logical line, so no
width can expose a cut, and the encoder precondition becomes unreachable from
retained history.

## Decision

A record is the ring interval `[offset, offset + byteLength) mod arenaCapacity`.
It may straddle chunk seams and the wrap point. There is no cell cap, no seam
cut, no pad record, no forced-split bit. A line longer than the arena is one
record that is both the retained head and the open tail: eviction trims its
oldest display rows while admission extends it, which is what engine doc D11
already states (`docs/design/2026-08-06-swift-terminal-engine.md:155`).

What changes, as requirements:

- The chunk is copy granularity only. Any read or write may cross a chunk seam
  or the wrap point; a whole-record walk is a walk over per-chunk segments.
  Backing materializes as the write cursor first reaches it, not when a record
  opens.
- The seam machinery (contiguous-room test, pad, physical-end split) goes.
  Making room means evicting one display row at a time until the ring bytes and
  the charge fit, or resetting an empty store.
- The admissibility unit is the arena: the only refused row is one that cannot
  fit the arena at all.
- The header stays one 8-byte word. Its cell-count field expresses the
  arena's cell capacity (~1.97M cells at the production budget, so at least 21
  bits); the freed split and pad bits and the table-count fields pay for it. A
  budget whose cell capacity exceeds the header's cell field or the cell
  word's spill field is refused at init.
- Side tables never cut or degrade a line. Identity already has a per-cell
  mode; hyperlinks get one. A table switches to per-cell mode when its run
  entries would cost more bytes than per-cell (today's trigger) or when its
  entry count would overflow its header field, so a line of any retained
  length keeps every entry.
- **Every index-addressed payload resolves through one head-relative base.**
  Spill indices in cell words, hyperlink keys, and identity keys (run and
  per-cell) resolve through a base that a head trim advances as it releases
  the prefix payloads; the trim rewrites no surviving cell word and no
  surviving table content, and every key field's range covers the arena's cell
  capacity. The base persists with the record across close and reopen and
  costs a record without tables or spills nothing (D2). This is what lets a
  line longer than the arena be trimmed at the head while open: the scratch
  tables shrink as cells leave, both the flushed per-cell table and the
  admission reservation `projectedTableBytes` makes are sized by retained
  cells, never by the cells the line has had in total, and the spill field
  never overflows however many graphemes the line has spilled in total.
- `TerminalSearch`'s three "record ends a line" reads become unconditional.
- `rebased(toBudgetBytes:)` replays through the admission shape, so a record
  larger than the target arena rebases without trapping.

Decisive constraints:

- **D1.** The chunk stays the copy-on-write unit: a mutation copies only the
  chunks it writes and never an untouched chunk. An ordinary row keeps today's
  small bound (PO10); a giant admissible row copies chunks in proportion to its
  own encoded size, which I9 permits.
- **D2.** The header stays one 8-byte word; a blank line still costs 8 arena
  bytes and 8 index bytes.
- **D3.** Side tables never cut, drop, or truncate an entry because a line is
  long.
- **D4.** Budget accounting is unchanged: `chargedBytes` is bounded by
  `capacityBytes`, the charge is the ring span plus the maintained terms, and
  the metadata reserve stays.
- **D5.** The per-frame cost contract holds: one `locate` per frame, and a row
  that lies in one chunk keeps today's single-hoist raw-pointer loop
  (`withPaintedCells` :2052-2120, `forEachKind` :2141).
- **D6.** Wrap is one compare-and-subtract of `arenaCapacity`, never a
  division; the arena need not be a power of two.

Scope: `LogicalLineStore.swift`, `LogicalLineRecord.swift`,
`TerminalSearch.swift`, their tests, and the docs named below. The public
coordinate stays an absolute display row; `RecordTextPosition` stays (record
identity, original cell offset).

## Invariants

- **I1. Every continuing row reaches the margin.** After any sequence of
  admission, width change, head eviction, tail truncation, reopen, and rebase,
  at any width, a retained row reports soft-wrapped only when its projected
  cells fill the width, or fill `width - 1` and end in a spacer head.
- **I2. The fold is invariant under placement.** For one line's cells `C` at
  width `W`, the retained rows equal the live grid's rows for `C` at `W`
  whatever the record's arena offset, chunk seams it straddles, or wrap point
  it crosses: cells, kinds, styles, spacers, the semantic mark on the first row
  and continuation marks after, the trailing fill on the last row, and the
  one-row floor for a zero-cell record.
- **I3. Index additivity.** Each display row belongs to exactly one record;
  block totals and `grandDisplayRowTotal` equal `independentDisplayRowRecount()`,
  and content-unit totals equal their recount, through every operation.
- **I4. Eviction and truncation are display-row granular.** One eviction step
  removes exactly one display row and makes progress: it trims at least one
  cell off the head or drops a record; the sole open record is dropped, not
  trimmed, when a row consumes it. Tail truncation of a row that begins inside
  a record reopens that record.
- **I5. A width change writes nothing outside the open tail.** The pull-back
  hands the live grid the tail's partial last row; no other retained byte moves
  and nothing is evicted.
- **I6. Text and search coordinates are unaffected.** `fullHistoryText`,
  search hits, `contentRank`, and `RecordTextPosition` round trips resolve the
  same cell before and after this change, across a record that straddles a
  seam or the wrap point, and a position taken on a cell that stays retained
  resolves to that cell through head trims, close, and width change of its
  record. A **reopen** retires it instead: see the Outcome note dated
  2026-09-02.
- **I7. Store equality ignores placement, not state.** Two stores with equal
  budget, width, eviction origin, pending-tail state, and decoded retained
  content (cells, payloads, tables, marks) compare equal however their ring
  cursors got there and however their bases differ. Raw segmented comparison
  is the fast path where the bytes are canonical; a record where any base
  (cells, spills, or table keys) differs between the two sides compares
  decoded, as the trimmed head already does today for table keys, and spills
  compare as the retained cells' decoded payloads, never as whole arrays.
- **I8. No table entry is lost or truncated.** Every hyperlink id and content
  identity a cell was admitted with reads back, at any line length the arena
  can hold.
- **I9. The refused row is the one that cannot fit the arena.** A budget too
  small for one display row retains nothing and keeps running; any row that
  fits the arena is admitted.

## Proof obligations

- **PO1 (I1).** The crash reproduction: `Terminal(columns: 20, rows: 4,
  scrollbackBudgetBytes: 1 << 16)`, feed 4,000 `x`, resize to 53 columns, round
  trip `stateSynchronization` onto a replica; screen and history text agree.
  A store-level check that every soft-wrapped retained row reaches the margin,
  run over a long line at several widths that do not divide the admitting
  width, after eviction into the line and after truncation into it.
- **PO2 (I2).** The live-grid oracle in `TerminalLogicalLineFoldTests` over a
  line that straddles at least one chunk seam and the wrap point, with narrow,
  wide, and spacer-at-seam content, a trailing fill, a semantic mark, and a
  zero-cell record, compared at the admitting width and at changed widths. The
  three readers (materialized, borrowed cells, kinds) agree on a row that
  straddles a chunk seam and on one that crosses the wrap point. Style
  liveness: the reclamation test gains a style used only by retained cells
  after a chunk seam and one used only after the wrap point; both survive
  reclamation and the rows still render with them.
- **PO3 (I3).** The existing index-vs-oracle recounts through admission, width
  change, eviction, truncation, reopen, and full ring cycles at a multi-chunk
  budget (`ringCyclesAcrossChunkSeamsAndKeepsItsRetainedSuffix` keeps its
  intent: the retained suffix reads back cell for cell).
- **PO4 (I4).** A line longer than the arena: admission keeps running, the head
  trims one row per step, the charge never passes capacity, the head reads as a
  mid-line continuation with no mark, and the retained suffix matches the same
  history rebased through `rebased(toBudgetBytes:)`. Eviction of a store whose
  only record is open and shorter than one row drops it. Reopening a tail whose
  bytes wrap round the arena appends in place.
- **PO5 (I5).** `widthChangePullsBackTheOpenTailsPartialRow` kept, plus the
  same with the pulled row straddling a chunk seam and the wrap point;
  `Terminal.resize` reflows a long line identically to the same line under a
  budget it never filled.
- **PO6 (I6).** Search tests over a line that straddles a seam and one that
  exceeds the old cap; a `RecordTextPosition` round trip through a changed
  width for an offset past a seam; a `RecordTextPosition` captured on a cell of
  a beyond-arena open line, checked after repeated head trims into that line,
  after close, after reopen, and after a width change, resolving the same cell
  each time.
- **PO7 (I7).** Two stores fed the same rows from different ring positions
  compare equal; `==` on a straddling record agrees with a decoded comparison;
  two stores at the same eviction origin that reach the same retained suffix
  of one giant line through evicted prefixes with different spill, hyperlink,
  and identity populations compare equal, and differ once one retained payload
  differs.
- **PO8 (I8, D3).** A line longer than 65,535 cells with hyperlinks and content
  identities on cells past that offset reads every one back after close, after
  a head trim into the line, and after reopen; the side-table charge stays
  inside the reservation `projectedTableBytes` made. An open line longer than
  the arena whose cells carry spilled graphemes, hyperlinks, and identities,
  driven through repeated head trims, a close, and a reopen: admission keeps
  running and the head trims one row per step, every retained cell reads back
  its payload, the spill and table charge is bounded by the retained cells
  (not the total fed), and the cell word's spill field never reaches its limit
  even when the line spills more graphemes than the field can count.
- **PO9 (I9, D2, D4).** `TerminalScrollbackBudgetTests` retains-nothing case
  keeps passing; a budget the header cannot express is refused at init; the
  blank-line depth at the production budget is unchanged; the memory census
  over a straddling record counts each cell once.
- **PO10 (D1, D5).** `publishedValueThenAdmitCopiesOneChunkNotTheWholeArena`
  keeps its bound (copied chunk bytes <= capacity / 4), and a variant admits a
  row that straddles a seam. `just benchmark-quick baseline=<pre-change sha>
  workload=retained-browse` is the directional gate (1.05% threshold) and must
  not report `slower`; `scrollback-stream` is collected descriptively only. No
  workload feeds a straddling row or a giant line, so
  `Instrument.rowBoundaryCellWalk` exact walk-count assertions
  (`TerminalLogicalLineStoreTests.swift:1949,1980,2290,2351,2429`) are kept
  and re-derived for the whole-line shape, and `TerminalLogicalLinePathologicalProbe`
  keeps its unbounded single-line stimulus as the opt-in measurement.

## Non-goals / Accepted risks / Rejected ideas

- **NG1.** The encoder precondition and its failure mode (trap versus refused
  sync) are out of scope. It stays as written.
- **NG2.** No protocol, recording, or wire change.
- **NG3.** No change to the budget, the metadata reserve, or the chunk-size
  rule (`DD53`). The fixed budget is load-bearing: the cell word's 21-bit
  spill field clears the production arena's ~1.97M cells by about 6%, and the
  init refusal is what makes a larger budget fail loudly.
- **AR1.** A giant line with wide cells is walked whole by `locate`, the
  width-change pull-back, and reopen. The cap bounded that walk to 65,536
  cells per record; a line that fills the arena is ~1.97M cells at the
  production budget, so one locate on such a line costs a few milliseconds
  (`findings.md` measured ~1.95 ns per cell). Accepted: it is once per frame,
  only on a line that is both giant and wide, and the walk-count tests pin the
  operation count. Reopen if a real workload shows it.
- **AR2.** A row that straddles a chunk seam takes the general per-word path
  instead of the single-hoist loop. A row is at most `width` cells, so at the
  production chunk size this is under 1 row in 300 at 179 columns.
- **AR3.** The head-relative window is the one place a stale base or a missed
  prefix release can hide, and it only shows on a giant line. PO8's
  beyond-arena case is the guard.
- **RI1.** Keep the cut and treat a forced split as a hard line end. Copy and
  reflow would break one printed line into two.
- **RI2.** Keep the cut and fold rows over runs of split records
  (`backup/run-fold`). It repairs every reader for cuts made for reasons that
  no longer hold, and keeps the seam census, the pad, and the bit.
- **RI3.** Cut only at the physical end. One seam still exposes the same short
  row once per ring cycle.
- **RI4.** A 16-byte header. Doubles the blank-line cost `research/31/D2`
  Decision 1 priced the budget on.
- **RI5.** Stop recording hyperlinks or identities past 65,535 cells. Silent
  loss.
- **RI6.** A power-of-two arena so wrap is a mask. The capacity is the budget
  less the reserve; rounding it would change the bound.

## Documentation

Amend `docs/research/31-logical-line-scrollback/decisions.md`: `I10`/`DD3`
(`:1655`), `DD6` (`findings.md:1120`), `DD14` and `DD20` (`:1683-1741`), `D5`'s
"a record never straddles a chunk" clause (`:3106`), and `DD54` (`:3305`).
Rewrite the store's file header and its D5 comment (`LogicalLineStore.swift:1-29,
179-189`), `chunkByteShift`'s doc (`:580-609`: chunk size is copy granularity
only), and `LogicalLineRecord.swift`'s header layout. Engine doc D7's fold
reading becomes "(line, width)" (`2026-08-06-swift-terminal-engine.md:151`).

## Tests at HEAD that pin the cut

Tests that assert a forced split, a pad, or a seam cut are rewritten under the
proof obligation that carries their invariant (mark once and fill last: PO2;
head trim stamps mid-line and ring wraps keep every cell: PO4; truncation and
tables across a former split: PO5, PO8; search joins a long line: PO6; census
counts a cell once: PO9). The test-only split API goes with the bits.
`TerminalLogicalLinePathologicalProbe` keeps its giant-line stimulus and drops
its piece-count expectations.

## Implementation discretion

- The per-chunk segment iterator's shape, and how `word`-level access chooses
  between the hoisted loop and the general path.
- The per-cell hyperlink table's entry width and the header's field split,
  provided D2, D3, and I8 hold.
- Where a record's base is stored and how keys wrap. Only the head record is
  ever trimmed and a record leaves the head only by being dropped, so one
  store-level head scalar per key space (as `headTrimmedCells` is today), set
  when a trimmed open record closes and reset when the head drops, may be
  enough; per-record storage is not required. Any choice must satisfy the base
  requirement and D2.
- How `recordSearchBoundaryWindow` bounds its scan of a long record.

## Commit progress

- [x] 1. fix(terminal): store retained logical lines as whole records

## Outcome

Measured against `be9fdeb2` before the commit. Two rounds of optimizing sat
on top of the first implementation, neither of which touched the decision.

The PO10 gate first read `retained-browse: slower (+1.99%)`. The frame-path
reader `withPaintedCells` had been rewritten around an `@escaping` accessor
closure, which heap-allocated a context per row and made every cell an
indirect call; it also built a temporary `TerminalScalars` per cell through
`.map(...) ?? .empty`, and captured a buffer plus an offset where one hoisted
pointer would do, pushing an argument to the stack on every cell call. The
row's accessor is a non-escaping `@inline(__always)` helper again, the
optional is an explicit branch, and the closures capture one pointer. Five
pooled quick runs then read equivalent (-0.5% to -0.8%).

The first confirm then found `terminal-feed` slower by 11.47% and the
`scrollback-stream` drain 13.6% slower. All of it was on the admission path:

- `appendCells` had lost the D5 hoist and wrote every cell through `setWord`,
  re-deriving the chunk and checking both arrays per cell. It writes through a
  swapped-out chunk again, one chunk segment at a time, so a straddling record
  still works.
- `admit` counted the row's hyperlinks and identities to size the reservation.
  The reservation only needs a bound, so the stored cell count is passed
  instead and the second scan of every row is gone.
- `flushOpenTables` allocated two clipped arrays per close; it clips as it
  reads now.
- `trimHeadRecord` scanned every evicted cell for spills; it skips records
  with no spill table.

Final confirm: `terminal-feed` inconclusive (+0.87%), `retained-browse`
inconclusive (-0.86%), `scrollback-stream` drain +2.25% descriptive, every
other workload equivalent. PO10 holds: no workload reports `slower`. The
terminal-feed residual sits inside the inconclusive band and is on record
here rather than resolved.

**I6 and the reopen, 2026-09-02.** I6 first said a coordinate survives a reopen
of its record. It does not, and the implementation is right: `reopenClosedTail`
renews the record's identity, so every `RecordTextPosition` taken before the
reopen resolves to nothing afterwards. That renewal is what `TerminalSearch`
reads as a regressed tail, which is how it drops the matches it had indexed into
a record whose text can now change again. Keeping the coordinate alive would
hand a stored match back over text the reopened line may overwrite -- the
failure `RecordIdentity` exists to prevent. I6's list drops "reopen"; the
retirement is asserted by
`recordCoordinateOnABeyondArenaLineResolvesTheSameCell`'s last leg.

**Review follow-ups and re-measurement, 2026-09-02.** A review of `87d8ae46`
found six defects that broke stated invariants and two commits fixed them:
`320ac8c5` (a zero-cell record whose header ended a chunk trapped the frame
path; `reopenClosedTail` and `resetToEmptyArena` leaked the head's table base;
the side-table reservation missed the count-overflow per-cell switch, so
`chargedBytes` passed `capacityBytes`; `==` compared a base-relative spill
index and a trimmed head's whole-line header bits; `rebased` marked every row
after the first as mid-line; the search boundary window walked a giant record
whole; the open-line trim did per-entry work per evicted row; plus the PO1,
PO2, PO4, PO6, and PO8 tests this plan required and the commit had not added)
and `a1389b35` (I9: `admit` priced the row together with the whole open line's
projected tables and refused before evicting, which lost rows of a plain line
at small budgets; it prices the row alone now). B2's ideal, a deque for the
open scratch, was not taken: `Deque` in the pinned swift-collections publishes
no `capacity`, so its charge could not be priced exactly, and a `RingBuffer`
sibling with a published capacity is the route if the memmove per evicted row
ever shows.

Measured again at `a1389b35` against `be9fdeb2`, quick then confirm. Nothing
reads `slower` in either mode.

| Workload | Quick | Confirm |
|---|---|---|
| terminal-feed | equivalent +0.43% | inconclusive +1.16% |
| scrollback-stream | descriptive -5.35% | descriptive +3.02% |
| content-churn | inconclusive -1.93% | inconclusive -0.79% |
| style-churn | equivalent +0.18% | inconclusive -0.87% |
| incremental-mixed | descriptive -17.87% | descriptive -4.80% |
| retained-browse | faster -1.28% | inconclusive -1.02% |
| kitten-feed-ascii | inconclusive -1.27% | faster -1.95% |
| kitten-feed-unicode | equivalent -0.27% | equivalent -0.19% |
| kitten-feed-unique-unicode | equivalent -0.93% | inconclusive -0.85% |
| kitten-feed-csi | equivalent -0.41% | inconclusive -0.86% |

The scrollback-stream drain's +3.02% sits inside its own A/A spread (median
+0.75%, SD 6.23%, `research/39/F9`) and its drain and draw-tail legs are within
a millisecond of baseline, so it claims nothing. The retained-browse quick
`faster` is not confirmed: -1.02% falls in the 0.75%-1.05% gap the ladder
cannot resolve, so it is "no change". The terminal-feed residual is +1.16%
now, still inside the inconclusive band. `kitten-feed-ascii` is the one
settled improvement.
