# Logical-line scrollback store

The design this plan implements is adjudicated in
[docs/research/31-logical-line-scrollback/](../../docs/research/31-logical-line-scrollback/README.md);
`31/D2`, `31/F6-HR1` and the like cite its decisions and findings, `28/...`
cites doc 28. Rationale, alternatives and the evidence behind every claim below
live there and are not restated here.

## Problem and desired outcome

Retained history stores display rows with wrapping baked in, so a width change
must mutate every retained row (`28/F15`: `1.85 us x rows + 0.352 us x cells`).
That is why depth is latency: ~10,000 rows of 179-column content costs a
measured 600.5 ms synchronous reflow (`28/F23`), and the cell and row caps
shipped as a dogfood trial in `28/D11` exist only to bound that product.

Desired outcome: history holds one record per logical line a program printed,
wrapping is derived at read from (record, width), and a width change stops
walking or rebuilding retained history -- its only arena write is the bounded
open-tail seam repair I11 requires, and the remaining resize work is refolding
the live screen and one pass to recount display rows. Deleted with it: reflow of history, both caps
and their `28/D8` derivations and tests, narrow-then-widen eviction machinery,
and per-display-row continuation bookkeeping.

Load-bearing premises, each measured in Phase 1 and each carried into a proof
obligation below:

- the read path is faster in isolation, not slower (`31/F1`);
- the eager counting pass that replaces reflow is milliseconds at every depth
  the budget admits (`31/F2`, `31/F7`);
- admission gets cheaper, including on `scrollback-stream`'s own row shape
  (`31/F3`);
- 28 catalogued edge cases, none requiring width-dependent data in history
  (`31/F4`);
- the simplification inequality holds on invariants, and it holds on their
  *shape* rather than their count: the contracts deleted are cross-cutting --
  between the store and every reader, or between a resize and every anchor
  holder -- while the ones added are local to the store, each with a single
  enforcing site and testable by one gate (`31/F5` as amended by `31/D3`). The
  tally itself is too close to carry the argument, which is why `31/DD8` is
  re-read against the landed implementation rather than quoted (Gates below).

Every Phase 1 number is a microbenchmark. `31/D1`'s `go` licenses design work,
not a production storage change; what licenses landing is Acceptance below.

## Decision

One contiguous per-pane byte arena of variable-length logical-line records
(content-only header, C1 cells, style runs), plus a derived index -- per-record
offsets, per-block cached display-row totals, one grand display-row total --
that is a cache, recomputable from the arena alone and discarded rather than
migrated at a width change. Admission appends a scrolled-off row to the open
tail record; eviction is byte-driven and display-row granular at the head; the
byte budget is the only bound and the arena's capacity is that budget.

Behavioral scope: retained history and the call sites that address it by display
row (69 enumerated in `31/F6`). One of them changes denomination rather than
address: `scrollbackRowContentIdentityShape` becomes per record rather than per
display row (`31/D3` Decision 6, `31/DD17`), so `31/DD9`'s "the public coordinate
does not change" holds everywhere except in that reader's sample unit, whose
consumers are two test suites and doc 28's `PR1`. Out of scope by construction:
the live grid's refold, which survives; the alternate screen, which has no
scrollback; the checkpoint/persistence path, which serializes history as text;
and the C1 cell format (`28/D9`, `28/D10`), which is not reopened.

**Milestone 1 -- the store.** Arena, derived index with eager whole-index
recompute at a width change, open-line admission, head-granular eviction, the
read-time fold, and the caps' deletion. The projection facade keeps
materializing a row per pointer query (`31/D3` Decision 5): the per-frame path
already borrows and never goes through it, so milestone 1 lands the arena on
exactly the path `31/F1` measured. Judged by the ladder.

**Follow-up plan -- the borrowing cursor.** Replacing the materializing facade
with a borrowing cursor and a forward walk over records for whole-history reads
is a separate plan, written after milestone 1 lands. It is not in this plan's
scope, proof obligations or acceptance. Its priority is already frozen: it is
promoted ahead of the rest of that work iff doc 21's `.character` drag-move at
trial depth re-measures **above 121 us** under doc 21's own instrument
(`31/D3` Decision 5, frozen before the number exists).

## Invariants

- **I1 -- nothing width-dependent is stored.** A record's bytes are a function of
  content alone. Every width-dependent quantity is a cache that a flush can
  rebuild from the arena.
- **I2 -- one *charged* bound, and it holds by construction.** Charged bytes --
  arena bytes in use plus index plus side tables -- never exceed the scrollback
  byte budget; the arena is allocated once at that capacity and is never grown,
  compacted or shrunk. **Resident bytes are a different quantity and this
  invariant does not bound them**: they are bounded by capacity plus metadata,
  because once the ring cursor has cycled every arena page has been touched, so
  the blank-record regime is a 16 MiB arena plus ~8 MiB of index resident against
  a 16 MiB charged bound (`31/D2` Decision 1 as amended). The budget constant
  does not change at migration, and no content class loses depth.
- **I3 -- a width change evicts nothing**, at any width down to the engine
  minimum. The lossiness `28/D8`'s row cap could not avoid becomes
  unrepresentable.
- **I4 -- eviction stays display-row granular.** No anchor and no scrollbar
  position moves further per admitted row than it does today. A head record
  trimmed inside a logical line reads as a mid-line continuation and carries no
  semantic mark.
- **I5 -- the middle is immutable.** The head record's header and the tail record
  are the only writable bytes; the arena has exactly the five mutating
  operations `31/D2` Decision 2 enumerates, as amended by `31/D3` and `31/DD20`
  (the seam split is operation 1, not a sixth operation).
- **I6 -- the fold reproduces today's output.** Reading history at a width emits
  the same cells, kinds, styles, spacer placement, continuation stamping and
  soft-wrap marking today's stored rows do -- including the styled blank a
  background-erase sever or spacer clear leaves behind (`31/D3` Decision 3).
- **I7 -- the frame path does not walk the index.** Projection totals, the top
  row, cursor stream row and every clamp bound stay integer arithmetic; planning
  one frame performs at most one display-row-to-record locate, and that count is
  invariant to history depth (`31/D3` Decision 1).
- **I8 -- anchors stay absolute display rows.** A width change captures the ten
  held anchors against the old fold, recomputes the index, then restates them;
  eviction needs no anchor edit. Selection, search occurrence, hovered and armed
  links, the drag pin and the browsing anchor all survive a resize.
- **I9 -- the index agrees with the arena.** The grand display-row total matches
  an independent recount after each of the six trigger points -- width change,
  admission, head eviction, tail truncation, forced split, clear-all. The fold
  arithmetic underneath it is `max(1, ceil((cells + spacers) / width))` per
  record: the floor is what makes a zero-cell record (`31/DD15`) one display row,
  and without it a blank history folds to nothing and the blank-line regime's
  1,048,576-records-to-rows reading (`31/F7`, `31/D2` Decision 1) breaks.
- **I10 -- no record exceeds 1/32 of the budget.** A logical line past that cap is
  hard-split with a marker, and readers rejoin split records by adjacency
  (`31/D3`-ratified `31/F4` derivation: the cap moves if the budget does). The
  same split fires at a second trigger: when the open tail record reaches the
  arena's physical end (`31/DD20`).
- **I11 -- the open tail record ends on a display-row boundary at the current
  width**, so a resize leaves no short display row in the middle of a logical
  line that continues in the live grid (`31/D3` Decision 4).

## Proof obligations

- **PO1 (I1, I6).** History read back row by row through the existing readers
  checksums identically to today's engine over every scalar, style id and kind,
  on the four content classes `31/F3` calibrated -- including content whose
  spacers the store refuses to hold and re-derives at read.
- **PO2 (I6).** Severing a retained wrap claim, and clearing a spacer through EL
  and through DCH, leave the affected column painted in the background-erase
  colour under a non-default erase style and in the default colour otherwise.
- **PO3 (I2).** Feeding past the budget leaves total charged bytes at or under
  it, for each measured content class and for a blank-line history; the census
  reports capacity and bytes-in-use separately, bytes-in-use falls when records
  are evicted, and capacity never grows.
- **PO4 (I3).** A narrow-then-widen cycle evicts nothing and loses no content, at
  widths down to the engine minimum.
- **PO5 (I4).** Evicting under a head record spanning many display rows moves the
  browsing anchor and the selection by the same amount they move on ordinary
  content; a trimmed head record's first display row reads as a continuation
  without a semantic mark, and its fold is otherwise identical to the untrimmed
  record's tail.
- **PO6 (I9, I5, I11).** The grand total and the per-block totals agree with a
  recount after each of the six triggers at two widths; a height grow with the
  cursor on the last row pulls the right rows back out of history and leaves the
  totals and the charge consistent; widening or narrowing while a logical line
  straddles the history/live seam leaves no short display row inside that line.
- **PO7 (I7).** A test-only locate counter shows one frame plans with at most one
  locate, and the count does not vary between a shallow and a deep history.
- **PO8 (I8).** A width change at several widths preserves the selection, search
  occurrence, hovered and armed links, drag pin and browsing anchor, as a
  round-trip property rather than a case table.
- **PO9 (I10).** A logical line driven past the cap splits, and copy and search
  treat the split line as one line.
- **PO10 (identity).** A hovered link's activation identity changes when any cell
  in its range is overprinted and not otherwise, with the range spanning the
  history/live seam.
- **PO11 (I2, migration depth).** Under the production budget, the same fed input
  retains at least as many logical lines and display rows in the new store as in
  today's engine, on each of the four calibrated classes and on spill-heavy,
  hyperlink-heavy and identity-heavy content, with the charge totalled worst-case
  per class over records, index and every side table. This is what graduates the
  record format: a class that retains less does not ship.
- **PO12 (I5, I6, I10).** Cycling variable-length records -- including near-cap
  records and an open tail that grows across the wrap seam, which `31/DD20`
  forced-splits at the physical end and pads only to the next sub-row boundary --
  through several full physical wraps of the arena, with head trims interleaved,
  leaves every reader returning exactly the expected retained suffix, cell for
  cell and in order, after each cycle.
- **PO13 (record fidelity).** Multi-scalar spills, hyperlink ids and targets,
  content identity and semantic marks survive admission, a width change, a forced
  split and a head trim: a split logical line's mark appears exactly once and on
  the piece that starts it, and spill and hyperlink content read back identically
  on both sides of the split. Evicting the whole first piece of a forced-split
  pair leaves the follower reading as a mid-line continuation carrying no mark --
  not as a fresh logical line (`31/D2` Decision 2 step 2 as amended). (A trimmed
  head's mark clearing is PO5's.)
- **PO14 (gate).** `just test` passes, and the deletion list `31/F5` names is
  actually gone from the tree rather than relocated.

## Acceptance

This plan completes when milestone 1 passes every proof obligation above and the
ladder below. Landing is decided by the paired benchmark ladder against a real
implementation, not by any Phase 1 number:

- **`retained-browse` is the go/no-go.** Not `slower` under its frozen rule in
  `scripts/terminal-benchmark-validation.py#DECISION_RULES`, measured against the
  parent revision the change forks from, under a rule frozen before the
  comparison is read.
- **`terminal-feed` and `scrollback-stream` carry the admission falsifier.**
  Not `slower` under the same discipline.
- `31/F1`'s and `31/F3`'s conversions to roughly **-2%** on `retained-browse` and
  **-7%** on `scrollback-stream`'s block are the **hypotheses this ladder tests**,
  not outcomes to be confirmed. A `neutral` verdict is a recorded cost, not a
  failure; only `slower` is one.
- A `slower` `retained-browse` verdict falsifies the implementation before the
  design: check the locate counter (I7) and the arithmetic-only projection reads
  first, in that order (`31/D3` Decision 1). Only with both holding does it read
  as evidence against wrap-at-read, which is `28/H7`'s reopening condition.
- The whole-arc reading against `de17e95` is descriptive accounting only and is
  never a verdict (`agent-docs/terminal-performance.md`'s two tiers).

## Gates carried from the research doc

Open conditions that the implementation, not the design, has to discharge:

- **Eviction is unmeasured on both sides** (`31/D1` condition 2, the largest
  unmeasured term in Phase 1). Compare today's budget enforcement and
  head removal against this design's head-trim -- whose per-step fold walk is
  the new term -- under a rule frozen before the comparison is read. Owed before
  the ladder verdict is read, since a real pane evicts on every admitted row.
  **Freeze the rule against this complexity reading**, not a worse one: `31/D2`
  Decision 2's steps 1 and 4 persist the head cell offset, so one trim step folds
  **one display row** from that offset -- `O(width)`, or `O(cells in that row)` on
  the wide path -- rather than re-folding the record, and the per-record cost is
  therefore linear in its display rows across a full drain, not quadratic.
- **Resident pages are unmeasured** (`AR6`, promoted from an accepted risk by the
  external review of `31/D2` Decision 1). `I2` bounds charged bytes, and `PO3`'s
  census can only see those; resident is capacity plus metadata once the ring
  cursor has cycled. Measure resident pages through `TerminalMemoryProbe`
  (`phys_footprint`, `--vmmap`) on an empty, a partially filled, a saturated and a
  cycled pane. Sequenced with the eviction measurement, because cycling the ring
  is what makes the two quantities diverge. If the overshoot matters, the remedy
  is sizing the arena's capacity below the budget -- a change to be taken on that
  reading, not before it.
- **The wide-content counting pass is unmeasured** (`31/D1` condition 1). Its
  probe, stimulus ladder, width changes and three-way decision rule are frozen in
  `31/D3` Decision 7; run it mechanically. Neither outcome changes the design --
  a reject picks between a per-record cached count and lazy per-block recompute,
  and that choice is a human's.
- **`28/D11` is a live trial** (`31/D1` condition 4). Its two caps are deleted
  with no analogue and its budget survives unchanged; landing this store without
  a doc 28 amendment recording the human's exit-1 verdict *and* the new
  "the cause is removed" exit would retire a live trial by side effect. The
  amendment is doc 28's to write, and the resize measurement it names is taken
  against the new store.
- **The forced-split cap is derived, not measured** (`31/D1` condition 8). No
  pathological input has been fed to a real engine to see what a session
  produces. Feed one; the cap bounds the hazard either way.
- **`31/DD8` is re-read against the landed implementation** rather than quoted
  from `31/F5`: the invariant margin is now 4.5 against 4.5, so the simplification
  side of the acceptance gate is re-adjudicated on what actually landed.
- The record format still owes a shape for the spill table, the hyperlink table
  and the semantic-mark slot (`31/D1` condition 9, advanced by `31/D3`
  Decision 6).

## Non-goals

- No user-facing scrollback configuration ships. If one is ever added its unit is
  bytes or logical lines; a display-row denomination is the one unit that would
  reintroduce narrow-then-widen lossiness (`31/D2` Decision 3).
- No reflow, rewrap or background rewrap of retained history in any form.
- No change to the stored cell format or to the live grid's refold.
- This plan does not rewrite the projection readers; the whole-history
  materialization stays as it is until the borrowing-cursor follow-up plan.
- No scheduling work: `28/F20`'s residual may be scheduling rather than encoding,
  and this store does not address it.

## Accepted risks

- **AR1 -- eviction's cost is unknown on both sides.** The head-trim adds a fold
  walk per step that today's removal does not pay, but a bounded one: the head
  cell offset persists across steps (`31/D2` Decision 2 steps 1 and 4), so a step
  folds one display row -- `O(width)`, or `O(cells in that row)` on the wide
  path -- and draining a record costs one pass over it rather than one per step.
  Mitigation is the measurement gate above. The whole-record fallback would
  reintroduce `31/F6-HR5`'s anchor jump as an accepted behavior change, and on
  this reading it is unlikely to be needed.
- **AR2 -- the wide-record fold is bracketed by arithmetic, not measured.** It is
  `O(display rows)` with an O(1) test per boundary, bounded by a total the budget
  already bounds, and the bracket clears one frame by ~3x on an unmeasured
  constant.
- **AR3 -- milestone 1 ships an arena behind a facade that still allocates per
  pointer query.** That is parity with today, but it means the ladder judges a
  store whose projection layer has not yet been paid for.
- **AR4 -- one new failure mode with no analogue today: a stale index.** The
  design trades an eagerly-maintained truth for a derived cache with six
  invalidation points; I9's recount test is the only thing that catches a missed
  one.
- **AR5 -- I7 is a discipline, not a mechanism.** Nothing in the type system stops
  a future call site from reaching the index inside a per-row loop; the locate
  counter is the only guard.
- **AR6 -- first-touch residency was an assumption about the allocator, and it is
  no longer an accepted risk.** It bounds an idle pane only: a pane whose ring
  cursor has cycled has touched every page by construction, so resident is
  capacity plus metadata and `I2` does not bound it. PO3's census cannot see this
  -- it reports capacity and logical bytes-in-use, not pages dirtied -- so the
  resident-page measurement is a **gate** above rather than a risk carried here.
- **AR7 -- the seam rule (I11) was discovered, not designed**, and no probe has
  exercised a width change with a logical line straddling the seam.

## Rejected ideas

- **The mixed-width hybrid (`28/H7`)** -- reflow viewport-adjacent rows and tag
  the rest by width. It adds the invariant this design deletes (every reader
  handles two widths). Reopens only on a `slower` ladder verdict with I7's
  diagnostics holding.
- **Porting iTerm2's LineBuffer.** Its block structure encodes Objective-C
  history; individual mechanisms are adopted only on DanTerm's own justification,
  as `31/F4` did for the wide-cell fast/slow split.
- **Lazy per-block index recompute for milestone 1.** Deferred, not refuted:
  eager measured 15.6x inside its bound. Reopens past ~100,000 logical lines,
  which the budget does not admit, or as a milestone-2 mitigation if the wide
  probe rejects.
- **Whole-record eviction.** Drops up to a screenful of display rows in one step,
  which is user-visible in four anchors and the scrollbar.
- **A growing or compacting arena.** Geometric growth hides resident slack from
  the charge model (the shape of `15/F4`'s leak); compaction puts a large copy on
  the admission path and rebases every stored offset.
- **A two-kind history/live anchor address, or logical-line anchors throughout.**
  Both move conversion work onto the admission path, where the admission
  falsifier lives, or onto the `Comparable` pointer path.
- **A per-record header style slot for the background-erase blank.** It adds a
  field to every record for a case reachable on one, and cannot express the
  variant where the record stays open.

## Implementation discretion

- Exact record, header, index and side-table byte layout, and the index's block
  size.
- How the fold computes a cut offset, and how a **closed** record's placement is
  kept off the ring's wrap seam (`31/DD14`'s pad), provided a record stays
  contiguous and the waste is bounded and charged. The **open tail** at the seam
  is not discretionary: `31/DD20` forced-splits it at the physical end and pads
  only the sub-row remainder.

## Commit progress

- [x] 1. docs(research): freeze the eviction comparison's decision rule before any eviction number exists, written against the per-step complexity the Gates section states (one display row per trim step, not a record walk)
- [x] 2. test(terminal): run `31/D3` Decision 7's frozen wide-content counting probe and record its verdict
- [x] 3. feat(terminal): add the logical-line record arena, its derived index and the read-time fold
- [ ] 4. test(terminal): price head-granular eviction against today's budget enforcement and record the verdict, taking the resident-page reading (empty, partial, saturated, cycled) in the same slice
- [ ] 5. refactor(terminal): store retained history as logical-line records, deleting reflow of history, both caps and the per-row charge model
- [ ] 6. docs(research): record `28/D11`'s exit against the new store's resize measurement
- [ ] 7. docs(research): record the paired ladder verdict, the residency and pathological-input readings, and the `31/DD8` re-read

## Implementation notes

- **Slice 1 recorded the eviction rule as a new `31/D4` entry** rather than as a
  decision inside `31/D3`, which hosted the wide-content rule. `D3` is a closed
  design entry whose scope is `F6`'s hard cases; this rule governs a measurement,
  carries a second measurement (the `AR6` residency reading) with its own
  three-way rule, and owns verdicts that fire after `D3` closed. A new `D` entry
  keeps the decision log auditable by ID, which is what the doc's format asks for.
- **The rule adds a fifth stimulus class and a second verdict-bearing statistic**
  beyond what `31/F3` froze, both recorded as `31/DD21` and `31/DD22`. `F3`'s four
  classes never trim inside a record, so they would leave the persisted head cell
  offset -- the term the amended `AR1` is about -- unexercised; and `28/F20`'s
  measured share covers admission and enforcement together, so the ladder
  conversion is exact for the write-path pair and only conservative for eviction
  alone. Both readings are reported so neither is lost.
- **Slice 2's finding is numbered `31/F9`, not `F8`.** `D4`, frozen in slice 1,
  reserves `F8` for the eviction measurement and the residency reading it governs
  (slice 4), and the README's Phase 3 ledger carries that reservation. Findings in
  doc 31 are numbered by reservation rather than by landing order -- `F3` and `F4`
  already are -- so renumbering a frozen entry to keep the sequence chronological
  would have cost more than it bought.
- **Slice 2's verdict is narrow confirm, so slice 3's scope is unchanged**: no
  per-record cached count and no lazy per-block recompute. The one thing it hands
  slice 3 is a number rather than a design change -- the counting pass costs
  5.2-5.4 ns per display row once the wide fallback engages, flat across record
  sizes.
- **The probe reads the verdict on budget-admissible cells only** (`31/DD23`).
  `D3` Decision 7's rule says "every measured cell" and also names continuity
  rungs at 10,000 and 100,000 wide records, which are 22.4 MB and 223.8 MB of
  charge against a 16.8 MB budget; those two cannot both be verdict-bearing. The
  resolution was written into the probe file's header before the probe was first
  run, so it is visible in the same commit as the numbers it governs.
- **Slice 3 lands the store as two files beside today's, unwired.**
  `lib/TerminalCore/Sources/TerminalCore/LogicalLineRecord.swift` holds the record
  header's bit layout and the pure width-derived fold;
  `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift` holds the arena,
  its ring discipline, the five mutating operations, the derived index and the
  reads. The one edit outside them widens `TerminalCellKind.packedCode` and
  `SemanticPromptRow.packedCode` from `fileprivate` to internal so the two stores
  share one C1 cell coding rather than transcribing it -- which is the fidelity
  limit every doc 31 probe recorded against itself.
- **`31/D3` Decision 1's reader contract is expressed as `locate` + `advance`,
  and the locate *counter* `PO7` asks for is deferred to the wiring slice.** The
  obligation is about what one planned *frame* does, and there is no frame until
  the store is wired; a counter on a `Sendable` value type would need a
  refcounted box, which is exactly the kind of member
  `docs/design/2026-07-29-cross-module-value-dispatch.md` warns off a hot type.
  What slice 3 owes is the API shape that makes one locate natural, and that is
  what landed.
- **The index's block size is 64 records**, from `31/F1` Observation 4's measured
  ladder (677 ns at 32, 697 at 64, 801 at 128, 870 at 256 per display row): small
  blocks read faster because the in-block scan shortens faster than the binary
  search lengthens, and 64 costs 0.25 B per record against the 8 B the offsets
  cost. Block size is named implementation discretion, so this is a note rather
  than a decision.
- **Four genuine judgment calls, each taken as the obvious simple option and
  recorded here continuing `31/DD24`'s numbering.** None blocked, and each is a
  human's to revisit:
  - **DD25 -- admission measures a hard-ended row to its *content* end, not to
    `PackedRetainedRow.pack`'s canonical extent.** This is `31/F4` case 17's
    stated rule, and it is a real choice rather than a restatement: today's
    `pack` keeps a trailing background-erase-styled blank past the content and
    today's `reconstructLogicalLines` drops it, so the two disagree and a record
    can hold only one. As a *display row* that blank is one painted column; as
    *line content* it is a cell the fold re-wraps, so keeping it would turn a
    painted tail on a hard-ended line into whole blank display rows at a narrower
    width. The consequence, stated rather than buried: at the admitting width the
    store's fold emits a default cell where today's stored row holds a styled
    one, past the content end of a hard-ended row. `31/D3` Decision 3's measured
    case is untouched -- it is a *soft-wrapped* row measured to full width, plus
    an explicit repair append.
  - **DD26 -- a hard-ended row with no content, appended to a record that already
    has cells, stores one default cell.** Without it `31/DD5`'s counted row and
    the fold's derived count disagree by one for that record, and `31/I9` is
    stated as their agreement. The case is reachable only by erasing a row whose
    predecessor soft-wrapped. `31/DD15`'s zero-cell record is untouched: that is
    an *empty* record, this is an empty *append*.
  - **DD27 -- the trimmed head's "cleared" mark reads as `.continuation` when the
    logical line carried a mark and as `.none` when it did not.** `31/D2`
    Decision 5 asks for both "the slot is cleared" and "stamped `.continuation`
    exactly as today's retained rows are"; today's rows carry `.continuation` on
    a marked line's continuation rows and nothing on an unmarked line's, so this
    is the reading that satisfies both at once and costs no extra bit. The same
    rule stamps a forced-split follower whose predecessor is evicted.
  - **DD28 -- condition 9's side-table shapes.** The hyperlink table
    (`(offset, id)` pairs) and the identity table (`(start, extent, base)` runs,
    with `pack`'s per-cell fallback) live **in** the arena immediately after the
    record's cells, keyed by cell offset within the record; the spill table lives
    outside it, in a dictionary keyed by absolute record sequence, because a
    multi-scalar payload is variable-width and `28/F11` puts it on 0.12% of rows.
    Two consequences the layout buys: a head trim moves the header forward by
    exactly the bytes it drops, so `header + cellCount * 8` still addresses the
    tables and they need no rewrite (the middle stays immutable, `31/I5`); and a
    blank logical line still costs eight arena bytes, which `31/D2` Decision 1's
    1,048,576-record depth rests on. The open tail's two in-arena tables are held
    in scratch until it closes, because admission would otherwise append cells
    over them.
- **The fidelity suite names one acknowledged divergence rather than hiding it.**
  The open tail's final display row is short by exactly the `.spacerHead`
  admission dropped, until the wide head that follows is admitted -- which is the
  same fact `31/D3` Decision 3 step 1 relies on to find the cleared spacer's
  column ("for an open record that is the only way a final display row can be
  short"). `assertOpenTailSeam` pins the shortfall to that one column instead of
  excluding the row.
- **Promoting the plan moved its path**, so the five research-doc references to
  `plans/wip/logical-line-scrollback-store.md` were repointed in the same commit;
  the `docs/research/README.md` index row drops the path entirely rather than
  carrying a 99-character cell against the format's 100-character cap.
