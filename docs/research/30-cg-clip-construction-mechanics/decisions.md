# Decisions -- CG clip construction mechanics

Each decision names its findings, its candidate shape, and a gate frozen
before the first comparison result for that candidate is read. States follow
the ledger vocabulary: VETTING (proposal awaiting evidence), ACTIVE, DONE,
REJECTED.

## D1 -- one `clip(to:)` call over dirtyRect-clamped span rects [VETTING]

Depends on: F2, F3, F5, F6.

**Candidate.** In `SwiftTerminalSessionView.draw(_:)`, replace the
`beginPath()` / per-span `addRect` / `clip()` sequence *and* the subsequent
`clip(to: dirtyRect)` with:

1. build `[CGRect]` from the maximal spans, each intersected with
   `dirtyRect` (drop empty results);
2. one `context.clip(to: rects)` call before the background fill.

Region algebra in F6 shows this produces the identical clip to today's two
stacked clips. F2/F3 show the call is bit-identical CG work for >= 2 rects
and upgrades the 1-rect case (more likely after clamping) to the path-free
`CGGStateClipToRect` route.

**Expected benefit.** Strictly simpler draw path (one clip-stack entry, no
manual path management, fewer bridged calls); possible small win on
single-span partial draws. The win is not required for adoption.

**Risks.** Behavioral: an intersection bug could under- or over-clip --
pinned by the drawn-row-set UI tests and the two-distant-row acceptance
stimulus. Edge case: all clamped rects empty (damage entirely outside
`dirtyRect`) must clip to empty, not skip clipping; `clip(to: [])` semantics
must be verified against an explicit empty-rect fallback while implementing.

**Frozen gate.** Run `just test` + `just test-ui`, then candidate vs its
parent on `incremental-mixed`, `synchronized-frames`, and both 29/F6
acceptance stimuli (two-distant-row, 17-span endpoint).

- Any `slower` verdict or test failure: REJECTED, revert, record.
- Otherwise (all `equivalent`, or any `faster` with none slower): adopt.
  Classify honestly in the outcome: "simplification, measured equivalent"
  unless a workload actually answered `faster`.

**Falsifies the recommendation.** A `slower` verdict on
`synchronized-frames` would mean the clamped multi-rect path costs more than
the stacked clips somewhere unmodeled -- that result must be attributed, not
argued away, before any retry.

## D2 -- derive spans from the bitset; drop the Set round-trip [VETTING]

Depends on: F7. Begin only after D1 is decided (unentangled measurement).

**Candidate.** Keep damage in ordered form end to end: either `TerminalDamage`
carries `[Range<Int>]`/bitset words, or `drain()` emits spans directly. Halo
expansion moves to word shifts with cross-word carries. Deletes
`terminalDamageMaximalContiguousSpans`'s sort, the per-draw allocations, and
the dead `Int.min` guard in `terminalDamageMaximalContiguousSpanCount`.

**Expected benefit.** Simplification only. The deleted work is nanoseconds at
viewport scale; no performance claim is made and none may be reported without
a `faster` verdict.

**Risks.** `TerminalDamage.rows: Set<Int>` is public within `TerminalCore`
and asserted by core tests; the representation change ripples into the halo
helper, the benchmark topology accounting, and test fixtures. If the diff
stops being a net simplification, that is the rejection reason -- record the
diff shape that killed it.

**Frozen gate.** `just test` green, then candidate vs parent on
`terminal-feed` and `incremental-mixed`.

- Both `equivalent` AND the diff judged a net simplification (fewer
  concepts/conversions, not merely different ones): adopt.
- Any `slower` verdict: REJECTED (would be genuinely surprising; attribute
  before concluding).
- `faster`: adopt and report the measured verdict, nothing more.

## D3 -- verify device-pixel alignment of clip edges [VETTING, verify-only]

Depends on: H4; produces F10.

**Candidate action.** No code change proposed. Locate where
`TerminalRenderMetrics.cellSize` is computed, confirm whether
`cellSize.height * backingScaleFactor` is integral at 1x and 2x, and record
the answer with citations. If integral: close as verified, noting the
invariant that keeps rect clips antialiasing-free. If fractional: open a new
task with its own gate -- alignment changes move glyph geometry and need the
full draw-workload ladder plus visual verification, which is beyond this
doc's scope.

## D4 -- instrumentation changes carry their own non-degradation gate [ADOPTED as standing rule]

Depends on: F8. Not a code-change candidate; this is the frozen gate any
future benchmark/profiling improvement made under this doc must pass before
it lands. It exists because the measurement system is also code on the app's
hot path, and an instrument that slows the app corrupts both the app and
every number the instrument reports.

**The gate.** An instrumentation change is acceptable only if all of:

1. **Production stays clean.** All new observer code is reachable only under
   `#if DANTERM_TERMINAL_BENCHMARK` (or lives in files only benchmark builds
   compile). Verify by building `just build-optimized` and confirming the
   change contributes nothing to it -- the flag is passed only by
   `scripts/terminal-benchmark.sh`.
2. **Verdict runs stay unperturbed.** Per-draw or per-frame accounting added
   for profiling visibility is gated so it no-ops when
   `DANTERM_TERMINAL_BENCHMARK_ACTIVITY_PATH` is unset/empty -- the state of
   every `faster`/`slower`/`equivalent` comparison run. If a new signal must
   run during verdict blocks (i.e. it changes what the benchmark itself
   records), it needs an A/A check: `just benchmark-quick baseline=<parent>
   workload=incremental-mixed` comparing the tree with and without the
   instrumentation change must answer `equivalent`.
3. **The draw path never does IO.** Snapshot/artifact writes belong to the
   timer publisher (`publishActivity`) or to block boundaries, never to
   `observeCompletedDraw` or anything `draw(_:)` calls synchronously.
4. **Arms stay symmetric.** The instrumentation change lands as its own
   commit, never inside a measured candidate's diff, so later comparisons can
   place both arms on the same instrumentation code (F8's cross-arm hazard).

**Falsifies the rule's sufficiency.** A profiling run whose activity-gated
accounting visibly shifts whole-process CPU attribution (e.g. the histogram
subtree appearing in a profile at more than noise level) would mean gate 2's
scope is too narrow and profiling runs need their own A/A bound; record that
evidence under a new finding before tightening.

## Rejected

- **R1 -- delete `clip(to: dirtyRect)` outright, relying on AppKit's
  pre-clip.** The AppKit statements in F6 are not written for the
  layer-backed backing-store path, 29/F2 already caught AppKit degrading
  region information on this exact view, and the clip carries a real
  double-blend guarantee. D1's fold achieves the same reduction without
  trusting undocumented behavior.
- **R2 -- per-span draw passes under single-rect clips.** Trades one
  multi-rect clip for N full render passes; 29/F5's 17-span endpoint showed
  the multi-rect clip does not need rescuing.
- **R3 -- remove the CG clip in favor of `clipFramePlan` scoping alone.**
  Antialiased glyph overhang at halo boundaries would double-blend over
  pixels whose background was not refilled. Correctness bar, not a
  performance judgment.
- **R4 -- span-count threshold fallback.** Settled in 29/H3 under a frozen
  rule; inherited, not reopened.
