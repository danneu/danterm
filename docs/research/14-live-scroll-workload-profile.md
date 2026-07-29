# Live scroll workload: the plan path under a full-viewport scroll

Research started: 2026-07-28.

## Purpose

This file owns one question: **does a real-application workload that re-plans the
whole viewport every frame change the conclusions docs 9, 11 and 13 reached on a
workload that does not?**

All four live captures those files closed on were **btop** -- a TUI that damages
individual panels. This file's capture is **`less -R` on a large file with the
down-arrow held**, which scrolls the entire viewport every frame. That is the
other end of `13/H4`'s workload axis, and it is the shape doc 9's
`full-screen-content-churn` benchmark was built to imitate, now observed in a
real app for the first time.

The boundary this file must preserve: **doc 11 closed the optimize-or-replace
question and doc 9 closed its Phase 5 backlog, and neither closure is reopened by
a profile share alone.** Doc 11's standing rule -- "a new render optimization
needs a trigger, not just a profile share" -- applies to everything below.
Doc 9's reopening condition is narrower and is the one this file may be able to
satisfy: *a profile puts a new node on the plan or draw path that is not on that
list.*

## Investigation rules

- **Inherited from doc 13, unchanged.** A live capture requires a person holding
  a key in a focused DanTerm window for 20 seconds. It is not scripted; see
  `13/D2`, which answered "should we build a scripted input driver" as **no** and
  recorded the reopening condition. Do not rebuild that case here.
- **Read subtrees, not nodes.** `sample` prints one function as several sibling
  nodes at different offsets. A per-node read understates it; this is the trap
  that turned doc 13's "720 blocked samples" into 1,064. Every number in F1 below
  is a subtree sum across offsets and sibling branches, matching doc 13's
  post-correction convention.
- **A `sample` share is not recoverable time.** Doc 9 and doc 11 each tested this
  and it failed both times -- ~3x optimistic on the one node measured directly
  (`9/F3`), and measuring slack rather than work in `11/F12`. Discount
  accordingly; no candidate here may be implemented on a share alone.
- **Re-size any `sample`-derived node on an on-CPU instrument before spending a
  paired benchmark on it.** Added 2026-07-29 after F6: `just benchmark-trace`
  (xctrace Time Profiler) records running samples only, so its shares mean what
  they appear to mean, and it costs one build and one 30 s run -- far less than a
  `benchmark-quick` pair plus the implementation the pair would be judging. It
  deflated this file's only candidate by 2.5x and rejected it (D1). It still
  **decides nothing**: profiling is diagnostic per
  [agent-docs/terminal-performance.md](../../agent-docs/terminal-performance.md),
  and a node that survives this step still needs the paired benchmark.
- **Re-report `sample.txt` captures through the report tool rather than reading
  them by hand.** `just benchmark-report <path/to/sample.txt> '--thread Main'`
  applies the subtree convention above mechanically and writes folded stacks plus
  JSON. F6 used it to confirm every number in F1.
- **Cross-capture absolutes are only comparable when machine load is known.**
  `13/F6` showed a background load moves the idle/busy split. This capture's
  machine load is **not** on record (see Open questions), so prefer shares over
  absolutes when comparing it to runs 1-4.
- **This workload is not btop.** Any comparison to runs 1-4 is a
  workload-versus-workload comparison, never a before/after. No change may be
  claimed as a regression or an improvement on this evidence.

## Trigger and current evidence

The user captured a fifth live profile while holding the down-arrow in
`less -R ~/runs-many.txt` and asked for an analysis. The capture was not taken to
test any pre-registered hypothesis, which bounds what it can settle: it is
attribution on a new workload, not an experiment.

**Artifact.**
`.build/manual-profiles/2026-07-28-210239-86850-less-scroll-run5.txt`
(copied out of `/tmp` per the standing rule; disposable, every decision-bearing
number is transcribed into F1-F5).

**Command and gesture.**

```
sample "$(pgrep -a -x 'DanTerm Dev')" 20 -mayDie -fullPaths -file /tmp/danterm-runs-many.txt
```

while a person held the down-arrow key for the full 20 seconds with `less -R`
open on a large file. Not scripted.

**Provenance, and it is weaker than run 4's.** pid 86850, launch 21:02:23,
sampled 21:02:39, 16,840 samples at 1 ms. The binary that produced it **no longer
exists**: `~/Applications/DanTerm Dev.app` was overwritten by a later build at
23:19, so run 4's mtime-matching method is unavailable. What can still be
established:

- It contains `specialized Dictionary<>.emptyValuesKeepingCapacity()` -- the
  symbol `13/F10` used to pin run 4 to R4's commit. So the binary is **at or
  after `07dd81f`** and contains R1, R1b, R2 and R4.
- **Geometry and window state, confirmed by the user.** The window was at its
  usual full size -- DanTerm Dev filling the screen, the pane being that minus
  chrome and sidebar -- the same state runs 1, 2 and 4 record. The exact column
  and row counts were not read off; `13/F10`'s 179 columns and `13/F1`'s 66 rows
  are carried as assumptions. Machine load remains unrecorded.
- Its `TerminalRenderExecution.swift` line numbers (635, 659) and
  `RenderFramePlanner.swift` line numbers (180-183, 291, 418) match the working
  tree at `39c9cfe` and do not match doc 13's captures (which cite line 575 for
  `CTFontDrawGlyphs`). The launch at 21:02:23 falls after `39c9cfe` (20:53) and
  before `b03eab2` (23:16).
- **Optimized. Confirmed by the user, 2026-07-28**, and independently consistent
  with the symbol evidence: the tree is full of `specialized`, `outlined` and
  `<deduplicated_symbol>` frames, which a debug build does not produce. This was
  the capture's weakest link and it is now closed -- every Swift-side share below
  is measured on the same build configuration as runs 1-4, so the cross-capture
  table in F1 compares like with like.

## Current hypotheses

### H1 -- the plan/draw ratio is workload-shaped, and this workload is the plan-heavy end

Doc 13 opened `H4` on exactly this and had two points: btop at 8.5% plan / 47%
draw, and doc 9's synthetic `content-churn` at 35.4% / 27.7%. This capture is a
third point from a real app: **17.4% plan / 33.1% draw** (F1). Supporting: the
mechanism is not in dispute -- `less` scrolling moves every row, so
`FramePlanner.plan`'s per-row reuse check at `RenderFramePlanner.swift:175-178`
misses on every row, and the whole grid is re-planned. Competing explanation:
none credible; the reuse path is visible in the source and the profile shows the
full-plan branch taken. **This is effectively confirmed by F1** and is recorded
as a hypothesis only because a single capture cannot establish a distribution.

### H2 -- the plan path carries two allocation/ARC nodes that doc 9's backlog does not cover

**Partially rejected, 2026-07-29.** The first node is real but too small to act
on: F6 sizes it at 2.11% of main-thread on-CPU where the `sample` share below
implied ~20% of `planFrame`, and D1 rejected the candidate on that. The second
node (the optionals) is still open. The paragraph below is preserved as the
state of the evidence before F6, not as a live claim.

`FramePlanner.textRuns` spends **152 samples (48% of its own 317)** in
`_ArrayBuffer._consumeAndCreateNew` -- inside `OpenTextRun.cells` as a run
extends, per F2's 2026-07-29 correction -- and `FramePlanner.inspectedCells` spends
**~64-70 of its 263** destroying `TerminalCell?` optionals (F2). Neither is on
doc 9's Phase 5 list, which is H2 (whole-viewport geometry), H3 (glyph cache) and
the sprite geometry cache. Doc 9's shipped unreserved-growth fix (R4, `07dd81f`)
was in **`drawTextRuns`**, the draw path; this is the planner's own `textRuns`,
and doc 9's outcome explicitly predicted it would grow ("`textRuns` absorbed
about a fifth of the plan-path saving because `RenderTextCell` is now a wider
struct to copy").

Competing explanation, and it is strong: **a `sample` share is not recoverable
time**, and both nodes are exactly the kind of Swift-side preparation that
`11/F10` sized at a ceiling. What would distinguish them is a paired benchmark on
`full-screen-content-churn`, not more profiling. **Nothing here licenses an
implementation.**

### H3 -- the compositing stall tracks rasterization content, not just pipeline slack

`11/F12` concluded the stall is *substantially* pipeline slack: the main thread
blocked **less** when given more of its own work. This capture blocks **less than
every btop capture** -- 951 samples, 22.0% of busy, against 25.0% (run 1) and
31.3% (run 4) -- on a workload whose `CA::CG::Queue` work is almost purely glyphs
(`FillRects::draw_shape` is 2 samples here against 261-368 on btop) (F3).

Supporting a content reading: less rect rasterization on the CG queue, less
blocking. Competing explanation, and `11/F12` is the reason to prefer it: the
workloads differ in frame rate as well as in per-frame content, and **`sample`
reports no frame count**, so a lower blocked total is equally consistent with
fewer, cheaper frames. This hypothesis is **not testable on the evidence in this
file** and is recorded so it is not mistaken for a refutation of `11/F12`.

## Candidate direction, pending evidence

C1 (the `OpenTextRun.cells` reservation) was proposed, sized on an on-CPU
instrument, and **rejected** in `D1` -- its whole ceiling sat below what the
deciding benchmark can resolve.

### C2 -- make `TerminalScalars`'s collection accessors inlinable across the module boundary

**Provisional, VETTING.** Sized by F8 at a **4.95% ceiling** of main-thread
on-CPU (plus ~1.06% of unspecialized generic helpers), against the **6.26%**
value-witness half that stays with doc 12 and stays rejected.

Why this clears the filter C1 failed. D1 rejected C1 because its 2.11% ceiling,
discounted by `9/F3`'s measured ~3x optimism, landed under `benchmark-quick`'s
2.5% calibrated plan-time threshold -- the benchmark could not have classified it
either way. C2's ceiling is roughly 2.4x C1's, and, more importantly, **it is
spread across both paths**: F8's callers include `drawTextRuns` as well as
`textRuns` and `decorationRuns`, so both the draw verdict (3.8-4.5% thresholds)
and the plan-time line (2.5%) can see it. C1 was visible to neither at its size.

Two shapes, and per D1's discipline, what each does *not* pay:

- **(a) Annotate the accessors.** `@inlinable` on `startIndex`, `endIndex`,
  `subscript` and the `RandomAccessCollection` conformance, which forces
  `Storage` and the `storage` property to `@usableFromInline internal`. **Does
  not pay:** any layout change, any new invariant, any behavior change. **Cost
  it does pay:** the private enum's shape becomes ABI-visible. Note the file
  header's stated intent -- "Private so that the case distinction can never leak
  into behavior callers might come to depend on" -- is about *source-level*
  encapsulation, which `@usableFromInline internal` preserves for the render
  modules exactly as `private` did, since they are different modules and still
  cannot name it.
- **(b) Turn on cross-module optimization** for the `TerminalCore` target.
  **Does not pay:** any source edit at all. **Cost it does pay:** it is a
  build-wide setting whose effect is not confined to this hot path, it lengthens
  builds, and it makes the win invisible in the source -- a future reader has no
  way to see why these accessors are fast. It is also the blunter instrument for
  a question F8 localized precisely.

(a) is the better first move on those grounds, and (b) is worth measuring only
if (a) underdelivers, since a null result from (a) would implicate specialization
rather than inlining.

**Nothing here licenses an implementation yet.** The gate is unchanged: this is a
share, F8 states plainly that 4.95% is a ceiling and not a prediction, and the
two halves of F6's 11.35% are not proven independent. The next step is the
paired benchmark, and it must be run for real before any claim is made.

**C2 shipped as (a) in `1323a6d`.** See F9 and D2.

### C3 -- stop materializing a `TerminalCell?` per cell, and stop re-fetching the row per column

**Provisional, VETTING.** Sized by F10 at **20.2% of `planFrame`** as a hard
ceiling, ~15.7% as the conservative recoverable share, ~5% after `9/F3`'s
discount -- 2x `benchmark-quick`'s 2.5% plan-time threshold. Unlike C1, the
deciding benchmark can classify it.

This is deliberately **not** doc 12's POD cell. F10 records the separability
argument: `12/F3` owns the grid *mutation* path where only layout can help, and
this owns the render *read* path where the value need not be built at all.

Two shapes, and what each does *not* pay:

- **(a) A row-scoped read on `Terminal`.** Give the planner a way to read one
  row's content once -- a `withViewportRow(row:)`-style borrow, or a narrow
  projection carrying only what `inspectedCells` uses (`scalars`, `style`) --
  and have `inspectedCells` walk the columns inside it. **Removes:** the
  per-column `GridRow` copy and array retain/release, the repeated
  `isAlternateScreenActive` and scrollback index checks, the unread `hyperlink`
  dictionary lookup, and the `TerminalCell?` construct/destroy pair. **Does not
  pay:** any change to `TerminalCell`, to `GridCell`, or to the existing
  `cell(row:column:)` signature, which has one production caller and 167 test
  call sites and should keep working untouched.
- **(b) A narrow per-cell accessor** returning only `(scalars, style)`.
  **Removes:** the `TerminalCell?` materialization and the hyperlink lookup.
  **Does not remove:** the per-column row lookup, which F10 sizes at roughly
  95 ms of the 272 ms -- so (b) leaves a third of the recoverable cost on the
  table for a similar amount of work.

(a) is the better first move: it is the shape that removes both halves, and (b)
is a strict subset of it.

**Nothing here licenses an implementation yet** on the sizing alone. But unlike
C1, the sizing clears the threshold with margin, so the next step is to build
(a) and run the paired benchmark for real.

## Task ledger

### Phase 1 -- establish what this capture actually says

- [x] Attribute the main thread by subtree, in doc 13's shape. -> **F1**
- [x] Break the plan path down and check every node against doc 9's Phase 5
      list. -> **F2**
- [x] Record the compositing stall and the `CA::CG::Queue` composition against
      runs 1-4. -> **F3**
- [x] Record the draw path by source line against `13/F6`'s table. -> **F4**
- [x] Confirm or refute that input and PTY parsing matter on a held-key
      workload. -> **F5**

### Phase 2 -- decide whether F2 is work or noise

- [x] **Gate.** Resolve the build-configuration question. **Answered
      2026-07-28: optimized**, confirmed by the user. F1's uncertainty drops from
      medium to low and the benchmark task below is unblocked.
- [x] **Check the premise before benchmarking anything.** Done 2026-07-29: the
      unreserved array is `OpenTextRun.cells`, not `textRuns`'s `result`. See
      F2's correction. This task exists because `9/F6` cost doc 9 an entire
      selected direction by skipping it.
- [x] **Size F2's node on an on-CPU instrument before spending a paired
      benchmark on it.** Done 2026-07-29, replacing the plan to go straight to
      `benchmark-quick`. `just benchmark-trace full-screen-content-churn` puts
      the reallocation at **2.11% of main-thread on-CPU**, against F2's
      `sample`-derived 20.2% of `planFrame`. -> **F6**
- [x] ~~**Candidate C1 -- give `OpenTextRun.cells` a reserved buffer.**~~
      **REJECTED, 2026-07-29 -- see D1.** Both shapes ((a) `reserveCapacity` in
      `init`, (b) a planner-owned reused buffer) are moot: F6 sizes the whole
      node below the threshold `benchmark-quick`'s calibrated plan-time rule can
      resolve, so no implementation could be decided. Rejected on measured
      headroom, not on doubt; D1 records the reopening condition.
- [x] ~~Benchmark the selected shape with `just benchmark-quick`.~~ Not run;
      D1 rejected the candidate before it existed. The routing analysis stands
      for whatever replaces it: a plan-path change is **damage generation**, so
      `8/D2` routes it to `benchmark-quick`, not `benchmark-headless-draw`.
- [x] **Resolve the observer tripwire before reading any further trace closely.**
      Done 2026-07-29. Not a regression: the recorded 3.3% and F6's 7.08% use
      different denominators, all three invariants hold, and the matched-method
      figure today is 4.44%. -> **F7**
- [x] **RESEARCH -- `TerminalScalars` traffic, 11.35% of main-thread on-CPU
      (F6).** Done 2026-07-29, starting from doc 12 as the task required.
      **Answer: partially separable.** 6.26% is value-witness traffic and stays
      doc 12's (POD-only fix, rejected in `12/F8`); 4.95% is cross-module call
      overhead that doc 12 never examined, because doc 12 profiled the *grid*
      path where those accessors are same-module and already inline. -> **F8**,
      candidate **C2**.
- [x] **Benchmark C2.** Done 2026-07-29. Baseline `b645a22` resolved before the
      first edit per `13/F7`. `just benchmark-confirm`: **faster on all three
      draw workloads** (-19.98% `content-churn`, -20.41% `style-churn`, -12.94%
      `incremental-mixed`), plan time -6.04%/-5.65%/-3.13%, and the grid-path
      workloads unmoved as F8 predicted. -> **F9**, kept by **D2**.
- [x] **Hand the general lesson to a design note.** Done 2026-07-29:
      [docs/design/2026-07-29-cross-module-value-dispatch.md](../design/2026-07-29-cross-module-value-dispatch.md),
      indexed in `docs/design/index.md` and in `AGENTS.md`'s further-reading
      list. It carries the decision, the profile signatures that distinguish
      witness-table dispatch from value-witness traffic, and the denominator trap
      that made F9's result look implausible. **Count corrected while writing
      it**: `TerminalScalars` is the **second** recorded instance, not the third
      -- the marker scanner's lazy generic sequence and its `scan(_:)`
      concreteness requirement are two facets of one incident, not two.
- [x] **Commit C2.** Done: `1323a6d`. The commit message
      should carry the decision-bearing values inline per
      `agent-docs/terminal-performance.md` -- mode, workload, both tree
      identities, the median symmetric estimates, the classifications -- since
      `.build/` is disposable and the artifact path alone is not a record.
- [x] Decide whether `inspectedCells`'s optional-destroy traffic is separable
      from `12/F3`'s "non-POD enum call overhead" attribution. **Do not** reopen
      the POD cell: `12/F8` reverted it and records what would have to change
      first. The question here is narrower -- whether `terminal.cell` can be made
      to return without copying, leaving the representation alone.
      **Answered 2026-07-29: separable, and larger than expected.** `12/F3` owns
      the grid *mutation* path, where only layout helps. This is the render
      *read* path, where `Terminal.cell` builds a four-field `TerminalCell` the
      caller reads two fields of, and re-copies the whole `GridRow` once per
      column. Sized on F6's existing trace at **20.2% of `planFrame`** -- the
      opposite of C1's verdict. -> **F10**, candidate **C3**.
- [x] **Implement C3 shape (a)** and benchmark it. Done 2026-07-29, baseline
      `0e5e2e9` resolved before the first edit per `13/F7`. All three
      pre-registered predictions held: plan time **faster** at `quick`'s
      calibrated threshold on `content-churn` (-15.38%) and `style-churn`
      (-18.01%), no draw verdict moved on any of five workloads, and the two
      grid-path workloads came back *equivalent*. **Tooling fact learned:**
      `benchmark-confirm` does not classify plan time at all -- the calibrated
      plan rule exists only in `benchmark-quick`, so a plan-only change needs
      both modes. -> **F11**, kept by **D3**.
- [ ] **Commit C3.** The message should carry the decision-bearing values
      inline per `agent-docs/terminal-performance.md` -- mode, workloads, both
      tree identities, the median symmetric estimates, the classifications --
      since `.build/` is disposable and an artifact path alone is not a record.

### Phase 3 -- close

- [ ] Record the outcome, hand anything durable to doc 9's backlog or a design
      note, and mark the file closed.

## Findings log

### F1 -- main-thread attribution: plan is 2x its btop share, draw and stall are both below every btop capture

- Status: recorded.
- Date and investigator: 2026-07-28, capture by the user, analysis by Claude
  (agent).
- Artifact: `.build/manual-profiles/2026-07-28-210239-86850-less-scroll-run5.txt`.
- Commit and worktree state: see "Provenance" above. **Binary not identifiable by
  mtime**; bounded to `[07dd81f, b03eab2)` by symbol and line-number evidence.
- Measurements -- main thread, 16,840 samples, 12,510 idle, **4,330 busy**.
  Subtree sums across offsets and sibling branches:

  ```
  CA::Transaction::commit                          3204   74.0% of busy
  |- CA::Layer::display_if_needed                  2176
  |  \- NSViewBackingLayer display                 1617
  |     \- SwiftTerminalSessionView.draw(_:)       1439
  |        \- drawRenderFrame                      1433
  |           \- drawTextRuns                      1419
  \- CA::Layer::prepare_commit                      957
     \- CABackingStoreGetFrontTexture               956
        \- _dispatch_sync_f_slow -> kevent_id       951   BLOCKED, not CPU

  TerminalPaneSessionController.consume             841   19.4% of busy
  \- planIfNeeded                                   840
     |- PaneFramePlanner.planFrame                  754
     |  \- FramePlanner.plan(reusing:damage:)       747
     \- SwiftTerminalSessionView.publish             85

  @objc SwiftTerminalSessionView.keyDown             43    1.0% of busy
  ```

  Against the btop captures (shares of main-thread busy):

  | Node | F1/run 1 | 13/F10 run 4 | **run 5 (this)** |
  | --- | ---: | ---: | ---: |
  | main-thread busy | 4,256 | 3,909 | **4,330** |
  | `drawTextRuns` inclusive | 1,970 (46.3%) | 1,394 (35.7%) | **1,419 (32.8%)** |
  | `CABackingStoreGetFrontTexture` | 1,079 | 1,228 | **956** |
  | -- blocked (`kevent_id`) | 1,064 (25.0%) | 1,224 (31.3%) | **951 (22.0%)** |
  | `PaneFramePlanner.planFrame` | 362 (8.5%) | not tabulated | **754 (17.4%)** |
  | `CA::CG::Queue` thread | 1,316 | 1,525 | **1,436** |

- Observation: the plan subtree **doubled in absolute samples** against run 1
  (362 -> 754) while draw fell (1,970 -> 1,419) and the stall fell (1,064 ->
  951). Busy is within 2% of run 1's.
- Inference: supports H1. Plan 17.4% / draw 32.8% sits between btop's 8.5% / 46.3%
  and doc 9's `content-churn` 35.4% / 27.7%, in the direction the mechanism
  predicts. `13/H4`'s claim that neither published ratio generalizes now has a
  third point that also does not generalize, which is the point.
- Competing interpretations: (a) frame rate, not per-frame cost -- `sample` has
  no frame count, so a workload producing more frames of cheaper plan work would
  look identical. This is unresolvable here and is the standing limitation
  `11/F13`-era work inherited from `13/F10`. (b) Machine load, unrecorded; it
  moves absolutes, which is why the table's conclusion is read off shares.
- Uncertainty: **low on the attribution, medium on what it generalizes to.** Both
  risks that dominated this finding when it was written are now resolved in the
  same direction: the user confirmed an **optimized** build and a **full-size
  window matching runs 1, 2 and 4** (2026-07-28). The absolute comparison in the
  table is therefore sound -- same build configuration, same window state, so
  `planFrame` 362 -> 754 is a workload effect and not a geometry or configuration
  artifact. What remains is one capture of one workload with no frame count, and
  cell counts carried as an assumption rather than read off.
- Next action: Phase 2's benchmark task, now unblocked.

### F2 -- two plan-path nodes that doc 9's Phase 5 backlog does not cover

- Status: recorded. **This is the finding that could satisfy doc 9's reopening
  condition, and it does not do so on its own.**
- Source: same artifact as F1.
- Measurements, inside `PaneFramePlanner.planFrame` (754):

  | Node | Samples | Share of `planFrame` |
  | --- | ---: | ---: |
  | `FramePlanner.textRuns` (`RenderFramePlanner.swift:418`) | 317 | 42.0% |
  | -- of which `_ArrayBuffer._consumeAndCreateNew` | **152** | **20.2%** |
  | `FramePlanner.inspectedCells` (`:291`) | 263 | 34.9% |
  | -- of which `outlined destroy of TerminalCell?` + `getEnumTagSinglePayload` | **~64** | **8.5%** |
  | -- of which `Terminal.cell(row:column:)` | 75 | 9.9% |
  | `FramePlanner.decorationRuns` | 75 | 9.9% |
  | `FramePlanner.backgroundRuns` | 11 | 1.5% |
  | `Terminal.geometry.getter` | 15 | 2.0% |
  | `TerminalScalars` copy/consume (all sites) | 45 | 6.0% |

- Observation 1: **an array inside `textRuns` grows unreserved**, and 48% of the
  function's own subtree is buffer reallocation. **The first reading of which
  array was wrong; see the correction below.**

- **Correction, 2026-07-29 -- the growing array is the run's `cells`, not
  `textRuns`'s `result`.** This finding originally attributed the 152 samples to
  `result` (the array of finished runs) and Phase 2 accordingly proposed
  `result.reserveCapacity`. Reading the line numbers off the current tree refutes
  that: the samples sit on `RenderFramePlanner.swift:418`, which is
  `open?.extend(with: textCell)`, and `result.append` is lines 420 and 424.
  `OpenTextRun.extend` (`:113`) appends into `cells`, which `init` (`:102`)
  creates as a **one-element literal** -- so every run reallocates its cell buffer
  at 2, 4, 8, 16 ... as it extends. `11/F8` measured real content at **5.8 to
  66.6 cells per run**, i.e. roughly 3 to 7 reallocations per run, each one
  copying an array of `RenderTextCell` -- a non-POD element (it holds
  `TerminalScalars`), so element-wise copy with retain traffic rather than a
  `memcpy`. The proposed fix changes from reserving the run list to reserving or
  reusing each run's cell buffer, which is a different change with a different
  cost model. **The share is unchanged; only its attribution and the candidate
  are.** This is doc 9's lesson recurring verbatim: a cheap experiment is only
  cheap once its premise about ownership has been checked (`9/F6`).
- Observation 2: `inspectedCells` builds a fresh `[PlannedCell]` per row per
  frame via `.map` at `:291`, and `terminal.cell(row:column:)` returns an
  **optional copy** of a non-trivial cell. Roughly a third of the function is
  copy and destroy traffic rather than inspection.
- Inference: supports H2 for observation 1, and the correction **strengthens**
  it. The shipped unreserved-growth fix (doc 9 / `13/R4`, `07dd81f`) was in
  `drawTextRuns`; this is a different array in a different function on the other
  side of the plan/draw boundary. Doc 9's own outcome predicted cost would land
  here and named the mechanism -- "`textRuns` absorbed about a fifth of the
  plan-path saving because `RenderTextCell` is now a wider struct to copy" --
  which is precisely what `OpenTextRun.cells` reallocating a non-POD element
  buffer 3-7 times per run does.
- **Inference for observation 2 is weaker and is deliberately not made.**
  `12/F3` corrected exactly this class of node -- `outlined init with copy` /
  `outlined consume` -- from "refcount traffic" to "non-POD enum call overhead",
  on two workloads containing zero spill cells. The same correction plausibly
  applies here and this file has not tested it. What is safe to say is that the
  cost exists and is not attributed.
- Competing interpretations: the entire finding is a share, and both doc 9 and
  doc 11 record that shares here run ~3x optimistic. `11/F10`'s ceiling argument
  (71.5% of a full-frame sprite draw inside `CGContextFillRects`) is about the
  **draw** path and does not directly bound the plan path -- but its lesson does.
- Uncertainty: low on the measurement, **high on whether either is worth
  changing**.
- Next action: Phase 2's benchmark task. Do not implement first.

### F3 -- the compositing stall is the smallest of the five captures, on the most glyph-pure workload

- Status: recorded. Data point, **not** a refutation of `11/F12`.
- Source: same artifact as F1.
- Measurements -- `CA::CG::Queue` thread, 1,436 inclusive samples:

  ```
  CA::CG::DrawOp::render                           1322
  |- DrawGlyphs::compute_dod_                       638   (run 1: 547, run 4: 644)
  |  \- ... TFPFont::CopyGlyphPath                  321   (run 1: 424, run 4: 439)
  |- FillGlyphs::draw_shape_and_color               517
  |  \- CA::CG::draw_glyph_bitmaps                  515   (run 1: 179, run 4: 189)
  |- ClipOp::ClipOp                                  92
  \- CA::CG::FillRects                                2   (run 1: 261, run 4: 368)
  ```

  Main-thread blocked: **951 (22.0% of busy)**, against 1,064 (25.0%) on run 1
  and 1,224 (31.3%) on run 4.
- Observation: `FillRects` all but vanishes and `draw_glyph_bitmaps` roughly
  triples. This workload rasterizes text and essentially nothing else; btop
  rasterizes box-drawing sprites as rects.
- Inference: consistent with H3 -- the stall is lowest on the capture whose CG
  queue does the least rect work -- but **the inference does not survive the
  missing frame count.** Fewer, cheaper frames produce the same signature.
- Competing interpretations: `11/F12` measured the stall *shrinking* when the
  main thread was given more of its own work, which is the slack reading. This
  capture has *less* draw work and *less* blocking, which is the opposite
  direction. Two different workloads cannot adjudicate that; only a frame-counted
  instrument could, and `13/D2` answered no to building one absent a new
  consumer.
- Uncertainty: **high**. Recorded so that nobody reads "22.0%" as evidence the
  stall improved.
- Next action: none. Do not open a compositing candidate on this.

### F4 -- `CTFontGetGlyphsForCharacters` costs 2.2x its btop share here

- Status: recorded.
- Source: same artifact as F1.
- Measurements -- `drawTextRuns` inclusive 1,419, by source line
  (`TerminalRenderExecution.swift`):

  | Line | Samples | Share | What it is |
  | --- | ---: | ---: | --- |
  | 659 | 750 | 52.9% | `CTFontDrawGlyphs` |
  | (compiler-generated) | 169 | 11.9% | inlined/outlined bodies |
  | **635** | **132** | **9.3%** | **`CTFontGetGlyphsForCharacters`** |
  | 441 | 71 | 5.0% | hoisted-buffer reset sweep |
  | 478 | 52 | 3.7% | single-scalar sprite classification |
  | 459 | 34 | 2.4% | CGColor cache lookup |
  | 649/657 | 50 | 3.5% | glyph/position array append |

- Observation: `13/F6` put line 549's `CTFontGetGlyphsForCharacters` at 4.3% /
  3.8% of `drawTextRuns` on btop. It is **9.3%** here.
- Inference: `9/H3`'s remaining half -- the glyph cache, deliberately never
  measured because "no result could have changed doc 11's conclusion" -- is worth
  roughly twice as much on a scroll workload as on btop. It maps every character
  to a glyph ID on every run of every frame.
- **This does not make it worth doing.** 132 samples is 3.0% of main-thread busy
  and 0.8% of wall clock, and doc 11 established the text path is 4.06 ms of a
  16.7 ms budget. It is a better-sized backlog item than it was, not a candidate.
- Competing interpretations: none needed; the line attribution is direct.
- Uncertainty: low.
- Next action: none. Note it on doc 9's Phase 5 backlog if that list is ever
  re-ranked.

### F5 -- input and PTY parsing are not on the map for a held-key workload

- Status: recorded. Negative result, and a useful one.
- Source: same artifact as F1.
- Measurements: `keyDown` -> `insertText` -> `TerminalPTYHost.send` totals **43
  samples** on the main thread (1.0% of busy). The entire
  `com.danneu.danterm.terminal-pty-host` queue is **72 samples** for the run, of
  which `Terminal.feed` is **30** and `Terminal.drainDamage` is **4**.
- Observation: on btop, `13/F6` measured the PTY host thread at 827-831 samples
  with `Terminal.feed` at 693-735. Here it is two orders of magnitude cheaper.
- Inference: `less` scrolling emits a small amount of output per keystroke and
  redraws a large amount of screen; btop emits a full-screen repaint per tick.
  **A held-key scroll is neither input-bound nor parse-bound**; every keypress
  buys a full re-plan and a full redraw, and that is where all the cost is.
- Competing interpretations: none.
- Uncertainty: low.
- Next action: none. This closes off "is the arrow-key path slow" for anyone who
  arrives at this workload assuming input latency.

### F6 -- the Time Profiler deflates F2's node by 2.5x and names a bigger one

- Status: recorded. **Supersedes F2's sizing, not F2's attribution.**
- Date and investigator: 2026-07-29, Claude.
- Commit and worktree state: `b645a22`, dirty (this file plus unrelated
  `plans/wip/`). Profile identity records `sourceTree`
  `7a4ed75875381e61c41d9765b5a48bffe5ced4e3`, binary SHA-256 `9a41764b...`,
  Mach-O UUID `6E069044-77A1-33B3-A622-796E71DDFAF1`.
- Commands, inputs, or reproduction:
  - `just benchmark-trace full-screen-content-churn "Time Profiler" 30`
  - `just benchmark-report .build/terminal-benchmark-profiles/2026-07-29-101853-80500 '--thread Main --top 40'`
  - Cross-check of F1: `python3 ./scripts/terminal-profile-report.py .build/manual-profiles/2026-07-28-210239-86850-less-scroll-run5.txt --thread Main`
- Result or artifact paths:
  `.build/terminal-benchmark-profiles/2026-07-29-101853-80500/` (`profile.trace`,
  `time-profile.xml`, `profile-report.json`, `profile-folded.txt`, and the
  `-filtered` pair). `.build/` is disposable; the table below is the record.
- Measurements or examples:

  **Cross-check first.** Re-reporting run 5's `sample.txt` through
  `scripts/terminal-profile-report.py --thread Main` reproduces F1's
  hand-computed subtree sums exactly: 16,840 main-thread samples, 12,510 idle,
  `CA::Transaction::commit` 3,204, `CA::Layer::display_if_needed` 2,176,
  `-[NSViewBackingLayer display]` 1,617. **F1's numbers stand.** The reading
  convention in the investigation rules is now mechanically checkable rather
  than a manual discipline.

  **The trace.** 30 s, `full-screen-content-churn`, 20,621 ms of on-CPU samples
  across all threads; **9,613 ms on the main thread**, which is the denominator
  for every share below. Inclusive, on-CPU only:

  | Node | ms | % main-thread on-CPU |
  | --- | --- | --- |
  | `TerminalPaneSessionController.consume` | 3137 | 32.63% |
  | `PaneFramePlanner.planFrame` | 2539 | 26.41% |
  | ` FramePlanner.plan(reusing:damage:)` | 1439 | 14.97% |
  | ` FramePlanner.inspectedCells` | 942 | 9.80% |
  | ` FramePlanner.textRuns` | 651 | 6.77% |
  | ` FramePlanner.decorationRuns` | 392 | 4.08% |
  | ` array reallocation under `textRuns`` | 203 | **2.11%** |
  | `drawRenderFrame` | 2094 | 21.78% |
  | ` CGContextRef.drawTextRuns` | 1213 | 12.62% |
  | ` CTFontDrawGlyphs` | 359 | 3.73% |
  | ` CTFontGetGlyphsForCharacters` | 311 | 3.24% |
  | **`TerminalScalars` traffic, all sites** | **1091** | **11.35%** |
  | `TerminalBenchmarkObserver` | 681 | 7.08% |

  `backgroundRuns` does not appear at all (0 ms), consistent with F2's 11
  samples. The `TerminalScalars` row is the union of `outlined consume of
  TerminalScalars.Storage` (4.5% self, the hottest self frame on the thread),
  `outlined copy of TerminalScalars.Storage` (1.8%), and
  `TerminalScalars.endIndex.getter` (3.0%); its callers span **both** paths --
  `drawTextRuns` 101 ms, `textRuns` 35 ms, `decorationRuns` 26 ms, and array
  deallocation 196 ms.

- Observation: the array reallocation F2 identified is real and lands where F2's
  correction said it does -- the direct caller chain is
  `_createNewBuffer <- FramePlanner.textRuns <- planFrame`. But it is **2.11% of
  main-thread on-CPU time, i.e. 8.0% of `planFrame`**, where F2's `sample` share
  put it at 48% of `textRuns` and 20.2% of `planFrame`. That is a 2.5x deflation
  measured as a share of `planFrame`, and a much larger one as a share of the
  thread.
- Inference: **this is the investigation rule "a `sample` share is not
  recoverable time" collecting for the third time in this repo** (`9/F3`,
  `11/F12`, now here), and the first time an on-CPU instrument was used to
  quantify the gap rather than to argue about it. The mechanism is the one the
  rules already name: `sample` counts every thread state, so a node adjacent to
  allocation and ARC -- which spend time in `malloc`/`free` and in the kernel --
  is inflated relative to an on-CPU-only instrument. C1's entire ceiling is
  2.11%, of which a reservation removes only the repeat allocations, not the
  first. Applying `9/F3`'s measured ~3x optimism discount puts the realistic win
  well under 1% of main-thread on-CPU, which is **below `benchmark-quick`'s
  calibrated plan-time threshold of 2.5%** -- the benchmark could not classify it
  even if it worked perfectly. See D1.
- Competing interpretations: the trace is a **different workload** (a serialized
  `full-screen-content-churn`, not a held-key `less` scroll), a **different
  binary** (`DanTerm Benchmark`, current tree, with the observer on the draw
  path), and a **different app identity** from run 5. So this does not prove
  F2's 20.2% wrong *on run 5's workload*; it proves the node is small on the one
  workload that would have to decide it. That distinction does not rescue C1 --
  `full-screen-content-churn` is precisely the benchmark boundary C1's own
  Phase 2 task named -- but it does mean the two numbers are not a
  before/after and neither refutes the other as a measurement.
- Uncertainty: low on the trace's own shares (on-CPU only, 9,613 main-thread
  samples). Medium on the transfer to run 5's workload, per the competing
  interpretation.
- Next action: D1. Separately, `TerminalBenchmarkObserver` at **7.08%** is above
  the 3.3% that `agent-docs/terminal-performance.md` records for this workload
  and treats as a tripwire; see Open questions.

### F7 -- the observer tripwire is not tripped; the 3.3% and the 7.08% have different denominators

- Status: recorded. **Resolves the F6 open question.**
- Date and investigator: 2026-07-29, Claude.
- Commit and worktree state: `b645a22`, same dirty tree as F6.
- Commands, inputs, or reproduction:
  - `just benchmark-sample full-screen-content-churn 25` -- deliberately the
    **same instrument and duration** the 3.3% figure was measured with, rather
    than the trace F6 used.
  - Static check of the three invariants in
    [agent-docs/terminal-performance.md](../../agent-docs/terminal-performance.md).
- Result or artifact paths:
  `.build/terminal-benchmark-profiles/2026-07-29-102815-85645/`.
- Measurements or examples:

  **The invariants hold.** `frameText` survives only inside a comment in
  `TerminalBenchmarkMarkersTests.swift:63`. Both production call sites
  (`app/TerminalBenchmark.swift:514` and `:523`) use the concrete `scan(_:)` /
  `scan(_:limitedToRows:)` overloads; the generic `scan(runs:)` is reached only
  from tests. `writeAcknowledgment` is a bare `open`/`close`
  (`app/TerminalBenchmark.swift:486-491`). The publish-path early return added
  as change 3 of the original work is intact (`:320`).

  **The denominators.** `plans/wip/benchmark-instrumentation-cost.md` states its
  method: "main-thread **inclusive samples** over 25s", 608 of ~18,424 = 3.3%.
  That denominator counts every main-thread sample, idle included. A matched
  capture today, same instrument, same duration, same workload:

  | Denominator | Main-thread total | Observer | Share |
  | --- | --- | --- | --- |
  | `sample`, all states (the 3.3% method) | 19,892 | 884 | **4.44%** |
  | `sample`, busy only | 6,611 | 884 | 13.37% |
  | xctrace, on-CPU only (F6's method) | 9,613 ms | 681 ms | 7.08% |

  The main thread is **66.8% idle** in this capture, so the first row's
  denominator is three times the third's.

  **Why the two instruments disagree by ~2x on the same code.** The observer's
  cost decomposes differently under each:

  | Leaf | `sample` | xctrace |
  | --- | --- | --- |
  | `__open` (the acknowledgment write) | **38.6%** | absent |
  | `Array.append(contentsOf:)` | 22.6% | 16.3% |
  | `TerminalScalars.endIndex.getter` | 12.3% | 24.2% |
  | `Sequence._copyContents(initializing:)` | -- | 15.0% |

- Observation: comparing F6's 7.08% against the doc's 3.3% compared an on-CPU
  share to an all-states share. On the 3.3% figure's own method the number today
  is **4.44%**, which is the same order and is explained by ordinary session and
  tree drift, not by a regression.
- Inference: **the tripwire is not tripped, and F6's flag was my error, not the
  instrument's.** Two things worth keeping, though. First, `__open` is 38.6% of
  the observer's `sample`-measured cost and **zero** of its on-CPU cost -- it is
  blocked syscall time. That is the same mechanism F6 identified for the
  `textRuns` reallocation, showing up a second time in the same session, which is
  useful corroboration that the mechanism is real and general rather than a
  one-off. Second, the acknowledgment sits on a **serialized** benchmark's
  critical path (write, then wait for that exact completed draw), so blocked time
  there is wall-clock the benchmark pays even though no profiler calls it CPU.
- Competing interpretations: 4.44% against 3.3% is a 1.34x gap that this finding
  attributes to drift without proving it. It could also be a small real
  regression below the resolution of a single unpaired capture. Distinguishing
  them needs the original measurement's tree, which is not worth recovering for a
  number that decides nothing.
- Uncertainty: low that the tripwire is untripped (invariants are structural and
  were checked directly). Medium on the 4.44%-vs-3.3% residual, per above.
- Next action: none for the observer. The durable correction belongs to
  `agent-docs/terminal-performance.md`, which states 3.3% without stating its
  denominator -- see Open questions.

### F8 -- F6's 11.35% splits in two: half is doc 12's rejected territory, half is cross-module call overhead

- Status: recorded. **Answers the Phase 2 `TerminalScalars` research task.**
- Date and investigator: 2026-07-29, Claude.
- Commit and worktree state: `b645a22`. No code changed; this is a re-read of
  F6's existing folded stacks plus a source and manifest audit.
- Commands, inputs, or reproduction: self-time decomposition of
  `.build/terminal-benchmark-profiles/2026-07-29-101853-80500/profile-folded-filtered.txt`;
  reads of `lib/TerminalCore/Sources/TerminalCore/TerminalScalars.swift` and
  `lib/TerminalCore/Package.swift`.
- Measurements or examples: self time on the main thread, on-CPU only, of 9,613 ms:

  | Node | ms | % | Class |
  | --- | ---: | ---: | --- |
  | `outlined consume of TerminalScalars.Storage` | 430 | 4.47% | value witness |
  | `outlined copy of TerminalScalars.Storage` | 172 | 1.79% | value witness |
  | **value-witness subtotal** | **602** | **6.26%** | **doc 12's territory** |
  | `TerminalScalars.endIndex.getter` | 288 | 3.00% | cross-module call |
  | `protocol witness for Collection.endIndex.getter` | 51 | 0.53% | cross-module call |
  | `TerminalScalars.subscript.getter` | 49 | 0.51% | cross-module call |
  | `protocol witness for Collection.distance(from:to:)` | 43 | 0.45% | cross-module call |
  | `protocol witness for Sequence.underestimatedCount.getter` | 42 | 0.44% | cross-module call |
  | **cross-module-call subtotal** | **476** | **4.95%** | **separable** |
  | `Sequence._copyContents(initializing:)` | 102 | 1.06% | unspecialized generic |

- Observation, and the structural facts behind it. `TerminalScalars` is defined
  in module `TerminalCore`; `TerminalRenderPlanning`, `TerminalRenderExecution`
  and `TerminalBenchmarkMarkers` are **separate SwiftPM targets** that depend on
  it. `TerminalScalars.swift` carries **no `@inlinable`, `@usableFromInline`, or
  `@_transparent` anywhere**, and `lib/TerminalCore/Package.swift` sets only
  `.swiftLanguageMode(.v6)` -- no cross-module-optimization flag on any target.
  So every `endIndex`, `subscript` and `distance(from:to:)` reached from the
  render modules is an opaque cross-module function call, and the
  `RandomAccessCollection` conformance is consumed through **witness tables**
  rather than specialized. The `protocol witness for ...` frames in the table are
  that mechanism appearing by name.
- Inference: **F6's 11.35% is not one cost, and doc 12 priced only one half of
  it.** `12/F3` inference 2 attributed the `outlined init with copy` /
  `outlined consume` nodes to the per-cell call and switch overhead of a non-POD
  enum, and concluded "only H3 can" remove them -- H3 being the POD cell that
  `12/F8` implemented, measured at **+6.74% slower** on `scrollback-stream`, and
  reverted in `94a1528`. That conclusion stands for the **value-witness half**
  (6.26%): copy and destroy of a non-trivial type are not call-overhead problems
  and no annotation removes them.

  The **cross-module-call half (4.95%, plus ~1.06% of unspecialized generic
  helpers) is a different mechanism with a different fix**, and doc 12 never
  examined it -- doc 12 was measuring the grid path (`moveAndFillCells`, the
  erase boundary, `Terminal.feed`), where the accessors are called from
  *inside* `TerminalCore` and therefore already inline. F6's capture is the
  render path, where every one of those calls crosses a module boundary. That is
  why this node class looks different here than it did in doc 12, and it is a
  genuinely new observation rather than a re-litigation.

  It is also **the second recorded instance of one mechanism in this repo**
  (corrected 2026-07-29 from "third", which double-counted the two facets of a
  single incident): `agent-docs/terminal-performance.md` records that handing the marker
  scanner a lazy generic sequence "replaced String cost with type-metadata and
  unspecialized-iterator cost of the same size", because SwiftPM does not
  specialize a library's generics for another module. The observer was fixed by
  making its entry point concrete. `TerminalScalars` has the same disease at a
  hotter site and has not been.
- Competing interpretations: **the two halves are not fully independent, and this
  finding does not claim they are.** Making the accessors inlinable lets the
  optimizer see the `Storage` switch at render call sites, which could fold some
  copies as well -- or could inline the switch without removing a single value
  witness. Only a measurement separates those. The 4.95% is therefore a **ceiling
  on the call-overhead half, not a prediction of recovery**, and the standing
  investigation rule that a profile share is not recoverable time applies here
  exactly as it did to C1.
- Uncertainty: low on the decomposition (self time, on-CPU instrument, symbol
  names that name their own mechanism). Medium on how much is recoverable.
- Next action: C2 below. Unlike C1, this one clears the filter that killed C1 --
  see D1's method and the Candidate section.

### F9 -- C2 measures faster on all three draw workloads, and F8's attribution predicted each number

- Status: recorded. **Benchmark result, not a profile.** Decision-bearing.
- Date and investigator: 2026-07-29, Claude.
- Commands, inputs, or reproduction: `just benchmark-confirm b645a22`.
- Identities: baseline revision `b645a22`, commit
  `b645a228b7efe58415bd5c68f1c6402d5b20355e`, tree
  `7a4ed75875381e61c41d9765b5a48bffe5ced4e3`. Candidate base the same commit,
  tree `baa2f75f267ab83d030b1c088b0532b6ca92a7d8`, 9 captured working-tree paths
  of which exactly one is code
  (`lib/TerminalCore/Sources/TerminalCore/TerminalScalars.swift`); the other
  eight are this file, the research README, `notes.md`, and five `plans/wip/`
  documents. Artifact:
  `.build/terminal-benchmark-comparisons/confirm/baa2f75f267a-0000`.
- Measurements:

  | Workload | Draw verdict | Plan time |
  | --- | --- | --- |
  | `terminal-feed` | inconclusive (-0.86%, 2 pairs) | -- |
  | `scrollback-stream` | inconclusive (-1.72%, 4 pairs) | -- |
  | `content-churn` | **faster (-19.98%, 4 pairs)** | -6.04% (4 pairs, no verdict) |
  | `style-churn` | **faster (-20.41%, 4 pairs)** | -5.65% (4 pairs, no verdict) |
  | `incremental-mixed` | **faster (-12.94%, 6 pairs)** | -3.13% (6 pairs, no verdict) |

  No invalidations, no flagged outliers, complete schedule. Phase timings:
  snapshot 0.2s, cache 124.5s, comparison 117.3s.

- Observation, and the check that matters. **-20% looked too large for a ceiling
  F8 stated as 4.95%**, so before believing it I re-measured F6's trace with the
  benchmark's own denominators rather than the main thread's. F8's 4.95% is a
  share of the *whole main thread*; the draw verdict brackets only `draw(_:)`,
  and the plan line only `planFrame`. Against those:

  | Region | Scalar-related share (F6 trace) | Measured improvement |
  | --- | ---: | --- |
  | `drawRenderFrame` | **20.6%** of 2,094 ms | **-19.98% / -20.41%** |
  | `planFrame` | **8.3%** of 2,539 ms | -6.04% / -5.65% |
  | grid path (`Terminal.feed`) | ~0, calls are same-module | -0.86%, inconclusive |

- Inference: **the mechanism is confirmed, and three independent predictions
  landed.** The draw improvement matches the profiled scalar share of the draw
  region to within half a point. The plan improvement sits just under its
  profiled share, which is the expected direction (inlining removes the call, not
  the work inside it). And the grid path -- which `F8` predicted would not move,
  because inside `TerminalCore` these accessors were always inline -- **did not
  move**, on two workloads, which is the strongest single piece of evidence that
  the win is cross-module dispatch rather than something incidental to the edit.
  A change that had accidentally altered behavior or elided work would not have
  produced a null result exactly where the attribution said null.
- Competing interpretations: considered and rejected on the evidence above. That
  the effect is an artifact of one workload is refuted by three workloads at
  three pair counts. That it is a build-nondeterminism artifact is refuted by the
  magnitude, which is 4-5x `benchmark-confirm`'s widest directional threshold.
  What is **not** established is which annotation did the work -- the `@inlinable`
  accessors, the `@usableFromInline` storage, or the explicit index-arithmetic
  bodies -- since they landed together. This finding does not claim to separate
  them, and D2 declines to spend a benchmark finding out.
- Uncertainty: low on the direction and low on the mechanism. The exact split
  across the three annotations is unknown and deliberately unmeasured.
- Next action: D2.

### F10 -- `inspectedCells` is separable from `12/F3`: the cost is a materialized value and a per-cell row lookup, not the cell's layout

- Status: recorded. **Answers the last Phase 2 task.** Re-read of F6's existing
  trace; no new capture.
- Date and investigator: 2026-07-29, Claude.
- Commit and worktree state: the trace is F6's, taken at `b645a22`. The source
  read is at `0e5e2e9`, i.e. **after** C2 landed. See the caveat below.
- Commands, inputs, or reproduction: subtree sums over
  `.build/terminal-benchmark-profiles/2026-07-29-101853-80500/profile-folded.txt`,
  same artifact as F6, same 9,613 ms main-thread on-CPU denominator.
- Measurements:

  | Node | ms | % main thread | % `planFrame` |
  | --- | ---: | ---: | ---: |
  | `FramePlanner.inspectedCells` | 942 | 9.80% | 37.1% |
  | ` Terminal.cell(row:column:)` | 272 | 2.83% | 10.7% |
  | ` `outlined destroy of TerminalCell?`` | 240 | 2.50% | 9.5% |
  | **the two together** | **512** | **5.33%** | **20.2%** |

  Inside `Terminal.cell` (272 ms): self 97, `swift_retain` 41,
  `initializeWithCopy for Terminal.GridCell` 30, `ScrollbackBuffer.indices.getter`
  24, `swift_bridgeObjectRetain` 22 + its DYLD stub 19,
  `_ArrayBuffer.immutableCount` 17, `isAlternateScreenActive.getter` 13,
  `outlined copy of TerminalScalars.Storage` 9.

  Inside `outlined destroy of TerminalCell?` (240 ms, of which 224 under
  `inspectedCells`): `getEnumTagSinglePayload for TerminalCell` 51,
  `destroy for TerminalCell` 37, `__swift_instantiateConcreteTypeFromMangledNameV2`
  23, `outlined consume of TerminalScalars.Storage` 21, self 25, plus an 83 ms
  leaf symbolicated as `destroy for ClosedRange<>.Index` -- implausible as a
  literal attribution and read here as the outlined destroy body attributed to a
  neighbouring symbol. The trustworthy number is the parent's 240 ms inclusive,
  not that leaf's identity.

  `Terminal.cell` has exactly **two** callers in the trace: the `inspectedCells`
  closure (245 ms) and `plan(reusing:damage:)` (27 ms).

- Premise check, done from source before any sizing was believed, per `9/F6`:
  1. `Terminal.cell` (`Terminal.swift:2867`) calls `viewportStreamRow(at:)`
     (`Terminal.swift:2313`), which returns **`GridRow?` by value**. `GridRow.cells`
     is `[GridCell]`, so every column pays a row-struct copy plus an array
     retain/release, and re-runs `isAlternateScreenActive` and the scrollback
     index check. On a 179-column row that is per-row work done 179 times. This
     is the `swift_retain` / `indices.getter` / `immutableCount` /
     `isAlternateScreenActive` traffic above.
  2. It then builds a fresh four-field `TerminalCell`, of which `inspectedCells`
     (`RenderFramePlanner.swift:291-320`) reads exactly **two**: `.style` and
     `.scalars`. `kind` comes from `geometry`, and `hyperlink` -- the
     `hyperlinkTargets` dictionary lookup at `Terminal.swift:2881` -- is **never
     read**. `12/F3` measured `hyperlinkId` nil in 100% of cells on all four
     workloads, so that field is pure construct-and-destroy cost.
  3. `Terminal.cell` has **one** production caller repo-wide
     (`RenderFramePlanner.swift:292`) and 167 test call sites, so the public
     signature can stay exactly as it is.
- Observation: the node is dominated by two costs that are visible in the source
  and neither of which is about how a cell is laid out -- a value materialized
  per cell that the caller half-uses, and per-row work repeated per column.
- Inference, and the answer to the ledger question: **separable.** `12/F3`
  attributed `outlined init with copy` / `outlined consume` on the **grid
  mutation** path (`moveAndFillCells`) to the per-cell call and switch overhead
  of a non-POD enum, paid regardless of case, and concluded only a
  representation change (H3) could remove it. That conclusion stands and is not
  reopened. This is different work at a different site: the **render read** path
  constructing a `TerminalCell?` that need not exist and re-fetching a row it
  already has. The fix is call shape, not layout, and it does not require the
  cell to be POD -- which is exactly why `12/F8`'s reverted POD experiment does
  not bear on it. This is the same distinction F8 drew for `TerminalScalars`:
  one symbol cluster, two costs, two owners.
- Sizing against the deciding benchmark's denominator, per D2's consequence:
  a plan-path change is damage *generation*, so `8/D2` routes it to
  `benchmark-quick`/`confirm` plan time, which brackets `planFrame`. The ceiling
  is **20.2% of `planFrame`**. Not all of it is recoverable: the scalars copy
  into `PlannedCell` is inherent (~9 ms copy + ~21 ms consume), and a row-scoped
  lookup still costs once per row rather than zero. Taking ~400 ms as the
  conservative recoverable share gives **~15.7% of `planFrame`**; applying
  `9/F3`'s measured ~3x optimism discount still leaves **~5%**, which is 2x
  `benchmark-quick`'s calibrated 2.5% plan-time threshold and 2.7x
  `benchmark-confirm`'s 1.85%. **This is the opposite of C1's verdict in D1** --
  C1 could not have been classified even if it worked; this one can be.
- Competing interpretations: the 240 ms destroy could be partly inherent if the
  compiler already elides construction where it can -- the trace says it does
  not, but the trace is one build. And `inspectedCells`'s remaining 430 ms
  (closure body, style resolution, `PlannedCell` construction) is untouched by
  any of this; a fix here caps out at the 512 ms, not the 942 ms.
- Uncertainty: low on the attribution and on the premise, both read from source.
  **Medium on the absolute sizes**, because the trace predates C2 (`1323a6d`),
  which cut plan time 3-6% and removed some of the `TerminalScalars` traffic
  inside this very subtree. The denominator and numerator both shrink; the
  direction and the margin over threshold are not at risk, but the numbers above
  should be treated as the pre-C2 tree's, not today's.
- Next action: candidate C3 below, then D3.

### F11 -- C3 classifies **faster** on plan time, ~16%, and F10's conservative estimate predicted it within a point

- Status: recorded. **Benchmark result, not a profile.** Decision-bearing.
- Date and investigator: 2026-07-29, Claude.
- Commands, inputs, or reproduction: `just benchmark-confirm 0e5e2e9`, then
  `just benchmark-quick 0e5e2e9 content-churn` and
  `just benchmark-quick 0e5e2e9 style-churn`.
- Why both modes were run, which is a fact about the tooling worth keeping:
  **`confirm` does not classify plan time.** `decision_rule("confirm")` has an
  empty `planWorkloads` table, so plan time prints as "descriptive, no verdict --
  uncalibrated" no matter how large it is. The calibrated plan-time rule lives in
  **`quick`** only -- `content-churn` and `style-churn`, 2 pairs, 2.5%
  directional threshold, 1.0% equivalence band
  (`scripts/terminal-benchmark-compare.py:64,217`). A change whose whole effect
  is in plan time therefore needs `benchmark-quick` to get a verdict at all, and
  `benchmark-confirm` for the breadth. This does not disturb `D1`, which cited
  `quick`'s 2.5% plan threshold and cited it correctly.
- Identities: baseline revision `0e5e2e9`, commit
  `0e5e2e9d807c1a6d29e9271c503ddac22d73c110`, tree
  `91eb4e5bb1df1082e8f0165d41b844218a3caa5b`. Candidate base the same commit,
  tree `ab36af6a5cb44c6adb1d9fcda8eb7317b0a16d94`, 9 captured working-tree paths
  of which exactly two are code
  (`lib/TerminalCore/Sources/TerminalCore/Terminal.swift`,
  `lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift`);
  the other seven are this file, `notes.md`, and five `plans/wip/` documents.
  All three runs used the same candidate tree. Artifacts:
  `.build/terminal-benchmark-comparisons/confirm/ab36af6a5cb4-0000`,
  `.../quick/ab36af6a5cb4-0000`, `.../quick/ab36af6a5cb4-0001`.
- Measurements:

  | Workload | Draw verdict (`confirm`) | Plan time (`confirm`, descriptive) | Plan verdict (`quick`) |
  | --- | --- | ---: | --- |
  | `terminal-feed` | equivalent (+0.72%, 2 pairs) | -- | -- |
  | `scrollback-stream` | equivalent (+0.18%, 4 pairs) | -- | -- |
  | `content-churn` | inconclusive (+1.33%, 4 pairs) | **-16.62%** | **faster (-15.38%, 2 pairs)** |
  | `style-churn` | equivalent (+0.23%, 4 pairs) | **-16.45%** | **faster (-18.01%, 2 pairs)** |
  | `incremental-mixed` | inconclusive (+1.56%, 6 pairs) | -2.31% | -- (not in the plan table) |

  No invalidations. `scrollback-stream` flagged 2 outlier pairs, retained in the
  estimate per the frozen rule. Per-pair plan-time spreads matter here and are
  worth preserving: `style-churn` -16.39 / -16.50 / -16.34 / -16.67 (a 0.33-point
  span across four pairs), `content-churn` -17.03 / -14.90 / -16.20 / -18.07,
  and `incremental-mixed` -0.14 / -4.47 / +7.32 / +14.01 / -13.99 / -18.65.

- Observation 1, the prediction. F10 pre-registered a 20.2% hard ceiling and
  **~15.7% as the conservative recoverable share** of `planFrame`, and predicted
  the draw verdict would not move. Measured plan time is -15.4% to -18.0% across
  three runs, inside the ceiling and within roughly a point of the conservative
  figure; no workload classified faster or slower on **draw** in either
  direction, on five workloads.
- Observation 2, `incremental-mixed` shows nothing, and this is an absence of
  evidence rather than a small win. Its six plan pairs span 32 points and
  straddle zero. The expected mechanism is that damage-scoped reuse skips
  `inspectedCells` for most rows -- `plan(reusing:damage:)` re-inspects only
  damaged rows -- so the changed code barely runs. That is consistent, but this
  run does not establish it; the honest statement is that the workload is
  uninformative about C3.
- Observation 3, and the one not to smooth over: **all five `confirm` draw
  medians are mildly positive** (+0.18% to +1.56%), while both `quick` draw
  medians on the same trees are mildly *negative* (-1.15%, -1.14%). Two of the
  five positives are `terminal-feed` and `scrollback-stream`, whose draw region
  this change cannot touch -- it edits the planner and a `Terminal` read path,
  not `drawRenderFrame`. A uniform small offset that appears on workloads the
  change provably cannot affect, and reverses sign on a re-run, is the
  between-arm drift `8/D2` and doc 8 already characterized. What this evidence
  does **not** do is exclude a real sub-threshold draw regression; it establishes
  only that nothing crosses a calibrated threshold in either direction.
- Inference: **C3's mechanism is confirmed.** The win is concentrated exactly
  where F10 put it -- plan time on the two full-redraw workloads -- and is absent
  exactly where F10 said it would be absent: the grid path, which never calls
  `Terminal.cell`, came back *equivalent* (inside the 0.75% band) on both
  workloads, which is stronger than the "inconclusive" F10 predicted. As in F9,
  the null result where the attribution says null is the strongest single piece
  of evidence that the win is the named mechanism and not something incidental.
- Inference 2, a refinement to an investigation rule. `9/F3`'s measured ~3x
  optimism discount, applied to F10's sizing, would have predicted ~5%; the
  actual is ~16%, so **the discount was not needed and would have been
  misleading here**. The difference is what the number came from: `9/F3`
  discounted a `sample`-derived share of an allocation node, where blocked time
  inflates the reading. F10's share came from an on-CPU instrument and named
  work that a call-shape change deletes outright -- a row copy, a dictionary
  lookup, a construct/destroy pair. The rule that survives is the one already in
  this file's Investigation rules ("a `sample` share is not recoverable time"),
  and the ~3x figure attaches to `sample`, not to profiling in general. An
  on-CPU share of deletable work is a usable estimate as-is.
- Competing interpretations: that the effect is one workload's artifact is
  refuted by two workloads across three runs and eight plan pairs each side of
  the median. That it is build nondeterminism is refuted by magnitude -- ~16% is
  6x the calibrated 2.5% threshold, and `style-churn`'s four pairs span a third
  of a point. What is **not** separated is the three hoists that landed together:
  the per-column row resolution, the unread hyperlink lookup, and the per-column
  `hoveredLink`/`scrollProjection` reads. This finding does not claim to split
  them, and D3 declines to spend benchmarks doing so.
- Uncertainty: low on direction, magnitude, and mechanism for the plan path.
  Low-to-medium on the draw path being genuinely unaffected -- the sign
  reversal between modes supports drift, but sub-threshold effects are by
  construction invisible to this instrument.
- Next action: D3.

## Decision log

### D2 -- keep C2

- Status: **decided -- keep.** Implemented in the working tree; not yet
  committed at the time of writing.
- Evidence used: F8 (attribution and ceiling), F9 (paired benchmark).
- Selected direction: shape (a) -- annotate. `@inlinable` on `startIndex`,
  `endIndex`, `subscript`; `Storage` and `storage` raised from `private` to
  `@usableFromInline internal`, which is the minimum that makes those bodies
  legal; and explicit `@inlinable` bodies for `count`, `underestimatedCount`,
  `index(after:)`, `index(before:)`, `index(_:offsetBy:)` and
  `distance(from:to:)`, which are the stdlib's own defaults for an `Int` index
  but were reaching this type through conformance witnesses another module
  cannot inline.
- Shape (b), cross-module optimization, was **not** run. F9 makes it moot: (a)
  delivered, and (b) was only worth measuring if (a) underdelivered. It stays
  recorded in the Candidate section as the fallback it was.
- Tradeoffs and correctness risks: no layout change, no new invariant, no
  behavior change. The cost is that `Storage`'s shape becomes ABI-visible.
  Source-level encapsulation is unaffected -- the render modules could not name
  `Storage` when it was `private` and still cannot -- and the file header now
  records why the annotations exist so the next reader does not strip them as
  noise.
- Behavioral verification: `swift build --package-path lib/TerminalCore` clean;
  **643 tests in 85 suites pass** (`swift test --package-path lib/TerminalCore`),
  including `TerminalFixtureTests`' neutral replay under all feed splits and
  `TerminalResizeTests`' randomized resize/input sweep; the full `just test` gate
  passes.
- Test coverage audit: **no new test.** The change alters no observable
  behavior, and the property that would need pinning -- "these accessors are
  inlined" -- is a statement about the optimizer, not about behavior. A test
  asserting it would be exactly the structure-coupled test this repo's review
  rubric says not to write. The existing suite already covers the collection
  surface through the fixtures and the render-plan equality path that
  `TerminalScalars: Equatable` serves. The regression that matters here is a
  performance one, and its cover is F9's recorded identities, which is how
  `agent-docs/terminal-performance.md` says to record a decision-bearing result.
- Decision and rationale: keep. Three workloads classified faster at `confirm`'s
  thresholds, the improvement matches the profiled share of each measured region,
  and the one region the attribution predicted would not move did not move.
- What this does **not** license: any claim about the value-witness half of
  F6's 11.35%. That half is untouched, remains doc 12's, and remains rejected
  (`12/F8`).

### D3 -- keep C3

- Status: **decided -- keep.** Implemented in the working tree; not yet
  committed at the time of writing.
- Evidence used: F10 (attribution, separability, ceiling), F11 (paired
  benchmarks).
- Selected direction: shape (a) -- a row-scoped read. Three things landed
  together, all instances of "per-row work was being done per column":
  1. `Terminal.forEachViewportCell(row:_:)` resolves the viewport row **once**
     and passes each column only `scalars` and `style`. That deletes the
     per-column `GridRow` copy with its array retain/release, the repeated
     `isAlternateScreenActive` and scrollback-index checks, the
     `hyperlinkTargets` lookup the planner never read, and the `TerminalCell?`
     construct/destroy pair.
  2. `inspectedCells` walks columns inside that single lookup, building
     `[PlannedCell]` with a reserved buffer, and pads any column the terminal
     row does not cover with the same empty/default content the old
     `terminal.cell(...) -> nil` path produced.
  3. `hoveredColumns(row:columns:)` replaces the per-cell `isHovered`, which was
     re-reading `terminal.hoveredLink` and `terminal.scrollProjection` on every
     column across a module boundary.
- Why closure-based rather than a returned row view, which is the one design
  choice here worth defending: a view's per-cell accessors would be opaque
  cross-module calls into `TerminalCore` unless `GridCell` itself became
  `@usableFromInline` -- exactly the mechanism
  [docs/design/2026-07-29-cross-module-value-dispatch.md](../design/2026-07-29-cross-module-value-dispatch.md)
  was written about, and a far wider ABI change than this warrants. The closure
  costs one cross-module call per **row** and keeps the per-cell work inside the
  module where it is already inline.
- Shape (b), a narrow per-cell accessor, was **not** built. F10 sized it as a
  strict subset that leaves the per-column row lookup in place, and F11's result
  came from removing both halves; there is no question (b) would now answer.
- Tradeoffs and correctness risks: no representation change, no new invariant,
  and `cell(row:column:)` keeps its exact signature. **It now has zero
  production callers** and 167 test call sites, so it survives as public
  inspection API -- worth knowing before anyone "cleans it up". One deliberate
  behavior difference: where a reversed hover range would previously have
  constructed `start..<end` with `start > end` and trapped, `hoveredColumns`
  returns nil. That input is unreachable through the link resolver and the old
  code could only have crashed on it.
- Behavioral verification: `swift build --package-path lib/TerminalCore` clean;
  **643 tests in 85 suites pass**; the full `just test` gate passes, including
  the core-purity lint's 65 assertions and the benchmark harness contracts.
- Test coverage audit: **no new test.** The changed behavior is plan output,
  and it is already pinned by structure-insensitive whole-plan comparisons:
  `RenderCorpusPlanningTests`, the neutral replay fixtures under all feed
  splits, `TerminalResizeTests`' randomized resize/input sweep (which exercises
  the short-row padding path), and
  `RenderFramePlanningTests.hoveredLinkDecoration` for the hover-underline
  branch specifically. A test asserting *how* the planner fetches cells would
  couple to the structure this change exists to alter. The performance
  invariant's cover is F11's recorded identities.
- Decision and rationale: keep. Plan time classifies **faster** at
  `benchmark-quick`'s calibrated 2.5% threshold on both workloads that have one,
  at ~16% -- 6x the threshold and within a point of F10's pre-registered
  conservative estimate -- and the draw path and the grid path both stayed
  inside their bands, which is where the attribution said they would stay.
- What this does **not** license: any claim about doc 12. The cell's
  representation is unchanged, `12/F8`'s POD experiment stays reverted, and
  `12/F3`'s attribution of the grid *mutation* path's copy/consume traffic to
  non-POD enum overhead is untouched by this result. F10's separability argument
  is about a different call site, not a correction to doc 12.

### D1 -- do not implement candidate C1

- Status: **decided -- rejected, not deferred.**
- Evidence used: F2 (and its 2026-07-29 correction) for the attribution; **F6**
  for the sizing.
- Candidate solutions: (a) `reserveCapacity` in `OpenTextRun.init` sized from a
  constant, bounded by `11/F8`'s 5.8-66.6 cells-per-run distribution;
  (b) a planner-owned buffer reused across runs and rows, with `finished(row:)`
  copying out.
- Tradeoffs and correctness risks: (a) over-allocates on every short run, and
  `11/F8`'s distribution is wide enough that no single constant is right at both
  ends. (b) removes the allocation rather than resizing it, but reintroduces the
  copy it exists to avoid -- `9/F6` found exactly this for the per-cell array,
  and the check for it was already a standing Phase 2 task.
- Recommendation: reject. The instrument that would decide it cannot resolve the
  effect. F6 sizes the whole node at 2.11% of main-thread on-CPU; a reservation
  claims a fraction of that; `9/F3`'s discount takes the realistic figure under
  1%; `benchmark-quick`'s calibrated plan-time rule for
  `full-screen-content-churn` decides at +/-2.5% with a 1.0% equivalence band.
  The predicted outcome is `equivalent`, which would license nothing either way.
  Building it would spend a paired benchmark to learn nothing.
- Behavioral verification: not applicable; no code changes.
- Decision and rationale: **rejected on measured headroom, not on doubt.** This
  is doc 11's standing rule applied to the plan path -- a share is not a trigger.
  The finding that survives is F6's method result, not C1.
- Reopening condition: a workload where `textRuns` reallocation exceeds ~5% of
  main-thread on-CPU under an on-CPU instrument, **or** a change that makes
  `RenderTextCell` cheap to copy (which would alter the cost per reallocation
  rather than their count, and is doc 12's territory, not this file's).

## Rejected

### Reopening the compositing stall on F3's lower blocked share

Considered because 22.0% is the lowest of five captures and the CG queue's
composition changed sharply. Rejected for now: `sample` carries no frame count,
so the same signature is produced by fewer frames, and `11/F12` already refuted
the two mechanisms doc 13 could name (glyph diversity, op count) with
pre-registered predictions. Reopening requires a frame-counted instrument, whose
own gate is `13/D2`, whose reopening condition requires a **new consumer** -- a
missed-frame observation, or a candidate whose predicted win lands inside the
stall. F3 is neither.

### Re-proposing the POD cell from `inspectedCells`'s destroy traffic

Considered because ~9% of `inspectedCells` is optional-destroy. Rejected on
sight: `12/F8` implemented it, measured -8.83% on `terminal-feed` and **+6.74%
slower** on `scrollback-stream`, and reverted it in `94a1528` rather than tune
it. `12/F3` also reattributed exactly this node class away from refcount traffic.
The narrower question -- can `terminal.cell` return without copying, leaving the
representation alone -- is a Phase 2 task and is not the same proposal.

**Resolved 2026-07-29, and the narrow question won.** F10 found the cost was
never the cell's layout: `Terminal.cell` re-resolved the row on every column and
built a four-field value the planner read two fields of. C3 removed the
materialization without touching the representation, and F11 measured plan time
**~16% faster**. The POD cell remains rejected and is not what fixed this.

### A scripted input driver to get frame counts

Already answered **no** in `13/D2`. Not re-argued here.

## Open questions and caveats

- ~~**Was the profiled binary optimized?**~~ **Resolved 2026-07-28: yes**,
  confirmed by the user, and consistent with the symbol evidence. Runs 1-5 are
  now all known-optimized.
- **Geometry: window state confirmed, cell counts still assumed.** The user
  confirmed (2026-07-28) that the window was at its usual full size -- DanTerm Dev
  filling the screen, the pane being that minus chrome and sidebar -- which is the
  same state runs 1, 2 and 4 describe. **Neither the column nor the row count was
  read off for run 5**, so `13/F10`'s 179 columns and `13/F1`'s 66 rows are
  carried as assumptions on the strength of matching window state, exactly as
  doc 13 carried its own row count. Residual risk is small (a differing sidebar
  width between sessions would shift columns by a few percent, not by the ~2x F1
  reports) but it is not zero, and a future capture should read the geometry off
  rather than extend the assumption chain a third time.
- **Machine load is unrecorded.** `13/F6` showed a background load moves the
  idle/busy split, which is why F1's conclusion is read off shares rather than the
  ~2% busy difference against run 1.
- **No frame count.** The standing `sample` limitation. Every per-20-second total
  in this file conflates per-frame cost with frame rate. It is the reason F3
  cannot conclude anything and the reason F1's absolutes are weaker than its
  shares.
- **The file compares two workloads, never two builds.** Nothing here is a
  before/after and nothing may be cited as a regression. F6 adds a third
  workload to that caution, not an exception to it: its trace is
  `full-screen-content-churn` on the benchmark app, and F1-F5 are a `less`
  scroll on `DanTerm Dev`.
- ~~**`TerminalBenchmarkObserver` measured 7.08% against a recorded 3.3%.**~~
  **Resolved 2026-07-29 by F7: not a regression.** The two figures use different
  denominators (on-CPU versus all-states-including-idle); on the recorded
  figure's own method the number today is 4.44%, and all three invariants hold.
  **One durable item this leaves open, in another file:**
  `agent-docs/terminal-performance.md` states the observer's cost as 3.3%
  without stating that its denominator is two-thirds idle. Read as a share of
  main-thread *work* the observer is ~7%, so the doc's phrasing invites exactly
  the misreading F6 made. Worth a one-line fix there; it is not doc 14's to make
  unilaterally, and it changes no measurement.
- ~~*(superseded, kept per the append-only rule)* `TerminalBenchmarkObserver`
  measured 7.08% of main-thread on-CPU in F6's trace, against the 3.3% that
  [agent-docs/terminal-performance.md](../../agent-docs/terminal-performance.md)
  records for `full-screen-content-churn` and names as a tripwire ("treat a
  profile where the observer is prominent again as a regression in the
  instrument, not a finding about the app"). Unresolved. Two readings that are
  not distinguished here: the trace ran with `DANTERM_BENCHMARK_PROFILING=1`,
  which the 3.3% figure may not have; or one of the three invariants that doc
  has drifted. **This is a question about the instrument, not about the app**,
  and it does not affect F6's other rows -- but it does mean F6's denominator
  includes ~7% of measurement overhead, which makes every share in that table
  slightly conservative. Worth resolving before the next trace is read closely.~~
  **The "~7% of measurement overhead" clause above survives F7 and still applies
  to F6's table**: the observer really does cost ~7% of main-thread on-CPU in
  that trace, so F6's other shares remain slightly conservative. What F7 refutes
  is only the inference that 7% indicated a regression.

## Outcome

Investigation in progress. Phase 1 is complete (F1-F5) and its build-configuration
gate is resolved (optimized).

Phase 2 has resolved its first half. The pivot from `sample` to the xctrace Time
Profiler (F6) did three things: it **confirmed** F1 mechanically, it **rejected**
the file's only candidate (D1) by sizing it below the deciding benchmark's
resolution, and it **named a node 5x larger** -- `TerminalScalars` traffic at
11.35% of main-thread on-CPU across both paths. The durable result so far is a
method one, and it is now an investigation rule: re-size a `sample`-derived node
on an on-CPU instrument before spending a paired benchmark on it.

F7 then cleared the instrument question F6 raised: the observer is not
regressed, and the alarming-looking 7.08% was a denominator mismatch of my own
making. It corroborated F6's mechanism from a second direction -- 38.6% of the
observer's `sample`-measured cost is a blocked `__open` that an on-CPU
instrument does not see at all.

F8 then answered the `TerminalScalars` research task by reading doc 12 rather
than profiling again, and split F6's 11.35% in two. Half (6.26%) is value-witness
traffic that doc 12 already priced and whose only fix -- the POD cell -- `12/F8`
measured and reverted; that half stays closed. Half (4.95%, plus ~1.06% of
unspecialized generic helpers) is **cross-module call overhead that doc 12 never
examined**, because doc 12 profiled the grid path where `TerminalScalars`'s
accessors are same-module and already inline, while F6 profiled the render path
where every one of them crosses a SwiftPM target boundary into witness-table
dispatch. That is candidate **C2**, and unlike C1 it is large enough for the
deciding benchmark to resolve and lands on both the plan and draw paths.

**C2 then passed its gate and was kept (F9, D2).** `just benchmark-confirm`
against `b645a22` classified it **faster on all three draw workloads** --
-19.98% `content-churn`, -20.41% `style-churn`, -12.94% `incremental-mixed` --
with plan time -6.04%/-5.65%/-3.13% and the two grid-path workloads unmoved.
The magnitudes match F8's attribution measured against each region's own
denominator (20.6% of the draw region, 8.3% of the plan region, ~0 in the grid
path), including the null result exactly where F8 predicted one. One annotated
file, no behavior change, 643 tests passing.

That makes the file's net result one shipped change and one instructive
rejection, from the same trace: the profile's largest node (C1's neighbourhood)
was rejected as too small to measure, and a node the previous investigation had
already declared closed turned out to be two costs wearing one set of symbol
names.

C2 is committed (`1323a6d`) and its general lesson has graduated to
[docs/design/2026-07-29-cross-module-value-dispatch.md](../design/2026-07-29-cross-module-value-dispatch.md).

**The last open question then resolved the same way, and larger.** F10 took the
`inspectedCells` optional-copy task -- whether `terminal.cell` can return without
copying, leaving the representation alone -- back to the *same trace*, and found
the node's cost was never the cell's layout at all. `Terminal.cell` re-resolved
the viewport row on every column and built a four-field `TerminalCell` of which
the planner read two fields, never reading the `hyperlink` it paid a dictionary
lookup for. Sized at 20.2% of `planFrame`. C3 resolves the row once per row and
hands the planner only what it uses; F11 measured plan time **faster at the
calibrated threshold** -- -15.38% `content-churn`, -18.01% `style-churn` -- with
no draw verdict moving and the grid path *equivalent*, landing within a point of
F10's pre-registered conservative estimate. Kept by D3.

**The file's shape, in one line:** one trace, four candidates, two shipped. The
two that shipped were both found the same way -- by asking which of two costs
wearing one set of symbol names was actually separable -- and both times the
answer doc 12 had recorded ("only a representation change can remove this") was
right about its own call site and wrong about the render path's.

Three method results are worth more than the changes:

1. **Re-size a `sample`-derived node on an on-CPU instrument before benchmarking
   it** (F6, D1). Now an investigation rule.
2. **An on-CPU share of deletable work needs no optimism discount** (F11).
   `9/F3`'s ~3x factor attaches to `sample`'s blocked-thread inflation, not to
   profiling in general; applied here it would have under-predicted a 16% win as
   5%.
3. **Convert a profile share to the deciding benchmark's own denominator before
   predicting** (F9, F10). Both shipped changes looked implausible against the
   main thread and landed on target against their region.

Two tooling facts recorded for the next agent: `benchmark-confirm` does not
classify plan time at all -- the calibrated plan rule exists only in
`benchmark-quick`, on `content-churn` and `style-churn` (F11) -- and
`Terminal.cell(row:column:)` now has **zero** production callers, surviving as
public inspection API for 167 test call sites (D3).

Nothing is parked. **This file is closed** once C3 is committed.
