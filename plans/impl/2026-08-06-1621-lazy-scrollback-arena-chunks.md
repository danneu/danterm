# Lazy per-pane scrollback arena chunks

## Context

Each `Terminal` reserves its whole scrollback arena at construction and writes
zeros across it, so every pane pays the full budget as dirty resident pages
before it holds a single line of history.

Evidence, from a live `DanTerm Dev` instance and the headless probe:

- A terminal with **zero** bytes fed and `retainedArenaBytesInUse: 0` costs
  **16.05 MB**. The cost is flat across a 29x range of grid geometry, so it is
  arena, not cells.
- That instance held **31 panes** and a 775 MB footprint, of which ~500 MB was
  arena chunk backing (`_ContiguousArrayStorage<UInt64>`, 512 KiB each).
- `vmmap` reports the pages DIRTY, so they are resident, not lazily faulted.

Desired outcome: a pane's resident arena cost becomes proportional to the
history it has actually written, at chunk granularity, with no change to
capacity, budget accounting, or eviction behavior.

Load-bearing premises:

- **P1.** Chunks are first written in consecutive, increasing index order.
  Before the arena's physical end wraps the cursor back to zero, each newly
  visited chunk index is the successor of the highest already visited; every
  backward cursor move targets a chunk that is already materialized. The
  premise is consecutive first materialization, not monotonic cursor movement
  — this is what makes append-only growth sufficient and a sparse table
  unnecessary.
- **P2.** A record never straddles a chunk (`research/31/D5`). This makes record
  placement a sufficient point to materialize backing: if the chunk holding a
  record's header exists, every later write for that record is in bounds.
- **P3.** Arena equality is computed record-by-record, never over the chunk
  table, so how much backing is materialized is not observable through `==`.
- **P4.** `research/31/I2` bounds resident bytes by capacity plus metadata.
  Lazy growth keeps that bound true and makes it strictly tighter, so `I2` is
  preserved as ratified and needs no amendment.

## Decision

Materialize arena backing lazily, per pane, by appending chunks on demand.
Capacity, chunk size, the byte address space, and the budget stay exactly as
they are; only the point at which backing is allocated moves.

Append-only, not a sparse table with an absent-chunk sentinel: P1 makes holes
unreachable, so the chunk count alone is sufficient state.

Critical file: `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift`
(the arena, its metadata charge, and its test-support hooks), plus the arena
tests in `lib/TerminalCore/Tests/TerminalCoreTests/`. Doc comments that
describe the arena as reserving its whole capacity at construction — including
the one on the rebudget path — must be updated to distinguish reserved capacity
from materialized backing.

## Invariants

- **I1.** A store materializes backing only for chunks it has written. Arena
  capacity, the byte address space, and budget accounting are unchanged.
- **I2.** Materialized backing never exceeds the arena's full chunk count, and
  that ceiling follows from the fixed capacity rather than from a tracked
  counter.
- **I3.** The arena's metadata charge is independent of how many chunks are
  materialized: it stays at the value it has today, derived from the full chunk
  count. The charge currently reads a live count that happens to be constant
  because every chunk is always allocated; under lazy growth that count varies,
  and letting the charge vary with it would drift the fixed metadata reserve
  underneath live content.
- **I4.** How much backing a store has materialized is not observable. Records,
  reads, equality, eviction, seam handling, and copy-on-write sharing depend
  only on content, never on materialization extent. Census is bounded more
  narrowly: it may still differ between equal-content stores through
  metadata capacities that legitimately do not shrink today, so
  materialization extent must not be an *additional* source of difference.

## Proof obligations

- **PO1** (I1). A store with no admitted records has materialized no backing; a
  store holding a single record has materialized exactly one chunk.
- **PO2** (I2, P1). A store cycled past its capacity across chunk seams
  materializes no more than its full chunk count and reads every retained
  record back exactly.
- **PO3** (I3). Census and charge figures are identical to today at equal
  content, including for an empty store.
- **PO4** (I4). Existing saturated-arena behavior is unchanged. The current
  suite already exercises this — the ring-cycling and copy-on-write identity
  tests both saturate their arena before asserting — so it is the regression
  net, and it must pass unmodified.
- **PO5** (I4, P3). Two stores holding equal content but reached through
  histories that materialized different amounts of backing are equal and read
  back identically. Their census figures match when backing high-water is the
  only representational difference between them — that is, when the metadata
  capacities census already charges are also equal.
- **PO6.** The measured per-terminal fixed footprint falls, while the arena
  capacity reported alongside it does not.

## Non-goals

- Reclaiming materialized backing when a store empties. Worth doing, separable,
  and deliberately not in this change.
- Any change to the scrollback budget, the chunk size, or the eviction policy.
- Any cross-pane or process-wide budget.

## Accepted risks

- **AR1.** The worst case is unchanged. N panes each holding full scrollback
  still cost N times the budget; this converts a fixed cost into a proportional
  one without lowering the bound.
- **AR2.** The distribution of arena occupancy across real long-lived panes is
  unmeasured, so the size of the win in a mature session is projected from the
  empty case rather than measured. Accepted because the change cannot regress
  memory: at full occupancy it allocates exactly what eager allocation did.

## Rejected ideas

- **RI1. Process-wide scrollback budget with cross-pane eviction.** Bounds the
  worst case, but a victim pane can only shed on its own queue, so the bound
  becomes soft and eventual — forfeiting the structural bound the arena design
  exists to provide. It also introduces silent cross-pane data loss, where one
  pane's flood destroys another's history, which is impossible today.
- **RI2. Per-pane budget scaled by pane count.** Keeps the bound structural and
  needs no cross-pane coordination, but shrinks every pane's history when a new
  pane opens. Deferred until occupancy evidence shows the worst case is real.
- **RI3. Sparse chunk table with an absent-chunk sentinel.** Strictly more
  machinery than P1's monotonic access requires.
- **RI4. Uninitialized or `calloc`-backed storage, keeping untouched pages
  clean.** Would preserve eager structure while shedding the dirty pages, but
  requires abandoning the array storage the chunked design depends on for
  copy-on-write between published frames, and hand-rolling that back is a far
  worse trade than an allocation.
- **RI5. Reducing the scrollback budget.** A tradeoff, not a fix; it costs every
  user history depth.

## Implementation discretion

- Where materialization is triggered. Any single site that runs before a
  chunk's first write is sufficient, given P2.
- Whether the full chunk count is stored or derived.

## Verification

Behavioral proof is PO1-PO5, via the arena tests; `just test` is the gate.
Start from the failing test for PO1, which fails today for the right reason (a
fresh store reports a full chunk table).

PO6 is a measurement, and per
[agent-docs/measurement-discipline.md](../../agent-docs/measurement-discipline.md)
it must compare contemporaneous arms: measure the eager and lazy builds
interleaved within a single session rather than against a baseline file stored
from an earlier one, so machine-state movement between sessions cannot be read
as the implementation's effect.

The calibrated instrument already exists:

```
scripts/terminal-fixed-cost-probe.py --reps 5 --compare <baseline>.json
```

It repeats each measurement and sweeps geometry as a control; both controls are
retained. Its noise floor is one 16 KB page against an expected drop of roughly
15.7 MB. Read `footprintDelta`: `arenaCapacity` is logical address space and
will correctly show no change, which is PO6's second half and the reason the two
are reported side by side.

Whole-app confirmation is a live `footprint` and `heap` on an optimized slot
instance. `just benchmark-memory` is the wrong tool — it is a leak detector,
and GUI compositing churn exceeds the effect.

## Implementation notes

- The calibrated `scripts/terminal-fixed-cost-probe.py` named by Verification
  was present in the working tree but untracked at implementation start. It is
  included with the implementation so the committed verification command is
  reproducible from a clean checkout.
- The probe's raw percentage geometry gate depended on the eager arena dominating
  every sample. Once lazy backing exposed ordinary grid-size costs, the control
  was changed to report the continuous residual drift after subtracting exact
  census cell storage, without inventing a post-result pass/fail threshold.

## Follow Up

- Reconcile `docs/design/2026-08-06-swift-terminal-engine.md` D5 and D9's 10 MiB
  scrollback budget with `Terminal.productionScrollbackBudgetBytes` and
  `research/28/D11`, which define the shipped budget as 16 MiB.
