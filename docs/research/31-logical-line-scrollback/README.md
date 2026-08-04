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
  Observation 1): a record whose `hasWideCells` header bit is set costs an
  O(cells) scan because a 2-cell cluster meeting a one-column gap starts the
  next row instead of splitting. The bit is a content property, not a width.
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

### Phase 2 -- design (open: D1 answered go on 2026-08-04)

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
  (`DD12`-`DD14`) and one open question that needs a measurement: the blank-line
  regime admits 1,048,576 records, 10.5x anything `F2` measured, with the
  probe and its decision rule frozen in the entry.
- [ ] `TODO` Graduate: when the design settles, extract it into a plan file
  (the `simplify-plan` admission test applies) and record here where it went.

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
- **The eight sites `F6` flagged are the design risks Phase 2 must close**, and
  four of them are decisions rather than edits: `HR1` (per-frame `topRow`
  re-derivation, which lands on `retained-browse`), `HR2` (the anchor coordinate
  space across the history/live seam, which gates ~130 lines of deletion), `HR4`
  (`resizeHeight`'s pull-back from history, a fourth tail mutation and the only
  operation that shrinks the arena from the back), `HR6` (`ProjectionRows` must
  stop materializing a row per display row). `HR3` and `HR5` are user-visible
  behavior changes; `HR7` makes inherited condition 9 concrete; `HR8` adds a
  grand display-row total to what the block index must maintain.
- **The eager counting pass is unpriced on wide content.** `F2` measured
  0.016 ms at trial depth on ASCII stimuli, where every record takes the O(1)
  `ceil` path. `F4` Observation 1 establishes that a record holding wide cells
  needs an O(cells) scan instead, so a CJK- or emoji-heavy history makes the
  pass a walk of the flagged records' bytes. `H2` cleared its bound by 15.6x,
  so there is margin -- but the margin is not measured against a wide-content
  stimulus and must not be assumed to transfer. Re-running `F2`'s probe with a
  wide stimulus is the cheapest way to close this, and it is Phase 2's.
- **Eviction is unpriced on both sides, and it is now the largest unmeasured
  term in Phase 1's evidence.** `F1` set it aside as Phase 2's, `F3`'s frozen
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
  probe has to see.
- **The eager counting pass is also unpriced at the record counts the budget now
  admits.** `D2` Decision 1 charges the index per record, which bounds a
  blank-line history at **1,048,576 records** at 16 MiB -- 10.5x the deepest
  `F2` measured. Extrapolating `F2`'s per-line rate puts the pass at ~6.4 ms
  against its own one-frame reject bound, which is arithmetic and not a
  measurement. `D2`'s open-question section names the probe and freezes the
  decision rule; the fallback if it fails is an internal record-count bound.
- The forced-split cap is **65,536 cells, derived** in `F4` Observation 3 as
  1/32 of the byte budget rather than chosen, and **ratified by `D2`** now that
  the budget it divides has its own derivation. Still unpriced: what a real
  pathological input (`cat` of a binary, minified JSON) actually produces --
  the derivation bounds the hazard without saying how often it is reached.
- `28/H8` (deferred packing) shares the amortized-background-work idea; a
  logical line is a natural compression unit if H8 is ever funded on top of
  this store. Noted as synergy, not a dependency in either direction.
- The `28/D11` trial verdict (human: keep the caps, hitch is livable) is
  recorded in conversation but not yet as a doc 28 decision amendment; this
  doc does not depend on which exit D11 records, since it removes the
  machinery all three exits negotiate with. **`D2` Decision 4 states the
  migration's side of it**: the two caps are deleted with no analogue, the
  budget survives at the same number on a new derivation, the trial keeps
  running until doc 28 records an exit, and the migration creates a fourth exit
  -- *the cause is removed* -- that doc 28 owes an amendment for. Landing this
  store without that amendment retires a live trial by side effect.

## Outcome

Investigation in progress. Phase 1 is complete: `D1` closed **`go`** on
2026-08-04 on five inputs -- `F1` (read path 1.64x faster), `F2` (the eager
counting pass 15.6x inside its bound), `F3` (admission 1.45x-1.60x cheaper),
`F4` (28 edge cases, zero requiring stored width) and `F5` (the simplification
inequality holds on invariants) -- with no frozen threshold failed by any of
them. The verdict licenses Phase 2's **design** work only: no production storage
change is licensed, and the paired ladder against a real implementation is the
acceptance dimension still outstanding.
