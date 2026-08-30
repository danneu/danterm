# Findings

### F1 -- The render thread typesets one `CTLine` per fallback cell per frame: 21 frames per second at a full core on the kitten `unicode` arm, and three throwaways price the layers (2026-08-30)

- Status: recorded; every code change reverted, tree back at `606708cc`.
- Date and investigator: 2026-08-30, Claude (agent).
- Commit and worktree state: HEAD `606708cc`, clean tree for the baseline;
  each experiment is one uncommitted edit to
  `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift`,
  built with `just launch-slot-optimized`, then discarded with `git checkout`.
- Commands, inputs, or reproduction: optimized slot 1 launched with
  `DANTERM_FRAME_RATE_LOG` passed through (`--pass-env`), pane pinned with
  `danterm pane resize --pane <id> 179x66`, slot brought frontmost with
  `open -b com.danneu.danterm-dev.1` and the frontmost process verified through
  System Events before the run; `kitten __benchmark__ --render
  --repetitions 1000 unicode` (kitten 0.48.2) typed into the pane through
  `danterm pane input`; 4 s in, `ps -M -p <pid>` (first row is the main
  thread), `ps -o time=` before and after a `sample <pid> 6 1 -mayDie`, and the
  frame-rate log read for its per-second `renders` over the steady interior of
  the run. Shares below are `sample` node counts as a fraction of the main
  thread's samples, aggregated over every occurrence of the frame in the tree.
  Runner and aggregator were session-local in the scratchpad and are not
  committed.
- Result or artifact paths: none committed; the tables are the record.

**The four runs.** Same session, same slot, same grid, frontmost verified each
time, one run each:

| Run | change | MB/s | main `%CPU` (`ps -M`) | renders/s (log, steady) | process cores (`ps time` delta over the sample) |
| --- | --- | ---: | ---: | --- | ---: |
| baseline | none | 122.7 | 100.0 | 20-22 | ~2.0 |
| language | `kCTLanguageAttributeName: "en"` added to the fallback attributes | 122.1 | 99.2 | 22-25 | -- |
| no ligature | the language attribute kept, `kCTLigatureAttributeName: 0` removed | 121.0 | 99.8 | 35-41 | -- |
| memo | no attribute change from baseline; `CTLine` cached across frames per (text, face identity, colour components) in a process-global dictionary | 124.0 | 60.9 | 95-103 | ~1.6 |

**The main thread by frame**, share of the main thread's `sample` stacks:

| Frame | baseline | language | no ligature | memo |
| --- | ---: | ---: | ---: | ---: |
| `_dispatch_main_queue_callback_4CF` | 99.6 | 99.8 | 99.6 | 62.6 |
| `drawRenderFrame` | 98.6 | 98.4 | 97.5 | 57.9 |
| `drawTextRuns` | 96.1 | 95.6 | 93.0 | 45.3 |
| `CTLineCreateWithAttributedString` | 75.2 | 71.1 | 61.5 | 0 |
| `TGlyphEncoder::EncodeChars` | 69.9 | 51.4 | 31.2 | 0 |
| `TAttributes::CopyOfFontWithLigatureSetting` | 27.3 | 30.1 | 0 | 0 |
| `TFont::TFont` | 19.0 | 20.3 | 1.0 | 0 |
| `TFont::SetExtras` | 14.8 | 15.6 | 0 | 0 |
| `CFLocaleCopyPreferredLanguages` | 11.5 | 5.7 | 9.1 | 0 |
| `TFont::NeedsShapingForGlyphs` | 23.7 | 0 | 0 | 0 |
| `TFont::ShapesAnyPreferredLanguage` | 23.6 | 12.5 | 20.0 | 0 |
| `TLine::DrawGlyphs` | 6.2 | 7.8 | 10.6 | 22.0 |
| `CTFontDrawGlyphs` | 5.1 | 6.5 | 9.0 | 18.5 |
| `CGContextFillRect` | 5.3 | 5.7 | 9.3 | 25.8 |
| `NSAttributedString` construction | 0.9 | 0.7 | 1.5 | 0.1 |

In the no-ligature run the surviving `ShapesAnyPreferredLanguage` sits under
`TTypesetter::FinishEncoding` -> `TShapingEngine::ShapeGlyphs` ->
`TOpenTypeMorph::TOpenTypeMorph`, i.e. the shaping engine asking the fallback
font it chose, not the font copy asking on construction. In the baseline the
frame also appears under `TFont::NeedsShapingForGlyphs` (the pre-shaping
question the language attribute answers) and under `TFont::SetExtras` (the
copied font's construction). In the memo run the main thread's remaining
stacks are `drawTextCell` 41.7% (the per-cell `saveGState`/`clip`/`CTLineDraw`/
`restoreGState` on the cached line) and the frame's background fill; the
dictionary lookup and `String` hashing are about 3%.

**Per-frame arithmetic.** The pane is 66 rows x 179 columns; every `unicode`
cell is a wide CJK character, so a row holds 89 fallback cells and a frame
5,874. At 123 MB/s and 21 frames per second a frame absorbs about 5.9 MB, which
is a few hundred rewrites of the alternate screen, so the folded damage is
`.full` and every frame redraws every cell. One core at 21 frames per second
is about 47 ms per frame and about 8 us per fallback cell; the memo run at 63%
of a core and 98 frames per second is about 6.4 ms per frame and about 1.1 us
per cell.

**Observation:**

- `39/F13`'s chain reproduces at HEAD with the same shares, and it is a
  per-cell chain: `drawTextCell` is inlined into `drawTextRuns` in the release
  object and every fallback cell builds its own attributed string and line.
- The frame rate is the draw's: 21 renders per second with the display at 120,
  the main thread saturated, and the parse thread unaffected (MB/s flat within
  3 points across all four runs, which is the run-to-run spread research 39
  recorded on this arm).
- The three layers price as: font copy per cell (`kCTLigatureAttributeName`)
  about half the frame; the pre-shaping language question about a fifth; the
  shaping itself and the fallback-font cascade the rest. Only the memo removes
  the shaping.

**Inference:**

- `H1`, `H2` and `H4` are confirmed as mechanisms by a change that moves the
  frame rate by the size the share predicted or more (the ligature attribute's
  27% share bought 1.8x; the memo's 75% bought 4.7x, to the panel's cap).
  `H3` is partially confirmed: the attribute answers one of the two language
  questions and the shaping engine asks the other again per fallback font.
- The user-observable claim `39/D9` lacked exists: a CJK stream repaints at a
  fifth of the panel rate and holds a core while it lasts, and the ASCII arm on
  the same tree does neither (`39/F13`: 0.24 core on `ascii`).
- The residual after a memo is `H5`: per-cell `CTLineDraw` and the full-frame
  fill, in roughly equal parts of a thread that is now a third idle.

**Competing interpretations:**

- The memo's frame rate could be a cache artifact of kitten's repeating corpus
  (a few hundred distinct characters, so a near-100% hit rate after one frame).
  True of the hit rate, not of the mechanism: the miss cost is the baseline's
  per-cell cost, and a real CJK stream with thousands of distinct characters
  pays it once per character rather than once per cell per frame. `T2` sizes
  the real hit rate; `D1` sizes the cap.
- The ligature result could be CoreText skipping ligature *analysis* rather
  than a font copy. The frames say copy: `CTFontCreateCopyWithAttributes` and
  `TFont::TFont` leave with the attribute, and a one-cluster string has nothing
  to ligate in either case.
- The 100% main thread in the first three runs could hide some idle inside
  the run loop that `sample` counts as busy. `ps -M` reads 99-100% independently
  in all three and 61% in the memo run, so the two instruments agree.

**Uncertainty:** one run per condition, unpaired, `sample` at 1 ms; the frame
rates are read off a log the app writes per second and vary 3-6 frames within
a run. Enough to rank the layers and to confirm the mechanisms; not a verdict,
and not a size for any shipped change. The memo experiment keyed on colour
components and never evicted; it is the mechanism's proof, not a design.

**Next action:** `T1`, the headless `fallback-shaped` draw arm, so Phase 2 has
a paired per-frame bracket to decide on; then `D1` on `F1` and `F2`.

### F2 -- The `fallback-shaped` headless draw arm: 130.5 ms per full 179x66 frame against `text-shaped`'s 3.06 ms, and a proposed rule of +/-1.00% on the two-direction estimate (2026-08-30)

- Status: recorded. The arm is committed (`3538b7b5`); the rule is proposed and
  **not frozen** -- a human freezes it, as `39/D2` did for the `kitten-feed-*`
  arms.
- Date and investigator: 2026-08-30, Claude (agent).
- Commit and worktree state: collected on the working tree that became
  `3538b7b5`, parent `880af295`. No other change was present.
- Commands, inputs, or reproduction:
  - Absolute per-draw cost: `just benchmark-draw 9`, which measures every
    workload at both standard grids in one process.
  - A/A series: ten invocations of
    `python3 ./scripts/terminal-headless-draw-compare.py --columns 179
    --rows 66 --clip-rows 0 --workload fallback-shaped --rounds 8
    --both-directions`, both arms bound to this same `lib/TerminalCore`, so
    every measured difference is noise by construction. Each invocation is 4
    direction runs x 8 ABBA rounds = 64 paired differences, ~92 s.
  - Control the change cannot reach: three of the same invocations on
    `--workload text-shaped`, interleaved with the fallback ones in the same
    session. A workload generator cannot alter the instrument's slot
    asymmetry, so the ASCII arm is what separates "this workload is biased"
    from "this machine was".
  - Machine: MacBookPro18,1 (M1 Pro) on AC power, 100% charged, load average
    1.8-2.2 throughout from other agent sessions on the host. This is **not**
    the idle machine the ladder's thresholds were calibrated on; see
    Uncertainty.
- Result or artifact paths: none committed. `.build/terminal-headless-draw/`
  holds only the generated arm packages; the reports were session-local.

**What one draw costs.** Full-frame, `displayScale` 2, median of 9 duration-
stable samples per cell of the matrix:

| workload | grid | cells | columns | median per draw | per cell |
| --- | --- | ---: | ---: | ---: | ---: |
| `text-shaped` | 80x24 | 1,920 | 1,920 | 0.553 ms | 0.29 us |
| `btop-shaped` | 80x24 | 1,920 | 1,920 | 2.356 ms | 1.23 us |
| `fallback-shaped` | 80x24 | 1,101 | 1,920 | 21.034 ms | 19.10 us |
| `text-shaped` | 179x66 | 11,814 | 11,814 | 3.064 ms | 0.26 us |
| `btop-shaped` | 179x66 | 11,814 | 11,814 | 14.415 ms | 1.22 us |
| `fallback-shaped` | 179x66 | 6,653 | 11,814 | 130.540 ms | 19.62 us |

The two grids agree on us/cell to within 2.7% on every workload, which is the
linearity check `DrawBenchmarkGrid.standard` exists for.

**The A/A series.** Every row is one `--both-directions` invocation.
`realEffectPercent` is the claimable quantity (the part that reverses when the
arms swap slots); `orderBiasPercent` is the part that does not.

| invocation | realEffect % | orderBias % |
| --- | ---: | ---: |
| 1 | +0.685 | +1.039 |
| 2 | +0.285 | +1.125 |
| 3 | -0.225 | +1.408 |
| 4 | +0.107 | +1.417 |
| 5 | -0.152 | +1.677 |
| 6 | +0.239 | +1.099 |
| 7 | +0.051 | +1.394 |
| 8 | +0.380 | +1.282 |
| 9 | +0.325 | +1.188 |
| 10 | +0.298 | +1.016 |

`realEffect`: n=10, mean +0.199, median +0.262, SD 0.252, range
-0.225..+0.685, worst magnitude 0.685. `orderBias`: mean +1.264, range
+1.016..+1.677, and it never crosses zero.

The `text-shaped` control, same session, three invocations: `realEffect`
+0.583, +0.056, -0.444; `orderBias` +0.118, -0.013, +0.073. Per-pair spread is
the same on both workloads (pooled SD 1.72% fallback over 320 pairs, 1.77%
text over 192), so the fallback arm is not noisier per pair -- it carries a
slot bias an order of magnitude larger, and only that.

**What the corpus's own screen says about a single direction.**
`terminal-benchmark-candidate-screen.propose_rule` was called on the 320
fallback quartets (the gates are `ACCEPTANCE_GATES`, read from the code that
owns them, not restated here):

- at `confirm`'s parameters (3% effect, 0.75% band): **no cell clears at any
  searched pair count**, because the resampled A/A distribution sits on the
  +1.26% bias.
- at `quick`'s parameters (5% effect, 1.0% band): 6 pairs at +/-2.70%, A/A
  false positives 0.0095, detection 0.984/0.991.
- the `text-shaped` control on the same call at `confirm`'s parameters: 6 pairs
  at +/-2.00%, false positives 0.0087, detection 0.947/0.962.

**Observation:**

- A full screen of CJK and cluster text costs **42.6x** an ASCII screen of the
  same 11,814 columns (130.540 ms against 3.064 ms) and 9.1x the dense sprite
  screen, on the same surface, in the same process, with the same plan
  structure. Per cell the ratio is 75x.
- The fallback arm carries a systematic slot asymmetry of +1.0 to +1.7% that
  the ASCII arm does not, in the same session on the same machine. Its sign is
  constant: whichever arm sits in the candidate dylib slot draws slower.
- `--both-directions` removes it. Across ten A/A invocations the antisymmetric
  estimate stays inside +/-0.69% with SD 0.25%.

**Inference:**

- The arm `T1` asked for exists and resolves what it was built to resolve. The
  candidate shapes in `D1` are priced by `F1` at 1.8x (`H2` alone) to 7x (the
  memo) on the frame; a 0.25% SD reads any of them without ambiguity, and would
  read a tenth of the smallest of them.
- **The rule has to be stated on `realEffectPercent`, not on a single
  direction.** That is not a preference: the screen refuses a `confirm`-grade
  cell on the single-direction series and grants one on the two-direction
  quantity, and the `text-shaped` control shows the difference is the
  workload's, not the day's.
- Proposed rule, for a human to freeze:
  **`fallback-shaped` decides on `realEffectPercent` from one
  `--both-directions` invocation at 8 rounds per direction, at +/-1.00%, and
  only when `orderBiasPercent` is below 2.5%.** +/-1.00% is 3.2 SD above the
  A/A mean and 1.46x the worst A/A magnitude seen in ten invocations. The
  order-bias guard is the instrument's own reading rule
  (`agent-docs/terminal-performance.md`: read `orderBiasPercent` before
  believing `realEffectPercent`) turned into a number, sized at 1.5x the worst
  bias observed; a run above it is invalid, not a verdict.
- Alongside it, for a single-direction run, which the recipe's default still
  produces: **descriptive only, no verdict below +/-2.70%**, and that cell is
  a 5%-effect cell, so it cannot see a 3% change at all.

**Competing interpretations:**

- The order bias could be the machine's rather than the workload's. Rejected by
  the interleaved `text-shaped` control, whose bias is +0.07% mean in the same
  session. It could still be an interaction of the workload with the harness's
  own warm-up -- `calibrate_batch_count` doubles on the baseline arm first, and
  at 4 draws per batch each arm enters measurement with a different number of
  prior draws behind it, which matters more at 130 ms per draw than at 3 ms.
  Not diagnosed here; it is a property the rule works around rather than a
  finding about the draw path.
- The 19.6 us per fallback cell could be read against `F1`'s ~8 us and taken as
  a contradiction. It is not comparable: `F1` timed the app drawing into its
  IOSurface with a warm CoreText state and one styled face in play, and this
  arm draws into a fresh sRGB bitmap across all four styled faces. Only the
  ratio between workloads inside one run is a claim.
- The 42.6x could be an artifact of the fallback corpus having 44% fewer cells
  per frame (wide cells). It is not -- fewer cells is the direction that would
  *understate* it; per cell the gap is 75x.

**Uncertainty:** the host was not idle (load average 1.8-2.2 from other agent
sessions), which is a documented invalidation condition for the GUI ladder and
is why the numbers above are quoted with their control rather than alone. Ten
A/A invocations bound the false-positive side and nothing here bounds detection
on a real revision pair, which no A/A series can (`agent-docs/terminal-
performance.md`: "its A/A precision is not its precision on a revision pair").
The +/-1.00% proposal is therefore a floor argued from A/A spread plus the
instrument's documented ~0.5-1% revision-pair resolution, not a screened cell
with a measured detection rate. A human freezing it should say which of the two
it is accepting.

**Next action:** `D1` can now be decided on `F1` and `F2`. `T2` and `T3` remain
open and neither gates it.

### F3 -- The shipped shape-once cache: `fallback-shaped` reads -141.3% under `D1`, no `CTLine` call survives on a steady-state frame, and the kitten `unicode` arm goes from 21 renders per second at a full core to 107 at 38% (2026-08-30)

- Status: recorded on the working tree that became this commit. The pre-change
  arm is `27f4ef8d`, read from a detached worktree in the same session.
- Date and investigator: 2026-08-30, Claude (agent).
- Commit and worktree state: candidate is the working tree of `T4`'s
  implementation, parent `27f4ef8d`; baseline is a detached worktree at
  `27f4ef8d` with nothing else applied. The user confirmed the host was idle
  for the whole run.
- Commands, inputs, or reproduction:
  - Gate: `python3 scripts/terminal-headless-draw-compare.py --rounds 8
    --both-directions --baseline-core <worktree>/lib/TerminalCore --workload
    fallback-shaped`, the invocation `PO8` spells out. The recipe cannot
    express it (it passes no `--workload` and wires its positional argument to
    `--candidate-core`, which would read a win as `slower`).
  - Fast-path control: the same invocation on `--workload text-shaped`.
  - Routine ladder: `just benchmark-confirm baseline=HEAD`.
  - Frame rate: optimized slot 1 through `./scripts/dev-slot-launcher.py
    --release --pass-env DANTERM_FRAME_RATE_LOG`, pane pinned with `danterm
    pane resize --pane <id> 179x66`, the slot made frontmost by unix id through
    System Events and the frontmost bundle id read back
    (`com.danneu.danterm-dev.1`) before each run; `kitten __benchmark__
    --render --repetitions 1000 <arm>` (kitten 0.48.2) typed in through
    `danterm pane input`; 4 s in, `ps -M -p <pid>` for the main thread and
    `ps -o time=` either side of `sample <pid> 6 1 -mayDie`. One run per cell.
    Runner was session-local in the scratchpad and is not committed.
- Result or artifact paths: none committed; the tables are the record.

**The gate (`PO8`).** One `--both-directions` invocation, 8 rounds per
direction, at the compare script's default geometry (160x50, 4 clipped rows):

| quantity | reading |
| --- | ---: |
| `realEffectPercent` | **-141.28%** |
| `orderBiasPercent` | +0.015% |
| rounds per direction | 8 |
| verdict under `D1` | `faster` |

The order bias sits two orders of magnitude under the 2.5% guard, so the run is
valid rather than re-run. `D1`'s floor is +/-1.00% and the reading is 141x it.

**What the fast path and the routine ladder read.** `text-shaped` on the same
instrument: `realEffectPercent` +0.63%, `orderBiasPercent` -0.09% -- inside the
same 1.00% floor, which is what "not `slower`" means here; no rule is frozen for
that workload, so the number is descriptive. `just benchmark-confirm
baseline=HEAD`: `content-churn` **equivalent** (+0.63%), `style-churn`
**inconclusive** (-1.04%), and no workload reads `slower`. `scrollback-stream`
is descriptive and uncalibratable, but its draw tail fell from 21.9 ms (33.7% of
the block) to 11.8 ms (22.0%), which is the same effect reaching a stream that
mixes fallback cells into ordinary output.

**The real stream (`PO9`), 179x66, frontmost, one run per cell:**

| arm | tree | renders/s (log, steady) | main `%CPU` (`ps -M`) | process cores over the sample |
| --- | --- | --- | ---: | ---: |
| `unicode` | `27f4ef8d` | 19-23 | 100.0 | 1.99 |
| `unicode` | this change | 105-108 | 37.8 | 1.41 |
| `unique_unicode` | `27f4ef8d` | 3-4 | 99.4 | 2.26 |
| `unique_unicode` | this change | 4-5 | 99.4 | 2.00 |

The `unicode` row is `F1`'s baseline reproduced (`F1` read 20-22 at 100.0) and
then re-taken on the change. Renders, publishes and deliveries all sit at
105-108 per second in the log, i.e. every published frame is drawn and the draw
is no longer the cadence; the panel offers 120. A second `unicode` run earlier
in the same session read 105-108 at 37.0% and 1.69 process cores.

**The main thread by frame** on the `unicode` arm, share of the main thread's
4,396 `sample` stacks, beside `F1`'s baseline column:

| Frame | `F1` baseline | this change |
| --- | ---: | ---: |
| `_dispatch_main_queue_callback_4CF` | 99.6 | 41.3 |
| `drawRenderFrame` | 98.6 | 35.9 |
| `drawTextRuns` | 96.1 | 21.8 |
| `CTLineCreateWithAttributedString` | 75.2 | **0** |
| `CTLineDraw` (under `TLine::DrawGlyphs`) | 6.2 | **0** |
| `CTFontDrawGlyphs` | 5.1 | 8.8 |
| `CGContextFillRect` | 5.3 | 28.6 |
| `ShapedClusterCache` lookup | -- | 1.8 |

**Observation:**

- `PO6`'s frame-presence check passes literally: the whole 6 s sample of a
  steady-state `unicode` frame contains zero `CTLineCreateWithAttributedString`
  and zero `CTLineDraw` stacks, on any thread. The typesetting is gone from
  steady state, not reduced.
- The frame's background fill is now the largest single item on the main thread
  (28.6%, up from 5.3% only because the denominator collapsed). That is the
  non-goal this plan names (`39/F13` `ascii`, doc 18 `L6`), and it is what the
  next draw-side item would attack.
- `unique_unicode` is `AR1`'s thrashing case made real: every cell of every
  frame is a cluster the cache has not seen, so each one pays today's
  typesetting plus extraction and insertion. It did not regress -- 4-5 renders
  per second against `27f4ef8d`'s 3-4, at the same saturated main thread -- but
  it is not fixed either, and no claim in this doc covers it.
- Process cores fell on both arms (1.99 -> 1.41 on `unicode`), so the work
  removed from the main thread was not pushed onto another one.

**Alternative explanations considered:**

- The -141% could be the arm measuring something other than the change. It is
  not measuring the *steady state*: `build_arm` copies one `Arm.swift` into both
  generated packages, so the arm cannot name `ShapedClusterCache` and the
  candidate runs with a per-draw cache, measuring within-frame reuse only. That
  understates the effect, which is the conservative direction for a gate. The
  cross-frame steady state is pinned by `PO6`'s miss counts and by the frame
  table above, never by this number.
- The frame-rate jump could be the parse thread going faster rather than the
  draw. Deliveries, publishes and renders all read 105-108 per second, so the
  pipeline is publish-paced end to end; and the process core count fell, which
  a faster parse would not produce.
- The `unicode` improvement could be the cache holding a working set that a real
  stream would not. The kitten arm repeats a small CJK set, so this reading is
  the *best* case for residency by construction; `unique_unicode` is the worst
  case and is tabled beside it precisely so neither is read alone. `T2` remains
  open and is what would measure a real stream between them.

**Uncertainty:** one session, one slot, one host, one run per cell, `sample` at
1 ms for 6 s. The `%CPU` column is a `ps -M` instant and the core count is a
`ps time` delta over the sample; neither is a distribution. `PO8`'s threshold is
`F2`'s false-positive floor, not a screened detection cell (`AR2`), which is
adequate at 141x and would not be near it. The `text-shaped` and
`benchmark-confirm` readings are "not `slower`" verdicts, not evidence the fast
path is unchanged -- that is a code property, and `PO7`'s unchanged suite is
what carries it.

**Next action:** `T4`, `T5` and Phase 3's closing reading are all satisfied.
`T2` and `T3` stay open; `unique_unicode` and the frame fill are the two items
this doc leaves on the table.

### F4 -- Real CJK streams on the shipped tree: a `cat` of 5,420 distinct Han characters draws at 97-103 renders per second with the main thread at 46%, and a held key in `less` at 27 with it under 6% (2026-08-30)

- Status: recorded on the shipped tree. No code change; `T3`'s throwaway
  instrumentation was not present for any number in this finding.
- Date and investigator: 2026-08-30, Claude (agent).
- Commit and worktree state: HEAD `d3651316`, clean tree.
- Commands, inputs, or reproduction: optimized slot 1 through
  `./scripts/dev-slot-launcher.py --release --pass-env DANTERM_FRAME_RATE_LOG`,
  pane pinned with `danterm pane resize --pane <id> 179x66`, the slot made
  frontmost by unix id through System Events and the frontmost bundle id read
  back (`com.danneu.danterm-dev.1`) before the runs, host on AC power. Two
  workloads, one run each, 14 s of stimulus with a `sample <pid> 6 1 -mayDie`
  starting 3 s in and `ps -M -p <pid>` either side of it, plus `ps -o time=`
  across the sample for the process core count:
  - `cat`: `bash -c 'for i in $(seq 400); do cat <corpus>; done'`, a 4.75 MB
    corpus of the Chinese-script lines of four Project Gutenberg texts
    (`24264` Dream of the Red Chamber, `23950` Romance of the Three Kingdoms,
    `25328`, `24144`) -- 1,557,453 non-space characters, **5,624 distinct**, of
    which 5,505 are Han. Repeating the file leaves the distinct set unchanged,
    which is the point: kitten's `unicode` corpus holds a few hundred.
  - `less`: the same corpus under `less`, with `Down` sent one key at a time
    every 30 ms for 14 s -- the host's own key-repeat cadence
    (`defaults read -g KeyRepeat` is 2, i.e. 30 ms), so the stimulus is a held
    key rather than a burst. 383 keys were delivered in 14.0 s (27.4/s).
  - No CJK TUI was run: the host has no Japanese or Chinese man pages
    (`/usr/share/man` holds `man1`..`mann` only) and no CJK TUI was to hand.
    `T2`'s third arm is not measured, and nothing below stands for it.
- Result or artifact paths: none committed; the tables are the record. The
  runner and the corpus were session-local in the scratchpad.

**The two streams**, beside `F3`'s two kitten arms on the same tree and grid:

| stream | renders/s (log, steady) | publishes/s | main `%CPU` (`ps -M`) | main busy (`sample`, 6 s) | process cores |
| --- | --- | --- | ---: | ---: | ---: |
| kitten `unicode` (`F3`) | 105-108 | 105-108 | 37.8 | -- | 1.41 |
| **`cat`, real CJK** | **97-103** | 97-103 | **46.2, 45.3** | **48.4** | **~1.7** |
| **`less`, held key** | **26.4-28.6** | same | **0.1-0.4** | **5.6** | **0.08** |
| kitten `unique_unicode` (`F3`) | 4-5 | -- | 99.4 | -- | 2.00 |

`renders` equals `publishes` in every window of both streams, so neither is
draw-paced: the `cat` sits at the delivery fence's cap and the `less` sits at
one frame per keypress (27.4 keys/s in, 27.3 frames/s out).

**The main thread by frame**, share of the main thread's `sample` stacks:

| Frame | `cat` (4,317 stacks) | `less` (4,683 stacks) |
| --- | ---: | ---: |
| `_dispatch_main_queue_callback_4CF` | 43.7 | -- |
| `drawRenderFrame` | 38.3 | 0.90 |
| `drawTextRuns` | 25.9 | 0.64 |
| `CGContextFillRect` | 25.3 | 0.47 |
| `CTFontDrawGlyphs` | 10.3 | 0.17 |
| `ShapedClusterCache` lookup | 2.5 | 0.15 |
| `shapeCluster` (miss path) | 0.9 | 0 |
| `CTLineCreateWithAttributedString` | 0.4 | 0 |

**Distinct clusters and fallback cells per frame**, from `F5`'s instrumented
run of the same two streams (the stimulus is identical; the counts are not
timing numbers):

| stream | fallback cells | frames | cells/frame | distinct clusters |
| --- | ---: | ---: | ---: | ---: |
| `cat`, real CJK | 2,920,157 | 1,399 | 2,087 | **5,420** |
| `less`, held key | 69,122 | 373 | 185 | **1,649** |
| kitten `unicode` | 2,572,079 | 1,478 | 1,740 | 327 |
| kitten `unique_unicode` | 610,416 | 65 | 9,391 | **252,795** |

**Observation:**

- A real CJK `cat` at full speed sits at the *good* end of `F3`'s bracket, not
  between the two arms: 97-103 renders per second against `unicode`'s 105-108
  and `unique_unicode`'s 4-5. The extra 8 points of main thread over `unicode`
  (46% against 37.8%) is the miss path -- `shapeCluster` 0.9% and
  `CTLineCreateWithAttributedString` 0.4% of the thread -- plus a larger
  repaint (2,087 fallback cells per frame against 1,740).
- The full-frame background fill is again the largest single item in the draw
  (25.3% of the main thread, two thirds of `drawTextRuns`' cost), exactly as
  `F3` found on the kitten arm. That is doc 18's `L6`, not this doc's mechanism.
- The interactive case is nowhere near a core. A held key in a CJK pager
  repaints once per keystroke and spends 0.9% of the main thread inside
  `drawRenderFrame`; the whole process runs at 0.08 cores.
- The distinct working set of a real stream is thousands, not hundreds: 5,420
  clusters for two full classical novels plus two shorter texts, 1,649 for the
  400 lines a held key scrolls past. Both are far below `unique_unicode`'s
  252,795 in fourteen seconds.

**Inference:**

- `H6` is confirmed as a mechanism and **fails its own stated threshold**. The
  exposure is bounded by the repaint -- a real stream is publish-paced, the
  draw is not the cadence, and the interactive case is free -- but the
  criterion written into `H6` ("the main thread under a quarter of a core")
  is not met by a full-speed `cat`, which holds 46%. The honest wording of the
  user-observable claim is: on the shipped tree a CJK stream repaints at the
  pace the pipeline publishes at, for about half a core of main thread at
  firehose speed and about nothing while a human scrolls.
- The `cat` is the worst real case available here: 1.4 GB of Han text through
  the fence as fast as the PTY delivers it. Anything a person reads is the
  `less` row.
- `D2`'s cap of 16,384 is not reached by either real stream. The largest real
  working set measured is 5,420, so the cap has 3.0x headroom on it; see `D2`'s
  note for what would move it.

**Competing interpretations:**

- The `cat` could be publish-paced only because the delivery fence is slower
  than the draw on this host, hiding a draw that is still expensive. Against
  it: the draw is 38.3% of a main thread that is 48.4% busy, i.e. about 4.7 ms
  of a 10 ms frame, and the panel offers 120 -- the draw has margin, and
  `renders` never falls below `publishes` in any window.
- The 46% main thread could be the corpus rather than the mechanism: a corpus
  whose distinct set is small would hide the miss path. It does not hide it
  here (5,420 distinct clusters, the miss path visible at 1.3% of the thread),
  and a corpus with more distinct characters would raise only that 1.3%.
- The `less` reading could be the stimulus, not the terminal: keys delivered
  through `danterm pane input` arrive as discrete writes rather than as a real
  key repeat. The cadence was matched to the host's own repeat interval and
  the frame count matches the key count, so the pane drew one frame per key,
  which is what a held key produces.

**Uncertainty:** one session, one slot, one host, one run per stream, `sample`
at 1 ms for 6 s, `%CPU` from two `ps -M` instants. The distinct-cluster and
per-frame counts come from the instrumented build of `F5` and were collected in
separate runs from the timing numbers, so they pair with the stream, not with
the frame rates in the first table. No CJK TUI arm exists.

**Next action:** none open on `T2`. `D2`'s cap question is answered in the
decision log; the frame fill (doc 18 `L6`) and `unique_unicode` (`AR1`) remain
the two items this doc leaves.

### F5 -- The fallback census: real CJK streams are 100% cmap misses of single BMP scalars, kitten `unicode` is 96.7% the same, and `unique_unicode` is 100% multi-scalar clusters (2026-08-30)

- Status: recorded; the instrumentation was a throwaway and is reverted. Tree
  back at `d3651316`, `git status` clean of it.
- Date and investigator: 2026-08-30, Claude (agent).
- Commit and worktree state: HEAD `d3651316` plus one uncommitted edit to
  `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift`
  (a counter at each of the three sites that append to `fallbackCells`, a
  distinct-key set keyed as the cache is keyed -- bold, italic, cluster scalars
  -- and a JSON line appended once a second from `drawRenderFrame`) and one to
  `scripts/dev-slot-launcher.py` (the log variable added to the pass-through
  allowlist). Both discarded with `git checkout` afterwards.
- Commands, inputs, or reproduction: one optimized slot launch per stream, the
  same frontmost 179x66 procedure as `F4`, 14 s per stream: `F4`'s `cat` and
  `less`, and `kitten __benchmark__ --render --repetitions 1000 <arm>`
  (kitten 0.48.2) on `unicode` and `unique_unicode`. The census counts a cell
  each time it is routed to the fallback path, so it counts per draw, not per
  distinct cell.
- Result or artifact paths: none committed; the table is the record.

**The distribution**, cells routed to the fallback path over 14 s:

| stream | cmap miss (single BMP scalar) | multi-scalar cluster | non-BMP scalar | ASCII-table miss | private use | distinct clusters |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `cat`, real CJK | 2,920,157 (100%) | 0 | 0 | 0 | 0 | 5,420 |
| `less`, held key | 69,122 (100%) | 0 | 0 | 0 | 0 | 1,649 |
| kitten `unicode` | 2,485,966 (96.65%) | 38,278 (1.49%) | 47,835 (1.86%) | 0 | 0 | 327 (304 / 13 / 10 by reason) |
| kitten `unique_unicode` | 0 | 610,416 (100%) | 0 | 0 | 0 | 252,795 |

**Observation:**

- Every fallback cell in a real Chinese stream is one BMP scalar the base face
  cannot map -- the monospaced system font covers no Han -- which is `4/H3`'s
  revival trigger ("non-sprite cmap misses dominating real output, CJK-heavy
  output in a non-covering font") measured for the first time.
- The two synthetic arms are the two other reasons: `unicode` mixes 1.9%
  non-BMP scalars and 1.5% multi-scalar clusters into the same cmap misses,
  and `unique_unicode` is nothing but four-scalar clusters.
- Neither the ASCII glyph table nor the packaged-symbols route ever spilled: no
  stream produced an ASCII-table miss or a private-use cell that reached the
  fallback path.
- `unique_unicode` produces 9,391 fallback cells per frame at 65 frames in 14 s
  and 252,795 distinct clusters in that time, so it clears the 16,384-entry
  cache about fifteen times a run.

**Inference:**

- `D2`'s key design covers the cells that occur. The key is (face emphasis,
  cluster scalars), and all four streams key on exactly that: a single scalar
  in the three real-shaped cases and a whole cluster in the multi-scalar ones.
  Nothing in the census wants a different key -- no reason bucket is empty of
  cells that would collide under it, and none needs colour or position.
- The mechanism this doc removed is a *cmap*-miss mechanism in the real world.
  A user font that covers CJK moves those cells to the fast path and empties
  this census; the cost follows whichever scalars the chosen face lacks, as the
  README's caveat says.

**Competing interpretations:**

- The 100% cmap-miss reading could be an artifact of the corpus being pure
  Chinese prose. Partly: the corpus keeps only lines containing Han, so no
  emoji or ZWJ sequence is in it. That is a claim about what a Chinese text
  file contains, and the kitten `unicode` row is the mixed case beside it.
- The counter could miss a fourth route. It sits at all three sites that append
  to `fallbackCells` and nowhere else, and the three totals are the whole
  fallback population by construction.

**Uncertainty:** one run per stream, one host, one font set (the default
monospaced system font at 13 pt). Counts are exact; nothing here is a timing
number, and the instrumented build is slower than the shipped one and was not
read for speed.

**Next action:** none. `T3` is closed.
