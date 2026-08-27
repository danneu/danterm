# Findings

### F1 -- ranked SIMD candidate survey

- Status: complete (reasoned, not measured).
- Date and investigator: 2026-08-26, 55-agent workflow (6 finders, 2 lenses per candidate, 1 synthesizer), read-only.
- Commit and worktree state: 93bf2c70, clean tree.
- Uncertainty: every impact score derives from existing profile docs, several stale by one or two cell representation changes; nothing here is a benchmark result.
- Next action: Phase 1 sampling into `F2`.

Scope: verified candidates only, plus the merged finder rejection list. Scores are the impact
reviewer's (0-10) and the confidence/feasibility reviewer's (0-10) as returned; product = impact x
confidence, ties broken by confidence. Line numbers below are the corrected ones (I re-read the
contested sites; see section 5).

Two pairs of verified entries are the same site found twice and are merged into one row each:
the ASCII ground-run scan (TerminalInputStream.swift:87 and :99, both really :85) and the curly
underline sine loop (TerminalRenderExecution.swift:1573, submitted twice).

## 1. Ranked table

Portability: every shape below is stdlib `SIMD*` or libc `memset`/`memmove`, and so
builds on Linux, except: rank 2 names `memset_pattern16` (Darwin libc; Linux spelling is
`initialize(repeating:)`, same win); rank 3 (own atlas, IOSurface blit) and rank 22 (`vvsin`)
depend on CoreGraphics/Accelerate and live in `TerminalRenderExecution`, which is Darwin-only
already; rank 19 (`vDSP_vrampD`) likewise, and is rejected.

| # | Site (file:line) | What it does | SIMD shape | Imp | Conf | Prod | Why |
|---|---|---|---|---|---|---|---|
| 1 | `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift:2914` (`appendCells`) | Per-cell admission encode: kind switch, spill branch, arena word store, identity-run extend | Blocked kind compare + popcount, stride-16 to stride-8 deinterleave store, block identity-run extend | 8 | 5 | 40 | Only site with a measured double-digit self share on a headline workload, but half the win is a scalar rewrite |
| 2 | `lib/TerminalCore/Sources/TerminalCore/Terminal.swift:5477` (`eraseCells`) | ED/EL interior blank fill, one 14-byte struct store per column | `memset` / `memset_pattern16` over a 16-byte stride | 3 | 8 | 24 | Cleanest, safest transform in the set; evidence for its size is two representation changes stale |
| 3 | `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift:1189` (glyph submission) | Hands glyphs to CoreGraphics; CG then colorizes and blits masks | Own atlas + `SIMD16<UInt8>` mask colorize-blit into the IOSurface | 7 | 3 | 21 | Biggest live pixel term after background fills, but it is a rasterizer rewrite, not a loop rewrite |
| 4 | `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift:830` (`admissionExtent`) | Reverse trailing-blank scan, once per admitted row | Reverse blocked kind compare, highest set lane | 5 | 4 | 20 | Real per-row cost on the admission path; a maintained `contentEnd` beats it outright |
| 5 | `lib/TerminalCore/Sources/TerminalCore/TerminalInputStream.swift:85` (ASCII run scan) | Byte-at-a-time printable-ASCII run scan | `(v &- 0x20) .>= 0x5F` over `SIMD16<UInt8>`, length-gated | 2 | 8 | 16 | Highest-volume loop in the tree and the most vectorizable, but arithmetically under 1% |
| 6 | `lib/TerminalCore/Sources/TerminalCore/Terminal.swift:8688` (`moveAndFillCells`) | ICH/DCH/insert-mode horizontal shift, per-cell closure with `Optional<Int>` source | One `memmove` + one pattern fill | 4 | 4 | 16 | Contiguous shift wearing a per-element closure; only `incremental-screen-updates` drives it |
| 7 | `lib/TerminalCore/Sources/TerminalCore/Terminal.swift:7849` (`writeNarrowCells`) | Stamps a `GridCell` per printed ASCII cell | Two interleaved `SIMD4<UInt64>` lanes per 4 cells | 3 | 4 | 12 | Destination of the largest print-path win, but the win was bookkeeping removal, not this store |
| 8 | `lib/TerminalCore/Sources/TerminalCore/Terminal.swift:5229` (retained style-run scan) | Finds the first differing style id across a retained row | `(w >> 32) .!= splat` over packed arena `UInt64` | 2 | 5 | 10 | Contiguous and clean, but only `retained-browse` reaches it and the closure call is the real cost |
| 9 | `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift:1774` (search cell scan) | Per-cell closure over closed-history words feeding `NeedleWindow` | First-key broadcast-compare prefilter with an 8-lane early-out | 2 | 5 | 10 | Ideal substrate, but the prefilter is not a superset under full case folding |
| 10 | `lib/TerminalCore/Sources/TerminalCore/Terminal.swift:6396` (`makeBlankRow`) | `(0..<columns).map` builds a blank row per scroll | `Array(repeating:count:)` | 1 | 6 | 6 | One-line tidy-up; both spellings probably lower to the same store loop |
| 11 | `lib/TerminalCore/Sources/TerminalCore/TerminalInputStream.swift:110` (probe DFA) | Byte-at-a-time UTF-8 DFA inside the non-ASCII run probe | simdutf-style block validate + scalar-start popcount | 2 | 3 | 6 | Only `synchronized-frames` has the content, and that workload issues no verdict |
| 12 | `lib/TerminalCore/Sources/TerminalCore/Terminal.swift:7672` (scalar-count scan) | Counts scalar starts in a bulk non-ASCII run | Mask-and-popcount over `(b & 0xC0) != 0x80` | 1 | 7 | 7 | Vectorizable, but the pass should be deleted, not accelerated |
| 13 | `lib/TerminalCore/Sources/TerminalCore/Terminal.swift:5326` (live style-run scan) | Same scan over live `[GridCell]` rows | Raw `SIMD4<UInt64>` load + even-lane de-interleave | 1 | 3 | 3 | Strided data, 2 comparands per register, in the planner's hottest traversal |
| 14 | `lib/TerminalCore/Sources/TerminalCore/TerminalInputStream.swift:98` (probe loop) | Non-ASCII scalar-run probe: DFA plus per-scalar classification | Find-and-validate block scan | 1 | 2 | 2 | Runs are 2-15 bytes on every committed corpus; classification stays a scalar gather |
| 15 | `lib/TerminalCore/Sources/TerminalCore/NeedleWindow.swift:49` (matcher ring) | Non-POD `[Unit?]` ring plus two `%` per cell | POD parallel rings (enabler, not SIMD) | 1 | 2 | 2 | Real scalar defects, zero vector content, and no workload reaches it |
| 16 | `lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift:481` (ink class) | Per-cell ASCII range test ORed into a row class | Lane compares reduced once per row | 1 | 2 | 2 | Two compares inside a much heavier closure; needs a module move to reach the words |
| 17 | `lib/TerminalCore/Sources/TerminalCore/UTF8Decoder.swift:73` (DFA tables) | Two `static let [UInt8]` lookups per decoded byte | Not SIMD; `InlineArray` / static blob | 2 | 1 | 2 | Serial recurrence; enables nothing for candidates 5 or 12 |
| 18 | `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift:951` (`drawTextRuns` classify) | Per-cell sprite/ASCII routing | Parallel `[UInt32]` scalar column + mask sweep | 2 | 1 | 2 | Multi-sink scatter loop; no compress-store in Swift SIMD |
| 19 | `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift:1081` (position ramp) | Appends a glyph origin per accepted cell | `vDSP_vrampD` / `SIMD2<Double>` fill | 1 | 1 | 1 | Already tried as lead L4, measured 2.5%, reverted, closed against re-proposal |
| 20 | `lib/TerminalCore/Sources/TerminalCore/EscapeAbsorber.swift:357` (control-string absorb) | One call and one array append per OSC/DCS/APC payload byte | Terminator scan + bulk `append(contentsOf:)` | 0 | 7 | 0 | Measured zero control-string payload bytes across all 17 MB of corpus |
| 21 | `lib/TerminalPTY/Sources/TerminalPTYHost/CanonicalInputDeliveryGate.swift:12` (`isOversized`) | Rescans the pending paste per `write()` iteration | Delimiter mask + run length | 0 | 3 | 0 | ICANON-only, no input workload exists, and the defect is quadratic not per-byte |
| 22 | `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift:1573` (curly underline) | One `sin` per device pixel of a curly underline run | `vvsin` / exact integer LUT | 0 | 3 | 0 | No workload emits SGR 4:3; an exact 8-24 entry LUT beats SIMD anyway |

## 2. The top 8

### 1. `appendCells` (LogicalLineStore.swift:2914)

Today the loop runs once per admitted cell and does six things: `originalCellOffset` (a
loop-invariant base plus index), a `TerminalCellKind` enum decode followed by a switch on that
enum, a spill branch, `chunk[cellsBase + index] = word.raw` into a `ContiguousArray` (bounds check
plus uniqueness check per element), a hyperlink check, and an identity-run extend that reads
`openIdentityRuns.last` and then modify-subscripts the last element. Proposed shape: 8-cell blocks
as `SIMD8<UInt64>` over the POD stride-16 source, `contentUnits` as `(w >> 21) & 7 .< 3` plus a
mask popcount, one spill/wide-head mask per block with a scalar fallback only when set, a
`uzp1`-style deinterleave into the arena, and a single block-extend of the open identity run when
the odd lanes equal `base + iota` (masked to the low 32 bits). Hot-path evidence: research/33/F42
measured 22.60% inclusive / 15.29% self on `scrollback-stream`, and the same 20 ns/cell that
implies reproduces doc 20's 146.4 ms absolute drain to within a point. The evidence is stale in one
direction only: `ded30f21` (POD stride-16 cell) deleted the `TerminalScalars` decode and the
per-cell ARC that were most of that 20 ns, so treat 15.29% as roughly 2x the current figure. Main
risk: this is not a pure map. Four pieces of open-record scratch (`openSpills`, `openHyperlinks`,
`openIdentityRuns`, `openPreviousIdentity`) are order-dependent, and a wrong identity run is
invisible until a selection or a search reads it back. Land the scalar half first
(`withUnsafeMutableBufferPointer` for the store, hoist the open run into a local, hoist
`originalCellOffset`, read the kind bits raw) and re-measure before writing a two-path encoder.
Prove it with `just benchmark-quick baseline=HEAD workload=scrollback-stream` (threshold 1.85%,
4 pairs at confirm), then `just benchmark-confirm baseline=HEAD`; four of six workloads will read
`equivalent` by construction because they never admit rows.

### 2. `eraseCells` (Terminal.swift:5477)

`let blank = GridCell(styleId: styleId)` then `for column in lower..<upper { cells[column] = blank }`
inside `withRowCells`, which is already an `UnsafeMutableBufferPointer`. `GridCell` is 14 bytes at
a 16-byte stride, so LLVM's loop-idiom pass cannot form a fill: the store size does not equal the
stride. Proposed shape: write the two padding bytes too. Build the 16-byte pattern once through
`withUnsafeTemporaryAllocation` (field-order independent, and it makes the padding deterministically
zero) and call `memset_pattern16`; for the default style the whole pattern is zero bytes
(`.padding.packedCode == 0`, `defaultStyleId == 0`) and it degenerates to `memset`. Evidence: doc 10
put `eraseCells` at 10.7-13.0% of root and doc 12/F5 put the erase family at 11-19%, calling it "a
memset-shaped loop" outright; 12/F6 then shipped -7.05% on `terminal-feed` by collapsing the
per-cell call into exactly this borrowed pass. Both figures are `sample`-derived and pre-date both
F6 and the POD cell, so they bound the site's history, not its size. Main risk: the pattern fill is
in-bounds only while the stride is 16, which `TerminalCellRepresentationTests.liveGridCellShape`
already pins; a field taking size past 16 makes stride 24 and fails that test, so the guard exists.
Do it once as a shared helper covering `moveAndFillCells`, `repairHorizontalMove`,
`clearPromptCells`, and `makeBlankRow` rather than at one site. There is also a strictly simpler
ideal on the table: add a 2-byte reserved field so `size == stride == 16` and every fill in the file
becomes idiom-recognizable for free, at zero memory cost. Prove it with
`just benchmark-quick baseline=HEAD workload=terminal-feed` (threshold 2.5%); check the disassembly
first, because if LLVM already unrolls the loop into vector stores the win is zero.

### 3. Own the glyph raster (TerminalRenderExecution.swift:1189)

Today `showGlyphs(mappedGlyphs, at: positions)` hands glyphs to CoreGraphics, which rasterizes and
composites them on our CPU account post-T25. Proposed shape: rasterize each (glyph, face) once into
an owned 8-bit coverage atlas, then blit into the IOSurface ourselves with premultiplied src-over,
16 destination pixels per iteration. Evidence: research/33/F26 puts `CGSColorMaskCopyARGB8888` at
1.33 s plus `RIPLayerBltGlyph` at 1.51 s of a 10.60 s 20-second `content-churn` trace, and against
`drawRenderFrame`'s own 6.25 s that is ~45% of the bracket the verdict metric measures. Main risks,
in order: the incremental path builds a multi-span non-rectangular clip inside `CGContext` and CG
exposes only `boundingBoxOfClipPath`, so the clip has to be lifted out and threaded through
`drawRenderFrame`'s public signature as data before a blitter can be correct at all; sprites,
underlines, the symbols face and the CTLine fallback stay on CoreGraphics and must match our
antialiasing, gamma and color conversion numerically; and CG's blit is already hand-tuned NEON, so
the win is overhead removal, not lane width. Note also that background fills (`memset_pattern16`,
3.62 s) are the larger term and are already the optimal primitive, and that the churn workloads are
frame-rate-capped (research/17/F16), so this is CPU and energy, not frames. If it is taken at all,
the honest ideal is a GPU atlas. Prove it with
`just benchmark-quick baseline=HEAD workload=content-churn` (threshold 1.65%) and
`workload=style-churn` (2.00%); expect 0% on `terminal-feed` and under 1% on `scrollback-stream`.

### 4. `admissionExtent` (LogicalLineStore.swift:830)

`for column in stride(from: min(width, row.cells.count) - 1, through: 0, by: -1)` reads
`row.cells[column].kind` through a bare `Array` subscript (bounds check per iteration) and
constructs a `TerminalCellKind` enum only to switch on it, breaking at the first content cell.
Proposed shape: borrow through `row.cells.withUnsafeBufferPointer`, scan backwards in blocks
testing `(word >> 21) & 7` for {narrow, wideHead}, take the highest set lane, then resolve the exact
column and the `min(width, column + 2)` wide-head clamp scalar-ly inside that one block. Evidence
is structural plus an enclosing bound: `scrollback-stream` replays 25,000 hard-terminated 59-column
lines at 179x66, so the scan walks 120 blank cells per admitted row, ~3.0M per replay; 28/F20 put
scrollback admission at 19.7% of the PTY-host thread and banked -6.69% for killing per-cell work on
this same path, and 31/F10 prices the landed `admit` at 456.1 ns per admitted row. Nothing prices
the scan itself. Main risk: the SIMD shape as pitched does not fit the layout - `row.cells` is
`[GridCell]` at a 16-byte stride, so a `SIMD8<UInt64>` covers 4 cells with half the lanes junk, and
the "all-zero cell" fast cut is unsound because a zero-word cell can carry a nonzero id and two
bytes of undefined tail padding. The ideal is not SIMD: maintain `contentEnd` on `GridRow` as cells
are written and read it in O(1). That is already the house pattern three lines above (the display-row
count is counted at admission, not derived, citing research/31/DD5), it retires
`Terminal.retainedContentEnd` and its three callers too, and it removes the wide-head clamp hazard
entirely. Prove either with `just benchmark-quick baseline=HEAD workload=scrollback-stream`, and
take a `just benchmark-sample scrollback-stream 20` attribution first, because the site is unpriced.

### 5. ASCII ground-run scan (TerminalInputStream.swift:85)

`repeat { index += 1 } while index < bytes.count && Self.isPrintableASCII(bytes[index])`, with
`isPrintableASCII` at :50-52 as `byte >= 0x20 && byte <= 0x7E`. Proposed shape: while
`index + 16 <= bytes.count`, load `SIMD16<UInt8>` unaligned from `bytes.baseAddress! + index`,
compute `bad = (v &- 0x20) .>= 0x5F`, advance 16 when `!any(bad)`, and on a hit take the first bad
lane portably via an iota vector plus `.replacing(with:where:)` plus `.min()` rather than
re-scanning the block scalar-ly. This is the best-shaped target in the tree: `bytes` is an
`UnsafeBufferPointer` end to end, no CoW, no release bounds check, no state carried inside the run,
and the run boundary is not observable because `.printASCIIRun` expands to one print per byte.
Evidence: it runs on every committed workload, with mean run lengths of 44.8 / 32.2 / 23.8 / 12.2 /
8.3 bytes (research/33/F10 and F16, agreeing to the unit). Main risk is that it cannot pay: F16 puts
the post-change `scrollback-stream` drain at 70.5 ms for 1.5M printed characters (~46 ns/byte)
against a ~1-1.5 cycle/byte scan, so the ceiling is ~0.8% on the friendliest corpus and ~0 on the
two corpora whose mean run never fills a 16-lane block - which are also the two where the old
profiles scored the parser highest. Budget `equivalent`. Do not do the UInt64-word variant first:
`x &- 0x2020...` borrows across byte lanes and needs the masked SWAR form, so the SIMD spelling is
the simpler and safer of the two. Prove it with
`just benchmark-quick baseline=HEAD workload=scrollback-stream`, and add chunk sizes 16, 17 and 31
to `TerminalASCIIRunTests` (its current set is 1, 2, 3, 5, 7, 11, 64, so six of seven chunkings
would never enter a vector block).

### 6. `moveAndFillCells` (Terminal.swift:8688)

`Self.moveInPlace(range, by: delta, amount: amount) { destination, source in ... }` drives a
per-element closure over an already-borrowed `UnsafeMutableBufferPointer<GridCell>`, paying an
`Optional<Int>` and a `range.contains` test per column. The permutation is a contiguous suffix
shift plus a contiguous vacated strip, so it is one `memmove` of `(range.count - amount) * 16` bytes
plus one pattern fill; the per-iteration branch is exactly what defeats LLVM's loop-idiom
recognition today. Multi-scalar cells are safe (spill indices are row-local and the row never
changes), and wide pairs are not the mover's problem because `repairHorizontalMove` runs after.
Evidence: doc 12/F7 re-measured this subtree at 8.1% of profile root after the POD spike (the
often-quoted 29% and 33.8% figures are older and were closed out in doc 10 itself), and the only
corpus that drives it is `incremental-screen-updates`, whose template emits exactly one ICH and one
DCH per cycle at column 10 of a 179-column grid - about 34M cell copies per replay, and that corpus
is ~57% of `terminal-feed`. Main risk: `repairHorizontalMove` then scans the entire row (179 cells)
branching on `kind` and heap-allocating an `[Int]`, so it is the co-equal cost and converting only
the shift captures at most half the subtree. There is no need to generalize `moveInPlace`: call the
memmove directly here and leave `moveAndFillRows` (whose element holds arrays) on the existing
helper. Prove it with `just benchmark-quick baseline=HEAD workload=terminal-feed` (2.5%) plus
`just benchmark-feed-sample incremental-screen-updates 30` for attribution. Do not measure
`incremental-mixed`: it is a draw workload whose producer emits no ICH, DCH or IRM at all.

### 7. `writeNarrowCells` (Terminal.swift:7849)

`for offset in 0..<count { cells[column + offset] = GridCell(scalars: .single(scalar(offset)),
kind: .narrow, styleId: styleId, hyperlinkId: hyperlinkId, contentIdentity: baseIdentity +
ContentIdentity(offset)) }`. Every field except the scalar and the identity is loop-invariant and
both varying fields are affine, so per 4-cell block the word lane is `constantHead | scalarBytes`
and the id lane is `(baseIdentity + iota) | hyperlink << 32`, interleaved into 64 bytes of stores.
Evidence: research/33/F16's -71.08% on `scrollback-stream` routed all bulk ASCII through this path,
so it is where that workload's print traffic now lands (1.5M cells per replay). Main risks: the win
is misattributed. F16's gain was collapsing per-character bookkeeping (damage snapshots 1,550,000
to 75,000, classification 180x), and this store is the residue it deliberately left. The removable
per-cell cost is dominated by the non-POD `TerminalScalars` temporary, an optional `.map`/`??`, and
three `precondition`s that survive `-O` - all of which a switch to the existing
`GridCell(word:hyperlinkId:contentIdentity:)` initializer with a hoisted head deletes, scalar. Swift
also has no `zip1`/`zip2`, so the interleave has to come from LLVM's interleaved-access group, i.e.
from that same cleanup. Only the `printASCIIRun` supplier is batchable; `printScalarRun`'s supplier
runs a stateful decoder and never will be. Prove it with
`just benchmark-quick baseline=HEAD workload=scrollback-stream`; note the only post-T8 profile of
this workload names `moveAndFillRows` and `appendCells`, not this loop.

### 8. Retained style-run scan (Terminal.swift:5229)

`while end < directEnd, storedStyleId(end) == styleId { end += 1 }`, where `storedStyleId` is a
closure handed out by `withPaintedCells` that reads
`CellWord(raw: words[cellsBase + shape.start + column]).styleId`. The words are packed `UInt64` in
one chunk (a record never straddles a chunk), already behind `withUnsafeBufferPointer`, and the
scan range is provably inside stored words, so the vector form is a first-difference search on
`(w >> 32)` against a splat. Evidence is indirect: doc 17 puts `planFrame` at 2.33-10.51% and
`forEachViewportCell` at 0.89-4.00%, but none of those four workloads browses history, so this
branch's share in that table is 0. The one workload that reaches it is `retained-browse`, whose
corpus is 45-column rows at 179 columns - the tail is merged in by one `joinsPadding` branch, not
scanned - against a 335.6 us/frame post-arena cost. Realistic reachable share: 1-3% of that
workload, 0 everywhere else. Main risk: the actual per-column cost is the opaque closure call, not
the compare, and a store-side `styleRunEnd(from:limit:)` primitive (or a segment emitter handing
back `(Range<Int>, StyleId)` pairs) captures that with no vector code while cutting indirect calls
from ~11,814 to ~66 per frame. The tail merges (deferred wide-head spacer, `shape.fillStyle`,
default padding out to `viewportColumns`) must stay byte-identical; the existing tests assert exact
segment ranges across those boundaries. Prove it with
`just benchmark-quick baseline=HEAD workload=retained-browse`, holding the slot fixed (its usable
margin is 0.3 points same-slot, 0.9 across slots).

## 3. Not worth it

Verified candidates with product < 12 (do not re-litigate):

- `Terminal.swift:7672` scalar-count scan (7): the count is already known in
  `nextAction`'s probe; widen the action to `.printScalarRun(range:scalarCount:)` and the pass
  disappears. Also reachable by only ~2.6% of `terminal-feed` bytes.
- `Terminal.swift:6396` `makeBlankRow` (6): `Array(repeating:count:)` lowers to
  `initialize(repeating:)`, not `memset`/`calloc`, and at 14 bytes in a 16-byte stride no idiom
  forms, so both spellings likely compile to the same loop. The real cost is the malloc/free pair;
  the ideal is recycling the popped row's buffer.
- `TerminalInputStream.swift:110` probe DFA (6): only `synchronized-frames` has the content
  (147,463 bulk-printable scalars), and that workload is a candidate with no verdict rule and a
  draw-side block metric. The same bytes are decoded twice; fix that first.
- `Terminal.swift:5326` live style-run scan (3): `[GridCell]` at stride 16 gives 2 comparands per
  NEON register; research/18/F15 already measured this class of unsafe rewrite at ~2.5% and reverted
  it. A per-row uniform-style bit removes the scan outright.
- `TerminalInputStream.swift:98` probe loop (2): every non-ASCII sequence in every committed corpus
  is 2-15 bytes with ASCII on both sides, so there is no vector-shaped work in the input; and
  `unicode-wrapping`'s non-ASCII is entirely non-bulk-printable, so the loop bails after one scalar.
- `NeedleWindow.swift:49` matcher ring (2): the compare loop's expected trip count is ~1 and the
  ring wraps mid-window, so nothing loads contiguously. The two real defects (two runtime `sdiv` per
  cell, a non-POD `[Unit?]` store) are ~10 lines of scalar code, and no benchmark opens a search.
- `RenderFramePlanner.swift:481` ink class (2): two compares inside a per-cell closure that also
  builds a `RenderTextCell` and drives four run coalescers; the `.band` bit and the `hidden` gate
  are not word-derivable, so a word pass would supplement rather than replace this one.
- `UTF8Decoder.swift:73` DFA tables (2): a serial recurrence, and it enables nothing for the ASCII
  scan (which never reads these tables) or for the blank-fill candidate. The all-integer-literal
  arrays are the shape SILGlobalOpt statically initializes, so the claimed `swift_once` cost is
  likely already absent; if anything survives it is the 108-entry table's bounds check, fixed by
  padding to 128 and masking.
- `TerminalRenderExecution.swift:951` `drawTextRuns` classify (1 x 2): twelve variable-length output
  sinks, no compress-store in Swift SIMD, and `RenderTextCell` is non-POD so there is no vector load.
  research/18's `L4` (unsafe pre-sized buffers) is 24.5% of the bracket against 8.2% for the whole
  Swift-loop-body group; the appends are the cost.
- `TerminalRenderExecution.swift:1081` position ramp (1): implemented, measured (-2.98% /-2.49%),
  reverted and explicitly closed as research/18/D7 "do not re-propose". `showGlyphs` derives its
  count from `Array.count`, so an over-sized vector fill draws its stale tail; and the accepted
  columns are a filtered subsequence, not a ramp.
- `EscapeAbsorber.swift:357` control-string absorb (0): measured 0 OSC/DCS/APC payload bytes across
  all five corpora (17.0 MB). Also the proposed OSC mask is wrong (high bytes are payload) and DCS
  needs a different one. The free adjacent fix is real though: `dispatchOSC`/`dispatchDCS` call
  `removeAll(keepingCapacity:)` while the enum payload still references the buffer, forcing an
  O(payload) copy that is immediately discarded.
- `CanonicalInputDeliveryGate.swift:12` (0): ICANON-only (so dead for any raw-mode shell), no
  workload drives PTY input, and research/20/D2 declined to build one. The defect is a quadratic
  rescan; the answer is monotone in the head offset, so cache one `Bool` per record per `c_iflag`.
- `TerminalRenderExecution.swift:1573` curly underline (0): no workload emits SGR 4:3, the cost is
  `addLine` per pixel plus CG stroking a multi-thousand-segment polyline, and the sample lattice is
  exactly periodic (`period / deviceStep == cellWidthPixels`, an integer), so an 8-24 entry LUT
  removes 100% of the `sin` calls with no vector code.

Finder rejections, merged (parser and Unicode):

- `EscapeAbsorber.consume` state machine: serial by byte, and doc 10 attributes 222/256 of its
  samples to `dispatchCSI`, not byte stepping.
- `colonSeparators.allSatisfy`: the flags are already a `UInt32` bitmask; the fix is `bits == 0`,
  not lanes.
- `collectParameter` digit accumulation / `CSIParameters` packing: bounded at 24 params, serial
  multiply-add, real SGR params are 1-3 digits.
- `OSCPayload.decodeBase64`: once per OSC 52, capped, no raw pointer, and strict quartet validation
  is what a vector decoder falls out of.
- `OSCPayload.percentDecoded` / selector / host normalization: tens of bytes, once per dispatch.
- `Terminal.dispatchOSC` payload splitting and OSC 133 options: shell-prompt frequency.
- PTY read/drain (`takeOutputTurn`, `finishOutputTurn`, `flushInput`): syscall-bound; the one bulk
  copy is already `_platform_memmove`.
- `UTF8Decoder.next` table lookups: loop-carried dependency; the only win is bounds-check removal.
- `synchronizationPrefix` builders: only run when a snapshot is taken, never during a feed.
- Standalone simdutf-style validator: the contracts are satisfiable, but there is nothing to
  validate - three corpora are 0.00% non-ASCII and the fourth's runs are shorter than one vector.
- `terminalUnicodeClassification` two-stage tables: three dependent loads with a 15-bit stage-two
  index; ARM64 has no useful gather and `vqtbl` covers 16 bytes. Hoist the stage-one block across a
  homogeneous run instead.
- `GraphemeBreakState.shouldBreak`: order-dependent state machine; its profile weight predates the
  bulk-ASCII path, which calls neither the table nor the segmenter.
- `canonicalCaselessOrder` / `canonicalCaselessKey` / `searchGraphemeKeys`: search-only, per
  grapheme of a typed query, data-dependent output length.
- `TerminalScalars.canAppend` / `utf8ByteCount`: n is 1-4 in practice and the hot path already
  tracks the running byte count incrementally.
- `recoverClusterContextFromGridIfNeeded`: sequential, and the loop body usually runs zero times.
- `isBulkPrintable`'s five-field conjunction: five register compares after a three-load gather; the
  fix is emitting the predicate as a palette field.

Finder rejections, merged (grid, store, search):

- `appendBlankCells` (LogicalLineStore.swift:2869): textbook memset shape that is nearly unreachable
  because live rows are always materialized to full width. Take the one-line
  `update(repeating:)` for free, but it decides nothing. This refutes the first half of the prior
  pass's hint 2.
- `recordsHoldTheSameContent` (:1914): literally `memcmp`, but whole-store equality left the frame
  path; it is a test-only value-semantics oracle now.
- `forEachStyleId` / `forEachContentIdentity` / `forEachHyperlinkId`: no calibrated workload contains
  the sweep trigger (research/33/F33), and the caller's `Set` insert dominates the word load.
- `withPaintedCells` / `forEachKind` / `forEachClosedRecordCell`: already resolve the chunk once and
  read through a raw pointer; the per-column callback contract is a deliberate design decision
  (research/31/D3 Decision 5). Do not touch.
- Per-cell `hyperlinkId` / `contentIdentity` binary searches: zero iterations and one compare
  respectively in the common case.
- `LogicalLineFold.enumerateRows` wide-cell walk: skipped entirely by `hasWideCells`; worst case
  measured at 5.6 ms, inside one frame.
- `contentCellCount`: guarded by `hasWideCells`; fix the unborrowed `word(at:)` addressing if it ever
  matters.
- `RingBuffer.grow` / `removeAll`, `materializeChunk` zero fill: indexed by record count, amortized,
  and already `calloc`-shaped.
- `Terminal.retainedContentEnd`, `rowContainsContent`, `Search.lastProjectedContentRow`,
  `forEachSearchUnit`: all read materialized `[GridCell]` rows whose `paintedRow` construction costs
  an order of magnitude more than the scan; the fix is routing through the arena, not lanes.
- `detectedLink` prefix scan, `isActivatableWebURI` predicates: hover/arm frequency, and the input
  array was heap-allocated per cell one call earlier.
- `NeedleWindow` binary searches in `synchronizeIndex` / `refinedSearchMatchIndex`: O(log n) over
  match counts.
- `TerminalGeometry.swift`, `RetainedHistory.swift`: contain no loop over cell data at all.

Finder rejections, merged (render):

- `TerminalDamage` row bitwords: `(rowCount + 63) / 64` is 2 words at 66 rows. Confirms the prior
  pass's non-candidate call.
- `renderRowReaches`, `renderApplyShape`, `renderTranslationStaleStrips`, plan-row selection,
  swapchain damage union: all bounded by row count (<= 66), a few bit tests each per frame.
- Background / overlay / decoration run fills: the largest pixel cost in the process
  (`memset_pattern16` 3.62 s) and already the optimal store; research/33/F36 refuted the "fewer
  pixels" lever and reverted T18.
- `translateRows` memmove and the initial surface `memset`: already libc-optimal.
- Sprite geometry (all eight families): 1-4 rects from integer division per cell; research/33/F37
  parked the adjacent memoization as below the schedulable ceiling. Confirms the prior pass's call.
- `TerminalFace` glyph table / bounding rects / `measuredInkEnvelope`: once per metrics.
- `fillPatternedUnderline` dash loop: cost is CG fill entry; batching is lead L6, not SIMD.
- `emptyValuesKeepingCapacity`, `RenderColor` component conversion: a handful of elements per run.
- `TerminalFrameBackingStore.blit`: has no production caller since T25.
- `overlayState` per-cell match scan: a genuine O(cells x matches) granularity bug, but the fix is an
  advancing cursor over sorted disjoint matches, not lanes.
- Row-vs-row equality for damage: does not exist. Damage is recorded at the mutation site and the
  planner reuses rows by reference. This refutes part of the prior pass's hint 3.
- Color resolution: already moved from 11,814 calls to 66 per frame by research/33/F32. Confirms the
  prior pass's call.
- AppKit chrome drawing, `ThemeRenderBridge` palette, view-side damage clip: off the frame path or
  deleted by T25.

## 4. Cross-cutting notes

**Two layouts, and half the candidates are on the wrong one.** The retained arena is
`ContiguousArray<ContiguousArray<UInt64>>` - packed cell words, one record never straddling a chunk,
already read through `withUnsafeBufferPointer`. Live and painted rows are `[Terminal.GridCell]`,
which is `CellWord(UInt64) + ContentIdentity(UInt32) + HyperlinkId(UInt16)` = size 14, stride 16,
POD, pinned by both `TerminalCellRepresentationTests.liveGridCellShape` and
`TerminalMemoryCensusTests` (`cellStrideBytes == 16`). On the arena a `SIMD8<UInt64>` is 8 cells; on
a row it is 4 cells with half the lanes junk, and the odd lane carries 2 bytes of undefined struct
padding that every compare must mask off. Candidates 1, 8, 9 are on the good side; 4, 7, 13, 14 are
not. Several finders wrote arena-shaped lane math for row-shaped data - the prior pass's hint 3
("row scans over contiguous UInt64 cell words") is true of the arena and false of `GridRow`.

**Raw-pointer access is a shared prerequisite, and it is mostly already paid.** `nextAction` takes
an `UnsafeBufferPointer<UInt8>`; `withRowCells` / `readingRowCells` hand out
`UnsafeMutableBufferPointer<GridCell>`; `withPaintedCells` and `forEachClosedRecordCell` already
borrow the chunk. The two sites that still index an `Array`/`ContiguousArray` inside the loop are
`admissionExtent` (bounds check per iteration) and `appendCells`' destination store (bounds check
*and* uniqueness check per cell). Neither `Package.swift` passes `-Ounchecked`, so those checks are
live in release; `UnsafeBufferPointer`'s subscript is `_debugPrecondition`-only, so the unsafe sites
already carry none.

**Bounds checks and CoW are not usually what blocks vectorization here.** Most of these loops are
early-exit searches (ASCII scan, style-run scans, `admissionExtent`, `isOversized`) or carry a
loop-carried recurrence (the DFA, the delimiter run length, the identity run). LLVM does not
vectorize either, packed layout or not - so "restructure over `UnsafeBufferPointer` and let it
auto-vectorize" is not available as a cheaper alternative at those sites, and explicit SIMD or an
algorithm change are the only routes.

**Swift stdlib SIMD gaps that recur across the write-ups.** No movemask and no "index of first true"
on `SIMDMask` (the portable idiom is an iota vector plus `.replacing(with:where:)` plus `.min()`, or
a bitcast to `UInt64` and `trailingZeroBitCount >> 3`); no runtime byte shuffle, which is the
primitive the entire standard simdutf validator is built on; no gather; no `zip1`/`zip2`; no
compress-store. Three candidates specified shapes that do not exist in the API.

**Which items are really memset/memcpy, not SIMD.** `eraseCells` (memset / `memset_pattern16`),
`makeBlankRow` (`initialize(repeating:)`), `appendBlankCells` (`update(repeating:)`),
`moveAndFillCells` (`memmove` plus a pattern fill), `recordsHoldTheSameContent` (`memcmp`),
`materializeChunk` (already `calloc`), `translateRows` and the backing-store clear (already
`memmove`/`memset` and optimal). Only `appendCells`' deinterleaved store, the ASCII and style
compare scans, the search prefilter, and the glyph blit are genuine lane work.

**A recurring theme: the SIMD proposal competes with deleting the pass.** Six candidates have a
non-SIMD alternative that is strictly larger: carry `scalarCount` in `.printScalarRun` (kills two
passes over the same bytes); maintain `contentEnd` on `GridRow` (kills `admissionExtent` and three
other callers); cache `isOversized` per record (kills a quadratic term ~60x bigger than the vector
win); a per-row uniform-style bit (kills the live style scan); an integer LUT (kills every `sin`);
and for `appendCells`, hoisting the open identity run plus a
`withUnsafeMutableBufferPointer` store probably captures most of the modelled win scalar.

**Measurement gating that constrains almost every item.** `terminal-feed` has no on-CPU instrument
(research/17/F2), so nothing on the feed path can be sized directly today. `synchronized-frames` -
the only corpus with bulk non-ASCII - is a candidate workload with no verdict rule and a draw-side
block metric. No calibrated workload searches, selects, resizes, or drives PTY input, so candidates
9, 15, 21 cannot be measured by the ladder at all. Thresholds to clear (frozen):
`content-churn` 1.65%, `style-churn` 2.00%, `incremental-mixed` 2.10%, `scrollback-stream` 1.85% at
confirm (2.15% frozen elsewhere; A/A distrust runs to 3.5 points), `terminal-feed` 2.5%,
`retained-browse` 0.3 same-slot / 0.9 across slots. Commands: `just benchmark-quick baseline=HEAD
workload=<w>`, `just benchmark-confirm baseline=HEAD` (all five, baseline only - it takes no
workload argument), `just benchmark-feed-sample <corpus> <seconds>` and
`just benchmark-sample <workload> <seconds>` for attribution, `just terminal-occupancy-probe` for
search latency.

## 5. Corrections the verifiers made to the finders

**Line numbers.** The ASCII scan is at `TerminalInputStream.swift:85-89` with the predicate at
:50-52, not :87/:99 and :62-64 (I re-read it). `eraseCells`' fill is at `Terminal.swift:5477-5482`,
not :5479. `appendCells` starts at `LogicalLineStore.swift:2893` with the loop at :2914;
`admissionExtent` starts at :820 with the scan at :830. `CanonicalInputDeliveryGate.isOversized` is
declared at :12.

**Misattributed hot-path evidence, four times over the same table.** Three separate finders cited
research/33/F10's "1,208,250 of 1,305,000 prints in runs on `unicode-wrapping`" as evidence for the
non-ASCII scalar path. That is the **ASCII**-run column; read correctly it bounds the scalar path
*downward*, to at most ~3% of prints. Worse, a corpus census shows `unicode-wrapping` reaches
`printScalarRun` zero times - all ten of its non-ASCII scalars fail `isBulkPrintable` (wide CJK, a
combining mark, an emoji ZWJ sequence). The corpus that actually exercises it is
`synchronized-frames`, which no finder named.

**Stale profile shares treated as live ceilings.** research/10's 8.7-11.8% for
`TerminalInputStream.feed` predates T7 (deletion of the materialized action array, sized at 60-80x
the corpus byte count) and T8 (bulk ASCII bypassing the decoder), so it overstates today's parser
residue by roughly an order of magnitude. research/12/F5's 11-19% for the erase family and
research/10's 10.7-13.0% for `eraseCells` predate F6 *and* the POD cell. research/33/F42's 15.29%
self for `appendCells` predates `ded30f21`, which removed the `TerminalScalars` decode and per-cell
ARC that were most of it. doc 12/F7's 8.1% is the better anchor for `moveAndFillCells` than the
often-quoted 29%, which doc 10 itself closed out as "a hole in F1's table". Doc 17's rule applies
throughout: a `sample`-derived number may be cited as history, never as a size.

**Corpus facts that were asserted rather than measured, and turned out to be zero.** Zero
OSC/DCS/APC payload bytes across all five corpora (17.0 MB). Zero non-ASCII bytes in
`scrollback-stream`, `styled-screen-redraw` and `incremental-screen-updates`. Zero SGR 4:3 anywhere,
including in the 4 MB btop recording. Zero ICH/DCH in the `incremental-mixed` producer (the finder
named it as the workload to measure for `moveAndFillCells`; the right one is
`incremental-screen-updates` inside `terminal-feed`). No benchmark opens a search, so
`RetainedHistory.mutate`'s `synchronizeIndex` and `Terminal.searchReadout` both short-circuit on
`search != nil` in every measured run.

**Proposed SIMD shapes that are wrong as written.**
- OSC terminator mask `(b &- 0x20) .>= 0x5F` flags every high byte, and the code's own comment
  (EscapeAbsorber.swift:412) says 0x9C inside an OSC payload is UTF-8 continuation data. Correct mask
  is `(b .< 0x20) | (b .== 0x7F)`, and a routed DCS needs a different one entirely ({0x18,0x1A,0x1B}).
- The UInt64-word variant of the ASCII range test is incorrect: `x &- 0x2020...` borrows across byte
  lanes. The finder recommended doing that form *first*.
- The block UTF-8 classifier described (continuation mask plus expected-length-from-nibble) is not a
  validator: it accepts overlongs, surrogates and F5..FF. And Swift has no runtime byte shuffle, so
  the standard nibble-lookup validator cannot be written without a C shim. "~6 lane ops" is not
  achievable.
- `writeNarrowCells`' lane formula assumes `hyperlinkId` is UInt32; it is UInt16, and the second lane
  is identity(32) | hyperlink(16) | 16 bits of undefined padding. Same error in `appendCells`.
- `admissionExtent`'s "a default-blank cell is all-zero bytes" is true of the *word* only; the ids
  are independent and the tail padding is undefined.
- The search prefilter's lane set is not a superset: full case folding maps non-ASCII scalars onto
  ASCII keys (U+212A to k, U+017F to s), so a fixed 2-4 compare lanes drop real matches. The stated
  rescan direction is also backwards for a first-key prefilter, and it does not restore
  `NeedleWindow`'s slot state. `SIMDMask` has no `toBitmask`.

**Scope errors.** `moveAndFillCells` is not reached by ECH (that is `eraseCells`); the callers are
ICH, DCH and insert-mode printing. `forEachClosedRecordCell` has a second production consumer
(`recordSearchBoundaryWindow`), not one. `NeedleWindow` is not stored inside `Search`; what is
stored is `[Unit]` as `boundaryWindow`, which is what actually constrains a POD rewrite. The DFA
tables are read on all-ASCII corpora after all - not per printable byte, but once per ESC and per
ground control byte, which is ~700k calls on `incremental-screen-updates`.

**Two claimed enablers that enable nothing.** Making the UTF8Decoder tables register-resident does
not help the ASCII scan (which never reads them) or the blank-fill candidate; the sites are
independent and should not be sequenced as one. And a POD `NeedleWindow` ring does not make the
search scan vectorizable - the compare loop's expected trip count is ~1 and the window wraps.

**Risk assessments that were mis-set.** `eraseCells`' "a future field taking size to 15-20 bytes
silently corrupts memory" is wrong: stride stays 16 at size 15-16 (a correctness bug, not
corruption) and jumps to 24 past that, which fails the existing stride test. Conversely the probe
DFA's correctness risk was *over*stated: the probe commits nothing on the success path and always
starts from decoder-idle, so a declined block replays through the untouched scalar DFA
automatically. And `TerminalFixtureTests.splitStrategies` already splits every feed event at every
offset (not "at 7 bytes"), giving far better mod-16 coverage than the finder credited - while
`TerminalASCIIRunTests`, named as the guard, uses chunk sizes 1/2/3/5/7/11/64, six of which can never
enter a 16-lane block.

**Free adjacent fixes surfaced by verification, none of them SIMD.** `dispatchOSC`/`dispatchDCS`
call `removeAll(keepingCapacity: true)` while the enum payload still references the buffer, forcing
an O(payload) copy that is immediately discarded. `repairHorizontalMove` scans the whole row after
every ICH/DCH and heap-allocates an `[Int]`. `printScalarRun` re-decodes bytes the probe already
decoded, after a third pass to count them. `appendCells` calls a loop-invariant
`originalCellOffset` per cell and decodes `kind` into an enum only to switch on it again. Every one
of these is larger than the vector win at the same site.

### F2 -- Phase 1 sizing: the rank-1 win is scalar, and rank 2 has no workload

- Status: complete.
- Date and investigator: 2026-08-26, three Time Profiler traces, machine held idle.
- Commit and worktree state: 7bf8459f; working tree carries only untracked docs and plans, no source change.
- Instrument: `just benchmark-trace <workload> "Time Profiler" 30`. Diagnostic
  only -- these are profile shares, not benchmark results, and decide nothing on
  their own.
- Uncertainty: one trace per workload; shares below 1% are not resolved.
- Next action: `D1`.

Three traces, all on-CPU (`threadStates` is 100% `Running` in each, so no parked-thread
inflation and the percentages mean what they say):

| Workload | Samples | Total |
|---|---|---|
| `scrollback-stream` | 38107 | 38107.0 ms |
| `full-screen-content-churn` | 14976 | 14976.0 ms |
| `localized-draw-acceptance` | 4940 | 4940.0 ms |

#### Instrument correction

The Phase 1 ledger named `just benchmark-sample`. A "self share" question routes
to `benchmark-trace` instead: `sample` captures every thread on-CPU or not, so its
percentages need a correction pass and its idle threads dilute every share
([agent-docs/terminal-performance.md](../../../agent-docs/terminal-performance.md),
"Choose a profiler"). All three traces below are `benchmark-trace`.

The ledger also named workload `content-churn`; the script's name is
`full-screen-content-churn`.

#### `appendCells` (rank 1): 6.35% self, 17.69% inclusive

On `scrollback-stream`, `LogicalLineStore.appendCells` is 2418.0 ms self (6.35% of
total CPU) and 6741.0 ms inclusive (17.69%). `F1` called this "the only site with a
measured double-digit self share"; the double digit is the inclusive figure, and self
is single-digit.

`H1`'s competing explanation is confirmed, and it is larger than the SIMD candidate.
Summed over every leaf under `appendCells`, copy-on-write uniqueness checks and array
bounds checks cost **3427.0 ms, 8.99% of total CPU** -- more than the function's own
self time. The direct children:

| Cost | Frame |
|---|---|
| 2589.0 ms | `appendCells` (recursive) |
| 1178.0 ms | `_ContiguousArrayBuffer.beginCOWMutation()` |
| 1093.0 ms | `_ArrayBuffer.beginCOWMutation()` |
| 360.0 ms | `ContiguousArray.subscript.modify` |
| 359.0 ms | `_ArrayBuffer._checkValidSubscriptMutating(_:)` |
| 354.0 ms | `_ArrayBuffer.immutableCount.getter` |
| 350.0 ms | `OriginalCellOffset.- infix(_:_:)` |

The two buffer families separate the two call sites cleanly, because the declared types
differ (`LogicalLineStore.swift:189`, `:335`):

- `_ContiguousArrayBuffer` is `chunks: ContiguousArray<ContiguousArray<UInt64>>`, reached
  through the loop's `chunk[cellsBase + index] = word.raw`. The existing swap-the-chunk-into-a-local
  trick (`research/31/F13`) removed the arena-level copy but not the per-cell uniqueness
  check, which is still executed once per admitted cell. `withUnsafeMutableBufferPointer`
  around the loop removes it, and takes `ContiguousArray.subscript.modify` with it.
- `_ArrayBuffer` is `openIdentityRuns: [IdentityRun]`, reached through
  `openIdentityRuns[openIdentityRuns.count - 1].extent += 1`. That is a COW check, a bounds
  check and a count load per cell, on the common path where identities run consecutively.
  Holding the open run in local `start`/`extent`/`base` variables and writing it back once
  after the loop removes all three.

Together those two hoists address roughly 3.3 s of 38.1 s -- about 8.7% of total CPU --
with no lane math. Whether the blocked kind compare is worth anything can only be judged
after they land, which is what `H1` said to do.

#### `eraseCells` (rank 2): no calibrated workload calls it

`H2` cannot be answered as posed. `eraseCells` does not appear in any stack on
`scrollback-stream` (0 of 38107 samples) or `full-screen-content-churn` (0 of 14976).
This is a coverage gap, not a measured zero, and the stimulus source says why:
`scripts/terminal-benchmark-producer.py` emits ED (`ESC [ 2 J`) only in
`localized_draw_initial_screen`, which is the excluded settling screen, and EL
(`ESC [ K`) only in `localized_draw_update` / `localized_draw_ready`. The
`full-screen-content-churn` frame overwrites every cell with printable text and issues
no erase at all.

`localized-draw-acceptance` is therefore the only workload that reaches the site, at one
EL per update on one row. Traced: **3.0 ms inclusive, 0.061% of total CPU; self 0.0 ms**
-- three samples. There is no verdict rule that a change to `eraseCells` could clear.

Two corrections while the site was open: the function is at `Terminal.swift:5442`, not
`:5477` as `F1` has it; and `F1`'s reading of `memset_pattern16` as evidence for this
rank does not survive attribution. `_platform_memset_pattern16` is the top self frame on
both of the big traces -- 8.9% on `scrollback-stream`, 36.2% on `full-screen-content-churn`
-- and in both its only caller is `CGBlt_fillBytes`. It is CoreGraphics background fill in
the renderer, not the grid's blank fill, and it is Darwin-only code DanTerm does not own.

#### `moveAndFillCells` (rank 4): also absent

No frame named `moveAndFillCells` appears in any of the three traces.
`_platform_memmove` on `scrollback-stream` is 7.5% self, and its callers are
`Terminal.apply` (944.0 ms), `recoverClusterContextFromGridIfNeeded` (338.0 ms),
`_ContiguousArrayBuffer._consumeAndCreateNew` (306.0 ms),
`LogicalLineStore.makeRoom(forCells:)` (217.0 ms) and `admit` (195.0 ms) -- array growth
and admission, not the scroll-region move the rank names.

#### Incidental observation, not part of Phase 1

`Terminal.recoverClusterContextFromGridIfNeeded()` spends 338.0 ms in `memmove` on
`scrollback-stream` (0.89% of total CPU). Nothing in `F1` names it. It reads like a pass
that reconstructs state that could be maintained, which is the `F1` section 4 shape --
delete rather than accelerate -- but no evidence here says that, and it is not a SIMD
candidate. Recorded so it is not lost.
