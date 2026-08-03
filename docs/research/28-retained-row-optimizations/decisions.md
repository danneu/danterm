# Decisions -- auditable decision log

Next free ID: **D4**. The remaining Phase 3 direction gates in
[README.md](README.md) are `D4` (H2) and `D5` (H5); `D2` was spent on the
browsing freeze and `D3` on the H3-vs-H4 direction.

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

### D2 -- freeze the browsing workload's rule at the conservative envelope, and name its dead zone in the rule itself

- Status: **decided and implemented.** `retained-browse` moves from
  `CANDIDATE_WORKLOADS` into `WORKLOADS`, and a rule enters `DECISION_RULES` for
  both modes. This closes `D1` pitch 1's graduation gate.
- Date and investigator: 2026-08-03, Claude (agent).
- Evidence used: `F5` (screen 1, and its stated inference that the honest rule is
  probably not the cheapest cell), `F6` (screen 2, replicating and quieter),
  `20/F11`/`20/D4` (the conservative-envelope precedent across replicates),
  `F1` (the structural dead zone this rule inherits).

#### The frozen rule

| mode | pairs | threshold | band | source |
| --- | ---: | ---: | ---: | --- |
| quick | 2 | +/-1.05% | 1.0% | both screens propose this cell outright |
| confirm | 4 | +/-1.05% | 0.75% | envelope: looser of two thresholds, one pair-count step above cheapest |

A/A false positives 0.0000 and detection 1.0000/1.0000 on both screens at both
cells, against gates of 0.01 and 0.90.

#### Why the envelope and not the cheapest cell

The two screens agree on `quick` and disagree on `confirm`: screen 1 proposes
+/-1.05%, screen 2 the tighter +/-0.80%, because screen 2's A/A spread is half
screen 1's (SD 0.51% against 0.99%). Freezing 0.80% would fit the rule to the
quieter of two samples and leave no margin the next occasion is guaranteed to
have. `20/F11` set the precedent when its three `synchronized-frames` screens
disagreed -- take the maximum pair count and maximum threshold across the
replicates -- and this follows it.

The pair count is then bought one step above the cheapest cell, which the
envelope alone would not do, because `F5` named the reason before screen 2 ran:
at 2 pairs the `confirm` A/A strict-`inconclusive` rate is 41.4%, and at 4 it is
28.4%. Two pairs is 15 percentage points of avoidable indecision for one extra
pair of blocks on the cheapest workload on the ladder. `quick` is left at 2
pairs deliberately -- its dead zone is 0.05 points wide rather than 0.30, and its
A/A rate is already 8.2%, inside the standard 10% gate. The modes differ because
their bands differ.

#### The dead zone is written into the rule, not left in a research doc

`select_candidate` applies `maximum_inconclusive_rate` to the effect conditions
only and never to A/A, so this rate is real and ungated at any cell the search
can return. It is also **not closable**: `confirm`'s band is 0.75% and the
threshold is 1.05%, so a true difference inside that 0.30-point gap is
unclassifiable by construction, exactly as `F1`'s ~+1% feed effect was. More
pairs narrow the estimator's spread; they do not move the band or the threshold.

The consequence is counter-intuitive enough to belong at the rule rather than
here: **the quietest workload on the ladder is the one most likely to return
`inconclusive`**, because its true effects are small enough to land in the gap.
Both `DECISION_RULES` entries therefore carry a comment stating that an
`inconclusive` browsing result means the difference is smaller than this ladder
resolves, and is not a symptom of a bad run. A future reader who reaches for a
rerun on seeing `inconclusive` here is doing the shopping `F1`'s protocol
forbids.

#### What this licenses, and what it does not

`H1`, `H3`, `H4`, and `H5` may now end in a browsing verdict rather than the
descriptive measurement `15/F18` was reduced to. `D1`'s fallback wording -- every
browsing claim stated as a paired descriptive measurement -- is retired.

It does not license reading `15/F18`'s -5.79% or `F5`'s 342,263 ns as verdicts:
both predate the rule, and a rule is not retroactive. It also does not change
`confirm`'s cost story silently -- `confirm` now runs six workloads rather than
five, and the sixth is the cheapest one on the ladder.

- Behavioral verification: no engine or app behavior changes. The moved workload
  and its rule are benchmark tooling; `just test` passes, including the workload-
  set test that pins the producer, validation, and comparison registries against
  each other.
- Quantitative verification: two independent screens, 24 pairs each, 0 quartets
  discarded in either, recorded in `F5` and `F6` with their host conditions.

### D3 -- H3 proceeds to a design and an experiment; H4 does not stand alone; and the criterion every deciding run will be read against

- Status: **decided as a direction gate.** It selects the hypothesis, states the
  bar its experiment must clear, and names the rules that bar is read under. It
  does **not** contain the design, and no experiment starts here -- the packing
  design is the next hand-off, and it is a plan-shaped piece of work rather than
  a decision entry.
- Date and investigator: 2026-08-03, Claude (agent).
- Evidence used: `F8` (the 89.5% / 10.5% split at both widths, and `H4`'s
  1.16 MB ceiling), `F10` (ragged savings survive the allocator; the ~12.5%
  bucket step; ~37 B/row belongs to history's buffer rather than to rows),
  `F9` (`H2`'s ceiling is 0 bytes on measured content), `F1` (the feed path
  cannot resolve ~1% and cannot buy pairs at `confirm`), `D2` (the frozen
  browsing rule), `D1` pitch 2 and `F7` (the committed resize probe and its
  upgrade gate), `D1` pitch 4 (the preflight annotation).

#### The selection

**`H3` proceeds first.** `F8` put 89.5% of saturated attributable footprint in
stored cell bytes at 179 columns and 89.3% at 80, against 10.5%/10.7% in per-row
overhead -- a 9:1 ordering that does not vary with pane width. `H3` is the
hypothesis pointed at the large side.

**`H4` does not proceed as a standalone candidate.** Its ceiling is 1.16 MB at
179 columns and only at *zero* per-row overhead, which no aggregate-storage
scheme reaches. `F10` sharpens why: about 37 B of the 197.5 B `F8` measured per
row belongs to history's own buffer (a 16 B `GridRow` slot plus its capacity
slack), which an aggregate cell store does not remove -- an aggregate scheme
still needs a per-row descriptor. `H4` stays live only as a *composition* with
`H3`, because `H3` changes what a row requests and therefore which size class it
rounds into; that composition is evaluated inside `H3`'s design, not as a
separate experiment.

**`H2` is handed to `D4` as a formality.** `F9` measured zero blank retained rows
across the whole committed corpus and showed the ceiling is under 350 KB at any
blank fraction below 50%, because canonical trimming already made a blank row
cost 80 B. `D4` still has to write the rejection -- this entry does not dispose
of a hypothesis it did not gate -- but no design work should wait on it.

**`H5` stays gated on `D5`**, unchanged: it is strictly more mechanism than `H3`
for the same bytes, so it is live only if `H3` lands and leaves deep-history
footprint on the table.

#### Does `F10` undercut the `F8` selection? No -- and here is the answer stated rather than assumed

The task that produced `F10` was posed as a threat to `H3`: if malloc rounded on
a fixed quantum, a packing scheme could shrink a row's request and deliver zero
bytes. Measured, the opposite holds. macOS malloc's classes above 256 B are four
buckets per octave -- **~12.5% granularity, geometric rather than quantized** --
so rounding is proportional to the request. Ragged storage realizes 70.8% against
71.1% on paper for `F8`'s payload, the worst gap across all stimuli is 0.9
percentage points, and two stimuli realize *more* than paper. `F8`'s selection
stands unmodified, and `F10` is the reason it can be trusted rather than a
qualification on it.

What `F10` does add is a **design admission test**, and it is cheap enough that
skipping it would be indefensible: a packing scheme must shrink a row's request
by more than one bucket step (~12.5%) to be *guaranteed* to yield any bytes at
all. Below that it can round back into the same class and deliver exactly zero,
however clean its arithmetic looks. `just terminal-retained-row-probe` already
reports the per-row stored-extent distribution for the whole corpus, so a
candidate packing can be priced against real rows -- request before, request
after, class before, class after -- **before a line of engine code is written**.
Any `H3` design that has not been through that arithmetic is not ready for an
experiment.

#### The success criterion, stated before the experiment exists

`H3` is a memory claim and a CPU claim at once, per this doc's rules, so it
clears the bar only if the memory claim is *measured* and neither CPU path
answers `slower`. Concretely:

1. **The win, and it is the deciding measurement.** Attributable footprint at
   saturation must fall, measured with `just terminal-memory-probe` at **both
   179x66 and 80x24** (the doc's standing rule for memory claims), reported as
   the same split `F8` used -- stored cell bytes against per-row overhead --
   with `just terminal-retained-row-probe` supplying the allocation
   decomposition. Absolute bytes and a percentage, both widths, both stated.
2. **The depth effect is stated and decided, never discovered.** Any byte change
   is a depth change: the same 10 MiB budget will admit a different number of
   retained rows. The proposal states retained row count before and after at both
   widths, and if the trade is anything other than "strictly more depth for
   strictly fewer bytes", it is decided in its own `D` entry as numbers -- not
   noticed after landing.
3. **The browsing guard, under `D2`'s frozen rule.** `retained-browse` must not
   answer `slower`: `quick` at **2 pairs, +/-1.05%, band 1.0%**; `confirm` at
   **4 pairs, +/-1.05%, band 0.75%**. `inconclusive` is an acceptable pass here
   and is *expected* -- `D2` wrote the 0.30-point dead zone into the rule itself,
   and reaching for a rerun on seeing it is the shopping `F1`'s protocol forbids.
   A packing scheme that re-inflates on read is exactly the change this workload
   exists to catch, so this is the guard most likely to fire.
4. **The admission guard, and its known wall.** `terminal-feed` must not answer
   `slower`: `quick` at 2 pairs, +/-4.5%, band 1.0%; `confirm` at 2 pairs,
   +/-2.5%, band 0.75%. `F1` established that this workload cannot resolve ~1%
   and cannot buy extra pairs at `confirm`. So if the design's *predicted* feed
   effect is under ~2% and graduation turns on that number, `D1` pitch 3's
   reopening condition fires first:
   `scripts/terminal-benchmark-candidate-screen.py --workload terminal-feed` for
   a longer schedule, before the deciding run rather than after an ambiguous one.
5. **The presentation and damage guards, unchanged from the standing ladder.**
   `confirm` runs `scrollback-stream` (4 pairs, +/-1.85%), `content-churn`
   (4, +/-2.15%), `style-churn` (4, +/-2.0%), and `incremental-mixed`
   (6, +/-1.85%); none may answer `slower`. `style-churn`'s ~3% residual from
   `F3`/`F4` is not an exemption and does not need one -- it lives in
   `dd51a12..e4556c0` and will sit in *both* arms of an adjacent-baseline
   comparison. If `H3` alters damage topology, the sparse-span pair is collected
   descriptively; neither has a frozen rule, so neither can produce a verdict.
6. **Resize is now a two-armed question, which changes `F7`'s status.** `H3`
   changes what reflow unpacks and repacks, so it is exactly the "change
   *expected* to move resize cost" that `D1` pitch 2 named as the gate for
   upgrading the committed probe to a paired candidate workload. That upgrade --
   screening `saturated-resize` toward a frozen rule via the standard pipeline --
   becomes a prerequisite task of `H3`'s experiment if a resize claim is to be
   made. If no resize claim is made, `just terminal-resize-probe` is re-run
   descriptively on both arms and reported as a distribution, as `F7` did.
7. **Every deciding run carries its preflight annotation.** `summary.hostConditions`
   must be present with both pre-launch readings, and read before the verdict is
   trusted. `D1` pitch 4 admitted this as an **annotation, not a gate**: it will
   not refuse a contaminated run, and `F2` is the standing incident where the
   harness graded one `decisionEligible: true` under load average 4.73/5.89/8.92.
   A run whose host conditions are absent or unread is not a deciding run.
8. **Framing, per the doc's evidence floor.** Baseline is the adjacent commit,
   not a wide range (`F3`: three of four `slower` verdicts evaporated when the
   baseline narrowed). AC power, no `DANTERM_BENCHMARK_ALLOW_BATTERY`. Every
   number at or after `dd51a12`.

Graduation is unchanged and deliberately strict: `faster` on a workload that
*contains the moved cost*, nothing else `slower`, or a trade stated as numbers
and decided in a `D` entry before it lands.

#### What this does not decide

The packing representation itself -- packed scalars, run-length styles, a style
side-table, or something else -- is not chosen here, and neither is whether `H4`
composes into it. `F8`'s stated gap is the reason: `styledCellCount` and
`multiScalarCellCount` were **zero** in both of its runs, and `F10` adds nothing
on that axis beyond what `unicode-wrapping` happens to contain. A packing design
is an argument about styled and multi-scalar content, and the corpus has not been
measured for it. Sizing that is the first task of the design work, not a caveat
on it.

- Behavioral verification: nothing here changes engine or app behavior. The
  probes this entry leans on are benchmark-only code already in the gate
  (`just test` passes, including the new retained-row shape tests).
- Quantitative verification: the selection rests on `F8`'s two-width split and
  `F10`'s paper-versus-realized comparison, both reproducible from committed
  probes (`just terminal-memory-probe`, `just terminal-retained-row-probe`). The
  criterion above is the verification plan for the work this gate authorizes.
