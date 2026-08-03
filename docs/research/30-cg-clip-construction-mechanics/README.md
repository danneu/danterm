# CG clip construction mechanics inside the shipped span clip

Research started: 2026-08-03. Continues closed doc
[29-sparse-appkit-damage-clip-topology](../29-sparse-appkit-damage-clip-topology/README.md):
29 settled the *topology* question (maximal contiguous spans, no complexity
fallback, shipped in `f3c774d`); this doc zooms in on the *implementation* of
that clip and the code that feeds it. Inherited boundary: whole-process CPU is
the decision metric for anything Core Animation touches (29/F3), and the
maximal-span topology itself is settled and not relitigated here (29/F5, 29/D1).

- [findings.md](findings.md) -- the evidence chain: Apple header contract,
  CoreGraphics disassembly, WebKit precedent, AppKit dirty-region docs, and the
  upstream damage-representation audit.
- [decisions.md](decisions.md) -- candidate changes, each with a frozen
  adopt/reject gate.

## Purpose

`SwiftTerminalSessionView.draw(_:)` builds the span clip with a manual
`beginPath()` / `addRect` loop / `clip()` sequence, then applies a second
`clip(to: dirtyRect)` before glyph drawing, and derives spans each draw by
sorting a `Set<Int>` that the engine originally produced from a sorted bitset.
This doc owns the question: does any of that leave measurable work on the
table, and where it does not, is there a strictly simpler equivalent?

Two ways a change can be accepted:

1. **Measured improvement** -- a `faster` verdict on at least one applicable
   workload and no `slower` verdict anywhere.
2. **Simplification** -- the change makes the code strictly simpler (fewer
   calls, fewer conversions, less code) and every applicable workload answers
   `equivalent`. Changing code for its own sake is not a goal; simplification
   with proven non-regression is an explicitly acceptable outcome.

Either way, no change lands on vibes: the mechanics findings below predict
direction, the benchmarks decide.

## Investigation rules

Inherited from doc 29, plus the simplification gate:

- Use whole-process CPU for decisions involving Core Animation; the synchronous
  draw timer ends before Core Animation replays the display list (29/F3).
- Freeze each candidate's decision rule in [decisions.md](decisions.md) before
  reading its first comparison result.
- Re-measure each candidate against the parent it forked from; never derive a
  verdict by subtracting comparisons taken under different stimuli.
- A simplification-only candidate requires `equivalent` on every applicable
  workload, not merely "no slower verdict on the one I ran".
- `just test` and `just test-ui` must pass before any benchmark of a candidate
  is treated as meaningful; the sparse-damage UI tests
  (`tests-ui/SwiftTerminalSessionViewTests.swift#swiftTerminalSessionViewTests`)
  pin the exact drawn-row sets.
- Disassembly findings are tied to one OS build (recorded in F2--F4). Re-verify
  on a new macOS major before citing them as current; the reproduction recipe
  in findings.md F2 makes that a five-minute check.
- **Instrumentation changes must not degrade what they measure.** Any change
  to the benchmark/profiling system made under this doc preserves the F8
  posture: compiled out of production builds (`DANTERM_TERMINAL_BENCHMARK`
  flag only), no-op in verdict-producing comparison runs (activity-path
  gated), and no IO on the draw path (timer-owned publishing). D4 holds the
  frozen gate.
- **Measured arms stay instrumentation-symmetric.** Never read a
  whole-process CPU comparison whose arms differ in compiled instrumentation
  code; land instrumentation changes in their own commit so both arms of any
  later comparison carry them identically (F8's cross-arm hazard).

## Applicable instruments

The workload ladder and its rules are in
`agent-docs/terminal-performance.md`; read it before running anything.

| Instrument | What it decides here |
| --- | --- |
| `just benchmark-quick baseline=<rev> workload=incremental-mixed` | The primary gate: 4-row damage on a settled screen is the damage-scoped draw path every candidate touches. |
| `just benchmark-quick baseline=<rev> workload=synchronized-frames` | The btop-shaped workload that caught 29's regression; guards the multi-span route. |
| `just benchmark-quick baseline=<rev> workload=terminal-feed` | Gates upstream damage-representation changes (D2) that touch `drainDamage` before any drawing. |
| `just benchmark-confirm baseline=<rev>` | Final all-workload gate before a candidate is called done. |
| `scripts/terminal-draw-acceptance.py` | The two-distant-row acceptance stimulus from 29/F6 (disjoint spans) and the 17-span every-fourth-row endpoint from 29/F5. |
| Benchmark activity `damageTopology` histogram (added in `f3c774d`) | Weights H1: the observed share of partial draws with `spans=1` under real stimuli. |

## Current hypotheses

### H1 -- single-span partial draws pay for a CGPath they do not need

Proposed mechanism: CoreGraphics has a rectangular clip fast path
(`CGContextClipToRect` -> `CGGStateClipToRect` -> `CGClipCreateWithRect`) that
skips CGPath construction and generic path-clip rasterization entirely, and
`CGContextClipToRects` auto-dispatches to it when `count == 1` (F2, F3). The
shipped loop always builds a path, so even a one-span draw takes the generic
route (F5). Replacing the loop with one `context.clip(to: rects)` call is
predicted equivalent-or-faster, never slower, and is simpler code either way.
Weighting evidence needed: the `damageTopology` histogram share of `spans=1`
draws under typing, scrolling, and btop stimuli. Falsifier: a `slower` verdict
on any applicable workload.

### H2 -- the second `clip(to: dirtyRect)` can be folded into the span clip

Proposed mechanism: intersecting each span rect with `dirtyRect` before a
single `clip(to:)` call produces the identical clip region (union of
per-span intersections) with one clip-stack entry instead of two, and makes
more draws hit H1's single-rect fast path after clamping. Important nuance
found in F6: the second clip is *not* dead code today -- it bounds glyph
drawing to the region whose background the same pass just refilled, which
matters if AppKit ever delivers a `dirtyRect` narrower than the pending damage
spans. The fold preserves that guarantee by construction instead of relying on
AppKit's documented pre-clipping. Falsifier: any drawn-row UI test failure or
a `slower` verdict.

### H3 -- the Set round-trip in span derivation is pure representation waste

Proposed mechanism: `TerminalDamageAccumulator` already holds damage as an
ordered `[UInt64]` bitset; `drain()` explodes it into an unordered `Set<Int>`,
the halo expansion walks the Set, and the view re-sorts it every draw to
recover the order the bitset had for free (F7). Deriving spans (and the halo,
via word shifts with cross-word carries) directly from the bitset -- or having
`TerminalDamage` carry ranges -- deletes the sort, the hashing, and the
allocation. At <= ~100 viewport rows this is nanoseconds, so this is a
simplification candidate, not a performance claim: the gate is `equivalent`
on `terminal-feed` and `incremental-mixed`, with the code strictly simpler.
Falsifier for "strictly simpler": if threading ranges through
`TerminalDamage`'s public API grows the diff beyond what the deleted
conversions justify, reject and record why.

### H4 -- clip rect edges are pixel-aligned in device space

Rect clips are only fully cheap when their edges land on device pixels; a
non-integral `cellSize * backingScaleFactor` would force even rectangular
clips through antialiased coverage. Expectation: the renderer already aligns
cell metrics to the backing scale, making this a verify-and-record task, not a
change. Falsifier: a fractional device-space cell height at any supported
scale factor, which would open a new alignment task.

## Task ledger

### Phase 1 -- mechanics evidence (attribution)

- [x] Disassemble the CG clip entry points and map the dispatch (F1--F4).
      DONE 2026-08-03, macOS 26.5.2 (25F84), arm64.
- [x] Confirm the precedent: WebKit's CG backend and Apple's sample code both
      treat rect clips and path clips as separate routes (F5).
- [x] Audit the in-repo call sites and the upstream damage representation
      (F5, F6, F7).
- [x] Audit the benchmark instrumentation's own cost posture -- production
      compile-out, verdict-run gating, draw-path IO -- and freeze it as the
      bar for future instrumentation changes (F8, D4). DONE 2026-08-03.
- [ ] RESEARCH: collect `damageTopology` histograms from three stimuli
      (interactive typing, `scrollback-stream`-style output, live btop) and
      record the `spans=1` share per stimulus under F9. This weights H1's
      expected impact; it does not gate D1, which is justified as a
      simplification even at zero measured win.

### Phase 2 -- D1: single `clip(to:)` call with dirtyRect-clamped spans

- [ ] Implement D1 (see decisions.md for the frozen gate) on top of a noted
      parent revision; keep the diff to `draw(_:)` and the span helpers.
- [ ] `just test` and `just test-ui` green, including the drawn-row-set tests.
- [ ] `just benchmark-quick baseline=<parent> workload=incremental-mixed`.
- [ ] `just benchmark-quick baseline=<parent> workload=synchronized-frames`.
- [ ] Re-run the 29/F6 acceptance pair: two-distant-row stimulus and the
      17-span endpoint via `scripts/terminal-draw-acceptance.py`, candidate vs
      parent.
- [ ] Apply D1's frozen rule; record the verdict and disposition in
      decisions.md.

### Phase 3 -- D2: bitset/range-native span derivation (begin only after D1
is decided, so the two diffs are never measured entangled)

- [ ] Implement D2; delete `terminalDamageMaximalContiguousSpans`'s sort path
      and the dead `Int.min` guard noted in F7.
- [ ] `just test` green (core suites cover `TerminalDamage`).
- [ ] `just benchmark-quick baseline=<parent> workload=terminal-feed`.
- [ ] `just benchmark-quick baseline=<parent> workload=incremental-mixed`.
- [ ] Apply D2's frozen rule; record verdict and diff-size judgment.

### Phase 4 -- verify H4 and close

- [ ] Record where cell metrics are computed, whether device-space cell
      height is integral at 1x and 2x, and cite the code (F10 when done).
- [ ] `just benchmark-confirm baseline=<pre-doc-30 revision>` over whatever
      landed, as the closing all-workload measurement.
- [ ] Write `## Outcome`, move this doc's index row to `## Closed`, and
      graduate the durable CG clip-mechanics lesson (F2--F4's dispatch map) to
      the guide that owns drawing performance if it proves reusable.

## Rejected ideas

- **Per-span draw passes** (saveGState + single-rect clip + render per span):
  repeats full frame-render overhead per span to buy a rect clip per pass;
  29/F5 already showed the multi-span path clip is acceptable at the 17-span
  endpoint, so the trade buys nothing that needs buying.
- **Dropping the CG clip and relying on `clipFramePlan` alone**: the clip is
  what trims glyph overhang at halo boundaries; without it, antialiased glyph
  edges double-blend over intact pixels outside the refilled background.
  Correctness, not preference.
- **A span-count threshold fallback**: rejected in 29/H3 under a frozen rule;
  nothing here reopens it.

## Open questions

- Does the `spans=1` share differ enough across stimuli that H1's fast path
  matters in practice, or is this purely the simplification case? (Phase 1
  histogram task.)
- Is AppKit's pre-clip of the drawing context to the update region reliable
  enough on layer-backed views to *ever* rely on, or should DanTerm keep
  treating it as undocumented behavior? F6 records the doc-quote evidence
  either way; D1 deliberately does not depend on the answer.
