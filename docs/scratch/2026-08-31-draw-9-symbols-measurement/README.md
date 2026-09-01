# DRAW-9 symbols-path measurements

Four `scripts/terminal-headless-draw-compare.py --both-directions` runs, taken in
one session on an idle machine, 8 rounds per direction, 160x50, `--clip-rows 0`
(full frame). The symbols runs draw 8000 icon cells per draw; the two controls
draw none.

Every number below is the report's `estimate.realEffectPercent` and
`absoluteEstimate.realEffectNanosecondsPerDraw` -- the antisymmetric estimate
across the forward and reversed runs. A negative value means the candidate arm
is faster. `symbols-shaped` has no frozen decision rule, so all four reports are
descriptive.

| File | Baseline arm | Candidate arm | Real effect | Per draw | Per icon cell | Order bias |
|---|---|---|---|---|---|---|
| `d3a-symbols-shaped.json` | pre-D1 (`4ccc171c`) | D1 (`e9bfa1b2`) | -12.55% | -1.348 ms | -168 ns | -0.50% |
| `d3b-symbols-shaped.json` | D1 (`e9bfa1b2`) | coverage table (throwaway) | -16.21% | -1.512 ms | -189 ns | -0.51% |
| `control-btop-shaped.json` | pre-D1 | D1 | -0.20% | -19.6 us | n/a | -0.04% |
| `control-text-shaped.json` | pre-D1 | D1 | -0.52% | -11.0 us | n/a | -0.01% |

The two controls cannot reach the symbols path, so they are negative controls
for the shipped change, measured in the same session. Neither moved further than
this instrument's own paired spread against an unchanged tree (~0.7% to 0.85%),
so both read as quiet. Quiet is what the code predicts, not what these runs
prove: an equivalence claim would need a rule this workload does not have.

## The throwaway coverage arm

`coverage-table-arm.patch` is the D3b candidate, applied to
`lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift`
at `e9bfa1b2` in a scratch copy of the package. It is a measurement arm only and
was never committed to the tree. It builds one
`[UInt32: (glyph: CGGlyph, bounds: CGRect)]` table for the packaged symbols face
at construction, from `CTFontCopyCharacterSet`'s real coverage intersected with
the three private-use ranges, so both live CoreText calls leave the draw --
`nominalGlyph` reads the glyph from the table and `drawPackagedSymbol` takes the
ink bounds from it.

The table holds 10396 entries at a 48-byte stride: 499008 bytes of payload per
`TerminalFontSet`, which is per pane and per font size, before the dictionary's
own load-factor overhead. That is measured, not estimated (the audit's
Correction guessed ~340KB). `NerdFontSymbolsExecutionTests` passes unmodified
against the arm, so the table resolves the same glyphs and bounds the live calls
did.

## Reproducing

```
git archive 4ccc171c lib/TerminalCore | tar -x -C <scratch>/pre-d1 --strip-components=1
python3 scripts/terminal-headless-draw-compare.py --both-directions --rounds 8 \
  --clip-rows 0 --workload symbols-shaped \
  --baseline-core <scratch>/pre-d1/TerminalCore \
  --candidate-core <repo>/lib/TerminalCore
```

Both `--*-core` paths must be absolute: SwiftPM resolves the generated
manifest's path dependency from the build's scratch directory, so a relative
path fails to resolve.
