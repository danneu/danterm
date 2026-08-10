# Findings -- logical-line scrollback (doc 31)

Append-only evidence chain for
[31-logical-line-scrollback](README.md); the contract is
[../FORMAT.md](../FORMAT.md). Cross-file citations are qualified (`28/F23` is
doc 28's); bare IDs are this doc's.

Phase 1's four viability probes are all recorded below: `F1` (read path), `F2`
(counting pass), `F3` (admission), `F4` (edge-case inventory). `F5` is not a
probe -- it is the simplification-inequality accounting pass that `D1`'s frozen
rule owed at its close. `F6` opens Phase 2: it is the display-row-indexed
call-site enumeration, and it discharges the sixth of the eleven conditions
`D1` carried forward. `F7` is Phase 2's first measurement: it prices `F2`'s
counting pass at the record count `D2` Decision 1 admits, and closes the one
open question `D2` could not decide without a number.

### F1 -- the read path is not the hazard: wrap-at-read browses 1.64x faster than today's store, and random seek is faster too

- Status: recorded. This is the go/no-go input `31/D1` Part A decides on, and
  it answers `H1`'s falsifier in the opposite direction from the one the
  hypothesis was written to guard against. **It settles the read path only.**
  Nothing here licenses a production storage change; `F2`, `F3`, `F4` and the
  simplification inequality are all still owed, and `28/H7` remains the
  fallback until D1 closes.
- Date and investigator: 2026-08-04, Claude (agent).
- Commit and worktree state: `eee1832` (the commit that froze `D1`'s rule,
  written before this probe existed in the tree), plus the one file this entry
  adds --
  `lib/TerminalCore/Tests/TerminalCoreTests/TerminalLogicalLineReadProbe.swift`,
  committed with it. **No file under `lib/TerminalCore/Sources/` is touched.**
  Two untracked paths were present and are in no build: `TODO.md` and
  `docs/scratch/2026-08-04-scroll-sample-breakdown.md`.
- Conditions: AC power, low-power mode off. One-minute load average 1.48 before
  the quoted invocation and 1.44 after, both under the 2.5 gate `28/F15`
  established and `D1` adopted. Release configuration, headless, one process.
- Commands:

      DANTERM_LOGICAL_LINE_PROBE=1 swift test -c release \
          --package-path lib/TerminalCore --filter TerminalLogicalLineReadProbe

- Artifacts: none durable. Every number below is stdout from the probe above and
  is reproduced by re-running it; the probe prints its own gate outcomes.

#### What was compared

Both arms are built from **one** `RetainedStimulus`: the display rows a real
`Terminal` at 179x66 actually retained, taken through
`retainedRowForTesting(at:)`, with the logical lines recovered from those rows
by joining on `isSoftWrapped`. So the candidate stores exactly the cells the
baseline stores -- this is a comparison of storage shape, not of two wrap
implementations.

- **Baseline** -- today's shape: one `Terminal.PackedRetainedRow` per display
  row, produced by the production `pack`, addressed at an O(1) index, read
  through the production `forEachKind` + `forEachContentCell` walks
  (`28/F17`'s two readers). `ScrollbackBuffer` is `private` to `Terminal`, so
  the arm reproduces its element type, readers and index arithmetic rather than
  calling it. That substitution is F1's stated fidelity limit.
- **Candidate** -- doc 31's sketch: one contiguous byte arena of
  variable-length logical-line records (8-byte header carrying cell count and
  flags, then C1 cell words verbatim), plus the derived block index (per-line
  record offsets, 256 lines per block, one cached display-row total per block);
  display-row lookup is a binary search over block totals then an in-block scan
  that reads each line's cell count out of its record header.

#### Observation 1 -- the four measured cells, and the verdict D1's rule reads off them

Median over 5 ABBA rounds of nanoseconds per display-row read, at ~10,000
display rows and 179 columns. Sample counts: 19,800 reads per browse round,
20,000 per seek round.

| pattern | class | baseline | candidate | ratio | A/A control | `D1` rule | result |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| sequential browse | `mix` | 882.3 ns | **536.3 ns** | **0.608x** | -0.64% | <= 1.20x | pass |
| sequential browse | `full` | 1,270.4 ns | **774.7 ns** | **0.610x** | -0.43% | <= 1.20x | pass |
| random seek | `mix` | 915.3 ns | **822.3 ns** | **0.898x** | +0.21% | <= 3.0x, <= 5.0 us | pass |
| random seek | `full` | 1,361.0 ns | **1,092.7 ns** | **0.803x** | -0.88% | <= 3.0x, <= 5.0 us | pass |

Every A/A control is under 1%, so all four differences are an order of
magnitude outside the instrument's resolution. Random seek's absolutes -- 0.82
and 1.09 us -- are 4.6x and 3.4x inside `D1`'s 5.0 us bound.

All five validity gates held on the quoted invocation:

1. **Cross-arm checksums identical** on all four measured patterns, so the arms
   provably read the same scalars, style ids and kinds in the same order.
2. **Stimulus calibration:** `mix` measured display-row cell counts at median
   **149**, p95 **179**, mean 124.2 -- inside `28/F23`'s band ([119, 154] /
   179) and near its pooled real-corpus mean of 128.3. `full` is 179 flat.
   `mix`'s length distribution was tuned against this gate alone, before any
   arm was timed.
3. **A/A resolution:** -0.64% / +0.21% / -0.43% / -0.88%, all far under the 5%
   ceiling.
4. **Host conditions** as recorded above.
5. **Coverage:** every aggregate printed with its sample count; the wrap check
   (below) reports a reason string rather than a silent pass.

**One earlier invocation was discarded unread of its verdict, and is recorded
rather than hidden.** It read an A/A control of **-6.91%** on `mix`/random
seek, above `D1`'s 5% ceiling, which voids the whole invocation by the frozen
rule. Its four ratios were 0.606x / 0.889x / 0.605x / 0.816x -- materially the
same as the quoted run, which is why the discard costs nothing but is reported
anyway: a rule that is only honoured when it would change the answer is not a
rule. A third invocation, taken while the descriptive sweep test ran
concurrently in the same process, read 0.597x / 0.896x / 0.594x / 0.787x. The
ratios reproduce across all three; only the quoted one is a valid invocation.

#### Observation 2 -- the wrap arithmetic is exact, which is the design's premise and not only its performance

`verifyWrapArithmetic` reported `ok` for both classes: the candidate's derived
display-row count equals the engine's retained row count (10,000 on both), and
`ceil(cells / 179)` reproduces the engine's own display-row count **for every
one of the 5,758 (`mix`) and 5,013 (`full`) logical lines**. Nothing
width-dependent is stored anywhere in the candidate; the index was built by one
eager pass and only read thereafter.

That is a small but real confirmation of the premise `H4` will be tested
against properly in `F4`: for this content, unwrapping history and re-wrapping
it at the same width is lossless and needs no stored wrap state. It says
nothing yet about wide characters at the last column, which `F4` owns.

Arena sizes, reported for `F2`'s and Phase 2's benefit: 9.98 MB (`mix`) and
14.36 MB (`full`) for 10,000 display rows. The `full` figure sits within 3% of
`28/F23`'s independently measured 14.80 MiB charge for the same content class
at the same depth, which is a useful cross-check that the two probes are
holding the same amount of content.

#### Observation 3 -- the leading competing interpretation was measured, and refuted

The obvious deflation of a 1.64x browse win is that it is not about storage
shape at all: `ScrollbackBuffer`'s subscript returns a `PackedRetainedRow` **by
value**, and that struct owns two Swift arrays, so every row read could be
paying a retain/release pair the arena never pays. If that dominated, the win
would be recoverable inside today's design with a borrowing accessor and no
storage change whatsoever -- which would make this finding an argument for a
one-line fix rather than for a redesign.

Measured directly, as a descriptive third arm outside `D1`'s rule: the same
baseline store, the same walks, the row borrowed in place through
`withUnsafeBufferPointer` instead of copied out.

| class | copying (today's shape) | borrowed | ratio |
| --- | ---: | ---: | ---: |
| `mix` | 881.5 ns | 890.7 ns | 1.010x |
| `full` | 1,269.6 ns | 1,276.8 ns | 1.006x |

Borrowing is **not faster** -- if anything marginally slower, and within
resolution of zero either way. The per-read copy is not where the difference
lives, so the competing interpretation is refuted and the remaining mechanism
is the one the design predicted: 10,000 separately allocated row blobs read
through a pointer indirection versus one contiguous region walked forward.

#### Observation 4 -- what the block index costs, descriptively

Outside `D1`'s rule, which is frozen at the design's stated ~256 lines per
block. Random seek only, 20,000 seeks, same stimulus:

| blockSize | `mix` ns/seek | `full` ns/seek |
| ---: | ---: | ---: |
| 32 | 677.5 | 1,029.5 |
| 64 | 697.4 | 959.1 |
| 128 | 800.9 | 1,018.4 |
| 256 | 870.0 | 1,166.6 |
| 1,024 | 1,544.6 | 1,873.9 |

The in-block scan is a real term: 32 -> 1,024 lines per block costs 2.3x on
`mix`. At the rule's 256 the candidate is still faster than the baseline's
O(1)-indexed read, and 64 would buy roughly another 170 ns/seek if a later
finding ever needs it. This exists so a future `narrow-go` on seek has a
measured starting point instead of a guess about which way to move the
parameter.

- Observation: at ~10,000 display rows and 179 columns, the logical-line arena
  plus derived block index reads **faster** than today's per-display-row packed
  store on both access patterns and both content classes -- 0.608x/0.610x on
  sequential browse and 0.898x/0.803x on random seek -- with A/A controls under
  1%, identical cross-arm checksums, and exact wrap arithmetic on all 10,773
  logical lines measured.
- Inference: `H1` is confirmed, and its competing explanation is refuted.
  The added wrap-at-read indirection does not give back `28/F17`'s win; it does
  not cost anything measurable at all. The mechanism the numbers support is
  memory layout: today's store is 10,000 separate heap blobs and the arena is
  one contiguous region, so a sequential browse walks forward through prefetched
  memory instead of chasing a pointer per row. The per-frame index lookup is
  amortized over 66 rows and disappears; even unamortized (random seek) the
  binary search plus in-block scan costs less than the allocation-chasing it
  replaces.
- Competing interpretations:
  1. *ARC on the per-read row copy, not layout.* **Measured and refuted** --
     Observation 3.
  2. *The arms differ in what they store, not how.* Both lost `hyperlinkId` and
     `contentIdentity`, so neither carries a side table. That strips a real
     candidate advantage (under the candidate an identity run table would be
     built once per logical line rather than once per display row), so it is
     conservative toward the baseline, and the cross-arm checksum proves the
     cells read are identical.
  3. *The baseline arm is not `ScrollbackBuffer`.* It reproduces the buffer's
     element type, readers and index arithmetic rather than calling it, because
     the type is `private`. A behavioral difference between the two would have
     to live in code the arm does not contain -- the subscript is three lines --
     but this is the entry's largest fidelity limit and is named as such.
  4. *A microbenchmark is not a frame.* This measures the read walk in
     isolation. `D1`'s 1.20x threshold was derived by converting a read-walk
     change into a `retained-browse` frame change through `28/F17`'s ~5.2%
     share; the same conversion says a 0.61x read is worth roughly -2% at the
     frame, which is a prediction this entry does **not** claim to have
     verified. Only the paired `retained-browse` ladder can, and only against a
     real implementation.
- Uncertainty:
  - **Depth.** Measured at one depth (~10,000 display rows). The candidate's
    seek cost is O(log blocks) + O(blockSize) and so should be depth-robust,
    but that is an argument, not a measurement. The baseline's O(1) index does
    not degrade with depth either, so the ratio could move in either direction
    at 100,000 rows.
  - **Content.** ASCII, single-scalar cells, no hyperlinks, no wide characters,
    no spills. The arena prototype has no spill table at all and calls
    `fatalError` if the stimulus produces a multi-scalar cell, precisely so a
    silent encoding difference cannot appear as a speed difference. Real
    history has spills in ~0.12% of rows (`28/F11`).
  - **The prototype is not a store.** It has no admission path, no eviction, no
    open-line rule, no forced split, and no side tables. `F3` measures
    admission; eviction from the front of an arena is Phase 2's problem and is
    not priced anywhere yet.
  - This entry cannot see anything about resize, which is the whole reason the
    design exists. `F2` owns that.
- Next action: `D1` Part A's verdict is recorded in
  [decisions.md](decisions.md) as **go (read path)**. The Phase 1 ledger
  continues with `F2` (the eager counting pass at depth), then `F3`
  (admission), then `F4` (the edge-case inventory, which can still make D1
  no-go). Two things this entry hands forward: the `blockSize` sweep in
  Observation 4 is the starting point if seek cost ever becomes the binding
  constraint, and `F2` can reuse this probe's `LogicalLineArena.recomputeIndex`
  directly -- it is the eager pass H2 describes.

### F2 -- the eager counting pass is 0.016 ms at trial depth and 0.64 ms at 100,000 lines, 15x inside H2's bound

- Status: complete. `H2` **confirmed** under `31/D1`'s Part B rule, frozen at
  `497d181` before this probe existed in the tree. This is a Part B input to
  `D1`; it cannot and does not move `D1`'s direction (the rule says so
  explicitly), and it does not open Phase 2.
- Date and investigator: 2026-08-04, agent.
- Commit and worktree state: measured at `497d181` plus the one file this
  finding adds (`TerminalLogicalLineIndexProbe.swift`) and the three members it
  needed on `F1`'s arena (a synthetic initializer, a second counting-pass
  variant, and the independent cross-check total). No file under
  `lib/TerminalCore/Sources/` is touched; `F1`'s arms are unedited.
- Commands, inputs, or reproduction:

      DANTERM_LOGICAL_LINE_PROBE=1 swift test -c release --package-path lib/TerminalCore \
        --filter TerminalLogicalLineIndexProbe

  Conditions: AC power, low-power mode off, one-minute load average **1.49
  before and 1.49 after**. 9 measured rounds plus 2 warmup per cell; statistic
  is the median over rounds of one whole pass, min and max and `n` beside every
  aggregate.

#### What was measured

One call of the eager recompute: discard every cached block total and rebuild
`blockPrefix` for a new width, reading one cell count per logical line and doing
one divide. Nothing else is inside the timed region.

`31/D1` named two count-sources, and the difference between them is the whole
cost:

- `arena` (**primary**) -- the count is read from each line's record header
  through `lineOffsets`, which is what the candidate direction sketches: the
  index stores offsets and the count lives in the record. A strided chase across
  the whole arena.
- `counts` (**alternative**) -- the count is read from a dense parallel array,
  which is what `F1`'s prototype happened to do. A sequential scan of
  `8 x lineCount` bytes, bought with 8 bytes per line of extra index state.

#### Observation 1 -- the measured passes, and the bound D1 reads them against

Median milliseconds per whole pass, primary `arena` source, `n=9` per cell.
10,000-line figures are the real-engine arena; 100,000-line figures are the
synthetic one (gate 2 below).

| class | width change | 10,000 lines | 100,000 lines |
| --- | --- | ---: | ---: |
| `mix` | 179 -> 179 | 0.016 ms | 0.547 ms |
| `mix` | 179 -> 100 | 0.015 ms | 0.550 ms |
| `mix` | 179 -> 200 | 0.015 ms | 0.545 ms |
| `full` | 179 -> 179 | 0.016 ms | 0.557 ms |
| `full` | 179 -> 100 | 0.016 ms | 0.639 ms |
| `full` | 179 -> 200 | 0.016 ms | 0.641 ms |

The `counts` alternative, same cells: **0.013 ms** at 10,000 lines in every one
of the six, and 0.127-0.136 ms at 100,000.

Read against `31/D1`'s frozen thresholds:

- **Confirm H2** required the 100,000-line median at or under **10.0 ms** on
  both classes and both width changes. Worst cell measured: **0.641 ms**. Passes
  with a 15.6x margin.
- **Reject** required 10,000 lines at or above **16.67 ms** (one 60 Hz frame).
  Worst cell measured: **0.016 ms**, about 1,000x under the line. Nowhere near
  rejection.
- The narrow-confirm band is not entered.

So: **H2 confirmed, eager recompute stands for milestone 1, and the lazy
per-block alternative stays in Rejected.** The primary count-source clears the
bound on its own, so the design does *not* need the parallel counts array --
that is the one Phase 2 input this entry produces.

For scale against what the pass replaces: 10,000 logical lines of `mix` content
is **17,248 display rows** at 179 columns, 1.72x the depth `28/F23` priced at a
600.5 ms synchronous reflow. The counting pass over it is 0.016 ms. The
comparison is a division between two separately measured numbers, not a paired
measurement, so treat the ratio as an order of magnitude (about 4 orders) rather
than a figure.

#### Observation 2 -- the gates

1. **Non-elision.** Every timed pass's total was cross-checked against a sum
   computed by an unblocked route; all 324 passes in the primary measurement
   matched, as did the ladder's 108, and no total was zero. The totals themselves are reported (`mix` at 179: 17,248 display rows
   from 10,000 lines; at 100: 26,498; at 200: 15,892 -- the pass responds to
   width, which is what it is for). A counting loop is exactly what an optimizer
   deletes, and this gate is why the numbers above are of a loop that ran.
2. **Synthetic-stimulus fidelity.** The 10,000-line arena was built both ways --
   through `F1`'s real-engine `buildStimulus` and synthetically from the same
   per-line counts -- and both were measured in every cell. Ratios spanned
   **0.975x to 1.062x**, inside the 15% the rule allows, and the two arenas
   agreed exactly on byte count and line count. The synthetic extension to
   100,000 lines is therefore admissible.
3. **Host conditions.** Load 1.49 before and after, AC power, low-power off.
   **One earlier invocation was discarded, and is recorded rather than
   hidden**: it read load 2.97 before and after, above the 2.5 the rule freezes,
   because `swift test` compiled the newly added file in the same command and
   the probe then measured itself under its own build. Its numbers were within a
   few percent of the ones above, which is exactly why discarding it had to be
   automatic -- a gate that is only honoured when it would change the answer is
   not a gate. The quoted run pre-builds and waits for the machine to settle.
4. **Coverage.** `n=9` beside every median, with min and max.

#### Observation 3 -- the cost per line is not constant with depth, measured rather than interpolated

Descriptive ladder, width 179 -> 100, nanoseconds per logical line:

| class | source | 10,000 | 30,000 | 100,000 |
| --- | --- | ---: | ---: | ---: |
| `mix` | `arena` | 1.60 | 1.70 | 5.49 |
| `mix` | `counts` | 0.68 | 0.68 | 0.68 |
| `full` | `arena` | 1.57 | 2.17 | 5.50 |
| `full` | `counts` | 0.68 | 0.72 | 0.68 |

The middle point was measured rather than assumed, because two points would not
have shown that the `arena` source's per-line cost is flat to 30,000 lines and
then roughly triples by 100,000 while `counts` stays flat throughout. The
mechanism this is consistent with is cache residency: at 100,000 lines the arena
is 172 MB (`mix`) or 287 MB (`full`) and the header chase touches one line per
~2.9 KB of it, while the dense counts array is 800 KB at the same depth and
stays resident. This is an explanation the data fits, not an attributed cause --
no counter was read.

A depth where this matters is far away and probably unreachable: at 100,000
lines of wide content the arena is 172-287 MB, which the 10 MiB byte budget
(`28/F23`: peak 3.38 MB observed) would have evicted from long before. **H2's
100,000-line bound therefore stresses a depth the current byte budget makes
unreachable**, which is the right way to test a bound and the wrong way to
describe a workload.

#### Observation 4 -- an instrument caveat, recorded because it is visible in the numbers

The `counts` source reads 0.013 ms at 10,000 lines in the main measurement and
0.007 ms in the ladder, at the same depth and width. The difference is that the
main measurement holds a 172-287 MB neighbour arena resident while it measures
the small ones and the ladder does not. Both are three orders of magnitude
inside every bound, so nothing here turns on it -- but it is the size of the
effect memory pressure has on this instrument, and a future reading that wants
tighter resolution than that should not take these cells as interchangeable.

- Observation: the eager block-total recompute costs 0.015-0.016 ms at 10,000
  logical lines and 0.545-0.641 ms at 100,000, for the count-source the
  candidate direction actually sketches, at both content classes and for
  narrowing, widening and same-width rebuilds.
- Inference: `H2` holds. Recounting display rows is cheap enough that a resize
  under this design has no meaningful history-side cost, which is the property
  the whole doc trades reflow away for. The eager choice needs no defence at
  milestone 1, and the index can stay as sketched -- offsets only, no parallel
  counts array.
- Competing interpretations:
  - *The loop was optimized away.* Refuted by gate 1: every pass's total was
    consumed and cross-checked, and the totals differ correctly by width.
  - *The synthetic arena is not the real one.* It is not, and that is why gate 2
    exists: at the depth where both can be built they agree within 6.2%. What
    the synthetic arena reproduces is geometry -- record sizes, header offsets,
    total footprint -- which is all the counting pass touches.
  - *This is fast because the stimulus is small.* The ladder is the answer: the
    per-line cost does grow, and it is still 0.64 ms at a depth the byte budget
    makes unreachable.
  - *A microbenchmark is not a resize.* Correct, and this entry does not claim
    otherwise -- see Uncertainty.
- Uncertainty:
  - **The pass is not the resize.** A resize also refolds the live screen, which
    this design does not remove and this probe does not measure. F2 prices the
    term the design deletes reflow *into*, not the whole event.
  - **No lookup follows the recompute here.** The index is rebuilt and then
    thrown away; a real width change is followed by reads, which Part A measured
    separately and which this entry does not compose with.
  - **Nothing about eviction.** An arena that has evicted from its front has a
    different offset structure than one that only ever grew. Unmeasured.
  - **One machine, one session.** As with `F1`.
- Next action: `D1` Part B advances -- `F2` is in, `F3` (admission) and `F4`
  (the edge-case inventory, which can still make `D1` no-go) remain. Two things
  this entry hands forward: keep the index offsets-only (the primary
  count-source clears the bound without the parallel array), and if a future
  design does want the counts array, this entry has already priced what it buys
  (4.3x on the pass at 100,000 lines, nothing that matters at trial depth).

### F4 -- 28 edge cases, none requiring stored width, and one arithmetic correction: `ceil(cells / width)` is wrong for lines containing wide cells

- Status: recorded. This is `D1` Part B's third input and the only Phase 1
  input that could have made `D1` no-go regardless of `F1`. **It does not.** No
  case in the inventory requires width-dependent data persisted in history, so
  `H4` is confirmed and the premise survives. What the sweep does produce is one
  correction to the *mechanism* `H1` stated -- display-row count is not
  `ceil(cells / width)` for a line containing wide cells -- and it is a change
  to the derivation, not to what is stored.
- Date and investigator: 2026-08-04, Claude (agent).
- Commit and worktree state: `dbe42f2`, the commit that recorded `F2`. **No
  file under `lib/` is added or changed by this entry** -- it is a reading and
  cataloguing pass. The two untracked paths present throughout this doc's work
  are still present and still in no build: `TODO.md` and
  `docs/scratch/2026-08-04-scroll-sample-breakdown.md`.
- Commands, inputs, or reproduction: the reference trees were read at the pins
  `just fetch-references --list` records, and DanTerm's own reflow behavior was
  read from `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` and its
  resize/wrap test suites. Observation 1's counter-example was executed against
  the real engine through a throwaway test in
  `lib/TerminalCore/Tests/TerminalCoreTests/`, deleted before this commit; its
  body is quoted below so the reading is reproducible from the doc alone.
- Artifacts: none durable.

#### What was swept

Seven implementations, chosen because most store display rows and rewrap
destructively while iTerm2 -- the doc's stated existence proof -- stores raw
lines and wraps at read, which is this design's category:

`references/iterm2/sources/LineBlock.mm`, `references/kitty/kitty/resize.c`,
`references/foot/grid.c#grid_resize_and_reflow`,
`references/wezterm/term/src/screen.rs#rewrap_lines`,
`references/vte/src/vte.cc`,
`references/windows-terminal/src/buffer/out/textBuffer.cpp#TextBuffer::Reflow`,
`references/alacritty/alacritty_terminal/src/grid/resize.rs`. Plus DanTerm's own
reflow -- `Terminal.swift#reconstructLogicalLines` and `Terminal.swift#pack`,
which already build and repack logical lines, destructively, at every width
change -- and the tests that pin it.

One correction to the README's framing fell out of the sweep and is recorded
rather than left standing: **vte is a second, partial member of the category.**
Its scrollback is a UTF-8 text stream plus an attr stream, and the wrap points
live in a separate row stream that `references/vte/src/ring.hh`'s own comment
describes as "(This stream is regenerated when the contents rewrap on resize.)"
-- so vte's *stored text* is already width-free, exactly as this design wants.
What vte does not do is defer the regeneration: `references/vte/src/ring.cc#Ring::rewrap`
rebuilds the row stream eagerly at resize instead of deriving wrap points at
read. It is therefore the halfway house between today's DanTerm and this doc's
candidate, and it is the closest thing in the sweep to a working reference for
the record format -- including for the parts iTerm2 gets to skip.

DanTerm's existing engine is the most important source in the sweep and is
easily overlooked: **`reconstructLogicalLines` is the admission rule this design
proposes, run backwards.** It joins display rows on `isSoftWrapped`, measures a
soft-wrapped row to full width and a hard-ended row to `retainedContentEnd`,
drops `.spacerHead` cells entirely, and carries one `semanticPrompt` per logical
line. That is exactly the record the arena would store. The design is therefore
not introducing a new normal form; it is deleting the round trip that converts
to it and back on every resize.

#### Observation 1 -- the one correction: display-row count is not `ceil(cells / width)` when the line contains wide cells

`H1` and `F2` both state the mechanism as "per-line display-row counts derived
as `ceil(cells / width)` from the record header". For narrow content that is
exact -- `F1` Observation 2 verified it on all 10,773 logical lines it measured,
and said in terms that it "says nothing yet about wide characters at the last
column, which `F4` owns". It is wrong for wide content, and the counter-example
is small:

    var t = try #require(Terminal(columns: 3, rows: 40))
    t.feed(Array("\u{754C}\u{754C}\u{754C}".utf8))   // three 2-cell clusters, 6 cells

Measured against the real engine: **3 display rows, where `ceil(6 / 3)` predicts
2.** Five wide clusters (10 cells) at width 3 measure 5 rows against a predicted
4. Narrow content and wide content that happens to divide evenly both match, so
this is not a case a casual check finds.

The mechanism is `Terminal.swift#pack`, and it is deliberate:

    if unit.cells.count == 2, columns - column == 1 {
        packedRows[row].cells[column] = GridCell(kind: .spacerHead, ...)
        packedRows[row].isSoftWrapped = true

A 2-cell cluster that meets a row with one column left does not split; a
`.spacerHead` fills the column and the cluster starts the next row. The exact
count is `ceil((cells + spacers) / width)`, and `spacers` -- the number of wide
clusters that land on a boundary -- is a function of *where* the wide cells sit,
so it needs a scan of the record's cells, not a read of its header.

**This is a derivation change, not a storage change.** `spacers` is computed from
(logical line, width) exactly as the design requires; nothing width-dependent is
persisted. Every surveyed implementation that wraps at read pays the same price
in the same place: iTerm2 splits precisely here, with
`references/iterm2/sources/LineBlock.mm#LineBlockNumberOfFullLinesFastPath`
(`MAX(0, length - 1) / width`, i.e. `ceil`) guarded by a flag, falling through
to `references/iterm2/sources/LineBlock.mm#iTermLineBlockNumberOfFullLinesImpl`,
whose whole body is the correction:

    for (int i = width; i < length; i += width) {
        if (ScreenCharIsDWC_RIGHT(buffer[i])) { --i; }
        ++fullLines;
    }

vte reaches the same place from the other side, and its version is worth having
because it shows the correction is intrinsic to the content rather than to
iTerm2's data structure: `references/vte/src/ring.cc#Ring::rewrap` wraps *early*
rather than padding --

    if (col >= columns - attr_change.attr.columns() + 1) {
        /* Wrap now */
        new_record.width = col;
        new_record.soft_wrapped = 1;

-- and records the short `width` on the row. No spacer is stored either way; the
display row is simply narrower than the terminal, which is the same statement as
"the count is not `ceil(cells / width)`".

The intended DanTerm behavior is the same split, with one deliberate divergence.
iTerm2's `mayHaveDoubleWidthCharacter` is a **sticky, buffer-wide, one-way**
flag (`references/iterm2/sources/LineBuffer.m#setMayHaveDoubleWidthCharacter:`
sets it and never clears it, and
`references/iterm2/sources/iTermLineBlockArray.m#setAllBlocksMayHaveDoubleWidthCharacters`
then discards every cached width count), so one CJK character anywhere
permanently downgrades the entire buffer to the scanning path -- which is why
iTerm2 needs three further layers of memoization
(`LineBlock.mm`'s `_numberOfFullLinesCache`, `LineBlockMetadata`'s
`number_of_wrapped_lines`, and
`references/iterm2/sources/iTermDoubleWidthCharacterCache.h`) to make it
tolerable. DanTerm should carry the bit **per record**, in the header flags the
sketch already has: it is a property of one logical line's content, it is known
at admission for free (the admitting row's cells are in hand), and it is
width-independent, so a width change never invalidates it. A record without the
bit keeps the O(1) `ceil`; a record with it pays an O(cells) scan.

The bit is an optimization, not a correctness requirement -- always scanning
would also be correct -- which is the strongest form this finding can take
against `D1`'s no-go trigger: the correction does not even need a stored flag,
let alone stored width.

#### Observation 2 -- the inventory

28 cases. `stored width?` answers `D1`'s no-go trigger directly: **`yes` means
the case is decidable from (logical line, width) plus live-grid state; `flag`
means it additionally wants a width-independent content bit in the record
header; `NO` would be a no-go trigger.** There are no `NO` rows.

| # | input / scenario | intended DanTerm behavior under the logical-line store | stored width? |
| ---: | --- | --- | :---: |
| 1 | wide cluster meets a row with one column left | insert `.spacerHead` at read/refold time, start the cluster on the next display row; never store the spacer | yes |
| 2 | display-row count of a line containing wide cells | `ceil((cells + spacers) / width)`; scan the record when its `hasWideCells` header bit is set, `ceil(cells / width)` otherwise (Observation 1) | flag |
| 3 | cluster wider than the whole pane | unreachable: `Terminal.swift#resize` refuses `columns < 2` and `desiredClusterWidth` caps a cluster at 2 cells. Keep the guard rather than adopting a policy | yes |
| 4 | VS16 upgrades a placed narrow cluster to 2 cells at the last column | live-grid concern only; the relocation happens before the row can scroll off, so history sees the settled cells | yes |
| 5 | multi-scalar grapheme cluster at a wrap boundary | a cluster is one cell (plus its tail), so it is atomic in the record and can never straddle a boundary | yes |
| 6 | cursor sits on a soft-wrapped line during a width change | refold the live screen only; the cursor never anchors into history because a row the cursor is on has not scrolled off | yes |
| 7 | pending wrap (`isPendingWrap`) armed at a width change | live-screen refold keeps today's boundary-anchor rule; `Terminal.swift#pack`'s `boundaryDestinations` moves to the refold, unchanged | yes |
| 8 | cursor parked in trailing blanks past the content end | live-screen refold keeps today's `.trailingPadding` distance rule, including the "squeezed-out trailing blank defers its wrap" clamp | yes |
| 9 | the wrap claim on the last retained row is severed or restored | flip the tail record's open/closed header bit: severing closes the open line, restoring reopens it. No cell is rewritten, and only the tail is touched | yes |
| 10 | a `.spacerHead` on the last retained row is cleared | no-op: the store never held the spacer | yes |
| 11 | alternate screen, width change | never reflowed; clip and pad the rectangle as `Terminal.swift#resizedRectangle` does today. Unaffected by this design | yes |
| 12 | alternate screen, scrollback admission | never admitted; the alt seam in `ScrollbackBuffer`'s reader stays as it is | yes |
| 13 | selection endpoints across a width change | remap through (logical line, cell offset), which becomes the *native* address instead of a transient reflow attachment | yes |
| 14 | search range and hovered/armed hyperlink ranges across a width change | same remap as 13; the four attachment computations in `resizeWidth` collapse into one address conversion | yes |
| 15 | browsing viewport anchor (scroll anchoring) across a width change | content-anchored, as today: the anchor is the top row's first cell, expressed as (logical line, offset) | yes |
| 16 | OSC 133 marks and `.continuation` stamping across a width change | one semantic mark per record (the header's mark slot); continuation rows are stamped at read, as `Terminal.swift#pack` already does | yes |
| 17 | trailing blanks: hard-ended row vs soft-wrapped row | admission measures a soft-wrapped row to full width and a hard-ended row to `retainedContentEnd`, exactly `reconstructLogicalLines`'s rule | yes |
| 18 | two hard-ended lines must not join when widening | two records; a record boundary is a hard newline by construction, so the failure mode is unrepresentable rather than merely tested against | yes |
| 19 | interior spaces of a continued row survive a narrowing | they are ordinary cells in the record; nothing distinguishes them from text | yes |
| 20 | a row emptied mid-line (prompt blanking) must not splice its old width into the next reflow | strictly removed: once a row is admitted its cells are frozen, so no later width change re-measures it. The live-screen rule still applies to rows that have not scrolled off | yes |
| 21 | DECAWM off, printing at the right margin | the row never soft-wraps, so it closes a record at its retained content end; measured: `"\u{1B}[?7l0123456789"` at 5 columns retains `01239` and no wrap flag | yes |
| 22 | hard tabs | already resolved to cursor motion at parse time (`Terminal.swift#execute`, `0x09`); history stores cells, never a tab | yes |
| 23 | styles, BCE padding, wide tails and spacers synthesized at a new width | style ids travel with cells; the synthesized wide tail and spacer inherit the head's style, as `reflowSynthesizesCoherentWideTailsAndSpacerHeads` pins | yes |
| 24 | DECDWL / DECDHL line attributes | not supported by DanTerm and not proposed here. If added, the attribute is a per-line content property that belongs in the record header, still not a stored width | yes |
| 25 | a single logical line with no hard newline, longer than history | one record that grows until the forced-split cap; no reference caps this (Observation 3) | yes |
| 26 | the forced-split cap itself | split at a fixed cell count with a `forcedSplit` header bit so copy, search and text extraction rejoin logically (Observation 3) | flag |
| 27 | eviction at the head of the arena | evict whole records. The head-truncation flag `isHistoryHeadTruncated` becomes always-false, and the budget can undershoot by at most one record, which the cap bounds (deferred decision DD2) | yes |
| 28 | degenerate history of blank rows | blank rows fold into records with near-zero cells, so the byte budget bounds them directly. This is the regime `productionScrollbackRowCap` exists for, and the row cap is on the deletion list | yes |

#### Observation 3 -- the forced-split cap: no reference caps a logical line, so the cap is DanTerm's own bound and needs its own derivation

The README proposes 65,536 cells "to be justified or replaced in F4". The sweep
found **no implementation that caps the length of a single logical line or the
number of display rows one may span.** What each has instead is an aggregate
bound the long line simply consumes:

- iTerm2 grows a block to fit: `references/iterm2/sources/LineBuffer.m#reallyAppendLine:length:partial:width:metadata:continuation:`
  allocates `length + prefix_len + block_size` for a line too long for the
  current block, with the in-source comment "this is the case when the line is
  freaking huge". Its only line-shaped cap is `iTermLineBlockMaxLines = 10000`
  in `references/iterm2/sources/LineBlock.mm#reallyAppendLine:length:partial:width:metadata:continuation:cert:`,
  which bounds lines *per block* to keep serialized state small, not line length.
- kitty: none; the bound is `scrollback_lines` (default 2,000,
  `references/kitty/kitty/options/definition.py`), and
  `references/kitty/kitty/options/utils.py#scrollback_lines` maps a negative
  value to `2 ** 32 - 1`.
- foot: none; the ring is a power of two capped at 2^30 rows in the resize path
  of `references/foot/render.c`.
- alacritty: none per line; `references/alacritty/alacritty_terminal/src/grid/resize.rs#Grid::shrink_columns`
  ends with `reversed.truncate(self.max_scroll_limit + self.lines)`, an aggregate
  row bound (default history 10,000).
- windows-terminal: none; an over-long line circles the ring inside
  `references/windows-terminal/src/buffer/out/textBuffer.cpp#TextBuffer::Reflow`.
- wezterm: none in `references/wezterm/term/src/screen.rs#Screen::rewrap_lines`,
  which joins a logical line unboundedly. It does cap logical-line *scanning* at
  `MAX_LOGICAL_LINE_LEN: usize = 1024`, declared inside both
  `references/wezterm/term/src/screen.rs#Screen::for_each_logical_line_in_stable_range`
  and its `_mut` twin, with the comment "Avoid pathological cases where we have
  eg: a really long logical line (such as 1.5MB of json) that we previously
  wrapped." That is the closest precedent in the sweep to a per-logical-line
  bound, it names exactly the input this doc's open question names, and it is
  still a *consumer* limit rather than a storage split.

Two near-precedents, then, and both degrade a feature rather than split the
line. vte's is the second:
  `references/vte/src/vtedefines.hh` defines
  `VTE_RINGVIEW_PARAGRAPH_LENGTH_MAX 500` -- "Maximum length of a paragraph, in
  lines, that might get proper RingView (BiDi) treatment" -- consumed by
  `references/vte/src/ringview.cc#RingView::update` and
  `references/vte/src/bidi.cc#BidiRunner::paragraph`. Past 500 display rows vte
  keeps the paragraph whole and gives up a *feature* on it.

So the cap is not a compatibility requirement, and the references supply no
number to adopt -- 1,024 cells and 500 display rows are thresholds past which a
*feature* is dropped, not lengths a store refuses to hold. What they do supply
is the shape of the argument: every one of them bounds *the store*, and lets one
line consume as much of that bound as it wants. DanTerm's reason for a cap is narrower and real -- the arena is one
contiguous region, a record must fit inside it, and eviction granularity is one
record (case 27) -- so the cap should be derived from the arena rather than
guessed.

**The proposed 65,536 already is that derivation, and the entry records it
rather than leaving it a guess.** A C1 cell is one `UInt64` (8 bytes;
`PackedRetainedRow.swift`'s `Header.cellStyleShift` and the `u64` accessors), the
production byte budget is `Terminal.productionScrollbackBudgetBytes` =
16,777,216, and `65,536 x 8 = 524,288` bytes = **1/32 of the arena**. Stated as a
rule -- *no single record may exceed 1/32 of the byte budget* -- the number
follows from the budget instead of from taste, moves with it, and bounds both
hazards it exists for: the worst-case eviction undershoot is 1/32 of history,
and the worst-case in-block wide-cell scan (Observation 1) is 65,536 cells.
Recorded as a derivation offered by F4, to be ratified in Phase 2 (DD3).

For scale on what a real pathological line costs: at 179 columns a
65,536-cell record is 367 display rows, and at the minimum 2 columns it is
32,768 -- under `productionScrollbackRowCap`'s 89,500, so a single forced-split
segment cannot alone exhaust any current bound.

#### Observation 4 -- where the references disagree, and what DanTerm does

Six disagreements matter to this design. In each, DanTerm's existing behavior
is already pinned by its own tests, so the intended behavior is "keep it", and
the reference split is recorded so it is not re-litigated.

| question | the split | DanTerm |
| --- | --- | --- |
| selection across a width change | **cleared:** kitty (`references/kitty/kitty/screen.c#screen_resize` calls `clear_all_selections`), alacritty (`references/alacritty/alacritty_terminal/src/term/mod.rs#Term::resize`: `if old_cols != num_cols { self.selection = None; }`). **remapped:** foot (tracking points through `references/foot/grid.c#grid_resize_and_reflow`), iTerm2 (`references/iterm2/sources/VT100ScreenMutableState+Resizing.m#convertRange:toWidth:to:inLineBuffer:tolerateEmpty:`), vte (markers 4 and 5 of the seven in `references/vte/src/vte.cc#Terminal::screen_set_size`, with block selection alone cleared) | remap, and keep remapping: `TerminalResizeTests` and `TerminalSelectionTests` pin it, and the logical-line store makes the remap cheaper, not harder (case 13) |
| a cluster wider than the pane | **discarded:** kitty (`references/kitty/kitty/resize.c#multiline_copy_src_to_dest`). **replaced by a blank:** foot (`references/foot/grid.c#grid_resize_and_reflow`) | unreachable behind the `columns >= 2` guard; adopt neither policy (case 3) |
| trailing blanks on a continued row | **trimmed:** kitty trims unwritten cells only (`references/kitty/kitty/resize.c#init_src_line`), windows-terminal trims to `MeasureRight` (`references/windows-terminal/src/buffer/out/Row.cpp#ROW::MeasureRight`, which returns full width for a wrap-forced row). wezterm trims by *character*, `references/wezterm/wezterm-surface/src/line/line.rs#Line::wrap` truncating at the last cell whose `str() != " "`, which also discards a blank carrying a non-default background. **not trimmed:** foot explicitly re-extends a continued row to full width; vte does not trim in `Ring::rewrap` at all and instead shrinks rows at write time and strips trailing nondefault-background blanks at read (`references/vte/src/vte.cc#Terminal::get_text`) | full width for a soft-wrapped row, `retainedContentEnd` for a hard-ended one -- the same rule, and already what `reconstructLogicalLines` does (case 17). Note DanTerm trims by cell *kind*, not by character, so wezterm's BCE-blank loss is not reachable here; `bceOnlyPaddingRemainsStyleBlindAcrossResize` pins that |
| viewport across a width change | **numeric:** kitty leaves `scrolled_by` untouched. **content-anchored:** foot adds the viewport to its tracking points; vte anchors on the row below the bottom visible row, after two special cases for "was at bottom" and "was at top" (`references/vte/src/vte.cc#Terminal::screen_set_size`) | content-anchored, pinned by `resizePreservesBrowsingAnchor` (case 15) |
| hard tabs in history | **not stored:** wezterm (`references/wezterm/term/src/terminalstate/mod.rs#TerminalState::c0_horizontal_tab` moves the cursor and writes nothing), kitty, foot. **stored:** vte writes a real `'\t'` cell spanning up to `VTE_TAB_WIDTH_MAX` = 15 columns when the tab lands past existing content (`references/vte/src/vteseq.cc#Terminal::move_cursor_tab_forward`), and the span survives its rewrap unchanged rather than re-snapping to the new tab stops | not stored, as today (case 22). vte's smart tab is worth knowing exists -- it is a per-cell content property, so it would fit a record header without introducing a width -- but it buys copy fidelity DanTerm has not asked for |
| DECDWL / DECDHL line attributes | **unimplemented:** vte stubs all three (`references/vte/src/vteseq.cc#Terminal::DECDWL`: "Probably not worth implementing"). **implemented and silently dropped by reflow:** wezterm sets `LineBits` in `references/wezterm/wezterm-surface/src/line/line.rs#Line::set_double_width` but `#Line::wrap` builds fresh rows with `bits = NONE`, and its `#test_dec_double_width` performs no resize, so the loss is untested. **partially handled:** windows-terminal refuses to reflow a non-single-width row and force-newlines around it | unimplemented, and this doc does not propose adding it (case 24). If it is ever added, wezterm's silent drop is the failure to avoid |

Where the sweep *agrees* is worth one line, because it is the shape cases 6-8
and 13-15 all want. Every implementation that remaps anything across a width
change converts (row, column) into an offset into the unwrapped logical text,
carries it through, and converts back. vte's is the most complete and is the
model to take to Phase 2: `CellTextOffset { text_offset, fragment_cells,
eol_cells }` (`references/vte/src/ring.hh`, `Ring::CellTextOffset`), computed by
`references/vte/src/ring.cc#Ring::frozen_row_column_to_text_offset` and reversed
by `#Ring::frozen_row_text_offset_to_column`. The three fields are exactly the
three cases DanTerm's reflow anchor enum already distinguishes -- an offset in
the line, a position *inside* a wide cluster, and a position at or past
end-of-line -- and vte carries seven such markers simultaneously (cursor, saved
cursor, below-viewport, below-current-paragraph, two selection endpoints).
DanTerm carries ten today, through the four `attachments` computations in
`Terminal.swift#resizeWidth`. Under the logical-line store that offset *is* the
stored address, so the conversion happens once at the boundary instead of twice
per resize.

#### Observation 5 -- the immutability premise survives, but only because every history mutation is confined to the tail record

The design says "scrolled-off content is immutable, so the open line only ever
grows at its end". That is a claim about today's engine, and today's engine does
write into retained history. Every such write was enumerated: there are exactly
three, all in `Terminal.swift`, and **all three target
`scrollbackRows.indices.last` and no other index**:

- `Terminal.swift#severScrollbackWrapClaim` -- clears `isSoftWrapped` and
  replaces a trailing `.spacerHead`, reached only through
  `Terminal.swift#severWrapClaim(before:replacementStyleId:)` at row 0.
- `Terminal.swift#restoreWrapClaimBeforeCursor` -- sets `isSoftWrapped` back to
  true on the last retained row.
- `Terminal.swift#clearPreviousSpacer` -- clears a `.spacerHead` on the last
  retained row when column 0 or 1 of the top viewport row is cleared.

Under the logical-line store these become: close the open record, reopen it, and
nothing at all (the spacer was never stored). All three are header-bit flips on
the arena's tail, which is the one record the append path already writes. The
premise holds, and the cases are 9 and 10 in the inventory.
`TerminalInspectionInvalidationTests`' "scrollback-tail wrap and spacer edits
invalidate that retained row" is the existing test that pins this surface, and
it is the test to re-point at the new store.

**Amended 2026-08-04 by [`D3`](decisions.md), which measured what these three
writes actually store.** "All three become header-bit flips" is true only when
the background-erase style is the default one. Under a non-default style,
`severScrollbackWrapClaim` replaces the trailing `.spacerHead` with a *styled*
blank that `pack`'s canonical extent keeps and the renderer paints (`F6` `HR3`),
and `clearPreviousSpacer`'s scrollback branch does the same through EL and DCH at
row 0 while leaving the row **soft-wrapped** -- so case 10's "no-op" and case 9's
"no cell is rewritten" both hold in the default case only. `D3` Decision 3
measured all four states and materializes the styled blank as a **tail append of
at most one cell**, so the premise this observation exists to defend -- mutation
is confined to the tail -- survives unchanged, while "these are bit flips" does
not.

**Amended again 2026-08-04 by the plan's `DD25` amendment, which settles case 17's
other half.** Case 17's rule ("a hard-ended row is measured to
`retainedContentEnd`") is unchanged as a rule about **cells**, and it is now only
half the admission rule: the blank, non-default-styled run that reaches the right
margin of a hard-ended row -- the same run `pack`'s canonical extent keeps and
`reconstructLogicalLines` drops -- is admitted as the record's **trailing fill
style**, an attribute rather than cells. So the store loses neither way: the
painted read reproduces today's stored row column for column at the admitting
width, the content read (copy, search) still stops at `retainedContentEnd`, and no
width turns a painted tail into extra display rows. Case 10's "the store never
held the spacer" is untouched; case 9's sever is untouched (`D3` Decision 3's
mechanism stands, with its unification recorded there as an option not taken).

#### Deferred decisions

Recorded here so a human can revisit; each took the obvious, simple choice
rather than blocking.

- **DD1 -- selection is remapped, not cleared, across a width change.** Two
  references clear it (Observation 4). Keeping DanTerm's remap is chosen because
  it is existing pinned behavior and this design makes it cheaper; the
  alternative would be a user-visible regression taken for implementation
  convenience.
- **DD2 -- eviction evicts whole records.** The simple choice. The cost is that
  `isHistoryHeadTruncated` becomes always-false and the byte budget can
  undershoot by up to one record. The alternative -- advancing a head offset
  inside the first record so eviction stays display-row granular -- is real and
  cheap to add later, and is not needed for milestone 1.

  **Amended 2026-08-04 by [`D2`](decisions.md), which takes the alternative
  above for milestone 1 after all.** The entry above priced the granularity as a
  *memory* consequence only; `F6` `HR5` found it is also user-visible -- a
  whole-record step drops up to 367 display rows at 179 columns, clamping four
  anchors and jumping the browsing viewport. `D2` Decision 2 evicts
  display-row-granularly at the head (whole records while they fit, then a trim
  of the head record's prefix with its header rewritten in place), so no anchor
  moves further per admitted row than it does today. This paragraph stands as
  the original reasoning; the decision it recorded is superseded.
- **DD3 -- the forced-split cap is 65,536 cells, stated as "no record exceeds
  1/32 of the byte budget".** Same number the README proposed, now with a
  derivation (Observation 3) instead of a guess. Reopen if the budget changes
  shape or if Phase 2 finds the eviction granularity or the wide-cell scan binds.
  **Ratified 2026-08-04 by [`D2`](decisions.md)**, which keeps the budget at
  16,777,216 on a new derivation, so the cap stays 65,536 cells and it is the
  *rule* that is adopted: the cap moves if the budget does.
- **DD4 -- the `hasWideCells` header bit is carried per record, not per buffer.**
  iTerm2's buffer-wide sticky flag is the alternative and is rejected on
  DanTerm's own constraint: a per-record bit costs one flag in a header that
  already exists, is computed free at admission, and never needs the three
  memoization layers iTerm2 added to survive its own pessimism.

- Observation: 28 edge cases were catalogued from seven reference
  implementations and DanTerm's own reflow path and tests. Every one is
  decidable as a pure function of (logical line, current width) plus live-grid
  state. **Zero cases require width-dependent data persisted in history.** One
  case (2) corrects the arithmetic `H1` and `F2` assumed, and one (26) wants a
  `forcedSplit` marker; both are content properties, not widths.
- Inference: `H4` is **confirmed** and `D1`'s no-go trigger does not fire. The
  design's core premise -- nothing width-shaped survives in storage -- holds
  against the full set of inputs the references' test suites exist to surface.
  Two things it hands to Phase 2 beyond the table: display-row counting needs a
  per-record `hasWideCells` bit and an O(cells) fallback, and the forced-split
  cap now has a derivation rather than a guess.
- Competing interpretations:
  1. *The inventory is only as good as the sweep, and a case was missed.* The
     honest limit of a cataloguing pass. Two things bound it: the sweep is
     anchored on DanTerm's own reflow implementation and its ~40 resize/wrap
     tests, which is a set already hardened against real incidents, and the
     references were read for their *tests* as well as their code precisely
     because a test suite is a record of what bit somebody. What would change
     the answer is a case that needs stored width. The two trees that separate
     text from wrap points -- iTerm2 and vte -- both keep every width-derived
     number in a structure they are willing to throw away
     (`references/iterm2/sources/iTermLineBlockArray.m#setAllBlocksMayHaveDoubleWidthCharacters`
     discards the whole cache collection; vte's row stream "is regenerated when
     the contents rewrap on resize"), which is weak but real evidence that the
     category is empty.
  2. *Case 2 is really a no-go in disguise -- a scan is a hidden cost, and a
     hidden cost is a hidden dependency on width.* It is not: the scan reads the
     record's own cells and the current width, both of which the design already
     has. The flag that avoids the scan is a content property. `D1`'s trigger is
     "requires storing wrap or width state", and no reading of case 2 reaches it.
  3. *`ceil` was always known to be wrong and this finding is bookkeeping.* `F1`
     Observation 2 explicitly reserved the question for `F4` rather than
     assuming either answer, and `F2` measured a pass built on the `ceil`
     assumption. Recording the correction is what keeps `F2`'s number from being
     quoted at content it does not cover -- see Uncertainty.
- Uncertainty:
  - **`F2`'s counting pass is priced for narrow content only.** Its `mix` and
    `full` stimuli are ASCII, so every line took the O(1) `ceil` path. A history
    of CJK or emoji output makes the eager pass an O(cells) walk of the flagged
    records. `H2` cleared its bound by 15.6x, so there is margin, but the margin
    is not measured against a wide-content stimulus and must not be assumed to
    transfer. This is a named Phase 2 measurement, not a resolved question.
  - **The forced-split cap is derived, not measured.** Observation 3 gives it a
    rule; no pathological input (`cat` of a binary, minified JSON) was fed to a
    real engine to see what a session actually produces.
  - **`references/windows-terminal/` in this checkout is partial** -- it has
    `src/buffer/`, `src/terminal/`, `src/types/` and no `src/host/` or
    `src/cascadia/` -- so its alternate-screen and selection behavior could not
    be read, and cases 11-13 rest on the other six trees. Its reflow and cursor
    evidence is complete.
  - **iTerm2 has no LineBuffer unit tests in this tree.** Every iTerm2 citation
    above is production code, and the category's existence proof is therefore an
    argument from a shipping implementation rather than from its test suite.
  - **The inventory is decisions, not code.** Nothing here has been implemented
    or measured end to end; each row is a claim about what the design must do,
    to be discharged by Phase 2's call-site enumeration.
- Next action: `D1` Part B has `F4` in and its verdict is unchanged in
  direction -- **still `go` on Part A, still open on Part B, and the no-go
  trigger is now known not to fire.** Owed: `F3` (the admission probe) and the
  simplification inequality. Two amendments this entry writes back into the
  README: `H1`'s and the candidate direction's `ceil(cells / width)` becomes
  "`ceil` for narrow records, scan for wide ones", and the forced-split cap's
  open question closes into DD3's derivation. One new open question opens: the
  eager counting pass is unpriced on wide content.

### F3 -- admission is not the residual either: open-line append admits a scrolled-off row 1.45x-1.60x faster than today's pack-per-row, including on `scrollback-stream`'s own row shape

- Status: recorded. `H3` **confirmed** under `31/D1`'s Part B rule for F3, frozen
  at `d6c83b0` before this probe existed in the tree. This is `D1` Part B's
  fourth and last measured input; it **cannot and does not close `D1`**, whose
  remaining debt is the simplification inequality alone. It licenses no
  production storage change, and `28/H7` stays the fallback until `D1` closes.
- Date and investigator: 2026-08-04, Claude (agent).
- Commit and worktree state: `d6c83b0` (the commit that froze this rule, written
  before this probe existed in the tree), plus the one file this entry adds --
  `lib/TerminalCore/Tests/TerminalCoreTests/TerminalLogicalLineAdmissionProbe.swift`,
  committed with it. **No file under `lib/TerminalCore/Sources/` is touched, and
  neither F1's nor F2's probe file is edited** -- the two admitters are new types
  in F3's own file, because F1's stores are read-oriented and built whole rather
  than incrementally. The two untracked paths present throughout this doc's work
  are still present and still in no build: `TODO.md` and
  `docs/scratch/2026-08-04-scroll-sample-breakdown.md`.
- Conditions: AC power, low-power mode off. One-minute load average **1.00
  before and 1.00 after**, well under the 2.5 gate `28/F15` established and `D1`
  adopted. Release configuration, headless, one process. The build was completed
  and the machine allowed to settle before the measured invocation, per `F2`'s
  gate-3 lesson.
- Commands:

      DANTERM_LOGICAL_LINE_PROBE=1 swift test -c release \
          --package-path lib/TerminalCore --filter TerminalLogicalLineAdmissionProbe

- Artifacts: none durable. Every number below is stdout from the probe above and
  is reproduced by re-running it; the probe prints its own gate outcomes.
- **No invocation was voided.** All six gates held on the first measured run.
  (The calibration test alone was run once beforehand to check the two new
  content classes; it produces no timing, and its calibration figures are
  identical to the measured run's.)

#### What was compared

Both arms admit the **same** engine-produced display rows, in the same order:
the rows a real `Terminal` at 179x66 retained, taken through
`retainedRowForTesting(at:)` and **materialized to full width**, because that is
the shape production admission is handed from the live grid -- `pack`'s first
walk covers every column, and charging the baseline a shorter walk than
production pays would understate it.

- **Baseline** -- today's admission, reproduced from
  `Terminal.swift#appendToScrollback`: `PackedRetainedRow.pack` per display row
  (the production encoder, which trims to canonical extent as it encodes), an
  append into the retained buffer, and the two accumulations that call site
  performs -- `Terminal.swift#scrollbackByteCost(of:)` into the charged byte
  total and `storedCellCount` into the stored-cell total. `ScrollbackBuffer` and
  `scrollbackByteCost` are `private` to `Terminal`, so the arm reproduces the
  append, the storage and the byte-cost arithmetic rather than calling them.
  That substitution is F3's stated fidelity limit, exactly as it was F1's.
- **Candidate** -- doc 31's open-line rule with `F4`'s corrected semantics: the
  row's cells are appended at the arena's write cursor into the **open** record,
  `.spacerHead` cells are dropped on the way in (`F4` case 10 -- the store never
  held one), a row that is not soft-wrapped closes the record and writes its
  header bits (`hasWideCells`, `forcedSplit`), and **the only record ever
  written is the tail** (`F4` Observation 5). Per-cell work is identical to the
  baseline's by construction, down to the zero-word omission `pack` makes, which
  is what leaves a *per-row* difference to measure.

#### Observation 1 -- the four measured classes, and the verdict D1's F3 rule reads off them

Median over 5 ABBA rounds of nanoseconds per admitted display row, at ~10,000
display rows and 179 columns. Sample count: 10,000 admitted rows per arm per
round (10,001 for `wide`), `n=5` rounds.

| class | verdict-bearing | baseline | candidate | ratio | saving | A/A control | `D1` F3 rule | result |
| --- | :---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
| `mix` | yes | 623.1 ns | **389.1 ns** | **0.624x** | -234.0 ns/row | +0.18% | <= 1.00x confirms | **confirm** |
| `full` | yes | 642.4 ns | **444.0 ns** | **0.691x** | -198.4 ns/row | +0.49% | <= 1.00x confirms | **confirm** |
| `stream` | yes | 484.5 ns | **302.4 ns** | **0.624x** | -182.1 ns/row | -0.15% | <= 1.00x confirms | **confirm** |
| `wide` | **no** | 749.4 ns | 407.2 ns | 0.543x | -342.2 ns/row | -0.02% | outside the verdict | observation |

Every A/A control is under 0.5%, so all four differences are two orders of
magnitude outside the instrument's resolution. Every verdict-bearing class is at
or under 1.00x, so **`H3` is confirmed outright** rather than landing in the
neutral band: admission does not merely get no worse, it gets **1.45x to 1.60x
cheaper per admitted row**. The reject bound -- 1.09x, the ratio that would
predict a `slower` verdict on `scrollback-stream` -- is not approached from
either side.

The class that matters most to `H3` is `stream`, and it behaves like the others.
`28/F20` Observation 5 established that `benchmark/scrollback-stream` -- the
workload `H3` names as its falsifier -- retains **hard-ended CRLF rows that never
soft-wrap**, because its producer writes `\n` through a tty whose Darwin default
`OPOST|ONLCR` converts it. That is the *worst* case for this design's stated
mechanism ("fewer records, less per-row header work"): the candidate creates
**one record per display row, exactly as many as the baseline** (10,000 and
10,000, measured). It is still 0.624x. So the win is not the record-count
reduction the sketch predicted.

All six validity gates held on the quoted invocation:

1. **Cross-arm equivalence:** both stores were read back display row by display
   row, outside every timed region, and checksummed over every scalar, style id
   and kind. **Checksums identical and display-row counts equal on all four
   classes.** That is the gate that holds the candidate to re-deriving what it
   refused to store: on `wide` it must re-insert 5,124 `.spacerHead` cells at
   read, from (record cells, width) alone, and it does -- the checksums would not
   match otherwise.
2. **Non-elision:** each arm's per-round product (records, bytes, rows/cells,
   folded) matched the value computed outside the timed region on every round,
   and no product was the empty store's.
3. **Stimulus calibration** (Observation 2), all four in band.
4. **A/A resolution:** +0.18% / +0.49% / -0.15% / -0.02%, all far under the 5%
   ceiling.
5. **Host conditions** as recorded above.
6. **Coverage:** every aggregate printed with its round count and its admitted-row
   count.

#### Observation 2 -- the stimuli, calibrated before any arm was timed

| class | display rows | logical lines | rows/line | soft-wrapped | spacers | median cells | p95 | mean | gate |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `mix` | 10,000 | 5,758 | 1.74 | 42.4% | 0 | 149 | 179 | 124.2 | median in [119,154], p95 179 -- **pass** |
| `full` | 10,000 | 5,013 | 1.99 | 49.9% | 0 | 179 | 179 | 179.0 | median and p95 179 -- **pass** |
| `stream` | 10,000 | 10,000 | 1.00 | **0.0%** | 0 | 60 | 60 | 60.0 | median in [55,65], soft-wrap 0 -- **pass** |
| `wide` | 10,001 | 4,877 | 2.05 | 51.2% | **5,124** | 179 | 179 | 135.1 | >=50% wide rows (100%), >=1 spacer -- **pass** |

`mix` reproduces Part A's calibration exactly (median 149, p95 179, mean 124.2),
which is the cheapest available check that F3 and F1 measure one content model.
`stream`'s template is `benchmarks/fixtures/terminal-app.json`'s
`scrollback-stream` segment verbatim, fed with CRLF as the tty delivers it; it
measures **60** stored cells per row against `28/F20` Observation 5's "~59",
which is that entry's own rounding of the same 60-character line. `wide` puts a
wide cell in 100% of admitted rows and produces 5,124 spacers -- roughly one per
soft-wrapped row, as expected at 179 columns where 89 two-cell clusters fill 178
and the 90th meets a one-column gap.

#### Observation 3 -- the saving is per *row*, not per cell, and today's admission is ~90-95% encoder

Two readings, taken together, say what the difference is made of.

The saving barely responds to cell count. `stream` admits 60 stored cells a row
and saves 182.1 ns; `full` admits 179 -- three times as many -- and saves 198.4
ns, 1.09x as much. If the candidate were winning per cell, `full`'s saving would
be about triple `stream`'s. **It is a per-row constant**, which is the signature
of the thing the candidate deletes: one heap allocation and one
`PackedRetainedRow` value per admitted row, against a store at a cursor.

The descriptive decomposition says the same thing from the baseline's side.
Median ns per row over 5 rounds, **not interleaved** -- these three arms run in
sequence, so they are comparable to each other and *not* to Observation 1's
interleaved figures (the `whole` column reads 4-11% above Observation 1's
baseline for exactly that reason, which is itself a measured statement about
what interleaving is worth):

| class | `pack` only | `pack` + buffer append | whole path (+ accounting) | encoder's share |
| --- | ---: | ---: | ---: | ---: |
| `mix` | 613.9 | 654.7 | 666.4 | 92.1% |
| `full` | 639.5 | 701.5 | 711.6 | 89.9% |
| `stream` | 497.0 | 512.0 | 524.7 | 94.7% |
| `wide` | 740.7 | 786.9 | 810.3 | 91.4% |

So the buffer append is 2.5-8.7 points of today's admission and the byte and
cell accounting 1.2-2.9 points; **the encoder is everything else.** A design
that kept `pack` and only changed the container could therefore recover at most
about a tenth of what the candidate recovers, which is the answer to the
competing interpretation that this is a container win.

#### Observation 4 -- the arena is also smaller than what the budget charges today, descriptively

Outside `D1`'s rule. The candidate's exact arena footprint against the byte total
today's budget charges for the same content, at the same depth:

| class | records | charged today | arena | ratio |
| --- | ---: | ---: | ---: | ---: |
| `mix` | 5,758 | 11,154,016 B | 9,982,856 B | 0.895x |
| `full` | 5,013 | 15,520,000 B | 14,360,104 B | 0.925x |
| `stream` | 10,000 | 6,560,000 B | 4,880,000 B | **0.744x** |
| `wide` | 4,877 | 12,077,312 B | 10,805,592 B | 0.895x |

The mechanism is per-record overhead: today every display row pays a 16-byte
buffer slot plus a 32-byte array header plus its blob's bucket rounding, while
the arena pays an 8-byte header per *logical line* and nothing per row.
`stream`'s 0.744x is the extreme because its rows are short, so the fixed 48
bytes a row costs today is a large share of its ~487-byte blob. This is a
byproduct, not a claim about eviction or about what the budget should be; it is
recorded because Phase 2 will have to decide what "the byte budget is the arena
size" admits.

- Observation: at ~10,000 admitted display rows and 179 columns, open-line
  append into a contiguous arena admits a scrolled-off row **faster** than
  today's pack-one-record-per-display-row admission on every content class
  measured -- 0.624x (`mix`), 0.691x (`full`), 0.624x (`stream`), 0.543x
  (`wide`, outside the verdict) -- with A/A controls under 0.5%, identical
  cross-arm checksums, and calibrated stimuli.
- Inference: `H3` is confirmed, in the direction it declined to assume. The
  campaign's residuals (`28/F20`: `scrollback-stream` +4.13%, `terminal-feed`
  +4.55% against pre-packing) are not made worse by the storage change this doc
  proposes, and the part of them that lives in admission's *encoding and storing*
  gets cheaper. The mechanism the numbers support is the same one `F1` found on
  the read side and `28/F17`/`28/F20` found twice before that: **the cost is the
  allocation and write pattern, not the encoding.** Today's admission allocates a
  blob per display row; the candidate writes the identical cell words at a cursor
  in a region it already owns.
- Competing interpretations:
  1. *The win is the container -- the buffer append and the accounting -- and is
     recoverable inside today's design.* **Measured and refuted** (Observation 3):
     those two together are 5-10% of today's admission, and the candidate's
     margin is 31-38%.
  2. *The win is per-cell work the candidate skips.* **Refuted by the shape of
     the saving** (Observation 3): tripling the stored cells per row from 60 to
     179 moves the saving by 9%, not by 200%. The cross-arm checksum independently
     proves the two arms produced the same cell words, so no per-cell work was
     skipped.
  3. *The residual `28/F20` measured is scheduling, not encoding, so making
     encoding cheaper does not remove it.* **Not refuted, and it is the most
     important limit on this entry.** The doc's own `H3` says so, citing `28/H8`.
     F3 measures admission in isolation, in one thread, with no PTY, no actor hop
     and no backpressure; it can see the encode-and-store term and nothing else.
     A -37.6% change in a term `28/F20` sampled at 19.7% of the drain thread
     *predicts* roughly -7% on `scrollback-stream`'s block, but that is a
     conversion through a share, exactly the kind of derivation `F1` was careful
     to label a prediction. Only the paired ladder against a real implementation
     can settle it.
  4. *The arms differ in what they store.* Both lost `hyperlinkId` and
     `contentIdentity`, so neither builds a side table -- the same strip Part A
     made, conservative toward the baseline for the same reason (under the
     candidate an identity run table would be built once per logical line rather
     than once per display row).
- Uncertainty:
  - **No eviction.** Today's `enforceScrollbackBudget` / `removeFirst` against
    `DD2`'s whole-record eviction is not measured here, by the frozen rule.
    Both arms grow into a store that is never bounded, and a real pane at steady
    state evicts on every admitted row. This is the largest thing F3 does not
    see, and it is Phase 2's.
  - **A microbenchmark is not a workload.** Parsing, grid mutation and damage all
    run before admission on a real feed, and none of it is here. The -7%
    prediction above is a conversion, not a measurement.
  - **One depth, one geometry, one machine, one session.** ~10,000 display rows
    at 179x66, as with `F1` and `F2`.
  - **The `wide` margin is larger and unattributed.** `wide` costs the baseline
    749.4 ns/row against `full`'s 642.4 while storing *fewer* cells per row (mean
    135.1 against 179.0), so its extra cost is per-cell work on wide clusters
    that the candidate also performs. Why the candidate's absolute saving is
    nonetheless 342 ns rather than ~200 is not explained by the per-row constant
    Observation 3 establishes, and no counter was read. It is recorded as an
    observation and not built on.
  - **The forced-split path is unexercised.** No class reaches 65,536 cells, so
    only the per-row bound check was measured.
  - **The prototype is still not a store.** No search, no selection, no semantic
    marks beyond a header slot, no spill table (the arm `fatalError`s on a
    multi-scalar cell rather than encoding one silently).
- Deferred decisions, continuing `F4`'s numbering; each took the obvious, simple
  choice rather than blocking:
  - **DD5 -- a record's display-row count is *counted* at admission, not
    derived.** Admission knows how many rows it consumed, so the block's cached
    display-row total is incremented as rows arrive and no `ceil` -- and no
    `hasWideCells` scan (`F4` Observation 1) -- runs on the write path at all.
    `F2`'s counting pass therefore belongs to the width-change path exclusively.
    The alternative, deriving the count at close, would pay the wide-cell scan on
    every admitted line for a number the writer already has.
  - **DD6 -- a forced split leaves no back-pointer.** The `forcedSplit` bit sits
    on the record that was cut and the continuation simply follows it in the
    arena; readers rejoin by adjacency. The alternative -- a `continuesPrevious`
    bit on the follower -- is one flag more state for a case no measured input
    reaches, and can be added later without changing the format.
- Next action: `D1` Part B's last measured input is in. **Part B now owes exactly
  one thing: the simplification inequality** (`D1`'s frozen paragraph "What the
  simplification inequality must show"), which is a reading and accounting pass
  over the deletion and addition lists, not a measurement. `D1` does not close on
  this entry and Phase 2 does not open. Two things this entry hands forward:
  Observation 3's decomposition says any future admission work belongs in the
  encoder rather than the container, and Observation 4 prices the arena against
  what the budget charges today, which the budget-and-eviction task in Phase 2
  will need.

### F5 -- the simplification inequality holds, and it holds on invariants rather than on line count: five cross-cutting invariants deleted against three local ones added

- Status: recorded. This is `D1` Part B's last owed input and the only one that
  is not a measurement -- the frozen rule calls it "a reading and accounting
  pass over the deletion and addition lists". It closes `D1`; the verdict and
  its scoping are in [decisions.md](decisions.md).
- Date and investigator: 2026-08-04, Claude (agent).
- Commit and worktree state: `3fd09fd`, the commit that recorded `F3`. **No file
  under `lib/` is added or changed by this entry** -- like `F4`, it is a reading
  and accounting pass. Line numbers below are read at `3fd09fd`. The two
  untracked paths present throughout this doc's work are still present and still
  in no build: `TODO.md` and
  `docs/scratch/2026-08-04-scroll-sample-breakdown.md`.
- Commands, inputs, or reproduction: the deletion side was enumerated by reading
  `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`,
  `lib/TerminalCore/Sources/TerminalCore/PackedRetainedRow.swift` and the
  `lib/TerminalCore/Tests/TerminalCoreTests/` suites named below; the addition
  side was enumerated from this doc's own three probe files, which are the
  candidate's only existing implementation, plus `F4`'s and `F3`'s deferred
  decisions (`DD1`-`DD6`), which are what settle its semantics.
- Artifacts: none durable.

#### What the rule asks, restated before it is answered

`D1`'s frozen paragraph "What the simplification inequality must show" names six
things the deletion list **must actually contain** -- history reflow mutation,
`productionScrollbackCellCap`, `productionScrollbackRowCap`, the `28/D8`
cost-model derivations and their tests, narrow-then-widen eviction machinery, and
continuation-flag bookkeeping in retained history -- and three properties the
addition list **must have**: pure, unit-testable, and free of any width-dependent
persisted state. The README states the same gate as a magnitude: the deletion
list "must exceed" the addition list. Both readings are answered below, and they
do not answer the same way, which is the substance of this entry.

#### Observation 1 -- the deletion side, named against real code sites

All six named items are present in the tree and are genuinely removed. What each
one actually is:

| # | rule's item | the code that is it | disposition |
| ---: | --- | --- | --- |
| 1 | history reflow mutation | `Terminal.swift:4288` `resizeWidth` (286 lines), `:4575` `reconstructLogicalLines` (137), `:4713` `pack(line:columns:)` (65), `:3686`-`:3791` `attachments` / two `attachment` overloads / `textDestination` (106), `:560`+`:599`-`:639` the seven reflow-only types (46), `:4791` `sourceKey` (3) | history is never rebuilt; see Observation 2 for the part that moves rather than vanishes |
| 2 | `productionScrollbackCellCap` | `Terminal.swift:784`, its 21-line derivation at `:763`-`:783`, the live `scrollbackCellCap` `:856`, `scrollbackStoredCellCount` `:860` and its two maintenance sites (`:3974`, `:3994`), `recomputedScrollbackStoredCellCount` `:2314`, and the cap's clause in `enforceScrollbackBudget`'s `while` (`:3990`) | deleted: the doc comment says in terms that the cap exists to bound reflow's dominant term, and there is no such term |
| 3 | `productionScrollbackRowCap` | `Terminal.swift:815`, its 29-line derivation at `:786`-`:814`, `scrollbackRowCap` `:853`, the row clause at `:3989` | deleted: it bounds the `1.85 us/row` term for `28/F9`'s blank-row regime, and `F4` case 28 shows blank rows fold into near-zero-cell records the byte budget already bounds |
| 4 | the `28/D8` cost-model derivations and their tests | the ~50 lines of doc comment carrying `1.85 us/row + 0.352 us/cell`, the `cellCap / 20` ratio and the 600.5 ms price; six of `TerminalScrollbackBudgetTests.swift`'s 21 tests (`:220`, `:257`, `:290`, `:341`, `:403`, `:761`); `TerminalHistoryDepthSizingProbe.swift` (294 lines, whose whole purpose is pricing candidate cap sets and their resize cost) | deleted; `TerminalResizeProbe` / `TerminalResizeProbeSupport` (344 lines) survives but loses its subject -- it would measure a live-screen refold plus `F2`'s counting pass |
| 5 | narrow-then-widen eviction machinery | not a module but an invariant: the cell cap's content-denomination exists solely to hold it (`Terminal.swift:767`-`:770`), the row cap documents a lossy region below 20 columns (`:800`-`:806`), `narrowThenWidenPreservesCappedHistory` (`TerminalScrollbackBudgetTests.swift:290`) pins it, and `resizeWidth` re-enforces the budget at `:4571` after every rebuild | deleted by construction: a width change does not touch the arena, so a narrow-then-widen cycle is a no-op on storage and the lossiness question becomes unrepresentable |
| 6 | continuation-flag bookkeeping in retained history | `PackedRetainedRow.swift:101` `softWrapBit` + `:149` accessor + pack/unpack at `:506`/`:289`, one bit **per display row**; the three tail mutations that keep it truthful (`Terminal.swift:6369` `severScrollbackWrapClaim`, `:6387` `restoreWrapClaimBeforeCursor`, `:6436` `clearPreviousSpacer`, plus `:6460` `setScrollbackCell`, 65 lines); `isHistoryHeadTruncated` (`:866`, maintained at `:3999` and `:5385`, asserted 14 times in `TerminalScrollbackBudgetTests`); `.continuation` stamping into retained rows (`:4731`, `:4746`) | reduced, not erased: the flag becomes one open/closed bit per **logical line**, two of the three mutations become header-bit flips on the tail record and the third disappears (`F4` Observation 5), `isHistoryHeadTruncated` becomes always-false (`DD2`), and `.continuation` is stamped at read (`F4` case 16) |

Summed as lines of `Terminal.swift`, the reflow-shaped code is **~660 lines**,
the cap machinery ~75, and the tail-mutation trio ~65: about **790 of 6,470
lines, 12% of the file**.

#### Observation 2 -- the honest subtraction: the fold is not deleted, it moves

`pack(line:columns:)` is the function that turns one logical line into display
rows at a width. Every rule in it -- the `.spacerHead` at a one-column gap
(`Terminal.swift:4734`), the `isSoftWrapped` marking (`:4726`), the
`.continuation` stamping (`:4731`, `:4746`) -- is exactly what the candidate has
to do **at read time** instead. So of that ~660 lines, roughly **70 move rather
than vanish**: `pack`'s fold minus its two destination dictionaries, plus
`retainedContentEnd` (`:4779`, which becomes admission's trailing-blank rule,
`F4` case 17). `F4` already said this from the other direction --
`reconstructLogicalLines` is the admission rule run backwards -- and the correct
statement of the deletion is therefore **the round trip, not the wrapping**.

What *is* deleted outright inside that machinery is everything that exists only
because the rebuild is destructive and identities must survive it: the
`sourceKey` coordinate space, the `cellDestinations` and `boundaryDestinations`
dictionaries built per logical line, `ReflowRowMetadata`, `ReflowCursorAnchor`'s
three cases, `ReflowTextAttachment`, and the four `attachments` computations plus
the eight destination locals and their `??` threading in `resizeWidth`
(`:4319`-`:4354`, `:4356`-`:4365`, `:4443`-`:4498`, `:4531`-`:4564`) -- about
**130 lines whose entire job is carrying ten anchors across a rebuild that no
longer happens**. `F4` Observation 4 priced the replacement: one address
conversion, because (logical line, offset) becomes the stored address.

Also deleted and easy to miss: `resizeWidth:4522`-`:4523` re-walks all of history
after every width change to recompute the charged byte and stored-cell totals.
Under the arena the byte total is the write cursor.

#### Observation 3 -- the addition side, stated at full cost

Six items, not the rule's four. `F4` added one and `F3`'s `DD5` removed work from
another; two more are named here because an inequality argued by omission is
worthless.

1. **The contiguous byte arena.** A record is an 8-byte header (cell count,
   flags, a semantic-mark slot) plus C1 cell words. Pure value type over
   `[UInt8]`; no clock, no IO, no AppKit. Unit-testable, and `F1`'s and `F3`'s
   cross-arm checksum gates are already the shape those tests take.
   Width-dependent persisted state: none -- `F1` Observation 2 reconstructed the
   engine's own display-row count for all 10,773 logical lines from (record,
   width) alone.
2. **The block-summed wrap index.** Per-line record offsets, blocked ~256 lines,
   one cached display-row total per block at the current width; offsets-only, per
   `F2`. This is the design's one genuinely new *mutable derived* structure, and
   it has **four maintain-or-recompute trigger points**: a width change (discard
   and recompute eagerly -- `F2`: 0.016 ms at trial depth), admission (`DD5`
   increments the tail block's total as rows arrive), eviction at the head
   (unspecified -- see below), and a forced split (one record becomes two).
   Nothing survives a flush, which is the property Observation 5 turns on, but
   the invalidation discipline is real and is new.
3. **The open-line rule.** Exactly one open record, always the arena's tail; a
   hard-ended row closes it. `F4` Observation 5 licenses the "tail only" premise
   by enumerating today's three history writes and finding all three target
   `scrollbackRows.indices.last`. `F3` measured the rule at 0.624x-0.691x of
   today's admission.
4. **The forced-split rule.** 65,536 cells, derived as 1/32 of the byte budget
   (`DD3`); a `forcedSplit` header bit; readers rejoin by adjacency with no
   back-pointer (`DD6`). One documented wart, bounded up front, and unexercised
   by every probe so far.
5. **The `hasWideCells` fast/slow split** (added by `F4`). A per-record content
   bit selecting `ceil((cells + spacers) / width)`'s O(1) path or an O(cells)
   scan. Weakest possible addition: always scanning would be correct, so the
   design does not depend on the bit existing.
6. **Spacer re-derivation at read.** The store never holds a `.spacerHead`, so
   every read re-inserts it from (record cells, width). `F3`'s gate 1 proved the
   derivation total -- 5,124 spacers re-derived on the `wide` class with
   identical checksums -- but it is work the reader does that today's store does
   not, and `F1`'s 0.608x browse figure was measured on stimuli with **zero**
   spacers.

Two further costs that are not permanent additions but are not free either, and
that the inequality must not be allowed to hide:

- **Eviction from the front of an arena is unpriced on both sides.** Today's
  `Terminal.swift:3978` `enforceScrollbackBudget` plus `ScrollbackBuffer`'s
  `removeFirst` (`:338`) and `compactIfNeeded` (`:371`) is the incumbent; `DD2`'s
  whole-record eviction is the candidate; nothing has compared them, and whole-
  record eviction additionally needs the index's head to move with it (trigger
  point 3 above). `F1`, `F3` and this doc's README all flag it, and it is the
  largest single hole in Phase 1's evidence.
- **Migration.** Phase 2's first task exists because the invariant "history is
  always at the current width" dies, and every display-row-indexed call site --
  `projectionRows`, `activationIdentity`'s range scan, `primaryHistoryText`,
  scrollbar math, selection, search -- must be re-expressed. That is a one-time
  cost, but it is a cost, and it is unenumerated.

#### Observation 4 -- on line count, the inequality is close to a wash, and this entry says so

The candidate's only existing implementation is this doc's probes. `F1`'s arena
plus derived index plus read walk is `TerminalLogicalLineReadProbe.swift:257`-`:560`,
about **303 lines**; `F3`'s open-line admitter is
`TerminalLogicalLineAdmissionProbe.swift:247`-`:458`, about **211**, of which the
read-back checksum is test scaffolding. Call the storage core **~350-400 lines**
of prototype -- and it has no spill table (`F1`'s arm calls `fatalError` on a
multi-scalar cell, and `28/F11` measured spills in ~0.12% of real rows), no
hyperlink or content-identity side tables, no semantic marks beyond a header
slot, no eviction and no search. A production version is plainly larger.

Against ~720 net lines deleted (790 less the ~70 that move), that is a win of
roughly 300 lines on a 6,470-line file, with an error bar wide enough to swallow
it. **The magnitude reading of the inequality is therefore weak**, and this
entry declines to rest the verdict on it. `DD8` records that choice.

#### Observation 5 -- on invariants, the inequality is not close

The reading that does carry it. What a maintainer must currently hold true, and
can currently get wrong:

| # | invariant deleted | who has to hold it today |
| ---: | --- | --- |
| 1 | history is always at the current width | every reader, and `resizeWidth` must re-establish it across the whole store before any of them runs |
| 2 | a narrow-then-widen cycle must not evict | the cell cap's content-denomination exists only for this, the row cap documents where it fails (below 20 columns), and one test pins the seam |
| 3 | the per-display-row continuation flag stays truthful under three tail edits | `severScrollbackWrapClaim`, `restoreWrapClaimBeforeCursor`, `clearPreviousSpacer`, plus `isHistoryHeadTruncated` at every eviction |
| 4 | ten anchors survive a destructive rebuild | four `attachments` computations, a source-key coordinate space, two destination dictionaries per logical line, three cursor-anchor cases |
| 5 | three bounds, whichever binds first | bytes, rows and cells, each with its own maintenance at two sites, its own derivation, and its own eviction clause |

| # | invariant added | who has to hold it |
| ---: | --- | --- |
| 1 | exactly one open record, always the arena tail | the admission path alone |
| 2 | cached block totals are valid for the current width, or discarded | the index alone, at four trigger points |
| 3 | no record exceeds 1/32 of the byte budget, and readers rejoin splits by adjacency | the admission path and the copy/search readers |
| 3.5 | `hasWideCells` is set iff the record holds a wide cell | the admission path -- and being wrong the safe way is still correct, which is why it counts as a half |

Five against three and a half, and the two sides are not the same kind of thing.
The deleted invariants are **cross-cutting**: each one is a contract between the
store and every reader, or between a resize and every anchor the terminal
carries. The added ones are **local**: each is a contract inside the store,
enforceable by one writer and testable by one gate.

Two of the deletions are stronger still, because they delete a failure mode
rather than a test of one. `F4` case 18 -- two hard-ended lines must not join
when widening -- becomes unrepresentable, since a record boundary *is* a hard
newline. And a width change that does not touch storage cannot evict, so
invariant 2 is not merely upheld but has nothing left to be about.

Against that, one addition has no analogue today and must be stated as a new
risk, not folded into the tally: **a stale block index**. Today there is no
derived width-dependent cache at all -- the store is at the width -- so this
design trades an eagerly-maintained truth for a derived cache with four trigger
points. It is the one item on the addition side that can grow, and `DD7` records
why it is nonetheless not "width-dependent persisted state" in `D1`'s sense.

#### Observation 6 -- the rule's three properties of the addition list, answered one at a time

- **Pure.** Every addition is a function of bytes already in hand: arena
  construction, index recompute, open-line append, forced split, wide-cell
  bit, spacer re-derivation. None reads a clock, a home directory, an id
  generator, or the filesystem. All six live under `lib/TerminalCore`, which
  takes no such input in the first place.
- **Unit-testable.** All three probes already demonstrate the test shape and it
  is a strong one: read the two stores back display row by display row and
  checksum every scalar, style id and kind. `F3` gate 1 is the proof that this
  catches the interesting failure -- it is what holds the candidate to
  re-deriving the 5,124 spacers it refused to store. `F2` gate 1's independent
  cross-check of the counting pass's total is the second shape.
- **Free of width-dependent persisted state.** Nothing width-shaped is written
  into a record: the header carries a cell count and content flags. The one
  width-dependent quantity in the design is the block index's cached totals, and
  it is a cache -- fully recomputable from the arena (`F2` measured exactly that
  pass, and cross-checked its output against an independently computed sum),
  discarded rather than migrated at every width change, and never consulted to
  decide what a record *is*. `DD7` records this reading.

- Observation: all six items `D1` requires on the deletion list are present in
  the tree at `3fd09fd` and are genuinely removed or reduced to a header-bit
  flip; the addition list has six members rather than four; and the two lists
  compare differently under two different units -- close to a wash on lines of
  code, five cross-cutting invariants against three and a half local ones on
  invariants.
- Inference: **the simplification inequality holds**, on the invariant reading,
  and `D1`'s three properties of the addition list are all satisfied. The
  argument is not that the design is smaller. It is that the design moves the
  wrapping rule from a destructive whole-history rebuild to a derivation at
  read, which deletes five contracts that span the entire engine and adds three
  and a half that live inside one store.
- Competing interpretations:
  1. *The inequality is being rescued by choosing a favourable unit.* The
     strongest objection, and Observation 4 concedes the unfavourable unit
     outright rather than burying it. The defence is that `D1`'s own rule is
     stated in terms of *what the lists contain*, not how long they are, and
     that the campaign's whole trigger (`28/D8`) was an invariant problem --
     "depth is latency" -- not a volume problem. `DD8` records the choice so it
     can be disputed.
  2. *`pack`'s fold moving to read time means the deletion is smaller than it
     looks.* Correct, and Observation 2 states it as the honest subtraction: ~70
     of ~790 lines move. It does not change the invariant tally, because the
     fold at read time is a pure function of (record, width) with no contract
     attached to it.
  3. *The block index is width-dependent persisted state, so the addition list
     fails `D1`'s third property outright.* Answered in Observation 6 and
     recorded as `DD7`. The distinguishing test the design leans on is whether
     the store can be reconstructed with no width anywhere in it; `F1`
     Observation 2 and `F2` gate 1 both demonstrate that it can.
  4. *An accounting pass cannot see the cost of code that does not exist yet.*
     True and unfixable at this stage. Everything on the addition side is sized
     from a prototype missing spills, side tables, eviction and search, so the
     addition list is the side with the larger error bar -- which is why the
     conditions carried into Phase 2 are all on that side.
- Uncertainty:
  - **Eviction is unpriced on both sides**, and it adds an index-head invariant
    nobody has designed. This is the largest term in the whole inequality that
    has no number attached to it.
  - **The addition list is sized from a prototype, not an implementation.** No
    spill table, no hyperlink or content-identity side tables, no search, no
    eviction. Each of those is on the addition side, and each will grow it.
  - **The migration is unenumerated.** Phase 2's call-site task is exactly the
    measurement of how large the one-time cost is, and it has not been done.
  - **The counting pass is still unpriced on wide content** (`F4`, `F2`), which
    is an addition-side cost that no reading here can settle.
  - **This is an accounting pass, not a measurement.** It reports what code
    exists and what contracts it carries. Nothing in it is a benchmark, and
    nothing in it substitutes for the paired ladder.
- Deferred decisions, continuing `F3`'s numbering; each took the obvious, simple
  choice rather than blocking:
  - **DD7 -- the block index's cached display-row totals are read as a cache,
    not as "width-dependent persisted state" under `D1`'s addition-list
    clause.** The test applied: the store can be reconstructed from its own
    bytes with no width anywhere in it (`F1` Observation 2, `F2` gate 1), and
    the cache is discarded rather than migrated at a width change. The stricter
    reading -- that any width-dependent byte anywhere in the design violates the
    clause -- would make the clause unsatisfiable by any wrap-at-read design
    that indexes at all, including iTerm2's, and would therefore have made `D1`
    no-go the moment the index was sketched at `de17e95`. A human may prefer the
    stricter reading; it would reopen `D1`.
  - **DD8 -- the inequality is adjudicated on invariants and cross-cutting
    coupling, not on line count.** Line count alone is close to neutral
    (Observation 4) and its error bar is wider than its margin, so resting the
    verdict on it would be resting it on noise. Reopen if Phase 2's
    implementation lands materially larger than the prototype suggests *and* the
    invariant argument has weakened -- either one alone does not reopen it.

    **Amended 2026-08-04 by [`D3`](decisions.md).** The reading stands; the
    margin does not. `D3` Decision 2 keeps `TextAnchor` an absolute display row,
    so invariant 4 ("ten anchors survive a destructive rebuild") is **reduced
    rather than deleted** -- the rebuild and its content-keyed mapping go, the
    renumbering stays and one restatement function owns it -- and the added side
    gains one ordering invariant (capture the anchors' addresses before the index
    is recomputed, restate them after). The honest tally is now **4.5 deleted
    against 4.5 added**, so the *count* no longer carries the inequality and the
    qualitative distinction does: cross-cutting contracts against local ones, and
    a total conversion function against a lookup table that can miss. This
    partially meets the second of `DD8`'s two reopening clauses; the first is not
    met, and `DD8` requires both, so it stands. The graduation task must re-read
    it against the landed implementation rather than quoting `F5`'s original
    margin.

    **Re-read 2026-08-04 by [`F11`](findings.md) Observation 4 against the landed
    implementation, and `DD8` now reopens: both clauses are met.** Clause 1 by a
    wide margin -- the storage core landed at **2,419 production lines**
    (`LogicalLineRecord.swift` 337 + `LogicalLineStore.swift` 2,082) against the
    ~350-400 this entry sized from the prototype, while `Terminal.swift` fell only
    6,470 -> 6,431, so `lib/TerminalCore/Sources` is a net **+2,419** across the
    arc and the line-count reading is not a wash but **inverted**. Clause 2
    because the invariant tally reversed as well: **4.5 deleted against 7.5
    added**, once `I11`'s seam rule, `DD25`'s trailing-fill side table, `DD43`'s
    seam-spacer reach and `historyEvictionsObserved`'s two-object protocol are
    counted, with `DD37`'s maintained charge cancelled against today's
    (`DD50`). The qualitative claim this entry rested the verdict on **mostly
    survives** -- six of the eight additions are contracts inside the store with
    one writer and one gate -- but it now has two named exceptions that cross the
    store's boundary, `DD43` at four call sites in `Terminal` and the eviction
    delta. What reopening means here is narrow and is stated so it is not
    over-read: the *choice of unit* is back on the table for a human, and with it
    the README's second acceptance dimension. It settles nothing on its own, and
    `F11` Observation 1 is where the acceptance actually failed.

    **ACCEPTED AND CLOSED 2026-08-05 by human judgment.** The tally above is not
    revised and no measurement was taken for this: the reopened dimension is
    closed by accepting the trade, not by re-arguing the count. What was weighed:
    the **performance wins** (`28/D11`'s exit amendment measures saturated-wide
    resize **576.19 ms -> 1.58 ms**, 364x, at greater depth; `F16` reads
    `scrollback-stream` **-13.60%** with the PTY drain past the pre-cutover
    engine's, and `retained-browse` at parity), the **bug class made
    unrepresentable by construction** (`I3` -- a width change touches no retained
    row, so `28/D8`'s lossy narrow-then-widen and the whole resize/reflow
    correctness surface stop existing rather than being defended), and **reach**:
    the 4.5 deleted rules were cross-cutting contracts spanning the store and
    every reader, the 7.5 added ones are store-local, single-writer and
    oracle-fenced. The two additions that cross the store's boundary -- `DD43`'s
    seam-spacer reach at four `Terminal` call sites and the
    `historyEvictionsObserved` eviction-delta protocol -- are accepted as named
    exceptions. So the inequality is **not** claimed to hold on count; the human
    judged the added local rules worth what they bought. `DD8` is closed and the
    plan's second acceptance dimension with it.
- Next action: `D1` closes. Its verdict, scoping, and the conditions Phase 2
  inherits are in [decisions.md](decisions.md); the ledger in
  [README.md](README.md) is updated to match. Phase 2 opens as a **design**
  phase only -- no production storage change is licensed by `D1`, because every
  Phase 1 number is a microbenchmark and the README's first acceptance dimension
  gives the verdict to the paired ladder.

### F6 -- the display-row-indexed call-site inventory: 69 sites, 13 of them deleted outright, and 8 whose mapping is not obviously satisfiable

- Status: recorded. This is Phase 2's first ledger task and it discharges
  inherited condition 6 (`D1`'s "Conditions and unpriced terms Phase 2
  inherits"). Like `F4` and `F5` it produces no number: it is a reading and
  cataloguing pass over the tree. **It licenses nothing.** `D1`'s scoping still
  holds -- `go` licenses design work only, and the paired ladder is still owed.
- Date and investigator: 2026-08-04, Claude (agent).
- Commit and worktree state: `eb17fbc`, the commit that recorded `F5` and closed
  `D1`. **No file under `lib/` is added or changed by this entry.** Line numbers
  below are read at `eb17fbc`. The two untracked paths present throughout this
  doc's work are still present and still in no build: `TODO.md` and
  `docs/scratch/2026-08-04-scroll-sample-breakdown.md`.
- Commands, inputs, or reproduction: the sweep read
  `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` (6,470 lines) and
  `PackedRetainedRow.swift` end to end, then followed every caller of
  `scrollbackRows`, `scrollbackRowCount`, `scrollProjection`, `ProjectionRows`,
  `TextAnchor`, `evictedRowCount`, `isSoftWrapped` and `scrollbackByteCost` out
  through `lib/TerminalCore/Sources/TerminalRenderPlanning/`,
  `lib/TerminalCore/Sources/TerminalCore/TerminalInteractionPolicy.swift`, the
  five probe-support targets, `lib/TerminalPTY/` and `app/`.
- Artifacts: none durable.

#### What "display-row-indexed" turned out to mean

The seed list in the ledger (`projectionRows`, `activationIdentity`'s range
scan, `primaryHistoryText`, scrollbar math, selection, search) named six sites.
The sweep found **69**, and the reason is that display-row indexing is not a
handful of readers but three coordinate systems that all currently bottom out in
the same identity -- *a retained row is a display row*:

1. **The absolute stream row.** `Terminal.swift:427 TextAnchor` is
   `(evictedRowCount + streamRow, column)`, and `TextAnchor` is `Comparable`.
   Selection, the search occurrence, the hovered link, the armed link, the
   browsing viewport top and the drag pin (`:463 PinnedTextRange`) are all
   stored in it. It spans history *and* the live grid in one space, which is the
   fact `HR2` below turns on.
2. **The public position.** `TerminalTextPosition.row` is a display row relative
   to the oldest *retained* row; `Terminal.swift:3396 publicRange` is the only
   converter, and it is `- evictedRowCount` plus a bound check against
   `scrollbackRows.count + rows.count`.
3. **The viewport row.** `scrollProjection.topRow + row`, resolved through
   `:3211 viewportStreamRow(at:)`, which is the funnel `presentedRows`,
   `presentedRowGeometry`, `cell(row:column:)` and `forEachViewportCell` share.

Every one of the three is O(1) today for exactly one reason: `scrollbackRows`
holds one element per display row, so a count is a count and an index is an
index. That identity is what the logical-line store removes, and the inventory
below is the list of places that notice.

Two boundaries the sweep settled and that are worth stating before the tables:

- **The checkpoint and persistence path does not serialize history as rows.** It
  serializes `Terminal.swift:2425 primaryHistoryText`'s **string**, through
  `TerminalPaneSession.swift:676 readPrimaryHistoryText` to
  `app/AppRuntime.swift:1265` and `:1687`. There is no on-disk row index, row
  count or offset anywhere in the recovery store, so the whole persistence layer
  is `unchanged` and the record format owes it nothing. The ledger's parenthetical
  asked for this to be checked; this is the answer.
- **`isHistoryHeadTruncated` has no production consumer.** It is
  `public private(set)` (`:866`) and every reference in the tree is one of 14
  assertions in `TerminalScrollbackBudgetTests.swift`. `DD2` makes it always
  false; `DD10` deletes it instead.

#### Observation 1 -- the inventory, grouped by mapping

**69 sites: 14 unchanged, 16 index-translated, 18 rewritten, 13 deleted, 8
flagged.** The flagged eight are counted inside their mapping group as well --
being hard is not a fifth mapping, it is a warning on one of the four -- so the
first four numbers sum to 61 and the eight are called out again in Observation 2.

**Unchanged (14).** Sites that touch only the live grid, only viewport-relative
coordinates, or only text.

| # | site | what it does today | why the store cannot reach it |
| ---: | --- | --- | --- |
| U1 | `Terminal.swift:6354 severWrapClaim(at:)` | clears a viewport row's wrap claim and its trailing spacer | viewport rows only; the scrollback sibling is `R13`/`HR3` |
| U2 | `Terminal.swift:6405 clearCellAndPair` | clears a cell and its wide partner in `rows` | live grid only |
| U3 | `Terminal.swift:6287 moveAndFillCells` | horizontal shift within one live row | live grid only |
| U4 | `Terminal.swift:6442 clearPreviousSpacer` (viewport branch) | clears a spacer on the previous *live* row | the scrollback branch is `X9` |
| U5 | `Terminal.swift:4232`-`:4252 resizeHeight` (shrink half) | drops blank tail rows, admits the displaced prefix | admission is `R14`; the row selection is live-grid arithmetic |
| U6 | `Terminal.swift:5359`-`:5368` ED 0/1/2 | erases live rows | ED 3 is `T15` |
| U7 | `Terminal.swift:413`, `:2082`, `:3213`, `:4093` alternate-screen branches | the alt grid never has scrollback | `F4` cases 11-12; the alt *seam* rule is `R17` |
| U8 | `TerminalGeometry.swift:146 TerminalScrollProjection`, `:36 activationIdentity` | value shapes crossing the module boundary | the producers move, the types do not |
| U9 | `TerminalDamage.swift` row spans + `Terminal.swift:1064 recordDamage(row:)` | viewport-relative damage rows | never absolute |
| U10 | `Terminal.swift:1107 damagedViewportRows` | clips a stream range to viewport rows | the subtraction is unchanged; only `topRow`'s supplier moves (`HR1`) |
| U11 | `RenderFramePlanner.swift:180`-`:184`, `:266`, `:286` | per-row planning off `geometry.rows[row]` | viewport-relative throughout |
| U12 | `TerminalInteractionPolicy.swift:592 isViewportPosition` | gates owner input on `geometry` | viewport-relative |
| U13 | `app/SwiftTerminalSessionView.swift:73`-`:82`, `:641`; `TerminalPaneSession.swift:591`-`:595` | the scrollbar: `totalRows` / `topRow` / `windowRows` -> `TerminalScrollPosition`, and `scroll(toTopRow:)` back | consumes `TerminalScrollProjection`, whose shape does not change. **The scrollbar math the ledger named is a pass-through; the work is in its producer (`T10`).** |
| U14 | `app/AppRuntime.swift:851`, `:1265`, `:1687`; `TerminalPaneSession.swift:599`, `:676` | checkpoint, recovery and `danterm read` | history crosses as text, never as rows or offsets |

**Index-translated (16).** Display row -> (record, offset) through the block
index; the reader's shape survives, its address does not.

| # | site | what it reads today | translation |
| ---: | --- | --- | --- |
| T1 | `Terminal.swift:2148 scrollbackRowCount` | `scrollbackRows.count` | the index's grand display-row total (`HR8`) |
| T2 | `Terminal.swift:2153 scrollbackRow(at:)` (public) | subscript + `unpacked().materialized(to:)` | locate the record, fold its k-th display row |
| T3 | `Terminal.swift:2184 scrollbackRowContentIdentityShape(at:)` | the row's *unmaterialized* stored prefix | locate + slice; the contract needs restating (`HR7`) |
| T4 | `Terminal.swift:2360 retainedRowForTesting(at:)` | subscript + `unpacked()` | same as `T2`, minus materialization |
| T5 | `Terminal.swift:2366 scrollbackRowByteCost(at:)` | `scrollbackByteCost(of:)` on one row | record bytes divided by its rows, or deleted with `X13` |
| T6 | `Terminal.swift:3211 viewportStreamRow(at:)` | `scrollbackRows[index].unpacked()`, else `rows[index - count]` | the one funnel: locate + fold, else live |
| T7 | `Terminal.swift:3185 presentedRowGeometry` | `scrollbackRows[index].forEachKind` per visible row | locate + walk the record slice's kinds |
| T8 | `Terminal.swift:4066 forEachViewportCell` | `scrollbackRows[streamRow].forEachContentCell` | locate + walk the slice. **`28/F17`'s hot path and `F1`'s measured one.** |
| T9 | `Terminal.swift:4027 cell(row:column:)` | `viewportStreamRow` + `cell(at:)` | one cell inside a record |
| T10 | `Terminal.swift:2090`, `:2125` `scrollProjection` / `scroll(toTopRow:)` | `scrollbackRows.count + rows.count`, `maximumTop` | grand total + live rows (`HR1`, `HR8`) |
| T11 | `Terminal.swift:3243 projectionRowCount` | same sum | same |
| T12 | `Terminal.swift:969`, `:4011` cursor stream row | `scrollbackRows.count + cursor.row` | grand total + cursor row |
| T13 | `Terminal.swift:3815`-`:3816`, `:3825`, `:3862`, `:3906` inspection and clamp bounds | `evictedRowCount + scrollbackRows.count + ...` | same origin, index-supplied |
| T14 | `Terminal.swift:3396 publicRange` | bound check against `base + streamCount` | same |
| T15 | `Terminal.swift:3226`, `:3235 revealSearchMatchIfNeeded`; `:5381`-`:5386` ED 3 | absolute match row vs viewport window; whole-history clear counts evicted *rows* | index-supplied totals |
| T16 | `TerminalRetainedRowProbeSupport.swift:450`, `:469`; `TerminalBrowseBenchmarkSupport.swift:165`; `OccupancyProbe.swift:39`; `TerminalResizeProbeSupport.swift:325` | `scrollbackRowCount` + `scrollbackRow(at:)` per row | measurement consumers; follow `T1`/`T2` |

**Rewritten (18).** The read stops being "fetch row i" and becomes something
else; the one-or-two-sentence new read is in the third column.

| # | site | today | the new read |
| ---: | --- | --- | --- |
| R1 | `Terminal.swift:394 ProjectionRows` + `:408` subscript | a `RandomAccessCollection<GridRow>` over scrollback then live, materializing per access | a cursor over (record, display-row-in-record) that yields a borrowed slice plus the folded spacers, never a `GridRow`. **The largest single rewrite (`HR6`).** |
| R2 | `Terminal.swift:3259 activeProjectionRows()` | `Array(activeProjection())` -- materializes all of history | a forward walk over records; consumers are search, Select All, export and `text(in:)`, all of which want units rather than rows |
| R3 | `Terminal.swift:2680 logicalLineRange(at:in:)` | walks `isSoftWrapped` outward in both directions from the clicked row | **the record you are in.** O(1) instead of O(rows in the line); this is the design's clearest reader win |
| R4 | `Terminal.swift:2704 trimmedLogicalLineRange` | slices `stream[line.start.row...line.end.row]` then trims units | trims units over one record's cells |
| R5 | `Terminal.swift:2737 explicitLink` | two soft-wrap walks (`:2748`-`:2749`), then a coordinate array over the whole logical line | one record; the coordinate array becomes a cell-offset range |
| R6 | `Terminal.swift:2789 detectedLink` | windows `rowRadius = maximumHyperlinkTargetBytes / columnCount + 2` rows around the click | a cell-offset window in the record; the window stops depending on width |
| R7 | `Terminal.swift:3338 projectedCellEnd` + `:4779 retainedContentEnd` | `isSoftWrapped ? columnCount : retainedContentEnd(in: row)` | a fold output: a non-final display row ends at `width`, the final one at the record's content end (`F4` case 17). Admission owns the trailing-blank rule; read owns the rest |
| R8 | `Terminal.swift:3278 forEachProjectionUnit` / `:3306 forEachRowTextUnit` | per row, with the hard boundary emitted when `row.isSoftWrapped == false` (`:3291`) | per record: units come from the record's cells and the hard boundary is the record boundary. Wrap boundaries stop existing in the data |
| R9 | `Terminal.swift:3477 nearestTextUnit`, `:3505`/`:3536 textUnit(before:/after:)`, `:3456 rowTextUnits` | step within a row's unit array, then walk to an adjacent row while `isSoftWrapped` | step within a record; the soft-wrap walk disappears (`F4` case 20) |
| R10 | `Terminal.swift:3624 searchMatches` | a needle window over `projectionUnits()`, i.e. over every row of history | the same window over records. **The README's open question resolves toward "simpler": there are no wrap artifacts to step over.** No separate search index is implied by any site in this inventory |
| R11 | `Terminal.swift:2891 activationIdentity` | scans `stream[row].cell(at: column).contentIdentity` over the link's row range | one contiguous cell-offset range in one record -- but see `HR7`: `contentIdentity` is a side table every Phase 1 probe stripped |
| R12 | `Terminal.swift:4713 pack(line:columns:)` | folds a logical line to display rows during reflow | **moves to read time** (`F5` Observation 2). Its `.spacerHead` at a one-column gap (`:4734`), `isSoftWrapped` marking (`:4726`) and `.continuation` stamping (`:4731`, `:4746`) are inherited condition 10 |
| R13 | `Terminal.swift:6369 severScrollbackWrapClaim`, `:6387 restoreWrapClaimBeforeCursor` | flip `isSoftWrapped` on the last retained row, and replace its trailing spacer | close / reopen the tail record's header bit (`F4` case 9). **The spacer replacement does not survive the mapping -- `HR3`** |
| R14 | `Terminal.swift:3965 appendToScrollback` | `pack` per display row, append, accumulate two totals | open-line append at the write cursor (`F3`); one total |
| R15 | `Terminal.swift:3978 enforceScrollbackBudget` | evict one display row at a time on three bounds | evict whole records on one bound, and move the index head (`DD2`, `HR5`) |
| R16 | `Terminal.swift:2227 memoryCensus` | `scrollbackRowCount`, `retainedRowStorageRowCount`, `rowStorageAllocationCount`, `retainedPackedPayloadBytes`, and a walk of `asArray()` | arena-denominated: bytes in use, capacity, records, and a walk of records (`DD11`) |
| R17 | `Terminal.swift:2414 fullHistoryText`, `:2425 primaryHistoryText`, `:3157 projectedHistoryText` | `scrollbackRows.asArray()` + rows, with the alt seam applied by mutating a copy's `isSoftWrapped` | walk records; the alt seam becomes a read-time "the tail record reads as closed", with no copy and no mutation |
| R18 | `Terminal.swift:2630 selectAll` | `projectionUnits()` over the whole projection, for its first and last unit | the arena's first cell offset and the live grid's last unit |

**Deleted (13).** Subsumed by wrap-at-read; nothing replaces them.

| # | site | why it goes |
| ---: | --- | --- |
| X1 | `Terminal.swift:4288 resizeWidth`'s history half | history is never rebuilt |
| X2 | `Terminal.swift:4575 reconstructLogicalLines` | it is admission run backwards (`F4`); admission now runs forwards once |
| X3 | `Terminal.swift:3686 attachments`, `:3710`/`:3744 attachment`, `:3767 textDestination`, `:4791 sourceKey`, `:560`+`:599`-`:639` the seven reflow-only types | nothing has to survive a destructive rebuild. **Conditional on `HR2`'s resolution** |
| X4 | `Terminal.swift:4319`-`:4364`, `:4443`-`:4498`, `:4531`-`:4564` | the four attachment computations, eight destination locals, their `??` threading and their write-back |
| X5 | `Terminal.swift:4522`-`:4523` | the post-resize re-walk of all history to recompute the charged byte and stored-cell totals |
| X6 | `Terminal.swift:784 productionScrollbackCellCap` + `:763`-`:783` derivation + `:855 scrollbackCellCap` + `:860 scrollbackStoredCellCount` + five maintenance sites (`:3974`, `:3994`, `:4269`-`:4271`, `:4523`, `:6462`/`:6468`) + `:2314` + the `:3990` clause | the cap bounds reflow's cell term |
| X7 | `Terminal.swift:815 productionScrollbackRowCap` + `:786`-`:814` derivation + `:853 scrollbackRowCap` + the `:3989` clause | the cap bounds reflow's row term |
| X8 | `Terminal.swift:866 isHistoryHeadTruncated` + `:3999`, `:5385` | constant under `DD2`, no production consumer (`DD10`) |
| X9 | `Terminal.swift:6445`-`:6456 clearPreviousSpacer` (scrollback branch) | the store never held the spacer (`F4` case 10) |
| X10 | `Terminal.swift:6460 setScrollbackCell` | its only two callers are `X9` and `R13`'s spacer replacement |
| X11 | `Terminal.swift:290 ScrollbackBuffer` entire: `:304` subscript, `:318 retainedCellStorageRowCount`, `:329 asArray`, `:333 suffix(from:)`, `:338 removeFirst`, `:352 removeLast`, `:371 compactIfNeeded`, `storageStart` | one arena replaces the whole type |
| X12 | `Terminal.swift:2302 retainedCellStorageRowCount` + `TerminalMemoryCensus.swift:81`, `:128` | doc 15's per-row leak proof is unrepresentable with one region (`DD11`) |
| X13 | `Terminal.swift:2349 retainedScrollbackAllocationBytes`, `:3943`/`:3961 scrollbackByteCost`, `:2307 recomputedScrollbackByteCount`, `:2321 blankScrollbackRowByteCost`, `:2326 compactScrollbackRowByteCost` | the per-row charge model. The arena's charge is its write cursor, and the charge-vs-cost honesty proof becomes an identity |

#### Observation 2 -- the eight sites whose mapping is NOT obviously satisfiable

These are the design risks Phase 2 exists to surface. Each names the site, why
the obvious mapping fails, and what has to be decided. **None of them is a
reason to reverse `D1`**; five are unenumerated work and three are behavior
changes that need a human's disposition.

**Status, updated 2026-08-04: all eight are disposed of.** The eight paragraphs
below stand as written -- they are the statement of the risk, not of its
resolution -- and each disposition is recorded in the decision that took it.

| # | disposition | where |
| --- | --- | --- |
| `HR1` | the index maintains one grand display-row total; no anchor cache is needed, and no index lookup runs per read or per row | [`D3`](decisions.md) Decision 1 |
| `HR2` | the stored anchor stays an absolute display row; ~40 lines of restatement return against `X3`/`X4`'s ~130 deleted, and `F5`'s invariant tally is amended | [`D3`](decisions.md) Decision 2 |
| `HR3` | the BCE-styled blank is materialized into the open tail record as one appended cell; measured against the real engine, and `X9` is the same case | [`D3`](decisions.md) Decision 3 |
| `HR4` | the tail truncation is `D2`'s operation 4, and gains a second trigger in `D3` Decision 4 | [`D2`](decisions.md) Decision 2, [`D3`](decisions.md) Decision 4 |
| `HR5` | closed rather than accepted: eviction is display-row granular at the head, so no anchor moves further per admitted row than today | [`D2`](decisions.md) Decision 2 |
| `HR6` | `ProjectionRows` keeps its materializing facade for milestone 1; the borrowing cursor is milestone 2 under a frozen priority rule | [`D3`](decisions.md) Decision 5 |
| `HR7` | identity is a per-record run table keyed by cell offset; the shape reader is re-denominated per record | [`D3`](decisions.md) Decision 6 |
| `HR8` | the grand display-row total is maintained, not walked | [`D3`](decisions.md) Decision 1 |

**`HR1` -- `scrollProjection.topRow` is read roughly 200 times per frame and
becomes an index lookup.** Sites: `Terminal.swift:3166 presentedRows`, `:3186
presentedRowGeometry`, `:4028 cell(row:column:)`, `:4071 forEachViewportCell`,
`:4007 geometry`, `:966 damageActionSnapshot`, `:1109 damagedViewportRows`,
`:3225 revealSearchMatchIfNeeded`, `:2113 scroll(byRows:)`,
`RenderFramePlanner.swift:244`, `:387`, `:398`,
`TerminalInteractionPolicy.swift:598`. Today `scrollProjection` is
`scrollbackRows.count + rows.count` and a clamp: pure arithmetic, so re-reading
it per row is free and the tree does exactly that -- the render planner reads it
three times per visible row (`forEachViewportCell` once, `hoveredColumns` once,
`selectedColumns` once), which is ~200 reads on a 66-row frame. Under the new
store `totalRows` is the index's grand total and `topRow` is the browsing
anchor's display row. If either is an index walk, a frame pays ~200 of them, and
`F1` priced one point lookup at **0.82-1.09 us** -- 164-218 us per frame, an
order of magnitude above the whole browse frame this design must not regress.
**This lands directly on `retained-browse`, the README's go/no-go workload, and
it is the concrete mechanism by which `F1`'s 1.64x could turn into a `slower`
ladder verdict.** The fix is not free: the index must carry an O(1) grand total
*and* the browsing anchor must cache its display row, which becomes a fifth
thing to invalidate on top of `F5` Observation 3's four trigger points. Do not
book this as bookkeeping.

**`HR2` -- the anchor coordinate space straddles history and the live grid, and
`F4` case 13 addresses only the history half.** `Terminal.swift:427 TextAnchor`
is `(absolute display row, column)` and is `Comparable`; that ordering is
load-bearing at `:2634 selectAll`, `:2807 detectedLink`, `:3348 text(in:)`,
`:3382`-`:3385 resolvedRange`, `:3486 nearestTextUnit`, `:3510`-`:3557` the four
`textUnit` steps, `:3848 range(_:intersects:)`, `:3864`-`:3868
clampSelectionToRetainedStream`, `:3877`-`:3899 handleEviction`, and `:4533`,
`:4540`, `:4548`, `:4558` in `resizeWidth`'s write-back. `F4` case 13 and
Observation 4 say the remap becomes "(logical line, cell offset), the *native*
address instead of a transient reflow attachment" -- but a live-grid anchor has
no record, and a selection dragged from scrollback into the viewport, a search
match crossing the seam, and `selectAll` all hold one endpoint in each space.
Two exits, and Phase 1 chose neither: (a) keep the anchor a display row and
translate at the store boundary, which is cheap per query but means a width
change must still restate every held anchor -- so `X3`'s deletion of the
attachment machinery is *conditional*, and what returns is smaller but not
nothing; or (b) make the anchor a record address and give the live grid a
parallel one, which needs a total order across two address kinds, defined for
every comparison above. **`X3` and `X4` -- about 130 lines and one of `F5`
Observation 5's five deleted invariants -- rest on this choice.**

**`HR3` -- severing a wrap claim on the tail record silently drops a
background-erase-colored cell that is stored and painted today.**
`Terminal.swift:6369 severScrollbackWrapClaim` does two things: clears
`isSoftWrapped`, and replaces a trailing `.spacerHead` with
`GridCell(styleId: replacementStyleId)` -- a BCE-colored blank.
`PackedRetainedRow.swift:487`-`:492` stores that cell (a styled `.padding`
extends the canonical extent) and `:371 forEachContentCell` emits it with its
style, so the renderer paints it in the erase color. `F4` case 9 maps the sever
to "flip the tail record's open/closed header bit ... No cell is rewritten" and
case 10 says the spacer was never stored -- both true, and together they lose
the blank: a closed record is measured to its content end at read (`R7`), so the
column is not emitted at all and the renderer pads it with the *default*
background. Reachable with `ESC[41m` followed by IL or ED at viewport row 0.
Either admission materializes the erase-styled blank into the record when the
claim is severed -- which reintroduces a *cell* write into history, still
tail-only but no longer a bit flip -- or the divergence is accepted and the
sever's BCE behavior changes. `F4` missed it because it read the sever as a flag
operation; it is a flag operation plus a cell write, and only the flag half maps.

**`HR4` -- `resizeHeight` is a fourth tail mutation, and it is a truncation
rather than a bit flip.** `Terminal.swift:4256`-`:4278`: growing the grid with
the cursor on the last row pulls up to `addedCount` retained **display rows**
back out of history into the live grid, materialized to full width, and
decrements both running totals. `F4` Observation 5 enumerated "exactly three"
writes into retained history and found all three are bit flips on the tail;
this one is absent from that list because it removes rows rather than editing
one. Under the arena it is: fold the tail record at the current width, cut it at
the cell offset that begins the k-th-from-last display row, hand the suffix to
the live grid, rewind the write cursor, reopen the record, and decrement the
tail block's total -- which is a *sixth* index trigger point and the only
operation in the whole design that shrinks the arena from the back. `DD5`'s
counted display-row total has to be decremented by a number only the fold
produces. **Nothing in Phase 1 designs or prices this, and it is on the resize
path -- the path the doc exists to make cheap.** The arena's "middle immutable"
premise survives (this is the tail), but "the open line only ever grows at its
end" does not.

**`HR5` -- whole-record eviction (`DD2`) evicts an unbounded batch of display
rows, and four anchors clamp per eviction.** `Terminal.swift:3873
handleEviction` runs once per `enforceScrollbackBudget` with the total evicted
row count and drops the selection, the search occurrence, the hovered link and
the armed link whose start precedes the new first retained row, then re-clamps
the browsing anchor (`:3898`-`:3901`). Today one eviction step is one display
row, so the clamp moves by one. Under `DD2` one step is one record -- **367
display rows at 179 columns and 32,768 at the 2-column minimum**, using `F4`
Observation 3's own arithmetic for a 65,536-cell record. So one admitted row can
evict a screenful-plus, dropping a selection that survives today and jumping a
browsing viewport by hundreds of rows. `F4` case 27 prices the granularity as "the
budget can undershoot by at most one record", which is a *memory* statement; the
same granularity is user-visible in four anchors and in the scrollbar, and no
entry says so. `DD2`'s recorded alternative -- advance a head offset inside the
first record so eviction stays display-row granular -- is the mitigation, and
this is the argument for taking it in milestone 1 rather than later.

**`HR6` -- `ProjectionRows` hands out a materialized `GridRow` per display row,
which is the allocation the arena exists to delete.** `Terminal.swift:394` and
its readers at `:2647`, `:2684`-`:2695`, `:2712`, `:2740`-`:2768`, `:2798`,
`:3283`-`:3290`, `:3412`-`:3414`, `:3457`-`:3467`, `:3520`, `:3549`, `:3604`.
The subscript is one `unpacked()` today. Under the new store it must locate
(record, display-row-in-record) and *fold* the slice into a `GridRow`, re-adding
a per-row allocation on every pointer query and on `activeProjectionRows()`'s
whole-stream materialization. Making it a borrowing cursor instead is the right
answer, and it is a rewrite of all fourteen readers, not a translation. `F5`
Observation 3 conceded the migration was unenumerated; **this is the
enumeration, and by line count the projection layer is larger than the arena
itself** -- which is a fact `DD8`'s line-count reading should be re-read against
when Phase 2 lands something real.

**`HR7` -- two call sites read `contentIdentity`, which every Phase 1 probe
stripped, and they disagree about the unit.** `Terminal.swift:2891
activationIdentity` walks every cell of a link's range reading
`cell.contentIdentity`; `:2184 scrollbackRowContentIdentityShape` reports one
retained row's identity-run shape and does so deliberately over the
*unmaterialized* stored prefix, because "counting the materialized trailing
cells would report the pane's width rather than the row's content". Inherited
condition 9 says the record format must carry what the probes dropped; these two
sites are what makes it binding. `PackedRetainedRow`'s identity run table is
keyed by column within a display row (`:243`-`:266` binary search, `:499`-`:503`
the per-cell fallback). Under records the key becomes a cell offset within a
logical line, which is strictly better -- one table per record rather than per
display row, the advantage `F1` and `F3` both measured themselves as *not*
having taken. But `scrollbackRowContentIdentityShape`'s contract has no meaning
at a fold boundary: a display row's "stored prefix" is now a slice chosen by the
current width, so "the row's own content" is a width-dependent question about a
width-free store. The reader must be re-specified before it can be
re-implemented, and doc 28's `PR1` consumes it.

**`HR8` -- three running totals collapse to one, and `scrollbackRows.count` is
load-bearing in ten places as "the viewport's origin in stream coordinates".**
`Terminal.swift:969`, `:2090`, `:2125`, `:3219`, `:3243`, `:3815`-`:3816`,
`:3862`, `:3906`, `:4011`, `:4316`. Each is O(1) today because a retained row
*is* a display row. Under the new store each is the index's grand display-row
total -- and `DD5` maintains a **per-block** total, not a grand one. Either the
index maintains a grand total explicitly (a fifth maintained quantity, alongside
`HR1`'s cached anchor row), or these become a walk over the block array: ~40
blocks at `28/D11`'s trial depth and ~390 at 100,000 lines, on paths that run
around **every `feed` action** (`:966 damageActionSnapshot` is taken before and
after each one). Small per call, on the exact path `terminal-feed` and
`scrollback-stream` measure -- the two workloads carrying `H3`'s named
falsifier.

#### Observation 3 -- what the inventory says about the invariant that dies

`28/H7`'s entry names it: "history is always at the current width". The sweep
can now say precisely what depends on it, and the answer is narrower than the
site count suggests. Of the 69 sites, **only 13 read a *cell* out of history**
(`T2`, `T3`, `T4`, `T6`, `T7`, `T8`, `T9`, `R1`, `R2`, `R11`, `R16`, `R17`, and
`X11`'s `asArray`). The other 56 read a **count**, an **index**, or a **flag**:
`scrollbackRows.count` in ten places, `isSoftWrapped` in eight, an absolute row
number in twenty-odd, a byte or cell total in a dozen. That asymmetry is the
finding: the design's difficulty is not decoding cells at a width -- `F1`
measured that faster -- it is that **a display-row count is currently free and
becomes derived**, and the tree spends it like it is free.

Read the other way, this is also why the deletion side is real. Every one of the
five invariants `F5` Observation 5 deletes shows up here as a group of sites
that stop existing rather than a group that gets harder: `X1`+`X2`+`X3`+`X4` is
invariant 4 (ten anchors across a rebuild), `X6`+`X7` is invariant 5 (three
bounds), `X8`+`X9`+`X10`+`R13` is invariant 3 (the per-display-row continuation
flag under three tail edits), and `X5` plus `resizeWidth:4571`'s re-enforcement
is invariant 2 (narrow-then-widen must not evict). The one that does *not*
simply vanish is invariant 1, and `HR1`/`HR8` are where its remains sit.

- Observation: 69 display-row-indexed sites were enumerated across
  `lib/TerminalCore`, `lib/TerminalPTY` and `app/` -- 14 unchanged, 16
  index-translated, 18 rewritten, 13 deleted -- and 8 of them have a mapping
  that is not obviously satisfiable. The checkpoint and persistence path
  serializes history as text and is entirely unaffected;
  `isHistoryHeadTruncated` has no production consumer at all.
- Inference: inherited condition 6 is discharged, and the migration `F5`
  Observation 3 called "a one-time cost, but a cost, and it is unenumerated" now
  has a size and a shape. The shape is the surprise: the work is concentrated in
  the *projection and anchor* layer (`R1`-`R11`, `HR1`, `HR2`, `HR6`), not in
  cell decoding, because 56 of the 69 sites read a count, an index or a flag
  rather than a cell. Four of the eight flagged items (`HR1`, `HR4`, `HR5`,
  `HR8`) are new obligations on the block index and the arena that no Phase 1
  entry states; two (`HR3`, `HR5`) are user-visible behavior changes needing a
  human's disposition; one (`HR2`) gates whether `X3`/`X4`'s ~130-line deletion
  is real; one (`HR7`) makes inherited condition 9 concrete.

  Against `D1`'s eleven carried-forward conditions: this entry **discharges 6**
  (the call-site enumeration) and **advances five others** -- **2** (`HR5` names
  what `DD2`'s eviction granularity costs in four anchors and the scrollbar),
  **3** (`HR1` names the concrete mechanism by which the paired ladder could come
  back `slower` on `retained-browse`), **5** (`HR4` and `HR1` grow the block
  index's trigger-and-maintenance list from four items to six), **7** (`X13`
  hands the budget task the six per-row charge sites and the open question of
  whether the spill table and the two side tables sit inside the arena's byte
  budget), and **9** (`HR7` names the two `contentIdentity` readers that make
  the stripped-side-table condition binding, and finds their units disagree).
  Conditions 1, 4, 8 and 11 are untouched; condition 10 gains its first
  counter-example in `HR3`.
- Competing interpretations:
  1. *The count is inflated by grouping -- 69 "sites" is really a dozen
     functions.* Partly fair, and the tables group deliberately (`X6` is one row
     covering nine code locations). The number that matters is not 69 but the
     four in `HR1`, `HR2`, `HR4` and `HR6`, each of which is a design decision
     rather than an edit. A reader who prefers a smaller count should read the
     tables and ignore the total.
  2. *`HR1` is a strawman: nobody would leave an index lookup on a per-row
     path.* Correct that it is fixable, and the entry says how. It is flagged
     because today's code re-reads `scrollProjection` ~200 times a frame *because
     it is free*, and a mapping that silently makes it not-free is exactly the
     kind of thing that shows up first as a `slower` ladder verdict rather than
     as a review comment. `28/F17` is the precedent: the browsing regression it
     chased was a per-cell cost nobody intended either.
  3. *`HR3` is a rounding error nobody will see.* Possibly. It is recorded
     because it is the first case found where the read-time fold does **not**
     reproduce today's output, which is inherited condition 10's whole subject,
     and because `F3`'s cross-arm checksum gate would not have caught it -- the
     probe's stimuli contain no severed wrap claim.
  4. *This should have been done before `D1` closed.* `D1`'s frozen rule did not
     ask for it, and `F5` Observation 3 named the migration as an addition-side
     cost with no number rather than hiding it. Nothing found here fires a `D1`
     trigger: no site requires stored width.
- Uncertainty:
  - **The inventory is a reading, not a compile.** No mapping here has been
    implemented, and the only way to know the list is complete is to delete
    `ScrollbackBuffer` and see what fails to build. That is Phase 2's
    implementation, not this pass.
  - **Test suites are enumerated only where they assert a deleted API.** The
    ~40 resize/wrap tests `F4` swept, the 21 in
    `TerminalScrollbackBudgetTests.swift` and the 14 `isHistoryHeadTruncated`
    assertions are named; a full test-site inventory is not here and would be
    larger than the production one.
  - **`HR1`'s 164-218 us is arithmetic, not a measurement**: `F1`'s point-read
    median times an estimated 200 reads per frame. The real figure depends on
    what an implementation caches, which is the point of flagging it rather than
    pricing it.
  - **`HR5`'s 367 rows is `F4`'s bound, not an observed record.** No real
    session has been fed to see what record lengths actually occur (inherited
    condition 8).
  - **`app/` was swept for terminal-engine consumers only.** The GhosttyKit
    surface in `app/TerminalView.swift` is the old backend and was read only far
    enough to confirm it reaches history as text (`:913`, `:917`).
- Deferred decisions, continuing `F5`'s numbering; each took the obvious, simple
  choice rather than blocking:
  - **DD9 -- the public coordinate does not change: `TerminalTextPosition.row`
    stays a display row relative to the oldest retained row.** All translation
    happens inside `Terminal`. The alternative -- publishing record-relative
    addresses -- would change every consumer in `app/`, `lib/TerminalPTY` and
    the render planner for no measured benefit, and would put a store detail in
    a cross-module value type. This decision is about the *public* coordinate
    only and deliberately does not settle `HR2`, which is about the stored one.
    **Extended 2026-08-04 by [`D3`](decisions.md) Decision 2**, which settles the
    stored coordinate in the same direction: `TextAnchor` stays an absolute
    display row, so the public and stored coordinates are one `evictedRowCount`
    subtraction apart and "all translation happens inside `Terminal`" now
    describes both.
  - **DD10 -- `isHistoryHeadTruncated` is deleted rather than kept
    always-false.** `DD2` makes it constant, and a public property that is
    always `false` is a claim a future reader can act on. It has no production
    consumer -- 14 assertions in `TerminalScrollbackBudgetTests.swift` and
    nothing else -- so deleting costs less than documenting. Reopen if a
    consumer ever needs "did the last eviction cut inside a logical line", which
    the evicted record's open/closed bit can still answer. **Still stands after
    [`D2`](decisions.md)**, which makes head truncation reachable again: `D2`
    Decision 5 carries it as a header bit on the head record and Decision 2
    states the invariant it replaces, neither of which is a public property.
  - **DD11 -- the census's per-row leak proof is restated in arena terms.**
    `retainedCellStorageRowCount` (doc 15's `F4`) asserts that history does not
    hold storage for rows it has evicted; with one region there are no per-row
    allocations to count. The simple analogue: eviction must advance the arena's
    head and the region must not grow monotonically, asserted as bytes-in-use
    against capacity. Dropping the proof entirely was rejected -- doc 15's
    regression was real and cost twice the promised memory. **Made concrete by
    [`D2`](decisions.md) Decision 1**: the arena is allocated once at the
    budget's size and never grows, so the proof reads "bytes-in-use falls when
    records are evicted, and capacity does not grow", and the census reports the
    two quantities separately.
- Next action: Phase 2's second ledger task (budget and eviction semantics)
  inherits `HR5` (eviction granularity is user-visible in four anchors and the
  scrollbar, which is an argument for `DD2`'s head-offset alternative in
  milestone 1) and `X13` (the per-row charge model's six sites, and the question
  of whether the spill table and the two side tables are inside the arena's byte
  budget or charged beside it). The graduation task inherits `HR1`, `HR2`, `HR4`
  and `HR6` as the four design decisions a plan file has to make before it can
  be sliced. Inherited condition 5's trigger-point list grows from four to six:
  add `HR4`'s tail truncation and, if `HR1` is resolved by caching, the browsing
  anchor's display row.

  **Superseded 2026-08-04**: `D2` took `HR5` and `X13`, and
  [`D3`](decisions.md) took the four design decisions, so the graduation task
  now inherits a settled design rather than four open choices. `D3` Decision 1
  also answers the trigger-point sentence above: the list is six, and `HR1` is
  *not* resolved by caching the anchor's display row -- `D3` Decision 2 keeps the
  anchor a display row, so there is nothing left to cache.

### F7 -- the eager counting pass at the record count the budget admits: 0.76 ms for 1,048,576 blank records, 21.9x inside the one-frame bound, and flat per record

- Status: complete. This is the measurement `D2`'s open question named, and it
  **discharges** that question: the pass lands under one 60 Hz frame, so `D2`'s
  frozen rule leaves the one-bound design standing and **no record-count safety
  bound ships**. It licenses nothing else -- `D1`'s scoping is unchanged, no
  production storage change is licensed, and the paired ladder is still owed.
- Date and investigator: 2026-08-04, Claude (agent).
- Commit and worktree state: measured at `aec227c` (the commit that froze `D2`
  and its decision rule, written before this probe existed in the tree) plus the
  one file this entry adds --
  `lib/TerminalCore/Tests/TerminalCoreTests/TerminalLogicalLineBlankIndexProbe.swift`.
  **No file under `lib/TerminalCore/Sources/` is touched, and `F1`'s, `F2`'s and
  `F3`'s probe files are unedited**; this entry follows `F2`'s isolation practice
  and adds its own file rather than extending `F2`'s arms. The two untracked
  paths present throughout this doc's work are still present and still in no
  build: `TODO.md` and `docs/scratch/2026-08-04-scroll-sample-breakdown.md`.
- Commands, inputs, or reproduction:

      DANTERM_LOGICAL_LINE_PROBE=1 swift test -c release --package-path lib/TerminalCore \
        --filter TerminalLogicalLineBlankIndexProbe

  Conditions: AC power, low-power mode off, one-minute load average **1.78
  before and 1.78 after**, under the 2.5 gate. Release configuration, headless,
  one process, pre-built so the probe does not measure itself under its own
  compile (`F2` Observation 2's lesson). 9 measured rounds plus 2 warmup per
  cell, statistic = median over rounds of one whole pass, min and max and `n`
  beside every aggregate -- `F2`'s instrument unchanged.
- Artifacts: none durable. Every number below is stdout from the command above.

#### What was measured, and why this depth

`D2` Decision 1 charges the block index 8 bytes per record, so 16 MiB admits
**1,048,576 blank logical lines** (8 arena bytes + 8 index bytes each) -- 10.5x
the deepest depth `F2` measured. `D2`'s open question extrapolated `F2`'s
100,000-line per-line rate (5.49 ns) to ~6.4 ms against `F2`'s own one-frame
(16.67 ms) reject bound, called that arithmetic rather than a measurement, and
froze the rule this entry reads.

The timed region is `F2`'s exactly: one call of the eager recompute -- discard
every cached block total and rebuild `blockPrefix` for a new width, reading one
cell count per record and doing one divide. Both of `D1`'s count-sources are
reported, `arena` (primary; the count read from each record's header through
`lineOffsets`) and `counts` (the priced alternative; a dense parallel array).

#### Observation 1 -- the measured passes, and the rule `D2` reads them against

Median milliseconds per whole pass at **1,048,576 records**, `n=9` per cell.
The zero-cell column is `D2`'s stimulus and is the verdict-bearing one; the
one-cell column is descriptive (see `DD15`).

| width change | source | zero-cell records | ns/record | one-cell records |
| --- | --- | ---: | ---: | ---: |
| 179 -> 179 | `arena` (primary) | **0.760 ms** | 0.72 | 1.378 ms |
| 179 -> 100 | `arena` (primary) | **0.761 ms** | 0.73 | 1.378 ms |
| 179 -> 200 | `arena` (primary) | **0.760 ms** | 0.72 | 1.381 ms |
| 179 -> 179 | `counts` | 0.689 ms | 0.66 | 1.344 ms |
| 179 -> 100 | `counts` | 0.689 ms | 0.66 | 1.352 ms |
| 179 -> 200 | `counts` | 0.689 ms | 0.66 | 1.343 ms |

**`D2`'s frozen rule applied once**: at or above 16.67 ms a record-count safety
bound ships; under it, the one-bound design stands. The worst verdict-bearing
cell is **0.761 ms**, **21.9x inside** the bound. **No record-count bound
ships**, `D2` Decision 1's single charged-byte bound stands as decided, and
Decision 3's "keep at most N logical lines" comparison stays *available and
unbuilt*, which is exactly where Decision 3 left it.

The rule is not close to firing on any reading of the stimulus: the descriptive
one-cell arm -- the record format `DD15` decides against, which doubles the
arena stride -- is 1.38 ms, still **12.1x inside**, and it would in any case be
measured at *fewer* records (16 MiB / 24 B = 699,050), so 1,048,576 bounds it
from above.

#### Observation 2 -- the extrapolation was 8.4x pessimistic, and the ladder says why

Descriptive ladder, width 179 -> 100, blank (zero-cell) records:

| records | `arena` median | ns/record | `counts` median | ns/record |
| ---: | ---: | ---: | ---: | ---: |
| 10,000 | 0.007 ms | 0.71 | 0.007 ms | 0.66 |
| 100,000 | 0.069 ms | 0.69 | 0.065 ms | 0.65 |
| 300,000 | 0.210 ms | 0.70 | 0.195 ms | 0.65 |
| 1,048,576 | 0.758 ms | 0.72 | 0.692 ms | 0.66 |

The per-record cost is **flat across two orders of magnitude** -- 0.69 to 0.73
ns for the primary source -- where `F2`'s `mix`/`full` ladder rose from 1.60 to
5.49 ns/line between 10,000 and 100,000. `D2`'s ~6.4 ms extrapolation took
`F2`'s degraded 100,000-line rate and multiplied; the measurement is **0.76 ms**,
8.4x cheaper, because the rate does not degrade here at all.

The mechanism the data fits, stated as an explanation and not an attributed
cause (no counter was read): `F2`'s degradation was **stride**, not record
count. At 100,000 lines of `mix` content the arena is 172 MB and the header
chase touches one record per ~2.9 KB of it; a blank arena is 8 bytes per record,
so the same "strided chase" is a dense sequential scan of 8 MB and the prefetcher
sees every byte. The corroboration is in the same run: `arena` and `counts`,
which `F2` measured 4.3x apart at 100,000 lines, are **within 10%** of each other
here (0.72 vs 0.66 ns/record) -- the two count-sources converge exactly when the
stride does. The one-cell arm is the control on that reading: doubling the stride
to 16 B costs 1.81x, which is the direction and roughly the magnitude the
mechanism predicts.

This is the second time the campaign has measured the middle of a curve rather
than acting on its endpoints (`agent-docs/measurement-discipline.md`), and the
second time the extrapolation had the shape wrong.

#### Observation 3 -- the gates, including the one the blank stimulus weakens

1. **Non-elision.** Every timed pass's total was cross-checked against a sum
   computed by a route the blocked prefix does not share, and no total was zero:
   all 270 passes in the primary measurement matched, as did the ladder's 72.
   **But a blank arena folds to one display row per record at every width, so
   its total cannot show that the pass responded to width** -- the half of
   `F2`'s gate 1 that catches a hoisted loop is inapplicable to this stimulus,
   and saying so is why the probe carries a **sentinel arm**: the same 1,048,576
   records with one full-width (179-cell) record every 1,000th, whose total is
   1,048,576 at widths 179 and 200 and **1,049,624 at width 100**. The pass
   responds to width on the same code path at the same depth, measured in the
   same session. The sentinel arm's own times (0.695-0.751 ms) are also the
   answer to "is the zero-cell arm fast because the divide is trivial": adding
   1,048 records that take the full `ceil` path changes nothing.
2. **Synthetic-stimulus fidelity.** `F2`'s control, unchanged in form: at 10,000
   records the arena was built both ways -- through a real `Terminal` fed 10,000
   CRLFs and read back through `retainedRowForTesting`, and synthetically from
   the same per-record counts -- and both were measured in every cell. Ratios
   spanned **0.997x to 1.003x** against the 15% the rule allows, and the two
   arenas agreed exactly on byte count (160,000 B) and record count. The
   synthetic extension to 1,048,576 records is admissible.
3. **Host conditions.** AC power, low-power mode off, load 1.78 before and 1.78
   after, both under 2.5.
4. **Coverage.** `n=9` beside every median, with min and max; no aggregate is
   reported without its sample count.
5. **Content-class calibration: inapplicable, and dropped explicitly rather than
   silently.** `F2` gated `mix` against `28/F23`'s measured cell-count band. A
   blank stimulus has no content distribution to calibrate -- every record holds
   zero cells by construction, which is the definition of the regime `D2`
   Decision 1 bounds. What replaces it is the report of the achieved geometry
   (8 B per record, 8,388,608 arena bytes + 8,388,608 index bytes = exactly the
   16,777,216 B budget) and the engine-side check in gate 2.
6. **A/A control: not part of `F2`'s rule and not added.** `F2` measures an
   absolute cost against a frozen bound rather than a ratio between two arms, so
   there is no second arm to interleave; the instrument's own spread is reported
   instead as min/max beside every median, and it is under 2% on every
   verdict-bearing cell.

**No invocation was voided.** One earlier invocation *crashed* before producing
any timing and is recorded rather than dropped: the probe's precondition that a
blank retained row packs to zero stored cells fired, because
`PackedRetainedRow.pack` floors the canonical extent at **one** cell (`I2`).
That is a defect in the probe's model of the stimulus, not a gate failure on a
measurement -- it produced no number to void -- and it is the reason `DD15`
exists below. The instrument caught a wrong assumption instead of quietly
measuring the wrong thing, which is what a precondition on a stimulus is for.

- Observation: the eager block-total recompute costs **0.760-0.761 ms** at
  1,048,576 zero-cell records for the primary count-source, at all three width
  changes, and its per-record cost is flat from 10,000 to 1,048,576 records.
- Inference: the blank-line regime does not threaten the eager pass. `D2`
  Decision 1's single charged-byte bound needs no record-count companion, and
  `H2`'s confirmation extends from `F2`'s 100,000 lines of content to the full
  record count 16 MiB admits. The degenerate regime is *cheaper* per record than
  the content regimes `F2` measured, not dearer, because record count and stride
  move in opposite directions under a fixed byte budget.
- Competing interpretations:
  - *The loop was optimized away.* Refuted by gate 1 plus the sentinel arm: every
    pass's total was consumed and cross-checked, and the sentinel arm's total
    changes with width on the same code path at the same depth.
  - *The synthetic arena is not the real one.* Gate 2: where both can be built
    they agree within 0.3%, on identical geometry.
  - *This is fast because the records are trivial.* Partly, and that is the
    finding: a blank record is the whole regime `D2` Decision 1 bounds. The
    one-cell arm and the sentinel arm both price departures from triviality
    (1.81x and 1.00x respectively), and both stay far inside the bound.
  - *A zero-cell record is not what the store would hold.* `DD15` takes that on
    directly, and the one-cell arm bounds the alternative -- which admits fewer
    records, so this measurement bounds it from above either way.
- Uncertainty:
  - **The pass is not the resize.** As `F2` said: a width change also refolds the
    live screen, which this design does not remove and this probe does not
    measure.
  - **Nothing about eviction.** An arena that has evicted from its front has a
    different offset structure than one that only ever grew. Still unmeasured,
    still inherited condition 2, and `D2` Decision 2's head-trim adds a per-step
    fold walk that no probe has seen.
  - **Nothing about wide content.** These records hold no cells at all, so the
    O(cells) wide-record scan (`F4` Observation 1, inherited condition 1) is
    untouched by this entry. A blank-record measurement cannot be quoted against
    it in either direction.
  - **The 16 MiB arena is not a 16 MiB working set here.** The zero-cell arm
    touches 8 MB of arena plus 8 MB of `lineOffsets`; a real arena at this record
    count would also carry whatever the index and side tables cost. The charge
    arithmetic is `D2`'s, and this entry measures the pass over it rather than
    re-deriving it.
  - **One machine, one session.** As with `F1`, `F2` and `F3`.
- Deferred decisions, continuing `D2`'s numbering; the obvious simple choice,
  taken at measurement time rather than blocking:
  - **DD15 -- a blank logical line is stored as a zero-cell record, and today's
    one-cell canonical floor does not transfer to the arena.**
    `PackedRetainedRow.pack` floors the canonical extent at one cell (`I2`)
    because a display row is the unit it stores; a record's cell count is a
    content property and zero is representable, which is what `D2` Decision 1's
    "8 arena bytes and 8 index bytes" already assumes. The alternative -- inherit
    the floor -- costs 16 arena bytes per blank record and admits 699,050 rather
    than 1,048,576 at the same budget, i.e. it is strictly the smaller number, so
    nothing in `D2` or here turns on the choice. Recorded because `D2`'s derived
    1,048,576 rests on it and because a probe crashed on the assumption. A
    human's to revisit; the record format is Phase 3's.

    **Amended 2026-08-04 by the external design review: a zero-cell record needs
    a fold *floor* to be worth what `D2` counts it.** A record's display-row count
    is `max(1, ceil((cells + spacers) / width))`. Without the `max(1, ...)` a
    blank logical line folds to **zero** display rows, a blank history folds to
    nothing at all, and `D2` Decision 1's 1,048,576-records-to-**rows** reading --
    together with this entry's own ladder, which counts one row per blank
    record -- is off by the whole quantity. The floor is what makes a zero-cell
    record read as the blank line the user printed, and it is stated in the plan's
    `I9`.
- Next action: `D2`'s open question is closed and its reopening condition 1 is
  spent -- the graduation task inherits no record-count bound. Two things this
  entry hands forward: the counting pass's cost is governed by **stride, not
  record count**, so any future re-measure of it (the wide-content one inherited
  condition 1 asks for) should vary bytes-per-record rather than depth; and the
  parallel counts array stays unnecessary, now on a second regime -- it is within
  10% of the primary source here, against 4.3x at `F2`'s 100,000 content lines.

### F9 -- the wide-content counting pass at the depth 16 MiB admits: 5.44 ms at the engine's minimum width, ~3x inside one frame, and flat at 5.2-5.4 ns per display row

- Status: complete. This is the measurement `D3` Decision 7 froze, and its rule
  reads **narrow confirm**: the eager pass stands, no mitigation ships, and the
  band-crossing cell -- `wide` at `179 -> 2` -- is recorded below as a condition
  on the store's depth. Inherited condition 1 (the wide-record counting
  fallback) is **discharged**, in the branch that changes no design and no
  constant. It licenses nothing else: `D1`'s scoping is unchanged, no production
  storage change is licensed, and the paired ladder is still owed.
- **Numbered `F9`, not `F8`**, because `D4` -- frozen at `2ac87e1`, before this
  probe existed -- reserves `F8` for the eviction measurement and the residency
  reading it governs (the plan's slice 4). This doc numbers findings by
  reservation rather than by landing order, as `F3` and `F4` already are.
- Date and investigator: 2026-08-04, Claude (agent).
- Commit and worktree state: measured at `2ac87e1` (the commit that promoted the
  plan and froze `D4`) plus the one file this entry adds --
  `lib/TerminalCore/Tests/TerminalCoreTests/TerminalLogicalLineWideIndexProbe.swift`.
  **No file under `lib/TerminalCore/Sources/` is touched, and `F1`'s, `F2`'s,
  `F3`'s and `F7`'s probe files are unedited**; this entry keeps `F2`'s isolation
  practice and adds its own file. The two untracked paths present throughout this
  doc's work are still present and still in no build: `TODO.md` and
  `docs/scratch/2026-08-04-scroll-sample-breakdown.md`.
- Commands, inputs, or reproduction:

      DANTERM_LOGICAL_LINE_PROBE=1 swift test -c release --package-path lib/TerminalCore \
        --filter TerminalLogicalLineWideIndexProbe

  Conditions: AC power, low-power mode off, one-minute load average **1.57 before
  and 1.57 after**, under the 2.5 gate. Release configuration, headless, one
  process, pre-built and the machine allowed to settle before the measured
  invocation (`F2` Observation 2's lesson). 9 measured rounds plus 2 warmup per
  cell, statistic = median over rounds of one whole pass, min and max and `n`
  beside every aggregate -- `F2`'s instrument, with the three changes `D3`
  Decision 7 names and no others.
- Artifacts: none durable. Every number below is stdout from the command above.
- **No invocation was voided.** Three earlier invocations were run and are
  recorded rather than hidden: a shakedown, whose purpose was to find a crash or a
  gate failure and which found neither; one before the probe was renumbered `F8`
  -> `F9`; and one before an unused `CaseIterable` conformance was removed from
  it. All three cleared every gate, all three returned the same verdict under the
  rule, and their medians sit within ~5% of the quoted ones. The quoted invocation
  is the last one, taken from the file exactly as committed with the machine
  settled; nothing was selected on the numbers.

#### What was measured, and what the fallback actually is

`D3` Decision 7's reframing is the thing under test: the wide-record fold is not
an `O(cells)` scan. To fold a record the pass needs to know, at each display-row
boundary, whether a 2-cell cluster straddles it -- one probe per **display row**.
The probe walks a flagged record's boundaries, reads the cell that would occupy
the last column, and takes `width - 1` cells instead of `width` when that cell
starts a cluster (`Terminal.swift#pack`'s spacer rule read from the record's
side; iTerm2's `LineBuffer` loop read from the other). An unflagged record takes
`F2`'s divide. The timed region is `F2`'s: one call of the eager recompute,
discarding every cached block total and rebuilding `blockPrefix` for a new width.

The stimulus is `F3`'s `wide` CJK generator through a real `Terminal` at 179x66:
10,000 records, 20,572 engine display rows, 2,777,004 cells, 2,229.6 bytes per
record against `F3` Observation 4's 2,215 (0.7% apart), 10,572 spacers at 179
columns, **100% of admitted rows carrying a wide cell and 100% of records
flagged**. Depths are `D3` Decision 7's: the record count 16 MiB admits for that
class, plus `F2`'s 10,000 and 100,000 rungs for continuity. Widths are `F2`'s
three plus `179 -> 2`, the engine minimum (`F4` case 3), where display rows per
record -- and therefore boundary probes -- are maximised.

#### Observation 1 -- the verdict-bearing arm, and the rule applied once

A budget-full wide arena: **7,531 records, 2,082,012 cells, 16,716,344 arena
bytes + 60,248 index bytes = 16,776,592 B charged** of the 16,777,216 B budget.
`n=9` per cell; the `fast path` column is `F2`'s divide over the *same* records,
which counts wide content wrong and is here as the contrast and the elision
guard.

| width change | display rows | wide-aware median | min / max | ns/display row | fast path | ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 179 -> 179 | 15,440 | **0.064 ms** | 0.064 / 0.068 | 4.17 | 0.012 ms | 5.49x |
| 179 -> 100 | 24,633 | **0.144 ms** | 0.142 / 0.164 | 5.84 | 0.012 ms | 12.29x |
| 179 -> 200 | 13,945 | **0.056 ms** | 0.055 / 0.057 | 3.99 | 0.012 ms | 4.74x |
| 179 -> 2 | 1,041,006 | **5.439 ms** | 5.425 / 5.603 | 5.22 | 0.012 ms | 464.52x |

**`D3` Decision 7's three-way rule, applied once.** Reject required a median at
or above **16.67 ms** on a measured cell; the worst verdict-bearing cell across
this arm and the ladder below is **5.634 ms**, **2.96x inside** the frame.
Confirm required every cell under **1.67 ms**; every `179 -> 2` cell measured is
1.835-5.634 ms, so that band is entered. **The verdict is narrow confirm.** Eager
stands, the per-record cached count and the lazy per-block recompute both stay
unbuilt, and the recorded band-crossing cell is **(`wide`, `179 -> 2`)** -- CJK
content at the engine's minimum width, where every display row holds exactly one
cluster.

Stated as a depth condition rather than as a width: the pass costs **5.2-5.4 ns
per display row** with the fallback engaged, so one 60 Hz frame is **~3.1-3.2
million display rows**. The 16 MiB budget admits **1,046,528** of them in the
worst case measured, a **~3x** margin -- and `D3` Decision 7's own arithmetic
bracket, written before any of this was measured, said 3.2x at a pessimistic 5 ns
per probe. The bracket was right in shape and in constant.

#### Observation 2 -- the ladder that matters is cells per record, and it is flat

`F7` handed forward that the counting pass's cost is governed by **stride, not
record count**, so this ladder holds the 16 MiB charge fixed and varies bytes per
record. Every rung is budget-admissible and therefore verdict-bearing (`DD23`).
Medians in milliseconds, `n=9` per cell.

| cells/record | records | cells | 179 -> 179 | 179 -> 100 | 179 -> 200 | 179 -> 2 | rows at width 2 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2 | 524,288 | 1,048,576 | 1.283 | 1.278 | 1.278 | **1.835** | 524,288 |
| 8 | 209,715 | 1,677,720 | 0.516 | 0.516 | 0.517 | **2.765** | 838,860 |
| 32 | 61,680 | 1,973,760 | 0.301 | 0.301 | 0.301 | **4.504** | 986,880 |
| 128 | 16,131 | 2,064,768 | 0.040 | 0.095 | 0.040 | **5.415** | 1,032,384 |
| 276 | 7,543 | 2,081,868 | 0.042 | 0.081 | 0.042 | **5.475** | 1,040,934 |
| 1,024 | 2,044 | 2,093,056 | 0.052 | 0.126 | 0.051 | **5.634** | 1,046,528 |
| 4,096 | 511 | 2,093,056 | 0.104 | 0.201 | 0.089 | **5.452** | 1,046,528 |

Two readings, and the second is the finding.

The `179 -> 2` column is **flat in display rows across three orders of magnitude
of record size**: 3.50 ns/row at 2 cells a record down to 5.21-5.38 ns/row from
128 cells a record upward, over 524,288 to 1,046,528 rows. Cells per record moves
the *number* of display rows the budget buys by 2x and moves the *cost per row*
by well under 2x. That is what `O(display rows)` with an O(1) test per boundary
predicts, measured rather than bracketed.

The other three columns are the fast-path regime seen from inside the wide
pass. At 2 and 8 cells a record no boundary probe fires at all at widths 100,
179 and 200 -- the record is shorter than one display row -- so those cells price
the header chase alone, at 2.44-2.47 ns per record against `F7`'s 0.72 ns for an
8-byte stride. The stride here is 24 bytes (an 8-byte header plus two 8-byte
cells), and `F7`'s mechanism reading survives the check: cost tracks stride.

#### Observation 3 -- the gates, including the two this stimulus changes

1. **Non-elision.** Every timed pass's total was cross-checked against a total
   computed by a route that reads no arena byte -- for content that is CJK end to
   end a display row holds `2 * (width / 2)` cells, so the total is closed-form
   arithmetic over the cell counts -- and no total was zero. All 108 passes in the
   primary arm matched, as did the fast-path arm's 36 against its own expectation,
   the cells-per-record ladder's 252 and the continuity ladder's 36. **The half of `F2`'s gate 1 that
   catches a hoisted loop is intact here and is stronger than `F7` could make
   it**: the totals move with width (15,440 rows at 179, 24,633 at 100, 13,945 at
   200, 1,041,006 at 2) *and* the fast-path arm over the identical records
   produces a **different** total at the odd width (15,405 against 15,440), which
   is the spacer the fold puts back. A boundary walk that had been optimized away
   would report the fast path's number and fail the check.
2. **Synthetic-stimulus fidelity.** The 10,000-record arena was built both ways --
   through a real `Terminal` fed `F3`'s CJK lines and read back through
   `retainedRowForTesting`, and synthetically from the same per-record cell counts
   -- and both were measured at every width. Ratios spanned **0.948x to 1.000x**,
   inside the 15% the rule allows, and the two arenas agreed exactly on byte count
   (22,296,032 B) and record count. The synthetic extension to the budget depth
   and along the ladder is therefore admissible.
3. **Host conditions.** AC power, low-power mode off, load 1.57 before and 1.57
   after, both under 2.5.
4. **Coverage.** `n=9` beside every median, with min and max; no aggregate is
   reported without its sample count.
5. **Content-class calibration: replaced, not dropped.** `F2` gated `mix` against
   `28/F23`'s measured cell-count band, which is an **ASCII** band and cannot be
   applied to CJK. What stands in its place is `F3`'s own `wide` band (at least
   50% of admitted rows carrying a wide cell, at least one spacer present:
   measured 100% and 10,572), the achieved geometry against `F3` Observation 4
   (2,229.6 B/record against 2,215), and -- the substantive one -- **the fold is
   checked against the engine's own wrapping**: the derived display-row count
   matches the 20,572 rows the engine produced for those 10,000 records, record
   by record. That is `F4`'s corrected arithmetic, spacers included, held to the
   engine rather than to itself.
6. **The count-source arm is inapplicable, and what replaces it is reported.**
   `F2` and `F7` price `arena` against `counts` -- whether the index carries a
   dense parallel array of per-record cell counts. A flagged record cannot be
   counted from such an array at all: the boundary probes must read the record's
   cells wherever the count came from. So the primary source is the only
   measurable one, and the second arm's place is taken by the **fast path over
   the same records**, which is what the fallback is measured against (columns 6
   and 7 of Observation 1's table).
7. **A/A control: not part of `F2`'s rule and not added**, for `F7`'s reason --
   this instrument measures an absolute cost against a frozen bound rather than a
   ratio between two arms. The instrument's own spread stands in, and it is not
   uniform: on the `179 -> 2` cells the verdict actually turns on, min and max sit
   within **3.4%** of the median (5.425 / 5.439 / 5.603 ms on the budget arm); on
   the sub-0.5 ms cells the spread reaches **14%** of the median, which is under
   30 microseconds in absolute terms and three orders of magnitude from any
   bound.
8. **Cross-session control.** `F2`'s `mix` and `full` arms were re-run unchanged
   in this session, as `D3` Decision 7 asks: **0.015-0.016 ms** at 10,000 lines at
   every width, against `F2`'s published 0.015-0.016 ms. No record in those
   classes is flagged, so none takes the fallback, and the machine this ran on is
   the machine `F2` ran on.

#### Observation 4 -- the continuity rungs, descriptive and outside the verdict

`D3` Decision 7 named `F2`'s 10,000 and 100,000 rungs "for continuity". At this
class's ~2,229 bytes a record those are **22.4 MB** and **223.8 MB** of charge
against a 16.8 MB budget, so they are depths the store cannot reach -- the same
thing `F2` Observation 3 said about its own 100,000-line rung. They are reported
and are **not** verdict-bearing (`DD23`).

| records | cells | charged | 179 -> 100 | ns/row | 179 -> 2 | ns/row |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10,000 | 2,777,004 | 22,376,032 B | 0.193 ms (32,819 rows) | 5.87 | 7.262 ms (1,388,502 rows) | 5.23 |
| 100,000 | 27,770,040 | 223,760,320 B | 11.466 ms (328,190 rows) | 34.94 | 72.653 ms (13,885,020 rows) | 5.23 |

**Said plainly, because it is the one number that could be misread as a reject:**
at 100,000 wide records -- 13.3x the charge the budget permits -- the `179 -> 2`
pass costs 72.7 ms, four frames. It is not a verdict cell and `DD23` says why
before the number is read; it is also not a hazard the design carries, because
the budget is the arena and the arena cannot hold that content.

What the two rows do show is which term degrades. At `179 -> 2` the per-row cost
is **5.23 ns at both depths** -- the boundary walk is a dense sequential scan
inside a record and the prefetcher sees it. At `179 -> 100` the per-row cost goes
from 5.87 ns to 34.94 ns between the two, which is `F2` Observation 3's cache
residency effect on the **header chase**, over a 224 MB arena. So the fallback's
own term is the cache-friendly one; what degrades with depth is the pointer chase
`F2` already measured and `F7` already explained.

- Observation: the wide-content counting pass costs **0.056-0.144 ms** at the
  three ordinary widths and **5.439 ms** at the engine's minimum width, on the
  deepest wide history a 16 MiB budget admits (7,531 records, 2,082,012 cells,
  1,041,006 display rows at width 2), with a per-display-row cost of **3.99-5.84
  ns** that stays flat from 2 to 4,096 cells per record.
- Inference: `D3` Decision 7's reframing holds as measured, not merely as an
  argument. The fallback is `O(display rows)` with a 5.2-5.4 ns constant, the
  frame bound sits at ~3.1-3.2 million display rows, and the budget admits about
  3x fewer than that in its worst case. **Narrow confirm**: the eager whole-index recompute
  stands for milestone 1 exactly as `F2` and `F7` left it, no per-record cached
  count and no lazy per-block recompute ships, and the README's Rejected entry for
  lazy recompute is **not** spent. The condition recorded against the store's
  depth is the `179 -> 2` cell: a resize to the engine minimum with a budget-full
  CJK history spends about a third of one frame in the counting pass.
- Competing interpretations:
  - *The boundary walk was optimized away.* Refuted by gate 1 and, specifically,
    by the fast-path arm: at width 179 the two passes over the identical arena
    report different totals (15,440 against 15,405), so the walk demonstrably ran
    and demonstrably inserted the spacers.
  - *The synthetic arena is not the real one.* Gate 2: where both can be built
    they agree within 9.1% on time and exactly on geometry, and the real arena's
    fold agrees with the engine's own wrapping row by row.
  - *The probe reads one byte where a real implementation reads a cell word.*
    True, and recorded as `DD24`: both touch the same cache line, so the
    difference is register work rather than memory traffic -- and the measured
    5.2-5.4 ns/row is already at `D3`'s **pessimistic** 5 ns/probe estimate rather
    than at its optimistic 0.7 ns one, so the arm is not where the cost hides.
  - *5.6 ms is not free.* Correct, and that is why the rule has a middle band and
    why this entry is a narrow confirm rather than a confirm. What it replaces at
    that depth is `28/F15`'s reflow, which is `1.85 us x rows + 0.352 us x cells`
    -- but the two numbers come from different instruments and different stores,
    so the comparison is an order of magnitude, not a figure.
- Uncertainty:
  - **The pass is not the resize.** As `F2` and `F7` said: a width change also
    refolds the live screen, which this design does not remove and this probe does
    not measure. At `179 -> 2` the live screen's own refold is likely to dominate,
    and nothing here says otherwise.
  - **One geometry of wide content.** The stimulus is CJK end to end. A record
    that mixes narrow runs with occasional clusters is flagged and takes the same
    walk, but its boundary probes are cheaper per cell because more cells fit per
    row; that case is bracketed by these numbers from above and was not measured.
  - **Nothing about eviction.** Unmeasured here as everywhere before `F8`: an
    arena that has evicted from its front has a different offset structure. The
    amended `AR1` names `O(cells in that row)` for a wide head-trim step, which is
    this probe's per-row term seen one row at a time -- but a walk that starts
    from a persisted offset is not this pass, and `D4` prices it.
  - **The budget-full arena is synthetic.** Its geometry is the engine's (gate 2)
    but a real 16 MiB pane also carries the side tables `D2` charges and this
    probe does not build.
  - **One machine, one session.** As with `F1`, `F2`, `F3` and `F7`.
- Deferred decisions, continuing `F7`'s numbering; each took the obvious simple
  choice at measurement time rather than blocking:
  - **DD23 -- a measured cell is verdict-bearing iff its charged bytes fit the
    16 MiB budget.** `D3` Decision 7 says the rule reads "every measured cell" and
    also names continuity rungs at 10,000 and 100,000 records, which for this
    class are 22.4 MB and 223.8 MB of charge. Both cannot be true at once, and
    this entry resolves it toward the budget: the decision was written into the
    probe's own header before the probe was first run, and it is the reading `D3`
    Decision 7 derived its bracket from (its stated worst case is "~2.08M stored
    cells become ~1.04M display rows", which is the budget-full arena and nothing
    larger) and the one `F7` handed forward (vary bytes per record, not record
    count). The alternative -- read every cell literally -- would return **reject**
    on a 223.8 MB arena that `I2` makes unrepresentable, and would spend the lazy
    per-block recompute on a depth the store cannot hold. A human's to revisit;
    if the byte budget ever grows, the rung to re-read is the one whose charge it
    then admits.
  - **DD24 -- the boundary probe reads the byte holding the kind field, not the
    whole 8-byte cell word.** Both loads touch one cache line, so the choice is
    register work; the alternative (assemble the `u64` as `F1`'s readers do) would
    add shifts that no real implementation needs to perform for a 3-bit test. It
    is recorded because it is the one place where an instrument choice could
    flatter the fallback, and because the measured per-probe cost lands at `D3`'s
    pessimistic estimate rather than under it, which is the evidence that it does
    not.
- Next action: `D3` Decision 7 is discharged and inherited condition 1 is closed
  in its narrow-confirm branch; the plan's slice 3 proceeds unchanged, with no
  mitigation to absorb. Two things this entry hands forward: the counting pass's
  cost is **5.2-5.4 ns per display row** once the fallback engages, which is the
  constant any future depth or budget question should be read against (one frame
  is ~3.1-3.2M display rows); and the `179 -> 2` cell is the store's depth condition,
  so a resize-to-minimum with a budget-full CJK history is the case a later
  end-to-end resize measurement should include rather than assume.

### F8 -- eviction and residency, both **reject**: the landed store's write path costs 1.42x-3.18x today's and its arena is resident from construction, and the attribution arm says neither number is wrap-at-read's

- Status: complete, and it is the only entry in this doc that returns a
  **reject** -- twice. `D4`'s eviction rule reads **reject** (the candidate is
  above 1.09x arm A on *both* statistics on *all four* verdict-bearing classes)
  and `D4`'s `AR6` residency rule also reads **reject** (the arena is resident at
  1.118x today's store for the same fed input on `scrollback-mixed`, over the
  1.10x second trigger). Inherited condition 2 -- *eviction unmeasured on both
  sides*, the largest unmeasured term in the campaign -- is **discharged as a
  measurement**, in its reject branch. `AR6` is **discharged as a gate**, in its
  reject branch, which ships a remedy. Neither verdict lands or fails the store:
  `D1`'s scoping is unchanged, no production storage change is licensed here, and
  landing is still the paired ladder's. **Disposition of both rejects is a
  human's**, and `D4` said so before either number existed.
- **The reject is attributed, and it is not the design's.** A third,
  descriptive arm ran `F3`'s own prototype beside the landed store on the same
  rows in the same session. `F3`'s prototype admits at **0.52x-0.64x** of today's
  cost -- reproducing `F3`'s published result -- while
  `Terminal.LogicalLineStore.admit` costs **1.79x-2.76x** of today's and
  **3.01x-4.31x** the prototype. Wrap-at-read admission is not what rejects; this
  implementation of it is. Gate 7, the one gate `D4` wrote to catch an
  implementation that does not match `D2` Decision 2, **passes at 1.000x**.
- Date and investigator: 2026-08-04, Claude (agent).
- Commit and worktree state: measured at `c8238ca` (the commit that landed the
  arena unwired) plus the one file this entry adds --
  `lib/TerminalCore/Tests/TerminalCoreTests/TerminalLogicalLineEvictionProbe.swift`.
  **No file under `lib/TerminalCore/Sources/` is touched, and `F1`'s, `F2`'s,
  `F3`'s, `F7`'s and `F9`'s probe files are unedited**; this entry keeps `F2`'s
  isolation practice and adds its own file. Arm B is **not** a prototype: it is
  `Terminal.LogicalLineStore` as slice 3 landed it, driven through its own
  `admit` and `evictOneDisplayRow`. The two untracked paths present throughout
  this doc's work are still present and still in no build: `TODO.md` and
  `docs/scratch/2026-08-04-scroll-sample-breakdown.md`.
- Commands, inputs, or reproduction:

      DANTERM_LOGICAL_LINE_PROBE=1 swift test -c release --package-path lib/TerminalCore \
        --filter TerminalLogicalLineEvictionProbe

      DANTERM_LOGICAL_LINE_PROBE=1 DANTERM_RESIDENCY_CASE=arena/plain/cycled \
        swift test -c release --package-path lib/TerminalCore --filter residencyReading

  the second once per `<store>/<class>/<state>` triple, which is `D4`'s
  one-process-per-state requirement. Conditions: AC power, low-power mode off,
  one-minute load average **1.52 before and 1.34 after** on the quoted eviction
  invocation and 1.3-1.5 across the twelve residency ones, all under the 2.5
  gate. Release, headless, 179x66, the 16,777,216-byte production budget, ABBA
  interleaving at 5 measured rounds plus 2 warmup, median over rounds with min,
  max and `n` beside every aggregate -- `D4`'s instrument, with the two
  substitutions the probe file's header states and no others.
- Artifacts: none durable. Every number below is stdout from the commands above.
- **Ten invocations were voided and are recorded rather than hidden**, every one
  of them on the same cell. Gate 5's A/A control on (`full`, `drain`) exceeded
  the 5% ceiling in **10 of 22** gated invocations of the verdict-bearing arms
  (worst -10.62%, +10.62%; the rest between 5.1% and 8.3%). **That cell is the
  instrument's floor and is stated as a limitation rather than worked around**:
  arm A's `full` drain is 2,000 `free` calls over ~180 microseconds, and the
  allocator's state after a 24,004-row rebuild is what moves it. **Nothing was
  selected on the numbers** -- the verdict is reject in all 22, at ratios between
  1.41x and 3.24x, and the quoted invocation's ratios sit inside that spread; it
  is one of the twelve that cleared every cell, at a worst cell of -1.16%. Two
  further invocations are **superseded** rather than voided: they copied one
  saturated baseline per round instead of rebuilding it, which let arm A's
  evictions decrement a shared reference instead of calling `free` (Observation
  5). Two residency invocations were voided for the reason `DD32` gives.

#### Observation 1 -- the two verdict-bearing statistics, and the rule applied once

Both arms were filled to the 16,777,216-byte budget from the same cycled fed
stream before anything was timed, and each was rebuilt per round. `n=5` rounds
per cell, 5,000 admissions per `steady` round and 2,000 eviction steps per
`drain` round.

**`steady` -- the whole write path, nanoseconds per admitted display row.**

| class | arm A (today) | min / max | arm B (arena) | min / max | ratio |
| --- | ---: | ---: | ---: | ---: | ---: |
| `mix` | 737.2 | 735.8 / 779.3 | 1,789.1 | 1,774.5 / 1,834.1 | **2.427x** |
| `full` | 708.0 | 696.9 / 714.6 | 2,249.4 | 2,244.3 / 2,307.7 | **3.177x** |
| `stream` | 754.1 | 752.9 / 768.3 | 1,069.4 | 1,066.5 / 1,071.7 | **1.418x** |
| `wrapped` | 764.3 | 753.8 / 776.8 | 2,101.6 | 2,093.2 / 2,110.8 | **2.750x** |
| `wide` (descriptive) | 864.5 | 854.6 / 866.4 | 1,882.7 | 1,867.2 / 1,920.2 | 2.178x |

**`drain` -- eviction alone, nanoseconds per evicted display row.**

| class | arm A (today) | min / max | arm B (arena) | min / max | ratio |
| --- | ---: | ---: | ---: | ---: | ---: |
| `mix` | 113.8 | 112.6 / 114.6 | 228.2 | 226.7 / 231.3 | **2.005x** |
| `full` | 93.8 | 82.1 / 105.9 | 267.3 | 266.8 / 279.5 | **2.850x** |
| `stream` | 47.2 | 45.8 / 50.3 | 146.9 | 146.4 / 149.1 | **3.114x** |
| `wrapped` | 132.2 | 126.0 / 134.7 | 241.9 | 237.0 / 246.6 | **1.830x** |
| `wide` (descriptive) | 120.6 | 119.2 / 142.6 | 234.5 | 233.7 / 234.9 | 1.945x |

**`D4`'s three-way rule, applied once.** Reject is a candidate median above
**1.09x** arm A on *either* statistic on *any* verdict-bearing class. All eight
verdict-bearing cells are above it, the smallest by **42%** of arm A and the
largest by **218%**. **The verdict is reject.**

Stated in the units the bound was derived in, because that is what the number
means rather than what it is: `D4` converts `28/F20`'s measured 19.7%
write-path share and `agent-docs/terminal-performance.md`'s 95.7% drain share
into 18.85% of a `scrollback-stream` block, so a write path at `R` moves the
block by `18.85% x (R - 1)`. On `stream` -- the class the bound is derived from,
and `H3`'s own named falsifier -- `R = 1.418`, which predicts a **+7.9%** block
regression against a frozen `slower` line of **1.85%**. That is `H3`'s falsifier
firing by a factor of four, predicted rather than observed.

#### Observation 2 -- what the depths are, and what the arms retained

Read outside every timed region. Both arms hold the byte budget; they do not
hold the same number of display rows, which is why `D4` gate 1 compares them
over the shorter suffix rather than over the whole store.

| class | fed rows | arm A rows | arm B rows | arm B records | depth B/A | arm B charge (arena + index + side) |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `mix` | 36,006 | 15,049 | 16,681 | 9,538 | 1.108x | 16,640,624 + 135,168 + 0 |
| `full` | 24,004 | 10,810 | 11,632 | 5,799 | 1.076x | 16,706,920 + 67,584 + 0 |
| `stream` | 72,000 | 25,575 | 33,269 | 33,269 | **1.301x** | 16,236,024 + 540,672 + 0 |
| `wrapped` | 26,880 | 10,835 | 11,740 | 36 | 1.084x | 16,774,352 + 768 + 0 |
| `wide` | 36,000 | 13,901 | 15,465 | 7,565 | 1.113x | 16,707,896 + 67,584 + 0 |

The depth column is the one thing this entry confirms rather than rejects, and
it confirms `D2` Decision 1's 1.16x-1.32x prediction from the other side of the
budget: the arena retains **1.076x-1.301x** the display rows today's charge
admits, on the same input, with `stream`'s 1.301x landing where `F3`
Observation 4's 0.744x bytes-per-record ratio said it would. `PO11`'s "no
content class loses depth" holds on all five measured classes.

#### Observation 3 -- the attribution arm: the cost is the implementation, not wrap-at-read

Descriptive, outside `D4`'s rule, and the reason it exists is that a bare reject
would be read as evidence against the design. Three admitters over the same
rows, admission only (every store has room, so nothing evicts), `n=5` rounds.

| class | today's `pack`+append+accounting | `F3`'s prototype | landed `LogicalLineStore.admit` | prototype / today | landed / today | landed / prototype |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `mix` | 672.2 | 402.6 | 1,557.5 | 0.599x | 2.317x | **3.868x** |
| `full` | 716.5 | 458.3 | 1,976.7 | 0.640x | 2.759x | **4.313x** |
| `stream` | 519.3 | 308.9 | 930.0 | 0.595x | 1.791x | **3.011x** |
| `wrapped` | 724.5 | 452.0 | 1,912.0 | 0.624x | 2.639x | **4.230x** |
| `wide` | 803.1 | 417.8 | 1,621.2 | 0.520x | 2.019x | **3.880x** |

Two readings, and the second is what the human needs.

**`F3` reproduces.** Its prototype re-measured at 0.52x-0.64x of today's
admission in this session, against the 0.62x-0.69x `F3` published -- so the
campaign's admission result is not an artifact of `F3`'s session, and the
open-line rule still admits a scrolled-off row for less than `pack` does.

**The landed store costs 3.0x-4.3x its own prototype**, and the cost tracks
stored cells almost exactly: 930.0 ns at 60 stored cells (`stream`) against
1,976.7 ns at 179 (`full`), a marginal slope of **~1.1 ns per stored cell byte**.
That is the signature of the arena's byte access rather than of anything the
design prescribes: `LogicalLineStore` reads and writes its arena one `UInt8` at
a time through checked `[UInt8]` subscripts (`setWord`/`word`, eight subscript
writes per cell, plus one per-row `[GridCell]` array from `admissionCells` and a
`census` recomputation per `admit` and per eviction step), where `F3`'s
prototype wrote the identical eight bytes inside one
`withUnsafeMutableBufferPointer`. **This entry does not fix that**: `D4` froze
its rule so the landed store would be priced as it stands, and optimising first
would be tuning to the number the rule exists to prevent being tuned to. It is
reported as the attribution and left to the human.

#### Observation 4 -- the `AR6` residency reading: four states, and a reject on the second trigger

One process per reading. `phys_footprint` sampled either side of the store's
construction and fill with the allocator settled (`malloc_zone_pressure_relief`)
before each sample, cross-checked against `vmmap --summary`'s TOTAL DIRTY delta,
which agreed to within 0.2 MiB on every one of the twelve readings. Census
capacity and bytes in use are reported separately (`DD11`). `n=1` process per
row; the two `cycled` rows that carry the verdict were each re-run three times
(the repeatability reading is under Competing interpretations).

| store | class | state | resident (footprint delta) | capacity | bytes in use | index | side tables | charged | retained rows |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| arena | plain | empty | **16.281 MiB** | 16.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0 |
| arena | plain | partial | 16.266 | 16.000 | 7.743 | 0.258 | 0.000 | 8.000 | 19,516 |
| arena | plain | saturated | 16.312 | 16.000 | 15.484 | 0.516 | 0.000 | 16.000 | 39,029 |
| arena | plain | cycled | 16.969 | 16.000 | 15.484 | 0.516 | 0.000 | 15.999 | 39,027 |
| arena | mixed | cycled | **20.375** | 16.000 | 13.553 | 0.516 | 1.931 | 16.000 | 50,150 |
| arena | blank | cycled | 31.609 | 16.000 | 7.750 | 8.250 | 0.000 | 16.000 | 1,015,806 |
| today | plain | empty | 0.219 | n/a | 0.000 | -- | -- | 0.000 | 0 |
| today | plain | partial | 8.125 | n/a | 8.000 | -- | -- | 8.000 | 18,079 |
| today | plain | saturated | 16.297 | n/a | 16.000 | -- | -- | 16.000 | 36,157 |
| today | plain | cycled | 18.188 | n/a | 16.000 | -- | -- | 16.000 | 36,157 |
| today | mixed | cycled | 18.219 | n/a | 16.000 | -- | -- | 16.000 | 43,034 |
| today | blank | cycled | 31.344 | n/a | 16.000 | -- | -- | 16.000 | 262,144 |

`cycled` means at least two full arenas' worth of display rows evicted: 78,058
against 39,027 retained on `plain`, 100,304 against 50,150 on `mixed`, 2,031,614
against 1,015,806 on `blank`. The census identity (`charged <= budget`) held in
the saturated and cycled states on every reading, so no reading is voided for
accounting.

**`D4`'s residency rule, applied once, on the cycled state:**

| class | arena resident / 16 MiB charged bound | arena / today, same fed input | confirm <= 1.10x of the bound | reject: >= 1.50x of the bound, or > 1.10x today's |
| --- | ---: | ---: | --- | --- |
| `plain` | 1.061x | **0.933x** | pass | -- |
| `mixed` | **1.273x** | **1.118x** | fail | **second trigger fires** |
| `blank` | 1.976x | 1.008x | (no trigger, by `D4`) | (no trigger, by `D4`) |

Confirm required every measured class at or under 1.10x of the charged bound;
`mixed` is 1.273x, so confirm is out. The first reject trigger (>= 1.50x of the
bound) does **not** fire on either triggering class. The **second** does:
`mixed`'s arena is **1.118x** today's resident for the same fed input in the
same session, over the 1.10x line `D4` derived as "a user does not pay more RAM
for the same program output". **The residency verdict is reject, and the remedy
`D4` names ships**: the arena's capacity is sized *below* the budget by the
measured index and side-table share.

Three things the table says that `D2` Decision 1 did not predict, and two of
them are worse than it predicted.

**`DD12` is refuted outright.** An *empty* arena pane is **16.281 MiB**
resident, against today's 0.219 MiB -- `vmmap` puts a single 16.0 MiB
MALLOC_LARGE region at 16.0 MiB VIRTUAL, 16.0 MiB RESIDENT and 16.0 MiB DIRTY
the instant the store is constructed. `Array(repeating: 0, count:)` initialises
its whole buffer, so the reservation is dirty from birth. `D2` Decision 1's
first-touch paragraph does not hold "until the cursor cycles"; it does not hold
at all, at any state -- `partial` is 16.266 MiB against today's 8.125 MiB for
the same half-full charge. The idle-pane reading `DD12` said "costs nothing" is
the **largest** single number in the `plain` column.

**The remedy's depth cost is much larger than `D4` derived it.** `D4` computed
the index share as 1.61% of the budget on its worst measured class and said the
capacity reduction "costs depth by at most that same share". The measured
index-plus-side-table share at the cycled state is **3.23%** on `plain`
(0.516 MiB), **15.29%** on `mixed` (0.516 index + 1.931 side tables) and
**51.56%** on `blank` (8.250 MiB of index). `D4`'s figure was index-only
arithmetic over `D2`'s depth table; the side tables it left as an unmeasured
constant are, on `mixed`, **3.7x the index**.

**The spill table is charged at less than it costs**, which is `15/F2`'s error
class recurring inside the new store. On `mixed` the census charges 1.931 MiB of
side tables, while the arena's total resident excess over its own 16 MiB
reservation is 4.375 MiB. The gap is `spillsBySequence` -- a `Dictionary` of
~50,000 entries each holding an array of arrays -- whose real allocator cost the
charge model describes rather than measures. That is exactly what `I2` promises
not to do, and it is the mechanism behind the one cell that rejects.

#### Observation 5 -- the gates, including the two `D4` could not have written literally

1. **Per-arm fidelity, then cross-arm equivalence.** Each arm's retained content
   was read back display row by display row and checksummed over every scalar,
   style id, kind and soft-wrap flag against an expectation computed from the
   fed stream's own suffix, touching neither store: **both arms matched on all
   five classes**. Over the display rows both retain (10,810 to 25,575 depending
   on class) the two checksums were **identical on all five**. The arena
   therefore re-derives at read the `.spacerHead` cells it refused to store --
   `wide` alone carries 3,067 of them -- and reproduces today's rows cell for
   cell.
2. **Head-stamping fidelity.** On every class, arm A's `isHistoryHeadTruncated`
   and the arena's head-record `startsMidLine` each equalled "the row above my
   first retained one was soft-wrapped": `false/false` on `mix` and `stream`,
   `true/true` on `full` and `wrapped`, and on `wide` each matched its own
   (different-depth) predecessor row.
3. **Steady-state check.** In `steady`, evicted display rows matched admitted
   within **0.22%** on every arm and class, against the 1% tolerance. In `drain`
   both arms evicted exactly 2,000 -- satisfied by construction under `DD29`
   rather than by tolerance, which is **reported rather than dropped**.
4. **Non-elision.** Every round's product (arm A: retained rows, charged bytes,
   stored cells, evicted rows; arm B: records, arena bytes in use, grand
   display-row total, evicted rows) matched the value computed outside the timed
   region on every round of every cell, and none was an empty store's.
   Independently, the arena's grand display-row total matched
   `independentDisplayRowRecount()` -- a count taken straight off the arena
   ignoring every cached total -- on all five classes.
5. **A/A resolution.** -1.16%, +0.87%, -0.63%, -0.68%, -0.08%, -0.24%, -0.75%,
   +0.33%, +0.36%, -0.20% on the quoted invocation, all inside the 5% ceiling.
   Ten other invocations exceeded it on (`full`, `drain`) and were voided; see
   the void note above.
6. **Host conditions.** AC power, low-power mode off, load 1.52 before and 1.34
   after on the quoted eviction invocation, 1.3-1.5 across the residency ones.
7. **Complexity fidelity -- the gate this rule owes its own frozen reading, and
   it passes.** Draining 20 whole `wrapped` records one display row at a time
   (335 timed steps each, 6,680 samples) put the per-step median at **250.0 ns
   in every quartile**: Q1 250.0 (n=1,675), Q2 250.0 (n=1,675), Q3 250.0
   (n=1,675), Q4 250.0 (n=1,655), **Q4/Q1 = 1.000x** against a 1.20x ceiling. A
   step that re-folded the record from its start would have separated the
   quartiles by ~7x, or 250 ns against ~1,750 ns. The step that drops the record
   -- the last of each drain, reported beside the quartiles rather than inside
   them -- is *cheaper* at 125.0 ns (n=20). So `D2` Decision 2's per-step
   complexity is what the landed code does, and `AR1`'s corrected reading is
   confirmed: **one display row per trim step, one pass per record across a full
   drain.** The medians are quantised by the 41.7 ns clock, which is stated
   because it is why they are equal to the tenth; the gate discriminates a 7x
   shape regardless.
8. **Coverage.** Every aggregate is printed with its round count and its
   per-round sample count; every residency row carries `n=1 process`; and "not
   measured" is distinguished from zero throughout.

**The two substitutions, both written into the probe file's header before it was
first run** and both recorded as deferred decisions below: `drain` times a fixed
2,000-step eviction loop rather than one budget-driven enforcement call (`DD29`
-- under `I2` the arena's capacity *is* the budget, so admission cannot run with
enforcement suppressed), and arm C is the arena *design* reproduced in the probe
file rather than the landed store (`DD30` -- `LogicalLineStore` exposes no
whole-record eviction, and adding one to production for a descriptive arm is not
licensed).

**The instrument bias that was found and removed before any number was read.**
The first two invocations copied one saturated baseline per round. A
`PackedRetainedRow` owns two Swift arrays, so a copied baseline keeps a
reference to every retained row's blob and arm A's evictions decrement instead
of calling `free` -- a real per-eviction cost silently deleted from the
**baseline only**, since the arena has no per-row allocation to free. Rebuilding
each arm's saturated store per round moved arm A's `full` drain from 36.5 to
~85 ns and left arm B unchanged, and every number quoted here is post-fix. It is
recorded because it ran in the candidate's disfavour and would otherwise have
made this reject look worse than it is.

#### Observation 6 -- arm C, descriptive: granularity is not where the cost is

`D4` runs arm C for exactly one purpose -- if arm B rejects, only arm C can say
whether the cost is the *granularity* or the *arena*. Head-granular against
whole-record on one arena, `n=5` rounds, 2,000 display rows per round.

| class | rows/record | head-granular | whole-record | head/whole | rows overshot |
| --- | ---: | ---: | ---: | ---: | ---: |
| `mix` | 1.74 | 96.1 | 5.3 | 18.3x | 1 |
| `full` | 2.00 | 134.0 | 4.4 | 30.3x | 0 |
| `stream` | 1.00 | 52.6 | 9.0 | 5.9x | 0 |
| `wrapped` | 336.00 | 133.7 | ~0.0 | >1,000x | **16** |
| `wide` | 2.04 | 105.6 | 138.6 | 0.76x | 0 |

Mechanically, `D4`'s fallback condition 2 fires: head-granular exceeds
whole-record by more than 1.09x on four of five classes. **Read alone that is
misleading, and the fidelity arm is why.** The same reproduction's head-granular
drain runs at **0.391x** (57.2 against 146.2 ns on `stream`) and **0.619x**
(150.6 against 243.4 ns on `wrapped`) of the landed store's -- so most of arm
B's excess over arm A is *not* granularity, it is the same per-byte arena access
Observation 3 attributes admission's excess to. And where the reproduction's
head-granular eviction can be compared to today's directly it is already at or
near parity: 52.6 ns against arm A's 47.2 on `stream`, 133.7 against 132.2 on
`wrapped`, 105.6 against 120.6 on `wide`.

So the honest statement of arm C is: **whole-record eviction is cheaper per
display row because one step drops many rows, which is its definition and not a
discovery**; the `wrapped` row prices that at 16 display rows dropped past the
2,000 asked for, which is `F6` `HR5`'s hazard measured -- at 179 columns and 336
rows per record a whole-record step moves four anchors and the scrollbar by up
to a third of a screenful more than today's does. `D4`'s bar for taking the
`AR1` fallback has three conditions and the third is not satisfiable by any
number here: **a human must accept a user-visible behavior change** that `D2`
Decision 2 closed rather than accepted and that `I4` and `PO5` currently forbid.
On this evidence, taking it would buy a regression the design already rejected
in order to fix a cost that is not granularity's.

- Observation: on a store saturated at the 16 MiB production budget, the landed
  arena's whole write path costs **1.418x-3.177x** today's per admitted display
  row and its eviction alone **1.830x-3.114x** today's per evicted display row,
  across all four verdict-bearing content classes; and an arena pane is
  **16.281 MiB resident when empty**, and **20.375 MiB when cycled on
  `scrollback-mixed`** against today's 18.219 MiB for the same fed input.
- Inference: **reject on both of `D4`'s rules**, and the plan gains both named
  conditions `D4` states. For eviction: the store does not land until either the
  implementation clears 1.09x under this same rule, or the paired ladder comes
  back not-`slower` on `terminal-feed` **and** `scrollback-stream` against a
  real implementation -- which is `H3`'s own falsifier and outranks a
  microbenchmark prediction. For residency: the arena's capacity is sized below
  the budget by the measured index and side-table share, whose measured value is
  **3.23% on `plain` and 15.29% on `mixed`**, not the 1.61% `D4` derived, and
  `PO3`'s census is what proves the new capacity holds. What neither verdict
  touches is the design: gate 7 confirms `D2` Decision 2's per-step complexity at
  1.000x, gate 1 confirms `I1`/`I6` cell for cell on five classes, the depth
  table confirms `PO11` on five classes, and the attribution arm puts the whole
  eviction reject in the landed store's byte access rather than in wrap-at-read.
- Competing interpretations:
  - *Wrap-at-read admission is intrinsically expensive.* Refuted by Observation
    3 in the same session on the same rows: `F3`'s prototype of the same rule
    admits at 0.52x-0.64x of today's cost while the landed store costs
    1.79x-2.76x.
  - *The head-trim's fold walk is the new cost `AR1` warned about.* Refuted by
    gate 7 (flat across a record's drain, 1.000x) and by arm C's fidelity arm
    (the reproduction's head-granular drain is at or near parity with today's on
    three classes). The fold walk is real and it is not what rejects.
  - *The baseline is flattered because it never frees.* True of the first two
    invocations and fixed before any quoted number; see Observation 5's bias
    note, which moved arm A's `full` drain 2.3x in the baseline's disfavour.
  - *The residency reject is measurement noise at a 1.118x line.* Refuted by
    repetition: three further runs of each `mixed`/`cycled` reading put the arena
    at 20.297-20.375 MiB and today's at 18.188-18.297 MiB, a ratio of
    **1.110x-1.118x**, never under the trigger.
  - *An arena that reserves 16 MiB obviously costs 16 MiB, so `AR6` discovered
    nothing.* Half true, and the half that matters is the other one: `D2`
    Decision 1 predicted first-touch would keep an idle pane cheap and the
    overshoot would appear only after cycling. Measured, an empty pane is already
    at 16.281 MiB and a cycled `plain` pane is *below* today's, at 0.933x. The
    gate found the prediction wrong in **both** directions.
- Uncertainty:
  - **This is a microbenchmark and predicts a ladder verdict; it does not
    produce one.** `D4` says so, and `H3`'s falsifier against a real
    implementation outranks it in the reject branch by `D4`'s own wording.
  - **The instrument calls enforcement once per admitted row** while production
    amortizes it over a batch of scrolled-off rows. Both arms are treated
    identically so the ratio is fair; the absolute nanoseconds carry a loop
    prologue per row and are upper bounds.
  - **Gate 5's ceiling is marginal on one cell.** (`full`, `drain`) exceeded 5%
    in 10 of 22 invocations. The verdict is nowhere near that margin -- the
    smallest verdict-bearing effect is +42% -- but a future rule that needs to
    resolve a 10% effect on that cell needs a longer drain than `D4` froze.
  - **Arm C is a reproduction** (`DD30`), and its fidelity arm measures it at
    0.391x-0.619x of the landed store, so its granularity ratio brackets the real
    one rather than equalling it.
  - **The residency source pool is 300 distinct lines, cycled.** Byte shapes are
    the payloads', but a real session's content novelty -- particularly its style
    and spill diversity -- is not reproduced, and `mixed`'s side-table term is the
    one the verdict turns on.
  - **One machine, one session**, as with every probe in this doc.
- Deferred decisions, continuing `DD28`'s numbering; each took the obvious simple
  choice at measurement time rather than blocking, and the first two were written
  into the probe file's header before it was first run:
  - **DD29 -- the `drain` statistic times a fixed 2,000-step eviction loop, not
    one budget-driven enforcement call.** `D4` asks for 2,000 rows admitted "with
    enforcement suppressed" and then one call that drains back to the budget.
    Under `I2` the arena's capacity *is* the budget and is a `let`, so admission
    cannot run with enforcement suppressed without changing the arena's defining
    geometry -- which would measure a different store. Both arms therefore run
    the same fixed-step loop, which is the body of `evictToBudget` /
    `enforceScrollbackBudget` with the loop condition supplied by the harness,
    and each arm's once-per-call epilogue runs once. Gate 3's drain half becomes
    satisfied by construction and is reported as such. A human's to revisit if
    the arena ever gains a budget separate from its capacity -- which the
    residency reject's remedy is about to give it.
  - **DD30 -- arm C is the arena design reproduced in the probe file, run in both
    granularities, with the reproduction measured against the landed store.**
    `D4` asks for whole-record eviction "on the same arena"; `LogicalLineStore`
    exposes no whole-record eviction, and adding one to production for a
    descriptive arm is not licensed by `D1`'s scoping. The reproduction uses the
    real `LogicalLineRecord` header and the real `LogicalLineFold`, and is linear
    rather than a ring because a drain writes nothing at the tail. The
    substitution's size is measured rather than assumed (the fidelity arm), which
    is what keeps the granularity ratio readable.
  - **DD31 -- the residency reading reproduces `TerminalMemoryProbe`'s instrument
    inside the test process instead of running the probe binary.** `D4` names
    `just terminal-memory-probe --vmmap`, and that binary **cannot see the
    arena**: `Terminal.LogicalLineStore` is internal to `TerminalCore`, so only a
    `@testable` caller can construct one, and making the store public for a
    measurement would be a production API change `D1` does not license. The
    mechanism is the probe's, verbatim -- `task_vm_info.phys_footprint`,
    `malloc_zone_statistics`, and `vmmap --summary` dumped rather than parsed --
    and only the caller moved. Today's store is measured through the same file's
    `enforceScrollbackBudget` reproduction rather than through a whole
    `Terminal`, so both sides measure history alone and neither carries a live
    screen. Reopen if the store is ever made public for another reason, in which
    case the binary should own this.
  - **DD32 -- resident is the settled `phys_footprint` delta, cross-checked
    against `vmmap`'s TOTAL DIRTY delta, over a 300-line source pool.** Two
    residency invocations were voided before this shape was settled and are
    recorded here rather than hidden: with a 12,000-line pool the process carried
    ~27 MiB of dirty pages before the store existed, the allocator then handed
    the arena pages it already owned, and four of the twelve readings came out
    *negative*. `malloc_zone_pressure_relief` before each sample, plus a pool
    small enough to leave the baseline near an empty process, fixed both, and the
    two instruments then agreed to within 0.2 MiB on every reading -- which is
    the cross-check that makes either quotable.
- Next action: **the human decides the disposition of two rejects, and this doc
  records no further verdict until they do.** The eviction reject's named
  condition and the residency reject's remedy both land on the plan's slice 5,
  which is where the store is wired: the remedy (capacity below budget) is a
  change to `LogicalLineStore`'s construction plus the census proof `PO3` already
  owes, and the eviction condition is either an optimization pass over the
  arena's byte access -- which Observation 3 sizes at 3.0x-4.3x of headroom
  against the store's own prototype -- or a decision to read `H3`'s falsifier on
  the paired ladder instead. Three things this entry hands forward regardless:
  the arena's byte access costs **~1.1 ns per stored cell byte** at the margin as
  written, which is the constant any optimization is measured against; `DD12` is
  **refuted** and an idle arena pane costs 16.281 MiB, which doc 28's `D11`
  amendment and any future multi-pane question must be read against; and the
  spill table's charge under-describes its allocation, which is `15/F2`'s error
  class inside `I2` and is the mechanism behind the residency reject.

### F10 -- the optimized store re-priced under `D4`'s frozen rule: eviction **neutral** at 0.85x-1.02x today's, residency **narrow confirm** at 0.85x-1.00x today's resident, and one real defect found by gate 1

- Status: complete. `D4`'s rule was **re-run unchanged** -- same probe file, same
  arms, same five stimulus classes, same eight gates, same 1.09x / 1.00x
  thresholds, same four residency states and 1.10x / 1.50x bounds -- against the
  store after `F8`'s attributed headroom was spent and `D4`'s residency remedy
  shipped. **Both of `F8`'s rejects are cleared.** The eviction rule reads
  **neutral** (every verdict-bearing cell at or under 1.09x on both statistics;
  two cells above 1.00x by more than the A/A resolution, so not `confirm`) and
  the `AR6` residency rule reads **narrow confirm** (`mixed` at 1.140x of the
  charged bound, inside the 1.50x line, and no class above 1.10x of today's
  resident for the same fed input). What neither of those says is that the
  campaign is finished: `D4`'s own wording still holds that a microbenchmark
  **predicts** a ladder verdict and does not produce one, and landing is still
  the paired ladder's.
- **The re-run also found a correctness defect, and that is the part a human
  should read first.** `D4` gate 1 failed on `wide` in the invocation taken
  against the optimized store: one retained display row in 14,486 read back 178
  cells where today's store holds 179 with a trailing `.spacerHead`. The defect
  is **slice 3's, not the optimization's** -- the fold re-derives a dropped
  spacer from the wide head it defers, and a forced split at the arena's physical
  end (`DD20`) moves that head into the *follower* record where the fold could
  not see it, so the column was lost permanently inside retained history. What
  the optimization changed is the arena's capacity, which moved where the ring
  wraps and so exposed a case `F8`'s own run happened to miss. Fixed at `5cf61e0`
  by the reader doing what `DD6` says readers do (rejoin split pieces by
  adjacency), pinned by its own test, and every number below is measured after
  the fix.
- Date and investigator: 2026-08-04, Claude (agent).
- Commit and worktree state: measured at `5cf61e0`, which is `c8238ca`'s store
  plus `af4f4b1` (the `DD25` fill amendment), `2a0b3a7` (the write-path
  optimization and `D4`'s residency remedy) and `5cf61e0` (the seam-spacer fix).
  **`lib/TerminalCore/Tests/TerminalCoreTests/TerminalLogicalLineEvictionProbe.swift`
  is byte-for-byte unedited**, as are `F1`'s, `F2`'s, `F3`'s, `F7`'s and `F9`'s
  probe files; the store keeps `init(capacityBytes:)` as an alias precisely so
  the frozen instrument still compiles and still constructs the store with the
  production budget. The two untracked paths present throughout this doc's work
  are still present and still in no build: `TODO.md` and
  `docs/scratch/2026-08-04-scroll-sample-breakdown.md`.
- Commands, inputs, or reproduction: `F8`'s, verbatim.

      DANTERM_LOGICAL_LINE_PROBE=1 swift test -c release --package-path lib/TerminalCore \
        --filter TerminalLogicalLineEvictionProbe

      DANTERM_LOGICAL_LINE_PROBE=1 DANTERM_RESIDENCY_CASE=arena/plain/cycled \
        swift test -c release --package-path lib/TerminalCore --filter residencyReading

  the second once per `<store>/<class>/<state>` triple, which is `D4`'s
  one-process-per-state requirement. Conditions: AC power, low-power mode off,
  one-minute load average **1.75 before and 1.58 after** on the quoted eviction
  invocation and 1.3-1.8 across the twelve residency ones, all under the 2.5
  gate. Release, headless, 179x66, the 16,777,216-byte production budget, ABBA
  interleaving at 5 measured rounds plus 2 warmup, median over rounds with min,
  max and `n` beside every aggregate.
- Artifacts: none durable. Every number below is stdout from the commands above.
- **Invocations voided, and how the optimization was developed, stated because
  the two are entangled here in a way they were not in `F8`.** Five gated
  invocations of the verdict-bearing arms were taken. **Four are void and none of
  them is quoted**: three ran against intermediate code states that no longer
  exist (taken while the write path was being changed -- the rule is frozen, the
  code was not, and using the probe as the optimization's instrument is what
  "optimize, then re-price" means), and the fourth ran against the landed
  optimization and is the one gate 1 failed on `wide`, which is how the defect
  above was found. Two of the four also tripped gate 5's 5% A/A ceiling, on
  (`full`, `drain`) at +8.91% and on (`wide`, `drain`) at +9.49% -- the same
  drain cells `F8` recorded as the instrument's floor. The fifth invocation, at
  `5cf61e0`, cleared every readable gate and is the one quoted; its ratios sit
  inside the spread the four voided ones showed, so **nothing was selected on the
  numbers**.

#### Observation 1 -- the two verdict-bearing statistics, and the rule applied once

Both arms filled to their own bound from the same cycled fed stream before
anything was timed, and each rebuilt per round. `n=5` rounds per cell, 5,000
admissions per `steady` round and 2,000 eviction steps per `drain` round. The
`F8` column is that finding's ratio for the same cell, quoted so the movement is
visible rather than reconstructed.

**`steady` -- the whole write path, nanoseconds per admitted display row.**

| class | arm A (today) | min / max | arm B (arena) | min / max | ratio | `F8` was |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `mix` | 740.3 | 734.9 / 764.0 | 644.2 | 640.0 / 670.8 | **0.870x** | 2.427x |
| `full` | 717.0 | 698.6 / 725.1 | 733.6 | 730.6 / 753.5 | **1.023x** | 3.177x |
| `stream` | 536.9 | 535.5 / 540.8 | 474.9 | 466.8 / 487.3 | **0.884x** | 1.418x |
| `wrapped` | 765.2 | 744.9 / 775.7 | 655.2 | 653.2 / 661.4 | **0.856x** | 2.750x |
| `wide` (descriptive) | 862.3 | 856.2 / 873.2 | 692.7 | 692.0 / 696.8 | 0.803x | 2.178x |

**`drain` -- eviction alone, nanoseconds per evicted display row.**

| class | arm A (today) | min / max | arm B (arena) | min / max | ratio | `F8` was |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `mix` | 114.6 | 114.3 / 120.9 | 63.2 | 53.1 / 67.9 | **0.551x** | 2.005x |
| `full` | 91.2 | 79.5 / 97.0 | 67.6 | 66.9 / 68.0 | **0.741x** | 2.850x |
| `stream` | 47.2 | 47.1 / 47.5 | 48.2 | 47.9 / 49.6 | **1.022x** | 3.114x |
| `wrapped` | 128.7 | 125.9 / 132.8 | 19.4 | 19.4 / 19.7 | **0.151x** | 1.830x |
| `wide` (descriptive) | 82.5 | 81.6 / 102.6 | 59.8 | 59.2 / 60.6 | 0.725x | 1.945x |

**`D4`'s three-way rule, applied once.** Reject is a candidate median above
**1.09x** arm A on either statistic on any verdict-bearing class: **no cell
reaches it**, and the worst is `full`'s `steady` at 1.023x. Confirm requires
**<= 1.00x on both statistics on every** verdict-bearing class, or a difference
smaller than gate 5's resolution: two cells fail that -- `full`/`steady` at
+2.31% against an A/A resolution of +0.62%, and `stream`/`drain` at +2.23%
against -0.26% -- so both are real effects above the floor and confirm is out.
Neutral is every verdict-bearing class under 1.09x on both statistics with at
least one above 1.00x by more than the A/A resolution. **The verdict is
neutral**, and `D4` says what that means: "a recorded cost, not a failure".

Stated in the units the bound was derived in, because that is what the number
means. `D4` converts `28/F20`'s 19.7% write-path share and
`agent-docs/terminal-performance.md`'s 95.7% drain share into 18.85% of a
`scrollback-stream` block, so a write path at `R` moves the block by
`18.85% x (R - 1)`. On `stream` -- the class the bound is derived from and
`H3`'s own named falsifier -- `R = 0.884` on the verdict-bearing primary, which
predicts a **-2.2%** block *improvement* against a frozen `slower` line of
+1.85%. `F8`'s reading of the same cell predicted +7.9%.

**The recorded cost the neutral verdict carries forward**, stated so the ladder
re-reads it rather than rediscovering it: `full`'s write path is +2.3% and
`stream`'s eviction alone is +2.2%, both above the A/A floor. Under the same
conversion, +2.3% of the write path is +0.43% of a block -- inside every frozen
directional threshold in
`scripts/terminal-benchmark-validation.py#DECISION_RULES`, and four times inside
`scrollback-stream`'s own 1.85%.

#### Observation 2 -- depth, and what `DD36`'s reserve cost

Read outside every timed region. The reserve is 1/16 of the budget, so the arena
now holds 15,728,640 bytes against today's 16,777,216, and `PO11` is the
constraint that sized it.

| class | fed rows | arm A rows | arm B rows | arm B records | depth B/A | `F8` was | arm B charge (arena + index + side) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `mix` | 36,006 | 15,049 | 15,628 | 8,932 | **1.038x** | 1.108x | 15,591,008 + 135,168 + 0 |
| `full` | 24,004 | 10,810 | 10,902 | 5,439 | **1.009x** | 1.076x | 15,658,312 + 67,584 + 0 |
| `stream` | 66,000 | 25,575 | 31,674 | 31,674 | **1.238x** | 1.301x | 15,457,800 + 270,336 + 0 |
| `wrapped` | 26,880 | 10,835 | 11,006 | 34 | **1.016x** | 1.084x | 15,725,776 + 768 + 0 |
| `wide` | 30,000 | 13,901 | 14,486 | 7,080 | **1.042x** | 1.113x | 15,658,536 + 67,584 + 0 |

`PO11` still holds on all five classes -- no class retains less than today's
engine -- and the margin on `full` is now **0.9%** where it was 7.6%. That is
`DD36`'s cost paid in the open: a 6.25% reserve against a 7.6% margin leaves
0.9%, which is why the reserve is not larger. It is also the number that says a
*larger* reserve cannot be taken without either a `PO11` amendment or a per-class
reserve the store cannot compute at construction.

#### Observation 3 -- the attribution arm: what the optimization actually moved

Descriptive, outside `D4`'s rule, and re-run because `F8` used it to attribute
the reject. Three admitters over the same rows, admission only, `n=5` rounds.

| class | today's `pack`+append+accounting | `F3`'s prototype | landed `admit` | landed / today | `F8` was | landed / prototype | `F8` was |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `mix` | 671.9 | 402.6 | 592.3 | **0.882x** | 2.317x | **1.471x** | 3.868x |
| `full` | 726.3 | 458.8 | 666.0 | **0.917x** | 2.759x | **1.452x** | 4.313x |
| `stream` | 523.6 | 312.9 | 456.1 | **0.871x** | 1.791x | **1.458x** | 3.011x |
| `wrapped` | 727.6 | 452.5 | 633.3 | **0.870x** | 2.639x | **1.400x** | 4.230x |
| `wide` | 807.1 | 423.5 | 625.6 | **0.775x** | 2.019x | **1.477x** | 3.880x |

`F3`'s prototype reproduces a third time (0.53x-0.63x of today's admission,
against 0.52x-0.64x in `F8`'s session and 0.62x-0.69x published), so the control
is stable. The landed store went from **1.79x-2.76x** of today's admission to
**0.775x-0.917x**, and from **3.0x-4.3x** its own prototype to **1.40x-1.48x**.
The residual 1.4x-1.5x is what the store does that the prototype does not: a
ring with a wrap seam, a two-level index maintained per record, side tables, the
charge, and the forced-split checks. It is reported rather than spent -- there is
no rule that asks for it, and `D4`'s reject line is 1.09x against *today*, not
against the prototype.

#### Observation 4 -- the `AR6` residency reading: four states, and the reject cleared

One process per reading, `phys_footprint` sampled either side of the store's
construction and fill with the allocator settled, cross-checked against `vmmap`'s
TOTAL DIRTY delta. Census capacity and bytes in use reported separately
(`DD11`). `n=1` process per row.

| store | class | state | resident (footprint delta) | `F8` was | capacity | bytes in use | index | side tables | charged | retained rows |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| arena | plain | empty | **15.266 MiB** | 16.281 | 15.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0 |
| arena | plain | partial | 15.250 | 16.266 | 15.000 | 7.743 | 0.258 | 0.000 | 8.000 | 19,516 |
| arena | plain | saturated | 15.281 | 16.312 | 15.000 | 14.484 | 0.516 | 0.000 | 14.999 | 36,508 |
| arena | plain | cycled | 15.359 | 16.969 | 15.000 | 14.484 | 0.516 | 0.000 | 14.999 | 36,507 |
| arena | mixed | cycled | **18.234** | 20.375 | 15.000 | 12.457 | 0.516 | 2.027 | 14.999 | 46,095 |
| arena | blank | cycled | 30.453 | 31.609 | 15.000 | 6.750 | 8.250 | 0.000 | 15.000 | 884,734 |
| today | plain | empty | 0.219 | 0.219 | n/a | 0.000 | -- | -- | 0.000 | 0 |
| today | plain | partial | 8.078 | 8.125 | n/a | 8.000 | -- | -- | 8.000 | 18,079 |
| today | plain | saturated | 16.266 | 16.297 | n/a | 16.000 | -- | -- | 16.000 | 36,157 |
| today | plain | cycled | 18.094 | 18.188 | n/a | 16.000 | -- | -- | 16.000 | 36,157 |
| today | mixed | cycled | 18.281 | 18.219 | n/a | 16.000 | -- | -- | 16.000 | 43,034 |
| today | blank | cycled | 31.375 | 31.344 | n/a | 16.000 | -- | -- | 16.000 | 262,144 |

`cycled` means at least two full arenas' worth of display rows evicted: 73,016
against 36,507 retained on `plain`, 92,193 against 46,095 on `mixed`, 1,769,470
against 884,734 on `blank`. The census identity (`charged <= capacity`) held in
the saturated and cycled states on every reading, so no reading is voided for
accounting.

**`D4`'s residency rule, applied once, on the cycled state:**

| class | arena resident / 16 MiB charged bound | arena / today, same fed input | `F8` was | confirm <= 1.10x of the bound | reject: >= 1.50x of the bound, or > 1.10x today's |
| --- | ---: | ---: | ---: | --- | --- |
| `plain` | 0.960x | **0.849x** | 0.933x | pass | -- |
| `mixed` | **1.140x** | **0.997x** | 1.118x | fail | neither trigger fires |
| `blank` | 1.903x | 0.971x | 1.008x | (no trigger, by `D4`) | (no trigger, by `D4`) |

Confirm required every measured class at or under 1.10x of the charged bound and
`mixed` is 1.140x, so confirm is out. Neither reject trigger fires: no class
reaches 1.50x of the bound (`blank` does, and `D4` gives it no trigger), and the
second trigger -- the one `F8` fired at 1.118x -- is now **0.997x** on `mixed`
and 0.849x on `plain`. **The residency verdict is narrow confirm**, which `D4`
defines as "no remedy ships, and the reading is recorded as a condition on pane
count". The remedy already shipped; what this records is the condition:
**a cycled `scrollback-mixed` arena pane costs 18.234 MiB resident against a
16 MiB budget, which is 1.140x, and that is the number a multi-pane question is
read against.**

Three readings the table carries that the rule does not:

**`DD12` stays refuted.** An *empty* arena pane is **15.266 MiB** resident
against today's 0.219 MiB. The reserve moved that number by exactly the reserve
and nothing else: `Array(repeating:)` still initialises the whole buffer, so the
reservation is still dirty from construction rather than on first touch, at every
state. Nothing here rehabilitates the first-touch reading.

**The charge now describes the allocation to within 0.69 MiB, where it was short
by 1.93 MiB.** On `mixed` the arena's resident excess over its own 15 MiB
reservation is 3.234 MiB against 2.543 MiB of charged metadata (0.516 index +
2.027 side tables). `DD37` closed the gap the spill dictionary's own storage
left; what remains is **malloc size-class rounding on ~46,000 small payload
allocations**, which a capacity-stride charge cannot see and which this entry
records as the residual rather than modelling.

**Depth in the residency payloads moved with the reserve, as `DD36` said it
would**: `plain` 36,507 retained rows against today's 36,157 (1.010x, was
1.079x), `mixed` 46,095 against 43,034 (1.071x, was 1.165x), `blank` 884,734
against 262,144 (3.375x, was 3.875x). Every class still retains at least as much
as today's engine.

#### Observation 5 -- the gates, including the one that can no longer be read

1. **Per-arm fidelity, then cross-arm equivalence.** Both arms matched their own
   fed-suffix expectation on **all five classes**, and over the display rows both
   retain (10,810 to 25,575) the two checksums were **identical on all five**.
   This is the gate that failed on `wide` in the previous invocation and found
   the seam-spacer defect; it passes after the fix, with the arena re-deriving
   every `.spacerHead` it refuses to store, including the one at a forced split.
2. **Head-stamping fidelity.** On every class each arm's first retained display
   row read as a mid-line continuation exactly when the row above it was
   soft-wrapped: `false/false` on `mix` and `stream`, `true/true` on `wrapped`
   and `wide`, and on `full` each matched its own (different-depth) predecessor.
3. **Steady-state check.** In `steady`, evicted display rows matched admitted
   within **0.28%** on every arm and class against a 1% tolerance. In `drain`
   both arms evicted exactly 2,000, satisfied by construction under `DD29`.
4. **Non-elision.** Every round's product matched the value computed outside the
   timed region on every round of every cell, and the arena's grand display-row
   total matched `independentDisplayRowRecount()` on all five classes.
5. **A/A resolution.** +0.52%, +1.08%, +0.62%, -4.52%, -0.06%, -0.26%, -0.50%,
   -2.16%, +0.61%, +4.91% -- all inside the 5% ceiling. The two drain cells `F8`
   flagged as the instrument's floor are still the loose ones.
6. **Host conditions.** AC power, low-power mode off, load 1.75 before and 1.58
   after on the quoted invocation, 1.3-1.8 across the residency ones.
7. **Complexity fidelity -- NOT MEASURED, and this is the entry's one unread
   gate.** The gate times *individual* trim steps and reports their median by
   quartile of a record's drain. Every quartile now reads **0.0 ns (n=1,554 to
   1,577)** and `Q4/Q1` is undefined, because the step it times costs about
   **19.4 ns** -- which the aggregate `wrapped` `drain` statistic measures over
   2,000 steps at 19.4 ns/row -- against the probe's **41.7 ns** clock. The
   quantity did not stop existing; the instrument stopped being able to see one
   step of it, and `D4` gate 8 says such a quantity is reported absent rather
   than as 0. It is **not** reported as a pass. Two independent readings say the
   complexity `D4` froze its rule against is still what the code does, and both
   are stated so a human can weigh them against an unread gate: `firstRowCellEnd`
   is now branch-only -- at most one wide-head probe and no loop at all, so a
   record walk is not representable in it -- and the aggregate `wrapped` drain is
   **0.151x** today's, where a per-step record walk over 315-row records would
   cost multiples of today's rather than a seventh of it. Recorded as `DD38`.
8. **Coverage.** Every aggregate is printed with its round count and per-round
   sample count; every residency row carries `n=1 process`; "not measured" is
   distinguished from zero throughout, including in gate 7 above.

#### Observation 6 -- arm C, descriptive: the granularity question is now moot

`D4` runs arm C to attribute a reject to granularity rather than to the arena.
**There is no reject to attribute**, so the arm is reported for continuity only.
Head-granular against whole-record on one reproduced arena, `n=5` rounds.

| class | rows/record | head-granular | whole-record | head/whole | `F8` head/whole |
| --- | ---: | ---: | ---: | ---: | ---: |
| `mix` | 1.74 | 18.8 | 5.4 | 3.5x | 18.3x |
| `full` | 2.00 | 18.5 | 4.6 | 4.0x | 30.3x |
| `stream` | 1.00 | 9.8 | 9.3 | 1.05x | 5.9x |
| `wrapped` | 336.00 | 23.0 | ~0.0 | >1,000x | >1,000x |
| `wide` | 2.04 | 17.8 | 136.0 | 0.13x | 0.76x |

The fidelity arm is the reading that changed most, and it changed direction: the
reproduction's head-granular drain is now **1.130x** the landed store's on
`wrapped` (22.1 against 19.5 ns) where `F8` measured it at 0.619x. On `stream` it
is still 0.274x, because the reproduction is a linear arena with no ring seam, no
index blocks and no side tables, and `stream` is the class where every step drops
a whole record. `D4`'s bar for taking the `AR1` whole-record fallback needs a
reject that no longer exists, so it stays where `D2` Decision 2 put it.

- Observation: after the write-path optimization and the residency remedy, on a
  store saturated at its own bound, the arena's whole write path costs
  **0.856x-1.023x** today's per admitted display row and its eviction alone
  **0.151x-1.022x** today's per evicted display row across all four
  verdict-bearing classes; a cycled arena pane is **15.359 MiB** resident on
  `scrollback-plain` and **18.234 MiB** on `scrollback-mixed` against today's
  18.094 and 18.281 MiB for the same fed inputs; and one retained display row in
  14,486 read back wrong before the seam-spacer defect this run found was fixed.
- Inference: **`D4`'s eviction rule reads neutral and its `AR6` residency rule
  reads narrow confirm**, so both of `F8`'s named conditions are discharged in
  the branch that does not block. The eviction condition -- "the store does not
  land until either the eviction implementation clears 1.09x under this same
  rule, or the paired ladder comes back not-`slower`" -- is satisfied by its
  first clause, on the same rule, the same probe file and the same thresholds.
  `AR6`'s remedy shipped and its reading is now a recorded condition on pane
  count rather than a trigger. What is **not** inferred: that the store may land.
  `D4` and `D1` both say a microbenchmark predicts a ladder verdict and does not
  produce one, `AR3` still stands (the projection facade still allocates per
  pointer query), and the acceptance dimension is unchanged.
- Competing interpretations:
  - *The optimization traded fidelity for speed.* Refuted by gate 1 in the
    opposite direction: the run found a fidelity defect that predates the
    optimization and the fix makes the store **more** faithful than `F8`
    measured it. Every other behavioral suite is unchanged and green.
  - *The numbers moved because the arena got smaller, not because the write path
    got cheaper.* Refuted by the attribution arm, which runs with **no eviction
    at all** on an arena sized past the stimulus and still shows admission at
    0.775x-0.917x of today's where `F8` measured 1.79x-2.76x.
  - *`stream`'s drain at 1.022x is the same reject `F8` recorded, shrunk.* It is
    the same cell and it is still the worst drain cell, at 1.022x against a
    1.09x line and +2.23% against an A/A floor of 0.26%. It is reported as a
    real effect above resolution, which is exactly why the verdict is neutral
    rather than confirm.
  - *Gate 7's unreadability hides a complexity regression.* Possible in
    principle and addressed in two ways rather than dismissed: the code path is
    branch-only and the aggregate drain on the class the gate is about is 0.151x
    today's. A reader who wants the gate read literally needs a longer per-step
    batch than `D4` froze, which is a change to the instrument and is a human's.
- Uncertainty:
  - **This is a microbenchmark and predicts a ladder verdict; it does not
    produce one.** `D4` says so, and that is unchanged by the verdict moving.
  - **Gate 7 is unread**, for the reason Observation 5 gives.
  - **The instrument calls enforcement once per admitted row** while production
    amortizes it over a batch; both arms are treated identically so the ratio is
    fair and the absolute nanoseconds are upper bounds.
  - **`full`'s depth margin over today's engine is now 0.9%.** `PO11` holds, but
    it holds by less than a percent on one class, and any future charge the store
    adds spends that margin.
  - **The residual charge gap is malloc rounding**, ~0.69 MiB on `mixed`, which a
    capacity-stride model cannot see.
  - **The residency source pool is 300 distinct lines, cycled**, and one machine,
    one session -- as with every probe in this doc.
- Deferred decisions, continuing `DD37`'s numbering (`DD36` and `DD37` are the
  remedy's two, recorded in the plan's slice-4a notes):
  - **DD38 -- gate 7 is recorded as *not measured* rather than as passed or
    failed, and the verdict is read on the remaining seven gates.** `D4` gives
    gate 7 a pass/fail form (`Q4/Q1 <= 1.20x`) that presumes the per-step cost is
    above the instrument's clock; the optimization put it below. Reporting it as
    a pass would be reading 0.0/0.0 as agreement, and reporting it as a failure
    would call an implementation defect on a step that got **cheaper**. `D4`
    gate 8 already fixes the tie-break for a quantity that cannot be measured --
    report it absent -- so that is what this does, with both independent readings
    of the same complexity claim stated beside it. A human's to revisit by
    batching the gated step, which is a change to a frozen instrument and is
    therefore not this entry's to make.
- Next action: **the human reads two things this entry does not decide.** First,
  whether a neutral eviction verdict and a narrow-confirm residency reading are
  what they wanted from the "optimize, then re-price" route -- both of `F8`'s
  named conditions are discharged in their non-blocking branch, and slice 5 is
  unblocked on this doc's side. Second, `I2`'s restatement, which the plan now
  carries as a marked amendment and which `F8` and `D4` both said the human owes:
  charged bytes bounded by the arena's **capacity**, capacity allocated **below**
  the budget by a fixed 1/16 reserve, resident still capacity plus metadata.
  Three things this entry hands forward regardless: the write path is now
  **0.856x-1.023x** today's, which is the number the paired ladder re-reads
  against a real implementation; an idle arena pane still costs **15.266 MiB**
  resident, so `DD12` stays refuted and doc 28's `D11` amendment must still be
  read against it; and `PO11`'s margin on `full` is down to **0.9%**, which is
  the budget any future per-record charge has to come out of.

### F11 -- the paired ladder against a real implementation: **all three acceptance rungs read `slower`**, `I7`'s two diagnostics both hold, and a pane costs 8.6x the resident bytes it did before the cutover

- Status: complete, and it is the campaign's **first failed acceptance
  criterion**. This is the acceptance dimension `D1`'s scoping reserved for the
  paired ladder -- the one thing no Phase 1 or Phase 3 microbenchmark was allowed
  to answer -- and it answers `slower` on `retained-browse` (the go/no-go), on
  `terminal-feed` and on `scrollback-stream` (`H3`'s named falsifier). Nothing
  here is a disposition: the plan's Acceptance section gives a `slower`
  `retained-browse` verdict a fixed diagnostic order, this entry runs it, and
  what to do about the result is a human's.
- **Read this first.** The regression is enormous and is not the shape any
  microbenchmark in this doc predicted: `retained-browse` **+60.44%** against a
  1.05% threshold, and `scrollback-stream` **+141.42%** against 1.85%, whose
  PTY drain rate fell from **8.4 MB/s to 1.3 MB/s** for the same corpus. `F1`
  measured the read walk at **0.61x** today's and `F10` measured the whole write
  path at **0.856x-1.023x** today's, both on the store this ladder judges, so the
  cost the ladder sees is one **neither probe's boundary contained**. The
  attribution work below narrows where it is not; it does not name what it is.
- Date and investigator: 2026-08-04, Claude (agent).
- Commit and worktree state: candidate is the working tree at `330c17b`
  (tree `76eade551cd5`), which is the landed store plus the two untracked paths
  present throughout this doc's work (`TODO.md`,
  `docs/scratch/2026-08-04-scroll-sample-breakdown.md`) and `F12`'s new probe
  file, none of which is in the app build. Baseline is **`28c54e1`**
  (tree `f7705cb0c767`), the last **pre-cutover** commit: the store existed and
  was unwired, so the baseline-to-candidate diff is exactly slice 5's cutover
  plus slice 6's docs. That is the "parent revision the change forks from" the
  plan's Acceptance names -- `9ad7cc5`'s own parent -- and it is what isolates the
  cutover from the four commits that built the store.
- Commands, inputs, or reproduction:

      just benchmark-confirm baseline=28c54e1

  one invocation, the complete six-workload ladder at the frozen pair counts, no
  block invalidated and no verdict withheld. `confirm` rather than `quick`
  because this is the campaign's landing gate and
  `agent-docs/terminal-performance.md` reserves the stronger evidence for exactly
  that. Conditions: AC power, one-minute load **1.21 at invocation** and 1.49
  before the first block, both far under any level that could produce effects of
  this size. Diagnostics:

      swift test --package-path lib/TerminalCore --filter TerminalFrameLocateTests
      just terminal-memory-probe "--payload scrollback-plain --vmmap"

- Artifacts:
  `.build/terminal-benchmark-comparisons/confirm/76eade551cd5-0000/run.json`
  (disposable; every decision-bearing value is quoted below).

#### Observation 1 -- the ladder, each rung against its frozen threshold and beside the hypothesis it was testing

The plan states the -2% and -7% figures as **hypotheses this ladder tests**, not
outcomes to confirm. Both are refuted, and in the opposite direction.

| workload | frozen rule (`confirm`) | hypothesis | measured | verdict |
| --- | --- | --- | ---: | --- |
| **`retained-browse`** (go/no-go) | 4 pairs, +/-1.05%, band 0.75% | **-2%** (`F1`'s 0.61x read walk through `28/F17`'s share) | **+60.44%** | **`slower`** |
| **`terminal-feed`** (`H3` falsifier) | 2 pairs, +/-2.5% | neutral | **+2.60%** | **`slower`** |
| **`scrollback-stream`** (`H3` falsifier) | 4 pairs, +/-1.85% | **-7%** (`F3`'s 0.624x admission through `28/F20`'s share); `F10` revised it to **-2.2%** | **+141.42%** | **`slower`** |
| `content-churn` | 4 pairs, +/-2.15%, band 0.75% | -- | -2.12% | `inconclusive` |
| `style-churn` | 4 pairs, +/-2.0% | -- | -3.09% | `faster` |
| `incremental-mixed` | 6 pairs, +/-1.85% | -- | -5.16% | `faster` |

`scrollback-stream`'s split, which is where its number becomes legible:
drain **182.0 ms at 8.4 MB/s** (baseline) against **1136.4 ms at 1.3 MB/s**
(candidate) for the same 1.53 MB corpus, with the draw tail *falling* from 15.4 ms
to 11.4 ms. The block is ~96% drain by construction
(`agent-docs/terminal-performance.md`), so this verdict is a throughput reading:
**the app drains a PTY 6.2x slower than it did before the cutover.**

The three draw workloads are the control this comparison cannot reach by design
-- none of them displays history at all -- and two of them read *faster*. So the
regression is not machine state, not the build, and not a broad slowdown: it is
specific to the paths that touch retained history. Their plan-time lines are
**+24% to +34%** (uncalibrated, no verdict) and move together with the two
history verdicts, which is the co-movement `17/D6` says may be used to
*undermine* a verdict -- here it corroborates rather than undermines, since the
draw verdicts it accompanies went the other way.

#### Observation 2 -- `D3` Decision 1's diagnostic order, run in the order it fixes, and both diagnostics hold

The plan's Acceptance section: *"A `slower` `retained-browse` verdict falsifies
the implementation before the design: check the locate counter (`I7`) and the
arithmetic-only projection reads first, in that order. Only with both holding
does it read as evidence against wrap-at-read, which is `28/H7`'s reopening
condition."* Both were run before anything else was concluded, and **both pass**:

1. **The locate counter (`PO7`, `I7`).**
   `frameLocateCountIsConstantInHistoryDepth` passes: a planned frame spends at
   most one locate per viewport traversal, and the count at 6,000 retained lines
   equals the count at 60. `HR1`'s named hazard -- a per-row index lookup, priced
   at 164-218 us per frame -- **is not what is happening.**
2. **The arithmetic-only projection reads.**
   `projectionArithmeticNeverTouchesTheIndex` passes: the projection totals and
   the top row, the ~200-per-frame reads `HR1` counted, cost no locate at all.

**What the campaign's own rule says follows from that, stated plainly because it
is the finding's most consequential sentence:** with both diagnostics holding,
the frozen rule reads the verdict as evidence against wrap-at-read and reopens
`28/H7`. **This entry records that the rule fires and simultaneously records why
it should not be executed yet**, because Observation 3 measures a mechanism the
two diagnostics cannot see and which is not wrap-at-read. `D3` Decision 1 froze
its diagnostics against `HR1`'s hazard, which was the only one known when it was
written; the pair is necessary and, on this evidence, not sufficient. Whether to
treat that as the rule working or as the rule being under-specified is a human's,
and it is the single question this entry hands forward.

#### Observation 3 -- the same pane costs 8.6x the resident bytes, and the per-row allocation the arena deleted is not what replaced it

`D4`'s residency reading names `just terminal-memory-probe` as its instrument.
`F8` and `F10` could not use it -- the store was internal and unwired, so both
reproduced the instrument inside the test process against a bare
`LogicalLineStore`. **The cutover makes the named instrument runnable against a
real pane for the first time, and that is what changed about this reading's
meaning:** `F10` priced the store, this prices the terminal.

`--payload scrollback-plain`, 10,000 lines at 179x66, one process per reading,
candidate at `330c17b` against baseline at `28c54e1`:

| quantity | baseline (`28c54e1`) | candidate (`330c17b`) | ratio |
| --- | ---: | ---: | ---: |
| footprint delta | **9.47 MB** | **81.66 MB** | **8.62x** |
| live heap | 5.45 MB | 15.55 MB | 2.85x |
| bucket rounding | 1.08 MB | 11.18 MB | 10.4x |
| row allocations | 10,001 | **66** | 0.007x |
| census coverage of the delta | 0.46 | **0.05** | -- |
| retained cells | 518,499 | 518,499 | 1.000x |
| content identities | 510,000 | 510,000 | 1.000x |

Four readings, and the third is the one that matters:

- **The arena did exactly what it promised on allocations.** 66 row allocations
  against 10,001: the per-row blob `F3` Observation 3 attributed its whole win to
  is gone, and only the live screen allocates.
- **`MALLOC_LARGE` is the arena and it is the expected 15.0 MB dirty**, on the
  `empty` payload as well (15.48 MB footprint for a pane fed nothing, which is
  `DD12` staying refuted at the pane level exactly as `F10` found it at the store
  level).
- **The census explains 5% of what the pane costs, against 46% before.** The
  arena, the index and the side tables are all *charged*, and `PO3`'s census says
  the charge holds -- so the ~66 MB the census cannot see is **not** retained
  history. It is dirtied pages nothing in the store's charge model is about,
  which is `15/F4`'s shape and `15/F2`'s error class at the same time, and it
  sits on the same path whose throughput fell 6.2x.
- **One lead was raised and refuted in the same reading.** 510,000 content
  identities for 10,001 rows is ~1 per cell, which would have made `DD28`'s
  identity run table degenerate to a per-cell fallback and explained both
  history verdicts at once. The baseline reports the **identical** 510,000, so
  the per-cell shape predates the cutover and is not the regression. Recorded
  because a refuted lead is evidence about where the cost is not.

#### Observation 4 -- the `DD8` re-read against what actually landed, and the honest tally runs the other way

The gate `D3` Decision 5 set: *"`DD8` is re-read as `F6` asked"*, and the plan's
premise 5 restates it as the cross-cutting-versus-local asymmetry rather than a
count. `F5` Observation 5 tallied 5 cross-cutting invariants deleted against 3.5
local ones added; `D3`'s amendment revised it to **4.5 against 4.5** and said the
count no longer carries the inequality. Re-read against the landed diff:

**The deletion side, verified symbol by symbol at `HEAD`.** All five hold as `D3`
left them, and none is smaller than claimed. `ScrollbackBuffer`,
`productionScrollbackCellCap`, `productionScrollbackRowCap`, `scrollbackByteCost`
and `setScrollbackCell` are **gone from the tree** (5, 5, 5, 12 and 3 references
at `de17e95`, zero now); `isHistoryHeadTruncated` survives only as two comment
citations; `ReflowTextAttachment` is gone (7 references to zero). Two are reduced
rather than deleted, both already priced: `reconstructLogicalLines` and
`pack(line:columns:)` survive restricted to the **live** screen (`DD39`), and
`boundaryDestinations` survives for the live half of the anchor restatement
(`DD40`) -- which is the 0.5 `D3` already charged. **Deleted: 4.5, unchanged.**

**The addition side is larger than either `F5` or `D3` counted**, because three
of the landed contracts were decided after the tally and one crosses the store's
boundary:

| # | invariant added by what landed | who has to hold it | local? |
| ---: | --- | --- | --- |
| 1 | exactly one open record, always the arena tail | the admission path | local |
| 2 | cached block totals valid for the current width, or discarded | the index, at six trigger points (`I9`; `F5` said four) | local |
| 3 | no record exceeds 1/32 of the budget, readers rejoin splits by adjacency | admission + copy/search readers | local |
| 3.5 | `hasWideCells` set iff the record holds a wide cell | the admission path, safe when wrong | local (half) |
| 4 | capture anchors before the index recompute, restate after (`D3`'s addition) | the width-change path | local |
| 5 | **`I11` -- the open tail ends on a display-row boundary at the current width** | admission **and** the width change's seam hand-back; `AR7` says it was discovered, not designed | local, two sites |
| 6 | **the seam spacer is re-derived in `Terminal`, not in the store (`DD43`)** | `Terminal.seamSpacer`, reached at **four** sites, because the store cannot see the live grid's first cell | **cross-cutting** |
| 7 | **a record's trailing fill lives in a side table gated by header bit 63, released on eviction, reopen and hand-back (`DD25` amended, `DD33`-`DD35`)** | the store | local |
| 8 | **eviction is read as a delta against a monotone counter a hard reset restarts (`historyEvictionsObserved`)** | `Terminal` and the store together | **cross-cutting** (half) |

That is **4.5 deleted against 7.5 added**, counting item 8 as a half and letting
the arena's maintained metadata charge (`DD37`) **cancel** against today's
`scrollbackByteCost` maintenance, which was the same obligation in the other
store. The count now runs against the design, where `F5` had it 5-to-3.5 for and
`D3` had it level.

**Does the cross-cutting-to-local claim survive contact? Mostly, and with two
named exceptions.** Six of the eight additions are contracts inside the store,
enforceable by one writer and testable by one gate, exactly as `F5` claimed. Two
are not: `DD43` puts a fold obligation on `Terminal` at four call sites, and the
eviction-delta counter is a two-object protocol. Both are contracts between the
store and something outside it -- the property `F5` used to distinguish the two
sides.

**Against `DD8`'s own reopening test, which requires both clauses:**

- *Clause 1, "the implementation lands materially larger than the prototype
  suggests":* **met, decisively.** `F5` Observation 4 sized the storage core at
  ~350-400 prototype lines against ~720 net deleted. What landed is
  `LogicalLineRecord.swift` (337) plus `LogicalLineStore.swift` (2,082) = **2,419
  new production lines**, while `Terminal.swift` fell only **6,470 -> 6,431**
  (-39). Across `lib/TerminalCore/Sources` the arc is **+3,337 / -918**, a net
  **+2,419**. The prototype under-predicted by 6-7x and the deletion did not
  arrive: on lines of code the inequality is not close to a wash, it is
  **inverted**.
- *Clause 2, "the invariant argument has weakened":* **met.** The count reversed
  (4.5 against 7.5) and two added contracts cross the store boundary.

**Both clauses are met, so `DD8` reopens on its own terms**, and with it the
README's second acceptance dimension -- which says in terms that a design
drifting to where the inequality no longer holds is "evidence against the
direction, not a cost to absorb". This is an accounting pass and it decides
nothing; what it removes is the option of quoting `F5`'s margin, which is exactly
what the gate existed to prevent.

- Observation: on one valid `confirm` invocation against the pre-cutover parent,
  `retained-browse` reads **+60.44%**, `terminal-feed` **+2.60%** and
  `scrollback-stream` **+141.42%**, all `slower` against frozen thresholds of
  1.05%, 2.5% and 1.85%; the three history-free draw workloads read
  `inconclusive`, `faster` and `faster`; both of `D3` Decision 1's diagnostics
  hold; the same pane costs 8.62x the resident bytes with 0.007x the row
  allocations and a census that explains 5% of it; and the `DD8` re-read finds
  4.5 invariants deleted against 7.5 added with a 6-7x line-count
  under-prediction.
- Inference: **acceptance dimension 1 fails, and this store does not land on this
  evidence.** Dimension 2's re-read reopens `DD8` on both its clauses. What the
  evidence does **not** support is concluding against wrap-at-read: `F1` measured
  this store's own read walk 1.64x *faster* on the same content shape
  `retained-browse` feeds (short hard-terminated lines, one record per display
  row), `F10` measured its write path at 0.856x-1.023x, and both `I7` diagnostics
  hold -- so a 60% read regression and a 6.2x drain collapse are being produced
  by something the four probe boundaries in this doc all exclude, which is the
  wiring slice 5 added rather than the model `D1` licensed.
- Competing interpretations:
  1. *Wrap-at-read is simply slower in situ than in isolation, and `28/H7` should
     reopen.* The reading `D3` Decision 1's rule produces mechanically. Against
     it: `retained-browse`'s stimulus is 10,000 **short hard-terminated** lines
     (`RETAINED_BROWSE_IDENTITY`), so every record folds to exactly one display
     row and the fold is one `ceil` -- there is almost no wrapping to do at read,
     and `F12` measures the fold's cost as a function of record size on the same
     engine and finds it flat until records are thousands of cells. A design
     whose read model is barely exercised cannot be what a 60% read regression
     indicts. **This is the interpretation the frozen rule selects and the one
     the evidence fits worst**, which is why it is stated first.
  2. *The cutover's wiring allocates per admitted row and per read row, on top of
     the arena.* Fits the most evidence: 8.62x resident with 0.007x row
     allocations and 5% census coverage says the pages are being dirtied by
     something that is not retained history and is not charged; a 6.2x PTY drain
     collapse is an admission-path cost; and `F10`'s 0.856x-1.023x write path was
     measured by driving `LogicalLineStore.admit` directly, which is precisely the
     boundary that excludes whatever `Terminal` does around it. Unproven: no
     profile was taken, because the plan's diagnostic order stops here and the
     disposition is a human's.
  3. *The comparison is confounded.* Refused on the run's own evidence: one valid
     invocation, no invalidated block, load 1.21 at invocation, and three
     history-free workloads on the same schedule reading -2.12%, -3.09% and
     -5.16%. A machine-state artifact does not move six workloads in two
     directions.
  4. *`terminal-feed`'s +2.60% is inside the noise.* It is 1.04x its frozen 2.5%
     threshold and is the weakest of the three `slower` readings; on its own it
     would deserve a `confirm`-level re-read. It is not on its own.
- Uncertainty:
  - **The mechanism is unattributed.** This entry bounds where the cost is not
    (not the locate count, not the projection arithmetic, not the identity table,
    not the store's own admit/evict as `F10` measured them) and never names it. A
    Time Profiler trace on `scrollback-stream` is the obvious next instrument and
    was deliberately not run: `agent-docs/terminal-performance.md` says to report
    findings and pause before optimizing, and the plan says the disposition is
    the human's.
  - **One invocation.** The pair counts are frozen precisely so a result cannot
    be shopped for, so this is the verdict and re-running is not licensed. At
    +60% and +141% against 1.05% and 1.85% thresholds, resolution is not the
    open question.
  - **The residency re-read is partial, and says so.** `F10`'s in-test four-state
    instrument was **not** re-run at the landed revision (`DD49`); what is
    reported is `D4`'s *named* instrument at the pane level on two payloads plus
    `empty`. The four-state ladder and the `blank` regime are **not measured**,
    not measured-zero.
  - **The `DD8` tally is an accounting pass over invariants**, with the same
    unit-choice objection `F5` Observation 4 conceded against itself; it is
    reported so it can be disputed rather than to settle anything.
- Deferred decisions, continuing `DD48`'s numbering; each took the obvious simple
  option and each is a human's to revisit:
  - **DD49 -- the residency re-read is `D4`'s named pane-level instrument, not a
    re-run of `F10`'s in-test four-state ladder.** Three reasons, and the first
    is the plan's. The ladder verdict fires the plan's STOP rule, so nothing
    downstream is waiting on a residency number and spending an hour of process
    launches to re-price a store whose landing is now in question buys nothing.
    The store's four-state reading was taken 2026-08-04 at `5cf61e0` and the only
    store change since is slice 5's (the index rings' minimum capacity, 16 -> 4),
    which moves an empty store's floor and not a cycled one's. And the pane-level
    instrument is the one `D4` actually named and the one the cutover makes
    runnable, so it reads *more* of the gate than the substitute did, on the
    quantity a user pays. What it costs: the second reject trigger ("> 1.10x
    today's resident for the same fed input **in the same session**") is
    **unreadable at the landed revision by construction** -- today's store no
    longer exists in the tree, so no same-session control can be built, and the
    8.62x above is two processes minutes apart on one machine rather than a
    paired reading. At that ratio the distinction does not change the reading,
    and it is stated rather than hidden.
  - **DD50 -- the `DD8` tally counts `DD37`'s maintained metadata charge as
    cancelling today's `scrollbackByteCost` maintenance rather than as a new
    invariant.** Both are "a derived total is maintained at every mutation and
    must equal a from-scratch recompute", one per store, and counting the new one
    without discharging the old would inflate the addition side by an obligation
    that merely moved. The alternative reading -- that the arena's version is
    worse because it has six invalidation points against today's two -- is
    `AR4`'s, is already carried there as a risk with no analogue, and would make
    the tally 4.5 against 8.5 rather than 7.5. Either way the count runs the same
    direction, which is why this was not worth blocking on.
- Next action: **the human decides, and the plan says so before this entry was
  written.** Three questions, in the order the evidence makes them tractable.
  (1) Whether to profile `scrollback-stream` and the browse path before
  concluding anything about the design -- Observation 2 records that the frozen
  rule fires and that the evidence fits interpretation 2 rather than 1, and only
  a profile separates them. (2) Whether `28/H7` reopens now or after that
  profile. (3) Whether the cutover is reverted, held, or fixed forward while the
  question is open; nothing in this doc licenses any of the three, and `D1`'s
  scoping never licensed the production storage change that has already landed.

### F12 -- the forced-split cap against a real pathological input: it bounds every hazard it was derived for, and binds a term nobody derived -- browsing a near-cap record costs 133 us per display row, 40x ordinary content

- Status: complete. It discharges `D1` inherited **condition 8** -- "the
  forced-split cap is derived, not measured; no pathological input has been fed
  to a real engine to see what a session produces. Feed one; the cap bounds the
  hazard either way." One was fed. The cap does bound the hazard, and the reading
  adds a term to what "the hazard" means.
- Date and investigator: 2026-08-04, Claude (agent).
- Commit and worktree state: `330c17b`, the landed store. **This finding adds one
  file** --
  `lib/TerminalCore/Tests/TerminalCoreTests/TerminalLogicalLinePathologicalProbe.swift`
  -- and edits nothing under `lib/TerminalCore/Sources/`; `F1`'s, `F2`'s, `F3`'s,
  `F7`'s, `F8`'s and `F9`'s probe files are unedited, which is the isolation
  practice `F2` established.
- Commands, inputs, or reproduction:

      DANTERM_LOGICAL_LINE_PROBE=1 swift test -c release --package-path lib/TerminalCore \
        --filter TerminalLogicalLinePathologicalProbe

  Release, headless, 179x66, the 16,777,216-byte production budget, fed in 4 KiB
  chunks (the memory probe's rule: a single-shot feed measures the parse spike).
  Load average **1.41 before and 1.23 after**. Two stimuli, both fed through the
  real `Terminal`: `31/F4`'s named wezterm shape (**1,499,979 bytes of minified
  JSON on one line**, on top of 2,000 ordinary lines) and a line **larger than
  the whole arena** (25,165,831 bytes, no newline), which is the case no
  derivation covers.
- Artifacts: none durable; every number below is stdout.

#### Observation 1 -- what a 1.5 MB JSON line does

The cap is **65,536 cells**, read from
`LogicalLineRecord.forcedSplitCellCount(forCapacity:)` rather than transcribed,
so it moves with the budget as `DD3` says it should. The line arrives as **23
pieces**, exactly `ceil(1,499,979 / 65,536)`.

| quantity | reading |
| --- | ---: |
| records retained (2,000 ordinary + 23 pieces) | 2,023 |
| display rows retained | 12,315 |
| arena bytes in use / capacity | 14,979,440 / 15,728,640 |
| admission of the whole line | **102.1 ms** |
| copy: text lines / longest line | 2,001 / **1,499,979** |
| width change 179 -> 100 -> 179 | 5.99 ms / 5.00 ms |

**Copy sees one logical line.** The 23 pieces rejoin by adjacency (`DD6`) into a
single 1,499,979-character text line whose prefix is the JSON's own, which is
`PO9`'s obligation met on a real input rather than a synthetic one. **The charge
holds**: bytes in use stay under capacity, and the ordinary history is evicted
byte-driven rather than the line being refused.

#### Observation 2 -- the term the derivation did not price: the fold is `O(cells in the record)` per display row

Browsing the split region, against two controls in the same process -- the same
terminal's own ordinary region, which no difference between two terminals can
reach, and a separate ordinary-content terminal at a comparable depth:

| region | one frame (geometry + 66-row cell walk) | per display row |
| --- | ---: | ---: |
| the JSON region | **8,844.7 us** | 134.0 us |
| same terminal, ordinary region | 219.1 us | 3.3 us |
| separate ordinary control | 219.7 us | 3.3 us |
| ratio | **40.3x** | -- |

`agent-docs/measurement-discipline.md` says two points are not a trend, so the
middle of the curve was measured -- retained depth held near 5,000 display rows,
varying only cells per logical line:

| cells per logical line | records | retained rows | one frame | per display row |
| ---: | ---: | ---: | ---: | ---: |
| 179 | 4,962 | 4,962 | 360.0 us | 5.45 us |
| 512 | 1,736 | 5,206 | 389.2 us | 5.90 us |
| 2,048 | 434 | 5,203 | 586.7 us | 8.89 us |
| 8,192 | 108 | 4,949 | 1,388.8 us | 21.04 us |
| 32,768 | 27 | 4,903 | 4,564.3 us | 69.16 us |
| **65,536** (the cap) | 13 | 4,706 | **8,789.3 us** | **133.17 us** |

Linear in cells per record at **~1.95 ns per record-cell per display row**, flat
in retained depth. The mechanism is readable in the code and the arithmetic
matches it to within the reading's precision:
`LogicalLineStore.forEachFoldedCell` calls `LogicalLineFold.enumerateRows` over
the **whole record** to find one display row's cell range, and `enumerateRows`
walks cell by cell. A frame reads 66 rows through two traversals, so a near-cap
record costs 66 x 65,536 x 2 = 8.65M cell steps -- which is the 8.8 ms measured.

**So the cap is what bounds this, and the bound it yields is 8.8 ms per frame:
53% of a 16.67 ms frame at 60 Hz.** `AR2` bracketed the wide-record fold as
"`O(display rows)` with an O(1) test per boundary ... the bracket clears one
frame by ~3x on an unmeasured constant". That bracket is about `rowCount`, which
does take the arithmetic fast path; the **cell-range** walk that `forEachFoldedCell`
performs has no such path, and it is the one a read actually spends. `F9`
measured `O(display rows)` at 5.2-5.4 ns for the counting pass and was right
about that pass; this is a different walk.

#### Observation 3 -- a line larger than the arena degrades gracefully

25,165,831 bytes on one line, into a 15.7 MB arena:

| quantity | open tail | after the closing newline |
| --- | ---: | ---: |
| records retained | 32 | 32 |
| display rows retained | 10,973 | 10,947 |
| arena bytes in use / capacity | 15,717,192 / 15,728,640 | 15,678,624 / 15,728,640 |
| admission (whole 24 MiB feed) | **1,713.2 ms** | -- |
| copy: text lines / longest | -- | 1 / 1,975,844 |
| ordinary lines surviving | **0** | -- |
| browse, one frame | 8,775.3 us | -- |
| width change 179 -> 100 -> 179 | 3.10 ms / 3.45 ms | -- |

The line evicts its own head while it is still being printed, keeps the last
~1.96M cells, and stays readable throughout: 32 records of a single logical line,
one text line on copy, the charge inside capacity at every point, and the head
piece reading as a mid-line continuation. Nothing traps, nothing is refused, and
browse costs the same 8.8 ms the cap bounds it to. **This is the case
`I10`'s derivation never covered and it is the one that behaves best**, because
byte-driven head eviction and adjacency-rejoining readers compose without needing
a rule of their own.

- Observation: a 1.5 MB single logical line splits into exactly the 23 pieces the
  cap predicts, reads back as one line for copy, holds the charge, resizes in
  ~5-6 ms, and costs **8,844.7 us to browse one frame against 219.1 us on
  ordinary content in the same terminal**; the cost is linear in cells per record
  at ~1.95 ns per cell per display row; and a line larger than the whole arena
  evicts its own head and stays readable.
- Inference: **the cap bounds every hazard `DD3` derived it for** -- eviction
  granularity, the wide-cell scan, and memory -- **and it also bounds one the
  derivation never named**, the read-time fold, at a value of **53% of a 60 Hz
  frame**. Two consequences. The derivation held in form (1/32 of the budget is
  still the right shape of rule) and is now under-motivated: the binding term at
  production width is the fold, not the two hazards the 1/32 was chosen for. And
  `forEachFoldedCell`'s `O(cells in record)` walk is a defect of the
  implementation rather than of the design -- `D3` Decision 7 already established
  that the boundary walk is `O(display rows)`, and this walk is not it. Recorded,
  not fixed: it is a production change outside the slice that measured it.
- Competing interpretations:
  1. *This is `AR2` coming due, so it was accepted in advance.* No. `AR2` is about
     a record that holds **wide cells**, where a boundary probe per display row is
     unavoidable; both stimuli here are ASCII, `hasWideCells` is false, and the
     arithmetic path exists and is not taken by this walk.
  2. *A 1.5 MB single line is not worth engineering for.* It is `F4`'s own named
     shape from a real terminal's issue history, and it is what `cat` of a
     minified bundle produces. The reading also shows the cost arriving long
     before the cap: 8,192-cell lines already cost 6.4x an ordinary frame.
  3. *The ratio is an artifact of comparing two terminals.* Refused by the
     same-terminal control: 8,844.7 us in the JSON region against 219.1 us at the
     top of the **same** history, 40.4x, which is the separate control's 40.3x.
- Uncertainty:
  - **One machine, one invocation per rung, no A/A control.** The gate asked what
    a real input produces, not for a threshold, and the effect is 40x; a paired
    instrument would be the wrong tool at that size.
  - **The 8.8 ms frame is `forEachViewportCell` plus `geometry`, not
    `planFrame`.** It is the store's contribution to a frame, not a frame; the
    calibrated instrument for the latter is `retained-browse`, which does not
    feed pathological content and so cannot see this at all.
  - **Search and selection across a forced split are covered by `PO9`'s existing
    tests**, not re-measured here; copy is, through `primaryHistoryText`.
  - **The width-change readings are reported without attribution.** The JSON
    history resizes in 5.99/5.00 ms against the control's 1.91/1.69 ms with a
    fifth of the records, which is the opposite of what the counting pass alone
    predicts; the live refold and the seam prefix are both in that number and
    nothing here separates them.
- Next action: none owed by this gate -- condition 8 is discharged. Two things it
  hands forward: the fold's `O(cells in record)` walk is a named, measured,
  reproducible target with a probe already committed, and `I10`'s cap now has a
  **third** hazard to be derived against if the budget ever moves.

### F13 -- the cutover's regression, attributed: a 15.75 MiB arena copied per published frame, a per-cell record decode where the incumbent decoded two fields, a planner traversal that hoists nothing, and a whole-terminal equality that materializes every retained cell

- Status: complete, and it is an **attribution rather than a verdict**. `F11`
  bounded where the cost is *not* and never named it; this entry names four
  mechanisms, each with a share of a real profile or a paired headless number, and
  each of them is wiring rather than `D2`/`D3`'s model. Nothing here re-runs the
  ladder and nothing here disposes of `F11`.
- **Read this first.** Every named mechanism is in the code slice 5 wrote between
  `LogicalLineStore` and `Terminal`, or in the planner slice 5 changed. **None of
  them is wrap-at-read**: the fold is not in the top thirty self frames of either
  app profile, `LogicalLineFold.enumerateRows` does not appear at all, and the
  store's own write path measures *faster* than the incumbent's on
  `scrollback-stream`'s own stimulus (97.4 against 101.5 ns per fed byte). So
  `28/H7`'s reopening condition -- which `F11` records as fired -- is fired on
  evidence that this entry attributes elsewhere.
- Date and investigator: 2026-08-04, Claude (agent).
- Commit and worktree state: candidate is the working tree at `0baf98d`
  (tree `a27a9d2695f5`), which is the landed cutover plus this entry's own probe
  file and the two untracked paths present throughout this doc's work (`TODO.md`,
  `docs/scratch/2026-08-04-scroll-sample-breakdown.md`), none of which is in any
  build measured here. Baseline is **`28c54e1`**, the pre-cutover parent `F11`
  paired against, checked out into a second worktree and built in the same
  session, so every ratio below has a control the change cannot reach
  (`agent-docs/measurement-discipline.md`).
- Commands, inputs, or reproduction:

      # two app profiles, `agent-docs/terminal-performance.md`'s share instrument
      just benchmark-trace scrollback-stream "Time Profiler" 30      # x2

      # the headless paired arms, run interleaved at both revisions
      swift build -c release --package-path lib/TerminalCore --product TerminalBrowseBenchmark
      .build/release/TerminalBrowseBenchmark --measured 2000         # x3 per arm, interleaved
      sample <pid> 15 1                                              # per arm

      DANTERM_WIRED_ATTRIBUTION_PROBE=1 swift test -c release \
        --package-path lib/TerminalCore --filter TerminalWiredHistoryAttributionProbe

      just terminal-memory-probe "--payload scrollback-plain --vmmap"   # per arm

  The probe file is
  `lib/TerminalCore/Tests/TerminalCoreTests/TerminalWiredHistoryAttributionProbe.swift`,
  behind `DANTERM_WIRED_ATTRIBUTION_PROBE` exactly as every probe since `F1`, and
  it is written to compile and run unchanged at `28c54e1`. No earlier probe file
  is edited and nothing under `lib/TerminalCore/Sources/` is touched by it.
- Artifacts: `.build/terminal-benchmark-profiles/2026-08-04-184812-40616/` and
  `.build/terminal-benchmark-profiles/2026-08-04-185157-42293/` (disposable;
  every decision-bearing value is quoted below).

#### Observation 1 -- `retained-browse` reproduces headlessly at +86.7%, which makes it an attributable workload rather than an app measurement

`retained-browse` is a pure headless product (`TerminalBrowseBenchmark`), so the
regression can be reproduced and profiled without the app at all. Three
interleaved invocations per arm, same session, same machine state:

| arm | ns per planned frame | retained rows | plan cell checksum |
| --- | ---: | ---: | ---: |
| `28c54e1` | 335,086 / 335,877 / 335,066 | 9,935 | 5,940,000 |
| `0baf98d` | 625,208 / 626,534 / 626,254 | 9,935 | 5,940,000 |

**+86.7%**, with the checksum and the retained row count identical, so both arms
planned the same cells over the same history. The ladder's `confirm` number is
+60.44%; this arm is untrimmed and unpaired and reads higher, which is the
expected direction for a raw ratio against a winsorized one. What matters is that
the effect survives outside the app, so `sample` can attribute it.

#### Observation 2 -- the browse profile, differenced per frame, puts 60% of the regression in the planner's traversal and 19% in the store's per-cell decode

`sample <pid> 15 1` on each arm, converted to nanoseconds per planned frame with
each arm's own measured frame rate (`agent-docs/terminal-performance.md`'s
per-frame rule). Self time only; the two arms' totals are 278.5 and 512.3 us
against measured 335.1 and 626.0, so the table covers 83% and 82% of each frame.

| frame | base ns/frame | candidate ns/frame | delta | share of +233.8 us |
| --- | ---: | ---: | ---: | ---: |
| `FramePlanner.inspectedCells` closure + its partial apply | 81,555 | 222,355 | **+140,800** | **60.2%** |
| `LogicalLineStore.cell(recordIndex:cellOffset:)` | 0 | 24,289 | +24,289 | 10.4% |
| `LogicalLineStore.contentIdentity(record:at:keyOffset:)` | 0 | 16,860 | +16,860 | 7.2% |
| `Terminal.forEachViewportCell` (both spellings) | 2,996 | 17,486 | +14,490 | 6.2% |
| `swift_release` + `swift_retain` + bridge-object pairs | 11,504 | 42,700 | +31,196 | 13.3% |
| `LogicalLineRecord.init(word:)` | 0 | 7,971 | +7,971 | 3.4% |
| `LogicalLineStore.hyperlinkId(record:at:keyOffset:)` | 0 | 5,718 | +5,718 | 2.4% |
| `Terminal.presentedRowGeometry.getter` | 2,370 | 6,302 | +3,932 | 1.7% |
| `PackedRetainedRow.forEachContentCell` + `u64` | 11,022 | 0 | -11,022 | -4.7% |
| `FramePlanner.decorationRuns` | 18,019 | 15,107 | -2,912 | -1.2% |

`LogicalLineFold.enumerateRows` does not appear in either arm's self table. The
fold is not the cost.

#### Observation 3 -- the four mechanisms, named in the code, with what each replaced

**M1 -- the arena is copied on write once per published frame.** `admit` is
16.42% and 21.83% inclusive of whole-process CPU in the two app profiles with
**0.03%-0.04% self**; the difference is one frame:
`memcpy` under
`applyOutput -> moveAndFillRows -> LogicalLineStore.admit -> ContiguousArray._makeMutableAndUnique -> _ArrayBuffer._consumeAndCreateNew`,
at **12.10%** and **16.13%** of whole-process CPU. `_consumeAndCreateNew` is the
non-unique path: the buffer had another reference, so the mutation copied it.
The other reference is the frame consumer's --
`TerminalPTYHost.drainedFrameState()` puts the whole `Terminal` **value** into a
`TerminalPTYFrameState` and hands it to the pane session, which holds it until the
next publish. Under the incumbent that made history's `[PackedRetainedRow]`
non-unique and cost one element copy per retained row; under the arena it makes a
single `ContiguousArray<UInt64>` of **15.75 MiB** non-unique and copies all of it.
Priced headlessly on `scrollback-stream`'s own stimulus, publishing at a 4 KiB
cadence: the incumbent pays **1.63x** its unshared feed, the arena pays
**2.03x**, and per fed byte the two are 165.5 against 197.8 ns. The arena's
unshared feed is *faster* (97.4 against 101.5 ns/byte), which is `F10`'s reading
holding: the copy is the whole of the difference.

**M2 -- the frame path materializes a whole `GridCell` per cell where the
incumbent decoded the two fields a renderer reads.** `forEachPaintedCell` and
`forEachKind` both funnel through `forEachFoldedCell`, which calls
`cell(recordIndex:cellOffset:)` per column; that function re-reads
`offsets[recordIndex]`, re-decodes the eleven-field record header
(`LogicalLineRecord.init(word:)`, +7,971 ns/frame), builds a full `GridCell`
including a retained `TerminalScalars`, and probes both side tables --
`contentIdentity` (+16,860) and `hyperlinkId` (+5,718) -- **for readers that
discard all three**. `forEachKind` keeps three bits of it. The incumbent had
exactly this split and `28/F17` is why: `forEachContentCell` yielded
`(column, scalars, styleId)` through one unsafe buffer, and `forEachKind` read
one word and masked. Headless, per frame at 9,935 retained rows: the geometry
pass costs **13.0 -> 48.1 us** (3.69x) and the cell pass **40.3 -> 83.6 us**
(2.07x).

**M3 -- the planner's plural traversal hoists nothing per row.** `DD45` gave
`forEachViewportCell` a plural spelling so a frame spends one locate, and moved
`FramePlanner.inspectedCells` inside a single closure. Three hoists the per-row
version had were lost with it, and all three now run **per cell**:
`let kinds = geometry.rows[row].cells` (an array extraction, so a retain/release
pair per cell -- `swift_retain`/`swift_release` and the bridge-object stubs are
+31,196 ns/frame between the arms), `result[row].append(...)` (a nested-array
subscript, so a uniqueness check on two buffers per cell --
`swift_isUniquelyReferenced_nonNull_native` +3,434), and `hovered`/`selected`,
which became captured `var`s re-read per cell. The closure is **4.34% and 3.25%
self** in the two app profiles and **+140,800 ns/frame** headless. It is the
largest single term and it costs the same on a live-grid frame as on a browsing
one, which is why it is visible on `scrollback-stream` at all.

**M4 -- one whole-terminal equality decodes every retained cell into a fresh
array per record.** `LogicalLineStore.==` compares `recordCells(at:)` per record,
and `recordCells` is `(0..<record.cellCount).map { cell(...) }` -- an allocation
per record and a full decode per cell. `Terminal` is `Equatable` with `history`
declared before `rows`, so this runs first. In the first app profile it is
**9.32%** of whole-process CPU, reached from
`TerminalPTYHost.applyPointer -> LogicalLineStore.== -> recordCells -> cell`,
plus **0.78%** in `GridCell.__derived_struct_equals`. **In the second profile,
taken with the pointer warped away from the window, it is 0.00%** -- so this term
is *input-conditional* and this entry does not claim it is inside `F11`'s
number. It is reported because the mechanism is real at any depth: `applyPointer`
takes `let previousTerminal = terminal` and compares, so one mouse move over a
pane with saturated history walks every retained cell **and** makes the arena
non-unique, priming M1's 15.75 MiB copy. The incumbent's `ScrollbackBuffer.==`
compared `[UInt8]` blobs, which is a memcmp with an identity fast path.

#### Observation 4 -- `DD49`'s 8.62x is mostly allocator hysteresis, and settled residency is at parity

`just terminal-memory-probe "--payload scrollback-plain --vmmap"`, run at both
revisions in this session, and its `vmmap` split is what separates the two
readings:

| `vmmap --summary` DIRTY | `28c54e1` | `0baf98d` |
| --- | ---: | ---: |
| `MALLOC_LARGE` (the arena) | -- | **15.0 MB** |
| `MALLOC_SMALL` | 9,216 K | 7,776 K |
| `MALLOC_SMALL (empty)` | **16 K** | **57.1 MB** |
| `MALLOC_LARGE (empty)` | 4,240 K | 6,368 K |
| TOTAL DIRTY | **15.0 MB** | **87.9 MB** |
| probe footprint delta | 9.16 MB | 81.64 MB |

`MALLOC_SMALL (empty)` is 17 regions with **no live allocation in them**: pages
the allocator dirtied for transient small blocks and has not returned. The
incumbent had 10,001 live packed-row blobs recycling that zone; the arena has 66
row allocations, so the same transient traffic -- one 5.7 KB blank cell array per
scrolled row from `makeBlankRow`, which neither revision changed -- spreads
across fresh regions and stays dirty. **Returning free pages before the sample
collapses the difference**: the probe arm here calls
`malloc_zone_pressure_relief` before its settled reading and measures the whole
history at **+16.27 MiB** on the candidate against **+17.73 MiB** on the
baseline, for the same fed corpus, with the arena's reservation charged to the
candidate. That is **0.92x**, which is `F10`'s "narrow confirm" residency reading
holding at the pane level. `DD49`'s 8.62x is a real footprint number and a
misleading residency one, and `just terminal-memory-probe` not settling the
allocator is why.

#### Observation 5 -- what this leaves for the model

`D2` Decision 2's operations, `D3` Decision 1's locate contract and the fold are
all clear on this evidence: the store's unshared write path is 0.96x the
incumbent's per fed byte, `enumerateRows` is absent from both profiles' self
tables, and `F11` already recorded both locate diagnostics holding. Every named
mechanism is a call-site or a facade, and each has a mechanical fix that changes
no invariant: give the store back the two-field and kind-only walks `28/F17`
established, hoist the planner's per-row lookups out of its per-cell closure,
stop the publish from making the arena non-unique, and make `==` compare stored
bytes instead of decoded cells. `F12`'s re-enumeration is a fifth mechanism that
this workload does not reach and that is still owed.

- Uncertainty:
  - **M4's share is input-conditional and the two profiles disagree by
    construction.** 9.32% with ambient pointer motion, 0.00% with the pointer
    parked. Whether `F11`'s invocation had pointer traffic is unknowable now.
  - **The per-frame conversion of a `sample` profile carries the frame rate as a
    divisor**, so the two arms' shares are only as comparable as their measured
    ns-per-frame, which is a three-invocation median rather than a paired
    statistic.
  - **Neither app profile has a baseline arm.** The app-side shares are
    candidate-only; every *ratio* in this entry comes from the two headless
    instruments, which do have one.
  - **The headless drain does not reproduce `F11`'s 6.2x**, and this entry does
    not claim it does: at a 4 KiB publish cadence the arena is 1.19x the
    incumbent per fed byte, not 6.2x. What the app adds is a publish cadence set
    by the display, a fence the drain queues behind, and the planner's per-frame
    cost on the same queue. The four mechanisms are what a profile attributes;
    whether they sum to the ladder's number is the ladder's to say.
- Next action: fix the four mechanisms, each with a behavioral test, then re-run
  the frozen ladder once against `28c54e1`. If any rung still reads `slower`, the
  disposition returns to a human with `28/H7` on the table.

### F14 -- the ladder re-run after `F13`'s fixes: `retained-browse` clears its go/no-go at +1.03%, `scrollback-stream` falls from +141% to +4.92% and `terminal-feed` does not move -- two rungs still read `slower`

- Status: complete, and **acceptance is still not met**. The plan's Acceptance
  section requires all three named rungs to read not-`slower`; one now does and
  two do not. This entry records the verdict and stops there: the plan's own rule
  says the disposition of a `slower` ladder is a human's, and
  `agent-docs/terminal-performance.md` says to report rather than iterate.
- **Read this first.** The regression `F11` recorded is mostly gone and the part
  that remains is a different size of problem: `scrollback-stream` went from
  **+141.42%** to **+4.92%** and its PTY drain from **1.3 MB/s back to 7.8 MB/s**
  against the baseline's 8.4; `retained-browse`, the go/no-go, went from
  **+60.44%** to **+1.03%**, which is `inconclusive` rather than `slower`. What
  did not move at all is `terminal-feed`: **+2.60% -> +2.68%** against a 2.5%
  threshold, the same reading twice.
- Date and investigator: 2026-08-04, Claude (agent).
- Commit and worktree state: candidate is `fa5fb74` (tree `3e11a79c39cb`), the
  cutover plus `F13`'s attribution and the three fixes it names, with the two
  untracked paths present throughout this doc's work captured by the harness and
  absent from the app build. Baseline is **`28c54e1`**, byte-identical to `F11`'s
  (tree `f7705cb0c767`), so the two runs are the same comparison twice.
- Commands, inputs, or reproduction:

      just benchmark-confirm baseline=28c54e1
      just terminal-memory-probe "--payload scrollback-plain --vmmap"

  One invocation, the complete six-workload ladder at the frozen pair counts, no
  block invalidated and no verdict withheld. No threshold, pair count or
  statistic was touched between `F11` and this run. Conditions: AC power,
  one-minute load **1.74 at invocation** (0.17 per processor) and 2.22 before the
  first block.
- Artifacts:
  `.build/terminal-benchmark-comparisons/confirm/3e11a79c39cb-0000/run.json`
  (disposable; every decision-bearing value is quoted below).

#### Observation 1 -- the ladder, before and after, against the same frozen thresholds

| workload | frozen rule (`confirm`) | `F11` | this run | verdict |
| --- | --- | ---: | ---: | --- |
| **`retained-browse`** (go/no-go) | 4 pairs, +/-1.05%, band 0.75% | +60.44% `slower` | **+1.03%** | **`inconclusive`** |
| **`terminal-feed`** (`H3` falsifier) | 2 pairs, +/-2.5% | +2.60% `slower` | **+2.68%** | **`slower`** |
| **`scrollback-stream`** (`H3` falsifier) | 4 pairs, +/-1.85% | +141.42% `slower` | **+4.92%** | **`slower`** |
| `content-churn` | 4 pairs, +/-2.15%, band 0.75% | -2.12% | -0.57% | `equivalent` |
| `style-churn` | 4 pairs, +/-2.0% | -3.09% | -2.97% | `faster` |
| `incremental-mixed` | 6 pairs, +/-1.85% | -5.16% | -10.18% | `faster` |

`scrollback-stream`'s split, which is where the size of the change is legible:
drain **182.6 ms at 8.4 MB/s** (baseline) against **196.3 ms at 7.8 MB/s**
(candidate) for the same 1.53 MB corpus, with the draw tail again *falling*
(15.2 -> 11.5 ms). `F11` read the same baseline at **182.0 ms and 8.4 MB/s**, so
the baseline arm reproduces itself within 0.3% across the two sessions and the
candidate arm moved from 1136.4 ms to 196.3 ms.

**The go/no-go rung is met and the two falsifier rungs are not.** The plan's
words are "not `slower` under its frozen rule", and `inconclusive` is not
`slower`; `retained-browse` at +1.03% sits inside its 1.05% threshold and outside
its 0.75% equivalence band, which is exactly what a change of no consequence
reads as at four pairs.

#### Observation 2 -- what the fixes bought, measured outside the ladder

The three mechanisms `F13` named and fixed, each re-measured on the instrument
that attributed it, interleaved against `28c54e1` in the same session:

| reading | `28c54e1` | before the fixes | after |
| --- | ---: | ---: | ---: |
| `retained-browse`, headless, ns per planned frame | 335,196 | 626,000 (+86.7%) | **341,335 (+1.8%)** |
| one frame's geometry pass over history, us | 13.0 | 48.1 | **9.8** |
| one frame's cell pass over history, us | 40.3 | 83.6 | **49.3** |
| one whole-terminal equality, saturated pane, ms | 0.069 | **44.31** | **0.91** |

The equality reading is the one that changes size rather than sign: a single
`terminal != previousTerminal` over 14,382 retained rows cost **44 ms** and now
costs **0.9 ms**. `TerminalPTYHost.applyPointer` takes two of those per pointer
event, so before this fix one mouse move over a saturated pane cost ~88 ms of CPU.
It is still **13x** the incumbent's 0.069 ms, and the reason is structural: the
incumbent compares `[PackedRetainedRow]`, whose elements are shared blob objects,
so `Array ==` answers on buffer identity; one contiguous arena has no analogue.

#### Observation 3 -- the mechanism `F13` named and this work did **not** fix

`F13`'s M1 -- the arena copied on write once per published frame -- is untouched,
and it is the largest single self frame in both of `F13`'s app profiles
(`memcpy` at **12.10%** and **16.13%** of whole-process CPU, all of it under
`applyOutput -> moveAndFillRows -> LogicalLineStore.admit`). It was left alone
deliberately rather than missed: `TerminalPTYHost.drainedFrameState()` publishes
the `Terminal` **value**, which makes a single 15.75 MiB `ContiguousArray`
non-uniquely referenced, and every fix for that changes what the arena *is* --
chunked backing, a shared-immutable region, or a publish that does not carry
history. `D2`'s decision says "one contiguous per-pane byte arena", so that is a
design change and not a wiring fix, and the brief for this work was to stop at
that line. It is the obvious first suspect for `scrollback-stream`'s residual
+4.92%, and this entry does not claim to have proved that.

`terminal-feed` is the reading that no named mechanism explains. It measures
`Terminal.feed` on a fresh terminal per execution, it never publishes and never
draws, and the headless drain arm measures the store's unshared write path at
**0.96x-1.04x** the incumbent's per fed byte across three sessions. It read
+2.60% before the fixes and +2.68% after, against a 2.5% threshold -- a 0.18%
overshoot of a directional threshold at **two pairs**, the smallest pair count on
the ladder.

#### Observation 4 -- `DD49`'s residency reading, re-taken on the same recipe

`just terminal-memory-probe "--payload scrollback-plain --vmmap"`, the same pane
recipe `F11` used:

| quantity | `28c54e1` | `F11` (`330c17b`) | this run (`fa5fb74`) |
| --- | ---: | ---: | ---: |
| footprint delta | 9.16 MB | 81.66 MB | **81.75 MB** |
| live heap | 5.43 MB | 15.55 MB | **15.55 MB** |
| row allocations | 10,001 | 66 | **66** |
| `vmmap` TOTAL DIRTY | 15.0 MB | 87.9 MB | **87.5 MB** |
| of which `MALLOC_SMALL (empty)` | 16 K | 57.1 MB | **56.9 MB** |

**Unchanged, and expected to be**: none of the three fixes touches allocation
volume on the feed path, and `F13` Observation 4 already established what this
number is -- 15.0 MB of it is the arena, and 56.9 MB is pages the allocator
dirtied for transient small blocks and has not returned. The settled reading,
taken with free pages returned first, is **+16.25 MiB** on the candidate against
**+17.73 MiB** on the baseline for the same fed corpus. So `DD49`'s **8.62x
stands as a footprint number and is still not a residency one**, and the honest
statement is that this gate is answered by two instruments that disagree because
they measure different things.

- Uncertainty:
  - **One invocation, as the plan's Acceptance specifies.** Both `slower`
    verdicts are near their thresholds (+2.68% against 2.5%, +4.92% against
    1.85%) rather than far past them, which is a different evidentiary position
    from `F11`'s and worth saying: at these sizes a second invocation is a
    reasonable thing for a human to want, and the rule does not require one.
  - **`terminal-feed`'s two-pair rule.** The workload's frozen cell is the
    ladder's smallest, and its 2.5% threshold is the widest; a +2.68% estimate
    from two pairs is the least-resolved number in the table.
  - **The residual is not attributed.** `F13`'s profiles predate the fixes, so no
    profile exists of what `scrollback-stream` now spends its time on. M1 is a
    named suspect with a measured share, not a demonstrated cause.
  - **The `-2%` and `-7%` hypotheses stay refuted.** Nothing here reaches them;
    the best rung is parity.
- Next action: none taken here. The disposition is a human's, and the three
  options the evidence supports are: take M1 (which reopens `D2` Decision 1's
  "one contiguous arena"), accept two near-threshold `slower` rungs as a recorded
  cost, or revert the cutover. `28/H7` remains reopened under `D3` Decision 1's
  frozen rule, and this entry weakens rather than strengthens the case for
  executing it: the go/no-go rung that rule is about now reads `inconclusive`.

### F15 -- the ladder re-run after `D5`'s chunked backing: `scrollback-stream` turns +4.92% into **-9.71% faster** and `terminal-feed` clears, and the go/no-go rung crosses the other way at **+1.39% `slower`**

- Status: complete, and **acceptance is still not met -- for the first time on a
  different rung.** `D5`'s decision rule required all three named rungs
  not-`slower`; two that were `slower` now are not, and the one that was not now
  is. This entry records the verdict and stops there: `D5` froze "any rung still
  `slower` means acceptance is not met, and no second fix round is taken", and
  `agent-docs/terminal-performance.md` says to report rather than iterate.
- **Read this first.** `F13`'s M1 was the residual, and taking it was worth more
  than anyone predicted: `scrollback-stream` went **+4.92% -> -9.71%**, its PTY
  drain from 7.8 MB/s past the baseline's 8.4 to **9.2 MB/s**, which is the first
  rung in this campaign to reach `F3`'s ~-7% hypothesis rather than refute it.
  `terminal-feed` went **+2.68% `slower` -> +2.33% `inconclusive`**, which `D5`
  said in advance it could not explain and still cannot. What broke is
  `retained-browse`: **+1.03% `inconclusive` -> +1.39% `slower`** against an
  unchanged 1.05% threshold. That is `D5`'s **second reopening condition firing
  verbatim** -- "the chunked read costs more than the copy saved" -- and it is why
  this entry is a stop rather than a landing.
- Date and investigator: 2026-08-04, Claude (agent).
- Commit and worktree state: candidate is `1e4cb61` (tree `c1a5371bab25`), the
  cutover plus `F13`'s three fixes plus `D5`'s chunked backing, with the two
  untracked paths present throughout this doc's work captured by the harness and
  absent from the app build (`TODO.md`,
  `docs/scratch/2026-08-04-scroll-sample-breakdown.md`). Baseline is **`28c54e1`**
  (tree `f7705cb0c767`), byte-identical to `F11`'s and `F14`'s, so the three runs
  are the same comparison three times.
- Commands, inputs, or reproduction:

      just benchmark-confirm baseline=28c54e1
      just terminal-memory-probe "--payload scrollback-plain --vmmap"
      DANTERM_LOGICAL_LINE_PROBE=1 DANTERM_RESIDENCY_CASE=arena/plain/cycled \
        swift test -c release --package-path lib/TerminalCore --filter residencyReading

  One `confirm` invocation, the complete six-workload ladder at the frozen pair
  counts, no block invalidated and no verdict withheld. No threshold, pair count
  or statistic was touched between `F14` and this run. Conditions: AC power,
  one-minute load **1.52 at invocation** (0.15 per processor across 10) and 2.95
  before the first block, the second reading confounded by the run's own builds.
- Artifacts:
  `.build/terminal-benchmark-comparisons/confirm/c1a5371bab25-0000/run.json`
  (disposable; every decision-bearing value is quoted below).

#### Observation 1 -- the ladder, all three readings, against the same frozen thresholds

| workload | frozen rule (`confirm`) | `F11` | `F14` | this run | verdict |
| --- | --- | ---: | ---: | ---: | --- |
| **`retained-browse`** (go/no-go) | 4 pairs, +/-1.05%, band 0.75% | +60.44% | +1.03% | **+1.39%** | **`slower`** |
| **`terminal-feed`** (`H3` falsifier) | 2 pairs, +/-2.5% | +2.60% | +2.68% | **+2.33%** | **`inconclusive`** |
| **`scrollback-stream`** (`H3` falsifier) | 4 pairs, +/-1.85% | +141.42% | +4.92% | **-9.71%** | **`faster`** |
| `content-churn` | 4 pairs, +/-2.15%, band 0.75% | -2.12% | -0.57% | -2.86% | `faster` |
| `style-churn` | 4 pairs, +/-2.0% | -3.09% | -2.97% | -2.12% | `faster` |
| `incremental-mixed` | 6 pairs, +/-1.85% | -5.16% | -10.18% | -5.20% | `faster` |

`scrollback-stream`'s split, which is where the size of the change is legible:
drain **182.4 ms at 8.4 MB/s** (baseline) against **166.5 ms at 9.2 MB/s**
(candidate) for the same 1.53 MB corpus, with the draw tail also falling
(14.6 -> 12.5 ms). The candidate now drains the corpus **faster than the
pre-cutover engine**, where `F11` measured it 6.2x slower and `F14` 1.08x slower.
One outlier pair was flagged and retained in the estimate, as the rule specifies.

`retained-browse`'s four paired symmetric percentages are **+0.582, +1.327,
+1.446, +1.502**, median +1.387; one pair (the first) was flagged as an outlier
and retained. Three of four sit above the 1.05% threshold, so the verdict does
not rest on the median's choice among scattered values.

#### Observation 2 -- what the chunked backing bought and what it cost, named separately

**Bought.** `F13` M1 measured `memcpy` at **12.10%** and **16.13%** of
whole-process CPU under
`applyOutput -> moveAndFillRows -> LogicalLineStore.admit -> ContiguousArray._makeMutableAndUnique`,
because publishing the `Terminal` value made a single 15.75 MiB
`ContiguousArray` non-unique. Under `D5` the production arena is 30 chunks of
512 KiB, and one admission after a publish copies **one** of them; the store
test `publishedValueThenAdmitCopiesOneChunkNotTheWholeArena` asserts that
directly, by chunk storage identity rather than by timing. `scrollback-stream`'s
**14.6-point swing** (+4.92% to -9.71%) is the ladder's reading of that, and it
is the first evidence in this campaign that M1 was in fact the residual rather
than merely the largest named suspect.

**Cost.** Every arena read is now `chunks[offset >> shift][(offset & mask) >> 3]`
where it was `arena[offset >> 3]`. The two hot per-row walks hoist the chunk once
per display row, so a *cell* read is the same single subscript it was; what is
not hoisted is the per-record work `retained-browse` does most of -- the header
read behind `record(at:)` and `displayRowCount(recordIndex:)`, once per record,
on a stimulus whose every record is exactly one display row. **+0.36 points is
what that reads as**, and this entry does not claim more precision than that: no
profile of the post-`D5` `retained-browse` has been taken, and the attribution
above is from the code rather than from an instrument.

#### Observation 3 -- `terminal-feed` moved, and `D5` said before the run that it should not

`D5`'s frozen rule states: "this change **cannot** move `terminal-feed`. That
workload measures `Terminal.feed` on a fresh terminal per execution, never
publishes and never draws... The honest prior is therefore that `terminal-feed`
reads `slower` again... If `terminal-feed` moves at all, that is unexplained and
must be recorded as unexplained rather than credited to this change."

It moved: **+2.68% -> +2.33%**, from `slower` to `inconclusive`, on the two
paired values +2.401 and +2.250. **This is recorded as unexplained.** Three
things that are true about it and none of which is an explanation: the rung is
the ladder's least-resolved cell (two pairs, the widest threshold, and a 0.17-point
move across the threshold); the write path did change shape, since `appendCells`
now moves its target chunk into a local for the append loop, which is a different
uniqueness-check pattern even when nothing is shared; and `F14`'s own +2.68% was
already inside the range where a two-pair estimate cannot separate a real effect
from its own noise. A rung that crosses a threshold by 0.17 points in the
direction the change wanted is exactly the reading a campaign should refuse to
bank, and this entry refuses to bank it.

#### Observation 4 -- the residency re-read, which the backing change was expected to move and did not

`just terminal-memory-probe "--payload scrollback-plain --vmmap"`, `DD49`'s named
pane-level recipe, on the same recipe `F11` and `F14` used:

| quantity | `28c54e1` (`F13`) | `F14` (`fa5fb74`) | this run (`1e4cb61`) |
| --- | ---: | ---: | ---: |
| footprint delta | 9.16 MB | 81.75 MB | **82.00 MB** |
| live heap | 5.43 MB | 15.55 MB | **16.01 MB** |
| row allocations | 10,001 | 66 | **66** |
| `vmmap` TOTAL DIRTY | 15.0 MB | 87.5 MB | **88.3 MB** |
| of which `MALLOC_SMALL (empty)` | 16 K | 56.9 MB | **56.8 MB** |
| of which `MALLOC_LARGE` (the arena) | -- | 15.0 MB | **0 -- see below** |

**The one thing that moved is which zone the arena lives in.** A 15 MiB single
allocation was `MALLOC_LARGE`; thirty 512 KiB allocations are `MALLOC_SMALL`,
which is why that row goes to zero and `MALLOC_SMALL` rises from 7.8 MB to
23.3 MB for the same content. TOTAL DIRTY is **88.3 MB against `F14`'s 87.5 MB**,
a 0.9% difference on a number whose 56.8 MB majority is `F13` Observation 4's
unreturned transient pages, so the honest statement is **parity**. The store's
own settled live-heap cost, read through `F8`'s `arena/plain/cycled` arm at this
revision, is **14.673 MiB against a 15.000 MiB capacity** with the census
reporting `charged/budget = 0.9375x` and `censusIdentity` holding, so the 30
chunks cost what the one allocation cost. `F13`'s settled **0.92x** against the
incumbent is quoted rather than re-measured, for `DD49`'s recorded reason: the
incumbent store no longer exists in the tree, so no same-session control can be
built at this revision.

- Uncertainty:
  - **One invocation, as the plan's Acceptance specifies.** `retained-browse` is
    `slower` by **0.34 points** over its threshold, which is the same evidentiary
    position `F14`'s two near-threshold rungs were in and deserves the same
    caution: at this size a human may reasonably want a second invocation, and
    the rule does not require one.
  - **The `retained-browse` regression is attributed from the code, not from a
    profile.** No profile of the post-`D5` browse path exists. That the per-record
    header read gained an indirection is a fact about the diff; that it is *the*
    +0.36 points is an inference.
  - **`terminal-feed`'s move is unexplained**, per Observation 3, and is not
    banked as a win.
  - **`scrollback-stream`'s -9.71% is one reading of a rung that has now produced
    +141.42%, +4.92% and -9.71% across three sessions.** The baseline arm has
    reproduced itself within 0.3% throughout, which is what makes the candidate
    arm's movement readable; the -9.71% itself has no second invocation.
  - **The chunk size is not tuned against a measurement.** `DD53` derived it and
    `D5` names it the one free variable; nothing here prices a different one.
- Next action: none taken here. The disposition is a human's, and the options the
  evidence supports are: accept one near-threshold `slower` rung as a recorded
  cost (the ladder is otherwise `faster` on five of six, including both `H3`
  falsifiers); spend one more round on `retained-browse`'s per-record read, which
  is a bounded and named target rather than an unattributed residual; re-run the
  ladder once more to see whether a 0.34-point overshoot reproduces; or revert the
  cutover. `28/H7` remains reopened under `D3` Decision 1's frozen rule and this
  entry weakens the case for executing it further: the rung that rule is about is
  `slower` by 0.34 points against a store whose two admission falsifiers now read
  `inconclusive` and `faster`.

### F16 -- the ladder re-run after the index's dense header cache: `retained-browse` clears at **+0.94% `inconclusive`**, and with it **every acceptance rung reads not-`slower` for the first time**

- Status: complete, and **acceptance is met.** The plan's Acceptance section
  requires `retained-browse`, `terminal-feed` and `scrollback-stream` all
  not-`slower` under their frozen rules against `28c54e1`; all three are, on one
  valid `confirm` invocation with nothing in the rule touched. This is the fourth
  reading of the same comparison (`F11`, `F14`, `F15`, this) and the first that
  clears.
- **Read this first.** `retained-browse`, the go/no-go rung, went **+1.39%
  `slower` -> +0.94% `inconclusive`** against an unchanged 1.05% threshold, on
  four paired values none of which exceeds it. That is `F15` Observation 2's
  attribution confirmed by the only test it had: `F15` named the per-record header
  read -- given one more indirection by `D5`'s chunked backing, taken once per
  record on a stimulus whose every record is one display row -- **from the code
  rather than from a profile**, and removing exactly that read moved the rung by
  **0.45 points**, slightly more than the 0.36 the attribution predicted.
  `scrollback-stream` improved again, **-9.71% -> -13.60% `faster`**, its drain
  from 9.2 to **10.0 MB/s** against the baseline's 8.6. `terminal-feed` moved the
  other way, **+2.33% -> +2.49%**, and is `inconclusive` by **0.01 points**;
  Observation 3 refuses to read that as clearance rather than as arithmetic.
- Date and investigator: 2026-08-04, Claude (agent).
- Commit and worktree state: candidate is `27c6fb6` (tree `32ae842c86f9`), which
  is `1e4cb61` plus `D2` Decision 1's dense header-cache amendment and its
  implementation, with the two untracked paths present throughout this doc's work
  captured by the harness and absent from the app build (`TODO.md`,
  `docs/scratch/2026-08-04-scroll-sample-breakdown.md`). Baseline is **`28c54e1`**
  (tree `f7705cb0c767`), byte-identical to `F11`'s, `F14`'s and `F15`'s, so the
  four runs are the same comparison four times.
- Commands, inputs, or reproduction:

      just benchmark-confirm baseline=28c54e1
      just terminal-memory-probe "--payload scrollback-plain --vmmap"
      DANTERM_LOGICAL_LINE_PROBE=1 DANTERM_RESIDENCY_CASE=arena/plain/cycled \
        swift test -c release --package-path lib/TerminalCore --filter residencyReading

  One `confirm` invocation, the complete six-workload ladder at the frozen pair
  counts, no block invalidated and no verdict withheld. No threshold, pair count
  or statistic was touched between `F15` and this run. Conditions: AC power, low
  power off, thermal state nominal on every sampled block, one-minute load
  **1.83 at invocation** (0.18 per processor across 10) and 1.66 before the first
  block, the second reading confounded by the run's own builds.
- Artifacts:
  `.build/terminal-benchmark-comparisons/confirm/32ae842c86f9-0000/run.json`
  (disposable; every decision-bearing value is quoted below).

#### Observation 1 -- the ladder, all four readings, against the same frozen thresholds

| workload | frozen rule (`confirm`) | `F11` | `F14` | `F15` | this run | verdict |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| **`retained-browse`** (go/no-go) | 4 pairs, +/-1.05%, band 0.75% | +60.44% | +1.03% | +1.39% | **+0.94%** | **`inconclusive`** |
| **`terminal-feed`** (`H3` falsifier) | 2 pairs, +/-2.5% | +2.60% | +2.68% | +2.33% | **+2.49%** | **`inconclusive`** |
| **`scrollback-stream`** (`H3` falsifier) | 4 pairs, +/-1.85% | +141.42% | +4.92% | -9.71% | **-13.60%** | **`faster`** |
| `content-churn` | 4 pairs, +/-2.15%, band 0.75% | -2.12% | -0.57% | -2.86% | **-4.81%** | `faster` |
| `style-churn` | 4 pairs, +/-2.0% | -3.09% | -2.97% | -2.12% | **-4.44%** | `faster` |
| `incremental-mixed` | 6 pairs, +/-1.85% | -5.16% | -10.18% | -5.20% | **-2.66%** | `faster` |

**All three named rungs are not-`slower`, which is the plan's Acceptance
condition stated in full.** No block was invalidated and no verdict withheld.

`retained-browse`'s four paired symmetric percentages are **+1.119, +0.890,
+0.995, +0.759**, median +0.942, **no pair flagged as an outlier** -- against
`F15`'s +0.582/+1.327/+1.446/+1.502 where three of four sat above the threshold.
The move is visible pair by pair rather than in a median's choice among scattered
values, which is the reading `F15` explicitly could not claim.

`scrollback-stream`'s split: drain **176.8 ms at 8.6 MB/s** (baseline) against
**152.7 ms at 10.0 MB/s** (candidate) for the same 1,525,084-byte corpus, with
the draw tail at 9.4 against 12.4 ms. One pair (-9.84% against three at -13.6%)
was flagged as an outlier and retained in the estimate, as the rule specifies.

#### Observation 2 -- what the header cache bought, and why this is `F15`'s attribution being tested rather than confirmed by assertion

`F15` Observation 2 said, in as many words, that "the per-record header read
gained an indirection" is a fact about the diff and "that it is *the* +0.36
points is an inference". `D2` Decision 1's amendment was written as the test of
that inference, with its own falsification clause frozen before the code existed:
*if `retained-browse` does not clear, `F15`'s attribution was wrong and the next
instrument is a profile.* It cleared, by 0.45 points against a predicted 0.36, so
the inference survives its one available test. What that does **not** license: a
claim that the +0.45 is *entirely* the three removed chases. No profile of either
browse path exists, this run is one invocation, and the change also removed a
`LogicalLineFold.rowCount` call's offset resolution on narrow records and put the
record's header in the same cache line neighbourhood as its offset. The honest
statement is that the named term was removed and the rung moved past its
threshold in the predicted direction and by a little more than the predicted
size.

Three per-record arena chases became three dense reads, per viewport traversal:
`displayRowCount(recordIndex:)` behind `advance`, `foldedRow`'s record, and
`trailingFillStyle`'s header bit. A planned frame makes two traversals
(`DD44`), so the stimulus -- 10,000 short hard-terminated lines, one record per
display row, 9,935 retained -- pays six per row where it paid none before the
cutover and six chunked ones after `D5`.

#### Observation 3 -- `terminal-feed` moved back, this time in the direction the amendment predicted, and is 0.01 points from `slower`

The rung reads **+2.49%** on two paired values, **+1.902 and +3.078**, against a
+/-2.5% threshold. It is `inconclusive` under the frozen rule, and it is
`inconclusive` **by one hundredth of a point**. Three things are true and this
entry banks none of them:

- **The direction is the one `D2`'s amendment predicted.** That entry stated
  before the run that the change *adds* work to the write path -- one dense
  8-byte store per header write and one ring slot per record -- and that a
  regression on `terminal-feed` or `scrollback-stream` would be "this change's
  cost, not an unexplained move". `terminal-feed` moved +0.16 points. That is the
  predicted sign at a size the instrument cannot separate from its own noise.
- **The rung is the ladder's least-resolved cell** and has now read +2.60,
  +2.68, +2.33 and +2.49 across four sessions of the same comparison -- a
  0.35-point spread with no candidate change able to explain more than a fraction
  of it. `F15` Observation 3 recorded its own move as unexplained; this entry
  records the move back the same way.
- **A verdict 0.01 points inside a threshold is a verdict**, under a rule frozen
  before the number existed, and the campaign's discipline is that the rule is
  read as written or not at all. It is also the single most fragile cell in the
  acceptance and the first thing a human should want a second invocation of.
  `scrollback-stream`, the *other* falsifier for the same hypothesis, reads
  -13.60% `faster` with its drain past the baseline's, which is what makes the
  admission falsifier's overall reading unambiguous even though this cell is not.

#### Observation 4 -- residency, which the index's growth was expected to move and moved by less than the instrument resolves

`DD49`'s named pane-level recipe, same payload as `F11`, `F14` and `F15`:

| quantity | `28c54e1` (`F13`) | `F14` | `F15` | this run |
| --- | ---: | ---: | ---: | ---: |
| footprint delta | 9.16 MB | 81.75 MB | 82.00 MB | **82.23 MB** |
| live heap | 5.43 MB | 15.55 MB | 16.01 MB | **16.15 MB** |
| row allocations | 10,001 | 66 | 66 | **66** |
| `vmmap` TOTAL DIRTY | 15.0 MB | 87.5 MB | 88.3 MB | **87.4 MB** |
| of which `MALLOC_SMALL (empty)` | 16 K | 56.9 MB | 56.8 MB | **56.4 MB** |

**Parity.** Footprint is +0.23 MB on `F15` and TOTAL DIRTY is -0.9 MB, on a
number whose 56 MB majority is `F13` Observation 4's unreturned transient pages;
neither difference is resolvable against that. `F13`'s settled **0.92x** against
the incumbent is quoted rather than re-measured, for `DD49`'s recorded reason.

The store-level reading is the one that shows the change, because it reports the
index separately. `F8`'s `arena/plain/cycled` arm at this revision:

| quantity | `F10` (`5cf61e0`) | this run |
| --- | ---: | ---: |
| census capacity | 15.000 MiB | 15.000 MiB |
| arena bytes in use | 14.484 | **13.983** |
| index | 0.516 | **1.017** |
| side tables | 0.000 | 0.000 |
| charged | 14.999 | 14.999 |
| `charged/budget` | 0.9375x | 0.9375x |
| retained display rows | 36,507 | **35,208** |
| `censusIdentity(charged <= capacity)` | true | **true** |

**The index exactly doubled and the arena gave up exactly what it gained**
(+0.501 MiB against -0.501 MiB), which is the displacement model `D2`'s amendment
derived its depth table from, measured. The depth cost on this stimulus is
**-3.56%** (36,507 -> 35,208 rows), which is at the *worst* end of the amendment's
derived 0.4%-1.7% range for a reason the amendment names: the index is charged at
the ring's **capacity** (`DD37`), and this stimulus's ~36,500 records sit just
past a power-of-two boundary, so it pays a full doubling for the 3,700 records
over it. A class whose record count sits just *below* one pays nothing. Nothing
here is a `PO11` failure -- that obligation is against today's engine, whose
measured margins were 1.009x-1.238x (`F10`) and whose arm no longer exists in the
tree (`DD49`) -- but it is the number that says **`PO11`'s margin is now the
binding constraint on any further per-record charge**.

- Uncertainty:
  - **One invocation, as the plan's Acceptance specifies.** Three of the six
    rungs are inside a point of their thresholds in one direction or the other,
    and `terminal-feed` is inside a hundredth of one. A human who wants the
    acceptance to rest on two invocations rather than one is asking for something
    the rule does not require and the evidence would not resent.
  - **`terminal-feed`'s +2.49% is a pass on the number and a coin toss on the
    mechanism**, per Observation 3.
  - **The +0.45-point `retained-browse` move is not profiled.** No profile of the
    browse path exists at any revision after `D5`. The attribution survived its
    test; it was not independently confirmed.
  - **`scrollback-stream` has now read +141.42%, +4.92%, -9.71% and -13.60%
    across four sessions.** The baseline arm has reproduced itself throughout,
    which is what makes the candidate arm's movement readable; the -13.60% itself
    has no second invocation, and this change has no mechanism that should have
    improved it by a further 3.9 points.
  - **`PO11` is derived at this revision, not measured**, because `D4`'s probe
    needs the incumbent store. The store-level reading above confirms the
    displacement model the derivation rests on and nothing more.
  - **The chunk size is still not tuned against a measurement** (`DD53`), and
    `D5` still names it the one free variable.
#### Observation 5 -- APPENDED 2026-08-04 after this entry was recorded: the cache measured DIRECTLY reads `equivalent`, so Observation 2's reading of `F15`'s attribution is WITHDRAWN

**Descriptive only, and it changes no verdict.** Acceptance is defined against
`28c54e1` and was read once under a frozen rule; Observation 1 stands exactly as
recorded and the plan's Acceptance stays MET. What this observation revises is
this entry's own **attribution** and its caution list, which were the weakest
things in it and are now measured rather than argued.

**Why it was taken.** Observation 2 credited the header cache with the go/no-go
rung's 0.45-point improvement by subtracting `F15`'s +1.39% from this entry's
+0.94% -- a **difference of two separately-run comparisons**, which
`agent-docs/terminal-performance.md` classes as descriptive accounting rather
than a verdict, and which this entry's own Uncertainty section flagged. The
direct instrument was one command and was not run. It has now been run:

      just benchmark-confirm baseline=1e4cb61

with candidate `b7a7d81` (tree `d521d718dac8`) -- the store **with** the cache --
against baseline `1e4cb61` (tree `3a5d427073`) -- the same store **without** it,
which is `F15`'s candidate. One session, paired, ABBA-interleaved, the same
frozen rules and pair counts. Conditions: AC power, load **1.53 at invocation**
(busiest external `WindowServer` at 46.2%) and 2.95 before the first block.
Artifact:
`.build/terminal-benchmark-comparisons/confirm/d521d718dac8-0000/run.json`.

| workload | frozen rule | `F15` -> `F16` by subtraction | **measured directly** | verdict |
| --- | --- | ---: | ---: | --- |
| **`retained-browse`** | ±1.05%, band 0.75% | -0.45 | **-0.10%** | **`equivalent`** |
| `terminal-feed` | ±2.5% | +0.16 | -0.93% | `inconclusive` |
| `scrollback-stream` | ±1.85% | -3.89 | -2.18% | `faster` |
| `content-churn` | ±2.15%, band 0.75% | -1.95 | -0.08% | `equivalent` |
| `style-churn` | ±2.0% | -2.32 | +0.69% | `equivalent` |
| `incremental-mixed` | ±1.85% | +2.54 | +2.35% | `slower` |

`retained-browse`'s four paired symmetric percentages are **+0.318, -0.274,
-1.020, +0.064**, median -0.105, **no pair flagged an outlier**. They straddle
zero. And `equivalent` is not "could not tell": under
`scripts/terminal-benchmark-calibration.py#decision_from_estimate` it means the
estimate sits inside the **0.75% equivalence band declared before the
comparison**, which is a positive statement of no difference.

**So the cache is not what moved the rung.** The 0.45 points Observation 2
credited to it is session-to-session drift in the paired estimate, and the
pair-distribution argument that seemed to corroborate it -- `F16`'s four values
sitting below `F15`'s three highest -- was an artifact of the same drift.
Observation 2's sentence "the inference survives its one available test" is
**withdrawn**: what it tested was the subtraction, and the subtraction is not the
measurement. `D2` Decision 1's amendment froze a falsification clause reading "if
`retained-browse` does not clear, `F15`'s attribution was wrong"; the rung did
clear, so the clause did not fire by its letter, and this observation records
that **the clause was the wrong test** -- it could not distinguish the cache from
the session.

**What this does and does not imply.**

- **`DD55` has a measured cost and no measured benefit.** The cost is exact and
  reproduced in this entry's Observation 4: index **0.516 -> 1.017 MiB**, arena in
  use 14.484 -> 13.983, retained depth **-3.56%** on the `plain` stimulus, and
  `PO11`'s derived margin on `full` from 0.9% to **0.4%**. The benefit it was
  taken for reads `equivalent`. **Whether to keep it is a human's**, and nothing
  is reverted here; the campaign's rule is to report rather than to act.
  **Ruled 2026-08-04: reverted.** The index is back to one word per record and
  the store is byte-for-byte `1e4cb61`'s plus `DD56`; the census arm above
  re-measured at index **1.017 -> 0.517 MiB** and retained rows **35,208 ->
  36,467** (+3.58%), giving back exactly what Observation 4 measured the cache
  taking. `D2` Decision 1's amendment carries the re-derived margins and states
  why this null is what licenses reverting without spending a ladder invocation.
- **`F16`'s verdict is untouched.** Acceptance is against `28c54e1`, and the
  store at `27c6fb6` reads +0.94% on that comparison whatever the reason.
- **It sharpens, rather than softens, this entry's "one invocation" caution.**
  `retained-browse` has now read +1.03% (`F14`), +1.39% (`F15`) and +0.94%
  (`F16`) against the same baseline, a **0.45-point spread on a rung whose
  threshold is 1.05%** -- and the direct comparison says the code changes between
  those readings account for none of it. Acceptance therefore rests on one
  invocation of a cell whose session-to-session variation is about half its own
  threshold. A second `confirm baseline=28c54e1` is the instrument for that and
  was not taken.
- **`F15`'s +0.36-point charge against `D5`'s chunked backing is in the same
  doubt, by the same argument**, and for the same reason it was never measured
  directly. `D5`'s **decision** is unaffected: its mechanism was profiled
  (`F13` M1, `memcpy` at 12.1%-16.1% of process CPU) and is independently
  evidenced by `scrollback-stream`'s 14.6-point swing. What is in doubt is only
  the cost it was charged on the browse rung.
- **This invocation's own resolution is worse than `F16`'s and is stated so it is
  not over-read.** `incremental-mixed` returned pairs from **-11.573 to +9.536**
  and its `slower` +2.35% is not a usable estimate of anything; `scrollback-stream`
  spans -4.868 to +1.403. Those cells are noise. The `retained-browse` cell is
  not: four pairs inside a 1.34-point spread centred on zero with no outlier
  flagged, which is what makes its null readable while its neighbours are not.
  A reader who wants the null at higher confidence should re-run this
  comparison, not this observation's neighbours.

- Next action: none owed by this entry. Acceptance is met, so what follows is
  closure rather than another measurement: `D4`'s landing condition is spent on
  its second clause as well as its first, `28/H7`'s reopening is spent, and the
  plan's Acceptance section records a pass. What stays open is listed in this
  doc's Outcome and is unchanged by this reading -- `I2`'s restatement awaiting
  ratification, `DD8`'s reopened simplification dimension, the borrowing-cursor
  plan's frozen 121 us trigger, doc 28's `F24`/`D8` follow-ups, `DD52`'s equality
  residual and `DD53`'s untuned chunk size.

### F17 -- the browse-frame profile nobody had taken: the residual is **closure-dispatch depth in the viewport traversal**, the store's whole read is 1.94% of the frame, and the one mechanical shave available reads `equivalent`

- Status: complete, **diagnostic only, and it issues no verdict.** Acceptance is
  recorded MET against `28c54e1` (`F16`) and nothing here moves it. This is the
  instrument `F15` said was owed ("no profile of the post-`D5` browse path
  exists"), `F16` repeated, and `D2` Decision 1's amendment named as what should
  have been taken instead of guessing -- run at last, after the amendment it
  would have prevented was reverted.
- **Read this first.** The `retained-browse` residual is **+1.00% of the frame**
  and the profile reconstructs it to within 0.06 points of the ladder's +0.94%.
  It is **not the store**: the arena's entire read path is **1.94% of the browse
  frame** and the fold is **0.02%**. It is **closure-dispatch depth in the
  viewport traversal** -- `31/DD45`'s plural, row-scoped spelling puts **seven**
  frames between `inspectedCells` and `plannedCell` where the incumbent's
  singular spelling put **three** -- at **+8,206 ns of a 340,025 ns frame**. The
  store's read is +2,359 ns on top. Every campaign probe that measured the store
  fast was right, and the thing they were not measuring was the shape of the call
  into it.
- Date and investigator: 2026-08-04, Claude (agent).
- Commit and worktree state: candidate `64112a4` (the cache revert), baseline
  `28c54e1` extracted with `git archive` into a scratch checkout and built there,
  with `TerminalWiredHistoryAttributionProbe.swift` copied in unchanged -- which
  is the procedure that probe's own header prescribes. Both arms built and run in
  the same session, minutes apart, on the same idle machine.
- Commands, inputs, or reproduction:

      DANTERM_WIRED_ATTRIBUTION_PROBE=1 swift test -c release \
        --package-path lib/TerminalCore --filter TerminalWiredHistoryAttributionProbe

      xctrace record --template "Time Profiler" --output <dir>.trace \
        --target-stdout /dev/null --launch -- \
        lib/TerminalCore/.build/release/TerminalBrowseBenchmark --measured 90000
      just benchmark-report <dir>.trace

  **Why not `just benchmark-trace`:** its sustained app workloads are
  `scrollback-stream` and the btop recipe; `retained-browse` has no app workload
  because it *is* a one-block command-line binary, and that binary is what the
  ladder times. Profiling it directly measures the thing the rung measures.
  Conditions: AC power, idle machine, ~30.5 s and ~30.4 s of on-CPU samples per
  arm (Time Profiler records running samples only, so shares need no correction).
- Artifacts: two `.trace` bundles plus their `profile-report.json` and
  `profile-folded.txt`, under the session scratch directory (disposable; every
  decision-bearing value is quoted below).

#### Observation 1 -- the two viewport passes, with a same-session control

`F13`'s committed probe, both arms, per planned frame:

| pass | `28c54e1` | `64112a4` | ratio |
| --- | ---: | ---: | ---: |
| geometry pass (kinds only) | 12,992 ns | **9,241 ns** | **0.711x** |
| cell pass (scalars + styles) | 40,398 ns | **51,472 ns** | **1.274x** |
| both | 53,390 ns | 60,713 ns | 1.137x |

The arena's geometry pass is **29% faster** and its cell pass **27% slower**. The
probe spells both per row, which the cutover's real frame path does not, so it
over-charges the arena for addressing -- which is why the profile below, not this
table, is the attribution.

Two readings the same probe carries, both re-measured rather than quoted:
`D5`'s chunked backing is working as designed -- a feed with a published value
copy every batch costs **188.49 -> 104.16 ns/byte** (1.833x -> **1.040x** of its
own unshared feed) -- and **`DD52`'s equality residual is 14.8x**, 72,370 ->
1,069,517 ns per comparison of a saturated pane, which is worse than the 13x that
entry recorded and is still not on the frame path.

#### Observation 2 -- where a browse frame's time goes, both arms, per frame

Self time bucketed by frame name, converted at each arm's own measured frame cost
(336,663 and 340,025 ns, from 2,000-frame runs of the same binaries):

| bucket | `28c54e1` | `64112a4` | delta |
| --- | ---: | ---: | ---: |
| runtime / ARC / array | 139,133 ns | 137,651 ns | -1,482 |
| planner (`plannedCell`, `resolveCellStyle`, runs, decoration) | 118,899 | 116,361 | -2,538 |
| **traversal + closure dispatch** | **35,927** | **44,533** | **+8,606** |
| other | 38,673 | 35,209 | -3,464 |
| **history read** | **4,031** | **6,271** | **+2,240** |
| **total** | **336,663** | **340,025** | **+3,362 (+1.00%)** |

**+1.00% against the ladder's +0.94% is the cross-check that matters**: an
independently built profile of a different binary in a different session
reconstructs the rung's regression to within 0.06 points, so the buckets can be
read as the rung's own composition rather than as a parallel measurement.

#### Observation 3 -- the named mechanism, frame by frame

The hot stack, which is where the shape is legible. Incumbent, `inspectedCells`
to `plannedCell`:

    inspectedCells(row:) -> forEachViewportCell(row:) -> partial apply closure #1 -> plannedCell

Arena, the same span:

    inspectedCells(rows:replanning:) -> forEachViewportRow(rows:where:)
      -> partial apply closure #1 -> closure #1
      -> partial apply closure #3 in forEachViewportRow -> closure #3
      -> partial apply closure #1 in closure #1 -> plannedCell

**Three intermediate frames became seven**, and the profile prices each side:

| frame | ns/frame |
| --- | ---: |
| `partial apply for closure #1 in closure #1 in inspectedCells(rows:...)` | **+16,583** |
| `closure #3 in Terminal.forEachViewportRow` (the `visit` closure) | **+13,597** |
| `closure #1 in closure #1 in inspectedCells(rows:...)` | **+11,278** |
| `closure #1 in closure #3 in Terminal.forEachViewportRow` | +2,464 |
| `partial apply for closure #1 in inspectedCells(row:...)` | -19,392 |
| `closure #1 in inspectedCells(row:...)` | -9,369 |
| `specialized emit #1 in Terminal.forEachViewportCell(row:_:)` | -3,555 |
| `Terminal.forEachViewportCell(row:_:)` | -3,400 |
| **net** | **+8,206** |

Spread over 66 rows x ~180 columns that is **~0.7 ns per cell** -- two or three
instructions of extra indirection, which is exactly what a closure layer costs
and exactly why no single frame looks alarming.

The store's own side, for completeness: `forEachPaintedCell` +3,896,
`foldedRow` +644, `word(at:)` +588, against the incumbent's
`PackedRetainedRow.forEachContentCell` closure -2,769 -- **+2,359 ns/frame**.
Inclusive, the whole `LogicalLineStore` subtree is **1.94%** of the frame,
`LogicalLineFold` **0.02%**, `locate` 0.24% and `advance` 0.37%. **`31/I7` and
`31/AR2` are both comfortable**, measured rather than argued.

**What this says about the traversal shape, and why it is a stop rather than a
target.** The depth is `DD45`'s (the plural spelling that fixed `HR1`'s
one-locate-per-row hazard) and `DD51`'s (the row-scoped form). `DD51` already ran
this optimization round: it measured a single closure holding row state in
captured vars at **+13.9 us/frame** and a nested-function form at **~+210
us/frame**, both worse than the +8.2 us the current shape costs. So the shape in
the tree is already the best of three measured, and the two remaining ways down
are not mechanical: making `Terminal.forEachViewportRow` `@inlinable` so the
chain specializes across the `TerminalCore` / `TerminalRenderPlanning` target
boundary (which pulls `scrollProjection`, `historyCursor`, `history`,
`viewportStreamRow`, `style(for:)` and the row storage into the module's
inlinable surface -- an ABI-surface decision, and exactly what
`docs/design/2026-07-29-cross-module-value-dispatch.md` exists to govern), or a
different traversal contract, which is design. Both are a human's.

**It does not land on the materializing facade**, so it does not strengthen the
borrowing-cursor plan's case: no `GridRow` materialization appears in the browse
frame at all, because `D3` Decision 5's facade is not on this path -- the frame
path borrows already. `D3` Decision 5's frozen 121 us trigger stands untouched
and is still the only thing that should promote that plan.

#### Observation 4 -- the one mechanical shave the profile named, and its paired null

The profile named a cost that is mechanical and contract-free: the two hot
per-row walks read the backing chunk through `ContiguousArray`'s subscript, so
they pay a bounds check and its `immutableCount` load per cell --
`ContiguousArray.subscript.getter` +1,376 ns/frame and
`_ArrayBuffer.immutableCount.getter` +1,097 ns/frame. `recordsHoldTheSameContent`
in the same file already borrows the chunk through `withUnsafeBufferPointer` for
the same reason. Applied to `forEachPaintedCell` and `forEachKind`, borrowing
from the **local** chunk copy so a caller's closure cannot conflict with the
access (`DD51` measured what dynamic exclusivity enforcement costs when it does).

Verified with the paired in-session instrument, `64112a4` as baseline:

| workload | rule | estimate | verdict |
| --- | --- | ---: | --- |
| **`retained-browse`** | +/-1.05%, band 0.75% | **-0.27%** | **`equivalent`** |
| `terminal-feed` | +/-2.5% | -0.63% | `equivalent` |
| `scrollback-stream` | +/-1.85% | +0.59% | `equivalent` |
| `content-churn` | +/-2.15%, band 0.75% | -3.20% | `faster` |
| `style-churn` | +/-2.0% | -2.80% | `faster` |
| `incremental-mixed` | +/-1.85% | +1.17% | `inconclusive` |

`retained-browse`'s pairs are **-0.096, -0.356, -0.186, -0.619**: all four
negative, none flagged, and the estimate is **a third of the equivalence band**.
**Recorded as null.** The direction is consistent and the size is below what the
rule declares meaningful, and the lesson this campaign just paid for is that a
sub-band effect read as a win is how `DD55` happened. No second round is taken;
that is the stop rule as frozen.

#### Observation 5 -- an instrument caution the same run produced, and it bears on every earlier reading

The change verified above touches **two functions in the retained-history read
path** and nothing else. On that change, in one paired ABBA session,
`content-churn` read **-3.20% `faster`** on four consistent pairs (-4.538,
-2.463, -2.238, -3.932) and `style-churn` **-2.80%** on four (-0.951, -2.903,
-2.695, -3.664). Those two workloads redraw the live screen and barely touch
retained history; no mechanism in the diff can move them by 3%.
`incremental-mixed` returned pairs from **-4.793 to +9.188** for the second
session running.

So the paired instrument's *within-session* estimate on the draw cells carries a
systematic component of a few points that its pair spread does not reveal --
four tight, consistent pairs that are nonetheless not the change. This does not
touch `retained-browse`, whose cells have been well-behaved in every session
(spreads of 0.36, 1.34 and 0.52 points), and it does not touch `F16`'s verdict.
It is recorded because it is the same failure mode that produced `DD55`, seen
from the other side: **consistency across pairs is not evidence of attribution**,
and this campaign has now been fooled by it once and caught it twice.

- Uncertainty:
  - **Two profiles, one session, one arm each.** No repeat, and the bucket table
    is a difference of two single traces. Its credibility rests on reconstructing
    the ladder's independently measured +0.94% to within 0.06 points, not on its
    own repetition.
  - **Bucketing is by frame name and is the author's.** The `other` bucket is
    10-12% and moves by -3,464 ns/frame, which is larger than the store's whole
    delta; a different classifier would move numbers between rows. The two
    conclusions that survive any classifier are the ones drawn: the store subtree
    is 1.94% inclusive, and the traversal's candidate-only and baseline-only
    closure frames net +8,206.
  - **The shave's null is one paired invocation**, as the stop rule specifies.
  - **`@inlinable` is named, not priced.** Nobody has measured what specializing
    the traversal across the target boundary would buy.
- Next action: none owed. The residual is attributed and it is not the store; the
  one mechanical fix available reads `equivalent` and no further round is taken.
  What this hands a human, in the order the evidence supports: the traversal's
  closure depth is the named term and both routes down it are decisions rather
  than fixes; `DD52`'s equality residual is 14.8x and unspent; and the draw cells'
  paired estimates deserve a calibration before any future reading leans on them.

#### Disposition 2026-08-05 -- the residual is ACCEPTED, no fix, and this entry becomes the first suspect for any future browse regression

The human declines **both** routes down the residual: the `@inlinable` traversal
that specializes across the target boundary (an ABI-surface decision under
[`../../design/2026-07-29-cross-module-value-dispatch.md`](../../design/2026-07-29-cross-module-value-dispatch.md))
and the different traversal contract (a design decision). Neither is a fix that
can be taken without deciding something larger, and the quantity at stake is
**+8,206 ns of a 340,025 ns frame -- about 3 us, +1.00%** -- which no user
observes. Nothing above is revised; this appends the disposition.

The standing note, which is why this is recorded rather than the item deleted:
**any future `retained-browse` regression on a calibrated reading makes the
viewport traversal's closure depth the first suspect.** The bucket table above is
the before-picture to diff a new profile against, and the seven-frames-versus-three
shape is the specific thing to re-count. `DD51` already priced the two
alternatives to this spelling once; a regression is what would justify pricing
them again.

The other two items the entry handed forward: `DD52`'s equality residual is still
unspent, and the calibration of the draw cells' paired estimates **was taken, as
`F18` below** -- it confirms the caution this entry raised and widens it: three of
the six ladder cells return a directional verdict on byte-identical source.

### F18 -- the paired ladder's A/A wobble, measured per workload: three of the six cells return a directional verdict on identical source, and `retained-browse`'s whole error budget is a slot-linked offset rather than noise

- Status: complete, **descriptive instrumentation context only.** It **issues no
  verdict, reopens nothing, reinterprets no recorded reading, proposes no
  threshold, and changes no frozen rule.** Every threshold in
  `scripts/terminal-benchmark-validation.py#DECISION_RULES` stands exactly as it
  did. The audience is whoever freezes or reads a rule on this instrument next.
- **Read this first.** Eight complete `confirm` invocations of the six-workload
  ladder, candidate and baseline at **byte-identical source**, taken back to back
  in one session on one host. Three cells -- `scrollback-stream`, `style-churn`,
  `incremental-mixed` -- returned a **directional** (`faster`/`slower`) verdict on
  code that cannot differ, `incremental-mixed` in **both directions** across two
  adjacent invocations (+4.85% `slower`, then -4.43% `faster`). `content-churn`
  missed by 0.01 points. `retained-browse` and `terminal-feed` never crossed. And
  `retained-browse`'s spread is not noise at all: within one physical arm
  assignment it is **0.28 and 0.06 points**, while the assignment itself moves the
  estimate by **~0.6 points**.
- Date and investigator: 2026-08-05, Claude (agent).
- Why it exists: this campaign twice came close to concluding from
  between-session drift. `F16` Observation 5 withdrew a header cache built on a
  -0.45-point subtraction that a direct paired run then measured at -0.10%, and
  the same observation recorded four tight consistent pairs on two draw workloads
  a two-function retained-history diff cannot reach. `F17`'s Next action handed
  the calibration forward in as many words. `agent-docs/measurement-discipline.md`
  is the standing rule this discharges: *give every comparison a control the
  change cannot reach, measured in the same session* -- an A/A run is that control
  with the change set to nothing.

#### Commit and worktree state, and why this is a legitimate A/A

- Both arms are `0b777d486a90` (`HEAD` at the time), the docs commit that opens
  this entry's own campaign closure. `benchmark-confirm` **refuses** a baseline
  that resolves to the candidate's own tree, so an exactly-identical pair cannot
  be run. The pair used instead differs by **three untracked non-source files**
  and nothing else: `TODO.md`, `docs/scratch/2026-08-04-scroll-sample-breakdown.md`
  and `dump.txt`, which `git add -A` sweeps into the candidate snapshot. The
  command prints them, and `run.json` records them as the candidate's complete
  changed-path list.
- Verified rather than asserted: `diff -rq` across the two exported arm roots
  reports **only those three files**, plus one `scripts/__pycache__/*.pyc` that
  each arm's own driver import generates after export. No `.swift`, no
  `Package.swift`, no fixture, no script. The two arms compile the same program.
- Both arms build separately, into separate cache entries, exactly as a real
  comparison does. That is deliberate: the point is to measure what a whole
  invocation does, builds and app launches included, not what one series does.

#### Commands, and the host conditions each invocation ran under

      just benchmark-confirm baseline=HEAD          # x8

| # | artifact | candidate slot | load at invocation | busiest external | invalidations |
| ---: | --- | --- | ---: | --- | --- |
| 1 | `confirm/33040fdc648e-0000` | `b` | 3.05 (0.31/cpu) | claude 20.9%, PerfPowerServices 7.9% | none |
| 2 | `confirm/33040fdc648e-0001` | `b` | 3.82 (0.38/cpu) | claude 28.4%, DanTerm 7.4% | none |
| 3 | `confirm/33040fdc648e-0002` | `b` | 5.01 (0.50/cpu) | claude 22.4%, DanTerm 9.1% | none |
| 4 | `confirm/33040fdc648e-0003` | `b` | 4.78 (0.48/cpu) | claude 29.1%, DanTerm 8.0% | none |
| 5 | `confirm/33040fdc648e-0004` | `b` | 5.35 (0.53/cpu) | claude 22.7%, DanTerm 10.5% | none |
| 6 | `confirm/09e3a8250ccd-0000` | `a` | 3.46 (0.35/cpu) | claude 23.2%, DanTerm 7.9% | none |
| 7 | `confirm/09e3a8250ccd-0001` | `a` | 5.40 (0.54/cpu) | claude, DanTerm | none |
| 8 | `confirm/09e3a8250ccd-0002` | `a` | 5.24 (0.52/cpu) | claude, DanTerm | none |

AC power throughout, `lowpowermode 0`, MacBookPro18,1, 10 processors, the same
179x66 geometry every frozen rule is calibrated for. No invocation invalidated a
block, so all eight are complete valid runs by the harness's own rule. Wall time
118-284 s each; the first and the sixth paid an arm build.

**The one stated condition that was not met, said plainly.** The guide requires
the machine otherwise idle. It was not: the agent process driving this session
sat at **20-29% of one processor** in every invocation, and the user's own
DanTerm at 5-10%, both of them external to the harness and so excluded from its
own-descendant filter. Load-per-processor ran 0.31-0.54. That load was roughly
constant across all eight, so it is a condition of the whole table rather than a
confound between its rows -- but the wobble below should be read as **this
instrument on a lightly loaded host**, which is plausibly an upper bound on an
idle one. Nothing here licenses relaxing the idleness rule; it licenses knowing
what a mildly non-idle host costs.

#### The wobble table -- eight A/A estimates per workload, against the frozen threshold

Estimates are the invocation's own symmetric median, the exact number the verdict
is read from. Slot `b` is invocations 1-5, slot `a` is 6-8.

| workload | pairs | frozen threshold | A/A estimates, slot `b` \| slot `a` | full spread | worst \|estimate\| | directional A/A verdicts |
| --- | ---: | ---: | --- | ---: | ---: | ---: |
| `terminal-feed` | 2 | 2.50% | -0.36 -0.37 +0.17 +0.25 -0.53 \| -0.83 -0.86 -0.55 | 1.11 | **0.86** | 0 / 8 |
| `scrollback-stream` | 4 | 1.85% | -0.67 -1.00 -2.12 +0.35 -3.48 \| -2.43 -1.78 -1.01 | 3.84 | **3.48** | **3 / 8** (all `faster`) |
| `content-churn` | 4 | 2.15% | -0.95 -1.75 -1.06 -0.56 +2.07 \| -1.87 -2.14 -0.40 | 4.21 | **2.14** | 0 / 8 |
| `style-churn` | 4 | 2.00% | +0.56 +0.86 +0.32 +0.97 -0.04 \| -2.01 +0.54 -3.43 | 4.39 | **3.43** | **2 / 8** (both `faster`) |
| `incremental-mixed` | 6 | 1.85% | +4.85 -4.43 +1.19 +0.20 +0.83 \| -1.53 +0.18 -2.76 | 9.27 | **4.85** | **3 / 8** (1 `slower`, 2 `faster`) |
| `retained-browse` | 4 | 1.05% | +0.63 +0.61 +0.78 +0.89 +0.68 \| +0.14 +0.08 +0.11 | 0.81 | **0.89** | 0 / 8 |

Per-invocation paired values, which is what a reader checks a suspicious estimate
against. Each row is one invocation's complete pair series.

| workload | slot `b`, invocations 1-5 | slot `a`, invocations 6-8 |
| --- | --- | --- |
| `terminal-feed` | (-0.600 -0.127) (-0.397 -0.340) (+0.223 +0.107) (+0.279 +0.216) (-0.348 -0.703) | (-0.536 -1.121) (-0.955 -0.760) (-0.574 -0.524) |
| `scrollback-stream` | (-3.104 +0.311 -1.651 +2.291) (-5.400 -1.076 +2.276 -0.930) (-7.048 -1.432 -2.812 -0.757) (-1.332 +3.600 -0.116 +0.823) (-5.092 -3.131 -3.834 +1.747) | (-2.853 -2.278 +1.577 -2.580) (-2.868 -1.580 +0.790 -1.984) (+0.001 +0.086 -2.018 -2.509) |
| `content-churn` | (-1.898 -0.915 -0.975 +0.190) (-2.756 -5.649 -0.741 +2.018) (-1.092 -1.024 -0.353 -3.129) (+0.273 -2.460 +0.237 -1.356) (+2.463 +0.585 +3.530 +1.676) | (-2.020 +1.334 -1.711 -3.573) (-3.868 -4.223 -0.213 -0.416) (-8.030 -0.376 +0.928 -0.432) |
| `style-churn` | (+0.005 -1.850 +3.164 +1.107) (+2.136 +0.508 +1.202 -0.469) (+1.774 -5.456 +1.284 -0.650) (+2.585 -0.134 -0.613 +2.067) (-0.969 +0.882 +1.554 -1.193) | (-0.871 -3.461 -0.770 -3.157) (+0.834 +1.158 -0.407 +0.236) (-4.078 +1.481 -2.776 -6.836) |
| `incremental-mixed` | (+6.031 -3.648 -6.693 +7.248 +3.666 +7.378) (-9.305 -6.160 -2.692 -10.033 -1.651 +3.662) (-0.824 +3.244 +3.197 -7.176 -3.462 +4.674) (+1.434 +7.547 +0.905 -0.514 -1.345 -1.407) (-6.175 +10.263 +1.236 +0.430 -3.659 +5.842) | (-11.414 +4.253 -1.547 -9.636 +1.984 -1.518) (-2.616 +2.468 +4.105 -2.110 -5.721 +8.289) (-1.299 -9.733 +2.727 -19.999 -3.230 -2.282) |
| `retained-browse` | (+0.901 +0.643 +0.249 +0.608) (+0.552 +0.672 +0.148 +1.170) (+0.747 +1.323 +0.668 +0.804) (+0.355 +1.093 +0.745 +1.033) (+0.922 +0.448 +1.145 +0.395) | (-0.005 +0.141 +0.134 +0.319) (+0.274 -0.409 +0.157 +0.002) (+0.171 -0.162 +0.053 +0.263) |

#### Observation 1 -- one reading rule per workload, and which cells are well-resolved

The rule is stated as the largest A/A estimate the workload produced, rounded up.
It is deliberately the crudest available statistic: no resampling, no quantile,
no call into `select_candidate`. `agent-docs/measurement-discipline.md` says to
read a gate from the code that owns it, and that gate belongs to
`scripts/terminal-benchmark-calibration.py`, which screens a *series* rather than
a set of invocations. This entry is not a screen and must not be usable as one.

| workload | reading rule on this host | against its threshold |
| --- | --- | --- |
| `terminal-feed` | Differences smaller than **0.9 points** are indistinguishable from noise. | **Well-resolved.** 2.5% is 2.9x the worst A/A estimate. |
| `scrollback-stream` | Differences smaller than **3.5 points** are indistinguishable from noise. | **Not resolved.** 1.85% is *below* the wobble; the cell produced three `faster` verdicts on identical source. |
| `content-churn` | Differences smaller than **2.2 points** are indistinguishable from noise. | **Threshold-marginal.** 2.15% sits 0.01 points above the worst A/A estimate. |
| `style-churn` | Differences smaller than **3.5 points** are indistinguishable from noise. | **Not resolved.** 2.0% is below the wobble; two `faster` verdicts on identical source. |
| `incremental-mixed` | Differences smaller than **4.9 points** are indistinguishable from noise. | **Not resolved, and the worst cell on the ladder.** 1.85% is a quarter of the wobble, and the cell answered in both directions. |
| `retained-browse` | **With the physical slot held fixed: 0.3 points.** Across slots: **0.9 points**. | **Threshold-marginal, and for a reason that is not noise** -- see Observation 2. Within a slot the cell is by far the best-behaved on the ladder. |

The expectation this entry was opened with is **half confirmed and half refuted**.
`retained-browse` was named as the suspect and is indeed marginal, but not the way
predicted: its run-to-run scatter is the smallest on the ladder and its margin is
eaten by a systematic instead. `terminal-feed`'s two-pair cell was the other named
suspect and is the **best-resolved cell here**, at 2.9x margin. The three draw
workloads, which nobody flagged, are where the instrument actually fails.

#### Observation 2 -- `retained-browse`'s error budget is a physical-slot offset, and the ABBA schedule does not remove it

`physical_candidate_arm` derives the candidate's slot from the candidate tree's
own hex parity, so it is fixed for the whole of one invocation and identical
across every invocation that shares a candidate tree. Invocations 1-5 shared one;
invocations 6-8 were taken deliberately against a second candidate tree, chosen
only so its parity landed the candidate in the other slot, and otherwise the same
byte-identical source.

| | slot `b` (n=5) | slot `a` (n=3) |
| --- | ---: | ---: |
| mean A/A estimate | **+0.72%** | **+0.11%** |
| spread within the slot | **0.28** points | **0.06** points |
| every estimate positive | yes (5/5) | yes (3/3, one pair negative) |

So the ladder's quietest cell separates into a **~0.6-point slot term** plus a
run-to-run scatter of **0.06-0.28 points**, against a 1.05% threshold and a 0.75%
equivalence band. Two consequences worth a reader's attention, both descriptive:

1. **A `retained-browse` comparison is far more repeatable than its threshold
   suggests, provided the slot does not change.** Five invocations of the same
   tree pair landed inside 0.28 points of each other. That is a usable property:
   re-running the *same* candidate tree measures the same thing.
2. **A change that alters the candidate tree can move this cell by ~0.6 points
   with no code difference at all**, because the tree hash decides the slot. Every
   comparison in this campaign changed the candidate tree between rounds.

The mechanism is **not determined here**, and this entry declines to guess it into
a conclusion. What is ruled out is a pure slot mirror: a purely positional effect
would put one slot at `+x` and the other at `-x`, and both slots read positive
(+0.72 and +0.11), so there is a common positive component of roughly +0.42 as
well as a slot component of roughly +/-0.31. Naming the mechanism needs a probe
this entry does not run.

#### Observation 3 -- `scrollback-stream` is biased negative on identical source, and it is not the slot

Six of eight estimates are negative, both slot means are negative (-1.38 and
-1.74), and the three directional verdicts are all `faster`. So unlike
`retained-browse` this is not a slot term; the whole cell leans one way. On a
workload whose block is ~93% PTY drain, the plausible sources are within-invocation
warm-up and page-cache state -- the drain figures the harness prints are
themselves nearly identical between arms every time (165.2-168.1 ms, 9.1-9.2 MB/s
on both arms in all eight runs), which is worth noticing: **the composition line
is stable to ~1% while the deciding metric swings 3.8 points.** Not attributed,
and named as the first thing a follow-up would measure.

#### Observation 4 -- what this does and does not say about the frozen rules

Stated explicitly because the table above is easy to over-read.

- **It does not say the thresholds are wrong**, and it proposes no replacement.
  The rules were frozen off A/A screens (`28/F5`, `28/F6` for `retained-browse`,
  doc 8 for the rest) that resample a **single 24-pair series** at 50,000-100,000
  trials. That measures the scatter *inside* one collection. This entry measures
  the scatter *between* whole invocations, which additionally contains two arm
  builds, two app launch cycles, the slot assignment, and whatever the host did in
  between. The two numbers are not the same quantity and the second being larger
  is expected rather than contradictory. Which one a decision should be read
  against is a rule-freezer's question, not this entry's.
- **It does not reopen or reinterpret any recorded verdict.** `F11`, `F14`, `F15`,
  `F16` and `F17` stand exactly as written, including `F16`'s acceptance reading
  and the two cautions `F16` already carried in its own text.
- **Eight invocations is a small n**, and "3 of 8 returned a direction" supports
  *"this cell returns directional verdicts on identical source"* and does **not**
  support a rate. Reading 37.5% off it would be the error this campaign already
  paid for once.
- **`scripts/terminal-benchmark-plan-calibration.py` was deliberately not used.**
  It screens only the auxiliary metrics in `CALIBRATABLE_METRIC_TABLES` (plan
  time, process CPU), never the deciding metric; it binds both physical arms to
  one immutable root, so it structurally cannot observe the slot effect
  Observation 2 found; and it reduces to one series rather than repeated whole
  invocations. It answers a different question well and this one not at all.

- Uncertainty:
  - **One host, one session, one geometry, one afternoon.** Nothing here
    generalizes to another machine, and the guide already says a machine change
    requires recalibration.
  - **The host was not idle** (see the conditions block). The wobble is plausibly
    an upper bound for an idle host, and that direction is an argument, not a
    measurement.
  - **n=3 in slot `a`.** Observation 2's decomposition into a common term and a
    slot term rests on three invocations on one side and five on the other.
  - **No mechanism is attributed** for either systematic. Both observations name
    what a follow-up would measure and stop there.
  - **The reading rule is the worst observed estimate**, which is a sample maximum
    and rises with n by construction. It is a floor on what to distrust, not an
    estimate of a distribution.
- Next action: none owed, and nothing is blocked on it. The durable half -- one
  reading rule per workload and the two systematics -- is written into
  `agent-docs/terminal-performance.md` under "Run it under the stated conditions",
  which is where a reader looks before measuring. Three deferred decisions are
  recorded below. What a future rule-freezer would measure next,
  in the order the evidence supports: alternate the slot *within* one invocation's
  schedule and see whether `retained-browse`'s offset survives it; take a
  `scrollback-stream` A/A series long enough to say whether its negative lean is
  warm-up or thermal; and repeat the whole table on a genuinely idle host.

#### New deferred decisions

- **DD58 -- the calibration is recorded as a finding in this doc rather than as a
  new research doc or a guide-only note.** `F17`'s Next action handed the
  calibration forward as this doc's owed item, so the evidence belongs on this
  doc's chain; `../FORMAT.md` then routes the durable cross-cutting half out to
  the guide that owns the subject, which is why one reading rule per workload
  lives in `agent-docs/terminal-performance.md` and the table lives here. The
  alternative -- opening doc 32 for benchmark noise -- is the better shape the
  moment a second host or a second session is measured, because at that point the
  subject is the instrument rather than this campaign. Reopen it then.
- **DD59 -- three extra invocations were taken with the physical slot inverted,
  making eight rather than the five planned.** Five invocations all shared one
  candidate tree and so one slot, which cannot separate a slot-linked systematic
  from an A/A offset -- and `agent-docs/measurement-discipline.md` forbids
  deriving what one more run could measure. The inversion was obtained by adding
  one disposable non-source file to the working tree until the candidate tree's
  hex parity flipped the assignment, then deleting it; the arms stayed
  byte-identical in source throughout. The cost is that the eight runs are not one
  homogeneous sample: five share one candidate tree and three share another. The
  table reports both groups separately rather than pooling them, which is the
  whole reason the slot effect is visible at all.
- **DD60 -- the reading rule is denominated as the largest A/A estimate observed,
  not as a resampled quantile, and `select_candidate` is deliberately not
  called.** That gate is owned by `scripts/terminal-benchmark-calibration.py` and
  takes its conditions from a single series; calling it on a set of whole
  invocations would produce a number shaped like a frozen threshold out of
  evidence that is not one, which is exactly the confusion
  `agent-docs/measurement-discipline.md` records under "read a gate from the code
  that owns it". A sample maximum is crude and rises with n, and both properties
  are stated where the rule is. A human who wants a real threshold on
  between-invocation noise should build the screen for it rather than reuse this
  table.
