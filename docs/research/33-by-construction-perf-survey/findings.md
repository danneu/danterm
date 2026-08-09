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

### F14 -- every `Msg` pays the whole model, and at the sizes one user runs the whole model costs 61 us

- Status: verified by direct probe. `T6`. **The instrument returns the outcome
  `H4` said it must be built to be capable of returning:** the reconcile sweep is
  totally unscoped -- a message naming one pane visits every pane four times,
  rebuilds every tab's container shape, and runs all twelve projections,
  identically for seven different messages -- and at 3 tabs that entire sweep
  costs **61 us**, which is **0.08% of one core** at the 75 ms coalescing rate.
  The mismatch is real, exact, and small.
- Date and investigator: 2026-08-06, T6 agent.
- Commit and worktree state: `e9948475`, clean apart from this task's untracked
  scripts and an untracked plan file. Apple Swift 6.3.3,
  arm64-apple-macosx26.0.
- Commands, inputs, or reproduction:
  `python3 scripts/research/33/t6-msg-work.py` (add `--json` for the raw report,
  `--iterations N` to change the timed run length; the tables below are the
  default 2,000 and the whole run takes roughly 15 minutes). The driver copies
  `lib/DanTermCore/Sources/DanTermCore` **and**
  `lib/DanTermProtocol/Sources/DanTermProtocol` into a scratch directory, strips
  the `import DanTermProtocol` lines so the two targets compile as one module,
  and builds that copy with `swiftc -O` together with the probe. **The core in
  the repo is never edited**, and every injection is an exact-text anchor that
  must match exactly once, so a source change that moves a site fails the run
  rather than silently miscounting -- the same discipline as `F10`, `F11` and
  `F13`.
- Method, and why there are two binaries: injecting counter increments perturbs
  inlining, so a timing taken from the instrumented build would mean nothing.
  The driver therefore builds the probe **twice** against the same staged
  sources -- once instrumented, for the counts, and once with no injection at
  all, for the wall clock -- and joins the two on (layout, message). Every count
  below comes from the first build and every microsecond from the second.
- Method, and what "the sweep" means here: `AppRuntime.reconcile()` lives in
  `app/`, which is AppKit and cannot build headlessly. Its passes split cleanly
  into a pure projection and a thin executor, so the probe runs every pure half
  in `reconcile()`'s own order against the same `ReconcilerCaches` discipline
  (each pass diffs against the value it last applied), then measures one
  `update()` plus one sweep. Caches are primed with two sweeps before the
  measured message, because an unprimed cache makes every pass *apply*, which is
  a first-frame cost rather than the steady state a shell's next title update
  lands in. **Not measured, and not claimed:** the AppKit executors themselves,
  `syncPaneVisibility`, and the three popover projections, which return nil while
  their popover is closed and so are not called in the steady state.
- Result or artifact paths: `scripts/research/33/t6-msg-work.py`,
  `t6-msg-work-probe.swift`, `t6-msg-work-counters.swift`. The run writes nothing
  durable.
- Measurements, per single `Msg` (`update()` plus one sweep), over four layouts.
  The first two are what one user runs; the last two exist only so the shape of
  the growth is visible.

  | layout | tabs | panes | panes visited | `allPanes` walks | projection calls | `containerShapeNode`s | `liveTabIds` sets | us/msg | us/update |
  | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
  | `3-tabs` | 3 | 3 | **13** | **4** | **12** | 3 | **1** | **61.5** | 3.0 |
  | `8-tabs-2-panes` | 8 | 16 | **66** | **4** | **12** | 24 | **1** | **169.4** | 5.9 |
  | `24-tabs-4-panes` | 24 | 96 | **388** | **4** | **12** | 168 | **1** | **739.0** | 16.6 |
  | `60-tabs-8-panes` | 60 | 480 | **1,928** | **4** | **12** | 900 | **1** | **3,076.5** | 36.2 |

  Every row above is `sessionTitle`. **Six other messages produce byte-identical
  counters** -- `sessionCwd`, `sessionProgress`, `paneBecameFirstResponder`,
  `splitRatioChanged`, `selectTab`, and (on the sweep half) `sessionBell` -- and
  their timings agree to within 1.5%, except `sessionBell` and `selectTab`, whose
  *`update()`* halves differ and whose sweeps do not.

  What the sweep rebuilds from scratch every time, at 60 tabs / 480 panes:
  **3,615 `[PaneModel]` array allocations** carrying 1,928 pane copies, **1,440
  per-pane dictionary entries** across the three `allPanes`-keyed projections,
  **900 `ContainerShapeNode` allocations** (the entire split forest), **900**
  `sumUnread` node visits, and **500** `paneInNode` walks.

  The one message whose `update()` half is not flat is `sessionBell`, and the
  cause is in `update()`, not the sweep: `tabForPane` walks every tab building an
  `allPaneIds` array per tab, so its `allPaneIdsNodeCalls` go 3 / 24 / 168 / 900
  against **0** for every other message, and its update time goes 8.7 / 15.9 /
  52.9 / **198.0 us**.

- Measurements, per pure projection, computed alone over the same primed model:

  | projection | 3 tabs / 3 panes | 8 / 16 | 24 / 96 | 60 / 480 |
  | --- | ---: | ---: | ---: | ---: |
  | `desiredSidebar` | **17.62** | **47.07** | **143.34** | 362.20 |
  | `desiredWindowChrome` | **11.85** | 12.43 | 13.34 | 15.03 |
  | `desiredFocusBorders` | 2.08 | 10.77 | 67.10 | **384.47** |
  | `sessionsToTearDown` | 1.95 | 9.17 | 62.10 | 312.33 |
  | `desiredPaneConfig` | 1.69 | 10.41 | 59.74 | 333.86 |
  | `desiredPaneToolbar` | 1.66 | 9.94 | 60.70 | 343.73 |
  | `desiredContainerShapes` | 1.20 | 4.78 | 21.05 | 94.08 |
  | `unreadAlertTally` | 0.99 | 3.54 | 12.77 | 46.36 |
  | `desiredThemeBrowser` | 0.47 | 0.51 | 0.55 | 0.59 |
  | `desiredSearchOverlays` | 0.05 | 0.05 | 0.05 | 0.05 |
  | `desiredPreferencesPanel` / `desiredSwitcher` / `desiredQuitConfirmation` | 0.02 | 0.02 | 0.02 | 0.02 |

- Observation, the mismatch is total and exactly stated. `allPanesWalks` is
  **4** and `projectionCalls` is **12** in every layout and for every message,
  including `splitRatioChanged`, whose sweep is an empty diff by construction
  because `ContainerShape` drops ratios. The sweep's inputs vary at the
  granularity of one pane; its work is at the granularity of the whole model,
  and it does not vary with the message at all. This is
  `agent-docs/perf-granularity-mismatch.md`'s shape in its purest form -- there
  is no cache to hide it and no fast path, only a fixed whole-model pass.
- Observation, `liveTabIds` is **1 per message, not N**. The ledger listed it
  beside the per-pane quantities; it is built exactly once, in `update()`'s
  `defer` (`reconcileMru`), and no projection builds another. Its insert count
  equals the tab count, so it is O(tabs) once, and it does not multiply.
- Observation, the tab-chrome derivation is the constant nobody would predict
  from a code read. `TabModel.title`, `displayTitle` and `subtitle` are three
  computed properties over one *private, uncached* `derivedChrome`, and
  `derivedChrome` costs a `paneInNode` tree walk plus `deriveTabChrome`, which
  calls `abbreviateHome` twice -- and `abbreviateHome`'s default argument is an
  `NSHomeDirectory()` call. The counters put it at **2 derivations per tab plus
  4 for the selected tab** (10 / 20 / 52 / 124) and exactly **twice that many**
  `abbreviateHome` calls. That is why `desiredWindowChrome`, which reads only the
  selected tab, costs 11.85 us at three tabs and barely moves at 480 panes: it is
  a fixed four derivations. At the realistic size, `desiredSidebar` plus
  `desiredWindowChrome` is **29.5 us of the 58.5 us sweep** -- half the sweep is
  tab chrome being re-derived.
- Observation, the absolute cost. `Msg.coalescesReconcile` throttles the
  shell-driven trio to about 75 ms, so a pane flooding title, cwd and progress
  updates costs at most ~13.3 sweeps per second:

  | layout | us/msg | ms of CPU per second at 13.3 Hz | share of one core |
  | --- | ---: | ---: | ---: |
  | 3 tabs / 3 panes | 61.5 | 0.82 | **0.08%** |
  | 8 tabs / 16 panes | 169.4 | 2.26 | **0.23%** |
  | 24 tabs / 96 panes | 739.0 | 9.85 | **0.99%** |
  | 60 tabs / 480 panes | 3,076.5 | 41.0 | **4.10%** |

  The uncoalesced messages (`selectTab`, `paneBecameFirstResponder`) reconcile
  inline, but they are human-paced -- a few per second at the very most -- so
  their contribution is smaller still.
- Inference, for `T23` (scope the reconcile sweep): **the mechanism is
  confirmed and the justification for it as a speed task is not.** `T23`'s
  premise -- "every sweep rebuilds the whole model's view state for an event that
  named one pane, up to 13 Hz, and boxes a fresh `ContainerShape` tree per tab to
  compare it" -- is exactly right, and the counters state it to the unit. But the
  reconciliation ADR's `Projection Scan Cost` section already anticipated this
  and set the bar: it accepted the rebuild *because* the coalescing policy holds
  the rate at ~13 Hz, and it wrote that the alert tally was added "only after the
  hot path had a concrete high-pane/high-tab report" and that the same bar
  applies "especially [to] `allPanes`". This probe is the measurement that bar
  asks for, and it does **not** clear it: 0.08% of a core at the size one user
  runs, and under 1% at 24 tabs and 96 panes. `T23` should therefore be closed as
  a speed task and, if it is kept at all, kept only as a complexity claim under
  `D1`, ranked below every item in this doc that has measured evidence. It must
  not be pitched with a percentage, because the honest percentage is 0.08.
- Inference, for `H4`: **its competing explanation wins, for this item.** `H4`
  said the runtime findings are unmeasured rather than small, and that "these
  costs may be genuinely negligible at the pane and tab counts one user runs, and
  the instrument would prove it. That is a perfectly good outcome and the probe
  should be built to be capable of returning it." The probe was, and it did. The
  first half of `H4` also stands: nothing on the ladder could have produced any
  of these numbers, and the coverage gap `F8` recorded is real. Doc 21's
  precedent held in method and not in result -- the same purpose-built-probe
  answer to the same wall, but where `21` found a 13.6 ms gesture, this finds a
  61 us message.
- Inference, one cheap candidate the counters did surface. Memoizing
  `TabModel.derivedChrome` (or having `desiredSidebar` and `desiredWindowChrome`
  read it once per tab instead of two to four times) removes half the sweep at
  the realistic size, and it is not `T23` -- it is a hoist inside two
  projections, with no change to the sweep's scoping and no context bag. The
  `NSHomeDirectory()` in `abbreviateHome`'s default argument is a second, even
  smaller one. Neither is worth a percentage claim either; both are recorded so
  the next agent does not have to re-derive them. `sessionBell`'s `tabForPane`
  scan is a third, and it is the only one whose growth is in `update()`.
- Competing interpretations: the sweep is a restatement, not the app's own
  `reconcile()`. It runs the pure half of every pass in order against the same
  cache discipline, but a drift in `app/Reconcile.swift` is not detected by an
  anchor check the way the engine-side injections are -- the same limitation
  `F11` records for its restatement of the publish path. It is also an
  **underestimate** in one direction and an overestimate in another: it omits the
  AppKit executors (which run only for keys the diff changed, so on a title
  change that is one pane's toolbar), and it charges a full sweep to every
  message, where the runtime's `reconcileDecision` coalesces bursts into one.
- Competing interpretations, the timing: this is a headless single-module `-O`
  build, not the app, so the microseconds are **diagnostic**, in
  `agent-docs/measurement-discipline.md`'s sense, and no benchmark verdict is
  claimed or available -- `F8` is precisely the finding that no ladder workload
  contains this path. What licenses reading them at all is that they are used
  only to bound an order of magnitude (0.08% of a core), and a 5x error in either
  direction does not change that verdict.
- Competing interpretations, the counters themselves: injecting increments
  perturbs inlining, which is why the timing comes from a separate uninstrumented
  build. The counts are exact and the instrumentation only adds statements.
- Uncertainty: none on any count -- every one is an exact tally of a
  deterministic replay over a model built from a counter-seeded id factory, and
  the counts are identical across runs. The timings are best-of-three over 2,000
  messages; the three `sessionTitle`/`sessionCwd`/`sessionProgress` rows, which
  do identical work, agree to within 1.5% at every layout, which is the
  instrument reporting its own repeatability. The four layouts are four points,
  not two, so the growth shape is measured rather than extrapolated
  (`agent-docs/measurement-discipline.md`, "measure the middle of the curve").
- Uncertainty, coverage: this measures **one** of `F8`'s nine runtime items --
  the reconcile sweep and `update()`, which is the pair `T23` owns. Checkpoint
  capture, IPC encode, snapshot construction, MRU reconciliation beyond
  `liveTabIds`, and the key monitor are still uninstrumented, so `H4` is answered
  for the sweep and open for the rest.
- Next action: **Phase 1 is complete.** `T23`'s gate has run and it fails as a
  speed task; re-scope or close it with the number above, and do not open a
  `decisions.md` entry that argues a percentage. This script is the before/after
  gate if `T23` is ever taken on complexity grounds: after a scoped sweep,
  `allPanes` walks and panes visited must fall to the panes the message named,
  `containerShapeNode` allocations to zero for a message that cannot change a
  shape, and the wall clock must not rise.

### F15 -- streaming the parser deletes the array and the 31 MB parse spike, and costs 1.7-5.4% on the drain, so `T7` is parked rather than landed

- Status: implemented, measured on both sides, **not landed**. `T7`. The
  by-construction claim holds exactly -- the token stream is never materialized,
  and feeding a corpus in one call now costs what feeding it in 4 KiB chunks
  costs -- and the non-regression check `T7` itself named is the one that fails:
  `benchmark-confirm` reads **`slower` (+5.43%) on `scrollback-stream`**, and a
  headless paired A/B puts the same corpus at +1.7% and the four-stream fixture
  at +2.1%. The parse spike this deletes is not paid at production's delivery
  size, and the drain cost is.
- Date and investigator: 2026-08-07, T7 agent.
- Commit and worktree state: `0b643073`, clean apart from this task's untracked
  scripts and an untracked plan file. Apple Swift 6.3.3, arm64-apple-macosx26.0.
  Machine: 10 processors, load 0.17-0.20 per processor at invocation.
- Commands, inputs, or reproduction: `python3 scripts/research/33/t7-streaming-parser.py`.
  The implementation is committed as `scripts/research/33/t7-streaming-parser.patch`
  rather than as engine source, because it is parked; the script builds **both**
  arms itself -- two detached worktrees at the named revision, one with the patch
  applied -- so the gate runs on both sides of a change the tree does not
  contain. Roughly 6 minutes. Directional verdicts came separately from
  `just benchmark-confirm baseline=0b643073`, run three times.
- Result or artifact paths: `scripts/research/33/t7-streaming-parser.py`,
  `t7-streaming-parser-probe.swift`, `t7-streaming-parser.patch`. The run writes
  nothing durable.
- What the change is: `TerminalInputStream.feed(_:) -> [TerminalStreamAction]`
  becomes `nextAction(in:from:)`, which recognizes one token and advances a
  caller-owned index, and `Terminal.feed` applies each action to the grid before
  pulling the next. The index lives on the caller's stack on purpose: a
  sink-closure form would mutate the grid inside a call that is already mutating
  `Terminal.inputStream`, which is overlapping access to `self`, and storing the
  chunk plus a position on the stream would put mid-feed state into a value that
  is `Equatable` and compared between feeds. Two codegen shapes came from
  measurement, not taste, and both are in the patch: the per-action dispatch is
  an `@inline(never)` method, because letting the optimizer inline it into the
  parse loop costs a further 1.5 points, and the chunk is passed as an
  `UnsafeBufferPointer` obtained once per feed.
- Measurements, claim 1 -- equivalence. All five corpora produce **F9's token
  counts and composition exactly**, at corpus framing, at the 16 KiB PTY turn
  limit, and single-shot; `scrollback-stream` is 1,500,000 `.print` plus 25,000
  `.execute` and zero CSI as before. The probe's `peakLiveActions` is **1** for
  every corpus at every chunking -- the structural claim stated as a number the
  probe measures rather than asserts. `swift test --package-path lib/TerminalCore`
  passes all 1,020 tests, including the 67-fixture replay that splits feeds
  mid-token at 7 bytes.
- Measurements, claim 3 -- the parse spike, from `TerminalMemoryProbe` on
  `scrollback-plain` at 179x66:

  | arm | single-shot | 4 KiB chunks | difference |
  | --- | ---: | ---: | ---: |
  | baseline | 103.72 MB | 72.80 MB | **30.92 MB** |
  | candidate | 72.61 MB | 72.61 MB | **0.00 MB** |

  `vmmap --summary` sampled while the terminal is resident, single-shot:
  `MALLOC_LARGE (empty)` falls from **37.2 MB across 4 regions to 6.2 MB across
  2**, and total dirty from 106.9 MB to 75.8 MB. That is `15/F7`'s figure, which
  `F1` predicted this array would explain, disappearing.
- Measurements, claim 4 -- the drain. `benchmark-confirm` against `0b643073`,
  three invocations, first two on an earlier shape of the patch and the third on
  the shape the patch file holds:

  | invocation | terminal-feed | scrollback-stream |
  | --- | --- | --- |
  | 1 (inline dispatch) | `slower` +4.52% | `slower` +10.00% |
  | 2 (inline dispatch) | not reported | drain 154.9 -> 173.8 ms |
  | 3 (parked shape) | `inconclusive` +1.12% | **`slower` +5.43%** |

  Thresholds are 2.5% and 1.85% at `confirm`. The headless paired A/B in the
  script, which alternates the two arms ABBA over six runs each, reads +1.66% on
  `scrollback-stream` and +2.05% on the four-stream fixture; it is stable to
  0.3% across repeats (min and median agree to that). `content-churn`,
  `style-churn`, `incremental-mixed` and `retained-browse` all read
  `inconclusive` or `equivalent`, as they must -- none of them feeds.
- Observation, where the cost is: `sample` over a sustained headless feed of
  `scrollback-stream` shows `_platform_memmove` at **1.5% of the baseline's
  samples and 12.9-14.1% of the candidate's**. Disassembly names it exactly: the
  candidate's `feed` calls `memcpy(dst: stack, src: self, size: 0x4f9)` -- **1,273
  bytes, the whole `Terminal` struct** -- immediately before each
  `damageActionSnapshot` getter call, at 9 call sites in the first shape and 3 in
  the parked one. The baseline emits the same copy at 3 sites, but not on its hot
  path.
- Inference: the array was not the cost `F1` and `F9` implied it was, and the
  per-token call boundary that replaces it is a real one. The array is ~1.5 MB
  and 15 allocations per 16 KiB PTY turn, allocated and freed back into the same
  hot allocator buckets and read back sequentially from L1; the streaming shape
  pays a call, an indirect 32-byte return and a defensive 1,273-byte copy of
  `Terminal` **per token**, roughly 3.7 ns each at ~106 ns per token. `F9`'s
  60-80x figure is allocator *traffic*, not footprint, and traffic in a reused
  bucket is cheaper than a call per token.
- Inference, what this does **not** say: the array's deletion is still the right
  end state. It is the granularity that is wrong, not the direction. `T8` prints
  ASCII runs in bulk, and `F10` measured those runs at 8.3 to 44.8 characters, so
  under `T8` the parser's output granularity is a run and the per-token call
  boundary amortizes 4x to 36x -- the exact factor that would turn this cost
  into a win. `T7` and `T8` are therefore one change, not two, and the ledger's
  ordering of them as separate confidence-ranked items is what this finding
  corrects.
- Competing interpretations: the third `benchmark-confirm` ran with
  `duetexpertd` at 78.7% at invocation, so its +5.43% may overstate the effect;
  the headless A/B on an otherwise idle machine says +1.66% on the same corpus.
  Both are above `scrollback-stream`'s 1.85% threshold, and the direction
  reproduced in three independent invocations plus two headless series, so the
  sign is not in question even though the size is uncertain within roughly a
  factor of three. Separately, the 1,273-byte copy before `damageActionSnapshot`
  is a **pre-existing** pathology this change made hot rather than one it
  introduced; an attempt to remove it by making the snapshot a `mutating` method
  made both arms 18-22% *slower* and was discarded.
- Uncertainty: none on the token counts, the footprints, or the `vmmap` regions
  -- all are exact or reproduce to 0.1 MB. The drain cost is directionally
  certain and sized only to within a factor of three. No claim is made about
  what `T7` costs **with** `T8`, because that was not built.
- Next action: **do not land `T7` alone.** Take it as the second half of `T8`:
  implement bulk ASCII runs against the eager parser or against this patch, then
  re-run this script's claim 4 and `benchmark-confirm`. If the pair is not at
  least `equivalent` on `scrollback-stream`, the array stays. See `D5`.

### F16 -- bulk ASCII runs collapse every print-path site to exactly `F10`'s predicted count, and `scrollback-stream` reads `faster` by 71%

- Status: implemented and landed. `T8`, first half -- **`T8` alone, against the
  eager parser**, which is the sequencing `D5` required so the pair's two halves
  can be told apart. The by-construction claim holds and the collapse is
  **exactly `F10`'s prediction, to the unit, on all five corpora**. The
  non-regression check is not merely clear: `scrollback-stream` reads
  **`faster` (-71.08%)** and its drain falls from 153.2 ms to 70.5 ms.
- Date and investigator: 2026-08-07, T8 agent.
- Commit and worktree state: measured with the change in the working tree over
  `63c693da`; nothing else modified but this task's own files and an untracked
  plan file. Apple Swift 6.3.3, arm64-apple-macosx26.0. Machine: 10 processors,
  load 0.24-0.52 per processor at invocation.
- Commands, inputs, or reproduction:
  `python3 scripts/research/33/t8-bulk-ascii-runs.py` (add `--json` for the raw
  two-arm report), roughly 3 minutes. It builds **both** arms itself -- a
  detached worktree at `--baseline` for the before side, this working tree for
  the after side -- copies each arm's engine sources to scratch, injects one
  counter increment at each site `F10` counted, and compiles each copy `-O` as
  one module with the probe. No arm's working tree is ever edited, and every
  injection is an exact-text anchor that must match once, so a source change
  that moves a site fails the run rather than miscounting. Directional verdicts
  came separately from `just benchmark-quick baseline=63c693da workload=<w>`.
- Result or artifact paths: `scripts/research/33/t8-bulk-ascii-runs.py`,
  `t8-bulk-ascii-runs-probe.swift`, `t8-bulk-ascii-runs-counters.swift`. The run
  writes nothing durable.
- What the change is: the parser recognizes a maximal run of printable ASCII
  (0x20-0x7E, in ground state with an idle decoder) and emits one
  `.printASCIIRun(Range<Int>)` naming it in the chunk being fed; `Terminal`
  reduces that with `printBulkASCII`, which writes a prefix of the run into one
  row in a single pass and pays the classification, the cluster-join attempt,
  `invalidateInspection`, the content-identity allocation, the style-id read, the
  wrap-spacer repair, `rememberOpenCluster` and `feed`'s damage snapshot **once
  for the whole prefix**. It *declines* -- returning 0, which costs one character
  on the per-character path and then re-enters -- on a latched pending wrap,
  insert mode, an open Prepend cluster, a cell whose overwrite would have to
  clear a partner, and a content-identity range that would straddle the
  counter's wrap. So each cut rule costs a character rather than the run, and a
  rule the reducer does not know about can only make it slower, never wrong.
- Measurements, claim 1 -- equivalence. Both arms consume **identical** printed
  character counts per corpus (1,500,000 / 4,189,500 / 1,305,000 / 2,500,025 /
  762,108, which are `F10`'s to the unit) and land on the same cursor, the same
  scrollback depth and the same screen text. `swift test --package-path
  lib/TerminalCore` passes all **1,029** tests, including the 67-fixture replay
  that splits feeds mid-token at 7 bytes, and `just test` passes all 75 steps.
- Measurements, claim 2 -- the collapse. Per-corpus counts, before at
  `63c693da` and after:

  | corpus | site | before | after | factor |
  | --- | --- | ---: | ---: | ---: |
  | `scrollback-stream` | bookkeeping units | 1,500,000 | 41,665 | **36.0x** |
  | | `terminalUnicodeClassification` | 1,500,000 | 8,333 | 180.0x |
  | | `invalidateInspection` | 1,508,333 | 49,998 | 30.2x |
  | | `rememberOpenCluster` | 1,500,000 | 41,665 | 36.0x |
  | | `searchMatchCache.invalidate` | 1,541,601 | 83,266 | 18.5x |
  | | `damageActionSnapshot` | 1,550,000 | 75,000 | 20.7x |
  | | snapshot diffs | 1,525,000 | 50,000 | 30.5x |
  | | content-identity allocations | 1,500,000 | 41,665 | 36.0x |
  | | `currentStyleId` | 1,500,000 | 41,665 | 36.0x |
  | `styled-screen-redraw` | bookkeeping units | 4,189,500 | 150,500 | **27.8x** |
  | | `terminalUnicodeClassification` | 4,189,500 | 21,000 | 199.5x |
  | | `damageActionSnapshot` | 4,403,002 | 322,002 | 13.7x |
  | `unicode-wrapping` | bookkeeping units | 1,305,000 | 147,537 | **8.8x** |
  | | `terminalUnicodeClassification` | 1,305,000 | 96,750 | 13.5x |
  | | `damageActionSnapshot` | 1,323,000 | 153,000 | 8.6x |
  | `incremental-screen-updates` | bookkeeping units | 2,500,025 | 300,001 | **8.3x** |
  | | `terminalUnicodeClassification` | 2,500,025 | **0** | -- |
  | | `damageActionSnapshot` | 3,300,031 | 1,100,007 | 3.0x |
  | `synchronized-frames` | bookkeeping units | 762,108 | 197,879 | **3.9x** |
  | | `terminalUnicodeClassification` | 762,108 | 147,463 | 5.2x |
  | | `damageActionSnapshot` | 934,985 | 370,756 | 2.5x |

  Nothing rose anywhere. `terminalUnicodeClassification` beats every other site
  because the bulk path never consults the table at all, so on
  `incremental-screen-updates` -- whose content is entirely printable ASCII and
  CSI -- the Unicode table is **never read**.
- Measurements, claim 3 -- the run structure, against `F10`'s prediction:

  | corpus | runs | in runs | mean | longest | declined | units | `F10` predicted |
  | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
  | `scrollback-stream` | 33,332 | 1,491,667 | 44.8 | 60 | 8,333 | 41,665 | 41,665 |
  | `styled-screen-redraw` | 129,500 | 4,168,500 | 32.2 | 52 | 21,000 | 150,500 | 150,500 |
  | `unicode-wrapping` | 50,787 | 1,208,250 | 23.8 | 57 | 6,750 | 147,537 | 147,537 |
  | `incremental-screen-updates` | 300,001 | 2,500,025 | 8.3 | 25 | 0 | 300,001 | 300,001 |
  | `synchronized-frames` | 50,416 | 614,645 | 12.2 | 177 | 0 | 197,879 | 197,879 |

  Every column matches `F10` exactly. `F10` predicted from a state machine over
  the byte stream and warned its factor was neither an upper nor a lower bound,
  because a real implementation might cut in more places; it cuts in exactly the
  same places. Two independently built counters agreeing to the unit on five
  corpora is what licenses reading either.
- Measurements, the paired benchmark, against `63c693da`. **`benchmark-confirm`
  cannot complete on this change** and the reason is itself a result: it
  calibrates `terminal-feed`'s fixed execution batch on whichever arm runs first
  -- the baseline -- and the candidate is fast enough that the same batch no
  longer fills the harness's 1-second block floor, so the invocation
  self-invalidates with `block-1-below-duration-floor` and
  `block-2-below-duration-floor` and issues no verdict for any workload. The
  retained raw blocks are the diagnostic: **1,425.7 ms baseline against 957.6
  and 980.0 ms candidate, -32.8%.** `confirm` is all-or-nothing by design, so
  the per-workload verdicts below are `benchmark-quick` (2 pairs each):

  | workload | verdict | detail |
  | --- | --- | --- |
  | `scrollback-stream` | **`faster` -71.08%** | drain 153.2 -> 70.5 ms; 10.0 -> 21.6 MB/s |
  | `incremental-mixed` | `equivalent` +0.88% | plan +0.56%, uncalibrated |
  | `retained-browse` | `equivalent` +0.95% | |
  | `content-churn` | `inconclusive` -2.5 to -3.6% (3 runs) | plan aux **`slower`** +5.7 to +6.8% |
  | `style-churn` | `inconclusive` -2.47% | plan aux **`slower`** +7.14% |
  | `terminal-feed` | no verdict, floor | raw blocks -32.8% |

- Observation, the two churn workloads. Their verdict metric is
  draw-nanoseconds-per-draw and it moved *down* (-2.5% to -3.6%, below the
  directional threshold), while their calibrated auxiliary plan metric reads
  `slower` at +4.1% to +7.1% and reproduced in five separate invocations, so it
  is not noise. The same blocks show `cumulativeFenceStallNanoseconds` falling
  from **37-39 ms to 4.5-6.5 ms** -- a ~7x reduction -- and total process CPU
  falling **13-16%**. In absolute terms the block gives up ~1.7 ms of planning
  and recovers ~33 ms of fence stall. `T8` touches no planner code and the grid
  it hands the planner is byte-identical, so the mechanism is not slower
  planning. In three of five invocations the delivery count rose 6.0-6.5% and
  plan time rose in lock step (plan-per-delivery +0.3%, +0.5%, +0.3%), which is
  simply more frames planned per draw; in the other two the delivery count was
  flat and plan-per-delivery rose 5.0-9.4%, which that arithmetic does not
  explain. The most likely remaining mechanism is contention rather than work:
  the baseline's main thread sits blocked in the delivery fence for ~38 ms while
  the terminal-owner queue drains with the cores to itself, and the candidate's
  does not, so main now plans concurrently with a drain instead of after it.
  **This is not confirmed** -- see the uncertainty below.
- Inference: the granularity mismatch `T8` names was real, is now removed, and
  was worth far more on the clock than this doc predicted. `F10` sized the
  mechanism and explicitly claimed no wall-clock share; the drain on
  `scrollback-stream` more than halves. The reason it is this large is that the
  collapsed sites are not one cost but eight, and two of them --
  `damageActionSnapshot` construction and its diff, at 1,550,000 and 1,525,000
  on `scrollback-stream` -- are the largest single counts in `F10`'s table and
  carry `F15`'s 1,273-byte defensive copy of `Terminal` with them. Deleting 96.8%
  of the snapshots deletes 96.8% of those copies.
- Inference, for `T7`: this is the amortization `D5` predicted. The parser's
  output granularity on plain text is now a 44.8-character run, so the
  per-token call boundary that cost `T7` 1.7-5.4% is paid 36x less often on
  `scrollback-stream`. `T7`'s re-gate is the next step and its result is not in
  this finding.
- Inference, for `T10`: `F12` measured 4.96 publishes per draw and `T10` exists
  to bound that. Making the drain 2.2x faster does not reduce the ratio and in
  three invocations here it raised the delivery count 6%, so `T8` slightly
  *increases* what `T10` has to recover. The two are complements, not
  substitutes.
- Competing interpretations: -71.08% is a very large number from a 2-pair
  `quick` invocation, and `quick` is the weaker instrument -- `scrollback-stream`
  carries 4 pairs at `confirm` and a 1.85% directional threshold. The effect is
  40x that threshold and the drain figure is an independent descriptive
  measurement of the same block (153.2 -> 70.5 ms), so the direction and rough
  size are not in question; the exact percentage is a `quick` reading and should
  be re-taken at `confirm` if anything ever depends on the digits. The reason it
  was not is that `confirm` refuses to issue any verdict while `terminal-feed`
  cannot fill a block.
- Uncertainty: none on any counter -- all are exact tallies of a deterministic
  replay, and all five corpora reproduce `F10` to the unit. The churn
  workloads' plan-time increase is **measured and unexplained**: the
  more-deliveries arithmetic accounts for three of five invocations and not the
  other two, and the contention hypothesis above is a hypothesis, not an
  ablation. It is recorded rather than resolved because the same blocks are
  unambiguously better on fence stall and process CPU and their own verdict
  metric did not regress. `terminal-feed` has no calibrated verdict at all.
- Next action: re-gate `T7` on top of this (`D5`), by rebasing
  `t7-streaming-parser.patch` onto the landed run granularity and re-running both
  `t7-streaming-parser.py` and the paired benchmark. Separately, the
  `terminal-feed` floor is now a live harness limitation for any change on the
  feed path of this size, and nothing in the ladder owns it.

### F17 -- on top of the run granularity the streaming parser inverts: 4-11% faster headless, and `T8` had already deleted its memory spike

- Status: implemented and landed. `T8`, second half -- **`T7` re-gated on top of
  `T8`**, which is what `D5` parked it for. `F15`'s +1.7-5.4% cost is gone and
  the sign has flipped: streaming is now **4.4% to 11.2% faster** than the eager
  array on every corpus measured headlessly. The memory claim it was originally
  justified by is a separate matter -- **`T8` alone already delivered it**, so
  `T7` adds nothing there.
- Date and investigator: 2026-08-07, T8 agent.
- Commit and worktree state: measured with `T7` in the working tree over
  `90731fdc` (`T8` landed), which is itself over `63c693da`. Apple Swift 6.3.3,
  arm64-apple-macosx26.0. Machine: 10 processors, load 0.45 per processor at
  invocation; the GUI blocks ran with `siriknowledged`, `fseventsd` and
  `WindowServer` at 27-33%, which is why the GUI readings below are quoted as
  neutral rather than as a size.
- Commands, inputs, or reproduction: three baselines built as detached
  worktrees -- `63c693da` (neither), `90731fdc` (`T8` only), and the working tree
  (both) -- with `swift build -c release --product TerminalCoreBenchmark` and
  `--product TerminalMemoryProbe` in each. The headless A/B alternates all three
  arms ABBA over six runs each and reports medians;
  `just benchmark-quick baseline=<rev> workload=<w>` supplied the GUI verdicts,
  and `python3 scripts/research/33/t8-bulk-ascii-runs.py` was re-run with `T7`
  applied to confirm the counters and the equivalence are unchanged by it.
- Result or artifact paths: no new script. `t8-bulk-ascii-runs.py` gates both
  halves -- re-run with `T7` applied, it reports the same counters and the same
  equivalence -- and `t7-streaming-parser.py`, its probe and its patch are all
  **deleted**. They existed to build both arms of a change the tree did not
  contain; the tree contains it now, so the patch would rot against it and the
  script would fail on the first run. `F15`'s arms are `63c693da..90731fdc` and
  `90731fdc..HEAD`, and its `.print`-keyed token expectations no longer describe
  the parser's vocabulary, so re-anchoring the script would mean rewriting the
  claims rather than preserving them.
- Measurements, the drain, headless medians of six alternating runs per arm:

  | corpus | `63c693da` | `T8` | `T8`+`T7` | `T7` on top of `T8` |
  | --- | ---: | ---: | ---: | ---: |
  | `scrollback-stream` | 164.08 ms | 82.62 ms | 79.00 ms | **-4.37%** |
  | `incremental-screen-updates` | 657.70 ms | 563.69 ms | 500.72 ms | **-11.17%** |
  | `synchronized-frames` | 110.13 ms | 87.31 ms | 78.38 ms | **-10.23%** |
  | four-stream fixture | 1,421.43 ms | 958.82 ms | 876.59 ms | **-8.58%** |

  `F15` measured the same shape at **+1.66%** on `scrollback-stream` and +2.05%
  on the four-stream fixture against the same instrument. The pair against
  `63c693da` is -51.85% / -23.87% / -28.83% / -38.33%.
- Measurements, the memory claim, `TerminalMemoryProbe` on `scrollback-plain` at
  179x66:

  | arm | single-shot | 4 KiB chunks | difference |
  | --- | ---: | ---: | ---: |
  | `63c693da` | 103.73 MB | 72.78 MB | **30.95 MB** |
  | `T8` only | 72.67 MB | 72.80 MB | **0.12 MB** |
  | `T8`+`T7` | 72.61 MB | 72.61 MB | **0.00 MB** |

  This is the finding's second result and it corrects the reason `T7` existed.
  The 31 MB spike `F15` deleted was one 32-byte action per *character*; under
  `T8` the array holds one action per 44.8-character run, so it is 36x smaller
  and is no longer a spike at all. `T8` alone takes the chunk difference to
  0.12 MB, which is inside `F15`'s own 2 MB tolerance. `T7` closes the last
  0.12 MB by construction rather than by being small.
- Measurements, the GUI ladder, `benchmark-quick` on the pair against
  `63c693da`: `scrollback-stream` **`faster` -69.32%** (drain 155.6 -> 69.1 ms,
  9.8 -> 22.1 MB/s), `content-churn` `equivalent` -0.90%, `incremental-mixed`
  `equivalent` +0.77%, `retained-browse` `equivalent` +0.65%, `style-churn`
  `inconclusive` -2.38%. `T7`'s own marginal effect against `90731fdc` on
  `scrollback-stream` was measured three times and read `inconclusive` -2.28%,
  +3.51% and -1.70% -- signs disagreeing, which is the GUI block correctly
  reporting that a 4% drain change inside a block that is mostly not drain is
  below what it can resolve. The churn workloads' plan-metric `slower` persists
  at +6.33% and +8.25% with the same ~15% process-CPU reduction, unchanged from
  `F16`; `T7` neither causes nor affects it.
- Measurements, equivalence, unchanged by `T7`: the counters, the printed
  character counts, the cursor, the scrollback depth and the screen text all
  match `F16` exactly, and `swift test --package-path lib/TerminalCore` passes
  **1,030** tests including the 67-fixture 7-byte-split replay. `just test`
  passes all 75 steps. A grep for `[TerminalStreamAction]` under `lib/*/Sources`
  returns **0 occurrences**, which is `T7`'s structural claim.
- Inference: `D5`'s reasoning was right and its size estimate was conservative.
  It predicted the per-token boundary would amortize by the run length and turn
  a cost into a win; it did, and by more than break-even, because the pull loop
  also deletes the array's own store-then-reload of every token. Note where the
  gain is largest: **`incremental-screen-updates` and `synchronized-frames`, the
  two corpora with the *shortest* runs**, at -11.2% and -10.2% against -4.4% on
  the corpus with 44.8-character runs. That is the opposite of what pure
  amortization predicts and it says the win is not only the boundary: those two
  corpora are CSI-heavy, so their token count stays high under `T8` and the array
  they no longer build stays large.
- Inference, on what justifies `T7` now: not memory. `T8` took the chunk
  difference from 30.95 MB to 0.12 MB, so anyone reading `F15`'s memory table as
  `T7`'s case is reading a number `T8` has since absorbed. What is left is a
  measured speed win of 4-11% on the drain and the complexity claim `D1` admits:
  the intermediate token representation does not exist, so no chunk size can make
  it large and no future reader can reintroduce a flatten-then-re-read step
  without deleting `nextAction`.
- Competing interpretations: the headless instrument is the one that resolves
  this and the GUI one is not, which is the reverse of the usual ordering in this
  project, so it deserves saying plainly rather than being relied on quietly.
  `F15` used the same headless A/B to establish the +1.66% cost and
  `benchmark-confirm` to establish direction; here `benchmark-confirm` cannot run
  at all (`F16`, the `terminal-feed` block floor) and `benchmark-quick` returns
  disagreeing signs on a 4% effect. The headless series is stable -- six
  alternating runs per arm, three arms, four fixtures, and every one of the twelve
  cells points the same way -- and the two largest effects are 10-11%, far outside
  its noise. But the pair's landing does not rest on `T7`'s marginal sign: the
  pair reads `faster -69.32%` against `63c693da`, which is `D5`'s stated
  condition, and `T7`'s worst plausible reading is neutral.
- Uncertainty: none on the footprints or the counters. `T7`'s marginal effect is
  directionally certain headlessly and unresolvable on the GUI ladder; no claim
  is made that a 4% drain improvement is visible to a user. `terminal-feed` still
  has no calibrated verdict for either half.
- Observation, two earlier scripts no longer run, by design rather than by
  neglect: `t1-action-array-size.py` probes an array production no longer builds,
  and `t2-print-bookkeeping.py` anchors on the eager `for action in actions` loop
  that no longer exists, so it exits with its own "the engine moved and this probe
  must be re-anchored" message. Both are kept as the record of `F9` and `F10`,
  whose numbers `F16` reproduces to the unit from independent anchors. Do not
  re-anchor them to make them pass; `t8-bulk-ascii-runs.py` is the live counter.
- Next action: none for `T7` or `T8`; both are landed and `D5` is discharged by
  `D6`. The `terminal-feed` block floor remains unowned, and `T10` is the next
  Phase 2 item -- `F16` showed the faster drain slightly *raises* the delivery
  count, so `T8` enlarged `T10`'s target rather than shrinking it.

### F18 -- the churn plan-metric `slower` is composition, not cost: the candidate plans 55-63% more frames per draw at 35% less per frame, and the planner is never off-CPU

- Status: measured, closing `F16`'s one recorded uncertainty. The calibrated
  plan-metric `slower` on the two churn workloads is real and reproduces
  (+4.83% `content-churn`, +6.70% `style-churn` on this run), and it is fully
  explained by frame composition: the faster drain publishes more frames per
  draw, each planned frame covers a smaller accumulated diff and costs less,
  and the per-draw *sum* rises because ~30 extra cheap plans outweigh the
  per-frame savings. `F16`'s contention hypothesis is **refuted by ablation**:
  thread CPU inside the plan bracket equals its wall time to within 0.1% on
  both arms of every block, so the planner is never descheduled and never
  blocked while planning.
- Date and investigator: 2026-08-07, follow-up agent.
- Commit and worktree state: measured between two purpose-built arms in a
  detached worktree, `ec6f319e` (`63c693da` plus the instrumentation commit)
  against `0e623913` (`50595488` plus the same commit), so the arms differ by
  exactly `T8`, `T7`, and the shared-narrow-cell-writer refactor (`50595488`),
  and the instrumentation cancels. The instrumentation commit is preserved on
  branch `bench/plan-thread-cpu` and is 22 lines, all inside the existing
  `#if DANTERM_TERMINAL_BENCHMARK` path: it captures
  `clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)` across the same
  `planFrame` bracket that produces `lastPlanDurationNanoseconds` and emits
  `cumulativePlanThreadCPUNanoseconds` beside the wall figure in the block
  artifact. Machine: 10 processors, load 0.27-0.30 per processor at
  invocation, otherwise idle.
- Commands, inputs, or reproduction:
  `just benchmark-quick baseline=ec6f319e workload=content-churn` and
  `workload=style-churn`, then read
  `rawBlocks[].artifact.finalDraw.{cumulativePlanNanoseconds,cumulativePlanThreadCPUNanoseconds,planCount,planFrameCount}`
  and `rawBlocks[].{measurementRole,drawCount}` from the comparison's
  `run.json`.
- Measurements, per block (A is baseline, B is candidate; 50 accepted draws
  per block in all eight):

  | workload | arm | planned frames | plan wall | plan thread CPU | per planned frame | per draw | fence stall |
  | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
  | `content-churn` | A | 51 | 25.4 ms | 25.3 ms | 497 us | 507 us | 33.5 ms |
  | | B | 82 | 26.6 ms | 26.6 ms | 325 us | 533 us | 4.1 ms |
  | | B | 81 | 26.5 ms | 26.5 ms | 328 us | 531 us | 5.4 ms |
  | | A | 51 | 25.3 ms | 25.3 ms | 496 us | 506 us | 37.8 ms |
  | `style-churn` | A | 51 | 24.7 ms | 24.7 ms | 485 us | 495 us | 36.0 ms |
  | | B | 77 | 26.8 ms | 26.8 ms | 348 us | 536 us | 6.8 ms |
  | | B | 83 | 26.5 ms | 26.5 ms | 319 us | 529 us | 6.0 ms |
  | | A | 51 | 25.1 ms | 25.1 ms | 492 us | 502 us | 39.1 ms |

  The stall column reproduces `F16`'s ~7x fence-stall reduction, and process
  CPU read -21.71% and -16.76% in the same invocations, so the block totals
  are unambiguously better while the plan metric reads `slower`.
- Inference: `planNanosecondsPerDraw` divides cumulative plan time by accepted
  draws, so it charges the candidate for planning *more often*, not for
  planning *slower*. Per planned frame the candidate is 30-35% cheaper. The
  thread-CPU column rules out the scheduling form of `F16`'s contention
  hypothesis outright; what the wall/CPU identity cannot separate is
  more-instructions from same-instructions-stalled-on-memory, but nothing is
  left for that distinction to explain -- the extra planned frames account for
  the whole rise with the per-frame cost *falling*. This is also direct
  evidence for `T10`: the extra plans are exactly the publishes a
  demand-bounded rate would not perform.
- Competing interpretations: `F16` reported two invocations where the
  *delivery* count was flat while plan-per-delivery rose; this run's
  discriminator is the *planned frame* count, which deliveries do not proxy --
  `planIfNeeded` is damage- and equality-gated, so frames planned per delivery
  can move while deliveries hold still. No invocation in this run shows a
  residual once planned frames are the denominator.
- Uncertainty: 2-pair `quick` invocations, so the percentages are not
  decision-bearing digits; the composition mechanism does not rest on them --
  it rests on the planned-frame counts, which are exact tallies. The
  instrumentation is not yet on the main branch: the working tree carries
  another session's uncommitted edits to the same files, so it waits on
  `bench/plan-thread-cpu` rather than colliding.
- Next action: land `bench/plan-thread-cpu` once the tree is clean, and treat
  the churn plan metric's `slower` as expected whenever a change raises
  publishes per draw -- until `T10` bounds the publish rate, which deletes the
  composition effect at its source.

### F19 -- live lines-per-delivery is bimodal: a paced producer pays one whole screen per line, and only a flood amortizes it

- Status: verified by direct measurement in a running app, reproduced across
  two full runs, with the one surprise confirmed by headless ablation. This is
  the measurement `F13` named as the one number to take before `T9` starts,
  and it places production at **both ends** of the amplification curve at
  once, segregated by producer type: every paced producer measured -- 30, 240
  and 960 lines/s, the shapes of build logs, test output and a fast logger --
  publishes **exactly one line per frame** (mean 0.997-1.005, h1 share 99.7%),
  the 66x end, while a full-speed `cat` publishes **~290 lines per frame**
  (96% of publishes at >=91 lines), the 1.0x end. Two discoveries ride along:
  at the history budget a scroll's damage arrives as a **whole-viewport row
  set instead of `.full`**, which corrects the scope of `F11`'s escalation
  claim; and the `T4` instrument re-run post-`T8` reads **13.0 publishes per
  draw**, up from `F12`'s 4.96.
- Date and investigator: 2026-08-07, T9-vetting agent.
- Commit and worktree state: `a62637b2` plus this task's own changes -- the
  `absoluteViewportTopRow` accessor on `Terminal` and
  `TerminalPaneSessionController` (with its eviction unit test), the
  `TerminalDeliveryShapeSampler` (`app/TerminalDeliveryShapeSampler.swift`)
  and its two call sites in `SwiftTerminalSessionView`, and the two launcher
  allowlist entries. Apple Swift 6.3.3, arm64-apple-macosx26.0, release
  configuration, 120 Hz display, default slot window at 40 grid rows.
- Commands, inputs, or reproduction:
  `scripts/research/33/t9-lines-per-delivery.sh` (the live measurement; four
  producer regimes in one pane),
  `scripts/research/33/t9-damage-at-budget-probe.sh` (the headless ablation),
  and `scripts/research/33/t4-publish-rate.sh --seconds 12 --megabytes 128`
  (the publish/draw ratio re-run, unchanged script).
- What the instrument counts: one JSON line per pane per elapsed second from
  inside `publish(_:)`, carrying publishes, full-damage publishes, scrolled
  viewport lines, and a lines-per-publish histogram whose buckets bracket
  `F13`'s curve points (1, 8, 91). Scrolled lines are the per-publish delta of
  the new `absoluteViewportTopRow` -- `evictedRowCount + topRow` -- because
  `scrollProjection.topRow` alone plateaus once eviction begins and would
  under-read a long stream to zero; the unit test pins that behavior. A second
  env-gated file traces every publish individually. Summaries drop each
  segment's first window, which by construction carries the previous
  scenario's unflushed tail (the sampler's windows close on the next publish).
- Measurements, steady state, both runs (run 2 first, run 1 in parentheses
  where it differs by more than rounding):

  | scenario | publishes/s | mean lines/publish | h1 share | full-damage share | rows touched per scrolled line |
  | --- | ---: | ---: | ---: | ---: | ---: |
  | `cat` full speed | 1,532 (1,535) | 291.4 (288.7) | 0% | 1.000 | **0.14** |
  | paced 30/s | 30.2 | **0.997** | 99.7% | 0.51 | **39.9** |
  | paced 240/s | 239.2 (238.9) | **1.001** | 99.7% | 0.49 | **39.9** |
  | paced 960/s | 956.4 (953.4) | **1.001** (1.005) | 99.8% | 0.44 (0.42) | **39.9** |

  Publishes equal deliveries to within a handful per thousand in every
  scenario, and paced publishes/s equal the producer's rate exactly -- so
  **nothing between the PTY write and the publish coalesces paced lines, up to
  at least 960 lines per second**. "Rows touched" counts the whole 40-row grid
  once per scrolling publish (see the damage-shape result below) against the
  lines the viewport actually moved.

  The `T4` instrument re-run, steady windows: **1,556-1,614 publishes/s
  against 120-121 draws/s -- 13.0 publishes per draw**, versus `F12`'s 594
  and 4.96 at `144d3054`. `T8`'s faster drain raised the publish rate ~2.6x
  while the display stayed at 120 Hz.
- Observation, the damage shape at the history budget -- found because the
  live full-damage share read ~0.5 where `F11`/`F13` predicted 1.0, and every
  "non-full" scrolling publish in the trace carried **exactly 40 rows**, the
  whole grid. The ablation probe (`t9-damage-at-budget-probe.sh`) settles it:
  below the budget a one-line scroll escalates to `.full` **200 of 200** times
  through `recordDamage(from:to:)`'s `topRow` guard, exactly as `F11` read;
  at the budget the same feed produces `.full` only **9 of 200** times, with
  the other 191 arriving as a 40-row damage set, because the history append
  and the arena eviction cancel in `scrollProjection.topRow` and the guard
  never fires -- while `absoluteViewportTopRow` still advances 200/200, which
  also validates the sampler's delta. Arena eviction is chunked, so live at
  budget the two shapes interleave (~0.5 share). The cost is the whole screen
  either way; only the representation differs. Two scope corrections follow:
  `F11`'s "streaming publishes `.full` on every frame" is the **below-budget
  half** of the story, and its "the damage-set apparatus is never on the
  streaming hot path" inverts at budget, where every scrolling delivery puts
  40 rows through the set -- `F11`/`F13` measured short-history probes and
  the benchmark corpora, all below budget.
- Inference, for `T9` (shift damage): production does not sit at one point on
  `F13`'s curve; it occupies both ends, split by producer type. The paced
  regime is `T9`'s entire case, and it is the strongest form of it: at 240
  lines/s the app plans and submits the whole screen 240 times a second --
  ~9,570 rows planned per second to express ~240 changed lines, `F13`'s
  amplification at this 40-row geometry (40x rows, and 2 ideal rows per
  publish counting the cursor row) sustained continuously. At 30 lines/s
  every one of those whole-screen plans is also drawn, because the publish
  rate sits under the display rate -- so unlike the flood, `T10` recovers
  none of it and `T9` is the only lever on this regime. The flood regime is
  `T10`'s case instead: at 1,532 publishes/s against 120 draws, 12 of every
  13 whole-screen plans are overwritten unseen, and shift damage would save
  little per frame (1.0x amplification) -- so `T9` and `T10` partition the
  producer space between them, which sharpens the README's "either alone is a
  win" into a regime split.
- Inference, for `T9`'s design, and this is the trap the measurement caught:
  a shift representation **cannot be derived from `topRow` deltas**, because
  at the history budget `topRow` is constant while the content translates
  under it -- any "topRow changed, therefore translate" reconstruction reads
  zero shift exactly where the pane spends its steady state. The shift must be
  recorded where the scroll happens (`moveAndFillRows`), carried in the
  damage value as `T9` already proposes. The same fact means `T9`'s
  verification must run its scenarios **at** the budget as well as below it,
  and `t9-damage-at-budget-probe.sh` is the seed of that arm.
- Inference, for `T10` and `H2`: the multiplier is now **13.0**, not 4.96;
  `F16` predicted `T10` would have "slightly more to recover" and the true
  factor is 2.6x more publishes at the same 120 Hz ceiling. A `T10` claim
  should be written against this number, with `F12`'s 4.96 as the pre-`T8`
  datum.
- Competing interpretations: the slot window here is 40 grid rows against
  `F13`'s 66, so the whole-screen cost per paced line is 40 rows, not 66 --
  the amplification scales with the viewport and the one-line-per-publish
  behavior is geometry-independent. The paced producer writes each line
  atomically with a flush, which is the common but not universal shape; a
  build tool that buffers multi-line bursts lands between the regimes (h2 and
  h3to8 stay near zero here, so bursts were rare in these runs), and the
  curve in `F13` interpolates those cases. And `cat`'s 290 lines per publish
  is the corpus's ~59-byte mean line against the 16 KiB read cap, so a
  wider-lined corpus floods at proportionally fewer lines per publish but
  identical bytes.
- Uncertainty: none on the counts, which are exact tallies, and the paced
  rows all reproduce to 0.5% or better across the two runs. The `cat`
  publish rate differs between the two instruments (1,532/s from the shape
  sampler's scenario, 1,584/s steady from the `T4` re-run) by corpus size and
  window boundaries; the ratio conclusion does not depend on the digit. The
  paced scenarios all ran at the history budget because the `cat` scenario
  precedes them in the same pane and fills the 16 MiB arena; below budget the
  paced damage shape would be `.full` on every line (the probe's first
  census), with identical whole-screen cost, so the regime conclusion is
  unaffected.
- Next action: `T9` has its production placement and may proceed to its
  `decisions.md` entry, with two riders from this finding: the shift must be
  recorded at the scroll site rather than derived from `topRow`, and the
  verification matrix gains an at-budget arm. `t9-lines-per-delivery.sh` is
  `T9`'s live before/after gate beside `T5`'s headless one: after the change,
  paced scenarios must publish O(1) damaged rows per line while
  `rewrite`-style output stays unmoved. `T10`'s claim updates to 13.0:1.

### F20 -- the consumer's deadline bounds the publish rate: publishes per draw fall from 10.45 to 0.997 live, the paced regime is untouched, and flood throughput rises 25%

- Status: implemented and verified live; this is `T10` landed against `D8`'s
  direction. The claim is the countable one `D8` stated: publishes per second
  fall from drain rate to display demand. On this run's display state the
  live `cat` fell from **571.9 publishes/s at 10.45 per draw** to **42.2
  publishes/s at 0.997 per draw** (13.6x fewer publishes), with deliveries,
  publishes, and draws now equal to within one per few hundred -- every
  fence produces a plan a display pass actually consumes. The paced 30/s
  scenario is unchanged to the third digit (30.17 publishes/s, 0.997 lines
  per publish), so the deadline never binds under the display rate and
  `F19`'s regime partition holds: the paced regime remains `T9`'s alone.
- Date and investigator: 2026-08-08, T10 implementation agent.
- Commit and worktree state: `b29125d0` plus this task's changes -- the
  `TerminalPTYUpdateSignal` payload on the host's update signal, the deadline
  and one-shot timer in `TerminalPaneSessionController`, the merging delivery
  boundary, and the view's display-interval provider. Apple Swift 6.3.3,
  arm64-apple-macosx26.0, release configuration for every live number,
  built-in ProMotion display (adaptive, max 120 Hz), default slot window at
  40 grid rows.
- Commands, inputs, or reproduction: `scripts/research/33/t4-publish-rate.sh`
  and `scripts/research/33/t9-lines-per-delivery.sh`, each run before and
  after on the same display within the same hour; paired
  `just benchmark-quick baseline=HEAD` on `content-churn`, `style-churn`, and
  `scrollback-stream`; the deterministic timer and bypass tests in
  `TerminalPanePublishDeadlineTests.swift`; `just test` (75 steps, all
  passing).
- What the mechanism is: the host's update signal now carries a small urgent
  payload (clipboard write, semantic events, primary-history generation,
  lifecycle result) drained on the owner queue at signal time, and the
  controller delivers that payload immediately but will not fence again until
  `lastDelivery + refreshInterval`, arming exactly one one-shot timer only
  while host work is pending. Damage accumulates where it always accumulated
  -- the engine's damage value -- and the deferred fence drains all of it at
  once. A child exit consumes immediately. The drain and parse never
  throttle; only the fence is deferred. The interval comes from the pane's
  actual display via `NSScreen.maximumFramesPerSecond`, read per fence.
- Measurements, live gates (before -> after, same scripts, same display,
  same hour):

  | scenario | publishes/s | mean lines/publish | scrolled lines/s |
  | --- | ---: | ---: | ---: |
  | `t4` `cat` 64 MB | 571.9 -> 42.2 | -- | -- |
  | `t4` publishes per draw | 10.45 -> **0.997** | -- | -- |
  | shape `cat` full speed | 576.2 -> 78.7 | 542.0 -> 4,956.4 | 312,268 -> **390,054** |
  | paced 30/s | 30.17 -> **30.17** | 0.997 -> **0.997** | 30.1 -> 30.1 |
  | paced 240/s | 238.4 -> 74.8 | 1.000 -> 3.19 | 238.4 -> 238.4 |
  | paced 960/s | 712.5 -> 81.4 | 1.343 -> 11.70 | 957.1 -> 951.9 |

  Paired benchmark, `benchmark-quick baseline=HEAD` (2 pairs each), with the
  composition counters from each comparison's `run.json`
  (`summary.workloads[].rawBlocks[].artifact.finalDraw`):

  | workload | draw verdict | plan time | planned frames per 50-draw block (A -> B) | in-block fence stall (A -> B) |
  | --- | --- | --- | ---: | ---: |
  | `content-churn` | inconclusive -3.11% | **faster -5.67%** | 83, 61 -> **51, 51** | 3.9, 7.6 ms -> 1.1 ms |
  | `style-churn` | **faster -4.31%** | **faster -8.29%** | 94, 66 -> **51, 51** | 4.6, 8.1 ms -> 1.2 ms |
  | `scrollback-stream` | inconclusive -2.62% | -- | -- | drain 80.5 -> 72.2 ms (descriptive) |

  `F18`'s expected reading lands exactly: planned frames per accepted draw
  fall back to one (51 per 50-draw block, both candidate blocks, both
  workloads), the plan-metric `slower` it measured (+4.83% / +6.70%)
  reverses to `faster` (-5.67% / -8.29%), and nothing on the ladder
  regresses.
- Observation, the draw-bound cycle: after the change the flood's publish
  rate sits at 42-81/s, not the 120 Hz ceiling, and draws track publishes
  1:1. The deadline arms at 8.3 ms, but the cycle it bounds serializes fence
  stall (up to ~1.8 ms behind a 16 KiB parse turn), a whole-screen plan, and
  a whole-screen draw on the same main thread, so the effective period is
  ~13-24 ms depending on geometry. The deficit against 120 Hz is exactly the
  whole-screen cost per scrolled frame that `T9` deletes; post-`T9` the same
  bound should ride up toward the display ceiling. The baseline's draws
  (54.7/s on `t4`, against `F19`'s 120) already sat below the ceiling for
  the same reason plus ProMotion's adaptive rate.
- Inference: `F12`'s waste is deleted at the source `D8` named -- the
  pipeline no longer pays plan, copy-on-write, damage-set construction, and
  fence for frames AppKit will discard; work starts only when a display pass
  can consume it. The multiplier `F19` warned about (every drain win widens
  the waste) is structurally capped at ~1 publish per draw. Flood throughput
  rose 25% (312k -> 390k lines/s) because main-thread cycles that went to
  discarded plans now go to the drain and the screen.
- Competing interpretations: the paced-240 and paced-960 scenarios now
  coalesce (their producers publish above this cycle's effective demand), so
  their publishes/s falls too -- designed behavior for any producer above
  display demand, not a regression: their scrolled lines/s is unchanged, so
  no output is lost and each publish simply carries more lines. The 42 vs 79
  publishes/s spread between the two flood instruments is corpus and
  window-boundary difference, as in `F19`.
- Uncertainty: the benchmark percentages are 2-pair `quick` figures and are
  not decision-bearing digits; the claim rests on the counts, which are
  exact tallies. `D8` named `cumulativeFenceStallNanoseconds` falling ~13x
  as a gate, and `t4`'s sampler does not carry that counter; the stall
  evidence here is the churn blocks' in-block stall (3.5-6.8x down in a
  serialized-draw workload that cannot flood) plus the count identity --
  fences fell 13.6x live with the per-fence cost unchanged in kind, so the
  cumulative flood stall falls by the same factor. The live absolute rates
  (42.2 vs `F19`'s 120 draws/s environment) depend on ProMotion's adaptive
  state; the before/after pairing is same-display and same-hour, so the
  ratios are unaffected.
- Next action: `T10` is done; `T9` (shift damage, `D7`) is the remaining
  Phase 2 task and now owns the whole paced regime plus the draw-bound
  cycle this finding measured. The README's follow-up question -- whether
  the 16 KiB read cap keeps any other reason to exist -- is now askable
  with the deadline in place. `T24` (the `benchmark-confirm` block floor)
  remains open instrument debt for future feed-path claims. `F18`'s parked
  instrumentation (`bench/plan-thread-cpu`) landed by cherry-pick in the
  commit after this task's, discharging its "once the tree is clean" wait.

### F21 -- the scroll site records the shift and the planner translates across it: damaged rows per scrolled line fall 66 to 2, planner inspection falls 33x, and the escalation rate falls to zero in both history regimes

- Status: implemented and verified; this is the engine/planner half of `T9`
  landed against `D7`, with `T20` riding along as `D2` and `30/D2`'s
  reopening clause required. The claim is the countable one `D7` stated, per
  regime, and every number below is a count. The view half -- the
  backing-store translation that would take submitted glyphs from 11,570
  toward the ideal -- is deliberately not in this change: the drawing seam
  folds the shift into region-wide row damage (`clipFramePlan`,
  `SwiftTerminalSessionView.publish`), so drawn pixels are byte-identical to
  before while the planner's half is banked and separately revertible.
- Date and investigator: 2026-08-08, T9 engine/planner implementation agent.
- Commit and worktree state: working tree on `ea6ea661` (post-`T10`), Apple
  Swift 6.3.3, arm64-apple-macosx26.0; release configuration for the live
  sampler, `-O` single-module build for the t5 probe.
- Commands, inputs, or reproduction:
  `scripts/research/33/t5-scroll-amplification.py --events 600` (now with a
  `text-line-at-budget` arm and an eviction-corrected ideal);
  `scripts/research/33/t9-lines-per-delivery.sh --seconds 10` (now reporting
  measured `damagedRowsPerScrolledLine` from the per-publish trace instead
  of the pre-`T9` whole-grid assumption);
  `scripts/research/33/t9-shift-damage-structure.sh` (the `T20` rider's
  structural gate); `just test` (75 steps); the four new suites named below.
- What the mechanism is, in the shape `D7` prescribed:
  - **Representation (`T20` rider).** `TerminalDamage` carries a
    width-bounded word bitset end to end plus at most one
    `TerminalDamageShift(region:delta:)`; `.full` carries neither. The
    drain builds no `Set`, spans and row walks come out canonical from the
    word scan with no sort, `init(rows:)`'s negative-row sanitizer is a
    precondition (an out-of-range row fails to construct; the pinning test
    is replaced by an exit test), and the halo is `w | w<<1 | w>>1` with a
    tail mask. Composition is `D7`'s contract verbatim: a later shift
    translates pending rows within its region and drops rows pushed out,
    same-region deltas sum and collapse to region rows at the region
    height, a region mismatch escalates to `.full`, and `.full` absorbs
    everything -- implemented identically in the accumulator and in the
    public `formUnion` the pane session coalesces with.
  - **Scroll site.** `moveAndFillRows` owns damage recording
    (`recordScrollDamage`): a shift plus the vacated strip plus at most two
    cursor rows (the retained planner bakes the block cursor into its row's
    runs, so the previous frame's cursor image rides the translation to
    `cursor.row + delta` and the cursor's own row needs a fresh bake --
    `D7`'s "at most two cursor rows above the ideal", measured below as
    exactly the bare-newline residue). Fallbacks are the contract's worst
    cases and never exceed the pre-shift representation: not-following
    escalates `.full` as before; a full-turnover move records range rows;
    an active overlay (selection, search occurrence, hovered or armed
    link) refuses translation except for the one scroll whose overlays are
    content-anchored in the direction content moves -- a whole-viewport
    scrollback push -- falling back to range rows for non-pushing scrolls
    and to `.full` for a partial-region push.
  - **Guard narrowing.** `DamageActionSnapshot` now carries the
    eviction-corrected `absoluteViewportTopRow` plus a monotone
    shift-accounted advance counter (an `ObservationGeneration`, outside
    value equality); `recordDamage(from:to:)` escalates only a viewport
    advance the recorded shifts do not account for. Because the absolute
    top advances by exactly the pushed amount in both regimes, below-budget
    and at-budget scrolls drain the same shift-carrying value -- `F19`'s
    second rider made structural -- while resize, alternate-screen flips,
    not-following, and any unaccounted move still escalate exactly as
    before.
  - **Planner.** `FramePlanner.plan` reuse is translation-aware: viewport
    row `r` replans when damaged, reuses retained row `r - delta` (runs
    rewritten to name `r`) inside the shifted region, and reuses `r`
    untranslated outside it.
- Measurements, t5 probe (600 events, 179x66, before figures from `F13`):

  | scenario, 1 line/delivery | rows/frame | ideal | planner rows/frame | planner cells/frame | `.full` frames | glyphs/frame |
  | --- | ---: | ---: | ---: | ---: | ---: | ---: |
  | `text-line` before (`F13`) | 66 (`.full`) | 2.0 | 66 | 11,814 | 100% | 11,570 |
  | `text-line` after | **2.0** | 2.0 | **2.0** | **358** | **0%** | 11,570 |
  | `text-line-at-budget` after | **2.0** | 2.0 | **2.0** | **358** | **0%** | 11,570 |
  | `bare-newline` after | 2.0 | 1.0 | 2.0 | 358 | 0% | 636 |
  | `rewrite-bottom-row` control | 1.0 | 1.0 | 1.0 | 179 | 0% | 356 |

  At 8 lines per delivery the after reads 9.0 rows against ideal 9.0; at 91
  (one 16 KiB turn) it reads 64.4 against ideal 64.4 with 6 of 7 frames
  `.full` -- `F13`'s 1.0x flood end, where the composition collapses at the
  region height and the flood fast path deliberately returns to `.full`
  once pending damage covers the viewport, restoring the pre-`T9`
  zero-cost delivery tail. The control is unmoved at 1.0 rows and
  356 glyphs, and the at-budget arm is byte-identical to below-budget at
  every delivery size. Glyphs per frame stay at 11,570 with the folded
  (view-facing) rows at 66: that is the view half, intact by design.
- Measurements, live (`t9-lines-per-delivery.sh`, release, 40-row grid,
  per-publish trace; the before arm is `F19`'s retained capture, which
  predates `T10` as well -- publish counts differ for that reason, but the
  per-line damage shape is `T9`'s dimension alone):

  | scenario | full-damage publishes (before -> after) | damaged rows per scrolled line (before -> after) |
  | --- | ---: | ---: |
  | paced 30/s | 184 of 369 -> **0** of 307 | 39.7 -> **2.0** |
  | paced 240/s | 1,416 of 2,880 -> 0 of 945 | 39.9 -> 1.39 |
  | paced 960/s | 5,096 of 11,497 -> 0 of 1,049 | 39.9 -> 1.11 |
  | `cat` full speed | 18,410 of 18,415 -> 782 of 787 | whole grid -> whole grid (`.full`, by the flood fast path) |

  Before, a scrolled line touched the whole 40-row grid however it was
  expressed -- `.full` below the budget, a whole-viewport row set at it
  (the 0.5 full-damage share is eviction's chunking flipping between the
  two). After, the paced steady state -- the regime `F19` measured at one
  whole screen per line -- publishes exactly the vacated row plus the
  cursor pair. The flood deliberately stays `.full`: `F13` measured its
  amplification at 1.0x, so once accumulated damage covers the viewport
  the fast path stops paying shift bookkeeping for a translation no
  consumer can exploit, and the drained shape there is byte-for-byte the
  pre-`T9` one.
- Verification, equivalence gates (all passing):
  - `TerminalShiftDamageTests` (value/composition semantics, the exit test
    that replaces the sanitizer pin) and `TerminalScrollShiftDamageTests`
    (scroll-site behavior in nine scenarios, including the at-budget arm
    asserting the identical drained value across 200 eviction-frozen
    scrolls).
  - `ShiftDamagePlanningTests`: reused plan equals from-scratch plan on
    every frame across below-budget, at-budget, DECSTBM-footer,
    alternate-screen, selection-over-push, overlay-fallback, and
    IL/DL-around-cursor scenarios, each asserting its shifted-frame count
    so it cannot pass vacuously.
  - `RenderCorpusPlanningTests`: the corpus-wide overlay and row-reuse
    equalities now run with shift-carrying damage over every danterm and
    libvterm fixture.
  - `ExecutorContractTests.shiftDamageRedrawMatchesFullFrame`: bitmap
    equivalence at the drawing seam -- an incrementally redrawn scrolled
    screen is byte-identical to a full redraw, whole-viewport and
    `DECSTBM` sub-region.
  - `just test`: 75 of 75 steps; 1,067 TerminalCore and 187 TerminalPTY
    tests.
- Measurements, the paired benchmark -- and this is the one gate that did
  not land where `D7` expected. `D7` scoped the ladder as a non-regression
  check "expected `equivalent`" because its 16 KiB framing sits at the 1.0x
  flood end; the calibrated `benchmark-confirm baseline=HEAD` read:

  | workload | verdict |
  | --- | --- |
  | `terminal-feed` | equivalent (+0.09%) |
  | `scrollback-stream` | **slower (+2.46%**, 4 pairs) |
  | `content-churn` | inconclusive (+0.77%; process CPU -4.22%, descriptive) |
  | `style-churn` | inconclusive (-0.83%; process CPU -3.63%, descriptive) |
  | `incremental-mixed` | **faster (-6.12%**, 6 pairs; plan time -7.08%) |
  | `retained-browse` | equivalent (-0.20%) |

  The `scrollback-stream` cost was chased before being accepted as real.
  The first implementation translated pending rows with a per-row loop and
  read `slower` +19% (`quick`); replacing it with the word-level barrel
  shift `D7`'s sketch named took the GUI drain to +0.4%, and a flood fast
  path (once pending damage covers the whole viewport, a further shift
  carries no information, so the site records `.full` and restores the
  pre-`T9` zero-cost delivery tail) removed the rest of the drain delta.
  What remains is sized by the committed
  `t9-headless-drain-ab.py` (interleaved arms, the instrument `F17`'s
  precedent trusts for drain-sized effects): **+1.60% median** across five
  rounds, with an A/A control at -0.79% showing the ordering if anything
  understates it -- so the true flood-drain cost is ~2%, agreeing with the
  calibrated +2.46%. Attribution: every new symbol on the path
  (`recordScrollDamage`, the shift compose, the guard, the drain) totals
  0.66% of 11,293 feed samples, and the two arms' profile shapes are
  identical frame for frame at sampling resolution -- the majority of the
  cost is unattributable there, consistent with feed-loop code layout
  shifting under the rewrite. The `quick` invocations along the way read
  +10% to +19% on the same change, driven by a draw-tail metric that
  swung 11.9-24.9 ms across four runs of both arms -- `18/D7`'s unbuilt
  variance study, visible live.
- Structural result (`T20`, measured as absence by
  `t9-shift-damage-structure.sh`): the damage path holds no `Set`, no
  hashing, and no sort anywhere from accumulator to consumer;
  `TerminalDamageSpans.swift` and its free functions are deleted with
  spans/halo as methods on the bounded value; `init(rows:)`'s
  `filter { $0 >= 0 }` and `negativeRowsCannotEnterDamage` are deleted,
  replaced by construction traps. `F11`'s per-frame apparatus -- 4 `Set`
  allocations, 3 array allocations, 386-721 hash operations, the
  never-needed `sorted()` -- is not zero-count at runtime; the sites are
  gone from the source. One allocation honestly remains: the drain copies
  the accumulator's word array (one or two words at these geometries) into
  the drained value, so `T3`'s "zero allocations" is met for sets and
  hashing but not to the last array; `t3-damage-round-trips.py` is retired
  with a pointer to its successors.
- Competing interpretations: the 2.0-rows figure could be read as the probe
  measuring its own stimulus rather than production; the live trace is the
  answer -- real paced producers in a real pane publish the same 2.0. The
  planner-half glyph number (11,570 unchanged) could be read as the change
  not paying; it is the scoped seam -- `17/F6` prices glyph submission per
  occurrence, and that is exactly the view half `D7` ordered second.
- Uncertainty: the modified t5 script cannot run against the pre-change
  engine (its probe consumes the new seam API), so the before column is
  `F13`'s recorded run rather than a same-day re-run; both are exact counts
  of deterministic stimuli, so the comparison is not timing-sensitive. The
  live sampler's paced-240/960 rows-per-line below 2.0 reflect `T10`'s
  batching (several lines share one publish's vacated-plus-cursor rows),
  not additional `T9` machinery.
- Inference, and the open trade this half leaves on the table: the paced
  regime -- `F19`'s common producer shape -- stops paying a whole screen of
  planning per line, `incremental-mixed` reads a calibrated `faster`
  -6.12%, and the flood end pays a calibrated +2.46% on
  `scrollback-stream`, two thirds of it unattributable to any new symbol.
  `D7` predicted `equivalent` there and was wrong by that margin; the
  README's task entry carries the deviation so the decision to keep, spend
  further effort on, or revert the flood cost is made in the open rather
  than defaulted. The precedent that parked `T7` at +1.7% differs in one
  material way: `T7`'s win was unpaid at the time, while `T9`'s is counted,
  live, and in a regime no ladder workload can contain.
- Next action: the view half -- `scrollRect`-style backing-store
  translation behind the same bitmap gate, retiring the fold in
  `clipFramePlan` and `publish` -- is now the smallest remaining slice of
  `T9` and owns the glyph dimension (11,570 to ~178 plus halo). `F20`'s
  draw-bound-cycle observation predicts the flood's publish rate rides up
  toward the display ceiling once whole-screen planning stops being the
  cycle's cost; re-run `t4-publish-rate.sh` after the view half to check.
  If the flood-drain +2.46% is judged worth further work before that, the
  two named leads are the feed-loop layout (the unattributed majority) and
  an earlier flood cutover in `recordScrollDamage` (escalate at half the
  region height instead of full coverage, trading the tail of `F13`'s
  decaying curve for drain cycles).

### F22 -- `scroll(_:by:)` on a layer-backed view preserves no bits: it schedules a silent repaint of the copy-destination region and the rest of the store is not guaranteed either

- Status: measured and decisive; this is the live trust probe `D7` required
  before the view half could build on an AppKit backing-store copy. The
  verdict is negative in every reading, so the view half cannot be realized
  with `scrollRect` and must own its pixel persistence instead (see the
  `D7` addendum).
- Date and investigator: 2026-08-08, T9 view-half implementation agent.
- Commit and worktree state: working tree on `558a8103`, macOS 26.5.2
  (25F84), backing scale 2.0.
- Commands, inputs, or reproduction:
  `xcrun swift scripts/research/33/t9-scrollrect-trust-probe.swift` from a
  logged-in GUI session. The probe builds the view the way
  `SwiftTerminalSessionView` is built (`wantsLayer = true`, flipped, layer
  background color, buffered window), draws eight 40 pt color bands, lets
  AppKit commit, then calls `scroll(bounds, by:)` (the Swift name of
  `scrollRect:by:`, deprecated since macOS 10.14) with no redraw of its
  own. After the first display every further `draw(_:)` paints a solid
  sentinel, so a post-scroll repaint cannot repaint the band pattern and
  masquerade as "the scroll was a no-op" -- the first, sentinel-free run
  did exactly that and read as UNCHANGED. Readback is `CALayer.render(in:)`
  of the view's layer (`NSViewBackingLayerContents`);
  `CGWindowListCreateImage` is obsoleted in macOS 15 and ScreenCaptureKit
  needs a TCC grant an unattended probe cannot give, so the WindowServer
  channel is unavailable.
- Measurements or examples, two deltas, both with the sentinel armed:
  - delta -1 band (the terminal scroll shape, content up): the view's
    `needsDisplay` stays false, yet one `draw(_:)` arrives on the next
    runloop turn with dirty rect `(0, 0, 320, 280)` -- exactly
    `bounds.offsetBy(delta) intersect bounds`, the copy-destination
    region. After it, every band row including band 7 (`280..<320`, which
    neither the "copy" nor the repaint touched) reads as background, not
    as its pre-scroll color.
  - delta +2 bands: same shape -- silent repaint of `(0, 80, 320, 240)`,
    the destination region again, and every row outside it reads as
    background too.
- Observation: three facts, each individually disqualifying. (1) No bits
  move: the layer contents never show translated bands. (2) The scroll
  schedules a repaint of the whole copy-destination region -- the region
  the optimization exists to avoid repainting -- so "trusting" it costs a
  region-wide redraw per scroll, the folded behavior with extra steps.
  (3) The repaint is invisible to the view's own `needsDisplay` flag, and
  rows outside the repainted rect do not retain their previous contents,
  which in production paints stale or undefined rows -- the tearing
  failure mode `D7` named.
- Inference: the AppKit-managed backing store of a layer-backed view
  cannot be translated by any public API on this macOS: `scrollRect:by:`
  is deprecated redraw-based compatibility shimming, and
  `translateRectsNeedingDisplayInRect:by:` only shifts dirty rects by
  contract. A view-half translation therefore requires the view to own a
  frame store it can translate itself; AppKit's store can only ever be a
  blit target.
- Competing interpretations: the band-7 background reading fits a store
  reallocation (scroll discards the contents and schedules a partial
  repaint) better than a pure no-op-plus-invalidate, which would have left
  band 7 purple; the probe cannot distinguish the two, and neither
  changes the verdict -- under both, bits are not preserved.
- Uncertainty: one readback channel. `CALayer.render(in:)` reads the
  layer's committed contents object, which is the same store the
  WindowServer composites, but a WindowServer-side capture was not
  available to corroborate. The sentinel design removes the main way this
  channel could lie (a repaint reproducing the old pattern).
- Next action: realize the view half on an owned, translatable frame
  store (the `D7` addendum records the selected shape and the named
  alternative), gated by byte-level equivalence tests against a full
  redraw -- which an owned store makes possible headlessly, strictly
  stronger than the live pixel proof this probe could offer.

### F23 -- the view half lands on the owned mirror store: paced-scroll glyph submission falls 11,570 to 1,086 per frame, the flood is untouched by policy, and the F21 flood-drain trade reverses to a calibrated `faster`

- Status: implemented and verified; this completes `T9` against `D7` and its
  `F22` addendum. Both halves are now landed, each separately revertible:
  reverting the view half restores the folded seam and keeps the planner win.
  Every claim below is a count or a calibrated ladder verdict.
- Date and investigator: 2026-08-08, T9 view-half implementation agent.
- Commit and worktree state: store `0e92778d`, harness repair `630b56e5`,
  view integration `10eff94a`, probe update `fa99391a`; macOS 26.5.2,
  release configuration for the live samplers, calibrated
  `benchmark-confirm baseline=630b56e5` for the ladder.
- What the mechanism is, in the shape the `D7` addendum prescribed:
  - **The store.** `TerminalFrameBackingStore` (TerminalRenderExecution)
    owns one grid-sized bitmap at backing-pixel resolution. `apply` realizes
    a drained shift as a row-range move in owned memory (integral by
    `cellHeightPixels`' construction), then renders the damaged rows through
    the existing executor; `blit` hands any dirty rect to the window context
    as one no-copy image draw. The window's store is only ever a blit
    target, which is all `F22` left it fit for.
  - **Exactness mechanics, stricter than the folded seam.** Byte-equality
    against a from-scratch render surfaced a latent sub-pixel defect in the
    folded path's halo use: erasing the haloed bands while planning only the
    haloed rows drops an undamaged neighbor's overhanging descender ink
    (about one pixel row at 2x on the shipped font, `F6`'s +1.13 px). The
    store instead erases the haloed bands and plans the erase set's own
    halo, so every erased band is rebuilt from all rows whose ink reaches
    it; and a translation additionally redraws the region's two boundary
    rows, whose imported and outward spill a pixel move cannot keep
    correct. The folded path keeps its historical behavior, unchanged.
  - **The view.** `publish` maintains one validity bit: apply while valid,
    build only at a shift-carrying publish (one full render at the
    flood-to-paced transition), zero mirror work on `.full`, and
    `invalidateFullDisplay()` as the sole stale transition. `draw(_:)`
    serves any dirty rect -- damage spans, AppKit's union coarsening, a
    fresh layer store -- with one blit while valid, submitting no glyph
    runs; every other state draws the folded path byte-for-byte as before.
- Measurements, t5 probe (600 events, 179x66; before figures `F21`):

  | scenario, 1 line/delivery | glyphs/frame before | glyphs/frame after | ideal |
  | --- | ---: | ---: | ---: |
  | `text-line` | 11,570 | **1,086** | 178 |
  | `text-line-at-budget` | 11,570 | **1,086** | 178 |
  | `bare-newline` | 636 | **76** | 0 |
  | `rewrite-bottom-row` control | 356 | 356 | 178 |
  | `text-line` at 91/delivery (flood) | 11,570 | 11,570 | 11,290 |

  The 10.7x fall stops 6.1x above the ideal because exactness costs rows:
  the damage pair plus two boundary rows, erase-haloed, planned at the
  erase set's halo, is seven full-width run rows per scrolled frame. `T14`'s
  derived-overshoot halo (`F6`: no upward ink escape on the shipped font)
  is the named lever for most of that residue. The flood row is the
  containment policy working: `.full` frames never touch the mirror, and
  the control never builds one.
- Measurements, live (`t9-lines-per-delivery.sh --seconds 10`, release):
  paced 30/s publishes 0 full-damage frames at 2.0 damaged rows per
  scrolled line (240/s: 1.42, 960/s: 1.11, both `T10` batching); the `cat`
  flood stays `.full` on 854 of 858 publishes. `t4-publish-rate.sh`:
  publishes per draw hold at exactly 1.0 with draws at the pane's display
  cadence -- `F20`'s deadline is undisturbed by the new draw path.
- Measurements, the paired benchmark (`benchmark-confirm
  baseline=630b56e5`, the last pre-mirror commit):

  | workload | verdict |
  | --- | --- |
  | `terminal-feed` | inconclusive (+0.76%) |
  | `scrollback-stream` | **faster (-3.55%**, 4 pairs; draw tail 18.7 -> 17.0 ms) |
  | `content-churn` | inconclusive (-1.20%) |
  | `style-churn` | **faster (-6.33%**, 4 pairs) |
  | `incremental-mixed` | inconclusive (+1.39%; process CPU +8.33% descriptive) |
  | `retained-browse` | equivalent (+0.08%) |

  `F21` recorded a +2.46% calibrated `scrollback-stream` cost as an open
  trade; this change reverses it to a calibrated `faster`. The mechanism is
  consistent with the flood's rare shift-carrying frames: the one frame per
  region-height that used to fold a region-wide glyph redraw into the draw
  now renders into the mirror at publish and blits at draw, and the draw
  tail is what moved. The trade `F21` left open is closed.
- Verification:
  - `FrameBackingStoreTests`: byte-equality of translate-plus-damaged-render
    against a from-scratch render, blitted, across below-budget streaming,
    at-budget streaming (eviction-frozen `topRow`), composed multi-line
    deliveries, `DECSTBM` sub-region scrolls, row-only damage, refusal
    no-ops, and clipped blits. This is the gate that replaced `D7`'s live
    pixel proof after `F22` showed macOS 15+ leaves an unattended probe no
    readback channel.
  - UI harness path-selection pins: build-then-blit, incremental apply,
    `.full` staleness, no build without a shift, refusal rebuild, resize
    staleness. (The harness itself had not compiled since `F21` landed --
    `630b56e5` repairs the file list and the shim's damage API; it is
    excluded from the local gate, which is how the break went unnoticed.)
  - `just test`: 75 of 75 steps; `test-ui`: 213 of 213.
- Competing interpretations: the `scrollback-stream` `faster` could be code
  layout rather than the draw-tail mechanism, exactly as `F21`'s cost was
  majority-unattributable in the other direction; the draw-tail move
  (18.7 -> 17.0 ms) is the measured component. The `incremental-mixed`
  +8.33% descriptive process CPU is the one number consistent with mirror
  maintenance cost (publish-side render plus blit in a mixed workload);
  its calibrated wall-clock verdict is inconclusive, so it is an
  observation to re-check, not a regression.
- Uncertainty: the mirror adds one grid-sized bitmap per pane that enters
  the paced-scroll regime (~28 MB for a full-screen 2x pane), retained for
  the pane's lifetime; `benchmark-memory` was not run in this change and
  the plan's accepted-risk entry carries the number. Byte parity live
  depends on the mirror sharing the window's color space (the view passes
  `window.colorSpace`); a window migrating across differently-profiled
  displays goes through `viewDidChangeBackingProperties`'s full
  invalidation, which stales and rebuilds the mirror.
- Next action: none for `T9` -- both halves are landed and the task closes.
  The named follow-ups now live with their owners: `T14` derives the halo
  from measured ink overshoot (the 6.1x-over-ideal residue), and the
  `wantsUpdateLayer` full-ownership alternative stays parked in the `D7`
  addendum unless the blit ever shows up in a gate.

### F24 -- the blit showed up in a gate: on the paced stream the mirror draw costs two full-frame copies per drawn frame inside CoreAnimation, process CPU 44.1% -> 64.1%, and the D7 addendum's `wantsUpdateLayer` trigger fires

- Status: measured and attributed; diagnostic only (live process CPU and
  `sample` profiles, no calibrated verdict). This is the re-check `F23`'s
  competing-interpretations entry ordered for the `incremental-mixed`
  +8.33% descriptive CPU observation, run instead on the workload where the
  user felt it: `scripts/saturate-scrollback.sh --stream 500`, the paced
  shift regime that is the mirror's home.
- Date and investigator: 2026-08-08, post-T9 blit-cost agent.
- Setup: two isolated optimized slots on one machine session, windows swapped
  frontmost one at a time, streams never concurrent. Candidate HEAD
  (`b7ca3a72`, T9 fully landed) vs baseline `630b56e5` (last pre-mirror
  commit). 179-column pane at the slot's default window. Metric: whole-process
  CPU over a 60 s steady-state stream window (`ps -o cputime` delta), then a
  10 s `sample` per arm. Process CPU is uncalibrated and decides nothing
  (17/F15); these are paired same-session descriptive numbers plus stack
  attribution, which is what a mechanism claim needs.
- The paired numbers:

  | arm | process CPU, 60 s stream | CA::CG::Queue samples /10 s | mtl_submission | main-thread mirror maintenance |
  | --- | ---: | ---: | ---: | ---: |
  | baseline `630b56e5` | **44.1%** | 836 | 63 | -- (publish ~8) |
  | HEAD (T9 mirror) | **64.1%** | 2,626 | 400 | 364 (257 in `translateRows`) |

- The mechanism, read from the stacks. On a layer-backed view, `draw(_:)`
  does not write pixels into a backing store: it records a display list
  that CoreAnimation renders asynchronously on its `CA::CG::Queue`, into a
  Metal-accelerated drawable. The mirror's `blit` therefore records a
  `DrawImage` op whose source is a fresh `CGImage` wrapping the mirror's
  mutable memory -- and at render time CA must capture that content:
  `CA::CG::DrawImage::draw_image` -> `CA::Render::copy_image` ->
  `create_image_by_copying` -> `CGBlt_copyBytes` -> `_platform_memmove`
  copies the whole frame (~21 MB at 179x66 @2x) on the CPU, then
  `MetalContext::update_image` -> `copy_image_to_texture` pays a second
  full-frame copy into a fresh GPU buffer. 1,923 of the CG queue's 2,626
  samples are the CPU copy alone (~19% of a core). No caching is possible:
  the image is a new identity every draw, and reusing one identity would be
  wrong anyway because the pixels mutate under it. The clip to `dirtyRect`
  does not shrink the capture, and for a scroll the dirty region is the
  whole shifted region regardless.
- What died, and what was misjudged:
  - **The colorspace hypothesis is dead.** The copy is a raw `memmove`, no
    ColorSync or `CGColorTransform` frames anywhere hot -- the
    `window.colorSpace` plumbing works and the blit is conversion-free.
  - **The "bounded memcpy-scale blit" accepted risk was priced wrong.** The
    D7 addendum priced the blit as one owned-memory copy. In the real
    display path it is one recorded op that costs a CPU frame capture plus
    a GPU upload per drawn frame -- roughly two full-frame copies -- and on
    this workload that is ~3x the CG-queue cost of the glyph redraw it
    replaced (836 -> 2,626 samples; the baseline's queue time is the known
    per-glyph `compute_dod_`/`get_glyph_bboxes` cost, 17/F6).
  - **The calibrated ladder could not see this, exactly as documented.**
    The draw verdicts bracket the main thread, where the mirror is cheap
    (`draw(_:)` fell from ~56 samples of glyph-run recording to ~11 of blit
    recording; that is the draw-tail improvement `F23` measured). The cost
    moved to the CG queue -- the same off-main-thread blind spot 17/F6
    names -- and surfaced only in descriptive process CPU, first as
    `incremental-mixed` +8.33% (`F23`), now as +20 points of a core here.
- Also measured: the main thread additionally spends 866/7,087 samples
  blocked in `CA::Transaction::commit` ->
  `CABackingStoreGetFrontTexture` -> `_dispatch_sync_f_slow` waiting for
  the CG queue to drain -- queue backpressure reaching the main thread.
  The mirror's own maintenance is comparatively small: 364 samples at
  publish (257 of them the region `memmove` in `translateRows`, ~93 the
  damaged-row render).
- Competing interpretations: the two arms' 60 s windows ran minutes apart
  rather than interleaved, so machine drift is uncorrected -- but the +20
  point delta is 4x-6x any drift seen in A/A ladder work, and the stack
  attribution is independent of the wall numbers. The baseline arm's
  spot-check (40.1%) sat below its measured window (44.1%), consistent with
  ordinary variation, not a trend.
- Consequence: the `D7` addendum's parked alternative is un-parked by its
  own written trigger ("it becomes the follow-up if the blit shows up in
  the gates" -- this is that observation, in the user-facing gate). The
  structural fix is full store ownership: `wantsUpdateLayer` with the
  mirror as the layer's `contents`, IOSurface-backed so CoreAnimation
  textures from it with zero CPU copies, with swapchain-style
  multi-buffering and per-buffer damage generations so a surface is never
  written while the render server scans it. That deletes the blit, both
  per-frame copies, and the `CABackingStoreGetFrontTexture` stall, and it
  moves the drawnRowSets/clipRects harness pins and the benchmark's
  dirty-rect observation, per the addendum's own risk note. It lands
  behind the existing `FrameBackingStoreTests` byte gates.
- Next action: write the `wantsUpdateLayer`/IOSurface plan as its own task
  (`T25` in the README ledger) and treat this finding as its evidence
  base. `T14` (derived halo) stays queued behind it: `T14` shrinks the
  mirror's damaged-row render -- the 93-sample term -- not the blit, which
  is the dominant term by 20x.

### F25 -- owning the pane surface deletes both per-frame copies: CoreAnimation's CG queue leaves the process entirely, the main-thread backing-store stall falls to zero, and paced-stream process CPU goes 65.2% -> 38.0%, below the pre-mirror 45.1%

- Status: measured and attributed. The CPU figures are diagnostic only (live
  process CPU and `sample` profiles, no calibrated verdict); the ladder run is
  calibrated but its three serialized-draw cells are unreadable directionally
  for the reason below. This is `T25`'s `PO2` and `PO6`: `F24`'s paired stream
  measurement re-run with both of its arms rebuilt in the same session, so the
  new arm is not compared against a number from another day.
- Date and investigator: 2026-08-08, T25 owned-surface agent.
- Setup: three isolated optimized slots on one machine session, one at a time,
  each activated frontmost for its whole window, streams never concurrent.
  Arms: `630b56e5` (last pre-mirror commit, `F24`'s baseline), `750a98d6` (the
  T9 mirror, `F24`'s candidate), and `5fd622cf` (T25 landed). Stimulus:
  `scripts/saturate-scrollback.sh --stream 500` from one checkout in every arm,
  so the byte stream is identical. 179x66 pane at the slot's default window in
  all three, confirmed per arm. Metric: whole-process CPU over a 60 s
  steady-state window (`ps -o cputime` delta over a measured wall interval),
  then a 10 s `sample`.
- **This measurement is interleaved, which `F24`'s was not.** `F24`'s own named
  weakness was that its two arms ran minutes apart, so machine drift was
  uncorrected. Here the three arms run twice, A-B-C then C-B-A, which brackets
  each arm's two windows around the other arms'. Drift would show as a spread
  within an arm; the widest within-arm spread is 0.3 points, against a 27-point
  difference between arms.

  | arm | process CPU, round 1 | round 2 | `CA::CG::Queue` samples /10 s | `mtl_submission` | main thread blocked in `CABackingStoreGetFrontTexture` |
  | --- | ---: | ---: | ---: | ---: | ---: |
  | pre-mirror `630b56e5` | 45.2% | 44.9% | 1,048 / 1,082 | 85 / 89 | 13.8% / 14.0% |
  | T9 mirror `750a98d6` | 65.0% | 65.3% | 2,645 / 2,796 | 373 / 360 | 37.1% / 37.8% |
  | **T25 `5fd622cf`** | **37.9%** | **38.0%** | **queue absent** | **queue absent** | **0.0% / 0.0%** |

  The two reproduced arms land where `F24` put them (44.1% and 64.1% there,
  45.1% and 65.2% here; CG-queue 836 and 2,626 there, ~1,065 and ~2,720 here),
  which is what licenses reading the third arm against them.
- **The deciding evidence, per `PO2`: both attributed stack families are gone.**
  Neither T25 sample contains `create_image_by_copying`, `CA::Render::copy_image`,
  `MetalContext::update_image`, or `copy_image_to_texture` -- the CPU frame
  capture and the GPU upload `F24` attributed the regression to. All four are
  present in the mirror arm's samples from the same machine session minutes
  apart. Stronger than the family counts: the T25 process carries **no
  `CA::CG::Queue` thread and no `mtl_submission` queue at all**, so there is no
  display list being replayed and no texture being submitted for this pane's
  content. `CABackingStoreGetFrontTexture` -- `F24`'s main-thread stall waiting
  on that queue to drain -- occurs nowhere in either T25 sample. The only
  `CGBlt_copyBytes` samples left in the T25 arm (1 and 2) sit under
  `RIPLayerBltGlyph` on the main thread: glyph rasterization into our own
  surface, which is a different stack.
- **What moved onto the main thread, priced.** The plan's accepted risk was that
  rasterization moves from CA's queue into the publish path. It did, and it is
  visible: of 7,418 main-thread samples in 10 s, 1,886 are inside `publish`,
  1,797 of them the swapchain render (`drawRenderFrame` 508, `draw_glyphs` 324,
  `RIPLayerBltGlyph` 273). Against that, `CA::Transaction::commit` falls from
  1,504 samples (pre-mirror) and 2,970 (mirror) to 179.
- Measurements, the paired calibrated ladder (`benchmark-confirm
  baseline=750a98d6`, the last pre-T25 commit):

  | workload | verdict | descriptive process CPU |
  | --- | --- | ---: |
  | `terminal-feed` | equivalent (-0.09%) | -- |
  | `scrollback-stream` | **faster (-7.87%**, 4 pairs; draw tail 19.6 -> 12.4 ms) | -- |
  | `content-churn` | slower (+163.09%) -- bracket moved, see below | +18.82% |
  | `style-churn` | slower (+163.15%) -- bracket moved, see below | +18.37% |
  | `incremental-mixed` | slower (+159.31%) -- bracket moved, see below | -8.69% |
  | `retained-browse` | equivalent (-0.28%) | -- |

  **The three `slower` cells are the bracket, not a regression, and no
  directional claim is issued from them.** `T25` moved
  `drawNanosecondsPerDraw` out of `draw(_:)` and onto the surface render site,
  so it now contains the glyph rasterization CoreAnimation used to replay after
  the draw returned -- outside the old bracket. The number measures more of a
  frame than the frozen rules were calibrated against. The honest cross-check is
  the process CPU line beside each cell, which is summed over every thread and
  so can see the replay the old bracket could not: +18.8%, +18.4%, -8.7%. The
  two-digit rise on the full-screen churns is an open descriptive observation,
  not a verdict, and it sits against a 27-point *fall* on the paced stream that
  the same instrument measured above -- the two workloads differ in that the
  churns redraw the whole grid every frame while the stream shifts it.
  `scrollback-stream` and `retained-browse` are unaffected by the move and
  carry their verdicts normally.
- **`PO6` could not run at all until the benchmark's acceptance rule moved off
  the rendered rectangle.** The first ladder attempt returned no decision:
  every `incremental-mixed` block on the candidate arm produced 1 of 50
  serialized draws and then stalled. `TerminalBenchmarkObserver` accepted a draw
  for that workload only when the drawn rectangle spanned exactly 6 rows -- 4
  damaged rows plus the glyph halo -- and a render now brings a stale swapchain
  buffer current over the damage composed since that buffer was last displayed,
  so it never spans exactly 6. No draw was acknowledged, the serialized producer
  waited forever, and the whole invocation was invalidated. The rule was moved
  onto the stimulus, where the sparse-span workloads already select: the app
  publishes an `acceptedDrawTopology` artifact carrying each accepted draw's
  engine damage, and both the app and the validator gate on that. The measured
  contract is 4 rows in 1 span, plus 5 rows in 2 spans for the first update
  after the settling frame, which also damages the row the cursor vacates. The
  full-screen workloads keep the rectangle rule, which staleness cannot widen
  past the whole grid. Coverage for the gate is read from each arm's own source
  tree rather than inferred from a missing artifact key, so a baseline older
  than the instrument stays comparable while a candidate whose publish path
  broke cannot pass as one.
- Measurements, t5 (`t5-scroll-amplification.py`, 600 events, 179x66): every
  cell is byte-identical to `F23`'s -- 1,086 glyphs per frame at 1 line per
  delivery for both `text-line` arms, 76 for `bare-newline`, 11,570 for the
  91-line flood, 356 for the `rewrite-bottom-row` control. That is the expected
  reading and it is a coverage statement rather than a null result: t5
  instruments the engine and the planner, which `T25` did not touch, so it
  measures the **per-publication** term. The flood arm's region render is
  intact, which is what that row was there to check.
  What t5 cannot see is the composed term. A buffer reacquired from a 3-deep
  swapchain is up to 3 generations stale and its bring-current applies the
  damage composed since it was last displayed, so a render submits the glyphs of
  the composed damage rather than of one publication -- which is why the plan
  recorded that 1,086 is not the ceiling. That bound is structural rather than
  measured here: the swapchain's headless pins hold every acquisition to
  applying exactly the composed stale damage or escalating to a full render, and
  the harness pin "a publish renders exactly the rows its damage names" holds
  the view side to it. A live per-render row count is not instrumented.
- Verification: `just test` 75 of 75 steps, `just test-ui` 215 of 215, and a
  `-DDANTERM_TERMINAL_BENCHMARK` build.
- Competing interpretations: the CPU figures are uncalibrated process CPU and
  decide nothing on their own (17/F15) -- they are here because they are
  `F24`'s own metric, re-run so the two findings are comparable. Interleaving
  corrects drift between arms, but the session carries no machine-invariant
  control, so a step change affecting all three arms equally would be invisible;
  the stack attribution is independent of the wall numbers and is what the
  conclusion rests on. The T25 arm landing 7 points *below* the pre-mirror arm
  is the one result no prior finding predicted: the profile attributes it to the
  display-list replay the pre-mirror arm also paid, but that arm's own CG-queue
  term (~1,065 samples of 10 s) is smaller than 7 points of a core, so part of
  the gap is unattributed.
- Uncertainty: memory was not measured. The plan's accepted risk stands at two
  to three grid-sized surfaces per displayed pane against one mirror bitmap plus
  AppKit's backing store, and `benchmark-memory` has not been run to price the
  net. The +18% descriptive process CPU on the two full-screen churn workloads
  was unexplained here; `F26` attributes it.
- Next action: none for `T25` -- the task closes. `T14`'s derived halo is the
  named lever on the residue t5 still measures. `F28` subsequently re-screened
  the three serialized-draw rules and deleted the structurally false dirty-rect
  fallback evidence.

### F26 -- the churn CPU rise is rasterization coming on-CPU: the old path shaded the full grid on the GPU through CoreAnimation's display-list renderer, and T25's software render costs more process CPU than the machinery it deleted

- Status: measured and attributed. Diagnostic only -- Time Profiler traces and
  unpaired `ps` deltas; process CPU carries no verdict (17/F15). This is the
  mechanism pass `F25` left open on its +18.8%/+18.4% descriptive churn cells.
- Date and investigator: 2026-08-08, T25 follow-up agent.
- Commit and worktree state: candidate `8c52d6e4` (tracked tree clean, one
  untracked plan file); baseline `750a98d6` (`F25`'s ladder baseline, the last
  pre-T25 commit) in a linked worktree. One machine session, arms alternated.
- Commands, inputs, or reproduction: `just benchmark-trace
  full-screen-content-churn "Time Profiler" 20` twice per arm plus one
  `full-screen-style-churn` trace per arm, six traces total; then
  `terminal-benchmark-profile.sh loop full-screen-content-churn` per arm with
  30 s `ps -o cputime` deltas on the app and on WindowServer, bracketed by a
  30 s idle-desktop control.
- Result or artifact paths: `.build/terminal-benchmark-profiles/`
  `2026-08-08-19{2316,2547,2629}-*` (candidate) and the worktree's
  `2026-08-08-19{2715,2852,3111}-*` (baseline), each with `profile-report.json`
  and `profile-folded.txt`.
- Measurements, whole-process on-CPU totals per 20 s trace (accepted-draw
  rates matched across all six runs, 104.3-106.2/s, so the totals compare
  per-frame work):

  | run | baseline | T25 | delta |
  | --- | ---: | ---: | ---: |
  | content-churn, round 1 | 8.59 s | 10.60 s | +23.3% |
  | content-churn, round 2 | 8.63 s | 10.41 s | +20.7% |
  | style-churn | 8.98 s | 10.52 s | +17.1% |

  Composition of the content-churn round-1 pair (inclusive seconds of CPU;
  folded-stack sums):

  | term | baseline | T25 |
  | --- | ---: | ---: |
  | main thread | 4.54 | 9.71 |
  | all other threads | 4.05 | 0.89 |
  | render seam, inclusive (`draw(_:)` / `publish`) | 1.22 | 7.47 |
  | `drawRenderFrame` inside it | 0.62 | 6.25 |
  | `CA::Transaction::commit` | 2.33 | 0.65 |
  | `CA::CG::Queue` | 2.94 | absent |
  | -- of which `compute_dod_` glyph-bounds recompute (`17/F6`) | 2.12 | -- |
  | -- of which `draw_glyph_bitmaps` mask preparation | 0.44 | -- |
  | -- of which `MetalContext` submission | 0.23 | -- |
  | solid fills (`memset_pattern16` under `CGContextFillRect`) | 0 | 3.62 |
  | glyph colorize/blit (`CGSColorMaskCopyARGB8888` / `RIPLayerBltGlyph`) | 0 / 0.01 | 1.33 / 1.51 |

  Live 30 s `ps` deltas under the sustained content-churn loop: app 13.02 s
  (baseline) against 15.06 s (T25), +15.7%; WindowServer 12.86 s against
  14.70 s, from an idle-desktop 0.57 s.
- **Observation: the baseline pays no CPU anywhere to fill or shade pixels.**
  Its in-process profile has zero samples in every fill/blit family
  (`memset_pattern16`, `argb32_mark`, `CGSColorMaskCopyARGB8888`;
  `RIPLayerBltGlyph` at 0.01 s), and WindowServer's CPU is the same
  compositing-sized cost under both arms, so the raster is not out-of-process
  CPU either. The only raster-adjacent CPU the baseline carries is glyph-mask
  preparation (0.44 s) and Metal submission (0.23 s) on the `CA::CG::Queue`,
  alongside `CA::OGL`/`MetalContext` frames that T25's profile lacks entirely.
  The full-grid shading therefore ran on the GPU, inside CoreAnimation's
  display-list renderer. T25 rasterizes the same grid in software inside
  `publish`: 6.25 s of `drawRenderFrame`, over half of it one memset family
  filling background rects (34% of the whole process), plus glyph mask
  colorize-and-blit.
- Inference: the +18% is work changing account, not new frame work. Per 20 s,
  T25 deletes ~5.2 s of in-process machinery -- display-list encode (0.62),
  the CG queue (2.94, mostly `17/F6`'s per-glyph bounds recompute), and most
  of the commit (2.33 to 0.65) -- and adds ~6.2 s of software raster, so
  full-grid workloads net +1 to +2 s. The sign flips with redrawn area
  because the added term scales with pixels shaded per frame while the
  deleted terms scale with glyph count and per-frame machinery:
  `incremental-mixed` shades ~6 rows and reads -8.7%, and the paced stream
  shades ~2 rows plus a memmove and fell 27 points (`F25`). On the churns the
  trade is CPU up, GPU down by an unmeasured amount -- and `17/F16` still
  holds: the churns are frame-rate-capped, so none of this is throughput.
- Competing interpretations: the GPU attribution is indirect -- GPU
  utilization was not measured (`powermetrics` needs root). The supporting
  evidence is the raster's absence from both processes' CPU plus the
  baseline-only Metal/`CA::OGL` submission frames; a render-server-private
  raster thread hiding inside WindowServer's compositing budget would produce
  the same reading, and would not change the conclusion that T25 moved the
  raster into the app's own CPU account. The WindowServer numbers are single
  unpaired runs on a live desktop; the T25 arm reading 1.8 s *higher* is an
  unexplained residue this finding does not lean on. The traces include the
  instrument (`__open` 0.25 vs 0.28 s -- equal across arms).
- Uncertainty: the bucket ledger attributes ~1.4 s of the ~2.0 s round-1
  delta; the remainder is scattered main-thread cost below the named
  families. `planFrame` also read 1.28 vs 1.00 s across the arms, unclaimed
  and within these runs' noise.
- Next action: none on the ladder -- the churn process-CPU cells stay
  descriptive and are now explained, and the serialized-draw re-screen
  already owns re-arming the draw rules. If full-grid CPU ever matters, the
  profile names the lever: background fills are one memset family at 34% of
  the process, ahead of any glyph cost.

### F27 -- the derived halo lands: paced-scroll glyph submission falls 1,086 to 375 per frame on a measured ink envelope, and the byte gate catches a latent edge-strip defect the full-row halo had been masking

- Status: implemented and verified; this closes `T14` against `D9`. Every
  claim below is a count, a byte-equality verdict, or a calibrated ladder
  verdict with `F25`'s bracket caveat where it applies.
- Date and investigator: 2026-08-08, T14 derived-halo agent.
- Commands, inputs, or reproduction:
  `swift scripts/research/33/t14-ink-envelope-probe.swift` (the measurement),
  `python3 scripts/research/33/t5-scroll-amplification.py` (the gate),
  `swift test --package-path lib/TerminalCore --filter
  "FrameBackingStoreTests|RenderInkReachTests"` (the byte and shape gates).
- What the mechanism is, in the shape `D9` prescribed:
  - **The envelope.** Each styled face measures its printable-ASCII table's
    ink box at construction (`CTFontGetBoundingRectsForGlyphs`, zero glyphs
    excluded); `TerminalRenderMetrics` unions the four faces into signed
    cell-relative pixel offsets, floored on the margin and ceiled on the
    overshoot, nil unless every face maps the whole table. Measured on the
    shipped font: top margin +4 px and descender overshoot +2 px at 2x
    (worst faces +4.98 / +1.13 before rounding), +2 / +1 at 1x -- `F6`
    reconfirmed and extended to all four faces.
  - **Per-row reach.** `renderRowReaches` classifies each plan row from its
    runs: ASCII cells reach the envelope; any other single-scalar cell
    reaches one full cell past both edges (the styled face's wider cmap is
    unclipped and untabulated -- the pre-T14 assumption, kept per row as
    the worst case); multi-scalar cells, background, overlay, decoration,
    and the cursor contribute the clipped cell band. The containment audit
    behind those classes: `drawTextCell` clips the symbols face and the
    CTLine fallback, and every sprite family clips or is
    geometry-contained.
  - **The apply shape.** `TerminalFrameBackingStore` keeps a per-row reach
    ledger describing the ink its pixels currently show (full renders reset
    it, applies update damaged rows, translations move it with the
    memmove). `renderApplyShape` erases each damaged row's band extended by
    its old and new reach, and plans every row whose reach intersects the
    erased region -- so an all-ASCII damaged row erases one band plus 2 px
    and replans itself and the one neighbor above whose descenders cross
    it, where the pre-T14 shape erased three full rows and planned five.
  - **Translation edge strips.** `renderTranslationStaleStrips` prices the
    four stale strips a row translation leaves at the moved block's edges
    (imported ghost spill inside the block's edge bands, outward spill left
    in unmoved neighbors), sized from the pre-move ledger, and the two
    boundary-row redraws the mirror had carried since `F23` are deleted --
    the strips are exact where the boundary rows were approximate.
- **The byte gate caught a latent defect in the boundary-row scheme while
  the strips were being derived.** Working the reach model through the edge
  cases showed the boundary-row redraw does not cover ghost spill when a
  general-class row's ink crosses a moved block's edge and neither the
  cursor pair nor a same-delivery rewrite blankets the strip. The exposure
  needs a cursor-neutral scroll: `CSI S`/`CSI T` with the cursor parked
  mid-region, general-reach ink beside the region edge, and content that
  physically escapes its cell -- U+01FA overshoots the cell top by +1.4 px
  at 2x and U+1E01 descends +2.35 px on the shipped font, found by a
  repertoire scan after A-grave-class capitals proved to stay inside the
  cell. The new `generalNeighborsOfRegionScroll` arm reproduced it (red at
  step 2, the bare `CSI T`) against the boundary-row implementation and is
  green on the strips. The pre-T14 halo-of-halo masked the whole class by
  redrawing edge+-1 rows unconditionally; the derivation, being exact,
  found it structurally -- this is `F23`'s "stricter contract" observation
  repeating one level up.
- Measurements, t5 probe (600 events, 179x66; before figures `F23`/`F25`):

  | scenario, 1 line/delivery | glyphs/frame before | after | ideal |
  | --- | ---: | ---: | ---: |
  | `text-line` | 1,086 | **375** | 178 |
  | `text-line-at-budget` | 1,086 | **375** | 178 |
  | `bare-newline` | 76 | **20** | 0 |
  | `rewrite-bottom-row` control | 356 | 356 | 178 |
  | `text-line` at 91/delivery (flood) | 11,570 | 11,570 | 11,290 |

  The residue is 2.1x over ideal and is now exactness, not assumption: the
  fresh line, the cursor pair, and the one neighbor above whose measured
  descenders sit in each erased band's top 2 px. The control holds at 356
  for the same reason -- its neighbor's descenders really do live in the
  erased band, so `D9`'s "expected to fall toward ~178" was wrong about the
  control and the recorded value stands. The named lever on what remains is
  per-row background-identity tracking (skip erasing a damaged band's top
  overshoot strip when the background is provably unchanged), which would
  drop the above-neighbor replan; nothing currently justifies it.
  The probe now calls the production derivation (`renderRowReaches`,
  `renderTranslationStaleStrips`, `renderApplyShape`) instead of modeling
  the store gate for gate.
- Verification: `RenderInkReachTests` pins the reach classes and the
  countable shape (13 tests); `FrameBackingStoreTests` byte-equality across
  the full `D7` matrix plus the new mixed-content streaming,
  decorated-neighbor, class-transition, and region-edge arms (15 tests);
  an ablation run (plan membership widened to band-only) confirmed the
  byte gate fails when the derivation is wrong. `just test` 75 of 75
  steps; `just test-ui` 215 of 215.
- Measurements, the paired benchmark (`benchmark-confirm
  baseline=8c52d6e4`, both arms post-T25 so the moved bracket is the same
  on each; the serialized-draw thresholds are still the pre-move
  calibration, so those cells' magnitudes carry that caveat):

  | workload | verdict |
  | --- | --- |
  | `terminal-feed` | equivalent (+0.24%) |
  | `scrollback-stream` | **faster (-2.15%**, 4 pairs) |
  | `content-churn` | equivalent (-0.23%; process CPU +0.05% descriptive) |
  | `style-churn` | equivalent (-0.43%; process CPU -0.18% descriptive) |
  | `incremental-mixed` | **faster (-13.23%**, 6 pairs; process CPU -1.97% descriptive) |
  | `retained-browse` | equivalent (+0.18%) |

  The `incremental-mixed` cell is the derived halo working on the term
  `F26` priced: its 4-row damage previously became 6 erased and 8 planned
  full-width rows in the owned store's software render, and now becomes
  the damaged bands plus 2 px and the neighbors whose measured ink
  reaches them -- less area for the memset family that `F26` measured at
  34% of process CPU on full-grid work, on the workload where damage is
  small enough for the difference to dominate the render. The full-grid
  churns are untouched (their damage is `.full`, which never enters
  `apply`), which is what their `equivalent` cells confirm.
- Competing interpretations: the envelope trusts
  `CTFontGetBoundingRectsForGlyphs` as an outer bound on rasterized
  coverage; antialiasing cannot paint outside the outline's box, and the
  offsets round only outward, so the trust is one-directional -- and the
  byte gate over descender-bearing content is the check that would catch a
  violation. `F28` retired the topology's halo-derived series because they
  modeled the deleted `withGlyphHalo` shape and had no production consumer.
- Uncertainty: the reach ledger is derived state with a one-line invariant
  (it describes the rows the store's pixels currently show); a
  stale-conservative entry costs rows, never correctness. A configured
  font whose ASCII table is incomplete, or whose measurement is degenerate,
  reads a nil envelope and reproduces the pre-T14 shape everywhere.
- Next action: none for `T14` -- the task closes. The background-identity
  refinement above is the only named lever on the 2.1x residue, unowned
  and unjustified at current cost.

### F28 -- the post-T25 draw bracket re-arms content and style, refuses an incremental rule, and exposes a swapchain reset defect

- Status: implemented and verified; this closes the standing T25 follow-up and
  `T26`.
- Date and investigator: 2026-08-08, serialized-draw recalibration agent.
- Commands and inputs:
  - Collected 24 production ABBA A/A pairs per workload with
    `scripts/terminal-benchmark-plan-calibration.py --metric draw` against one
    immutable post-T25 source snapshot. Screened them with
    `scripts/terminal-benchmark-calibration.py` at the ladder's fixed pair
    counts and accuracy gates.
  - Re-ran the four frozen content/style cells with 100,000 resampling trials
    and disjoint seeds (`20260816`, `20260817`).
  - Searched `incremental-mixed` through 160 pairs in both modes rather than
    treating the fixed schedule as evidence that some threshold must exist.
  - Ran `just benchmark-confirm baseline=188d2c030104247d2ffe962f516bd2afece622e4`
    eight times. The unreferenced baseline commit captured the implementation;
    the candidate differed only by a one-line Markdown marker. Artifacts are
    `.build/terminal-benchmark-comparisons/confirm/bf140e0954a6-0000` through
    `-0007`.
- The first screen was not calibration evidence. Its
  `incremental-mixed` blocks unpredictably included one wide or full render:
  only the most recently used swapchain buffer had absorbed setup damage, so a
  later block could acquire a cold buffer and pay old whole-frame work inside
  a supposedly settled four-row draw. The initial artifact is
  `.build/terminal-benchmark-draw-calibration/ff7a70d2d145-0000`; intermediate
  artifacts are diagnostic only.
- The ideal reset is now structural. `TerminalFrameSwapchain` tracks the latest
  whole-frame damage generation, can require every buffer to render again, and
  prioritizes buffers that have not crossed that convergence barrier. At the
  first marker draw, the benchmark requests one barrier. The producer then
  serializes distinct settling frames until the app acknowledges that all
  surface buffers have rendered the latest whole-frame generation. Each block
  records `surfaceBuffersSettled`, and validation rejects the block when it is
  absent or false. The final topology probe accepted exactly 400 of 400
  incremental draws at four damaged rows, with no wider draw.
- Final 24-pair screen at tree `cb0b9d233d49`, zero discarded quartets:

  | workload | median | SD | range | frozen quick | frozen confirm |
  | --- | ---: | ---: | ---: | --- | --- |
  | `content-churn` | -0.42% | 1.34% | -3.55%..+2.40% | 2 pairs, +/-2.0% | 4 pairs, +/-1.5% |
  | `style-churn` | +0.46% | 1.45% | -4.20%..+2.60% | 2 pairs, +/-2.0% | 4 pairs, +/-1.75% |
  | `incremental-mixed` | +2.64% | 15.14% | -27.21%..+32.36% | no rule | no rule |

  The 100,000-trial freeze measured zero quick false positives and 1.0000
  detection for both workloads. Confirm measured 0.00683 false positives and
  0.99654 detection for content, and 0.00662 / 0.95801 for style. Each clears
  the under-1% false-positive and at-least-90% detection gates.
- `incremental-mixed` has no defensible directional cell. No threshold cleared
  either mode even at 160 pairs. Keeping its old threshold would turn measured
  noise into authority; lengthening every routine comparison would spend much
  more time without repairing the GUI regime. The robust route already exists:
  damage drawing uses `benchmark-headless-draw`, while the GUI cell keeps its
  topology and percentage as descriptive evidence under
  `docs/design/2026-07-27-damage-render-benchmark-routing.md#D2`.
- Held-out whole-invocation gate: all eight content results were `equivalent`
  or `inconclusive` (largest magnitude 0.99%); all eight style results were
  `equivalent` or `inconclusive` (largest magnitude 1.75%); incremental emitted
  no verdict in every invocation while estimates ranged from -5.16% to +5.55%.
  Therefore none of the three serialized-draw cells made a false directional
  claim. The same noisy session produced one false `faster` call each on
  `scrollback-stream` and `retained-browse`; those unrelated pre-T25 rules keep
  `research/31/F18`'s warning and do not weaken this draw-specific gate.
- Dead machinery deleted in the same schema change:
  `usedDirtyRectFallback`/`dirtyRectFallbackCount`, which T25 made structurally
  false; `haloDamagedRowCounts` and `haloSpanCounts`, which modeled the T14-
  deleted view halo; and the performance guide's live Core Animation replay
  blind-spot framing. Process CPU remains a descriptive all-thread diagnostic,
  but owned-surface rasterization is now inside the deciding draw bracket.
- Verification: focused Python suites (133, 79, and 85 tests across the
  validator, comparator, producer, calibration, and topology artifact paths),
  `FrameSwapchainTests` (6 tests), and
  `TerminalBenchmarkDamageTopologyRecorderTests` (8 tests) pass. `just test`
  passes all 75 steps. `just test-ui` passes 215/215 on the confirming run; its
  first run passed 214/215 when the existing IOSurface release-timing viability
  check transiently reported the swapped-out surface still in use, while the
  companion detached-surface safety check passed on both runs.
- Next action: none for the serialized-draw recalibration. `T24` remains the
  independent confirm block-floor debt.
