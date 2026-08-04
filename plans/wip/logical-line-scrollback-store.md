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
touching history -- the remaining resize work is refolding the live screen and
one pass to recount display rows. Deleted with it: reflow of history, both caps
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
- the simplification inequality holds on invariants -- currently 4.5
  cross-cutting contracts deleted against 4.5 local ones added
  (`31/F5` as amended by `31/D3`).

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
row (69 enumerated in `31/F6`). Out of scope by construction: the live grid's
refold, which survives; the alternate screen, which has no scrollback; the
checkpoint/persistence path, which serializes history as text; and the C1 cell
format (`28/D9`, `28/D10`), which is not reopened.

**Milestone 1 -- the store.** Arena, derived index with eager whole-index
recompute at a width change, open-line admission, head-granular eviction, the
read-time fold, and the caps' deletion. The projection facade keeps
materializing a row per pointer query (`31/D3` Decision 5): the per-frame path
already borrows and never goes through it, so milestone 1 lands the arena on
exactly the path `31/F1` measured. Judged by the ladder.

**Milestone 2 -- the borrowing cursor.** Replace the materializing facade with a
borrowing cursor and a forward walk over records for whole-history reads.
Scheduled after milestone 1 lands; promoted ahead of the rest of milestone 2 iff
doc 21's `.character` drag-move at trial depth re-measures **above 121 us** under
doc 21's own instrument (`31/D3` Decision 5, frozen before the number exists).

## Invariants

- **I1 -- nothing width-dependent is stored.** A record's bytes are a function of
  content alone. Every width-dependent quantity is a cache that a flush can
  rebuild from the arena.
- **I2 -- one bound, and it holds by construction.** Arena bytes in use plus
  index plus side tables never exceed the scrollback byte budget; the arena is
  allocated once at that capacity and is never grown, compacted or shrunk. The
  budget constant does not change at migration, and no content class loses depth
  (`31/D2` Decision 1).
- **I3 -- a width change evicts nothing**, at any width down to the engine
  minimum. The lossiness `28/D8`'s row cap could not avoid becomes
  unrepresentable.
- **I4 -- eviction stays display-row granular.** No anchor and no scrollbar
  position moves further per admitted row than it does today. A head record
  trimmed inside a logical line reads as a mid-line continuation and carries no
  semantic mark.
- **I5 -- the middle is immutable.** The head record's header and the tail record
  are the only writable bytes; the arena has exactly the five mutating
  operations `31/D2` Decision 2 enumerates, as amended by `31/D3`.
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
  admission, head eviction, tail truncation, forced split, clear-all.
- **I10 -- no record exceeds 1/32 of the budget.** A logical line past that cap is
  hard-split with a marker, and readers rejoin split records by adjacency
  (`31/D3`-ratified `31/F4` derivation: the cap moves if the budget does).
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
- **PO11 (gate).** `just test` passes, and the deletion list `31/F5` names is
  actually gone from the tree rather than relocated.

## Acceptance

Landing is decided by the paired benchmark ladder against a real
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
- Milestone 1 does not rewrite the projection readers; the whole-history
  materialization stays as it is until milestone 2.
- No scheduling work: `28/F20`'s residual may be scheduling rather than encoding,
  and this store does not address it.

## Accepted risks

- **AR1 -- eviction's cost is unknown on both sides.** The head-trim adds a fold
  walk per step that today's removal does not pay. Mitigation is the measurement
  gate above; the fallback is whole-record eviction with its anchor jump accepted
  as a behavior change.
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
- **AR6 -- first-touch residency is an assumption about the allocator.** If the
  arena is allocated in a way that touches every page, an idle pane costs its
  whole capacity resident; PO3's census is what would catch it.
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
- How the fold computes a cut offset, and how the ring's wrap seam is kept from
  splitting a record, provided a record stays contiguous and the waste is bounded
  and charged.
