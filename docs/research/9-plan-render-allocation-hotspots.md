# Plan and render allocation hotspots

Research started: 2026-07-27.

## Purpose

This file owns the investigation into per-cell and per-draw allocation on
DanTerm's frame-planning and frame-drawing paths, opened by a diagnostic sample
profile of the two full-screen churn workloads. It exists because the profile
named a small number of concrete, repeated allocations -- not a diffuse "render
is slow" -- and those are testable one at a time.

The evidence boundary it must preserve: everything here is **diagnostic sample
profiling**, collected with `DANTERM_BENCHMARK_PROFILING=1` active. No number in
this file is a benchmark result, and none of them may be quoted as one. A
directional performance claim requires a paired `just benchmark-quick` /
`benchmark-confirm` run against an explicitly named pre-change revision, per
[agent-docs/terminal-performance.md](../../agent-docs/terminal-performance.md).

## Investigation rules

- **Sample shares are attribution, not timings.** Report them as a percentage of
  a named inclusive subtree (plan, draw, or non-idle main thread) and always
  name the profile artifact they came from.
- **Every change re-posts the plan and render call trees.** After each candidate
  lands in the working tree, collect a fresh `full-screen-content-churn` and a
  fresh `full-screen-incremental-mixed-churn` sample, and append the same
  planFrame / drawRenderFrame trees to the corresponding finding. A change is
  not verified by the aggregate percentage moving; it is verified by the
  targeted node shrinking *and* by nothing else in the tree inflating to absorb
  the work. Post the tree even when the result is disappointing -- a change that
  moved allocation from one node to another is exactly the outcome that only the
  tree can show.
- **Two profiles minimum before a stack is treated as stable**, per the doc's
  standing rule. The content-churn baseline below already satisfies this; each
  post-change capture must too.
- **Plan-time claims and draw claims are decided separately.** The three
  serialized-draw verdicts bracket only `draw(_:)`; `planFrame` runs on the
  PTY-output path and is invisible to them. `content-churn` and `style-churn`
  carry a calibrated plan-time rule at 2 pairs; `incremental-mixed` reports plan
  time with no verdict and must not borrow one.
- **No implementation before the open direction gate is answered.** That gate is
  now D2; D1 was answered and then superseded by F6.

## Trigger and current evidence

Four diagnostic sample profiles collected 2026-07-27 at commit
`6c58c45d7ee416d9cc36268b8ea65ae28d3f5583`, working tree clean except for
untracked `notes.md`, `docs/research/9-*.md`, and `plans/wip/*` files that do not
enter any build.

| Artifact | Workload | Duration |
| --- | --- | --- |
| `.build/terminal-benchmark-profiles/2026-07-27-212440-75867/sample.txt` | `full-screen-content-churn` | 20s |
| `.build/terminal-benchmark-profiles/2026-07-27-212643-77552/sample.txt` | `full-screen-content-churn` (repeat) | 20s |
| `.build/terminal-benchmark-profiles/2026-07-27-212718-78428/sample.txt` | `full-screen-incremental-mixed-churn` | 20s |
| `.build/terminal-benchmark-profiles/2026-07-27-214736-86434/sample.txt` | `full-screen-incremental-mixed-churn` (repeat) | 20s |

Commands:

```
just benchmark-sample full-screen-content-churn seconds=20
just benchmark-sample full-screen-incremental-mixed-churn seconds=20
```

`.build/` is disposable, so the artifact paths are pointers only; the
decision-bearing numbers are transcribed into F1-F3 below.

Main-thread attribution on content-churn: 6088 non-idle samples out of 15995,
split **plan 35.4% / draw 27.7% / `TerminalBenchmarkObserver` 7.6%**. The
observer figure is 2.9% of wall thread time, consistent with the 3.3% the
performance doc records as its healthy state -- the instrument is in spec and is
not distorting these trees. `Terminal.feed` (4310 samples) sits entirely on the
`com.danneu.danterm.terminal-pty-host` queue and is off this path.

## Current hypotheses

### H1 -- the plan path is allocator-bound on a per-cell array that is almost always one element

`Terminal.cell(row:column:)` returns a fresh `TerminalCell` whose `scalars` is
built with `Array(cell.scalars)` (`Terminal.swift:2836`), while the underlying
grid storage is already a three-case enum (`.empty` / `.single` / `.spill`,
`Terminal.swift:117`). For a single-scalar cell -- the overwhelming majority --
that is a heap allocation for a one-element array. At 179x66 that is up to
11,814 allocations per full-viewport plan.

Corrected by F6: this originally read "read once and destroyed", which is wrong.
The array is retained through `PlannedCell` into the public `RenderTextCell` and
lives as long as the frame plan. The count stands; the lifetime does not, and
the difference is what invalidated candidate B.

Supporting evidence: F1 puts `Terminal.cell` at 40% of plan inclusive, of which
`Array.init<A>` is 24 points and its `_ContiguousArrayBuffer` /
`swift_allocObject` / `malloc_size` descendants account for essentially all of
that; the matching `outlined destroy of TerminalCell?` is a further 11%.

Competing explanation: the cost is the `TerminalCell` value copy generally
(style, hyperlink, kind), not the scalar array specifically. Distinguished by
the sub-tree -- the allocation descendants sit under `Array.init<A>`, not under
the struct copy -- but a candidate that removes only the array and moves the
number very little would confirm the competing reading instead.

Confirmed if a change that eliminates the single-scalar allocation collapses the
`Array.init<A>` subtree without inflating a sibling.

### H2 -- plan carries a fixed whole-viewport cost that damage scoping does not reach

`FramePlanner.plan(reusing:damage:)` opens with `let geometry = terminal.geometry`
(`RenderFramePlanner.swift:151`), and the getter maps every presented row into a
freshly allocated `[TerminalCellGeometry]` (`Terminal.swift:2807`) before the
per-row reuse check at `RenderFramePlanner.swift:173` ever runs. Row reuse
therefore skips `inspectedCells` for undamaged rows but never skips geometry
construction.

Supporting evidence: F2 measures `Terminal.geometry.getter` at 0.6-0.9% of plan
on content-churn (where 66 rows are replanned anyway, so it is dwarfed) but
27.8% and 19.5% on the two incremental-mixed profiles (where ~6 rows are
damaged), where it is the second-largest plan node in both. This is a concrete
mechanism for the performance doc's standing observation that per-draw plan cost
"barely moves when damage shrinks from 66 rows to 6".

Competing explanation: the incremental-mixed plan subtree is small in absolute
terms (209 and 221 samples), so the share is noisy. The repeat capture bounds
that -- the two runs disagree by 8 points, so the magnitude is a range around
one fifth to one quarter of plan, not a single figure -- but does not overturn
the direction. The doc independently records incremental plan time as the
jittery quantity, which is why the magnitude here is still not load-bearing.

### H3 -- the draw path rebuilds per-draw font and glyph state that is constant across draws

`drawTextRuns` constructs four `CTFont` objects on every call
(`TerminalRenderExecution.swift:344-348` via `metrics.font(bold:italic:)`, which
calls `CTFontCreateWithName` plus `CTFontCreateCopyWithSymbolicTraits`), and
maps characters to glyphs through `CTFontGetGlyphsForCharacters` per run with no
cache, landing in the font's format-4 cmap binary search.

Supporting evidence: F3 puts font construction at 5% of draw on content-churn
but 19.5% on incremental-mixed -- the signature of a fixed per-draw cost -- and
`CTFontGetGlyphsForCharacters` at 11% of draw with
`TFormat4UTF16cmapTable::MapT` alone at 7.4%.

## Candidate direction, pending evidence

**Superseded by F6 and D2; retained as the record of what was proposed and
why.** B cannot collapse the targeted node, and A is no longer reachable as a
separate second step. Provisional as originally written. H1 is the largest single node and the cheapest to test, so the
proposed sequence is a narrow experiment that can only confirm or reject H1,
followed by the wider change that H1 would license.

### B (first) -- a planner-facing non-allocating cell accessor

Add an accessor that hands cells to the planner without materializing a
`TerminalCell` per cell -- e.g. `forEachCell(row:_:)` filling a caller-owned
buffer, or a `withScalars`-style borrow -- and change `inspectedCells`
(`RenderFramePlanner.swift:291-292`) to use it. `cell(row:column:)` stays exactly
as it is for every other caller.

Why first: it is the smallest thing that can distinguish H1 from its competing
explanation. One new accessor, one call site, no public type change, and the
existing planner behavior is unchanged by construction. If the plan tree's
`Array.init<A>` subtree does not collapse, H1 is wrong and A must not be
attempted.

Cost if it succeeds and stops there: two cell-access paths coexist, one of them
allocation-free and one not, which is a real maintenance liability and the
reason B is framed as a step toward A rather than a destination.

### A (second, gated on B) -- give `TerminalCell` a non-allocating scalar representation

Change `TerminalCell.scalars` so the single-scalar case never touches the heap,
mirroring the enum the grid already stores internally, and then retire the
duplicate path B introduced. This is the version that also removes the
allocation for every non-planner consumer.

Why second: `TerminalCell.scalars` is public and consumers index it directly --
`drawTextRuns` tests `cell.scalars.count == 1` and reads `cell.scalars.first`
(`TerminalRenderExecution.swift:394`) to route sprite classification -- so the
blast radius spans the render-execution module and any test that constructs a
cell. That is worth paying once H1 is confirmed and worth nothing if it is not.

Both are pitched as sequence, not as alternatives: B is the experiment, A is the
change the experiment licenses.

## Task ledger

### Phase 1 -- establish evidence

- [x] Collect two `full-screen-content-churn` samples and one
      `full-screen-incremental-mixed-churn` sample; record plan and draw trees.
      Recorded in F1, F2, F3.
- [x] Repeat the `full-screen-incremental-mixed-churn` capture once so H2 rests
      on two profiles rather than one. Record the second geometry-getter share
      in F2 and state whether the 27.8% figure held. Recorded in F2 (and the
      draw side in F3): it did **not** hold as a figure -- run 2 reads 19.5% --
      but the getter is the second-largest plan node in both runs, so H2's
      direction holds and its magnitude is now stated as a range.

### Phase 2 -- direction gate

- [x] Answer D1: accept, revise, or reject the B-then-A sequence. Begin no
      implementation before this is recorded. Acceptance criterion for opening
      Phase 3 is an explicit selected direction in D1. Answered 2026-07-27:
      accepted unchanged, B then A. Phase 3 is open.

### Phase 3 -- implement and verify the D2 change

Opened, blocked on D2 before any code, then unblocked by D2 selecting E. The
tasks below describe E rather than B; they are otherwise unchanged, and the
re-post rule is now the only gate between the change and F4's verdict.

- [x] Note the pre-change revision explicitly; it is the paired baseline. Do not
      infer it from `HEAD` after committing. **Pre-change baseline:
      `6c58c45d7ee416d9cc36268b8ea65ae28d3f5583`**, the commit all four profiles
      in F1-F3 were taken at.
- [x] Record a selected direction in D2 before writing code. Answered
      2026-07-27: **E**, one inline scalar type across `TerminalCell`,
      `PlannedCell`, and `RenderTextCell`.
- [x] Audit existing planner test coverage and record the audit in D2's
      behavioral-verification field. Done; it found four coverage gaps and one
      implementation constraint (element-wise `==`). Cover the behavior the change must
      preserve -- empty, single-scalar, multi-scalar/combining, and wide-pair
      cells plan to the same runs -- and record explicitly if existing tests
      already suffice rather than adding a structure-coupled test.
- [x] Implement the D2-selected change. Run `just test` and the targeted
      TerminalCore suites. Done: `TerminalScalars` replaces `[Unicode.Scalar]`
      in `TerminalCell`, `PlannedCell`, and `RenderTextCell`, and absorbs the
      grid's private `GridCellScalars`. `just test` exits 0 (618 core tests; the
      one known issue is pre-existing and declared). Only 6 assertion sites
      needed rewriting -- `ExpressibleByArrayLiteral` absorbed the rest of the
      ~93 the audit flagged. Four new tests cover the audit's gaps: the type's
      content-based equality, an oversized cluster surviving the plan, the
      no-empty-payload invariant (added to `assertCanonical`, so it now holds
      corpus-wide), and a second-family multi-scalar sprite negative.
- [x] **Re-post the call trees.** Done in F4. The `Array.init<A>` subtree is
      absent, not merely reduced. One sibling did inflate -- `textRuns` by ~110
      samples -- and F4 identifies the mechanism and states the net.
- [x] Decide H1 in F4: **confirmed**, and confirmed against its competing
      explanation, with the caveat that ~20% of the saving is handed back at
      `textRuns` and the residual `TerminalCell` teardown was never recoverable.
- [x] Run the paired comparison D2 specifies against baseline `6c58c45` and read
      the **plan-time line**, not the draw verdict. Recorded in F4:
      `quick` / `content-churn` gives **plan time -46.86%, faster**, on the
      calibrated 2-pair rule; `confirm` adds `terminal-feed` faster -14.55% and
      `scrollback-stream` faster -23.66%. Measured on battery under the F7
      override -- read the caveat with the numbers.

### Phase 4 -- dissolved

- [x] Reassess once D2 is answered. D2 selected E, so the experiment/licensed-
      change split is gone and Phase 4 folded into Phase 3. Nothing is carried
      forward; F5 is retired unpopulated.

### Phase 5 -- remaining hotspots, unscheduled

- [ ] H2 (whole-viewport geometry construction per plan). The second incremental
      profile is in; H2 is evidenced and unblocked, still unscheduled. The
      blocker to confront first is scoring, not evidence -- see the open question
      on `incremental-mixed` having no calibrated plan-time verdict.
- [ ] H3 (per-draw font construction; no glyph cache). Two separable changes;
      both live in the region the draw verdict can actually see.
- [ ] Unreserved array growth in `drawTextRuns` (F3, 14% of draw). Cheapest of
      the three but also the one most likely to be absorbed by allocator noise.

## Findings log

### F1 -- plan time is dominated by a per-cell scalar-array allocation

- Status: recorded, stable across two profiles.
- Date and investigator: 2026-07-27, Claude (agent), at the user's request.
- Commit and worktree state: `6c58c45`, clean but for untracked `notes.md` and
  `plans/wip/*`.
- Commands: `just benchmark-sample full-screen-content-churn seconds=20`, twice.
- Artifacts: `.build/terminal-benchmark-profiles/2026-07-27-212440-75867/sample.txt`,
  `.build/terminal-benchmark-profiles/2026-07-27-212643-77552/sample.txt`.
- Measurements -- planFrame inclusive tree, run 1 (2154 samples inclusive):

  ```
  planFrame                                            2154  100%
  └─ FramePlanner.plan(reusing:damage:)                2143   99%
     ├─ inspectedCells(row:geometry:cursorSpan:)       1394   65%   RenderFramePlanner.swift:291
     │  ├─ Terminal.cell(row:column:)                   871   40%   Terminal.swift:2836
     │  │  ├─ Array.init<A>(_:)                         521   24%
     │  │  │  └─ _ContiguousArrayBuffer.init(_uninit…)  436   20%
     │  │  │     ├─ swift_allocObject                   224   10%
     │  │  │     └─ malloc_size                         162    8%
     │  │  └─ Terminal.viewportStreamRow(at:)            66    3%
     │  └─ outlined destroy of TerminalCell?            234   11%
     ├─ textRuns(row:cells:)                            266   12%
     ├─ decorationRuns(row:cells:)                      252   12%
     └─ ARC teardown of retained row arrays              84    4%
  ```

- Repeatability across the two content-churn runs, as share of plan inclusive:

  | Node | Run 1 | Run 2 |
  | --- | ---: | ---: |
  | `inspectedCells` | 64.7% | 65.9% |
  | `Terminal.cell(row:column:)` | 40.4% | 39.7% |
  | `textRuns` | 12.3% | 13.2% |
  | `decorationRuns` | 11.7% | 11.0% |
  | `backgroundRuns` | 1.3% | 1.4% |

- Observation: two thirds of plan time is `inspectedCells`, and the largest
  single node beneath it is the `TerminalCell` materialization, whose cost is
  overwhelmingly allocation and deallocation rather than field copying.
- Inference: supports H1. The grid already knows the cell is one scalar; the
  planner throws that knowledge away and pays malloc for it, per cell, per frame.
- Competing interpretations: the `Terminal.cell` cost could be the whole struct
  copy rather than the array; the subtree attribution argues against that but
  only a change settles it. Separately, `sample` attributes malloc call cost
  accurately but cannot say whether the allocator is contended or merely called
  too often -- a Time Profiler trace would separate those if B underdelivers.
- Uncertainty: low on the attribution, moderate on how much of the 40% is
  actually recoverable, since some `PlannedCell` construction remains either way.
- Next action: D1, then Phase 3.

### F2 -- plan carries a whole-viewport geometry cost that row reuse does not skip

- Status: recorded, stable in direction across two incremental profiles; the
  magnitude is a range, not a figure.
- Date and investigator: 2026-07-27, Claude (agent).
- Commit and worktree state: as F1.
- Commands: `just benchmark-sample full-screen-incremental-mixed-churn seconds=20`,
  twice.
- Artifacts: `.build/terminal-benchmark-profiles/2026-07-27-212718-78428/sample.txt`,
  `.build/terminal-benchmark-profiles/2026-07-27-214736-86434/sample.txt`.
- Measurements -- `Terminal.geometry.getter` as share of plan inclusive:

  | Workload | Share of plan | Plan subtree size |
  | --- | ---: | ---: |
  | content-churn run 1 | 0.9% | 2154 samples |
  | content-churn run 2 | 0.6% | 2142 samples |
  | incremental-mixed run 1 | 27.8% | 209 samples |
  | incremental-mixed run 2 | 19.5% | 221 samples |

  incremental-mixed plan tree, run 1:

  ```
  planFrame                                             206  98.6%
  └─ FramePlanner.plan(reusing:damage:)                 206  98.6%
     ├─ inspectedCells                                   94  45.0%
     │  └─ Terminal.cell(row:column:)                    62  29.7%
     │     └─ Array.init<A>(_:)                          36  17.2%
     ├─ Terminal.geometry.getter                         58  27.8%   Terminal.swift:2807
     ├─ textRuns                                         19   9.1%
     └─ decorationRuns                                   10   4.8%
  ```

  incremental-mixed plan tree, run 2 (221 samples inclusive):

  ```
  planFrame                                             221  100%
  └─ FramePlanner.plan(reusing:damage:)                 220  99.5%
     ├─ inspectedCells(row:geometry:cursorSpan:)         97  43.9%   RenderFramePlanner.swift:291
     │  ├─ Terminal.cell(row:column:)                    67  30.3%   Terminal.swift:2836
     │  │  └─ Array.init<A>(_:)                          40  18.1%
     │  │     └─ _ContiguousArrayBuffer.init(_uninit…)   33  14.9%
     │  │        ├─ swift_allocObject                    16   7.2%
     │  │        └─ malloc_size                          17   7.7%
     │  └─ outlined destroy of TerminalCell?             13   5.9%
     ├─ Terminal.geometry.getter                         43  19.5%   RenderFramePlanner.swift:151
     │                                                                -> Terminal.swift:2807
     ├─ textRuns                                         21   9.5%
     ├─ decorationRuns                                   20   9.0%
     └─ backgroundRuns                                    3   1.4%
  ```

- Repeatability across the two incremental runs, as share of plan inclusive:

  | Node | Run 1 | Run 2 |
  | --- | ---: | ---: |
  | `inspectedCells` | 45.0% | 43.9% |
  | `Terminal.cell(row:column:)` | 29.7% | 30.3% |
  | `Array.init<A>` | 17.2% | 18.1% |
  | `Terminal.geometry.getter` | 27.8% | 19.5% |
  | `textRuns` | 9.1% | 9.5% |
  | `decorationRuns` | 4.8% | 9.0% |

- Observation: the geometry getter is invisible when all 66 rows are replanned
  and is the second-largest plan node in both runs when only ~6 rows are damaged.
  It is also the least repeatable node in the tree: every other node moves by at
  most a point or two between the runs, while geometry moves 8 points and
  `decorationRuns` doubles off a small base.
- Inference: supports H2. It is a fixed cost paid before the per-row reuse check,
  so damage scoping cannot reach it. Note that F1's per-cell allocation is still
  the largest node here too -- H1 and H2 are additive, not competing. Also note
  the run-2 line attribution: the getter is charged to
  `RenderFramePlanner.swift:151`, the `let geometry = terminal.geometry` binding,
  which is 22 lines above the per-row reuse check at line 173. The mechanism is
  visible in the profile's own line numbers, not only in the source reading.
- Competing interpretations: ~215 samples is a small subtree and the performance
  doc independently records incremental plan time as the jittery quantity. The
  repeat bounds rather than removes that: two runs of the same workload at the
  same commit disagree by 8 points on this one node, so the honest statement is
  "roughly a fifth to a quarter of plan", and any H2 change must be scored on a
  re-posted tree rather than on beating 27.8%.
- Uncertainty: low on direction, moderate on magnitude. Two profiles.
- Next action: H2 remains Phase 5 and unscheduled; it is not gating D1. Before
  acting on it, confront the open question below -- `incremental-mixed` is the
  workload where H2 shows and the one with no calibrated plan-time verdict.

### F3 -- the draw path rebuilds fonts per draw and re-maps glyphs per run

- Status: recorded, stable across four profiles.
- Date and investigator: 2026-07-27, Claude (agent).
- Commit and worktree state: as F1.
- Artifacts: all three profiles above.
- Measurements -- drawRenderFrame inclusive tree, content-churn run 1
  (1688 samples inclusive):

  ```
  drawRenderFrame                                      1688  100%   TerminalRenderExecution.swift:226
  └─ CGContextRef.drawTextRuns(_:metrics:colorSpace:)  1569   93%
     ├─ CTFontDrawGlyphs                                227   13%
     ├─ CTFontGetGlyphsForCharacters                    185   11%   -> cmap MapT<UTF16> 125
     ├─ _ArrayBuffer._consumeAndCreateNew               235   14%
     ├─ ARC release/dealloc of run arrays               132    8%
     └─ CTFontCreateWithName + CopyWithSymbolicTraits    86    5%
  ```

- Share of draw inclusive across all four profiles (incremental 2 added
  2026-07-27 from artifact `…-214736-86434`, draw subtree 330 samples):

  | Node | content 1 | content 2 | incremental 1 | incremental 2 |
  | --- | ---: | ---: | ---: | ---: |
  | `CTFontCreateCopyWithSymbolicTraits` | 3.3% | 3.9% | 19.5% | 20.3% |
  | `CTFontCreateWithName` | 1.8% | 2.1% | 4.6% | 5.5% |
  | `CTFontGetGlyphsForCharacters` | 11.0% | 10.2% | 12.6% | 9.4% |
  | `CTFontDrawGlyphs` | 13.4% | 12.4% | 9.5% | 9.1% |
  | `_ArrayBuffer._consumeAndCreateNew` | 13.9% | 12.4% | 11.3% | 11.5% |

  The draw side repeats far more tightly than the plan side did: every node
  lands within 3 points of its incremental-1 value, and the font-construction
  signature (~20% + ~5% on incremental against ~4% + ~2% on content) reproduces
  cleanly. F3's status as stable now rests on four profiles, not two.

- Observation: font construction scales as a fixed per-draw cost -- small when a
  draw does a lot of glyph work, dominant when it does little. Glyph mapping is
  re-done every frame for characters that do not change.
- Inference: supports H3. Both are caching problems, and the font one penalizes
  precisely the small incremental draws that should be cheapest.
- Competing interpretations: CoreText may already cache internally, in which case
  the observed cost is the wrapper and the retain traffic rather than real font
  construction; the presence of `TFont::TFont` and
  `TDescriptor::CreateMatchingDescriptor` in the subtree argues that real
  construction is happening.
- Uncertainty: low on attribution, unknown on how much a cache recovers.
- Next action: Phase 5; not scheduled ahead of H1.

### F6 -- the per-cell array is retained into the frame plan, so B as specified cannot collapse it

- Status: recorded. Structural finding from source reading, corroborated by the
  F1/F2 trees. No new profile; none is needed to establish it.
- Date and investigator: 2026-07-27, Claude (agent), while opening Phase 3.
- Commit and worktree state: as F1.
- Measurement: none. This is a type-level fact about where the allocation ends
  up, established by following the value.
- Observation: the array allocated by `Array(cell.scalars)`
  (`Terminal.swift:2836`) is not consumed and dropped at the planner boundary.
  It is retained, unchanged and uncopied, through the entire plan:

  ```
  Terminal.cell            Array(cell.scalars)         <- the malloc F1 measures
    -> TerminalCell.scalars       [Unicode.Scalar]     TerminalGeometry.swift:68
    -> PlannedCell.scalars        [Unicode.Scalar]     RenderFramePlanner.swift:64, :322
    -> RenderTextCell.scalars     [Unicode.Scalar]     TerminalRenderPlanning.swift:229, :416
  ```

  Each hop is an array assignment, which is a retain, not a copy. The buffer
  allocated per non-empty cell therefore lives as long as the `PlannedFrame`
  that quotes it, and is released with the frame.
- Corroboration in the existing trees: `Array.init<A>` appears *only* beneath
  `Terminal.cell` in both F1 and F2. If any downstream hop copied the payload,
  a second `Array.init<A>` would appear under `textRuns`; what appears there
  instead is `_ArrayBuffer._consumeAndCreateNew` (the run's own cell list
  growing) and `outlined init with copy of PlannedCell` (retains). Empty and
  padding cells cost nothing here either way -- `Array(.empty)` yields the empty
  singleton and does not call malloc -- so the measured allocations correspond
  one-to-one with the non-empty cells that reach a text run.
- Inference: **H1's count is right and its mechanism statement is wrong.** There
  is one heap allocation per non-empty cell per plan, as H1 says. But H1
  describes it as "a heap allocation for a one-element array read once and
  destroyed", and it is not destroyed at the planner boundary -- it is the
  representation the plan output itself carries.
- Consequence for D1: **B as specified cannot work.** A non-allocating accessor
  feeding `inspectedCells` removes the allocation from `Terminal.cell` and
  immediately re-incurs it when `PlannedCell`/`RenderTextCell` are built, because
  both store `[Unicode.Scalar]`. The predicted result of implementing B verbatim
  is the exact outcome the investigation rules single out: the targeted node
  collapses and a sibling inflates to absorb it, netting ~zero. That would not
  reject H1; it would only re-measure this finding at the cost of a full
  implement-and-profile cycle.
- Competing interpretations: none identified for the retention chain itself --
  it is directly readable in the types. The open question is whether any
  *other* consumer of `TerminalCell` copies rather than retains, which would not
  change the conclusion but would widen it.
- Uncertainty: low. This is source-level, not statistical.
- Next action: revise D1 before implementing anything. See D2.

### F7 -- the AC-power gate was enforced on one workload out of five

- Status: recorded, and acted on. Behavior change to the benchmark harness.
- Date and investigator: 2026-07-27, Claude (agent), at the user's direction.
- Observation: `benchmark-confirm` refused to decide on battery, naming only
  `terminal-feed` blocks. Reading
  `scripts/terminal-benchmark-validation.py`, the AC-power check existed in
  exactly one place -- the `terminal-feed` collector -- while the four render
  collectors check thermal state and low-power mode but never power source. The
  prose in [agent-docs/terminal-performance.md](../../agent-docs/terminal-performance.md)
  lists battery power among the conditions that invalidate a block, so the doc
  and the code disagreed, and the code was the narrower of the two: four of the
  five workloads already accepted battery runs.
- Change made: the check is now opt-in-overridable via
  `DANTERM_BENCHMARK_ALLOW_BATTERY=1`, which suppresses only the
  `not-on-ac-power` reason. `power-source-changed`, `low-power-mode`, and
  `thermal-pressure-*` still invalidate, so the non-stationary cases -- the ones
  interleaving genuinely cannot cancel -- remain hard failures. The per-block
  `machineStateSamples` already record `powerSource`, so any run made under the
  override is self-documenting in its `run.json`.
- Why this is defensible: the schedule is position-balanced, so a steady
  slowdown applies to both arms and the symmetric median stays unbiased.
- Why it is still opt-in rather than removed: the decision thresholds are
  calibrated for AC, per the performance doc's own statement that changing the
  measurement conditions requires recalibrating before directional claims
  resume. Battery widens the distribution those fixed thresholds are compared
  against, which degrades `equivalent` and `inconclusive` verdicts specifically.
  Making it explicit keeps that cost visible at the call site instead of
  silently lowering the bar for every future run.
- Open item, not addressed here: the harness has an A/A calibration mode that
  reports the cheapest pair count and threshold clearing the gates. Running it on
  battery would establish whether the frozen thresholds are still appropriate
  under the override, and until that is done, battery `inconclusive` results
  should not be read as evidence of equivalence.
- Next action: none required for Phase 3. Flagged for whoever next touches the
  decision rules.

### F4 -- post-change verification: H1 confirmed, with partial absorption

- Status: complete. Tree evidence decisive and paired benchmark recorded. The
  trees below are sample attribution; the benchmark verdicts at the end of the
  finding are the only performance claims, and they carry a battery caveat.
- Date and investigator: 2026-07-27, Claude (agent).
- Change measured: D2's option E in the working tree -- `TerminalScalars`
  replacing `[Unicode.Scalar]` in `TerminalCell`, `PlannedCell`, and
  `RenderTextCell`, and replacing the grid's private `GridCellScalars`.
- Commit and worktree state: baseline `6c58c45` plus the E change, uncommitted.
- Commands: `just benchmark-sample full-screen-content-churn seconds=20` twice,
  `just benchmark-sample full-screen-incremental-mixed-churn seconds=20` once.
- Artifacts: `.build/terminal-benchmark-profiles/2026-07-27-221256-12303/sample.txt`,
  `…/2026-07-27-221401-13339/sample.txt`, `…/2026-07-27-221428-13842/sample.txt`.
- Note on comparability: `sample` takes one sample per millisecond per thread, so
  each 20s profile carries a near-fixed main-thread total. The four content-churn
  profiles report 15995, 16057, 15961, and 16040 main-thread samples -- within
  0.4% of each other. **Absolute node counts are therefore comparable across
  these profiles**, which is what lets the absorption question below be answered
  rather than guessed at. Shares alone could not have answered it: every
  surviving plan node's *share* rose purely because the denominator shrank.

  planFrame tree, content-churn post-change run 1 (1687 samples inclusive):

  ```
  planFrame                                            1687  100%
  └─ FramePlanner.plan(reusing:damage:)                          
     ├─ inspectedCells(row:geometry:cursorSpan:)         824   48.8%
     │  ├─ Terminal.cell(row:column:)                    312   18.5%
     │  │  └─ (no Array.init<A> subtree)                   0    0.0%
     │  └─ outlined destroy of TerminalCell?             182   10.8%
     ├─ textRuns                                         390   23.1%
     ├─ decorationRuns                                   240   14.2%
     ├─ backgroundRuns                                    35    2.1%
     └─ Terminal.geometry.getter                          18    1.1%
  ```

  drawRenderFrame tree, same profile (1715 samples inclusive):

  ```
  drawRenderFrame                                      1715  100%
     ├─ _ArrayBuffer._consumeAndCreateNew                242   14.1%
     ├─ CTFontDrawGlyphs                                 241   14.1%
     ├─ CTFontGetGlyphsForCharacters                     176   10.3%
     ├─ CTFontCreateCopyWithSymbolicTraits                36    2.1%
     └─ CTFontCreateWithName                              15    0.9%
  ```

- Content-churn, absolute main-thread samples, baseline vs post-change:

  | Node | Base 1 | Base 2 | Post 1 | Post 2 | Change |
  | --- | ---: | ---: | ---: | ---: | ---: |
  | `planFrame` (inclusive) | 2154 | 2142 | 1687 | 1648 | **-22%** |
  | `inspectedCells` | 1394 | 1412 | 824 | 781 | **-43%** |
  | `Terminal.cell` | 871 | 850 | 312 | 292 | **-65%** |
  | `Array.init<A>` under it | 521 | ~510 | **0** | **0** | **eliminated** |
  | `outlined destroy of TerminalCell?` | 234 | ~230 | 182 | 160 | -26% |
  | `textRuns` | 266 | 283 | 390 | 376 | **+39%** |
  | `decorationRuns` | 252 | 235 | 240 | 270 | ~flat |
  | `drawRenderFrame` (inclusive) | 1688 | 1677 | 1715 | 1669 | ~flat |

- **Did the targeted node collapse?** Yes, completely. `Array.init<A>` and its
  `_ContiguousArrayBuffer` / `swift_allocObject` / `malloc_size` descendants are
  entirely absent from the post-change plan subtree in all three profiles -- not
  reduced, absent. `Terminal.cell` fell from ~40% of a larger plan to ~18% of a
  smaller one, which in absolute terms is a two-thirds cut.
- **Did a sibling inflate to absorb it?** Partially, and the rule exists for
  exactly this. `textRuns` grew from 266/283 to 390/376 samples, roughly +110.
  Reading into that subtree, its dominant child is unchanged in kind:
  `_ArrayBuffer._consumeAndCreateNew` plus `memmove`, the unreserved run-array
  growth already logged as a Phase 5 item. The operation did not change; its
  cost per element did, because `RenderTextCell` now carries an inline payload
  and is a wider struct to copy. This is a real and predictable cost of E, and
  it is not hidden: about a fifth of the ~560-sample saving in `inspectedCells`
  is handed back at `textRuns`.
- Inference: **H1 is confirmed, and confirmed against its competing
  explanation.** F1's competing reading was that the cost was the `TerminalCell`
  value copy generally rather than the scalar array specifically. Removing only
  the array cut `Terminal.cell` by 65% and eliminated the allocation subtree
  outright, which the struct-copy reading does not predict. The residual
  `outlined destroy of TerminalCell?` at 182/160 samples is the part of F1's 40%
  that was never recoverable, as F1 itself warned.
- **Unexpected result, off the plan path entirely.** `Terminal.feed`, which runs
  on the PTY-host queue and is invisible to every render verdict, fell from
  4310/4306 to 3105/3104 samples -- about -28%, on a thread this change was not
  aimed at. The likely mechanism is `rememberOpenCluster`, which recorded the
  look-behind cluster with `Array(cell.scalars)` on the print path and now
  stores the payload directly. This is stated as an observation and a candidate
  mechanism only. It is a *sample* result on a workload whose feed path has its
  own calibrated verdict, so it must not be quoted as a feed-path improvement
  until a paired benchmark says so.
- Uncertainty: low on the plan-path attribution -- the targeted subtree is gone
  and the profiles agree. Moderate on the net size of the win, which is what the
  paired benchmark is for and which the `textRuns` absorption makes smaller than
  the headline -65% suggests.
- **Paired benchmark, run on battery by explicit opt-in.** The first
  `benchmark-confirm` attempt returned no decision --
  `terminal-feed:block-N-not-on-ac-power` for all four blocks. That gate was
  relaxed deliberately; see the caveat below and F7. Both runs are recorded:

  - Mode `confirm`, baseline revision `6c58c45`, baseline tree
    `492efe2b2ca9b65d735419224bd008feb04a1f7a`, candidate tree
    `f7339aae677f3854b006252a5026b2b0e9d5f33261e5fe83d3dd5fb9e98ca923` (binary
    identity; the source snapshot captured 24 working-tree paths). Artifact
    `.build/terminal-benchmark-comparisons/confirm/57a35ba7af28-0000`.

    | Workload | Verdict | Symmetric median | Pairs |
    | --- | --- | ---: | ---: |
    | `terminal-feed` | **faster** | -14.55% | 2 |
    | `scrollback-stream` | **faster** | -23.66% | 4 |
    | `content-churn` | inconclusive | -1.46% | 4 |
    | `style-churn` | inconclusive | -1.54% | 4 |
    | `incremental-mixed` | inconclusive | -1.03% | 6 |

    Plan-time lines in `confirm` are descriptive only -- the calibrated plan-time
    rule is defined at 2 pairs and `confirm` runs 4 or 6, so it reports
    -47.27% (content-churn), -47.46% (style-churn), and -29.67%
    (incremental-mixed) explicitly marked uncalibrated. `incremental-mixed`
    flagged 5 outlier pairs, retained in the estimate.

  - Mode `quick`, same baseline and candidate identities, workload
    `content-churn`, artifact
    `.build/terminal-benchmark-comparisons/quick/57a35ba7af28-0000`:

    ```
    content-churn: inconclusive (-1.36% symmetric median of 2 pairs)
      plan time: -46.86% symmetric median of 2 pairs (faster)
    ```

    This is the decision-bearing number for E: **plan time -46.86%, classified
    faster, on the calibrated 2-pair rule.**

- Reading the verdicts against the trees, which agree closely:
  - **Plan time is nearly halved**, matching the profiles' -22% of main-thread
    plan samples plus the removal of allocator work the sample tree attributes
    to `Terminal.cell`. This is the change's actual target and it landed.
  - **The draw verdicts are all inconclusive**, exactly as the trees predicted:
    `drawRenderFrame` was flat across every profile. E was never a draw change,
    and the serialized-draw verdicts bracket only `draw(_:)`.
  - **`terminal-feed` faster by -14.55% promotes F4's unexpected observation
    from a sample artifact to a verdict.** The profiles saw `Terminal.feed` fall
    28% on the PTY-host thread; the paired benchmark independently classifies
    that workload faster. The `rememberOpenCluster` mechanism proposed above is
    now the leading explanation for a measured effect rather than a guess about
    a sample count -- though it remains unproven as *the* cause.
  - **`scrollback-stream` faster by -23.66% was not predicted by any tree here**,
    because no profile in this investigation covered that workload. It is
    consistent with the same grid-write mechanism, and it is the strongest
    single number in the suite. Flagged as unexplained rather than claimed.
- **Caveat on all five verdicts: they were measured on battery.** The
  position-balanced schedule means a steady slowdown hits both arms alike, so
  the symmetric median stays unbiased -- the A/B structure is doing its job. What
  battery operation does not preserve is the *distribution* the fixed thresholds
  were calibrated against on AC. The practical consequence is asymmetric: the
  `faster` verdicts are the trustworthy ones, since added noise works against
  finding significance, while the three `inconclusive` draw verdicts are the
  weaker claim and should not be read as "proven equivalent". The trees
  independently show draw flat, which is the better evidence for that half.
- Next action: none for E's verification. Phase 3 is complete.

### F5 -- second-stage verification

- Status: retired unpopulated. D2 selected a single change, so there is no
  second stage to verify; F4 carries the whole verification.

## Decision log

### D1 -- how to remove the per-cell scalar allocation from the plan path

- Status: **selected, then superseded by D2 before any code was written.** F6
  invalidated B's premise while Phase 3 was being opened. Kept in full because
  the reasoning that produced it is still the reasoning D2 inherits.
- Evidence used: F1 (primary), F2 (shows H1 and H2 are additive).
- Candidate solutions:
  - **B -- planner-facing non-allocating accessor.** New accessor plus one call
    site in `inspectedCells`; `cell(row:column:)` untouched.
  - **A -- non-allocating `TerminalCell.scalars` representation.** Removes the
    allocation for every consumer; changes public API used by render execution.
  - **C -- cache `PlannedCell` arrays across frames, rebuilding only damaged
    rows' cells.** Composes with H2 and would also cut the geometry cost, but
    adds a second reuse cache beside `RetainedFrameRows` with its own
    invalidation hazard, and it hides rather than removes the per-cell
    allocation on the rows that *are* damaged.
- Tradeoffs and correctness risks:
  - B: lowest risk; behavior-preserving by construction. Leaves two cell-access
    paths that can drift, which is only acceptable because A is the intended
    follow-up.
  - A: real risk at the `drawTextRuns` sprite-routing call site, which indexes
    `scalars` directly to classify single-scalar cells; a representation change
    that silently alters `count` or `first` semantics for empty or wide-tail
    cells would misroute sprites. Also touches every test that builds a
    `TerminalCell`.
  - C: highest risk, and its win is conditional on damage staying small, so it
    would be measured on the workload with no calibrated plan-time verdict.
- Recommendation: **B first, then A gated on B's result.** B is the smallest
  useful test of H1 -- it can confirm or reject the hypothesis without paying A's
  blast radius, and A is unjustified if B does not move the tree. C is deferred,
  not rejected; revisit it under H2 in Phase 5 where the geometry cost gives it a
  second reason to exist.
- Direction review: 2026-07-27, by the user, on the recommendation as written.
- Selected direction: **B first, then A gated on F4** -- the recommendation
  accepted unchanged. C stays deferred under H2 in Phase 5. The gate this
  imposes on Phase 4 is the one already written into the Phase 3 ledger: if the
  re-posted plan tree does not collapse the `Array.init<A>` subtree, H1 is
  rejected and A is not attempted.
- Behavioral verification: pending the Phase 3 test audit. The contract to
  protect is that empty, single-scalar, multi-scalar/combining, and wide-pair
  cells produce identical text, background, and decoration runs before and
  after -- a structure-insensitive property, testable at the planner boundary.
- Quantitative verification, when applicable: re-posted plan/render call trees in
  F4 and F5, plus `benchmark-quick` (B) and `benchmark-confirm` (A) against the
  recorded pre-change revision, read on the plan-time line.
- Decision and rationale: B then A, selected 2026-07-27. Rationale unchanged from
  the recommendation: F1 attributes 40% of plan to `Terminal.cell` and puts the
  allocation descendants under `Array.init<A>` rather than under the struct copy,
  but attribution is not proof -- only a change that removes the allocation can
  separate H1 from its competing explanation. B is that change at its smallest:
  one accessor, one call site, no public type change. A is worth its blast radius
  only after B has shown the tree move.

### D2 -- how to remove the per-cell allocation now that F6 shows it is retained into the plan

- Status: **direction selected.** Supersedes D1's selected sequence. Phase 3 is
  unblocked; Phase 4 is dissolved into it.
- Evidence used: F6 (primary -- kills B), F1 (the size of the prize), F2 (H1 and
  H2 are additive).
- What changed: D1 assumed the allocation was a planner-local temporary, which
  made a planner-local accessor a sufficient experiment. F6 shows the array is
  the plan's own scalar representation, carried by `TerminalCell`,
  `PlannedCell`, and the public `RenderTextCell`. Removing it means changing
  that representation; there is no smaller place to stand.
- Candidate solutions:
  - **E -- one inline-storage scalar type across the whole chain.** Introduce a
    public `TerminalScalars` value type -- the same three-case shape the grid
    already stores privately as `GridCellScalars` (`Terminal.swift:117`), which
    is proven and has an `append` that already handles the spill transition --
    conforming to `RandomAccessCollection`, and use it for
    `TerminalCell.scalars`, `PlannedCell.scalars`, and `RenderTextCell.scalars`.
    The single-scalar cell then never touches the heap anywhere on the path.
  - **B-verbatim -- implement D1's accessor as written.** F6 predicts a net-zero
    tree. Its only value is as a measurement of F6 itself, paid for at the price
    of a full implement-and-profile cycle.
  - **C -- cache `PlannedCell` arrays across frames** (carried over from D1).
    Still composes with H2, still hides rather than removes the allocation on
    damaged rows, still scored on the workload with no calibrated plan-time
    verdict. Unaffected by F6.
  - **Stop.** Bank F1-F3 and F6 as evidence and leave the allocation in place.
- Blast radius of E, measured rather than estimated: 3 `TerminalCell(`
  construction sites and 4 `RenderTextCell(` sites across `lib/` and `app/`;
  140 `.scalars` use sites, of which the overwhelming majority are reads
  (`count`, `first`, `isEmpty`, iteration, `append(contentsOf:)`) that a
  `RandomAccessCollection` conformance keeps compiling untouched. 23 of the 34
  affected files are in `lib/TerminalCore/Tests/`. An `ExpressibleByArrayLiteral`
  conformance plus an `init(_: [Unicode.Scalar])` keeps existing array-literal
  construction source-compatible.
- Tradeoffs and correctness risks:
  - E: the risk D1 already named for A, unchanged and now unavoidable --
    `drawTextRuns` routes sprite classification on `cell.scalars.count == 1` and
    `cell.scalars.first` (`TerminalRenderExecution.swift:395`), so a
    representation whose `count`/`first` semantics differ for empty or wide-tail
    cells would misroute sprites silently. This is a real hazard and it is
    exactly what the Phase 3 behavioral audit exists to pin down. Mitigated by
    the fact that the semantics are copied from a type already in production use
    inside `Terminal`.
  - B-verbatim: no correctness risk and no expected win.
  - C: unchanged from D1 -- highest risk, conditional win, weakest scoring.
- Recommendation: **E**, treated as a single change rather than a sequence. F6
  removes the staging that made B-then-A attractive: there is no longer a cheap
  experiment that can reject H1, because the only change that can move the tree
  is the one that changes the representation. E still gets a real gate -- the
  re-posted trees in F4 -- it just cannot be gated any earlier than that.
- Direction review: 2026-07-27, by the user, on the recommendation as written.
- Selected direction: **E -- one inline-storage scalar type across the whole
  chain**, as a single change rather than a sequence. B is not implemented even
  as a measurement of F6; C stays deferred under H2 in Phase 5.
- Behavioral verification: audit completed 2026-07-27; recorded here rather than
  in a separate finding because it changes what E must implement, not just what
  it must be tested against.

  Already pinned, no new test needed:
  - `Terminal.cell` payloads for all four cases: empty -> `[]`
    (`TerminalTests.swift:73`), wideTail -> `[]` and *not* the head's scalars
    (`TerminalTests.swift:82`), single-scalar (dozens of sites), multi-scalar up
    to 3 scalars plus the whole libvterm JSON corpus
    (`TerminalFixtureTests.swift:471-474`).
  - Planner payloads: single-scalar and a 2-scalar combining cluster
    (`RenderFramePlanningTests.swift:87-88`), wideHead payload with the tail
    contributing no text cell (`RenderFramePlanningTests.swift:227-241`).
  - Sprite routing positive path: exhaustive bitmap coverage across eight sprite
    families, all driven through a real `Terminal`, so they exercise
    `count == 1` / `first` end to end.
  - Sprite routing negative path: exactly one test,
    `GeometricShapeSpriteExecutionTests.swift:40-65`, whose own comment names the
    `count == 1` gate as "the sole guard".

  Gaps that need tests written before the change:
  1. No test asserts the planner never emits a `RenderTextCell` with an empty
     payload -- the `RenderFramePlanner.swift:414` filter is only inferable today
     from run start columns.
  2. Nothing reaches a cluster larger than 3 scalars through the planner or
     executor, so the spill path would be unproven end to end.
  3. The multi-scalar sprite negative exists for one family only.
  4. The new type's `==` needs its own test.

  **The audit also surfaced a correctness trap that E's implementation must
  avoid.** Roughly 93 test sites compare `scalars` against array literals, and
  `TerminalCell`, `RenderTextCell`, `RenderTextRun`, and `RenderFramePlan` are
  all `Equatable` and compared whole. A naive derived enum `==` would make
  `.single(x)` unequal to `.spill([x])` for identical content, silently breaking
  plan equality wherever the same content arrived by a different route. E's
  scalar type must therefore define `==` element-wise over the collection, not
  derive it from the representation, and be tested for exactly that. Same for
  `hash(into:)` if it is ever made `Hashable`.

  Source-compatibility cost, measured: `ExpressibleByArrayLiteral` plus an
  `init(_: [Unicode.Scalar])` keeps almost all of the 93 sites compiling. Four
  do not, because their right-hand side is explicitly `[Unicode.Scalar]` rather
  than an inferable literal: `ViewportRenderPlanningTests.swift:25` and `:49`,
  `TerminalScrollbackBudgetTests.swift:96`, `TerminalFixtureTests.swift:473`.
  The type must also keep `Sequence` working -- `flatMap(\.scalars)` and
  `append(contentsOf:)` are used in `TerminalBenchmarkMarkers.swift:129` and
  `TerminalRenderExecution.swift:787`.
- Quantitative verification: re-posted plan and render call trees in F4 under the
  standing rule, plus `benchmark-confirm` against `6c58c45` -- confirm rather
  than quick, since E crosses the plan/execute boundary that D1 assigned to A.
- Decision and rationale: E, selected 2026-07-27. Rationale: F6 removes the
  staging that made B-then-A attractive, because the allocation is not
  planner-local and no planner-local change can reach it. E is therefore not a
  larger alternative to a smaller experiment -- it is the smallest change that
  can move the targeted node at all. It is licensed to skip the experiment stage
  precisely because F6 is a source-level fact rather than a statistical one:
  there is nothing left for a cheap experiment to discover. The gate does not
  disappear, it moves to F4's re-posted trees, where the standing rule about
  siblings inflating still decides the outcome.

## Rejected

Nothing rejected yet. C is deferred under D1 and D2, not rejected. B is
superseded by F6 rather than rejected on its merits -- it was the right
experiment for the mechanism D1 believed in.

## Open questions and caveats

- The plan-time metric that would score B and A is calibrated only on
  `content-churn` and `style-churn`. `incremental-mixed` -- the workload where
  H2's fixed cost is most visible -- reports plan time with no verdict, so H2 may
  be provable by profile and still unprovable by paired benchmark. Confront that
  before Phase 5 rather than during it.
- All shares here are `sample` attribution under active profiling. The observer
  overhead is in spec, but profiling is on, so the absolute mix differs from an
  unprofiled run.
- H1's recoverable fraction is unknown. Removing the allocation does not remove
  `PlannedCell` construction, and some of the 40% will remain.
- Untracked `plans/wip/*` files were present during capture. They do not enter
  the build and cannot affect these profiles, but they would be captured by a
  paired comparison's candidate tree -- read the printed path list before
  believing a Phase 3 or Phase 4 benchmark result.

## Outcome

Phases 1-4 are complete. H1 is confirmed and acted on; H2 and H3 remain evidenced
and unscheduled in Phase 5.

The investigation's shape changed once mid-flight and it is worth recording why.
D1 selected a two-step sequence -- a cheap planner-local experiment, then the
representation change it would license -- on the belief that the per-cell array
was a planner temporary. F6 showed it was not: the array is the plan's own scalar
representation, retained through `PlannedCell` into the public `RenderTextCell`
for the life of the frame. That killed the cheap experiment outright, because a
planner-local accessor would have moved the allocation rather than removed it.
D2 replaced the sequence with a single change, E, and the change landed:

- Plan time **-46.86%, classified faster** on the calibrated 2-pair rule.
- The targeted `Array.init<A>` subtree is gone from the plan tree entirely.
- Two workloads this change was not aimed at came back faster --
  `terminal-feed` -14.55% and `scrollback-stream` -23.66% -- because the same
  representation removed an allocation from the grid-write path. The
  `scrollback-stream` result is unexplained by any profile collected here.
- The draw verdicts are inconclusive, as the trees predicted; E was never a draw
  change.

Two things are deliberately left open. The benchmark verdicts were measured on
battery under the F7 override, which keeps the `faster` results trustworthy but
weakens the `inconclusive` ones -- an A/A calibration on battery would settle
whether the frozen thresholds still hold there. And `textRuns` absorbed about a
fifth of the plan-path saving because `RenderTextCell` is now a wider struct to
copy; that lands squarely on the unreserved-array-growth item already sitting in
Phase 5, which is now worth more than it was when it was logged.
