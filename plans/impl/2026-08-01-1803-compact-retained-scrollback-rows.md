# Retained history should cost what it holds, not how wide the pane is

## Context

This came out of investigating why fish sometimes shows a truncated `...` prompt
after a resize. That turned out to be an upstream fish race, not a DanTerm
defect. Looking for a DanTerm improvement worth doing regardless surfaced this,
which is a bigger problem than the one we started on.

**Widening a pane permanently destroys scrollback.** A retained row stores a full
`columnCount` of cells and is charged for all of them, so the number of rows the
budget admits is inversely proportional to the pane's width. Widening re-pads
every retained row, pushes the total over the budget, and evicts the oldest
history. Narrowing back cannot restore it. The loss is silent and irreversible,
and it is triggered by an ordinary window drag.

Evidence:

- `Terminal#scrollbackByteCost(of:)` charges a row its `cells.capacity` times the
  cell stride. `Terminal#pack(line:columns:)` builds every retained row full
  width, so that term is the pane's width regardless of content.
- `Terminal#resizeWidth(to:)` ends by enforcing the budget, which evicts from the
  head until the total fits.
- `docs/research/15-memory-footprint.md` measures the same fact from the other
  side: "Rows are *not* trimmed to their content", a 179-column row is ~12,888
  bytes, and a bounded scrollback costs ~22 MB of real cell storage against a
  10 MB budget "on every payload regardless of content", at a measured average
  line length of ~58 characters.
- This silently contradicts `I4 Conservation` in
  `plans/impl/2026-07-18-0119-primary-scrollback-reflow.md`, which claims any
  sequence of resizes leaves full-history text bit-identical. That invariant was
  proven before the budget existed (`AR1`: "Scrollback is unbounded until the
  budget slice").

Load-bearing premise: for a row that is not soft-wrapped, the projection already
discards trailing padding (`I3`), so a trailing run of blank cells carries no
observable information. Storing it buys nothing and costs retention depth.

Prior art, checked: doc 15's `H6` (compact immutable scrollback rows) is
**deferred, not rejected**, and this is a strict subset of it. Doc 16 closed a
cell-layout change for slowing the draw loop; that risk is about `GridCell`'s
stride and alignment, which this does not touch.

**Desired outcome:** retained history depth is a function of what the user ran,
not of how wide their window is, and widening never costs history.

## Decision

Stop storing the trailing run of blank cells on a row when it enters history. The
budget's cost function is unchanged — fixing the representation fixes the
accounting on its own.

Behavioral scope is retained history only. Live grid rows stay full width, and
every public surface that presents *terminal content* continues to present
exactly `columnCount` cells, so renderers and the app see no change. Storage
diagnostics are the deliberate exception: `TerminalMemoryCensus` exists to report
what is actually held, so it reports the reduced stored-cell and allocation-byte
totals and its documented "rows are full-width" premise no longer holds.

Three constraints that are not free to decide:

- A retained row must keep at least one stored cell. An empty cell array is the
  vacated-slot sentinel behind doc 15's `D1` leak proof, and a zero-width row
  would be indistinguishable from a leaked slot.
- Trimming may only drop cells indistinguishable from the blank pad. A row erased
  with a coloured pen carries trailing padding cells with a non-default style
  that the renderer draws, and a written space is content, not padding.
- Retained rows stay logically mutable at the history/viewport seam. Wrap-claim
  repair and hard reset index a retained row's last column directly, so a trimmed
  row must answer a write or a read at any column below `columnCount` rather than
  trapping on its stored extent.

Critical files: `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` (the whole
mechanism; cell storage never escapes it), `TerminalMemoryCensus.swift`, and the
core test suites that denominate scrollback budgets in whole-row costs.

## Invariants

- **I1.** Trimming is unobservable in terminal content. Every read of a retained
  cell — projection, text, geometry, browsing render, pointer hit-testing, link
  and selection resolution — returns what it returned before, and a retained row
  answers reads and writes at every column below `columnCount`. Storage
  diagnostics are exempt by design and report the smaller true totals.
- **I2.** Widening a pane never evicts retained history: no logical line and no
  part of one is lost, and the oldest retained content stays the oldest retained
  content. Physical row count may legitimately fall when reflow merges
  soft-wrapped rows into a wider one.
- **I3.** Trimming never increases a retained row's charge, and decreases it
  whenever the smaller cell array crosses an allocator capacity boundary — the
  budget charges capacity, so a row trimmed within its existing bucket costs the
  same. At a fixed width and budget, a history of short lines therefore retains
  more rows than one of full-width lines.
- **I4.** Trimming is canonical: a retained row's stored cells are a pure function
  of its observable content, so no trailing blank-pad run survives any mutation of
  a retained row. Two terminals in the same observable state therefore hold
  identical row storage and compare equal under synthesized equality — no
  hand-written `==`.
- **I5.** A row that leaves history for the live grid is full width again.

## Proof obligations

- **PO1** (I2): a test that fails today — fill history past the budget at a
  modest width, widen, and assert the full-history text is unchanged. Use
  hard-terminated lines that fit the narrow width, so reflow cannot merge rows
  and the physical row count is invariant too; that isolates the failure to
  eviction.
- **PO2** (I1): reads and writes at and past a trimmed row's stored extent are
  safe — pointer, link, and selection resolution at the last column of a short
  retained row, plus the seam mutations that index a retained row's last column
  directly: wrap-claim repair against a trimmed row and a hard reset over a
  trimmed history. A trailing coloured erase still presents its style while
  browsing. After each seam mutation, `scrollbackByteCount ==
  recomputedScrollbackByteCount` — a seam write may change a trimmed row's stored
  extent, and a stale cached total either evicts rows that fit or makes the budget
  dishonest.
- **PO3** (I1): the projection and browsing render of a trimmed row are
  byte-identical to the untrimmed case, and the memory census reports the reduced
  stored-cell count and allocation bytes.
- **PO4** (I3): at a width, content lengths, and budget chosen to separate them —
  short lines far enough below full width to fall into a smaller capacity bucket —
  two histories retain different depths.
- **PO5** (I4): terminals reaching one observable state by routes that pass
  through different stored widths converge to identical row storage and compare
  equal, including the existing no-op-resize equality cases.
- **PO6** (I5): a row pulled back into the live grid accepts a write at its last
  column and leaves a valid grid.

## Non-goals

- Restoring `I4 Conservation` unqualified. Narrowing still splits a logical line
  across more rows, each paying fixed per-row overhead, so a deep enough narrow
  can still evict. This change removes the width-proportional term, not the
  eviction path. Whether reflow should be exempt from eviction entirely is a
  separate decision.
- The resize-pacing question that started this thread (how many grids a drag
  tells the child). Unrelated mechanism, already adjudicated in
  `plans/impl/2026-07-30-1330-coalesce-superseded-resizes.md`.
- Shrinking `GridCell`. Doc 16 closed that.

## Accepted risks

- **AR1.** Retained rows are read on the browsing render path, so this touches a
  hot loop. Accepted because the blank tail is uniform and can be emitted without
  adding a branch to the per-cell inner loop, but it must be measured, not
  asserted.
- **AR2.** Admission to history runs once per scrolled line, on the feed path.
  Trimming allocates there. Bytes fall sharply and the full-width array it
  replaces is released immediately, but throughput needs a paired benchmark
  before any claim of neutrality.
- **AR3.** Roughly fifteen core suites size budgets in whole-row costs and assert
  exact retained depths at narrow widths with short content — the case this
  changes most. Most will retain more rows than they expect. This is the bulk of
  the mechanical work, and each update is evidence the fix works rather than a
  test being bent to fit.

## Rejected ideas

- **RI1.** Charge the budget for content while still storing rows full width. The
  tempting one-line version, and it is backwards: the budget would promise
  history the process cannot afford and real memory would rise.
- **RI2.** Keep a content-width field alongside a full-width array. No memory win
  and, because the cost function charges capacity, no budget win either.
- **RI3.** Inflate every retained row on read. Correct but reintroduces a
  per-row allocation on the browsing render and reflow paths.

## Verification

- `just test` for the gate.
- `just terminal-memory-probe` at **both 179 and 80 columns** before and after.
  Doc 15's rule applies: size wins land in malloc buckets, not strides, and
  `15/F12` is the precedent for a change that saved at one width and cost memory
  at another.
- Paired CPU benchmark per `10/F9` on the feed path and the browsing draw path,
  for `AR1` and `AR2`.
- Informative: retained-row count at saturation, before and after, from the same
  history data at the same width and budget. Not a gate — just the headline number
  for how much deeper history got on realistic content.
- Live check: saturate a pane with `scripts/saturate-scrollback.sh`, scroll to the
  oldest visible line, widen the window substantially, and confirm that line is
  still there. This fails today.
- Append the probe result to `docs/research/15-memory-footprint.md` as a new
  finding with a forward pointer from `F4`; findings are append-only.

## Implementation discretion

- The trim predicate and where it is applied, provided `I1` holds and the two
  constraints under `Decision` are respected.
- Whether the seam lands as one behavior-preserving change followed by enabling
  the trim, or as one change. The former makes a green suite the proof the seam
  is transparent.
- Wording updates to the reflow plan's representation-stated invariants.

## Commit progress

- [x] 1. refactor(core): add logical retained-row access seam
- [x] 2. fix(core): trim retained row padding
- [x] 3. perf(core): validate compact scrollback storage

## Implementation notes

- No routine paired workload renders retained history: `scrollback-stream`
  follows the bottom and the draw workloads start from live grids. Browsing CPU
  validation therefore used a temporary ABBA-scheduled `planFrame` probe in
  throwaway baseline and candidate worktrees; the probe was removed after its
  result was recorded in `docs/research/15-memory-footprint.md#f18`.

## Follow Up

- Investigate why `benchmark-confirm` receives empty stdout from
  `scrollback-stream` arm A at `scripts/terminal-benchmark-validation.py:883`,
  then rerun the feed comparison against `fa01b66`; quick was inconclusive at
  +1.13%, and two confirm attempts failed before producing evidence.
