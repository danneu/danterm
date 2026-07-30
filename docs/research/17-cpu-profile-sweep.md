# Whole-workload on-CPU profile sweep

Research started: 2026-07-29.
Continues: [14-live-scroll-workload-profile.md](14-live-scroll-workload-profile.md)
(`14/F6`, `14/D1`), [13-live-app-compositing-and-draw-hotspots.md](13-live-app-compositing-and-draw-hotspots.md)
(`13/H3`, `13/D2`), and [9-plan-render-allocation-hotspots.md](9-plan-render-allocation-hotspots.md)
(`9/H2`, `9/H3`, Phase 5).
Continued by: [18-cpu-renderer-optimization-leads.md](18-cpu-renderer-optimization-leads.md),
which decomposes the one region this sweep ranked but never opened -- the draw
bracket -- and explains the display-list mechanism behind `F1`'s off-main-thread
surprise and `F2`'s unbracketed region.

## Purpose

Doc 14 pivoted from `sample` to the xctrace Time Profiler and that pivot paid for
itself immediately: from **one** trace it rejected the file's only standing
candidate as too small to measure (`14/D1`) and named two nodes that shipped as
-20% draw and -16% plan (`14/D2`, `14/D3`). The pivot became an investigation
rule -- *re-size a `sample`-derived node on an on-CPU instrument before spending a
paired benchmark on it*.

But that was one capture of one workload (`full-screen-content-churn`), and
`14/F1` established that the plan/draw ratio is workload-shaped with no published
ratio generalizing. Every other CPU share this project holds -- doc 9's plan and
draw hotspots, doc 10's entire feed ranking, doc 11's and doc 13's draw and
compositing shares -- was taken on `sample`, under the ~3x inflation `9/F3`
measured and `14/F6` demonstrated at 2.5x on a specific node.

So the project's CPU map was one on-CPU photograph plus a large collection of
pictures taken with a lens now known to distort. **This file owns re-taking the
map on the on-CPU instrument, across every workload that has one, and ranking
what it finds.** It is a survey, not a fix: the deliverable is a ranked
opportunity list with pitched and pre-rejected solutions, handed to the user for
direction selection before any implementation.

## Investigation rules

- **On-CPU instrument only for ranking.** A `sample`-derived number may be cited
  as history, never as a size.
- **Every workload that has an on-CPU mode, one capture each, before any
  ranking.** Reading one trace and generalizing is the failure this file exists
  to correct. `10/F1` sharpens it: prune *that* workload's own tree rather than
  reusing another's node list.
- **Convert a share to the deciding benchmark's own denominator before predicting
  a win** (`14/F9`, `14/F10`).
- **Check the standing rejection list before pitching.** See "Pre-rejected".
- **No implementation of a *code* candidate before a user direction gate**
  (Phase 5), per `agent-docs/terminal-performance.md`. Phase 4's tooling fixes
  were directed and are exempt: they change what can be measured, not what is
  measured, and they are covered by tests rather than by a benchmark verdict.

## Trigger and current evidence

The trigger is method, not a symptom: doc 16 closed and the memory sequence that
ran from doc 12 through doc 16 is finished, while the one CPU instrument that has
repeatedly corrected this project's own conclusions had been pointed at exactly
one workload.

Inherited quantities that frame what a finding here must beat:

| Quantity | Value | Source |
| --- | --- | --- |
| Plan vs draw time, `content-churn` | ~1.16M ns plan / ~0.9M ns draw per accepted draw | `agent-docs/terminal-performance.md` |
| Plan vs draw time, `incremental-mixed` | ~1.15M ns plan / ~0.16M ns draw | same |
| Full-frame 179x66 CPU draw | ~8.5 ms all-sprite, 4.06 ms all-text, against 16.7 ms | `11/F7`, `11/F8` |
| Share of a full-frame sprite draw inside `CGContextFillRects` | 71.5% | `11/F10` |
| Swift-side draw surface doc 9's backlog can reach | 28% of the draw, largest item 3.8% | `11/F10` |

**`F5` refutes rows 1-2 of that table.** They are the reason this sweep expected
`9/H2` to be the leading candidate, and they are stale by one commit.

`F12` then replaced them with measured values at `4ecb032`, on the same metric and
denominator the stale rows used -- so the correction is a like-for-like swap, not
a change of units:

| Quantity | Stale claim | Measured (`F12`) | Error |
| --- | --- | --- | --- |
| `content-churn` plan per draw | ~1.16M ns | 501k-510k ns | 2.3x too high |
| `content-churn` draw per draw | ~0.9M ns | 540k-542k ns | 1.7x too high |
| `incremental-mixed` plan per draw | ~1.15M ns | 65,584 ns | **17.5x too high** |
| `incremental-mixed` draw per draw | ~0.16M ns | 85,805 ns | 1.9x too high |

The stale text also gets the *ordering* wrong on both workloads: it says planning
is the larger cost, and on both it is now the smaller one. This is what candidate
D corrects, and `F12` supplies the replacement numbers it needs.

## Current hypotheses

### H1 -- planning is the dominant term and is damage-blind

**REJECTED by `F5`.** `8188b9a` ("plan only the rows the terminal damaged",
2026-07-27) landed *after* the measurement the inherited figures come from, and
the planner has retained per-row reuse since. The trace agrees.

### H2 -- the four workloads have disjoint hot sets, so one ranking cannot serve all

**Partially confirmed, and sharpened, by `F4`.** Three distinct shapes, not four:
`content-churn` and `style-churn` are indistinguishable on CPU, `scrollback-stream`
is nearly disjoint from both, and `incremental-mixed` is dominated by instrument
and kernel frames rather than by app work.

### H3 -- the feed path's on-CPU shape is unknown and its `sample` ranking overstates allocation and ARC

**Rejected in its predicted direction by `F7`.** `sample` did not overstate the
one feed node that both instruments have now sized: `10/F8` put the
`DamageActionSnapshot` copy at 4.7% of root under `sample`, and the on-CPU trace
puts the same frame at 4.78% self. On this node the instruments agree.

### H4 -- the remaining cross-module dispatch surface is not exhausted

**Open, ranked low.** `TerminalScalars.Storage` copy/consume survives in all four
traces (4.45% of total on `scrollback-stream`), but `F8` attributes the majority
of it to scrollback eviction freeing row storage rather than to call overhead.

### H5 -- the largest CPU cost in the app is one no DanTerm instrument brackets

**Confirmed by `F6`.** CoreAnimation replaying DanTerm's display list is the
single largest region on the draw workloads, and per-glyph bounds computation
inside it is 16.8% of total process CPU -- 1.6x the entire region the draw verdict
measures. Not hypothesised in advance; it emerged from the sweep.

## Task ledger

### Phase 1 -- take the map

- [x] Capture a Time Profiler trace on each sustained workload that has an on-CPU
      mode, sequentially so they never contend. **Done -- `F1`.**
- [x] Record what the instrument cannot reach, so the map's edges are explicit.
      **Done -- `F2`. This is the phase's most consequential output.**

### Phase 2 -- attribute and rank

- [x] Per workload, prune that workload's own tree and record top self and
      inclusive frames with region denominators. **Done -- `F3`.**
- [x] Test `H2` by overlapping the four top-frame lists. **Done -- `F4`.**
- [x] Test `H1` by comparing plan cost across `content-churn` and
      `incremental-mixed`. **Done -- `F5`, and it rejected `H1` on code
      provenance rather than on the trace, because `F2` denies the trace the
      frame counts the comparison needs.**
- [x] Rank candidates by expected impact against their own denominators.
      **Done -- `F6` through `F9` and the ranking table in `D1`.**

### Phase 3 -- pitch

- [x] Candidate solutions, tradeoffs, correctness risks, smallest first
      experiment. **Done -- `D1`.**
- [x] Record what to reject off the bat. **Done -- "Pre-rejected".**

### Phase 3b -- price the instrument gap the ranking exposed

- [x] Establish whether the undecidability in `F2` is fixable, and at what cost,
      rather than accepting a ranking distorted by it. **Done -- `F10` verifies
      the mechanism, `D2` proposes three tooling fixes (T1-T3) and recommends an
      order.**

### Phase 4 -- fix the instrument (`D2`)

- [x] T2: publish a draw counter from loop/profiling mode, and derive the draw
      rate over a profiling window. **Done -- `F11`.**
- [x] T1: whole-process CPU per accepted draw, emitted per block, normalized over
      the same 50 draws, reported by the comparator with no path to a verdict.
      **Done -- `F12`.**
- [x] Behavioral tests for both, written against the two seams rather than the
      implementations: comparator + validation suites for T1, harness contract
      (including a line-order assertion that each snapshot brackets its profiler)
      for T2. Each verified to fail against the pre-change behaviour before being
      accepted. `just test` green.
- [x] Re-read `D1`'s ranking against the fixed instrument. **Done -- `D3`.**
- [ ] T3 -- not taken. Unchanged from `D2`: real, but serves a question nobody is
      currently asking.

### Phase 5 -- code-candidate direction gate

- [x] Gate opened by user instruction; **B selected**. `D3` recommended B, then C,
      then A, plus a fourth option (the A/A screen).
- [x] **Candidate B implemented, measured, kept. `F13`, `D4`.** Guarding test
      written first -- and it rejected the implementation `F7`/`D1` had pitched
      before any benchmark ran, so what shipped is a revision counter rather than an
      identity token. Verdicts: `terminal-feed` **faster -14.59%**,
      `scrollback-stream` **faster -10.78%**, both churn workloads `equivalent`,
      `incremental-mixed` `inconclusive`. `DamageActionSnapshot` is now POD, 190 ->
      166 bytes.
- [x] **Candidate C measured and rejected. `F14`, `D5`.** The ablation `F9` asked
      for removed `recentOutput` entirely and *nothing vanished* (`applyOutput`'s
      body 14.95% -> 15.24%); `scrollback-stream` flipped sign between 2 and 4
      pairs. It also refuted the method that sized C: `F9`'s frame subtraction is
      unsound because `Terminal.feed` is partially inlined. Diagnostic reverted.
- [x] **A/A screen for `processCPUNanosecondsPerDraw` done; no rule earned. `F15`,
      `D6`.** 24 A/A pairs per workload at one immutable arm root. The two accuracy
      gates cross with no overlap on every workload in both modes -- the closest
      case, `content-churn`/`quick`, reaches a 0.0000 false-positive rate only at a
      threshold where detection has fallen to 0.8320 against a 0.90 gate. The metric
      is now screened-and-refused rather than unscreened, and `D6` names the one use
      it does have. **`D5` logged this as "prerequisite for reading candidate A
      partially"; it turned out to be a prerequisite that cannot be met.**
- [x] **`F6`'s elasticity confirmed. `F16`.** Two captures at 179x66 and 80x25
      (5.907x glyph-occurrence lever): the `get_glyph_bboxes` subtree moves 5.62x,
      **95.1% of linear**. The bar `11/F12` used to refute two earlier mechanisms is
      passed. Also replicates `F6` at HEAD (16.37% vs 16.78%).
- [x] **Live sizing capture taken; `F6`'s magnitude retired. `F17`.** A
      damage-scoped stimulus at the same geometry puts the node at **27.3 us/draw
      against 801.0** -- 29.3x smaller -- and `F3`'s 1.85% on `scrollback-stream`
      agreed all along. The draw path is damage-scoped, like planning (`F5`).
- [x] **Candidate A closed. `D8`.** Magnitude is a benchmark artifact, the win
      would be energy rather than frames (`F16`), and no instrument here can decide
      it (`F12`, `F15`). Reopening condition recorded: a capture of a real
      full-screen animated TUI showing the node above 1.85%.

## Findings log

### F1 -- the sweep, and the structural surprise in it

- Status: recorded. The file's baseline; every later finding reads off these four
  artifacts.
- Date and investigator: 2026-07-29, Claude (agent).
- Commit and worktree state: `4ecb032`. Tracked tree clean; untracked `notes.md`
  and five `plans/wip/*.md` present, which do not enter the build.
- Commands, run strictly sequentially so no two captures contended:

      just benchmark-trace scrollback-stream "Time Profiler" 30
      just benchmark-trace full-screen-content-churn "Time Profiler" 30
      just benchmark-trace full-screen-style-churn "Time Profiler" 30
      just benchmark-trace full-screen-incremental-mixed-churn "Time Profiler" 30

- Artifacts, under `.build/terminal-benchmark-profiles/` (disposable; every
  decision-bearing number is transcribed into this file):

  | workload | run directory | on-CPU total |
  | --- | --- | ---: |
  | `scrollback-stream` | `2026-07-29-175721-21606` | 36,711 ms |
  | `content-churn` | `2026-07-29-175854-23359` | 18,008 ms |
  | `style-churn` | `2026-07-29-175944-24423` | 17,965 ms |
  | `incremental-mixed` | `2026-07-29-180034-25423` | 7,455 ms |

- Method: `profile-folded.txt` parsed directly. Region shares are inclusive
  weight of every stack containing a named frame, over that workload's own total.
  Stack depth reaches 51 and 85 in the two largest traces, so nothing is
  truncated at the depths these attributions read.
- Observation, and it reframes the whole survey: **on the draw workloads most
  on-CPU time is not on the main thread.** `content-churn` splits 46.4% main
  thread against 53.6% in a four-thread `_pthread_wqthread` dispatch pool, and the
  pool's four threads have near-identical profiles -- each carrying both
  `Terminal.feed` and CoreAnimation glyph work -- so the pool must be read as one
  aggregate rather than per thread. `scrollback-stream` is more extreme: the main
  thread is 12.5% and the terminal/PTY work is spread across four pool threads.
- Inference: any ranking read off "the main thread" would have missed the largest
  item in the app. That is what `F6` is.
- Uncertainty: 30 s per workload, one capture each. Doc 9's two-profile rule is
  therefore **unsatisfied for every workload here.** The two churn workloads
  cross-validate each other closely (`F4`), which is partial cover;
  `scrollback-stream` and `incremental-mixed` have no replicate.

### F2 -- the map's edges: what no instrument here reaches

- Status: recorded. Read this before quoting any share in `F3`.
- **`terminal-feed` has no on-CPU mode at all.** `just benchmark-trace` supports
  only the four sustained GUI workloads; the feed corpus harness is served solely
  by `just benchmark-feed-sample`, which is `sample`. So doc 10's entire ranking
  cannot be re-sized on its own boundary. `scrollback-stream` is the substitute
  and a good one -- 56.09% of its on-CPU total is inside `Terminal.feed`, through
  a real PTY -- but it is the app boundary, not the feed boundary.
- **The largest region in the app is in no benchmark bracket.**
  `drawDurationNanoseconds` is computed inside `SwiftTerminalSessionView.draw`
  around `clipFramePlan` + `drawRenderFrame` (`app/SwiftTerminalSessionView.swift:143-168`),
  so the draw verdict measures the `drawRenderFrame` region -- 10.43% of
  `content-churn`. CoreAnimation's display-list replay, at 23.15%, happens after
  `draw` returns, on the dispatch pool. **No frozen decision rule contains it.**
  `scrollback-stream`'s end-to-end wall clock does contain it, but there it is
  only 2.83%.
- **No frame count, and three candidate proxies disagree by 1.7x.** This is the
  standing `sample` limitation (`13/F10`) surviving the pivot to xctrace: shares
  are time, not invocations, so absolute ms cannot be compared across workloads
  with different draw cadences. Taking each per-frame-once node as a proxy for
  frame count between `content-churn` and `incremental-mixed`: the observer's ack
  `__open` says incremental ran **1.25x** more frames, GPU submit
  (`iokit_user_client_trap`) says **0.75x**, and `mach_msg2_trap` says **0.73x**.
  Two of three disagree with the first, so **no per-draw normalization is
  available from these traces** and `F3`'s absolute ms columns are comparable only
  within a workload.
- **The instrument is a large share of the smallest workload.** The observer's
  per-draw acknowledgment `open()` -- called from `draw` after the timed bracket
  closes -- is **9.81% of `incremental-mixed`'s total on-CPU time**, against
  3.24% on `content-churn` and 3.45% on `style-churn`, plus a further 2.3-7.0%
  for the observer region proper. On `incremental-mixed` the ack alone costs
  **5.4x the entire `drawRenderFrame` region** (9.81% vs 1.81%). It is outside
  `drawNanosecondsPerDraw`, so it does not corrupt the draw verdict, but it does
  occupy the main thread between serialized draws.
- Inference: `incremental-mixed` is the least trustworthy of the four traces --
  roughly a sixth of it is measurement -- and it is also the workload
  `agent-docs/terminal-performance.md` already documents as the noisiest. Read its
  column as an order of magnitude, not a size.
- Competing interpretation on the ack: `agent-docs/terminal-performance.md`
  records the observer at 3.3-3.9% and calls a prominent observer "a regression in
  the instrument, not a finding about the app". `14/F7` then showed a 7.08%
  reading was a denominator mismatch, not a regression. This finding is a third
  case and it is neither: the three documented invariants still hold (the acks
  *are* bare `open`/`close`), and the share is large because
  `incremental-mixed`'s total on-CPU work is small, not because the ack got more
  expensive. It is a denominator effect again -- but on that workload the
  denominator is what a reader cares about.
- Next action: none blocking. `F2` is a caveat set, and `D1` respects it.

### F3 -- the ranked matrix

- Status: recorded. Inclusive share of **each workload's own** on-CPU total, with
  absolute ms alongside. Per `F2`, compare down a column, not across a row.
- Date and investigator: 2026-07-29, Claude (agent).

| node / region | scrollback-stream | content-churn | style-churn | incremental-mixed |
| --- | ---: | ---: | ---: | ---: |
| **total on-CPU** | **36,711 ms** | **18,008 ms** | **17,965 ms** | **7,455 ms** |
| `planFrame` (region) | 2.33% | 10.51% | 10.44% | 4.08% |
| &nbsp;&nbsp;`forEachViewportCell` | 1.19% | 4.00% | 3.82% | 0.89% |
| &nbsp;&nbsp;`FramePlanner.textRuns` | 0.42% | 2.47% | 2.70% | 0.55% |
| &nbsp;&nbsp;`FramePlanner.decorationRuns` | 0.23% | 2.23% | 2.14% | 0.39% |
| &nbsp;&nbsp;`FramePlanner.plannedCell` | 0.44% | 1.38% | 1.41% | 0.35% |
| &nbsp;&nbsp;`resolveCellStyle` | 0.20% | 0.88% | 0.74% | 0.16% |
| `drawRenderFrame` (region) -- *the draw verdict's bracket* | 0.88% | **10.43%** | 10.77% | 1.81% |
| &nbsp;&nbsp;`drawTextRuns` | 0.56% | 5.84% | 5.99% | 0.97% |
| &nbsp;&nbsp;`CTFontGetGlyphsForCharacters` | 0.14% | 1.67% | 1.76% | 0.24% |
| &nbsp;&nbsp;&nbsp;&nbsp;cmap `MapT` | 0.10% | 1.45% | 1.53% | 0.13% |
| **CA display-list replay** -- *in no bracket* | 2.83% | **23.15%** | **22.86%** | 10.36% |
| &nbsp;&nbsp;`CA::CG::DrawGlyphs::compute_dod_` | 1.85% | **16.78%** | **16.55%** | 4.98% |
| &nbsp;&nbsp;&nbsp;&nbsp;`TFPFont::GetGlyphIdealBounds` | 1.58% | 13.99% | 13.65% | 4.01% |
| &nbsp;&nbsp;&nbsp;&nbsp;`TGlyphOutlineDictionaryCache` | 1.10% | 10.05% | 9.65% | 2.71% |
| &nbsp;&nbsp;`CA::CG::FillGlyphs` (rasterize) | 0.39% | 3.47% | 3.62% | 1.48% |
| &nbsp;&nbsp;`CA::OGL::GlyphCache` (Metal upload) | 0.21% | 2.12% | 2.18% | 0.91% |
| &nbsp;&nbsp;`CA::CG::FillRects` | 0.01% | 0.37% | 0.37% | 0.25% |
| GPU submit (`iokit_user_client_trap`) | 0.57% | 3.33% | 3.14% | 6.06% |
| `Terminal.feed` (region) | **56.09%** | 19.32% | 20.58% | 4.27% |
| &nbsp;&nbsp;`Terminal.recordDamage` | **15.79%** | 4.90% | 4.74% | 0.75% |
| &nbsp;&nbsp;`DamageActionSnapshot` copy/init/destroy (region) | **8.27%** | 2.56% | 2.23% | 0.42% |
| &nbsp;&nbsp;`TerminalDamageAccumulator` | 2.26% | 0.83% | 0.72% | 0.17% |
| &nbsp;&nbsp;`GraphemeBreakState.shouldBreak` | 1.99% | 0.63% | 0.67% | 0.05% |
| &nbsp;&nbsp;`terminalUnicodeClassification` | 1.08% | 0.40% | 0.36% | 0.05% |
| `applyOutput` minus `Terminal.feed` (upper bound, see `F9`) | 23.82% | 2.42% | 2.45% | 0.48% |
| `TerminalScalars.Storage` copy/consume | 4.45% | 3.10% | 3.04% | 1.44% |
| observer region (instrument) | 0.28% | 2.44% | 2.28% | 6.96% |
| &nbsp;&nbsp;`__open` ack (instrument) | 0.00% | 3.24% | 3.45% | **9.81%** |

- Observation: the three largest app-attributable quantities in the whole sweep
  are **CA's per-glyph bounds computation** (16.8% of a churn workload),
  **`applyOutput`'s non-feed body** (up to 23.8% of `scrollback-stream`), and
  **`recordDamage`** (15.8% of `scrollback-stream`). None of the three is a node
  any earlier doc ranked first.
- Inference: `planFrame` and `drawRenderFrame` -- the two regions this project has
  spent docs 9, 11, 13 and 14 optimizing -- are 10.5% and 10.4% of the workload
  where they are largest. They are no longer where the time is.

### F4 -- three shapes, not four, and the two churn workloads are CPU-identical

- Status: recorded. Tests `H2`.
- Method: overlap of each workload's own top-12 self-frame list.
- Measurements: 1 frame appears in all four lists (`outlined consume of
  TerminalScalars.Storage`); 9 in three of four; 13 in exactly one.
- Observation 1: **`content-churn` and `style-churn` are indistinguishable.**
  Region by region: plan 10.51 vs 10.44, draw 10.43 vs 10.77, `compute_dod_`
  16.78 vs 16.55, feed 19.32 vs 20.58. Their top-12 lists differ only in
  ordering.
- Observation 2: `scrollback-stream`'s list is nearly disjoint from theirs -- its
  seven unique entries are all grid-write and array traffic -- and
  `incremental-mixed`'s top five are `__open`, `iokit_user_client_trap`,
  `start_wqthread`, `mach_msg2_trap`, `objc_msgSend`: instrument, GPU submit,
  thread plumbing. Its first app frame is 6th.
- Inference: **`H2` holds for ranking but the axis is not the four-workload one.**
  The benchmark ladder's content/style split exists to attribute a *verdict* by
  freezing one axis; it does not produce two CPU shapes, so **tracing both is
  redundant** and a future sweep can capture one. What the ladder does not have is
  a workload that isolates CA replay, which `F6` says is the largest item.
- Competing interpretation: the two churn workloads could agree because
  profiling forces a republished full-viewport redraw in loop mode
  (`DANTERM_TERMINAL_BENCHMARK_REDRAW_UPDATES=1000000`), swamping the frozen axis.
  That would make the redundancy an artifact of profiling mode rather than of the
  workloads. Not distinguished here; it does not change the ranking.

### F5 -- the planner is already damage-scoped, and `agent-docs` says otherwise

- Status: recorded. **Rejects `H1` and retires `9/H2`.**
- Evidence, in the order it actually decided the question:
  1. `lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift:38-52`
     defines `RetainedFrameRows`, which exists so "a later frame can copy an
     undamaged row's runs instead of re-inspecting its cells", and
     `planFrame(for:presentation:)` is the `damage: .full` special case of a
     `plan(reusing:damage:)` that takes damage.
  2. `git log` dates that mechanism to **`8188b9a`, 2026-07-27, "perf(terminal):
     plan only the rows the terminal damaged"**.
  3. The inherited "~1.15M ns plan on `incremental-mixed`, barely moving as
     damage shrinks from 66 rows to 6" figure entered `agent-docs` in
     **`b7f5c12`, 2026-07-24** -- three days and one commit *before* the fix.
  4. The trace is consistent: `planFrame` is 10.51% / 1,892 ms on `content-churn`
     against 4.08% / 304 ms on `incremental-mixed`, and `forEachViewportCell`
     -- the cell-inspection traversal reuse is meant to skip -- falls 4.00% to
     0.89%.
- Observation: `agent-docs/terminal-performance.md` currently tells every agent
  that "the planner plans the whole viewport regardless" and that planning is the
  larger cost in both workloads. **The first clause is false and the second is
  unsupported.**
- Inference 1: **`9/H2` ("whole-viewport geometry per plan"), parked in doc 9's
  Phase 5 backlog as evidenced and unrefuted, is retired.** It was implemented
  two days after doc 9 closed and nobody updated either document.
- Inference 2: this file expected `9/H2` to be its leading candidate. It was the
  single strongest a-priori hypothesis and it was already fixed -- which is the
  argument for the sweep rather than against it.
- Competing interpretation, and why it does not rescue `H1`: point 4's absolute ms
  are not per-draw normalized, and `F2` shows they cannot be. So the trace alone
  could be explained by `incremental-mixed` simply running fewer frames. Points
  1-3 do not depend on frame counts, and they are decisive on their own.
- Uncertainty: what remains unmeasured is *how much* plan work is still
  viewport-wide. Selection, search-match and cursor runs are recomputed every
  frame by design (`RenderFramePlanner.swift:38-44`), and `clipFramePlan` is a
  set of `filter` passes over the whole plan (`:17-36`) -- it appears at 0.05% on
  `incremental-mixed` and 0.00% elsewhere, so it is not currently a cost.
- Next action: correct `agent-docs/terminal-performance.md` and doc 9's Phase 5
  note. Neither is this file's to edit unilaterally; both are listed in `D1` as
  the zero-risk item.

### F6 -- CoreAnimation recomputes every glyph's bounds on every frame, and it is the largest cost in the app

- Status: recorded, **mechanism confirmed (`F16`), magnitude retired (`F17`).** The
  per-occurrence mechanism below is right and elastic at 95.1% of linear. The
  **16.8% is not**: it is 29.3x smaller under a damage-scoped draw, and `F3`'s own
  1.85% on `scrollback-stream` always agreed. Read the heading as "in the
  forced-full-redraw churn workload", not "in the app". Candidate A is closed
  (`D8`). Confirms `13/H3` and satisfies `13/D2`'s reopening condition either way.
- Date and investigator: 2026-07-29, Claude (agent).
- Measurements: `content-churn` 16.78% of total on-CPU (3,021 ms of 18,008);
  `style-churn` 16.55%; `incremental-mixed` 4.98%; `scrollback-stream` 1.85%.
  Against the region the draw verdict actually brackets (10.43%), it is **1.61x
  the whole measured draw**.
- Call path, 99.1% of the subtree through one chain:

      CA::CG::Queue::render_callback -> CA::CG::DrawOp::render
        -> CA::CG::DrawGlyphs::compute_dod_ -> get_glyph_bboxes
        -> FPFontGetGlyphIdealBounds -> TFPFont::GetGlyphIdealBounds
        -> TFPFont::CopyGlyphPath -> TGlyphOutlineDictionaryCache::Copy

- Self-frame split inside that subtree: `TGlyphOutlineDictionaryCache::Copy`
  48.4%, `___CFBasicHashFindBucket_Linear` 11.1%, `CFRetain` 9.5%,
  `__CF_IS_OBJC` 4.8%, `os_unfair_lock_lock`/`_unlock` 8.9%, `_CFRetain` 4.2%,
  `_platform_memmove` 3.4%, `CFDictionaryGetValue` 1.7%.
- Mechanism: `app/SwiftTerminalSessionView.swift:102` sets `wantsLayer = true`
  and the view draws in `draw(_:)`, so AppKit records DanTerm's CoreText output
  into a CGDisplayList that CA replays on the dispatch pool. For every
  `DrawGlyphs` op CA computes the op's domain of definition, which asks
  libFontParser for each glyph's ideal bounds, which copies the glyph's **outline
  path** out of a CFDictionary -- one dictionary lookup, one path copy, one
  retain/release pair, and an unfair lock, **per glyph occurrence, per frame**. At
  179x66 that is ~11,800 occurrences a frame.
- Observation: the cost is per *occurrence*, not per distinct glyph -- the
  hash-find and `CFRetain` shares are the tell -- so it scales with cells drawn
  and no amount of glyph diversity reduction touches it.
- Inference 1: **this confirms `13/H3`** -- doc 13's glyph-bounds attribution,
  stable across four `sample` captures, which doc 13 kept research-only and doc 11
  explicitly refused to inherit as settled (`11`'s caveat: "the experiment that
  would confirm it has never been run"). It is now measured on an on-CPU
  instrument on a reproducible workload, with the full call chain.
- Inference 2: **`13/D2`'s reopening condition is met.** That decision declined to
  build a frame-counted compositing instrument until there was "a new consumer: a
  missed-frame observation, or a candidate whose predicted win lands inside the
  stall". This is the second of those. `11/F12` refuted glyph *diversity* and op
  *count* as mechanisms for the stall; per-glyph bounds recomputation is a third
  mechanism neither doc tested.
- Inference 3: it explains why `11/F10`'s conclusion felt incomplete. That finding
  put 71.5% of a full-frame **sprite** draw inside `CGContextFillRects` and
  concluded the only draw lever is fewer or larger rects. That is true of the
  sprite path measured offscreen in `benchmark-draw`, which never creates a
  CA queue at all (`13`'s caveat). In the real app the text path's dominant cost
  is not in DanTerm's process-side draw at all.
- Competing interpretations, neither excluded:
  1. **It may be off the critical path.** These are pool threads running
     concurrently with the main thread, and `11/F12` established that an unbounded
     fraction of the compositing stall is pipeline slack -- the main thread blocked
     *less* when given more work. So removing this may buy energy rather than
     latency. It is real CPU either way, which on a laptop is battery.
  2. **It may be inflated by profiling mode.** Loop mode forces a republished
     full-viewport redraw every draw, so the per-frame glyph count is at its
     maximum. A live capture would size it as the user experiences it.
- Uncertainty: no experiment here varied glyph count and showed the node move,
  which is exactly the pre-registered test `11/F12` used to *refute* its two
  candidate mechanisms. **This finding has not passed that bar.** It is a
  confirmed attribution with an unconfirmed elasticity.
- Next action: `D1` candidate **A**.

### F7 -- `DamageActionSnapshot` is non-POD for exactly one reason, and it costs 8.3% of the throughput workload

- Status: recorded. **Reopens `10/H1(b)` at 3.4x the size that rejected it.**
  **Taken and kept -- `F13`** -- though the implementation this finding pitched
  turned out to be wrong; see `F13` for what shipped instead and why.
- Measurements, `scrollback-stream`:
  - `recordDamage` region: **15.79% of total on-CPU** (5,796 ms), the largest
    app-owned region inside `Terminal.feed`.
  - `DamageActionSnapshot` construct/copy/destroy region: **8.27% of total**.
  - `initializeWithCopy for Terminal.DamageActionSnapshot` is the **3rd hottest
    self frame in the whole trace at 4.78%**.
  - Inside the `recordDamage` region: that copy is 30.3%, `outlined init with
    copy` 5.2%, `outlined destroy of TerminalResolvedLink?` 3.5%,
  `getEnumTagSinglePayload for TerminalResolvedLink` 3.1% -- **42.1% of the region
    is snapshot value traffic**, plus `___chkstk_darwin` at 8.5% (a stack probe,
    i.e. a large stack frame) and `destroy for ClosedRange<>.Index` at 7.3%.
- Mechanism, from the source. `DamageActionSnapshot`
  (`Terminal.swift:190-199`) has eight fields, and seven are trivially copyable:
  `TerminalCursor?`, two `TerminalTextRange?`, `Int`, two `Bool`,
  `TerminalPresentation`. The eighth is `hoveredLink: TerminalResolvedLink?`,
  which holds a `TerminalHyperlink` -- **`uri: String` and `explicitId: String?`**
  (`TerminalGeometry.swift:13-24`). Two refcounted members make the whole struct
  non-trivial, so every construction, copy and destruction runs a value witness.
  Two snapshots exist per action, and `feed` carries each action's "after" forward
  as the next action's "before" (documented at `Terminal.swift:692-698`).
- The lever, and it is unusually clean: **`recordDamage` uses `hoveredLink` for
  exactly two things** -- `before.hoveredLink != after.hoveredLink` and
  `.hoveredLink?.range` (`Terminal.swift:731-734`). It never reads the URI. And
  `TerminalResolvedLink` already carries `activationIdentity: Int`, whose stated
  purpose is to distinguish a live run from identical text
  (`TerminalGeometry.swift:35-36`).
- Inference: replacing the field with `(identity: Int, range: TerminalTextRange)?`
  makes the snapshot trivially copyable, which should remove the
  `initializeWithCopy`, `outlined init with copy`, `outlined destroy of
  TerminalResolvedLink?` and `getEnumTagSinglePayload` frames outright and shrink
  the stack probe. That is 42.1% of a 15.79% region -- **~6.6% of total on-CPU on
  `scrollback-stream`**, before any discount.
- Provenance: this is `10/H1(b)`, which doc 10 implemented, measured, and reverted
  as `equivalent` when the node was 1.4% of root -- and which **`10/F8`
  explicitly reopened** on measuring it at 4.7%, filing it as "candidate 4". It
  was never taken. The on-CPU instrument now sizes the same frame at 4.78% self,
  so `sample` was not inflating it.
- Competing interpretation: `10/F4` got this node's attribution wrong once
  before -- it read a surviving memmove as the 932-byte `Terminal` when `10/F8`
  showed it was snapshot construction -- and its recorded lesson is that "when a
  node survives an experiment, the experiment has only excluded what it actually
  varied". The earlier revert varied *layout*; this candidate varies *triviality*,
  which is a different property.
- Correctness risk, stated because it is the reason this is not a trivial change:
  `!=` on the full link compares URIs, and a token comparison would not.
  `TerminalResolvedLink.init(hyperlink:range:)` is public "for clients that do not
  participate in private run identity" (`TerminalGeometry.swift:38-39`), so if
  `hoveredLink` can ever be assigned from that initializer, two different URIs
  could share one identity value and the same range, and a hover change would stop
  damaging. **Unverified here.** The guarding test is behavioral and exists to be
  written: hover two different URIs occupying the same range and assert both
  damage.
- Next action: `D1` candidate **B**.

### F8 -- `TerminalScalars.Storage` traffic is mostly scrollback eviction, not call overhead

- Status: recorded. Sizes `H4` down.
- Measurements: 4.45% of `scrollback-stream`'s total (1,634 ms), 3.10%
  `content-churn`, 3.04% `style-churn`, 1.44% `incremental-mixed` -- the only node
  in all four top-12 lists.
- Attribution by ancestor chain on `scrollback-stream`: **59.4% is nested array
  destruction** (`_swift_release_dealloc -> _ContiguousArrayStorage.__deallocating_deinit
  -> swift_arrayDestroy -> ...`), a further 10.2% under
  `moveAndFillRows -> enforceScrollbackBudget`, 16.0% under `Terminal.print`,
  5.9% under `printNarrow`, and only ~3.4% under the planner
  (`planFrame -> FramePlanner.inspectedCells` and friends).
- Inference: the majority is the scrollback ring freeing evicted rows whose cells
  hold spill storage -- the same traffic `benchmark-memory`'s heap diff reports as
  replacement rather than accumulation (`15`'s reading of it). It is the cost of
  bounded history working correctly, not a removable indirection. `14/D2` already
  took the cross-module half of this node on the render path; what is left on the
  render path is ~3.4% of 4.45%, i.e. ~0.15% of total.
- Inference 2: **`H4` is not exhausted but it is small.** Nothing here justifies
  another pass over the module boundary.
- Next action: none. Ranked last in `D1`.

### F9 -- `applyOutput` spends production time maintaining a 64 KB buffer that only tests read

- Status: recorded. **The cheapest candidate in the sweep, and the one with a
  measurement caveat I created and then caught.**
- Measurement, and the caveat first: stacks inside `applyOutput` but outside the
  `Terminal.feed` subtree total **23.82% of `scrollback-stream`** (8,745 ms).
  **That figure is an upper bound and partly wrong**, because `Terminal.feed` is
  inlined away in some stacks, so feed-internal frames leak into the filter --
  `Terminal.print` (194 ms) and `Terminal.damageActionSnapshot.getter` (298 ms)
  both appear inside it and are unambiguously feed work.
- The unambiguous part, by ancestor chain:
  - `specialized ContiguousArray._reserveCapacityAssumingUniqueBuffer` -- 2.41% of
    total, **95.7% of it directly under `applyOutput`** (846 ms, 2.30%).
  - `specialized IndexingIterator.next` -- 4.54% of total, split 44.2% directly
    under `applyOutput` (737 ms, 2.01%) and 55.7% under
    `Terminal.moveAndFillRows`.
  - Also directly under `applyOutput`: `UnsafeMutablePointer.initialize` 2.62%,
    `Array._getElement` 2.31%, `Array._checkSubscript` 2.31% -- but these names
    also occur in feed's grid access, so they cannot be assigned by symbol alone.
  - So: **lower bound ~4.3% of total, plausible central estimate ~7%, upper bound
    23.8%.** Stack depth reaches 51 in this trace, so these are genuine inlined
    leaves, not truncation.
- Mechanism, from the source (`TerminalPTYHost.swift:1067-1070`), on every PTY
  read chunk:

      recentOutput.append(contentsOf: bytes)
      if recentOutput.count > 64 * 1024 {
          recentOutput.removeFirst(recentOutput.count - 64 * 1024)
      }

  `removeFirst(n)` on an `Array` is O(remaining), so this memmoves up to 64 KB
  down on every chunk, and the `IndexingIterator` / `_checkSubscript` /
  `_getElement` signature says the `append(contentsOf:)` is running an
  element-by-element bounds-checked generic copy rather than a buffer memcpy --
  the same cross-module non-specialization shape as
  `docs/design/2026-07-29-cross-module-value-dispatch.md`.
- **What `recentOutput` is for:** its only readers are
  `waitForOutput(containing:)` (`:456`) and `resumeOutputWaiters` (`:1323`), and
  `waitForOutput`'s own doc comment says **"Test synchronization waits on observed
  bytes rather than elapsed time."** Its only callers in the repo are
  `lib/TerminalPTY/Tests/`. So this is production per-byte work in the PTY hot
  path serving a test-only facility.
- Observation: `Terminal.moveAndFillRows`'s 55.7% slice of the same iterator node
  (~2.53% of total) is a separate cost -- `Array(rows[range])` materializing the
  evicted prefix -- and the source documents why it must materialize: `self.rows`
  cannot be handed to a mutating `appendToScrollback` as a slice
  (`Terminal.swift:5363-5368`). That constraint is real, so it is a harder
  candidate than it looks.
- Inference: no earlier research doc has looked at `TerminalPTYHost` at all. Docs
  9-16 profiled the core and the renderer; the PTY host was never on the map.
- Uncertainty: the central estimate is not measured, only bracketed. **The
  decisive probe is cheap**: delete the two statements, re-trace, and see which
  frames vanish -- which also settles the leak in this finding's own filter.
- Next action: `D1` candidate **C**.

### F10 -- whole-process CPU time is available and provably sums across threads

- Status: recorded. Feasibility evidence for `D2`'s T1; it is a property of the
  platform API, not of DanTerm, so it needed a standalone check rather than a
  guess.
- Date and investigator: 2026-07-29, Claude (agent).
- Method: a scratch Swift binary outside the repo, compiled `-O`, reading
  `task_info(mach_task_self_, task_flavor_t(TASK_ABSOLUTETIME_INFO), ...)` and
  converting `total_user + total_system` through `mach_timebase_info`. It brackets
  a fixed CPU-bound workload run on 1, 2 and 4 concurrent dispatch threads and
  prints wall clock beside the reading. Deleted after measuring.
- Measurements:

  | concurrent threads | wall clock | process CPU reading | ratio |
  | ---: | ---: | ---: | ---: |
  | 1 | 30 ms | 30 ms | 1.00x |
  | 2 | 30 ms | 59 ms | 1.97x |
  | 4 | 30 ms | 120 ms | 4.00x |

- Observation: wall clock is flat while the reading scales linearly with thread
  count. The metric therefore charges work on *every* thread, which is the exact
  property `drawNanosecondsPerDraw` lacks and the reason `F6`'s 16.8% is invisible
  to it.
- Inference: T1 is mechanically sound and needs no new dependency -- the same
  `task_info` idiom is already in tree at `TerminalMemoryProbeSupport.swift:226`
  under a different flavor. What T1 still needs is an A/A calibration before it
  may classify, not a proof of concept.
- Uncertainty: this measured a synthetic CPU-bound load in a separate process. It
  does not prove the reading is *stable enough* per block in the real harness --
  that is precisely what the A/A screening pass in `D2` would establish, and it
  is the step that must not be skipped.
- Next action: `D2`, T1.

### F11 -- T2 shipped; the draw rate is now measured, and the profiler's own window is not what it claims

- Status: recorded. `D2`'s T2, implemented and exercised on a real capture.
- Date and investigator: 2026-07-29, Claude (agent).
- Method: the observer counts *every* `observeCompletedDraw` and
  `observePublishedFrame` call -- before all block gates, since a `loop`-mode app
  never opens a block -- and republishes `(drawCount, planFrameCount,
  uptimeNanoseconds)` at most every 100 ms to
  `DANTERM_TERMINAL_BENCHMARK_ACTIVITY_PATH`. `terminal-benchmark-profile.sh`
  snapshots that file before the profiler attaches and after it detaches, then
  writes `frame-accounting.json`. The env var is set only by the profiling script,
  so a decision block pays one nil check per draw and nothing else -- asserted in
  `terminal-benchmark-harness_test.sh`, which also asserts on line order that each
  snapshot brackets its profiler.
- Artifact: `.build/terminal-benchmark-profiles/2026-07-29-200051-97853/`, a 12s
  `Time Profiler` trace of `full-screen-content-churn`.
- Measurements, from that run's `frame-accounting.json`:

  | quantity | value |
  | --- | ---: |
  | draws per second | 113.19 |
  | plan frames per draw | 1.028 |
  | counted window | 20.12 s |
  | requested profiler window | 12 s |

- Observation: **the counted window overshot the trace by 8.1 s, 67% longer.** The
  100 ms publish cadence cannot explain that; a profiler spends seconds attaching
  and seconds saving, and both snapshots necessarily sit outside all of it. So the
  raw *count* between snapshots is not the count during the trace.
- Inference: the **rate** is the usable output, not the count. Node costs are
  stated per frame as `(share x on-CPU total) / (drawsPerSecond x traceSeconds)`,
  which is sound here only because these are sustained steady-state workloads. The
  schema now separates `measured` from `estimated` and says so in the artifact;
  reading `measured.draws` as "draws in the trace" would overstate by ~67%.
- Second observation, unlooked-for and useful: **`planFrame` runs 1.028 times per
  draw** on `content-churn`, not many times per draw. AppKit coalescing is
  therefore nearly absent in loop mode, which means `F3`'s `planFrame` share
  already *is* a per-draw figure and needs no coalescing correction. It also
  quietly confirms `F5` from the trace side: a damage-blind planner replanning the
  viewport on every published frame would still show 1.0, but the observed cost per
  plan (`F3`: 10.51% inclusive) is far too small for 66 full rows of run-building.
- Uncertainty: one workload, one capture. The rate is not established for
  `scrollback-stream`, whose draws are not serialized the same way. The 1.7x
  proxy disagreement in `F2` is now moot for any *future* capture but is not
  retroactively fixed for the four traces in `F3`.
- Next action: none required. Any future capture gets this for free.

### F12 -- T1 shipped, and the deciding metric sees 11% of what a draw actually costs

- Status: recorded. `D2`'s T1, implemented and measured on real blocks. **This is
  the finding that most changes `D1`.**
- Date and investigator: 2026-07-29, Claude (agent).
- Method: `TASK_ABSOLUTETIME_INFO` (per `F10`) read at block open and at each
  accepted draw; the delta since the previously accepted draw is charged to this
  one, exactly as plan time is accumulated. Emitted as
  `cumulativeProcessCPUNanoseconds` / `processCPUCount` and normalized by
  `terminal-benchmark-validation.py` over the same 50 draws as the draw metric.
  Reported by the comparator through `UNCALIBRATED_BLOCK_METRICS`, which consults
  no rule table and so has no code path to a verdict. Blocks run at commit
  `4ecb032` plus this tooling change, via
  `DANTERM_TERMINAL_BENCHMARK_REDRAW_UPDATES=50 ./scripts/terminal-benchmark.sh <w> swift`.
- Measurements, per accepted draw, ns:

  | workload | draw (main thread) | plan | process CPU (all threads) | CPU / draw |
  | --- | ---: | ---: | ---: | ---: |
  | `content-churn` #1 | 539,990 | 501,189 | 4,879,935 | 9.04x |
  | `content-churn` #2 | 542,193 | 508,564 | 4,973,353 | 9.17x |
  | `content-churn` #3 | 541,884 | 510,489 | 5,153,560 | 9.51x |
  | `style-churn` | 546,050 | 514,344 | 5,155,702 | 9.44x |
  | `incremental-mixed` | 85,805 | 65,584 | 1,993,000 | **23.23x** |

- Observation: on `content-churn` the deciding metric brackets **11%** of the CPU
  the process burns per accepted draw. Draw plus plan together reach 21%; the
  other **79% is in no bracket**. On `incremental-mixed` the deciding metric
  brackets **4.3%**.
- Observation: `blockProcessCPUNanoseconds` equalled the summed interval series in
  all five blocks, so the 50 intervals accounted for each block with zero dropped
  samples across 250 intervals. The seed-at-block-open and monotonicity guard both
  behave.
- Inference: this is `F6`'s blind spot measured on the deciding benchmark's own
  denominator instead of a diagnostic profiler's. It is a stronger statement than
  `F6`: not "16.8% of on-CPU samples sit outside the bracket" but "an `equivalent`
  verdict on `content-churn` constrains one ninth of the per-draw cost, and on
  `incremental-mixed` one twenty-third."
- **Do not over-read it.** The interval between accepted draws contains everything
  the process did in it -- the previous draw's replay, parsing, planning, the
  observer's own acks. It is not "the draw is 9x more expensive than we thought";
  it is "per-frame cost is 9x the draw bracket, and the bracket was never claiming
  otherwise." The ratio's value is as a denominator, not as an indictment.
- Uncertainty, and the reason this metric still classifies nothing:

  | metric | spread across 3 `content-churn` blocks |
  | --- | ---: |
  | draw ns/draw | 0.41% |
  | plan ns/draw | 1.85% |
  | **process CPU ns/draw** | **5.60%** |

  The CPU metric's block-to-block spread is **14x the draw metric's**. Its
  threshold will have to be far looser, and three sequential unpaired blocks are
  not a paired A/A screen -- they establish the order of magnitude of the noise,
  not the rule. Anything smaller than ~6% is currently indistinguishable from
  nothing.
- Next action: `D3`.

### F13 -- candidate B taken and accepted: two `faster` verdicts, and the pitched implementation was wrong

- Status: recorded. **`D1` candidate B implemented, measured, accepted.** The first
  code candidate this file has spent a benchmark on.
- Date and investigator: 2026-07-29, Claude (agent).
- Direction gate: satisfied by user instruction ("continue", following the message
  that ended "Ready for candidate B when you are"). Recorded because the
  investigation rules forbid implementing a code candidate without one, and a gate
  must not look self-opened.
- What shipped, and it is **not what `F7` and `D1` specified.** Both pitched
  replacing the field with `(identity: Int, range: TerminalTextRange)`. That
  implementation is wrong, and the guarding test proved it before any benchmark ran:
  built exactly as pitched, it recorded `rows: []` where `rows: [0]` is required.
  - Mechanism of the defect: `activationIdentity` is `max(contentIdentity)` over the
    range's cells (`Terminal.swift:2330-2344`), so it is a function of the *cells*,
    never of the URI. Two links can share a range and an identity while differing in
    target -- the OSC 8 shape, where the URI is metadata rather than visible text.
    `F7` listed this as a "correctness risk ... **Unverified**"; it is now verified,
    and it is a defect in the pitch rather than a risk in the change.
  - What shipped instead: `hoveredLinkRange: TerminalTextRange?` plus
    `hoveredLinkRevision: UInt64`, a counter advanced by `hoveredLinkState`'s
    existing `didSet`. It compares no values, so no token needs to be a function of
    the URI. It advances even on a write that stores an equal value, so the diff
    over-reports rather than under-reports -- a redundant repaint of the hovered
    rows, never a missed one.
  - The range comparison is retained and is **not** redundant with the revision:
    scrollback eviction reindexes rows without touching `hoveredLinkState`, so the
    same anchors can name different viewport rows with no mutation to notice. Both
    conditions are live for different reasons.
- Structural result, measured rather than assumed (`_isPOD` via a temporary hook,
  since removed):

  | | POD? | size | stride |
  | --- | --- | ---: | ---: |
  | before | **false** | 190 | 192 |
  | after | **true** | 166 | -- |

  Two snapshots exist per parser action, so this is also 48 fewer bytes of stack
  traffic per action -- relevant to `F7`'s `___chkstk_darwin` observation, though
  nothing here isolates that term.
- Verdicts, `just benchmark-confirm baseline=HEAD` at baseline `e4298bf`, candidate
  tree `bc13d2f67132`:

  | workload | verdict | symmetric median | pairs |
  | --- | --- | ---: | ---: |
  | `terminal-feed` | **faster** | **-14.59%** | 2 |
  | `scrollback-stream` | **faster** | **-10.78%** | 4 |
  | `content-churn` | equivalent | +0.22% | 4 |
  | `style-churn` | equivalent | -0.31% | 4 |
  | `incremental-mixed` | inconclusive | -1.09% | 6 |

  A prior single-workload `quick` on the same tree returned `faster` -8.30%
  (-8.45% / -8.14%, no outliers), so `scrollback-stream` reproduced its own
  direction across two independent runs at different pair counts. Artifacts:
  `.build/terminal-benchmark-comparisons/confirm/bc13d2f67132-0000`.
- Both `faster` workloads are the two `F7`/`D1` named in advance as the ones that
  could see it. Neither churn workload regressed, which matters because
  `recordDamage` runs on every workload.
- **On the magnitude, against this file's own rule.** `F7` predicted "~6.6%", a
  share of `scrollback-stream`'s on-CPU total. The verdicts above are reductions in
  each workload's *deciding* metric -- time-to-final-draw for the two `faster` ones.
  Those are different denominators, so this is a confirmed direction landing in the
  same neighbourhood, **not** a prediction beaten by 4 points. The investigation
  rule "convert a share to the deciding benchmark's own denominator before
  predicting a win" is exactly about not conflating these, and `F7` did not do that
  conversion.
- The Phase 4 instrument did not decide this. `scrollback-stream` and
  `terminal-feed` decide on completion time, so they carry no per-draw auxiliary
  line at all; the frozen draw rule decided B, as `D3` said it would.
- Observation worth exactly its weight, no more: on the three serialized-draw
  workloads the new process-CPU metric moved negative in every case (-1.63%
  `content-churn`, -1.05% `style-churn`, -3.88% `incremental-mixed`) while two of
  the three draw verdicts were `equivalent`. Consistent in sign across 14 pairs. It
  is **not evidence** -- the metric has no frozen rule and `F12` put its unpaired
  block spread at 5.60%, above two of these three magnitudes. Pairing cancels drift
  that unpaired blocks do not, so the paired sensitivity is probably better than
  5.60%, but "probably better" is not a threshold. This is precisely the reading the
  A/A screen in `D3` would make legitimate.
- Next action: `D4`.

### F14 -- candidate C refuted, and `F9`'s sizing method was unsound

- Status: recorded. **`D1` candidate C measured and rejected.** The diagnostic
  `F9` asked for was run; it refuted both the candidate and the reasoning that
  sized it. Diagnostic reverted; the tree is unchanged by this finding.
- Date and investigator: 2026-07-29, Claude (agent).
- Method: the experiment `F9` specified. Comment out the two statements at
  `TerminalPTYHost.swift:1067-1070`, re-trace `scrollback-stream`, record which
  frames vanish. Baseline `2026-07-29-204444-50228` at commit `0e5d7f4`, candidate
  `2026-07-29-204807-53130`, both `just benchmark-trace scrollback-stream "Time
  Profiler" 30`, run sequentially. **Build verified before reading the result** --
  the candidate's `harness.log` shows `Compiling TerminalPTYHost` and
  `Linking DanTerm` -- because "no change" and "no rebuild" produce identical
  output.
- Result: **nothing vanished.**

  | | baseline | candidate | delta |
  | --- | ---: | ---: | ---: |
  | `applyOutput` own body | 14.95% | 15.24% | +0.29 pts |
  | `Array._checkSubscript` | 2.88% | 3.06% | +0.18 |
  | `UnsafeMutablePointer.initialize(to:)` | 2.67% | 2.75% | +0.08 |
  | `_reserveCapacityAssumingUniqueBuffer` | 2.47% | 2.64% | +0.16 |
  | trace total, ms | 37,177 | 37,203 | +0.07% |

  A prediction of 8-9% was registered before the run. It was wrong, and a change of
  that size cannot hide in a folded profile.
- Paired verdicts on the **maximal** form of C (full deletion, so these bound all
  three shapes `D1` listed), baseline `0e5d7f4`:

  | workload | `quick` | `confirm` |
  | --- | --- | --- |
  | `scrollback-stream` | inconclusive **-2.65%** (2) | inconclusive **+0.85%** (4, 2 outliers flagged) |
  | `terminal-feed` | -- | equivalent -0.03% (2) |
  | `content-churn` | -- | inconclusive -1.40% (4) |
  | `style-churn` | -- | **faster -3.02%** (4) |
  | `incremental-mixed` | -- | inconclusive -0.98% (6) |

- **The sign flipped on the workload C should most affect** -- `scrollback-stream`
  went -2.65% at 2 pairs to +0.85% at 4. That is what a null effect looks like when
  read at insufficient power, and it is the reason `quick`'s inconclusive was
  escalated rather than closed.
- **`style-churn`'s `faster` is not evidence for C, and the Phase 4 metrics are how
  we can tell.** Its plan time moved -3.08% and its process CPU -3.07%, against the
  draw metric's -3.02% -- three regions shifting by the same amount. `recentOutput`
  has no causal path to *plan* time, so a uniform shift across unrelated regions is
  an arm-level artifact, not a targeted win. This is the first time the uncalibrated
  CPU metric has changed a reading: without it, a lone `faster -3.02%` on one
  workload would have looked like partial support for C. It carries no verdict and
  it did not need one -- it was used as a **consistency check**, which is a use `D2`
  did not anticipate.
- **`F9`'s sizing was measuring the wrong thing, and so was my first replacement
  for it.** Both derived a bound by subtracting the `Terminal.feed(_:)` frame from
  `applyOutput`. That subtraction is unsound on these traces: `Terminal.feed(_:)`
  is **partially inlined**, present as a frame in some stacks (52.87%) and elided in
  others. The proof is in the folded stacks --
  `Terminal.moveAndFillRows < TerminalPTYHost.applyOutput` with no feed frame
  between them, i.e. scrollback movement, which is feed's own work, presenting as
  `applyOutput`'s child. So:
  - `F9`'s "`applyOutput` minus `Terminal.feed` = 23.82% upper bound" is not a bound
    on non-feed work.
  - The 14.95% figure computed here by excluding engine-named descendants is
    contaminated the same way, one level deeper: inlined feed carries no
    `Terminal.*` frame to exclude. **It should not be cited as a bound either.**
  - `applyOutput`'s body contains no per-byte loop besides the deleted one, so the
    per-byte array frames under it are the parser loop.
- Generalizable lesson, and it outlives this candidate: **under partial inlining,
  subtracting a frame does not subtract that function's work**, and no amount of
  care with folded stacks repairs it -- the discriminating frame is gone. Sizing a
  region by frame subtraction needs a check that the region's *callees* are absent
  too. Ablation (delete it and re-measure) does not have this failure mode, which is
  the one thing `F9` got right in asking for the experiment rather than trusting its
  own number.
- What survives: `recentOutput` is still production work maintained for a test-only
  facility. That is a **cleanliness** argument, and `D1` ranked C on performance.
  Nothing here recommends spending the `waitForOutput` decision on it.
- Next action: `D5`.

### F15 -- the CPU metric is screened and cannot be calibrated: both gates cannot be met at once

- Status: **closed.** The A/A screen `D2` deferred and `D5` promoted is done. The
  answer is that `processCPUNanosecondsPerDraw` earns **no rule on any workload in
  either mode**, and this is a measured refusal rather than an unfinished search.
- Method: `scripts/terminal-benchmark-plan-calibration.py --metric process-cpu
  --revision HEAD --quartets 12`, generalized for this run so the calibrator names
  a metric instead of reaching into one hardcoded table (see below). 12 quartets =
  **24 A/A pairs** per workload, both roles bound to one immutable arm root, so
  every difference is machine and schedule noise with no code difference present.
  Zero quartets discarded. 443s of machine time, 20,000 resampling trials per
  searched cell.
- The series, against the plan-time series that *did* freeze a rule:

  | Workload | CPU median | CPU SD | CPU range | plan SD (frozen) |
  | --- | --- | --- | --- | --- |
  | `content-churn` | -0.84% | **1.88%** | -3.02%..+3.77% | 1.48% |
  | `style-churn` | +0.60% | **3.52%** | -8.54%..+4.44% | 1.22% |
  | `incremental-mixed` | +1.23% | **8.75%** | -27.63%..+13.23% | 5.75% (no rule) |

- **Why nothing clears, stated precisely.** The two accuracy gates cross with no
  overlap: the threshold where the false-positive rate falls to the 1% gate is
  already above the threshold where detection is still 90%. `content-churn`/`quick`
  is the closest case in the whole grid and it misses by a knowable margin:

  | Threshold | A/A false positives (gate <=0.01) | Detection at 5% (gate >=0.90) |
  | --- | --- | --- |
  | +/-2.5% | 0.0855 | 0.9568 |
  | +/-2.75% | 0.0855 | 0.9139 |
  | **+/-3.0%** | **0.0000** | **0.8320** |

  So at the first threshold quiet enough, detection has already fallen 7 points
  under its gate. `content-churn`/`confirm` fails from the other side -- +/-2.5%
  gives false positives 0.0084, which *clears*, with detection 0.5954 against a 3%
  effect. `style-churn` never reaches the false-positive gate until +/-5.75%, where
  detection is 0.2485. This is the same shape of answer plan time gave for
  `incremental-mixed`, one workload wider.
- **The pair count is not available as a fix.** An auxiliary metric rides the
  deciding metric's own blocks, so the only pair count a CPU rule could ever be
  applied at is the one that mode already collects (2, 4, or 6). Buying more pairs
  means changing what a `quick` or a `confirm` *is*, which is a different decision
  from calibrating a metric.
- **The retro-test, and it is why this screen was worth the 443s even though no
  rule came out of it.** `F14` read `style-churn`'s lone `faster` verdict (-3.02%
  draw, -3.07% CPU, -3.08% plan) as arm-level drift, on a mechanism argument and
  without a repeat run. This series prices that call: **5 of 24 A/A pairs sit at or
  below -3.02%** on `style-churn` with no code difference at all, and the resampled
  median-of-4 rule at a +/-3.0% threshold produces a directional verdict on **5.91%
  of pure-noise runs**. A -3% CPU move on that workload is a one-in-seventeen event
  under noise -- not rare, entirely consistent with drift, and exactly the size that
  needs corroboration rather than a face-value reading. `F14`'s judgement stands,
  and is now quantified instead of argued.
- **A prediction registered before the report was read, scored honestly.** Four
  predictions; the direction held on all four, the magnitude was wrong on two.
  Correct: the CPU spread is wider than plan time's on every workload; `confirm`
  earns a rule on none; `incremental-mixed` is the worst; `F14`'s -3.02% falls
  inside the A/A band. Wrong: I put the SD band at 2.5%-5%, and `content-churn`
  came in *under* it at 1.88% while `incremental-mixed` came in at 8.75%, well over.
  I also expected `quick` to be the likelier place a rule would clear on a churn
  workload; nothing cleared there either.
- **`incremental-mixed` carries one pair at -27.63%**, more than three times its own
  SD and roughly twice its next-worst pair. A single block whose scheduler luck ran
  out dominates that workload's spread. Not excluded: the calibration's whole job is
  to measure this distribution as the harness actually produces it, and a screen
  that trims its own worst observation would understate the false-positive rate it
  exists to bound.
- Tooling shipped alongside, and its one real risk: the calibrator now takes
  `--metric {plan,process-cpu}`, selecting from a new
  `COMPARE.CALIBRATABLE_METRIC_TABLES` registry. Both quantities ride the *same
  blocks*, so a generalization that kept silently reading `planNanosecondsPerDraw`
  would have reported plan-time noise under a CPU heading and nothing in the numbers
  would have looked wrong. That is the test that was written first and failed first.
  Report and default artifact directory are named per metric, which leaves plan
  time's existing `plan-calibration.json` path -- cited by doc 8, which is
  append-only -- undisturbed.
- Artifacts: `.build/terminal-benchmark-process-cpu-calibration/67cf8d58a35e-0000/`
  (`process-cpu-calibration.json`, `blocks.json`). Disposable; the report carries
  the full 24-pair series per workload, so the grid can be re-searched with
  `--reanalyze` without re-measuring.

### F16 -- `F6` passes the elasticity bar at 95% of linear, and the draw rate never moves

- Status: **closed.** The test `F6` recorded as its own unmet bar, and the one
  `11/F12` used to *refute* two earlier mechanisms, has now been run against `F6`.
  **It passes.** Candidate A's attribution is confirmed elastic.
- Date and investigator: 2026-07-29, Claude (agent).
- Method: two 30s Time Profiler captures of `full-screen-content-churn` at HEAD,
  differing only in grid geometry -- **179x66 (11,814 glyph occurrences per frame)
  and 80x25 (2,000)**, a 5.907x lever. The producer generates the screen from the
  live geometry (`scripts/terminal-benchmark-producer.py:73`), so the small run is a
  genuinely smaller full-screen churn, not a cropped one. Deciding quantity is
  **absolute microseconds in the `get_glyph_bboxes` subtree per accepted draw**,
  normalized by T2's published draw rate -- a normalization that did not exist
  before `F11`.

  | Quantity | 179x66 | 80x25 | Ratio |
  | --- | ---: | ---: | ---: |
  | Glyph occurrences per frame | 11,814 | 2,000 | 5.907x |
  | `get_glyph_bboxes` us/draw | **801.0** | **142.5** | **5.62x** |
  | `CA::CG::DrawGlyphs::compute_dod_` us/draw | 874.6 | 158.4 | 5.52x |
  | `get_glyph_bboxes` share of on-CPU | 16.37% | 4.15% | -- |
  | Whole-trace on-CPU total | 17,479 ms | 12,288 ms | 1.42x |
  | Draw rate | 119.10/s | 119.32/s | **1.00x** |

- **Elasticity: 5.62x against a 5.907x lever, or 95.1% of linear.** Per occurrence
  the cost is 67.8 ns at the large geometry and 71.3 ns at the small one -- a 5%
  per-occurrence premium at 2,000 glyphs, which is the per-op fixed cost showing
  through and bounds how much of the node is *not* addressable by drawing fewer
  glyphs. `F6`'s mechanism is right: this is paid per glyph occurrence per frame.
- **Replication, which this file's first caveat asked for.** The large-geometry
  capture is a second `content-churn` profile on a different commit: `F6` measured
  `get_glyph_bboxes` at 16.78% of on-CPU, this one at 16.37%. The self-frame split
  inside the subtree is also stable across *both* geometries here
  (`TGlyphOutlineDictionaryCache::Copy` 32.8% and 33.3%). **It is not stable against
  `F6`, which reported 48.4%** -- a denominator discrepancy this test does not
  resolve; treat `F6`'s split as the less trustworthy of the two, since this one is
  reproduced twice.
- **The finding nobody asked for, and it changes what candidate A is worth: the
  draw rate does not move.** 119.10/s and 119.32/s across a 5.9x change in
  per-frame glyph work. On this machine's built-in 120Hz ProMotion panel that is
  the refresh cap, and the app is sitting on it at both geometries. So at 179x66
  the process is paying 801 us/draw of pool-thread glyph-bounds work **and still
  making every frame**. Removing that cost cannot raise the frame rate of this
  workload, because the frame rate is not what it is limited by.
- Inference: this is direct evidence for `F6`'s competing interpretation 1, which
  it listed as "not excluded". **The win from candidate A is energy and thermal
  headroom, not latency** -- on a laptop, battery. That is a real win and a
  materially different one from the "largest cost in the app" framing, which
  invites a reader to expect frames.
- Inference 2, and it is the awkward one: **no instrument this project owns can
  return a verdict on candidate A.** The deciding draw metric brackets main-thread
  work and this cost is on the pool (`F12`); the frame rate is pinned, so no
  throughput metric moves; and `F15` established that
  `processCPUNanosecondsPerDraw` cannot be calibrated at any mode's pair count.
  Note also that with the draw rate constant, per-draw and per-second
  normalizations of the CPU metric differ only by a constant, so re-denominating it
  buys no noise reduction. `D7` takes this up.
- **Predictions registered before either trace was read, scored honestly. Two of
  four were wrong.**
  1. *"ms/draw falls 3x-6x"* -- **correct**, 5.62x, at the top of the range.
  2. *"the subtree's share stays within a few points of 16.8%, so a share-only
     reading would look like nothing happened"* -- **wrong, and backwards.** The
     share fell 16.37% -> 4.15%, because the rest of the trace is largely *not*
     glyph-elastic: the total fell only 1.42x. The share statistic would have shown
     this effect plainly. Per-draw normalization was still the right choice, but the
     reason I gave for needing it does not hold.
  3. *"draw rate rises at the small geometry"* -- **wrong**, and this is the wrong
     prediction worth having made. It did not move at all, which is what surfaced
     the refresh cap and Inference 1. I had assumed the workload was CPU-bound.
  4. *"`TGlyphOutlineDictionaryCache::Copy` stays dominant at ~48%"* -- **half
     right**: dominant and stable across geometries, but at ~33%, not `F6`'s 48.4%.
- **Limitation, stated before the result and unchanged by it:** the geometry lever
  varies glyph occurrences and `DrawGlyphs` ops *together*, so this cannot separate
  per-occurrence from per-op scaling. It answers what candidate A turns on -- does
  the node move with content -- and not the finer question. The 5% per-occurrence
  premium at the small geometry is the only per-op evidence here.
- **What this does not fix:** both captures ran in loop profiling mode with
  `DANTERM_TERMINAL_BENCHMARK_REDRAW_UPDATES=1000000`, so per-frame glyph counts are
  at maximum in both arms. The *elasticity* result transfers to live use -- the cost
  is proportional to glyphs drawn, whatever that number is -- but the **16.4%
  magnitude does not**, and `F6`'s second competing interpretation stands unresolved.
- Artifacts: `.build/terminal-benchmark-profiles/2026-07-29-213635-10866/` (179x66)
  and `.../2026-07-29-213852-13142/` (80x25).

### F17 -- the draw path is damage-scoped, and `F6`'s 16.8% is mostly loop mode's own stimulus

- Status: **closed, and it retires `F6`'s magnitude.** The live-sizing capture `D7`
  named as the cheapest next step. The mechanism `F16` confirmed is real; the
  *number* attached to it is not a property of the app.
- Date and investigator: 2026-07-29, Claude (agent).
- Method: a third 30s Time Profiler capture at the same 179x66 geometry, on the
  `localized-draw-acceptance` workload -- **one damaged row per update against a
  dense styled screen**, versus `F16`'s forced full-viewport republication. A ~66x
  occurrence lever if the draw path scopes to damage, more than ten times `F16`'s.
  Required a new profiling workload case; see the tooling note below.

  | Stimulus at 179x66 | `get_glyph_bboxes` us/draw | Share of on-CPU | Draw rate |
  | --- | ---: | ---: | ---: |
  | Forced full redraw (`F16`) | **801.0** | 16.37% | 119.10/s |
  | One damaged row | **27.3** | 0.42% | 97.85/s |
  | Ratio | **29.3x** | | |

- **The draw path is damage-scoped.** At `F16`'s measured 67.8-71.3 ns per glyph
  occurrence, 27.3 us/draw implies **~390 occurrences per frame** against a
  179-cell damaged row -- about 2.2 rows' worth. So the view does not rebuild the
  whole viewport's display list for a one-row change; it draws the damaged row plus
  roughly a row of halo. This answers a question `F5` left open for the draw side:
  planning is damage-scoped, and so is drawing.
- **Triangulation, and it is what makes this decisive.** `F17` is not the only
  non-forced measurement. `F3` already put `get_glyph_bboxes` at **1.85% on
  `scrollback-stream`**, which runs with `redraw_updates=0` and replays a real
  corpus. Two independent realistic stimuli therefore say 0.42% and 1.85%; the only
  stimulus that says 16.8% is the one that republishes every glyph on the screen
  120 times a second. **`F6`'s headline number is a property of the benchmark, not
  of DanTerm.**
- Inference: **candidate A's live value is one to two orders of magnitude below its
  pitch.** It scales with glyphs actually redrawn per second, so it approaches
  `F6`'s figure only for a full-screen animated TUI at high frame rate, and sits
  near 0.5-2% for typing, scrolling, and streaming output. `D8` acts on this.
- **Share versus absolute, and why only one of these numbers is safe.** The 0.42%
  share is deflated by instrument: this trace is dominated by the per-draw
  acknowledgment write (`_convertJSONString` 4.78%, `CFStringCompareWithOptions...`
  3.49%, `__open` 2.51%, `__rename` 2.03%), because the localized producer
  serializes on a JSON ack file per update and the real work per draw is tiny. The
  **absolute 801.0 -> 27.3 us/draw is the robust comparison**, and it is
  apples-to-apples: both stimuli pay the same per-draw ack cost, so it cancels in
  the per-draw figure and does not cancel in the share.
- **Predictions registered before the trace was read; three of four correct.**
  1. *"falls to a few percent at most, plausibly under 1%"* -- **correct**, 0.42%.
     My arithmetic estimate of ~12 us/draw was 2.3x low, because I assumed exactly
     one row of damage and the real figure is ~2.2 rows.
  2. *"not to zero, and the floor is the interesting number"* -- **correct**, and
     the floor is the halo: ~390 occurrences where the damaged row holds 179.
  3. *"the alternative outcome: the subtree stays near 801 us/draw, meaning the
     draw path is not damage-scoped"* -- **did not happen.** It is scoped.
  4. *"I do not predict the draw rate holds at ~119/s"* -- **correct** not to; it
     fell to 97.85/s, set by the ack round trip rather than the panel.
- Tooling: `scripts/terminal-benchmark-profile.sh` gained a
  `localized-draw-acceptance` case, since the three churn workloads all hardcode
  forced republication and there was no way to profile a damage-scoped stimulus.
  It also **fixed a provenance bug `F16` exposed**: `fixtureIdentity` hardcoded
  `179x66`, so `F16`'s 80x25 artifact claimed a fixture it had not run. The
  identity now derives the geometry, and the contract test refuses the literal.
- Artifacts: `.build/terminal-benchmark-profiles/2026-07-29-214810-22895/`.

## Decision log

### D1 -- which CPU opportunity to take first

- Status: **recommendation recorded; awaiting user direction.** Nothing
  implemented, no paired benchmark spent.
- Evidence used: `F1` through `F9`.

#### The ranking

Impact is the node's inclusive share of its **best** workload's on-CPU total, and
"decidable" is whether a frozen benchmark rule can accept or reject the change.
That column is the one that should change how the list is read.

| # | Candidate | Measured size | Decidable? | Risk |
| --- | --- | ---: | --- | --- |
| A | Stop CA recomputing per-glyph bounds (`F6`) | 16.8% `content-churn`, up to 23.2% with the rest of replay | **No** -- in no bracket (`F2`) | High, architectural |
| B | Make `DamageActionSnapshot` trivially copyable (`F7`) | ~6.6% `scrollback-stream` | Yes -- `scrollback-stream`, `terminal-feed` | Low-moderate; one named correctness risk |
| C | Stop maintaining `recentOutput` in production (`F9`) | ~4.3% floor, ~7% central, 23.8% ceiling | Yes -- `scrollback-stream` | **Lowest**; test-only facility |
| D | Correct the stale planner docs (`F5`) | 0% | n/a | **None** |
| E | Cache glyph ids instead of per-frame cmap lookup (`9/H3`) | 1.67% `content-churn` (16% of `drawTextRuns`) | Marginal -- near `quick`'s floor | Low |
| F | `moveAndFillRows`'s evicted-prefix `Array(...)` (`F9`) | ~2.5% `scrollback-stream` | Yes | Moderate -- exclusivity constraint is documented and real |
| G | Remaining `TerminalScalars.Storage` traffic (`F8`) | ~0.15% attributable | No | n/a -- do not take |

#### Candidate A -- the largest, and the one I do not recommend starting with

Three shapes, in increasing cost:

1. **Give CA an image instead of glyph ops.** `wantsUpdateLayer` + `updateLayer()`
   setting `layer.contents` from a persistent `CGBitmapContext` DanTerm
   rasterizes into, redrawing only damaged rows. Removes `compute_dod_` (16.8%),
   `FillGlyphs` (3.5%) and `OGL::GlyphCache` (2.1%) -- but **takes on glyph
   rasterization that CA is currently doing on the GPU** (`CA::OGL::GlyphCache ->
   MetalContext::draw` is in the trace). Net sign genuinely unknown.
2. **Reduce what CA must bound.** Worth an hour of investigation before (1):
   whether a tighter per-op clip, or one `DrawGlyphs` op per row rather than per
   run, changes `compute_dod_`'s cost. Cheap to test, and if bounds cost is per
   occurrence (`F6` says it is) this fails -- which is worth knowing for 30
   minutes' work.
3. **The GPU renderer.** `10/F9` named the renderer gap -- libghostty composites a
   GPU-rendered `IOSurfaceLayer` while DanTerm rasterizes on the CPU -- and called
   sizing it the thing that should outrank finishing doc 10's list. `F6` is that
   sizing, from the other side. This is a rewrite, and `11`'s standing warning
   applies: *this must not become a rewrite proposal by momentum.*

Why not first, despite being 2.4x the next candidate: it is undecidable by any
frozen rule (`F2`), its elasticity is unconfirmed (`F6`'s uncertainty), and
`11/F12` already refuted two plausible compositing mechanisms with pre-registered
predictions. Taking it first means building an instrument before knowing whether
the cost is recoverable latency or concurrent energy.

#### Candidate B -- the one I recommend

Replace `hoveredLink: TerminalResolvedLink?` in the snapshot with the identity and
range `recordDamage` actually reads (`F7`).

- Expected benefit: removes four value-witness frames totalling 42.1% of a 15.79%
  region. Converted to `scrollback-stream`'s own denominator, ~6.6% of on-CPU;
  converted to the paired benchmark's, this lands where `terminal-feed` and
  `scrollback-stream` can both see it. `14/F11` says an on-CPU share of
  *deletable* work needs no optimism discount, and these frames are deletable
  rather than relocatable -- a trivially copyable struct has no
  `initializeWithCopy`.
- Tradeoffs: the snapshot stops carrying the hovered URI, so any future damage
  rule that needs it must reach for the terminal's own state.
- Correctness risk and its test: identity collision across distinct URIs at the
  same range, via the public non-identity initializer (`F7`). Write the failing
  behavioral test first -- hover two different URIs occupying one range, assert
  both damage -- and verify it fails against a naive token comparison.
- Smallest useful first experiment: change the field, run the core suite, then
  `just benchmark-quick baseline=4ecb032 workload=scrollback-stream`. It is the
  smallest because it is one field on one private struct, it needs no new
  instrument, and a frozen rule decides it.

#### Candidate C -- the cheapest, and worth doing alongside B

`recentOutput` is production per-byte work for a test-only facility (`F9`).
Three shapes:

1. **Ring buffer.** O(chunk) instead of O(64 KB) per chunk, semantics byte-identical.
   Safest, keeps `waitForOutput` working for tests that register a waiter after
   the bytes arrived (which `:456` supports on purpose).
2. **Reserve + drop the generic append.** Copy through
   `withUnsafeBufferPointer`, keep `removeFirst`. Removes the per-byte traffic,
   keeps the memmove.
3. **Gate it off in production**, alongside `captureTransitions`. Largest win,
   and it changes what a test-only facility depends on -- so it needs a decision
   about whether `waitForOutput` must work in a shipping build.
- First experiment, and it doubles as the measurement `F9` lacks: delete the two
  statements, re-trace `scrollback-stream`, and record which frames vanish. That
  turns the 4.3-23.8% bracket into a number and simultaneously fixes the leak in
  `F9`'s filter. Then implement (1) and decide with `benchmark-quick`.

#### Candidate D -- free, and it stops the next agent repeating my mistake

`agent-docs/terminal-performance.md` states the planner plans the whole viewport
regardless of damage and that planning is the larger cost in both churn
workloads. `F5` shows the mechanism landed in `8188b9a`, three days after that
text. Doc 9's Phase 5 note carries `9/H2` as evidenced and unrefuted for the same
reason. Both need a correction, and neither is this file's to make unilaterally.

- Direction review: pending.
- Selected direction: pending.
- Behavioral verification: pending.

### D2 -- fix the instrument before spending candidate A

- Status: **recommendation recorded; awaiting user direction.** Raised because
  `D1` ranked a 16.8% opportunity below a 6.6% one purely on decidability, which
  is an argument for fixing the instrument rather than for accepting the ranking.
- Evidence used: `F2` (the three gaps), `F6` (the cost that falls in them), `F10`
  (the mechanism is verified).

#### T1 -- add whole-process CPU time per accepted draw as an auxiliary metric

**This is the one that makes candidate A decidable, and it is small.**

- What it measures: the delta in *whole-task* CPU time across a measured block,
  divided by that block's accepted-draw count. Because it sums every thread, it
  contains CA's display-list replay, the GPU-submit path, and the pool's share of
  feed work -- everything `drawNanosecondsPerDraw` structurally cannot see (`F2`).
- Why it fits without redesign: **plan time is the precedent.** The block
  evidence JSON already carries `cumulativeDrawNanoseconds` / `drawCount` beside
  `cumulativePlanNanoseconds` / `planFrameCount` (`app/TerminalBenchmark.swift:450-461`),
  and `scripts/terminal-benchmark-compare.py` already separates a deciding
  `BLOCK_METRICS` from an `AUXILIARY_BLOCK_METRICS` reported beside it with its own
  frozen rule (`:50-67`). T1 is a third entry in exactly that shape -- one reading
  at block start, one at block end, one derived field, one auxiliary metric.
- Mechanism: verified, see `F10`. `task_info(mach_task_self_,
  TASK_ABSOLUTETIME_INFO, ...)`, converted through `mach_timebase_info`. The
  same `task_info` idiom is already in tree at
  `TerminalMemoryProbeSupport.swift:226` with a different flavor, so this adds no
  new dependency and needs no entitlement.
- What it costs to trust: **an A/A calibration before it may classify anything.**
  Per this project's own rule a frozen threshold comes from a screening pass a
  human signs off, as `scripts/terminal-benchmark-plan-calibration.py` does for
  plan time. Until then T1 reports a bare percentage marked `no verdict` -- which
  is still strictly better than today, where the quantity does not exist.
- Four limits to state in the doc when it lands, because each one invites a
  misreading:
  1. **CPU time is not latency.** A change that moves work off the critical path
     onto an idle core reads as neutral. T1 answers "did we stop doing work",
     which is the right question for `F6` and the only question that maps to
     battery -- but it is not a frame-time metric and must not be read as one.
  2. **It includes the instrument.** The observer costs 3.2-9.8% of on-CPU
     (`F2`), so it sits inside T1 and dilutes any percentage effect. Plan time has
     the same property; it is a reason to calibrate, not to abandon.
  3. **Replay can cross a block boundary.** Frame N's replay may finish after
     frame N+1's start. Over 50 serialized accepted draws that is an edge effect,
     not a bias, but a block of 1 would be meaningless.
  4. It will make `incremental-mixed`'s ack cost (`F2`) *visible in a decision
     metric* for the first time. That is a feature, and it may well be the first
     thing T1 reports.

#### T2 -- publish a draw counter from loop/profiling mode

Fixes `F2`'s worst methodological gap: **three frame-count proxies disagree by
1.7x**, so no trace in this file can be normalized per draw, which is why `F5`
had to rest on commit provenance instead of on its own measurement. The counters
already exist in benchmark mode (`drawCount`, `planFrameCount`); loop mode simply
does not publish them. Writing a running count into the profile artifact
directory would let every future trace divide by frames -- retroactively raising
the value of every capture, and it is the cheapest item here.

#### T3 -- an on-CPU trace mode for the headless feed harness

`terminal-feed` has no on-CPU instrument at all (`F2`), so doc 10's entire
ranking still cannot be re-sized on its own boundary -- the standing
research-README warning tells agents to do exactly that and there is no tool for
it. `scripts/terminal-feed-profile.py` already publishes a pid and shells out to
`sample`; adding an `xctrace` path alongside is mostly mechanical, and the report
parser it would feed (`scripts/terminal-profile-report.py`) already accepts both
input shapes.

- Recommendation: **T2, then T1, then reconsider `D1`'s ranking.** T2 is nearly
  free and improves every capture. T1 is the one that converts candidate A from
  "edit the renderer on faith" into a decidable experiment, and until it exists
  the honest ranking puts a 6.6% win above a 16.8% one. T3 is real but serves a
  question nobody is currently asking.
- Tradeoff worth naming: T1 and T2 are work that produces no user-visible
  improvement. The case for them is that `F6` found the largest cost in the app
  by accident, with an instrument the project's own contract labels
  diagnostic-only -- and a survey should not be the only thing that can see the
  biggest number.
- Direction review: 2026-07-29, user directed "continue", i.e. take the
  recommendation as written.
- Selected direction: **T2 and T1 implemented in that order; T3 not taken.**
  Results in `F11` and `F12`; the ranking is re-read in `D3`. Two of the four
  limits stated above are now measured rather than predicted: limit 2 (the
  instrument is inside the metric) shows up as the CPU metric's 5.60% block
  spread against the draw metric's 0.41% (`F12`), and limit 4 is confirmed --
  `incremental-mixed`'s deciding metric brackets 4.3% of its per-draw CPU, the
  worst ratio of any workload. Limits 1 and 3 stand as stated and are
  unmeasured.

### D3 -- the ranking, re-read now that the instrument is fixed

- Status: **recommendation recorded; awaiting user direction on the code
  candidates.** `D2` is closed; no code candidate from `D1` has been implemented
  and no paired benchmark has been spent.
- Evidence used: `D1`'s ranking, plus `F11` and `F12`.
- What changed: exactly one column. `D1` ranked candidate A below candidate B on
  decidability alone -- "**No** -- in no bracket". That is no longer true.

  | # | Candidate | Measured size | Decidable? (was) | Decidable? (now) |
  | --- | --- | ---: | --- | --- |
  | A | CA per-glyph bounds (`F6`) | 16.8% | No -- in no bracket | **Partly** -- visible in `processCPUNanosecondsPerDraw`, uncalibrated, needs >~6% to read |
  | B | `DamageActionSnapshot` POD (`F7`) | ~6.6% | Yes | Yes, unchanged |
  | C | `recentOutput` (`F9`) | ~4.3-23.8% | Yes | Yes, unchanged |

- **Partly, not yes, and the distinction decides the recommendation.** `F12`
  measured the new metric's block-to-block spread at 5.60% against the draw
  metric's 0.41%. Candidate A's 16.8% is an on-CPU share of `content-churn`'s
  whole profile; converted to the new metric's denominator it is a change in the
  ~79% of per-draw CPU that sits outside the draw bracket, so a full elimination
  should read as roughly a fifth of total CPU -- comfortably above 6%. A partial
  win would not. So the metric can now see candidate A succeed completely; it
  cannot yet see it succeed partially, and it can report nothing with a verdict
  attached until an A/A screen freezes a rule.
- Recommendation, unchanged in order but for a different reason than `D1` gave:
  **B first, then C, then A.** `D1` put B first because A was undecidable. A is
  now measurable, so the argument has to stand on its own -- and it does: B is one
  field on one private struct with a frozen rule that decides it, and A is
  architectural work in the renderer whose *elasticity is still unconfirmed*
  (Open questions; nothing here varied glyph count and watched the node move,
  which is the pre-registered test `11/F12` used to refute two prior mechanisms).
  Measurability was never the only thing standing between A and the top of the
  list; it was the only thing I could name in `D1`.
- The genuinely new option that did not exist before: **run the A/A screening
  pass and freeze a rule for `processCPUNanosecondsPerDraw`**, which would move A
  from "partly" to "yes" and is the same shape of work as
  `scripts/terminal-benchmark-plan-calibration.py`. Worth doing before A, not
  before B.
- Direction review: **directed** -- B taken. See `D4`.
- Selected direction: **B**, per user instruction.

### D4 -- candidate B is kept, and what its acceptance does to the rest of the list

- Status: **closed.** Candidate B implemented, measured across all five routine
  workloads, and **kept**.
- Evidence used: `F13`.
- Decision: keep the change. Two `faster` verdicts on the two workloads named in
  advance, no regression on the other three, and a structural guarantee (POD) that
  the earlier `10/H1(b)` attempt never obtained. `10/F4`'s lesson -- "when a node
  survives an experiment, the experiment has only excluded what it actually varied"
  -- is what `F7` invoked to reopen this after doc 10 reverted it: doc 10 varied
  *layout*, this varied *triviality*, and triviality is what moved the number.
- What the ranking looks like now. B is done; A and C are unchanged in size and in
  risk, and the A/A screen is unchanged in value:

  | # | Candidate | Status |
  | --- | --- | --- |
  | B | `DamageActionSnapshot` POD | **Done** -- `F13`, kept |
  | D | Correct the stale planner docs | **Done** -- shipped with `F5`'s correction |
  | C | `recentOutput` (`F9`) | Open, next in `D3`'s order, lowest risk |
  | A/A screen for `processCPUNanosecondsPerDraw` | Open, prerequisite for reading A partially |
  | A | CA per-glyph bounds (`F6`) | Open, largest, elasticity still unconfirmed |
  | E, F, G | Unchanged from `D1` |

- **What B's acceptance does not license.** It says nothing about A or C: the three
  candidates share no mechanism. It also does not retire `D3`'s A/A screen -- B was
  decided by the frozen draw rule, so the new metric is exactly as uncalibrated
  after this result as before it. The one thing B does establish is procedural:
  writing the guarding test first is what caught a defect in the pitched
  implementation, and both `F7` and `D1` had that implementation written down as the
  thing to build.
- Next action: none forced. `C` is next in order if the direction continues.

### D5 -- candidate C is rejected, and one of this file's two sizing methods is retired

- Status: **closed.** Candidate C measured by ablation and by two paired runs, and
  **rejected**. Diagnostic reverted; no code change survives it.
- Evidence used: `F14`.
- Decision: **do not take C, in any of its three shapes.** The measurement was made
  on the maximal form -- full deletion -- so it bounds the ring buffer and the
  production gate too: neither can beat deleting the thing outright. Nothing vanished
  from the profile, `scrollback-stream` flipped sign between 2 and 4 pairs, and the
  one `faster` verdict is contradicted by its own plan-time co-movement. The
  `waitForOutput` question `D1` raised does not need answering, because the reason to
  ask it is gone.
- What this does to the ranking: C is closed, not deferred. Remaining, in order:

  | # | Candidate | Status |
  | --- | --- | --- |
  | B | `DamageActionSnapshot` POD | Done, kept (`F13`) |
  | D | Stale planner docs | Done (`F5`) |
  | C | `recentOutput` | **Rejected -- `F14`** |
  | A/A screen for `processCPUNanosecondsPerDraw` | Open; now the cheapest useful step |
  | A | CA per-glyph bounds (`F6`) | Open, largest, elasticity still unconfirmed |
  | E, F | Unchanged from `D1`; both small |
  | G | Do not take (`D1`) |

- **The A/A screen moves up by default, not by argument.** `D3` placed it behind C.
  C is gone, so it is now the cheapest step that changes what the next candidate can
  be decided by -- and `F14` sharpened why it matters: the CPU metric was useful as a
  consistency check while carrying no verdict, and a frozen rule would let it do that
  job deliberately rather than by luck.
- **A methodological consequence, and it is the durable part of this decision.**
  `F14` retires frame subtraction as a sizing method for any region whose callees can
  inline. Two numbers in this file were produced that way -- `F9`'s 23.82% and
  `F14`'s own 14.95% -- and neither is a bound. This does not touch `F7`'s 8.27% or
  `F6`'s 16.8%, which are inclusive shares of stacks containing a named frame rather
  than differences between two regions; a share attributes what it contains, while a
  subtraction assumes what it excludes. Future sizing of a *non*-region ("X minus Y")
  needs an ablation or a callee check before it is quoted.
- Cost of the rejection: two 30s traces and two paired runs, about 8 minutes of
  machine time, to close a candidate that had been carried as "lowest risk, worth
  doing alongside B" since `D1`. Cheap, and the alternative was shipping a change to
  a test-only facility for no measured gain.
- Next action: none forced. The A/A screen is the recommended next step; `A` remains
  the largest and least decidable.

### D6 -- the CPU metric stays permanently descriptive, and its one legitimate use is named

- Status: **closed.** Evidence: `F15`, with `F14` as the worked example.
- Decision: **stop trying to give `processCPUNanosecondsPerDraw` a verdict.** It is
  screened, not unscreened; `F15` is the measurement that closes the question rather
  than an admission that the search was too shallow. `UNCALIBRATED_BLOCK_METRICS`
  stays where it is, `summarize_uncalibrated` keeps taking no `mode` and consulting
  no rule table, and the code comments that said "no calibration exists yet" are
  corrected to say what was measured instead.
- **What it may be used for, stated as a rule rather than left to improvisation.**
  `F14` used this metric to *undermine* a verdict, and that use is sound and
  asymmetric:
  - **Legitimate -- disconfirming.** When the draw metric returns a direction and
    plan time and CPU move by the same amount on a change with no causal path to
    planning, that co-movement is evidence of arm-level drift. Three unrelated
    regions do not shift together because one of them got faster.
  - **Legitimate -- sizing.** A CPU move with no draw move is the signature of
    off-main-thread work, which is what `F12` showed the draw bracket cannot see.
    That is a reason to profile, not a result.
  - **Never -- confirming.** Agreement across regions cannot establish a targeted
    win, and no threshold on this number may be quoted as an effect. `F15`'s bands
    are the reason: on `style-churn`, 21% of pure-noise pairs clear 3%.
- **This is a genuine cost to `D2`.** `D2` fixed the instrument so candidate A could
  be decided, and T1 was half of that fix. T1 delivered *sizing* -- `F12`'s result
  that the deciding metric brackets 11% of a frame is the sharpest thing in this
  file -- but it did **not** deliver decidability. Candidate A is still not decidable
  by any frozen rule on the region it lives in, and `F15` says a paired A/A screen
  cannot make it so at these pair counts. The honest statement of `D2`'s outcome:
  it bought a much better *description* of the gap and no new verdict.
- **What would change this**, none of it taken here: a lower-variance formulation of
  the same quantity (per-thread attribution rather than whole-process, so scheduler
  luck on unrelated threads stops entering the numerator); a winsorized or trimmed
  estimator, for which `scripts/terminal-benchmark-winsorized-{freeze,screen}.py`
  already exist from a prior investigation; or a mode that collects more blocks,
  which is a change to what `confirm` means and not a calibration.
- Cost: 443s of collection plus the calibrator generalization. Bought a closed
  question, a quantified `F14`, and a named practice.
- Next action: **candidate A is now the only open item**, and it is open with its
  decidability question answered in the negative. Read `D3`'s framing accordingly --
  A cannot be settled by the benchmark's frozen rules on the region that makes it
  worth 16.8%, so taking it means either accepting a profiler-share verdict or
  building the bracket first. `F6`'s elasticity is still unconfirmed and remains the
  cheaper prerequisite.

### D7 -- candidate A is confirmed and still cannot be decided; what it would take

- Status: **open, and open with its two questions answered in opposite
  directions.** Evidence: `F16`, on top of `F6`, `F12`, `F15`.
- What is now settled about A: the attribution is **real and elastic** (95.1% of
  linear across a 5.9x lever), the mechanism `F6` proposed is the right one, and the
  cost is paid per glyph occurrence per frame. The last remaining doubt about
  *whether there is something there* is gone.
- What is now settled against it: **the win is energy, not frames** (`F16` --
  the draw rate is pinned at the panel's refresh at both geometries), and **no
  instrument here can return a verdict on it** -- the draw rule brackets the wrong
  thread, the frame rate does not move, and `F15` refused the CPU metric a rule.
- Decision: **do not start candidate A as a code change.** Not because it is
  unattractive -- it is the largest confirmed cost in the app -- but because the
  order is wrong. A change of this size whose result cannot be measured is how a
  project acquires an unfalsifiable optimization. `11/F12` is the precedent: two
  plausible mechanisms for the compositing stall survived until someone ran the
  elasticity test, and both died. A has now *passed* that test, which earns it the
  next step and not the implementation.
- **The next step, if A is taken: build the bracket first.** Concretely, a
  measurement of process CPU over a **fixed wall-clock window at the pinned frame
  rate**, with its own A/A screen -- the shape `F15` used, but as a bespoke
  experiment rather than a rule inside `confirm`, which is what makes more blocks
  available. `F15`'s refusal binds the frozen comparison modes, not a
  candidate-specific measurement that may collect as many blocks as it needs. Note
  what will *not* help: re-denominating per second instead of per draw, since `F16`
  shows the rate is constant and the two differ by a constant factor.
- The cheaper alternative, and its cost: **accept profiler-share evidence with two
  independent captures**, which is exactly what doc 13 did and doc 11 explicitly
  refused to inherit. This file has been sceptical of that standard throughout;
  adopting it here for the largest change on the list would be the worst place to
  start. Recorded so the option is visible, not because it is recommended.
- **The magnitude question is still open and is cheaper than either.** Both `F16`
  captures forced full-viewport redraws every frame. A live capture -- `F6`'s
  second competing interpretation -- would size the node as a user actually
  experiences it, and could plausibly move A's value by an order of magnitude in
  either direction. **Do that before building any bracket.** It is one capture.
- Next action: none forced, and A should not be started. In cost order: a live
  capture to size the node (cheap), then a purpose-built CPU bracket with its own
  A/A screen (expensive), then the change.

### D8 -- candidate A is closed, and the sweep's headline finding is demoted

- Status: **closed.** Evidence: `F17`, on `F16`, `F6`, `F3`, `F12`, `F15`.
- Decision: **do not take candidate A.** Not deferred -- closed, with a reopening
  condition below. Three independent reasons, and the third alone is sufficient:
  1. **Its magnitude is a benchmark artifact** (`F17`). 801.0 us/draw under forced
     full-viewport republication, 27.3 us/draw when the draw is damage-scoped --
     29.3x. `F3`'s 1.85% on `scrollback-stream` agrees. The 16.8% that made A the
     top of the ranking exists only under a stimulus that redraws every glyph on
     screen 120 times a second.
  2. **Its win is energy, not frames** (`F16`). The draw rate is pinned at the
     panel's refresh regardless.
  3. **Nothing here can measure it** (`F12`, `F15`, `D7`). Wrong thread for the
     draw rule, no headroom in the frame rate, no calibratable rule for CPU.
- So the honest ordering of this file's findings changed twice. `F6` ranked A first
  on a share; `F16` confirmed its mechanism and looked like vindication; `F17`
  removed the number. A confirmed mechanism attached to an unrealistic input is not
  an opportunity.
- **Reopening condition**, and it is specific: a capture of a *real* full-screen
  animated TUI -- not the synthetic churn stimulus -- showing `get_glyph_bboxes`
  materially above `F3`'s 1.85% on `scrollback-stream`. That is the only regime
  where A's arithmetic works, and no measurement here has sampled it. A live
  complaint about fan noise or battery during full-screen TUI use is the same
  trigger arriving from the user's side.
- **What this does to `D1`'s ranking, finally.** Every ranked candidate is now
  resolved: B kept, C rejected, D done, **A closed**, E and F still small and
  untaken, G still not to be taken. The file has no open code candidate.
- **The generalizable lesson, and it is the one worth carrying out of doc 17.**
  An elasticity test confirms a *mechanism*; it says nothing about whether the
  mechanism's input is realistic. `F16` proved the cost scales with glyphs drawn,
  and it was right -- what it could not see is that the benchmark was drawing an
  absurd number of glyphs. **Ask what the input is worth before asking whether the
  cost scales with it.** In profiling terms: a share measured under a synthetic
  stimulus inherits that stimulus's unrealism, and the cheapest defence is a second
  capture under a different stimulus shape, which cost one trace here and would
  have reordered `D1` at the top of the file.
- Next action: none. Doc 17 has no open candidate and no unmet prerequisite.

## Pre-rejected

Candidates a fresh survey would plausibly re-propose, with the evidence that
already closed them. Re-proposing any of these needs new evidence of the kind
named, not a new profile share.

### The POD / trivially-copyable `GridCell`

Implemented and reverted twice. `12/F8` measured -8.83% `terminal-feed` and
**+6.74% slower** `scrollback-stream`, reverted in `94a1528`; doc 14 rejected
re-proposing it from `inspectedCells` destroy traffic, and `14/F10` then showed
that node's cost was never the cell's layout. **Note that `F7` is not this
candidate** -- `DamageActionSnapshot` is a per-action stack value with one
refcounted field, not the per-cell representation, and `10/F8` already reopened
it independently.

### Shrinking the cell below stride 32

`16/D1`. Stride 24 was implemented, bought +19%/+49% history, and was rejected
because `incremental-mixed` came back slower in two independent confirm runs. **A
cell's stride is also its cache-line alignment**; 32 divides 64, 24 and 20 do not.
Reopen on a live scrollback-depth complaint, or on a trace attributing that
regression to something other than the stride.

### Cheaper Swift-side preparation of draw rects

`11/F10`: 71.5% of a full-frame sprite draw is inside `CGContextFillRects`,
leaving 28% Swift-side with a 3.8% largest item, on a path `11/F7`/`11/F8` showed
fits the 60Hz budget. `F6` adds a second reason to leave it alone: on the text
path in the real app the dominant cost is not in DanTerm's draw at all.

### The sprite geometry cache

Doc 9 Phase 5, sized in place at ~4% by `11/F9`/`11/F10`, and it shrank twice
under measurement before anyone started it. `F3` puts `CA::CG::FillRects` at
0.37% of `content-churn`. Do not take it.

### Reopening the compositing stall *as a stall*

`13/D2` declined the frame-counted instrument; `11/F12` refuted both nameable
mechanisms with pre-registered predictions that failed in the wrong direction --
the main thread blocked *less* when given more work. **`F6` reopens the
compositing *cost*, which is a different claim**: it is on-CPU work with a named
call chain, not blocked time. Do not use `F6` to relitigate the slack question.

### A scripted input driver for live frame counts

Answered no in `13/D2`. Not re-argued.

### Tracing both churn workloads in a future sweep

`F4`: `content-churn` and `style-churn` are CPU-indistinguishable. One capture
serves both. This is a saving, not a rejection of the workloads -- they still
separate a *verdict* by freezing one axis, which is what they exist for.

## Open questions and caveats

- **One capture per workload; doc 9's two-profile rule is unsatisfied, except for
  `content-churn`.** The two churn workloads cross-validate each other (`F4`), and
  `content-churn` now has a genuine second capture at HEAD (`F16`);
  `scrollback-stream` and `incremental-mixed` have no replicate. Every share here is provisional in that
  specific sense, and a candidate should get a second capture before it is
  benchmarked.
- **No frame counts, and three proxies disagree by 1.7x** (`F2`). Absolute ms are
  comparable within a workload only. This is the reason `F5` rests on commit
  provenance rather than on the trace. **Fixed for future captures by T2 (`F11`),
  not retroactively for the four traces in `F3`** -- those were taken before the
  counter existed and cannot be renormalized without re-tracing.
- **The new CPU metric classifies nothing, and now never will** (`F12`, `F15`,
  `D6`). `F12`'s ~6% figure came from three sequential unpaired blocks; the paired
  A/A screen replaces it with a per-workload band (SD 1.88% / 3.52% / 8.75%) and the
  finding that no threshold clears the accuracy gates at any mode's pair count. Do
  not quote a `processCPUNanosecondsPerDraw` difference as an effect or a verdict.
  `D6` names the two uses that remain, both of which point at a profiler rather than
  at a conclusion.
- **`frame-accounting.json`'s counted window is ~67% longer than the trace it
  brackets** (`F11`), because a profiler spends seconds attaching and saving. Use
  `measured.drawsPerSecond`; `measured.draws` is not the draw count during the
  trace, and the artifact says so in its own text.
- **`incremental-mixed`'s trace is ~1/6 instrument** (`F2`): the observer's ack
  `open()` is 9.81% of its on-CPU total, 5.4x its entire `drawRenderFrame`
  region. Treat that column as an order of magnitude.
- **Loop profiling mode forces a republished full-viewport redraw**
  (`DANTERM_TERMINAL_BENCHMARK_REDRAW_UPDATES=1000000`), so per-frame glyph counts
  sit at maximum. This caveat was recorded as "inflates `F6` by an unmeasured
  amount"; **`F17` measured it: 29.3x** on the glyph-bounds node. It may also be why
  `F4` finds the two churn workloads identical. **Any share in `F3` for one of the
  three churn workloads carries this inflation to the extent it scales with glyphs
  drawn** -- `scrollback-stream` does not, which is why its column repeatedly
  disagrees and repeatedly turns out to be the truthful one.
- **`F6`'s elasticity is confirmed** (`F16`) and **its magnitude is retired**
  (`F17`). The mechanism scales at 95.1% of linear; the 16.8% attached to it was the
  benchmark's stimulus, not the app's behavior. Superseded caveat, kept for the
  chain: *"nothing here varied glyph count and showed the node move."* Both
  questions this file left open about `F6` are now answered, in opposite
  directions.
- **The churn workloads are frame-rate-capped, not CPU-bound** (`F16`). 119.10/s and
  119.32/s across a 5.9x change in per-frame glyph work, on a 120Hz panel. Any
  reading of these workloads that treats a CPU reduction as a throughput win is
  wrong: there is no throughput headroom to win. This also means a candidate whose
  cost sits off the main thread has **no** metric here that can decide it (`D7`).
- **`F9`'s central estimate is bracketed, not measured**, and its own filter is
  known to leak inlined feed frames. The probe in `D1`'s candidate C fixes both.
- **`terminal-feed` has no on-CPU instrument** (`F2`), so doc 10's ranking still
  cannot be re-sized on its own boundary. Building a `trace` mode for the headless
  feed harness is an unlogged tooling opportunity.
- **`F9`'s 23.82% and `F14`'s 14.95% are both retired as bounds** (`D5`). Anything
  in this file of the form "region X minus region Y" needs re-deriving by ablation
  before it is quoted; inclusive shares of a named frame are unaffected.
- The one `faster` verdict in `F14` (`style-churn` -3.02%) is read as an arm-level
  artifact on the strength of its plan-time co-movement, not on a repeat run. A
  second paired run would settle it, and was not spent: no mechanism connects
  `recentOutput` to plan time, so the candidate's fate does not turn on it.
  **`F15` since priced it**: 5 of 24 A/A pairs on that workload sit at or below
  -3.02% with no code difference present, and a +/-3.0% rule fires on 5.91% of
  pure-noise runs. Still not a repeat run, but no longer unquantified.
- Untracked `notes.md` and `plans/wip/*` were present during capture. They cannot
  affect a profile, but they **would** be captured into a paired comparison's
  candidate tree -- read the printed path list before believing any benchmark run
  that follows from this file.

## Outcome

**Phases 1-5 complete; no open code candidate.** Nine on-CPU traces, seventeen
findings, five ranked code candidates all resolved,
two tooling fixes shipped plus one calibration screen, seven pre-rejections, **one
code candidate kept** (B: `terminal-feed` -14.59%, `scrollback-stream` -10.78%),
**one rejected on measurement** (C: nothing vanished when it was deleted outright),
**one metric screened and refused a verdict** (`processCPUNanosecondsPerDraw`), and
**the headline finding confirmed in mechanism and retired in magnitude** (A: elastic
at 95.1% of linear per `F16`, but 29.3x smaller under a realistic stimulus per
`F17`, and closed by `D8`).

Ten results are worth more than the ranking:

1. **The two regions this project has spent four documents optimizing are no
   longer where the time is.** `planFrame` and `drawRenderFrame` are 10.5% and
   10.4% of the workload where each is largest. The three biggest
   app-attributable quantities in the sweep -- CA's per-glyph bounds (16.8%),
   `applyOutput`'s non-feed body (up to 23.8%), and `recordDamage` (15.8%) -- were
   ranked first by nobody. **Read this alongside result 10: two of those three
   numbers did not survive the file that produced them.** The 23.8% was retired as
   unsound (`F14`) and the 16.8% as unrealistic (`F17`); only `recordDamage` held,
   and it is the one that shipped.
2. **The largest cost in the app is in no benchmark bracket** (`F2`, `F6`). The
   draw verdict measures 10.43% of `content-churn` while CA's replay of that same
   draw costs 23.15%, on threads the draw timer never sees. This confirms
   `13/H3`, which doc 13 kept research-only and doc 11 refused to inherit.
3. **The strongest a-priori candidate was already fixed and both documents still
   advertise it** (`F5`). `9/H2` -- whole-viewport planning -- was implemented in
   `8188b9a` two days after doc 9 closed. `agent-docs/terminal-performance.md`
   still tells agents the planner is damage-blind. The generalizable lesson: a
   parked backlog item inherits the staleness of the document holding it, and a
   performance guide's headline numbers need a provenance date.

4. **The ranking was distorted by the instrument, and the instrument is now
   fixed** (`D2`, `F10`-`F12`). Candidate A sat below a quarter-sized candidate
   purely because no frozen rule could decide it. Whole-process CPU per accepted
   draw now exists as a third reported quantity, following plan time's precedent
   through the same two seams, and the draw rate is published from loop mode. This
   was done before spending the 16.8%, which was the point.
5. **The deciding metric brackets 11% of what a frame costs -- 4.3% on
   `incremental-mixed`** (`F12`). This is the sweep's sharpest result and it
   arrived only after the tooling was fixed. `drawNanosecondsPerDraw` measures
   540,000 ns on `content-churn` while the process burns 4,879,935 ns of CPU per
   accepted draw. Draw plus plan reach 21%; the remaining 79% is in no bracket.
   `F6` said this in profiler shares; `F12` says it in the benchmark's own units,
   which is the version that can change a decision. The corollary is the standing
   warning: an `equivalent` verdict on these workloads is a statement about one
   ninth of the cost, and was never claiming to be more.
6. **The guarding test caught a defect in the pitch, not in the change** (`F13`).
   `F7` and `D1` both specified candidate B's implementation as an identity token,
   and `F7` filed the collision risk as "unverified". Written first, the test
   demonstrated that implementation drops the damage outright, because
   `activationIdentity` is derived from cell content and never from the URI. What
   shipped is a revision counter that compares no values at all. The generalizable
   lesson: a pitch's *mechanism* deserves the same scepticism this file applies to a
   pitch's *size*, and a test written before the code is what supplies it -- the
   benchmark would have reported `faster` either way, with the hover bug included.
7. **One of this file's two sizing methods does not work, and it produced two of its
   numbers** (`F14`). `F9` sized candidate C by subtracting the `Terminal.feed(_:)`
   frame from `applyOutput`; the first attempt to correct that repeated the mistake
   one level deeper. `Terminal.feed` is *partially inlined*, so subtracting its frame
   does not subtract its work -- `moveAndFillRows` appears as `applyOutput`'s direct
   child. Deleting `recentOutput` outright then changed nothing, which is what
   actually closed the candidate. Inclusive shares of a named frame (`F6`, `F7`) are
   unaffected: a share attributes what it contains, a subtraction assumes what it
   excludes. Size a "X minus Y" region by ablation, or check that Y's callees are
   absent too.

8. **The instrument fix bought a better description and no new verdict** (`F15`,
   `D6`). `D2` fixed the tooling specifically so candidate A could be decided, and
   the paired A/A screen now says the CPU metric cannot carry a rule at any mode's
   pair count: the false-positive and detection gates cross with no overlap on all
   three workloads. What T1 did deliver is `F12` -- the single sharpest number in
   this file. So the ledger is honest and lopsided: A is still the largest candidate
   and is now *known* to be undecidable by frozen rule on its own region, rather than
   merely awaiting a screen. The generalizable lesson: "the metric is uncalibrated"
   and "the metric is uncalibratable at this sample size" feel like the same
   sentence and license opposite next steps, and only a screen distinguishes them.
   The screen also retro-priced a judgement (`F14`'s artifact reading) that had been
   made on mechanism alone -- calibration evidence is worth collecting even when it
   freezes nothing.

9. **The headline finding survived its own kill test, and the surprise was next to
   it** (`F16`, `D7`). `F6`'s 16.8% is elastic at 95.1% of linear across a 5.9x
   glyph-occurrence lever, so the mechanism is right and candidate A is real. But the
   draw rate did not move -- 119.10/s and 119.32/s, pinned at a 120Hz panel's refresh
   at both geometries. The app pays 801 us/draw of pool-thread glyph-bounds work at
   179x66 **and still makes every frame**. So A's win is energy, not latency, and
   between that and `F15` there is now **no instrument in this project that can
   return a verdict on it**. `D7` therefore declines to start the largest confirmed
   candidate on the list: a change of this size whose result cannot be measured is
   how a project acquires an unfalsifiable optimization. The generalizable lesson:
   confirming that a cost is real and confirming that removing it would show up are
   two different experiments, and passing the first is what makes the second worth
   designing.

10. **The headline finding was confirmed and then demoted, and the second step is
    the one that mattered** (`F16`, `F17`, `D8`). `F6` ranked candidate A first on a
    16.8% share. `F16` ran the elasticity test A had never faced and it passed at
    95.1% of linear -- which reads as vindication and is not. One further capture
    under a *damage-scoped* stimulus put the same node at 27.3 us/draw against
    801.0, and `F3`'s 1.85% on `scrollback-stream` had been saying so all along. The
    generalizable lesson: **an elasticity test confirms a mechanism and says nothing
    about whether the mechanism's input is realistic.** Ask what the input is worth
    before asking whether the cost scales with it. The defence costs one capture
    under a different stimulus shape, and here it would have reordered `D1` at the
    top of the file.

Findings F1-F17 are recorded; the next free ID is **F18**. Decisions D1-D8 are
recorded; D2 and D4-D8 are closed and acted on; **every ranked code candidate is
resolved** -- B kept, C rejected, D done, A closed (`D8`), E and F small and
untaken, G not to be taken -- and the A/A screen is done and earned no rule; the
next free ID is **D9**.
