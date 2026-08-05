# Faster Saturation Guard Test

## Problem and desired outcome

The parameterized saturation guard currently feeds all 430,000 declared recipe
lines through individual `Terminal.feed` calls. In the full TerminalCore gate it
has occupied about 93 seconds of the critical path under contention, even though
the behavior it needs to prove is only that each shipped recipe reaches the
production scrollback budget and remains at that ceiling under further output.

Reduce that test cost without weakening its saturation evidence, changing the
real resize probe, reducing the shipped recipes, or serializing the cases.

## Decision

Keep the optimization inside the saturation guard test. Feed each recipe's exact
byte stream in bounded batches, stop after the first observable budget eviction,
and retain the declared recipe line count as the hard search limit. The real
probe continues to feed every declared line so its frozen stimulus and reports
remain reproducible.

Saturation evidence consists of a terminal that has actually evicted retained
history and the number of recipe lines examined. Absence of evidence is distinct
from zero lines examined. After finding eviction, the guard continues with 200
lines of the same payload and preserves its current retained-depth band: the
additional output must leave the retained row count within 100 rows of the count
at detection and must not create a retained-storage overdraft.

The three shipped saturating recipes remain parameterized and eligible for
Swift Testing's normal parallel execution.

## Invariants

**I1. Production probe fidelity.** `makeSaturatedTerminal`, the shipped recipe
constants, their identities, and the resize measurement path are unchanged.

**I2. Real saturation evidence.** A recipe passes only after an observable
eviction at the production budget. Merely producing scrollback or filling the
viewport is not saturation.

**I3. Bounded search.** The detector never feeds beyond the recipe's declared
line count while searching. Failure to observe eviction within that prefix is a
test failure rather than an assumed saturated state.

**I4. Equivalent stimulus.** Batching preserves recipe order, line bytes, hard
line boundaries, geometry, payload, and production budget. Follow-up output uses
the same payload beginning at the next unfed recipe index.

**I5. Continued ceiling behavior.** Once eviction is observed, 200 more recipe
lines buy no material retained depth and history remains within its storage
budget.

**I6. Parallelism is preserved.** The optimization reduces work per case rather
than avoiding contention by serializing the parameterized cases.

## Proof obligations

**PO1 (I2, I3).** All three shipped saturating recipes produce non-empty
saturation evidence within their declared line counts, including an explicit
positive `linesFed` count.

**PO2 (I2).** A deliberately shallow production-budget recipe does not produce
saturation evidence. This guards against treating viewport fill or ordinary
scrollback growth as eviction.

**PO3 (I4, I5).** Each shipped recipe preserves the existing post-saturation
retained-depth band after 200 same-payload lines and reports no storage
overdraft.

**PO4 (I1, I6).** The complete resize-probe support suite and TerminalCore gate
pass with production probe code, recipe data, and test parallelism unchanged.

**PO5 (performance premise).** Record rough warm before/after samples for the
targeted parameterized guard, alongside an unchanged control test in the same
session. Report Swift Testing duration, process wall and CPU time, medians, and
the detected line count for each recipe. The timings are informative only: no
elapsed-time assertion or benchmark verdict is introduced, and comparable
movement in the control makes the speedup reading noisy rather than decisive.

## Non-goals, accepted risks, and rejected ideas

- **Non-goal:** optimizing `Terminal.feed`, scrollback storage, the production
  resize probe, or the recipe constants.
- **Non-goal:** turning rough test timing into a calibrated product-performance
  claim or a wall-clock test threshold.
- **Accepted risk (AR1):** the guard observes first eviction plus 200 further
  same-payload lines rather than the probe's full declared prefix, on the premise
  that continued same-payload feeding cannot later leave a meaningfully shallow
  history. Eliminating this extrapolation would also eliminate the early-stop
  saving, and the existing guard already extrapolates from a 200-line overfeed.
- **Rejected idea:** using charged bytes equal to arena capacity as saturation
  evidence. Record granularity does not require exact equality.
- **Rejected idea:** reducing CPU use by serializing the recipe cases. That
  lengthens the gate and does not remove unnecessary work.
- **Rejected idea:** using a smaller test budget. It would no longer prove that
  the shipped recipes saturate the production configuration.

## Implementation discretion

- Batch size and private test-helper structure are discretionary, provided the
  bounded search and exact-stimulus invariants hold.
- The order of intermediate timing checkpoints is discretionary; only a warm
  current-tree baseline, a final measurement, and the unchanged control are
  required.

## Implementation notes

- The detector uses 2,048-line batches. It first observed eviction after 40,960
  dense lines, 247,808 sparse lines, and 12,288 wide lines; each count is positive
  and within its shipped recipe's declared bound.
- Three warm `--skip-build` samples in one session moved the targeted guard's
  median from 54.820s to 22.970s in Swift Testing, 56.80s to 23.81s process wall,
  and 93.87s to 42.35s user CPU (about 58%, 58%, and 55% lower). The unchanged
  control moved from 3.868s to 3.620s in Swift Testing, 5.18s to 5.46s wall, and
  2.86s to 2.95s user CPU, so its movement was small relative to the target.
