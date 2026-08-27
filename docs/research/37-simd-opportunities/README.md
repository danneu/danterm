# SIMD opportunities

Research started: 2026-08-26.

- [findings.md](findings.md) -- the ranked survey (`F1`): 22 verified sites, the
  top 8 written up, the "not worth it" list, cross-cutting notes, corrections.
- [decisions.md](decisions.md) -- the decision log.
- [verifier-output.json](verifier-output.json) -- raw per-candidate reviews and
  the 64 finder rejections the survey was synthesized from.

## Purpose

There is no SIMD anywhere in the tree. This doc owns the question of where
explicit SIMD (stdlib `SIMD*` types, Accelerate) or auto-vectorization would
pay, ranked by impact x confidence, so that each site is either tried against
the benchmark ladder or rejected once with a reason.

## Investigation rules

- A site is not a win until `just benchmark-quick baseline=HEAD workload=<w>`
  clears the frozen threshold for that workload
  ([agent-docs/measurement-discipline.md](../../../agent-docs/measurement-discipline.md)).
- When a non-SIMD alternative deletes the pass instead of accelerating it
  (`F1` section 4 lists six), try the deletion first; SIMD on a pass that
  should not exist is rejected.
- Check the data layout before writing lane math: the retained arena is packed
  `UInt64` (8 cells per `SIMD8<UInt64>`); live `GridRow` is a 16-byte-stride
  struct with 2 bytes of padding (4 cells per register, odd lanes must be
  masked). `F1` section 4.
- Shapes in `TerminalCore` use stdlib `SIMD*` types and libc only, so they build
  on Linux. Accelerate, `simd`, and `memset_pattern16` are Darwin-only and stay
  in `TerminalRenderExecution` or behind a `#if canImport` fallback.
- `terminal-feed` has no on-CPU instrument (`17/F2`); size feed-path sites with
  `just benchmark-feed-sample` before implementing.
- A frame name says which code is on the stack, not which work would vanish if
  that code were spelled differently. `F1` scored candidates from frame names and
  `F3` predicted a win from them; `F4` refuted the prediction by measuring. Trace
  the rewrite, do not reason from the profile of the original.
- `benchmark-quick`'s 2 pairs cannot adjudicate a change of a few percent on this
  host: `F4` got `slower (+8.81%)` and `faster (-6.22%)` from the same pair of
  arms, against a 3.5-point rule. Use `benchmark-confirm`, or accept that the
  ladder has no verdict for the change and say so.

## Trigger and current evidence

A single-agent pass proposed five SIMD sites (parser ground-run scan, blank
fill, row scans, UTF-8 validation, style-run coalescing). A 55-agent workflow
(6 area finders, 2 lenses per candidate, one synthesizer; read-only, no
benchmarks run) produced `F1`. Its verdict on the seed list: the ground-run
scan is the most vectorizable loop in the tree but under 1% of feed time; blank
fill is a `memset`, not SIMD; "row scans over contiguous UInt64" is true of the
arena and false of `GridRow`; UTF-8 validation only matters on
`synchronized-frames`, which has no verdict rule; style-run coalescing is
closure-bound, not compare-bound.

Provenance caveat: every impact score is reasoned from existing profiles
(docs 10, 17, 18, 28, 31, 33), several of them stale by one or two
representation changes. Nothing in `F1` is a measurement.

## Current hypotheses

### H1 -- `appendCells` is the only site with a double-digit self share

RESOLVED by `F2`, against the hypothesis as worded and for its competing
explanation. Self is 6.35%, not double-digit; 17.69% is the inclusive figure.
The competing explanation won outright: copy-on-write and bounds checks under
the function cost 8.99% of total CPU, more than its own self time, and both are
removable without lanes. The scalar rewrite lands first, and the kind compare is
judged only on what a post-rewrite trace still shows.

### H2 -- `eraseCells` is a memset whose size no current profile shows

RESOLVED by `F2`, but not as posed: no current profile shows it because no
calibrated workload calls it. `full-screen-content-churn` overwrites every cell
with printable text and emits no erase; the only timed EL in the whole stimulus
set is one row per update on `localized-draw-acceptance`, worth 0.061%. `F1`'s
supporting evidence was also misattributed -- the large `memset_pattern16` share
on both big traces is `CGBlt_fillBytes`, CoreGraphics background fill, not the
grid. Site is at `Terminal.swift:5442`, not `:5477`.

## Candidate direction, pending evidence

Narrowed by `F2`, `F3`, `F4` and `D1`, and no longer in `F1`'s rank order.
`admissionExtent` (rank 4) is the largest single item at a stable 5.04-5.19% of
`scrollback-stream` CPU, and `F4` established that nothing local to its loop
reaches that cost -- so the maintained `contentEnd` deletion is the only form
this rank has, and its open design question (can the fill boundary be maintained
when an erase moves it backwards?) has to be answered before any code. The
`appendCells` identity-run hoist is vetted at -2.38 points and ready to
implement (`F5`); its sibling chunk-pointer hoist is rejected, and the blocked
kind compare stays deferred behind a post-rewrite trace.
The ASCII run scan is a clean `SIMD16<UInt8>` exercise but is expected to land
under the `terminal-feed` threshold. `eraseCells` and `moveAndFillCells` left
this list at `D1` -- no calibrated workload reaches either. The glyph raster
(rank 3) is a rasterizer rewrite; it belongs in doc 18's ladder, not here.

## Task ledger

### Phase 1 -- size the top sites

- [x] `appendCells`: traced `scrollback-stream`; 6.35% self, 17.69% inclusive,
  and 8.99% of total CPU in COW and bounds checks under it. `F2`. DONE
- [x] `eraseCells`: no calibrated workload calls it; the one that reaches the
  site at all costs 0.061%. `F2`. DONE
- [x] Decision gate `D1`: rank 1 kept as a scalar rewrite, rank 4 kept, ranks 2
  and 6 rejected for want of a workload, rank 5 held. DONE

### Phase 2 -- implement gated by the ladder

- [ ] `appendCells` scalar rewrite: `withUnsafeMutableBufferPointer` over the
  arena chunk, and the open identity run in local variables instead of
  `openIdentityRuns[count - 1]`. Gate on `scrollback-stream`. TODO
- [ ] `appendCells` blocked kind compare -- only if a post-rewrite trace still
  shows compare-shaped cost. TODO
- [ ] `admissionExtent` (`F1` rank 4) -> maintained `contentEnd`, the deletion.
  `F3` sizes the pass at 5.04% and `F4` confirms 5.19% on a second trace. Open
  question first: the fill boundary can move backwards on erase and style
  change, so decide whether it is maintainable or only relocates the rescan.
  `F4` closed the local alternatives, so this is the whole rank. RESEARCH
- [x] `admissionExtent` reverse scan -> plain `while` loop. Written, measured,
  reverted: it removes both witness frames and none of the cost, which
  reappears as bounds checks and kind decoding. `F4`. REJECTED
- [ ] ASCII ground-run scan -> `SIMD16<UInt8>`; keep only if `terminal-feed`
  clears 2.5%. TODO

### Phase 3 -- what the ladder cannot see

- [ ] A calibrated workload that emits ED, EL and scroll-region moves. It is the
  prerequisite for ranks 2 and 4, and `D1` rejected both without it. RESEARCH
- [ ] `recoverClusterContextFromGridIfNeeded`: 0.89% of `scrollback-stream` CPU
  in `memmove`, named by no `F1` rank. Decide whether it is a pass to delete.
  RESEARCH

## Rejected

`F1` section 3 holds the full list (ranks 9-22 plus 64 finder rejections), each
with its reason. Headline rejections so they are not re-proposed:

- TerminalDamage bitwords, sprite geometry, color resolution: off the profile or
  computed once.
- Control-string absorb (`EscapeAbsorber.swift:357`): zero payload bytes across
  all 17 MB of corpus.
- Curly underline `sin`: no workload emits SGR 4:3; an integer LUT beats SIMD.
- Glyph position ramp: tried as 18/L4, measured 2.5%, reverted.
- `eraseCells` and `moveAndFillCells` (`F1` ranks 2 and 6): rejected at `D1`, not
  on cost but on visibility -- neither appears in any calibrated workload's
  profile, so no threshold can be cleared. Reopening needs a workload that emits
  erase and scroll-region sequences first (Phase 3).
- SIMD UTF-8 validation: Swift stdlib SIMD has no byte shuffle, which simdutf
  is built on; the DFA is a serial recurrence; only `synchronized-frames`
  carries the content.

## Open questions and caveats

- No calibrated workload searches, selects, resizes, or drives PTY input, so
  ranks 9, 15, 21 cannot be measured by the ladder.
- Swift SIMD lacks movemask / first-true-lane; the portable idiom is a bitcast
  to `UInt64` plus `trailingZeroBitCount >> 3`. Three finder shapes used APIs
  that do not exist.

## Outcome

Investigation in progress. Phase 1 is done: the survey's top-ranked SIMD site
turned out to be a scalar copy-on-write problem worth ~8.7% of `scrollback-stream`
CPU, and its second and fourth ranks turned out to be unreachable by the benchmark
ladder. No SIMD has been written, and none is currently the next action.
