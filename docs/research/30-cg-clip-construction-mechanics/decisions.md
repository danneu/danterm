# Decisions -- CG clip construction mechanics

Each decision names its findings, its candidate shape, and a gate frozen
before the first comparison result for that candidate is read. States follow
the ledger vocabulary: VETTING (proposal awaiting evidence), ACTIVE, DONE,
REJECTED.

## D1 -- one `clip(to:)` call over dirtyRect-clamped span rects [DONE -- adopted]

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

**Gate amendment, frozen 2026-08-05 before its first result was read.** The
`synchronized-frames` arm of this gate is unrunnable: doc 23/F9 demoted that
workload to a collectable candidate, and `terminal-benchmark-compare.py`
now rejects the name outright, so it can issue no verdict. Its job here was
to guard the multi-span route. `content-churn` -- the surviving verdict
workload whose damage is churn-shaped rather than append-shaped -- takes that
slot, alongside the 17-span acceptance endpoint that already covers the
many-span topology directly. Same disposition rules apply to the substitute:
any `slower` verdict is a rejection.

- Any `slower` verdict or test failure: REJECTED, revert, record.
- Otherwise (all `equivalent`, or any `faster` with none slower): adopt.
  Classify honestly in the outcome: "simplification, measured equivalent"
  unless a workload actually answered `faster`.

**Falsifies the recommendation.** A `slower` verdict on
`synchronized-frames` would mean the clamped multi-rect path costs more than
the stacked clips somewhere unmodeled -- that result must be attributed, not
argued away, before any retry.

**Outcome (2026-08-05, evidence in F9).** Adopted. Gates green (74/74, 207/207);
`incremental-mixed` printed `faster` at -4.23%; `content-churn` inconclusive at
-2.04%; both span-count acceptance endpoints favorable in direction. No `slower`
verdict anywhere, so the frozen rule adopts.

Classified honestly, per this gate's own instruction: **simplification, measured
non-regression.** The `faster` string does *not* promote this to a measured
improvement. Doc 31/F18 calibrated `incremental-mixed` on this host one commit
before this candidate's parent and found it the worst-resolved cell on the
ladder -- it returned both a -4.43% `faster` and a +4.85% `slower` verdict on
byte-identical source, giving a reading rule of 4.9 points. This candidate's
-4.23% is inside that. `content-churn`'s 2.04% is likewise inside its 2.2-point
rule. F9's independent plan-time control on the acceptance runs says the same
thing about the same session.

D1 therefore lands on the gate's second acceptance route (simplification with
proven non-regression), which the README declares an explicitly acceptable
outcome. **No performance claim may be made for this change, and re-running the
same workloads cannot produce one.**

The empty-clamped-rect edge case named under **Risks** resolved as predicted: an
empty rect list is possible when damage misses `dirtyRect` entirely, and
`clip(to: [])` has no documented clip-out-everything guarantee, so `draw(_:)`
falls back to an explicit `clip(to: .zero)`.

## D2 -- derive spans from the bitset; drop the Set round-trip [REJECTED]

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

**Outcome (2026-08-05). REJECTED, unmeasured** -- rejected on the diff-shape
clause of the gate above, which does not require a measurement to apply. Only
the `Int.min` deletion was taken, separately (see below).

**Why the cheap version does not exist.** The intermediate this decision was
nearly narrowed to -- "have `drain()` emit ordered rows so the view's per-draw
`sorted()` disappears, without changing `rows`'s type" -- was traced and does
not work. Two order-destroying steps sit between drain and the sort:

1. `SwiftTerminalSessionView#publish` runs the glyph halo on every published
   frame, and `terminalDamageRowsWithGlyphHalo` returns a `Set<Int>`.
2. Its result is `formUnion`'d into `pendingDisplayDamage`, which **accumulates
   across several publishes** before one draw consumes it.

So `terminalDamageMaximalContiguousSpans`' sort runs over an accumulated,
haloed set, never over what `drain()` produced. Ordering created at drain is
discarded twice before reaching it -- and with `rows` typed `Set<Int>` there is
no order to emit in the first place. Deleting that sort therefore requires an
ordered merge at the *accumulation* point (bitset words, word-wise OR), which
is D2 in full. The narrow version buys nothing; there is no middle.

**Why the full version is not worth it.** It trades a readable Set/sort loop for
word shifts with cross-word carries, changes a type that is public within
`TerminalCore`, and ripples into the halo helper, the benchmark topology
accounting, and test fixtures -- to delete work that is O(n log n) on n <= ~100
rows, once per partial draw. That is a different implementation, not a simpler
one, which is exactly the disposition this gate's **Risks** clause names. F9
adds the measurement-side reason it could never be justified empirically
either: `incremental-mixed` cannot resolve a difference below ~4.9 points
(31/F18), so no run of this ladder could show the deleted work mattering.

**What was taken.** `terminalDamageMaximalContiguousSpanCount`'s `Int.min`
guard is deleted, since F7 correctly established it unreachable. The invariant
it rested on -- `TerminalDamage` filters negative indexes, `rows` is
`private(set)` -- was itself untested, which was the real gap; it is now pinned
by `TerminalDamageTests#negativeRowsCannotEnterDamage` and cited from the
helper, so removing the filter fails there instead of becoming an overflow trap.

**Reopen only if** the damage representation is being changed for another
reason and the ordered form falls out for free. Do not reopen this for the
sort.

## D3 -- verify device-pixel alignment of clip edges [DONE -- verified, no change]

Depends on: H4; produces F10.

**Candidate action.** No code change proposed. Locate where
`TerminalRenderMetrics.cellSize` is computed, confirm whether
`cellSize.height * backingScaleFactor` is integral at 1x and 2x, and record
the answer with citations. If integral: close as verified, noting the
invariant that keeps rect clips antialiasing-free. If fractional: open a new
task with its own gate -- alignment changes move glyph geometry and need the
full draw-workload ladder plus visual verification, which is beyond this
doc's scope.

**Outcome (2026-08-05, F10).** Integral, and at every scale factor rather than
just the two checked: metrics quantize to whole device pixels first and derive
the point-space cell size by dividing by the scale. Closed as verified; no
follow-up task opens.

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
