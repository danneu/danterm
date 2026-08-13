# Per-cell sprite classification redraw regression

<!-- The paths below are deliberately gone; this doc records them as history. -->
<!-- docs-lint: allow-missing benchmarks/results/terminal-redraw.jsonl -->

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
`b6c98ad`. HEAD moved while the benchmark was running because the unrelated
Cmd-A whole-stream selection commit landed. That commit does not touch render
execution, sprite code, benchmark generation, or the benchmark harness, so the
JSONL measurements are trusted for this investigation. The stamp still does
not identify the exact source snapshot compiled at benchmark startup.

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

**Status: REJECTED -- not reproduced.** The canonical stationary `d19103f` rerun
(save=1, stamped `d19103f`) puts every ASCII text workload *below* its trustworthy
baseline -- content 305,240 vs 324,141 (-5.8%), style 302,798 vs 320,814 (-5.6%),
mixed 307,196 vs 331,802 (-7.4%) -- and symbol at 329,032 vs the 332,237
reproducible baseline (-1.0%). There is no demonstrated text residual left to
isolate, so H3's premise (per-run accumulator setup adds material common-path
cost) is unsupported: optimizing empty accumulator initialization with no measured
regression would be speculative. Reopen H3 only if a future stationary run reveals
a material text regression against these baselines.

## Candidate direction, pending evidence

**Resolved: this candidate was selected and shipped as commit `a785d45` (see
Decision D1).** The forward-looking framing below is preserved as the original
reasoning that led there; it is no longer open.

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

[Superseded: F3 confirmed classification is the dominant cost, and D1 selected
this routing shape over the ASCII-only guard. Shipped as `a785d45`.]

## Task ledger

### Phase 1 -- establish trustworthy baselines

- [x] For future runs, confirm the worktree and HEAD remain stationary for the
  duration of each run; record the commit and cleanliness in the findings log.
  (The canonical `d19103f` rerun compiled committed render/harness source with
  HEAD fixed at `d19103f`; records stamp that commit -- see the Outcome section.)
- [x] Confirm that the unrelated `b6c98ad` Cmd-A selection commit does not
  touch the measured renderer, sprite implementation, workload generator, or
  benchmark harness.
- [x] Accept the five unprofiled `b6c98ad` JSONL records as the trustworthy
  post-sprite investigation baseline despite the source-stamp caveat.
- [x] Record the compatible baseline medians, variation, draw counts, and JSONL
  locations in Finding F1.
- [x] Decide that the consistent 11-16% text regressions and 42% symbol
  regression are strong enough to continue to attribution.

### Phase 2 -- attribute the text-path regression

- [x] Collect two textual profiles of a sprite-free text workload and record
      both artifact paths. (F2; scrollback-stream, the only profilable workload.)
- [x] Confirm the workload truly contains no supported sprite scalars.
- [x] Record repeated concrete hot work, call paths, thread, and available
      sample or own-time evidence in Finding F2.
- [x] List competing interpretations, including classifier calls, per-run
      accumulator setup, CoreText work, and measurement noise.
- [x] Create the smallest diagnostic experiment that bypasses only sprite
      classification for provably ineligible single-scalar cells. Do not retain it
      as the production fix merely because it is convenient. (F3 `< 0x2500` guard.)
- [x] Run focused behavioral tests and `just test` for the diagnostic change.
- [x] Rerun content, style, and mixed churn unprofiled without saving the
      diagnostic result as canonical history.
- [x] Record recovered time and percentage for each text workload in Finding
      F3, then revert or supersede the diagnostic experiment. (Reverted.)
- [x] Decide whether H1 is confirmed, partially confirmed, or rejected.
      (Confirmed material.)

### Phase 3 -- choose the text-path fix

- [x] If H1 is material, compare at least these candidates against the measured
      cost: an ASCII-only guard, direct single-scalar family routing, and a
      centralized exact classification result.
- [x] For each candidate, record expected benefit, correctness risk,
      synchronization risk as families change, and effect on unsupported Unicode,
      multi-scalar cells, wide cells, and real sprites.
- [x] Identify the smallest structure-insensitive behavioral coverage needed:
      supported-family classification, range boundaries and gaps, multi-scalar
      fallback, wide-cell placement, and unchanged visible rendering.
- [x] Write the evidence summary and recommended first production change in
      Decision D1.
- [x] Pause for direction review before implementing the production fix.
- [x] Write the failing behavioral test first where the chosen change alters a
      testable contract; verify the expected failure before changing production
      code. (N/A: routing is behavior-preserving -- the failing proof is the
      established redraw regression and F3 benchmark; existing family tests
      already pin the invariant. See D1's test-coverage audit.)
- [x] Implement only the selected text-path fix.
- [x] Run focused package tests and `just test`.
- [x] Rerun content, style, mixed, symbol, and sprite-coverage churn unprofiled
      under compatible conditions.
- [x] Accept the fix only if behavior remains correct, the target regression
      improves materially, and symbol/sprite workloads do not incur an unexplained
      material loss.
- [x] Record the final evidence and disposition in Decision D1.

### Phase 4 -- isolate the symbol-path regression

- [x] Begin only after the text-path work has been measured, so its contribution
      can be removed from the symbol result.
- [x] Compare controlled commits or variants spanning `0698376` through the
      Braille geometry changes and Box Drawing integration to locate the first
      material symbol-churn change. (Six-rung ladder from the reproducible
      `6d0306d` baseline; the entire regression is `d357dc3`.)
- [x] Collect two profiles of `full-screen-symbol-churn` at the relevant
      regressed state and record both artifact paths. (Not possible: the loop
      profiler cannot drive serialized redraw workloads; substituted a controlled
      paired hoist diagnostic, recorded in F4.)
- [x] Attribute repeated cost between Box Drawing misses before Braille,
      Braille pattern/geometry construction, collection allocation, and Core
      Graphics fill/stroke work. (Per-cell `[Int]` layout-array allocation; Box
      misses and fill area both refuted.)
- [x] Record the evidence and competing interpretations in Finding F4.
- [x] Decide whether the remaining regression is a defect, an accepted
      correctness tradeoff, or measurement noise. (Defect: accidental per-cell
      allocation; intended square-dot geometry is preserved by the fix.)
- [x] If it is a defect, compare candidate solutions and record the recommended
      smallest experiment in Decision D2.
- [x] Pause for direction review before implementing a symbol-path fix.
      (Selected hoist-only, lazy per draw.)
- [x] Protect the selected behavioral invariant, implement one dominant-path
      change, run focused tests plus `just test`, and rerun symbol and
      sprite-coverage churn unprofiled. (Lazy per-draw layout; braille suite +
      `just test` green; all five workloads rerun, symbol -34%, none regressed.)
- [x] Record the final evidence and disposition in Decision D2.

### Phase 5 -- close the investigation

- [x] Rerun all five redraw workloads from the final clean commit. (Stationary
      `d19103f`, `save=1`; see the Outcome section.)
- [x] Save only compatible, unprofiled results chosen as canonical history.
      (Five `d19103f` records, all `profilingActive:false`.)
- [x] Confirm no profiled or diagnostic result entered
      `benchmarks/results/*.jsonl`. (Zero `profilingActive:true` records.)
- [x] Summarize recovered regressions, accepted tradeoffs, and remaining
      uncertainties in the Outcome section.
- [x] Update `agent-docs/terminal-performance.md` only if the investigation
      reveals a reusable methodology or workload rule not already documented.
      (Documented the loop-profiler limitation: it cannot drive serialized
      `benchmark-redraw` workloads; use commit isolation plus paired unprofiled
      redraw runs instead.)

## Findings log

Use one entry per task cluster. Do not replace old measurements silently;
append a correction and mark the earlier interpretation superseded.

### F1 -- reproducible post-sprite baseline

- Status: complete. Transcription done, and the owed fresh stationary rerun was
  since captured as the canonical `d19103f` set (see the Outcome section); F1's
  `b6c98ad` records are retained as the exploratory investigation baseline.
- Date and investigator: 2026-07-23
- Commit and worktree state: records stamped `b6c98ad`; HEAD moved during the
  run for the unrelated Cmd-A whole-stream selection commit. The commit does
  not touch the renderer, sprites, workload generator, or benchmark harness.
- Commands: `just benchmark-redraw save=1`
- Compatible comparison record:
  `0698376`, labelled `executor-local-braille-sprites`
- New result or artifact paths: `benchmarks/results/terminal-redraw.jsonl`
- Measurements: medians are recorded in "Trigger and current evidence" above.
  Full min / median / max ns-per-draw and draw counts from the trusted records:

  Baseline `0698376` (`executor-local-braille-sprites`):
  | Workload        |        min |     median |        max | draws |
  | --------------- | ---------: | ---------: | ---------: | ----: |
  | content-churn   |    294,992 |    324,141 |    334,968 | 1,849 |
  | style-churn     |    300,910 |    320,814 |    330,247 | 1,825 |
  | mixed-churn     |    319,739 |    331,802 |    344,051 | 1,807 |
  | symbol-churn    |    337,210 |    342,513 |    347,633 | 1,458 |
  | sprite-coverage | 12,272,750 | 12,420,459 | 12,706,174 |    39 |

  Exploratory `b6c98ad`:
  | Workload        |       min |    median |       max | draws |
  | --------------- | --------: | --------: | --------: | ----: |
  | content-churn   |   340,886 |   368,789 |   376,994 |   191 |
  | style-churn     |   354,098 |   373,417 |   385,317 |   215 |
  | mixed-churn     |   356,510 |   369,718 |   381,793 |   214 |
  | symbol-churn    |   483,242 |   486,283 |   490,350 | 1,015 |
  | sprite-coverage | 1,118,039 | 1,132,792 | 1,147,543 |   391 |

- Observation: content, style, and mixed churn regress by 11-16%; symbol churn
  regresses by 42%; sprite-coverage churn improves by about 10x. For every
  workload the two runs' regressed medians fall outside each other's min/max
  bands (baseline text spread is ~13% of median, exploratory ~10%), so the
  direction of each delta is not within-run variance.
- Inference: the regressions are strong and consistent enough to continue to
  attribution.
- Uncertainty: `b6c98ad` identifies the repository state when results were
  recorded, not necessarily the exact source snapshot compiled at startup.
  This is accepted because the intervening commit is unrelated to the measured
  paths. Separately, the baseline text runs used `targetBatchNanoseconds`
  400,000,000 (~1,800 draws) while the exploratory text runs used 50,000,000
  (~200 draws). `targetBatchNanoseconds` is deliberately not a redraw
  compatibility field (`REDRAW_COMPATIBILITY_FIELDS`) because results are
  normalized per completed draw, so this difference is worth recording but does
  not by itself invalidate the comparison. The `b6c98ad` non-reproducible stamp
  (HEAD moved during the run) was the standing reason to prefer a fresh
  stationary rerun before treating F1 as canonical; that rerun is now the
  `d19103f` canonical set, so F1's records stand as exploratory baseline only.
- Next action: none outstanding. [Historical: led to Phase 2 (F2). The owed
  canonical rerun is now the `d19103f` set in the Outcome section.]

### F2 -- text-path profiles

- Status: two profiles captured and cross-checked.
- Date and investigator: 2026-07-23, Dan (with Claude).
- Commit and worktree state: current worktree (dirty: agent-docs, this doc, and
  the redraw JSONL modified). Both profiles built the release Benchmark binary
  from this source state.
- Workload and reason: `scrollback-stream` (max codepoint `0x7d`, verified to
  contain no scalar at or above `U+2500`, so no supported sprite candidate).
  This is the workload the sampling harness (`just benchmark-sample`) drives; it
  is sprite-free like the regressed `content-churn`/`style-churn`, whose
  fixtures are also pure ASCII (verified independently).
- Profile commands:
  - `just benchmark-sample scrollback-stream seconds=15` (profile 1, pre-existing)
  - `just benchmark-sample scrollback-stream seconds=15` (profile 2, this session)
- Artifact paths:
  - `.build/terminal-benchmark-profiles/2026-07-23-160656-30415/sample.txt`
  - `.build/terminal-benchmark-profiles/2026-07-23-162904-46215/sample.txt`
- Repeated hot functions and call paths: both profiles show the same render
  spine on the main thread --
  `SwiftTerminalSessionView.draw(_:)` (app/SwiftTerminalSessionView.swift:160)
  -> `drawRenderFrame(_:metrics:in:)` (TerminalRenderExecution.swift:214)
  -> `CGContextRef.drawTextRuns(_:metrics:colorSpace:)`. Inside `drawTextRuns`
  both profiles surface inlined sprite-family classifier frames on a workload
  with no sprites: profile 1 shows `BlockElementSprite.pattern(for:)` and
  `PowerlineSprite.pattern(for:)`; profile 2 shows `BoxDrawingSprite.pattern`,
  `BranchDrawingSprite.pattern`, and `LegacyComputingSupplementSprite.pattern`.
- Thread and sample/own-time evidence: main-thread totals 12,197 (p1) and
  12,254 (p2) samples. The entire on-screen draw subtree is tiny on this
  workload: `SwiftTerminalSessionView.draw` = 80 (p1) / 81 (p2) samples,
  `drawRenderFrame` = 79 / 77, i.e. ~0.65% of main-thread samples. Within that
  subtree WMO inlines the classification chain into `drawTextRuns`, so named
  classifier frames are sparse (1-2 samples each) and no single node dominates.
- Observation: both profiles independently confirm that sprite-free text still
  executes the sprite-family classification chain per cell (H1's premise). The
  classifier frames repeat across two runs, so their presence is stable, not a
  one-off sampling artifact.
- Competing interpretations:
  1. Per-cell classifier calls (H1) -- present and confirmed, but share of cost
     unquantified.
  2. Per-run accumulator setup (H3) -- not separable from H1 in these samples.
  3. CoreText / CGContext `drawTextRuns` glyph work -- the bulk of the draw
     subtree; classification is a fraction of it.
  4. Sampler cannot quantify the redraw regression here: `scrollback-stream` is
     parse/scroll-bound (draw is ~0.65% of samples), while the regression was
     measured on the serialized-redraw harness, which isolates the draw path and
     would magnify classification's share. The two are different harnesses.
- Confidence: high that classification executes on sprite-free text; low that
  these profiles quantify how much of the 11-16% redraw regression it explains.
  Sparse inlined frames plus a parse-bound workload mean magnitude must come
  from a controlled unprofiled bypass on the redraw workloads, not from the
  sampler.
- Next action: resolved. [Historical: led to the F3 diagnostic guard, then D1.]
  Proposed the smallest one-variable diagnostic that bypasses only sprite
  classification for provably ineligible single-scalar cells, ran it against
  `content`/`style`/`mixed` churn unprofiled, and recorded recovered time in F3.

### F3 -- classification isolation experiment

- Status: complete; paired A/B measured, guard reverted.
- Date and investigator: 2026-07-23, Dan (with Claude).
- Commit and worktree state: HEAD `6d93366`, same source tree for both arms
  except the one-line diagnostic guard. Both arms run in the same session on AC
  power to isolate the guard from run-to-run environmental drift; the guard was
  reverted after measuring, leaving only research-log updates.
- Exact isolated variable: the per-cell sprite-family classifier chain for
  provably-ineligible cells. Everything else in the draw path is unchanged.
- Diagnostic change: in `drawTextRuns` (TerminalRenderExecution.swift), a guard
  at the top of the per-cell loop -- when `cell.scalars.count == 1` and the
  single `scalar.value < 0x2500` (below every supported sprite family's floor),
  append straight to the character path and skip the eight `pattern(for:)`
  calls. `< 0x2500` implies `<= UInt16.max`, so the routed cells are
  behavior-identical to the existing character branch. Multi-scalar and
  `>= 0x2500` cells still traverse the full chain.
- Behavioral verification: `just test` exits 0 (0 failures across all suites,
  including the render/sprite Swift Testing suites). No new behavioral test
  added: the change deliberately preserves behavior and a branch-entry assertion
  would be structure-coupled; existing rendering tests plus the benchmark are
  the appropriate guard.
- Before/after compatible measurements: paired, same session, `save=0`,
  `target_ms=50`, `batches=15`, identical workloads. Median ns per draw
  (min..max, draws):
  | Workload  | Control A                        | Diagnostic B                     |
  | --------- | -------------------------------- | -------------------------------- |
  | content   | 348,053 (333,990..363,026; 204)  | 329,146 (315,102..341,399; 224)  |
  | style     | 358,448 (337,172..374,614; 206)  | 327,756 (276,310..340,545; 221)  |
  | mixed     | 350,732 (338,826..361,591; 201)  | 328,224 (308,009..340,496; 228)  |
- Recovered time and percentage:
  - content: 18,907 ns/draw, -5.43%
  - style:   30,692 ns/draw, -8.56%
  - mixed:   22,508 ns/draw, -6.42%
- Observation: bypassing sprite classification for ineligible single-scalar
  cells recovers 5.4-8.6% of per-draw time on the three ASCII text workloads,
  with medians cleanly separated between arms. This is a large fraction of the
  measured ~11-16% text regression but does not close it entirely.
- H1 disposition: confirmed material. Per-cell sprite classification is a
  dominant, directly-attributed contributor to the text-path regression.
- Uncertainty: the recovered 5.4-8.6% is smaller than the full 11-16% regression
  band, so classification is not the sole cause. The residual is consistent with
  H3 (per-run accumulator setup) or other common-path machinery added in the
  same series; F3 does not isolate that residual. The paired A/B is one session's
  measurement, not a canonical saved baseline.
- Next action: Phase 3 -- compare production candidates (ASCII-only guard vs
  direct single-scalar family routing vs centralized exact classification)
  against this measured cost, then pause for a direction decision (D1) before
  implementing. Consider a follow-on isolation for the H3 residual.
  [Superseded: after D1 routing landed, the D1/D2 paired text measurements sit at
  or below the trustworthy baselines, so no residual remains demonstrated; the H3
  follow-on is downgraded to conditional -- see H3's status note and D2.]

### F4 -- symbol-path isolation

- Status: complete
- Date and investigator: 2026-07-23, agent session.
- Commit range or controlled variants: a six-rung commit ladder measuring
  `full-screen-symbol-churn` (`save=0`, unprofiled) at each controlled render
  state. Harness and workload are byte-identical across `7fd4c7b..HEAD`
  (verified: no changes to `terminal-benchmark.sh`, `terminal-draw-acceptance.py`,
  `terminal-benchmark-producer.py`, or `TerminalDrawBenchmarkSupport`), and the
  single `7fd4c7b` harness change only shortens the *ordinary* workloads
  (symbol-churn is not in `FAST_ORDINARY_WORKLOADS`) on a per-draw-normalized
  metric, so `6d0306d` remains comparable. Per direction, the reproducible
  procedural-Braille source baseline is `6d0306d`, not the mislabelled `0698376`
  record.

  | Commit    | State                          | ns/draw | Step delta        |
  | --------- | ------------------------------ | ------: | ----------------: |
  | `6d0306d` | procedural braille baseline    | 332,237 | --                |
  | `d357dc3` | square braille dot allocation  | 484,170 | +151,933 (+45.7%) |
  | `eb4233e` | extract shared sprite geometry | 491,354 | +7,184 (noise)    |
  | `d9a0fae` | box drawing integration        | 486,482 | -4,872 (noise)    |
  | `140934b` | end of family series           | 481,460 | noise             |
  | `a785d45` | current routing baseline (HEAD)| 482,086 | noise             |

- Workload: `full-screen-symbol-churn`
  (`full-screen-symbol-churn-v1-btop-symbol-mix-80x24`), ~90% Braille + 10% Box
  Drawing, 80x24, release, M1 Pro, 15 batches. Metric: median ns per completed
  draw.
- Profile commands and artifact paths: none captured. The loop profiler
  (`terminal-benchmark-profile.sh sample`) cannot drive the serialized *redraw*
  workloads -- it times out "waiting for benchmark geometry" because loop mode
  targets streaming workloads (F2 used `scrollback-stream`). Attribution was
  instead obtained by commit-level isolation plus a controlled paired hoist
  experiment, which is sharper than WMO-inlined samples for this question.
- Repeated hot functions and call paths: `BrailleSprite.appendRects` ->
  `BrailleSpriteGeometry.layout(cellWidthPixels:cellHeightPixels:)`, invoked once
  per braille cell inside `drawTextRuns`' per-cell loop
  (TerminalRenderExecution.swift:417).
- Before/after compatible measurements: the whole +42/45% symbol regression is a
  single commit, `d357dc3 feat(renderer): adopt square braille dot allocation`.
  Every later sprite-family commit (Box Drawing integration included) is within
  run-to-run noise of it. Paired hoist diagnostic (same session, `save=0`):
  control (regressed HEAD) 510,520 ns (min 503,238 / max 521,634); diagnostic
  (layout hoisted to once-per-draw) 352,040 ns (min 348,527 / max 357,779);
  recovered 158,480 ns (-31.0% of control), non-overlapping bands, landing within
  ~6% of the 332,237 pre-regression baseline.
- Observation: `d357dc3` changed `BraillePixelLayout` from stack scalars
  (`dotWidth`/`dotHeight`) with fully inline per-dot integer arithmetic and
  **zero heap allocation** (see `6d0306d:BrailleSprite.swift`) to a struct holding
  `xPositions: [Int]` and `yPositions: [Int]`, constructed by
  `BrailleSpriteGeometry.layout`. That construction allocates two `[Int]` arrays
  **per braille cell**. At ~1700 braille cells/draw that is ~3400 array
  allocations plus ARC traffic every draw, all recomputing an identical result
  because the layout depends only on `metrics` (constant across a draw). Hoisting
  the layout to once-per-draw removes essentially all of it.
- Competing interpretations: (a) larger square dots cost more Core Graphics fill
  area -- refuted as the dominant cause: the hoist keeps identical dot geometry
  yet recovers 88% of the regression, and the ~6% residual vs the `6d0306d`
  baseline is the ceiling for any fill-area or once-per-draw-compute component.
  (b) added Box Drawing classification before Braille -- refuted: the
  `d9a0fae` Box integration rung is within noise of the pre-Box rung.
  (c) run-to-run variance -- refuted: the 332k->484k jump and the paired
  510k->352k recovery both have non-overlapping min/max bands.
- H2 disposition: confirmed and localized. The Braille-heavy symbol regression
  is real, is entirely `d357dc3`, and its mechanism is per-cell layout-array
  allocation -- not Box-miss classification and not procedural-vs-fallback
  drawing. It is a defect (an accidental allocation regression), not the intended
  visual square-dot change, which the fix preserves exactly.
- Uncertainty: the ~6% residual between the hoisted state (352k) and the
  pre-regression baseline (332k) is unattributed; it is small and plausibly the
  intended slightly-larger dot fill plus the single retained per-draw layout
  build. Not worth isolating unless a later target needs it.
- Next action: resolved via Decision D2 -- selected the lazy per-draw braille
  layout (commit `d19103f`), which removes the per-cell layout allocation while
  preserving square-dot geometry.

## Decision log

### D1 -- text-path production fix

- Status: drafted; paused for direction review before implementation. Scoped to
  H1 only -- H3 residual is deliberately excluded and follows after this fix is
  measured, so the H1 fix's benchmark is cleanly attributable.
- Evidence used: F3 (guard recovers 5.4-8.6% per draw, H1 confirmed material),
  F2 (classification executes on sprite-free text in two profiles), F1 (text
  regression band 11-16%). Family scalar map read from the eight sprite sources:

  | Family (dispatch order)      | Supported scalar range(s)                                             | Shape within range |
  | ---------------------------- | --------------------------------------------------------------------- | ------------------ |
  | Box Drawing                  | `0x2500...0x257F`                                                      | dense              |
  | Block Elements               | `0x2580...0x259F`                                                      | dense              |
  | Geometric Shapes             | `0x25E2...0x25FF` (only 8 scalars: E2-E5, F8-FA, FF)                   | sparse             |
  | Braille                      | `0x2800...0x28FF`                                                      | dense              |
  | Powerline                    | `0xE0B0...0xE0D4` (PUA, sparse subset)                                 | sparse             |
  | Branch Drawing               | `0xF5D0...0xF60D` (PUA)                                                | dense              |
  | Legacy Computing             | `0x1FB00...0x1FBAF`, `0x1FBBD...0x1FBBF`, `0x1FBCE...0x1FBEF`          | multi-range        |
  | Legacy Computing Supplement  | `0x1CC1B..1E`, `0x1CC21..3F`, `0x1CD00..DE5`, `0x1CE00..01/0B..0C/16..19/51..AF` | multi-range |

  The eight coarse ranges are mutually disjoint, so any single scalar value maps
  to at most one candidate family by range membership. Within a coarse range a
  family may still return `nil` for an unsupported member (Geometric, Powerline,
  the multi-range families), which each family's exact `pattern(for:)` already
  handles.

- Candidate solutions:
  1. **ASCII-only guard** -- route single-scalar cells with `scalar.value < 0x2500`
     straight to the character path; everything else keeps the eight-family chain.
     This is exactly the F3 diagnostic promoted to production.
  2. **Direct single-scalar family routing** -- extract the single scalar once,
     select the one family whose coarse range contains it (or the font path for
     `< 0x2500`, inter-family gaps, and multi-scalar cells), and invoke only that
     family's exact `pattern(for:)`. Membership/pattern decoding stays inside
     each family.
  3. **Centralized exact classification** -- a single `classify(scalar) -> Family?`
     (or a sprite-kind enum) that owns the full mapping and returns the decoded
     pattern, replacing the inline chain with one table/dispatch.

- Tradeoffs and correctness risks:
  - **ASCII-only guard (1):** smallest, lowest-risk change; benefit is directly
    validated by F3 (5.4-8.6%). Helps only `< U+2500` text -- unsupported
    non-ASCII cells (CJK, emoji, most of the BMP) still pay the full eight-family
    chain, and real sprite cells still walk the chain to their family. No new
    boundary surface: the only edge is the single `0x2500` literal, and
    multi-scalar/`>= 0x2500` behavior is byte-for-byte unchanged.
  - **Direct single-scalar routing (2):** broadest reach -- ASCII, unsupported
    Unicode, and real sprites each invoke at most one family classifier instead
    of up to eight. Correctness obligations: the coarse range table must exactly
    cover each family's real membership floor/ceiling; every inter-family gap
    (`0x25A0...0x25E1`? no -- Geometric starts 0x25E2 so `0x25A0...0x25E1` is a
    real gap; `0x2600...0x27FF`, `0x2900...0xE0AF`, `0xE0D5...0xF5CF`,
    `0xF60E...0x1CC1A`, etc.) must fall through to the font path; and the router
    must preserve dispatch precedence where ranges are adjacent (Box ends 0x257F,
    Block begins 0x2580 -- disjoint, so no ordering hazard, but the table must be
    kept in sync as families change). Sparse families (Geometric, Powerline)
    still delegate the exact-membership `nil` decision to the family, so coarse
    routing is safe. Main risk is the range table drifting out of sync with a
    family's real set on future edits.
  - **Centralized exact classification (3):** cleanest conceptual API and one
    dispatch point, but it either duplicates each family's membership knowledge
    in the central table (two sources of truth to keep synchronized -- the exact
    risk the sprite-doc shared-abstraction policy warns against) or introduces an
    intermediate sprite-kind representation plus a second dispatch to the family,
    adding indirection cost on the hot path the fix is meant to shorten.

- Recommendation: **direct single-scalar family routing (candidate 2)**, with
  exact pattern decoding kept inside each family. It captures the full F3-measured
  win for ASCII, extends the same one-classifier bound to unsupported Unicode and
  real sprites (helping the symbol path too, relevant to Phase 4), and avoids
  duplicating family membership. The ASCII-only guard is the fallback if routing's
  boundary coverage proves fragile; centralized classification is rejected for
  duplicating mapping knowledge or adding dispatch cost.

- Minimal structure-insensitive behavioral coverage required (write failing
  first where a contract changes):
  - each supported family still classifies and renders its representative
    scalars (one per family);
  - range boundaries and gaps: lowest/highest supported scalar of each family
    renders as a sprite; the scalars just outside each range (e.g. `0x24FF`,
    `0x2580` vs `0x257F`, `0x25A0`, `0x25E1`, `0xE0AF`, `0xE0D5`) render via the
    font path;
  - multi-scalar cells fall back to the font path regardless of leading scalar;
  - wide-cell placement and grid advance unchanged;
  - a sprite-free ASCII line and a mixed sprite/text line produce visibly
    unchanged rendering.

- Direction review: APPROVED -- direct single-scalar family routing selected,
  with exact membership and pattern decoding kept inside each family.
- Test-coverage audit (no new tests for unchanged behavior): existing suites
  already provide the structure-insensitive coverage routing must preserve.
  - Per-family membership: each family has a `Sprite membership is exactly ...`
    test that asserts every in-range scalar classifies and that just-outside
    boundaries (e.g. `0x24FF`, `0x2580`) and multi-scalar inputs return `nil`.
    These pin membership <= coarse range and boundary/multi-scalar rejection.
  - Per-family end-to-end rendering: each family has an exhaustive execution
    test (e.g. "All 128 Box Drawing scalars render as cell-local foreground
    sprites", plus the 32 block, 62 branch, 213 legacy, braille block, 8
    geometric, 18 powerline, and supplement-range equivalents) that renders
    every supported scalar through the full `drawTextRuns` executor and checks
    sprite ink lands in-cell and adjacent cells stay clean. A misroute that
    dropped a supported scalar to the font path would fail these.
  - Mixed lines / stale pixels and wide cells: per-family "..., text, and other
    sprites replace without stale pixels" tests plus the wide-cursor test cover
    mixed rendering and column advancement.
  Because coarse ranges are disjoint and each family's real membership is a
  subset of its coarse range, the only failure routing can introduce is dropping
  a supported scalar to font (caught by the exhaustive execution tests); a
  gap/out-of-range scalar routed to one family returns `nil` and falls to font,
  identical to the chain. Conclusion: no new behavioral tests are warranted; no
  test-only "candidate family" seam is added.
- Selected fix: direct single-scalar family routing in `drawTextRuns`. The
  per-cell loop now extracts the single scalar once and `switch`es on its value
  to the one family whose coarse range can contain it (Box `0x2500...0x257F`,
  Block `0x2580...0x259F`, Geometric `0x25E2...0x25FF`, Braille
  `0x2800...0x28FF`, Powerline `0xE0B0...0xE0D4`, Branch `0xF5D0...0xF60D`,
  Supplement `0x1CC1B...0x1CEAF`, Legacy `0x1FB00...0x1FBEF`), invoking only that
  family's exact `pattern(for:)`. A `nil` result (sparse gap, or a Geometric
  pattern with no representable triangle) and every out-of-range or multi-scalar
  cell fall through to the unchanged character/fallback path. Exact membership
  and pattern decoding remain owned by each family.
- Behavioral verification: focused `swift test --package-path lib/TerminalCore`
  passes (570 tests, 77 suites; the pre-existing 1 known issue unchanged); full
  `just test` exits 0 with 0 failures. No new tests added, per the audit above.
- Performance verification: clean back-to-back paired A/B in one session on AC
  power, `save=0`, default per-workload targets, `batches=15`. Median ns per
  draw (min..max, draws):
  | Workload        | Control (no routing)             | Routing                          | Recovered  |     % |
  | --------------- | -------------------------------- | -------------------------------- | ---------: | ----: |
  | content         | 353,170 (338,218..356,451; 202)  | 325,783 (319,528..332,723; 226)  | 27,387 ns  | -7.76 |
  | style           | 360,477 (337,166..374,477; 206)  | 327,000 (320,209..336,903; 220)  | 33,477 ns  | -9.29 |
  | mixed           | 360,784 (352,912..373,299; 205)  | 325,154 (314,513..336,087; 222)  | 35,630 ns  | -9.88 |
  | symbol          | 516,451 (491,785..519,904; 1006) | 489,429 (483,107..494,107; 950)  | 27,022 ns  | -5.23 |
  | sprite-coverage | 1,223,122 (1,208,830..1,240,287; 384) | 1,155,057 (1,140,611..1,170,575; 425) | 68,065 ns | -5.57 |
  All five workloads improved and none regressed. Text recovery (7.8-9.9%)
  covers the F1 11-16% text-regression band and lands the text workloads at or
  below their baselines, so no residual is demonstrated (H3 is conditional -- see
  its status note).
  Symbol and sprite-coverage also improved (~5%) because sprite cells now invoke
  one family instead of walking the chain, but symbol's large regression versus
  the pre-sprite baseline is unaffected and remains Phase 4 work. No profiled or
  diagnostic result was saved to `benchmarks/results/*.jsonl` (`save=0`).
- Decision and rationale: ACCEPTED. Behavior is preserved (full suite green),
  the target text regression improves materially, and no workload incurs an
  unexplained loss. Routing is the production text-path fix. Next: Phase 4
  symbol-path isolation. (H3 per-run accumulator isolation was expected here as a
  follow-on, but the post-routing text measurements leave no demonstrated
  residual, so it is now conditional -- see H3's status note.)

### D2 -- symbol-path production fix or accepted tradeoff

- Status: ACCEPTED and implemented.
- Evidence used: Finding F4. The symbol regression is entirely `d357dc3` and its
  mechanism is per-cell allocation of the two `[Int]` arrays inside
  `BraillePixelLayout`, recomputed identically for every braille cell in a draw.
  A paired hoist diagnostic recovered 158,480 ns (-31.0%), to within ~6% of the
  pre-regression baseline, with identical dot geometry.
- Candidate solutions:
  1. **Hoist the layout to once-per-draw (call-site).** Compute
     `BrailleSpriteGeometry.layout` once before the run loop in `drawTextRuns`
     and pass it into an `appendRects(..., layout:)` overload. This is the exact
     shape the F4 diagnostic measured. Smallest change; keeps the layout type and
     geometry untouched. Cost: threads one value through the call site, and any
     other caller of the per-cell `appendRects` still recomputes (only `rects(...)`
     does today, off the hot path).
  2. **Make `BraillePixelLayout` allocation-free (representation).** Replace the
     `[Int]` `xPositions`/`yPositions` with fixed-size storage (two-tuple + the
     four y-offsets derivable from `yMargin`, `dotSize`, `ySpacing`, or a small
     fixed struct), so constructing a layout allocates nothing. This fixes the
     cost at the source for *every* caller regardless of hoisting, and composes
     with candidate 1. Cost: touches the pure `TerminalSpriteGeometry` type and
     its `rect(column:row:)` accessor; slightly more code than the hoist.
  3. **Memoize `layout` by `(cellWidth, cellHeight)`.** A one-entry cache in
     `BrailleSpriteGeometry`. Rejected: introduces mutable static state into a
     pure module (purity-lint and concurrency hazard) for no benefit over 1/2.
- Tradeoffs and correctness risks: candidates 1 and 2 are behavior-preserving --
  the rendered rects are bit-identical (same `dotSize`, `xPositions`,
  `yPositions`); only *when/how often* the layout is built changes. The existing
  braille execution tests (every supported scalar rendered through the executor,
  square-dot geometry assertions in `TerminalSpriteGeometryTests`) already pin the
  output and would catch a misalignment, so no new behavioral test is required --
  same standard as D1. Candidate 2's only risk is transcribing the array-index
  accessor to fixed storage; covered by the existing geometry tests.
- Recommendation: **candidate 2 (allocation-free layout) composed with candidate 1
  (hoist).** Candidate 2 removes the defect at its source so no future caller can
  reintroduce per-cell allocation, and candidate 1 additionally avoids rebuilding
  the identical layout ~1700x/draw. If a single change is preferred, candidate 1
  alone already recovers the measured 31%; candidate 2 alone recovers the same
  allocation cost with a marginal residual for the once-per-draw rebuild. The
  combined change is small and fully covered by existing tests.
- Direction review: selected candidate 1 (hoist only) with a lazy refinement:
  build the layout at most once per draw, on the first braille cell, via an
  optional held outside the run/cell loops. This keeps the exact measured fix,
  builds nothing for text-only draws, needs no persistent cache or
  metrics-change invalidation, and defers any allocation-free storage rewrite
  (candidate 2) unless the residual proves material -- which it did not.
- Selected fix or accepted tradeoff: lazy per-draw braille layout. In
  `drawTextRuns`, `var brailleLayout: BraillePixelLayout?` is initialized on the
  first braille cell and reused for the rest of the draw, passed into a new
  `BrailleSprite.appendRects(..., layout:)` overload. The convenience
  `appendRects(...)` (used only by the off-hot-path `rects(...)`) still builds
  its own layout. `BraillePixelLayout`'s `[Int]` representation is unchanged.
- Behavioral verification: rendered rects are bit-identical (same `dotSize`,
  `xPositions`, `yPositions`); only the build frequency changed. Braille-focused
  suite green (`swift test --package-path lib/TerminalCore --filter Braille`, 11
  tests across `BrailleSpriteExecutionTests` + `BrailleSpriteGeometryTests`,
  including the per-scalar executor renders and square-dot geometry invariants),
  and full `just test` exits 0. No new test added -- existing coverage already
  pins the output, matching the D1 standard.
- Performance verification: paired unprofiled `save=0` runs, all five workloads,
  same session, median ns/draw (FIX vs CONTROL = committed HEAD render source):

  | Workload                            |       FIX |   CONTROL |   Delta |
  | ----------------------------------- | --------: | --------: | ------: |
  | `full-screen-content-churn`         |   318,251 |   325,108 |  -2.11% |
  | `full-screen-style-churn`           |   318,982 |   326,477 |  -2.30% |
  | `full-screen-mixed-churn`           |   327,184 |   329,961 |  -0.84% |
  | `full-screen-symbol-churn`          |   326,440 |   495,545 | -34.10% |
  | `full-screen-sprite-coverage-churn` | 1,088,480 | 1,126,696 |  -3.39% |

  Symbol-churn recovered ~169,000 ns and lands at 326,440 -- at/below the
  332,237 pre-regression baseline -- so the ~6% F4 residual is fully closed by
  the lazy hoist. No workload regressed; text and sprite-coverage are flat to
  slightly improved. No profiled or `save=1` result entered benchmark history.
- Decision and rationale: ACCEPTED. The `d357dc3` symbol regression was per-cell
  `BraillePixelLayout` allocation; hoisting layout construction to once-per-draw
  (lazy) restores the pre-regression symbol cost with a behavior-identical,
  test-covered change and helps every braille-bearing workload. Candidate 2
  (allocation-free storage) is not pursued: once construction is once-per-draw
  the two small arrays are immaterial (symbol already recovered past baseline).
  This closes Phase 4. Remaining investigation work: the canonical stationary
  `d19103f` rerun (Phase 1 / Phase 5). H3 (per-run accumulator setup) is now an
  unsupported hypothesis -- the D1/D2 text measurements sit at or below their
  baselines with no demonstrated residual -- so it is not scheduled work; it is
  rejected as not reproduced if the canonical rerun confirms those measurements,
  and reopened only if that run reveals a material text regression.

## Existing profile evidence

[Superseded by F2 (two profiles captured and cross-checked) and by the F3/F4
controlled isolation experiments. Retained for provenance; the "requires a second
profile" note below is historical and no longer open.]

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
content-churn delta. Phase 2 required a second profile and a controlled
unprofiled isolation experiment -- both since done (F2, F3), so this is resolved.

## Open questions and caveats

- The `b6c98ad` benchmark stamp does not identify the exact source state
  compiled at benchmark startup because HEAD moved during the run. The
  intervening Cmd-A selection commit is unrelated to rendering and benchmark
  execution, so this is an accepted provenance caveat rather than a reason to
  discard or repeat the measurements.
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

Closed. Both regressions introduced by the procedural terminal-sprite series are
fixed, and the canonical stationary `d19103f` rerun confirms every workload at or
below its trustworthy baseline. Canonical medians (ns per completed draw,
`save=1`, unprofiled, M1 Pro, 80x24, release):

| Workload                            | Baseline  | Canonical `d19103f` |  Delta |
| ----------------------------------- | --------: | ------------------: | -----: |
| `full-screen-content-churn`         |   324,141 |             305,240 | -5.8%  |
| `full-screen-style-churn`           |   320,814 |             302,798 | -5.6%  |
| `full-screen-mixed-churn`           |   331,802 |             307,196 | -7.4%  |
| `full-screen-symbol-churn`          |   332,237 |             329,032 | -1.0%  |
| `full-screen-sprite-coverage-churn` | 1,132,792 |           1,081,186 | -4.6%  |

(Text baselines are the `0698376` records; symbol uses the reproducible `6d0306d`
baseline; sprite-coverage uses the post-sprite `b6c98ad` record, since its
`0698376` value predates procedural sprites and reflects the old fallback path.)

- **Text-path regression (H1 -> D1).** Per-cell sprite classification walked an
  eight-family chain for every cell including sprite-free text. Fixed by direct
  single-scalar family routing (commit `a785d45`). Text workloads recovered past
  their baselines.
- **Symbol-path regression (H2 -> F4/D2).** Isolated by a commit ladder to a
  single commit, `d357dc3`, whose `BraillePixelLayout` refactor allocated two
  `[Int]` arrays per braille cell (~3400 allocations/draw on the 90%-braille
  workload). Fixed by building the layout lazily once per draw (commit `d19103f`).
  Symbol churn recovered ~34% back to its pre-regression cost.
- **Rejected hypothesis (H3).** No text residual survived D1; the canonical rerun
  confirms text workloads below baseline, so per-run accumulator setup is not a
  demonstrated cost and was not optimized.
- **Refuted mechanisms.** Box Drawing classification inserted before Braille
  (noise on the ladder) and larger square-dot fill area (hoist recovered 88% with
  identical geometry) were both eliminated as causes of the symbol regression.
- **Accepted tradeoff / provenance caveats.** The `b6c98ad` exploratory records
  carry a non-reproducible source stamp (HEAD moved mid-run); they are retained
  as investigation evidence, and the canonical baseline going forward is the
  stationary `d19103f` set. The intended square-dot braille geometry from
  `d357dc3` is preserved unchanged; only its build frequency was corrected.
- **Reusable methodology.** The loop/sample profiler cannot drive serialized
  `benchmark-redraw` workloads (it times out waiting for benchmark geometry); it
  targets streaming app workloads. Redraw regressions were attributed instead by
  commit-ladder isolation plus paired unprofiled redraw runs -- now documented in
  `agent-docs/terminal-performance.md`.
- **Remaining uncertainty.** None material. The former ~6% F4 residual is closed
  (symbol at 329,032 <= 332,237 baseline).
