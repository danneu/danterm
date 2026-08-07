# Findings -- by-construction performance survey

Append-only. `F1`-`F8` are the survey's directly verified results: a code-read
in the tree at the stated commit, or a contention-free probe. Everything the
survey merely *proposed* lives in the task ledger in
[README.md](README.md), not here.

All entries are dated 2026-08-06 at commit `5391260b` (branch
`experiment/swift-terminal-engine`), working tree clean apart from an untracked
plan file. No benchmark and no profiler was run: six read-only agents ran
concurrently and would have poisoned any timing. Every size below is therefore a
**structural** claim -- a count, a stride, or a call path -- and none is a
performance verdict.

### F1 -- the parser materializes one 32-byte enum per input token before the grid is touched

- Status: verified by code-read and layout probe.
- Commit and worktree state: `5391260b`, clean.
- Commands, inputs, or reproduction: read
  `lib/TerminalCore/Sources/TerminalCore/TerminalInputStream.swift#TerminalInputStream.feed`
  and `Terminal.swift#Terminal.feed`; separately, a standalone `swiftc -O`
  program printing `MemoryLayout<TerminalStreamAction>.size/stride`.
- Measurements or examples: `TerminalStreamAction` is size 26, **stride 32**.
  `TerminalInputStream.feed` returns `[TerminalStreamAction]`, built by
  appending one element per recognized token; `Terminal.feed` then iterates the
  completed array.
- Observation: for plain text, one array element is produced per printed
  character. A 620 KB single-shot feed therefore builds roughly 620k x 32 B
  ~= 19.8 MB live, plus the geometric-growth copies behind it.
- Inference: this reproduces `15/F7`'s 37.2 MB of `MALLOC_LARGE (empty)` and its
  coverage-0.35-versus-0.87 discrepancy, which that finding diagnosed as an
  instrument artifact and worked around with `--chunk`. The allocation is real
  and is paid in production on every feed, not only by the probe.
- Competing interpretations: the optimizer could in principle stack-promote or
  eliminate the array; the layout probe does not prove it survives to runtime in
  an optimized build. `10/F1`'s profile tree shows an unattributed
  `Terminal.feed -> _platform_memmove` node at 7.4% of harness root with no
  callee frame, which is the shape array-growth memmove would take -- suggestive,
  not conclusive.
- Uncertainty: high confidence the array exists and its element stride is 32;
  medium confidence on the CPU magnitude, low confidence on how much of the
  memory figure survives optimization.
- Next action: `T1` sizes it per corpus in situ; `T7` removes it.

### F2 -- damage is a bitset, flattened to a `Set<Int>` at the public boundary, then re-coalesced into spans by every consumer

- Status: verified by code-read. **Named independently by four of six survey
  verticals** (PTY/IO, planning, grid, draw).
- Commands, inputs, or reproduction: read
  `lib/TerminalCore/Sources/TerminalCore/TerminalDamage.swift`.
- Measurements or examples: `TerminalDamageAccumulator` stores
  `private var words: [UInt64]` under the doc comment *"Keeps hot-path row
  damage in reusable words until a consumer requests the public set."* The
  public `TerminalDamage` exposes `public private(set) var rows: Set<Int>`, and
  `init(rows:)` is `self.rows = Set(rows.filter { $0 >= 0 })` -- a second
  allocation and a second full rehash of a set the accumulator just built.
  Downstream, `RenderFramePlanner` asks `damage.rows.contains(row)` per row,
  `terminalDamageRowsWithGlyphHalo` builds a third set, and
  `terminalDamageMaximalContiguousSpans` calls `sorted()` to recover ordering the
  words already had.
- Observation: the exact, coarse representation exists and is deliberately
  destroyed at the public seam; three consumers then re-derive it.
- Inference: textbook flatten/compute/re-coalesce
  (`agent-docs/perf-granularity-mismatch.md` heuristics 2, 4 and 5). The
  `>= 0` sanitizer in `init(rows:)` exists only because the type admits
  arbitrary integers -- with a width-bounded bitset, an out-of-range row is
  unrepresentable rather than filtered.
- Competing interpretations: `30/D2` examined this and rejected it, on the
  grounds that the diff shape did not justify the change and explicitly writing
  *"do not reopen this for the sort"*. That rejection stands on its own terms;
  the survey's contribution is that three *other* verticals reached the same
  representation from unrelated directions, which `30/D2` did not have.
- Uncertainty: high confidence on the structure, low confidence that it is worth
  measurable time standalone -- the damaged-row count is bounded by ~66, so this
  is on the order of a few hundred hash operations and four allocations per
  frame. It matters mainly as a multiplier under `H2`'s publish rate.
- Next action: `T3` counts the round trips; `T20` records the disposition, which
  is provisionally "rider on `T9`/`T14`, not standalone".

### F3 -- `PackedRetainedRow`'s encode/decode surface has no production caller

- Status: verified by code-read.
- Commands, inputs, or reproduction:
  `grep -rn "PackedRetainedRow" lib/TerminalCore/Sources/`.
- Measurements or examples: every `Sources/` reference is to
  `PackedRetainedRow.Header`'s bit constants (`cellStyleShift`, `cellSpillBit`,
  `cellScalarMask`, `cellKindShift`, `cellKindMask`), read from
  `LogicalLineStore.swift` in roughly 19 places. `pack`, `cell(at:)`,
  `unpacked`, `forEachCell`, `forEachContentCell` and `forEachKind` are reached
  only from `Tests/`.
- Observation: a 643-line file whose header comment describes a representation
  the engine no longer uses, retained in production solely for five integer
  constants.
- Inference: not a performance finding. It is a correctness hazard at exactly
  the seam `T19` would rewrite -- the next reader of the live-to-retained
  boundary will read a stale description of it. The ideal shape is a small
  word-layout type owning the constants and the encode/decode pair together, with
  the reference encoder moved into the test target that is its only consumer.
- Uncertainty: none on the fact. `28/PO5` already records this as half-retired.
- Next action: fold into `T19`, which touches the same layout.

### F4 -- the planner builds a whole-viewport geometry projection above its own damage-scoped reuse check

- Status: verified by code-read. **Corrects `17/F5`.**
- Commands, inputs, or reproduction: read
  `lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift`
  lines 284-291 and the callers of `Terminal.geometry`.
- Measurements or examples: `FramePlanner.plan` opens with
  `let geometry = terminal.geometry` at line 284; the per-row retained-reuse
  check (`retained.columns == geometry.columns`) is at 291. So the projection is
  built unconditionally, **before** and therefore outside damage scoping. It
  allocates one `[TerminalCellGeometry]` of `columnCount` per row -- 66
  allocations on a 179x66 pane -- and the planner reads exactly one field from
  it, `.kind`. `PackedRetainedRow.swift:402` carries a comment confirming the
  projection's purpose: *"`Terminal.geometry` projects kinds and nothing else"*.
  The kind is already in the same packed `UInt64` word `forEachPaintedCell`
  decodes. `Terminal.geometry` has no other production caller in the render path;
  the only other `Sources/` use is a bounds check in
  `TerminalInteractionPolicy.swift`.
- Observation: whole-viewport work on a damage-scoped path, to obtain a field
  that is free at a traversal the planner already runs.
- Inference: `9/F2` measured this getter at 0.6-0.9% of plan on `content-churn`
  and **19.5-27.8% on `incremental-mixed`**; `14/F2` put it at 2.0% on live
  scroll. `17/F5` retired `9/H2` on the grounds that `8188b9a` made planning
  damage-scoped -- true of the planner, but `8188b9a` did not touch
  `terminal.geometry`, which is still built whole-viewport every frame. `17/F5`
  concedes as much in its own "what remains unmeasured" clause. So this is
  `9/H2`'s live remainder, not a re-proposal of retired work.
- Competing interpretations: none on the mechanism; the code is unambiguous. The
  open question is size, and it lands almost entirely in `incremental-mixed`,
  whose plan-time line carries no verdict (A/A SD 5.75%).
- Uncertainty: high confidence on the mechanism, high confidence that it is
  **unscoreable** by any calibrated rule this project owns. Absolute saving is
  roughly 5-16 us per frame.
- Next action: `T11`. When it lands, correct doc 9's Phase 5 note and `17/F5`.

### F5 -- a one-row scroll marks the entire scroll region damaged

- Status: verified by code-read.
- Commands, inputs, or reproduction: read
  `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#moveAndFillRows` and its
  `invalidateInspection(inViewportRows:)` call.
- Measurements or examples: shifting rows in place records damage over the whole
  shifted range. For an unrestricted scroll region that is every viewport row --
  66 at the canonical geometry, ~11,800 cells.
- Observation: the information content of the event is one new row plus a
  translation; the damage records 66 changed rows.
- Inference: every published frame during streaming output (`cat`, a build log,
  `tail -f`, any command producing lines) therefore re-plans, re-classifies,
  re-submits and lets Core Animation re-measure the whole screen's glyphs. This
  multiplies every other per-row cost in the planning and draw verticals, which
  is why `H3` ranks it above findings with larger local shares. `17/F6`'s
  off-main-thread per-glyph bounds cost scales with glyph occurrences submitted
  per second, so it is multiplied here too.
- Competing interpretations: `PaneFramePlanner`'s retained-row reuse may already
  absorb much of the *planning* half, since a translated row's runs could in
  principle be copied forward -- but they are copied forward only for rows the
  damage does not mark, and this marks all of them. The submission half is not
  absorbed at all. Untested either way.
- Uncertainty: high confidence on the code path, unmeasured amplification
  factor.
- Next action: `T5` measures the amplification; `T9` proposes the shift
  component. Note the damage-aware frame planning plan
  (`plans/impl/2026-07-27-1105-damage-aware-frame-planning.md`) lists shift
  damage as an explicit deferred non-goal, so this is a stated reopening, not an
  oversight being discovered.

### F6 -- on the shipped font no printable-ASCII ink escapes a cell upward, so one of the glyph halo's two extra rows is unnecessary

- Status: verified by direct probe. This is the survey's only measurement.
- Commands, inputs, or reproduction: a standalone `CTFontGetBoundingRectsForGlyphs`
  query over printable ASCII for the shipped faces at the canonical metrics. No
  app, no timing, no contention -- a static font query, so it is unaffected by
  the concurrent agents.
- Measurements or examples, `.AppleSystemUIFontMonospaced-Regular` 13 pt:
  - 2x scale: cell 31 px, baseline 26 px, ink 20.76 px above / 6.13 px below
    baseline; overshoot **above the cell -5.24 px (none)**, below **+1.13 px**.
  - 1x scale: cell 16 px, baseline 13 px, ink 10.38 / 3.07; overshoot above
    **-2.62 px (none)**, below **+0.07 px**.
  - Menlo 2x: -3.72 / +0.13. SF Mono 2x: -0.84 / +0.75. Monaco 2x: -4.33 /
    -3.08 (fully contained).
- Observation: `terminalDamageRowsWithGlyphHalo` expands every damaged row to
  three (`row-1`, `row`, `row+1`) unconditionally. `29/F6` records the
  consequence: 17 engine rows become **50 drawing rows**, and
  `incremental-mixed`'s 4 rows become 6.
- Inference: the exact requirement is asymmetric. `row-1` must be redrawn --
  its descenders spill into `row`. `row+1` must **not** be: its own ink begins
  5.24 px below its top edge, so extending the fill and clip band ~1.2 px into
  `row+1` is sufficient and no run of `row+1` need be planned or submitted. The
  halo becomes `2N` rows plus a sub-pixel band, derived rather than assumed --
  and this is what discharges `30/R3`'s double-blend objection instead of
  arguing around it.
- Competing interpretations: the probe covers printable ASCII on five faces. It
  does **not** cover the packaged Nerd Font symbols face at cell-width point
  size, the `CTLine` fallback path for non-BMP and multi-scalar cells, or the
  sprite families that `docs/terminal-sprites.md` says are *intentionally*
  overscanned (Powerline contacts cell edges by design). Any of those could
  escape upward.
- Uncertainty: high confidence for ASCII on the shipped font; medium that a
  general derivation stays simple once every contributing face is unioned in.
- Next action: `T14`, whose safe shape is a per-metrics
  `verticalInkOvershootRows(above:below:)` that falls back to today's full-row
  halo whenever any contributing face fails containment -- so the worst case is
  current behavior.

### F7 -- the style and hyperlink sweeps materialize the entire retained history as `GridRow`s

- Status: verified by code-read.
- Commands, inputs, or reproduction:
  `grep -rn "allPaintedDisplayRows" lib/TerminalCore/Sources/`.
- Measurements or examples: eight call sites. Two of them are the reclamation
  sweeps -- `Terminal.swift:1098` (`liveStyleIds`) and `:1769`
  (`liveHyperlinkIds`) -- each calling
  `LogicalLineStore.allPaintedDisplayRows()`, which per retained display row does
  one fold, one `[GridCell]` allocation, and a full `GridCell` materialization
  including scalars and both side-table probes.
- Observation: at a saturated arena that is tens of thousands of row
  allocations and millions of cell constructions, run synchronously on the
  PTY-drain thread, to collect a 4-byte field the arena already holds packed in
  each cell word.
- Inference: a latency spike rather than a throughput term -- `internStyle`
  sweeps on a doubling threshold, so the trigger is distinct-style count, which
  truecolor output reaches repeatedly. Docs 28 and 31 applied the
  borrow-don't-materialize split to the frame path (`28/F17`) and to equality
  (`31/F13`); this is the whole-history reader that never received it.
- Competing interpretations: the sweep must also cover the live grid, the
  inactive primary screen, and the *derived* cells the fold synthesizes (a
  trailing-fill style is a record header field; a derived spacer head inherits
  its head's style), so a word-scan replacement must be proven to reach all of
  them. That is a correctness obligation, not a competing interpretation of the
  cost.
- Uncertainty: high confidence the work is unnecessary; no calibrated workload
  contains the path, so the size is unknown. `28/F21` left `style-churn`'s
  +2.36% unexplained, which this could partly account for.
- Next action: `T16`, gated on an equality test that the word-walk live set
  equals the materialized one.

### F8 -- seven of nine app-runtime findings are invisible to every workload on the benchmark ladder

- Status: verified by inspection of the workload contracts.
- Commands, inputs, or reproduction: compare
  `agent-docs/terminal-performance.md`'s workload table against the app-runtime
  code paths.
- Measurements or examples: all six ladder workloads feed byte corpora into a
  terminal. None emits an application `Msg`, opens an IPC connection, triggers a
  checkpoint, or types a key. So no reconcile sweep, no projection, no snapshot
  encode and no key-monitor pass executes inside a measured block.
- Observation: any change to the reconcile sweep, container-shape derivation,
  checkpoint capture, MRU reconciliation, IPC encode, snapshot construction, or
  the key monitor will read `equivalent` on every workload.
- Inference: per the guide's own rule, that means "this workload does not
  contain the cost", **not** "the change did nothing". The one partially covered
  runtime item is per-frame scroll-chrome resynchronization, and its coverage is
  weak: it lands in `scrollback-stream`'s drain (~96% of that block, a
  throughput number wearing a draw metric's name) and in
  `processCPUNanosecondsPerDraw`, which is explicitly uncalibratable and carries
  no verdict. It is outside the `draw(_:)` bracket, so the draw verdict cannot
  see it at any size.
- Competing interpretations: these costs may be genuinely negligible at the pane
  and tab counts one user runs. That is a plausible outcome and the point is
  that nothing currently distinguishes it from the alternative.
- Uncertainty: none on the coverage gap; complete uncertainty on the magnitudes
  behind it.
- Next action: `T6` builds the per-`Msg` counter. Doc 21 hit this identical wall
  for pointer gestures and answered it with a purpose-built probe rather than a
  new calibrated workload, which then surfaced a 13.6 ms -> 5.5 us win no
  workload would have found. Build `T6` so it is capable of returning
  "negligible".

### F9 -- the parser's action array is real in an optimized build, and it allocates 60-80x the corpus's own byte count

- Status: verified by direct probe. `T1`.
- Date and investigator: 2026-08-06, T1 agent.
- Commit and worktree state: `9abf3383`, clean apart from untracked
  `scripts/research/` and an untracked plan file. Apple Swift 6.3.3,
  arm64-apple-macosx26.0.
- Commands, inputs, or reproduction:
  `python3 scripts/research/33/t1-action-array-size.py` (add `--json` for the
  raw report). The driver frames each committed corpus exactly as the
  `terminal-feed` workload does, then compiles
  `scripts/research/33/t1-action-array-probe.swift` with `swiftc -O` into one
  module together with the unmodified `lib/TerminalCore/Sources/TerminalCore`
  sources. That single-module build is how the probe reaches the internal
  `TerminalInputStream` without any edit to the engine.
- Result or artifact paths: the two script files above; the run writes nothing
  durable.
- Measurements or examples. `MemoryLayout<TerminalStreamAction>`: size 26,
  **stride 32**, reconfirming `F1` on this toolchain. `feed`'s array grows
  through the capacities `1, 2, 4, 9, 19, 39, 79, 159, 319, 639, 1535, 3071,
  6143, 12287, 24575, 49151, ...`, recorded by appending to a real
  `[TerminalStreamAction]`, not assumed from Swift's documented policy.

  At the corpora's own chunk framing, which is what `terminal-feed` feeds:

  | corpus | feeds | bytes | tokens | tok/byte | peak capacity | peak live | total allocated | reallocations |
  | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
  | `scrollback-stream` | 25,000 | 1,525,000 | 1,525,000 | **1.000** | 79 | 2.5 KB | 122.40 MB | 150,000 |
  | `styled-screen-redraw` | 3,501 | 5,211,504 | 4,399,501 | 0.844 | 1,535 | 48.0 KB | 314.16 MB | 35,000 |
  | `unicode-wrapping` | 9,000 | 1,521,000 | 1,314,000 | 0.864 | 159 | 5.0 KB | 89.86 MB | 63,000 |
  | `incremental-screen-updates` | 100,002 | 5,700,042 | 3,200,029 | 0.561 | 39 | 1.2 KB | 236.80 MB | 500,005 |
  | `synchronized-frames` | 96 | 3,020,580 | 934,889 | 0.310 | 49,151 | 1,536.0 KB | 62.28 MB | 1,071 |

  Re-chunking to the PTY host's 16 KiB turn limit changes only
  `synchronized-frames` (96 feeds become 248; peak capacity 49,151 -> 12,287,
  1,536 KB -> 384 KB; total allocated 62.28 -> 73.66 MB). Every other corpus is
  already framed below 16 KiB, so its numbers are unchanged.

  Fed single-shot -- the shape `terminal-memory-probe --chunk 0` uses -- the
  same corpora reach one array of **1,572,863 elements (48 MB live)** for
  `scrollback-stream` and **6,291,455 elements (192 MB live)** for
  `styled-screen-redraw`, at 20-22 reallocations and 100-403 MB total
  allocated.

  Token composition at corpus framing: `scrollback-stream` is 1,500,000
  `.print` plus 25,000 `.execute` and **zero** CSI; `incremental-screen-updates`
  is 2,500,025 `.print`, 100,000 `.execute`, 600,004 `.csi`.
- Observation: **275,355 of 275,355 feed calls returned an array whose live
  `capacity` matched the replayed growth table exactly** -- zero mismatches
  across all three chunkings. The array is not stack-promoted or elided in an
  `-O` build; it is allocated, grown, and returned at full capacity.
- Inference: the **T2 gate passes.** `scrollback-stream` produces exactly 1.000
  tokens per byte, and the two other plain-ish corpora sit at 0.86; the
  ASCII-run premise `T8` rests on is intact. The magnitude `F1` extrapolated is
  confirmed and is larger than it estimated per unit of input: at production
  delivery sizes the parser hands the allocator **60-80x the corpus's byte
  count** in total array bytes, and a single 16 KiB all-ASCII PTY turn costs 15
  allocations totalling 1.56 MB (48,881 elements x 32 B) to carry 16,384
  tokens. The reallocation count also says where the cost is not: it is
  dominated by feed count, not by array size, so `incremental-screen-updates`
  pays 500,005 reallocations across small arrays while `synchronized-frames`
  pays 1,071 across huge ones. Streaming the parser (`T7`) removes both shapes
  at once.
- Competing interpretations: the probe reads `capacity` on the returned array,
  which by itself forces the array to survive optimization in *this* binary.
  It therefore proves the array is materialized whenever a caller consumes it,
  which `Terminal.feed` does, but it is not a proof about `Terminal.feed`'s own
  optimized code. `15/F7`'s 37.2 MB of `MALLOC_LARGE (empty)` under
  `--chunk 0`, and the chunk-invariance of the census that sits beside it, are
  the independent evidence that it survives there too; the single-shot row
  above matches that shape in magnitude. Separately, "total allocated" counts
  every buffer handed to the allocator, and the freed ones are reused -- it is
  an allocator-traffic number, not a footprint.
- Uncertainty: none on the token counts, the stride, the growth capacities, or
  the peak capacities -- all are exact counts of a deterministic replay. No
  timing was taken and none is claimed. The share of `terminal-feed`'s wall
  clock this represents is still unmeasured.
- Next action: `T2` (per-printed-cell bookkeeping) is unblocked and its gate is
  met. `T7`/`T8` may proceed to the direction gate; `T7`'s script is this one,
  which must report zero allocations afterward.

### F10 -- every bookkeeping site in the print path runs exactly once per printed character, and ASCII runs are 8-45 characters long

- Status: verified by direct probe. `T2`. **The expected shape held exactly.**
- Date and investigator: 2026-08-06, T2 agent.
- Commit and worktree state: `94ef4c14`, clean apart from this task's untracked
  scripts and an untracked plan file. Apple Swift 6.3.3,
  arm64-apple-macosx26.0.
- Commands, inputs, or reproduction:
  `python3 scripts/research/33/t2-print-bookkeeping.py` (add `--json` for the
  raw report). The driver copies `lib/TerminalCore/Sources/TerminalCore` into a
  scratch directory, injects one counter increment at each named site, and
  compiles the copy with `swiftc -O` as one module together with the probe and
  the counter shim. **The engine in the repo is never edited.** Every injection
  is an exact-text anchor that must match exactly once, so a source change that
  moves a site fails the run rather than silently miscounting. The terminal is a
  fresh 179x66 per corpus and the framing is the corpus's own, which is what
  `measureFeedBatch` feeds for `terminal-feed`.
- Result or artifact paths: `scripts/research/33/t2-print-bookkeeping.py`,
  `t2-print-bookkeeping-probe.swift`, `t2-print-bookkeeping-counters.swift`. The
  run writes nothing durable.
- Measurements or examples. Call counts over the five committed corpora
  (`T2` said four; the corpus has five and all five were run):

  | corpus | bytes | prints | classify | invalidateInspection | rememberOpenCluster | searchMatchCache.invalidate | damageActionSnapshot | contentIdentity | currentStyleId |
  | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
  | `scrollback-stream` | 1,525,000 | 1,500,000 | 1,500,000 | 1,508,333 | 1,500,000 | 1,541,601 | 1,550,000 | 1,500,000 | 1,500,000 |
  | `styled-screen-redraw` | 5,211,504 | 4,189,500 | 4,189,500 | 4,294,566 | 4,189,500 | 4,294,566 | 4,403,002 | 4,189,500 | 4,189,500 |
  | `unicode-wrapping` | 1,521,000 | 1,305,000 | 1,305,000 | 1,366,070 | 1,305,000 | 1,382,397 | 1,323,000 | 1,269,000 | 1,269,322 |
  | `incremental-screen-updates` | 5,700,042 | 2,500,025 | 2,500,025 | 2,800,091 | 2,500,025 | 2,900,091 | 3,300,031 | 2,500,025 | 2,500,025 |
  | `synchronized-frames` | 3,020,580 | 762,108 | 762,108 | 762,108 | 762,108 | 762,109 | 934,985 | 762,108 | 762,108 |

  ASCII-run structure, cut exactly where `T8` says to cut -- at a non-ASCII
  scalar, a non-print action, row end (the pending-wrap latch), insert mode, and
  a wide-or-spacer cell about to be overwritten:

  | corpus | prints | runs | prints in runs | mean run | longest run | units after `T8` | factor | snapshots after `T8` | factor |
  | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
  | `scrollback-stream` | 1,500,000 | 33,332 | 1,491,667 | 44.8 | 60 | 41,665 | **36.0x** | 91,665 | 16.9x |
  | `styled-screen-redraw` | 4,189,500 | 129,500 | 4,168,500 | 32.2 | 52 | 150,500 | **27.8x** | 364,002 | 12.1x |
  | `unicode-wrapping` | 1,305,000 | 50,787 | 1,208,250 | 23.8 | 57 | 147,537 | **8.8x** | 165,537 | 8.0x |
  | `incremental-screen-updates` | 2,500,025 | 300,001 | 2,500,025 | 8.3 | 25 | 300,001 | **8.3x** | 1,100,007 | 3.0x |
  | `synchronized-frames` | 762,108 | 50,416 | 614,645 | 12.2 | 177 | 197,879 | **3.9x** | 370,756 | 2.5x |

  "Units after `T8`" is one per run plus one for every print no run can absorb.
  "Snapshots after `T8`" adds the non-print actions and the one snapshot `feed`
  carries in per call, both of which survive.
- Observation: the four per-character sites are exactly per-character.
  `terminalUnicodeClassification` and `rememberOpenCluster` equal the print count
  in **all five** corpora, to the unit. `invalidateInspection` reached from
  `printNarrow` plus `printWide` equals the *printed-cell* count in all five --
  `scrollback-stream` 1,500,000 + 0, `unicode-wrapping` 1,215,000 + 54,000 =
  1,269,000, which is exactly that corpus's `contentIdentity` count. Its other
  36,000 prints are scalars that joined an open cluster or had zero cell width,
  so they never occupied a new cell; the cluster-joining ones still reach
  `invalidateInspection` through `appendToOpenClusterIfJoined`.
  `contentIdentity` and `currentStyleId` are likewise one per printed cell;
  `unicode-wrapping`'s 1,269,322 exceeds its 1,269,000 by the 322 wide prints
  that hit the right-margin spacer branch, which reads the pen twice. The counts
  above the print count are the
  rest of the engine using the same funnels: `invalidateInspection` also runs for
  scrolls and erases, and `searchMatchCache.invalidate` sits in
  `notePrimaryHistoryDamage`, which every content mutation reaches.
- Observation, cross-check: `damageActionSnapshot` came out at exactly
  `tokens + feedCalls` and the snapshot diff at exactly `tokens`, for every
  corpus, against `F9`'s independently derived token counts (1,525,000 /
  4,399,501 / 1,314,000 / 3,200,029 / 934,889). Two probes built from different
  anchors agreeing to the unit is what licenses reading either.
- Inference: `T8`'s premise is confirmed and sized. On the streaming corpus the
  five per-character sites collapse **36x**; on the styled redraw **27.8x**; the
  worst corpus is `synchronized-frames` at 3.9x, because its content is not
  mostly long ASCII runs. `damageActionSnapshot` construction and its diff -- the
  largest single count in the table, since `feed` pays one per action -- fall
  2.5-16.9x, and that is the part `T7` and `T8` compound on: `T7` deletes the
  array the actions live in, `T8` deletes most of the actions.
- Inference, one site is already cheap: `currentStyleIdMisses` is **1** on
  `scrollback-stream`, `unicode-wrapping` and `incremental-screen-updates`, and
  38,500 / 62,868 on the two styled corpora. So `currentStyleId`'s per-character
  call is a cache hit almost always and `T8` should not claim an interning win
  from hoisting it -- only one fewer call.
- Competing interpretations: the run counts are what the *cut rules* produce, not
  what an implementation would necessarily achieve. A real `T8` may cut in more
  places -- an ASCII scalar that could join an open cluster, a scrolled-back
  viewport, a row-end fill -- and every extra cut lowers the factor. The rule
  here also assumes the run advances one column per print, which it checks
  directly (`column == previous + 1`), so a cursor move disguised as a print
  cannot inflate a run. In the other direction the factor is not an upper bound
  either: the mean run is capped by the corpora's line lengths (longest observed
  60 on `scrollback-stream` at 179 columns), so a wider pane or longer lines
  would raise it.
- Competing interpretations, the counters themselves: injecting increments
  perturbs inlining, so this build's *timing* means nothing and none is claimed.
  The counts are exact and the instrumentation only adds statements -- no engine
  branch is rewritten.
- Uncertainty: none on any count; all are exact tallies of a deterministic
  replay. No timing was taken. The share of `terminal-feed`'s wall clock that
  these sites represent is still unmeasured, and this finding does not predict
  one.
- Next action: `T8` is sized and may proceed to its direction gate; its
  before/after script is this one, which must show the five per-character
  counters fall to the "units after `T8`" column. `T3` (damage round trips) is
  the next Phase 1 counter and is unaffected by this result.
