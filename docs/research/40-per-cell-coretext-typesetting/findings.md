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
