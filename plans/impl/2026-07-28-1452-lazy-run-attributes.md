# Build the per-run text attributes only when a run actually has fallback cells

Candidates **R1** and **R1b** from
[13-live-app-compositing-and-draw-hotspots.md](../../docs/research/13-live-app-compositing-and-draw-hotspots.md),
landed together per D1.

## Problem and evidence

`drawTextRuns` builds a `[NSAttributedString.Key: Any]` dictionary for **every
run**, unconditionally. It is read at exactly one place: inside
`for fallback in fallbackCells`, a loop that is empty for the overwhelming
majority of runs, because a run only produces fallback cells for multi-scalar
clusters, scalars above `UInt16.max`, or glyphs the font does not map. A
three-key heterogeneous dictionary with boxed values is built, and torn down,
per run, to be read almost never.

Adjacent and three lines away: the CGColor cache is written back on every run,
including on a cache hit, where the write stores the value already there.

Load-bearing evidence:

- **13/F2, 13/F6**: the attributes literal is the single largest node in the
  live draw path -- **18.3% of `drawTextRuns` in run 1, 19.3% in run 2** -- and
  reproduced on a byte-identical binary. It costs as much as all glyph drawing
  (`CTFontDrawGlyphs`, 17.8% / 19.0%). The cache write-back is **85 / 101
  samples**, ~0.9%.
- **13/F5**: in `benchmark-draw`'s fixture, the fraction of runs producing a
  non-empty `fallbackCells` is **zero**, and the fixture is the
  maximum-run-density case rather than a low-density one. This **inverts** the
  risk R1 was originally recorded against: the instrument is not biased against
  the change, it is biased in its favour, and D1 revised R1's prediction upward
  on the strength of it.

## Decision

Build the attributes dictionary only on the path that reads it, and write the
color cache only on a miss.

Behavioral scope: none. Every glyph that is drawn today is drawn tomorrow, with
the same font, foreground color, and ligature setting. This changes when a
value is constructed, not what any pixel is.

Decisive constraint: the dictionary's three values must be identical to today's
at the point of use, including on the run where the color cache first misses.
R1b changes when the cache is written; if it ever wrote a *different* value than
the unconditional version did, R1's dictionary would carry a wrong foreground
into the fallback path -- so the two changes interact and are measured together.

## Invariants

- **I1.** Rendered output is unchanged for runs with no fallback cells, with
  some fallback cells, and for the first run of a given foreground color (the
  cache miss).
- **I2.** A given foreground color resolves to the same `CGColor` whether it is
  reached by a cache hit or a cache miss.
- **I3.** The damage-clipped draw path stays consistent with the full-frame
  path; a run partially outside the clip is unaffected by the change.

## Proof obligations

- **PO1** (I1): a run with fallback cells renders identically before and after.
  `TextExecutionTests.unicodeClusterContainment` renders genuine fallback and
  multi-scalar content into bitmaps, while `fallbackSubstitutionIsReal`
  establishes that the unsupported-base-font case selects a usable substitute
  rather than `.notdef`.
- **PO2** (I2, regression guard): a frame drawing the same foreground color
  across several runs renders identically to one drawing it once -- pinning
  that the miss path and the hit path agree, including against a future
  refactor that makes them diverge.
- **PO3** (I3): `ExecutorContractTests.damageRedrawMatchesFullFrame` exercises
  the damage-clipped path and compares its bitmap bytes with a full-frame draw.

## Deciding the benchmark

- **Baseline acceptance:** resolve and record the pre-change revision *before*
  implementation begins; do not infer it from `HEAD` afterwards.

  Pre-change revision: **`fcfff10`**. `just benchmark-draw` (15 iterations)
  captured on it before any edit, median `drawDurationNanoseconds`:

  | Scenario | Grid | Median draw (ns) |
  | --- | --- | ---: |
  | full-frame | 80x24 | 3,812,103 |
  | damage-clipped | 80x24 | 739,177 |
  | full-frame | 160x50 | 15,700,956 |
  | damage-clipped | 160x50 | 1,366,175 |

  D1's -13% to -18% prediction is against the full-frame rows.
- **Primary instrument:** `just benchmark-draw`, run before and after. D1
  predicts full-frame **-13% to -18%**. Per 13/F5 this instrument's fixture
  produces zero fallback cells, so it measures the change's best case.
- **Secondary:** `just benchmark-quick <base> content-churn`, the render-bound
  workload where a draw win should show up if it transfers out of the harness.
- **R1b is not separately measurable.** ~0.9% is below every benchmark's
  resolution here; its verdict is joint with R1's by design. Attribution stays
  separate through the live `sample` re-post required by doc 13: after building
  the candidate, pause for the human-driven btop/down-arrow capture using doc
  13's command and provenance rules, then report R1's attributes node and R1b's
  cache-store node as distinct source-line shares.
- **Sequencing:** R4 also edits `drawTextRuns` and must not land in the same
  commit, or neither change's attribution survives.

## Non-goals

- R4's scratch buffers / `reserveCapacity` (separate commit, after this is
  measured).
- R3 and the CoreAnimation glyph-bounds thrash; explicitly gated until Phase 2
  is measured, because this change shrinks the display list that queue replays
  and would otherwise absorb R3's attribution.
- Changing which cells route to the fallback path at all.

## Accepted risks

- **AR1.** `benchmark-draw` renders into an offscreen bitmap and never creates
  the `CA::CG::Queue` that doc 13 opened on. A good number here is therefore not
  evidence the live app got smoother; it is evidence the CPU-side draw path got
  cheaper. Whether that reaches the user is a live-capture question, not a
  `benchmark-draw` question.
- **AR2.** 13/F5 means the primary instrument sees the change's most favourable
  case (zero fallback runs). Real workloads with multi-scalar clusters will see
  less. The prediction is a ceiling, and a `content-churn` result well below it
  is the expected shape, not a failure.

## Rejected ideas

- **RI1. Cache the dictionary across runs keyed by (font, color).** It reaches
  the same allocation count in the common case only if the key comparison is
  cheaper than the construction it avoids, and it adds a cache whose invalidation
  is a new invariant. Constructing lazily removes the cost outright with no new
  state.

## Implementation discretion

- Whether the dictionary is hoisted, made lazy, or built inside the fallback
  loop, provided it is not constructed on runs with no fallback cells.
- The spelling of the cache-write-on-miss.

## Implementation notes

- The dictionary is built inside an `if fallbackCells.isEmpty == false` guard
  wrapping the fallback loop, rather than a `lazy var`. Same construction site,
  no captured-closure indirection, and the guard states the precondition the
  plan's problem statement is about.
- PO2's new test (`TextExecutionTests.repeatedForegroundColorMatchesFirstUse`)
  is a regression guard, so it passes both before and after. It was
  mutation-checked against the pre-change code by making the cache-hit branch
  return a half-alpha color; it failed as expected, then the mutation was
  reverted.
- **Primary result exceeds D1's prediction.** `just benchmark-draw` (15
  iterations), median `drawDurationNanoseconds`:

  | Scenario | Grid | Baseline (ns) | After (ns) | Delta |
  | --- | --- | ---: | ---: | ---: |
  | full-frame | 80x24 | 3,688,963 | 2,439,973 | -33.9% |
  | damage-clipped | 80x24 | 710,321 | 532,790 | -25.0% |
  | full-frame | 160x50 | 14,960,141 | 10,300,003 | -31.2% |
  | damage-clipped | 160x50 | 1,313,731 | 946,960 | -27.9% |

  D1 predicted -13% to -18% on the full-frame rows; the measured full-frame win
  is roughly double the ceiling. Because that overshoot is large enough to
  suspect drift in the recorded baseline, the pre-change revision `fcfff10` was
  re-benchmarked in a throwaway worktree in the same session; the table's
  baseline column is that same-session re-measurement, not the number recorded
  in "Deciding the benchmark" (which read 3,812,103 / 739,177 / 15,700,956 /
  1,366,175 -- within run-to-run variance of the re-measurement, and giving
  -36.0% / -27.9% / -34.4% / -30.7%). Both baselines agree the win is well past
  the prediction.
- **Secondary result:** `just benchmark-quick fcfff10 content-churn` reports
  `faster (-4.36% symmetric median of 2 pairs)`, with plan time inconclusive
  (+1.08%). This is the shape AR2 predicts: the draw win is real but diluted by
  the rest of the workload.

## Follow Up

- The live `sample` re-post that doc 13 requires is still outstanding: it is a
  human-driven btop/down-arrow capture, so it could not run here. Until it
  lands, R1's attributes node and R1b's cache-store node have no post-change
  source-line shares, and doc 13 cannot record this candidate's live verdict.
- `docs/research/13-live-app-compositing-and-draw-hotspots.md` still carries R1
  and R1b as open candidates; recording the result belongs with the live capture
  above, not with this commit.
- R4 (scratch buffers / `reserveCapacity` in `drawTextRuns`) is now unblocked --
  it was sequenced after this measurement, per "Sequencing".
