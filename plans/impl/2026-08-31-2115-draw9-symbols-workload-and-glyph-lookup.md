# DRAW-9: nominalGlyph allocations + a symbols-shaped draw workload

## Context

Audit finding DRAW-9 (docs/scratch/2026-08-26-improvement-audit.md, rescored)
targets the packaged-symbols draw path in
`lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift`.
Every private-use cell that reaches the packaged symbols face pays, per redrawn
frame: a live `CTFontGetGlyphsForCharacters` inside `TerminalFace.nominalGlyph`
(which also heap-allocates two arrays per call for at most 2 UTF-16 units), and
a live `CTFontGetBoundingRectsForGlyphs` inside `drawPackagedSymbol`.

The audit's own correction rejected the originally proposed eager
whole-coverage glyph table: ~340KB per metrics instance to save tens of
microseconds is the trade `agent-docs/measurement-discipline.md` exists to
refuse. The rescored action (audit line 427) is the ideal here: delete the two
per-call allocations, and only then measure whether a coverage-built table is
worth its memory. No workload on the benchmark ladder reaches this path today
-- `btop-shaped` never leaves the sprite path, `text-shaped` stays on the
batched ASCII path, and `fallback-shaped` (commit 35847043) exercises
`drawTextCell` CTLine shaping, not the symbols path -- so the measurement
needs a new workload. The DRAW-3 blocker is resolved: the headless draw arm is
the `HeadlessDrawArm` target and `just benchmark-headless-draw` runs.

Desired outcome: the allocation cost is gone, the symbols path is priceable on
the existing paired-arm harness, and the table-vs-live-calls question is
answered by a recorded measurement instead of staying open.

## Decision

- **D1.** Rewrite `nominalGlyph` to use fixed-size storage for its UTF-16
  units and glyphs. A `Unicode.Scalar` encodes to at most 2 units, so no
  per-call heap allocation is needed.
- **D2.** Add a `symbols-shaped` workload to the headless draw benchmark,
  following the `fallback-shaped` precedent end to end: generator in
  `TerminalDrawBenchmarkSupport` with a byte-equivalent copy in
  `HeadlessDrawArm/Arm.swift`, a new workload index the arm refuses when
  unknown, driver plumbing in `scripts/terminal-headless-draw-compare.py` and
  the `justfile`, and a note in `agent-docs/terminal-performance.md`.
- **D3.** Answer the coverage-table question with two paired comparisons,
  each measuring only the thing it changes:
  - **D3a.** Pre-D1 vs D1 on `symbols-shaped`: the cost of the two deleted
    allocations, and nothing else.
  - **D3b.** D1 vs an experimental coverage-built glyph-plus-bounds table
    (built from `CTFontCopyCharacterSet`'s real coverage, on a throwaway
    branch, never shipped by this plan): the cost of the two remaining live
    CoreText calls, recorded beside the table's retained memory.
- **D4.** The measurement artifact must carry the absolute per-draw delta and
  the workload's icon-cell count, so the per-icon-cell cost is read from the
  instrument rather than reconstructed outside it. The absolute delta is
  subject to the same slot bias the percentage estimate already cancels
  (the driver's own docstring records -1.797% one way, +0.101% the other),
  so it must be the antisymmetric estimate across the forward and reversed
  runs, with the absolute order bias reported beside it -- never a
  one-direction difference. The compare driver's report today keeps only
  paired percentages, so its envelope grows these fields.

## Invariants

- **I1.** `nominalGlyph` resolves the same glyph as before for every scalar in
  all three private-use ranges, including planes 15 and 16, with no heap
  allocation per call.
- **I2.** Rendered private-use cells are visually unchanged: the existing
  `NerdFontSymbolsExecutionTests` bitmap coverage stays green.
- **I3.** Every cell in the `symbols-shaped` workload reaches the
  packaged-symbols path: single private-use scalar, unmapped by the base
  face's cmap, outside every sprite family's coarse range (E0B0-E0D4 and
  F5D0-F60D are sprite-claimed), and mapped by the packaged face. A cell that
  misses any of these measures a different path and invalidates the workload.
- **I4.** The arm refuses to prepare the `symbols-shaped` workload when the
  packaged symbols face is unavailable in its process
  (`PackagedSymbolsFace.face(pointSize:)` is the public probe), rather than
  silently timing the CTLine fallback. The arm loads as a dylib into the
  compare driver's process, where the SwiftPM resource bundle -- not
  `Bundle.main` -- must supply the font; absence must be a refused prepare,
  not a wrong number.
- **I5.** The arm's generator stays byte-equivalent to the
  `TerminalDrawBenchmarkSupport` copy, like the three existing workloads.
- **I6.** `btop-shaped` and `text-shaped` never reach the symbols path, so no
  behavioral movement is expected from D1; their comparisons are negative
  controls, not equivalence proofs (no frozen rule exists for them, and the
  driver reports uncalibrated workloads as descriptive).

## Proof obligations

- **PO1** (I1): a test resolving representative scalars from each private-use
  range through `nominalGlyph` against a direct
  `CTFontGetGlyphsForCharacters` call on the same face.
- **PO2** (I2): existing packaged-symbol bitmap tests, unmodified.
- **PO3** (I3): a test asserting each workload scalar is private-use, outside
  every sprite coarse range, unmapped by the metrics base face, and mapped by
  the packaged face.
- **PO4** (I4): a test that a prepare with the symbols workload index refuses
  when the packaged symbols face is unavailable. The render module's
  nil-resource seam is internal and not importable by the arm, so the
  implementation adds an arm-owned availability seam and tests refusal
  through it.
- **PO5** (I5): a behavioral parity test that the arm's duplicated workload
  generators produce the same bytes as the `TerminalDrawBenchmarkSupport`
  copies -- no such test exists today (only comments assert it), so this
  covers all four generators, not just the new one.
- **PO6** (D3): both-directions `symbols-shaped` runs for D3a and D3b,
  recorded per `agent-docs/measurement-discipline.md`, plus `btop-shaped` and
  `text-shaped` same-session A/B negative controls whose descriptive results
  are recorded (I6 -- quiet is expected because they cannot reach the changed
  code, not proven by the run).
- **PO7** (D4): a driver test that feeds known synthetic forward/reverse
  durations and proves the reported absolute per-draw delta is the
  antisymmetric estimate with the correct sign, normalized per draw and per
  icon cell, with the absolute order bias carried separately -- presence of
  the fields alone is not enough.

## Non-goals

- Shipping the coverage-built glyph-plus-bounds table. D3b builds it only as
  a throwaway measurement arm; adopting it, if the numbers justify the
  memory, is its own plan. The set would have to come from
  `CTFontCopyCharacterSet`'s real coverage, never the whole private-use area.
- Batching the per-cell `saveGState`/`clip`/`CTFontDrawGlyphs` submission:
  the per-cell fit is by design.
- A draw-time memo on `TerminalFace`: its doc comment already rejects mutable
  state inside a `Sendable` value, and the audit's cheaper-fallback was
  rejected for the same reason.

## Implementation discretion

- The fixed-storage mechanism in `nominalGlyph` (tuple vs
  `withUnsafeTemporaryAllocation` vs manual surrogate split).
- Workload scalar choice and grid layout, within I3's constraints.
- Whether the caller's per-cell `String($0).utf16.count` glyph-index advance
  (same String-allocation pattern, audit-dropped as micro) is swapped for a
  plane test while the code is open.

## Verification

- `swift test --package-path lib/TerminalCore --filter TerminalRenderExecutionTests`
  and `--filter HeadlessDrawArmTests` / `TerminalDrawBenchmarkSupportTests`
  in the edit loop, plus `just lint`.
- `just benchmark-headless-draw <n> --workload symbols-shaped` (and the other
  workloads) for PO6.
- `just test` before each commit; the change touches `justfile` and
  `scripts/terminal-headless-draw-compare.py`, so run `just test-tooling`
  once as well.

## Commit progress

- [x] 1. benchmark(draw): add a packaged-symbol workload and absolute paired costs
- [ ] 2. perf(draw): remove nominal glyph lookup allocations
- [ ] 3. docs(audit): record DRAW-9 measurements and mark it done

## Implementation notes

- Commit 1. The workload's twelve scalars were picked by probing the packaged
  face and the monospaced system face directly: every one maps in the packaged
  face, maps in neither the regular nor the bold base face, and sits outside
  both sprite-claimed private-use ranges. Plane 16 was left out because the
  packaged font maps nothing there, so a plane-16 cell would fall to
  `drawTextCell` and measure the fallback path. Plane 15 covers the astral case
  instead.
- Commit 1. `isPrivateUse` in `TerminalRenderExecution` went from `private` to
  internal so the workload test checks the same condition the draw loop routes
  on. The arm cannot reach it across the module boundary, so its icon-cell count
  repeats the three ranges inline.
- Commit 1. D4's absolute estimate is derived from the direction runs the report
  already carries, rather than passed in beside them, so the percentages and the
  nanoseconds cannot describe different measurements. A single-direction report
  now carries only the raw per-draw differences, which are labelled as raw
  material rather than a result.
- Commit 1. The driver refuses a pair of arms whose surfaces hold different icon
  cell counts: two checkouts that draw different corpora cannot be paired at all,
  and averaging the denominators would hide it.
