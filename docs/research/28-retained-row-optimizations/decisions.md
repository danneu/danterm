# Decisions -- auditable decision log

Next free ID: **D2**. Direction gates D2-D4 named by the Phase 3 tasks in
[README.md](README.md) shift accordingly if `D1` spawns siblings.

### D1 -- benchmark coverage for retained history, and two instrument gaps the Phase 1 runs exposed

- Status: **decided as a pitch set with gating criteria.** Four pitches, each
  dispositioned below. Implementation is a follow-on ledger task, not part of
  this entry -- per the doc's rule that a cost no calibrated workload contains
  gets a workload before it gets an experiment.
- Date and investigator: 2026-08-03, Claude (agent).
- Evidence used: `15/F18` (the deleted browsing probe and its -5.79% result),
  `F1` (the feed verdict is unobtainable; `terminal-feed` cannot resolve ~1%
  and cannot buy pairs at `confirm`), `F2`/`F3` (a wide baseline plus host load
  produced four `slower` verdicts, three of which evaporated under the correct
  adjacent baseline, on a run the harness graded `decisionEligible: true`).

#### Pitch 1 -- retained-history browsing workload. **Admit as candidate.**

- The gap: nothing on the ladder displays retained history.
  `scrollback-stream` follows the bottom; the three serialized-draw workloads
  start from live grids. So `15/F18`'s browsing measurement -- the single
  strongest result the compact-row change produced, -5.79% on frame planning --
  rests on a probe that was deleted after measurement and cannot be re-run.
- The recipe is already written down in `15/F18`: identical 179x66 terminals,
  10,000 short hard-terminated lines, browse from the oldest retained row, warm
  20 full `planFrame` calls, time 2,000 per process, ABBA rounds, checksum both
  arms to prove they planned the same cells.
- Why a candidate and not a frozen rule: the doc's own precedent
  (`sparse-spans-few`/`-max`, and `23/D4`'s demotion of `synchronized-frames`)
  is that a workload enters `CANDIDATE_WORKLOADS`, collects descriptively, and
  earns a rule only from a screening pass a human signs off via
  `scripts/terminal-benchmark-candidate-screen.py`.
- Gating criterion to graduate to a frozen rule: a screen that selects a
  (pair count, threshold) cell clearing the standing accuracy gates -- A/A
  false positives under 1% against detection at 90% -- on two independent
  screens. If no cell selects, it stays descriptive, and every H1/H3/H4/H5
  browsing claim must then be stated as a paired descriptive measurement, as
  `15/F18`'s was.
- Placement: benchmark-only code. It plans frames; it must not add a callback
  to the draw or admission path.

#### Pitch 2 -- saturated-history resize workload. **Freeze a probe recipe, do not admit as a candidate.**

- The gap: nothing on the ladder resizes a deep history, which is exactly what
  `H1` proposes to measure.
- Why a probe rather than a candidate: `H1`'s question is **absolute, not
  comparative** -- "does a saturated resize fit in a frame budget, and where
  does its time go" -- and the doc already states there is no pre-trim arm to
  compare against and that wanting one is forbidden. A paired workload answers
  a question nobody is asking here, and a frozen rule for it would be
  calibration effort spent on a comparison that has no second arm.
- What "freeze the recipe" means concretely: the probe is committed rather than
  deleted after use (the `15/F18` failure this doc is still paying for), it
  states its geometry, budget, row count, and repeat count, and it reports a
  distribution rather than a single number.
- Gating criterion to upgrade to a candidate workload: only if a change is
  proposed that is *expected* to move resize cost, at which point the
  comparison has two arms and paired measurement becomes meaningful.

#### Pitch 3 -- a longer-schedule screening tier for `terminal-feed`. **Reject for now; reopen on a named candidate.**

- The gap `F1` found: `terminal-feed` is the only ladder workload whose
  `confirm` pair count stays at 2 rather than 4-6, so escalation buys a tighter
  threshold and no extra pairs. Four schedules agreed on ~+1% and none could
  classify it. Any future candidate here predicting a ~1% feed effect hits the
  identical wall.
- Why reject now: a screen is only worth its cost against a change you intend
  to decide. Screening `terminal-feed` to chase an effect already bounded under
  2.5%, on a trim that has shipped and is not being reverted, buys a number
  nobody will act on. `17/F15` is the standing precedent that a screening pass
  can legitimately propose nothing.
- Reopening condition, stated so the next agent does not re-derive it: the
  first time a candidate in this doc predicts a feed-path effect **under ~2%**
  and the decision to graduate it turns on that number, run
  `scripts/terminal-benchmark-candidate-screen.py --workload terminal-feed`
  first. `terminal-feed` owns its blocks and so *can* buy more pairs -- that is
  exactly the lever `17/F15` says an auxiliary metric lacks and a workload has.

#### Pitch 4 -- a host-idleness preflight guard. **Admit, scoped to annotate-and-refuse, and it is the highest-value item here.**

- The gap `F2`/`F3` found, and it is an instrument defect rather than a
  measurement: a confirm run taken while host load averaged 4.73/5.89/8.92,
  with `WindowServer` at ~49% and a second agent session at ~17%, reported four
  `slower` verdicts with `invalidations: []` and `decisionEligible: true`.
  **The harness cannot see the one stated condition that was violated.** Three
  of those four verdicts did not survive re-measurement.
- The non-obvious design constraint, measured rather than assumed (`F3`): host
  load sampled *during* a run rose monotonically from 3.23 to 9.68 because the
  benchmark's own builds and GUI app are most of it. **Load average during the
  run is confounded by the run and cannot be the gate.** The guard must sample
  before launch, or discount the harness's own process tree.
- Scope, deliberately narrow: sample host load and the top non-harness CPU
  consumers immediately before the first block, record them in `run.json`
  beside the existing condition evidence, and either refuse or stamp the run
  with a condition annotation the summary carries. It must be able to say "not
  measured" distinctly from "measured idle", per the measurement-discipline
  rule this doc already binds itself to.
- What it must not do: gate on a threshold nobody calibrated. The honest first
  version records the readings and annotates; a refusal threshold is a second
  decision that needs its own evidence about what load actually perturbs a
  verdict.
- Placement: preflight, in the comparison driver. It runs once before blocks
  start, so it is off every measured path by construction -- the
  measurement-machinery rule is satisfied trivially rather than by argument.
- Tradeoff and risk: a guard that refuses too eagerly makes the ladder unusable
  on a developer's working machine, which is the only machine it has. `F3`
  established that this machine's floor is ~2.4 with `WindowServer` at 45% and
  will not go quieter. Annotate-first is the direction precisely because the
  refusal threshold is unknown and a wrong one is worse than none.

#### Decision and rationale

Admit Pitch 1 as a candidate workload and Pitch 4 as a preflight annotation;
freeze Pitch 2 as a committed probe recipe; reject Pitch 3 with the reopening
condition above. Pitch 4 is sequenced first despite being the one nobody asked
for: it is the cheapest item, it is the only one that protects every later
measurement in this doc, and `F2` is the concrete incident showing that without
it the harness reports confident verdicts under conditions it cannot observe.

Pitch 1 is the one the doc's hypotheses actually need -- H1, H3, H4, and H5 all
make browsing claims, and none of them can currently end in anything better
than the descriptive anecdote `15/F18` was reduced to.

- Behavioral verification: none of the four pitches changes engine or app
  behavior. Pitch 4 touches the comparison driver only; Pitches 1-2 are
  benchmark-only code. Any hook that turns out to require an app or engine
  callback gets the no-`slower` paired treatment and a gate lint, per this
  doc's measurement-machinery rule -- and if a pitch cannot be built without
  such a hook, that fact is itself a finding worth recording before it is
  built.
- Quantitative verification: Pitch 1's graduation is gated on the screening
  criterion stated under it; Pitch 4's is a run whose `run.json` carries
  pre-launch host readings that a reader can check against the verdict.
