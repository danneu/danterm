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
- [x] DROPPED 2026-08-05: collect `damageTopology` histograms from three
      stimuli to weight H1's expected impact. It gated nothing -- D1 was
      adopted on its own measured gate -- and F9 makes it moot for
      attribution: this session's drift on untouched code exceeded the effect
      the histogram would have weighted, so a `spans=1` share could not settle
      where `incremental-mixed`'s win came from. Reopen only alongside an
      attribution instrument that can resolve it.

### Phase 2 -- D1: single `clip(to:)` call with dirtyRect-clamped spans

- [x] Implement D1 on top of parent `b6556f1c`; the diff is `draw(_:)`, one new
      private `spanClipRects` helper, and the two UI tests.
- [x] `just test` (74/74) and `just test-ui` (207/207) green, including the
      drawn-row-set tests and two new clip-region tests (F9).
- [x] `just benchmark-quick baseline=b6556f1c workload=incremental-mixed` --
      printed `faster` at -4.23%, which is **inside** that cell's 4.9-point A/A
      reading rule (31/F18) and so resolves nothing. Not a win.
- [x] `just benchmark-quick baseline=b6556f1c workload=content-churn` --
      inconclusive, -2.04%, likewise inside its 2.2-point rule. Substituted for
      `synchronized-frames`, which doc 23/F9 demoted and the harness now rejects
      outright; the substitution was frozen in decisions.md before its result
      was read.
- [x] Acceptance pair via `scripts/terminal-draw-acceptance.py`, candidate vs
      parent: the shipped single-span stimulus and the 17-span endpoint (a
      temporary stride-four producer applied identically to both arms, then
      reverted). Both favorable in direction and inside session drift (F9).
- [x] Apply D1's frozen rule: adopted as a **simplification with measured
      non-regression** -- no `slower` verdict anywhere, and no resolvable win
      either. Verdict and classification recorded in decisions.md.

### Phase 3 -- D2: bitset/range-native span derivation

- [x] **REJECTED 2026-08-05, unmeasured**, on the diff-shape clause of its own
      gate; the benchmark steps below were never reached and are struck. The
      sort cannot be deleted narrowly -- the halo and the cross-publish
      `formUnion` both destroy ordering before it reaches the span helper, so
      the only version that works is the full bitset rewrite, which is a
      different implementation rather than a simpler one. Reasoning in
      decisions.md/D2.
- [x] Deleted the unreachable `Int.min` guard, the one piece worth taking, and
      pinned the negative-row invariant it rested on (that invariant was
      untested, which was the real finding).
- [x] `just test` green (74/74).
- ~~`just benchmark-quick baseline=<parent> workload=terminal-feed`~~ -- not
      run; no candidate to measure.
- ~~`just benchmark-quick baseline=<parent> workload=incremental-mixed`~~ --
      not run; and per F9 it could not have resolved this change's size anyway.

### Phase 4 -- verify H4 and close

- [x] Record where cell metrics are computed, whether device-space cell
      height is integral at 1x and 2x, and cite the code. DONE 2026-08-05:
      integral at every scale factor by construction (F10); D3 closed as
      verified with no code change.
- [x] DROPPED 2026-08-05: `just benchmark-confirm baseline=<pre-doc-30
      revision>` as the closing all-workload measurement. It cannot decide
      anything about what landed. F9 establishes that this ladder's noise floor
      exceeds any effect the mechanisms in F2--F5 predict -- `incremental-mixed`
      needs >4.9 points to speak (31/F18), roughly 20x the predicted effect --
      and the only two changes that landed are a region-identical clip fold
      (`c4fc65f7`, already measured against its parent on two calibrated
      workloads plus both span-count acceptance endpoints) and the deletion of
      an unreachable branch (`f31e1d77`, provably zero-effect). A confirm run
      would spend the ladder to print numbers no one may read. Reopen only
      behind an instrument that can resolve the effect (see `## Outcome`).
- [x] CG clip-mechanics lesson: **not graduated as a dispatch map.** F2--F4 are
      disassembly pinned to one OS build and specific to this one call site, so
      they stay here. The one durable, API-contract-level sentence they support
      -- prefer a single `clip(to: [CGRect])` over a manual
      `beginPath()`/`addRect`/`clip()` loop, since rect clips and path clips are
      separate routes in CoreGraphics and a one-rect list takes the path-free
      one (F1, F2, F3) -- is *recommended* for
      `agent-docs/terminal-performance.md`, not applied here.
- [x] Write `## Outcome`. DONE 2026-08-05.

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

- ~~Does the `spans=1` share differ enough across stimuli that H1's fast path
  matters in practice, or is this purely the simplification case?~~
  **Answered for this doc's purposes: purely the simplification case (F9).**
  Not because the share was measured -- the histogram task was dropped -- but
  because the available instruments cannot resolve an effect of the size any
  mechanism in F2--F5 predicts. `incremental-mixed` needs >4.9 points to speak
  (31/F18); the acceptance stimuli drift by more than the effect on untouched
  code. The share would only weight an impact nothing here can detect. This
  reopens only behind a new instrument.
- Is AppKit's pre-clip of the drawing context to the update region reliable
  enough on layer-backed views to *ever* rely on, or should DanTerm keep
  treating it as undocumented behavior? F6 records the doc-quote evidence
  either way; D1 deliberately does not depend on the answer.

## Outcome

Closed 2026-08-05. One change shipped, one candidate rejected, one invariant
verified, one standing rule adopted.

**The arc.** F1--F5 established the mechanics: CoreGraphics treats rect clips
and path clips as separate routes, `CGContextClipToRects` auto-dispatches a
one-rect list to the path-free `CGGStateClipToRect` road (F2, F3), no rect-list
clip exists on the path route (F4), and the shipped `beginPath()`/`addRect`/
`clip()` loop therefore always took the generic route while stacking a second
`clip(to: dirtyRect)` on top of it (F5, F6). That produced three candidates.

- **D1 -- shipped** (`c4fc65f7`): one `clip(to:)` call over span rects already
  intersected with `dirtyRect`, replacing both stacked clips. The region is
  identical by construction (F6); the second clip's double-blend guarantee
  becomes structural instead of a separate clip-stack entry; an empty clamped
  rect list falls back to an explicit `clip(to: .zero)`. Adopted on the
  *simplification* route, not the measured-improvement one (F9).
- **D2 -- rejected**, unmeasured, on its own gate's diff-shape clause. The
  narrow version does not exist: the halo and the cross-publish `formUnion`
  both destroy ordering before it reaches the span helper, so the only version
  that works is the full bitset rewrite -- a different implementation, not a
  simpler one. Only the unreachable `Int.min` guard was taken (`f31e1d77`),
  along with the test that pins the negative-row invariant it rested on.
- **D3 -- verified, no code change** (F10): metrics quantize to whole device
  pixels and *then* divide by the scale, so `cellSize.height * displayScale` is
  integral at every scale factor and no clip edge can fall into antialiased
  coverage. The invariant to preserve is the ordering: quantize first, divide
  second.
- **D4 -- standing rule**, not a change: the four-part non-degradation gate any
  future benchmark/profiling change must pass (production compile-out,
  verdict-run no-op, no draw-path IO, arms symmetric). It outlives this doc.

**No performance claim, on any workload or stimulus.** The harness printed
`faster` at -4.23% on `incremental-mixed`; that string is recorded in F9 only
because it is what the instrument printed. 31/F18 calibrated that exact cell on
this host one commit before D1's parent and found it the worst-resolved on the
ladder -- a -4.43% `faster` and a +4.85% `slower` on byte-identical source, for
a reading rule of 4.9 points. `content-churn`'s -2.04% is likewise inside its
2.2-point rule, and F9's independent plan-time control (untouched code moving
-5.2%) says the same about the same session. **Re-running the same ladder cannot
produce a win here**, which is why Phase 4's closing `benchmark-confirm` was
dropped rather than run: it would spend the ladder to print numbers no one may
read. What the measurements do establish -- the absence of a resolvable
regression at both span-count endpoints -- is all D1's gate needed.

**Caveats that stay live.**

- Whether AppKit's pre-clip of the drawing context to the update region is
  reliable on layer-backed views is still unanswered (see Open questions). D1
  deliberately does not depend on it, and R1 refuses to.
- F2--F4 are local disassembly pinned to **macOS 26.5.2 (25F84), arm64**. Re-verify
  on a new macOS major before citing them as current; the reproduction recipe in
  findings.md F2 makes that a five-minute check.

**Reopening condition.** Not by re-running this ladder. H1's magnitude -- how
much the single-rect fast path is actually worth -- needs a *different*
instrument, one that can resolve roughly 1/20th of `incremental-mixed`'s reading
rule. And before the many-span route is measured again, promote F9's 17-span
stride-four stimulus into
`scripts/terminal-benchmark-producer.py#run_localized_draw_workload` rather than
hand-patching two trees a third time; the shipped producer writes one row per
update and exercises the single-span route only. D2 reopens only if the damage
representation is being changed for another reason and the ordered form falls
out for free -- never for the sort alone.
