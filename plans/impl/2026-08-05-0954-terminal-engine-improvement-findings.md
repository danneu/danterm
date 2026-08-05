# Terminal engine improvement findings (2026-08-05)

Read-only audit of the Swift terminal engine (`lib/TerminalCore`, `lib/TerminalPTY`,
the app-side engine integration, and terminal-related docs), produced by 12 Opus 5
finder agents partitioned by subsystem, each followed by an Opus 5 adversarial
verifier that tried to refute every finding against the actual code (call sites,
fixtures, hot-path constraints). Old libghostty-era code, `plans/`,
`plan-terminal-engine/`, and `*.generated.swift` contents were out of scope.
The audit itself changed no files.

This doc is now the working record for acting on those findings: it lives here so
commits can point at it and a later reader can see what drove a change. Each finding's
`**Status:**` line is updated as the work lands.

Verdicts:

- **confirmed** -- every factual claim checked out and the recommendation is safe as written.
- **downgraded** -- the problem is real, but the verifier's note names a required adjustment; read it before acting.
- **rejected** -- refuted; kept in the appendix for the record.

Totals: 106 findings -- 71 confirmed, 32 downgraded, 3 rejected.

## Outcome

**Closed.** 102 done, 1 partial by design (32), 3 rejected by the original verifiers
(104-106). Every accepted finding landed, gate green (`just test`, 74 steps) on each
commit. Work spans `b1130938..HEAD`; commit messages cite this file by path and list
the finding numbers they close.

Four findings (5, 7, 9, 13) were parked mid-run as design decisions rather than
mechanical fixes, briefed out separately, and resolved afterwards -- each one's Status
line records what was decided and on what evidence. Their resolutions were *not* what
the audit proposed in three of four cases; see those Status lines before trusting the
recommendation text above them.

What remains is in **Orchestrator follow-ups** below: nothing from the audit itself,
but two deliberate non-fixes, two optional cosmetics, one new defect this work
surfaced, one docs obligation, and two gate flakes needing a call.

## Work tracker

Every numbered finding carries a `**Status:**` line. Statuses:

- `done` -- applied and the gate passed.
- `partial` -- part of the finding applied, the rest deliberately not; the status line
  says which and why. Only finding 32.
- `rejected` -- refuted by the original verifier; 104, 105, 106. No action.
- (`todo` / `in-progress` / `deferred` / `dropped` were used while the work was in
  flight and no longer appear.)

Work was partitioned into batches by **exclusive file ownership** so concurrent agents
never edited the same file; an agent needing coverage in a file it did not own added a
new test file rather than editing the foreign one. The table is kept as the record of
that partition -- it is not a to-do list.

| Batch | Owns | Findings |
| --- | --- | --- |
| `store` | `LogicalLineStore/Record`, `PackedRetainedRow` + their suites | 1, 8, 14, 20, 28, 31, 47, 48, 71, 76, 77, 83, 84, 87, 95, 101 |
| `terminal` | `Terminal.swift` | 24, 27, 30, 46, 96 |
| `parser` | `EscapeAbsorber`, `CanonicalCaseless`, recording codec, interaction policy | 3, 22, 32, 34, 41, 53, 89 |
| `render-plan` | `RenderFramePlanner` + planning suites | 16, 18, 33, 43, 52, 54, 69, 79, 91 |
| `render-exec` | sprite geometry, `TerminalRenderExecution` + execution suites | 10, 19, 21, 25, 35, 36, 37, 44, 57, 62, 72, 78, 81 |
| `pty` | `lib/TerminalPTY` sources + suites | 4, 15, 17, 23, 29, 38, 39, 40, 42, 45, 60, 65, 73, 75, 80 |
| `probes` | memory/resize/draw/browse/occupancy probe supports + suites | 6, 12, 26, 63, 66, 70, 82, 86, 93, 97, 99 |
| `app` | `app/TerminalBenchmark`, `app/SwiftTerminalSessionView` | 2, 11, 100 |
| `tests-a` | `TerminalCoreTests` subset A | 49, 50, 51, 55, 56, 58, 59 |
| `tests-b` | `TerminalCoreTests` subset B | 61, 64, 67, 68, 74, 85, 90 |
| `docs` | prose under `docs/`, `agent-docs/` | 92, 94, 98, 102, 103 |
| `solo` | cross-cutting duplicate-helper sweeps; run alone, last | 21, 78, 88, 90 |

Findings 5, 7, 9 and 13 sat outside the batches: they were pulled out as design
decisions and landed separately, after the twelve batches were done.

## Orchestrator follow-ups

Everything the audit itself asked for is done. What follows is what the work *left* --
each entry says what the state is, why it is that way, and what a decision would have
to settle. Nothing here blocks the audit being closed.

### Open: needs a decision

- [x] **Gate flake A -- the tail-cost ratio test.**
  `TerminalHistoryTailTests#tailReadCostTracksTheBudgetNotTheCapacity` asserts
  `large < small * 4`, comparing a bounded tail read over 400 lines against one over
  6,400. It failed twice inside the 74-step parallel `just test` pool (observed 0.244s
  vs 0.196s, ratio 5.0) and passed 5/5 in isolation and on every rerun.
  **Why it is not a regression:** the failure mode it guards -- a read that walks from
  the head instead of the budget -- would show ~16x, matching the 16x history growth.
  A ratio of 5.0 is scheduling noise, not a linear walk. The test's own comment says 4x
  was chosen to leave "room for scheduling noise on a loaded machine"; the gate's
  parallel pool is a heavier load than that estimate assumed.
  **The decision:** loosen the threshold (say 8x, still far below 16x and still able to
  fail a full walk), make the instrument load-robust (best-of-N rather than a single
  timed pair), or move it off the parallel gate entirely. Note this is the same class
  of wall-clock test that finding 47 deleted two of, so "delete it" is on the table --
  but unlike those two it guards a live path (`I3`, the checkpoint tail read) with no
  other cover, so deleting it needs a replacement that pins the bound structurally.
  **Resolved 2026-08-05:** fixed the instrument, not the bound. `tailCost` now runs three
  times per size and the minimum is taken for each of `small` and `large`; noise is
  one-sided (preemption only adds time), so min-of-3 strips it while a real full-history
  walk still shows its ~16x. Threshold stays at 4x, the warm-up call stays, and the
  comment block records the two observed gate failures. Verified: 6 consecutive isolated
  runs green, plus the full 74-step gate.

- [x] **Gate flake B -- the agent-notifications live test.**
  `scripts/tests/agent-notifications-live_test.py::test_auth_symlink_cleanup_does_not_remove_auth_target`
  failed once in the gate with `OSError: [Errno 22] Invalid argument` from `os.stat` on
  a symlink under `/var/folders/.../auth.json`, inside a `drive_pty` readiness predicate
  that polls `link.exists()` while the child unlinks it. Passed 22/22 standalone and on
  the gate rerun.
  **Unrelated to any audit finding** -- noted only because it is the second gate step to
  flake under the parallel pool, which makes "the pool is oversubscribed" worth
  considering as a common cause rather than treating each flake in isolation.
  **The decision:** whether to harden the predicate (treat `OSError` as "not yet gone")
  or leave it as accepted noise.
  **Resolved 2026-08-05:** hardened the predicate. The readiness lambda now calls a local
  `link_gone()` helper that catches `OSError` from the existence check and returns False,
  so a stat that lands mid-unlink just means "not settled yet, poll again" instead of
  raising. The comment naming the TOCTOU race sits on the helper; the existing comment
  about waiting for the unlink is unchanged. Verified: 5 standalone runs of the file
  (22 tests each) green, plus the full 74-step gate.

- [x] **New defect: `PaneWrapperView`'s clipboard writes have no seam.**
  `app/PaneWrapperView.swift:509-516` -- the copy-cwd and copy-session-id menu actions
  write `NSPasteboard.general` directly. Finding 11 gave the pane's own copy/paste an
  injectable `selectionPasteboard` (`app/SwiftTerminalSessionView.swift:54`) precisely
  so tests stop clobbering the developer's real clipboard; these two actions are the
  same shape in a different file and were outside that batch's ownership.
  **Not a latent bug** -- production behavior is correct -- but they cannot be tested in
  isolation, and a future test for them would repeat the exact mistake finding 11 fixed.
  The libghostty-backed paths (`app/TerminalView.swift:341`, `app/GhosttyApp.swift:222`
  and `:250`) also write `NSPasteboard.general` and were left alone deliberately: that
  code is on its way out with libghostty.
  **Resolved 2026-08-05:** gave `PaneWrapperView` a `menuPasteboard` property defaulting to
  `NSPasteboard.general`, and routed both `copyCwdAction` and `copyAgentSessionIdAction`
  through it -- the same shape as `SwiftTerminalSessionView.selectionPasteboard`, which its
  doc comment cites. The libghostty-backed writes stay untouched. Verified: `just build`
  compiles the app target clean, plus the full 74-step gate.

- [ ] **47 (docs obligation) -- record what `PO5` still covers.**
  Finding 47 deleted two wall-clock tests that guarded a `PackedRetainedRow` read path
  production no longer takes, and its verifier noted the retirement is broader than
  those two tests. **That framing needs correcting before it is written down:** the type
  is only half retired. `PackedRetainedRow.pack` has no production callers -- every
  remaining mention in `Sources/` is a doc comment citing it as precedent -- but
  `PackedRetainedRow.Header`'s bit-layout constants are load-bearing, used live by
  `LogicalLineStore` in a dozen places (`cellStyleShift`, `cellSpillBit`,
  `cellKindMask`, ...). So the honest note for doc 28 is that `PO5`'s *subject* (the
  standalone packed-row read path) is retired while its *encoding* survives inside the
  logical-line store, not that the whole type is dead.
  Left undone because amending a dated `Status: Accepted` research record is the same
  class of call as the four deferred findings.

### Open: deliberate non-fixes, recorded so they are not re-litigated

- [ ] **22 (residual)** -- `pointerDownDecision` keeps a `.link` arm
  (`TerminalInteractionPolicy.swift:520`) that `pointerOwner` can never mint, because
  the Cmd-click path latches `.link` itself and returns earlier. It is marked with a
  comment saying exactly that. Removing it would mean splitting the enum again, which is
  the opposite of what finding 22 did. **Reopen only if** the ownership model changes so
  that a link owner can be minted.

- [ ] **32 (the one `partial`)** -- the unreachable inner capacity guard in
  `EscapeAbsorber.dispatchCSI` is gone; the `csiParameter` `0x30...0x3A` / `0x3B` arm
  fold was left undone. The verifier marked that half optional and noted the split
  deliberately mirrors `csiEntry`, where 0x3A and 0x3B diverge. Folding it would save one
  line and cost that symmetry. **Reopen only if** `csiEntry`'s arms stop diverging.

### Open: optional cosmetics, no coverage impact

- [ ] **51** -- `TerminalGraphemeWidthTests#regionalIndicatorGeometry` (line 125) absorbed
  the deleted `regionalIndicatorParity`'s coverage but not its title claim ("a third
  Regional Indicator starts a new cluster"). A retitle would make the surviving test
  self-describing.
- [ ] **59** -- `tabClampsWithDefaultStopsPresent` stayed in `TerminalTests.swift:194`
  rather than moving to the adjacent `TerminalTabStopTests.swift`, because that file was
  outside the batch's ownership. One-test move if colocation is wanted.

### Closed during the run

- [x] **21** -- five sprite files re-deriving the light-stroke width -> all six now use
  `metrics.lightStrokePixels`; the `max(1, ...)` clamp each carried was dead.
- [x] **26** -- `measureDurationStable` promoted into TerminalCoreBenchmarkSupport with
  the `Package.swift` dependency edge and both preconditions carried over.
- [x] **48** -- retention guards folded into `censusReportsRetentionHealth`; the file is
  deleted.
- [x] **78** -- `BackgroundExecutionTests`' duplicate overflow helper now calls the
  shared one.
- [x] **80** -- `primaryHistoryGenerationDifferential` moved off the serialized PTY gate
  step into `TerminalHistoryGenerationTests`.
- [x] **90 (residual)** -- all seven xorshift copies now use `SeededByteGenerator`, each
  keeping its original byte/word width so the seeded sequences are bit-identical.

## Top picks

Preserved as the audit wrote it, including the framing that later turned out wrong (item
3's fix was narrowed, and the "deliberate decision" note at the end was resolved against
libvterm). **Each finding's `Status:` line is authoritative for what actually happened**;
this section is the original prioritization, not a report of it.

The highest-value items across all sections, in recommended order:

1. **Tail truncation double-subtracts a display row from the block index**
   (`LogicalLineStore.removeLastDisplayRow`) -- confirmed accounting bug; the
   decrement lands on the *preceding* block after `retireEmptyTailBlocks()` pops
   the tail block, and it does not self-heal. Small, mechanical fix. (Section 1)
2. **Closing a coalescing run resurrects superseded resizes**
   (`ResizeCoalescer.isSuperseded`) -- a backlog of drag resizes all re-apply
   `TIOCSWINSZ` + reflow after any non-resize submission closes the run. (Section 1)
3. **Erase paths never close history's open tail record** (`Terminal.eraseDisplay`,
   DECALN) -- text printed after `ESC[2J` is glued to the pre-clear logical line
   and can resurface on resize. Downgraded: the verifier narrowed the fix (do not
   sever on ED 0 with a nonzero column; requires a decisions-doc amendment and it
   is a deliberate divergence from kitty/xterm). (Section 1, downgraded)
4. **Occluded draws rewrite the whole benchmark sample file per draw**
   (`TerminalBenchmark.observeDrawState`) -- O(n^2) file rewriting inside
   `draw(_:)`; one-line dedupe fixes it. (Section 1)
5. **PO5 timing tests guard a read path production no longer takes**
   (`TerminalPackedRetainedRowTests`) -- two wall-clock ratio tests in the
   `just test` gate exercise `PackedRetainedRow` readers with zero production
   callers; browsing now reads `LogicalLineStore`. Delete or restate. (Section 3)
6. **Hyperlink admission arithmetic exists in four copies** (`setArmedLink`,
   `canAdmitArmedLink`, `dispatchOSC8`, `setHoveredLink`) -- each walks the full
   retained scrollback via `liveHyperlinkIds()`; fold into one helper. (Section 2)
7. **`strictlyDecodedUTF8` duplicates `String(validating:as:)`** -- one predicate,
   three spellings, eight sites in `Terminal.swift`; also drops per-call array
   copies. (Section 2)
8. **The cell-rect formula is spelled out seven times in the executor**
   (`TerminalRenderExecution.swift`) -- same drift risk `glyphOrigin` was already
   extracted to prevent. (Section 2)
9. **Weak-assertion test batch** -- `memoryAffectsEquality` passes on an unrelated
   field, the style-table bound is 20,000x looser than the behavior, the
   locate-budget test passes when nothing is measured, and the Powerline mirror
   test uses the production mirror as its own oracle. All confirmed with concrete
   replacement assertions. (Section 4)
10. **Shell-integration PTY test pads 6 seconds of dead sleeps** and is missing a
    `.timeLimit` -- directly speeds up the serialized PTY suite. (Section 4)
11. **`docs/terminal-capabilities.md` states a 10 MiB scrollback bound; the engine
    ships 16 MiB** (`productionScrollbackBudgetBytes`) -- wrong row in a normative
    table. (Section 5)
12. **`replay()` reports an unsupported schema version as `.invalidDimensions`**
    (`NeutralTerminalRecording`) -- trivial guard split, misleading during
    debugging. (Section 1)

Also worth a deliberate decision (not a plain bug fix): **invalid DECSTBM**
currently resets the region and homes the cursor (libvterm behavior) where
xterm/kitty/ghostty treat it as a no-op -- changing it means updating the
libvterm fixture's `recordedDeviations`, not just the unit test. (Section 1,
downgraded)

## 1. Correctness and behavior improvements

Latent bugs and edge-case handling problems in the engine. These are the findings most worth acting on first.

### 1. Tail truncation double-subtracts a display row from the block index

**Status:** `done` -- totals now move before the drop; `truncatingAcrossABlockBoundaryKeepsEveryRowAddressable` failed first ("row 63 lost its index entry"), passes now

`lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift:941` -- high confidence, small effort, found by `core-storage`

**Problem.** `removeLastDisplayRow` adjusts the totals *after* the record is dropped: `dropTailRecord` calls `retireEmptyTailBlocks()` (line 960), which pops the last `Block` when the dropped record was the only record of its block, and then line 941 decrements `blocks[blocks.count - 1].rowCount` -- which is now the *preceding* block. The row is therefore removed twice from the block totals but once from `grandDisplayRowTotal`. Every other mutator moves the totals first and drops after: `evictOneDisplayRow` says so explicitly at lines 754-764 ("The totals move first"), and `wrapWriteCursorAtSeam` does the same at lines 2261-2267.

**Recommendation.** Move `grandDisplayRowTotal -= 1` and the `blocks[blocks.count - 1].rowCount -= 1` decrement (lines 939-942) to the top of `removeLastDisplayRow`, before the `if rows == 1 { dropTailRecord(...) }` dispatch, so `retireEmptyTailBlocks` sees a block whose `rowCount` already excludes the removed row.

**Verifier (confirmed).** Checked the exact lines: `removeLastDisplayRow` (LogicalLineStore.swift:915-943) dispatches to `dropTailRecord` (945-961) which calls `retireEmptyTailBlocks()` (960) after `offsets.removeLast()`, and only then does line 941 decrement `blocks[blocks.count - 1].rowCount`. Worked the concrete case: 65 records, tail sequence 64 (i.e. sequence % 64 == 0) -> `lastBlockNumber` drops from 1 to 0, the last block is popped (863-869), and the decrement lands on block 0. Result: sum(block.rowCount) = grand - 1. It does not self-heal: `appendRecordOffset` seeds every later block's `rowStart` from `previous.rowStart + previous.rowCount` (2313-2314), so `locate(displayRow:)` (1101-1139) then misses the last row or maps rows off by one, and neither `truncateTail` caller recomputes the index (Terminal.swift#resizeRows has no recompute; Terminal.swift#resizeColumns calls `history.setWidth` at 4320 *before* the truncate at 4424). The recommended move is safe: nothing in `dropTailRecord`, `cutTail`, or `reopenTailRecord` reads `grandDisplayRowTotal`, `retireEmptyTailBlocks` ignores `rowCount`, and the offsets-empty branch clears `blocks` anyway. It also matches the two mutators that already order it correctly (754-764, 2261-2267).

### 2. Occluded draws re-serialize and rewrite the whole sample file per draw

**Status:** `done` -- sustained occlusion now contributes one sample and one checkpoint write

`app/TerminalBenchmark.swift:76` -- high confidence, trivial effort, found by `app-harness`

**Problem.** `observeDrawState()` runs inside AppKit's `draw(_:)` (reached from `observeCompletedDraw` at line 628, which `SwiftTerminalSessionView.draw` calls). When `isWindowPresentedLocally()` is false it appends a `draw-while-occluded` sample, and `record(reason:)` then calls `checkpointSamples()`, which re-serializes the entire growing `samples` array with `JSONSerialization` and does an atomic `Data.write` -- once per draw, so O(n^2) total work under the CoreAnimation transaction. That is precisely the pattern `publishActivity`'s own doc (lines 829-845) says was moved off the draw path. A window that never fits inside `screen.visibleFrame` makes it fire on every draw of the run, and `scripts/terminal-benchmark-validation.py` invalidates the block on the first sample with `visible: false`, so every sample after the first buys nothing.

**Recommendation.** In `observeDrawState()`, append a `draw-while-occluded` sample only when the last recorded sample was not already one, so a sustained occlusion contributes a single sample and a single checkpoint write.

**Verifier (confirmed).** Verified end to end. SwiftTerminalSessionView.draw calls observeCompletedDraw inside draw(_:) (app/SwiftTerminalSessionView.swift:220), which calls stateRecorder?.observeDrawState() at TerminalBenchmark.swift:628; observeDrawState -> record(reason:) -> checkpointSamples() re-serializes the whole growing samples array and does an atomic Data.write every time, and record() additionally pays the CGWindowListCopyWindowInfo round-trip in isWindowVisible(). stateResultPath is always set (scripts/terminal-benchmark.sh:217), so the write is live on every benchmark run. The validation side checks out: _append_reason dedupes (scripts/terminal-benchmark-validation.py:541-543) and the occluded loop only ever adds `-window-occluded` once, so samples after the first buy nothing. No consumer reads the reason strings or counts machineStateSamples beyond an emptiness check, so a last-sample-reason dedupe loses no artifact content; thermal/low-power transitions during a sustained occlusion are still captured by the notification observers, which fire on change. Same-file doc at 829-845 states exactly this rule for the draw path. Benchmark-only code (#if DANTERM_TERMINAL_BENCHMARK), so the blast radius is the harness, not the shipping app.

### 3. replay() reports an unsupported schema version as .invalidDimensions

**Status:** `done` -- dedicated `unsupportedVersion(Int)` case per the verifier, not a reuse of unsupportedEvent

`lib/TerminalCore/Sources/TerminalCoreRecording/NeutralTerminalRecording.swift:616` -- high confidence, trivial effort, found by `core-rest`

**Problem.** `NeutralTerminalRecording.replay` folds two unrelated failures into one `guard`: `guard version == 1, let initialTerminal = Terminal(columns:rows:...) else { throw .invalidDimensions }`. A recording with `version: 2` -- a future or corrupt schema -- is reported to the caller as `NeutralTerminalRecordingError.invalidDimensions`, which points a debugging reader at `initial.columns`/`initial.rows` that are in fact fine. The error enum already distinguishes schema problems (`unsupportedEvent`, `invalidEvent`) from geometry problems.

**Recommendation.** Split the version check into its own `guard version == 1 else { throw NeutralTerminalRecordingError.unsupportedEvent("version \(version)") }` (or add a dedicated `unsupportedVersion(Int)` case) before the `Terminal(...)` construction, leaving `.invalidDimensions` for the geometry failure only.

**Verifier (confirmed).** Verified at NeutralTerminalRecording.swift#replay (line 616): `guard version == 1, let initialTerminal = Terminal(...) else { throw .invalidDimensions }`. Nothing else in the file checks `version`, and no test or fixture exercises version != 1 (NeutralTerminalRecordingTests only pattern-matches `.invalidBase64` and otherwise uses `throws: NeutralTerminalRecordingError.self`), so splitting the guard loses no coverage and no caller switches exhaustively over the error enum. Prefer the parenthetical option: a dedicated `unsupportedVersion(Int)` case. Reusing `unsupportedEvent("version 2")` still files a schema-level failure under an event-level name, which is a milder form of the same mislabeling the finding is about.

### 4. Closing a coalescing run resurrects resizes already superseded within it

**Status:** `done` -- closed runs now seal their final submission count in a run-indexed array (verifier's shape); new ResizeCoalescerTests

`lib/TerminalPTY/Sources/TerminalPTYHost/ResizeCoalescer.swift:56` -- medium confidence, medium effort, found by `pty`

**Problem.** `isSuperseded` returns true only while `state.run == submission.run`, so once `closeRun()` bumps the run counter, every still-queued resize from the closed run reports "not superseded" and applies its full `TIOCSWINSZ` + reflow pair. The file's own rationale (lines 25-27) justifies only the *last* resize before the barrier having to apply — "a non-resize action queued between two grids reads the earlier one and must see it applied" — but the implementation resurrects all of them. Concretely: 40 drag resizes are submitted while the owner queue is busy, then one `sendPointer(.move)` from `mouseMoved` calls `closeRun()`, and all 40 reflows now run instead of the 1 that the invariant requires. The existing test `nonResizeSubmissionClosesTheCoalescingRun` only pins the single-resize-per-side case, so nothing catches this.

**Recommendation.** Record each run's final submission count when `closeRun()` seals it (e.g. a small `closedRunFinalIndex: [UInt64: UInt64]`, pruned in `isSuperseded` for runs older than the one being asked about, which is safe because the owner queue checks submissions in FIFO run order) and have `isSuperseded` compare against that sealed count for closed runs.

**Verifier (confirmed).** Verified against ResizeCoalescer.swift and the host: `isSuperseded` requires `state.run == submission.run`, and `queueClosingResizeRun()` (TerminalPTYHost.swift:392) bumps the run for every non-resize submission, so a whole backlog from the closed run reports not-superseded and each applies TIOCSWINSZ + reflow. The file's stated rationale only requires the LAST resize before the barrier to apply, and skipping the intermediates is safe for the same reason it is safe inside an open run (nothing observes between contiguous resizes; dropped intermediate SIGWINCHes are already accepted by `supersededResizesSkipBothWinsizeAndReflow`). The trigger is realistic: every `mouseMoved`/`mouseEntered` over a pane calls `controller.sendPointer(.move…)` (app/SwiftTerminalSessionView.swift:401, 1004), and tracking-area re-entry fires while panes resize under a stationary cursor. Coverage claim checks out -- `nonResizeSubmissionClosesTheCoalescingRun` (TerminalPTYHostTests.swift:304) has exactly one resize per side, and it still passes under the proposed fix (a sealed final index of 1 does not supersede index 1). Add an N-resizes-then-barrier test with the fix; a sealed-count array indexed by run offset is simpler than the suggested dictionary, and an out-of-order query just misses and applies, which degrades safely.

### Downgraded (correctness and behavior improvements)

Real problems, but apply the verifier's adjustment.

### 5. splitVertical parameter is inert; U+1CE00 and U+1CE01 render identically

**Status:** `done` -- verifier's adjustment taken: `.splitCircle` now emits two edge-centered circles of radius min(w,h)/2 (left/right vs top/bottom), so the two scalars differ; inert `splitVertical:` parameter and dead `LegacySupplementRegion` enum deleted

`lib/TerminalCore/Sources/TerminalSpriteGeometry/LegacyComputingSupplementSpriteGeometry.swift:276` -- high confidence, medium effort, found by `core-rest`

**Problem.** `ellipseOutline` ends with `if splitVertical { /* comment */ return result }` followed by `return result` -- both branches are the same value, so the `splitVertical:` argument threaded in from `rects(pattern: .splitCircle(vertical:))` (line 69) has no effect whatsoever. `LegacyComputingSupplementSprite.pattern(for:)` maps 0x1CE00 -> `.splitCircle(vertical: true)` and 0x1CE01 -> `.splitCircle(vertical: false)` (LegacyComputingSupplementSprite.swift:27-28), and every other argument to `ellipseOutline` in that case is identical, so the two distinct Unicode characters produce byte-identical geometry. No test pins the distinction (the only `.splitCircle` in the test suite is `vertical: true` in the constrained-size matrix).

**Recommendation.** Replace the no-op `if splitVertical` branch with real split geometry: emit two half ellipse outlines centered on opposite cell edges (left/right for `vertical: true`, top/bottom for `vertical: false`, radius `min(width,height)/2`), matching how U+1CE00 and U+1CE01 differ; if the merged single centered ellipse is genuinely the intended DanTerm policy, delete the `splitVertical` parameter and collapse `LegacySupplementPattern.splitCircle(vertical:)` to `.splitCircle` so the type stops implying a distinction the geometry does not make.

**Verifier (adjustment required).** Facts all check out: `ellipseOutline` ends with `if splitVertical { return result }` / `return result` (LegacyComputingSupplementSpriteGeometry.swift#ellipseOutline lines 276-280), the `.splitCircle` case passes identical centers/radii and only varies `splitVertical:`, `pattern(for:)` maps 0x1CE00->true / 0x1CE01->false, and no test pins the distinction (the only `.splitCircle` in the suite is the `vertical: true` entry in the constrained-size matrix; `exhaustiveBitmapCoverage` only asserts 'some non-background pixel in the cell'). Adjustment: take only the first option. `.ghostty-src/src/font/sprite/draw/symbols_for_legacy_computing_supplement.zig#draw1CE00` is 'RIGHT HALF AND LEFT HALF WHITE CIRCLE' = circle(.left)+circle(.right), and `draw1CE01` is 'LOWER HALF AND UPPER HALF WHITE CIRCLE' = circle(.top)+circle(.bottom), with `sflc.circle` centering at (0|w, h/2) or (w/2, 0|h) with r = 0.5*min(w,h) and clipping to the cell -- which matches the reviewer's proposed geometry. The fallback option ('collapse `.splitCircle(vertical:)` to `.splitCircle`') must be rejected: it would permanently render two distinct Unicode characters identically, and today's single full-cell ellipse matches neither of them, so it is not a DanTerm policy worth preserving. Also note the fix needs new coverage (a mapping assertion for 0x1CE00/0x1CE01 plus a geometry test that the two differ), since the existing bitmap test cannot see the difference.

### 6. --payload mode frees the rest of the payload matrix before its own baseline

**Status:** `done` -- payloads(named:) filters before materializing bytes; framed as removing an unquantified confound, one source of truth for names (both verifier adjustments)

`lib/TerminalCore/Sources/TerminalMemoryProbe/main.swift:84` -- high confidence, small effort, found by `app-harness`

**Problem.** `--payload NAME` is documented at main.swift:33-37 as "the only mode whose footprint delta is attributable", but the existence check at lines 84-86 calls `MemoryProbeMatrix.payloads(columns:lineCount:)`, which eagerly materializes all six payloads' byte arrays at the full `lineCount` (~2 MB at the 10,000-line default) and then discards five of them. `runMatrix` (TerminalMemoryProbeSupport.swift:324-327) builds the whole matrix a second time and its `.filter` drops five more before `measure()` reads `footprintBeforeBytes`/`heapBefore`. The measured terminal then allocates into pages malloc is already holding, understating `footprintDeltaBytes` by up to the size of the discarded payloads -- exactly the allocator-reuse confound the mode exists to eliminate. The default full-matrix path is unaffected because its `.filter` keeps every payload alive, so the defect degrades only the clean mode.

**Recommendation.** Select the payload by name before materializing bytes: add `MemoryProbeMatrix.payloadNames` plus a `payload(named:columns:lineCount:)` builder, and use it both for main.swift's existence check and for `runMatrix`'s `only:` path, so only the payload being measured is ever built.

**Verifier (adjustment required).** Structural claims check out: main.swift#selectedPayload calls MemoryProbeMatrix.payloads(columns:lineCount:) at the full lineCount and keeps one of six (~2.0 MB of byte arrays built, ~1.5 MB dropped -- I measured the payload sizes: plain ~530 KB, styled ~550 KB, mixed ~480 KB, unicode ~350 KB, full-screen ~36 KB), and runMatrix's `.filter { only == nil || $0.name == only }` rebuilds the whole matrix and drops five more before measure() samples footprintBefore/heapBefore. What is NOT established is the impact claim ('understating footprintDeltaBytes by up to the size of the discarded payloads'). Those are ~0.5 MB medium/large-tier blocks; the dominant allocation in measure() is history's arena, which Terminal reserves whole at construction (Terminal.swift#init, ~10 MiB, its own VM region), and small per-row/index allocations come from separate magazines -- freed 0.5 MB blocks cannot serve either, so the reuse path requires a size-class coincidence nobody has measured. Whether the temporaries are even released before measure() also depends on optimization level (in -Onone the six-element array lives to the end of the statement, i.e. through compactMap). Adjustments: (1) state the fix as removing an unquantified confound from the mode whose doc promises a clean delta, not as a proven correction -- per agent-docs/measurement-discipline.md, don't assert a magnitude nobody ran; (2) keep one source of truth for payload names -- `matrixCoversSpecifiedAxes` (TerminalMemoryProbeSupportTests.swift:33) asserts the name list off payloads(), so a separate `payloadNames` constant would be a second place to drift. Deriving both from one table, or simply filtering by name before building bytes inside payloads(), avoids that.

### 7. Invalid DECSTBM resets the region and homes the cursor instead of being ignored

**Status:** `done` -- invalid DECSTBM is now a complete no-op (margins and cursor untouched); valid DECSTBM still homes. Taken as a deliberate 5-of-6 divergence from libvterm (xterm, kitty, ghostty, alacritty, tmux no-op; only libvterm resets and homes, and its own suite asserts nothing for the invalid case), and `scroll-boundaries.json` now carries a `recordedDeviations` entry with the manifest case reclassified `adapted`.

`lib/TerminalCore/Sources/TerminalCore/Terminal.swift:6262` -- high confidence, small effort, found by `core-parser`

**Problem.** `setScrollRegion` treats `bottom <= top` (e.g. `CSI 5;2r`, `CSI 1;1r`, `CSI 100;105r`) as "reset to full screen": it sets `scrollRegion = nil` and then unconditionally runs `moveCursor(row: positioningOriginRow, column: 0)`. Both references do the opposite — an invalid region is a complete no-op that leaves the existing margins and the cursor untouched: xterm guards the whole body with `if (bot > top) { ... set_tb_margins(...); CursorSet(screen, 0, 0, ...) }` (`references/xterm/charproc.c#CASE_DECSTBM`), and kitty likewise wraps both the margin write and `screen_cursor_position` in `if (bottom > top)` (`references/kitty/kitty/screen.c#screen_set_margins`). A TUI that probes with a degenerate region silently loses its active margins and its cursor position.

**Recommendation.** Make the `bottom <= top` case return without touching `scrollRegion` or the cursor (move the `moveCursor(row: positioningOriginRow, column: 0)` call inside the `else` branch), and update the `\u{1B}[5;2r` / `\u{1B}[100;105r` fixtures in `TerminalScrollRegionTests.decstbmNormalizationAndArity`, which currently pin the divergent behavior.

**Verifier (adjustment required).** The divergence is real and the xterm/kitty citations are accurate (references/xterm/charproc.c#CASE_DECSTBM guards on `bot > top`; references/kitty/kitty/screen.c#screen_set_margins on `bottom > top`), and ghostty agrees (.ghostty-src/src/terminal/Terminal.zig#setTopAndBottomMargin returns on `top >= bottom`). But "both references do the opposite" overlooks the one reference DanTerm actually adopted a fixture from: references/libvterm/src/state.c case 0x72 explicitly resets the region to full screen on an invalid range and then homes the cursor unconditionally -- i.e. exactly the current code. Consequently the fix breaks more than the named unit test: lib/TerminalCore/Tests/TerminalCoreTests/Fixtures/libvterm/scroll-boundaries.json (upstreamCase "Invalid boundaries; DECSTBM resets cursor position", recordedDeviations: []) feeds `ESC[5;2r ESC D` and expects cursor row 1, which only holds if DECSTBM homed the cursor; with the fix it lands on row 2. Adjustment: make the change only as a deliberate 3-of-4-references decision, and in the same edit update scroll-boundaries.json plus the recordedDeviations list asserted in TerminalFixtureTests.swift#libvtermManifestCoverage, rather than treating it as a pure bug fix.

### 8. cutTail on a forced-split tail record leaves its side tables at the old offset

**Status:** `done` -- private `reopenTailRecordForTruncation()` per the verifier; `reopenTailRecord`'s guard was NOT loosened

`lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift:933` -- high confidence, medium effort, found by `core-storage`

**Problem.** `removeLastDisplayRow` calls `reopenTailRecord()` for a closed tail, but that method returns immediately when `record.isForcedSplit` (line 676). Control then falls through to `cutTail`, which rewrites only `record.cellCount` (line 993). A closed record's tables are addressed as `offset + LogicalLineRecord.headerAndCells(record.cellCount)` (lines 1832 and 1866), so shrinking `cellCount` moves the computed base backwards into the cell words while the real hyperlink/identity tables stay where `flushOpenTables` wrote them. `hyperlinkCount`/`identityEntryCount` in the header are left non-zero, and since every printed cell gets a `contentIdentity` (`Terminal.printNarrow`/`printWide` call `allocateContentIdentity()`), essentially every real record has an identity table. The record's `hasTrailingFill` is likewise not cleared, unlike the reopen path at lines 678-681.

**Recommendation.** Let `reopenTailRecord()` also accept a forced-split tail (its follower is gone by construction at this call site) -- reload the scratch, zero `hyperlinkCount`/`identityEntryCount`/`identityPerCell` and clear the fill exactly as the non-split path does -- so `cutTail` never runs against a record whose tables are still in the arena.

**Verifier (adjustment required).** The diagnosis checks out: line 676 refuses a forced-split tail, `cutTail` rewrites only `cellCount` (993), closed-record tables are addressed off `offset + headerAndCells(record.cellCount)` (1832, 1866), and every printed cell does get an identity (Terminal.swift#printNarrow / #printWide call `allocateContentIdentity`), so the identity table is essentially always present. The path is reachable, but only narrowly: a forced split is always immediately followed by `openRecordIfNeeded`, so the split record is the tail only after `truncateTail` has consumed every row of its continuation record(s). The recommendation needs a specific adjustment: do NOT loosen `reopenTailRecord`'s guard, because its other caller is Terminal.swift#restoreWrapClaimBeforeCursor (6516-6518), where a forced-split tail was split for a *physical* reason (chunk boundary or the 1/32 cell cap) and reopening it rewinds `writeCursor` to before the seam pad that `wrapWriteCursorAtSeam` already charged into `bytesInUse` (2272-2279) -- the next wrap re-pads and double-charges, and the span subtraction in `dropHeadRecord` (851) never gives it back. Fix it locally instead: a private truncation-only reopen (load scratch, zero `hyperlinkCount`/`identityEntryCount`/`identityPerCell`) used only from `removeLastDisplayRow`, or make `cutTail` rewrite the tables. Also note the `hasTrailingFill` sub-claim is inert in practice: an open record never carries a fill (a soft-wrapped admit passes nil to `setTrailingFillOnTail`, and reopen clears it), so a forced-split record cannot have one.

### 9. Three composition arrays are per record, not per display row

**Status:** `done` -- the three identity axes were *retired*, not re-denominated: they priced doc 28's per-row candidates C1-C6, and the engine now picks a record's identity encoding at admission time, so the question is closed (same retirement `packedPayloadModelBytes` took in 9ad7cc55). Gone with them: `singleRunRowCount`, the driver's `identity_charge` + byte constants + `identity=` variants, `singleRunRowFraction` / `meanIdentityRunsPerRow`, the `packingIdentityFloor` pool and the identity render columns. `Terminal.scrollbackRecordContentIdentityShape` survives in the engine. Pre-fix the corpus aborted with `RuntimeError: benchmark/scrollback-stream: contentIdentityRunCounts has 10750 entries for 14334 rows`; it now completes.

`lib/TerminalCore/Sources/TerminalRetainedRowProbeSupport/TerminalRetainedRowProbeSupport.swift:506` -- high confidence, medium effort, found by `app-harness`

**Problem.** `readRetainedRowShape` fills `contentIdentityRunCounts`, `identifiedCellCounts` and `strictContentIdentityRunCounts` by iterating `terminal.scrollbackRecordCount` (logical lines, `history.recordCount`), while the other eleven `RetainedRowComposition` arrays are filled by iterating `terminal.scrollbackRowCount` (display rows, `history.grandDisplayRowTotal`). Nothing else was updated: the type doc at lines 116-117 still says "per row, oldest first and index-aligned with `RetainedRowShapeReport.storedCellCounts`", `singleRunRowCount` (line 233) calls them rows, and the driver `scripts/terminal-retained-row-shape.py#row_facts` length-checks both consumed arrays against `storedCellCounts` and raises RuntimeError on mismatch. Any stimulus whose retained history contains a soft-wrapped logical line aborts the corpus run; the Swift test `contentIdentityRunsAreCarriedPerRow` asserts `.count == report.retainedRowCount` but only feeds unwrapped short lines, so it never sees the divergence.

**Recommendation.** Move the three record-scoped arrays out of `RetainedRowComposition` into their own record-scoped field on `RetainedRowShapeReport` and rename `singleRunRowCount` to `singleRunRecordCount`, so the sample unit is carried by the type instead of surfacing as a `row_facts` length error.

**Verifier (adjustment required).** Every factual claim verified. readRetainedRowShape fills 11 arrays over `0..<terminal.scrollbackRowCount` (history.grandDisplayRowTotal) and the three identity arrays over `0..<terminal.scrollbackRecordCount` (history.recordCount); the RetainedRowComposition type doc (lines 116-117) still says 'per row ... index-aligned with RetainedRowShapeReport.storedCellCounts', and singleRunRowCount (line 233) still counts 'rows'. scripts/terminal-retained-row-shape.py#row_facts does list contentIdentityRunCounts and identifiedCellCounts among the keys it length-checks against storedCellCounts and raises RuntimeError on mismatch, then indexes them per row (lines 353-354) into the per-row identity pricing at #price_facts and #identity_charge. git confirms the drift: 9ad7cc55 record-scoped the probe and did not touch the driver (last touched one commit earlier, 987927af). contentIdentityRunsAreCarriedPerRow feeds 1-17 char lines at 40 columns, so it can never see the divergence. Required adjustment the finding omits: the driver and its python self-test must change in the same commit -- moving the fields out of `composition` turns today's RuntimeError into a KeyError in row_facts, and the per-row identity model (singleRunRowFraction, meanIdentityRunsPerRow, identity_charge's run variant) has to be re-denominated per record or retired the way packedPayloadModelBytes already was. scripts/tests/terminal_retained_row_shape_test.py:68-69 synthesizes those two keys and needs the same update. Also worth noting strictContentIdentityRunCounts has no consumer at all today, and singleRunRowCount has no caller -- the rename may be moot.

### 10. LegacyComputingTopology.decode's catch-all default traps on out-of-family scalars

**Status:** `done` -- `case 0x1FBE0...0x1FBEF:` plus a new `.unsupported` topology, so decode and runs() now agree; the failable-init variant would have broken a file the batch did not own

`lib/TerminalCore/Sources/TerminalSpriteGeometry/LegacyComputingSpriteGeometry.swift:93` -- high confidence, trivial effort, found by `core-rest`

**Problem.** `decode`'s final `default:` unconditionally evaluates `legacyCircleShapes[Int(value - 0x1FBE0)]`, silently assuming every unmatched scalar is in 0x1FBE0...0x1FBEF. Any other value crashes with an opaque array index-out-of-range: 0x1FBB0 (an interior gap of the family) computes index -48, and anything at or above 0x1FBF0 computes index >= 16. `LegacyComputingPattern.init(scalar:)` is public and unguarded, so the membership predicate that actually protects this lives in a different module (`LegacyComputingSprite.pattern(for:)`, TerminalRenderExecution). `runs()` by contrast has a safe `default: break` at line 404 for the same unknown scalars, so the two halves of this file disagree about what an unsupported scalar means.

**Recommendation.** Change the catch-all to an explicit `case 0x1FBE0...0x1FBE3, 0x1FBE4...0x1FBEF:` (or `case 0x1FBE0...0x1FBEF:`) and add a real `default: preconditionFailure("unsupported legacy-computing scalar \(value)")`, so an out-of-vocabulary scalar fails at the decode seam with a diagnosable message instead of an array-bounds trap.

**Verifier (adjustment required).** The shape of the problem is real -- `default:` indexes `legacyCircleShapes[Int(value - 0x1FBE0)]` with no membership check, `runs()` has a benign `default: break` (line 405), and the guard lives one module away in `LegacyComputingSprite.pattern(for:)`. Two corrections. (1) The failure mechanism is misdescribed: `value` is `UInt32` and so is the literal, so 0x1FBB0 does not produce index -48; `value - 0x1FBE0` traps first as an unsigned-subtraction overflow. Only scalars >= 0x1FBF0 reach the array-bounds trap. (2) It is latent, not reachable: the only non-test caller guards membership before constructing, `exhaustiveContainment` only iterates the three supported spans, and if finding 2 is applied `decode` leaves the draw path entirely. Adjustment if a human does touch it: use `case 0x1FBE0...0x1FBEF:` (the split `0x1FBE0...0x1FBE3, 0x1FBE4...0x1FBEF` in the recommendation is pointless) and note that a `preconditionFailure` still leaves the two halves of the file disagreeing (decode traps, `runs` silently returns no ink) -- making decode/`init` failable is the only version that actually reconciles them.

### 11. pasteClipboard bypasses the injectable pasteboard seam

**Status:** `done` -- paste reads the seam, and the existing UI test (which the finding wrongly said did not exist) now uses a scratch pasteboard instead of clobbering the real clipboard

`app/SwiftTerminalSessionView.swift:734` -- high confidence, trivial effort, found by `app-harness`

**Problem.** `pasteClipboard()` reads `NSPasteboard.general` directly, while every write goes through the injectable `selectionPasteboard` property (declared line 52, used by `writeClipboard` at line 701). The Cmd-V / Edit>Paste responder path therefore cannot be isolated from the developer's real system pasteboard, and `tests-ui/SwiftTerminalSessionViewTests.swift` has no test for `paste(_:)` or `pasteClipboard()` at all even though it covers copy through the injected board at lines 564, 594 and 682.

**Recommendation.** Read from `selectionPasteboard` in `pasteClipboard()` and widen that property's doc comment from "selection copies" to the pane's clipboard in both directions, so paste is testable through the seam copy already uses.

**Verifier (adjustment required).** The seam asymmetry is real: selectionPasteboard is declared at app/SwiftTerminalSessionView.swift:52 and used by writeClipboard (701-703), while pasteClipboard() reads NSPasteboard.general directly (734), and both the Cmd-V responder (paste(_:), 729) and the pane context menu (PaneWrapperView.swift:482) route through it. Default-valued property means routing paste through it is behavior-identical in production. But the claim that the UI suite 'has no test for paste(_:) or pasteClipboard() at all' is false: tests-ui/SwiftTerminalSessionViewTests.swift line ~996, 'menu and context paste share the owner-side safe-paste path', calls both pane.paste(nil) and pane.pasteClipboard(). That test makes the finding stronger, not weaker -- it does `NSPasteboard.general.clearContents()` + setString, so running `just test-ui` silently destroys the developer's real clipboard. Adjustment: the fix must include updating that existing test to assign a scratch pasteboard to pane.selectionPasteboard (as the copy tests at 564/594/682 already do), rather than being described as adding first coverage.

### 12. Degenerate alternate width makes the resize probe report zeros as a distribution

**Status:** `done` -- validation lives in TerminalResizeProbe/main.swift (usage + exit 2, verified by running the binary); the support precondition is a documented backstop

`lib/TerminalCore/Sources/TerminalResizeProbeSupport/TerminalResizeProbeSupport.swift:312` -- high confidence, trivial effort, found by `app-harness`

**Problem.** `Terminal.resize` early-returns when `columns < 2` or `columns == columnCount` (Terminal.swift:1823-1824). `measureSaturatedResize` never checks that `recipe.alternateColumns` differs from `recipe.columns` or is at least 2, and the CLI only validates `value >= 1` (TerminalResizeProbe/main.swift:41,54). So `--alternate-columns 179` (matching the standard recipe's columns) or `--alternate-columns 1` produces `sampleCount` no-op resizes and a full, plausible-looking `ResizeProbeDistribution` of near-zero nanoseconds -- with nothing marking it unmeasured, despite that type's doc at lines 221-225 committing to an empty distribution rather than a zero when nothing was measured.

**Recommendation.** Add `precondition(recipe.alternateColumns >= 2 && recipe.alternateColumns != recipe.columns)` at the top of `measureSaturatedResize`, so a degenerate alternation fails loudly in the headlessly tested support target rather than only being catchable by eye in the CLI.

**Verifier (adjustment required).** Mechanics verified: Terminal.resize guards `columns >= 2, rows >= 1` and `columns != columnCount || rows != rowCount` (Terminal.swift#resize), the probe never varies rows, and TerminalResizeProbe/main.swift only checks `value >= 1`, so --alternate-columns 179 (== standard.columns) or 1 yields a full sampleCount of no-op resizes timing two clock reads. The codebase already knows this risk -- probeAlternatesWidths' 'Why it exists' names it -- but guards only the alternation logic, not the recipe. Two reasons to downgrade rather than confirm: the emitted report carries both `columns` and `alternateColumns`, so the artifact is self-describing to a reader who pastes it into a finding, and this is operator error on a hand-run probe rather than a silent blind spot in a scheduled collector. Adjustment to the fix: a bare precondition traps the CLI with a SIGTRAP instead of the usage error every other bad flag produces, so add the check in TerminalResizeProbe/main.swift (write usage, exit 2) and keep the support-target precondition only as a backstop. Existing tests use 100/179 and 60/120, so neither breaks.

### 13. Erase paths never close history's open tail record

**Status:** `done` -- erases that blank the whole of live row 0 (ED 2, ED 1 below row 0, ED 0 from home, DECALN) now sever the open tail record through the existing `severWrapClaim(before: 0,)` funnel; the partial-row cases (ED 1 on row 0, ED 0 past column 0) and EL 2 are pinned as non-triggers. Deliberately diverges from kitty/xterm/ghostty, which leave the incoming claim -- costless for them because none has the width-change pull-back that makes the stale bit observable as resurrected text here. Recorded as an amendment to operation 2's trigger list in `docs/research/31-logical-line-scrollback/decisions.md`, not a sixth arena operation

`lib/TerminalCore/Sources/TerminalCore/Terminal.swift:5492` -- medium confidence, small effort, found by `core-parser`

**Problem.** `severScrollbackWrapClaim` (which calls `history.closeOpenRecord()`) is reached from only two places: `hardReset` (line 5816) and `moveAndFillRows` (line 6389), both via `severWrapClaim(before:replacementStyleId:)`. No erase path calls it. So `eraseDisplay` (ED 1/ED 2, and ED 0 with the cursor on row 0), `eraseLine(mode: 2)` on row 0, and DECALN (`dispatchEscape(_ sequence:)`, line 5600) all blank live row 0 while leaving `history.hasOpenTailRecord == true` — i.e. history still believes the blanked row continues its last logical line. `LogicalLineStore.admit` (line 484) appends every later scrolled-off row into that still-open record, so text printed after `ESC[2J` is joined into the pre-clear logical line; and `pullBackOpenTailRemainder` (LogicalLineStore.swift:1031), which only fires for an *open* tail, hands that record's trailing partial display row back to the live refold on the next width change.

**Recommendation.** In `eraseDisplay`, sever the history seam whenever the erase clears row 0 — call `severWrapClaim(before: 0, replacementStyleId: backgroundEraseStyleId())` before the row loop for modes 1 and 2, and for mode 0 when `cursor.row == 0` — exactly as `hardReset` already does at line 5816 (DECALN at line 5600 needs the same treatment).

**Verifier (adjustment required).** Facts check out: severScrollbackWrapClaim (Terminal.swift:6503, not 5492) is reached only from hardReset:5816 and moveAndFillRows:6389 via severWrapClaim(before:); eraseDisplay/eraseLine/DECALN (dispatchEscape:5600) never close the record; admit():LogicalLineStore.swift:484 appends the next scrolled-off row into the still-open record and pullBackOpenTailRemainder:1031 splices its partial row into the live refold on a width change (resizeWidth:4320-4332 feeds it in as leadingCells), so post-clear text really can be glued to the pre-clear logical line in primaryHistoryText and re-appear at the top of a cleared screen after a resize. Three adjustments before acting. (1) The ED 0 clause is wrong: with cursor.row == 0 and column > 0, mode 0 leaves columns 0..<cursor.column of row 0 intact, and those cells genuinely continue the scrollback line -- severing there splits one real logical line in two. Restrict the sever to erases that blank the whole of row 0 (ED 2, ED 1 when cursor.row > 0, DECALN), and decide EL 2 at row 0 explicitly, which the recommendation names in the problem but omits in the fix. (2) This is a DanTerm design choice, not a compat fix: kitty (references/kitty/kitty/screen.c#screen_erase_in_display clears only each erased line's own next_char_was_wrapped) and xterm (references/xterm/screen.c#ClearBufRows clears only the erased row's LINEWRAPPED) both leave the incoming claim, so both would join across the clear too. (3) docs/research/31-logical-line-scrollback/decisions.md enumerates exactly five arena operations and names operation 2's triggers; adding an erase trigger needs that list amended. Also note TerminalHistoryGenerationTests.swift:40-42 already asserts in a comment that ESC[2J severs the claim -- it does not (only clearPreviousSpacer's spacer repair runs), so that comment is stale either way.

### 14. Discarding the last empty record at a seam leaves head stale and its pad permanently charged

**Status:** `done` -- empty branch now resets to a clean arena, restoring `head == offsets[0]`; no test (not drivable from the public surface), treated as tidy-up per the verifier

`lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift:2263` -- medium confidence, small effort, found by `core-storage`

**Problem.** Every other mutator keeps the invariant `head == offsets[0]` (`trimHeadRecord` line 799, `dropHeadRecord` line 852, `resetToEmptyArena` line 872), but `wrapWriteCursorAtSeam`'s empty-open-record branch does `offsets.removeLast()` (line 2263) without touching `head`. When that record was the only one, `offsets` is left empty while `head` still names its offset, and the pad written immediately afterwards (lines 2272-2279) is charged into `bytesInUse` at an address no future `dropHeadRecord` span subtraction can ever reclaim -- `bytesInUse -= next > offset ? next - offset : ...` (line 851) only spans from a dropped record's offset forward, and this pad sits *before* the first record. The stale `head` also mis-bounds `contiguousRoomAtCursor` via `writeCursorPrecedesHead` once the ring wraps, until the next head drop resyncs it.

**Recommendation.** In that branch, after `offsets.removeLast()`, bail out to a clean arena when no records remain -- `if offsets.count == 0 { resetToEmptyArena(); return }` -- since an empty arena has nothing to wrap around and needs no pad.

**Verifier (adjustment required).** The mechanism is real -- `wrapWriteCursorAtSeam`'s empty branch (2260-2267) never touches `head`, `retireEmptyTailBlocks` returns immediately when `offsets` is empty (864), and the pad at 2272-2279 is charged -- and the suggested one-liner is safe (makeRoom `continue`s at 2165 and would just take its own `offsets.count == 0` reset at 2155). But the impact is marginal and one claim is overstated. "Permanently charged" is wrong: makeRoom's own empty branch calls `resetToEmptyArena()` whenever the next room/charge test fails, and any full drain through `dropHeadRecord` (840-843) zeroes `bytesInUse`, so the stranded pad clears at the next drain rather than never. The stale `head` is also conservative, not corrupting: `writeCursorPrecedesHead` can only *under*-report `contiguousRoomAtCursor`, costing a few early evictions until the next head drop resyncs it, never an overwrite of live bytes. Reachability is narrow too -- it needs the reopened blank record to be the store's only record at a region-end wrap. Treat it as tidy-up (restore the `head == offsets[0]` invariant) rather than a bug fix, and drop the "permanently" framing from the rationale.

### 15. reapLeaderAfterKill treats an interrupted waitpid as a completed reap decision

**Status:** `done` -- EINTR retry added, framed as contract hardening not a live leak

`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift:673` -- medium confidence, trivial effort, found by `pty`

**Problem.** `reapLeaderAfterKill` does a single blocking `waitpid(leaderPID, &status, 0)` and only sets `leaderReaped = true` when the return equals `leaderPID`; any other return, including `-1`/`EINTR`, falls through silently. Its own doc comment (lines 664-668) argues the whole point of blocking here is to "prove reap before publishing quiescence" and that giving up would be "abandonment wearing quiescence's clothes" — but an interrupted wait does exactly that: `performForcedCleanupAfterMasterClose` proceeds to `finishTeardown()` and publishes quiescence over an unreaped zombie the process still owns. Every other blocking syscall in this file (`flushInput` line 1418, `readReady` line 1508, `drainCommittedOutput` line 1598, `PTYSpawner.readBootstrapFailure`) retries on `EINTR`; this one does not.

**Recommendation.** Wrap the call in an `EINTR` retry: `var result = waitpid(leaderPID, &status, 0); while result < 0 && errno == EINTR { result = waitpid(leaderPID, &status, 0) }`, then set `leaderReaped` when `result == leaderPID`.

**Verifier (adjustment required).** Every factual claim checks out: the single `waitpid` at 673 only sets `leaderReaped` on an exact match, `performForcedCleanupAfterMasterClose` (625) goes straight on to `finishTeardown()`, which clears `leaderPID` (1898) and publishes quiescence, and the file retries EINTR at 1418, 1508, 1598 plus PTYSpawner.swift:214. What makes it marginal is reachability: `waitpid` only returns EINTR when a caught signal interrupts it, and I found no `sigaction`/`signal` handler installed anywhere in the host process (the only hits are in the child PTYProbe/bootstrap C sources), so this is contract-hardening against a future handler or an attached tool, not a live bug. Take the three-line retry -- it is free, cannot spin (ECHILD still falls through as today) and matches the file's convention -- but do not describe it as a zombie leak users are hitting.

## 2. Code simplifications

Dead code, duplicated logic, and needless indirection. All were checked call-site-by-call-site; none should change behavior.

### 16. inspectedCells' `rows` range parameter is only correct at lowerBound 0

**Status:** `done` -- parameter is now `rowCount: Int`; range built internally

`lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift:300` -- high confidence, trivial effort, found by `core-render`

**Problem.** `inspectedCells(rows:replanning:geometry:cursorSpan:)` allocates `result` with `count: rows.count` (line 316) but then indexes it by the *absolute* viewport row -- `result[row] = cells` (line 352) and `result[row]` in the second pass (line 357). That is only correct when `rows.lowerBound == 0`; any other range silently reads/writes the wrong slot or traps. The single caller (line 176) always passes `0..<rowCount`, and which rows are actually inspected is decided by the `replanning` predicate, not by the range -- so the parameter is redundant generality that also encodes a trap.

**Recommendation.** Replace the `rows: Range<Int>` parameter with `rowCount: Int` and construct `0..<rowCount` inside the function for the `forEachViewportRow` call and the second pass.

**Verifier (confirmed).** Verified in /Users/dan/Code/danterm-terminal-engine/lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift: line 316 allocates `count: rows.count`, line 352 writes `result[row]` and line 357's second pass reads `result[row]` and `geometry.rows[row]` with absolute indices, so any `lowerBound > 0` either traps or misaligns. `inspectedCells` is private with exactly one caller (line 176, `0..<rowCount`) -- confirmed by rg across lib/ and app/. Replacing the parameter with `rowCount: Int` and building `0..<rowCount` for both the `forEachViewportRow` call and the second pass is behavior-identical (Terminal.forEachViewportRow clamps `requested` to `0..<rowCount` anyway) and touches nothing across a target boundary, so the cross-module dispatch note does not apply. Equally valid alternative if you prefer to keep the range: index `result[row - rows.lowerBound]`.

### 17. Unreachable .closeMaster case in the single-command execute

**Status:** `done` -- dead arm replaced with a preconditionFailure naming the coupling

`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift:1165` -- high confidence, trivial effort, found by `pty`

**Problem.** `execute(_ command: PaneLifecycleCommand)` has a `case .closeMaster: closeMaster()` arm that can never run. Its only caller is `execute(_ commands: [PaneLifecycleCommand])` (line 1143), and that loop intercepts `.closeMaster` at line 1133 — every path there either `return`s (after appending the tail to `deferredCommandsAfterMasterClose`) or `continue`s, so control never reaches line 1143 with `.closeMaster`. Grep confirms `execute(_ command:)` has no other call site (only lines 954, 1143, 1735, 1738 call an `execute` overload). The dead arm is also actively misleading: it performs a bare `closeMaster()` with none of the command-deferral bookkeeping that makes a pending master close safe, so anyone who later routes a single command through it silently loses the tail of the teardown ladder.

**Recommendation.** Delete `case .closeMaster: closeMaster()` from `execute(_ command:)` and replace it with `case .closeMaster: preconditionFailure("closeMaster is handled by execute(_ commands:) so its tail can be deferred")`, which documents the coupling and keeps the switch exhaustive.

**Verifier (confirmed).** Verified: `execute(_ command:)` (TerminalPTYHost.swift:1147) is reached only from the loop at line 1143; the other three `execute` sites (954, 1735, 1738) all take the array overload (`reducer.handle` returns `[PaneLifecycleCommand]`). The loop intercepts `.closeMaster` at 1133 and either returns (deferring the tail) or continues, and the reducer emits `.closeMaster` exactly once per command list (PaneLifecycle.swift:294), so the deferred tail cannot reintroduce it either. The arm at 1165-1166 is genuinely dead. `preconditionFailure` is consistent with this layer's temperament and existing precedent (`precondition(isReducing == false)` at line 1729, six `preconditionFailure` calls in TerminalPaneSession.swift for equally impossible fence-payload mismatches), and it is a no-op change today since the arm is unreachable.

### 18. plannedCell rebuilds ResolvedCellStyle three times to change one field

**Status:** `done` -- ResolvedCellStyle stored props are `var`; three literals replaced by in-place mutation in the same order

`lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift:390` -- high confidence, small effort, found by `core-render`

**Problem.** `plannedCell` applies hover (390-401), selection (402-413) and block-cursor (414-426) overrides by constructing a whole new `ResolvedCellStyle` each time, restating all eight fields verbatim in each of the three literals. That is ~36 lines to mutate at most three fields, and each copy must repeat the other five exactly or silently drop them -- exactly the failure mode the repo's payload-threading tests exist to catch elsewhere.

**Recommendation.** Change `ResolvedCellStyle`'s stored properties (RenderColorResolution.swift:8-15) from `let` to `var` and mutate the affected fields in place (`style.underline = .single; style.underlineColor = style.foreground`, etc.), keeping the same three-step order; the struct is a trivial POD so this cannot regress the per-cell path.

**Verifier (confirmed).** Checked the three literals (lines 390-426) field by field against an in-place rewrite: hover sets underline/.single + underlineColor = the pre-hover foreground; selection then overwrites only foreground (leaving underlineColor at the old foreground); block cursor overwrites foreground/background/underlineColor. Mutating in the same order reproduces each of those exactly, including the hover case reading `style.foreground` before any later step changes it. `ResolvedCellStyle` (RenderColorResolution.swift:7-16) is internal to TerminalRenderPlanning -- only RenderFramePlanner, resolveCellStyle and one test helper name it -- and holds only PODs (RenderColor is three UInt8s, TerminalUnderlineStyle is a plain enum), so `let`->`var` changes no layout, no Sendable/Equatable synthesis, and no ABI across a target boundary. In-place mutation is at worst free versus reconstructing the struct. One nit in the problem statement: the memberwise init has no defaults, so a copy cannot silently *drop* a field -- the real risk is mis-threading one, which is still what the change removes.

### 19. LegacyComputingPattern.topology is decoded on every draw but read only by tests

**Status:** `done` -- topology is computed, so the draw path no longer decodes it per cell per frame

`lib/TerminalCore/Sources/TerminalSpriteGeometry/LegacyComputingSpriteGeometry.swift:10` -- high confidence, trivial effort, found by `core-rest`

**Problem.** `LegacyComputingPattern.init(scalar:)` eagerly stores `topology = LegacyComputingTopology.decode(scalar)`, which for most ranges indexes a `[String]` table (`blockPolicies`, `cellDiagonalSegments`, `legacyCircleShapes`, `smoothMosaicGrids`) and retains a String. `LegacyComputingSpriteGeometry.runs` never reads `pattern.topology` -- it binds `let value = pattern.scalar` (line 143) and re-derives everything by re-switching on the raw scalar. Grepping `.topology` across app/ and lib/ finds it only in LegacyComputingSpriteGeometryTests.swift. The pattern is constructed per cell per frame from the render loop (TerminalRenderExecution.swift:767), so every legacy-computing cell pays for a value only the tests observe.

**Recommendation.** Change `topology` from a stored property to a computed one (`public var topology: LegacyComputingTopology { LegacyComputingTopology.decode(scalar) }`) so the draw path stops decoding it; synthesized `Equatable` then compares `scalar` alone, which is equivalent since topology is a pure function of scalar.

**Verifier (confirmed).** Verified: `init(scalar:)` stores `topology = LegacyComputingTopology.decode(scalar)` (line 10); `runs` binds `let value = pattern.scalar` (line 143) and re-switches on the raw scalar, never touching `pattern.topology`. Grepping `.topology` across app/ and lib/ (excluding .claude/worktrees) finds reads only in LegacyComputingSpriteGeometryTests.swift; the sole non-test construction site is `LegacyComputingSprite.pattern(for:)`, called per cell from the render-run loop. Making it computed is behavior-preserving: synthesized `Equatable` then compares `scalar` only, and topology is a pure function of scalar. No cross-module-dispatch risk (docs/design/2026-07-29-cross-module-value-dispatch.md): nothing in TerminalRenderExecution reads `topology`, TerminalSpriteGeometry carries no `@inlinable` surface today, and dropping the String-carrying enum from storage actually removes ARC traffic on a value that crosses the target boundary each cell. One interaction to note: today an out-of-vocabulary scalar traps at construction; with a computed property that trap moves to the (test-only) access -- which is fine, and interacts with finding 4.

### 20. Dead helpers left behind in PackedRetainedRow.swift

**Status:** `done` -- dead Array extension and `spillScalarCount` deleted

`lib/TerminalCore/Sources/TerminalCore/PackedRetainedRow.swift:601` -- high confidence, trivial effort, found by `core-storage`

**Problem.** The `fileprivate` `extension Array where Element == UInt8` with `appendUInt16`/`appendUInt32` (lines 601-614, plus its three-line explanatory comment) has zero callers anywhere in the repo -- `pack` writes bytes through the local `put16`/`put32` closures over an unsafe buffer instead. `spillScalarCount` (line 592) also has zero references outside its own declaration. Both are leftovers from the pre-`31` byte-appending encoder the doc comment at lines 437-445 describes as rejected.

**Recommendation.** Delete the `Array where Element == UInt8` extension (lines 598-614) and the `spillScalarCount` property (lines 591-592).

**Verifier (confirmed).** Grepped the whole repo (excluding .build): `appendUInt16`, `appendUInt32`, and `spillScalarCount` each appear exactly once, at their own declarations (PackedRetainedRow.swift:592, 602, 608). `pack` writes through the local `put16`/`put32` closures over the unsafe buffer (561-577), never through the Array extension. The neighbouring accessors are genuinely live and must stay: `payloadByteCount` (TerminalPackedRetainedRowTests.swift:165) and `spillCount` (TerminalLogicalLineAdmissionProbe.swift:182, TerminalLogicalLineEvictionProbe.swift:354). Deleting 591-592 and 598-614 is a pure no-op; `fileprivate` unused members produce no warning, which is why they lingered.

### 21. Light-stroke pixel width re-derived from metrics in six sprite files

**Status:** `done` -- all six sprite files now use `metrics.lightStrokePixels`; all derived it identically and the max(1, ...) clamp each carried was dead

`lib/TerminalCore/Sources/TerminalRenderExecution/BoxDrawingSprite.swift:46` -- high confidence, small effort, found by `core-render`

**Problem.** `max(1, Int((metrics.underlineThickness * metrics.displayScale).rounded()))` is written out six times -- BoxDrawingSprite.swift:46, LegacyComputingSprite.swift:30, LegacyComputingSupplementSprite.swift:56, PowerlineSprite.swift:48, BranchDrawingSprite.swift:42, GeometricShapeSprite.swift:44-47 -- and every one of them recovers a value the metrics already computed: `TerminalRenderMetrics.init` sets `underlineThickness = CGFloat(underlinePixels) / displayScale` from the `underlinePixels` local (TerminalRenderExecution.swift:89-108), and `quantizedPixelCount` guarantees `underlinePixels >= 1`, so the round trip and the `max(1, ...)` are both no-ops. Six copies of a derivation of stored state, executed per sprite cell.

**Recommendation.** Add `let lightStrokePixels: Int` to `TerminalRenderMetrics`, assign it from the existing `underlinePixels` local in `init`, and replace all six expressions with `metrics.lightStrokePixels`.

**Verifier (confirmed).** All six sites exist and are the same expression (BoxDrawingSprite.swift:46, LegacyComputingSprite.swift:30, LegacyComputingSupplementSprite.swift:56, PowerlineSprite.swift:48, BranchDrawingSprite.swift:42, GeometricShapeSprite.swift:44-47), and all six are inside the per-cell sprite switch in `drawTextRuns` (lines 680-768). The round trip is a no-op: `underlineThickness = CGFloat(underlinePixels)/displayScale` (line 108) and `quantizedPixelCount` returns only `pixels > 0` (line 475), so `max(1, ...)` cannot bind and the multiply/round recovers `underlinePixels` for any realistic scale. Two adjustments worth carrying: declare the new property internal (not public) -- the sprite files are same-module, and widening TerminalRenderMetrics' public surface buys nothing; and do not sell this as a perf fix -- docs/research/11-render-frame-budget.md `11/F9` measured the *entire* sprite geometry recomputation at 66.7 ns/cell, of which this expression is a sliver. The value is the single derivation site, which is also the direction 9-plan-render-allocation-hotspots.md already points (caching sprite inputs on TerminalRenderMetrics).

### 22. PointerOwnership duplicates TerminalPointerConsumption case-for-case

**Status:** `done` -- PointerOwnership and its identity map deleted; pointerOwners stores the consumption type directly

`lib/TerminalCore/Sources/TerminalCore/TerminalInteractionPolicy.swift:198` -- high confidence, small effort, found by `core-rest`

**Problem.** `private enum PointerOwnership` declares exactly the same five cases as the public `TerminalPointerConsumption` (report, selection, paneMenu, link, ignored), and `pointerConsumption(for:)` (line 655) is a pure identity map between them with a single call site (line 283). The parallel type also hides a dead branch: `pointerOwner(button:modifiers:tracking:)` (line 496) can only return `.report`/`.selection`/`.paneMenu`/`.ignored`, and it is the sole source of the `owner` argument to `pointerDownDecision` (single call site, line 293), so `pointerDownDecision`'s `case .link:` at line 526 is unreachable -- the link arm returns at line 271 before `pointerOwner` is ever consulted.

**Recommendation.** Delete `PointerOwnership` and `pointerConsumption(for:)`, store `TerminalPointerConsumption?` in `TerminalInteractionState.pointerOwners`, and have `pointerOwner` return `TerminalPointerConsumption` directly.

**Verifier (confirmed).** All claims verified in TerminalInteractionPolicy.swift: `PointerOwnership` (line 198) has the same five cases as `TerminalPointerConsumption` (line 89); `pointerConsumption(for:)` (line 655) is an identity map with exactly one call site (line 283); `pointerOwner` (line 496) can only return .report/.selection/.paneMenu/.ignored; and its result is the only source of `pointerDownDecision`'s `owner` (single call site, line 293), so the `.link` arm at line 525-526 is unreachable because the link path returns at line 271 first. The swap is behavior-preserving: `pointerOwners` is `fileprivate` inside a public `Equatable, Sendable` struct with no Codable conformance, `PointerOwnership` is file-private with no other references, and `$0 == .link` / `?? .ignored` all still typecheck against the public enum. Caveat (not a blocker): the recommendation does not remove the dead branch it cites -- `PointerOwnership.link` is genuinely stored in `pointerOwners` (line 270) and read at 306/364/436, so after the merge `pointerDownDecision` still needs an unreachable `.link` arm for exhaustiveness.

### 23. Production and test fence bodies duplicate the drain contract

**Status:** `done` -- shared private drainedConsumptionState(); diagnostic pair left alone per the verifier

`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift:696` -- high confidence, small effort, found by `pty`

**Problem.** `performProductionFence` (line 696) and the `package`/`public` test fences duplicate their payload construction verbatim: `.frameState` vs `fencedFrameState()` (line 772) both call `drainedFrameState()`; `.consumptionState` (lines 705-715) and `fencedConsumptionState()` (lines 783-794) contain the same six-line `if case .some(.exited) = owner.reportedResult, owner.captureTransitions` transition-selection block; `.diagnosticState` (lines 716-720) and `fencedDiagnosticState()` (lines 802-804) are the same pair again. The comment at lines 683-693 warns that this exact hand-over contract already produced one interleaving bug, so having two copies of the drain-and-select logic is where the next drift lands — a change to the production copy silently leaves the test fences asserting the old behavior.

**Recommendation.** Extract private owner-isolated builders (`drainedConsumptionState()` and `drainedDiagnosticState()`) and call them from both `performProductionFence` and the `fenced*` entry points, leaving `fence(countsAsProduction:)` as the only difference between the two paths so the entry census stays correct.

**Verifier (confirmed).** Verified line by line: the `.consumptionState` arm (705-715) and `fencedConsumptionState()` (782-794) contain the same transition-selection block, and `.diagnosticState` (716-720) matches `fencedDiagnosticState()` (802-804). I checked evaluation order, which is the one thing that could differ: both compute `transitions` before calling `drainedFrameState()`, and both read `reportedResult` after the drain, so a shared tuple-returning builder is behavior-preserving. `fencedConsumptionState` has exactly one substantive assertion site (TerminalPTYHostTests.swift:81), so silent drift there is plausible. Minor scoping note: `drainedFrameState()` is already shared, so the value is concentrated in `drainedConsumptionState()`; the two-line diagnostic pair is optional and extracting it buys little.

### 24. strictlyDecodedUTF8 duplicates String(validating:as:), which the same file already uses

**Status:** `done` -- strictlyDecodedUTF8 deleted, all eight sites use String(validating:as:); localFilePath/percentDecoded take slices, dropping five per-call array copies

`lib/TerminalCore/Sources/TerminalCore/Terminal.swift:1541` -- high confidence, small effort, found by `core-parser`

**Problem.** One predicate ("decode these bytes only if they are valid UTF-8") has three spellings in this file: the hand-rolled `strictlyDecodedUTF8` (line 1541, used at 1356, 1435, 1436, 1552, 1556), the same decode-and-re-encode round trip written inline in `dispatchOSC8` (lines 1621-1622 and 1629-1630) and `dispatchOSC52` (lines 1734-1735), and `String(validating:as:)` (lines 1373, 1444, 1479). The round-trip form is exactly equivalent to `String(validating:)` — `String(decoding:)` only differs from the input when the input is invalid — but costs an extra `String` plus an extra `[UInt8]` per call, and `admitNotification` pays a third array copy converting its `ArraySlice` arguments with `Array(titleBytes)`.

**Recommendation.** Delete `strictlyDecodedUTF8` and replace all five of its call sites plus the three inline round trips with `String(validating:as: UTF8.self)`, passing the existing slices directly instead of materializing arrays.

**Verifier (confirmed).** Verified all eight sites: the helper at Terminal.swift:1541 with call sites 1356, 1435, 1436, 1552, 1556, and the inline round trips at 1621-1622, 1629-1630, 1734-1735; String(validating:as:) is already used unguarded at 1373, 1444, 1479 and the package targets .macOS(.v26) (lib/TerminalCore/Package.swift), so availability is not a concern. The round trip is exactly equivalent -- String(decoding:) only diverges from its input on invalid UTF-8 (including overlongs and surrogate encodings), and Swift does no normalization on init, so re-encoding a valid decode reproduces the bytes. String(validating:as:) accepts any Sequence<UInt8>, so ArraySlice arguments can be passed directly (line 1373 already does), removing the Array(titleBytes)/Array(bodyBytes) copies in admitNotification and the Array(payload[...]) materializations in dispatchOSC8/dispatchOSC52. localFilePath's signature would need to take a slice to get the full benefit; that is the only non-mechanical part. No hot path and no cross-module/inlinable surface is involved (all sites are private, same-module, per-OSC-sequence).

### 25. The cell-rect formula is spelled out seven times in the executor

**Status:** `done` -- one private cellRect(row:startColumn:columnCount:metrics:) now serves all seven sites

`lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift:409` -- high confidence, medium effort, found by `core-render`

**Problem.** The identical `CGRect(x: CGFloat(startColumn) * cellSize.width, y: CGFloat(row) * cellSize.height, width: CGFloat(count) * cellSize.width, height: cellSize.height)` appears seven times: background runs (409), selection runs (419), search-match runs (431), the block-cursor fill (444), `drawCursor`'s cellRect (557), `drawTextCell`'s cellRect (1132) and `drawDecorationRuns`' runRect (1167). Any of the seven can drift by half a pixel from the others -- which is precisely the reason `glyphOrigin` (line 539) was already extracted for the two baseline sites.

**Recommendation.** Add a private `cellRect(row:startColumn:columnCount:metrics:)` next to `glyphOrigin` and call it from all seven sites (the selection and search-match loops then collapse to the same three lines with a different fill color).

**Verifier (confirmed).** All seven sites verified in TerminalRenderExecution.swift (409, 419, 431, 444, 557, 1132, 1167) and they are character-for-character the same formula over (row, startColumn, count). The eighth `cellRect` at line 959 (drawGeometricShapeTriangle) is a different construction from a precomputed `cellOrigin` and correctly is not in the list. Extraction is safe: `glyphOrigin` (line 539) is already a private file-level func taking `metrics` by value and called from inside the `CGContext` extension on the far hotter per-glyph path, with a header comment giving exactly this drift rationale; parameters are +0 so passing `metrics` costs no retain even if the call is not inlined, and nothing crosses a SwiftPM target boundary. Minor wording nit: the selection/search-match loops collapse to one line each inside the loop, not three.

### 26. Duration-floor calibration is duplicated across two benchmark support targets

**Status:** `done` -- promoted to one public measureDurationStable in TerminalCoreBenchmarkSupport; both preconditions carried over and the dependency edge added

`lib/TerminalCore/Sources/TerminalDrawBenchmarkSupport/TerminalDrawBenchmarkSupport.swift:349` -- high confidence, small effort, found by `app-harness`

**Problem.** `measureDurationStable` (line 349) and `scaledBatchCount` (line 377) in TerminalDrawBenchmarkSupport are a copy of the calibrate-then-verify loop in `measureDurationStableFeed` (TerminalCoreBenchmarkSupport.swift:92) and its `scaledBatchCount` (line 128). The two `scaledBatchCount` bodies are identical line for line; the loops differ only in `guard let shortest = totals.min(), shortest < targetNanoseconds` versus `totals.allSatisfy { $0 >= targetNanoseconds }`, which are equivalent given both callers' `precondition(iterations >= 2)`. This is the duration-floor policy every reported sample in both benchmarks rests on, maintained in two places.

**Recommendation.** Promote the loop to one public `measureDurationStable(iterations:targetNanoseconds:measureBatch:) -> (batchCount: Int, totals: [UInt64])` in TerminalCoreBenchmarkSupport, have `measureDurationStableFeed` wrap it, and add TerminalCoreBenchmarkSupport as a dependency of TerminalDrawBenchmarkSupport (TerminalRetainedRowProbe already depends on it, so the cross-target reuse is precedented).

**Verifier (confirmed).** Both bodies read as claimed: TerminalDrawBenchmarkSupport.swift:349-386 vs TerminalCoreBenchmarkSupport.swift:92-137. The two scaledBatchCount functions are byte-identical; the verify loops differ only in `totals.allSatisfy { $0 >= target }` vs `guard let shortest = totals.min(), shortest < target else { return }`, which agree for any iterations >= 1 (and even for 0). Both callers do assert the floor input: measureDrawBenchmarks has precondition(iterations >= 2)/precondition(targetNanoseconds > 0) at lines 231-232, measureDurationStableFeed has them inline at 97-98. No cycle risk -- TerminalCoreBenchmarkSupport depends only on TerminalCore -- and no test references the private draw-side helper, so nothing loses coverage. Two notes for the implementer: carry both preconditions into the promoted function so the draw path keeps its guard, and update TerminalCoreBenchmarkSupport's file header ('Testable timing policy for the headless Terminal.feed benchmark executable') since it would no longer be feed-specific. The cross-target closure call is once per calibrated batch (target 400 ms in the draw case), so there is no dispatch concern under docs/design/2026-07-29-cross-module-value-dispatch.md.

### 27. setArmedLink recomputes canAdmitArmedLink's entire admission block

**Status:** `done` -- one private admittedHyperlinkTargets(adding:replacing:) serves all four sites; an over-cap arm now walks retained history once instead of twice

`lib/TerminalCore/Sources/TerminalCore/Terminal.swift:2451` -- high confidence, medium effort, found by `core-parser`

**Problem.** `setArmedLink` guards on `canAdmitArmedLink(link)` (line 2450) and then repeats that function's first nine lines verbatim (lines 2451-2459) to obtain `candidateTargets`: the same `hoverCost`, the same `reduce` over `hyperlinkTargets.values`, and the same `liveHyperlinkIds()`-then-`filter`. `liveHyperlinkIds()` calls `history.allPaintedDisplayRows()`, which materializes the whole retained scrollback, so an over-cap arm walks all of history twice. The same reclaim-then-recheck arithmetic also appears a third and fourth time in `dispatchOSC8` (lines 1644-1657) and `setHoveredLink` (lines 2398-2410), each with a slightly different "cost of the other interaction slot" term, so a change to the cap accounting has to be made in four places.

**Recommendation.** Extract one private helper (e.g. `admittedHyperlinkTargets(adding:excluding:) -> [HyperlinkId: TerminalHyperlink]?` returning nil when the link does not fit) and have `dispatchOSC8`, `setHoveredLink`, `canAdmitArmedLink`, and `setArmedLink` all go through it.

**Verifier (confirmed).** Verified verbatim: setArmedLink:2451-2459 duplicates canAdmitArmedLink:2433-2441 (same hoverCost, same reduce over hyperlinkTargets.values, same liveHyperlinkIds()-then-filter), and canAdmitArmedLink discards its reclaimed table, so the recompute is currently load-bearing rather than removable on its own. liveHyperlinkIds() (1700-1714) does call history.allPaintedDisplayRows(), materializing the whole retained scrollback, so an over-cap arm walks it twice inside setArmedLink -- three times counting the TerminalInteractionPolicy.swift#decideTerminalPointer predicate call that precedes it. dispatchOSC8:1644-1657 and setHoveredLink:2398-2410 are the third and fourth copies, differing only in the other-slot cost term (both slots / arm only / hover only), which a single `excluding:` parameter covers. The helper can be non-mutating (liveHyperlinkIds and hyperlinkByteCost are both non-mutating), so setHoveredLink's damageActionSnapshot/recordDamage bracketing is unaffected, and dispatchOSC8 keeps its allocateHyperlinkId step after the helper returns. Behavior-preserving and strictly less work on the over-cap path.

### 28. The "last display row of a record" walk is written out three times

**Status:** `done` -- folded into one private `lastRowRange(ofRecordAt:cellCount:)` used by all three sites

`lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift:707` -- high confidence, small effort, found by `core-storage`

**Problem.** Three private methods each open-code the same idiom -- run `LogicalLineFold.enumerateRows` over the whole record with an `isWideHead(recordAt:cell:)` probe and keep only the last callback's `(start, end)`: `repairClearedSpacer` (lines 707-713, which keeps only `end - start`), `removeLastDisplayRow` (lines 921-929, which also keeps the row count), and `pullBackOpenTailRemainder` (lines 1036-1043). Any change to the fold's last-row semantics has to be made in three places, and two of them already differ in what they keep.

**Recommendation.** Add one private helper on the store -- e.g. `lastRowRange(ofRecordAt offset: Int, cellCount: Int) -> (start: Int, end: Int, rowCount: Int)` -- and call it from all three sites.

**Verifier (confirmed).** All three sites verified verbatim at the cited lines: `repairClearedSpacer` 707-713 (keeps `end - start`), `removeLastDisplayRow` 921-929 (keeps start/end/rows), `pullBackOpenTailRemainder` 1036-1043 (keeps start/end). Identical arguments (whole record, store `width`, `self.isWideHead(recordAt: offset, cell:)`), and the defaults never survive because `enumerateRows` always fires at least one callback (296-299), so a shared helper is behavior-identical. Two safety checks passed: the helper should be a private *non-mutating* func (all three call sites are mutating and already capture `self` read-only in the probe closure), and docs/design/2026-07-29-cross-module-value-dispatch.md does not apply -- `LogicalLineFold` and `LogicalLineStore` are the same target, so no `@inlinable` surface is involved and none of the three sites is on the per-frame read path (sever, resize, width change).

### 29. Three near-identical convenience initializers on TerminalPaneSessionController

**Status:** `done` -- one private makeHost recipe behind all three convenience inits

`lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift:303` -- high confidence, medium effort, found by `pty`

**Problem.** Lines 303-380 hold three convenience initializers whose bodies are the same seven-argument `TerminalPTYHost(...)` construction followed by the same `self.init(host:launchInput:isVisible:theme:)` call. The `#if DANTERM_TERMINAL_CHARACTERIZATION` pair at 328-353 and 355-380 is byte-identical apart from `public` vs `package`, and the first (303-325) differs only in omitting `captureTransitions` (the public `TerminalPTYHost` init at line 252 just forwards with `captureTransitions: false`). That is ~75 lines carrying one construction recipe, and any new host parameter has to be threaded through all three.

**Recommendation.** Add a `private static func makeHost(configuration:bootstrapExecutable:machineHostname:theme:captureTransitions:recordsFlightTape:) throws -> TerminalPTYHost` holding the one recipe, and reduce each convenience init to `self.init(host: try Self.makeHost(...), launchInput: configuration.launchInput, isVisible: isVisible, theme: theme)`.

**Verifier (confirmed).** Verified: 303-325, 328-353, and 355-380 all end in the same `TerminalPTYHost(...)` build plus the same `self.init(host:launchInput:isVisible:theme:)`, with the `#if`/`#else` pair differing only in `public` vs `package`, and the first differing only by omitting `captureTransitions` (the public host init at 252 just forwards `captureTransitions: false`, so routing it through the package init is equivalent). All three are genuinely needed (the app calls the no-captureTransitions one in non-characterization builds, where the other is `package`-invisible), so shrinking the bodies rather than deleting an init is the right shape. `package` access from TerminalPaneSession into TerminalPTYHost is fine -- same SwiftPM package -- and computing the host in a `private static func` before `self.init` is legal in a convenience init, as the current code already does inline.

### 30. ReflowRowMetadata.startOffset and firstSourceKey are write-only

**Status:** `done` -- write-only startOffset/firstSourceKey removed along with their writes and the unread return-tuple element

`lib/TerminalCore/Sources/TerminalCore/Terminal.swift:528` -- high confidence, trivial effort, found by `core-parser`

**Problem.** `ReflowRowMetadata.startOffset` and `.firstSourceKey` are assigned (lines 4740, 4742, 4748, 4752, 4784, 4799, 4802) and never read anywhere in the package — a grep for both names across `app/`, `lib/TerminalCore/Sources`, and `lib/TerminalCore/Tests` returns only the declarations and these writes. `startOffset` even carries a doc comment claiming it "turns a live (row, column) anchor into the boundary key `pack` produces destinations for", but that conversion is done independently by `liveReflowOffset(inRow:upTo:)`. The whole `rowMetadata: [ReflowRowMetadata]` element of `reconstructLogicalLines`' return tuple is likewise unread: its only caller, `resizeWidth` (line 4326), uses `reconstruction.lines`, `.anchor`, and `.cursorLine` only.

**Recommendation.** Drop `startOffset` and `firstSourceKey` from `ReflowRowMetadata` along with their three `firstSourceKey = firstSourceKey ?? key` assignments in the reflow inner loop, and drop `rowMetadata` from the return tuple (the local `metadata` array is still needed for `cursorMetadata`).

**Verifier (confirmed).** Confirmed by grep across lib/TerminalCore/Sources, lib/TerminalCore/Tests and app: `startOffset` and `firstSourceKey` appear only at the declarations (528, 531), the local/initializer writes (4740, 4742, 4748, 4752, 4784, 4799, 4802) -- never read. Only line, boundaryOffset and retainedEnd are read, via cursorMetadata at 4815-4841. reconstructLogicalLines has exactly one caller (resizeWidth:4326), which destructures .lines, .anchor and .cursorLine only, so the rowMetadata tuple element is unread too and the local `metadata` array stays for cursorMetadata. No test touches any of these names. Git history supports it: firstSourceKey came in with "reflow primary history on resize" (295fdddf) and was orphaned by 9ad7cc55, which deleted reflow of history -- so the startOffset doc comment describes a mechanism that no longer exists, and liveReflowOffset(inRow:upTo:) does that conversion now.

### 31. Dead bytesInUse subtraction before resetToEmptyArena

**Status:** `done` -- dead `bytesInUse` subtraction removed from dropHeadRecord's empty branch

`lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift:841` -- high confidence, trivial effort, found by `core-storage`

**Problem.** In `dropHeadRecord`, the empty-store branch does `bytesInUse -= record.byteLength` (line 841) and then calls `resetToEmptyArena()` (line 842), which unconditionally assigns `bytesInUse = 0` (line 874). The subtraction can never be observed, and it reads as if the two lines were maintaining the same quantity together.

**Recommendation.** Delete line 841 so the branch is just `resetToEmptyArena(); return`.

**Verifier (confirmed).** Confirmed straight-line: LogicalLineStore.swift:840-844 subtracts then calls `resetToEmptyArena()`, which unconditionally assigns `bytesInUse = 0` at 874 with nothing in between that reads it. Zero-risk deletion. Worth noting for the human that the visually similar line in `dropTailRecord` (954) is NOT dead -- it precedes the emptiness test and is required on the non-empty path -- so only the `dropHeadRecord` one should go.

### 32. Duplicated capacity guard in EscapeAbsorber.dispatchCSI

**Status:** `partial` -- unreachable inner capacity guard deleted; the csiParameter arm fold left undone on purpose (the verifier marked it optional and the split mirrors csiEntry)

`lib/TerminalCore/Sources/TerminalCore/EscapeAbsorber.swift:363` -- high confidence, trivial effort, found by `core-parser`

**Problem.** `dispatchCSI` runs `guard parameters.count < Self.parameterCapacity else { return nil }` at line 361 and again at line 363; nothing between them touches `parameters`, so the second guard can never fire. Nearby, `csiParameter`'s `case 0x30...0x3A: collectParameter(byte)` (line 215) and `case 0x3B: collectParameter(byte)` (line 217-218) are two arms with identical bodies over adjacent byte ranges.

**Recommendation.** Delete the inner guard at line 363, and fold the two `csiParameter` arms into a single `case 0x30...0x3B: collectParameter(byte)`.

**Verifier (confirmed).** Verified: dispatchCSI (EscapeAbsorber.swift:359-366) guards parameters.count < parameterCapacity at 361 and again at 363 with only the `if hasParameterDigits || parameters.isEmpty == false` test between them -- both are stored-property reads with no side effects, so the inner guard can never fire. Deleting the inner one (not the outer, which is the real overflow-drop policy) is behavior-preserving. The second half is cosmetic-only: csiParameter's `case 0x30...0x3A` and `case 0x3B` (215-218) do have identical bodies and fold to `0x30...0x3B` with no behavior change, but note the split mirrors csiEntry:192-197, where 0x3A and 0x3B are deliberately handled differently, so keeping the arms apart is a defensible reading too -- treat that part as optional.

### 33. clipFramePlan filters the damage set for rows no plan can contain

**Status:** `done` -- per-clip Set rebuild dropped; damageClipping still green

`lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift:22` -- high confidence, trivial effort, found by `core-render`

**Problem.** `let rows = damage.rows.filter { plan.rows > $0 }` rebuilds the damage `Set` on every clip, but the filter cannot change any answer: every value later queried via `rows.contains(...)` is a run row or `plan.cursor.row`, and `RenderFramePlan`'s initializer is internal to this module, so the only producer is `FramePlanner.plan`, which emits rows strictly inside `0..<rowCount` (the retained-reuse path is gated on `retained.rowCount == rowCount`). The result is a per-frame Set allocation and rehash whose output is queried identically to `damage.rows`.

**Recommendation.** Use `damage.rows` directly and delete the `filter`.

**Verifier (confirmed).** `RenderFramePlan.init` is internal (TerminalRenderPlanning.swift:295) and rg finds only two producers in Sources -- `clipFramePlan` itself and `FramePlanner.plan` -- plus one test helper that rebuilds from an existing plan's runs. Every run row is the loop index in `0..<rowCount` and `plan.rows == rowCount`; `cursorSpan` is bounded by `geometry.rows.indices` (line 276), and the reuse path is gated on `retained.rowCount == rowCount`, so no run or cursor row can be >= plan.rows and the filter can only drop damage rows nothing queries. `damage.rows` is already a `Set<Int>` (TerminalDamage.swift:15), so `contains` stays O(1) and the change removes a per-clip Set allocation. The one test that pins out-of-range damage -- RenderFramePlanningTests.damageClipping, `TerminalDamage(rows: [-1, 1, 5])` against a 3-row plan -- still passes unchanged, since {5} matches no run and the cursor is on row 2.

### 34. canonicallyOrder builds the combining-class array before its early return

**Status:** `done` -- single-scalar early return hoisted above the combining-class array

`lib/TerminalCore/Sources/TerminalCore/CanonicalCaseless.swift:76` -- high confidence, trivial effort, found by `core-rest`

**Problem.** `canonicallyOrder` runs `var classes = values.map(canonicalCombiningClass)` on line 76 and only then checks `guard values.count > 1 else { return }` on line 77. For the zero- and one-scalar cases -- which dominate, since `canonicalCaselessKey` calls `canonicalDecomposition` twice per grapheme and most graphemes decompose to a single scalar -- this allocates an array and runs a binary search whose result is immediately discarded.

**Recommendation.** Move `guard values.count > 1 else { return }` above the `classes` map so the early return happens before any work; the count > 1 path is bit-for-bit unchanged.

**Verifier (confirmed).** Verified at CanonicalCaseless.swift lines 75-78: `var classes = values.map(canonicalCombiningClass)` runs before `guard values.count > 1 else { return }`. Hoisting the guard is bit-for-bit identical on the count > 1 path (`classes` is untouched before the guard) and the guard is still required for both count 0 and count 1, since `1..<values.count` traps at count 0. `canonicallyOrder` is called twice per grapheme via `canonicalCaselessKey` -> `canonicalDecomposition` (lines 31/35), so the single-scalar case really is the common one, and it currently costs one heap allocation plus one binary search per call.

### 35. drawCursor gates .block twice, leaving an unreachable switch case

**Status:** `done` -- redundant guard dropped; the unreachable case is now a commented early return

`lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift:566` -- high confidence, trivial effort, found by `core-render`

**Problem.** `drawCursor` returns early for the block shape at line 556 (`guard cursor.shape != .block else { return }`) and then repeats the same decision as `case .block: return` at line 566. The switch case is required for exhaustiveness, so the guard is the redundant half -- two gates for one condition, and a reader has to check both to see that block cursors are handled by the background fill in `drawRenderFrame` instead.

**Recommendation.** Delete the `guard` on line 556 and let the switch's `case .block: return` be the single gate.

**Verifier (confirmed).** Both gates verified (guard at line 556, `case .block: return` at 566) and `TerminalCursorShape` has exactly three cases (TerminalPresentation.swift:4-8), so the switch stays exhaustive without the guard. Deleting the guard only makes a block cursor compute `cellRect` and `thickness` before returning -- side-effect-free, once per frame at most. Worth pairing with a one-line comment on `case .block` pointing at the background fill in `drawRenderFrame` (lines 439-450), since neither gate currently carries the reason; that is a nicety, not a precondition for the change.

### 36. ellipseOutline duplicates its corner predicate in the empty-result fallback

**Status:** `done` -- one hoisted local inCorner(_:_:) serves the main scan and the fallback

`lib/TerminalCore/Sources/TerminalSpriteGeometry/LegacyComputingSupplementSpriteGeometry.swift:260` -- high confidence, small effort, found by `core-rest`

**Problem.** `ellipseOutline` computes the same `inCorner` switch over `LegacySupplementArcCorner` twice: once in the main scan (lines 242-248) and again, character for character, in the `result.isEmpty` nearest-pixel fallback (lines 260-266). The `dx`/`dy` normalization feeding it is likewise duplicated (lines 239-240 and 258-259). Editing the corner semantics in one copy and not the other silently makes the degenerate-size fallback pick a pixel from the wrong quadrant.

**Recommendation.** Hoist a single local `func inCorner(_ dx: Double, _ dy: Double) -> Bool` (closing over `corner`) above the first loop and call it from both scans.

**Verifier (confirmed).** Verified: the `dx`/`dy` normalization (lines 239-240 vs 258-259) and the four-case `LegacySupplementArcCorner` switch (lines 242-248 vs 260-266) are character-for-character identical, and the fallback's copy is what keeps the degenerate-size nearest-pixel pick inside the requested quadrant, so a one-sided edit really does silently corrupt it. A non-escaping local `func inCorner(_ dx: Double, _ dy: Double) -> Bool` capturing `corner` is a pure refactor; the compiler inlines it, and the second scan only runs when the main scan produced nothing, so there is no plausible regression on the per-cell draw loop.

### 37. Tautological `where` clause in the checker mosaic loop

**Status:** `done` -- tautological `where y < rows` deleted

`lib/TerminalCore/Sources/TerminalSpriteGeometry/LegacyComputingSpriteGeometry.swift:209` -- high confidence, trivial effort, found by `core-rest`

**Problem.** `for y in 0..<rows where y < rows` -- the `where y < rows` condition is implied by the range bound and can never be false, so it reads as a guard that does nothing. It sits directly above a genuine filter (`for x in 0..<4 where (x + y) % 2 == parity`), which makes it look intentional.

**Recommendation.** Delete the `where y < rows` clause, leaving `for y in 0..<rows {`.

**Verifier (confirmed).** Verified at LegacyComputingSpriteGeometry.swift line 209: `for y in 0..<rows where y < rows` -- `rows` is `let`-bound at line 208 and never mutated in the loop, so the clause is always true and deleting it is a provable no-op. It is also genuinely misleading in context, sitting one line above the real filter `for x in 0..<4 where (x + y) % 2 == parity`.

### 38. Dead store of .tearingDown before finishTeardown in the sessionDrained arm

**Status:** `done` -- unobservable .tearingDown store removed

`lib/TerminalPTY/Sources/PaneLifecycle/PaneLifecycle.swift:258` -- high confidence, trivial effort, found by `pty`

**Problem.** In `handleTeardown`'s `case .sessionDrained where !next.sessionDrained`, line 258 assigns `storage = .tearingDown(next)`, but both exits from that arm (lines 260 and 262) call `finishTeardown(next)`, which unconditionally sets `storage = .finished` (line 301). Nothing reads `storage` in between, so the assignment can never be observed. The sibling `.childExited` arm at line 251 needs its identical-looking assignment because one of its two paths does not finish, which makes this copy read as load-bearing when it is not.

**Recommendation.** Delete line 258 and pass the locally updated `next` straight into `finishTeardown(next)`.

**Verifier (confirmed).** Verified: in `handleTeardown`'s `.sessionDrained` arm both exits (260 and 262, the latter through `[.reapLeader] + finishTeardown(next)`) call `finishTeardown`, which unconditionally sets `storage = .finished` (301). Nothing between 258 and those calls reads `storage` -- line 259 reads the local `next` -- so the store is unobservable. The contrast with the `.childExited` arm at 251 is accurate: its `!next.sessionDrained` path returns `[.reapLeader]` without finishing, so that store is load-bearing. Deleting 258 is safe and makes the asymmetry meaningful.

### 39. classifySpawnFailure is an identity wrapper

**Status:** `done` -- classifySpawnFailure inlined at both call sites and deleted

`lib/TerminalPTY/Sources/TerminalPTYHost/PTYSpawner.swift:195` -- high confidence, trivial effort, found by `pty`

**Problem.** `private static func classifySpawnFailure(_ code: Int32) -> SpawnFailure { .systemError(code) }` performs no classification — it is a one-to-one rename of the enum case. Its two call sites (lines 88 and 123) sit beside four other sites in the same function that construct `.failure(.systemError(...))` directly (lines 45, 56, 66, 78, 92, 156), so the indirection makes two of eight failure paths look like they get special treatment when they do not.

**Recommendation.** Inline it — replace both `classifySpawnFailure(x)` calls with `.systemError(x)` and delete the function.

**Verifier (confirmed).** Verified: PTYSpawner.swift:195-197 returns `.systemError(code)` with no classification, it is `private static` (no test or cross-file reference possible), and its only callers are lines 88 and 123, sitting among direct `.failure(.systemError(...))` constructions at 45, 56, 66, 73, 78, 92, 145, and 156. It carries no doc comment claiming a seam for future classification, which AGENTS.md would require if the indirection were intentional. Inlining is a pure textual change with no behavior difference. (Nit: the finding says "four other sites" then lists six; the count is off but nothing turns on it.)

### Downgraded (code simplifications)

Real problems, but apply the verifier's adjustment.

### 40. TerminalPaneLaunchConfiguration.initialDimensions is stored but derivable

**Status:** `done` -- initialDimensions is computed; one construction site had been hand-writing a diverging 80x24

`lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneLaunch.swift:68` -- high confidence, small effort, found by `pty`

**Problem.** `TerminalPaneLaunchConfiguration` stores `initialDimensions` alongside `launchInput`, whose `LaunchPolicyInput.initialDimensions` must hold the identical value — the struct's own doc says its job is "Keeps the duplicated host/launch geometry visibly identical at construction." The type is constructed in exactly one place, `assembleTerminalPaneLaunch` (line 92), where both fields are fed from the same `dimensions` local, and the stored field is only read at TerminalPaneSession.swift:312/339/365 to build the host. A mismatch is not caught at the boundary; it surfaces as a runtime launch failure in `TerminalPTYHost.start` (line 313), which rewrites the input to 0x0 to force `.launchFailed(.invalidDimensions)`. The invariant is documented rather than enforced when it could be unrepresentable.

**Recommendation.** Replace the stored property with `public var initialDimensions: TerminalDimensions { launchInput.initialDimensions }` and drop the parameter from the initializer, so the two geometries cannot diverge.

**Verifier (adjustment required).** The duplication and the fix are real, but the claim "constructed in exactly one place" is wrong: the type is built at six sites -- TerminalPaneLaunch.swift:92 plus `.init(...)` in TestSupport/TerminalWorkflowRunner/main.swift:102, TestSupport/TerminalProtocolProbeRunner/main.swift:58, and TerminalPaneSessionControllerTests.swift:1184, 1251, 1708. My grep for `TerminalPaneLaunchConfiguration(` missed them because they use `.init`. Adjustment: the change must drop the argument at all six sites (note 1708 passes a hand-written `.init(columns: 80, rows: 24)` next to a `makeLaunchInput` launch input -- the exact divergence the finding is about, which strengthens the motivation but makes effort medium, not small), and TerminalPaneSessionPolicyTests.swift:81 (`input.initialDimensions == configuration.initialDimensions`) becomes a tautology and should be deleted rather than left asserting nothing.

### 41. Unreachable OSC branches in EscapeAbsorber.consume

**Status:** `done` -- both dead OSC bodies deleted; the verifier-rejected 8-bit ST clause was not applied

`lib/TerminalCore/Sources/TerminalCore/EscapeAbsorber.swift:105` -- high confidence, trivial effort, found by `core-parser`

**Problem.** `consume` returns unconditionally for `state == .oscString` (lines 73-86) and for `state == .oscEscape` (lines 87-92) before reaching the C1 switch, and the switch's own `.oscString/.oscEscape` arm is a `preconditionFailure` (line 313) stating exactly that. So `case 0x9C`'s `if state == .oscString || state == .oscEscape { return dispatchOSC() }` (lines 106-108) and `case 0x1B`'s `if state == .oscString { state = .oscEscape; return nil }` (lines 113-115) can never execute. They also misrepresent the parser's actual behavior: the absorber does honor 8-bit C1 controls elsewhere (lines 101-135 execute 0x80-0x8F and start CSI/DCS/OSC from 0x9B/0x90/0x9D), but a real 0x9C ST inside an OSC falls through to `collectOSC` and is appended to the payload, so only BEL and `ESC \\` terminate an OSC.

**Recommendation.** Delete the two dead `if` bodies so the switch reads as "state is never an OSC state here", and if 8-bit ST really should terminate an OSC, add that check to the live `.oscString` branch at line 73 instead.

**Verifier (adjustment required).** The dead-code claim is exactly right: consume returns on every path for .oscString (lines 71-86) and .oscEscape (87-92), so `case 0x9C`'s OSC check (106-108) and `case 0x1B`'s (113-115) are unreachable, matching the preconditionFailure at 312-313; deleting those two bodies is safe. The trailing clause is not: 8-bit ST must NOT be added to the live .oscString branch. OSC payloads are UTF-8 text (window titles, URIs), and 0x9C is a legitimate continuation byte -- U+201C encodes as E2 80 9C -- so terminating on a raw 0x9C would truncate any title containing such a character. It is also deliberate policy: TerminalFixtureTests.swift#libvtermManifestCoverage records "DanTerm follows VT500 string states: C0 is absorbed inside strings and BEL terminates only OSC" and #windowsTerminalManifestCoverage records "DanTerm treats raw C1 bytes as UTF-8 input", and two tests pin it -- TerminalHyperlinkTests.swift:62 and TerminalOSC52Tests.swift:108 both feed a raw 0x9C inside an OSC and require it to land in the payload (the hyperlink one would start accepting `https://invalid` and fail). Apply the deletion; drop the conditional suggestion.

### 42. applyViewportNavigation accepts a 9-case transition and dead-ends 6 of them

**Status:** `done` -- cheap version per the verifier: unreachable arm is a preconditionFailure, no private enum

`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift:1122` -- high confidence, small effort, found by `pty`

**Problem.** `applyViewportNavigation(_:publishUpdate:)` takes a `TerminalPTYAppliedTransition`, but only `.scrollByRows`, `.scrollToTopRow`, and `.scrollToBottom` are meaningful; line 1122 is `case .feed, .input, .paste, .focus, .mouse, .resize: return`, a silent no-op for six cases. All seven call sites (lines 334, 401, 410, 419, 965, 1091, 1100) pass one of the three navigation cases, so that arm is unreachable. The over-general parameter also means a mistaken `.feed(...)` call would compile and silently do nothing instead of failing to build.

**Recommendation.** Introduce a private `enum ViewportNavigation { case byRows(Int); case toTopRow(Int); case toBottom }` as the parameter type and map it to the corresponding `TerminalPTYAppliedTransition` at the single `appliedTransitions.append` on line 1126, deleting the unreachable arm.

**Verifier (adjustment required).** Facts check out: all seven call sites (334, 401, 410, 419, 965, 1091, 1100) pass `.scrollByRows`/`.scrollToTopRow`/`.scrollToBottom`, so the arm at 1122 is unreachable. But the recommendation is not a net simplification: a private three-case enum plus the mapping switch needed at the `appliedTransitions.append` (1126) adds roughly as many lines as the one dead line it removes, and it renames three call-site cases for no readability gain. Adjustment: either take the cheap version -- replace the dead arm with a `preconditionFailure` naming the three legal cases, matching finding 1's treatment of the same shape one screen away -- or, if the private enum is wanted for type safety, sell it as type safety and put the mapping in a computed `appliedTransition` property so it lives in one place.

### 43. Column padding in inspectedCells is written twice

**Status:** `done` -- in-closure padding loop deleted, stale comment rewritten, overlapping access hoisted (both verifier adjustments)

`lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift:340` -- high confidence, trivial effort, found by `core-render`

**Problem.** The `while cells.count < kinds.count { cells.append(plannedCell(... scalars: .empty, semanticStyle: TerminalStyle() ...)) }` block appears twice with identical bodies: inside the traversal closure (340-351) and again in the post-traversal pass (362-372). The in-closure copy is also currently unreachable: `Terminal.forEachViewportRow` already pads every visited row out to `columnCount` (Terminal.swift:4090-4098) and `TerminalGeometry` rows always hold exactly `columnCount` cells (`presentedRowGeometry`, Terminal.swift:3145-3148), so `cells.count == kinds.count` on exit from `visit`, and the post-pass covers the shortfall case for every replanned row anyway.

**Recommendation.** Delete the in-closure `while` loop (lines 340-351) so padding lives only in the post-traversal pass, and while there, append directly into `result[row]` instead of `var cells = result[row]` to avoid the CoW copy.

**Verifier (adjustment required).** The duplication and the unreachability both check out -- Terminal.forEachViewportRow pads every visited row to `columnCount` (Terminal.swift:4090-4098, plus the spacer emit at 4067-4077), `forEachPaintedCell` emits contiguous columns from 0 (LogicalLineStore.swift:1427-1467), and `presentedRowGeometry` allocates exactly `columnCount` kinds (Terminal.swift:3145-3148), so `cells.count == kinds.count` on exit from `visit`; the post-pass condition `result[row].count < kinds.count` also covers any visited-but-short row, so nothing is lost. Two adjustments the recommendation needs. (1) The post-pass comment at lines 355-356 asserts it can only be reached by a row the traversal never handed out -- that becomes false once it is the sole padding site and must be rewritten, or the next reader will re-add the in-closure loop. (2) `result[row].append(plannedCell(column: result[row].count, ...))` is an overlapping access to `result` (read inside an active modify); hoist `let column = result[row].count` first. Also note the CoW argument is cosmetic: the second pass only runs for rows whose stream row does not resolve, so it is off the hot path.

### 44. cornerDiagonalMasks table duplicated verbatim in the same file

**Status:** `done` -- duplicate cornerDiagonalMasks table deleted; the survivor is fileprivate per the verifier

`lib/TerminalCore/Sources/TerminalSpriteGeometry/LegacyComputingSpriteGeometry.swift:47` -- high confidence, trivial effort, found by `core-rest`

**Problem.** The identical 15-element literal `[1, 2, 4, 8, 5, 10, 12, 3, 9, 6, 14, 13, 11, 7, 15]` is declared twice in one file: `LegacyComputingTopology.cornerDiagonalMasks` (line 47, used by `decode` at line 84) and `LegacyComputingSpriteGeometry.cornerDiagonalMasks` (line 131, used by `runs` at line 336). Both index the same 0x1FBA0...0x1FBAE scalar offset, so the decoded topology and the drawn pixels are keyed off two copies of one table that must stay in lockstep and nothing enforces it.

**Recommendation.** Delete `LegacyComputingTopology.cornerDiagonalMasks` (line 47) and have `decode` read `LegacyComputingSpriteGeometry.cornerDiagonalMasks` instead, leaving exactly one table.

**Verifier (adjustment required).** The duplication is real and exact: `[1, 2, 4, 8, 5, 10, 12, 3, 9, 6, 14, 13, 11, 7, 15]` at LegacyComputingSpriteGeometry.swift line 47 (used by `decode` for 0x1FBA0...0x1FBAE) and line 131 (used by `runs` for the same span), both indexed by `Int(value - 0x1FBA0)`. Required adjustment: the recommendation as written will not compile. `LegacyComputingSpriteGeometry.cornerDiagonalMasks` is `private`, and in Swift a member's `private` scope is the enclosing declaration plus same-file extensions of it -- a sibling type (`LegacyComputingTopology`) cannot reach it. The surviving table must be `fileprivate`, matching the existing precedent in this same file: `smoothMosaicGrids` is `fileprivate` precisely so `decode` can read it at line 68.

### 45. tearDown and fenceForApplicationExit duplicate the close-fence sequence

**Status:** `done` -- extracted stopDeliveryAndCacheFinalTerminal(); both verifier adjustments honored

`lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift:573` -- high confidence, trivial effort, found by `pty`

**Problem.** `fenceForApplicationExit()` (lines 573-583) and `tearDown()` (lines 797-815) repeat the same five-step, order-sensitive sequence: guard `isTornDown`, `deliveryBoundary.stop()`, `performAccountedFence(kind: .teardown, operation: .beginCloseAndSnapshot)`, the `guard case .closeSnapshot` payload check with its `preconditionFailure`, and `cachedTerminal = terminal` / `isTornDown = true`. Only the tails differ (exit emits `emitPrimaryHistoryMutationIfNeeded()`; teardown nils the nine callbacks). Duplicating the ordering of stop-then-fence in the two functions that end a pane's life is where a future change gets applied to one and not the other.

**Recommendation.** Extract `private func stopDeliveryAndCacheFinalTerminal()` containing the shared guard/stop/fence/cache/`isTornDown` steps, and have both entry points call it before running their distinct tails.

**Verifier (adjustment required).** The duplication is real, but the extraction as specified changes behavior twice. (1) `fenceForApplicationExit` calls `emitPrimaryHistoryMutationIfNeeded()` BEFORE `isTornDown = true` (581 then 582); `tearDown` sets the flag first (805). Folding `isTornDown = true` into the shared helper moves the emit after it, and that callback re-enters: app/AppRuntime.swift:1679 wires it to `notePrimaryHistoryMutation` -> `applyRecoveryAction(.write)` -> `performEnrichedCheckpoint` -> `captureScrollbackReads` -> `SwiftTerminalSessionView.primaryHistoryTailReader()` -> `controller.synchronizeState()`, which is itself gated on `isTornDown`. Keep `isTornDown = true` out of the helper (set it last in each tail). (2) A void helper that owns `guard isTornDown == false else { return }` does not stop the caller's tail, so a `tearDown()` after `fenceForApplicationExit()` would newly nil the nine callbacks; the helper must return a Bool the callers guard on.

### 46. Unreachable .zero arm in Terminal.print's width switch

**Status:** `done` -- verifier form (doc-only): the switch stays, with a comment tying the unreachable arm to the guard and to the exhaustiveness check

`lib/TerminalCore/Sources/TerminalCore/Terminal.swift:5907` -- high confidence, trivial effort, found by `core-parser`

**Problem.** `print(_:)` returns early on `guard properties.cellWidth != .zero` (line 5899) and then switches over the same `properties.cellWidth` with a `case .zero: break` arm (lines 5907-5908) that cannot be reached, which makes the reader look for a zero-width path that does not exist.

**Recommendation.** Replace the three-arm switch with `if properties.cellWidth == .wide { printWide(...) } else { printNarrow(...) }`, or keep the switch and drop the `.zero` arm by switching on a non-optional narrow/wide value.

**Verifier (adjustment required).** The unreachability claim is correct -- `properties` is a local let bound at 5898, the guard at 5899 rejects .zero, and the switch at 5906 re-tests the same value -- but the recommendation is a net negative as written. TerminalCellWidth (UnicodeProperties.generated.swift:7-11) is a three-case enum, so Swift requires the `case .zero: break` arm for exhaustiveness; it cannot simply be dropped from a switch. Replacing the switch with `if == .wide { printWide } else { printNarrow }` in the engine's hottest function trades the compiler's exhaustiveness check for two saved lines: a future case added by the table generator would then silently route through printNarrow instead of failing to compile. The stated harm (a reader hunting for a zero-width path) is small next to that, and the alternative ("switch on a non-optional narrow/wide value") means reshaping TerminalUnicodeProperties, which is not trivial effort. If anything is done here, keep the switch and add a short comment tying the .zero arm to the guard above it.

## 3. Test pruning

Tests that duplicate surviving coverage, pin behavior that no longer exists, or cannot fail.

### 47. PO5 timing tests guard a read path production no longer takes

**Status:** `done` -- both wall-clock ratio tests deleted; header records that PO5's subject is retired

`lib/TerminalCore/Tests/TerminalCoreTests/TerminalPackedRetainedRowTests.swift:418` -- high confidence, small effort, found by `tests-storage`

**Problem.** `randomReadIsFlatInStoredWidth` (line 418) and `fullRowReadStaysLinear` (line 455) are wall-clock ratio assertions that run in the default `just test` gate, and both exercise `Terminal.PackedRetainedRow.cell(at:)` / `.unpacked()`. Retained history is now `Terminal.LogicalLineStore` (Terminal.swift declares `private var history: LogicalLineStore`), and grepping `lib/TerminalCore/Sources/` shows no caller anywhere for `PackedRetainedRow.pack`, `.unpacked()`, `.cell(at:)`, `.forEachCell`, `.forEachContentCell` or `.forEachKind` -- the only production references to the type are `PackedRetainedRow.Header` constants that `LogicalLineStore` borrows for the shared C1 cell word. Both tests' own preambles justify themselves as "a regression here just makes browsing slow", but browsing now reads `LogicalLineStore.forEachPaintedCell`, so neither test can protect the claim it states while both can flake on a loaded machine.

**Recommendation.** Delete `randomReadIsFlatInStoredWidth` and `fullRowReadStaysLinear`; if the flat-random-read property still needs a guard, restate it against `LogicalLineStore.locate(displayRow:)` + `forEachPaintedCell(at:_:)`, which is the reader the frame path actually uses.

**Verifier (confirmed).** Checked: Terminal.swift#history is `private var history: LogicalLineStore`; grepping app/, lib/ and lib/TerminalCore/Sources for `PackedRetainedRow.pack`, `.unpacked()`, `.cell(at:)`, `.forEachCell`, `.forEachContentCell`, `.forEachKind` returns zero production hits -- the only live references are `PackedRetainedRow.Header.*` constants borrowed by LogicalLineStore.swift and LogicalLineRecord.swift. The type is internal (not public API), and no other SwiftPM target (TerminalRetainedRowProbeSupport et al.) touches it. TerminalCoreTests is a path-based test target, so deleting tests needs no Package.swift change. Two caveats for the human, neither refuting: (a) the flake claim is asserted, not measured -- the strong argument is that the tests can no longer guard what their preambles claim, since LogicalLineStore reimplements its own readers and only shares the cell-word layout; (b) the same dead-code reasoning covers the whole PackedRetainedRow type, not just these two tests, and doc 28's `PO5`/`decisions.md:823` record should note the obligation's subject is retired rather than silently losing the two tests that stood for it.

### 48. TerminalScrollbackRetentionTests duplicates the census retention proof

**Status:** `done` -- guards folded into censusReportsRetentionHealth with the rationale carried over; TerminalScrollbackRetentionTests.swift deleted

`lib/TerminalCore/Tests/TerminalCoreTests/TerminalScrollbackRetentionTests.swift:19` -- high confidence, small effort, found by `tests-storage`

**Problem.** `frontEvictionReleasesEvictedRows` (line 19) builds `Terminal(columns: 8, rows: 2, scrollbackBudgetBytes: 6_000)`, feeds 1,200 lines, and asserts peak charge <= capacity plus capacity-never-grows. `TerminalMemoryCensusTests.censusReportsRetentionHealth` (line 151) builds the identical terminal (same 8x2 geometry, same 6_000 budget), feeds the identical 1,200 lines, and asserts the same two things -- `memoryCensus.retainedChargedBytes` is defined in TerminalMemoryCensus.swift:145 as exactly `LogicalLineStore.Census.chargedBytes`. `clearingHistoryReleasesEveryRow` (line 57) is likewise covered twice over: `censusReportsRetentionHealth` ends with the same ED-3 -> `retainedArenaBytesInUse == 0` check, and `TerminalScrollbackBudgetTests.eraseDisplayThreeResetsBudgetState` (line 290) already asserts rowCount 0, recordCount 0 and arenaBytesInUse 0 after ED 3. The only assertions unique to this file are the guard-the-guard pair `#expect(sawEviction)` and `#expect(1_200 - terminal.scrollbackRowCount > 100)`.

**Recommendation.** Move the `sawEviction` / eviction-depth guard assertions into `TerminalMemoryCensusTests.censusReportsRetentionHealth` and delete `TerminalScrollbackRetentionTests.swift` (the whole TerminalCore test target is one `scripts/run-test-suite.sh` step and suites are auto-discovered, so no gate or Package.swift wiring changes).

**Verifier (confirmed).** Verified the quantities are literally identical, not merely analogous: Terminal.swift#memoryCensus builds `retainedArenaBytesInUse/CapacityBytes/IndexBytes/SideTableBytes` straight from `let arena = history.census`, and `TerminalMemoryCensus.retainedChargedBytes` is `arenaBytesInUse + indexBytes + sideTableBytes` -- the same expression as `LogicalLineStore.Census.chargedBytes`. Both tests build Terminal(8, 2, 6_000), feed 1,200 lines, sample the peak per iteration, and assert peak <= capacity plus capacity-unchanged; censusReportsRetentionHealth additionally asserts `hasRetainedStorageOverdraft == false` and the ED-3 -> arenaBytesInUse == 0 tail. TerminalScrollbackBudgetTests#eraseDisplayThreeResetsBudgetState does assert rowCount 0 / recordCount 0 / arenaBytesInUse 0 after ED 3 (at a smaller but still evicting fixture). Package.swift confirms TerminalCoreTests is path-based, so the deletion is wiring-free. One adjustment: carry the deleted file header's 'accounting vs effect / doc 15 F4 failed independently' rationale into censusReportsRetentionHealth's preamble along with the sawEviction and eviction-depth guards, or the reason the second proof existed is lost with the file.

### 49. legacyNavigationMatrix is a strict subset of completeLegacySpecialKeyMatrix

**Status:** `done` -- all nine literals verified as produced by completeLegacySpecialKeyMatrix's sweeps

`lib/TerminalCore/Tests/TerminalCoreTests/TerminalKeyEncodingTests.swift:147` -- high confidence, trivial effort, found by `tests-behavior-b`

**Problem.** All 9 cases in `legacyNavigationMatrix` are already produced by `completeLegacySpecialKeyMatrix` (line 29), which sweeps the full 8-entry xterm modifier table over the same key sets under the same `modes: .default`. Checked each: (.up,[]) and (.up,[.shift]) and (.home,[.alt,.control]) come from its `cursorKeys` loop; (.insert,[]), (.pageDown,[.control]), (.f5,[]), (.f12,[.alt]) from its `tildeKeys` loop; (.f1,[]) and (.f1,[.shift]) from its `ss3Keys` loop. Every expected string matches the formula the surviving test builds. Nothing in `legacyNavigationMatrix` can fail while `completeLegacySpecialKeyMatrix` passes.

**Recommendation.** Delete `legacyNavigationMatrix`; `completeLegacySpecialKeyMatrix` keeps the coverage.

**Verifier (confirmed).** Checked all 9 literals against the surviving sweep at lib/TerminalCore/Tests/TerminalCoreTests/TerminalKeyEncodingTests.swift#completeLegacySpecialKeyMatrix: up/home come from the cursorKeys loop (param 1 -> ESC[A, param 2 -> ESC[1;2A, param 7 -> ESC[1;7H), insert/pageDown/f5/f12 from tildeKeys (2~, 6;5~, 15~, 24;3~), f1 from ss3Keys (ESC OP, ESC[1;2P). Same key type, same modes: .default, same encodeTerminalKey entry point -- nothing in the deleted table can fail while the sweep passes. The one theoretical loss (formula-built expectations vs. golden literals) is covered independently: Fixtures/libvterm/state-input.json pins literal inputBytes for these legacy keys and runs through TerminalFixtureTests.

### 50. Dead helpers in the shared grid-assertion file

**Status:** `done` -- both dead helpers deleted after rg confirmed zero readers across lib/ and app/

`lib/TerminalCore/Tests/TerminalCoreTests/TerminalGridAssertions.swift:6` -- high confidence, trivial effort, found by `tests-behavior-a`

**Problem.** The `expectValidGrid(_ geometry: TerminalGeometry, context:sourceLocation:)` overload (lines 6-19) has no caller: `TerminalGeometry` appears nowhere in the TerminalCoreTests target except this signature, every one of the ~150 `expectValidGrid(...)` call sites passes a `Terminal`, and the `Terminal` overload reaches `expectValidRow` directly rather than through it. `RecordCharge.hyperlinkEntry` (line 326) is likewise never read -- `TerminalScrollbackBudgetTests.costModelUsesPinnedLiterals` uses only `header`, `cell`, `identityRun`, and `identityCell`. Neither is referenced from `lib/TerminalPTY` or `app/`.

**Recommendation.** Delete the `TerminalGeometry` overload of `expectValidGrid` and the `RecordCharge.hyperlinkEntry` constant; `expectValidRow` stays live via `expectValidStream`.

**Verifier (confirmed).** Both claims check out. All 172 `expectValidGrid(` call sites in lib/ and app/ pass a `Terminal` (including `expectValidGrid(try replay(...))`, where `replay` is declared `throws -> Terminal`); `TerminalGeometry` appears in the whole TerminalCoreTests target only in the dead overload's own signature, and the file is compiled into that one test target only (Package.swift gives each test target its own path). `RecordCharge.hyperlinkEntry` has zero readers -- `costModelUsesPinnedLiterals` uses `header`, `cell`, `identityRun`, `identityCell`, and `historyLineCost` uses the first three. `expectValidRow` stays live through `expectValidStream`. Minor judgment note only: `RecordCharge`'s doc says it deliberately mirrors `LogicalLineRecord`, so dropping one member leaves an incomplete mirror -- worth a one-line rationale in the commit, but it is genuinely dead.

### 51. regionalIndicatorParity is duplicated by regionalIndicatorGeometry

**Status:** `done` -- deleted; regionalIndicatorGeometry is a strict superset

`lib/TerminalCore/Tests/TerminalCoreTests/TerminalGraphemeTests.swift:28` -- high confidence, trivial effort, found by `tests-behavior-b`

**Problem.** `TerminalGraphemeTests.regionalIndicatorParity` builds `Terminal(columns: 7, rows: 1)`, feeds `U+1F1E6 U+1F1E7 U+1F1E8`, and asserts `cell(0,0).scalars == [RI-A, RI-B]` and `cell(0,2).scalars == [RI-C]`. `TerminalGraphemeWidthTests.regionalIndicatorGeometry` (TerminalGraphemeWidthTests.swift:124) constructs the identical terminal, feeds the identical bytes, and makes those same two assertions plus the cell-kind vector, the cursor position, and `expectValidGrid`. The parity test is a strict subset with no assertion of its own.

**Recommendation.** Delete `regionalIndicatorParity`; `TerminalGraphemeWidthTests.regionalIndicatorGeometry` keeps the RI-parity coverage (fold its `"a third Regional Indicator starts a new cluster"` phrasing into that test's title if the intent should stay visible).

**Verifier (confirmed).** Read both: TerminalGraphemeWidthTests.swift#regionalIndicatorGeometry builds the same Terminal(columns: 7, rows: 1), feeds the same three RI scalars, and makes the same two scalar assertions plus cell kinds, cursor, and expectValidGrid. Same test target, so no gate wiring depends on the suite split, and TerminalGraphemeTests still keeps RI break coverage via softWrapResetsLookBehind. Folding the "a third Regional Indicator starts a new cluster" phrasing into the surviving title is worth doing, since that segmentation intent is the only thing the deleted test carried.

### 52. cursorLayerOverridesAndInvisibility is two-thirds duplicated by cursorShapes

**Status:** `done` -- reduced to its unique SGR-8 section and renamed hiddenCellUnderBlockCursor

`lib/TerminalCore/Tests/TerminalRenderPlanningTests/RenderFramePlanningTests.swift:332` -- high confidence, small effort, found by `tests-render`

**Problem.** `cursorLayerOverridesAndInvisibility` and `cursorShapes` build the identical terminal (`Terminal(columns: 3, rows: 1)` fed `\u{1B}[31;44;4mA\u{1B}[1;1H`). The visible-block section (lines 340-347: background == cursor, text foreground == cursorText, decoration color == cursorText) is asserted verbatim by `cursorShapes` lines 411-420, which additionally checks `block.cursor`. The invisible section (lines 349-363: cursor nil, background == ansi[4], text == ansi[1], decoration == ansi[1]) is asserted by the `cursorShapes` hidden loop at lines 431-444 for all three shapes, not just block. Only the SGR-8 hidden-text section (lines 365-378) is unique coverage.

**Recommendation.** Delete lines 333-363 of `cursorLayerOverridesAndInvisibility`, keeping only the `hiddenTerminal` section, and rename the test to describe what survives (a hidden cell under a visible block cursor still plans the cursor background but no text or decoration runs); `cursorShapes` keeps the removed coverage.

**Verifier (confirmed).** Line numbers and inputs check out: both tests build Terminal(columns: 3, rows: 1) fed "\u{1B}[31;44;4mA\u{1B}[1;1H". cursorShapes:411-420 asserts the same three visible-block values (via `first?.color ==`, which also fails on a nil run, so no coverage is lost by dropping the `#require`s) plus the full block.cursor; cursorShapes:431-444 asserts cursor == nil and the same three ANSI colors for all three shapes including .block. Only the SGR-8 section is unique. One mechanical adjustment: deleting 333-363 also removes the `presentation` constant at 335-339, which the surviving hidden section uses at line 367 -- keep it (or inline it) or the file will not compile.

### 53. multipleFeedRepresentationsAreRejected duplicates a case of invalidEventFieldsAreRejected

**Status:** `done` -- duplicate deleted; the case in invalidEventFieldsAreRejected keeps the coverage

`lib/TerminalCore/Tests/TerminalCoreTests/NeutralTerminalRecordingTests.swift:40` -- high confidence, trivial effort, found by `tests-behavior-b`

**Problem.** `multipleFeedRepresentationsAreRejected` is a parameterized test with exactly one argument, `{"type":"feed","base64":"AQ==","text":"x"}`, asserting `throws: NeutralTerminalRecordingError.self`. `invalidEventFieldsAreRejected` (line 65) already includes `{"type":"feed","base64":"YQ==","text":"a"}` with the identical assertion; both hit the same `encodings.count == 1` guard in `NeutralTerminalRecordingEvent.init(from:)` and differ only in the base64/text payload strings, which the guard never inspects.

**Recommendation.** Delete `multipleFeedRepresentationsAreRejected`; the `base64`+`text` case inside `invalidEventFieldsAreRejected` keeps the coverage.

**Verifier (confirmed).** Both JSON strings produce keys {type, base64, text}, hit the same `encodings.count == 1` guard in NeutralTerminalRecordingEvent.init(from:), and assert the same `throws: NeutralTerminalRecordingError.self`; only the payload strings differ and the guard never inspects them. The surviving test's title already advertises "duplicate" fields, so the intent stays documented. feedHexIsRejected and the missing-field case remain untouched.

### 54. cursorPlanning's wide head/tail cases are subsumed by cursorShapeWideCellSnapping

**Status:** `done` -- wideHead/wideTail blocks deleted, test retitled, pointer left to cursorShapeWideCellSnapping

`lib/TerminalCore/Tests/TerminalRenderPlanningTests/RenderFramePlanningTests.swift:280` -- high confidence, trivial effort, found by `tests-render`

**Problem.** `cursorPlanning` lines 280-296 plan `"\u{754C}\u{1B}[1;1H"` and `"\u{754C}\u{1B}[1;2H"` at columns 3 (via `plannedCursor`, which uses rows 1, visible cursor, `.block`) and assert the cursor snaps to `RenderCursor(row: 0, column: 0, columnWidth: 2, shape: .block, color: .cursor)`. `cursorShapeWideCellSnapping` (lines 447-482) runs exactly those two inputs at the same geometry for `[.block, .underline, .bar]` and asserts the same `RenderCursor`, so the block case is a strict subset.

**Recommendation.** Delete the `wideHead` and `wideTail` blocks (lines 280-296) from `cursorPlanning`, leaving it to cover the narrow, pending-wrap, and styled-wide-override cases; `cursorShapeWideCellSnapping` keeps the snapping coverage.

**Verifier (confirmed).** Verified plannedCursor(after:columns:) builds Terminal(columns:, rows: 1) with presentation (theme .dark, visible, .block) -- identical to what cursorShapeWideCellSnapping constructs for shape == .block with the same two inputs and columns: 3, and both assert RenderCursor(row: 0, column: 0, columnWidth: 2, shape: .block, color: .cursor). Strict subset, so the deletion loses nothing; no later line in cursorPlanning references wideHead/wideTail. Minor follow-on: the @Test title still claims 'snapping', which after the deletion is covered only by cursorShapeWideCellSnapping -- retitle it.

### 55. characterizationNonBase64FeedsAreRejected tests a decoder that exists only in the test file

**Status:** `done` -- deleted; the policy stays enforced by replayCharacterizationCorpus and the schema-audit gate step

`lib/TerminalCore/Tests/TerminalCoreTests/GhosttyInspectionRecoveryReplayTests.swift:9` -- high confidence, trivial effort, found by `tests-behavior-b`

**Problem.** The three parameterized JSON cases are decoded into `ReplayEvent`, a `private enum` declared at line 170 of this same test file with a hand-written `init(from:)` whose `guard values.contains(.hex) == false, values.contains(.text) == false` is exactly what the test asserts. There is no production type behind it -- the schema is bespoke to `Fixtures/ghostty/inspection-recovery.json` -- so no source change in lib/TerminalCore can make this test fail. The corpus itself is already required to parse by `replayCharacterizationCorpus` (line 26), which would fail loudly if the fixture ever grew a hex or text feed.

**Recommendation.** Delete `characterizationNonBase64FeedsAreRejected`; `replayCharacterizationCorpus` still fails if the checked-in corpus stops being base64-only.

**Verifier (confirmed).** ReplayEvent is private to GhosttyInspectionRecoveryReplayTests.swift with a hand-written init(from:), the schema is bespoke to Fixtures/ghostty/inspection-recovery.json, and no TerminalCore source change can fail these three cases. The recommendation is safe because the policy has two other enforcers: the retained guard still makes replayCharacterizationCorpus fail loudly on a hex/text/duplicate feed, and scripts/terminal-recording-schema-audit.py -- a `just test` gate step -- audits ghostty['replay']['events'] with the same "exactly one of base64 or text" rule. That external gate is what makes this different from finding 6, where the guarded policy has no other enforcer.

### Downgraded (test pruning)

Real problems, but apply the verifier's adjustment.

### 56. phase2LibvtermReplay re-runs fixtures replayFixtures already covers

**Status:** `done` -- verifier's adjustment: replaced with libvtermFixtureInventory pinning 51 recordings, so a silently deleted fixture still fails

`lib/TerminalCore/Tests/TerminalCoreTests/TerminalFixtureTests.swift:22` -- high confidence, trivial effort, found by `tests-behavior-b`

**Problem.** `phase2LibvtermReplay` replays the 8 names in `Self.phase2LibvtermRecordings` (state-mouse-idempotent-1002, vttest-movement-2..4, vttest-screen-1..4) through `replayFixture(at:)`. All 8 files live in `Fixtures/libvterm/` (verified by `ls`), and `replayFixtures` (line 10) enumerates that whole directory via `fixtureURLs()` and filters out only `Self.milestone8AlacrittyRecordings` -- which contains none of those 8 names. So both tests call the identical `replayFixture(at:)` on the identical URLs, and `replayFixture` is the expensive path: authored + bytewise + every `splitStrategies` chunking (quartile splits for the 2-6 KB vttest feeds). The whole TerminalCore package is one `just test` gate step (scripts/run-test-suite.sh:22), so no gate wiring depends on the separate test name.

**Recommendation.** Delete `phase2LibvtermReplay` and the now-unused `phase2LibvtermRecordings` constant; `replayFixtures` keeps the coverage. (Keep `milestone8ApplicationReplay` -- those 5 names *are* filtered out of `replayFixtures`, so it is not redundant.)

**Verifier (adjustment required).** Factually right: all 8 names exist in Tests/TerminalCoreTests/Fixtures/libvterm/, fixtureURLs() enumerates that whole directory, and milestone8AlacrittyRecordings (the only filter) holds alacritty names only, so replayFixture(at:) runs identically twice; the constant is referenced nowhere outside this file (worktree copies aside). One coverage difference the finding misses: phase2LibvtermReplay resolves each name through Bundle.module.url(forResource:), so it is the only thing pinning that those 8 recordings still EXIST by name. replayFixtures just enumerates whatever is on disk, libvtermManifestCoverage only pins manifest case names (the fixture path lives in a prose rationale), and the repo clearly cares about this class of check -- alacrittyManifestCoverage asserts fixtureNames == adopted. Adjustment: delete the duplicate replay, but add a cheap libvterm inventory assertion (a name-set #expect, mirroring the alacritty one) so a silently deleted vttest/state-mouse fixture still fails.

### 57. adjacentTwelfthsShareEllipse asserts only constants it computed itself

**Status:** `done` -- real geometry assertion (ink in every column of the joined 24-column arc, monotone); the finding's proposed edge assertions were probed and do not hold, as the verifier suspected

`lib/TerminalCore/Tests/TerminalSpriteGeometryTests/LegacyComputingSupplementSpriteGeometryTests.swift:102` -- high confidence, small effort, found by `tests-render`

**Problem.** The test body constructs two `LegacySupplementCirclePiece` values, then computes `leftGlobalCenter = -left.xCells * cellWidth` (= -0*8 = 0) and `nextGlobalCenter = cellWidth - next.xCells * cellWidth` (= 8 - 1*8 = 0) and expects them equal. It never calls `LegacyComputingSupplementSpriteGeometry.rects` or any other production geometry -- it only reads back stored properties the test set. The expectation is `0 == 0` and cannot fail under any change to the supplement geometry, despite the title claiming it proves adjacent twelfths share a translated ellipse center.

**Recommendation.** Replace the body with one that calls `LegacyComputingSupplementSpriteGeometry.rects(pattern: .circlePieces([piece]), ...)` for the two adjacent pieces at a fixed cell size and asserts the two cells' arc runs meet at the shared boundary column (left cell has a run touching `x + width == cellWidth`, right cell one touching `x == 0`, at matching `y` rows); delete the test if that duplicates `arcCornerEdgeIntersections`.

**Verifier (adjustment required).** The vacuity claim is exactly right (-0*8 == 8-1*8, i.e. 0 == 0; no production call), but the proposed replacement assertion does not hold. I simulated LegacyComputingSupplementSpriteGeometry.circlePiece/ellipseOutline for the two pieces at 12x16, thickness 2: the left piece (xCells 0, 2x2, .topLeft) has NO pixel within tolerance of the arc, so it falls through to the `if result.isEmpty` nearest-pixel fallback and yields a single rect at (11,15); the right piece (xCells 1) yields a blob whose minimum x is 7, so `rects.contains { $0.x == 0 }` fails. Adjustment: before writing the replacement, settle the construction -- Ghostty's circlePiece puts the ellipse centre at cell-local (radiusX - xOffset, radiusY - yOffset) for every corner (.ghostty-src/src/font/sprite/draw/symbols_for_legacy_computing_supplement.zig#circlePiece), while DanTerm's .topLeft uses (-xOffset, -yOffset) with the opposite visible quadrant, which renders the four quarter-circle scalars as a four-petal shape rather than a circle. Write the new test against the intended arc (a continuity/edge assertion that actually holds), or file the geometry divergence first.

### 58. rawLiveCaptureIsNotFixtureAdmissible only re-pins a constant another test already asserts

**Status:** `done` -- verifier's adjustment: KEPT and retitled; it is the only can-fire proof of the admission guard (recordingCorpus passes vacuously)

`lib/TerminalCore/Tests/TerminalCoreTests/TerminalSemanticPromptInvariantTests.swift:49` -- high confidence, trivial effort, found by `tests-behavior-b`

**Problem.** The test asserts that `admitDanTermRecordingFixture(.liveCapture())` throws. `admitDanTermRecordingFixture` is a `private func` declared at the bottom of this same test file (line 201) whose entire body is `guard provenance.source != "danterm-live-capture"`. The only production fact it can catch is a change to `NeutralTerminalProvenance.liveCapture().source` -- and `NeutralTerminalRecordingTests.liveCaptureProvenanceValidates` (NeutralTerminalRecordingTests.swift:100) already asserts `provenance.source == "danterm-live-capture"` directly, plus that it validates and differs from `.danTerm(test:)`. So this test only re-checks test-local code.

**Recommendation.** Delete `rawLiveCaptureIsNotFixtureAdmissible` (keep `admitDanTermRecordingFixture`, which `recordingCorpus` still calls); `NeutralTerminalRecordingTests.liveCaptureProvenanceValidates` keeps the production coverage.

**Verifier (adjustment required).** The mechanics are as described (admitDanTermRecordingFixture is private to the file, its body is one source-string guard, and liveCaptureProvenanceValidates pins provenance.source == "danterm-live-capture"), but the finding undersells what deleting it costs. This is the only can-fire proof that the corpus admission guard is not vacuous: recordingCorpus passes whether or not the guard fires, because no committed fixture is a live capture, so an inverted or deleted guard would be silent. Unlike the Ghostty case (finding 9), nothing else in the gate enforces "no raw live capture in Fixtures/danterm" -- and the live-capture pipeline is real (scripts/terminal-tape-to-fixture.py, PaneTapeFollow). Adjustment: keep the test (it costs microseconds) unless the guard itself is being removed; at most retitle it to say it pins the admission guard rather than provenance.

### 59. tabStopsAndPadding is subsumed by tabStopDispatch

**Status:** `done` -- verifier's adjustment: trimmed, not deleted; the defaults-present clamp is genuinely unique

`lib/TerminalCore/Tests/TerminalCoreTests/TerminalTests.swift:193` -- medium confidence, trivial effort, found by `tests-behavior-a`

**Problem.** `TerminalTests.tabStopsAndPadding` builds a 12x1 terminal and asserts HT lands on the default stop at column 8, that a second HT clamps to column 11, and that the row stays all-padding. `TerminalTabStopTests.tabStopDispatch` uses the same 12x1 geometry and asserts all three: the default stop at 8 (after `\u{1B}[g` clears the custom stop), the clamp to column 11, and the identical `allSatisfy { $0.kind == .padding }`. `TerminalTests.groundControlMatrix` (line 111) additionally covers HT reaching column 8. Nothing in `tabStopsAndPadding` is unique.

**Recommendation.** Delete `TerminalTests.tabStopsAndPadding`; `TerminalTabStopTests.tabStopDispatch` keeps the default-stop, clamp, and padding coverage.

**Verifier (adjustment required).** Not fully subsumed. `tabStopDispatch` reaches column 11 only after `ESC[3g` has cleared *every* stop, whereas `tabStopsAndPadding` clamps with the default stop set intact and the cursor sitting past the last default stop (12 columns -> stops {0,8}). Those are the same expression today (`tabStops.filter { $0 > cursor.column }.min() ?? columnCount - 1`), but that is a structure-sensitive argument: an implementation that keeps the Set only for custom stops and computes the default case arithmetically -- a plausible optimization, since the filter runs per HT -- would return 16 for the defaults-present case and still pass the empty-set case. The default-stop-at-8 and all-padding halves genuinely are duplicated (`tabStopDispatch` line 24/30, plus `groundControlMatrix`). Adjustment: if the test is deleted, first add the defaults-present clamp to `tabStopDispatch` (fresh 12x1 terminal, two HTs -> column 11); moving `tabStopsAndPadding` into TerminalTabStopTests instead is the cheaper equivalent.

### 60. synchronizedOutputAccumulatesDamage largely duplicates presentationProjectionAndSynchronizedGating

**Status:** `done` -- duplicate deleted, survivor now asserts frame damage and carries the pruned test's rationale

`lib/TerminalPTY/Tests/TerminalPaneSessionTests/TerminalPaneSessionControllerTests.swift:797` -- medium confidence, small effort, found by `tests-pty-probes`

**Problem.** `synchronizedOutputAccumulatesDamage` (797) and `presentationProjectionAndSynchronizedGating` (832) drive the identical scenario: same `probe sync` child, same `first` / `second` / `commit` round trips, same `__SYNC_A__` / `__SYNC_B__` / `__SYNC_DONE__` waits, same "no frame during synchronization, exactly one after commit" count assertions. The survivor additionally asserts `host.fencedSnapshot().presentation.isSynchronizedOutputActive` at both suppressed steps, that reads stay current during suppression, and — strictly stronger than the duplicate's damage check — that `plans.last` equals a from-scratch `planFrame` of the final terminal, which stale or dropped damage would break through row reuse. The only assertion the survivor does not make literally is `frames.last?.damage != TerminalDamage.none`. Each test costs a real PTY plus three round trips in a `.serialized` suite.

**Recommendation.** Delete `synchronizedOutputAccumulatesDamage` after adding its one unique assertion — collect `$0.damage` alongside `$0.plan` in `presentationProjectionAndSynchronizedGating`'s `onFrame` and assert the post-commit frame's damage is not `.none`.

**Verifier (adjustment required).** The overlap is real: both drive the same `probe sync` child through first/second/commit with the same __SYNC_A__/__SYNC_B__/__SYNC_DONE__ waits, and the survivor is strictly stronger on suppression -- it asserts plans.count stays at baseline through both suppressed steps, which the pruned test never does (it only snapshots the count), plus isSynchronizedOutputActive, live reads, and full plan equality against a from-scratch planFrame. So the finding's own description slightly understates the survivor. But `frames.last?.damage != .none` is not subsumed by plan equality: the plan and the TerminalPaneFrame.damage field are two different observables, and damage is what a consumer uses to invalidate. Adjustments needed before deleting: carry the pruned test's 'Why it exists' rationale (draining on each owner read can discard damage before the session may publish) into the survivor's preamble, and retitle the survivor so the damage claim is not an orphaned one-liner under a title about cursor visibility and planning gates -- AGENTS.md's preamble convention expects the guarded risk to be stated. With those, the merge is safe; without them the regression this test names loses its attribution.

## 4. Test improvements

Assertions too weak to catch the regression the test names, missing calibration gates, fixture duplication, and slow/flaky patterns.

### 61. REP equality test passes on an unrelated field

**Status:** `done` -- both terminals now differ in lastPrintedCluster alone; confirmed by feeding identical bytes and watching equality hold

`lib/TerminalCore/Tests/TerminalCoreTests/TerminalRepeatTests.swift:102` -- high confidence, trivial effort, found by `tests-behavior-a`

**Problem.** `memoryAffectsEquality` claims "last-cluster memory participates in terminal equality", but the two terminals it compares also differ in `Terminal.nextContentIdentity`. `Terminal` uses synthesized `Equatable` over all stored properties (Terminal.swift:61, :652); `allocateContentIdentity` bumps the counter on every printed cell (Terminal.swift:6077) and only `hardReset` resets it (Terminal.swift:5807) -- `eraseCells` does not. So `remembered` (fed `A` then `CSI 2 J`) holds `nextContentIdentity == 2` while `plain` (only `moveCursor`) holds `1`. The `!=` would still hold if `lastPrintedCluster` were deleted from the type outright, so the test cannot fail for the reason its name promises.

**Recommendation.** Make the cluster memory the only difference: build the second terminal with `plain.feed(Array("B\u{1B}[2J".utf8))` instead of `plain.moveCursor(row: 0, column: 1)`. Both then have identical grids (all `GridCell(styleId:)` padding), identical cursors at (0,1), and identical `nextContentIdentity == 2`, leaving `lastPrintedCluster` ("A" vs "B") as the sole differing field.

**Verifier (confirmed).** Checked Terminal.swift: `Terminal` has no custom `==` (the four `static func ==` are on nested ObservationGeneration/etc.), so equality is synthesized over all stored properties including `nextContentIdentity` and `damage`. `allocateContentIdentity` bumps on every printNarrow/printWide and only `hardReset` resets it (ED 2 does not), so `remembered` holds 2 and `plain` holds 1; `damage` also differs (print records row 0, `moveCursor` records nothing). The test would therefore still pass with `lastPrintedCluster` deleted. The proposed fix is sound: ED 2 (`eraseDisplay` case 2) calls `clearPendingMotionState()`, so both terminals end with `clusterContext == nil`, `isPendingWrap == false`, cursor (0,1), identical erased grids, identical damage and identical `nextContentIdentity == 2`, leaving `lastPrintedCluster` ("A" vs "B") as the sole difference.

### 62. Powerline mirror test uses the production mirror as its own oracle

**Status:** `done` -- test-local oracle replaces the production mirror as its own reference

`lib/TerminalCore/Tests/TerminalSpriteGeometryTests/PowerlineSpriteGeometryTests.swift:93` -- high confidence, small effort, found by `tests-render`

**Problem.** `horizontalMirrors` asserts `rhs == lhs.mirroredHorizontally(cellWidthPixels: 7)`, but `PowerlineSpriteGeometry.geometry` computes 7 of the 9 listed right-hand patterns by literally calling that same internal `PowerlinePixelGeometry.mirroredHorizontally`: `.leftHard`, `.leftThin`, `.leftHardRounded`, `.leftThinRounded`, `.lowerRightHardDiagonal`, `.upperLeftHardDiagonal`, and `.rightCap` are all `geometry(<counterpart>).mirroredHorizontally(width)` (PowerlineSpriteGeometry.swift:92-161). For those seven pairs the expectation restates the implementation and cannot fail; only the two thin-diagonal pairs, which are built independently, are real checks. A bug in `mirroredHorizontally` itself -- e.g. also mirroring `y`, or dropping a cubic control point -- would leave every one of these assertions green.

**Recommendation.** Stop calling the production `mirroredHorizontally` in the test: define a test-local mirror helper over `[PowerlinePixelPathCommand]` that maps `x -> Double(width) - x` and leaves `y` and `style` alone, and assert `rhs.paths == testMirror(lhs.paths, width: 7)`.

**Verifier (confirmed).** Verified: PowerlineSpriteGeometry.geometry has exactly 7 `.mirroredHorizontally(cellWidthPixels:)` self-delegations (lines 96, 107, 117, 122, 132, 142, 161) and they are precisely .leftHard, .leftThin, .leftHardRounded, .leftThinRounded, .lowerRightHardDiagonal, .upperLeftHardDiagonal, .rightCap -- the 7 right-hand entries of the test's 9 pairs. Recursion passes the already-clamped stroke, so at 7x15/light 1 the two sides are the identical expression: a bug inside PowerlinePixelPathCommand.mirroredHorizontally (mirroring y, dropping a control point) changes both sides and stays green. Nothing else pins a left-form's coordinates: canonicalGeometry only pins .rightHard/.rightHardRounded, and PowerlineSpriteExecutionTests only assert ink-present/neighbour-clean. A test-local mirror over [PowerlinePixelPathCommand] is a legitimate independent oracle and is test-only. Equally acceptable alternative: extend canonicalGeometry with exact left-form coordinates.

### 63. Occupancy saturation test cannot detect an unsaturated corpus

**Status:** `done` -- now builds at the probe binary's shipped 179x66 / 30k lines and asserts eviction actually happened

`lib/TerminalCore/Tests/TerminalOccupancyProbeSupportTests/OccupancyCorpusTests.swift:59` -- high confidence, small effort, found by `tests-pty-probes`

**Problem.** `saturationReachesDepth` says it guards the premise that "the probe's headline numbers are all 'at a saturated history'" and that "if the feed were too short, every case would report the shallow-history cost under a saturated label". Its only depth assertion is `terminal.scrollbackRowCount > 0`, which is satisfied by any feed longer than one screen (rows: 24, so ~25 lines). It also builds the terminal at `lines: 4_000`, while the probe binary `Sources/TerminalOccupancyProbe/main.swift` ships `--lines` defaulting to 30_000. `occupancyCorpusLine` averages ~105 bytes/line, so 4_000 lines is ~0.4 MB against `Terminal.productionScrollbackBudgetBytes` = 16_777_216 — nothing can have evicted, so the test proves the opposite of what it claims. (`makeOccupancyTerminal`'s own doc comment still says "10 MiB budget", which is stale too.)

**Recommendation.** Build at the probe binary's shipped depth and assert eviction actually ran — `let terminal = makeOccupancyTerminal(columns: 179, rows: 66, lines: 30_000)` with `#expect(terminal.scrollbackRowCount < 30_000)` — the same ceiling check `TerminalResizeProbeSupportTests.saturatingRecipeReachesTheBudgetCeiling` uses; a failure there is exactly the "corpus stopped saturating" condition the preamble says must be caught.

**Verifier (confirmed).** Verified: Terminal.productionScrollbackBudgetBytes = 16_777_216 (Terminal.swift#productionScrollbackBudgetBytes), the store reserves budget/16 so the arena is 15,728,640 B, and a corpus record costs Header.byteCount (8) + ~105 cells x cellBytes (8) ~= 856 B, so 4,000 lines charge ~3.4 MB -- nothing evicts, and `scrollbackRowCount > 0` is satisfied by any feed past one screen. One arithmetic correction to the finding: the ~0.4 MB figure counts raw text bytes, not charged bytes; the real charge is ~3.4 MB, which still leaves the conclusion intact (and makes it slightly less lopsided). The recommendation is sound and has precedent: TerminalResizeProbeSupportTests already builds 120,000- and 250,000-line saturated terminals in unit tests, so 30,000 lines at 179x66 is well inside the existing cost envelope, and it charges ~26 MB against a 15.7 MB arena so eviction is comfortably real (~18,200 rows retained, far under 30,000). The stale "10 MiB budget" doc comment on makeOccupancyTerminal is genuinely wrong and should be fixed in the same edit.

### 64. Consumer-work generation never checked for staying put

**Status:** `done` -- inert-dispatch and re-damage legs added; the second leg had been passing incidentally off an already-damaged row

`lib/TerminalCore/Tests/TerminalCoreTests/TerminalDamageTests.swift:20` -- high confidence, small effort, found by `tests-behavior-a`

**Problem.** `consumerWorkGenerationCategoriesAndRearming` only ever asserts `pendingConsumerWorkGeneration != generation`. It never asserts the token stays unchanged when a feed adds no new pending work -- yet that is the whole contract: `TerminalPTYHost.swift:1644` gates consumer work on this token, and `recordPresentationDamage` deliberately bumps only when `damage.record(row:)`/`recordFull()` returns true (Terminal.swift:963-973, TerminalDamage.swift `TerminalDamageAccumulator.record(row:)` returns false for an already-set bit). A regression that bumped the generation on every `feed` call would restore a wakeup per read and pass every assertion in this test.

**Recommendation.** Add a negative leg to the test: after a drain, feed the already-pinned inert dispatch `\u{1B}[9z` (see `CSIParserTests.uninterpretedDispatchIsNoOp`) and `#expect(terminal.pendingConsumerWorkGeneration == generation)`; then print into an already-damaged row without draining and assert the generation is still unchanged.

**Verifier (confirmed).** Verified the mechanism: `recordPresentationDamage(row:)`/`recordFull()` bump only when `TerminalDamageAccumulator.record` returns true (Terminal.swift `recordPresentationFullDamage`/`recordPresentationDamage`), and TerminalPTYHost `applyOutput` wakes on `hasPendingConsumerWork && (consumerWorkWasSignaled == false || generation != previous)`. Nothing anywhere asserts the token stays put -- and, importantly, the existing `terminal == expected` no-op tests cannot cover it because `PendingConsumerWork.generation` is an `ObservationGeneration` whose `==` returns `true` unconditionally, so the generation is deliberately outside value equality. Both proposed legs hold against the current code: an unrecognized CSI final ('z') falls through `dispatchCSI`'s `default: break` and the snapshot diff records no damage; a second print into an already-set row bit returns false from `record(row:)`. Only caveat for the author: keep the second print inside the same row so it cannot scroll (which would escalate to full damage and legitimately bump).

### 65. PTY executable-locating and marker helpers duplicated verbatim across three test files

**Status:** `done` -- helpers moved into TerminalPTYTestSupport; all three verbatim copies deleted

`lib/TerminalPTY/Tests/TerminalPaneSessionTests/TerminalPaneSessionControllerTests.swift:1901` -- high confidence, small effort, found by `tests-pty-probes`

**Problem.** `printMarker` (with its 8-line doc comment), `builtExecutable`, `bootstrapExecutable`, and `probeExecutable` are byte-identical between `TerminalPaneSessionControllerTests.swift:1827-1837,1901-1921` and `TerminalPTYHostTests.swift:2041-2051,2166-2186` (verified with `diff`). `TerminalPTYExternalTests.swift:111-123` holds the same `builtExecutable` body renamed to `externalBuiltExecutable` — in the *same* target as `TerminalPTYHostTests` — and `shellQuote` is identical between `TerminalPTYExternalTests.swift:125` and `TerminalPaneSessionControllerTests.swift:1897`. The package already has a shared `TerminalPTYTestSupport` target that both `TerminalPTYHostTests` and `TerminalPaneSessionTests` depend on (Package.swift:120, 133).

**Recommendation.** Move `printMarker`, `builtExecutable`/`bootstrapExecutable`/`probeExecutable`, and `shellQuote` into `TestSupport/TerminalPTYTestSupport` as `public` helpers and delete the three copies; the `#filePath`-relative walk still resolves to `lib/TerminalPTY` from that directory (also three `deletingLastPathComponent()` levels up).

**Verifier (confirmed).** Diffed the cited ranges: printMarker (1827-1837 vs 2041-2051) and the builtExecutable/bootstrapExecutable/probeExecutable block (1901-1921 vs 2166-2186) are byte-identical. TerminalPTYExternalTests.swift#externalBuiltExecutable is the same body renamed, in the same test target as TerminalPTYHostTests, and shellQuote matches too. TerminalPTYTestSupport exists at TestSupport/TerminalPTYTestSupport, both suites depend on it (Package.swift), and it already imports Testing unconditionally, so `#require` in a moved helper compiles and works (the calls still run inside a test's task-local context). The #filePath walk is also three levels from TestSupport/TerminalPTYTestSupport/<file> to lib/TerminalPTY, so the path math holds. Two small consequences to expect: #require failures will report the support file's source location rather than the caller's (pass a SourceLocation parameter if that matters), and the new file needs an AGENTS.md-style header block.

### 66. Attribution probe reports green instead of skipped when disabled

**Status:** `done` -- all three attribution tests carry .enabled(if:); a disabled run now reports skipped, not green

`lib/TerminalCore/Tests/TerminalCoreTests/TerminalWiredHistoryAttributionProbe.swift:131` -- high confidence, trivial effort, found by `tests-storage`

**Problem.** `drainAttribution` (line 131), `browseAttribution` (line 163) and `equalityAttribution` (line 206) each open with `guard Self.probeIsEnabled else { return }`, so all three report as PASSED in `just test` while measuring nothing. Every other probe in this cluster gates with the trait instead -- `TerminalLogicalLineReadProbe`, `TerminalLogicalLineIndexProbe`, `TerminalLogicalLineBlankIndexProbe`, `TerminalLogicalLineWideIndexProbe`, `TerminalLogicalLineEvictionProbe` and `TerminalLogicalLinePathologicalProbe` all use `.enabled(if: probeIsEnabled)` and therefore show as skipped. The file's own header cites `agent-docs/measurement-discipline.md`, whose first rule this violates: an instrument that cannot say "not measured" is indistinguishable from one that measured and found nothing.

**Recommendation.** Replace the three `guard Self.probeIsEnabled else { return }` bodies with an `.enabled(if: probeIsEnabled)` trait on each `@Test`, matching the other six probe suites.

**Verifier (confirmed).** Confirmed all three tests (TerminalWiredHistoryAttributionProbe.swift:130/162/205) open with `guard Self.probeIsEnabled else { return }` and carry no trait, while TerminalLogicalLineReadProbe, IndexProbe, BlankIndexProbe, WideIndexProbe, EvictionProbe, PathologicalProbe and AdmissionProbe all spell `.enabled(if: probeIsEnabled)`. agent-docs/measurement-discipline.md line 10 states the rule verbatim ('Every metric must be able to say "not measured" separately from "measured zero"'), and the file's own header already claims the measurements are skipped. The pattern transfers directly: `probeIsEnabled` is a `static let` on the suite struct, exactly as in TerminalLogicalLineIndexProbe where the unqualified name already resolves inside the trait argument.

### 67. Style-table bound is 20,000x looser than the behavior

**Status:** `done` -- both bounds expressed against baseStyleSweepThreshold; real values are 111 and 444 against the old 19,999/1,999 tolerances

`lib/TerminalCore/Tests/TerminalCoreTests/TerminalStyleTableTests.swift:63` -- high confidence, trivial effort, found by `tests-behavior-a`

**Problem.** `stylesSurviveTableChurn` states its intent as "the table does not grow with the number of styles seen", but asserts only `terminal.retainedStyleCount < styleCount` with `styleCount == 20_000` -- a table holding 19,999 entries passes. `internStyle` sweeps whenever `styleTable.count >= styleSweepThreshold` before minting (Terminal.swift:1033) and `reclaimDeadStyleEntries` resets the threshold to `max(baseStyleSweepThreshold, survivors * 2)` (Terminal.swift:1085); with ~3 live styles here the threshold never leaves `Terminal.baseStyleSweepThreshold` (512), so the real bound is two orders of magnitude tighter than what is asserted. `evictedStylesAreReclaimed` (line 92) has the same problem with `< styleCount / 2`.

**Recommendation.** Replace both bounds with `#expect(terminal.retainedStyleCount <= Terminal.baseStyleSweepThreshold)`, which is the bound `internStyle` actually enforces and survives a change to the constant.

**Verifier (confirmed).** `internStyle` sweeps at `styleTable.count >= styleSweepThreshold` and `reclaimDeadStyleEntries` resets it to `max(baseStyleSweepThreshold, survivors * 2)` with `baseStyleSweepThreshold = 512`. In `stylesSurviveTableChurn` the live set is ~3 (default + pinned column 0 + current column 1) and in `evictedStylesAreReclaimed` it is a handful (two retained history rows plus the 2x4 live grid), so the threshold never leaves 512 in either test and `retainedStyleCount` can peak at exactly 512. `<= Terminal.baseStyleSweepThreshold` therefore holds today and is the real bound. Both `baseStyleSweepThreshold` (internal `static let`) and `retainedStyleCount` (internal) are reachable under `@testable`. The only cost is that a future change to the *sweep policy* (not the constant) would trip it -- which is the point of the tighter bound.

### 68. TerminalShellDialectTests re-implements the neutral recording decoder, with a dead hex path

**Status:** `done` -- decodes NeutralTerminalRecording directly; kept decode-only per the verifier, since provenance validation would reject three fixtures

`lib/TerminalCore/Tests/TerminalCoreTests/TerminalShellDialectTests.swift:18` -- high confidence, small effort, found by `tests-behavior-b`

**Problem.** The suite declares a private `Recording`/`Recording.Event` Decodable pair plus `bytes(fromHex:)` and `bytes(from:)` to load the very files that `NeutralTerminalRecording` (from `TerminalCoreRecording`, already a declared dependency of this test target) decodes. Sibling suites prove it: `TerminalPromptAnchorResizeSweepTests.loadPromptAnchorSweepFixture` decodes `zsh/bash/fish-dialect-width-sweep` as `NeutralTerminalRecording`, and `TerminalSemanticPromptInvariantTests.recordingCorpus` decodes *every* file in `Fixtures/danterm` that way. On top of the duplication, `bytes(fromHex:)` and the `hex` field are dead: `grep -rl '"hex"' Fixtures/` matches only `utf8-decoder-corpus.json` (a different schema owned by UTF8DecoderTests) -- no danterm fixture has ever used hex, so the branch has never executed.

**Recommendation.** Replace the private `Recording`/`Event` types and both `bytes` helpers with `NeutralTerminalRecording` + `NeutralTerminalRecordingEvent`, switching `replay(_:redrawOverride:)` over `.feed(bytes)` / `.resize(columns:rows:)`, and delete the hex path.

**Verifier (confirmed).** Verified: every file in Fixtures/danterm decodes as NeutralTerminalRecording today (TerminalSemanticPromptInvariantTests.recordingCorpus decodes the whole directory; TerminalPromptAnchorResizeSweepTests decodes three of the very files this suite uses), all events are base64 feed + resize, and no fixture anywhere uses "hex" except utf8-decoder-corpus.json. The hex branch is not just unused but forbidden: scripts/terminal-recording-schema-audit.py (a `just test` step) rejects any feed whose encoding set is not exactly {base64} or {text}, and the private decoder cannot even handle a legal {text} feed. Two implementation notes for whoever does it: (1) keep decode-only -- zsh-redraw-discriminator, zsh-stale-width-repaint and zsh-stale-width-prompt-drift carry free-form provenance.source strings that NeutralTerminalProvenance.validate() rejects, so the suite must keep driving feeds itself rather than calling NeutralTerminalRecording.replay(); (2) make the new switch throw on .input/.paste/.focus/.mouse/.viewport rather than skipping them, matching today's hard failure via #require(event.hex).

### 69. searchHighlightDerivation's separation assertion is always true

**Status:** `done` -- vacuous `>= 0` replaced with the exact golden RenderColor; dead helpers removed

`lib/TerminalCore/Tests/TerminalRenderPlanningTests/RenderColorResolutionTests.swift:101` -- high confidence, trivial effort, found by `tests-render`

**Problem.** The test sets `defaultBackground = RenderColor(red: 175, green: 128, blue: 20)` and `baked = RenderColor(red: 175, green: 128, blue: 20)` -- the same color -- so `separationScore(baked, from: defaultBackground, and: selectionBackground)` is `min(0, ...) == 0`. The final expectation therefore reduces to `separationScore(derived, ...) >= 0`, which holds for any color because both terms are squared distances. The two private helpers `separationScore`/`squaredDistance` (lines 208-221) exist only to feed that vacuous comparison, and no test anywhere asserts which candidate `RenderTheme.deriveSearchMatchBackground` actually picks (`bakedDarkThemeGoldenValues` omits `searchMatchBackground`, and `SearchMatchExecutionTests` uses `RenderTheme.dark.searchMatchBackground` as its own expected value).

**Recommendation.** Replace the `>=` expectation with the exact derived value for this theme -- `#expect(first.searchMatchBackground == RenderColor(red: 80, green: 127, blue: 235))` -- which pins the max-separation choice, and delete the now-unused `separationScore`/`squaredDistance` test helpers.

**Verifier (confirmed).** Verified: baked and defaultBackground are both (175,128,20), so the right-hand separationScore is min(0, d2) = 0 and the comparison degenerates to `>= 0`, which squared distances always satisfy. Confirmed the recommended golden by hand against RenderTheme.deriveSearchMatchBackground: min-distances are candidate A (175,128,20) -> 0, B (80,127,235) -> 11122, C (56,88,140) -> 0, so `max(by:)` returns B = RenderColor(red: 80, green: 127, blue: 235). Also confirmed no other test pins a derived value (bakedDarkThemeGoldenValues stops at cursorText; SearchMatchExecutionTests and SelectionExecutionTests both read RenderTheme.dark.searchMatchBackground as their own expectation). separationScore/squaredDistance have no other caller in the file, so deleting them is clean.

### 70. Both decodeBenchmarkChunks framing errors are unreachable from any test

**Status:** `done` -- negative tests added for both truncatedLength and truncatedChunk

`lib/TerminalCore/Tests/TerminalCoreBenchmarkSupportTests/TerminalCoreBenchmarkSupportTests.swift:49` -- high confidence, small effort, found by `tests-pty-probes`

**Problem.** `lengthFramingPreservesChunks` is the only test touching `decodeBenchmarkChunks`, and it only round-trips well-formed framing. Neither `CoreBenchmarkError.truncatedLength` (fewer than 8 bytes left for a length prefix) nor `.truncatedChunk` (a declared length exceeding the remaining bytes) is exercised anywhere in the repo — I grepped `lib`, `app`, and `scripts`. This is the stdin deserialization boundary for two shipped executables that `try` it (`Sources/TerminalCoreBenchmark/main.swift:15`, `Sources/TerminalRetainedRowProbe/main.swift:45`), so a corrupt or half-written fixture is meant to surface as a named error rather than a crash or a silent partial decode.

**Recommendation.** Add a parameterized negative test feeding a 4-byte prefix (expect `CoreBenchmarkError.truncatedLength`) and an 8-byte length of 99 followed by 2 payload bytes (expect `.truncatedChunk`), using `#expect(throws:)`.

**Verifier (confirmed).** Grepped lib/, app/, and scripts/: the only references to truncatedLength/truncatedChunk are their declarations and throw sites; lengthFramingPreservesChunks is the sole decodeBenchmarkChunks test and only round-trips well-formed framing. Both guards are real crash defenses -- without them `Array(data[offset..<end])` traps -- and two shipped executables (TerminalCoreBenchmark/main.swift, TerminalRetainedRowProbe/main.swift) `try` this on stdin. Traced the proposed inputs: 4 bytes hits the `data.count - offset >= 8` guard, and an 8-byte length of 99 with 2 payload bytes hits `length <= UInt64(data.count - offset)`. CoreBenchmarkError has no associated values so it gets implicit Equatable, meaning `#expect(throws: CoreBenchmarkError.truncatedLength)` compiles as written.

### 71. The "budget too small for one display row" guard is never exercised

**Status:** `done` -- new `aBudgetBelowOneFullWidthRowRetainsNothing` exercises the sub-one-row budget guard

`lib/TerminalCore/Tests/TerminalCoreTests/TerminalScrollbackBudgetTests.swift:79` -- high confidence, small effort, found by `tests-storage`

**Problem.** `LogicalLineStore.admit` opens with `guard worstCase <= regionCapacityBytes else { return }` (LogicalLineStore.swift:497) whose comment states the contract explicitly: "the honest answer is that such a pane has no history, and the degenerate configuration stays reachable instead of being a crash". Nothing exercises it. Every budget in the suite is either 6_000 or a `historyBudget(...)` result, and `historyBudget` deliberately floors its answer with `fullWidthRowFloor(columns:)` (TerminalGridAssertions.swift:311) whose own doc says "A pane whose history cannot hold a single display row of its own width retains nothing at all -- legal, and never what a fixture means". The store-level suite's smallest budget is `1 << 13` at width 16, far above the `16 + 16 * columns` arena a full-width row needs. So the one branch that keeps a degenerate pane from trapping has no test.

**Recommendation.** Add a behavioral test that builds a terminal whose budget is below `fullWidthRowFloor` for its width (e.g. `Terminal(columns: 80, rows: 2, scrollbackBudgetBytes: 1024)`), feeds enough soft-wrapping output to scroll several full-width rows off, and asserts it does not trap: `scrollbackRowCount == 0`, `scrollbackCensus.chargedBytes <= scrollbackCensus.capacityBytes`, correct `screenText`, and `expectValidGrid`.

**Verifier (confirmed).** The guard is real and undocumented by any test: LogicalLineStore.swift#admit opens with `guard worstCase <= regionCapacityBytes else { return }`, and nothing in the suite asserts the degenerate-pane contract. historyBudget's binary search calls the store itself, so any budget it returns is by construction one where the guard cannot fire for the rows the search admitted; fullWidthRowFloor(columns:) covers the wider-pane case whenever paneColumns is passed. I also checked the proposed fixture arithmetic: at budget 1024 the metadata reserve is 64, arenaCapacity 960, chunk 1024, so regionCapacityBytes = 960, while an 80-cell row's worstCase is 8 + 640 + projectedTableBytes(80)=648 = 1,296 -- the guard does fire, and Terminal.init masks the budget with `& ~7` so 1024 is legal. Two caveats: the problem statement's 'every budget in the suite is either 6_000 or a historyBudget(...) result' is imprecise (TerminalScrollbackBudgetTests also uses productionScrollbackBudgetBytes and productionScrollbackBudgetBytes - 8; 6_000 lives in the retention/census suites), and the stimulus must be full-width rows only -- any admitted row of <= 59 content cells still fits at that budget and would break the `scrollbackRowCount == 0` assertion.

### 72. Branch node connector direction-to-edge mapping is untested

**Status:** `done` -- new nodeConnectorEdges fails on a swapped .up/.down or .left/.right arm

`lib/TerminalCore/Tests/TerminalSpriteGeometryTests/BranchDrawingSpriteGeometryTests.swift:99` -- high confidence, small effort, found by `tests-render`

**Problem.** `BranchDrawingSpriteGeometry.geometry` emits one connector rect per requested direction, each anchored to a specific cell edge (`.up` -> y0 = 0, `.down` -> y1 = height, `.left` -> x0 = 0, `.right` -> x1 = width; BranchDrawingSpriteGeometry.swift:150-159). No test pins which direction produces which edge: `nodeConnectivity` uses `directions: [.up, .right, .down, .left]`, so all four rects exist regardless of mapping; `boundedMatrix` only checks determinism and rect containment; the executor's `exhaustiveBitmapCoverage` only checks that the cell has some ink and the neighbor is clean; `exhaustiveMapping` checks the classifier, not the geometry. Swapping the `.up` and `.down` (or `.left` and `.right`) arms of `append(_:)` passes the entire suite while drawing every one-connector node glyph with its connector on the wrong edge.

**Recommendation.** Add a geometry test iterating the four single-direction nodes at 9x17 asserting each produces exactly one rect touching only its requested edge -- e.g. `.up` yields one rect with `rect.y == 0` and no rect satisfying `rect.y + rect.height == 17`, `rect.x == 0`, or `rect.x + rect.width == 9`.

**Verifier (confirmed).** Verified the gap: nodeConnectivity requests all four directions, so the four edge-contact assertions are satisfied by the set of rects regardless of which arm produced which; boundedMatrix only asserts determinism plus containment (a swapped arm is still contained); canonicalLineTopologies covers only the 30 line patterns, never a node; and BranchDrawingSpriteExecutionTests only assert ink-present/neighbour-clean/mapping. Checked the proposed test against the implementation at 9x17, light 1 (left=4, top=8, cx=4.5, cy=8.5, radius=4.5): .up -> single rect (4,0,1,5); .down -> (4,12,1,5); .left -> (0,8,1,1); .right -> (8,8,1,1) -- each touches exactly its requested edge, so the recommended assertions pass today and would fail on a swapped arm. Consistent with docs/terminal-sprites.md, which lists 'connectors that meet the node and their requested cell edges' and 'structural snapshots that pin every compound topology' for this family.

### 73. Shell-integration PTY test pads with 6 seconds of fixed sleeps it does not need

**Status:** `done` -- 6s of sleeps removed and a .timeLimit added; 6.0s -> 0.4s, run 3x

`lib/TerminalPTY/Tests/TerminalPaneSessionTests/TerminalPaneSessionControllerTests.swift:206` -- high confidence, small effort, found by `tests-pty-probes`

**Problem.** `shellIntegrationsDeliverTypedEvents` wraps each shell invocation in `sleep 1; source ...; danterm_emit_command_start ...; danterm_emit_command_end; sleep 1; exit` for all three of zsh, bash, and fish — 6 seconds of unconditional wall clock in a `.serialized` suite. Neither sleep is load-bearing: the test is `@MainActor` and installs `controller.onSemanticEvents` synchronously before any suspension point, and it synchronizes on `await host.waitForResult() == .exited(.exited(0))` followed by `controller.synchronizeState()`, which fences the owner queue after the reducer has already drained output to EOF. It is also one of only 12 of 47 tests in this file with no `.timeLimit`, so a shell that never reaches its marker hangs the serialized suite instead of failing.

**Recommendation.** Delete both `sleep 1` calls from the constructed invocation (the `waitForResult` + `synchronizeState` pair is the real synchronization) and add `.timeLimit(.minutes(1))` to the `@Test` attribute like the rest of the suite.

**Verifier (confirmed).** Traced both synchronization claims. Callback registration: TerminalPaneDeliveryBoundary.scheduleFrame always hops through DispatchQueue.main.async, so no delivery can run before the @MainActor test body reaches its first await -- and semantic events accumulate in the Terminal until a fence calls drainSemanticEvents(), so nothing is discarded in the meantime. Output drain: PaneLifecycle#handleRunning routes .childExited with outputEOF == false into .drainingOutput + .drainOutput, and beginTeardown(result: .exited(...)) only runs after the subsequent .outputEOF, so `waitForResult() == .exited(...)` already implies the FIONREAD drain completed; the trailing synchronizeState() fence then hands over every accumulated event. Neither sleep is load-bearing. Counted 47 @Test and 35 .timeLimit, matching the 12-without claim. Minor wording nit: this test waits on waitForResult(), not on a marker, so the hang mode is a child that never exits. Recommend running the PTY step a few times after the edit, since real-shell timing is the one thing static reading cannot settle.

### 74. Reflow style assertion is satisfied by an untouched cell

**Status:** `done` -- per-cell assertions replace the existential; the old form was confirmed to pass on an untouched cell

`lib/TerminalCore/Tests/TerminalCoreTests/TerminalStyleTests.swift:141` -- high confidence, trivial effort, found by `tests-behavior-a`

**Problem.** `underlineColorRetention` checks reflow with `#expect(terminal.geometry.rows.indices.contains { row in ... cells.indices.contains { column in cell(row:column:)?.style == styled } })`. After `\u{1B}8C` the row holds "AC" with both cells carrying `styled`, and the 4->2 resize leaves them at row 0 columns 0 and 1. The existential is satisfied by cell (0,0) alone, so a reflow that dropped the underline color from the second styled cell -- the cell the DECRC-restored pen wrote, which is what the test name is about -- still passes.

**Recommendation.** Replace the existential with the two concrete post-resize cells: `#expect(terminal.cell(row: 0, column: 0)?.style == styled)` and `#expect(terminal.cell(row: 0, column: 1)?.style == styled)`.

**Verifier (confirmed).** Traced the fixture: `A` is written with the styled pen, DECSC saves it, SGR 59 clears the underline color, `B` is written at column 1, then `ESC 8` restores the pen and cursor and `C` overwrites column 1 with `styled`. So row 0 is "AC", both styled, and the existential is satisfied by (0,0) alone -- a reflow that dropped the DECRC-written cell's underline color still passes. The two-cell replacement is correct after the resize: `resizeWidth` reconstructs logical lines from `rows[...max(cursor.row, lastLiveContentRow)]` (row 0 only here) and packs "AC" into a single 2-column row, so nothing scrolls into history and (0,0)/(0,1) are the reflowed styled cells.

### 75. Fixed 2s sleep used as a positive wait for child cleanup

**Status:** `done` -- fixed 2s sleep replaced with a bounded 20ms ppid poll; 2.0s -> 0.22s

`lib/TerminalPTY/Tests/TerminalPTYHostTests/TerminalPTYHostTests.swift:1339` -- high confidence, trivial effort, found by `tests-pty-probes`

**Problem.** `applicationExitTerminationClaimsResolvedSpawn` injects a 1.0s spawn-delivery delay, then ends with `try await Task.sleep(for: .seconds(2))` followed by `#expect(directChildProcessIDs().contains(launched) == false)`. That is a positive wait — the test is waiting *for* the delayed worker to run its token-gated callback and the child to die — expressed as a fixed deadline with ~1s of slack, so it flakes under the parallel gate load that `scripts/run-test-suite.sh` creates. The same file already establishes the correct pattern for exactly this claim: `waitForProcessExit(_:within:)` (line 2228) polls every 20ms to a 10s bound and is used at lines 616, 732, 930, 967, 1010, 1049, 1226 and 1242. It cannot be reused verbatim here because `kill(pid, 0)` succeeds for a zombie whereas `directChildProcessIDs()` filters on `pbi_ppid`.

**Recommendation.** Replace the `Task.sleep(for: .seconds(2))` with a bounded poll on the same predicate — loop `try await Task.sleep(for: .milliseconds(20))` until `directChildProcessIDs().contains(launched) == false` or a 10s `ContinuousClock` deadline — mirroring `waitForProcessExit`.

**Verifier (confirmed).** Confirmed at TerminalPTYHostTests.swift:1339: injectSpawnDeliveryDelay(1.0) then a bare `Task.sleep(for: .seconds(2))` followed by `#expect(directChildProcessIDs().contains(launched) == false)` -- a positive wait for the delayed worker's token-gated discard (which runs on spawnQueue via discardOffOwner) expressed as a fixed deadline. waitForProcessExit exists at line 2228 and is used at 616, 732, 742, 930, 967, 1010, 1049, 1226 (the finding lists 1242 instead of 742; immaterial). The reason it cannot be reused verbatim is correct: kill(pid, 0) succeeds for a zombie while directChildProcessIDs() filters on pbi_ppid. Note the neighbouring `Task.sleep(for: .seconds(1))` at line 1296 is a legitimate negative wait ('nothing arrives afterward') and must not be converted. This gate step does run under scripts/run-test-suite.sh's parallel pool, so the load argument holds.

### 76. Two assertions in chargedBytesStayUnderTheBudget cannot fail

**Status:** `done` -- peakInUse tracking dropped; post-removeAll check tightened to `== 0` with a `> 0` pre-check

`lib/TerminalCore/Tests/TerminalCoreTests/TerminalLogicalLineStoreTests.swift:275` -- high confidence, trivial effort, found by `tests-storage`

**Problem.** In `chargedBytesStayUnderTheBudget`, `#expect(peakInUse <= capacity)` (line 275) is implied by the in-loop `#expect(store.census.chargedBytes <= capacity)` (line 265): `Census.chargedBytes` is `arenaBytesInUse + indexBytes + sideTableBytes`, so it is >= `arenaBytesInUse` at every sample `peakInUse` is taken from -- the final check can never be the one that fires. Line 273's `#expect(store.census.arenaBytesInUse < saturated)` after `removeAll()` is similarly slack: `removeAll()` routes through `resetToEmptyArena()`, which sets `bytesInUse = 0`, so the exact post-condition is `== 0` and the `<` form would still pass on a store that released only one byte.

**Recommendation.** Drop the `peakInUse` tracking and its assertion, and tighten line 273 to `#expect(store.census.arenaBytesInUse == 0)`.

**Verifier (confirmed).** Both claims check out. `Census.chargedBytes` is `arenaBytesInUse + indexBytes + sideTableBytes`, and peakInUse (line 267) is sampled in the same iteration, after the same admit, as the in-loop `#expect(store.census.chargedBytes <= capacity)` (line 265), so line 275 is implied at every sample and can never be the sole failure. `removeAll()` (LogicalLineStore.swift#removeAll) unconditionally calls `resetToEmptyArena()`, which sets `bytesInUse = 0`, so the exact post-condition is `== 0`; the `<` at line 273 is strictly weaker and the tightening is correct for both loop arms (the blank-history arm still charges 8-byte header-only records, so `saturated > 0` holds and the assertion is not vacuous).

### 77. Locate-budget test passes when nothing is measured

**Status:** `done` -- added a `#expect(shallow >= 1)` calibration gate so the test cannot pass when nothing is measured

`lib/TerminalCore/Tests/TerminalCoreTests/TerminalFrameLocateTests.swift:55` -- high confidence, trivial effort, found by `tests-behavior-a`

**Problem.** `frameLocateCountIsConstantInHistoryDepth` asserts only `shallow <= 2` and `deep == shallow`. Both hold when `shallow == deep == 0`, which is exactly what happens if the single `LocateCounter.record()` call site (LogicalLineStore.swift:1107) stops being reached -- a removed instrumentation call, or a read path that no longer consults the index at all. The instrument cannot report "not measured", which `agent-docs/measurement-discipline.md` names as the thing to build against; the test both scrolls to `topRow: 0` over 60 and 6,000 retained lines, so a working implementation must spend at least one locate.

**Recommendation.** Add a calibration gate before the invariance assertions: `#expect(shallow >= 1)`, so a silently disconnected counter fails instead of passing.

**Verifier (confirmed).** `LocateCounter.record()` has exactly one call site, `LogicalLineStore.locate(displayRow:)`, and both measured reads reach it through `historyCursor(atStreamRow:)` -- `geometry` -> `presentedRowGeometry` (one locate at `topRow`) and `forEachViewportRow` (one more). With 60 fed lines in a 24-row terminal scrolled to `topRow: 0` the whole viewport is retained history, so today `shallow == 2` and the proposed `#expect(shallow >= 1)` gate passes; the warm-up pass memoizes nothing (there is no locate cache), so it cannot drive the measured count to zero. The gate is exactly the "metric can say not measured" requirement in agent-docs/measurement-discipline.md. Worth noting the sibling test `projectionArithmeticNeverTouchesTheIndex` (`spent == 0`) inherits the same protection once the counter is calibrated by this one.

### 78. Two identical overflow-metrics helpers and three redundant plan builders in one test target

**Status:** `done` -- shared OverflowMetricsSupport.swift; both copies now call it

`lib/TerminalCore/Tests/TerminalRenderExecutionTests/RenderMetricsTests.swift:238` -- high confidence, small effort, found by `tests-render`

**Problem.** `largestMetricsWhoseTwoColumnFrameOverflows()` (RenderMetricsTests.swift:238-251) and `largestOverflowingMetrics()` (BackgroundExecutionTests.swift:79-92) are line-for-line identical binary searches differing only in name, both `private` in the same `TerminalRenderExecutionTests` target. Separately, `makePlan(columns:rows:)` (RenderMetricsTests.swift:253) and `makeTwoColumnPlan()` (BackgroundExecutionTests.swift:94) each re-implement the shared `makePlan(input:columns:rows:isCursorVisible:cursorShape:)` already exported from BitmapTestSupport.swift:205, which produces the same plan when called with `input: ""`.

**Recommendation.** Move one copy of the overflow-metrics search into BitmapTestSupport.swift as a shared non-private helper, delete the other copy, and replace the two local plan builders with calls to the existing `makePlan(input: "", columns:rows:)`.

**Verifier (confirmed).** Verified byte-identical bodies for largestMetricsWhoseTwoColumnFrameOverflows (RenderMetricsTests.swift:238) and largestOverflowingMetrics (BackgroundExecutionTests.swift:79), both private in TerminalRenderExecutionTests, each with a single call site (RenderMetricsTests:177, BackgroundExecutionTests:56). Confirmed the shared `makePlan(input:columns:rows:isCursorVisible:cursorShape:)` at BitmapTestSupport.swift:205 uses the same presentation (theme .dark, cursor hidden, .block), so `input: ""` reproduces both local builders; BackgroundExecutionTests already calls the shared helper at line 42, so the local one is plainly redundant. Test-only, no behavior or perf implication.

### 79. Canonical-plan form is never checked over the danterm fixture corpus

**Status:** `done` -- assertCanonical now runs per corpus event across all 15 danterm fixtures; assertCanonical also gained a `Comment` parameter so a corpus failure names its fixture and event index (orchestrator follow-up)

`lib/TerminalCore/Tests/TerminalRenderPlanningTests/RenderCorpusPlanningTests.swift:123` -- high confidence, trivial effort, found by `tests-render`

**Problem.** The file header claims "corpus-wide ... canonical-form proofs", but `assertCanonical` is only called from `everyLibvtermCheckpoint`, which reads only the `libvterm` fixture directory and only at `.checkpoint` events. `everyNeutralEventOverlaysDamage` walks both `danterm` and `libvterm` fixtures but only compares plans for equality -- it never calls `assertCanonical` on `completePlan`. The 15 `danterm` fixtures contain no `checkpoint` events at all (verified by grep), so no plan derived from them is ever checked for run ordering, non-overlap, non-mergeability, in-bounds columns, or the payload-free-cell filter. A planner regression that emits mergeable or out-of-order runs only on a DanTerm-specific scenario (reflow, resize, viewport navigation) would still compare equal against itself and pass.

**Recommendation.** Call `assertCanonical(completePlan)` inside the per-event loop of `assertDamageEquivalence`, right after `completePlan` is planned on line 123.

**Verifier (confirmed).** All claims hold: the header does say 'canonical-form proofs'; assertCanonical is called only at RenderCorpusPlanningTests.swift:63 inside everyLibvtermCheckpoint; assertDamageEquivalence only compares plans for equality. The reviewer's grep token was wrong (checkpoints serialize as `"type": "expect"`, NeutralTerminalRecording.swift#init(from:)) but the conclusion is right -- I counted 0 'expect' events across all 15 danterm fixtures and non-zero in libvterm. Also checked the two failure risks: minimum columns across initial state and all 756 resize events is 3, so `plan.columns >= 2` holds, and the planner filters background runs whose color equals the theme default (RenderFramePlanner.swift line 461), so that invariant holds by construction. Two notes for the implementer: assertCanonical takes only a sourceLocation, so pass the loop's existing `context` string (add a Comment parameter) or a failure among 2340 events will be unattributable; and I could not run the suite, so the added ~2340 sweeps are unmeasured for runtime and untested for pass/fail.

### 80. Pure TerminalCore generation test lives in the real-PTY pane-session suite

**Status:** `done` -- moved into TerminalHistoryGenerationTests, off the serialized PTY gate step; the then-stale ESC[2J comment was later made true and rewritten by finding 13's fix (79564fbb)

`lib/TerminalPTY/Tests/TerminalPaneSessionTests/TerminalPaneSessionControllerTests.swift:149` -- high confidence, small effort, found by `tests-pty-probes`

**Problem.** `primaryHistoryGenerationDifferential` (lines 149-190) constructs a bare `TerminalCore.Terminal` and feeds it bytes; it never touches `TerminalPaneSessionController`, `TerminalPTYHost`, a PTY, or anything else in the TerminalPaneSession module. It nonetheless sits inside a `@MainActor @Suite(.serialized)` suite whose file header reads "Real-PTY session tests for planning, visibility, capture, exit, and teardown", so it runs on the `./scripts/test-terminal-pty.sh` gate step behind every real-PTY test instead of on the `swift test --package-path lib/TerminalCore` step. It is also the only site in the file using the internal `Terminal(columns:rows:scrollbackBudgetBytes:)` initializer (line 185). `lib/TerminalCore/Tests/TerminalCoreTests/TerminalHistoryGenerationTests.swift` already owns `primaryHistoryGeneration` coverage, though not this test's alternate-screen and resize-truncation funnels.

**Recommendation.** Move the test verbatim into `lib/TerminalCore/Tests/TerminalCoreTests/TerminalHistoryGenerationTests.swift` as a third `@Test` beside the forward and converse halves already there.

**Verifier (confirmed).** Read lines 149-190: the test constructs a bare Terminal and feeds bytes only -- no TerminalPaneSessionController, TerminalPTYHost, or PTY -- while sitting in a @MainActor @Suite(.serialized) file headed 'Real-PTY session tests for planning, visibility, capture, exit, and teardown', run by scripts/test-terminal-pty.sh. Confirmed by grep that line 185 is the file's only Terminal(columns:rows:scrollbackBudgetBytes:) use, and TerminalCoreTests already has @testable import TerminalCore so the internal initializer resolves after the move. TerminalHistoryGenerationTests.swift does own primaryHistoryGeneration coverage but genuinely lacks the alternate-screen and resize-truncation funnels, so this is an add, not a duplicate. One accompanying edit the recommendation does not mention: that file's header explicitly frames it as 'Two-sided proofs' whose two halves 'live together because each is only meaningful as the other's counterweight', so it needs rewording once a third test lands.

### 81. renderingDoesNotAlterMetrics ends on an assertion about the test helper's own arithmetic

**Status:** `done` -- assertion about the helper's own arithmetic deleted

`lib/TerminalCore/Tests/TerminalRenderExecutionTests/ExecutorContractTests.swift:114` -- high confidence, trivial effort, found by `tests-render`

**Problem.** The second expectation, `cellRect(row: 0, column: 2, columnCount: 2, metrics: before).x.count == before.cellWidthPixels * 2`, exercises no production code: `cellRect` is defined in the test support file as `x: column * cellWidthPixels ..< (column + columnCount) * cellWidthPixels` (BitmapTestSupport.swift:141-144), so `x.count` is `2 * cellWidthPixels` by construction for every possible metrics value. It cannot fail and says nothing about the test's stated intent (that rendering styled fallback content leaves regular-face metrics unchanged), which the preceding `#expect(after == before)` already covers.

**Recommendation.** Delete the `cellRect(...).x.count` expectation (lines 114-117), leaving `#expect(after == before)` as the test's assertion.

**Verifier (confirmed).** Verified cellRect (BitmapTestSupport.swift:135-146) builds x as `column * cellWidthPixels ..< (column + columnCount) * cellWidthPixels`, so for columnCount 2 the count is `2 * cellWidthPixels` by construction for any metrics -- the expectation is an identity over test-support arithmetic and touches no production behavior beyond reading cellWidthPixels. Deleting it leaves `#expect(after == before)`, which is what the test's stated intent (rendering styled fallback content does not mutate regular-face metrics) actually needs.

### 82. Three budget-ceiling probe tests share a verbatim body and comment block

**Status:** `done` -- three verbatim bodies collapsed into one parameterized test; .standard deliberately excluded and noted inline

`lib/TerminalCore/Tests/TerminalResizeProbeSupportTests/TerminalResizeProbeSupportTests.swift:86` -- high confidence, small effort, found by `tests-pty-probes`

**Problem.** `saturatingRecipeReachesTheBudgetCeiling` (30), `sparseRecipeReachesTheBudgetCeiling` (86), and `wideRecipeReachesTheBudgetCeiling` (132) have identical bodies apart from the `ResizeProbeRecipe` they select: same 200-line overfeed loop over `recipe.payload.line(...)`, same four assertions (`atCeiling > 0`, `atCeiling < recipe.lineCount`, and the +/-100 band), and the same seven-line "A band rather than an equality..." comment repeated word for word three times. A future change to the saturation contract has to be made in three places and will silently drift in the copy someone misses.

**Recommendation.** Collapse them into one `@Test("a saturating recipe fills the budget: feeding more lines buys no more rows", arguments: [ResizeProbeRecipe.saturating, .sparseSaturating, .wideSaturating])` taking the recipe as a parameter, keeping the three per-recipe rationales as bullet lines in the single preamble.

**Verifier (confirmed).** Read lines 30-63, 86-117, and 132-158: the four assertions (atCeiling > 0, atCeiling < recipe.lineCount, and the +/-100 band) and the seven-line 'A band rather than an equality...' rationale are word-for-word identical three times, and the only structural difference is the recipe selected plus two differently-worded comments on the same overfeed loop (the finding glosses this as fully identical bodies; the substance holds). ResizeProbeRecipe is `Equatable, Sendable`, which satisfies Swift Testing's parameterized-argument requirement, and the package already uses `arguments:` widely (TerminalSpriteGeometryTests, TerminalDamageSpanTests, TerminalBenchmarkSparseSpanRecorderTests). Cost profile is unchanged -- the suite is not .serialized, so the three cases already run concurrently. Two notes: keep .standard out of the argument list (it is deliberately the non-saturating v1 recipe, covered by probeTerminalIsBudgetSaturated), and consider conforming ResizeProbeRecipe to CustomTestArgumentEncodable or filtering on identity if you want to re-run a single case, since a bare Sendable argument cannot be individually addressed.

### 83. truncateTail's fold-before-cut ordering is untested on spacer-bearing content

**Status:** `done` -- new `truncatingTheTailHandsBackTheDerivedSpacers`, scoped per the verifier

`lib/TerminalCore/Tests/TerminalCoreTests/TerminalLogicalLineStoreTests.swift:999` -- medium confidence, small effort, found by `tests-storage`

**Problem.** `LogicalLineStore.truncateTail` carries a named regression in its body comment (LogicalLineStore.swift:896-900): rows must be folded before any is cut, because "A display row's trailing `.spacerHead` is re-derived from the wide head that *follows* it ... Cutting from the back one row at a time and folding as it went dropped exactly that cell on a height grow." All five `truncateTail` call sites in the suite -- lines 154, 382, 681, 819 and 1015 -- use narrow ASCII (`filledRow`/`shortRow`) or a background-erased row, so no handed-back row contains a derived spacer. Reversing the two loops in `truncateTail` would leave every existing assertion passing while silently dropping a column on a CJK height grow.

**Recommendation.** Extend `truncatingTheTailHandsRowsBack` (or add a sibling) that admits CJK wide clusters at an odd width so the fold derives a trailing `.spacerHead`, truncates at least two display rows, and asserts each handed-back row's last cell is `.spacerHead` carrying the following wide head's `styleId`.

**Verifier (confirmed).** Verified the mechanism and the gap. LogicalLineStore#truncateTail's comment names the regression, and #spacerDeferring shows the trailing `.spacerHead` is synthesized from the wide head that follows -- nothing stores it (`31/I1`). All five call sites (TerminalLogicalLineStoreTests 154, 382, 681, 819, 1015) feed filledRow/shortRow/backgroundErasedRow, all of which build only `.narrow` and blank cells, so no handed-back row can carry a derived spacer. The claim that a reversed order stays green is stronger than stated: expectValidStream only validates spacerHead -> next row starts with a matching wideHead, never the converse, so a *missing* spacer is invisible to expectValidGrid. Terminal-level height walks (TerminalResizeTests#heightAndCombinedWalksConserveFullHistory) use wide glyphs but at widths where nothing defers a spacer, and fullHistoryText would not see the lost column anyway. One scoping adjustment when writing it: assert the spacer on the handed-back rows that *precede* a deferred wide head -- the store's final display row has no following head, so 'each handed-back row's last cell is .spacerHead' cannot hold for the last one.

### 84. repairClearedSpacer's Bool result and its no-op guards are unasserted

**Status:** `done` -- the @discardableResult Bool is now asserted in both arms, plus a new full-last-row guard test

`lib/TerminalCore/Tests/TerminalCoreTests/TerminalLogicalLineFoldTests.swift:501` -- medium confidence, small effort, found by `tests-storage`

**Problem.** `LogicalLineStore.repairClearedSpacer(styleId:)` is `@discardableResult` and documented as "Returns whether the repair stored anything, so a caller can invalidate exactly the display row whose painted content changed and no other"; Terminal.swift:6573 branches on it (`let repaired = history.repairClearedSpacer(...)`). The only test, `clearedSpacerMaterializesTheBackgroundEraseBlank` (line 501), calls it and discards the result, and only covers the two style cases. The guard `lastRowColumns == width - 1` (LogicalLineStore.swift:714) -- which makes the repair a no-op when the open tail's last display row is already full -- has no test at all, so a store that appended a stray styled blank onto a full row would still pass.

**Recommendation.** Assert the returned Bool in `clearedSpacerMaterializesTheBackgroundEraseBlank` (true for `styleId: 5`, false for `Terminal.defaultStyleId`) and add a case where the open record's last display row occupies the full width, expecting `repairClearedSpacer(styleId: 5) == false` and an unchanged `recordSummary(at: 0)!.cellCount`.

**Verifier (confirmed).** Confirmed on all three points. LogicalLineStore#repairClearedSpacer is `@discardableResult` with the documented 'returns whether the repair stored anything' contract; Terminal.swift#clearPreviousSpacer consumes it as `if repaired || seamRowIsShortOfItsSpacer { invalidateInspection(...) }`, so the Bool drives a real branch (the other caller, #severScrollbackWrapClaim, discards it and invalidates unconditionally). The sole test, TerminalLogicalLineFoldTests.swift:485, calls it as a statement and infers the outcome only from cellCount. The `lastRowColumns == width - 1` guard has no test anywhere -- grep finds exactly one test reference to the method. The proposed expectations are correct against the code: `styleId: 5` on the width-3 wrapped fixture returns true (record cellCount 2 == width-1), `Terminal.defaultStyleId` returns false at the first guard, and a full-width open tail (e.g. a soft-wrapped 3-cell row at width 3) returns false at the lastRowColumns guard with cellCount unchanged.

### Downgraded (test improvements)

Real problems, but apply the verifier's adjustment.

### 85. everyByteSplit's title says two-chunk while the body also sweeps three-chunk splits

**Status:** `done` -- verifier's retitle-only branch; both loops kept, no coverage lost

`lib/TerminalCore/Tests/TerminalCoreTests/TerminalShellEventTests.swift:55` -- high confidence, trivial effort, found by `tests-behavior-b`

**Problem.** `@Test("a native event survives every two-chunk byte split")` names only half the body. Lines 62-70 run the two-chunk sweep, and lines 72-83 run a full three-chunk sweep. The three-chunk loop subsumes the two-chunk one: at `second == first` the middle chunk is empty, so `feed(bytes[..<first])` / `feed([])` / `feed(bytes[first...])` is byte-for-byte the two-chunk case at every `first`. So the first loop adds no coverage and the title understates what the test actually asserts. (`TerminalInputStreamTests.chunkBoundaryInvariance` at line 375 has the same redundant two-way-inside-three-way shape, though its title is accurate.)

**Recommendation.** Delete the two-chunk loop (lines 62-70) and retitle to "a native event survives every two- and three-chunk byte split", which is what the surviving loop proves.

**Verifier (adjustment required).** The title mismatch is real and the subsumption argument holds -- Terminal.feed([]) is a strict no-op (TerminalInputStream.feed returns [] and Terminal.feed early-returns on empty actions), so second == first reproduces every two-chunk case. But the deletion buys essentially nothing: the two-chunk loop is ~n iterations against the three-chunk loop's ~n^2/2, and after deleting it the retitled "two- and three-chunk" claim holds only via the empty-middle-chunk equivalence rather than explicitly. Adjustment: make the retitle the fix ("survives every two- and three-chunk byte split") and leave the loop, or delete it and title it for what remains (three-chunk) rather than asserting two-chunk coverage implicitly.

### 86. sustainedFeedRecreatesTerminalEachCycle title claims behavior its body never checks

**Status:** `done` -- retitled to the boundary claim the body actually verifies, with a pointer to the test that covers the fresh-terminal claim

`lib/TerminalCore/Tests/TerminalCoreBenchmarkSupportTests/TerminalCoreBenchmarkSupportTests.swift:61` -- high confidence, trivial effort, found by `tests-pty-probes`

**Problem.** The `@Test` title says "sustained feed recreates the measured terminal boundary each cycle", but `runSustainedFeed` (Sources/TerminalCoreBenchmarkSupport/TerminalCoreBenchmarkSupport.swift:79-89) never constructs or touches a `Terminal` — it only calls the supplied `feedCycle` closure until `maximumCycles` is reached and returns the count. The body correspondingly asserts only `completed == 3` and `batches == 3`. The fresh-terminal-per-execution claim is real but belongs to `measureFeedBatch`, and is already pinned by `feedBatchCreatesFreshTerminalPerExecution` (line 9) via its `creations == 3` assertion.

**Recommendation.** Rename the test to what it verifies — e.g. `@Test("a bounded sustained feed runs exactly maximumCycles cycles")` — leaving the fresh-terminal claim to `feedBatchCreatesFreshTerminalPerExecution`.

**Verifier (adjustment required).** The literal claim is right -- runSustainedFeed only loops the supplied closure and never touches a Terminal -- but the title reads at the composition level rather than contradicting the code. runSustainedFeed's own doc says 'Repeats the same fresh-terminal feed boundary for profiler attachment', and the production call site (TerminalCoreBenchmark/main.swift `runSustainedFeed { _ = measureFeedBatch(chunks: chunks, executionCount: 1) }`) makes the closure exactly that boundary; `batches == 3` is what pins that the boundary is re-entered once per cycle. Adjustment: the proposed rename ('runs exactly maximumCycles cycles') over-corrects by dropping the boundary claim that batches == 3 actually verifies. Prefer something like 'a bounded sustained feed re-enters its feed boundary once per cycle', which keeps both assertions accounted for and still removes the misreading that a fresh Terminal is proved here.

### 87. cursorAndControlStateAreImmune declares three paths but only two distinct ones

**Status:** `done` -- verifier-approved option only: paths/setup merged into one three-entry cases array, no setup dropped

`lib/TerminalCore/Tests/TerminalCoreTests/TerminalScrollbackBudgetTests.swift:428` -- high confidence, trivial effort, found by `tests-storage`

**Problem.** The `paths` array in `cursorAndControlStateAreImmune` holds three closures, but the second (lines 421-427) and third (lines 428-434) are byte-identical -- both do `bounded.resize(columns: 2, rows: 1)` / `unbounded.resize(columns: 2, rows: 1)`. The real axis is the paired `setup` array: index 1 is a 2x4 pane (height shrink) and index 2 a 4x1 pane (width narrow). The preamble's "each eviction path is compared immediately with its no-eviction twin" reads as three distinct eviction paths, so a maintainer editing one resize closure would reasonably assume the other differs and leave the pair inconsistent.

**Recommendation.** Collapse `paths` to the two distinct operations (feed and resize) and drive the third case from its `setup` entry alone, or merge `paths` and `setup` into one array of `(setup, operation)` tuples so the duplicate closure disappears.

**Verifier (adjustment required).** The duplication is real -- paths[1] (lines 421-427) and paths[2] (428-434) are byte-identical `resize(columns: 2, rows: 1)` closures, and the real axis is setup[1] (2x4, height shrink) vs setup[2] (4x1, width narrow). But the first half of the recommendation is unsafe as written: the loop is `for index in paths.indices`, so literally 'collapsing paths to the two distinct operations' drops the third setup and its coverage silently. Take only the second option -- merge into one array of `(setup, operation)` tuples with three entries and two distinct closure bodies (or keep three entries and hoist the shared resize into a named local) -- so all three cases still run. Downgraded also because the impact is purely readability; no assertion changes and no coverage is currently missing.

### 88. labeledTerminal fixture builder copied into three suites

**Status:** `done` -- builder moved to its own LabeledTerminalFixture.swift per the verifier (not into TerminalGridAssertions), all three copies deleted

`lib/TerminalCore/Tests/TerminalCoreTests/TerminalEditingTests.swift:261` -- high confidence, small effort, found by `tests-behavior-a`

**Problem.** The same A/B/C/D row-labelling fixture builder is defined three times in one test target: `TerminalEditingTests.labeledTerminal` (line 261) and `TerminalScrollRegionTests.labeledTerminal` (line 287) are byte-identical, and `TerminalRegionScrollbackTests.labeledTerminal` (line 181) is the same body plus a `scrollbackBudgetBytes` parameter defaulted to `Terminal.productionScrollbackBudgetBytes` -- which is exactly what the public `Terminal(columns:rows:)` init already passes (Terminal.swift:1099), so the parameterized copy is a strict superset of the other two.

**Recommendation.** Move the `TerminalRegionScrollbackTests` version (the parameterized one) into `TerminalGridAssertions.swift` as a shared non-private helper and delete the two identical private copies.

**Verifier (adjustment required).** The duplication is real and the superset claim is right: TerminalEditingTests:261 and TerminalScrollRegionTests:287 are byte-identical, TerminalRegionScrollbackTests:181 adds a `scrollbackBudgetBytes` defaulted to `Terminal.productionScrollbackBudgetBytes`, and the public `Terminal(columns:rows:)` forwards exactly that value with the same defaults for the other three parameters -- so the parameterized copy reproduces the other two exactly. Adjustment needed on the landing spot: TerminalGridAssertions.swift's header declares it holds "shared structural assertions", and AGENTS.md's file-header rule makes that header the statement of what belongs in the file. Dropping a fixture *builder* there needs the header updated to admit fixture builders (the file already quietly hosts `historyBudget`/`RecordCharge`, so amending it is defensible), or the helper should go in a separate shared-fixtures file. Also keep the shared version file-scope-`internal`, not a method, so the three call sites resolve unchanged.

### 89. mouseWheelButtonsRoundTrip's title promises wheel-direction behavior it never exercises

**Status:** `done` -- rename branch only, per the verifier (replay discards mouse output, so wheel bytes are unobservable)

`lib/TerminalCore/Tests/TerminalCoreTests/NeutralTerminalRecordingTests.swift:341` -- high confidence, trivial effort, found by `tests-behavior-b`

**Problem.** `@Test("neutral mouse buttons preserve upstream wheel directions")` implies the button->direction mapping is under test, but the body only encodes and decodes the recording and asserts `decoded == recording`. It never calls `replay()` or `applyNeutralTerminalMouse`, so `neutralWheelDirection` in NeutralTerminalRecording.swift (`TerminalMouseWheelDirection(rawValue: button + 60)`, mapping 4->.up ... 7->.right) is never invoked. Mutating that `+ 60` offset would leave this test green. The real mapping coverage lives elsewhere: `Fixtures/libvterm/state-mouse.json` events 27-31 feed buttons 4-7 and its checkpoint pins `inputBytes` `1B 5B 4D 60/61/62/63 ...`, run through `TerminalFixtureTests`.

**Recommendation.** Rename the test to what it checks -- e.g. "neutral wheel buttons 4-7 round-trip through the JSON codec" -- or add `let replayed = try decoded.replay()` and assert the resulting wheel report bytes so the title's claim becomes true.

**Verifier (adjustment required).** The body really is encode/decode/#expect(decoded == recording) with no replay, so neutralWheelDirection's `+ 60` is never exercised, and the mapping is indeed pinned elsewhere -- Fixtures/libvterm/state-mouse.json events 27-31 feed buttons 4-7 and the checkpoint pins inputBytes ... 96/97/98/99 ... through TerminalFixtureTests. Two corrections. (1) The test is not vacuous: the decoder's `(1...7).contains(button)` range check means it pins that the neutral schema still admits the 4-7 wheel vocabulary that NeutralTerminalMouseEvent's doc comment claims, so the title is imprecise rather than false. (2) The suggested alternative fix cannot work as written: NeutralTerminalRecording.replay() discards mouse output (`_ = applyNeutralTerminalMouse(...)`), so no wheel report bytes are observable through it -- asserting bytes would mean calling applyNeutralTerminalMouse directly with tracking enabled. Adjustment: take the rename branch only (e.g. "neutral wheel buttons 4-7 round-trip through the JSON codec").

### 90. Five test files each carry a private copy of the same xorshift Generator

**Status:** `done` -- shared SeededByteGenerator; all seven copies switched over, each keeping its original byte/word width so the seeded sequences are bit-identical

`lib/TerminalCore/Tests/TerminalCoreTests/TerminalSelectionTests.swift:487` -- high confidence, small effort, found by `tests-behavior-b`

**Problem.** `private struct Generator { var state: UInt64; mutating func next() -> UInt8 { xorshift13/7/17; return UInt8(truncatingIfNeeded: state) } }` is byte-identical in TerminalSelectionTests.swift:487, TerminalGraphemeTests.swift:234, TerminalInputStreamTests.swift:476, TerminalResizeTests.swift:457 and TerminalTests.swift:471 (TerminalScrollbackBudgetTests.swift:578 has the UInt64-returning variant, and TerminalPromptAnchorResizeSweepTests.swift:120 a renamed one). The package already has a shared home for cross-suite test helpers -- TerminalGridAssertions.swift, which hosts the file-scope `historyBudget(...)` and `expectValidGrid(...)` these same suites call -- so the duplication is not forced by scoping.

**Recommendation.** Move one copy into TerminalGridAssertions.swift as a file-scope `struct SeededByteGenerator` (with a `next() -> UInt64` accessor for the scrollback-budget variant) and delete the five private copies.

**Verifier (adjustment required).** The duplication is exactly as described (byte-identical UInt8 copies at TerminalSelectionTests:487, TerminalGraphemeTests:234, TerminalInputStreamTests:476, TerminalResizeTests:457, TerminalTests:471, plus the UInt64 variant in TerminalScrollbackBudgetTests:578 and the renamed PromptAnchorSweepGenerator), and TerminalGridAssertions.swift does host file-scope helpers. Two adjustments the recommendation needs. (1) Do not overload on return type: call sites like `generator.next().isMultiple(of: 5)` (scrollback budget, UInt64) and `Int(generator.next()) % bytes.count` (selection, UInt8) would become ambiguous, and silently moving any call site from the truncated byte to the full word changes the seeded sequence -- e.g. `% 6` differs between the low byte and the full state -- so each site must keep its original width behind distinctly named accessors. (2) TerminalGridAssertions.swift's header scopes it to "shared structural assertions"; per the file-header convention, either widen that header deliberately or put the RNG in its own small shared file.

### 91. Glyph-halo row filtering and the zero-row-count guard are untested

**Status:** `done` -- added glyphHaloClampsRowsOutsideTheGrid + emptyDamageHasNoSpans; refuted resize story dropped, guards kept

`lib/TerminalCore/Tests/TerminalRenderPlanningTests/TerminalDamageSpanTests.swift:34` -- high confidence, trivial effort, found by `tests-render`

**Problem.** `terminalDamageRowsWithGlyphHalo` has two guards nothing exercises: `guard rowCount > 0 else { return [] }` and the per-row filter `where row >= 0 && row < rowCount` (TerminalDamageSpans.swift:5-7). Every call in `glyphHaloStaysInsideTheViewport` and the two topology tests passes only in-range rows with a positive `rowCount`. Rows at or above `rowCount` are reachable in practice -- damage recorded before a shrinking resize outlives the smaller grid -- and dropping the filter would insert out-of-grid rows into the drawing clip, which the plan cannot describe. `terminalDamageMaximalContiguousSpans([])` returning `[]` is likewise unasserted (only the span *count* has an empty-set case).

**Recommendation.** Add cases to `glyphHaloStaysInsideTheViewport` asserting `terminalDamageRowsWithGlyphHalo([-1, 4, 9], rowCount: 4).isEmpty`, `terminalDamageRowsWithGlyphHalo([0], rowCount: 0).isEmpty`, and `terminalDamageMaximalContiguousSpans([]).isEmpty`.

**Verifier (adjustment required).** The coverage observation is accurate -- every existing call passes in-range rows with positive rowCount, and terminalDamageMaximalContiguousSpans([]) is unasserted (only the *count* has an empty case) -- and all three proposed assertions do pass against the current code. But the failure scenario is refuted: Terminal.resize calls `damage.reset(rowCount: rows, isFull: true)` (Terminal.swift#resize), so a shrink publishes full damage and the app takes invalidateFullDisplay(), never the halo path; both halo call sites (SwiftTerminalSessionView.swift:922 and TerminalBenchmarkSparseSpanTopology.swift:110) pass a same-frame TerminalDamage whose rows are already in range and already non-negative (pinned by TerminalDamageTests#negativeRowsCannotEnterDamage). Adjustment: drop the resize story and decide reachability first -- commit f31e1d77 set the precedent of deleting an unreachable downstream guard (`row == Int.min`) and pinning the upstream invariant instead, and `row >= 0` here is the same shape. Either frame the additions as pinning the public helper's documented clamp contract for raw Set<Int> callers, or propose deleting the branch. The `terminalDamageMaximalContiguousSpans([]).isEmpty` assertion is worth adding either way.

## 5. Docs and comments

Comments and markdown whose factual claims contradict the current code.

### 92. Capability contract states a 10 MiB scrollback bound; code ships 16 MiB

**Status:** `done` -- table row + prose now 16 MiB; also fixed the stale `pins 10 MiB` comment in TerminalMemoryProbeSupport

`docs/terminal-capabilities.md:198` -- high confidence, trivial effort, found by `docs-comments`

**Problem.** The normative "Resource behavior" table row `| scrollback | 10485760 | bytes |` and the prose at line 211 ("Scrollback is limited to 10 MiB") contradict the engine: `Terminal.productionScrollbackBudgetBytes = 16_777_216` in lib/TerminalCore/Sources/TerminalCore/Terminal.swift:689, whose own doc comment says it was "Raised from 10 MiB to 16 MiB by doc 28's `D11`". Every other numeric limit in that table still matches code (`maximumTerminalMetadataBytes`, `maximumSemanticValueBytes`, `maximumReplyBytes`, the 1 MiB OSC 52 decode, the 2 MiB `oscPayloadCapacity`), so this one wrong row reads as authoritative.

**Recommendation.** Change the `scrollback` row to `16777216` and the sentence at line 211 to "Scrollback is limited to 16 MiB", sourcing both from `Terminal.productionScrollbackBudgetBytes`.

**Verifier (confirmed).** Verified: docs/terminal-capabilities.md:198 says `| scrollback | 10485760 | bytes |` and :211 says "Scrollback is limited to 10 MiB", while lib/TerminalCore/Sources/TerminalCore/Terminal.swift:689 is `public static let productionScrollbackBudgetBytes = 16_777_216` with a doc comment explaining the 10->16 MiB raise, and the cited evidence suite (TerminalScrollbackBudgetTests) asserts against that constant, not a literal. The doc's front matter calls itself the normative contract, so it is a living doc and the edit is right. One extension while you are there: lib/TerminalCore/Sources/TerminalMemoryProbeSupport/TerminalMemoryProbeSupport.swift:273 still says the public initializer "pins 10 MiB" -- same staleness, same fix, and it is inside this review's scope.

### 93. Browse-benchmark file header still calls retained-browse an uncalibrated candidate

**Status:** `done` -- header and candidate-workload paragraph now name retained-browse as calibrated

`lib/TerminalCore/Sources/TerminalBrowseBenchmarkSupport/TerminalBrowseBenchmarkSupport.swift:1` -- high confidence, trivial effort, found by `docs-comments`

**Problem.** Line 1 says this is "Headless frame planning over *retained* history, which no calibrated workload reaches", and lines 13-16 justify excluding decision rules with "this is a *candidate* workload, so it collects descriptively and a human moves a screened threshold into the frozen table". That move already happened: `retained-browse` sits in `WORKLOADS` (scripts/terminal-benchmark-validation.py:22), not `CANDIDATE_WORKLOADS`, and carries frozen `directionalThresholdPercent` entries in both `quick` (1.05%, 2 pairs, line 180) and `confirm` (1.05%, 4 pairs, line 255). agent-docs/terminal-performance.md:76-84 documents that frozen rule. The header now denies the calibrated status of the very workload the file implements.

**Recommendation.** Rewrite lines 1 and 13-16 to say this is the calibrated `retained-browse` workload -- the only one that plans over retained history -- and that the decision rule lives in `scripts/terminal-benchmark-validation.py#DECISION_RULES` rather than here.

**Verifier (confirmed).** Verified: `retained-browse` is in VALIDATION.WORKLOADS (scripts/terminal-benchmark-validation.py:16-23, the tuple the script's own comment calls "the *calibrated* set"), not in CANDIDATE_WORKLOADS, and it carries frozen rules in both modes (quick: 2 pairs / 1.05% at :180; confirm: 4 pairs / 1.05% at :255). agent-docs/terminal-performance.md:76-84 documents that frozen threshold. So both "which no calibrated workload reaches" (line 1) and "this is a *candidate* workload" (lines 13-16) are now false, and DECISION_RULES is the correct symbol name (script line 144). Extend the same fix to lib/TerminalCore/Sources/TerminalBrowseBenchmark/main.swift:1, which also still calls it "the retained-history browsing candidate workload".

### 94. Performance guide says benchmark-confirm compares "all five" workloads; the ladder is six

**Status:** `done` -- both spots now say six, matching VALIDATION.WORKLOADS

`agent-docs/terminal-performance.md:24` -- high confidence, trivial effort, found by `docs-comments`

**Problem.** Line 23-24 ("`benchmark-confirm` compares all five") and line 332 ("the stronger five-workload evidence") are contradicted by the same document's own ladder table, which lists six calibrated workloads plus one candidate, and by `VALIDATION.WORKLOADS` in scripts/terminal-benchmark-validation.py:16-23, which contains six entries (terminal-feed, scrollback-stream, content-churn, style-churn, incremental-mixed, retained-browse). `resolve_workloads` returns that whole tuple for `confirm`, so a confirm run measures six.

**Recommendation.** Replace "all five"/"five-workload" at lines 24 and 332 with "all six", matching `VALIDATION.WORKLOADS`.

**Verifier (confirmed).** Verified: agent-docs/terminal-performance.md:24 ("all five") and :332 ("stronger five-workload evidence") against VALIDATION.WORKLOADS, which holds six (terminal-feed, scrollback-stream, content-churn, style-churn, incremental-mixed, retained-browse); terminal-benchmark-compare.py:169 returns that whole tuple when no workload is selected. The same document's ladder table already lists all six plus the `synchronized-frames` candidate, so the doc contradicts itself. This is a living operational guide, so updating the count in place is the right fix.

### 95. firstRowCellEnd's doc comment splices a truncated sentence into a duplicated paragraph

**Status:** `done` -- dangling paragraph removed, cross-reference folded into the surviving hasWideCells paragraph

`lib/TerminalCore/Sources/TerminalCore/LogicalLineRecord.swift:313` -- high confidence, trivial effort, found by `core-storage`

**Problem.** The doc comment on `LogicalLineFold.firstRowCellEnd` breaks mid-sentence: line 313 ends with "-- which matters because eviction asks" and line 314 starts a different, later-written paragraph ("The *first* row is the one case `enumerateRows`' walk collapses to arithmetic...") that re-states the same point and ends with its own "which matters because eviction asks this once per dropped display row". A reader gets one dangling clause and two overlapping explanations of the same fast path.

**Recommendation.** Delete the dangling tail of the first paragraph (lines 311-313, from "The `hasWideCells` fast path..." through "...because eviction asks") and keep the complete paragraph at lines 314-321, which already covers both the arithmetic collapse and the `hasWideCells` skip.

**Verifier (confirmed).** Read LogicalLineRecord.swift:303-321. Line 313 really does end mid-clause ("-- which matters because eviction asks") with no `///` blank line before line 314, and 314-318 restates the same fast path and completes the same clause ("...eviction asks this once per dropped display row"). The comment describes real behavior at both altitudes, so nothing factual is lost by the cut; 320-321 already carries the `hasWideCells` skip and the `31/DD4` cite. One small thing worth preserving when deleting 311-313: the cross-reference that this is the same fast path `LogicalLineFold.rowCount` takes (verified at 242-257) -- fold that half-sentence into the surviving `hasWideCells` paragraph rather than dropping it.

### 96. Terminal.swift's one-line header omits most of what the 6,582-line file owns

**Status:** `done` -- one-line header replaced with the block AGENTS.md prescribes, including what deliberately lives elsewhere and the rule for new code

`lib/TerminalCore/Sources/TerminalCore/Terminal.swift:1` -- high confidence, small effort, found by `docs-comments`

**Problem.** The whole header is "Pure headless terminal reduction: byte ingestion, grid mutation, controls, and inspection." for a 6,582-line file. AGENTS.md's "File header comments" rule allows a single line only for "a small, focused file". The file also owns selection (`setSelection`, `selectAll`, `clearSelection` at 2540-3027), search (`beginSearch`/`searchNext`/`searchStatus` at 3039+), hyperlink hover/click interaction (86 `hyperlink` references), OSC 133 prompt vacate/reclaim (`clearPromptForResizeIfNeeded`, `reclaimStalePromptHeads`), retained-history admission into `LogicalLineStore`, and the `memoryCensus` walk. Three sibling headers point readers back here for responsibilities the header never names: PackedRetainedRow.swift:11 ("that is admission, in Terminal.swift beside canonical trimming"), TerminalMemoryCensus.swift:11-13 (the census walk "lives in Terminal.swift"), and LogicalLineStore.swift:17 ("anchors, selection, projection -- which stays in `Terminal.swift`").

**Recommendation.** Expand the header into the multi-line block AGENTS.md prescribes, naming the added domains (selection, search, hyperlink interaction, semantic prompt anchoring, history admission, memory census) and what deliberately lives elsewhere (`LogicalLineStore`, `LogicalLineRecord`, `PackedRetainedRow`).

**Verifier (confirmed).** Verified: the file is 6,582 lines and the header is the single line quoted. Every named domain is really there -- setSelection/selectAll/clearSelection at 2540/2573/3027, beginSearch/searchNext at 3039/3055, 86 `hyperlink` occurrences, reclaimStalePromptHeads at 1305 and clearPromptForResizeIfNeeded at 1881, `memoryCensus` at 2123 -- and all three sibling back-references check out (PackedRetainedRow.swift:11-12, TerminalMemoryCensus.swift:11-13, LogicalLineStore.swift:17). AGENTS.md's file-header rule ("a single line is fine for a small, focused file") is plainly not satisfied here, so the expansion is convention-compliant and doc-only.

### 97. PackedRowModel's doc justifies it by a function that does not exist, and nothing uses the type

**Status:** `done` -- PackedRowModel deleted (public, zero call sites); stale doc sentences replaced with the extent claim the test checks

`lib/TerminalCore/Sources/TerminalRetainedRowProbeSupport/TerminalRetainedRowProbeSupport.swift:75` -- high confidence, small effort, found by `docs-comments`

**Problem.** The doc on `PackedRowModel` says "`packedPayloadMatchesModel` below is a comparison between the design's arithmetic and the implementation's bytes", and the inline comment at line 518-521 says "the byte claim moved to `packedPayloadMatchesModel`, which prices that extent through `C6`'s own arithmetic." No `packedPayloadMatchesModel` exists anywhere in lib/ or app/, and `PackedRowModel` itself has exactly one occurrence in the repo -- its own declaration at line 77 -- so no caller checks anything. Line 282 of the same file already records that the sibling `packedPayloadModelBytes` "was retired with the representation it described", and the `C6` citation is the rejected predecessor design (PackedRetainedRow.swift:5 records `C1` as the one that shipped).

**Recommendation.** Delete `PackedRowModel` (lines 69-93) along with the stale `packedPayloadMatchesModel`/`C6` sentences at lines 518-521, leaving the extent claim that `derivationMatchesCensus` actually checks.

**Verifier (confirmed).** Verified: repo-wide grep (excluding .git and .claude/worktrees) finds `packedPayloadMatchesModel` only in plans/ and docs/research/, never in lib/ or app/; `PackedRowModel` appears only at its declaration (TerminalRetainedRowProbeSupport.swift:77) plus the stale doc sentence at :75 -- no call site, no test. Line 282 does record `packedPayloadModelBytes` as retired with the representation, and PackedRetainedRow.swift:5 does record C1 as shipped (C6 is the rejected predecessor), so the `C6` attributions at :519-521 are also wrong. Deleting lines 69-93 is build-safe (public but unreferenced, TerminalCore is a local path package) and loses no test coverage. If you would rather keep the widths as an independent model for a future probe, the minimum acceptable fix is to correct :75 (drop the dead function reference) and :519-521 (C6 -> C1, and point at derivationMatchesCensus for the extent claim).

### 98. Performance guide claims app/ has no test target

**Status:** `done` -- reason replaced with the real one (DanTermAppTests does not define DANTERM_TERMINAL_BENCHMARK)

`agent-docs/terminal-performance.md:848` -- high confidence, trivial effort, found by `docs-comments`

**Problem.** Line 848-849 reads "`TerminalBenchmarkMarkersTests` is the only automated cover for detection semantics, since `app/` has no test target". Package.swift:91-103 declares `.testTarget(name: "DanTermAppTests", dependencies: ["DanTerm", ...], path: "app-tests")` with five suites; it was added 2026-08-01 (`e0d11fa7`), after this sentence was written on 2026-07-24 (`df80150e`). The conclusion may still hold for a different reason -- `TerminalBenchmarkObserver` is behind `#if DANTERM_TERMINAL_BENCHMARK`, which that target does not define -- but the stated reason is false and would mislead anyone adding app-side coverage.

**Recommendation.** Replace "since `app/` has no test target" with the real reason: `DanTermAppTests` does not build with `DANTERM_TERMINAL_BENCHMARK`, so the observer is not compiled into it.

**Verifier (confirmed).** Verified: Package.swift declares `.testTarget(name: "DanTermAppTests", dependencies: ["DanTerm", ...], path: "app-tests")` with five suites (AppLaunchPolicyTests, CheckpointScrollbackTailTests, DevelopmentSlotLockTests, IpcServerOwnershipTests, PaneTapeFollowEncodingTests), and AppLaunchPolicyTests uses `@testable import DanTerm`, so app code is covered. The proposed replacement reason is also accurate: app/TerminalBenchmark.swift is wholly inside `#if DANTERM_TERMINAL_BENCHMARK` (line 13), a flag only scripts/terminal-benchmark.sh passes (`-Xswiftc -DDANTERM_TERMINAL_BENCHMARK`), so TerminalBenchmarkObserver is not compiled into DanTermAppTests. The conclusion (TerminalBenchmarkMarkersTests, in lib/TerminalCore, is the only automated cover) survives the reason swap.

### 99. runMatrix carries a stale leftover summary line

**Status:** `done` -- the two contradicting summary lines merged into one

`lib/TerminalCore/Sources/TerminalMemoryProbeSupport/TerminalMemoryProbeSupport.swift:310` -- high confidence, trivial effort, found by `app-harness`

**Problem.** `runMatrix` has two consecutive summary lines: `/// Runs the whole matrix at one geometry.` immediately followed by `/// Runs the matrix, or one named payload of it.` The first predates the `only:` parameter and now contradicts the second, and DocC will render both as one run-on abstract.

**Recommendation.** Delete line 310, keeping the accurate `/// Runs the matrix, or one named payload of it.` as the abstract.

**Verifier (confirmed).** Both lines are present and both attach to runMatrix (TerminalMemoryProbeSupport.swift:310-311, immediately above `/// ///` and the `only` paragraph at 313-315). The first predates the `only:` parameter added at 320 and now contradicts it, and being in the same paragraph DocC renders them as one run-on abstract. Only nit: deleting line 310 outright drops 'at one geometry'; merging to `/// Runs the matrix, or one named payload of it, at one geometry.` keeps that fact, though MemoryProbeReport's own doc ('A full matrix run, with the geometry every payload shares') already carries it, so plain deletion is also fine.

### 100. acceptPendingWork's doc names a nonexistent series and omits the fence-stall one

**Status:** `done` -- all three attributed series named, plus the verifier's bonus about the process-CPU series starting one sample short

`app/TerminalBenchmark.swift:956` -- high confidence, trivial effort, found by `docs-comments`

**Problem.** The doc says the method attributes "planning, and whole-process CPU" and that "both series stay index-aligned with `drawDurations` and all three normalize by the same accepted-draw count." The body (lines 972-986) appends to three series -- `acceptedPlanDurations`, `acceptedFenceStallDurations`, and `acceptedProcessCPUDurations` -- so the fence-stall series it maintains is unmentioned and the "both/all three" arithmetic is off by one. `drawDurations` is not a symbol in the file either; the series is `localizedDrawDurations` (the JSON key is `drawDurationsNanoseconds`).

**Recommendation.** Update the doc to list all three attributed series (plan, fence stall, process CPU) and to name `localizedDrawDurations` instead of `drawDurations`.

**Verifier (confirmed).** Verified: the body (app/TerminalBenchmark.swift:972-986) appends to acceptedPlanDurations, acceptedFenceStallDurations, and acceptedProcessCPUDurations, so "planning, and whole-process CPU" / "both series" / "all three" are each short by one. `drawDurations` is not a symbol; the array is `localizedDrawDurations` (declared :265, appended at :642 and :691, both immediately followed by acceptPendingWork()), emitted as `drawDurationsNanoseconds` at :744. Optional bonus while editing: the process-CPU series is not strictly index-aligned -- the monotonicity guard at :982 drops the first sample -- and each series is normalized by its own count in the JSON (:750, :758), so the "index-aligned / same accepted-draw count" sentence deserves the same pass.

### 101. LogicalLineStore comment cites the pre-rename scrollbackRowContentIdentityShape

**Status:** `done` -- citation renamed to scrollbackRecordContentIdentityShape

`lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift:1221` -- high confidence, trivial effort, found by `docs-comments`

**Problem.** The doc on `recordCells(at:)` says width-free storage "makes `scrollbackRowContentIdentityShape`'s contract literally true once it is re-denominated to the record". The re-denomination already landed and renamed the API: the only such entry point is `Terminal.scrollbackRecordContentIdentityShape(at:)` (Terminal.swift:2074), used by TerminalRetainedRowProbeSupport.swift:507 and TerminalContentIdentityShapeTests. A reader grepping the name in the comment finds nothing.

**Recommendation.** Rename the citation to `scrollbackRecordContentIdentityShape` and drop the now-completed "once it is re-denominated" conditional.

**Verifier (confirmed).** Verified: LogicalLineStore.swift:1221 is the only source occurrence of `scrollbackRowContentIdentityShape`; every other hit is in docs/research (historical record). The live entry point is `Terminal.scrollbackRecordContentIdentityShape(at:)` (Terminal.swift:2074), consumed by TerminalRetainedRowProbeSupport.swift:507 and TerminalContentIdentityShapeTests/TerminalPackedRetainedRowTests. The re-denomination to the record did land (31/D3 Decision 6), so dropping the "once it is re-denominated" conditional is correct too.

### Downgraded (docs and comments)

Real problems, but apply the verifier's adjustment.

### 102. Cross-module dispatch note says TerminalCore is nine SwiftPM targets; it is 23

**Status:** `done` -- dropped the count rather than freezing 23, per the verifier

`docs/design/2026-07-29-cross-module-value-dispatch.md:8` -- high confidence, trivial effort, found by `docs-comments`

**Problem.** The Context opens "`lib/TerminalCore` is not one module. It is nine SwiftPM targets". lib/TerminalCore/Package.swift declares 23 non-test targets (`.target` + `.executableTarget`) plus 15 `.testTarget`s, 38 in total. The adjacent claim in the same sentence -- "every target carries only `.swiftLanguageMode(.v6)`" -- is still true of all 38, so the count is the only wrong part, but it is the number a reader uses to gauge how many boundaries the render path crosses.

**Recommendation.** Change "nine SwiftPM targets" to the current count (23 non-test targets), or drop the number and keep "a package of many targets" so it cannot go stale again.

**Verifier (adjustment required).** The count is stale -- lib/TerminalCore/Package.swift now has 23 non-test targets (15 `.target` + 8 `.executableTarget`) and 15 test targets, 38 total, and all 38 carry only `.swiftLanguageMode(.v6)`, so the adjacent claim does hold. But the recommendation needs the adjustment the finding lists second: drop the number rather than freeze "23". At the ADR's authoring commit (0e5e2e9d, 2026-07-29) the package had 11 targets and exactly 9 *products*, so "nine" was a products count that went stale in a week; a new hard number in a dated, Status:Accepted ADR will go stale just as fast. Prefer "a package of many targets" (or "more than twenty"), leaving the substantive guidance -- no cross-module optimization, annotate hot value surfaces -- untouched.

### 103. Damage-routing ADR's context says the paired benchmark spans five workloads

**Status:** `done` -- dropped the count ("the calibrated workload ladder") rather than renumbering a dated ADR

`docs/design/2026-07-27-damage-render-benchmark-routing.md:9` -- high confidence, trivial effort, found by `docs-comments`

**Problem.** The Context paragraph frames the whole note as "a paired A/B benchmark (`just benchmark-quick` / `just benchmark-confirm`) across five workloads". `VALIDATION.WORKLOADS` (scripts/terminal-benchmark-validation.py:16-23) holds six, `retained-browse` having been given frozen thresholds in both modes. Unlike the doc's dated findings, this sentence describes the instrument as it stands, so it reads as current and is wrong.

**Recommendation.** Change "across five workloads" to "across six workloads" (or drop the count), leaving the D1/D2 findings themselves untouched as the dated record they are.

**Verifier (adjustment required).** The count is stale today (WORKLOADS holds six), but the sentence was accurate when written: at the last commit before 2026-07-28, WORKLOADS was exactly the five named, and retained-browse only entered on 2026-08-03 (415fbd17). docs/design/index.md defines these notes as dated ADRs whose change mechanism is a `Superseded` status, so swapping five->six would make a Status:Accepted, Date:2026-07-27 Context describe a state that did not exist at the decision date, and it will re-stale on the next graduation. Adjusted fix: drop the count ("across the calibrated workload ladder") rather than renumber it, or leave it and rely on the date -- the D1/D2 substance about incremental-mixed is unaffected either way. Low stakes: the guide a reader actually operates from (agent-docs/terminal-performance.md, finding 3) is where the count matters.

## Appendix: rejected findings

Reported by a finder, refuted by its verifier. Kept for the record so the same idea is not re-litigated later.

### 104. selectedColumns/hoveredColumns trap on an inverted range that highlightRuns tolerates

**Status:** `rejected` -- no action (kept for the record)

`lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift:445` -- medium confidence, trivial effort, found by `core-render`

**Problem.** `selectedColumns` (line 445) and `hoveredColumns` (line 434) test row membership by building a `ClosedRange` -- `selection.start.row...selection.end.row ~= streamRow` -- which hits `ClosedRange`'s `lowerBound <= upperBound` precondition and traps (in release too) if the range ever arrives inverted. `highlightRuns`, reading the *same* `terminal.selectionRange`, deliberately tolerates that case with `guard firstRow <= lastRow else { return [] }` (line 256). Two consumers of one value disagree about whether inversion is possible; if it ever is, one silently draws nothing while the other crashes the app mid-frame.

**Recommendation.** Replace both `a...b ~= streamRow` tests with the non-trapping `streamRow >= a && streamRow <= b`, matching `highlightRuns`' tolerance at zero cost.

**Verifier (refuted).** Two problems. (1) The premise about highlightRuns is a misreading: `guard firstRow <= lastRow` (line 256) fires on the ordinary case of a selection that does not intersect the viewport (firstRow/lastRow are the selection clamped to `topRow..<topRow+rows`), not on an inverted selection -- it is not evidence that any consumer treats inversion as possible. (2) Inversion is unreachable. Every writer orders the endpoints: `setSelection(from:to:)` (Terminal.swift:2547), `setSelection(_:)` (2558), `selectAll` (first/last of the projection), `setHoveredLink` (2412), and `restateAnchors` rebuilds reflowed ranges as `TextAnchorRange(start: min(first, last), end: max(first, last))` (4602). The two clamps that edit a live selection (`clampSelectionToRetainedStream` 3809-3818, `handleEviction` 3826-3832) both preserve order, and `publicRange` (3451) only shifts both rows by the same base. Given that, `a...b ~= x` is a cheap assertion of an invariant the engine enforces; swapping it for `>= && <=` would convert a loud failure into a silently wrong frame with no observable benefit.

### 105. Pane launch failure discards the thrown reason

**Status:** `rejected` -- no action (kept for the record)

`app/SwiftTerminalBackend.swift:85` -- high confidence, trivial effort, found by `app-harness`

**Problem.** `createSession` wraps `TerminalPaneSessionController.init` in `do { ... } catch { return nil }`, discarding the error. That initializer throws whatever `TerminalPTYHost.init` throws -- the actual spawn/openpty/bootstrap failure. The caller in AppRuntime.swift:767 turns the nil into `.surfaceCreationFailed(paneId:)`, so a user whose pane will not open leaves no record of why anywhere. The same file already logs the far less important recording-write failure at line 137.

**Recommendation.** Log the caught error before returning nil, matching the existing style in this file: `catch { print("[terminal] pane session creation failed: \(error)"); return nil }`.

**Verifier (refuted).** The central factual claim is wrong. That catch cannot observe a spawn/openpty/bootstrap failure: TerminalPaneSessionController's convenience init (lib/TerminalPTY/.../TerminalPaneSession.swift#init) has exactly one `try`, TerminalPTYHost.init, and TerminalPTYHost declares a single error case -- `TerminalPTYHostError.invalidDimensions`, documented as 'Construction failures caught before any PTY or process ownership exists' and thrown only by the `guard let terminal = Terminal(...)` at TerminalPTYHost.swift#init. The process spawn happens later and asynchronously via start(_:)/submitStart, and its failures travel the launch/session-ended path, not this return-nil. So the caught error carries one bit whose meaning is already fully determined by the call site, and 'a user whose pane will not open leaves no record of why anywhere' does not follow -- a real launch failure never reaches here. Adding the print is harmless and matches the file's style, but with a single-case error and an existing .surfaceCreationFailed signal it buys essentially nothing.

### 106. Shell-integration test hard-fails instead of skipping when fish is absent

**Status:** `rejected` -- no action (kept for the record)

`lib/TerminalPTY/Tests/TerminalPaneSessionTests/TerminalPaneSessionControllerTests.swift:196` -- high confidence, trivial effort, found by `tests-pty-probes`

**Problem.** `let shells = try ["zsh", "bash", "fish"].map { try findExecutable(named: $0) }` resolves each shell through `findExecutable`, which ends in `try #require(...)` (line 1892). zsh and bash ship with macOS; fish does not. On a machine without fish, this gate step fails with an unattributed `#require` failure pointing at a PATH-scanning helper. The sibling gate step `scripts/tests/shell-integration_test.sh` handles the same situation deliberately, with `command -v "$shell" >/dev/null 2>&1 || continue`, and `flake.nix` provisions fish only inside dedicated dev shells.

**Recommendation.** Filter the shell list to those actually on PATH (`["zsh", "bash", "fish"].compactMap { try? findExecutable(named: $0) }`) and `#expect` the list is non-empty, matching how `scripts/tests/shell-integration_test.sh` skips uninstalled shells.

**Verifier (refuted).** Two problems. (1) The recommended fix does not work: findExecutable ends in `try #require(...)`, and Swift Testing records the Issue at evaluation time before throwing, so `try? findExecutable(named:)` swallows the error but still fails the test. A working version would need a plain Optional-returning PATH probe (no #require) or an .enabled(if:) ConditionTrait. (2) The cited precedent is misread: scripts/tests/shell-integration_test.sh has `command -v "$shell" || continue` in exactly one of its four shell loops (the expect-driven one at line 74); the loops at lines 49, 148, and 290 invoke zsh, bash, and fish unconditionally and hard-fail without fish. The gate as a whole therefore already requires fish, so making only the PTY test skip buys nothing and quietly drops a third of the test's intended coverage. flake.nix does provision fish, and fish is installed on this machine (it is the user's login shell), while CI builds only and never runs this step -- so the practical failure mode described does not arise on any machine the gate runs on.

