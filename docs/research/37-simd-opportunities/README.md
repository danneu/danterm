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

`LogicalLineStore.swift:2914`, on the admission path of every scrolled row.
Competing explanation: most of the modelled win is scalar (hoist the open
identity run, store through `withUnsafeMutableBufferPointer`), and the SIMD
kind compare adds little on top. Distinguish by landing the scalar rewrite
first and benchmarking `scrollback-stream` before adding lanes.

### H2 -- `eraseCells` is a memset whose size no current profile shows

`Terminal.swift:5477`. The two profiles that sized it predate two cell
representation changes. Distinguish with `just benchmark-sample content-churn`.

## Candidate direction, pending evidence

Try in this order, each gated by its own benchmark: `appendCells` scalar
rewrite then blocked kind compare (`scrollback-stream`); `eraseCells` as
`memset_pattern16` (`content-churn`); `moveAndFillCells` as `memmove` + fill
(`incremental-screen-updates`); `admissionExtent` replaced by a maintained
`contentEnd` (a deletion, not SIMD). The ASCII run scan is a clean
`SIMD16<UInt8>` exercise but is expected to land under the `terminal-feed`
threshold. The glyph raster (rank 3) is a rasterizer rewrite; it belongs in
doc 18's ladder, not here.

## Task ledger

### Phase 1 -- size the top sites

- [ ] `appendCells`: `just benchmark-sample scrollback-stream` self share at
  HEAD; record in `F2`. RESEARCH
- [ ] `eraseCells`: sample `content-churn`; record in `F2`. RESEARCH
- [ ] Decision gate `D1`: which of ranks 1, 2, 4, 6 clear their threshold on
  paper after `F2`; the rest move to Rejected with the number.

### Phase 2 -- implement gated by the ladder

- [ ] `appendCells` scalar rewrite, then lanes if the scalar win leaves the
  kind compare on the profile. TODO
- [ ] `eraseCells` -> `memset_pattern16`. TODO
- [ ] `moveAndFillCells` -> `memmove` + pattern fill. TODO
- [ ] `admissionExtent` -> maintained `contentEnd`. TODO
- [ ] ASCII ground-run scan -> `SIMD16<UInt8>`; keep only if `terminal-feed`
  clears 2.5%. TODO

## Rejected

`F1` section 3 holds the full list (ranks 9-22 plus 64 finder rejections), each
with its reason. Headline rejections so they are not re-proposed:

- TerminalDamage bitwords, sprite geometry, color resolution: off the profile or
  computed once.
- Control-string absorb (`EscapeAbsorber.swift:357`): zero payload bytes across
  all 17 MB of corpus.
- Curly underline `sin`: no workload emits SGR 4:3; an integer LUT beats SIMD.
- Glyph position ramp: tried as 18/L4, measured 2.5%, reverted.
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

Investigation in progress.
