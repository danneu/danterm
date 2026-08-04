# Logical-line scrollback: store content unwrapped, wrap at read

Research started: 2026-08-04. Continues
[28-retained-row-optimizations](../28-retained-row-optimizations/README.md):
`28/D8` capped retained depth because resize reflow visits every retained row
(`28/F15`: `1.85 us x rows + 0.352 us x cells`), `28/F23` priced the human's
~10,000-rows-at-179-columns target at a measured 600.5 ms reflow, and `28/D11`
shipped those bounds as a dogfood trial. This doc supersedes `28/H7` (the
incremental hybrid that would defer reflow) as the resize direction: the human
chose a from-scratch redesign that removes reflow-of-history entirely instead
of scheduling it better. Inherited boundary: C1's cell format is settled
(`28/D9`, `28/D10`) and is not reopened here -- this doc changes what a stored
*record* is, not what a stored *cell* is.

- [findings.md](findings.md) -- the append-only evidence chain; F1-F4 are the
  Phase 1 viability probes and F5 is the simplification-inequality accounting
  pass D1's rule owed at its close.
- [decisions.md](decisions.md) -- the auditable decision log; D1 is the
  go/no-go gate, whose rule was frozen before F1's comparison was read and
  which closed **`go`** on 2026-08-04, licensing Phase 2's design work only.
  D4 is the newest entry and freezes the eviction comparison's rule -- and the
  `AR6` residency reading sequenced with it -- before any such number exists.

## Purpose

This doc owns the question: **can history be stored as unwrapped logical lines
-- one record per line a program actually printed -- with wrapping computed at
read time, without regressing the read path?** Wrapping today is baked into
stored data (display rows with continuation flags), which is the single fact
all the resize pain descends from: reflow must mutate every retained row, so
depth is latency, and `28/D8`'s cell and row caps exist only to bound that
product. Store content unwrapped and resize stops touching history at all: the
only resize work left is refolding the live screen and one metadata pass to
recount display rows.

Two acceptance dimensions, and a change lands only on both:

1. **Measured non-regression.** The paired-benchmark ladder decides;
   `retained-browse` parity is the go/no-go, because the named fear is
   scroll-speed regression from the added wrap-at-read indirection. No design
   argument substitutes for a verdict.
2. **Net simplification.** The deletion list (history reflow mutation, the
   cell cap, the row cap, their derivations and tests, narrow-then-widen
   machinery, continuation bookkeeping in retained history) must exceed the
   addition list (arena, block-summed wrap index, open-line rule, forced-split
   rule), and every addition must be pure and unit-testable. If the design
   drifts to where that inequality no longer holds, that is evidence against
   the direction, not a cost to absorb.

   **Evaluated 2026-08-04 by [F5](findings.md), and it holds -- on invariants,
   not on volume.** All six deletion-list items are present in the tree and
   genuinely removed; the addition list has six members (F4 added the
   `hasWideCells` fast/slow split, and F5 names spacer re-derivation at read as
   the sixth) and all six are pure, unit-testable and free of width-dependent
   persisted state. On lines of code the comparison is close to a wash and F5
   says so; what carries it is **five cross-cutting invariants deleted against
   three and a half local ones added**. Dimension 1 remains outstanding: it is
   the paired ladder's, against a real implementation, and Phase 1 produced only
   microbenchmark predictions of it.

## Investigation rules

- **Design from first principles.** iTerm2 proves the category
  (`references/iterm2/sources/LineBuffer.h#unwrappedLineAtIndex` stores raw
  lines and wraps per-width at read); most other pinned terminals store
  display rows and rewrap destructively (e.g.
  `references/wezterm/term/src/screen.rs#rewrap_lines`). **`F4` amends this:
  vte is a second, partial member** -- its scrollback is a width-free text
  stream plus a separately stored row stream that `references/vte/src/ring.hh`
  says "is regenerated when the contents rewrap on resize", so it holds the
  record format this design wants but regenerates wrap points eagerly at
  resize instead of deriving them at read. Read the references
  to mine edge cases and failure inputs, cited `file#identifier` -- never to
  port structure. Any adopted mechanism is justified on DanTerm's own
  constraints or not adopted (`AGENTS.md`: references are input, not
  authority).
- Read `agent-docs/terminal-performance.md` and
  `agent-docs/measurement-discipline.md` before producing any number. Freeze
  each decision rule in [decisions.md](decisions.md) before reading the first
  comparison result it governs.
- **The arc baseline is pinned: `de17e95`** (the commit that opened this doc;
  no part of the design exists in the tree at that revision). When the
  implementation is judged as a whole, its total performance difference is
  measured against `de17e95` -- this doc's analogue of `28/F22`'s
  wide-baseline audit. Two-tier discipline, per
  `agent-docs/terminal-performance.md`: the wide reading is **descriptive
  accounting only** (a wide gap attributes everything landed in between,
  including work unrelated to this doc), and it never substitutes for
  verdicts. Every individual change still earns its verdict against the
  parent revision it forked from, under a rule frozen before the comparison
  is read. Checkpoint sub-benchmarks during implementation are that
  per-change tier, not this one.
- Phase 1 prototypes live in scratch or test targets only. No production
  storage change of any kind before `D1` answers go.
- **Eager index recompute is the milestone-1 choice, by explicit human
  decision**: on a width change, all cached block totals are discarded and
  recomputed in one pass. Lazy per-block recompute is a recorded alternative
  (see Rejected), reopened only if `F2` measures the eager pass above budget.
- Claims about current storage behavior cite doc 28's findings rather than
  re-measuring them; this doc re-measures only what it changes.

## Trigger and current evidence

The chain that opened this doc, all measured in doc 28:

- Real content at 179 columns nearly fills the width: the retaining workloads
  measure median 119-154 cells/row with p95 at 179 (`28/F23`), so "typical"
  and "worst case" barely separate and the cell cap is the operative bound.
- Reaching ~10,000 retained rows of that content costs a measured 600.5 ms
  synchronous reflow (6.04x the 99.5 ms pre-packing baseline) and ~15 MiB
  (`28/F23` candidate (b)); `28/D11` shipped those bounds as a dogfood trial
  and the human judged the hitch livable but chose to fund removing its cause.
- The cost model is two terms, rows and cells (`28/F15`), and both caps exist
  only because reflow visits every retained row (`28/D8`). A store that never
  reflows history deletes the caps' reason to exist.
- The byte budget binds nothing today (`28/F23`: peak 3.38 MB of 10 MiB), so
  a design where the byte budget is the *only* bound is returning to the knob
  the human originally wanted, not inventing a new one. **`D2` corrects this
  bullet**: 3.38 MB of 10 MiB is a `28/D8`-era reading, and at `28/D11`'s
  shipped bounds (budget 16 MiB) the byte budget already binds for short-line
  content while the cell cap binds for everything else. The conclusion is
  unchanged -- one bound is still where this design lands -- but the premise
  "the budget binds nothing" is no longer true of the tree.

## Current hypotheses

### H1 -- the read path fits inside retained-browse parity

Proposed mechanism: display-row lookup is a binary search over per-block
display-row totals plus an in-block scan, with per-line display-row counts
derived as `ceil(cells / width)` from the record header -- nothing
width-dependent is stored, wrapping of visible rows happens at read into the
existing projection shape. Supporting evidence: C1's readers already reached
browse parity through a materialize-per-row path (`28/F17`), so the budget for
"read a row" demonstrably absorbs a decode step. Competing explanation: the
extra indirection per viewport row (index walk + offset arithmetic) lands on
exactly the path `28/F17` had to fight for, and gives back that win.
Falsifier: a `slower` verdict on `retained-browse` under its frozen rule, from
the F1 probe or any later candidate. This is the go/no-go input to `D1`.

**Confirmed 2026-08-04 by [F1](findings.md), and the competing explanation is
refuted.** The candidate did not merely fit inside parity -- it browsed 1.64x
faster than today's store on both content classes, because today's store is one
heap allocation per retained row and the arena is one contiguous region. Note
what remains unverified: F1 measures the read walk in isolation, so the
prediction that this is worth ~-2% on `retained-browse` at the frame is a
conversion through `28/F17`'s share, not a measurement. Only the paired ladder
against a real implementation can settle it, and that is Phase 2's.

### H2 -- the eager counting pass is milliseconds at depth

Proposed mechanism: recomputing every block's display-row total for a new
width reads one cell-count integer per line and does one divide -- no cell
movement, no allocation -- so it is orders of magnitude cheaper than reflow's
`0.352 us x cells` term. Confirm: measured pass at or under ~10 ms at 100,000
lines of wide content (with the 10,000-line figure recorded alongside).
Reject: a pass that approaches frame budget at the `28/D11` trial depth, which
would force the lazy per-block alternative back onto the table.

**Confirmed 2026-08-04 by [F2](findings.md).** Measured 0.641 ms at 100,000
lines against this bound's 10.0 ms, and 0.016 ms at 10,000 -- about a thousandth
of the frame the reject condition names. The mechanism is as proposed (one
count read, one divide, no cell movement), and the per-line cost is flat to
30,000 lines before cache residency roughly triples it by 100,000, at a depth
the byte budget makes unreachable. What remains unverified: F2 prices the
counting pass alone, not a whole resize -- refolding the live screen survives
this design and is unmeasured here.

### H3 -- admission gets no worse, and plausibly better

Proposed mechanism: a row scrolling off appends its cells to the open logical
line (one memcpy-shaped append into the arena) instead of constructing and
packing a per-display-row record; fewer records, less per-row header work.
Caution from the ancestor doc: admission is exactly where `28/H3`'s residuals
live (`terminal-feed` +4.55%, `scrollback-stream` +4.13%, `28/F20`), and
`28/H8`'s evidence says those costs are scheduling, not encoding -- so neutral
is the expectation and "better" is not assumed. Falsifier: a `slower` verdict
on `terminal-feed` or `scrollback-stream` against the store this design
replaces.

**Confirmed 2026-08-04 by [F3](findings.md), and confirmed in the direction the
hypothesis declined to assume.** Open-line append admits a scrolled-off row
**1.45x-1.60x faster** than today's pack-per-display-row admission on all three
verdict-bearing classes (0.624x `mix`, 0.691x `full`, 0.624x `stream`), with A/A
controls under 0.5% -- against a rule that only needed 1.00x to confirm and 1.09x
to reject. The proposed mechanism is **not** what produced it: on `stream`, the
class reproducing `scrollback-stream`'s own CRLF row shape (`28/F20` Observation
5), the candidate creates one record per display row -- exactly as many as today
-- and is still 0.624x. The saving is a per-row constant, and `28/F20`'s lesson
holds a third time: the cost is the allocation and write pattern, not the
encoding. What remains unverified: F3 sees the encode-and-store term alone, so
`H3`'s own caution stands -- if `28/F20`'s residual is scheduling, this does not
remove it, and the conversion to roughly -7% on `scrollback-stream`'s block is a
prediction through a share. Eviction is unmeasured.

### H4 -- the edge-case set is enumerable, and none requires stored width

Proposed mechanism: the behaviors that make reflow subtle -- a wide character
that does not fit in the last column, the cursor sitting on a soft-wrapped
line during a width change, selection endpoints across a resize, scroll
anchoring, the alternate screen (no scrollback; expected untouched) -- are all
decidable as pure functions of (logical line, width) plus a small amount of
live-grid state. Confirm: F4 produces a table of inputs and intended DanTerm
behavior with no entry that needs width-dependent data persisted in history.
Reject: any edge case that genuinely requires storing wrap state, which would
break the design's core premise and is exactly the kind of thing the
references' test suites exist to surface.

**Confirmed 2026-08-04 by [F4](findings.md), and `D1`'s no-go trigger does not
fire.** 28 cases were catalogued from seven reference implementations plus
DanTerm's own reflow path and its ~40 resize/wrap tests, and every one is
decidable from (logical line, width) plus live-grid state; **no entry needs
width-dependent data persisted in history.** The sweep produced one correction
to the *mechanism* `H1` states rather than to what is stored: display-row count
is `ceil((cells + spacers) / width)`, not `ceil(cells / width)`, because a
2-cell cluster meeting a one-column gap does not split. Two cases want a
width-independent content bit in the record header (`hasWideCells`,
`forcedSplit`), and both are optimizations or markers, not widths. What remains
unverified: `F2` priced the counting pass on ASCII stimuli only, so the
O(cells) fallback for wide records is unmeasured.

## Candidate direction, pending evidence

Provisional sketch, recorded before any probe has run; F1-F4 exist to change
it.

- **One contiguous byte ring per pane.** Variable-length logical-line records:
  a small header (cell count, flags, a semantic-mark slot for OSC 133), then
  C1 cells, then style runs. Append at the back, evict at the front, middle
  immutable. The byte budget *is* the arena size -- memory is bounded by
  construction and the byte budget becomes the only cap. **`D2` settles this
  bullet**: the arena's capacity is the budget, allocated once at 16 MiB and
  never grown or compacted; the index and side tables are charged inside it;
  eviction is display-row granular at the head; and "middle immutable" narrows
  to its true form -- the head record's header and the tail record are the only
  writable bytes.
- **A derived wrap index, never a stored one.** A deque of record offsets,
  blocked ~256 lines per block, one cached display-row total per block at the
  current width. Lookup: binary search over block totals, then an in-block
  scan. On width change: discard all block totals, recompute eagerly in one
  pass (H2 prices this). Nothing width-shaped survives a cache flush, which is
  the purity property the whole design leans on. **A record's display-row count
  is `ceil(cells / width)` only when it holds no wide cells** (`F4`
  Observation 1): a record whose `hasWideCells` header bit is set costs a scan,
  because a 2-cell cluster meeting a one-column gap starts the next row instead
  of splitting. The bit is a content property, not a width. **`D3` Decision 7
  corrects the scan's cost**: it is `O(display rows)`, not `O(cells)` -- one
  boundary probe per display row, backing off a column when the boundary cell is
  a wide tail, which is the loop `F4` already quoted from iTerm2.
- **The open-line rule at the live boundary.** A row scrolling off the live
  viewport appends its cells to the current open logical line; a hard newline
  closes the line. Scrolled-off content is immutable, so the open line only
  ever grows at its end, which the arena already supports. **`F3` measured this
  rule and it is 1.45x-1.60x cheaper per admitted row than today's admission**;
  `F4` Observation 5 is what licenses the "only grows at its end" premise, since
  all three of today's writes into retained history target the tail row. `F3`
  `DD5` settles one detail the sketch left open: a closed record's display-row
  count at the admitting width is **counted** as rows arrive, not derived, so
  neither `ceil` nor the wide-cell scan below runs on the write path at all.
- **The forced-split rule for pathological lines.** Hard-split a logical line
  at a fixed cell cap, with a `forcedSplit` flag so copy and search rejoin
  logically. One documented wart, bounded up front. **The cap is 65,536 cells,
  now derived rather than guessed** (`F4` Observation 3, `DD3`): a C1 cell is 8
  bytes and the byte budget is 16,777,216, so the rule is *no record exceeds
  1/32 of the arena*, which bounds both hazards the cap exists for -- eviction
  granularity and the wide-cell scan. No surveyed terminal caps a logical line
  at all; the two near-precedents (wezterm's 1,024-cell scan limit, vte's
  500-row BiDi limit) degrade a feature rather than split the line.
- **What this deletes** (the simplification side of the acceptance gate):
  history reflow mutation, `productionScrollbackCellCap`,
  `productionScrollbackRowCap`, the `28/D8` cost-model derivations and their
  tests, narrow-then-widen eviction machinery, and continuation-flag
  bookkeeping in retained history.

## Task ledger

### Phase 1 -- viability evidence (gates everything else)

- [x] `DONE` **F1, the read-path probe.** Recorded in [F1](findings.md);
  `D1` Part A answers **go** on the read path. The candidate browsed **1.64x
  faster** than today's store on both content classes (0.608x / 0.610x
  ns per display-row read) and was faster on random seek too (0.898x / 0.803x),
  A/A controls under 1%. `H1` is confirmed and its competing explanation
  refuted, including the deflationary reading that the win was ARC on today's
  per-read row copy (measured; it is not). Probe:
  `lib/TerminalCore/Tests/TerminalCoreTests/TerminalLogicalLineReadProbe.swift`,
  gated behind `DANTERM_LOGICAL_LINE_PROBE`. Its `recomputeIndex` is the eager
  pass `F2` needs, and its `blockSize` sweep is where to start if seek cost
  ever binds.
- [x] `DONE` **F2, the counting pass at depth.** Recorded in
  [F2](findings.md); `H2` **confirmed** with a 15.6x margin. The eager
  recompute costs **0.015-0.016 ms at 10,000 logical lines** (17,248 display
  rows of `mix` content -- 1.72x the depth `28/F23` priced at 600.5 ms of
  reflow) and **0.545-0.641 ms at 100,000**, reading counts from the record
  headers as the sketched offsets-only index requires. Eager stands for
  milestone 1 and lazy per-block recompute stays in Rejected. Phase 2 input:
  **keep the index offsets-only** -- a parallel counts array is 4.3x faster on
  the pass at 100,000 lines and buys nothing at any reachable depth. Probe:
  `lib/TerminalCore/Tests/TerminalCoreTests/TerminalLogicalLineIndexProbe.swift`,
  same env gate as F1's.
- [x] `DONE` **F3, the admission probe.** Recorded in [F3](findings.md); `H3`
  **confirmed**, and the campaign's residuals are not made worse by this store.
  Open-line append admits a scrolled-off row at **0.624x / 0.691x / 0.624x** of
  today's pack-per-display-row cost on `mix` / `full` / `stream`, A/A controls
  under 0.5%, against a rule that needed only 1.00x to confirm. `stream` is the
  class that matters: it reproduces `scrollback-stream`'s own CRLF row shape
  (`28/F20` Observation 5), where the candidate creates **one record per display
  row, as many as today**, and it wins anyway -- so the win is not the
  record-count reduction the sketch predicted. Three things it hands forward:
  (a) the saving is a **per-row constant** (tripling stored cells per row moves
  it 9%), so it is the per-row blob allocation the arena deletes; (b) today's
  admission is **90-95% encoder** -- the buffer append and byte accounting are
  5-10% -- so a container-only fix could recover at most a tenth of this; (c) the
  arena holds the same content in **0.744x-0.925x** of the bytes the budget
  charges today, which Phase 2's budget task needs. Probe:
  `lib/TerminalCore/Tests/TerminalCoreTests/TerminalLogicalLineAdmissionProbe.swift`,
  same env gate as F1's and F2's; F1's and F2's files are unedited. Two deferred
  decisions added (`DD5`, `DD6`). Unmeasured: eviction, and anything about
  scheduling.
- [x] `DONE` **F4, the edge-case inventory.** Recorded in [F4](findings.md);
  `H4` **confirmed** and `D1`'s no-go trigger **does not fire**. 28 cases
  catalogued from seven reference trees plus DanTerm's own reflow path and
  tests; **zero require stored width**, two want a width-independent content
  bit (`hasWideCells`, `forcedSplit`). Three things it hands forward: (a) the
  arithmetic correction -- display rows are `ceil((cells + spacers) / width)`,
  so a record holding wide cells needs an O(cells) scan; (b) the forced-split
  cap is 65,536 cells *derived* as 1/32 of the byte budget, since no terminal
  surveyed caps a logical line at all; (c) all three of today's writes into
  retained history target the tail row only
  (`Terminal.swift#severScrollbackWrapClaim`,
  `#restoreWrapClaimBeforeCursor`, `#clearPreviousSpacer`), so the arena's
  "middle immutable" premise holds and two of the three become header-bit
  flips while the third disappears. Four deferred decisions are recorded in
  F4 for the human to revisit.
- [x] `DONE` **D1, the go/no-go gate -- closed `go`.** Rule frozen at `eee1832`
  (Part A) with Part B's sub-rules frozen at `497d181` (F2) and `d6c83b0` (F3),
  each in a commit predating the probe it governs. Full adjudication in
  [decisions.md](decisions.md). Part A answered `go` on the read path (F1);
  Part B is complete -- `F2` confirmed `H2` with a 15.6x margin, `F4` confirmed
  `H4` and the stored-width no-go trigger **did not fire**, `F3` confirmed `H3`
  outright at 0.624x-0.691x, and **[F5](findings.md) finds the simplification
  inequality holds**. No frozen threshold was failed by any input.
  **Scoping, which is part of the verdict:** `go` licenses **Phase 2's design
  work and nothing else**. No production storage change is licensed, because
  every Phase 1 number is a microbenchmark and this doc's first acceptance
  dimension gives the verdict to the paired ladder -- `retained-browse`,
  `terminal-feed` and `scrollback-stream` against a real implementation, under
  rules frozen before the comparisons are read, are all still owed. The -2% and
  -7% frame figures are conversions through measured shares, not measurements.
  `28/H7` stays in Rejected and its reopening condition becomes a `slower`
  ladder verdict rather than a `D1` no-go. Eleven conditions and unpriced terms
  are carried forward into Phase 2 and enumerated in the D1 closure; the four
  that bind hardest are the **unpriced wide-record counting fallback**,
  **eviction unmeasured on both sides**, the **paired ladder**, and the
  **`28/D11` trial bounds** this design's caps are currently shipped as.

### Phase 2 -- design (complete: D1 answered go on 2026-08-04, graduated the same day)

Read the "Conditions and unpriced terms Phase 2 inherits" list in
[decisions.md](decisions.md) before starting any task below; the tasks are the
work, that list is the constraint on it.

- [x] `DONE` **F6, the display-row-indexed call-site enumeration.** Recorded in
  [F6](findings.md); it discharges inherited condition 6. **69 sites** across
  `lib/TerminalCore`, `lib/TerminalPTY` and `app/` -- **14 unchanged, 16
  index-translated, 18 rewritten, 13 deleted, and 8 whose mapping is not
  obviously satisfiable.** Three boundary answers the seed list wanted: the
  checkpoint and persistence path serializes history as **text**
  (`primaryHistoryText`), so the record format owes it nothing; scrollbar math
  is a pass-through over `TerminalScrollProjection`, so the work is in its
  producer; and search needs no index of its own -- `searchMatches` gets
  *simpler*, since wrap boundaries stop existing in the data. The structural
  finding: only 13 of the 69 sites read a **cell** out of history; the other 56
  read a count, an index or a flag, so the difficulty is not decoding at a width
  but that **a display-row count is free today and becomes derived**. The four
  flagged items that are design decisions rather than edits: `HR1`
  (`scrollProjection.topRow` is read ~200x per frame and would become an index
  lookup -- this lands on `retained-browse`, the go/no-go), `HR2` (anchors
  straddle history and the live grid, and `F4` case 13 addresses only the
  history half; ~130 lines of deletion rest on the choice), `HR4` (`resizeHeight`
  pulls rows back out of history -- a **fourth** tail mutation `F4` Observation 5
  missed, and a truncation rather than a bit flip), and `HR6` (`ProjectionRows`
  hands out a materialized row per display row, the allocation the arena exists
  to delete). Two are user-visible behavior changes needing a human's
  disposition: `HR3` (severing a wrap claim drops a BCE-colored cell that is
  stored and painted today -- the first case found where the read-time fold does
  not reproduce today's output) and `HR5` (whole-record eviction drops up to 367
  display rows at once, clamping four anchors and the browsing viewport). Three
  deferred decisions added (`DD9`-`DD11`). `28/H7`'s entry names the invariant
  that dies -- "history is always at the current width" -- and F6 Observation 3
  says exactly which sites depended on it.
- [x] `DONE` **`D2`, budget and eviction semantics.** Recorded in
  [decisions.md](decisions.md); it **discharges inherited conditions 4 and 7**,
  ratifies `DD3`, amends `DD2`, and advances 2, 5, 8, 9 and 10. Five decisions:
  (1) **one charged-byte bound at the same 16 MiB** -- the arena's capacity *is*
  the budget, allocated once and never grown, compacted or shrunk, with the
  block index (8 B per record), the spill table and the two side tables charged
  **inside** it; the number is re-derived from `F3` Observation 4's measured
  footprint (13.74 MiB for `28/D11`'s own 10,000-full-width-row target) rather
  than inherited from the cap arithmetic that dies with the caps, and **every
  measured content class gets 1.16x-1.32x deeper at the same constant**.
  (2) **Eviction is byte-driven, display-row granular at the head and never
  copies**: whole records while they fit, then a trim of the head record's
  prefix with its 8-byte header rewritten in place -- which closes `HR5`'s
  367-row anchor jump instead of accepting it, and **amends `DD2`** to its own
  recorded alternative. The five mutating arena operations are enumerated there,
  including `HR4`'s tail truncation, the only back-of-arena shrink. (3) **No
  user-facing "keep N lines" knob ships**: a display-row denomination would
  reintroduce `28/D8`'s narrow-then-widen lossiness, which this design otherwise
  makes unrepresentable, so any future knob is denominated in bytes or logical
  lines. (4) **`28/D11`'s cell and row caps are deleted with no analogue and its
  budget survives unchanged**; the trial itself keeps running until doc 28
  records an exit, and the migration creates a fourth exit ("the cause is
  removed") that doc 28 owes an amendment for. (5) A trimmed head record reads
  as a mid-line continuation and loses its semantic mark, which is what replaces
  `isHistoryHeadTruncated` under `DD10`. Three deferred decisions added
  (`DD12`-`DD14`) and one open question that needed a measurement: the blank-line
  regime admits 1,048,576 records, 10.5x anything `F2` measured, with the
  probe and its decision rule frozen in the entry. **`F7` has since answered it
  and no decision moved.**
- [x] `DONE` **F7, the blank-record counting pass.** Recorded in
  [F7](findings.md); it **closes `D2`'s open question** and spends `D2`'s
  reopening condition 1. The eager recompute costs **0.760-0.761 ms at 1,048,576
  zero-cell records** -- the full record count `D2` Decision 1's per-record index
  charge admits at 16 MiB -- against the **16.67 ms** one-frame bound `D2` froze,
  so **no record-count safety bound ships** and Decision 1's single charged-byte
  bound stands. `D2`'s ~6.4 ms extrapolation was **8.4x pessimistic**: the ladder
  (10,000 / 100,000 / 300,000 / 1,048,576) measures the per-record cost **flat at
  0.69-0.73 ns**, where `F2`'s content ladder tripled over the same span, because
  the pass's cost is governed by **stride, not record count** -- which is also
  why the `arena` and `counts` sources converge to within 10% here against 4.3x
  apart at `F2`'s depth. Gates: non-elision on all 342 passes plus a **sentinel
  arm** that restores the width-responsiveness a blank stimulus cannot show
  (1,049,624 rows at width 100 against 1,048,576 at 179), synthetic-vs-real
  fidelity 0.997x-1.003x against a 15% allowance, load 1.78 before and after; the
  content-class calibration gate is inapplicable to a zero-cell stimulus and is
  dropped explicitly. No invocation voided; one crashed before producing a number
  and is recorded, which is where `DD15` comes from. Probe:
  `lib/TerminalCore/Tests/TerminalCoreTests/TerminalLogicalLineBlankIndexProbe.swift`,
  same env gate as `F1`'s, `F2`'s and `F3`'s; all three of those files are
  unedited.
- [x] `DONE` **`D3`, the five open `F6` hard cases and the wide-record
  fallback.** Recorded in [decisions.md](decisions.md); it **discharges inherited
  condition 5**, advances 1, 3, 9, 10 and 11, and disposes of the last of `F6`'s
  eight flagged sites, so **the design has settled and the graduation task's gate
  is met**. Seven decisions: (1) `HR1` -- the index maintains one **grand
  display-row total** and nothing else new, `scrollProjection` stays two-integer
  arithmetic, a planned frame performs **at most one** display-row-to-record
  locate, and `retained-browse` not-`slower` under its frozen rule is what judges
  it, with the diagnostic order fixed in advance. (2) `HR2` -- the stored anchor
  coordinate **stays the absolute display row**, because the alternative moves
  the conversion onto the admission path where `H3`'s falsifier lives; `X3`/`X4`
  still delete ~130 lines against ~40 returning as one restatement function, and
  `F5`'s invariant tally is amended from 5-versus-3.5 to **4.5-versus-4.5** in
  the open. (3) `HR3` -- **measured against the real engine**: severing under a
  non-default background-erase style stores and paints a styled blank (4 stored
  cells against the control's 3), and `clearPreviousSpacer` reaches the same cell
  through EL and DCH while leaving the record *open*, so `X9` was wrong too; both
  become a **tail append of at most one cell**, which reproduces today's output
  byte for byte and keeps the default-style case a genuine no-op. (4) a case
  discovered there -- the open tail record must end on a display-row boundary at
  the current width, re-established by `D2` operation 4's pull-back at a width
  change, so a resize leaves no short row mid-line. (5) `HR6` -- the materializing
  `ProjectionRows` facade **stays for milestone 1** (the frame path never touches
  it: `28/F17` already split borrow from materialize along the hot/cold line), and
  the borrowing cursor is milestone 2 under a frozen drag-move rule; `DD8` is
  re-read as `F6` asked. (6) `HR7` -- identity is a per-record run table keyed by
  **cell offset in the logical line**, `activationIdentity`'s `max` semantics are
  preserved exactly, and the shape reader is re-denominated per record, which is
  what dissolves its width-dependent contract. (7) inherited condition 1 -- the
  wide fallback is reframed and bracketed with existing numbers, and **its probe
  and three-way decision rule are frozen** for a follow-up to run mechanically.
  Three deferred decisions added (`DD16`-`DD18`).
- [x] `DONE` **Graduate: the design is in
  [`plans/impl/2026-08-04-1137-logical-line-scrollback-store.md`](../../../plans/impl/2026-08-04-1137-logical-line-scrollback-store.md).**
  Written 2026-08-04 under the `simplify-plan` admission test, so it carries the
  contract and cites this doc for everything else: eleven invariants, fourteen
  proof obligations (eleven when this entry was written; `PO11`-`PO14` were added
  by the plan's revise cycles), the two milestones `D3` named (milestone 1 the store with
  the materializing facade, milestone 2 the borrowing cursor under `D3`
  Decision 5's frozen 121 us drag-move rule), and the paired ladder as the
  acceptance criterion with the -2% / -7% conversions labelled as the hypotheses
  the ladder tests rather than outcomes to confirm. The still-open inherited
  conditions ride there as a "Gates carried from the research doc" section: **2**
  (eviction, owed before the ladder verdict is read), **1** (the wide-content
  counting probe, frozen in `D3` Decision 7), **4** (`28/D11`'s trial and the doc
  28 amendment it owes), **8** (the forced-split cap against a real pathological
  input), **9**'s remainder (spill / hyperlink / semantic-mark formats), and the
  `DD8` re-read `D3` requires against the landed implementation. What stayed
  here rather than moving: every rationale, alternative, measured number and
  disposition -- the plan cites `31/D2`, `31/F6-HR1` and the rest instead of
  restating them. Two graduation-time choices are recorded as `DD19`.

  - **DD19 -- one plan file covers both milestones, and the eviction measurement
    is sequenced before the ladder verdict is read.** The first is the obvious
    simple option: `D3` names two milestones of one design, and splitting them
    across two plan files would duplicate the invariants both share; a second
    file is one promotion away if milestone 2 grows. The second is an added
    constraint this doc did not state -- inherited condition 2 says eviction is
    unmeasured, not when to measure it -- and the plan puts it before the ladder
    because a real pane evicts on every admitted row, so a ladder verdict read
    with eviction unpriced would attribute a term nobody has looked at. Reopen
    either if the implementation's slicing wants it: neither is a design change.

    **Amended 2026-08-04 by the external design review: the first half is
    stale.** The plan's revise cycles moved milestone 2 out of it -- the Decision
    section scopes the borrowing cursor to a follow-up plan and the projection
    rewrite is a Non-goal -- so `DD19` reads: **one plan file covers milestone 1;
    milestone 2 is a follow-up plan, written after milestone 1 lands, with its
    priority rule already frozen (`D3` Decision 5's 121 us drag-move
    re-measure).** The second half is unchanged and still carried in the plan's
    Gates section.

- [x] `DONE` **Fold the external review of the deferred decisions and the plan.**
  An external review of `DD1`-`DD19` and
  [the plan](../../../plans/impl/2026-08-04-1137-logical-line-scrollback-store.md) was adjudicated
  by the human and folded in on 2026-08-04, **before the plan's first slice ran**,
  so the eviction rule that slice freezes is written against the corrected
  reading. Nine points, each verified against the tree or the doc before it was
  folded, each recorded as a marked amendment at the entry it corrects rather
  than as a rewrite. Three are substantive. (1) **`D2` Decision 1's residency
  claim covers charged bytes only** -- once the ring cursor cycles, resident is
  capacity plus metadata, which in the blank-record regime is 24 MiB against a
  16 MiB bound -- so the plan's `AR6` is promoted from an accepted risk to a gate
  sequenced with the eviction measurement, and sizing capacity below the budget
  is the remedy only if that reading shows the overshoot matters. (2) **`D2`
  Decision 2's step 2 loses a forced split's continuation**: dropping a whole
  record that carries `forcedSplit` leaves its follower reading as a fresh
  logical line, diverging from today's
  `isHistoryHeadTruncated = lastEvictedIsSoftWrapped` (`Terminal.swift:3999`);
  the step now propagates the continuation bit and clears the follower's mark,
  and the plan's `PO13` covers it. (3) **`DD14`'s pad has no mechanism for the
  growing open tail**, which is why `PO12` tested a case with no decision behind
  it; **`DD20`** decides it -- forced-split the open record at the arena's
  physical end and pad only the sub-row remainder -- with the cap-sized
  reservation recorded as the alternative it beats, because the reservation's
  charge would evict ~3.1% of history on one admitted row and that is `HR5`'s
  hazard again. Seven smaller ones: `DD19` restated above; `DD15` given its
  `max(1, ...)` fold floor, without which the 1,048,576-records-to-rows
  arithmetic breaks; `DD17`/`DD9`'s denomination tension named at `DD17` and in
  the plan's behavioral scope; step 4's stale `HR1` anchor cache noted at the
  step; this entry's "eleven proof obligations" corrected to fourteen; the plan's
  premise 5 restated as the cross-cutting-versus-local asymmetry rather than
  quoting the 4.5-versus-4.5 tie as a result (`DD8`'s re-read gate unchanged);
  and the plan's `AR1` corrected to the per-step complexity `D2` Decision 2
  actually specifies -- one display row per step, not a walk of the record.

### Phase 3 -- the implementation's gates (the plan owns the work; this doc owns the rules and the verdicts)

The plan's "Gates carried from the research doc" section is the authoritative
list of what implementation must discharge. What lands *here* is each gate's
frozen rule before its measurement runs, and each verdict after. No entry below
licenses a production storage change; landing is the paired ladder's.

- [x] `DONE` **`D4`, the eviction comparison's frozen rule** (`D1` condition 2,
  the largest unmeasured term in the campaign). Recorded in
  [decisions.md](decisions.md), frozen at `de17e95` before the probe exists and
  before any eviction or residency number does. Three arms, named as real code:
  today's `Terminal.swift#enforceScrollbackBudget` / `#removeFirst` /
  `#handleEviction`, the arena head-trim as `D2` Decision 2 specifies it, and --
  descriptive only -- whole-record eviction on the same arena, which is the only
  thing that could attribute a reject to granularity rather than to the arena.
  Two verdict-bearing statistics (the write path per admitted row at steady
  state; eviction alone per evicted display row), five stimulus classes with
  every calibration band cited, eight validity gates, and **1.09x** as the reject
  line -- `F3`'s own derivation (`28/F20`'s 19.7% x the 95.7% drain share, against
  `scrollback-stream`'s frozen 1.85%) applied to the other half of the same
  subtree. The rule is written against the **corrected** per-step complexity (one
  display row per trim step from the persisted head cell offset, not a record
  walk), and gate 7 holds the implementation to it rather than assuming it. The
  `AR6` residency reading rides the same entry: four states (empty, partial,
  saturated, cycled) through `just terminal-memory-probe --vmmap`, with
  capacity-below-budget as the remedy only above a derived 1.10x / 1.50x band.
  Two deferred decisions added (`DD21`, `DD22`).
- [x] `DONE` **`F8`, the eviction measurement and the residency reading** (`D1`
  condition 2 and `AR6`). Recorded in [F8](findings.md); `D4` was frozen at
  `2ac87e1` before the probe existed and was run mechanically (the plan's slice
  4). **Both verdicts are `reject`, and they are the only rejects in this doc.**
  Eviction: the landed store's whole write path costs **1.418x-3.177x** today's
  per admitted display row and its eviction alone **1.830x-3.114x** per evicted
  display row, on all four verdict-bearing classes, against a 1.09x reject line.
  Residency: an arena pane is **16.281 MiB resident when empty** (so `DD12`'s
  "an idle pane's reservation costs nothing" is **refuted** -- the reservation is
  dirty from construction, not on first touch) and **20.375 MiB cycled on
  `scrollback-mixed`** against today's 18.219 MiB for the same fed input, which
  is **1.118x** and fires the second reject trigger. **The design is not what
  rejects**: gate 7 confirms `D2` Decision 2's per-step complexity at **1.000x**
  (one display row per trim step, flat across a record's drain), gate 1 confirms
  `I1`/`I6` cell for cell on five classes, the depth table confirms `PO11` at
  **1.076x-1.301x** today's retained rows, and the descriptive attribution arm
  re-measured `F3`'s own prototype at **0.52x-0.64x** of today's admission in the
  same session while the landed store cost **3.01x-4.31x the prototype** -- so
  the eviction reject is the store's per-byte arena access, not wrap-at-read.
  Disposition of both rejects is a human's; the residency remedy `D4` names
  (capacity sized below the budget) costs **3.23%-15.29%** of depth measured,
  against the 1.61% `D4` derived. Four deferred decisions added (`DD29`-`DD32`).
- [x] `DONE` **`F10`, the re-price after the optimization** (`D4` re-run
  unchanged, the plan's inserted slices 4a and 4b). Recorded in
  [F10](findings.md). The human took `F8`'s "optimize, then re-price" route; the
  store's write path was changed and `D4`'s residency remedy shipped, then the
  **same probe file, arms, stimuli, gates and thresholds** were run again with
  nothing in `D4` edited. **Both of `F8`'s rejects are cleared.** Eviction reads
  **neutral**: the write path is **0.856x-1.023x** today's per admitted display
  row and eviction alone **0.151x-1.022x** per evicted display row on all four
  verdict-bearing classes, so `D4`'s named condition is discharged by its first
  clause rather than deferred to the ladder. Residency reads **narrow confirm**:
  a cycled arena pane is **15.359 MiB** on `plain` and **18.234 MiB** on `mixed`
  against today's 18.094 and 18.281 for the same fed inputs -- **0.849x** and
  **0.997x**, where the reject trigger was 1.10x. What the run also found is a
  **real fold defect** gate 1 caught: a `.spacerHead` dropped at a forced-split
  seam could not be re-derived, so one retained display row in 14,486 read back
  178 cells where today's store holds 179; it predates both measurements and is
  fixed. `PO11` still holds on every class but its margin on `full` is down to
  **0.9%**, which is `DD36`'s reserve paid in the open, and **gate 7 is now
  unreadable** -- the trim step it times fell below the probe's 41.7 ns clock, so
  it is recorded as *not measured* rather than as a pass (`DD38`). Three deferred
  decisions added (`DD36`-`DD38`); `I2`'s restatement is still the human's to
  ratify.
- [x] `DONE` **`F9`, the wide-content counting pass** (`D1` condition 1).
  Recorded in [F9](findings.md); `D3` Decision 7's probe and three-way rule were
  frozen before it existed and were run mechanically (the plan's slice 2). It
  numbers `F9` rather than `F8` because `D4` had already reserved `F8` for the
  eviction measurement. Verdict: **narrow confirm**. On the deepest wide history
  16 MiB admits (7,531 CJK records, 2,082,012 cells) the pass costs **0.056-0.144
  ms** at widths 200, 179 and 100 and **5.439 ms** at `179 -> 2`, the engine
  minimum -- above the 1.67 ms tenth-of-a-frame line and **3.07x inside** the
  16.67 ms reject line. The eager recompute stands, **neither mitigation ships**
  (the per-record cached count and the lazy per-block recompute both stay
  unbuilt, so the Rejected entry for lazy recompute is not spent), and the
  recorded depth condition is the (`wide`, `179 -> 2`) cell. The fallback measures
  `O(display rows)` at **5.2-5.4 ns a row**, flat from 2 to 4,096 cells per
  record, which puts one frame at ~3.1-3.2M display rows against the 1.05M the
  budget admits
  -- `D3` Decision 7's own arithmetic bracket said 3.2x before the constant
  existed. Two deferred decisions added (`DD23`, `DD24`).
- [x] `DONE` **`28/D11`'s exit, recorded against the new store's resize
  measurement** (`D1` condition 4, the plan's slice 6). The amendment `D2`
  Decision 4 demands is written, in **doc 28** where the trial lives:
  [`28/D11`'s "Amendment 2026-08-04 -- exit 4"](../28-retained-row-optimizations/decisions.md).
  The human's verdict was **exit 1** (keep the caps, the ~600 ms hitch is
  livable) and it is recorded as **still unratified** when the store deleted the
  cost it accepted, so the entry claims the question lost its subject rather than
  that the trial answered it. The measurement is the committed frozen probe
  `saturated-wide-resize-v1` -- `28/F23`'s own calibration harness, and the
  trial's exact shape (179-column lines at 179x66 <-> 100, budget-saturated) --
  run unmodified at both revisions, under a rule frozen before either number was
  read: *the cause is removed iff, at a depth not below the before arm's, median
  and maximum both fall under `28/D8`'s ~150 ms budget*. Read: **576.19 ms at
  9,860 retained rows** (`de17e95`) -> **1.58 ms at 10,735** (`9ad7cc5`), max
  2.75 ms, so depth is 1.089x and cost is 0.011x `D8`'s budget against the
  trial's 3.84x. The before arm reproduces `28/F23` candidate (b)'s 600.5 ms
  within 4.1%, which is what makes it the trial's number and not a new one. Both
  caps are deleted with no analogue; the 16 MiB budget survives on `D2`
  Decision 1's derivation. **Not a verdict on the store** -- one recipe, one arm
  per revision, no pairing, no calibration gate. One deferred decision added
  (`DD48`).
- [ ] `TODO` **The paired ladder verdict and the `DD8` re-read.** The acceptance
  dimension, owed against a real implementation.

## Rejected

### Port iTerm2's LineBuffer

Rejected by standing rule, recorded so it is not re-litigated: iTerm2 is the
existence proof that read-time wrapping ships in a mainstream macOS terminal,
and its edge cases fed F4 -- but its block-object structure encodes
Objective-C history, not DanTerm's constraints. Individual mechanisms may be
adopted only with a DanTerm-specific justification in a D entry. **F4 adopted
one and rejected one**, both on DanTerm's own constraints: the fast/slow split
for display-row counting is taken (it is intrinsic to the content, not to
iTerm2's structure), while iTerm2's sticky *buffer-wide*
`mayHaveDoubleWidthCharacter` flag is rejected in favour of a per-record bit,
because the buffer-wide version is what forces iTerm2's three further layers of
memoization (`F4` `DD4`). F4 also found that iTerm2 has **no LineBuffer unit
tests** in the pinned tree, so this doc's "test-hardened" framing of it was
wrong: its edge cases are readable from production code, not from a suite.

### Hybrid mixed-width history (28/H7)

The incremental alternative: reflow viewport-adjacent rows synchronously,
tag the rest by width, rewrap on demand or in the background. Set aside by
explicit human choice in favor of this doc's rethink, because the hybrid's
transient mixed-width state *adds* invariants (every reader must handle two
widths) where this design *deletes* them (no reader ever sees a width in
storage). **D1 answered `go` on 2026-08-04, so this stays rejected and its
reopening condition changes**: it is no longer "if D1 answers no-go" but a
`slower` verdict on the paired ladder against a real implementation. It remains
the fallback that needs no storage rewrite.

### Lazy per-block index recompute (for milestone 1)

Recompute a block's display-row total only when a lookup first touches it
after a width change. Deferred, not refuted: the human chose eager for the
first milestone because it is simpler and F2's expectation is that the whole
pass costs milliseconds. Reopen if F2 measures the eager pass above H2's
bound. **F2 measured it 15.6x inside the bound, so this stays rejected**, and
the reopening condition is now a depth rather than a doubt: an arena past
~100,000 logical lines, which the byte budget does not currently allow.
**`F9` closes the second route back in**: the plan carried this as the mitigation
a wide-content reject would ship, and the wide probe returned narrow confirm at
~3x inside its reject line, so nothing is spent and this stays rejected on both
counts.

## Open questions and caveats

The authoritative list of what Phase 2 inherits is the "Conditions and unpriced
terms Phase 2 inherits" section of the `D1` closure in
[decisions.md](decisions.md); the entries below are the ones that predate it or
add detail to it.

- ~~What does search operate on -- a straight scan of the arena's packed cells,
  or does it need its own index?~~ **Answered by `F6` (`R10`): no separate index
  is implied by any call site.** `Terminal.swift#searchMatches` already runs a
  needle window over `projectionUnits()`, i.e. over a flat unit stream, and
  under the new store the same window runs over records with the wrap boundaries
  gone -- so search gets simpler, as expected. `F4` case 20 and
  `wideGraphemeSearchRangeSpansSoftWrap` were the supporting evidence and remain
  it. What is still unpriced is the *cost*: `19/F9`'s occupancy probe measures
  search against today's store and nothing has re-measured it against an arena.
- ~~**The eight sites `F6` flagged are the design risks Phase 2 must close.**~~
  **All eight are closed: `HR4`, `HR5` and `X13` by `D2`, and `HR1`, `HR2`,
  `HR3`, `HR6`, `HR7` and `HR8` by `D3`.** The status table is in `F6`
  Observation 2 and each disposition is in the decision that took it. Two things
  the closures change rather than merely settle: `HR3` was measured against the
  real engine and turned out to have a **second** reachable site (`X9`, which
  `F6` had mapped as a no-op), and `HR2`'s answer costs `F5`'s invariant tally
  half a point, which `DD8`'s amendment records instead of absorbing.
- ~~**The eager counting pass is unpriced on wide content.**~~ **Answered by
  `F9`, narrow confirm: 5.439 ms at `179 -> 2` on the deepest wide history 16 MiB
  admits, 3.07x inside the 16.67 ms reject line and above the 1.67 ms
  tenth-of-a-frame line, so the eager pass stands and neither mitigation ships.**
  `F2` had measured 0.016 ms at trial depth on ASCII stimuli, where every record
  takes the O(1) `ceil` path, and `F4` Observation 1 established that a record
  holding wide cells needs a boundary walk instead. `D3` Decision 7 reframed that
  walk as `O(display rows)` rather than `O(cells)` -- one probe per display row,
  which is iTerm2's own loop as `F4` quoted it -- and bracketed it at ~5 ms on a
  pessimistic 5 ns per probe against the 16.67 ms frame, then froze the probe
  rather than spend a margin it had computed itself. **The bracket was right in
  shape and in constant**: measured 5.2-5.4 ns per display row, flat from 2 to
  4,096 cells per record, putting one frame at ~3.1-3.2M display rows against the
  1.05M the budget admits. What the answer leaves standing is a **depth condition**, not an
  open question: a resize to the engine's minimum width with a budget-full CJK
  history spends about a third of a frame in the counting pass.
- ~~**Eviction is unpriced on both sides, and it is now the largest unmeasured
  term in Phase 1's evidence.**~~ **Answered by `F8`, and the answer is
  `reject`: the landed store's write path costs 1.418x-3.177x today's per
  admitted display row and its eviction alone 1.830x-3.114x per evicted display
  row, against a 1.09x line.** What the same finding says in the other
  direction is why this is not a verdict on the design: gate 7 confirms `D2`
  Decision 2's per-step complexity at 1.000x, and `F3`'s own prototype of the
  open-line rule re-measured at 0.52x-0.64x of today's admission in the same
  session while `LogicalLineStore.admit` cost 3.01x-4.31x that prototype. The
  reject is the landed store's per-byte arena access. Disposition is a human's,
  and the named condition `D4` attaches is the plan's now. The historical
  framing follows. `F1` set it aside as Phase 2's, `F3`'s frozen
  rule excluded it, so nothing has compared today's
  `Terminal.swift#enforceScrollbackBudget` / `ScrollbackBuffer.removeFirst`
  against `DD2`'s whole-record eviction. A real pane at steady state evicts on
  every admitted row, so F3's admission win is measured on the half of the write
  path that was easy to isolate. Descriptively, `F3` Observation 4 found the
  arena holds the same content in **0.744x-0.925x** of the bytes the budget
  charges today, which is the input the budget-and-eviction task needs.
  **`D2` has since spent that input and specified the mechanism** -- eviction is
  byte-driven, display-row granular at the head, and copies nothing -- so what
  remains owed is the measurement itself, against today's
  `enforceScrollbackBudget` / `removeFirst`, under a rule frozen before the
  comparison is read. The head-trim's per-step fold walk is the new term such a
  probe has to see. **`D4` is that rule, frozen 2026-08-04 at `de17e95`**: arms,
  five stimulus classes, eight gates, a 1.09x reject line derived the way `F3`
  derived its own, and the honest bar for `AR1`'s whole-record fallback -- which
  would reintroduce `F6` `HR5`, so a reject alone does not authorize it. Only the
  number is still owed.
- ~~**Resident pages are unmeasured, and `I2` does not bound them.**~~
  **Answered by `F8`, and the answer is `reject` on the second trigger:** an
  arena pane is 16.281 MiB resident *when empty* -- the reservation is dirty
  from construction, so `DD12`'s "costs nothing" is refuted and first-touch
  never applied at any state -- and 20.375 MiB cycled on `scrollback-mixed`
  against today's 18.219 MiB for the same fed input, which is 1.118x and over
  the 1.10x line. The remedy `D4` names ships (capacity sized below the budget),
  and its measured depth cost is 3.23% on `plain` and 15.29% on `mixed` rather
  than the 1.61% `D4` derived, because the side tables that derivation left as an
  unmeasured constant are 3.7x the index on `mixed`. The historical framing
  follows. The external
  review of `D2` Decision 1 found the entry's residency claim true of *charged*
  bytes and overstated for resident ones: once the ring's write cursor has
  cycled, every arena page has been touched, so resident is capacity plus
  metadata -- 24 MiB against a 16 MiB charged bound in the blank-record regime.
  `PO3`'s census cannot see it, which is why the plan carries it as a gate rather
  than as an accepted risk. **`D4` freezes its reading too**: four pane states
  through `just terminal-memory-probe --vmmap`, today's store as a same-session
  control at the same fed inputs, and sizing the arena's capacity below the
  budget as the remedy only if the cycled-state reading crosses the derived band.
- ~~**The eager counting pass is also unpriced at the record counts the budget
  now admits.**~~ **Answered by `F7`: the pass costs 0.761 ms at 1,048,576
  zero-cell records, 21.9x inside the 16.67 ms bound `D2` froze, so no
  record-count bound ships and `D2` Decision 1's one charged-byte bound stands.**
  The ~6.4 ms extrapolation was 8.4x pessimistic because the per-record cost is
  flat with depth and governed by **stride** instead -- which is the reading that
  now carries forward to the *wide-content* re-measure this list already owes
  (inherited condition 1): vary bytes per record, not record count. `DD15` (a blank logical line is a
  zero-cell record; today's one-cell canonical floor is `PackedRetainedRow`'s,
  not the arena's) is the one new deferred decision, and the alternative it
  declines admits fewer records, so `F7`'s figure bounds it from above.
- The forced-split cap is **65,536 cells, derived** in `F4` Observation 3 as
  1/32 of the byte budget rather than chosen, and **ratified by `D2`** now that
  the budget it divides has its own derivation. Still unpriced: what a real
  pathological input (`cat` of a binary, minified JSON) actually produces --
  the derivation bounds the hazard without saying how often it is reached.
- `28/H8` (deferred packing) shares the amortized-background-work idea; a
  logical line is a natural compression unit if H8 is ever funded on top of
  this store. Noted as synergy, not a dependency in either direction.
- ~~The `28/D11` trial verdict (human: keep the caps, hitch is livable) is
  recorded in conversation but not yet as a doc 28 decision amendment.~~
  **Discharged 2026-08-04**: `28/D11` carries the amendment, closing on exit 4
  (*the cause is removed*) with the exit-1 verdict recorded and recorded as
  unratified, and with the resize re-measured on the trial's own recipe at
  **576.19 ms / 9,860 rows -> 1.58 ms / 10,735 rows**. `D2` Decision 4's status
  line and the Phase 3 ledger carry the full reading. What the amendment
  deliberately left open, and this doc does not own: `28/D8`'s ~150 ms resize
  budget is not formally superseded, because resize cost stopped being a
  function of history depth and a successor budget wants deriving against the
  live screen rather than inherited.

## Outcome

Investigation in progress. Phase 1 is complete: `D1` closed **`go`** on
2026-08-04 on five inputs -- `F1` (read path 1.64x faster), `F2` (the eager
counting pass 15.6x inside its bound), `F3` (admission 1.45x-1.60x cheaper),
`F4` (28 edge cases, zero requiring stored width) and `F5` (the simplification
inequality holds on invariants) -- with no frozen threshold failed by any of
them. The verdict licenses Phase 2's **design** work only: no production storage
change is licensed, and the paired ladder against a real implementation is the
acceptance dimension still outstanding.

Phase 2 is complete and had four inputs: `F6` (the call-site enumeration), `D2`
(budget and eviction semantics -- one charged-byte bound at the same 16 MiB,
head-granular eviction, no user-facing knob), `F7` (the counting pass at the
record count that budget admits: 0.761 ms against a 16.67 ms bound, so `D2`
ships one bound rather than two) and `D3` (the five remaining `F6` hard cases
and the wide-record fallback). **With `D3` the design settled** -- all eight of
`F6`'s flagged sites disposed of, the four decisions `F6` handed forward made --
and it **graduated on 2026-08-04 into
[`plans/impl/2026-08-04-1137-logical-line-scrollback-store.md`](../../../plans/impl/2026-08-04-1137-logical-line-scrollback-store.md)**,
which closes Phase 2. No decision in Phase 2 was blocked on a measurement, and
both measurements still owed have their mechanisms specified and change no
decision on either outcome: **eviction** remains the largest unmeasured term on
both sides, and the **wide-content counting pass** has a frozen probe and
decision rule. Both ride the plan as gates, alongside `28/D11`'s live trial, the
forced-split cap's missing pathological input, and the record format's remaining
side tables.

Phase 3 has opened, and it is rules and verdicts rather than design. `D4`
(2026-08-04) freezes the eviction comparison's decision rule -- three arms named
as real code, five calibrated stimulus classes, eight validity gates, a 1.09x
reject line derived from `28/F20`'s measured share, and the `AR6` residency
reading sequenced into the same slice -- **before any eviction or residency
number exists**, and against the corrected per-step complexity (one display row
per trim step, not a record walk). It licenses nothing: `F8` is the measurement
it governs.

**`F8` ran it, and both of its rules read `reject`** -- the first rejects in this
doc. The eviction comparison puts the landed store's write path at 1.418x-3.177x
today's and its eviction alone at 1.830x-3.114x, against a 1.09x line; the
residency reading puts an *empty* arena pane at 16.281 MiB and a cycled
`scrollback-mixed` pane at 1.118x today's resident for the same fed input. Both
dispositions are a human's and `D4` said so before either number existed. What
the same finding establishes in the design's favour is not small: gate 7
confirms the per-step complexity at 1.000x, gate 1 confirms `I1`/`I6` cell for
cell on five content classes, the depth table confirms `PO11` at 1.076x-1.301x,
and the attribution arm re-measured `F3`'s prototype of the same admission rule
at 0.52x-0.64x of today's cost in the same session while the landed store cost
3.01x-4.31x that prototype. The store as landed is what rejects, and it rejects
on how it touches its own bytes.

**`F10` re-ran the same rule after the human took the "optimize, then re-price"
route, and both rejects are cleared.** Nothing in `D4` was edited: same probe
file, same three arms, same five stimulus classes, same eight gates, same 1.09x
and 1.10x lines. The write path is now **0.856x-1.023x** today's per admitted
display row and eviction alone **0.151x-1.022x** per evicted display row --
**neutral**, with two cells above 1.00x by more than the instrument's resolution
and none within reach of 1.09x -- and a cycled arena pane is **0.849x** today's
resident on `scrollback-plain` and **0.997x** on `scrollback-mixed`, which is
**narrow confirm**. `D4`'s named condition is discharged by its first clause, on
its own rule. Two things the re-run adds that the numbers do not: gate 1 caught a
**real fold defect** -- a spacer dropped at a forced-split seam that no reader
could re-derive, one display row in 14,486, predating both measurements and now
fixed -- and gate 7 became **unreadable**, because the step it times fell below
the probe's clock. Landing is still the paired ladder's, and `I2`'s restatement
is still the human's to ratify.

**`28/D11` is no longer a live trial.** The store landed (`9ad7cc5`) and deleted
both caps, so `D2` Decision 4's obligation came due: doc 28 now carries the
amendment, closing the trial on the fourth exit *the cause is removed*, with the
human's exit-1 verdict recorded and recorded as **unratified** at the moment the
cost it accepted stopped existing. The measurement behind it is the trial's own
committed recipe run at both revisions -- **576.19 ms at 9,860 retained rows ->
1.58 ms at 10,735**, greater depth at 0.011x `28/D8`'s ~150 ms budget instead of
3.84x. That discharges `D1` condition 4 and removes the last gate that could
have been retired by side effect rather than on the record. It settles nothing
about whether the store ships.

What this doc still owns after graduation is the verdict, not the work. `D1`'s
scoping stands: no production storage change is licensed by any entry here, and
the acceptance dimension outstanding is not a design question but the **paired
ladder against a real implementation** -- `retained-browse` as the go/no-go,
`terminal-feed` and `scrollback-stream` carrying `H3`'s falsifier, under rules
frozen before the comparisons are read. The -2% and -7% frame figures stay
predictions through measured shares, and the plan states them as the hypotheses
the ladder tests. A `slower` `retained-browse` verdict with `D3` Decision 1's two
diagnostics holding is what reopens `28/H7`.
