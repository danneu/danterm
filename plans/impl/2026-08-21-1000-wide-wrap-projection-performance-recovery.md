# Recover wide-wrap projection performance

## 1. Problem and evidence

The wide-wrap projection work preserved behavior and deterministic memory use,
but introduced two decision-bearing CPU regressions. FRAME-1 is already
complete in `3bea76c5`; this plan builds on the current row-indexed frame
representation and does not reopen it.

### End-to-end result

`25997f26` versus `8710ac53`, under a valid confirm run:

| Workload | Verdict | Change | Planning |
|---|---:|---:|---:|
| `terminal-feed` | equivalent | +0.54% | n/a |
| `scrollback-stream` | slower | +7.05% | n/a |
| `content-churn` | equivalent | -0.01% | +5.55% |
| `style-churn` | equivalent | -0.55% | +6.50% |
| `incremental-mixed` | descriptive | +0.43% | +6.34% |
| `retained-browse` | slower | +1.18% | deciding metric |

`scrollback-stream` split:

- Baseline drain: 68.6 ms.
- Candidate drain: 69.0 ms.
- Baseline draw tail: 12.4 ms.
- Candidate draw tail: 17.1 ms.
- Three of four paired estimates were +6.88% through +7.72%; the required
  negative outlier remained in the estimate.
- All four `retained-browse` pairs were positive, from +0.75% through +1.67%.

The exact memory census did not move:

- Every deterministic census field was identical.
- Cell stride remained 32 bytes.
- Cell storage, retained arena use, indexes, side tables, allocation counts,
  and content/style counts were identical.
- Both normalized reports had SHA-256
  `b89e8c39288a8d90be9b0dbe583eb15a494d2072eb73b9526a64283d32cca644`.

### Commit-boundary confirm results

All runs used immutable cached arms, their frozen schedules, and reported no
invalidations.

| Boundary | Feed | Scrollback | Content draw / plan | Style draw / plan | Incremental draw / plan | Retained |
|---|---:|---:|---:|---:|---:|---:|
| `8710ac53 -> 14b664eb` | inconclusive +0.78% | equivalent +0.27% | inconclusive +0.94% / +0.16% | equivalent -0.46% / +2.71% | descriptive +1.80% / +1.22% | equivalent -0.02% |
| `3a773b0b -> ea62eb30` | equivalent +0.32% | faster -2.87% | equivalent +0.27% / +2.53% | equivalent -0.45% / +1.10% | descriptive +8.70% / +4.67% | equivalent -0.28% |
| `ea62eb30 -> 4bc9dc68` | equivalent -0.13% | slower +2.40% | equivalent -0.30% / +4.44% | equivalent -0.41% / +6.01% | descriptive +3.91% / +9.67% | equivalent +0.40% |
| `4bc9dc68 -> 8313e3e8` | inconclusive -0.87% | equivalent -0.18% | equivalent -0.46% / +0.64% | inconclusive +1.24% / -1.03% | descriptive +5.74% / +3.24% | slower +2.22% |
| `8313e3e8 -> 25997f26` | equivalent +0.34% | equivalent +0.49% | equivalent -0.33% / -0.99% | equivalent +0.52% / -0.74% | descriptive +1.03% / +1.92% | equivalent -0.74% |

Quick isolation agreed on the actionable boundaries:

| Boundary and workload | Result |
|---|---:|
| `14b664eb`, retained | equivalent -0.30% |
| `14b664eb`, scrollback | inconclusive +1.67% |
| `ea62eb30`, scrollback | inconclusive +1.93% |
| `4bc9dc68`, retained | equivalent -0.10% |
| `4bc9dc68`, scrollback | inconclusive -1.16% |
| `4bc9dc68`, content draw | equivalent -0.99% |
| `4bc9dc68`, calibrated content planning | slower +7.92% |
| `8313e3e8`, retained | slower +1.75% |
| `8313e3e8`, scrollback | faster -5.88% |
| `25997f26`, retained | faster -1.18% |
| `25997f26`, scrollback | equivalent +0.69% |

The isolated causes are therefore:

- `4bc9dc68` moved wrap-gap projection into
  `Terminal.forEachViewportRow`'s inner traversal. Style-run discovery and
  cell emission now test every column for the one possible projected margin.
  Ordinary rows also resolve their follower even when their margin provenance
  cannot project.
- `8313e3e8` added open-tail pending-margin state. Retained-browse setup and row
  admission occur before its timer, and its oldest-row viewport never reaches
  the retained/live seam. The measured regression is therefore planning
  value/layout cost, not admission or projection work.

Matched 10-second retained samples before and after `8313e3e8` contained 8,325
and 8,331 samples. They showed the same hot stack and no new pass:

| Top frame | Before | After |
|---|---:|---:|
| Main `FramePlanner` cell closure | 2,882 | 2,794 |
| Closure partial apply | 1,520 | 1,578 |
| `swift_release` | 499 | 495 |
| `withPaintedCells` | 439 | 408 |
| Viewport traversal closure | 401 | 444 |
| `initializeWithCopy for Terminal` | 59 | 61 |

Diagnostic process footprint was 7,264 KiB before and 7,360 KiB after. This is
not a deterministic memory verdict; the exact census above remains
authoritative. The samples show a small cost distributed through the existing
planner and value-witness path rather than a new algorithm.

Complete evidence is preserved under
`.build/wide-cell-wrap-gap-benchmarks/commit-isolation`.

## 2. Decision

### D1: frame planning borrows terminal state

A transient planner must not own a copied `Terminal`.

- Keep the public planning behavior and row-indexed `RenderFramePlan`
  unchanged.
- Remove `Terminal` from `FramePlanner`'s stored state. Pass it through the
  planning call as a borrow for the duration of inspection.
- Read viewport geometry, viewport top, cursor placement, selection, hover,
  and search facts once per plan. Row helpers consume those small facts instead
  of repeatedly reading the terminal or its scroll projection.
- Keep presentation and retained-frame state under their existing owners.
- Do not alter `LogicalLineStore` representation or pending-margin semantics.
  The fix removes planning's sensitivity to unrelated terminal metadata
  instead of packing or hiding that metadata.

This is the structural retained-browse fix: adding a field to terminal state
must not make every frame plan copy more terminal state.

### D2: projection is a row-boundary operation

Only a row's final column may be replaced by wrap-gap projection. Ordinary
columns must use the pre-projection fast traversal.

- Classify each visited row once as either an ordinary stored row or a row with
  a projected margin.
- An ordinary live row uses the direct stored traversal when it does not both
  continue and carry `.wideWrap` margin provenance.
- An ordinary retained row uses the direct packed-cell traversal unless it is
  the retained/live seam and the open tail has a pending margin.
- A projected row traverses the prefix before the margin through the same
  branch-free path, then emits the resolved margin once.
- Resolve the follower only for a row eligible to project.
- Preserve style-run coalescing across the prefix/margin boundary. The
  resulting `RenderPlanRow` must equal a from-scratch plan, including
  background, text, overlay, decoration, ink classification, hyperlink
  presentation, and cursor presentation.
- Keep projection inside `TerminalCore`'s concrete closure visitor. Do not
  introduce a cross-module row collection, generic iterator, or per-cell
  accessor.

This keeps one projection rule while charging its work only to rows that can
use it.

## 3. Invariants and proof obligations

- **I1 - projection identity.** Every public reader continues to observe the
  same derived spacer, stored fallback blank, style, hyperlink, and content
  identity as before this performance work.
- **I2 - frame identity.** Full and reused row-indexed plans remain equal to
  from-scratch plans for ordinary rows, live gaps, the retained/live seam, head
  restyling, and gap retirement.
- **I3 - branch-free ordinary traversal.** Ordinary rows do not resolve a
  follower and do not test each emitted column for margin projection.
- **I4 - borrowed planning.** Planning does not retain or copy a complete
  `Terminal`; adding unrelated terminal metadata cannot increase per-frame
  copy work.
- **I5 - memory identity.** Grid, history, pending-margin, style, hyperlink,
  and identity storage remain unchanged.
- **I6 - damage scope.** A follower change still damages the preceding gap row
  only when that row can project from it. No cache or projected-row lifetime is
  introduced.

Proof:

- Keep the three direct consumer regressions green:
  - `derivedWrapGapFramesMatchFromScratch`
  - `explicitLinkCrossesWideWrapGap`
  - `reconstructsDerivedWideWrapGap`
- Keep the complete render corpus proof that reused planning equals
  from-scratch planning.
- Exercise both planner entry points over:
  - an ordinary dense live viewport;
  - a live wide-wrap gap;
  - a retained viewport that does not reach the seam;
  - the retained/live seam with a head, a restyled head, and a retired gap.
- Assert only observable plans and terminal inspection results. Do not test
  helper names, branch counts, or private traversal structure.
- No new behavioral feature requires a new red unit test. The existing
  benchmark regressions are the failing acceptance proof for this
  behavior-preserving refactor.
- Run the complete `lib/TerminalCore` package tests, then `just test` with
  sandbox escalation.

## 4. Measurement and acceptance

Record the implementation starting revision before any edit.

### Commit 1: borrow terminal state during planning

- Remove the planner-owned terminal value and hoist repeated terminal-derived
  facts.
- Run
  `just benchmark-quick baseline=<commit-1-parent> workload=retained-browse`.
- The result must be `faster`. If quick is inconclusive, run confirm rather
  than rerunning quick.
- Take the same bounded retained sample used during diagnosis.
  `initializeWithCopy for Terminal` must no longer appear inside the measured
  planning loop; treat the sample as attribution, not a verdict.
- Do not land this slice if retained browsing is not directionally faster.

### Commit 2: isolate projected margins from the cell loop

- Restore the branch-free ordinary-row traversal and emit an eligible projected
  margin once.
- Run
  `just benchmark-quick baseline=<commit-2-parent> workload=content-churn`.
- The calibrated plan-time verdict must be `faster`; the draw verdict must not
  be `slower`.
- Run `just benchmark-confirm baseline=<commit-2-parent>`.
- `scrollback-stream` must be `faster`, and `retained-browse`, `terminal-feed`,
  `content-churn`, and `style-churn` must not be `slower`.
- Report the descriptive incremental draw and planning estimates without
  assigning them a verdict.

### Final regression closure

Run `just benchmark-confirm baseline=8710ac53`.

- `scrollback-stream` and `retained-browse` must no longer be `slower`.
- No calibrated workload may become `slower`.
- Report every planning estimate, including uncalibrated ones.
- Preserve any valid outlier exactly as the protocol requires.
- Rerun the deterministic memory probe. Every census field and the normalized
  SHA-256 must remain identical to the recorded baseline hash.
- Preserve comparison, profile, and memory artifacts before removing temporary
  worktrees.

## 5. Delivery constraints

### Commit progress

- [x] `refactor(renderer): borrow terminal state during frame planning`
- [x] `perf(terminal): keep wrap projection outside the ordinary cell loop`

Each commit stays green, carries any necessary behavioral test adjustment, and
records its own decision-bearing benchmark result.

### Non-goals

- Reopening FRAME-1 or changing the row-indexed frame-plan interface.
- Restoring stored `.spacerHead` cells.
- Caching projected rows or margins.
- Changing pending-margin storage, the memory budget, or cell layout.
- Recalibrating workloads or changing benchmark thresholds.
- Optimizing CoreText/CoreGraphics drawing; the measured draw verdicts remained
  equivalent.

### Rejected directions

- **Pack pending state into a sentinel or spare bit.** This attacks a layout
  symptom, constrains valid style IDs, and leaves planning coupled to terminal
  value size.
- **Cache the projected margin.** Follower writes would require another
  invalidation protocol and recreate the maintenance problem the projection
  design removed.

- **Return a row view across the SwiftPM boundary.** Per-cell access would
  become opaque cross-module dispatch or require widening private cell ABI.
- **Annotate the new path broadly with `@inlinable`.** The regression is
  unnecessary work and value ownership, not an unidentified cross-module call.
- **Merge this work with another renderer refactor.** Separate commits keep
  each recovered regression attributable.

### Implementation discretion

- Internal helper names and local code organization are free, provided the
  planner owns no terminal value and the ordinary traversal remains
  branch-free.
- The explicit Swift ownership spelling is free only if optimized profiling
  proves that no complete `Terminal` copy remains in the planning loop.

## Implementation notes

- Commit 1 confirm against `bc94ff57` made `retained-browse` faster by 4.13%.
  The same run reported `terminal-feed` equivalent (-0.25%),
  `scrollback-stream` slower (+2.29%), `content-churn` equivalent (+0.52%),
  and `style-churn` equivalent (-0.33%). The commit 2 slice owns the measured
  scrollback regression. Artifacts are under
  `.build/terminal-benchmark-comparisons/confirm/72802e8f94b1-0000`.
- The matched 10-second retained sample contained 8,325 samples and no
  `initializeWithCopy for Terminal`, outlined terminal copy, or terminal
  destroy path inside planning. The attribution artifacts are
  `.build/wide-cell-wrap-gap-benchmarks/commit-isolation/danterm-retained-borrowed-final.*`.
- Per operator direction, commit 2 used full confirm runs in place of the
  planned quick benchmark. The first confirm after moving projection to the
  row boundary left `scrollback-stream` inconclusive at +1.72%. The accepted
  slice therefore gives full ordinary live rows a direct contiguous-buffer
  traversal, omits the style snapshot when only the default style exists, and
  carries retained storage through one reference context only when the
  viewport starts in retained history.
- Commit 2 confirm against `281022fc` made `scrollback-stream` faster by 4.94%
  and `retained-browse` faster by 5.52%. It reported `terminal-feed`
  equivalent (-0.01%), `content-churn` inconclusive (+0.89%), and
  `style-churn` equivalent (+0.70%). Descriptive planning estimates improved
  by 18.06% for content churn, 16.51% for style churn, and 11.38% for
  incremental mixed; incremental draw was +2.70%. Artifacts are under
  `.build/terminal-benchmark-comparisons/confirm/1412af96580c-0000`.
- Final confirm against `8710ac53` made `retained-browse` faster by 8.29% and
  left `scrollback-stream` inconclusive at -1.83%. It reported `terminal-feed`
  equivalent (-0.05%), `content-churn` equivalent (+0.04%), and `style-churn`
  equivalent (-0.12%). Descriptive planning estimates were -9.59% for content
  churn, -8.92% for style churn, and -3.44% for incremental mixed;
  incremental draw was -0.70%. Artifacts are under
  `.build/terminal-benchmark-comparisons/confirm/1412af96580c-0001`.
- The final matched 10-second retained sample contained 6,873 planning samples
  and no `initializeWithCopy for Terminal`, outlined terminal copy, or terminal
  destroy path inside planning. The attribution artifacts are
  `.build/wide-cell-wrap-gap-benchmarks/commit-isolation/danterm-retained-commit2-final.*`.
- The final deterministic memory census kept every field unchanged and its
  normalized report matched the baseline SHA-256
  `b89e8c39288a8d90be9b0dbe583eb15a494d2072eb73b9526a64283d32cca644`.
  The raw and normalized artifacts are `.build/wide-wrap-memory-final.json`
  and `.build/wide-wrap-memory-final-normalized-pretty.json`.
- The focused projection and retained-row suites passed 29 tests. The full
  TerminalCore suite passed 1,301 tests in 143 suites with two known issues,
  and `just test` passed all 102 steps. The gate log is
  `.build/wide-wrap-just-test.log`.
