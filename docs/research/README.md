# docs/research/ -- living research files

## File index and status

Reviewed 2026-07-29. **Doc 1 is live; every other file is closed.**
Closed means the
questions it opened have answers and nothing in it is waiting on anyone -- not
that every idea in it was implemented. Several closed with parked backlogs; each
one records its own reopening condition, and those conditions are the right
entry point, not a re-read of the evidence.

| # | Topic | Status |
| --- | --- | --- |
| 1 | External terminal tests | **LIVE.** Survey complete; its Milestone 8/9/10 injection points are not yet consumed. Close when M9's evidence package is assembled. |
| 2 | Wraptest coverage | Closed. Declined, on redundant coverage *and* unclear license. |
| 3 | Serialized redraw optimization | Closed. Per-run glyph batching shipped; medians -97%. |
| 4 | Fallback-glyph batching | Closed. Superseded by procedural sprites across eight families. |
| 6 | Sprite classification regression | Closed. Both regressions from the sprite series found and fixed. |
| 7 | Fast paired A/B benchmarks | Closed. Runner shipped and decided every verdict in docs 8-13. Ghostty baseline never built. |
| 8 | Benchmark variance regression | Closed. Cause is a CPU frequency governor; `D2` routes around it and graduated to a design note. |
| 9 | Plan/render allocation hotspots | Closed. Three changes shipped; Phase 5 parked with a measured ceiling. |
| 10 | `Terminal.feed` hotspots | Closed. -24.31% on `terminal-feed`; remaining items are optional backlog. |
| 11 | Render frame budget | Closed. The draw path fits the 60Hz budget; no change proposed or warranted. |
| 12 | Cell representation | Closed. Erase leg shipped; POD cell demonstrated-and-rejected; memory half parked. Its reopening condition was met on 2026-07-29 and taken up by doc 15. |
| 13 | Live-app compositing | Closed. Three candidates landed; compositing stall is substantially pipeline slack. |
| 14 | Live scroll workload profile | Closed. One trace, four candidates, two shipped: `TerminalScalars` accessor inlining (**-20% draw**, `14/D2`) and a row-scoped cell read (**-16% plan**, `14/D3`). One candidate rejected as too small to measure (`14/D1`). |
| 15 | Memory footprint | Closed. Took up doc 12's reopening condition and owned resident bytes per cell, per row, and in aggregate. End to end (`15/F17`): at 179x66 a pane holds **the same ~1,768 rows of history for 57-59% less memory** (~26 -> ~11 MB), closing the **2.6x** gap between the configured 10 MB budget and what it actually cost; at 80x66 it is 3-12% less depth for ~50% less memory. Three legs got there. **A retention bug** (`15/F4`+`15/D1`): evicted rows kept their cells, so history held up to 2x the rows it admitted. **An accounting fix** (`15/D2`+`15/F9`, `15/D4`+`15/F13`): the budget charged 40 bytes for a 72-byte cell and charged what cells *occupy* rather than what a row *reserves*; it now reads `Array.capacity` and lands within ~1% of the configured value. **The cell, 72 -> 32 bytes** across `15/F10` (link id: the cost was its `Int?` alignment, not its width), `15/F14` (content identity), and `15/F15` (style moved behind a 32-bit id into a swept table). All three were CPU-*positive*: `scrollback-stream` 18-19% faster, `terminal-feed` 18-19% faster across two independent runs, plan time -6..-9%. `15/D2` closed by the user: the budget stays denominated in bytes, because a line limit bounds only a proxy -- 2,000 lines is 4 MB at 80 columns and 11 MB at 179. Two of Phase 1's four answers were corrections to its own instruments (`15/F6`, `15/F7`). Durable lessons graduated to `agent-docs/terminal-performance.md`: the malloc bucket rather than the stride decides whether a cell shrink reaches the user (`15/F12` cost 1.8 MB at 179 columns while winning 26% at 80), Swift's declaration-order layout is worth as much as a field (`15/F15`), and a field written per cell but *changed* per mode switch belongs behind an id cached on the SGR pen (`15/F11`). Open residue, deliberately not taken: padding is now the largest line item in the cell at 10 of 32 bytes (`15/F16`), and `15/F6`'s ~1,300 unexplained app-side row arrays. |
| 16 | Cell padding | Closed. Continues `15/F16`. Found the 8 bytes doc 15 missed -- `hyperlinkId` and `contentIdentity` are 3 and 5 bytes only because they are `Optional`, and each tag byte also pushes the next 4-byte field past an aligned offset, so the two tags cost **six** bytes of cell, not two. Reserving zero in both ids (which `contentIdentity` already did, per `15/F14`) and reordering reaches **stride 24 with no interior padding at all**, and unlike `15/F12` the allocator honors it at *both* widths: a row falls 6,112 -> 5,088 bytes at 179 columns and 3,040 -> 2,016 at 80, worth **+19% and +49% history** at an unchanged budget. **Implemented, measured, and rejected on CPU** (`16/F3`, `16/D1`): `incremental-mixed` is **slower in two independent confirm runs** (+1.95%, +3.39% against a 1.85% threshold) while `scrollback-stream` got faster in both -- the sign splits by access pattern, because **a cell's stride is also its cache-line alignment**. 32 divides 64 and 24 does not, so line-aligned two-per-line cells become straddling ones and a per-cell read that touched one line sometimes touches two. Intrinsic to the stride; not fixable by reordering or inlining (the accessor explanation was refuted by inspection -- `forEachViewportCell` reads only stored properties). The user rejected the trade: the workload that regressed is the interactive one and the ones that improved are throughput, and doc 15 had already taken the pane from ~810 honest rows to ~1,768. **This retires `15/F16`'s two open candidate directions too** -- stride 20 does not divide 64 either, and has no bucket win at 179 columns to weigh against it. 32 bytes is a resting point, not an accident. Reopen on a live scrollback-depth complaint, or on a trace attributing the regression to something other than the stride. |

| 17 | Whole-workload on-CPU profile sweep | Closed. Continues `14/F6`'s pivot by taking a Time Profiler trace on all four workloads that have an on-CPU mode. Phases 1-5 done; **every ranked candidate resolved -- B kept (`17/F13`, `17/D4`), C rejected on measurement (`17/F14`, `17/D5`), and the CPU metric screened and refused a rule (`17/F15`, `17/D6`).** Four results dominate. **The regions four documents optimized are no longer where the time is** (`17/F3`): `planFrame` and `drawRenderFrame` are 10.5% and 10.4% of the workload where each is largest, while the three biggest app-attributable quantities -- CA's per-glyph bounds 16.8%, `applyOutput`'s non-feed body up to 23.8%, `recordDamage` 15.8% -- were ranked first by nobody. **The largest cost in the app is in no benchmark bracket** (`17/F2`, `17/F6`): the draw verdict measures 10.43% of `content-churn` while CoreAnimation's replay of that same draw costs 23.15% on threads the draw timer never sees, 16.8% of it recomputing every glyph's ideal bounds per frame -- which **confirms `13/H3`** and meets `13/D2`'s reopening condition, though its elasticity is still unconfirmed. And **the strongest a-priori candidate was already fixed while both documents still advertise it** (`17/F5`): `9/H2`, whole-viewport planning, landed in `8188b9a` two days after doc 9 closed, so doc 9's Phase 5 note and `agent-docs/terminal-performance.md`'s "the planner plans the whole viewport regardless" are both stale. Also found: `DamageActionSnapshot` is non-POD solely because of one `String`-bearing field, at 8.27% of `scrollback-stream` (`17/F7`, reopening `10/H1(b)` at 3.4x the size that rejected it), and `TerminalPTYHost.applyOutput` maintains a 64 KB byte buffer per PTY chunk that only tests read (`17/F9`). **`17/D2` fixed the instrument first, and it is done** (`17/F10`-`17/F12`): every block now reports `processCPUNanosecondsPerDraw`, CPU summed over all threads via `task_info(TASK_ABSOLUTETIME_INFO)`, and every `sample`/`trace` capture now writes `frame-accounting.json` with a measured draw rate. **That immediately produced the file's sharpest result** (`17/F12`): the deciding draw metric brackets ~11% of the CPU the process burns per accepted draw on the churn workloads (540k ns of 4.9M) and **~4.3% on `incremental-mixed`** -- so an `equivalent` draw verdict constrains roughly one ninth of a frame's cost. The new metric carries no verdict (uncalibrated; block spread 5.60% against the draw metric's 0.41%, so ~6% is its noise floor). It also replaced `agent-docs`' stale plan/draw figures, which were 1.7x-17.5x too high with the ordering backwards, and revealed `planFrame` runs 1.028 times per draw (`17/F11`). `17/D3` re-reads the ranking against the fixed instrument: candidate A is now *partly* decidable, but the recommendation stays **B, then C, then A**, since A's elasticity is still unconfirmed -- with a new fourth option, an A/A screen to freeze a rule for the CPU metric. **Candidate B was then taken and kept** (`17/F13`, `17/D4`): `DamageActionSnapshot` is now POD (190 -> 166 bytes), `terminal-feed` **-14.59%** and `scrollback-stream` **-10.78%** (`faster`), the three other routine workloads unregressed. Its lasting lesson is procedural -- the guarding test, written first, **demonstrated that the implementation `17/F7` and `17/D1` had both pitched was wrong**: an identity token cannot notice a target change, because `activationIdentity` is `max(contentIdentity)` over the range's cells and never a function of the URI, so what shipped is a revision counter that compares no values. The benchmark would have said `faster` either way, hover bug included. B was decided by the frozen draw rule, so the new CPU metric is exactly as uncalibrated as before and the A/A screen is untouched; **Candidate C was then measured and rejected** (`17/F14`, `17/D5`): the ablation `17/F9` asked for deleted `recentOutput` outright and **nothing vanished** (`applyOutput`'s body 14.95% -> 15.24%, the three predicted frames all up slightly), and `scrollback-stream` flipped sign between 2 pairs (-2.65%) and 4 (+0.85%). The lone `faster` (`style-churn` -3.02%) is an arm-level artifact, shown by its plan time and process CPU moving the same -3.1% -- `recentOutput` has no causal path to plan time, so the uncalibrated metric earned its keep as a **consistency check** while carrying no verdict. **It also retired a sizing method**: `17/F9`'s "`applyOutput` minus `Terminal.feed`" is unsound because `Terminal.feed` is *partially inlined* -- `moveAndFillRows` appears as `applyOutput`'s direct child -- so subtracting a frame does not subtract that function's work. Inclusive shares of a named frame (`17/F6`, `17/F7`) are unaffected. **The A/A screen was then run, and refused the metric a rule** (`17/F15`, `17/D6`): 24 paired A/A blocks per workload against one immutable arm root, and no threshold clears the accuracy gates on any workload in either mode -- the false-positive gate and the detection gate **cross with no overlap**, the closest case (`content-churn`/`quick`) hitting a 0.0000 false-positive rate only at +/-3.0% where detection has already fallen to 0.8320 against a 0.90 gate. Paired A/A SD is 1.88% / 3.52% / 8.75% across the three workloads, and because an auxiliary metric rides the deciding metric's own blocks it **cannot buy more pairs**, which is the only knob that would close the gap. So `processCPUNanosecondsPerDraw` is now *screened-and-refused* rather than merely uncalibrated, and `17/D6` names its one legitimate use -- co-movement that **undermines** a suspect verdict, never confirmation. The screen paid for itself by retro-pricing `17/F14`'s artifact call, which had rested on mechanism alone: 5 of 24 pure-noise pairs on `style-churn` sit at or below -3.02%, and a +/-3.0% rule fires on 5.91% of A/A runs. The honest reading of `17/D2`: fixing the instrument bought a much better *description* of the gap (`17/F12`) and **no new verdict** -- candidate A is still undecidable by frozen rule on the region that makes it worth 16.8%, and now known to be. **`F6`'s elasticity was then tested and passed** (`17/F16`): two captures at 179x66 and 80x25 -- a 5.907x glyph-occurrence lever -- move the `get_glyph_bboxes` subtree 801.0 -> 142.5 us/draw, **5.62x, or 95.1% of linear**, with a 5% per-occurrence premium at the small geometry marking the per-op floor. The mechanism `17/F6` proposed is right, the bar `11/F12` used to *refute* two earlier mechanisms is cleared, and `content-churn` gains the replicate this file's first caveat asked for (16.37% vs 16.78%). **The surprise sat next to it: the draw rate did not move** -- 119.10/s and 119.32/s, pinned at a 120Hz panel's refresh at both geometries, so the app pays 801 us/draw of pool-thread glyph work at full size *and still makes every frame*. Candidate A's win is therefore **energy, not latency**, and combined with `17/F15` there is **no instrument in this project that can return a verdict on it**. So `17/D7` declines to start it: a change that large whose result cannot be measured is how a project acquires an unfalsifiable optimization. **That live capture was then taken, and it retired the headline number** (`17/F17`, `17/D8`): profiling a *damage-scoped* stimulus at the same geometry -- one damaged row against a dense screen -- puts the same node at **27.3 us/draw against 801.0, 29.3x smaller**, and implies ~390 glyph occurrences a frame for a 179-cell row, so the draw path is damage-scoped just as planning is (`17/F5`). `17/F3`'s **1.85% on `scrollback-stream`** had been saying the same thing from the start. So two realistic stimuli read 0.42% and 1.85% while the only one reading 16.8% republishes every glyph on screen 120 times a second: **`17/F6`'s headline is a property of the benchmark, not of DanTerm.** `17/D8` closes candidate A on three counts -- artifact magnitude, energy-not-frames, and no instrument able to decide it -- with a specific reopening condition (a capture of a real full-screen animated TUI showing the node above 1.85%). Doc 17's durable lesson is that pair: **an elasticity test confirms a mechanism and says nothing about whether the mechanism's input is realistic**, and the defence costs one capture under a different stimulus shape. E and F remain small and untaken; G stays rejected. T3 (an on-CPU mode for `terminal-feed`, which has none) was logged and not taken. |
| 20 | PTY throughput reporting and interactive stimulus | **LIVE.** Opened 2026-07-30 from "can we benchmark btop under a held key?". Phase 1 is done from artifacts already on disk and produced one result that reframes an existing instrument: **`scrollback-stream` has been a PTY throughput benchmark all along.** `producerWriteNanoseconds` is recorded in every block by `scripts/terminal-benchmark-validation.py:656`, referenced by no metric table, and is **95.7% of `finalDrawNanoseconds`** (median over 368 blocks, 55 runs, all 179x66) -- so the draw tail is only ~9.5 ms, and **a change touching only drawing can move that workload by at most ~4%** (`20/F2`). That refuted this file's own opening hypothesis (`20/H1`: that the deciding metric could hide drain work -- it cannot, they are the same number). The producer is not the bottleneck: it can push the corpus in **30.2 ms / 50.6 MB/s** against blocks of 145-372 ms, so the bracket measures DanTerm, with a ≤30 ms additive arm-symmetric offset (`20/F3`). The drain bracket is also **quieter than the metric that already carries a frozen rule** -- within-arm block CV 0.87% against 1.24% (`20/F4`) -- which raises but does not take `20/H3` (replace the deciding metric; parked, since it would recalibrate every threshold docs 8-18 rest on for a 96%-correlated quantity). `20/D1` selected the descriptive split (drain ms, MB/s, draw tail per arm) with no new rule, and **it is implemented and verified** (`20/F5`): the producer now records the bytes it wrote inside the timed bracket, validation carries them into every block, and all four reported quantities reproduce by hand against an archived series. A live run then proved it end to end (`20/F7`: `bytesWritten` 1,525,076 = corpus plus completion marker, 10.34 MB/s). **And the producer offset turned out not to exist**: `20/F6` rejected `20/H2`'s additive framing by pacing a consumer at the app's real rate, where rechunking the writes moves the block by **0.0 ms** against 20.4 ms unthrottled -- the writer is parked on a full PTY buffer either way, so `20/F3`'s 30.2 ms ceiling is an upper bound never approached and the reported MB/s needs no correction. `agent-docs/terminal-performance.md` documents the new lines and carries the corrected caveat. Phase 3 is untouched: `20/D2` (a keypress-driven workload) is open, and its subject choice is load-bearing, since btop redraws on its own timer and cannot attribute a keypress to a draw while `less`/vim can. Also surveyed: **no terminal project drives synthetic input in-process** -- Ghostty's benchmarks are seven headless micro-benchmarks plus one disabled Xcode-only suite, vtebench and kitty's kitten are both stdout-payload harnesses, and latency everywhere is measured externally (`20/F1`). vtebench's 12 payload generators are logged as an unclaimed corpus opportunity. |
| 22 | Application-exit job corruption | Closed inconclusive. Named the crashing task-group child and confirmed an image-relative bad resume pointer plus the exact exit arena (`22/F1`-`22/F13`), but the one budgeted debugger attempt could not identify the corrupting write because its breakpoints silently failed. Phase F removed the entire Swift Concurrency exit path in `6d97878` and `50c5240`; the optimized build now quits cleanly. Reopen only if the crash returns. |

(There is no doc 5; numbers are never reused or renumbered.)

**Two results worth knowing before you open any of these.** The draw path fits
the frame budget (`11/F7`, `11/F8`), so a new render optimization needs a
trigger, not just a profile share. And `8/D2` moved damage-*drawing*
comparisons off the GUI benchmark onto `just benchmark-headless-draw`; damage
*generation* stays on a degraded `benchmark-quick`. Read
[docs/design/2026-07-27-damage-render-benchmark-routing.md](../design/2026-07-27-damage-render-benchmark-routing.md)
before measuring anything. A third: **the plan/draw ratio is workload-shaped and
no published ratio generalizes** -- doc 13's four captures are btop, doc 14's is
a full-viewport scroll, and they disagree by 2x in both directions (`14/F1`).
And a fourth, which is about method: **re-size any `sample`-derived hotspot on an
on-CPU instrument before spending a paired benchmark on it.** `just
benchmark-trace` costs one build and one 30 s run; in `14/F6` it deflated a node
by 2.5x and killed the candidate built on it (`14/D1`). `sample` counts blocked
threads, so it inflates anything near allocation, ARC, or the kernel. The
corollary, from `14/F11`: **do not then discount the on-CPU share.** `9/F3`'s ~3x
optimism factor attaches to `sample`, and applying it to an on-CPU share of
deletable work under-predicted a 16% win as 5%. And a mechanical trap worth
knowing before you measure a plan-path change: **`benchmark-confirm` does not
classify plan time at all** -- the calibrated plan rule lives only in
`benchmark-quick`, on `content-churn` and `style-churn` (`14/F11`). The memory
equivalent, from `15/F6`: **`just benchmark-memory` is a leak detector, not a
measurement instrument.** Asked to confirm a ~22 MB saving it reported the fixed
build as *larger* -- one memgraph samples one arbitrary point on a sawtoothing
quantity, and GUI IOSurface churn ran 50 MB over the same window. Use it for
"is this growing without bound"; do not use it for "did this get smaller".
Its replacement can be wrong too, in the same shape: the headless probe that
succeeded it charged its own oversized `feed` call to resident state and reported
cell bytes as 35-50% of process cost when the true figure is ~85% (`15/F7`). The
general rule those two cost: **vary something that should not matter -- sawtooth
phase, feed chunk size, column count -- before believing any memory number.**
Related, and cheap to be burned by: a 2-pair `benchmark-quick` reading of
**+1.05%** on `scrollback-stream` flipped to **-0.86%** at 4 pairs (`15/F6`) --
an "inconclusive" verdict is not a weak regression signal, so escalate before
reporting one.

Two more, both from doc 17 and both about where to *look*. **The draw verdict does
not contain the draw's largest cost.** `drawNanosecondsPerDraw` brackets
`clipFramePlan` + `drawRenderFrame` inside `draw(_:)` -- 10.43% of
`content-churn`'s on-CPU time -- while CoreAnimation's replay of that same display
list costs 23.15% on the dispatch pool, after `draw` returns, inside no frozen
decision rule at all (`17/F2`, `17/F6`). **Now measured on the benchmark's own
denominator: the draw verdict brackets ~11% of the CPU the process burns per
accepted draw on the churn workloads and ~4.3% on `incremental-mixed`** (`17/F12`).
Every block now reports `processCPUNanosecondsPerDraw` beside the verdict -- read
it before concluding a change was free, and note it carries no verdict of its own
(uncalibrated; ~6% noise floor). And **date a performance number before you plan
against it**: `agent-docs/terminal-performance.md`'s claim that the planner plans
the whole viewport regardless of damage was made three days before the commit that
fixed it, and it kept a parked backlog item (`9/H2`) alive for two days after it
was already implemented (`17/F5`). Its figures were 1.7x-17.5x too high and it had
the plan-versus-draw ordering backwards on both workloads (`17/F12`); both that
file and doc 9's Phase 5 note are now corrected. A parked item inherits the
staleness of the document holding it.

One more, from doc 17's first accepted candidate. **A pitch's mechanism deserves the
same scepticism these files apply to a pitch's size.** `17/F7` and `17/D1` both
specified candidate B's implementation, and `17/F7` filed its one correctness risk as
"unverified"; the guarding test, written before the code, showed that implementation
drops hover damage outright (`17/F13`). The benchmark would have returned `faster`
with the bug included, because no benchmark measures hover damage. Write the
behavioral test for the *named risk* first, and verify it fails against the naive
implementation -- a green paired verdict is not evidence of correctness.

And one from the screen that closed doc 17's tooling arc. **"This metric is
uncalibrated" and "this metric is uncalibratable at the sample size we have" read as
the same sentence and license opposite next steps.** Only a screen tells them apart:
`17/F15` ran one and found the false-positive and detection gates cross with no
overlap, so the honest label changed from *pending* to *refused* and the plan that
depended on it (deciding candidate A by frozen rule) died rather than waiting.
A calibration that proposes nothing is a result -- and this one still paid off twice
over, by retro-pricing a judgement (`17/F14`) that had been made on mechanism alone.
Run the screen before building on the rule you expect it to produce.

And one from the same file's last measurement. **Confirming that a cost is real and
confirming that removing it would show up are two different experiments.** `17/F16`
put doc 17's headline finding through the elasticity test it had never faced and it
passed at 95% of linear -- and the same two traces showed the draw rate pinned at the
panel's refresh in both, so the app pays that cost *and still makes every frame*. The
win is energy, not latency, and no metric this project owns can decide it. Passing the
first experiment is what makes the second worth designing; it is not permission to
start the change (`17/D7`).

A research file is a scratchpad for a single investigation or strategy area.
It is not an ADR and not a plan: design decisions that are settled graduate to
`docs/design/`, and work that is ready to implement graduates to a plan file.
A research file is where ideas live while they are still being discovered,
vetted, refined, or rejected.

## Contract

- **Files are numbered** (`N-topic.md`, next unused integer) and never
  renumbered. A dead file is marked superseded at the top, not deleted, so its
  rejected ideas stay findable.
- **A new file may continue an older one.** Reopening a closed investigation, or
  zooming in on one revelation from another file, gets its own number and names
  its ancestor at the top. See "Continue an older file instead of reopening it"
  below.
- **The task ledger is the file's primary interface.** Keep it near the top,
  after the short framing sections needed to interpret the tasks: purpose,
  investigation rules, triggering evidence, and current hypotheses. It is
  ever-growing and ever-changing: tasks are added as ideas appear, re-scoped as
  understanding improves, and closed with an outcome. Many tasks are
  legitimately "do further research on X" -- that is a first-class task, not a
  placeholder.
- **Each task carries a status**: `TODO` (idea, not yet examined), `RESEARCH`
  (needs investigation before it can be judged), `VETTING` (has a concrete
  proposal awaiting evidence or review), `ACTIVE` (being worked),
  `DONE` (landed; link the commit/plan), or `REJECTED` (kept, with the reason
  inline -- rejection reasons are the most valuable content in the file).
  A checkbox ledger may use `[ ]` and `[x]` instead when the tasks form an
  ordered investigation; record the richer status and disposition in the
  corresponding finding or decision entry.
- **The file is live.** Update it whenever the investigation learns something:
  new profile evidence, a dead end, a better decomposition, a changed
  recommendation. The body converges over time toward a final strategy that
  directs the actual implementation; when that happens, the strategy is
  extracted into a plan or design doc and the research file records where it
  went.
- **Claims cite evidence.** Performance numbers name the benchmark, commit,
  and compatibility conditions per
  [agent-docs/terminal-performance.md](../../agent-docs/terminal-performance.md).
  Profiled timings are labeled as diagnostic, never as benchmark results.
- **Rejected ideas are never silently removed.** Move them to a "Rejected"
  section (or mark the task `REJECTED`) with one or two lines on why, so the
  same idea is not re-litigated six months later.
- **The file is the handoff.** An investigation usually outlives the agent
  working it, and no agent knows in advance whether it is the one that closes
  the file. The file -- not the conversation that produced it -- is all the
  next agent inherits, so anything an agent knows and does not write down is
  lost. Write as you go, not at closure; see "Write for the next agent" below.

## Required shape

Use this order unless the investigation has a concrete reason to omit or
rename a section:

```markdown
# Research topic

Research started: YYYY-MM-DD.
Continues: [N-topic.md](N-topic.md) (`N/F3`).   <!-- only when it has an ancestor -->

## Purpose

What this file owns, why the investigation exists, and what evidence or
decision boundary it must preserve.

## Investigation rules

- Investigation-specific constraints on evidence, comparison, testing, and
  when implementation may begin.

## Trigger and current evidence

The observed behavior that opened the investigation, its provenance and
caveats, and the smallest useful summary of measurements or examples.

## Current hypotheses

### H1 -- falsifiable explanation

Evidence that supports it, competing explanations, and what would confirm or
reject it. Hypotheses are not conclusions.

## Candidate direction, pending evidence

The currently promising shape and why, explicitly labeled as provisional.
Omit this section when evidence does not yet justify a candidate.

## Task ledger

### Phase 1 -- establish evidence

- [ ] A concrete action with a recorded result in Finding F1.
- [ ] A decision gate with explicit acceptance or rejection criteria.

### Phase 2 -- attribute the cause

- [ ] ...

## Findings log

### F1 -- stable descriptive name

- Status:
- Date and investigator:
- Commit and worktree state:
- Commands, inputs, or reproduction:
- Result or artifact paths:
- Measurements or examples:
- Observation:
- Inference:
- Competing interpretations:
- Uncertainty:
- Next action:

## Decision log

### D1 -- decision being made

- Status:
- Evidence used:
- Candidate solutions:
- Tradeoffs and correctness risks:
- Recommendation:
- Direction review:
- Selected direction:
- Behavioral verification:
- Quantitative verification, when applicable:
- Decision and rationale:

## Rejected

### Rejected idea

Why it was considered, the evidence against it, and what new evidence would
justify reopening it.

## Open questions and caveats

- Unresolved facts, provenance limits, and constraints that remain live.

## Outcome

Investigation in progress.
```

The template is a schema, not a demand for empty boilerplate. Omit fields that
do not apply, but do not collapse distinct observations, inferences, and
decisions into narrative prose.

## How to run the file

### Start from a bounded trigger

State the concrete observation that caused the research to exist. Record enough
provenance to reproduce or audit it: commit and worktree state, command or
input, environment when relevant, artifact paths, and known compatibility
limits. Separate trustworthy evidence from exploratory evidence, and preserve
why either is usable.

### Continue an older file instead of reopening it

Work that grows out of an existing file -- reopening a closed question, or
zooming in on one revelation from another investigation -- gets its own new
numbered file that names its ancestor. That keeps each file scoped to one
question while the backreference still points at prior work, so it is not
redone.

Cite the specific `N/F#` or `N/D#` you are building on, and restate only the
boundary you inherit, not the evidence behind it. Leave a pointer in the
ancestor so the lineage is findable from either end; pointing at a successor
does not reopen a closed file. Cross-file IDs are always qualified -- `F3` is
this file's, `9/F3` is doc 9's -- and a continuation numbers its own findings
from `F1`.

### Turn theories into falsifiable hypotheses

Give hypotheses stable IDs (`H1`, `H2`, ...). For each one, record:

- the proposed mechanism;
- the evidence already supporting it;
- plausible competing explanations;
- the smallest experiment or observation that would distinguish them; and
- the condition that confirms, partially confirms, or rejects the hypothesis.

Do not let a plausible mechanism silently become the selected fix. A controlled
experiment may validate a cause without being suitable production code.

### Organize work as an evidence funnel

Make ledger phases narrow uncertainty in order:

1. establish a trustworthy baseline or reproduction;
2. attribute the behavior to a cause;
3. compare candidate directions against the evidence;
4. pause at an explicit direction gate when the choice matters;
5. implement and verify only the selected direction; and
6. close with a clean final measurement or behavioral result.

Each task should name its durable destination (`F1`, `D1`, a plan, a design
doc, or a commit) when one exists. Include explicit sequencing constraints such
as "begin only after..." when later evidence would otherwise be confounded.
Ledger tasks should say what result to record, not merely what command to run.

### Keep an append-only evidence chain

Findings use stable IDs (`F1`, `F2`, ...). One finding may cover a tightly
related task cluster, but it must preserve:

- what was actually observed;
- what is inferred from that observation;
- alternative interpretations;
- confidence or uncertainty; and
- the next action the result unlocks.

Do not silently replace an earlier measurement or interpretation. Append the
new evidence, mark the old interpretation superseded, and explain why. Link
large artifacts instead of pasting them unless a compact excerpt or table is
necessary to reason about the result.

### Make decisions auditable

Decisions use stable IDs (`D1`, `D2`, ...), cite the findings they depend on,
and compare credible candidates. Record expected benefit, behavioral and
correctness risks, maintenance risks, and the evidence that would falsify the
recommendation. Keep recommendation, direction approval, implementation, and
verification as separate states.

Audit behavioral coverage before implementation. Tests must protect observable
behavior or an invariant, not a helper, branch, or chosen internal structure.
It is valid to conclude that existing tests are sufficient; record the audit
and its reasoning rather than adding a structure-coupled test.

### Close without erasing uncertainty

The Outcome summarizes what was learned, what shipped or graduated elsewhere,
what was rejected, and which uncertainties or follow-up tasks remain. Link the
plan, design doc, and commits that received the settled work. If the
investigation is abandoned or superseded, say so at the top and link its
successor; keep the evidence and rejected paths intact.

### Write for the next agent

Write as though the agent who continues this file starts cold: no chat history,
no memory of what you tried, only the file and the repo. That reader is often a
future you with a fresh context window.

- **Update mid-investigation, not only at closure.** Record a result when you
  have it, not once the phase is done. An investigation that ends abruptly
  should lose at most the step in progress.
- **An `ACTIVE` task carries its in-progress state.** Note what is running or
  half-done, what has already been tried within the task, and the next concrete
  step. `ACTIVE` with no notes underneath tells the next agent nothing except
  that someone started.
- **Record inconclusive attempts, not just rejections.** A command that did not
  reproduce the behavior, a profiler that would not attach, a benchmark whose
  variance swamped the effect -- these are not findings-grade results and not
  rejected ideas, but re-running them is the most common way a fresh agent
  wastes an hour. One line under the task is enough.
- **Prefer the file over the summary.** If you would put a fact in a hand-off
  message, it belongs in the file first.

## Reading order for agents

Before working in an area that has a research file: read its task list first,
then the findings, decisions, hypotheses, and caveats referenced by the active
task. Before proposing a new idea in that area, check the Rejected section and
the competing interpretations in relevant findings.
