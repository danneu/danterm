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
- **I2 -- one *charged* bound, and it holds by construction. *(Restated
  2026-08-04 as `31/D4`'s residency remedy shipped. The original sentence said
  "the arena's capacity *is* that budget", which the remedy makes false; `31/F8`
  and the slice-4 notes both record that this restatement is the human's to
  ratify, so it is marked rather than folded in silently.)*** Charged bytes --
  arena bytes in use, plus the index, plus **every** side table at what its
  allocator gave rather than at what its live entries weigh -- never exceed the
  **arena's capacity**; the arena is allocated once, at a capacity held **below**
  the scrollback byte budget by a fixed metadata reserve, and is never grown,
  compacted or shrunk. The three quantities are distinct and each is reported
  separately by `PO3`'s census: the **budget** is what a pane's history may cost,
  the **capacity** is what the charge is tested against, and the **reserve** is
  the difference, which exists so that the index and the side tables are resident
  inside the budget rather than on top of it. **Resident bytes are a different
  quantity again and this invariant still does not bound them**: they are
  capacity plus metadata once the ring cursor has cycled, which lands inside the
  budget exactly when the metadata fits the reserve -- so the degenerate
  blank-record regime is still an arena plus ~8 MiB of index resident against a
  16 MiB budget (`31/D2` Decision 1 as amended). The budget constant does not
  change at migration; depth costs the reserve, and `PO11`'s "no content class
  loses depth" is what bounds how large the reserve may be (`31/DD36`).
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
  background-erase sever or spacer clear leaves behind (`31/D3` Decision 3), and
  including a hard-ended line's background-erase tail, which the **painted** read
  reproduces from the record's trailing fill style (`31/DD25` as amended). The
  **content** read stops at the line's content on purpose, and that is the one
  place the two reads differ: the fill is paint, not text, so copy never sees it.
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

**Measured 2026-08-04 as `31/F11`, and this section is NOT satisfied.** One valid
`confirm` invocation against `28c54e1`, the pre-cutover parent: `retained-browse`
**+60.44%** (frozen 1.05%), `terminal-feed` **+2.60%** (2.5%) and
`scrollback-stream` **+141.42%** (1.85%, PTY drain 8.4 -> 1.3 MB/s) -- all three
`slower`, the -2% / -7% hypotheses refuted in the opposite direction. The three
history-free draw workloads read `inconclusive` / `faster` / `faster` on the same
schedule. The diagnostic order below was run first and **both diagnostics hold**,
which under the frozen rule is the condition that reopens `28/H7`; `31/F11`
records that the rule fires and records why it fits the cutover's wiring better
than the model (`retained-browse` feeds one-record-per-display-row content, `31/F1`
measured that walk 1.64x faster, and the same pane is 8.62x resident with 0.007x
the row allocations and a census explaining 5% of it). **Milestone 1 does not
land on this evidence; the disposition is the human's and no further work is
taken here.** The original statement of the section follows.

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
  unmeasured term in Phase 1). **Measured 2026-08-04 as `31/F8`, and the verdict
  is `reject`**: the landed store's whole write path costs 1.418x-3.177x today's
  per admitted display row and its eviction alone 1.830x-3.114x per evicted
  display row, on all four verdict-bearing classes, against `31/D4`'s 1.09x line.
  **Re-priced 2026-08-04 as `31/F10` after the write path was optimized, and the
  condition is discharged by its first clause**: under the same rule, the same
  probe file and the same thresholds, the write path is now **0.856x-1.023x**
  today's and eviction alone **0.151x-1.022x**, which reads **neutral**. The
  original reject and the condition it attached follow verbatim, because the
  condition is exactly what the re-run satisfies -- by its **first** clause, not
  by deferring to the ladder: *the store does not land until either the eviction
  implementation clears 1.09x under that same rule, or the paired ladder comes
  back not-`slower` on `terminal-feed` and `scrollback-stream` against a real
  implementation* (`31/H3`'s own falsifier, which `31/D4` says outranks a
  microbenchmark prediction). Disposition was a
  human's. What the same finding rules out as the cause: `31/D4` gate 7 passes at
  1.000x, so `31/D2` Decision 2's per-step complexity is what the landed code
  does; and `31/F3`'s own prototype of the open-line rule re-measured at
  0.52x-0.64x of today's admission in the same session while
  `LogicalLineStore.admit` cost 3.01x-4.31x that prototype, which puts the reject
  in the store's per-byte arena access rather than in wrap-at-read. The original
  statement of the gate follows. Compare today's budget enforcement and
  head removal against this design's head-trim -- whose per-step fold walk is
  the new term -- under a rule frozen before the comparison is read. Owed before
  the ladder verdict is read, since a real pane evicts on every admitted row.
  **Freeze the rule against this complexity reading**, not a worse one: `31/D2`
  Decision 2's steps 1 and 4 persist the head cell offset, so one trim step folds
  **one display row** from that offset -- `O(width)`, or `O(cells in that row)` on
  the wide path -- rather than re-folding the record, and the per-record cost is
  therefore linear in its display rows across a full drain, not quadratic.
- **Resident pages are unmeasured** (`AR6`, promoted from an accepted risk by the
  external review of `31/D2` Decision 1). **Measured 2026-08-04 as `31/F8`, and
  the verdict is `reject` on the second trigger**, and **re-read 2026-08-04 as
  `31/F10` after the remedy shipped, where it is `narrow confirm`**: the cycled
  arena is now 0.849x today's resident on `scrollback-plain` and 0.997x on
  `scrollback-mixed` for the same fed inputs, and 1.140x of the 16 MiB charged
  bound on `mixed`, so neither reject trigger fires and the recorded condition is
  on pane count. The original reject follows. The arena is resident at
  1.118x today's store for the same fed input on `scrollback-mixed`, over the
  1.10x line, and an *empty* arena pane is already 16.281 MiB resident because
  the reservation is dirty from construction rather than on first touch (which
  refutes `31/DD12`). **The remedy `31/D4` names has shipped, in the inserted
  slice 4a rather than in slice 5** -- it is a change to the store's construction
  and to its charge model, and the store is still unwired, so it never needed the
  wiring slice: the arena's capacity is held *below* the byte budget by a fixed
  metadata reserve (`31/DD36`), every side table is charged at what its allocator
  gave rather than at what its live entries weigh (`31/DD37`), and `PO3`'s census
  is what proves the new capacity holds. The
  measured share is 3.23% of the budget on `plain` and 15.29% on `mixed`, not the
  1.61% `31/D4` derived -- the side tables that derivation left as an unmeasured
  constant are 3.7x the index on `mixed`, and the spill table in particular is
  charged at less than it allocates, which is `15/F2`'s error class recurring
  inside `I2`. `I2`'s "the arena is allocated once at that capacity" survives;
  what changes is that capacity and budget stop being the same number, which
  `I2`'s own wording ("the arena's capacity *is* that budget") is restated for
  above -- **marked as an amendment, and still owed the human's ratification**.
  The original statement
  of the gate follows. `I2` bounds charged bytes, and `PO3`'s
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
- **`28/D11` is a live trial** (`31/D1` condition 4). **Discharged 2026-08-04 by
  slice 6**: `28/D11` carries the amendment, closing the trial on the fourth exit
  *the cause is removed*, with the human's exit-1 verdict recorded and recorded
  as still **unratified** when the store deleted the cost it accepted. The resize
  measurement is the committed frozen probe `saturated-wide-resize-v1` -- which
  is `28/F23`'s own calibration harness and the trial's exact shape -- run
  unmodified at `de17e95` and `9ad7cc5` under a rule frozen before either number
  was read (*the cause is removed iff, at a depth not below the before arm's,
  median and maximum both fall under `28/D8`'s ~150 ms budget*). Read:
  **576.19 ms at 9,860 retained rows -> 1.58 ms at 10,735**, max 2.75 ms, so
  depth is 1.089x and cost is 0.011x `28/D8`'s budget against the trial's 3.84x;
  the before arm reproduces `28/F23` candidate (b)'s 600.5 ms within 4.1%. Left
  open on purpose and named as a fresh question rather than resolved by side
  effect: `28/D8`'s ~150 ms budget is not formally superseded, because resize
  cost stopped being a function of history depth. The original statement of the
  gate follows. Its two caps are deleted
  with no analogue and its budget survives unchanged; landing this store without
  a doc 28 amendment recording the human's exit-1 verdict *and* the new
  "the cause is removed" exit would retire a live trial by side effect. The
  amendment is doc 28's to write, and the resize measurement it names is taken
  against the new store.
- **The forced-split cap is derived, not measured** (`31/D1` condition 8).
  **Discharged 2026-08-04 as `31/F12`**: `31/F4`'s named wezterm shape (1.5 MB of
  minified JSON on one line) and a line larger than the whole arena were fed to
  the real engine. The cap bounds every hazard it was derived for -- 23 pieces
  exactly as predicted, copy reads one 1,499,979-character logical line, the
  charge stays inside capacity, and the over-arena line evicts its own head and
  stays readable as 32 records of one line. It **also** bounds one the derivation
  never named: browsing a near-cap record costs **8,844.7 us per frame against
  219.1 us in the same terminal's ordinary region (40.3x)**, measured linear at
  ~1.95 ns per record-cell per display row, because `forEachFoldedCell`
  re-enumerates the whole record to find one display row's cell range. That is
  53% of a 60 Hz frame at the cap, and it is an implementation defect rather than
  `AR2` (both stimuli are ASCII, and the arithmetic path exists but this walk does
  not take it). Recorded, not fixed. The original statement of the gate follows.
  No pathological input has been fed to a real engine to see what a session
  produces. Feed one; the cap bounds the hazard either way.
- **`31/DD8` is re-read against the landed implementation** rather than quoted
  from `31/F5`: the invariant margin is now 4.5 against 4.5, so the simplification
  side of the acceptance gate is re-adjudicated on what actually landed.
  **Re-read 2026-08-04 in `31/F11` Observation 4, and `31/DD8` reopens on both of
  its clauses.** The tally against what landed is **4.5 deleted against 7.5
  added** -- `I11`'s seam rule, `31/DD25`'s trailing-fill side table, `31/DD43`'s
  seam-spacer reach and `historyEvictionsObserved`'s two-object protocol are all
  additions the earlier tallies predate, with `31/DD37`'s maintained charge
  cancelled against today's -- and the storage core landed at **2,419 production
  lines** (`LogicalLineRecord` 337 + `LogicalLineStore` 2,082) against `31/F5`'s
  ~350-400 prototype estimate, while `Terminal.swift` fell only 6,470 -> 6,431. The
  cross-cutting-to-local asymmetry mostly survives -- six of the eight additions
  have one writer and one gate -- with two exceptions that cross the store's
  boundary. Disposition is a human's.
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
  variant where the record stays open. **Both objections survive and neither
  covers what landed 2026-08-04** (`31/DD25` as amended): the trailing fill is a
  *side table* keyed by record, so a record without one pays a header bit and
  nothing else, and it is not the mechanism for the open-record variant -- `31/D3`
  Decision 3's measured cell append still owns that. What is rejected is a style
  field in every header, and that stays rejected.

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
- [x] 4. test(terminal): price head-granular eviction against today's budget enforcement and record the verdict, taking the resident-page reading (empty, partial, saturated, cycled) in the same slice
- [x] 4a. perf(terminal): spend `31/F8`'s attributed headroom on the arena's write path, and ship `31/D4`'s residency remedy
- [x] 4b. test(terminal): re-run `31/D4`'s frozen rule against the optimized store and record the verdict
- [x] 5. refactor(terminal): store retained history as logical-line records, deleting reflow of history, both caps and the per-row charge model
- [x] 6. docs(research): record `28/D11`'s exit against the new store's resize measurement
- [x] 7. docs(research): record the paired ladder verdict, the residency and pathological-input readings, and the `31/DD8` re-read

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

    **Amended 2026-08-04 -- the choice above is superseded, and the loss it
    accepted is gone.** Both options DD25 chose between were lossy: storing the
    styled blank as a cell wraps paint into blank display rows at a narrower
    width, and dropping it repaints a line the user saw in colour with the
    default background. The third option, approved by the human and landed here,
    is neither -- **a hard-ended row's trailing to-edge paint is stored as a
    per-record *fill style*: an attribute, not cells.** A record keeps its content
    cells plus, optionally, one style id meaning "after this line's content ends,
    the remainder of its last display row is painted in this style". What each
    half of the design now says:

    - **Admission.** The predicate that identifies the fill is `pack`'s own
      canonical-extent predicate read backwards
      (`PackedRetainedRow.swift#pack`: a blank cell extends the extent when it
      carries a non-default style): the maximal run of blank, non-default-styled,
      unlinked, unidentified cells reaching the **right margin** of a hard-ended
      row is the fill, and it is recorded as one style id rather than as cells. A
      soft-wrapped row occupies every column and so can have no fill.
    - **Trailing versus interior, the one line this draws.** Only the run that
      reaches the margin is width-relative and only it becomes the attribute.
      Styled blanks *between* content -- or a styled run that stops short of the
      margin -- stay real cells: their columns are positionally meaningful, and
      they re-wrap with the line like any other content.
    - **Read.** Two walks, and the store's API makes the distinction expressible:
      `gridRow`/`recordCells` are the **content** walk and never emit the fill;
      `paintedRow` is the **painted** walk and appends the fill from the content's
      end to the margin, on the line's last display row only. Copy, selection and
      search take the content walk, because paint is not text. A zero-content
      record with a fill paints its whole single row, which is the
      ED-with-background case.
    - **At every width.** At the admitting width the painted walk reproduces
      today's stored row cell for cell -- *including* the styled blanks, which is
      **more** than the original DD25 kept. Narrower, the content re-wraps and the
      paint still runs from the content's end to the margin of the last row;
      wider, it extends to the new margin. All three are what a terminal of that
      width running the same bytes would display, and none of them adds a display
      row.
    - **Where it lives.** Header bit 63 -- the word's last spare -- says a record
      has a fill; the style id itself is a side table keyed by absolute record
      sequence, exactly like the spill table, so **only records that carry a fill
      pay for one** and a blank logical line still costs eight arena bytes. The
      slot is charged inside the budget at the table's capacity (`31/D2`
      Decision 1's charge table, amended with the row).
    - **The fidelity claim, restated precisely, because this is a deliberate
      divergence and not a silent one.** Slice 3's
      `foldReproducesTodaysRetainedRows` compares the store against today's
      stored rows, and today stores the styled blank. It now compares **both**
      walks: the painted walk against today's stored row over the full width
      (equal, cell for cell, on all five content classes including a new
      background-erased one), and the content walk against today's row up to the
      content end (equal). Past the content end the two walks intentionally
      differ, and that difference is the design: the fill is there, the content
      is not. The divergence from *today's engine* is now in the store's favour
      and is pinned by its own test --
      `widthChangeRepaintsTheTrailingFillTodaysReflowDrops`: today's
      `reconstructLogicalLines` discards the paint at a resize, and the fill
      survives one because it is width-free.
    - **`31/D3` Decision 3 is untouched, and its unification is recorded as an
      option not taken.** The sever/spacer-clear repair still materializes one
      styled cell into the **open** tail record. Severing could instead be spelled
      "set the trailing fill from the severed spacer's style", which would leave
      one mechanism for both sites -- but Decision 3 is a *measured* case against
      the real engine, and re-spelling it on the back of an unmeasured
      generalization is not licensed by this amendment. Recorded so a later slice
      can take it deliberately.
  - **DD26 -- a hard-ended row with no content, appended to a record that already
    has cells, stores one default cell.** Without it `31/DD5`'s counted row and
    the fold's derived count disagree by one for that record, and `31/I9` is
    stated as their agreement. The case is reachable only by erasing a row whose
    predecessor soft-wrapped. `31/DD15`'s zero-cell record is untouched: that is
    an *empty* record, this is an empty *append*. **Amended 2026-08-04 with
    `31/DD34`:** that cell takes the row's fill style when the row has one, so a
    restored row is painted from its first column exactly as today's stored row
    is; it is still a default cell when there is no fill.
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
    over them. **Amended 2026-08-04 by `DD25`'s amendment:** a **third** side
    table joins the spill table outside the arena -- the trailing fill style,
    keyed by absolute record sequence and gated by header bit 63 -- for the same
    reason and on the same terms: it is reachable on a minority of records, it is
    evicted with its record, and it is charged at its table's capacity. The
    header word is now full.
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
- **Slice 4's two verdicts are both `reject`, and they change slice 5's scope in
  one direction each.** The residency reject *adds* work to slice 5: the arena's
  capacity must be constructed below the byte budget by the measured index and
  side-table share, and `PO3`'s census has to prove the new capacity holds --
  which also means `31/I2`'s "the arena's capacity *is* that budget" is no longer
  literally true and is a sentence the human owes a restatement of. The eviction
  reject *gates* slice 5 rather than resizing it: `31/D4`'s named condition says
  the store does not land until the implementation clears 1.09x under that same
  rule or the paired ladder clears `H3`'s falsifier against a real
  implementation, and which of those two routes is taken is explicitly a human's
  decision. Nothing was optimised in this slice in response: `31/D4` froze its
  rule precisely so the landed store would be priced as it stands, and the
  probe's own attribution arm sizes the available headroom (3.0x-4.3x against the
  store's own `F3` prototype) without spending it.
- **Slice 4 changed no production code, and the probe found no correctness
  defect.** Every `31/D4` gate that tests the landed store's behavior passed on
  the first gated invocation and every one after: gate 1 (both arms' retained
  content checksums identically over the display rows both retain, on all five
  content classes, with the arena re-deriving the 3,067 `.spacerHead` cells it
  refuses to store), gate 2 (head stamping), gate 4 including the independent
  display-row recount off the arena, and gate 7 (per-step complexity flat at
  1.000x across a record's drain). The rejects are cost readings, not defects.
- **Four judgment calls, recorded as `31/DD29`-`31/DD32` continuing `DD28`'s
  numbering**, the first two written into the probe file's header before it was
  first run so the resolution is visible in the same commit as the numbers it
  governs: the `drain` statistic times a fixed 2,000-step eviction loop because
  `31/I2` makes the arena's capacity its budget and admission cannot run with
  enforcement suppressed; arm C is the arena design reproduced in the probe file
  because `LogicalLineStore` exposes no whole-record eviction and adding one for
  a descriptive arm is not licensed; the residency reading reproduces
  `TerminalMemoryProbe`'s instrument inside the test process because
  `Terminal.LogicalLineStore` is internal to `TerminalCore` and the probe binary
  cannot see it; and resident is read as a settled `phys_footprint` delta
  cross-checked against `vmmap`'s TOTAL DIRTY delta.
- **Ten of twenty-two gated eviction invocations were voided and are recorded in
  `31/F8` rather than hidden.** All ten failed the same cell -- gate 5's A/A
  control on (`full`, `drain`), whose 2,000 `free` calls over ~180 microseconds
  sit at the instrument's resolution floor against a 5% ceiling. The verdict was
  `reject` in all twenty-two at ratios between 1.41x and 3.24x, so nothing was
  selected on the numbers; the quoted invocation is simply one of the twelve that
  cleared every cell.

- **`DD25`'s amendment landed as its own commit, between slices 4 and 5**, on the
  unwired store rather than as part of the wiring: it changes what a record
  *means*, so landing it before slice 5 keeps the wiring slice from having to
  re-decide the trailing-blank question against live readers. It touches
  `LogicalLineRecord` (header bit 63, the `hasTrailingFill` flag),
  `LogicalLineStore` (the fill side table, the admission split, the painted read,
  and eviction/reopen/hand-back release), and both store test suites. No
  measurement is re-run: the fill costs one bit on every record and one table slot
  on the minority that carry one, which is inside `31/F8`'s reported precision,
  and `31/F8`'s verdicts stand as recorded.
- **Three judgment calls, recorded as `31/DD33`-`31/DD35` continuing `DD32`'s
  numbering**, each taken as the obvious simple option:
  - **DD33 -- a forced-split line's trailing fill belongs to the LAST piece.** The
    fill describes the paint after the line's *end*, so the piece that holds the
    end is its only coherent owner; a fill on the first piece would paint a margin
    in the middle of a line. It falls out of admission order rather than needing
    machinery -- a split closes the earlier piece *before* the closing row's cells
    are appended -- and a test pins it rather than trusting the ordering. Evicting
    the first piece leaves the follower's fill untouched, for the same reason.
  - **DD34 -- `31/DD26`'s restored blank cell takes the fill's style.** A
    hard-ended empty row appended to a record that already has cells stores one
    cell so the counted and derived row counts agree; giving it the fill style
    (default when there is none) is what keeps the restored row painted from
    column 0, which is what today's stored row shows.
  - **DD35 -- reopening the tail record clears its trailing fill.** A reopened
    line has no end, so the paint after its end is meaningless; the next
    admission re-derives the tail of whichever row finally closes it. The
    alternative -- keeping the fill through a reopen -- would paint a margin
    inside a line that is still being printed.
- **The optimize-then-re-price round is inserted as `4a` and `4b` rather than
  renumbered into the list.** The human took `31/F8`'s "optimize, then re-price"
  route, which is a slice the plan did not have; numbering it `5` would have
  renumbered the wiring slice that `31/F8`, `31/D4` and this plan's own gates all
  refer to by number. Two entries rather than one because the campaign's
  rule-then-measure separation is a commit boundary: `4a` changes the store and
  reads no new number, `4b` runs the frozen rule and records what it says.
- **Slice 4a spends `31/F8`'s measured headroom and ships `31/D4`'s residency
  remedy, on the same unwired store.** The human's disposition of `F8`'s two
  rejects was "optimize, then re-price", so this slice changes the store's write
  path and its construction and changes nothing else -- no call site, no reader,
  no threshold, and no line of `31/D4`. What it does, in the order `F8`
  Observation 3 attributed the cost:
  - **The arena is words, not bytes.** `LogicalLineStore` composed and decomposed
    each 8-byte cell through eight checked `[UInt8]` subscripts; it now stores
    `ContiguousArray<UInt64>` and addresses a word as `offset >> 3`. Every
    sub-word table field is naturally aligned inside one word by the layout that
    was already there, so `u16`/`u32` are one masked shift and no field straddles
    a boundary -- stated as assertions rather than as a hope.
  - **Admission streams from the caller's row.** `admissionContent` returned a
    freshly allocated `[GridCell]`; it is now `admissionExtent`, which returns a
    count and a fill style, and the append walks the row's own buffer through an
    `UnsafeBufferPointer` reading each cell's fields in place. Binding the
    element was itself a cost -- a `TerminalScalars` copy and release per cell --
    which is why `PackedRetainedRow.pack` already walks a row exactly this way.
  - **The charge is maintained, not recomputed.** The write path tested
    `census.chargedBytes` -- two dictionary capacities and four array capacities,
    rebuilt -- once per admission and once per eviction step. Index and
    side-table bytes are now maintained at the operations that move them, the
    same discipline `grandDisplayRowTotal` keeps, and `census` recomputes them
    from scratch and asserts the two agree so a missed refresh fails a test.
  - **Two mechanisms the attribution did not name, both found by re-reading the
    step the reject is about.** `RingBuffer` wrapped every index with `%` on a
    capacity that has always been a power of two, so it masks now; and
    `firstRowCellEnd` walked a display row's worth of columns to answer a
    question whose only possible boundary is the last column, so it is one probe.
    The head drop also reads the reclaimed span off the index instead of
    re-deriving the record's length and then walking the ring's pads.
- **Two judgment calls in the remedy, recorded as `31/DD36`-`31/DD37` continuing
  `DD35`'s numbering.** `31/D4`'s remedy names the shape ("capacity sized below
  the budget by the measured index and side-table share") and leaves the number
  to judgment, and `31/F8` measured a share that does not fit the number
  unqualified:
  - **DD36 -- the metadata reserve is a fixed 1/16 of the byte budget.** `31/F8`
    measured the metadata share at 3.23% of the budget on `plain` and 15.29% on
    `mixed`; a reserve at the worst measured class would cost 15.29% of depth,
    and `31/F8`'s own depth table puts the arena's tightest margin over today's
    store at **1.076x** (`full`) and 1.084x (`wrapped`) -- so any reserve above
    ~7.1% makes those classes retain *less* than today's engine, which `PO11`
    forbids outright ("a class that retains less does not ship"). 1/16 = 6.25% is
    the largest simple fraction under that ceiling. Its depth cost is 6.25%,
    which the re-priced depth table shows leaves every measured class at or above
    today's. What it does **not** do is cover `mixed`'s measured metadata share,
    so `I2`'s resident reading stays "capacity plus metadata" rather than "inside
    the budget" on that class. That tension is real and is recorded rather than
    resolved: closing it needs either a per-class reserve, which the store cannot
    know at construction, or a depth loss `PO11` currently forbids. A human's to
    revisit if a later reading makes residency bind harder than depth.
  - **DD37 -- a side table is charged at its allocated bucket count, not at its
    entry count.** `Dictionary.capacity` is the count it holds *before* it
    resizes -- three quarters of the power-of-two bucket count it actually
    allocated -- so the existing `capacity * stride` charge under-describes the
    allocation by a third plus the occupancy bitmap, and the spill table was not
    charging its dictionary at all. Both tables now charge
    `buckets * (key + value stride)` plus the bitmap and the allocation header.
    This is `15/D4`'s rule, and it is the mechanism `31/F8` Observation 4 put
    behind the residency reject; the alternative -- charging `malloc_size` --
    would measure rather than model, and neither `Dictionary` nor its storage is
    reachable for that from inside the store.
- **Slice 4b re-ran `31/D4` mechanically and both rejects cleared**, recorded as
  `31/F10`: eviction **neutral** (0.856x-1.023x on `steady`, 0.151x-1.022x on
  `drain`) and residency **narrow confirm** (0.849x and 0.997x of today's
  resident on the two triggering classes). Three things the slice hands the plan
  rather than the finding:
  - **A defect fix landed between the two commits, and it is why there are
    three.** `31/D4` gate 1 failed on `wide` in the invocation taken against the
    optimized store: a `.spacerHead` dropped at a forced-split seam (`31/DD20`)
    could not be re-derived, because the wide head that explains it is the
    *follower* record's first cell. That is slice 3's defect, exposed by the new
    capacity moving where the ring wraps, and it violated `I6` inside retained
    history. It is fixed with its own test and its own commit, before the
    recorded run, so no number here was measured against a store that failed a
    gate.
  - **`PO11`'s margin is now the reserve's ceiling, measured.** The arena still
    retains at least as much as today's engine on every class, but `full`'s
    margin is **0.9%** (1.009x) where `31/F8` measured 7.6%. Any future per-record
    charge, and any larger reserve, comes out of that 0.9%.
  - **`31/D4` gate 7 can no longer be read**, because the trim step it times
    fell to ~19.4 ns against the probe's 41.7 ns clock. `31/F10` records it as
    *not measured* under gate 8's discipline rather than as a pass (`31/DD38`),
    with two independent readings of the same complexity claim beside it. A
    human who wants it read literally has to batch the gated step, which is a
    change to a frozen instrument.

- **Slice 5 wires the store and deletes reflow of history, and the wiring is smaller than
  `31/F6` predicted in one direction and larger in another.** Smaller, because `31/D3`
  Decision 5's materializing facade means `ProjectionRows` keeps its shape: every reader
  `F6` classified as *rewritten* because it walks a row collection -- `R2`-`R11`, `R17`,
  `R18` -- is unchanged, and only its backing changed. Larger, because two of `F6`'s
  deletions turned out to cover only half of what they name, and because the fuzz suite
  found two real defects the mapping did not predict. What landed, by subsystem:
  - **Admission and eviction.** `appendToScrollback` is `history.admit` per display row;
    `enforceScrollbackBudget` is `history.evictToBudget()` plus one sync. Admission evicts
    on its own, so the count `handleEviction` needs is read as a delta against the store's
    monotone `evictedRowCount` rather than returned per call -- `historyEvictionsObserved`
    exists because a hard reset restarts `evictedRowCount` while history survives it, so
    the two counters cannot be one.
  - **Projection and reads.** `scrollProjection`, `projectionRowCount`, the cursor stream
    row and every clamp bound read `history.grandDisplayRowTotal`: two-integer arithmetic,
    no locate (`31/D3` Decision 1 rule 1, asserted by `TerminalFrameLocateTests`). The two
    per-visible-row walks locate once and advance.
  - **Tail mutations.** `severScrollbackWrapClaim` is repair-then-close;
    `restoreWrapClaimBeforeCursor` is `reopenTailRecord`; `clearPreviousSpacer`'s scrollback
    branch is the repair alone; `resizeHeight`'s grow is `truncateTail`.
  - **The width change.** History adopts the new width and refolds nothing; only the live
    screen is rebuilt, with the seam remainder `31/D3` Decision 4 hands back as its first
    line's prefix.
- **Nine judgment calls, recorded as `31/DD39`-`31/DD47` continuing `DD38`'s numbering.**
  The first two are where `31/F6`'s mapping proved wrong against the code; the rest are
  ordinary choices taken as the obvious simple option.
  - **DD39 -- the live screen's refold survives, so `F6` `X2`/`R12` delete history's half
    of it and not the whole.** `X2` deletes `reconstructLogicalLines` and `R12` moves
    `pack(line:columns:)` "to read time", but a width change still has to rewrap the *live*
    screen, and nothing else in the engine can. `31/D3` Decision 2's own table says as much
    ("the seven reflow-only types, **less the live-refold half**"), and `31/F5`
    Observation 2 and `31/F4` case 7 counted the live refold as *moving* rather than
    deleting. So `reconstructLogicalLines`, `pack`, `sourceKey`, `ReflowCursorAnchor`,
    `ReflowDestination` and `PackedReflowLine` stay, restricted to the live rows plus the
    seam prefix; what goes is history as a reflow *source*, which is the ~286-line half
    `X1` names.
  - **DD40 -- the anchor restatement is split at the seam, and that is what replaces the
    attachment machinery.** `31/D3` Decision 2 says a display-row anchor needs "one
    restatement function, not the attachment machinery", and that is exactly right for the
    history side: capture `(record, cell offset)` before the width change, convert back
    after, both arithmetic. It does not cover the *live* side, which is genuinely rebuilt --
    the decision's table is about history. So the live half restates through the reflow's
    own `boundaryDestinations`, which survive for the cursor anyway (DD39). Deleted as
    promised: `ReflowTextAttachment`, `attachments`, `attachment` (both), `textDestination`,
    and `oldUnits = projectionUnits()` -- a whole-history materialization on the resize path.
  - **DD41 -- the projection facade materializes the *painted* walk everywhere.**
    `31/DD25`'s amendment reserves the content walk for copy, selection and search, and the
    facade serves all three. It is still the painted walk, because `projectedCellEnd`
    measures a hard-ended row to `retainedContentEnd`, which excludes a trailing fill
    whichever walk produced the row -- so the distinction is invisible to every text
    consumer, and using the painted walk keeps `scrollbackRow(at:)`, the geometry pass and
    the renderer faithful to what the user saw. The content walk stays reachable and is
    what `recordCells` serves.
  - **DD42 -- a soft-wrapped row projects its own extent, not the pane width.** `31/I1`
    forbids storing a spacer, so a folded row can legitimately be short: at the open tail's
    seam by the dropped `.spacerHead`, and at a forced split whenever the split offset is
    not a multiple of the current width. Measuring those to `columnCount` projected padding
    as spaces the program never printed, which the resize fuzz caught as history text
    gaining a space across a resize.
  - **DD43 -- the history/live seam's spacer is re-derived in `Terminal`, not in the
    store.** The fold re-derives a `.spacerHead` from the wide head that follows it; for the
    *last* retained display row that head is the live grid's first cell, which the store
    cannot see. Slice 3 recorded the resulting short row as an acknowledged divergence;
    four behavioral tests turned out to depend on the column, so `Terminal` -- the one type
    that sees both sides -- makes the same reach the store already makes across a forced
    split's seam. The divergence is gone rather than accepted.
  - **DD44 -- `31/PO7`'s "at most one locate" is read per viewport *traversal*.** A planned
    frame makes two -- the geometry pass and the cell pass -- because they are two public
    reads of two different projections, and merging them would undo `28/F17`. The
    load-bearing half of the obligation is invariance to depth, and that is asserted
    directly: the same count at 60 lines and at 6,000.
  - **DD45 -- `forEachViewportCell` gains a plural spelling, and the planner uses it.**
    `31/D3` Decision 1 rule 2 assumes the per-visible-row walks are loops; the singular
    entry point is called once per row by `RenderFramePlanner`, so under the store it would
    have been one locate per row -- exactly `31/HR1`'s hazard. The plural form takes the row
    range and a predicate, so a damage-clipped frame still folds only what it redraws.
    `31/F6` `U11` called the planner unchanged; this is the one thing it needed.
  - **DD46 -- a budget too small to hold one display row retains nothing rather than
    trapping.** The arena is reserved once and never grown (`31/I2`), so there is no room to
    make for a row that does not fit an empty arena. The old store had no such floor, and a
    `precondition` would turn a degenerate configuration into a crash.
  - **DD47 -- evicting an *open* head record stamps the next record opened.** `31/D2`
    Decision 2 step 2 as amended stamps a dropped forced-split piece's follower; the open
    tail has the same problem and no follower yet, so the stamp is pending until the next
    record opens. Without it a line whose whole retained head was evicted reads as a fresh
    logical line -- the divergence from `isHistoryHeadTruncated = lastEvictedIsSoftWrapped`
    that inherited condition 10 exists to prevent.
- **Two defects the resize fuzz found, both fixed with the test that caught them.** Neither
  is in `31/F6`'s inventory, and both are seam cases the design's own rules imply:
  `truncateTail` folded each handed-back row *after* cutting the one below it, which loses
  the `.spacerHead` the fold re-derives from the row below (it now folds the whole batch
  first); and a widening left the refolded live half shorter than the viewport, which used
  to be padded with blanks -- it now pulls the deficit back out of history, which is `31/D2`
  operation 4 at a third trigger and moves no anchor.
- **Test contract changes, each citing what changed the contract.** `isHistoryHeadTruncated`
  and its 14 assertions are gone (`31/DD10`), replaced by `31/D2` Decision 2's invariant
  asserted on the head record's `startsMidLine`. `narrowThenWidenPreservesCappedHistory` and
  the five other cap tests are gone with the caps; `widthChangeEvictsNothing` states `31/I3`
  directly instead, at three widths down to the engine minimum. A reflow no longer clears a
  search occurrence (`31/I3`, `31/D3` Decision 2). The census's per-row leak flag is restated
  in arena terms (`31/DD11`), and its retained cell count no longer counts a blank line's
  fold floor (`31/DD15`). The saturating resize probe's ceiling is asserted as a direction
  rather than an equality, because eviction is byte-granular. The fold suite's oracle moved
  from "today's stored row" -- which *is* the store now -- to the live grid, which shares no
  code with the fold.
- **`PackedRetainedRow` stops being history storage and survives as an instrument.**
  `ScrollbackBuffer` is deleted outright, and with it the per-row charge model
  (`scrollbackByteCost`, `retainedScrollbackAllocationBytes`, the two `recomputed*`
  accessors, the two sizing helpers), `setScrollbackCell`, `isHistoryHeadTruncated` and both
  caps with their derivations. `PackedRetainedRow` itself stays: the store shares its cell
  coding, and `31/D4`'s frozen eviction probe plus `31/F1`/`31/F3`'s instruments are written
  against it as arm A. Deleting it would make those unrunnable, which is a worse outcome
  than `31/F5`'s line count reads.
- **The index rings' minimum capacity drops from 16 to 4.** The index is charged at what its
  rings allocated (`31/DD37`), so an empty store's charge is a fixed cost every budget pays;
  at 16 slots that floor was 384 B, which made a small history unrepresentable rather than
  merely shallow. Production depth grows both rings past 16 within one screenful, so the
  steady-state charge every `31/F8`/`31/F10` number was measured against is unchanged.

- **Slice 6 defined no new instrument, because an existing frozen one is the trial's own
  shape.** `28/F23` priced candidate (b) with `TerminalHistoryDepthSizingProbe`, which slice 5
  deleted along with the two caps it is written against -- but `F23` Observation 4 had
  *calibrated* that harness against the committed `saturated-wide-resize-v1` recipe (179-column
  full-width lines at 179x66 <-> 100, budget-saturated, 4 warmup + 20 timed resizes) and found
  the two agree within 2.5%. So the measurement is that committed probe, unmodified, run at
  `de17e95` and at `9ad7cc5`; nothing new was frozen. What the slice *did* write first was the
  reading rule, before either arm ran. Both arms, the rule and its two named failure readings
  are in `28/D11`'s amendment.
- **One judgment call, recorded as `31/DD48` continuing `DD47`'s numbering**, taken as the
  obvious simple option and a human's to revisit:
  - **DD48 -- the exit's measurement lives inline in `28/D11`'s amendment rather than as a new
    doc 28 finding.** Doc 28's next free finding id is `F25` (`F24` is reserved for Phase 2's
    resize *profile*, which `F23` renumbered onto it), so a finding was available. Three
    reasons it is not one. `31/D2` Decision 4 prescribes the shape -- "a doc 28 amendment that
    records the human's exit-1 verdict **and** notes that the successor removed the cost the
    verdict accepted, **with the resize measurement re-taken**" -- so the measurement is
    written as part of the closure, not as evidence a later entry consumes. `D11` already
    carries `Behavioral verification` and `Quantitative verification` bullets, which is where a
    decision entry's own numbers belong in this doc's format. And the reading is one committed
    recipe with one arm per revision and no pairing or calibration gate -- a finding id would
    advertise it as evidence for future decisions to cite, which would overstate what a
    two-point probe supports. The cost of the choice, stated: a reader who greps doc 28's
    findings for "resize measurement against the new store" will not find one, which is why
    both README ledger rows and doc 31's Phase 3 ledger name the amendment by its heading.

- **Slice 7 records a failed acceptance, and the plan stops there rather than acting on
  it.** The ladder is this plan's own gate and it read `slower` on all three rungs it
  names, so the slice's deliverable -- the record -- is complete and the plan's Acceptance
  is not. What the slice did in the order the plan fixed: ran `just benchmark-confirm
  baseline=28c54e1` once (the pre-cutover parent, which is `9ad7cc5`'s parent and so
  isolates the cutover from the four commits that built the store), read every rung against
  its frozen threshold, then ran `31/D3` Decision 1's two diagnostics **before concluding
  anything**, then took the residency and pathological readings the checklist also owes.
  Nothing was optimised, profiled or reverted: the plan says the disposition of a `slower`
  verdict is the human's, and `agent-docs/terminal-performance.md` says to report and pause
  before optimizing.
- **The ladder's result does not fit any probe boundary this campaign built, and the entry
  says so rather than resolving it.** `31/F1` measured the read walk at 0.61x, `31/F3`
  admission at 0.62x-0.69x, `31/F10` the whole write path at 0.856x-1.023x -- and the wired
  engine browses 60% slower and drains a PTY 6.2x slower. Every one of those probes drives
  `LogicalLineStore` directly; the ladder drives `Terminal`. The one new measurement that
  narrows it is the pane-level residency reading (8.62x footprint, 0.007x row allocations,
  census coverage 0.46 -> 0.05), which says the pages being dirtied are not retained
  history and are not charged. A profile is the next instrument and is deliberately not
  taken here.
- **Two judgment calls, recorded as `31/DD49`-`31/DD50` continuing `DD48`'s numbering**,
  each taken as the obvious simple option and each a human's to revisit:
  - **DD49 -- the residency re-read is `31/D4`'s named pane-level instrument rather than a
    re-run of `31/F10`'s in-test four-state ladder.** The store is wired now, so
    `just terminal-memory-probe` -- which `D4` named and which `F8`/`F10` had to substitute
    for -- measures a real pane for the first time; the four-state ladder's only store
    change since `5cf61e0` is the index rings' minimum capacity, which moves an empty
    store's floor and not a cycled one's; and the ladder verdict means no decision is
    waiting on the number. What it costs, stated: `D4`'s second reject trigger is written
    "in the same session", and today's store no longer exists in the tree, so no
    same-session control can be built at this revision. The four states and the `blank`
    regime are recorded as **not measured**, not as measured-zero.
  - **DD50 -- the `DD8` tally cancels the arena's maintained metadata charge against
    today's `scrollbackByteCost` maintenance** rather than counting it as a new invariant.
    Both are the same obligation in two stores. Counting it instead makes the tally 4.5
    against 8.5; the direction does not change either way, which is why it did not block.
- **`31/F12`'s probe file is the one non-doc file this slice adds.** It is a test-target
  probe gated behind `DANTERM_LOGICAL_LINE_PROBE`, exactly as every probe since `31/F1`,
  and it touches nothing under `lib/TerminalCore/Sources/`. It is committed rather than run
  from scratch because the campaign's convention is that a finding's instrument is
  re-runnable, and because the fold hazard it measured is now a named target.

## Follow Up

- **Doc 28's Phase 2 resize *profile* (`F24`) is now a different question, and its
  README entry still states the old one.** It asks where inside reflow's dominant
  per-cell term the time goes, and names itself "the prerequisite for `D8`'s cell
  cap ever rising" -- but slice 5 deleted reflow of history and the cell cap both.
  What survives is the live screen's refold, which slice 6's after arm prices at
  1.46 ms (widening) and 2.65 ms (narrowing) on a 179x66 pane. Either restate the
  task against the live refold or close it; it is currently a live ledger item
  nobody can run as written. `docs/research/28-retained-row-optimizations/README.md`
  Outcome item 1 and the Phase 2 ledger row are the two places that say it.
- **`28/D8`'s ~150 ms resize budget is unowned.** `D11`'s amendment deliberately
  does not supersede it (exit 1 said a keep-the-caps successor would), because
  resize cost stopped being a function of history depth and a successor budget
  wants deriving against the live screen. Nothing currently bounds resize cost.
- **The cutover's regression is unattributed and nothing is profiling it.** `31/F11` bounds
  where the cost is not -- not the locate count, not the projection arithmetic, not the
  content-identity table, not `LogicalLineStore.admit`/`evictOneDisplayRow` as `31/F10`
  measured them -- and never names it. The next instrument is
  `just benchmark-trace scrollback-stream template="Time Profiler" seconds=30` plus a browse
  profile, and the residency reading (8.62x footprint, 0.007x row allocations, census
  coverage 0.05) says to look for per-row allocation on the wired admission and read paths
  rather than inside the arena.
- **`LogicalLineStore.forEachFoldedCell` re-enumerates the whole record for every display
  row it folds** (`LogicalLineStore.swift#forEachFoldedCell` calling
  `LogicalLineRecord.LogicalLineFold.enumerateRows`), which `31/F12` measured at ~1.95 ns
  per record-cell per display row -- 133 us per row and 8.8 ms per frame at the 65,536-cell
  forced-split cap, 40.3x ordinary content. `rowCount` and `firstRowCellEnd` already have
  the arithmetic fast path this walk lacks, and `31/D3` Decision 7 settled that the boundary
  walk is `O(display rows)`. Independent of how the ladder question resolves.
- **`31/DD8` has reopened and the README's second acceptance dimension with it.** Both
  clauses are met (`31/F11` Observation 4). A human owes the choice of unit and, if the
  invariant reading is kept, a disposition on the two additions that cross the store's
  boundary: `31/DD43`'s seam-spacer reach at four `Terminal` call sites, and the
  `historyEvictionsObserved` eviction-delta protocol.
- **The residency gate is only partly re-read at the landed revision** (`31/DD49`).
  `31/D4`'s four pane states and the `blank` regime are **not measured** there, and its
  second reject trigger is unreadable by construction now that today's store is gone from
  the tree. If the cutover is held, that gate wants a same-session instrument that does not
  depend on the incumbent existing.
- **`28/D8`'s ~150 ms resize budget is still unowned and `28/F24` still states a question
  nobody can run.** Both were surfaced by slice 6 and neither is this plan's; they are
  repeated here because slice 7 is the plan's last commit and they would otherwise leave
  with it. `docs/research/28-retained-row-optimizations/README.md` Outcome item 1 and its
  Phase 2 ledger row are the two places to edit.
