# Sparse AppKit damage clip topology

Research started: 2026-08-01. Continued by
[30-cg-clip-construction-mechanics](../30-cg-clip-construction-mechanics/README.md),
which owns the clip-construction mechanics inside the shipped implementation
(CG dispatch fast paths, the second dirtyRect clip, and span derivation).

- [findings.md](findings.md) -- the migrated investigation notebook and full
  profiling evidence chain.
- [decisions.md](decisions.md) -- the keep/revert, fallback, and benchmark
  instrumentation decisions.

## Purpose

This doc owns the performance behavior of exact sparse terminal damage after it
crosses the AppKit boundary: why one Core Graphics rectangle per damaged row
regressed live btop, which clip topology avoids that regression, and the
evidence required to keep sparse clipping instead of reverting it.

It preserves the profiling record behind the
[sparse-damage implementation](../../../plans/impl/2026-08-01-2219-preserve-sparse-appkit-terminal-damage.md)
shipped in `f3c774d`,
including the direct-draw metric's blind spot for asynchronous Core Animation
replay and the remaining benchmark-coverage handoff to M9 criterion 2.

## Investigation rules

- Compare fresh optimized apps at verified 179x66 geometry and record app
  foreground state before an automated Down-arrow stimulus.
- Use whole-process CPU for decisions involving Core Animation; the synchronous
  draw timer ends before Core Animation replays the recorded display list.
- Treat `sample` counts as attribution, not a CPU quantity, because blocked and
  running samples coexist.
- Freeze a decision rule before reading a topology endpoint, and require a
  topology histogram with a sample count as the calibration gate.
- Re-measure each candidate directly against the relevant parent; do not derive
  a new verdict by subtracting comparisons from different stimuli or cadences.

## Trigger and current evidence

Commit `d378096` retained exact sparse engine damage through AppKit, but emitted
one Core Graphics path rectangle per damaged row. Holding Down in btop at
179x66 raised DanTerm CPU from the previously observed roughly 25% to roughly
40%. Controlled profiles attributed the increase to Core Animation compound
clip construction even while DanTerm's synchronous draw work fell.

The final controlled three-arm comparison measured mean process CPU of 24.17%
for `d378096^`, 44.10% for uncoalesced `d378096`, and 22.94% for maximal-span
coalescing. The parent and coalesced ranges overlap, so the supported conclusion
is equivalent or better, not a claimed speedup. See findings F3-F6.

## Current hypotheses

### H1 -- row-rectangle topology causes the Core Animation cliff

Confirmed for the reported workload. Btop's dominant 45 damaged rows arrived as
only two contiguous spans, and replacing 45 row rectangles with two span
rectangles removed 95.5% to 97.6% of the regressed compound-shape subtree.

### H2 -- maximal-span coalescing is sufficient

Confirmed at 179x66. It recovered the btop regression, retained the motivating
two-distant-row win, and stayed no slower than parent at the halo-limited
17-span endpoint.

### H3 -- a complexity fallback is required

Rejected under the frozen rule. The maximum-span endpoint did not regress
whole-process CPU, so a threshold would add policy without measured benefit.

## Task ledger

### Phase 1 -- reproduce and attribute

- [x] Reproduce the regression at controlled 179x66 geometry (F3).
- [x] Measure the post-halo btop topology with a counted histogram (F4).

### Phase 2 -- revise and decide

- [x] Coalesce adjacent damage into maximal spans and verify exact output (F5,
  D1).
- [x] Re-run the two-distant-row acceptance workload against the parent (F6).
- [x] Calibrate and measure the 17-span maximum endpoint under a frozen rule
  (F6, D2).
- [x] Run `just test` and `just test-ui`; 60/60 and 207/207 passed (D1).

### Phase 3 -- hand off durable coverage

- [x] Retain benchmark-only topology accounting as the calibration seam (D3).
- [x] Hand permanent `sparse-many-runs` workload calibration to the future M9
  criterion-2 plan; it is visible-output coverage, not unfinished renderer
  selection work (D3).

## Rejected

### Revert exact sparse damage

Rejected because maximal-span coalescing cleared every keep-bar line while
retaining the low-complexity sparse-damage benefit. Reopen only if a larger-grid
measurement shows a separated whole-process CPU loss.

### Add a span-count fallback

Rejected because coalescing was no slower than parent at the maximum 17-span
topology available at 66 rows. Reopen only after calibrating a failing endpoint,
not from an extrapolated clip cost.

### Draw every span separately

Rejected without implementation. It duplicates frame-level setup and display
list operations, while the simpler compound path already cleared the bar.

## Open questions and caveats

- The maximum span exposure grows with grid height, approximately
  `ceil(rows / 4)` under the current one-row glyph halo. Only the reported
  179x66 geometry has a calibrated maximum-endpoint result.
- The benchmark suite still lacks a permanent decision-bearing workload whose
  primary metric includes post-`draw` Core Animation CPU. The reproduction
  precondition is met; calibration belongs in the criterion-2 plan.
- `.build/` artifacts are disposable. The decision-bearing values are therefore
  transcribed into findings as well as linked to local artifacts.

## Outcome

Shipped in `f3c774d`: exact sparse damage remains, but adjacent damaged rows are
coalesced into the minimum number of vertical clip spans. This preserves the
two-distant-row CPU win, removes the live-btop regression, and needs no
complexity fallback at the calibrated 179x66 maximum topology.

The investigation is closed. Reopen as a new research doc only if larger-grid
evidence produces a separated regression or if permanent workload calibration
reveals that whole-process CPU cannot support a stable verdict.

**Flagged from doc 28 (2026-08-03), not a reopening.** `28/F4` localizes a
`style-churn` regression of roughly 3-7% to `dd51a12..e4556c0`, the range that
contains this doc's shipped work (`d378096`, `f3c774d`, `24c3d03`, `3fbd487`).
Two independent `confirm` runs at two baselines agree in direction, and the
competing explanation -- that the benchmark's own accepted-draw instrumentation
was billing itself to what it observes -- was tested against `13f82c8~1` and
failed, so this is not a measurement artifact. `style-churn` freezes text and
varies only attributes, which is a workload this doc's calibration did not
weigh against the btop-scroll win it shipped on. Whether that meets the
separated-regression bar above is this doc's owner's call, not doc 28's; the
evidence and both bounding runs are recorded in `28/F4`.
