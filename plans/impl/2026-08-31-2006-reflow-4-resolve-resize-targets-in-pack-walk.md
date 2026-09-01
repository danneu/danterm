# REFLOW-4: resolve tracked cursors and anchors during the pack walk

Source finding: REFLOW-4 in `docs/scratch/2026-08-26-improvement-audit.md`
(Wave 14, unchecked). Verified live against the current tree on 2026-08-31.

## Problem

A width resize builds, per live cell, heap structures whose only purpose is
to answer at most eleven lookups afterward: `reconstructLogicalLines`
allocates one `ReflowUnit` holding a `[GridCell]` array and a
`sourceOffsets` tuple array per cell plus a `retainedSourceKeys` set insert,
and `pack` fills two dictionaries (`cellDestinations`,
`boundaryDestinations`) with one entry per cell and per unit boundary. The
consumers are two tracked cursors (live + DECSC saved) and at most nine
captured `WidthChangeAnchor` slots. The work scales with screen size, not
with what the resize needs, and live drag-resize runs it per geometry step.
The wide branch also inserts each source key into the set twice.

The Wave 7 reflow rewrite (848d8e41) already moved halfway: tracked cursors
resolve to per-line attachments during the reconstruction walk, and the
boundary anchor case and all nine captured anchors are already expressed as
logical offsets within their reflow line (`liveReflowOffset` builds them
that way). Only the cursor-on-a-retained-cell case still goes through a
per-cell key map, and that one case is what forces every per-cell structure
to exist.

## Decision

Carry every resolution target as a logical offset within its reflow line,
and have `pack`'s own walk -- which already maintains the running logical
offset -- record a destination when it reaches a wanted offset. The
authority (the pack walk) answers directly; no lookup structure is built.

Consequences, all deletions:

- `PackedReflowLine.cellDestinations` and `.boundaryDestinations` stop
  existing; `pack` resolves a small per-line wanted list instead.
- `ReflowUnit.sourceOffsets`, `retainedSourceKeys`, and the
  `sourceKey(row:column:columns:)` flattening stop existing.
- `ReflowUnit.cells: [GridCell]` becomes a head cell plus a width: the only
  two-cell unit is a wide pair whose tail is already synthesized from the
  head, so `pack` synthesizes it at placement and the per-cell array
  allocation disappears.
- `reflowDestination` dissolves into the pack walk.

The two anchor meanings survive as two offset-keyed kinds, because they
differ at the new margin: a *cell* target means "where the cell covering
this offset was placed" (a cell pushed to the next row resolves there); a
*boundary* target keeps the current spelling ("after this many cells",
folding onto the margin as last-column-plus-pending-wrap).

Landing gate (from the audit): the change lands only if the paired
comparison in PO4 shows the `wide` recipe's per-resize wall-clock median
and p95 improved, with retained row and cell counts identical across arms.

## Invariants

- I1: Every resize destination the refold produces -- live cursor, saved
  cursor, and all nine captured anchors -- is identical to today's, for
  every case: cursor on a narrow cell, on a wide head, on a wide tail, on a
  spacer column before a wide head, a wide pair straddling the new margin
  (offset advances by two while the destination column does not), cursor
  past the fold bound, pending wrap, and below content.
- I2: A captured anchor whose offset never appears as a unit boundary in
  its packed line (for example an offset landing inside a wide pair) still
  falls back to the line's content end, as today.
- I3: Packed row content -- text, styles, wrap flags, prompt marks, fill,
  cursor-only row accounting -- is unchanged; the deleted structures had no
  other reader.

## Proof obligations

- PO1 (I1, I3): the existing behavioral suites pass unchanged --
  `TerminalResizeTests`, `TerminalSavedCursorResizeTests`,
  `TerminalLogicalLineFoldTests`, `TerminalPromptAnchorResizeSweepTests`.
  They assert projected text and cursor positions, not the maps, so they
  survive the restructuring by construction.
- PO2 (I1): each of the nine captured anchor slots is carried through a
  width reflow by a behavioral test that asserts its resulting position.
  Cite the suites that actually assert each slot (the prompt-anchor sweep
  does not cover them); the armed-link range currently has no such test,
  so add one that arms a link, reflows the width, and observes the
  resulting range and activation identity.
- PO3 (I1, I2): if no existing test pins the cursor on a spacer column of
  a wide pair straddling the new margin, or the mid-wide-pair anchor
  fallback to content end, add characterization tests for those cases.
  They pin unchanged behavior, so they must pass against the baseline
  before restructuring and stay green after -- there is no red state.
- PO4 (cost gate): a contemporaneous paired comparison per
  `agent-docs/measurement-discipline.md`. The probe is deliberately
  single-arm today; this change is "expected to move resize cost", which
  is exactly `research/28/D1`'s stated gate for upgrading it to a paired
  candidate workload. Requirements, all of which one comparison owner
  (a script, not eyeballed logs) enforces from the paired artifact:
  - Baseline and candidate probe binaries run interleaved in one session
    on one machine; never a comparison of logs across sessions.
  - The decision rule -- pair count, estimator (paired `wide`-recipe
    median and p95 deltas), and a minimum improvement threshold -- is
    frozen before any decision run, and not by fiat. Two A/A stages,
    per the doc's "a screen is not a freeze" rule: *select* the pair
    count and threshold from one series of baseline-vs-baseline
    replications, then *confirm* the frozen rule against a disjoint A/A
    series under a predeclared false-positive limit (a threshold set at
    an observed maximum of n replications is exceeded by a fresh run
    with probability about 1/(n+1), so the selection sample alone
    cannot validate itself). Only a rule that survives confirmation
    gates the decision run; the owner enforces the frozen values and
    the decision run changes none of them.
  - Both arms report retained row and cell counts, and the owner fails
    the comparison on any mismatch or missing field (a missing field is
    not a zero), so a candidate that drops cells cannot read as a
    speedup.
  - A same-session series the change cannot reach serves as the timing
    control and must be unmoved.
  Optionally confirm with an Instruments Allocations pass on one 200x60
  resize that the per-cell arrays are gone.

## Non-goals

- No behavior change anywhere; this is a cost-and-structure refactor.
- The anchor capture side (`liveReflowLine`, `liveReflowOffset`,
  `rebasedAcrossSeam`) already speaks offsets and is untouched.
- `resizeWidth`'s `projectedLiveRows` materialization (the finding's
  "three representations" remark) stays; it is a separate cost item.
- The cheaper fallback in the finding (`reserveCapacity` + deduplicated
  inserts) is rejected: it trims constants and keeps the per-cell
  allocation, which is where the time is.

## Rejected ideas

- RI1: Promote the `wide` recipe through the full screen-and-confirm
  calibration process (`terminal-benchmark-candidate-screen.py`, with
  injected-effect detection conditions). PO4 is a one-shot comparative
  claim: it takes interleaved same-session arms, a control, direct
  baseline measurement, and a rule frozen from an A/A noise calibration
  -- all prescribed there -- but not injected-effect detection, because
  a rule too weak to detect the real effect only refuses the landing,
  which is the safe direction.

## Implementation discretion

- How `pack` receives and returns the per-line wanted list, and whether
  the reconstruction walk resolves cursor offsets per cell or per row.
- PO4's choice of control series and the comparison script's shape.
  The pair count and threshold are not discretion: their values come
  from the A/A calibration PO4 prescribes.

## Files

`lib/TerminalCore/Sources/TerminalCore/Terminal.swift` --
`ReflowUnit`, `ReflowCursorAnchor`, `PackedReflowLine`,
`reconstructLogicalLines`, `reflowDestination`, `pack`, `sourceKey`, and
the resolution loops in `resizeWidth`. Tests in
`lib/TerminalCore/Tests/TerminalCoreTests/`. The probe upgrade for PO4
lives in
`lib/TerminalCore/Sources/TerminalResizeProbeSupport/TerminalResizeProbeSupport.swift`.

## Verification

1. Targeted suite: `swift test --package-path lib/TerminalCore --filter
   Resize` plus the fold and anchor-sweep suites; then `just lint`.
2. The paired probe protocol from PO4.
3. `just test` before commit.
4. On landing, check REFLOW-4 off in the audit's Wave 14 checklist with the
   commit hash, matching the established convention in that file.

## Commit progress

- [x] 1. perf(probe): add a calibrated paired resize comparison
- [x] 2. perf(reflow): resolve resize targets during the pack walk
- [x] 3. docs(audit): mark REFLOW-4 complete

## Implementation notes

- Commit 1 decides on **four** statistics, not the two PO4 names: a median and a
  p95 for each resize direction. The calibration is what forced it. The probe
  alternates narrow and wide, and on the `wide` recipe the two directions centre
  on 2.59 ms and 1.45 ms, so every quantile of the combined samples sits inside
  one group and moves between them for reasons that are not cost -- the combined
  median's paired A/A spread was 4.7-7.7%, against 0.4-0.8% once the groups are
  read apart. So `ResizeProbeReport` now carries each direction's samples
  separately and the rule decides on the four numbers that mean one thing each.
  Reading PO4's "median and p95 improved" onto them: both narrowing statistics
  (narrowing is the direction that reflows) must improve, and neither widening
  statistic may regress. Requiring an improvement in the direction that mostly
  re-pads would refuse a real win in the direction that does the work.
- The selection procedure takes the pair count and the thresholds from the A/A
  series, as PO4 requires, but it needs one declared input to choose among cells:
  `TARGET_THRESHOLD_PERCENT = 2.0`, the sensitivity the deciding half of the rule
  must reach for a pair count to be usable. It is declared from what REFLOW-4 is
  expected to remove, not from any candidate measurement -- no candidate exists
  yet. Thresholds are per estimator because the tails are far noisier than the
  medians and one number would price every estimator at the noisiest one's.
- Frozen rule, from `docs/scratch/2026-08-31-reflow-4-resize-calibration/`: 24
  pairs; thresholds 0.5% (narrowing median), 2.0% (narrowing p95), 0.5%
  (widening median), 4.0% (widening p95). A/A false-positive rates 0.000-0.048 on
  the selecting series and 0.001-0.047 on the disjoint confirming one, against
  limits of 0.05 and 0.10.
- The comparison runs the probe at `--samples 200` rather than the `wide`
  recipe's 20. A sample costs about two milliseconds, and 20 prices a p95 off a
  single order statistic.
- Series artifacts keep every raw sample and are stored gzipped (1.3 MB -> 185 KB
  each); the script reads either shape.

### Commit 2

- The reconstruction walk resolves a tracked cursor's offset per cell, not per
  row, and pays for it only on the rows that carry one. A per-row helper walk
  was the obvious alternative and is wrong: a spacer column at the end of a
  soft-wrapped row belongs to a wide head on the *next* row, so resolving one
  row at a time cannot answer it. The walk instead carries the cursors parked on
  an unconsumed spacer, which is the same state the old code carried as
  `pendingSpacerKeys`. A row that carries no tracked cursor pays one bool test
  per cell, read once before the row's columns.
- `pack`'s per-line wanted lists are five buffers hoisted out of the line loop
  and emptied with `removeAll(keepingCapacity:)`, so the whole refold allocates
  them once rather than once per logical line. The boundary requests are the
  cursors' first and the anchor slots' after, which is what lets one offset
  array carry both kinds of requester and each find its answer by position.
- PO3's second case has no test, because it has no construction. An anchor
  offset that lands *inside* a wide pair cannot be produced through the public
  API on the live side: `liveReflowOffset` counts a wide pair with a single
  two-step, so every live address it can make is a unit boundary. The one route
  left is a history address rebased across the seam, whose cell offset is not
  built by that walk. I2's fallback is therefore preserved by identical code
  (`nil` -> `contentEnd`) rather than pinned by a new test, and fabricating a
  scenario to reach it would have tested the fabrication. PO3's first case --
  the cursor on a spacer column of a wide pair straddling the new margin -- is
  reachable and is now pinned for the live cursor and the DECSC slot both. All
  three new tests were run against the baseline `Terminal.swift` and pass there
  too, which is what makes them characterization tests rather than a spec for
  the new code.
- PO2's armed-link test drives the arm through `decideTerminalPointer` rather
  than `setArmedLink`, so it observes activation identity the way a Cmd-click
  does: press, resize, release, and the release still opens the link.
- PO4 decided `improved`, and by much more than the rule asks: the narrowing
  median falls 2.60 ms -> 0.37 ms and the widening median 1.45 ms -> 0.33 ms,
  with both arms on 10700 retained rows and 1915200 retained cells and a control
  that moved 0.06% to 0.95%. The artifacts are
  `docs/scratch/2026-08-31-reflow-4-resize-calibration/decision.json.gz` and
  `decision-verdict.json`. The Instruments Allocations pass PO4 offers as
  optional was not run: the win is far outside the rule's band and its shape
  (both directions, proportional to cells) already reads as the per-cell heap
  traffic going away.
