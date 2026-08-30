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
