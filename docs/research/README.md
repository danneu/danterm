# docs/research/ -- living research files

## File index and status

Reviewed 2026-07-30. **The table below is the only record of which files are
live** -- a file is live iff its own row says so. Closed means the
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
| 18 | CPU renderer optimization leads | **LIVE.** Continues doc 17 by decomposing the one bracket doc 17 never opened -- the renderer -- against the frozen, calibrated draw rule, so every top-tier lead is decidable by a rule that already exists. Three leads taken and kept (`18/L3`/`F10` sprite-switch guard, `18/L2`/`F11` per-face ASCII glyph table, `18/L12`/`F14` dropping the CoreText glyph wrapper), which cut the draw bracket roughly in half on all three draw workloads -- confirmed independently at -42.8% on-CPU (`18/F12`). One lead taken and rejected on its own measurement (`18/L1`/`F13`), and one measured `faster` and reverted anyway because the only implementation the API permits is memory-unsafe for ~2.5% (`18/L4`/`F15`, `18/D7`). `L6` and `L5` still gated behind a variance measurement `18/D7` ranks above them. |
| 19 | Owner-queue occupancy and the main-thread fence | **LIVE.** Opened 2026-07-30; `C1` and `C4` are landed and measured (`257bfee`, `02f3ba1`), `C2`/`C3`/`C5` rejected as premature. Owns an axis no earlier doc does: not CPU cost per unit of work, but **how long a single job holds `TerminalPTYHost`'s serial queue, and who waits behind it**. Load-bearing because `f75019a` replaced `await host.frameState()` with a blocking `host.fencedFrameState()` -- the fence that makes the damage handoff atomic also makes main's per-frame latency floor the duration of whatever is already running on that queue. `a990606` capped the read turn at 16 KiB on exactly that reasoning (measured 5.94 ms mean / 6.66 ms max stall before; 24% off the termination test after), but the read path was only the job a *flood* workload exposed. **Phase 1 is done** (`19/F1`-`19/F4`), from source and with nothing measured yet. 20 distinct jobs, **four unbounded**: search, select-all, resize/reflow, and the exit-path drain -- while the two IO turns are correctly capped-and-re-firing, which is the shape this file prefers over making a job faster. **The queue is per host** (`19/F2`), so all contention is self-contention -- the pane a long job stalls is the pane that asked for it -- which retires the teardown jobs and keeps the three user-facing ones. **Search is worse-shaped than its seed** (`19/F3`): O(cells) in *allocations* before it is a scan, no match list cached across steps, and one next-match keypress runs the whole-history scan **twice**, because `searchStatus` recomputes it for the overlay's counter. And **one job is proportional to the machine, not the terminal** (`19/F4`): the teardown census enumerates every process on the box and calls `getsid()` per pid on a 10 ms poll, so its cost is set by unrelated system load and no workload-shaped instrument here can see it. `19/H3` (write turn at 4x the read cap) was **answered and retired** -- it caps and re-fires, so the asymmetry is a constant, not a defect. **Phase 2 then measured the three user-facing jobs, and they are large** (`19/F5`-`19/F7`): one search keystroke holds the pane's queue **88 ms** at a saturated history -- **5.3 frames at 60Hz** -- and one reflow step 53.7 ms, with copy-on-write ruled out by control and the obvious "empty terminal" floor discarded as degenerate. The cost is **flat per cell across a 27x range** (140 ns/cell search, 170 reflow), so the depth at which each first blows a frame is arithmetic: **~333 rows for a search keystroke**, ~548 for a reflow -- shallow histories, not extreme ones. The stimulus is worse than per-action: the needle debounce is **zero for needles of 3+ characters** (`19/F7`), inverted relative to cost, so typing a six-character term accumulates ~350 ms of occupancy while the user is still typing. `19/F6` also corrects `19/F3`'s own emphasis -- the matching loop is **78%** of a search and materializing the projection units is the minority cost, so a fix that only avoids the array addresses the smaller share. **Phase 3 ranked four candidates on where that time lands** (`19/F8`, `19/D1`): a search never blocks the main thread by itself -- it is enqueued async -- but the consume task's per-delivery fence is `@MainActor`, so **a search in a pane that is also producing output becomes an app-wide main-thread block** of the same 88 ms, while on an idle pane the harm stays a late result. Ranked: a **cached match list** first (removes the doubling, makes navigation O(1), named risk is staleness), a **bounded re-enqueuing scan** second (this file's rule prefers a bound, but the cache shrinks its frequency first), a **non-materializing walk** third (the only one that helps the Cmd-A path), reflow fourth pending its own rate measurement. Raising the search debounce is **not proposed** despite `19/F7`. `19/D2` records an unusual decidability answer: **no existing workload searches at all**, so no calibrated rule applies and none is needed -- at 5x-50x these are decidable by a stopwatch, where `17/F15` refused a metric a rule for candidates worth a few percent. Recommended first commit is landing the probe as a checked-in occupancy benchmark. **Then confirmed in the live app** (`19/F9`), which sharpened the pitch rather than the size: typing a needle and single Enter steps are responsive -- 88 ms is under the threshold a discrete action is graded against, so `19/F7`'s zero debounce is not the felt problem -- while **holding Enter down is "really weirdly choppy."** The adjective is the finding: key repeat arrives at roughly service time, putting the queue at ~100% utilization, where mean throughput still looks fine and latency variance explodes. Uniform slowness reads as lag; utilization near 1.0 reads as chop. So `19/C1` stays first but on new grounds -- it is the only candidate aimed at repeated navigation on an *unchanged* needle, while `19/C2` and `19/C3` both attack a first scan nobody notices. `scripts/saturate-scrollback.sh` (`--stream` for live output) is the repro. **Phase 4 took `C1`, and almost nothing about the plan survived contact.** Chasing the reported symptom first turned up a **correctness bug rather than an occupancy one** (`19/F10`): both paths that invalidate a stale match -- eviction and overwrite -- discarded the whole search *including the needle*, so `searchNext` returned false forever and on a streaming pane Enter was not slow, it was dead. The recovery for exactly that state already existed and its doc comment described the symptom; it was unreachable because both callers destroyed the query first. Fixed in `364af5c`, and it re-attributes part of `19/F9`. Re-measuring the quiet pane then read **99.3 ms per press, not `19/F5`'s 88** (`19/F11`), splitting to within 0.04 ms between `searchNext` and `searchStatus` -- the strongest confirmation available that the job is literally the same scan twice -- for a ceiling of **10.1 presses/second against a 15-66/s key repeat**. `19/F11` also names the mechanism `19/F9` left implicit: each press publishes an update whose consumer blocks `@MainActor` in `queue.sync` behind the entire backlog, which is why the symptom is chop rather than a steady 10 fps, and why nothing coalesces repeats. Two structural facts then settled the design. **No frame ever reads the match list** (`19/F12`) -- the renderer takes only the single selected match and `searchStatus` has one non-test caller -- so streaming alone triggers zero scans and a wrong cache can never produce a wrong frame. And **`19/D1` named the wrong invalidation hook** (`19/F13`): the right one is `notePrimaryHistoryDamage`, whose existing comment already documents the fail-safe invariant a cache needs (over-invalidate, never under), while `D1`'s guess would have been actively wrong -- `invalidateInspection` early-returns on `guard hasInteractionState`, so search/clear/stream/search-again would have served a stale list. The general lesson: **the codebase had already solved the classification problem, for a different consumer, in a comment.** `19/D3` records the result -- held Enter on a quiet saturated pane **99.3 ms -> ~0.00 ms**, a new needle -> 51.4, streaming -> 48.8 -- plus two admissions. The proposed "free 2x first" staging was **unsound**, since serving one scan to both callers without a cache requires a public API change, so the smaller-looking first step was larger than what it de-risked. And **`19/D2`'s recommended first commit was skipped**: the probe never landed, so the 99.3 ms baseline is now unreproducible without checking out `364af5c` -- acceptable for a 99->0 result, and `19/D3` rules that `19/D2` applies in full to `19/C5`. Method worth repeating: three freshness tests were written first and passed against the *uncached* code, then the cache was built with **no invalidation at all** to prove they had teeth (6 tests failed, 12 issues, 3 of the 6 pre-existing) before the invalidation was added. **`19/C5`** is the new successor candidate -- an incremental tail rescan for the streaming case, resting on matches being stored in *absolute* coordinates (so eviction is a prefix drop, not a rebuild) and naming three edges a design assuming append-only history would get wrong. It was gated on the `--stream` comparison `19/F9` owed, and Phase 5 ran it and came back **negative** (see below). Its one inverted rule is worth knowing before measuring: **occupancy is wall-clock, not CPU**, so doc 14's "re-size it on an on-CPU instrument" would understate precisely the jobs that matter most here. **Phase 5 then closed the search thread on a negative and extracted the more valuable half** (`19/F14`): `C1`'s prediction held -- streaming search at 48.8 ms sits under the key-repeat interval and the user reports it feels fine -- so `C5` is rejected, and **the durable output is a threshold this file had wrong.** `19/D1` ranked against the 16.7 ms frame budget; what actually predicts felt behavior is **the repeat interval of the gesture driving the job**, 66 ms at the default 15/s key repeat. Occupancy above one frame is not by itself a defect, which is why `19/D4` rejects three of five candidates (`C2`, `C3`, `C5`) as premature, all reopenable only on a history materially deeper than doc 15's ~1,768 rows. **`C4` was predicted from source before it was tested and then confirmed live** (`19/F15`) -- the first time this file's prediction went that direction after `F9` and `F10` both went the other way. Geometry reached the owner queue once per *distinct* grid, so a drag across forty columns queued ~2.5 seconds of reflow at 4x-8x utilization, the worst ratio in the file, and forwarded one SIGWINCH per grid: the stacked prompts in the screenshot are four complete zsh redraws at four `COLUMNS` values, not rendering corruption. **Landed in `02f3ba1`** as latest-wins coalescing over contiguous resize runs, closed structurally by every non-resize submission so pointer hit-testing and viewport navigation still read the grid submitted before them. Still open and deliberately not guessed at (`19/F13`'s standing rule): **why** the prompts stack rather than overwrite -- our reflow's cursor placement, or zsh losing its own redraw race under the storm. The discriminating test is one notch, settled, repeated; a positive result outranks the performance work, the same way `19/F10` did. |
| 20 | PTY throughput reporting and interactive stimulus | Closed. Opened 2026-07-30 from "can we benchmark btop under a held key?". Phase 1 is done from artifacts already on disk and produced one result that reframes an existing instrument: **`scrollback-stream` has been a PTY throughput benchmark all along.** `producerWriteNanoseconds` is recorded in every block by `scripts/terminal-benchmark-validation.py:656`, referenced by no metric table, and is **95.7% of `finalDrawNanoseconds`** (median over 368 blocks, 55 runs, all 179x66) -- so the draw tail is only ~9.5 ms, and **a change touching only drawing can move that workload by at most ~4%** (`20/F2`). That refuted this file's own opening hypothesis (`20/H1`: that the deciding metric could hide drain work -- it cannot, they are the same number). The producer is not the bottleneck: it can push the corpus in **30.2 ms / 50.6 MB/s** against blocks of 145-372 ms, so the bracket measures DanTerm, with a ≤30 ms additive arm-symmetric offset (`20/F3`). The drain bracket is also **quieter than the metric that already carries a frozen rule** -- within-arm block CV 0.87% against 1.24% (`20/F4`) -- which raises but does not take `20/H3` (replace the deciding metric; parked, since it would recalibrate every threshold docs 8-18 rest on for a 96%-correlated quantity). `20/D1` selected the descriptive split (drain ms, MB/s, draw tail per arm) with no new rule, and **it is implemented and verified** (`20/F5`): the producer now records the bytes it wrote inside the timed bracket, validation carries them into every block, and all four reported quantities reproduce by hand against an archived series. A live run then proved it end to end (`20/F7`: `bytesWritten` 1,525,076 = corpus plus completion marker, 10.34 MB/s). **And the producer offset turned out not to exist**: `20/F6` rejected `20/H2`'s additive framing by pacing a consumer at the app's real rate, where rechunking the writes moves the block by **0.0 ms** against 20.4 ms unthrottled -- the writer is parked on a full PTY buffer either way, so `20/F3`'s 30.2 ms ceiling is an upper bound never approached and the reported MB/s needs no correction. `agent-docs/terminal-performance.md` documents the new lines and carries the corrected caveat. **Phase 3 then ran to completion and is the more instructive half of the file, because most of what it first concluded was wrong.** `20/D2` declined the keypress workload on evidence rather than taste (`20/F8`: its one genuinely new segment is thin AppKit handling plus a `queue.async` onto the queue doc 19 owns; its expensive segments already belong to existing workloads) and took a captured recording instead. `20/F9` justified the subject: **100% of btop's bytes arrive inside `DECSET 2026` brackets**, where `planIfNeeded` returns early and suppresses planning and drawing outright -- a path no generated workload enters. `20/D3` admitted it and required characterizing before calibrating, which immediately caught `20/F10`: the draw tail is a **constant ~8 ms**, so the block is ~95% drain and this is not the draw instrument a short block made it look like. `20/D4` froze it as the sixth deciding workload (quick 6p @2.65%, confirm 8p @2.15%) from two replicating screens (`20/F11`). **Then four findings in a row corrected the three before them, and the corrections are the durable content.** `20/F12` withdrew a tail this file had asserted twice -- a 193 ms block reported as "~1 in 24, cause unknown, doc 19's to explain" was screen 1's *discarded* outlier counted a second time; across the 192 blocks `D4` rests on, none exceeds +10% and the worst is +6.9%. **A block discarded from a statistic is discarded from the whole file**, and doc 19 inherits nothing. `20/F12` also inferred from two block lengths that the noise was *additive*, so a longer replay should divide it; `20/F13` measured a 5x replay and appeared to confirm it (trimmed pair SD 1.30-1.72% -> 0.56%), and `20/F14` proposed re-freezing on it. **`20/F15` and `20/F16` then dismantled both.** `20/F15` is a retraction: the accuracy gates are deliberately read from *different conditions* -- `select_candidate` takes the false-positive rate from the **A/A** condition and detection/inconclusive/wrong-direction from the **injected-effect** conditions -- and reading `inconclusive` off `aa` manufactured failures that were not there, briefly indicting `D4`'s combination method and every frozen rule in the table. **Read a gate from the code that owns it.** Checked correctly, `20/F15` found two *real* defects instead: the frozen `confirm 8p@2.15%` clears its detection gate only on pooled evidence (0.8571 and 0.8867 against 0.90 on two of three individual screens), and **`synchronized-frames` skipped the confirmation stage the other five workloads had** -- doc 7 records their selected cells re-run at 100,000 trials with disjoint fresh seeds before freezing, while this one was frozen straight off 50,000-trial screens. `20/F16` then killed the lengthening outright by measuring the intermediate points nobody had taken: at 1x/2x/3x/5x the trimmed pair SD reads 1.30-1.72% / 1.65% / 1.62% / 0.56-0.77% -- **the first three are flat**, which is multiplicative noise and the opposite of `F12`'s model, leaving 5x an unexplained two-screen anomaly. It also refuted the obvious confound: the main-thread fence regime shifts at **2x**, not 5x (9 stalls of ~16 ms become 1-2 of 126-266 ms), so 2x/3x/5x share that regime and only 5x is quiet. `20/D5` therefore **declines** -- the fixture stays at 1x, no rule moved, and the tested `replayCount` feature stays because it defaults to 1 and is what made the negative result cheap. Durable lessons graduated to `agent-docs/terminal-performance.md`: a missing field is not a zero, **two points are not a trend** (and a trend with an n=5 endpoint is not even two points -- measure the middle of a predicted curve before acting on it), a **screen is not a freeze**, and verify a candidate cell on each series independently rather than only pooled. Also surveyed: **no terminal project drives synthetic input in-process** -- Ghostty's benchmarks are seven headless micro-benchmarks plus one disabled Xcode-only suite, vtebench and kitty's kitten are both stdout-payload harnesses, and latency everywhere is measured externally (`20/F1`). vtebench's 12 payload generators are logged as an unclaimed corpus opportunity. **Closed 2026-07-30**: `D5` decided (its stated close condition); the two surviving actionables -- the frozen confirm cell's per-screen detection failures and the skipped 100,000-trial confirmation stage -- are inherited by doc 23 (`23/D2`). |
| 21 | Selection gesture cost | **LIVE.** Opened 2026-07-30; nothing measured yet. Owns an axis no earlier file does -- **the cost of a pointer-driven query**, which no workload in the paired harness generates. Converted from a reviewed, converged plan whose every cost claim was derived from the call graph rather than measured; the plan's contract is preserved verbatim as this file's candidate direction and graduates back to a plan only if `21/D1` says take. From source (`21/F1`): every local selection query rebuilds a materialized copy of the whole retained stream, the word/cluster path allocates **one array per projected cell** of it, and a single drag-move additionally pays **~six** full row-array materializations through `setSelection`'s helper chain -- an upper bound of ~300k cells at 179x66 given doc 15's ~1,768 retained rows (`15/F17`). `21/D2` decided how to measure a path no calibrated workload contains: a scratch release-mode probe against the public selection API, **not** a sixth calibrated workload, with a live-drag `sample` as the reality check -- because `17/F17` is what happens when a probe's stimulus is not the app's. `21/D1`'s gate is **pre-registered before Phase 1 runs**, and its deciding quantity is the deep/shallow scrollback ratio rather than an absolute. The change's real price is not code volume but three whole-stream facts the unit walk secretly depends on (`21/F1`): global last-content truncation, a whole-stream nearest-unit fallback (clicking a blank line between two commands selects the previous line's last word *today*), and an alternate-screen seam rule that the obvious existing indexed accessor gets wrong. Two are pinned by no test, so Phase 3 writes them first and requires they fail against a naive slice. |
| 22 | Application-exit job corruption | Closed inconclusive. Named the crashing task-group child and confirmed an image-relative bad resume pointer plus the exact exit arena (`22/F1`-`22/F13`), but the one budgeted debugger attempt could not identify the corrupting write because its breakpoints silently failed. Phase F removed the entire Swift Concurrency exit path in `6d97878` and `50c5240`; the optimized build now quits cleanly. Reopen only if the crash returns. |
| 23 | PTY benchmark alignment with the PTY rewrite | **Closed 2026-07-30.** Opened after the dispatch-join PTY rewrite (`6d97878`/`50c5240` precursors, then `a932c5f`..`a1c00b9`) landed under the benchmark system the same evening. **The fence-stall bracket had been blind to a material, workload-dependent share since `50c5240`** (`23/F2`, `23/F4`): the consume path took two `queue.sync` fences per delivery and timed only the second; one valid post-rewrite block found the untimed first fence was 38.35% of combined wait under `scrollback-stream` and 57.23% under `synchronized-frames`. That confirmed the coverage defect but refuted the proposed mechanism -- the second fence was not consistently cheap. **`23/F5` restores one atomic, fully timed consume fence**: frame state, lifecycle result, and captured transitions now return from one owner-queue transaction, proven by a real-child TDD case and the 132-test TerminalPTY suite. The drain remained inside doc 20's envelope at 91.45%, so the rewrite does not reopen calibration for the other five workloads. **Every number doc 20 recorded characterizes the pre-rewrite delivery path** (`23/F1`): all its screens were committed 11:57-13:04 and `50c5240` landed at 16:02 -- while the frame-delivery coalescing itself predates the plan (rename, not rebuild) and the removed `Task` relays are off the frame path. **The harness's SIGTERM bypass of rewritten shutdown is now verified against DanTerm itself** (`23/F3`, `23/F6`): a temporary marker at the first line of `applicationWillTerminate` stayed absent, while a focused saturated-pane probe put the real registry transaction at 361 ms. **`23/F7` closes the missing package-test intersection**: the real registry path now quiesces a chatty pane under the existing 3-second behavioral ceiling, while benchmark cleanup remains SIGTERM. **Fresh calibration refuses `synchronized-frames`** (`23/F8`): two valid 48-pair screens independently and pooled select no confirm cell; the frozen `8p@2.15%` rule reads 12-14% A/A false positives and 74-78% detection, so no exact cell was eligible for the 100,000-trial stage. **`23/D4` demotes it without deleting the instrument** (`23/F9`): routine comparison returns to the five supported workloads, while the fixture, collector, direct harness, block contract, and candidate-screen path remain available for future research. |

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
