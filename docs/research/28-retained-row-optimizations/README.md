# Retained-row optimization opportunities

Research started: 2026-08-01.
Continues: [15-memory-footprint.md](../15-memory-footprint.md) (`15/H6`,
`15/H7`, `15/F18`).

- [findings.md](findings.md) -- the append-only evidence chain.
- [decisions.md](decisions.md) -- the auditable decision log.

## Purpose

This doc owns **the follow-on performance opportunities opened by compact
retained-row storage** -- the representation shipped in
`plans/impl/2026-08-01-1803-compact-retained-scrollback-rows.md` (seam
`fa01b66`, trim `dd51a12`, validation `54d4d2d`). Retained rows now store only
their content prefix in canonical form; the blank tail is virtual, depth
follows content rather than pane width, and the budget charge is coherent
under seam mutation. Several optimizations that were incoherent against
full-width mutable rows are newly cheap or newly attackable against canonical
content-sized rows. This doc enumerates them, sizes them against fresh
evidence, and graduates any winner to a plan.

It also owns the measurement residue the shipped change left behind: `15/F18`
never resolved the feed-path CPU verdict, and the browsing-render measurement
was a one-off probe that no routine workload can reproduce.

| Question | Owned by |
| --- | --- |
| What the process held before compact rows, and the shipped compaction | doc 15 (**closed**) |
| Live-grid cell layout (`GridCell` stride, alignment) | doc 16 (**closed**, rejected) |
| Renderer bracket leads | doc 18 (live) |
| **What compact retained rows make possible next** | **this file** |

## Investigation rules

- **Evidence floor: `dd51a12`.** Every number used in a verdict is measured at
  or after the trim commit, on current HEAD. Pre-trim measurements across docs
  9-17 are historical orientation and technique input only -- the
  representation, the cell (32 bytes since `15/F15`), and the row population
  (`15/F18`: 5,799 plain rows at saturation, up from ~1,700) have all changed
  under them. `15/F18` is the only inherited baseline; anything it did not
  measure gets measured fresh here.
- **Performance claims follow
  [agent-docs/terminal-performance.md](../../../agent-docs/terminal-performance.md)**:
  name the benchmark, commit, and compatibility conditions; profiled or probe
  timings are diagnostic, never benchmark verdicts, until a frozen decision
  rule exists.
- **The shipped invariants are the boundary, not an obstacle course.** Any
  candidate must preserve canonical trimmed form (stored cells are a pure
  function of observable content), budget-charge coherence, and the
  observability contract (reads at every column below `columnCount` answer as
  before). The landed behavioral suite is the gate. A candidate that needs to
  relax canonicality -- e.g. lazy trimming to reclaim feed-path allocation --
  is a plan-level decision to reopen, not a research-side hack.
- **Any byte change is a depth change.** The budget is denominated in bytes,
  so a representation change silently changes retained depth at the same
  nominal budget. Every proposal states its depth effect and decides it
  deliberately (carried forward from doc 12/15 as a rule, not a number).
- **A representation change is a CPU claim as much as a memory claim.** State
  and measure the effect on the feed path (admission) and the browsing render
  path (presentation) for every candidate.
- **References supply techniques, never numbers.** kitty's `PagerHistoryBuf`
  (`references/kitty/kitty/history.h#PagerHistoryBuf`) and similar prior art
  are mined for shape and edge cases; every cost and benefit is measured in
  DanTerm.
- **Pre-adjudicated boundaries stay closed here.** Doc 16 closed live-grid
  `GridCell` layout changes. The shipped plan's rejected ideas (charge content
  while storing full width; content-width field beside a full array; inflate
  on read) stay rejected. Doc 27's adoption bar governs any swift-collections
  container this doc is tempted by.

## Trigger and current evidence

The compact retained-row representation landed 2026-08-01 and `15/F18`
validated it: plain retained history is **3.41x deeper at 179 columns and
1.71x deeper at 80 columns** at the same 10 MiB budget, candidate depth
converges across pane widths (content now dominates the charge), the browsing
frame plan measured **-5.79% symmetric median** in a 16-pair probe, and a live
widen kept the head of history byte-identical.

Three facts in that finding are this doc's starting evidence:

1. **Per-row fixed overhead is now a first-class cost.** At saturation the
   candidate holds 2,404-4,097 *more* row arrays than before; their
   `GridRow` strides, array headers, and allocator buckets raised attributable
   footprint by +2.51 MB at 179 columns (+21.8%) and +0.44 MB at 80. Compact
   rows converted the dominant cost from blank cells to per-row overhead --
   which is `15/H7`'s territory, quantified fresh by `15/F18`.
2. **The feed-path CPU verdict is unresolved.** `benchmark-quick` was
   inconclusive (+1.13% symmetric median); the escalated `benchmark-confirm`
   run produced no usable evidence because `scrollback-stream` arm A returned
   empty stdout instead of JSON. No neutrality claim exists for admission-time
   trimming (the shipped plan's `AR2`).
3. **The browsing measurement is unreproducible by routine tooling.** No
   paired workload displays retained history -- `scrollback-stream` follows
   the bottom and the draw workloads start from live grids. `15/F18`'s result
   came from a temporary probe that was deleted after measurement.

## Current hypotheses

### H1 -- deep-history resize is now proportionally cheaper, and nobody has measured it

Reflow unpacks and repacks every retained row on a width change. Both sides of
that operation now touch the content prefix instead of `columnCount` cells per
row, so a saturated-history resize should move roughly a content-to-width
ratio less data -- while also processing ~2-3x more rows at the same budget,
which cuts against it. Net direction is genuinely unknown. Window-drag latency
on a deep pane is user-visible and composes with the shipped resize
coalescing. Confirm or reject with a paired before/after-style probe at HEAD
(there is no pre-trim arm to compare against and the rules forbid wanting one;
the measurement is absolute: does saturated resize fit comfortably in a frame
budget, and where does its time go).

### H2 -- canonical blank rows can share one storage allocation

Canonical form means every fully blank retained row stores identical content
(one blank cell). Swift arrays are COW, so all blank rows could share a single
storage buffer: a screenful of blank lines costs one allocation total. Two
open mechanics questions decide viability: the budget charges per-row
`capacity`, so shared storage needs a deliberate charge-model answer (charging
each row for shared bytes overstates; charging once complicates eviction
accounting), and the share must survive the seam (a write into a shared blank
row must CoW-detach without corrupting siblings -- the existing suite should
prove this for free). Reject if blank rows are a negligible fraction of real
histories (measure first).

### H3 -- retained rows can be packed tighter than `[GridCell]` (15/H6 proper)

The shipped change stores fewer cells; `15/H6` proposes storing them
*smaller*: retained rows are immutable-in-practice, so a packed form (packed
scalars plus run-length styles, or similar) does not need the live grid's
32-byte random-write cell. This is the deferred remainder of `15/H6`, and the
shipped seam -- readers already tolerate storage narrower than the logical row
-- is most of the machinery it needed. Doc 16's constraint stands: the live
grid's `GridCell` is untouched. Gate on Phase 2 evidence: only worth designing
if stored cell bytes, not per-row overhead, dominate the remaining footprint.

### H4 -- per-row overhead wants fewer, larger allocations (15/H7 on new evidence)

The counterpart gate to H3. `15/F18` measured the overhead side growing
(+2.51 MB attributable at 179 columns) precisely because compact rows multiply
row count at a fixed budget. `15/H7`'s narrow form -- aggregate storage for
immutable retained rows only, no manual memory control -- composes with H3 and
attacks the bytes H3 cannot. Whichever of H3/H4 Phase 2 shows is larger gets
designed first; they may graduate as one plan (that is doc 15's own Phase-3
gate logic, reapplied to post-trim numbers).

### H5 -- ancient history can demote to a compressed tier

kitty's `PagerHistoryBuf` precedent: recent history stays cell-backed for
interaction; history older than some horizon demotes to packed text that
re-inflates on browse. Strictly more mechanism than H3/H4 for the same bytes,
so it is live only if Phase 2 shows deep-history footprint still matters after
the cheaper hypotheses land or are rejected. The canonical representation
makes the demotion boundary well-defined (stored content is already exactly
the observable content).

### H6 -- canonical rows make scrollback persistence cheap enough to be a feature

Storage is now a pure function of observable content: content-sized and
deterministic across runs, which is exactly what a save/restore codec wants
(and aligns with the SAVED/SENT/ASSERTED injection rule). This is a product
question before it is a performance question -- the recovery store snapshots
the model, not terminal content, today. Parked until session-restore of
terminal content is a live feature goal; recorded here so the sizing argument
is not lost.

## Task ledger

### Phase 1 -- close the shipped change's measurement residue

- [ ] `RESEARCH` Resolve the feed-path verdict at HEAD: rerun
  `benchmark-quick` on `terminal-feed` against the pre-trim baseline arm per
  the frozen protocol, escalate to `benchmark-confirm` if inconclusive, and
  record the verdict in `F1`. Diagnose the `scrollback-stream` empty-stdout
  confirm failure first if it recurs (tooling; its own finding if nontrivial).
- [ ] `TODO` Decide whether retained-history browsing becomes a routine paired
  workload. `15/F18`'s probe was deleted; every hypothesis here will need the
  measurement again. Destination: `D1` (add a workload, or freeze a documented
  probe recipe).

### Phase 2 -- size the remaining costs at HEAD

- [ ] `TODO` Split saturated attributable footprint into stored cell bytes vs
  per-row fixed overhead (headers, `GridRow` strides, bucket slack) at both
  179 and 80 columns, using the census plus probe arithmetic. This is the
  H3-vs-H4 gate input. Destination: `F2`.
- [ ] `TODO` Measure blank-row frequency in realistic histories (shell
  sessions, build logs, TUI dumps -- the existing benchmark corpora) to size
  H2's ceiling. Destination: `F3`.
- [ ] `TODO` Check allocator behavior under ragged row sizes: do
  content-length-distributed allocations fragment size classes measurably, or
  does malloc absorb them? (`15/F7`'s bucket analysis is technique precedent;
  numbers measured fresh.) Destination: `F4`.
- [ ] `RESEARCH` Probe saturated-history resize cost at HEAD (H1): where does
  a full-width change on 5,000+ retained rows spend its time, and is it within
  a frame budget? Destination: `F5`.

### Phase 3 -- direction gates

- [ ] `TODO` Gate: H3 vs H4 -- pick the larger target from `F2`, or conclude
  both/neither clears the bar. Destination: `D2`.
- [ ] `TODO` Gate: H2 -- viable only if `F3` shows blank rows matter and the
  charge-model question has a clean answer. Destination: `D3`.
- [ ] `TODO` Gate: H5 -- live only if the selected H3/H4 direction leaves
  deep-history footprint on the table. Destination: `D4`.

### Phase 4 -- graduate

- [ ] `TODO` Extract any selected direction into a plan file; record where it
  went and close, or close with all hypotheses dispositioned.

## Rejected

None yet. The shipped plan's rejected ideas and doc 16's closure are inherited
boundaries (see Investigation rules), not re-litigated here.

## Open questions and caveats

- Is +2.51 MB attributable footprint at 179-column saturation an accepted cost
  of 3.41x depth, or itself a target? The shipped plan chose depth
  deliberately; H4 could claw the overhead back without giving depth up.
- The browsing -5.79% result has no frozen decision rule behind it; treat it
  as descriptive until `D1` gives the measurement a home.
- H2's charge-model question (how shared storage is charged) may itself be the
  reason to reject it; cheapness of the trick does not excuse an incoherent
  budget.

## Outcome

Investigation in progress.
