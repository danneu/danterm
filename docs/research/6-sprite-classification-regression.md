# Per-cell sprite classification redraw regression

Research started: 2026-07-23.

## Purpose

This document owns the investigation of serialized full-screen redraw
regressions observed after the procedural terminal-sprite work. It is both the
evidence record and the task ledger. Record results here as each task completes
so that the eventual fix follows measured causes rather than an attractive
hypothesis.

This is bottleneck-discovery evidence, not benchmark history. Profiled timings
must never enter `benchmarks/results/*.jsonl`. Only compatible, unprofiled
benchmark runs may become canonical history.

## Investigation rules

- Preserve a clean, stationary commit for every canonical benchmark run.
- Change or isolate one suspected cost at a time.
- Compare only benchmark records with compatible fields.
- Collect at least two profiles before treating a sampled stack as stable.
- Use profiles to attribute work; use compatible unprofiled benchmarks to
  quantify an improvement.
- Keep observations, inferences, and decisions distinct in the findings log.
- Protect observable rendering and classification behavior with
  structure-insensitive tests. Do not add tests that only assert which helper
  or branch executed.
- Do not optimize the symbol path until its regression has been isolated from
  the text-path regression.
- Before implementing a fix, summarize the evidence, compare candidate
  solutions, and pause for a direction decision as required by
  `agent-docs/terminal-performance.md`.

## Trigger and current evidence

The compatible redraw records before the sprite-family series are stamped
commit `0698376` (`perf(benchmark): record pre-braille redraw baselines`) and
labelled `executor-local-braille-sprites`. They report the post-change
procedural Braille result later committed as `6d0306d`, but the stamped commit
itself does not contain that implementation. This is another provenance
limitation to preserve when interpreting the comparison. The later
sprite-family series runs from
`eb4233e refactor(renderer): extract shared sprite geometry` through
`140934b docs(renderer): document terminal sprite system`.

A full `just benchmark-redraw save=1` after that series produced records stamped
`b6c98ad`. HEAD moved while the benchmark was running, so these results are
useful discovery evidence but are not yet a reproducible post-sprite baseline.

Machine: Apple M1 Pro (MacBookPro18,1), macOS 26.5.2, display scale 2, release,
80x24, 15 batches, Swift 6.3.3. Metric is median nanoseconds per completed draw.

| Workload                            | Baseline at `0698376` | Exploratory at `b6c98ad` |  Delta |
| ----------------------------------- | --------------------: | -----------------------: | -----: |
| `full-screen-content-churn`         |               324,141 |                  368,789 | +13.8% |
| `full-screen-style-churn`           |               320,809 |                  373,417 | +16.4% |
| `full-screen-mixed-churn`           |               331,817 |                  369,718 | +11.4% |
| `full-screen-symbol-churn`          |               342,513 |                  486,283 | +42.0% |
| `full-screen-sprite-coverage-churn` |            12,419,485 |                1,132,792 | -90.9% |

The results currently support three observations:

1. The curated sprite-coverage workload improved by about 10x. Newly supported
   sprite candidates avoid the earlier expensive fallback path.
2. All three ASCII pseudo-lazygit workloads regressed by 11-16%, indicating
   added common draw-path work.
3. The btop-shaped workload regressed by 42%. It contains exactly 90% Braille
   and 10% Box Drawing. The reference record is labelled as the result of
   procedural Braille rendering, so this is evidence of a regression within an
   already-procedural, Braille-heavy path, not a general comparison of
   procedural sprites against CoreText fallback. Its non-reproducible commit
   stamp means this premise must be confirmed during causal isolation.

## Current hypotheses

### H1 -- text cells pay unnecessary sprite classification cost

`TerminalRenderExecution.swift` currently runs an ordered eight-family
classification chain for every cell:

1. Box Drawing
2. Braille
3. Block Elements
4. Legacy Computing Supplement
5. Geometric Shapes
6. Powerline
7. Branch Drawing
8. Legacy Computing

Every supported sprite scalar is at or above `U+2500`. An ASCII cell therefore
fails eight family checks before reaching the normal font path. The existing
scrollback sample contains classifier frames in a workload with no sprites,
which confirms that this unnecessary work executes. It does not quantify how
much of the 11-16% regression the classification chain explains.

Other common-path costs added during the same series remain possible, including
per-run sprite accumulator setup and drawing-state machinery. H1 is the leading
hypothesis, not yet the sole attributed cause.

### H2 -- the Braille-heavy symbol path has an additional regression

The symbol reference record stamped `0698376` is labelled as procedural
Braille, though that source change was committed later as `6d0306d`.
Subsequent commits changed Braille allocation and geometry, inserted Box
Drawing classification before Braille, and added other sprite-family machinery
to the same draw loop. Any of these may contribute to the +42% result.

The first goal is causal isolation. Potential mechanisms such as geometry
allocation, array growth, pattern translation, or Core Graphics drawing are
candidate explanations only after profiles or controlled commit experiments
identify them.

### H3 -- per-run setup contributes independently of per-cell classification

Each text run initializes accumulators for the sprite families even when the
run contains only ordinary text. This may be negligible, but the current
before/after comparison does not isolate it from classification. If an H1
experiment recovers only part of the text regression, per-run setup is the next
common-path mechanism to measure.

## Candidate direction, pending evidence

If H1 is confirmed as material, the preferred shape is single-scalar range
routing:

- Extract a single scalar once.
- Route its value directly to the only family whose range or finite set can
  contain it.
- Send values below `U+2500`, gaps between supported families, and
  multi-scalar cells directly to the existing font path.
- Keep exact membership and pattern decoding owned by each sprite family.

This is preferable to a separate "might be a sprite" predicate followed by the
same eight-family chain. Direct routing avoids duplicated checks, helps
unsupported non-ASCII cells and real sprites as well as ASCII, and keeps the
number of invoked family classifiers bounded at one.

This remains a candidate, not a selected implementation. Controlled evidence
may show that a smaller ASCII-only guard is sufficient or that classification
is not the dominant cost.

## Task ledger

### Phase 1 -- establish trustworthy baselines

- [ ] Confirm the worktree and HEAD remain stationary for the duration of each
      run; record the commit and cleanliness in the findings log.
- [ ] Rerun all five serialized redraw workloads unprofiled from a clean
      post-sprite commit with compatible machine, OS, scale, toolchain,
      configuration, geometry, batch count, and fixture fields.
- [ ] Treat the `b6c98ad` records as exploratory rather than canonical if the
      clean rerun supersedes them.
- [ ] Record the compatible baseline medians, variation, draw counts, and
      result locations in Finding F1.
- [ ] Decide whether the regression reproduces strongly enough to continue. If
      it does not, repeat under controlled conditions before profiling.

### Phase 2 -- attribute the text-path regression

- [ ] Collect two textual profiles of a sprite-free text workload and record
      both artifact paths.
- [ ] Confirm the workload truly contains no supported sprite scalars.
- [ ] Record repeated concrete hot work, call paths, thread, and available
      sample or own-time evidence in Finding F2.
- [ ] List competing interpretations, including classifier calls, per-run
      accumulator setup, CoreText work, and measurement noise.
- [ ] Create the smallest diagnostic experiment that bypasses only sprite
      classification for provably ineligible single-scalar cells. Do not retain it
      as the production fix merely because it is convenient.
- [ ] Run focused behavioral tests and `just test` for the diagnostic change.
- [ ] Rerun content, style, and mixed churn unprofiled without saving the
      diagnostic result as canonical history.
- [ ] Record recovered time and percentage for each text workload in Finding
      F3, then revert or supersede the diagnostic experiment.
- [ ] Decide whether H1 is confirmed, partially confirmed, or rejected.

### Phase 3 -- choose the text-path fix

- [ ] If H1 is material, compare at least these candidates against the measured
      cost: an ASCII-only guard, direct single-scalar family routing, and a
      centralized exact classification result.
- [ ] For each candidate, record expected benefit, correctness risk,
      synchronization risk as families change, and effect on unsupported Unicode,
      multi-scalar cells, wide cells, and real sprites.
- [ ] Identify the smallest structure-insensitive behavioral coverage needed:
      supported-family classification, range boundaries and gaps, multi-scalar
      fallback, wide-cell placement, and unchanged visible rendering.
- [ ] Write the evidence summary and recommended first production change in
      Decision D1.
- [ ] Pause for direction review before implementing the production fix.
- [ ] Write the failing behavioral test first where the chosen change alters a
      testable contract; verify the expected failure before changing production
      code.
- [ ] Implement only the selected text-path fix.
- [ ] Run focused package tests and `just test`.
- [ ] Rerun content, style, mixed, symbol, and sprite-coverage churn unprofiled
      under compatible conditions.
- [ ] Accept the fix only if behavior remains correct, the target regression
      improves materially, and symbol/sprite workloads do not incur an unexplained
      material loss.
- [ ] Record the final evidence and disposition in Decision D1.

### Phase 4 -- isolate the symbol-path regression

- [ ] Begin only after the text-path work has been measured, so its contribution
      can be removed from the symbol result.
- [ ] Compare controlled commits or variants spanning `0698376` through the
      Braille geometry changes and Box Drawing integration to locate the first
      material symbol-churn change.
- [ ] Collect two profiles of `full-screen-symbol-churn` at the relevant
      regressed state and record both artifact paths.
- [ ] Attribute repeated cost between Box Drawing misses before Braille,
      Braille pattern/geometry construction, collection allocation, and Core
      Graphics fill/stroke work.
- [ ] Record the evidence and competing interpretations in Finding F4.
- [ ] Decide whether the remaining regression is a defect, an accepted
      correctness tradeoff, or measurement noise.
- [ ] If it is a defect, compare candidate solutions and record the recommended
      smallest experiment in Decision D2.
- [ ] Pause for direction review before implementing a symbol-path fix.
- [ ] Protect the selected behavioral invariant, implement one dominant-path
      change, run focused tests plus `just test`, and rerun symbol and
      sprite-coverage churn unprofiled.
- [ ] Record the final evidence and disposition in Decision D2.

### Phase 5 -- close the investigation

- [ ] Rerun all five redraw workloads from the final clean commit.
- [ ] Save only compatible, unprofiled results chosen as canonical history.
- [ ] Confirm no profiled or diagnostic result entered
      `benchmarks/results/*.jsonl`.
- [ ] Summarize recovered regressions, accepted tradeoffs, and remaining
      uncertainties in the Outcome section.
- [ ] Update `agent-docs/terminal-performance.md` only if the investigation
      reveals a reusable methodology or workload rule not already documented.

## Findings log

Use one entry per task cluster. Do not replace old measurements silently;
append a correction and mark the earlier interpretation superseded.

### F1 -- reproducible post-sprite baseline

- Status: pending
- Date and investigator:
- Commit and worktree state:
- Commands:
- Compatible comparison record:
- New result or artifact paths:
- Measurements:
- Observation:
- Inference:
- Uncertainty:
- Next action:

### F2 -- text-path profiles

- Status: pending
- Date and investigator:
- Commit and worktree state:
- Workload and reason:
- Profile commands:
- Artifact paths:
- Repeated hot functions and call paths:
- Thread and sample/own-time evidence:
- Observation:
- Competing interpretations:
- Confidence:
- Next action:

### F3 -- classification isolation experiment

- Status: pending
- Date and investigator:
- Commit and worktree state:
- Exact isolated variable:
- Diagnostic change:
- Behavioral verification:
- Before/after compatible measurements:
- Recovered time and percentage:
- Observation:
- H1 disposition: pending
- Uncertainty:
- Next action:

### F4 -- symbol-path isolation

- Status: pending
- Date and investigator:
- Commit range or controlled variants:
- Workload:
- Profile commands and artifact paths:
- Repeated hot functions and call paths:
- Before/after compatible measurements:
- Observation:
- Competing interpretations:
- H2 disposition: pending
- Uncertainty:
- Next action:

## Decision log

### D1 -- text-path production fix

- Status: pending
- Evidence used:
- Candidate solutions:
- Tradeoffs and correctness risks:
- Recommendation:
- Direction review:
- Selected fix:
- Behavioral verification:
- Performance verification:
- Decision and rationale:

### D2 -- symbol-path production fix or accepted tradeoff

- Status: pending
- Evidence used:
- Candidate solutions:
- Tradeoffs and correctness risks:
- Recommendation:
- Direction review:
- Selected fix or accepted tradeoff:
- Behavioral verification:
- Performance verification:
- Decision and rationale:

## Existing profile evidence

One textual profile already exists:

```text
just benchmark-sample scrollback-stream seconds=15
.build/terminal-benchmark-profiles/2026-07-23-160656-30415/sample.txt
```

The profile was captured with profiling active. It shows
`BlockElementSprite.pattern(for:)` and `PowerlineSprite.pattern(for:)` inside
`CGContextRef.drawTextRuns(_:metrics:colorSpace:)`, plus self-time samples in
the classification region. Whole-module optimization inlines much of the chain
into `drawTextRuns`, so sparse named frames cannot quantify its total cost.

This is evidence that sprite-free text executes sprite classification. It is
not enough by itself to establish a stable bottleneck or attribute the 13.8%
content-churn delta. Phase 2 requires a second profile and a controlled
unprofiled isolation experiment.

## Open questions and caveats

- The `b6c98ad` benchmark stamp does not identify the exact source state that
  produced the exploratory results because HEAD moved during the run.
- The `0698376` reference records are labelled as post-change procedural
  Braille measurements, but the implementation was committed later as
  `6d0306d`; controlled reruns must replace commit-stamp inference.
- The sprite-family series includes more than classification changes. It also
  changes Braille geometry and adds per-run collections and draw machinery.
- The full app corpus has not been rerun. The serialized redraw suite is the
  narrowest boundary containing the suspected draw bottleneck, so it remains
  the primary measurement until evidence points outside it.
- Multi-scalar cells and wide cells must preserve the existing font and grid
  behavior. An optimization may only bypass sprite work after proving that the
  cell cannot be a supported sprite.

## Outcome

Investigation in progress.
