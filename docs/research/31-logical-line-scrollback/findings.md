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
