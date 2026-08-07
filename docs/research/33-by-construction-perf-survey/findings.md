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

### F11 -- one row-damaged frame costs exactly 4 `Set` allocations, 3 array allocations and 386-721 hash operations, and a scroll skips the whole apparatus by escalating to `.full`

- Status: verified by direct probe. `T3`. **Two results, and the second is the
  larger one:** the round trips `F2` described are real and exactly sized, and
  the corpora that stream text never reach them at all, because every scroll
  publishes `.full`.
- Date and investigator: 2026-08-06, T3 agent.
- Commit and worktree state: `8d0ae09d`, clean apart from this task's untracked
  scripts and an untracked plan file. Apple Swift 6.3.3,
  arm64-apple-macosx26.0.
- Commands, inputs, or reproduction:
  `python3 scripts/research/33/t3-damage-round-trips.py` (add `--json` for the
  raw report). The driver copies `lib/TerminalCore/Sources/TerminalCore` **and**
  `.../TerminalRenderPlanning` into a scratch directory, strips the
  `import TerminalCore` lines so the two targets can compile as one module,
  injects one counter increment at each site on the damage path, and builds the
  copy with `swiftc -O` together with the probe. **The engine in the repo is
  never edited**, and every injection is an exact-text anchor that must match
  exactly once, so a source change that moves a site fails the run rather than
  silently miscounting -- the same discipline as `F10`.
- Result or artifact paths: `scripts/research/33/t3-damage-round-trips.py`,
  `t3-damage-round-trips-probe.swift`, `t3-damage-round-trips-counters.swift`.
  The run writes nothing durable.
- Method, and what "a published frame" means here: the three owners of the
  damage path do not share a module, so the probe restates the production
  sequence headlessly -- `TerminalPaneSession.consume` (drain, `formUnion` into
  `pendingDamage`), `planIfNeeded` (its three gates, `PaneFramePlanner`,
  publish), `SwiftTerminalSessionView.publish` (halo, `TerminalDamage(rows:)`,
  `formUnion` into `pendingDisplayDamage`, one `setNeedsDisplay` per haloed
  row), then `drawingDamage` + `spanClipRects`. Every gate production applies
  before publishing is applied, including the synchronized-output hold, so a
  suppressed publish accumulates damage exactly as it does live. One delivery is
  one drain and one publish attempt; one draw is modelled per publish. Two
  framings are run: the PTY host's 16 KiB read-turn cap, which is the live
  delivery size, and the corpus's own framing, which brackets the answer from
  the many-small-deliveries side. Terminal is a fresh 179x66 per corpus.
- Measurements, at the 16 KiB delivery cap (the production-shaped framing):

  | corpus | deliveries | frames | full-damage frames | held | rows/frame | sets/frame | arrays/frame | hashes/frame |
  | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
  | `scrollback-stream` | 94 | 94 | **94** | 0 | 66.0 | 0.00 | 0.00 | 0.0 |
  | `styled-screen-redraw` | 319 | 319 | 1 | 0 | 30.1 | 3.99 | 2.99 | 438.6 |
  | `unicode-wrapping` | 93 | 93 | **93** | 0 | 66.0 | 0.00 | 0.00 | 0.0 |
  | `incremental-screen-updates` | 348 | 348 | 1 | 0 | 23.1 | 3.99 | 2.99 | 384.9 |
  | `synchronized-frames` | 185 | 1 | 1 | 184 | 66.0 | 368.00 | 184.00 | 18058.0 |

  Per **row-damaged** frame -- the frames that actually pay -- the allocation
  count is invariant across every corpus and both framings: **exactly 4.0
  `Set<Int>` allocations and 3.0 array allocations**, never 3.9 or 4.1. The four
  sets are `drain()`'s, `TerminalDamage.init(rows:)`'s rebuild of it,
  `terminalDamageRowsWithGlyphHalo`'s, and `init(rows:)` again on the halo. The
  three arrays are the two `rows.filter { $0 >= 0 }` results and `sorted()`.

  | corpus (framing) | row-damaged frames | rows/frame | hashes/frame | drain inserts | init hashes | union hashes | halo inserts | planner lookups |
  | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
  | `styled-screen-redraw` (16 KiB) | 318 | 30.0 | **440.0** | 30 | 61 | 61 | 90 | 198 |
  | `incremental-screen-updates` (16 KiB) | 347 | 23.0 | **386.0** | 23 | 48 | 48 | 69 | 198 |
  | `scrollback-stream` (corpus) | 4,749 | 65.4 | **720.9** | 65 | 131 | 131 | 196 | 198 |
  | `unicode-wrapping` (corpus) | 277 | 58.0 | **662.6** | 58 | 116 | 116 | 175 | 198 |
  | `synchronized-frames` (corpus) | 95 | 50.8 | **607.7** | 51 | 103 | 103 | 152 | 198 |

  Span ordering, over every call the draw path made:

  | corpus (framing) | span calls | input already ascending | inversions | spans before halo | spans drawn |
  | --- | ---: | ---: | ---: | ---: | ---: |
  | `styled-screen-redraw` (16 KiB) | 318 | **0** | 4,922 | 1.00 | 1.00 |
  | `incremental-screen-updates` (16 KiB) | 347 | **0** | 4,514 | 1.00 | 1.00 |
  | `scrollback-stream` (corpus) | 4,749 | **2** | 151,667 | 1.00 | 1.00 |
  | `unicode-wrapping` (corpus) | 277 | **0** | 7,872 | 1.00 | 1.00 |
  | `synchronized-frames` (corpus) | 95 | **0** | 2,420 | 1.79 | 1.01 |

  Full-damage attribution, by call site:

  | corpus (framing) | full-damage calls | escalations | from `topRow`/screen change | from any other site |
  | --- | ---: | ---: | ---: | ---: |
  | `scrollback-stream` (16 KiB) | 23,873 | 93 | **23,873** | 0 |
  | `unicode-wrapping` (16 KiB) | 15,336 | 92 | **15,336** | 0 |
  | `scrollback-stream` (corpus) | 23,873 | 20,250 | **23,873** | 0 |
  | `unicode-wrapping` (corpus) | 15,315 | 8,722 | **15,315** | 0 |
  | `synchronized-frames` (corpus) | 2 | 0 | 1 | 1 |

  `styled-screen-redraw` and `incremental-screen-updates` record zero
  full-damage calls in either framing.
- Observation, the round trips are exactly what `F2` read: four sets, three
  arrays, and 386-721 hash operations per row-damaged frame, with the largest
  single contributor being the planner's **198 = 3 x 66** membership lookups.
  Three, not two: `damage.rows.contains(row)` is asked once by the traversal
  predicate in `inspectedCells`, a second time by the padding sweep below it
  (`for row in 0..<rowCount where replanning(row)`), and a third time by the
  row-copy loop in `plan(reusing:damage:)`. The probe counts the predicate
  (`plannerPredicateCalls`) and the loop (`plannerRowCopyLookups`) separately,
  and the split is exactly 2:1 in every corpus.
- Observation, the spans were **never** already sorted. Across 5,438 span calls
  at the 16 KiB cap and corpus framing combined, 0 to 2 found their input set
  already ascending, and the inversion count runs at roughly a third of adjacent
  pairs -- the order is random, not nearly-sorted. The count varies run to run
  (`scrollback-stream` corpus framing gave 1, 2, 2 already-ascending and
  145,775-164,580 inversions across four runs) because Swift seeds `Set` hashing
  per process; the conclusion does not vary. The drained set, before
  `init(rows:)` rebuilds it, is equally unordered: 22 of 25,000 for
  `scrollback-stream`.
- Observation, and this is the larger one: **at the live 16 KiB delivery size,
  `scrollback-stream` and `unicode-wrapping` publish `.full` on every single
  frame** -- 94 of 94 and 93 of 93 -- so the whole `Set` apparatus costs them
  literally zero and buys them nothing, because the entire viewport is redrawn.
  100% of that escalation comes from one branch: `recordDamage(from:to:)`'s
  `guard before.topRow == after.topRow`. Any scroll of the viewport window
  changes `topRow` and therefore escalates. At the corpora's own (61-byte)
  framing the same corpora still publish `.full` on 81% and 97% of frames.
- Observation, the spans are already trivial. Damage coalesces to **1.00 spans
  per frame** on four of five corpora *before* the halo runs, so the sort is
  recovering a single contiguous block. Only `synchronized-frames` has sparse
  damage (1.79 spans), and the halo collapses even that to 1.01.
- Inference, for `T20` (damage carries words end to end): the mechanism it
  deletes is confirmed and exactly sized -- 4 sets, 3 arrays, ~200-720 hashes
  per row-damaged frame, plus the `filter { $0 >= 0 }` sanitizer and the
  `sorted()`, which this finding shows is never a no-op. But the sizing also
  confirms `F2`'s own uncertainty and `30/D2`'s rejection on the numbers: this
  is a few hundred hash operations on a bounded-by-66 set, and the corpus where
  the app spends its time does not execute it at all. So `T20` stays a
  **complexity** claim under `D1` and stays sequenced as a rider on `T9`/`T14`.
  Nothing here licenses a speed claim, and none is made.
- Inference, for `T9` (shift damage) and `T5`: `F5` said a one-row scroll marks
  the whole scroll region damaged. It is stronger than that -- a scroll does not
  mark 66 rows, it publishes `.full`, which also refuses `PaneFramePlanner`'s row
  reuse (`reusable` is `nil` whenever `damage.isFull`), so the planner replans
  every row *and* the drawer redraws every row. On the streaming corpus that is
  every frame at production delivery size. `T9` is therefore the task this
  finding most strongly supports, and `T5` should measure the same escalation
  with a synthetic scroll rather than assume row damage.
- Inference, for `T4`/`T10` (publish rate): at the 16 KiB delivery cap the
  corpora publish 94 to 348 frames for 1.5-5.7 MB, so the per-frame costs above
  are multiplied by delivery count, not by byte count. `synchronized-frames` is
  the extreme case in the other direction: 184 of 185 deliveries are held by the
  synchronized-output guard and the single surviving publish carries 368 set
  allocations' worth of accumulated round trips. Bounding publish rate moves
  every number in the first table down proportionally.
- Competing interpretations: the "one draw per publish" model is an upper bound
  on `spanCalls`; a real display-rate-limited consumer draws less often, which
  lowers the span count and raises the row count each surviving call sorts.
  Every other counter sits on the publish side and is unaffected. Separately,
  the corpus-framing run inflates frame count relative to production (61-byte
  deliveries), which is why the 16 KiB run is quoted first -- but it is the
  framing `terminal-feed` measures, so both are reported. Finally, the probe
  reconstructs the app-side stages rather than running `SwiftTerminalSessionView`
  itself, which no headless build can do; the reconstruction is line-for-line
  against the two functions and any drift in them is not detected by an anchor
  check, unlike the engine-side injections.
- Competing interpretations, the counters themselves: injecting increments
  perturbs inlining, so this build's *timing* means nothing and none is claimed.
  The counts are exact and the instrumentation only adds statements.
- Uncertainty: none on the allocation, hash, damaged-row or escalation counts --
  all are exact tallies of a deterministic replay, and the 4.0/3.0 allocations
  per row-damaged frame are invariant across ten corpus-framing pairs. The
  already-ascending and inversion counts are the one nondeterministic pair, for
  the per-process hash seed reason above, and the range across four runs is
  recorded. No timing was taken.
- Next action: `T20`'s disposition is settled as "complexity claim, rider on
  `T9`/`T14`" and `D2` should record this sizing. `T5` is unblocked and should
  be scoped to confirm the `.full` escalation with a synthetic scroll. `T9` gains
  the strongest single piece of evidence in Phase 1: at production delivery size
  the streaming corpora have no row damage at all, only whole-screen redraws.

### F12 -- a live pane publishes 594 frames per second against 120 draws, a 4.96:1 ratio that reproduces to 0.2%

- Status: verified by direct measurement in a running app. `T4`. `H2`'s
  mechanism is confirmed live: the ratio is not near 1:1, so `T10` survives its
  gate. Two secondary results are method-critical and are recorded because they
  each would have produced the opposite verdict: a **debug** build reads 1.07:1,
  and an **occluded** pane publishes nothing at all.
- Date and investigator: 2026-08-06, T4 agent.
- Commit and worktree state: `144d3054` plus this task's own changes -- the
  sampler (`app/TerminalFrameRateSampler.swift`), its two call sites in
  `SwiftTerminalSessionView`, and the launcher allowlist entry. Apple Swift
  6.3.3, arm64-apple-macosx26.0, 179x66 pane, 120 Hz display.
- Commands, inputs, or reproduction:
  `scripts/research/33/t4-publish-rate.sh --seconds 15 --megabytes 96`
  (add `--debug-build` for the debug-configuration comparison). The script
  builds a 114 MB corpus by repeating every `.swift` file under `lib/`, launches
  an isolated development slot with `DANTERM_FRAME_RATE_LOG` set, activates that
  slot's window, runs a real `cat` of the corpus in the pane through
  `danterm --socket ... pane input`, samples for 15 s, sends `C-c`, and hands
  the front back to the app that held it.
- Result or artifact paths: `scripts/research/33/t4-publish-rate.sh`. The run
  writes only into its own scratch directory.
- What the instrument counts: one line of JSON per pane per elapsed second,
  written from inside `publish(_ frame:)` and `draw(_:)` themselves -- no timer,
  no polling, and nothing at all unless the environment variable names a file.
  `deliveries` is the delta of `TerminalPaneSessionController.fenceMetrics`
  `.delivery.count`, the existing metric doc 25's `T3` asked for a surface on,
  and it counts `consumeHostUpdate` calls. `publishes` counts frames that reach
  the view. `draws` counts `draw(_:)` entries, which AppKit may split per
  dirty rect, so it is an upper bound on display passes.
- Measurements, release configuration, steady state (every window after the
  settle window, which holds only shell startup):

  | run | seconds | deliveries/s | publishes/s | draws/s | publishes per draw |
  | --- | ---: | ---: | ---: | ---: | ---: |
  | 1 | 12.009 | 594.8 | **594.6** | **119.8** | **4.96** |
  | 2 | 12.008 | 593.9 | **593.9** | **119.8** | **4.96** |

  Per-second windows are flat, not bursty: publishes alternate between roughly
  565 and 635 every second while draws hold 118-121, so the ratio is stable
  within each window and not an artifact of averaging.

  Whole-log figures including the 3.3 s settle window, which is what the
  script prints: 466.8 / 463.9 publishes/s, 94.2 / 93.7 draws/s, 4.96 / 4.95.

- Measurements, debug configuration, same script and same corpus:

  | | seconds | deliveries/s | publishes/s | draws/s | publishes per draw |
  | --- | ---: | ---: | ---: | ---: | ---: |
  | debug | 15.571 | 16.7 | **16.6** | **15.5** | **1.07** |

- Observation, the answer `T4` asked for: a real `cat` in a real pane publishes
  **594 frames per second** and draws **120**, and the second run reproduces
  both to within 0.2%. Deliveries and publishes are the same number to within
  two frames across a 7,000-frame run, so essentially every 16 KiB read turn
  becomes a published frame -- the coalescing that exists is between publish and
  draw, not between delivery and publish.
- Observation, the debug build cannot see this mechanism. In debug the same
  workload runs the whole pipeline at ~16 Hz and reads **1.07 publishes per
  draw**, which is exactly the "near 1:1" reading the ledger named as the
  condition for closing `T10`. The cause is that per-frame cost, not delivery
  rate, is the binding constraint in an unoptimized build: the child is
  flow-controlled by how fast the app drains the PTY, so a slower app produces
  a slower child and the ratio collapses. Any future publish-rate reading must
  be taken in release configuration, which is why the script defaults to it.
- Observation, an occluded pane publishes nothing. The first attempt logged zero
  samples: `just launch-slot` leaves the slot in the background, the window was
  fully covered, and `syncPaneVisibility` therefore held every pane hidden, so
  `planIfNeeded` never ran and neither `publish` nor `draw` was ever called
  while the PTY streamed normally. This is `25/F2` observed from the other side
  and it is why the script activates the slot window for the sampling interval.
  The slot still launches with `--background`, which is the flag that refuses
  the notification prompt, so activating it afterwards raises none.
- Inference, for `T10` (bound publish rate by consumer demand): **the gate
  passes and `T10` stays open.** The live ratio is 4.96:1, not 1:1. Five of
  every six published frames are overwritten before any of them reaches a
  display pass, so the plan, the copy-on-write, the damage set construction and
  the delivery fence for those five are work whose result is discarded. Bounding
  publish rate to the display rate would remove roughly 475 of the 594 publishes
  per second.
- Inference, `H2` is confirmed but its stated size is corrected. `H2` predicted
  "near 8:1" from `23/F5`'s 470 publishes/s in a benchmark block. Live, the
  publish rate is *higher* than `23/F5`'s -- 594/s -- but so is the draw rate,
  because the display runs at 120 Hz, so the multiplier is **4.96x, not 8x**.
  The direction is confirmed and the magnitude is now measured rather than
  inferred; any `T10` claim should be written against 4.96x.
- Inference, for `F11`: `F11` measured 94 published frames for `scrollback-stream`
  at the 16 KiB delivery cap and inferred that per-frame costs multiply by
  delivery count. This finding supplies the live multiplier for that inference:
  at 594 deliveries/s each one is a full delivery fence, and `F11` showed the
  streaming corpora publish `.full` damage on every one of them.
- Competing interpretations: the `draws` counter is an upper bound on display
  passes, because AppKit may call `draw(_:)` more than once per pass for
  disjoint dirty rects. If it does so here, the true display-pass count is lower
  and the ratio is *larger* than 4.96, so the verdict is unaffected in the only
  direction that matters. In the other direction, the publish rate is set by how
  fast the child can be drained, so a faster machine or a wider pane would move
  the absolute numbers; the ratio against a fixed 120 Hz display is the stable
  quantity. Finally, `cat` of a file is the fastest producer a pane sees; an
  interactive program that writes a screen at a time will not reach 594
  publishes/s, so this is the top of the range, not a typical rate.
- Uncertainty: none on the counts, which are exact tallies. The window
  boundaries are wall-clock and the samples are emitted from the next publish or
  draw after a second elapses, so `windowSeconds` is 1.000-1.002 in release and
  up to 1.06 in debug; the per-second rates divide by the measured window, not
  by a nominal 1.0. No CPU time and no energy was measured, and no claim about
  either is made here.
- Next action: `T10` is unblocked with its multiplier measured at 4.96x and may
  proceed to its `decisions.md` entry. This script is `T10`'s before/after gate:
  after the change, `publishesPerSecond` must fall to the display rate while
  `drawsPerSecond` holds, and `cumulativeFenceStallNanoseconds` must fall by
  roughly the same factor. The sampler it added is the in-app sampling surface doc
  25's `T3` asked for; that task also wants visibility tagging and a hidden
  flood, so it is unblocked rather than closed.

### F13 -- a one-line scroll damages 66 rows and submits 11,570 glyph occurrences to express 2 changed rows and 178 changed cells

- Status: verified by direct probe. `T5`. A confirmation, as `F11` predicted, and
  it supplies the two amplification factors `T9` is written against: **66x on
  rows and 65x on glyph occurrences** at one line per delivery, decaying to 1x
  once a delivery carries a whole screen.
- Date and investigator: 2026-08-06, T5 agent.
- Commit and worktree state: `5e0ad1dc`, clean apart from this task's untracked
  scripts and an untracked plan file. Apple Swift 6.3.3,
  arm64-apple-macosx26.0.
- Commands, inputs, or reproduction:
  `python3 scripts/research/33/t5-scroll-amplification.py` (add `--json` for the
  raw report, `--events N` to change the run length; the table below is the
  default 600 events). The driver reuses `F11`'s harness technique: it copies
  `lib/TerminalCore/Sources/TerminalCore` **and** `.../TerminalRenderPlanning`
  into a scratch directory, strips the `import TerminalCore` lines so the two
  targets compile as one module, injects one counter increment at each site, and
  builds the copy with `swiftc -O` together with the probe. **The engine in the
  repo is never edited**, and every injection is an exact-text anchor that must
  match exactly once, so a source change that moves a site fails the run rather
  than silently miscounting.
- Result or artifact paths: `scripts/research/33/t5-scroll-amplification.py`,
  `t5-scroll-amplification-probe.swift`,
  `t5-scroll-amplification-counters.swift`. The run writes nothing durable.
- Method, and how the *ideal* is measured rather than assumed: the probe fills a
  179x66 grid with text, plans one frame so the planner holds a retained
  generation exactly as it does mid-stream, resets the counters, and then feeds
  the stimulus. Each delivery runs the production sequence headlessly, gate for
  gate, the same way `F11`'s probe does -- `TerminalPaneSession.consume` and
  `planIfNeeded`, then `SwiftTerminalSessionView.publish`'s halo and its draw's
  `clipFramePlan`, at one draw per publish. Before and after every delivery the
  probe snapshots all 66 viewport rows cell by cell (scalars and style) together
  with `scrollProjection.topRow`. A row counts as *ideally* damaged only when its
  content differs from the row that translated into its place across
  `afterTop - beforeTop` -- which is precisely the damage a shift-carrying
  representation would publish. So the denominator of every amplification below
  is measured on the same run as its numerator, not declared.
- Method, the three stimuli. `bare-newline` is a lone `LF` at the bottom of a
  full screen: the minimum-information scroll, one translation and one blank row.
  `text-line` is 178 characters and `CR LF`, which is what streaming output
  actually emits and the only stimulus whose screen stays full. And
  `rewrite-bottom-row` is `CR` and 178 characters -- **the control**: the same
  cell count changed, on a viewport that does not move. It is reachable by the
  same code, so it separates "a scroll is expensive" from "this workload is
  expensive". Three delivery sizes are run: 1 line (the worst case), 8, and 91,
  which is the PTY host's 16 KiB read turn at this line width.
- Measurements, 600 events per scenario, deterministic across two full runs:

  | scenario | lines/delivery | frames | `.full` frames | rows/frame | ideal rows/frame | row amp | glyphs/frame | ideal glyphs/frame | glyph amp |
  | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
  | `bare-newline` | 1 | 600 | **600** | 66.0 | 1.0 | **66.0x** | 636 | 0 | n/a |
  | `text-line` | 1 | 600 | **600** | 66.0 | 2.0 | **33.0x** | **11,570** | **178** | **65.0x** |
  | `rewrite-bottom-row` | 1 | 600 | 0 | 1.0 | 1.0 | 1.0x | 356 | 178 | 2.0x |
  | `bare-newline` | 8 | 75 | **75** | 66.0 | 8.0 | 8.2x | 570 | 0 | n/a |
  | `text-line` | 8 | 75 | **75** | 66.0 | 9.0 | 7.3x | 11,570 | 1,424 | 8.1x |
  | `rewrite-bottom-row` | 8 | 75 | 0 | 1.0 | 1.0 | 1.0x | 356 | 178 | 2.0x |
  | `bare-newline` | 91 | 7 | **7** | 66.0 | 64.3 | 1.0x | 0 | 0 | n/a |
  | `text-line` | 91 | 7 | **7** | 66.0 | 64.4 | 1.0x | 11,570 | 11,290 | 1.0x |
  | `rewrite-bottom-row` | 91 | 7 | 0 | 1.0 | 1.0 | 1.0x | 356 | 178 | 2.0x |

  Escalation attribution and the planning half:

  | scenario | lines/delivery | scrolling deliveries | full-damage calls | escalations | from `topRow`/screen | any other site | drain inserts | planner rows/frame | planner cells/frame |
  | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
  | `bare-newline` | 1 | 600 | 600 | 600 | **600** | 0 | **0** | 66.0 | 11,814 |
  | `text-line` | 1 | 600 | 600 | 600 | **600** | 0 | **0** | 66.0 | 11,814 |
  | `rewrite-bottom-row` | 1 | 0 | 0 | 0 | 0 | 0 | 600 | **1.0** | **179** |
  | `text-line` | 8 | 75 | 600 | 75 | 600 | 0 | **0** | 66.0 | 11,814 |
  | `text-line` | 91 | 7 | 600 | 7 | 600 | 0 | **0** | 66.0 | 11,814 |

- Observation, `F5`'s code path is confirmed and `F11`'s correction to it holds
  under a synthetic scroll: a scroll never produces row damage at all. Every one
  of the 600 scroll events calls `recordPresentationFullDamage`, 100% of them
  through `recordDamage(from:to:)`'s `topRow`/screen guard and 0% through any
  other site, and the damage accumulator's `drain()` inserts **zero** rows across
  the entire run. The `.full` frame count equals the published frame count in
  every scrolling scenario and every delivery size.
- Observation, the amplification has two halves and both are total. The planner
  re-inspects **66.0 rows and 11,814 cells per frame** -- the whole grid, since
  `reusable` is `nil` whenever `damage.isFull` -- and the drawer receives
  **11,570 glyph occurrences**, which is 65 full rows of 178 characters, the
  entire screen's text. The information content of that frame is 2 changed rows
  and 178 changed cells.
- Observation, the control separates the scroll from the workload. The same 178
  cells rewritten without moving the viewport damage **1 row**, re-inspect **1
  row and 179 cells**, and submit **356 glyph occurrences** -- 2 rows, because
  the glyph halo adds `row-1` and `row+1` and `row+1` is off the grid. So the
  row-scoped path works exactly as designed and delivers a 66x smaller frame; a
  scroll is what disables it. That 2.0x residue on the control is `F6`'s halo,
  and it is the ceiling `T14` is aiming at, not something `T9` can remove.
- Observation, the amplification is a function of delivery size and vanishes at
  the top of the range. At 91 lines per delivery -- one 16 KiB read turn -- the
  whole screen genuinely did change, ideal rows reach 64.4 of 66, and the
  amplification is 1.0x on both rows and glyphs. This is the honest bound on
  `T9`: shift damage wins nothing on a delivery that scrolls the screen more than
  once, and it wins 33-66x on a delivery that scrolls it once. `F12` measured 594
  publishes per second live, so the live regime is many small deliveries, not few
  large ones -- but the exact live lines-per-delivery figure is not measured here
  and is the one number that would place production on this curve.
- Inference, for `T9` (shift damage): the gate passes with the largest margin in
  Phase 1. At one line per delivery the frame is 33x wider than its content in
  rows and **65x wider in glyph occurrences**, and `17/F6` puts the
  off-main-thread per-glyph bounds cost in proportion to glyph occurrences
  submitted -- so this is the multiplier on the draw vertical, measured. `T9`'s
  stated verification ("damaged rows per scroll fall to O(1)") is now
  operational: this script's `ideal rows/frame` column is the target, and after
  the change `rows/frame` must equal it. The `bare-newline` row at one line per
  delivery is the cleanest statement of the target: **66 damaged rows to express
  1**.
- Inference, for `T20`: unchanged and reinforced. The scrolling scenarios put
  **zero** rows through the damage `Set` -- 0 drain inserts across 1,800 frames
  -- so nothing on the damage-representation path is on the streaming hot path
  today, and `T20` stays a complexity claim riding on `T9`, exactly as `F11`
  concluded. What `T9` changes is that a shifted frame *would* carry rows, which
  is when the word representation starts to matter.
- Competing interpretations: `F5`'s uncertainty asked whether
  `PaneFramePlanner`'s retained-row reuse already absorbs the planning half. It
  does not, and the planner counters settle it directly -- 11,814 cells
  re-inspected per scrolling frame against 179 on the control. Separately, the
  "one draw per publish" model is an upper bound on draw count; a
  display-rate-limited consumer draws less often, which would lower total
  submitted glyphs but not the per-frame ratio, since a coalesced `.full` frame
  still submits the whole screen. Finally, the ideal is content-based and ignores
  the cursor: a shift-carrying representation must still damage the rows the
  cursor left and entered, so the true ideal is at most two rows above the number
  in the table -- which lowers the 66x toward 22x in the worst case and leaves
  the 65x glyph figure untouched, because a cursor row's glyphs are already
  counted when its content changed.
- Competing interpretations, the counters themselves: injecting increments
  perturbs inlining, so this build's *timing* means nothing and none is claimed.
  The counts are exact and the instrumentation only adds statements.
- Uncertainty: none on the counts -- every number is an exact tally of a
  deterministic replay, and two full 600-event runs produced byte-identical
  output. The `bare-newline` glyph column is the one figure that is not a steady
  state: a screen fed only newlines empties, so its submitted-glyph average falls
  with run length (636/frame at 600 events, 1,273 at 300) and its ideal is 0 by
  construction. That is why `text-line` carries the glyph claim and
  `bare-newline` carries only the row claim. No timing and no benchmark was run;
  `31/F18` makes a ladder verdict on a corpus that cannot contain this mechanism
  worthless, and the mechanism here is a synthetic stimulus, not a corpus.
- Next action: `T9`'s Phase 1 gate is passed and it may proceed to its
  `decisions.md` entry. This script is its before/after gate: after the change,
  `rows/frame` must equal `ideal rows/frame` and `glyphs/frame` must approach
  `ideal glyphs/frame` plus the halo, at every delivery size, with the
  `rewrite-bottom-row` control unmoved at 1.0 rows and 356 glyphs. The one
  measurement worth taking before `T9` starts is live lines-per-delivery, which
  places production on the 1-to-91 curve above and therefore sets the win's real
  size.
