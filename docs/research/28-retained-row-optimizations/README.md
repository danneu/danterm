# Retained-row optimization opportunities

Research started: 2026-08-03.
Continues: [15-memory-footprint.md](../15-memory-footprint.md) (`15/H6`,
`15/H7`, `15/F18`).

- [findings.md](findings.md) -- the append-only evidence chain.
- [decisions.md](decisions.md) -- the auditable decision log.

## Purpose

This doc owns **the follow-on performance opportunities opened by compact
retained-row storage** -- the representation shipped in
`plans/impl/2026-08-01-1803-compact-retained-scrollback-rows.md` (seam
`fa01b66`, trim `dd51a12`, validation `54d4d2d`). Retained rows now store only
their content prefix in canonical form; the blank tail is virtual, depth
follows content rather than pane width, and the budget charge is coherent
under seam mutation. Several optimizations that were incoherent against
full-width mutable rows are newly cheap or newly attackable against canonical
content-sized rows. This doc enumerates them, sizes them against fresh
evidence, and graduates any winner to a plan.

It also owns the measurement residue the shipped change left behind: `15/F18`
never resolved the feed-path CPU verdict, and the browsing-render measurement
was a one-off probe that no routine workload can reproduce.

| Question | Owned by |
| --- | --- |
| What the process held before compact rows, and the shipped compaction | doc 15 (**closed**) |
| Live-grid cell layout (`GridCell` stride, alignment) | doc 16 (**closed**, rejected) |
| Renderer bracket leads | doc 18 (live) |
| **What compact retained rows make possible next** | **this file** |

## Investigation rules

- **Evidence floor: `dd51a12`.** Every number used in a verdict is measured at
  or after the trim commit, on current HEAD. Pre-trim measurements across docs
  9-17 are historical orientation and technique input only -- the
  representation, the cell (32 bytes since `15/F15`), and the row population
  (`15/F18`: 5,799 plain rows at saturation, up from ~1,700) have all changed
  under them. `15/F18` is the only inherited baseline; anything it did not
  measure gets measured fresh here.
- **Performance claims follow
  [agent-docs/terminal-performance.md](../../../agent-docs/terminal-performance.md)**:
  name the benchmark, commit, and compatibility conditions; profiled or probe
  timings are diagnostic, never benchmark verdicts, until a frozen decision
  rule exists.
- **An experiment ends in a verdict, and a candidate graduates only on
  `faster` (or a deliberate, quantified trade).** A hypothesis leaves this doc
  for a plan only when a calibrated workload that *contains the moved cost*
  answers `faster` under its frozen rule, and nothing else the change
  plausibly touches answers `slower`: `terminal-feed` and `scrollback-stream`
  for anything on the admission path, the serialized-draw ladder for anything
  on presentation, and the sparse-span candidates (`sparse-spans-few`/`-max`)
  for anything that alters damage topology. Memory claims ride the probe at
  both 179 and 80 columns. A trade (e.g. H4 giving back depth for footprint)
  is admissible only stated as numbers and decided in a `D` entry, never
  discovered after landing.
- **A cost no calibrated workload contains gets a workload before it gets an
  experiment.** The ladder's recent growth is the precedent: btop's
  `synchronized-frames` and the sparse-span pair entered as candidates and are
  screened toward frozen rules via
  `scripts/terminal-benchmark-candidate-screen.py` and the winsorized freeze
  pipeline (per
  [agent-docs/measurement-discipline.md](../../../agent-docs/measurement-discipline.md)).
  An unfrozen workload produces numbers, not decisions -- `23/D4`'s demotion
  of `synchronized-frames` is the standing example. If a hypothesis here moves
  a cost the ladder cannot see, building and screening that measurement is a
  prerequisite task of the hypothesis, not optional tooling.
- **Measurement machinery must not perturb what it measures -- or anything
  else.** The standing incident: the benchmark's activity-snapshot write ran
  inside AppKit's `draw(_:)` and billed 71 ms of a 20 s btop-scroll trace to
  the path it exists to observe, fixed in `6747e82` and pinned by
  `scripts/terminal-benchmark-draw-path-lint.sh` in the test gate (its sibling
  `2eaac68` moved coverage observation onto a clock for the same reason). Any
  workload, probe, or coverage instrumentation this doc adds obeys the same
  law: its cost stays off the measured hot paths (run-loop timers and
  benchmark-only code, never draw/feed/admission callbacks); if it must touch
  app or engine code, that change gets the same no-`slower` paired treatment
  as an optimization candidate; and where the boundary is mechanically
  pinnable, pin it with a lint in the gate rather than a convention in prose.
- **The shipped invariants are the boundary, not an obstacle course.** Any
  candidate must preserve canonical trimmed form (stored cells are a pure
  function of observable content), budget-charge coherence, and the
  observability contract (reads at every column below `columnCount` answer as
  before). The landed behavioral suite is the gate. A candidate that needs to
  relax canonicality -- e.g. lazy trimming to reclaim feed-path allocation --
  is a plan-level decision to reopen, not a research-side hack.
- **Any byte change is a depth change.** The budget is denominated in bytes,
  so a representation change silently changes retained depth at the same
  nominal budget. Every proposal states its depth effect and decides it
  deliberately (carried forward from doc 12/15 as a rule, not a number).
- **A representation change is a CPU claim as much as a memory claim.** State
  and measure the effect on the feed path (admission) and the browsing render
  path (presentation) for every candidate.
- **References supply techniques, never numbers.** kitty's `PagerHistoryBuf`
  (`references/kitty/kitty/history.h#PagerHistoryBuf`) and similar prior art
  are mined for shape and edge cases; every cost and benefit is measured in
  DanTerm.
- **Pre-adjudicated boundaries stay closed here.** Doc 16 closed live-grid
  `GridCell` layout changes. The shipped plan's rejected ideas (charge content
  while storing full width; content-width field beside a full array; inflate
  on read) stay rejected. Doc 27's adoption bar governs any swift-collections
  container this doc is tempted by.

## Trigger and current evidence

The compact retained-row representation landed 2026-08-01 and `15/F18`
validated it: plain retained history is **3.41x deeper at 179 columns and
1.71x deeper at 80 columns** at the same 10 MiB budget, candidate depth
converges across pane widths (content now dominates the charge), the browsing
frame plan measured **-5.79% symmetric median** in a 16-pair probe, and a live
widen kept the head of history byte-identical.

Three facts in that finding are this doc's starting evidence:

1. **Per-row fixed overhead is now a first-class cost.** At saturation the
   candidate holds 2,404-4,097 *more* row arrays than before; their
   `GridRow` strides, array headers, and allocator buckets raised attributable
   footprint by +2.51 MB at 179 columns (+21.8%) and +0.44 MB at 80. Compact
   rows converted the dominant cost from blank cells to per-row overhead --
   which is `15/H7`'s territory, quantified fresh by `15/F18`.
2. **The feed-path CPU verdict is closed as unobtainable, not as neutral**
   (`F1`). Four valid paired schedules agree on +1.03% to +1.45% against
   `fa01b66`, which falls in the dead zone between `confirm`'s equivalence band
   and its directional threshold; the escalation ladder has no third rung. The
   shipped plan's `AR2` neutrality assumption is therefore neither confirmed
   nor refuted, and the only defensible statement is a bound: admission-time
   trimming costs no more than ~2.5% on the feed path, point estimate ~+1%.
   Later candidates in this doc inherit that bound, not a neutrality claim.
3. **The browsing measurement is unreproducible by routine tooling.** No
   paired workload displays retained history -- `scrollback-stream` follows
   the bottom and the draw workloads start from live grids. `15/F18`'s result
   came from a temporary probe that was deleted after measurement.
4. **The benchmark system just grew in the right direction, but not far
   enough for this doc.** The ladder now carries btop's `synchronized-frames`
   workload, the `sparse-spans-few`/`sparse-spans-max` candidates for
   non-contiguous damage, and the live btop-scroll GUI diagnostic
   (`just test-terminal-btop-gui`) -- all presentation/damage coverage. The
   two paths this doc's hypotheses move remain uncovered: nothing displays
   retained history, and nothing resizes a deep history. Both gaps are named
   workload pitches in the Phase 1 ledger.

## Current hypotheses

### H1 -- deep-history resize is now proportionally cheaper, and nobody has measured it

Reflow unpacks and repacks every retained row on a width change. Both sides of
that operation now touch the content prefix instead of `columnCount` cells per
row, so a saturated-history resize should move roughly a content-to-width
ratio less data -- while also processing ~2-3x more rows at the same budget,
which cuts against it. Net direction is genuinely unknown. Window-drag latency
on a deep pane is user-visible and composes with the shipped resize
coalescing. Confirm or reject with a paired before/after-style probe at HEAD
(there is no pre-trim arm to compare against and the rules forbid wanting one;
the measurement is absolute: does saturated resize fit comfortably in a frame
budget, and where does its time go).

### H2 -- canonical blank rows can share one storage allocation

Canonical form means every fully blank retained row stores identical content
(one blank cell). Swift arrays are COW, so all blank rows could share a single
storage buffer: a screenful of blank lines costs one allocation total. Two
open mechanics questions decide viability: the budget charges per-row
`capacity`, so shared storage needs a deliberate charge-model answer (charging
each row for shared bytes overstates; charging once complicates eviction
accounting), and the share must survive the seam (a write into a shared blank
row must CoW-detach without corrupting siblings -- the existing suite should
prove this for free). Reject if blank rows are a negligible fraction of real
histories (measure first).

### H3 -- retained rows can be packed tighter than `[GridCell]` (15/H6 proper)

The shipped change stores fewer cells; `15/H6` proposes storing them
*smaller*: retained rows are immutable-in-practice, so a packed form (packed
scalars plus run-length styles, or similar) does not need the live grid's
32-byte random-write cell. This is the deferred remainder of `15/H6`, and the
shipped seam -- readers already tolerate storage narrower than the logical row
-- is most of the machinery it needed. Doc 16's constraint stands: the live
grid's `GridCell` is untouched. Gate on Phase 2 evidence: only worth designing
if stored cell bytes, not per-row overhead, dominate the remaining footprint.

### H4 -- per-row overhead wants fewer, larger allocations (15/H7 on new evidence)

The counterpart gate to H3. `15/F18` measured the overhead side growing
(+2.51 MB attributable at 179 columns) precisely because compact rows multiply
row count at a fixed budget. `15/H7`'s narrow form -- aggregate storage for
immutable retained rows only, no manual memory control -- composes with H3 and
attacks the bytes H3 cannot. Whichever of H3/H4 Phase 2 shows is larger gets
designed first; they may graduate as one plan (that is doc 15's own Phase-3
gate logic, reapplied to post-trim numbers).

### H5 -- ancient history can demote to a compressed tier

kitty's `PagerHistoryBuf` precedent: recent history stays cell-backed for
interaction; history older than some horizon demotes to packed text that
re-inflates on browse. Strictly more mechanism than H3/H4 for the same bytes,
so it is live only if Phase 2 shows deep-history footprint still matters after
the cheaper hypotheses land or are rejected. The canonical representation
makes the demotion boundary well-defined (stored content is already exactly
the observable content).

### H6 -- canonical rows make scrollback persistence cheap enough to be a feature

Storage is now a pure function of observable content: content-sized and
deterministic across runs, which is exactly what a save/restore codec wants
(and aligns with the SAVED/SENT/ASSERTED injection rule). This is a product
question before it is a performance question -- the recovery store snapshots
the model, not terminal content, today. Parked until session-restore of
terminal content is a live feature goal; recorded here so the sizing argument
is not lost.

## Task ledger

### Phase 1 -- close the shipped change's measurement residue

- [x] `DONE` Resolve the feed-path verdict at HEAD. Closed by `F1`: **no
  directional verdict is obtainable.** Four valid paired schedules (`15/F18`'s
  quick and confirm, plus a quick and a confirm at `6da2bb7` on AC power)
  agree on +1.03% to +1.45% against baseline `fa01b66`, which sits in the dead
  zone between `confirm`'s 0.75% equivalence band and its 2.5% directional
  threshold. The escalation ladder is exhausted and re-running is shopping. The
  defensible bound: admission-time trimming costs no more than ~2.5% on the
  feed path, point estimate ~+1%, direction slower. The `scrollback-stream`
  empty-stdout defect did **not** recur -- `15/F18` records it as already
  diagnosed and repaired (theme-packer status prefix; the tolerance lives in
  `_load_fresh_replay_result` in `scripts/terminal-benchmark-validation.py`),
  and all four `scrollback-stream` blocks of this confirm returned JSON. That
  confirm also produced `F2`, which is unrelated to the trim and is flagged
  there for another doc.
- [x] `DONE` Isolate `F2`'s draw-path signal against the adjacent baseline.
  Closed by `F3`: `just benchmark-confirm baseline=dd51a12` collapsed three of
  the four `slower` verdicts (`scrollback-stream` +4.46% -> `equivalent`,
  `content-churn` +4.02% -> `inconclusive`, and `incremental-mixed` is
  sign-mixed across -8.03%..+8.95% and so not directional). **`style-churn`
  survives at +3.09%** with tight positive pairs, reproducing `F2`'s +3.47%,
  which places it in `dd51a12..HEAD`. Handed to docs 29/30 with the isolating
  bisect named (`confirm` against `13f82c8~1` separates the renderer work from
  its accepted-draw-path instrumentation). Not fixed here: the cause may be the
  renderer work, which this doc does not own.
- [x] `DONE` Run the `13f82c8~1` bisect and attribute `F3`'s survivor. Closed
  by `F4`: `style-churn` is **4.05% faster** at HEAD than at `13f82c8~1` (four
  of four negative pairs), so the accepted-draw-path instrumentation is **not**
  the cause and this doc's measurement-machinery rule did not recur. `13f82c8`'s
  recorder is nil for every workload but the two sparse-span ones, which is the
  mechanism. The residual cost localizes to `dd51a12..e4556c0` -- the sparse
  damage renderer work -- and is handed to docs 29/30 unfixed, with both
  bounding runs named. `content-churn` is also 4.46% faster over the same range,
  plausibly `6747e82`/`2eaac68` paying out.
- [x] `DONE` Pitch and decide benchmark coverage for retained history.
  Closed by `D1`, which dispositions four pitches: admit the retained-history
  browsing workload as a candidate; freeze the saturated-resize probe recipe
  rather than admitting it (H1's question is absolute, not paired); reject a
  longer-schedule `terminal-feed` screening tier with a stated reopening
  condition; and admit a host-idleness preflight annotation, sequenced first.
- [x] `DONE` Implement `D1`'s admitted item (a), the preflight host-idleness
  annotation. `sample_host_conditions` in
  `scripts/terminal-benchmark-compare.py` reads load average, per-processor
  load, and the busiest **non-harness** processes at two points -- at invocation
  and immediately before the first block -- and records both under
  `summary.hostConditions` in `run.json`, rendered beside the verdicts. It
  excludes the driver's own descendants (`F3`'s confound), reports "not
  measured" as a state distinct from "measured idle", and applies **no
  threshold**, per `D1`'s refusal to invent an uncalibrated gate. Off every
  measured path by construction: it runs before collection starts.
- [x] `DONE` Implement `D1`'s admitted item (b), the retained-history browsing
  candidate workload. `lib/TerminalCore/Sources/TerminalBrowseBenchmarkSupport`
  plus the `TerminalBrowseBenchmark` executable resurrect `15/F18`'s recipe
  (179x66, 10,000 hard-terminated lines, parked at the oldest retained row, 20
  warm and 2,000 measured `planFrame` calls, coverage checksum). Registered as
  `retained-browse` in `CANDIDATE_WORKLOADS` with a block contract and the
  `planNanosecondsPerFrame` metric -- **no frozen rule**, per `D1`'s gate.
  Headless, so it needs no window: it plans frames and never draws one. Screen
  result in `F5`.
- [x] `DONE` Implement `D1`'s admitted item (c), the committed saturated-resize
  probe recipe. `lib/TerminalCore/Sources/TerminalResizeProbeSupport` plus the
  `TerminalResizeProbe` executable and `just terminal-resize-probe` freeze the
  recipe `D1` pitch 2 specified: geometry, budget, retained row count, warm
  count, and sample count all stated in the emitted report, and a distribution
  reported rather than a single number. Benchmark-only code, no app or engine
  hook, so no lint was needed. First run recorded descriptively in `F7`: ~98 ms
  median over 6,756 retained rows, with narrowing and widening separable. **No
  verdict** -- `D1` scoped this probe to an absolute question with one arm.
- [x] `DONE` Run the **second** independent browsing screen `D1` requires.
  Closed by `F6`: a separate invocation at a separate tree replicates screen 1
  and is quieter (SD 0.51% against 0.99%, 0 of 12 quartets discarded in both).
  Frozen by `D2` at the **conservative envelope** rather than the cheapest cell
  -- `quick` 2 pairs at +/-1.05%, `confirm` **4** pairs at +/-1.05% -- and
  `retained-browse` moved from `CANDIDATE_WORKLOADS` into `WORKLOADS`. Both
  rules carry the A/A dead zone in their own comment, so a reader who sees
  `inconclusive` here knows it is structural rather than a bad run. This screen
  is also the host-condition preflight's first real consumer: the screen script
  now records both pre-launch readings into `candidate-screen.json`.
- [ ] ~~`TODO` Pitch and decide benchmark coverage for retained history, so
  every later experiment here can end in a verdict rather than a probe
  anecdote. Two named gaps, one decision: (a) a **retained-history browsing**
  workload -- saturate history, scroll to the oldest row, then run serialized
  updates while the viewport sits in history (`15/F18`'s deleted probe is the
  recipe; the sparse-span pair is the precedent for admitting it as a
  candidate and screening it toward a frozen rule); (b) a
  **saturated-history resize** workload or documented probe -- repeated width
  changes against 5,000+ retained rows, timed like the serialized-draw
  blocks. Decide each as: admit as candidate, freeze a probe recipe, or
  reject with reason. Either workload lives in benchmark-only code per the
  measurement-machinery rule; any hook it needs in app or engine code gets
  the no-`slower` treatment and, where pinnable, a gate lint. Destination:
  `D1`.~~ (superseded by the two entries above; kept for the reasoning it
  carries)

### Phase 2 -- size the remaining costs at HEAD

- [x] `DONE` Split saturated attributable footprint into stored cell bytes vs
  per-row fixed overhead (headers, `GridRow` strides, bucket slack) at both
  179 and 80 columns, using the census plus probe arithmetic. Closed by `F8`:
  **stored cell bytes are 89.5% at 179 columns and 89.3% at 80**, per-row
  overhead 10.5%/10.7% at ~197 bytes per row allocation, and the split does not
  vary with pane width. The malloc block delta matches the row allocation count
  to within 64 blocks at both widths, so the residual is per-row overhead rather
  than an unattributed mixture. **H3 is the larger target by roughly 9x**; H4's
  ceiling is 1.16 MB at 179 columns and only at zero per-row overhead.
- [ ] `TODO` Measure blank-row frequency in realistic histories (shell
  sessions, build logs, TUI dumps -- the existing benchmark corpora) to size
  H2's ceiling. Destination: `F9`.
- [ ] `TODO` Check allocator behavior under ragged row sizes: do
  content-length-distributed allocations fragment size classes measurably, or
  does malloc absorb them? (`15/F7`'s bucket analysis is technique precedent;
  numbers measured fresh.) Destination: `F10`.
- [ ] `RESEARCH` Probe saturated-history resize cost at HEAD (H1): where does
  a full-width change on 5,000+ retained rows spend its time, and is it within
  a frame budget? `F7` has the distribution and the committed probe; this task
  is the profile and the frame-budget reading `F7` deliberately withheld.
  Destination: `F11`.

### Phase 3 -- direction gates

- [ ] `TODO` Gate: H3 vs H4 -- pick the larger target from `F8`, or conclude
  both/neither clears the bar. `F8` supplies the split (89.5% cells vs 10.5%
  per-row overhead) and points at H3; what it does not settle is whether H3
  clears the bar at all, which needs a design with a stated depth effect and a
  browsing verdict under `D2`'s now-frozen rule. Destination: `D3`.
- [ ] `TODO` Gate: H2 -- viable only if `F9` shows blank rows matter and the
  charge-model question has a clean answer. Destination: `D4`.
- [ ] `TODO` Gate: H5 -- live only if the selected H3/H4 direction leaves
  deep-history footprint on the table. Destination: `D5`.

### Phase 4 -- graduate

- [ ] `TODO` Extract any selected direction into a plan file; record where it
  went and close, or close with all hypotheses dispositioned.

## Rejected

None yet. The shipped plan's rejected ideas and doc 16's closure are inherited
boundaries (see Investigation rules), not re-litigated here.

## Open questions and caveats

- ~~Is +2.51 MB attributable footprint at 179-column saturation an accepted cost
  of 3.41x depth, or itself a target?~~ **Sized by `F8`:** per-row overhead is
  1.16 MB of an 11.00 MB attributable total, 10.5%. `15/F18`'s +2.51 MB is a
  delta against the pre-trim representation, not a share of the current one, and
  the two are not in tension. H4 could at best reclaim that 1.16 MB and only by
  driving per-row overhead to zero, which nothing does.
- ~~The browsing -5.79% result has no frozen decision rule behind it; treat it
  as descriptive until `D1` gives the measurement a home.~~ **Resolved by `D2`:**
  the workload is calibrated and future browsing claims can be verdicts. The
  -5.79% itself stays descriptive -- a rule is not retroactive, and `15/F18`'s
  probe no longer exists to re-run under it.
- `terminal-feed` cannot resolve a ~1% effect and buys no extra pairs at
  `confirm` (`F1`). Any later candidate here whose predicted feed effect is
  around 1% will hit the same wall, so either predict a larger effect or expect
  to screen `terminal-feed` for a longer schedule before running one.
- `F2`'s four `slower` verdicts are resolved by `F3`: three were artifacts of a
  15-commit-wide baseline plus host load, and **`style-churn`'s ~3% survives**,
  living in `dd51a12..HEAD`. `F4` then ran the bisect and narrowed it to
  `dd51a12..e4556c0` -- the sparse-damage renderer work -- while clearing the
  benchmark instrumentation. The renderer docs own it; neither doc 29's nor doc
  30's outcome currently names this cost.
- A wide baseline is a smoke alarm, not a diagnosis. Three of `F2`'s four
  verdicts evaporated under the correct adjacent baseline, so per-commit A/B is
  the discipline. Its one structural blind spot is the reason to run a wide
  baseline occasionally anyway: `F1` established that `terminal-feed` cannot
  resolve ~1% and cannot buy pairs, so a series of individually sub-threshold
  regressions would each read `equivalent` while the range total did not. Run
  wide baselines to detect accumulation, never to attribute it.
- `F1`'s ~+1% feed cost is now attributed to the trim itself, not to later
  commits (`F3` reads `equivalent` on `terminal-feed` across `dd51a12..HEAD`).
  The bound is unchanged; only the attribution sharpened.
- The harness graded a load-contaminated run `decisionEligible: true` (`F2`).
  `D1`'s preflight annotation now exists and every `run.json` carries two
  pre-launch host readings. It is an annotation, **not a gate**: it will not
  stop a contaminated run, so reading it before trusting a verdict is still the
  operator's job. What load actually perturbs a verdict remains uncalibrated,
  and that is the evidence a refusal threshold would need.
- ~~The browsing workload is admitted as a **candidate** only.~~ **Closed by
  `F6`/`D2`:** two independent screens replicate and the envelope is frozen.
  What replaces this caveat is a subtler one -- **expect `inconclusive` on this
  workload and do not treat it as a defect.** `confirm`'s band is 0.75% and its
  frozen threshold 1.05%, so a true difference inside that 0.30-point gap is
  unclassifiable by construction; screen 1's A/A series landed there 28.4% of
  the time at the frozen 4 pairs. Being the quietest workload on the ladder is
  exactly what makes it prone to this: its real effects are small enough to fall
  in the gap. The rule entries in `DECISION_RULES` say so in place, so nobody
  reaches for the rerun `F1`'s protocol forbids.
- `F7`'s resize distribution is a **probe**, not a verdict, and `D1` pitch 2
  chose that deliberately: `H1`'s question has one arm. The ~98 ms median and
  the narrow/widen split are descriptive facts about one geometry on one
  machine. Reading them against a frame budget is Phase 2's `RESEARCH` task, and
  upgrading the probe to a paired candidate workload needs `D1`'s stated gate --
  a change *expected* to move resize cost, which is what supplies a second arm.
- H2's charge-model question (how shared storage is charged) may itself be the
  reason to reject it; cheapness of the trick does not excuse an incoherent
  budget.

## Outcome

Investigation in progress.
