# Plan: a plan-time line that measures plans, and arms that are warm before they are measured

## 1. Problem

Two defects in the paired benchmark harness make it call `slower` on code that
did not change.

- **The plan line sums unlike things.** `planNanosecondsPerDraw` is the block's
  cumulative `planFrame` time divided by its 50 accepted draws. The samples
  behind it are bimodal: a plan that replans the whole 66-row viewport costs
  ~320 us, and a plan that replans part of it costs ~110-200 us. Which mix a
  block gets depends on PTY read chunking and producer timing, not on the
  planner, and it differs between the two arm processes by 0-14 plans per
  block. An A/A series at `HEAD` against itself read the quick plan line at
  +7.33% (range +5.35..+9.31%) on identical binaries
  (`.build/terminal-benchmark-plan-calibration/310a8352d7ad-0000`). The
  frozen quick rule (2 pairs at +/-2.5%) was calibrated on a 12-quartet series
  whose ABBA/BAAB alternation averaged this out; a quick run is one ABBA
  quartet and cannot.
- **The first block of a persistent arm is cold.** In the draw A/A
  (`.build/terminal-benchmark-draw-calibration/310a8352d7ad-0000`) the first
  block drew at 3325 us against 3083-3140 us for the seven after it. Quick mode
  is a single quartet, always ABBA, so the baseline role always owns that cold
  block, and the slope inside the quartet is not cancelled.

## 2. Decision

- **D1.** The observer records every `planFrame` call inside a block as its own
  sample -- duration and the number of rows it replanned -- instead of folding
  plan time into the accepted draw that followed it. Full damage replans every
  row, so it records the viewport row count; a shift region's rows are copied,
  not replanned, and are not counted.
- **D2.** The block's plan quantity is the median duration over samples that
  replanned the full viewport, named `planNanosecondsPerFullPlan`, emitted
  beside its sample count `fullPlanCount`. Fewer than 25 full plans in a block
  makes the quantity absent, not zero. `planNanosecondsPerDraw` is deleted.
  `incremental-mixed` plans 4-5 rows and never a full viewport, so it carries no
  plan line; its old line was already refused a rule and declared jittery.
- **D3.** No plan rule is frozen. `DECISION_RULES.quick.planWorkloads` is
  removed, so the plan line is descriptive in both modes until an A/A series on
  the new quantity is collected and a human freezes a threshold from its
  report. The calibration script screens the new quantity through the existing
  `--metric plan` table.
- **D4.** Each persistent draw arm runs one discarded warm-up block after it
  starts and before any scheduled block, once per app process per invocation.
  The warm-up's per-draw number is recorded in the workload evidence as
  `warmupBlocks` so a reader can see the cold cost it absorbed.
- **D5.** A quick invocation's single quartet starts on ABBA or BAAB by a bit of
  the candidate tree hash, the way `physical_candidate_arm` already picks the
  slot, and the run record names the phase. Alternation was already the
  schedule's stated intent; this makes it hold across invocations instead of
  only across quartets.

Not chosen, and why:

- Nanoseconds per replanned row over all plans. Simpler to state, but a
  partial plan carries the same fixed cost as a full one over fewer rows, so
  the ratio still moves with the mix -- less, not zero.
- Keeping the per-draw sum and widening the rule. The A/A refuses any threshold
  at 2 pairs; widening until it passes would make the line unable to see the
  5% effect it exists for.
- Warming inside `_collect_draw_churn`. The calibration collector calls it once
  per quartet, so the cost would repeat and the second warm-up would measure
  nothing. Once per process, at the lifecycle seam, is the invariant.
- Alternation alone for the cold block. It randomizes which arm pays the cost;
  it does not remove it. The warm-up removes it; the alternation is for what
  remains.

## 3. Invariants

- **I1.** A block's plan quantity does not change when the same plans are
  regrouped across draws or when partial plans are added to the block.
- **I2.** A block that carries no full-plan samples, or an arm built before the
  per-plan fields existed, produces no plan line and does not invalidate the
  draw verdict.
- **I3.** Every scheduled block of a persistent draw workload runs after that
  arm's warm-up block, and the warm-up block appears in no paired difference.
- **I4.** Across candidate trees, quick quartets start on ABBA and BAAB with
  equal frequency, and within any run each quartet is one of the two.

## 4. Proof obligations

- **PO1 (I1).** `terminal_benchmark_validation_test`: a `finalDraw` with mixed
  full and partial samples normalizes to the median of the full ones; adding
  partial samples leaves it unchanged; fewer than 25 full samples gives `None`
  with the count still emitted.
- **PO2 (I2).** `terminal_benchmark_compare_test`: a block series lacking the
  field on one arm yields no plan summary; the draw decision is unaffected.
  `terminal_benchmark_plan_calibration_test`: the series reduces on the new
  metric name.
- **PO3 (I3).** `terminal_benchmark_validation_test`: with fake lifecycle and
  runner, `make_production_collectors` runs the runner once for `a` and once
  for `b` before any collector is called, `rawBlocks` holds only scheduled
  blocks, and `warmupBlocks` holds two.
- **PO4 (I4).** `terminal_benchmark_compare_test`: two trees differing in the
  phase bit produce ABBA and BAAB first quartets; every quartet is still in
  `{ABBA, BAAB}`.
- **PO5 (defect reintroduced).** The A/A plan series on the new quantity:
  collected on the warmed harness with `--metric plan --workload content-churn
  --workload style-churn`, its report recorded for the user to freeze from.
  The old quantity's +7.33% is the reference the new one must not reproduce.
- **PO6.** The draw A/A on the warmed harness with `--metric draw --workload
  content-churn`: the first measured block sits inside the range of the others.

## 5. Non-goals / Accepted risks / Rejected ideas

- **NG1.** No executor or planner code changes. Phase 2 measures the traversal
  on this harness; this plan only makes the harness able to.
- **NG2.** No rule is frozen here. `DECISION_RULES` moves by a human reading a
  report.
- **AR1.** Baselines older than this change lose their plan line against a new
  candidate. Accepted: the line is absent, never zero, and the draw verdict
  does not depend on it.
- **AR2.** Two extra blocks per draw workload per invocation (~10 s).

## 6. Implementation discretion

- Field names inside the observer artifact, provided the replanned-row count
  and duration are index-aligned and the full-plan count is emitted.
- How `warmupBlocks` is summarized, provided the arm and its per-draw number
  are readable.

## Commit progress

- [x] 1. bench(harness): measure plan time as the median full-viewport plan
- [x] 2. bench(harness): warm each persistent arm and phase the quick quartet
- [ ] 3. docs(research): record the plan-metric and warm-up A/A series
