# Decisions -- by-construction performance survey

<!-- The paths below are deliberately gone; this doc records them as history. -->
<!-- docs-lint: allow-missing scripts/research/33/t7-streaming-parser.patch -->

One entry per stable ID. `D1` is a standing rule for the whole doc; the later
entries record the directions, landings, and rejections that resolved the
survey's inherited tensions.

### D1 -- a complexity win counts as a win, on its own evidence

- Status: **settled**, and it governs how every task in this doc is judged.
- Evidence used: `agent-docs/perf-granularity-mismatch.md`, closing paragraph of
  "The fix pattern": *"Report the mismatch even where current cost is
  acceptable: the same mismatch is usually also a complexity smell, and the
  flatten/compute/re-coalesce code plus its dedup/memo/optional-array
  scaffolding disappears with the fix. That scaffolding is the structure
  apologizing."* Also `30/D1`, which shipped a folded `clip(to:)` explicitly as
  a simplification with no win the ladder could resolve, and is the precedent
  that this project already accepts such changes.
- Candidate solutions considered for how to rank tasks:
  - Rank by predicted percentage only. Rejected: it deletes most of this doc,
    because `F8` shows seven runtime items and `F4` shows the geometry item are
    unscoreable by any calibrated rule -- ranking by a number nobody can measure
    means ranking by guess.
  - Rank speed first, complexity as a tiebreak. Rejected: it reproduces the
    failure the granularity doc was written about, where a cache that hides a
    mismatch outranks the structural lift that deletes it.
  - Rank by what the change makes **impossible**, and record speed and
    complexity as two separate, independently sufficient justifications.
    Selected.
- Tradeoffs and correctness risks: the obvious failure mode is licensing
  churn -- "it is cleaner" is exactly the argument the Workflow-level design bar
  warns about when it is used to justify effort nobody asked for. The guard is
  that a complexity claim must still be *falsifiable and verified*, not
  asserted: it needs its one-off script like any other task, and the script
  measures the structure (call sites deleted, allocations reached zero, a state
  that can no longer be constructed), not the wall clock.
- Decision and rationale: a task in this doc may be justified by **either** a
  measured speed or memory improvement, **or** by deleting a class of possible
  wrong states or a body of compensating scaffolding -- and a task that does
  only the latter is not thereby second-tier. What a task may **not** do is
  claim a speed win it did not measure. Each task states which of the two it is
  claiming, and `Verification` proves that one.

  The practical consequence for this doc: `T20` (damage carries words end to
  end), `T11` (geometry off the frame path), `T17` (inline CSI storage), `T18`
  (exact fills) and the `PackedRetainedRow` retirement in `F3` are all
  legitimate on complexity grounds alone, and should be written up that way in
  the commit rather than padded with a percentage that the ladder cannot
  support.

### D2 -- damage carrying words: reopened as a complexity change, not as a speed claim

- Status: **implemented and verified as T20 riding on T9's engine/planner half
  (`F21`).** No standalone damage-representation task remains.
- Evidence used: `F2` (four independent verticals reached the same
  representation); `30/D2`, which rejected precisely this change and wrote *"do
  not reopen this for the sort"*; `27/F9`/`27/D2`, which rejected
  swift-collections `BitArray` for the accumulator's internals with a reopening
  gated on preserving reusable storage and the public determinism seam.
- Candidate solutions:
  - Leave it. The accumulator already holds words; only the public seam
    flattens. Cost is bounded by ~66 rows per frame.
  - Change the public seam type to carry the words, keeping the accumulator's
    internals and its reusable storage untouched.
  - Adopt a library bitset throughout. Rejected upstream by `27/D2`, and it ends
    `TerminalCore`'s import-free boundary.
- Tradeoffs and correctness risks: `TerminalDamage.rows` is public and read by
  tests and two benchmark harnesses; those rewrites are free under this repo's
  no-back-compat rule. The real gain is that a width-bounded bitset makes an
  out-of-range row **unrepresentable**, so `init(rows:)`'s `filter { $0 >= 0 }`
  sanitizer and the test that pins it both delete -- along with the `sorted()`
  and the three redundant set constructions. The real risk is re-litigating a
  decision another doc already made on its own terms.
- Recommendation: take it as a **complexity change under `D1`**, sequenced as a
  rider on `T9` or `T14` -- both change the damage representation for an
  independent reason, which is the exact reopening condition `30/D2` itself
  names ("reopen only if the damage representation is being changed for another
  reason and the ordered form falls out for free"). Do **not** pitch it as a
  speed win: `17/F5` measured `clipFramePlan` at 0.05% on `incremental-mixed`
  and 0.00% elsewhere, and `31/F18` rates that cell's reading rule at 4.9
  points, so no honest verdict is available. Standalone and unsequenced, it is a
  re-litigation of `30/D2`; ridden on `T9`/`T14` with `T3`'s diff-shape counts in
  hand, it is the condition that decision asked for.
- Behavioral verification: the row set a consumer sees must be identical before
  and after -- an equality test over the two representations across the four
  corpora, plus the existing damage tests.
- Decision and rationale: **take the word-carrying representation only as the
  complexity rider D2 described.** T3 measured the redundant conversions, and
  T9 supplied the independent representation change required by `30/D2`'s
  reopening clause. F21 records the landed word seam, structural absence gate,
  and behavioral equivalence coverage.

### D3 -- reject terminal-owned POD `GridCell` after its bounded experiment

- Status: **decided: reject T19 and leave `28/H8` as the next ranked option.**
  `F42` admitted the experiment; `F43` records its implementation, calibrated
  failure, and removal.
- Date and investigator: 2026-08-09, Codex.
- Evidence used: `F42`, `F43`; `12/F7`, `12/F8` (implemented, +6.74% on
  `scrollback-stream`, reverted at `94a1528`); `16/D1`/`16/F3` (stride 24
  reverted; 32 divides 64 and is a resting point); `28/D10` (a smaller retained
  cell rejected; `H8` named as the successor); `15/F12`, `15/F15` (measure the
  stride and the malloc bucket, do not reason about them); `9ad7cc5` (deleted
  `[GridRow]` scrollback).
- Candidate solutions:
  - Do nothing; treat `12/F8` as settled.
  - `28/H8` deferred packing: move *when* the encode runs, off the drain thread.
  - `T19`: make the live cell word identical to the retained word and give
    cluster scalars a `Terminal`-owned table, so scalar/kind/style admission is
    a direct word store and every `[GridCell]` operation becomes a `memcpy`.
- Reopening condition, quoted exactly from `12/F8`: *"either row-move traffic
  stops being hot on `scrollback-stream`, or cluster scalars find an owner that
  does not enlarge the row"*.
  - **The row-move half is rejected.** `9ad7cc5` removed retained `[GridRow]`
    storage and therefore removed the old row-owned spill field's specific tax.
    It did not make live-row movement cold. At HEAD, `moveAndFillRows` is 84.98%
    inclusive and 17.32% self in the headless `scrollback-stream` feed profile;
    four hot live-row destruction stacks through `swift_arrayDestroy` total
    14.36% of profile weight.
  - **The owner half is met.** The previous design enlarged `GridRow` from 16 to
    32 bytes and tied every scalar lookup to the cell's current row. A table
    owned once by `Terminal` adds no `GridRow` field, and a table id stays valid
    when a cell moves anywhere inside that terminal. History and the live and
    inactive screens are already all owned by that terminal, the same complete
    live set `reclaimDeadStyleEntries` walks. This changes the rejected cost
    model rather than tuning the rejected row-owned design.
- Measured layout, not a stride prediction: today's `GridCell` is size 25,
  stride 32, non-POD. The direct C1 word plus today's two optional ids is size
  17, stride 24, POD. The exact live-row construction reserves 3,040 -> 2,016
  cell bytes at 80 columns and 6,112 -> 5,088 at 179 columns. Both are measured
  `Array.capacity` results. They do not support a speed claim: stride 24 is the
  same cache-line-straddling shape `16/F3` rejected.
- Current materiality: `LogicalLineStore.appendCells` remains 22.60% inclusive
  and 15.29% self in the same current profile. It still rebuilds the scalar,
  kind, and style C1 word one live cell at a time. The profile is attribution,
  not a predicted T19 effect: direct word storage cannot remove the identity and
  hyperlink side-table work or the arena write that also sit inside that frame.
  The live-row destruction stacks establish that non-POD cleanup remains
  material even though the old retained-row movement no longer exists.
- Ranking against `28/H8`: the research ranking put T19 first because it deletes
  both non-POD live-cell destruction and scalar/kind/style conversion. The
  experiment did not clear the gate, so the actionable ranking is now **H8
  first, T19 rejected**. H8 still carries its stated complexity -- a bounded
  unpacked tail plus scheduling and backpressure policy -- and must earn its own
  decision before implementation.
- Risks and experiment gates:
  - The spill id must stay valid across live rows, the inactive primary screen,
    history, reflow, resize, publication, and every reset. Reclamation needs the
    style table's swept-live-set discipline, with behavioral tests for cluster
    fidelity and id reuse across those owners.
  - Assert POD and exact layout, and repeat both capacity probes in the
    implementation. Do not turn the 24-byte result into a memory rationale.
  - Run `benchmark-confirm` against the pre-experiment tree. No calibrated rung
    may answer `slower`; `terminal-feed` and `scrollback-stream` are the expected
    payoffs, while retained browsing and both full-grid plan-time rules guard
    reads.
  - The known localized scattered-read risk has no healthy directional GUI rule
    after `F28` made `incremental-mixed` descriptive. Record that coverage gap;
    neither a descriptive percentage nor headless drawing, which excludes frame
    planning, may be used to waive it.
- Decision and rationale: **reject the third attempt.** The ownership clause was
  genuinely met and the target costs were material, so running the experiment
  was justified. The final ownership-safe candidate nevertheless produced a
  calibrated `slower` verdict of +190.33% on `terminal-feed`. The written gate
  says any such result rejects the experiment without a tuning pass. The
  implementation and its tests were removed; only the research record remains.
  Exact next action outside this survey: decide whether to open `28/H8`. T23 is
  closed by F44.

### D4 -- `lastPlannedTerminal`: split the retention from the check

- Status: **implemented and verified** in `F41` after the assertion passed in
  `F40`.
- Evidence used: survey code-read of
  `TerminalPaneSession.swift#planIfNeeded` -- `guard pendingDamage != .none`
  at line 990, then `|| terminal != lastPlannedTerminal` at 992; `31/DD52`,
  which declined a store-identity/generation token for its silent-wrong-answer
  (torn frame) mode and left a 14.8x residual explicitly unspent; `31/D5` on
  publish-copy costs.
- Candidate solutions:
  - Leave both.
  - Delete only the retention (stop holding a second whole `Terminal`
    generation, which also holds a second reference to every arena chunk and so
    defeats copy-on-write uniqueness on the next in-place append), keeping the
    comparison against a cheaper witness.
  - Replace the check with a content generation counter. This is what `31/DD52`
    declined.
- Tradeoffs and correctness risks: the third option's risk is not performance
  but silence -- a mutation that changes presentation without bumping the
  generation stops repainting, which is the worst failure mode in that file. The
  second option's risk is much smaller and is mostly a question of what the
  cheaper witness is.
- Recommendation: make `pendingDamage` the sole post-visibility planning
  witness. Remove the whole second guard, both retained comparison witnesses,
  and `requiresCompleteFrame`; keep the rendering-availability and theme paths
  forming `.full` damage before they call the planner. Do not add a generation
  token: the benchmark found no case for one to preserve, while `31/DD52`
  already records its silent torn-frame failure mode.
- Decision and rationale: the temporary benchmark-only recorder observed both
  signal directions before the damage guard. Across all 94 in-block calls in
  the five committed corpora, damage and terminal change were both true; both
  disagreement counts were zero (`F40`). Retaining and deep-comparing a second
  terminal generation therefore preserves no behavior in the prescribed gate.
  `F41`'s first focused run caught that deleting only the equality term left the
  remaining OR terms able to reject ordinary damage; deleting that redundant
  guard whole is the behavior-preserving form.

### D5 -- the parser streams, but not one token at a time: `T7` waits for `T8`

- Status: **settled for now, on measurement.** `T7` is implemented, gated, and
  parked; the implementation is `scripts/research/33/t7-streaming-parser.patch`.
- Evidence used: `F15` (this task's own before/after run: token equivalence, a
  31 MB parse spike deleted, `slower` +5.43% on `scrollback-stream` under
  `benchmark-confirm` and +1.66% headless); `F9` (the array is real in an `-O`
  build and costs 60-80x the corpus's byte count in allocator traffic); `F10`
  (ASCII runs are 8.3 to 44.8 characters); `12/F8` and `16/F3`, the two prior
  engine changes this project implemented and reverted on a measured regression
  of +6.74% and a repeated `slower`.
- Candidate solutions considered:
  - **Land it.** Rejected: the memory it buys is not paid at production's
    delivery size. The spike it deletes is 31 MB under single-shot feeding, and
    the PTY host feeds at most 16 KiB per turn, where the array is 1.5 MB and 15
    allocations into reused buckets. The drain cost, by contrast, is paid on
    every turn. Two prior reverts set the precedent that a measured
    `scrollback-stream` regression is not traded for a structural improvement.
  - **Keep tuning the codegen.** Partly done and then stopped: extracting the
    per-action dispatch behind `@inline(never)` and passing the chunk as an
    `UnsafeBufferPointer` took the regression from +10.00% to +5.43%, and three
    further shapes (moving the parser state to a local for the loop, letting the
    optimizer choose, making the damage snapshot `mutating`) were all worse --
    the last by 18-22%. What remains is a per-token call boundary, and no
    attribute deletes that.
  - **A bounded stack batch** -- parse into a fixed-capacity inline buffer and
    drain it. Not attempted. It would keep both loops tight and allocate nothing,
    but it is the flatten-then-re-read structure `T7` exists to delete, with a
    capacity constant added; it should only be reached for if the `T8` pairing
    below also fails.
  - **Pair it with `T8`.** Selected. `T8` makes the parser's output granularity a
    run of printable ASCII rather than a character, and `F10` sized those runs at
    8.3 to 44.8 characters. The per-token cost `F15` measured is a call, an
    indirect 32-byte return and a defensive copy of `Terminal`, all of which
    amortize by that factor -- so the pair is the first shape in which deleting
    the array can be cheaper than keeping it.
- Tradeoffs and correctness risks: parking has a cost of its own -- a patch file
  rots against the tree, and `T8` is a larger change than `T7` with real
  correctness edges (wide-cell overwrite, the right margin in both `DECAWM`
  states, insert mode). The mitigation is that `t7-streaming-parser.py` builds
  its own arms from the patch, so the day it stops applying is the day the gate
  fails loudly rather than silently. The alternative risk, landing now, is a
  known 1.7-5.4% regression on the hottest path in the engine in exchange for
  memory nobody is short of.
- Decision and rationale: **`T7` does not land alone.** It is re-scoped as the
  second half of `T8`: build bulk ASCII runs, then re-run `T7`'s gate, and land
  the pair only if `scrollback-stream` reads at least `equivalent`. The ledger's
  ranking of `T7` and `T8` as two independently confident items is corrected --
  they are one change. Nothing here reopens `F9`'s numbers, which were about
  allocator traffic and remain correct; what `F15` corrects is the inference that
  traffic of that size is a *cost worth a call per token*.
- Behavioral verification, already satisfied and to be re-run with `T8`: token
  equivalence against `F9` at three chunkings, `peakLiveActions == 1`, the full
  1,020-test `TerminalCore` suite including the 67-fixture 7-byte-split replay,
  and chunk-invariant footprint within 2 MB.

### D6 -- the pair lands: `T8`'s run granularity makes `T7` pay, and `T8` alone had already collected `T7`'s memory

- Status: **settled on measurement, and both halves are landed.** `D5` is
  discharged. `scripts/research/33/t7-streaming-parser.patch` is deleted, because
  the change it parked is now in the tree.
- Evidence used: `F16` (`T8` alone -- every counter falls to exactly `F10`'s
  predicted count on all five corpora, `scrollback-stream` `faster` -71.08%, drain
  153.2 -> 70.5 ms); `F17` (`T7` on top of `T8` -- 4.4% to 11.2% faster headless on
  four fixtures, and the chunk-invariance table showing `T8` alone taking the
  single-shot footprint difference from 30.95 MB to 0.12 MB); `F15` (the same
  streaming shape cost +1.66% headless and read `slower` +5.43% before the run
  granularity existed); `D5`, whose condition was that the pair land only if
  `scrollback-stream` reads at least `equivalent`.
- Candidate solutions considered:
  - **Land `T8` alone and leave `T7` parked.** Rejected, but it was the live
    option until `F17` ran, and it is why the two halves were built and measured
    separately: landing both and reading one benchmark could not have told which
    half moved the number, and `F15`'s whole result was that the two move it in
    opposite directions. With `T8` landed, `T7`'s marginal effect is measurable on
    its own, and it is a 4-11% improvement rather than the 1.7-5.4% cost that
    parked it.
  - **Keep the array as a bounded stack batch.** Not attempted, and now moot.
    `D5` recorded it as the fallback if the `T8` pairing failed. The pairing did
    not fail, and a capacity constant on a flatten-then-re-read structure is worse
    than not having the structure.
  - **Land the pair.** Selected. `D5`'s condition is met with a very large margin
    -- the pair reads `faster -69.32%` on `scrollback-stream` against `63c693da`
    -- and `T7`'s own contribution is positive on the instrument that can resolve
    it and neutral on the one that cannot.
- Tradeoffs and correctness risks: the ordering matters and was followed. `T8`
  landed first as `90731fdc`, with its own counters, its own suite run and its own
  paired benchmark, and `T7` was then measured against that commit rather than
  against `63c693da`. Two risks remain recorded rather than removed. `T7`'s
  marginal sign comes from the **headless** A/B, because
  `benchmark-confirm` cannot run on a change this fast at all -- it calibrates
  `terminal-feed`'s batch on the baseline arm and the candidate then fails the
  1-second block floor, invalidating every workload -- and `benchmark-quick`
  returns disagreeing signs on a 4% drain effect inside a block that is mostly not
  drain. That is the reverse of this project's usual ordering of those two
  instruments and `F17` says so plainly. Separately, the two churn workloads
  report a calibrated plan-metric `slower` of +6.3% and +8.3% against a ~7x
  fence-stall reduction and ~15% less process CPU in the same blocks; `F16`
  records that as measured and unexplained, and it is attributable to `T8`, not to
  `T7`.
- Decision and rationale: **both land.** The corrected reading of `F15` is that
  its memory table was never `T7`'s case -- `T8` collects 99.6% of that footprint
  difference on its own, because the array it shrinks 36x stops being a spike. So
  `T7`'s justification is now a measured 4-11% drain win plus the complexity claim
  `D1` admits: no chunk size can make the intermediate token representation large,
  because it does not exist. `F15`'s closing inference stands as written -- "the
  array's deletion is still the right end state; it is the granularity that is
  wrong, not the direction" -- and this is the measurement that settles it.
- Behavioral verification, satisfied for both halves together: 1,030
  `TerminalCore` tests including the 67-fixture replay that splits feeds mid-token
  at 7 bytes; `just test`'s 75 steps; `TerminalASCIIRunTests`' chunk-invariance
  sweep replaying each cut rule at seven chunkings, where feeding one byte at a
  time forces every run to a single character and so compares the bulk path
  against the character path directly; identical printed-character counts, cursor,
  scrollback depth and screen text between the arms on all five corpora; a
  chunk-invariant footprint to 0.00 MB; and zero `[TerminalStreamAction]`
  occurrences under `lib/*/Sources`.

### D7 -- shift damage is recorded at the scroll site, carried in the damage value, and realized in two independently gated halves

- Status: **implemented and landed in both halves. The engine/planner half
  landed with the `T20` rider -- `F21` records the result** (damaged rows
  per scrolled line 66 -> 2, planner inspection 33x down, zero escalations,
  both regimes draining the same shift value). **The view half landed on the
  owned mirror store after `F22` disqualified `scrollRect` -- the addendum
  below records the pivot, and `F23` records the result** (paced-scroll
  glyph submission 11,570 -> 1,086 per frame, flood and control untouched,
  `F21`'s +2.46% flood-drain trade reversed to a calibrated `faster`
  -3.55%). The claim is a **countable one under `D1`**, stated per regime: in the paced regime, damaged rows per scrolled line
  fall from the whole viewport (66 at the canonical geometry, 40 at `F19`'s) to
  O(1), and submitted glyph occurrences approach the changed cells plus the
  halo. **No wall-clock percentage is claimed**, because the ladder corpora at
  their live 16 KiB framing sit at the flood end of `F13`'s curve (1.0x
  amplification at 91 lines per delivery), so no benchmark workload can contain
  the mechanism -- the paired benchmark is the non-regression check only.
- Evidence used: `F5` (code path: `moveAndFillRows` damages the whole shifted
  range via `invalidateInspection(inViewportRows:)`); `F11` (below the history
  budget, 100% of streaming escalation is `recordDamage(from:to:)`'s `topRow`
  guard, and zero rows reach the damage set); `F13` (the sizing: 66 rows damaged
  to express 1, 11,570 glyph occurrences to express 178 changed cells, planner
  re-inspecting all 66 rows and 11,814 cells because `reusable` is `nil` under
  `.full`; the control shows the row-scoped path intact at 1 row / 356 glyphs;
  the ideal is measured by viewport diff, not assumed); `F19` (production
  placement: paced producers publish exactly one line per frame at every rate
  tried up to 960 lines/s, so the 66x end is the sustained steady state of build
  logs, test output and loggers, and it is `T9`'s alone because those publishes
  sit under the display rate where `T10` recovers nothing; plus the two riders
  folded in below); `17/F6` (the off-main-thread per-glyph bounds cost scales
  with glyph occurrences submitted, so the 65x is a draw-vertical multiplier,
  not just a planning one); `D2` and `30/D2` (the `T20` rider condition).
- Prior decision, quoted and answered: the damage-aware frame planning plan
  (`plans/impl/2026-07-27-1105-damage-aware-frame-planning.md`) listed
  "teaching `TerminalDamage` a scroll delta" as an explicit non-goal, *"not
  justified until a profile shows scroll planning still dominant afterwards"*,
  and grounded row-reuse soundness in `TerminalDamage` escalating to `.full`
  *"for every event where viewport row identity is unstable."* The evidence bar
  it set is now met, in this doc's preferred counter form rather than a profile:
  `F13` shows the planner's whole-grid re-inspection surviving that plan intact
  (its reuse is disabled by exactly the escalation that makes it sound), and
  `F19` shows production paying it once per line, continuously, in the regime
  no other task reaches. The soundness argument is answered structurally, not
  waived: a shift makes row-identity instability *exact* instead of
  unrepresentable, and every identity change the shift does not fully describe
  keeps escalating to `.full`, so the worst case remains current behavior.
- Candidate solutions considered:
  - **Record the shift at the scroll site and carry it in the damage value.**
    Selected. `moveAndFillRows` records `(region: Range<Int>, delta: Int)`
    alongside ordinary row damage for the rows the shift does not describe: the
    vacated strip it blank-fills, and the wrap-seam rows `severWrapClaim`
    rewrites. The ledger's sketch named a third field, `newlyFilledRows`; it is
    not needed -- filled rows are content changes and enter the existing row
    set, so the representation is `rows` plus one optional shift. The drained
    value means: translate the previously presented frame by `delta` within
    `region`, then the rows are damaged in post-shift coordinates.
  - **Derive the shift at the consumer from `topRow` deltas**, leaving the
    representation alone. Rejected by measurement -- this is `F19`'s first
    rider. At the history budget the append and the arena eviction cancel in
    `scrollProjection.topRow` (191 of 200 scrolled lines leave it unmoved in
    `t9-damage-at-budget-probe.sh`), so a `topRow`-derived shift reads zero
    exactly where a long-running pane spends its steady state; a `DECSTBM`
    region scroll never moves `topRow` at all.
  - **Detect the translation by diffing the new grid against the planner's
    retained rows.** Rejected: it re-derives at the consumer a fact the
    producer held exactly and threw away, which is the granularity mismatch
    this survey exists to delete; it costs a whole-grid scan on precisely the
    hot frames; and it is ambiguous on self-similar screens (a viewport of
    repeated lines matches at many deltas), so it is a heuristic where the
    scroll site is exact.
  - **Planner-only shift**: translate the retained rows so reuse survives a
    scroll, but leave the view's full redraw. Rejected as the end state -- it
    recovers the planning half (66 rows inspected to O(1)) and none of the
    submission half, and `17/F6` prices the submission half per glyph
    occurrence. Retained as the explicit fallback for the view half: it is the
    first landable slice, and it stands on its own if the backing-store
    translation fails verification.
  - **Leave the regime to `T10`.** Rejected by `F19`'s partition: paced
    producers publish under the display rate, so every whole-screen plan is
    also drawn and rate bounding recovers none of it. The paced regime is
    `T9`'s alone, and it is the common producer shape.
- Composition semantics, stated here because they are the contract, not an
  implementation detail. Recording a shift into an accumulator holding row
  damage translates the pending rows within `region` by `delta` (on the word
  representation this is a bit shift) and drops rows the shift pushes out of
  the region. A second shift with the same region composes by summing deltas
  and translating again; once `|delta|` reaches the region height nothing
  survives and the shift collapses to region-wide row damage (still cheaper
  than `.full`: rows outside the scroll region stay reusable). A shift with a
  *different* region than one already pending escalates to `.full` -- correct
  by the same argument as today, and rare enough that no cleverness is owed.
  Anything already `.full` stays `.full`.
- Tradeoffs and correctness risks, each named in the ledger and answered:
  - **Row-reuse soundness.** Reuse becomes translation-aware: viewport row `r`
    may reuse retained row `r - delta` when `r - delta` lies in the shifted
    region and is not in the damage set. This is sound iff the recorded shift
    is exactly the permutation the grid applied, which is not arguable in
    prose; the bitmap-equivalence gate below asserts it per frame. A wrong
    shift shows as a torn or stale screen, not a slow one, which is why the
    gate is equivalence against a full redraw of the same state, not a spot
    check.
  - **Overlays.** Selection, search match, cursor and hover damage is computed
    as row diffs in `recordDamage(from:to:)` against anchors that are not
    row-content; under a shift the same anchors name different viewport rows,
    a case `.full` currently hides. The hover branch already handles exactly
    this for eviction reindexing (its `hoveredLinkRange` compare fires when
    the projection moves under an unchanged link) and is the template: after a
    shift, each overlay's before/after viewport rows are re-derived and
    damaged as ordinary rows. The cursor is the overlay always present, and
    `F13` already prices it -- at most two rows above the content ideal, which
    lowers the worst-case 66x toward 22x and leaves the glyph figure
    untouched.
  - **The backing-store translation.** `SwiftTerminalSessionView` is
    layer-backed and its sparse-damage clip already depends on the backing
    store preserving undamaged rows (`setFrameSize` documents the
    fresh-backing-store hazard). `scrollRect(_:by:)` is not trusted on a
    layer-backed view until proven: the view half lands only behind a live
    verification that translated content is bit-preserved, and it falls back
    to a full redraw of the shifted region -- degrading to the planner-only
    win, never below current behavior -- whenever the store's contents are not
    known-good (first frame, dirty-rect fallback, occlusion, any of
    `invalidateFullDisplay`'s callers).
  - **The `topRow` guard.** With the shift recorded at the scroll site,
    `recordDamage(from:to:)`'s `topRow` escalation must stop swallowing the
    case the shift already describes, while continuing to escalate everything
    it does not: not-following, alternate-screen flips, resize, scrolled-back
    mutation. This is `F19`'s second rider made structural -- below budget the
    guard fires on every scroll and at budget it never fires, and after `T9`
    both regimes must drain the *same* shift-carrying value. The at-budget
    verification arm exists to pin that.
  - **`T20` rides along.** Changing `TerminalDamage`'s representation is
    exactly the reopening condition `30/D2` wrote ("the damage representation
    is being changed for another reason") and `D2` recommended this seat. The
    shift-translation of pending damage is a word shift, so the ordered form
    falls out for free: the public seam carries the accumulator's words plus
    the optional shift, and `init(rows:)`'s sanitizer, its pinning test, the
    `sorted()` and the redundant per-frame `Set` constructions delete, per
    `T20`'s own entry. `T20`'s structural counters (`T3`'s script reaching
    zero allocations and zero hash operations on the damage path) ride the
    same commits.
- Decision and rationale: **`moveAndFillRows` records the shift; the damage
  value carries it; consumers realize it in two independently landable halves,
  each behind the bitmap gate.** First the engine and planner: the
  representation change, the accumulator's composition rules, the guard
  narrowing, and translation-aware reuse -- countable as inspected rows per
  scrolling frame falling to O(1). Then the view: the backing-store
  translation, redrawing only damaged rows plus the halo boundary -- countable
  as submitted glyph occurrences falling to the ideal plus halo. The ordering
  is chosen so the riskier half (the one whose failure mode is visual tearing)
  lands second, smallest, and separately revertible, with the planner win
  already banked.
- Behavioral verification, all named before implementation:
  - `scripts/research/33/t5-scroll-amplification.py` before and after:
    `rows/frame` must equal `ideal rows/frame` (plus at most two cursor rows),
    `glyphs/frame` must approach `ideal glyphs/frame` plus the halo, at all
    three delivery sizes, with the `rewrite-bottom-row` control unmoved at 1.0
    rows and 356 glyphs.
  - An **at-budget arm** added to that matrix, seeded from
    `t9-damage-at-budget-probe.sh`: the same O(1) readings where `topRow` is
    frozen by eviction, so the shift is proven at the steady state a
    long-running pane actually occupies.
  - `scripts/research/33/t9-lines-per-delivery.sh` live, before and after:
    paced scenarios must publish O(1) damaged rows per line with the flood
    scenario unchanged.
  - **Bitmap equivalence**: an incrementally scrolled screen byte-identical to
    a full redraw of the same state, across below-budget, at-budget, `DECSTBM`
    sub-region, alternate-screen and overlay-active scenarios.
  - The existing reuse-equals-scratch equality in
    `RenderCorpusPlanningTests`, extended to shifted frames.
  - Paired benchmark on `scrollback-stream` as the non-regression check,
    expected `equivalent`, and read as nothing more: its 16 KiB framing is the
    1.0x end of the curve and cannot contain the win.
- **Addendum (2026-08-08), after `F22`: the view half's mechanism pivots from
  `scrollRect` to an owned frame store; the contract above is unchanged.**
  `F22` ran the live trust probe this decision required and the verdict is
  negative in every reading: `scroll(_:by:)` preserves no bits on a
  layer-backed view, schedules a silent repaint of the exact region the copy
  exists to avoid repainting, and leaves the rest of the store unguaranteed.
  So AppKit's backing store can only ever be a blit target, and the
  translation must happen in memory the view owns.
  - **Selected realization: a mirror frame store.** The view keeps one
    grid-sized bitmap at backing-pixel resolution
    (`TerminalRenderMetrics.cellHeightPixels` makes a row shift integral in
    backing pixels by construction). At a shift-carrying publish the mirror
    translates its region with a row-range copy, damaged rows render into it
    through the existing executor, and `draw(_:)` blits the dirty rect from
    the mirror instead of re-executing glyph runs. Glyph submission per
    scrolled frame falls from region-wide to damaged-rows-plus-halo -- the
    countable claim above, unchanged.
  - **The flood tax is contained by policy, not hope.** The mirror is
    maintained only while it pays: a `.full` publish marks it stale at zero
    cost and the draw path is byte-for-byte today's, so the flood regime and
    the churn ladder never touch mirror machinery. The mirror is built or
    rebuilt only at a shift-carrying publish (one full-plan render at the
    flood-to-paced transition), and row-damage publishes maintain it only
    while it is already valid.
  - **Fallback ledger, now structural instead of enumerated.** The mirror is
    the whole current frame, so any AppKit-initiated draw -- first frame,
    dirty-rect fallback, occlusion return, a fresh backing store after
    `setFrameSize` -- is satisfied by a blit whenever the mirror is valid,
    and falls back to the folded redraw exactly when it is stale. The
    known-good question `D7` had to enumerate per caller collapses into one
    validity bit the view owns.
  - **Named alternative, kept on the table: full store ownership via
    `wantsUpdateLayer`.** Assigning the mirror as the layer's `contents`
    would delete the blit entirely and make the owned store *the* display
    surface. Rejected for this slice, not on effort but on risk placement:
    it swaps the pane's entire presentation contract (draw-seam
    instrumentation, the UI harness's drawn-row and clip-rect pins, the
    benchmark's dirty-rect observation) and requires swapchain-style
    multi-buffering with per-buffer damage generations to avoid writing a
    surface CoreAnimation is scanning. That is a rearchitecture of the
    display seam, while `D7` ordered the view half to land smallest and
    separately revertible. It becomes the follow-up if the blit shows up in
    the gates.
  - **Verification upgrade.** The bitmap-equivalence gate moves from a live
    pixel proof (which macOS 15+ makes nearly unreadable for an unattended
    probe, per `F22`) to headless byte-equality on the owned store:
    translate-plus-damaged-render must equal a from-scratch full render,
    byte for byte, across the same scenario matrix named above. The live
    scripts and the paired benchmark stay as stated.

### D8 -- the consumer bounds the publish rate: a delivery deadline, one one-shot timer only while damage is pending, and a bypass for semantic events

- Status: **implemented and landed; `F20` records the result** -- publishes
  per draw fell 10.45 to 0.997 live, the paced 30/s scenario unchanged, and
  `F18`'s churn plan-metric reversed to `faster`. This was `T10`'s Phase 2
  direction-gate entry. The claim is a **countable one under
  `D1`**: publishes per second fall from ~1,560 to the display rate, so
  publishes per draw fall from **13.0** (`F19`, the post-`T8` figure a `T10`
  claim must be written against; `F12`'s 4.96 is the pre-`T8` datum) to ~1,
  measured by `T4`'s own sampler. No wall-clock percentage is claimed. The
  scope is stated plainly up front: **`T10` helps only producers above the
  display rate** -- the flood regime. A paced producer publishing under
  ~120/s never touches the deadline, its whole-screen cost per line is
  untouched, and that regime is `T9`'s alone (`F19`'s partition). `T10` is
  not a substitute for shift damage; the two are complements that split the
  producer space.
- Evidence used: `F12` (a real `cat` publishes **594 frames/s against 120
  draws/s**, reproduced to 0.2%; deliveries equal publishes to within two
  frames across 7,000, so nothing coalesces before the publish -- the only
  coalescing in the pipeline is AppKit's, between publish and draw, *after*
  every per-frame cost has been paid; a debug build reads 1.07:1, so any
  publish-rate reading must be release configuration; an occluded pane
  publishes nothing, so visibility gating already covers the hidden case);
  `F19` (the re-run post-`T8`: **13.0 publishes per draw**, because the
  faster drain publishes 2.6x more frames into the same 120 Hz display -- so
  every future drain win raises this multiplier, and 12 of every 13
  whole-screen plans are overwritten unseen); `F18` (the wasted work made
  visible on the calibrated instrument: the churn workloads plan 55-63% more
  frames per draw at 30-35% less per frame, the planner is never off-CPU, and
  the finding's own inference is that *"the extra plans are exactly the
  publishes a demand-bounded rate would not perform"*); `F16` (`T8` raised the
  delivery count and cut fence stall ~7x, recording `T8` and `T10` as
  complements); `25/F1` (rendering is event-driven with no display link and no
  periodic timer on the render path, by construction); doc 25's Rejected list
  (the occluded urgent-only tier, and read-side PTY throttling).
- Prior decision, quoted and answered: doc 25 rejected a separate occluded
  "urgent-only" tier because *"primary-history mutation reaches the runtime
  only through delivery ... so a mode with no bounded delivery interval
  silently stops recovery checkpoints for a long-running occluded build that
  rings no bell, writes no clipboard, and does not exit."* `T10` must not
  reintroduce that failure through the back door, and its design differs in
  both of the ways that rejection turned on. First, the deadline **bounds**
  delivery -- at most one display interval, ~8.3 ms at 120 Hz -- and never
  suspends it, so the recovery boundary holds with orders of magnitude to
  spare against the ~500 ms cadence doc 25 itself considered acceptable.
  Second, the event classes that reach the runtime only through delivery --
  bell and other semantic events, clipboard writes, child exit, and
  `onPrimaryHistoryMutation` -- **bypass the deadline outright**, delivered as
  a separate small payload rather than riding a full frame publish. The bypass
  must not carry a frame, or the flood returns through it. Separately,
  `25/F1`'s rule -- no display link, no poll on the hot path -- survives by
  construction: the design arms **exactly one one-shot timer, and only while
  damage is pending**. No damage means no timer and no wakeup, so an idle
  pane's zero-wakeup steady state is unchanged.
- Candidate solutions considered:
  - **Leave it: AppKit already coalesces publishes into draws.** Rejected by
    `F12`'s measurement: that coalescing happens after the plan, the
    copy-on-write, the damage-set construction and the delivery fence have all
    been paid, which is exactly the work being discarded 12 times out of 13.
    And the ratio is not stable -- `T8` alone raised it from 4.96 to 13.0, so
    doing nothing means every drain improvement widens the waste.
  - **Throttle the read side.** Rejected in doc 25 (read-side PTY throttling
    while hidden), and `F12`'s debug observation shows why it is the wrong
    lever even when visible: drain speed flow-controls the child, so slowing
    the reads slows the program in the pane. Parsing must also stay current
    for OSC and bell semantics regardless of display demand, so the bound
    belongs after the parse, not before it.
  - **Raise the 16 KiB read cap so each delivery carries more.** Rejected: it
    tunes a constant toward the flood end of `F13`'s curve instead of bounding
    anything -- publishes still track drain speed, only in bigger steps, and
    the paced regime is untouched. The deadline inverts the dependency: the
    display's demand sets the rate, and the read cap stops being the
    accidental rate governor. (Whether the cap keeps any other reason to
    exist is a follow-up once `T10` lands, per the README's candidate
    direction, not part of this decision.)
  - **Drive frames from a display link or periodic timer.** Rejected: a timer
    that ticks regardless of damage is the poll `25/F1` rules out, and it
    charges every idle pane a wakeup stream to fix a cost only flooding panes
    pay.
  - **The consumer holds a deadline.** Selected. The consumer will not fence
    again until `lastDelivery + refreshInterval`. Damage arriving before the
    deadline accumulates where it already accumulates today -- in the engine's
    damage value -- and arms the one one-shot timer if it is not armed; when
    the timer fires, the newest frame is published with the accumulated
    damage. Damage arriving after the deadline has passed publishes
    immediately, so a producer slower than the display rate never waits and
    the event-driven path is byte-for-byte today's. The drain never throttles;
    only the fence is deferred.
- Tradeoffs and correctness risks:
  - **A stale final frame is the failure mode.** If the timer is not armed, or
    is cancelled without a publish, the last burst of a flood never reaches
    the screen and the pane freezes one frame in the past -- silent and
    visual, like `T9`'s risks, not slow. The invariant is that any damage is
    published within one `refreshInterval` of arriving, and it is
    deterministic, so it gets a deterministic test rather than an eyeball.
  - **Added latency is bounded by what the display already imposes.** A
    deferred publish waits at most one display interval, which is time the
    frame would have spent invisible anyway; no producer under the display
    rate is delayed at all. The interval must come from the pane's actual
    display, not a hardcoded 120 Hz, or an external 60 Hz monitor pays double.
  - **The bypass is a second delivery path and must stay small.** Its contract
    is exactly doc 25's urgent list plus `onPrimaryHistoryMutation`; anything
    more and it becomes the unbounded path again, anything less and a
    clipboard write or an exit status waits on a flood's deadline.
  - **The benchmark's plan metric will move and should.** `F18` established
    that the churn workloads' plan-metric `slower` is composition -- more
    plans per draw, each cheaper -- and its closing note says `T10` deletes
    the effect at its source. After `T10`, plans per draw on those workloads
    should fall back toward 1; a reading that stays at 1.6 means the deadline
    is not binding where `F18` measured it.
- Decision and rationale: **the consumer holds the deadline; the publish rate
  is bounded by display demand; the drain and the parse never throttle; the
  urgent classes bypass.** The rationale is `F12`'s one-line observation
  sharpened by `F19`: the pipeline pays full per-frame cost for every 16 KiB
  read turn and then lets AppKit discard 12 of every 13 results, and the
  discard ratio grows with every drain improvement. Moving the bound to the
  consumer makes the wasted plan **unrepresentable in the steady state**:
  work is only started when a display pass can consume it. This is the last
  of the three Phase 2 structural changes, and with `D7` it completes the
  regime partition -- `T9` deletes the per-publish amplification the paced
  regime pays, `T10` deletes the publishes the flood regime wastes.
- Behavioral verification, all named before implementation:
  - `scripts/research/33/t4-publish-rate.sh` before and after, release
    configuration, window frontmost: `publishesPerSecond` must fall from
    ~1,560 to the display rate (~120) while `drawsPerSecond` holds, and
    `cumulativeFenceStallNanoseconds` must fall by roughly the same ~13x
    factor.
  - `scripts/research/33/t9-lines-per-delivery.sh`: the 30 lines/s paced
    scenario must be unchanged -- 30 publishes/s at ~1 line per publish,
    proving the deadline never binds under the display rate -- while the
    flood scenario's publishes/s falls to the display rate with mean lines
    per publish rising to match.
  - Deterministic timer tests: damage arriving mid-interval is published
    within one `refreshInterval` (no stale final frame); no timer is armed
    when no damage is pending, per doc 25's `T1` idle-wakeup shape.
  - Bypass tests: bell, clipboard, child exit and `onPrimaryHistoryMutation`
    each observed at the runtime without waiting for the deadline while a
    flood's frame publishes are being deferred.
  - Paired benchmark as the non-regression check, with `F18`'s expected
    reading recorded alongside it: the churn workloads' planned frames per
    draw fall back toward 1, and their plan-metric `slower` reverses.

### D9 -- the glyph halo is derived per row from a measured ink envelope, with the full-row halo as the per-row fallback

- Status: **implemented and verified in `F27`.** The claim is a
  **countable one under `D1`**: on an all-ASCII paced scroll, the store's apply
  shape falls from three erased and five planned full-width rows per damaged
  row (halo of the damage, halo of the halo) to the damaged rows themselves
  plus a 2-pixel erase band and the one neighbor above whose descenders reach
  it -- `t5-scroll-amplification.py`'s glyphs-per-frame is the gate, 1,086
  today against an ideal of 178 (`F23`, reconfirmed post-T25 in `F25`). No
  wall-clock percentage is claimed; the paired benchmark is the non-regression
  check, with the three serialized-draw cells carrying `F25`'s bracket caveat.
- Evidence used: `F6` (no printable-ASCII ink escapes a cell upward on the
  shipped font; descenders overshoot ~1.13 px at 2x; the asymmetric exact
  requirement and the fallback shape); the T14 ink-envelope probe
  (`scripts/research/33/t14-ink-envelope-probe.swift`, run 2026-08-08: all four
  styled faces map every glyph of `0x20...0x7E`, worst-face top margin +4.98 px
  and bottom overshoot +1.13 px at 2x, union envelope top margin 4 px floored /
  bottom overshoot 2 px ceiled, so the margin exceeds the overshoot at both
  scales); a code-read of every non-batch draw path (`drawTextCell` clips
  symbols-face and CTLine-fallback cells to their cell; every sprite family
  either clips to its cell at the render boundary or is geometry-contained per
  `docs/terminal-sprites.md`'s contract) -- which leaves the four styled faces'
  unclipped glyph batch as the *only* ink source that can cross a cell
  boundary; `F23` (the store's stricter erase-set/plan-set contract and the
  latent sub-pixel defect byte-equality caught in the folded seam, since
  deleted with that seam by T25); `F25` (the swapchain applies composed damage
  through the same `apply`, so this shape is now on the one render path).
- What `F6`'s sketch said, and what changed under it: the ledger's safe shape
  was a per-metrics `verticalInkOvershootRows(above:below:)` falling back to
  today's halo *globally* when any contributing face fails containment. Two
  things moved. First, T25 deleted the folded view seam, so the halo's
  production consumers collapsed to `TerminalFrameBackingStore.apply`; `F28`
  later retired the benchmark topology's halo-derived series because it modeled
  that deleted seam. Second, the containment audit
  found the fallback-face and sprite cautions are discharged by clipping --
  but also that the unclipped batch submits *any* BMP scalar the styled face
  maps, not just ASCII, and an accented capital can legitimately exceed the
  ascent. A per-metrics-only envelope is therefore unsound for non-ASCII rows
  and a global fallback would surrender the win to one such row anywhere on
  screen. The granularity rubric points at the fix: classify per row, which is
  the granularity the input actually varies at.
- Candidate solutions considered:
  - **Per-row ink classes over a per-metrics measured envelope.** Selected.
    Each plan row classifies from its text runs: `empty` (no ink), `ascii`
    (every cell single-scalar in `0x20...0x7E` -- exactly the cells the
    measured table batch submits), `general` (anything else; assumed to reach
    one full cell beyond both edges, today's global assumption). The metrics
    measure the ASCII envelope once per face set -- signed ink-top and
    ink-bottom offsets in backing pixels, unioned over the four styled faces,
    valid only when every face maps the whole table -- and `apply` derives:
    the erase region is each damaged row's band extended by the old and new
    ink reach of that row, and the plan set is every row whose ink or band
    footprint intersects the erase region. Rows with background, overlay, or
    decoration runs, and the cursor row, contribute their band as footprint,
    so a sub-pixel erase intrusion into a colored-background neighbor replans
    it rather than refilling it with the default background.
  - **Per-metrics envelope with a global (frame-level) fallback**, `F6`'s
    literal sketch. Rejected: one box-drawing prompt glyph or one accented
    character anywhere on screen would surrender the entire win, and modern
    shell prompts and TUIs make that the common screen, not the edge case.
    Work at iteration granularity for input varying at change granularity is
    the smell this survey exists to delete.
  - **Measure the whole BMP repertoire per face** so non-ASCII batch rows get
    a measured envelope too. Rejected: the union box over a face's repertoire
    legitimately exceeds the line box (accented capitals), so the measurement
    would return the full-row answer anyway; per-glyph tables scale with the
    repertoire for a row class that is rare on real screens.
  - **Clip the batch to the row band** so every draw path is contained and the
    halo dies entirely. Rejected: clipping changes rendering -- it would cut
    legitimate descenders and accents at cell boundaries, which is exactly the
    ink the halo exists to preserve.
- Placement, stated here because the probe depends on it: the classification
  and the erase/plan derivation are pure functions in `TerminalRenderPlanning`
  (plan in, pixel offsets in, row sets out), the measured envelope lives on
  `TerminalRenderMetrics` beside the faces it measures, and the store holds a
  small per-row class ledger describing the ink it last rendered -- updated by
  full renders and applies, translated with shifts -- because the erase must
  cover the *old* content's reach, which only the store knows. The t5 probe
  compiles `TerminalRenderPlanning` already, so it calls the real derivation
  instead of modeling it gate-for-gate.
- Tradeoffs and correctness risks, named:
  - **A wrong envelope shows as dropped ink, not slowness.** The gate is the
    existing `FrameBackingStoreTests` byte-equality suite -- the instrument
    that caught the folded seam's latent halo defect -- extended with
    general-class neighbors, colored-background and decorated neighbors,
    class transitions, and translations over mixed classes.
  - **Rounding is directional.** The ink-top margin floors and the
    ink-bottom overshoot ceils, so quantization can only widen the derived
    reach, never narrow it; AA cannot paint outside the outline's bounding
    box, so pixel-snapped outward bounds cover rasterized coverage.
  - **The worst case is current behavior, per row.** A `general` row's reach
    is exactly today's +-1-row assumption, and a nil envelope (an incomplete
    ASCII table on any face, or degenerate geometry) makes every row
    `general`, reproducing today's shape byte-for-byte.
  - **The class ledger is new state.** It is derived state with a one-line
    invariant -- it describes the rows the store's pixels currently show --
    and it fails safe: a stale-conservative entry (general where ascii would
    do) costs rows, never correctness; the byte gates cover the transitions.
- Behavioral verification, named before implementation:
  - `FrameBackingStoreTests` byte-equality across the arms above, unchanged
    and extended; this replaces no gate and weakens none.
  - `t5-scroll-amplification.py` re-run with the probe calling the real
    derivation: `text-line` and `text-line-at-budget` glyphs per frame must
    fall from 1,086 toward the low hundreds, `bare-newline` from 76 toward
    zero, with the flood row and the `rewrite-bottom-row` control unchanged
    by policy (`.full` never touches the store's incremental path; the
    control's 2.0x halo residue is exactly what this task deletes, so the
    control is expected to fall toward ~178 -- record both).
  - The ink-envelope probe's output recorded in the finding, per face, both
    scales, with the completeness bits.
  - `just test`, `just test-ui`, and `benchmark-confirm` against the pre-T14
    commit as the non-regression check with `F25`'s caveat on the three
    serialized-draw cells.
- Decision and rationale: **derive reach per row and land the measured envelope.**
  F27 records the implementation and gates: paced-scroll glyph submission fell
  from 1,086 to 375 per frame, `bare-newline` fell from 76 to 20, byte equality
  held across the directed arms, and the calibrated ladder reported
  `incremental-mixed` faster by 13.23% with no standing regression.
