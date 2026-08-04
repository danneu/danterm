# Decisions -- auditable decision log

Next free ID: **D9**, which the remaining Phase 3 direction gate in
[README.md](README.md) (H5) claims. `D2` was spent on the browsing freeze, `D3`
on the H3-vs-H4 direction, `D4` on rejecting H2, `D5` on selecting H3's packing
representation, `D6` on correcting its pricing, `D7` on the resize-for-depth
trade, and `D8` on the bounds that resolve it. IDs are allocated in the order
entries are written, not reserved in advance -- the H5 gate has now moved from
`D5` to `D6` to `D7` to `D8` to `D9` for that reason.

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

### D4 -- H2 is rejected on sizing: canonical trimming already took this win, and the population it needs is empty

- Status: **decided as a direction gate, and it is a rejection.** `H2` is closed.
  Nothing waits on this entry -- `D3` handed it over as a formality -- but the
  rejection has to be written down with its reopening condition, because a
  blank-row sharing trick is exactly the kind of idea that gets re-derived from
  first principles by the next reader of the representation.
- Date and investigator: 2026-08-03, Claude (agent).
- Evidence used: `F9` (0 blank retained rows across the committed corpus, the
  80 B / 1,808 B per-row charge arithmetic, and the ceiling curve), `F10` (the
  blank row's 64 B heap block and the ~37 B/row that lives in history's own
  buffer rather than in the row), `D3` (which gated the direction and deferred
  this disposition), and doc 15's `D4` (the budget charges `Array.capacity`,
  which is what makes the charge-model question below well-posed at all).

#### The decision

**`H2` -- "canonical blank rows can share one storage allocation" -- is
rejected.** It does not proceed to a design, an experiment, or a plan.

#### Why, and the reason is structural rather than a corpus accident

The obvious reading of `F9` is "the corpus has no blank rows, so measure a
better corpus." That reading is wrong, and stating why is the whole point of
this entry.

The measured facts are two, and only the first is about the corpus:

1. **The population is empty.** Not one retained row in the committed corpus is
   blank -- 0 of 133 recorded rows across 34 live PTY captures of fish/zsh/bash,
   vim, tmux, htop and git log, and 0 of 4,707 rows overall. `F9`'s negative
   control reports 49.9% blank on an alternating stream and the unit suite pins
   that a bare-newline row counts as blank, so the zero is a measurement rather
   than a broken detector. The mechanism behind it is not sampling luck either:
   a blank row only reaches history if a session emits blank lines *faster than
   a screenful*, and interactive shells and TUIs leave their blank rows on the
   screen, where they are overwritten or redrawn.
2. **The prize is small at every blank fraction short of the absurd, and that
   is a fact about the representation, not about the corpus.** The shipped trim
   made a blank retained row cost **80 B** (16 B `GridRow` slot + 32 B array
   header + 32 B for its one canonical cell) against a content row's **1,808 B**
   at `F8`'s saturation regime. Sharing storage reclaims only the 64 B heap
   block -- the `GridRow` slot stays in history's buffer either way (`F10`
   observation 5). So the ceiling curve is convex and nearly flat: 40.1 KB at a
   10% blank fraction, 119.1 KB at 25%, **347.1 KB at 50%** -- 3.39% of a 10 MiB
   budget at a blank fraction no plausible session reaches. It only becomes
   interesting (8.00 MB, 80% of budget) at a history that is *entirely* blank.

Fact 2 is the one that closes this. A better corpus could move `f`; it cannot
move the curve. **`H2` is not a win awaiting better evidence -- it is a win the
shipped trim already collected**, by making the blank row cheap in the first
place. What sharing would reclaim is 64 B off an 80 B row, and it would reclaim
it from rows that do not exist.

#### The charge-model question dies with it, and it was not free

The README flagged an unanswered mechanic: the budget charges per-row
`Array.capacity`, so shared storage needs a deliberate charge-model answer --
charging every sharer for the shared bytes overstates the footprint and
under-fills the budget, while charging once complicates eviction accounting
(the last sharer standing owes the whole block, and eviction order decides who
that is). That question is now moot, and it is worth recording that it was
never *cheap*: `H2` would have bought at most tens of KB while making the one
number this doc's whole budget rests on -- what a retained row costs -- depend
on how many other rows happen to be blank. That is a poor trade at any corpus.

#### The reopening condition, stated so nobody re-derives it

`H2` reopens on **one** piece of evidence, and it is specifically not "someone
found some blank rows":

> A recorded stimulus -- committed content, replayed through
> `just terminal-retained-row-probe`, not a generated stream -- whose **retained
> history is more than ~50% blank rows by count**.

That threshold is chosen from the arithmetic rather than from taste: below it
the ceiling stays under ~350 KB, which does not justify perturbing the charge
model; at and above it the prize passes a hundred KB and climbs steeply, so the
charge-model question becomes worth answering. The byte share cannot get there
by any other route -- `F9`'s curve shows blank rows must be an overwhelming
*count* share before they are a meaningful *byte* share, precisely because
trimming made each one cost 80 B. So a corpus with "more blank rows than we
thought" is not a reopening; a corpus that is **majority** blank at depth is.

The instrument for that test is committed and reports the number directly
(`blankRowFraction`, per stimulus and pooled), so re-testing this is one command
rather than a re-derivation.

- Behavioral verification: no engine or app behavior changes; this entry
  rejects a hypothesis and writes no code.
- Quantitative verification: `F9`'s two pools (0 of 133 recorded, 0 of 4,707
  overall), its negative control (467 of 935 on an alternating stream), its
  measured extreme (131,072 blank rows at 80 B each; 8.00 MB reclaimable), and
  the ceiling curve derived from the 80 B / 1,808 B charges. All reproducible
  from `just terminal-retained-row-probe` at `e1af871` or later.

### D5 -- the H3 packing representation: a per-row fixed-stride scalar slot with run-length styles, with H4 composed in

- Status: **decided as a design selection.** It picks the representation `H3`'s
  experiment will build, prices it against real rows before any engine code
  exists, and names what must be watched and what would falsify it early. It is
  **not** the plan: the experiment implementation is the next hand-off, and it is
  read against `D3`'s success criterion exactly as `D3` wrote it. No engine code
  was written for this entry.
- Date and investigator: 2026-08-03, Claude (agent).
- Evidence used: `F11` (composition at depth and the priced candidates -- the
  whole basis of this entry), `F8` (the 89.5 / 10.5 split), `F10` (the ~12.5%
  bucket step and the ~37 B/row in history's buffer), `F9` (the 1,808 B content row
  and 80 B blank row that anchor every charge here), `D3` (the selection of `H3`,
  the admission test, and the success criterion), `D2` (the frozen browsing rule),
  `D1` pitch 2 / `F7` (the resize probe and its upgrade gate), `F1` (the feed
  path's resolution wall), `D4` (`H2` closed, so no blank-sharing composes in).

#### The candidates, and what each is worth

All six were priced by `just terminal-retained-row-probe "--saturated"` against
every retained row in the corpus, through the engine's own charge model and
libmalloc's own size classes. `D3`'s admission test -- more than one ~12.5% bucket
step of shrink, or the saving can round to zero -- is cleared by all six at **100%
of rows**, so it does not discriminate here; it would have, and that is why it was
run first.

Saturated pool, current cost 1,076.9 B/row (9,736 rows at 10 MiB):

| candidate | shape | B/row | saving | depth | column read |
| --- | --- | ---: | ---: | ---: | --- |
| C1 | 8 B cell: 4 B scalar, 1 B kind, 2 B style id | 304.6 | 71.7% | 3.54x | O(1) |
| C2 | C1 + a 4 B cell for all-ASCII rows | 225.0 | 79.1% | 4.79x | O(1) |
| C3 | UTF-8 text + 1 B/cell descriptor + style runs | 123.3 | 88.6% | 8.74x | O(row) scan |
| C4 | C3 + single-style shortcut | 122.2 | 88.6% | 8.81x | O(row) scan |
| C5 | fixed stride + style runs + 1 B kind/cell | 143.9 | 86.6% | 7.48x | O(1) |
| **C6** | **fixed stride + style runs + exception list** | **114.5** | **89.4%** | **9.41x** | **O(1)** |

#### The selection: C6

**A retained row stores a per-row fixed-stride scalar column, a run-length style
table, and a short exception list.** Concretely:

- **Scalar column.** One slot per stored cell, at a stride chosen **per row** from
  the widest single-scalar value that row holds: 1 byte below U+0100, 2 bytes below
  U+10000, 4 bytes otherwise. Slot value zero encodes a never-written cell, which
  is free -- NUL is not content -- and is what makes interior padding cost one byte
  rather than a descriptor.
- **Style table.** `(runLength, styleId)` pairs over the stored prefix, 6 bytes
  each. The style ids remain the engine's existing interned ids; nothing about
  style interning changes.
- **Exception list.** 3 bytes per exception (2 B column + 1 B kind) for the two
  things a slot cannot hold: wide-cell geometry (`wideHead`/`wideTail`/`spacerHead`)
  and multi-scalar cells, whose scalars stay in the spill allocation the budget
  already charges. Hyperlink cells join this list; `F11` measured 0.37% of stored
  cells carrying OSC 8, which is small but not zero and must be represented rather
  than assumed away.

Why C6 and not the two obvious alternatives:

- **Not C3/C4 (UTF-8 text), though they look competitive on paper.** At 0.903 UTF-8
  bytes per stored cell, "one byte per scalar" and "UTF-8" are the same number for
  nearly every row, so the text form buys nothing in bytes -- and on the saturated
  pool it is *dearer* (123.3 against 114.5), because it pays a descriptor byte on
  every cell to make a variable-width payload navigable while C6 pays only on the
  0.86% of cells that are exceptions. What it costs on top is the thing that
  matters: **a column read becomes a scan from the start of the row.**
  `retained-browse` is the guard `D3` named as most likely to fire, and C3 is the
  design that fires it. Paying more bytes for a worse browse profile is not a trade
  worth running an experiment on.
- **Not C1/C2 (a narrower cell), though they are the smallest change.** They leave
  a style id on every cell, which the content says is waste: 1.66 style runs per
  row means the per-cell style field is redundant almost everywhere. C1 yields
  3.54x depth against C6's 9.41x for a design simpler by roughly one table.

**`H4` composes in, and `D3`'s gate for it is now met.** Packing shrinks the
payload ~16x while the 16 B row slot, the 32 B array header and size-class rounding
do not move: `F8`'s 89.5 / 10.5 split inverts to roughly **50 / 50** after C6.
Aggregate storage for the packed payload is therefore worth a further **36%**
(114.5 -> 73.2 B/row at depth; 112.0 -> 73.0 on `F8`'s payload). `D3` kept `H4`
alive only as a composition inside this design, and this is the number that earns
it the place. **Sequencing is explicit: C6 lands first and is measured alone; the
arena is a second, separately measured step.** Landing both at once would make an
`inconclusive` browsing result unattributable, and `D2` says to expect
`inconclusive` on that workload.

#### The priced expected yield, in `F8`'s split terms

`F8`'s payload at saturation, both widths (identical at both -- content-sized rows
already made depth width-independent, and `F11` re-measured that rather than
assuming it):

| quantity | now | C6 | C6 + `H4` |
| --- | ---: | ---: | ---: |
| charge per retained row | 1,808.0 B | **112.0 B** | 73.0 B |
| retained rows at 10 MiB | 5,799 | **93,622** | 143,640 |
| depth multiple | 1.00x | **16.14x** | 24.8x |
| stored payload share | 89.5% | ~51% | ~78% |
| fixed per-row share | 10.5% | ~49% | ~22% |

At depth across the saturated pool -- the honest mixed-content number, and the one
to quote if only one is quoted: **1,076.9 -> 114.5 B/row, 89.4%, 9.41x depth.**
Per-stimulus the saving ranges from **65.7%** (`alacritty/history`, 4.7-cell rows
where the fixed per-row cost dominates whatever the payload does) to **93.8%**
(`F8`'s plain payload). No stimulus prices C6 below C1.

These are the *predicted* numbers. `D3` criterion 1 requires them re-measured with
`just terminal-memory-probe` at both geometries on the real implementation, and
criterion 2 requires the depth effect stated and decided rather than discovered.
Note what criterion 2 means here: this is not a trade. It is strictly more depth
for strictly fewer bytes per row, so the `D` entry it needs is a statement of the
new depth, not an adjudication of a giveback.

#### The risks the experiment must watch

1. **The browse rule is the one that decides this.** `retained-browse` under `D2`'s
   frozen rule (`quick` 2 pairs +/-1.05% band 1.0%; `confirm` 4 pairs +/-1.05% band
   0.75%) must not answer `slower`. C6 is chosen partly *because* it keeps a column
   read O(1), but O(1) is not free: a read now reconstructs a `TerminalCell` from
   three places (slot, style run, exception list) instead of loading a struct. The
   style-run lookup is the sharp edge -- a linear scan of 1.66 mean runs is nothing,
   but a pathological row with many runs must not turn a row read into a quadratic
   walk. `inconclusive` is an acceptable pass and is *expected*; reaching for a
   rerun on seeing it is the shopping `F1`'s protocol forbids.
2. **The admission guard, with `F1`'s wall in front of it.** `terminal-feed` must
   not answer `slower` (`quick` 2 pairs +/-4.5%; `confirm` 2 pairs +/-2.5%).
   Packing happens where trimming already happens -- at admission -- so this is a
   real cost, not a neutral one. If the design's predicted feed effect is under
   ~2% and graduation turns on it, `D1` pitch 3's reopening condition fires
   *first*: screen `terminal-feed` for a longer schedule **before** the deciding
   run, not after an ambiguous one.
3. **The four standing ladder guards.** `scrollback-stream` (4 pairs, +/-1.85%),
   `content-churn` (4, +/-2.15%), `style-churn` (4, +/-2.0%), `incremental-mixed`
   (6, +/-1.85%); none may answer `slower`. `style-churn`'s ~3% residual from
   `F3`/`F4` needs no exemption -- it lives in `dd51a12..e4556c0` and sits in both
   arms of an adjacent-baseline comparison.
4. **Resize is now two-armed, and the upgrade gate fires.** C6 changes what reflow
   unpacks and repacks on every retained row, which is exactly the "change expected
   to move resize cost" `D1` pitch 2 named. If a resize claim is made, screening
   `saturated-resize` toward a frozen rule is a prerequisite task; if not,
   `just terminal-resize-probe` runs descriptively on both arms and is reported as
   a distribution, as `F7` did. `F7`'s ~98 ms median over 6,756 rows is the current
   arm, and depth is about to increase ~9x at the same budget -- **a per-row-cheaper
   reflow over 9x more rows can easily be slower in total**, and that is the single
   most likely way this design produces a user-visible regression.
5. **The shipped invariants are the boundary.** Canonical trimmed form (stored
   cells a pure function of observable content), budget-charge coherence, and the
   observability contract (every column below `columnCount` reads as before) all
   hold. The landed behavioral suite is the gate, and the retained-row probe's
   `derivationMatchesCensus` is a second check that trips loudly if the derived
   shape stops describing the representation.
6. **Every deciding run carries its preflight annotation**, read before the verdict
   is trusted (`D1` pitch 4; `F2` is the standing incident). Baseline is the
   adjacent commit, AC power, every number at or after `dd51a12`.

#### What would falsify this choice early, before the experiment is finished

Cheap checks, in the order they should be run:

- **A prototype row read that is not O(1) in practice.** If reconstructing a
  `TerminalCell` from slot + run + exception measurably costs more than a struct
  load in a microbenchmark of the row reader, C6's whole advantage over C3
  evaporates and the choice should be re-opened toward C1/C2 -- which keep a real
  cell and give up 3.54x instead of 9.41x.
- **A corpus whose rows carry many style runs.** The selection rests on 1.66 runs
  per row. If a real recorded stimulus at depth shows a mean above roughly 8 runs
  per row, the style table stops being nearly free and C1's per-cell style id
  becomes competitive again. `just terminal-retained-row-probe "--saturated"`
  reports `meanStyleRunsPerRow` directly, so this is one command.
- **A corpus whose rows are mostly non-ASCII.** C6 promotes a whole row to a 2- or
  4-byte slot for one wide scalar. `unicode-wrapping` already shows the failure
  mode (544.0 B/row against C3's 343.4). If recorded content at depth showed most
  rows above U+00FF, C3's variable width would win on bytes and the browse
  trade-off would have to be re-argued rather than assumed.
- **A feed-path cost that shows up in a prototype at over ~2%.** Then `F1`'s wall
  is load-bearing and the longer `terminal-feed` schedule must be screened before
  any deciding run -- discovering that after an ambiguous verdict is the failure
  `D1` pitch 3 wrote its reopening condition to prevent.
- **Reflow at 9x depth.** Run `just terminal-resize-probe` against a prototype
  early rather than at the end; it is the risk with the largest user-visible blast
  radius and the one this evidence says least about.

#### What this does not decide

The plan's shape: whether the packed row is a value type in `TerminalCore` or a
buffer with accessors, how reflow inflates and repacks, and where the seam sits
relative to `GridRow`. Doc 16's closure stands -- the **live grid's `GridCell` is
untouched**, and this representation is retained-only. `H5` (a compressed ancient
tier) remains gated on `D6`: it is strictly more mechanism than `H3` for the same
bytes, and after a 9.41x depth improvement it is very likely dead on sizing, but
that is a decision to make on post-landing evidence rather than here.

- Behavioral verification: nothing here changes engine or app behavior. The
  probe extension this entry rests on is benchmark-only code in the gate; `just
  test` passes (70 steps), including the new composition and charge-model tests
  that pin `row_charge` against `F9`'s measured 80 B and 1,808 B charges.
- Quantitative verification: every number above is reproducible from
  `just terminal-retained-row-probe "--saturated"` at this commit, per stimulus and
  pooled. The verification plan for the work this entry authorizes is `D3`'s
  success criterion, unchanged, plus the falsification checks listed above.

### D6 -- every retained-row field is preserved, `contentIdentity` run-encoded; C6 stands as the selection on corrected pricing

- Status: **decided, and it closes `PR1`.** It records what a packed retained row
  must preserve, how each field is charged, and which representation the corrected
  table selects. It **supersedes `D5`'s pricing**, not `D5`'s selection: the
  representation is unchanged and the yield figures are restated. Phase 1 of
  [`plans/wip/packed-retained-rows.md`](../../../plans/wip/packed-retained-rows.md)
  may begin. No engine packing code exists; the only engine change is a read-only
  measurement accessor.
- Date and investigator: 2026-08-03, Claude (agent).
- Evidence used: `F12` (the contiguity measurement and the corrected table -- the
  whole basis of this entry), `F11` (composition at depth), `F8`/`F9`/`F10` (the
  charge model, the 1,808 B content row, the bucket step), `D3` (the admission test
  and the success criterion), `D5` (the representation this entry re-prices).

#### What a retained row must preserve, field by field

`D5` selected a representation without an inventory, which is how a field with a
real reader came to be charged nowhere. The inventory is the entry's first output.

| field | width | adjudication | charged as |
| --- | --- | --- | --- |
| `GridCell.scalars` | 1-4 B, or spill | preserved | per-row fixed-stride scalar column; multi-scalar cells spill, as today |
| `GridCell.kind` | tag | preserved | free for padding (a zero slot *is* "never written"); wide geometry takes an exception entry |
| `GridCell.styleId` | 4 B | preserved | run-length style table, 6 B/run |
| `GridCell.hyperlinkId` | 2 B | preserved | 4 B side-table entry per hyperlink cell (2 B column + 2 B id) |
| `GridCell.contentIdentity` | 4 B | **preserved, run-encoded** | 8 B per contiguous run (4 B base + 2 B start column + 2 B extent), capped at 4 B/cell |
| `GridRow.isSoftWrapped` | 1 bit | preserved, unchanged | already inside the `GridRow` slot every candidate pays |
| `GridRow.semanticPrompt` | tag | preserved, unchanged | as above |

**Nothing is dropped.** The one field where a drop was arguable is
`contentIdentity`, and it is closed rather than open: `activationIdentity` reads
zero as "this run has no identity", so dropping it would silently stop adjudicating
links that live in scrollback. No reader tolerates that, which makes it an `I3`
violation rather than a trade; `linkArmTracksRunIdentity` pins the adjacent case.

The last two rows are an accounting decision worth stating: they are identical
across all six candidates and inside a cost every candidate already pays, so they
cancel in the comparison. Charging them would move every row of the table by the
same amount and change nothing.

#### The selection: C6, unchanged, on numbers that changed

C6 is cheapest on the saturated pool (121.5 B/row against C3's 137.4) and on `F8`'s
CRLF reference payload (128.0 against 176.0), **under both identity variants**. The
selection therefore never depended on how the `contentIdentity` adjudication came
out -- only the headline did. That is a stronger result than `D5` had: `D5` picked
C6 on an 8.8 B/row margin computed without the metadata; the corrected margin is
15.9 B/row on the same pool and 48.0 B/row on the reference payload.

`D5`'s reasoning for C6 over C3 is untouched by this entry and remains the reason:
at 0.903 UTF-8 bytes per stored cell the text form buys nothing in bytes, so the
tiebreak is that C6's column read is a multiplication and C3's is a scan.

#### What this supersedes

- **`D5`'s 114.5 B/row and 9.41x depth are withdrawn.** The corrected figures are
  **121.5 B/row and 8.86x** on the saturated pool, and **128.0 B/row and 14.12x**
  (81,920 rows at 10 MiB) on the CRLF reference payload that the plan headlines --
  down from 112.0 B/row and 16.14x.
- **`D5`'s claim that a retained cell's `contentIdentity` has no reader is
  withdrawn**, along with the C1 docstring it came from. It has a reader:
  `activationIdentity`, over a `ProjectionRows` range that spans retained rows.
- `D5`'s `H4` composition still holds and is re-priced with it: C6 + `H4` is
  **81.0 B/row, 129,453 rows** on the reference payload.

#### What is not decided here

The resize question. Depth still rises by roughly an order of magnitude at the same
budget, so reflow still processes far more retained rows than `F7` measured, and
gate item 6 of the plan -- convert `F7`'s probe to a two-armed comparison and
*decide* it -- is untouched by this entry. If anything the corrected depth makes it
marginally less severe (14.1x rather than 16.1x), which is not a reason to soften
the gate.

- Reopening condition: a measured single-run fraction materially below `F12`'s
  85.14% on content that reaches depth -- which would push C6 toward the per-cell
  floor (238.4 B/row saturated, 336.0 B/row reference) and make the `H4`
  composition, not the packing, the larger remaining win. C6 would still be the
  selection; the plan's expected yield would not survive.

### D7 -- the resize-for-depth trade, stated as numbers: `H3` does not graduate on this evidence, and the choice among three exits is a human design decision

- Status: **decided as far as measurement can decide it, and deliberately no
  further.** Gate item 6 of
  [`plans/wip/packed-retained-rows.md`](../../../plans/wip/packed-retained-rows.md)
  is **not cleared**. This entry states the trade as numbers, which is the second
  of the two exits that gate allows; it does not pick which way to take the trade,
  because every option changes the shape the remaining gate runs would measure.
- Date and investigator: 2026-08-03, Claude (agent).
- Evidence used: `F14` (the two-armed saturating resize comparison -- the whole
  basis of this entry), `F13` (which of the probe's numbers may be quoted at
  HEAD), `F7` (the one-armed baseline this replaces and reproduces), `D6` (the
  depth the packing buys), `D3` (the success criterion), `D1` pitch 2 (the gate
  that made the probe two-armed at all).

#### The trade, in one table

At the production 10 MiB budget, 179x66, ASCII CRLF content:

| quantity | `678bfe9` | `efa549f` | ratio |
| --- | ---: | ---: | ---: |
| retained rows at saturation | 6,756 | 81,920 | **12.13x deeper** |
| charge per retained row (CRLF reference payload) | 1,808.0 B | 128.0 B | 14.12x cheaper |
| saturated resize, median | 100.2 ms | 1,425.8 ms | **14.2x slower** |
| saturated resize, per retained row | 14.84 us | 17.40 us | 1.17x slower |

The two headline numbers are the same fact. Depth rose 12.13x because the bytes
per row fell, and the resize cost rose 14.2x because reflow visits every retained
row -- multiplied by a per-row reflow that packing made 1.17x dearer rather than
cheaper. `H1` left that per-row direction genuinely open; it is now measured, and
it is the smaller of the two terms.

#### Why this is a decision entry and not a `slower` verdict

`retained-browse`, `terminal-feed` and the four ladder guards have frozen rules;
`saturated-resize` has none, by `D1` pitch 2's deliberate refusal. Gate item 6
anticipated exactly this and offered two exits -- screen the workload toward a
frozen rule and clear it, or **state the measured resize-for-depth trade as
numbers and decide it in a `D` entry**. A 14x difference is not a threshold
question, so screening would be ceremony: no rule this doc could freeze would call
1,425.8 ms against 100.2 ms anything but a regression.

The plan's graduation rule is `faster` on a workload containing the moved cost,
nothing else `slower`, **or every trade stated as numbers and decided**. The trade
is stated. It is not decided here, and the reason is scope rather than caution:
each of the three exits below changes what the remaining gate runs would be
measuring, so running them now would spend a deciding-run budget on a shape that
may not ship.

#### The three exits, and what each costs, so the decision is made on evidence

None of these is chosen here. Each is stated with the number that governs it.

1. **Cap retained depth.** A row cap restores resize cost in direct proportion and
   gives back exactly that much of the win: a cap at ~2x the old depth returns
   resize to ~230 ms and keeps 2x deeper history at a 14x cheaper per-row charge,
   which the byte budget then never reaches. This makes the budget nominally
   byte-denominated and actually row-denominated, which is a coherence question
   doc 15's `D4` would want answered rather than a free knob.
2. **Make reflow cheaper.** The 1.17x per-row term is the only part of the 14.2x
   that is a cost rather than a consequence, and it is unprofiled -- Phase 2's open
   resize task (`RESEARCH`, destination `F15`) is the read that would say whether
   unpack/repack, allocation traffic, or something else holds it. Even eliminating
   the term entirely leaves **12.13x**, so this is a necessary-but-insufficient
   route on its own; it becomes decisive only combined with (1) or with reflow that
   does not visit every row.
3. **Accept the trade.** Defensible only against a use question this doc cannot
   answer from its own evidence: how often a user resizes a *saturated* pane, and
   whether the shipped resize coalescing makes 1.43 s a one-time cost at the end of
   a drag rather than a per-step one. Coalescing bounds how many resizes survive a
   drag; it does not shorten one. The honest form of this exit is a stated
   user-visible cost, not an assumption that nobody hits it.

#### What this blocks, and what it does not

- **`H3` does not graduate** on this evidence. The packing is landed, measured, and
  correct -- `PO1`-`PO5` are green and `D6`'s 128.0 B/row headline was reproduced
  to the byte -- but the gate it must clear is not cleared.
- **The remaining deciding runs are not run**: the longer `terminal-feed` screen,
  the `terminal-feed`/`retained-browse` deciding runs, the four ladder guards, and
  the two-width memory read. Not skipped on judgement -- the plan instructs
  stopping here, and exits (1) and (2) would both change the depth those runs
  measure against.
- **`H4` stays sequenced behind this** (`RI3` unchanged). It composes with whatever
  shape C6 settles into and would make an already-unattributable browsing result
  worse.
- **Nothing here reopens the representation.** `D6`'s selection is untouched: C6 is
  still the cheapest candidate under both identity variants, and the text form
  would reflow no faster. This is a depth consequence, not a packing-shape one --
  every candidate that bought this much depth would buy this much resize with it.

- Reopening condition: a resize path that does not visit every retained row (lazy
  or incremental reflow), or a measured per-drag cost showing coalescing reduces
  the user-visible figure to one 1.43 s event per drag rather than a stall per
  step. Either changes the arithmetic above rather than the judgement about it.

### D8 -- bound retained history by cells and rows, not bytes alone: `D7`'s trade resolves for two content regimes and is paid by the third

- Status: **decided and implemented** at `43b9c83`. This takes `D7`'s exit 1
  (cap retained depth) and, on `F15`'s evidence, changes what is capped. It
  clears gate item 6 of
  [`plans/wip/packed-retained-rows.md`](../../../plans/wip/packed-retained-rows.md)
  by the second of its two exits -- the trade stated as numbers and decided
  before landing.
- Date and investigator: 2026-08-03, Claude (agent), on a human decision to take
  the cap exit and open hybrid lazy reflow as the follow-on that later raises it.
- Evidence used: `F15` (the whole basis -- the cost model, the three-regime
  comparison, the pre-packing depth ceiling, and the row-cap failure), `F14` (the
  regression this answers), `F13` (which probe numbers may be quoted at HEAD),
  `F9` (near-empty rows, which is why a cell cap alone is not enough), `D7` (the
  trade), `D6` (the depth packing buys).

#### What changed, and the one sentence that explains it

The byte budget stopped bounding resize cost, and the caps put that bound back.

Before packing, a `GridCell` cost 32 B, so 10 MiB could hold at most
`10 MiB / 32 B` = **327,680 stored cells** no matter how the rows were shaped.
Reflow cost is `1.59 us x rows + 0.292 us x cells` (`F15`), overwhelmingly the
cell term -- so the byte budget was bounding reflow *implicitly*, and the three
measured content regimes came in at 304K, 298K and 246K cells, which is why a
pre-packing saturated resize was 87-152 ms whatever the content was. A packed
stored cell costs ~1 B. The coupling is gone, 10 MiB now admits ~10 M cells, and
that is the whole of `F14`'s 1,450 ms.

#### The two bounds, and why each exists

- **Cell cap, 327,680.** The old implicit ceiling restated explicitly at the value
  it always had. It bounds the dominant term, and being denominated in *content*
  makes it safe under reflow: rewrapping moves stored cells between rows without
  creating any.
- **Row cap, 16,384.** The backstop for what a cell cap cannot see. `F9`'s
  near-empty rows store ~zero cells, so a history of blank lines satisfies any
  cell cap while leaving the per-row term unbounded. Sized from the model rather
  than chosen, at the ~150 ms budget with **both** bounds binding at once:

      1.85 us x R + 0.352 us x 327,680 <= 150,000 us
      1.85 us x R <= 34,558 us
      R <= 18,680   ->   16,384 (2^14)

  which prices that simultaneous case at **145.8 ms**, 1.46x the 99.5 ms
  pre-packing baseline. It also sits at or above what every mainstream terminal
  defaults to: `xterm/XTerm.ad` `*saveLines: 1024`, `foot/foot.ini`
  `[scrollback] lines=1000`, `kitty/kitty/options/definition.py#scrollback_lines`
  2,000, `tmux/options-table.c#options_table` `history-limit` 2,000,
  `alacritty/alacritty_terminal/src/term/mod.rs#Config` `scrolling_history: 10000`.

#### A row cap alone was tried, and is rejected on two measurements

Recorded because it is the obvious design and it looks sufficient.

1. **It bounds the wrong term.** At 8,192 rows, wide content reflows in 232.6 ms
   against an 87.4 ms baseline -- **2.66x**, missing the target -- because 8,192
   rows of 179 columns is 1.47 M cells in ~2.15 MB, satisfying the row cap with
   the byte budget untouched.
2. **It destroys history.** Narrowing multiplies row count while leaving content
   alone, so the cap evicts and widening cannot restore:
   `8,192 -> narrow to 100 -> 8,192 -> widen to 179 -> **4,095**`. Half a user's
   scrollback gone from one window drag. `narrowThenWidenPreservesCappedHistory`
   pins the round trip and the mechanism.

#### The trade, stated as numbers

| regime | `678bfe9` | packed uncapped | dual-bound | resize vs old | depth vs old |
| --- | ---: | ---: | ---: | ---: | ---: |
| dense (~45 cells/row) | 99.5 ms / 6,756 | 1,450.2 ms / 81,920 | **117.6 ms / 7,123** | 1.18x | **1.05x deeper** |
| sparse (~4.9 cells/row) | 152.0 ms / 50,412 | 445.2 ms / 124,830 | **57.1 ms / 16,384** | 0.38x | **3.08x shallower** |
| wide (179 cells/row) | 87.4 ms / 1,665 | 1,846.5 ms / 29,757 | **104.1 ms / 1,798** | 1.19x | **1.08x deeper** |

**The decided giveback is sparse-content depth, 3.08x.** A shell history of short
commands retained 50,412 rows before packing and retains 16,384 now. It is a real
regression, not a bounded pathology -- `F15` Observation 2 checked the
alternative and closed it, measuring the pre-packing sparse resize at 152 ms
rather than the ~835 ms an extrapolation had predicted. Those 50,412 rows were
depth users had at a price they were paying, and 16,384 is above every mainstream
terminal's default while resizing in 57.1 ms, a third of what it used to cost.
Hybrid lazy reflow (`H7`) is the mechanism that raises it.

**What is not a trade:** dense and wide content get slightly *more* depth and
near-baseline resize together, because their bound was always the cell ceiling
and this restores it.

#### Two consequences recorded rather than left implicit

- **The 10 MiB byte budget is now unreachable for ordinary content.** The two caps
  together admit at most roughly `16,384 x 84 B + 327,680 B` -- under 2 MB. The
  budget has become the valve for byte-*expensive* rows, where a stored cell
  carries a multi-scalar spill the cell cap cannot see. That is the coherence
  question `D7` exit 1 raised, answered: the budget is no longer the depth bound,
  it is the memory backstop, and `publicProductionBoundsCrossing` was restated to
  stop claiming otherwise. It also means ordinary-content footprint lands near
  ~1-2 MB rather than 10 MiB, which is a further memory win beyond packing.
- **Below 20 columns the row cap can still bind on a narrowing and lose content**,
  because `cellCap / rowCap` = 20. Raising the row cap enough to make a 10-column
  pane lossless would cost the cell cap most of its budget. Taken deliberately.

- Reopening condition: a reflow path that does not visit every retained row
  (`H7`'s hybrid lazy reflow), which breaks the depth-is-latency coupling both
  caps work around and lets them rise; or a measured per-cell reflow cost
  materially below 0.352 us, which `F16`'s profile is the prerequisite for and
  which would let the same budget buy a larger cell cap.
