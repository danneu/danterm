# Scroll the viewport by rotating rows, not by moving them

Source: FEED-1 (absorbing ROW-5) in
`docs/scratch/2026-08-18-construction-audit.md`, verified 2026-08-22 against
`e36bca38`. This is a pivot from the finding's proposal.

## 1. Problem, evidence, premises

`ScreenState.rows` is `[GridRow]` and a row's storage slot is its viewport
row. A line feed at the bottom of a full-height region therefore costs, per
line (`Terminal.moveAndFillRows`, `moveInPlace`, `makeBlankRow`):

- a throwaway `Array` of the evicted rows, built only to be iterated;
- one `GridRow` copy per surviving row (retain + release of a cell buffer);
- one fresh 179-cell allocation for the vacated row, built through a
  per-column closure.

This is the dominant structure of the `terminal-feed` workload, not a
corner: `scrollback-stream` is 25,000 full-region scrolls at 179x66. (The
`incremental-screen-updates` corpus scrolls inside `ESC[2;23r` -- a
sub-region -- and is out of scope, see NG2.)

Premises checked against the tree:

- `screen.rows` is private to `Terminal.swift`. Every reader -- projections,
  resize/reflow, census, state synchronization, alternate-screen swap,
  damage, inspection, wrap severing -- addresses rows by logical viewport
  index, absolute stream row, or value copy; nothing holds a storage slot
  across a scroll, because `[GridRow]` never had one.
- The full-height push scroll is the only scroll on the line-feed path when
  no scroll region is set (`advanceToNextRow`, `scrollUp`); a top-anchored
  partial region (`CSI 1;N r`) pushes to scrollback but is not whole-region.
- History admission (`LogicalLineStore.admit`) copies a row's cells into the
  arena and retains nothing of the `GridRow`. `resizeHeight` already admits
  `screen.rows.prefix(n)` directly and then `removeFirst(n)`; the comment in
  `moveAndFillRows` claiming the prefix must be materialized is wrong.
- The whole `Terminal` value is published to consumers
  (`TerminalPTYFrameState.terminal`, `TerminalPaneSession.cachedTerminal`),
  so after each publish every live cell buffer is shared until the ring has
  turned over. An evicted row's buffer is unique only in the unshared arm or
  after `rowCount` further scrolls.
- `DequeModule` is already a `TerminalCore` dependency (`TerminalSearch`
  uses it). `Deque`'s subscript `_modify` moves the element out and back
  without retain or copy, so `withRowCells` / `readingRowCells` and the
  per-cell store sites keep their uniqueness and allocation profile; a
  `get` copies the row value (one retain/release), which per-cell *read*
  sites that do not hoist the row would pay per cell.
- `Deque` is `Equatable` over logical order and `Sendable` for a `Sendable`
  element, so the synthesized `ScreenState` / `Terminal` conformances hold
  and stay semantic.
- FEED-2 (`26c15e55`) and ROW-4 (`c36da989`) have landed; nothing open
  blocks this.

## 2. Decision

Make the viewport a ring: `ScreenState.rows` becomes `Deque<GridRow>`, and a
whole-viewport scroll that pushes to scrollback admits the evicted prefix to
history, drops it from the head, and appends `amount` blank rows at the
tail. No row moves and no intermediate array. Every other scroll
(sub-region, IL/DL, SD/RI, the stale-prompt deletion) keeps the existing
shift-and-fill path.

Recycling the evicted row's cell buffer (pop, admit, blank in place, append)
is the second half of the ideal and stays on the table as its own
measurement-gated step: it removes the last per-line allocation, but only
in the unshared arm or once the ring has turned over since the last
publish, and it is the only part that adds a correctness obligation (I2
stale content). It lands iff `terminal-feed` reads `faster` over the ring
alone and `scrollback-stream` reads not `slower` (PO4).

Why `Deque` and not a hand-rolled head index or ROW-5's flat `rows *
columns` cell buffer: `Deque` is the repo's prescribed ring
(`AGENTS.md`), it removes the cost the corpora measure, and it keeps a row
a value with its own wrap/provenance/prompt identity. The flat buffer would
also rewrite what a row is across resize/reflow, admission, and the ~100
per-cell sites -- X2 in the audit ordered that work (ROW-2) after this one
for that reason.

Scope: `Terminal.swift` only, plus tests, plus the benchmark record. No
change to any control sequence, projection, damage contract, or history
record. Helpers fed from `screen.rows` on a per-event path
(`ProjectionRows.live`, `primaryScreenRows`, `projectedLiveRows`) must stay
O(1) to construct -- they take the deque or a generic collection, never an
`Array(...)` copy.

## 3. Invariants

- I1. For every byte stream, `viewportText`, `screenText`, `drainDamage()`,
  `stateSynchronization`, `scrollbackRowCount`, and every
  `scrollbackRow(at:)` (cells and `isSoftWrapped`) are identical to the
  pre-change terminal. The rotation is unobservable from outside the engine.
- I2. A row vacated by a scroll is a blank row: every cell is the default
  cell with the background-erase style in force at the scroll and carries no
  hyperlink, and the row carries no wrap claim, no erase provenance, and no
  prompt mark -- whatever it held before eviction, and whether or not a
  published copy of the terminal shares its buffer. A retained copy taken
  before the scroll is unchanged by it.
- I3. Under a full-height region, a line-feed scroll performs no per-row
  move and builds no intermediate row array. With recycling, it also
  allocates nothing when the evicted row's buffer is unique, and when the
  buffer is shared it costs no more than building a blank row and copies no
  stale content.
- I4. Scroll damage, inspection invalidation, wrap-claim severing, and the
  history budget keep their current semantics and ordering relative to the
  row mutation; the admission of `amount > 1` rows in one scroll reaches
  history in the same order and with the same wrap flags as today.
- I5. Resize/reflow, the alternate-screen swap, the memory census, and the
  projections see the same rows in the same order as before; the census's
  `rowStorageAllocationCount` stays one per live row per retained screen.

## 4. Proof obligations

- PO1 (I1, I5): a scripted stream on a `labeledTerminal` that mixes
  full-region LF scrolls, a DECSTBM sub-region `SU`, `DECSTBM` reset, IL/DL,
  `SU n` with `1 < n < rows`, `SD`, `RI` at the top, a resize up and back
  down, an alternate-screen round trip with a scroll inside, and a final
  `SU` larger than the height; after each step `displayedRows(of:)` and
  `expectValidGrid`, and at the end `drainDamage()`,
  `stateSynchronization` bytes, and `scrollbackRow(at:)` wrap flags, all
  pinned as literals from the current tree before the change.
- PO2 (I2): the *top* row -- the one a whole-viewport scroll evicts, and
  whose buffer recycling reuses -- holds SGR-styled text, an OSC 8 link, a
  wide pair wrapping at the margin (soft-wrap claim with wide-wrap
  provenance), and an OSC 133 prompt mark. One whole-viewport LF scroll
  under a BCE background evicts it; afterwards every column of the new
  bottom row is a default cell in the BCE style with no link, and
  `rowStructure` / `semanticPromptRowsForTesting` show no claim or mark on
  it. Run twice: plain (evicted buffer unique), and with a copy of the
  terminal held across the scroll (evicted buffer shared), asserting the
  copy is unchanged in both its content and its marks. When recycling
  lands, both arms must be shown to fail against a deliberately incomplete
  blank.
- PO3 (I4): whole-viewport `SU n`, `1 < n < rows`, with a soft-wrapped pair
  straddling the cut -- history order, admitted `isSoftWrapped` flags, and
  `fullHistoryText` as today; `SU 2` followed by LF in one drain composes to
  one shift of `-3` plus the vacated strip and cursor rows (extends
  `TerminalShiftDamageTests`).
- PO4 (I3): `just benchmark-quick baseline=<pre-change sha>
  workload=terminal-feed`, then `benchmark-confirm`, recorded inline in the
  commit message (mode, workload, both tree identities, median symmetric
  estimate, classification). The type change alone must read not `slower`
  on `terminal-feed`, `content-churn`, and `retained-browse` (the AR1
  controls -- `content-churn` is the one that walks live rows through the
  `Deque` subscript per frame, which `retained-browse` reaches only at the
  seam); the ring must read `faster`; recycling lands only if it reads
  `faster` over the ring. Both the ring step and the recycling step
  additionally require `scrollback-stream` to read not `slower` at
  `benchmark-confirm` before they land: `terminal-feed` runs an unshared
  headless `Terminal`, so it cannot see the published-copy sharing this
  change depends on, and `scrollback-stream` is the only workload that
  drives the real PTY publish path. Read each verdict against its own A/A
  floor (`agent-docs/terminal-performance.md`): `terminal-feed` 0.9 points,
  `content-churn` 1.0, `retained-browse` 0.3 with the arm slot fixed and
  0.9 across slots, `scrollback-stream` 3.5. A `scrollback-stream` `slower`
  inside its 3.5-point floor is noise, not a gate failure -- re-run
  `benchmark-confirm` and record both readings.
  `TerminalWiredHistoryAttributionProbe` (env-gated, release) gives the
  published-vs-unshared split the quick ladder cannot.
- PO5 (I1, I4, I5): `TerminalScrollbackTests`, `TerminalRegionScrollbackTests`,
  `TerminalScrollbackBudgetTests`, `TerminalEditingTests`,
  `TerminalScrollRegionTests`, `TerminalResizeTests`,
  `TerminalAlternateScreenTests`, `TerminalShiftDamageTests`,
  `TerminalDamageTests`, `TerminalMemoryCensusTests`, `TerminalFixtureTests`
  pass unchanged; `just terminal-memory-probe --payload scrollback-plain`
  census equals the pre-change census.
- PO6 (I4): a whole-viewport scrollback push (full-height LF and `SU n`)
  with a live selection and an active search, one case intersecting the
  evicted row and one disjoint from it, asserting the surviving selection
  range and search outcome. The two cases differ today and must keep
  differing: `advanceToNextRow` scrolls with `invalidatesInspection: false`,
  so the LF case pins no invalidation while `SU n` pins the whole-range one.
  `TerminalInspectionInvalidationTests`' `rowMutationMatrix` only drives
  sub-region row rotations, so nothing today exercises inspection
  invalidation through the new branch.

## 5. Non-goals / accepted risks / rejected ideas

- NG1. Changing what a sub-region scroll, IL/DL, SD/RI, or resize costs.
- NG2. The `incremental-screen-updates` sub-region scroll (`ESC[2;23r`) and
  the top-anchored partial region (`CSI 1;N r`) still shift rows per cycle.
  A per-region ring or the flat buffer would change that; both are out of
  scope (RI2).
- NG3. Changing `GridCell`, `GridRow`, history records, or any projection
  type.
- AR1. Through `Deque` every row access crosses a module boundary on a
  generic type, and a subscript read copies the row value where `Array`
  projected an address. swift-collections marks the surface `@inlinable`
  and the hot paths already hoist the row once per run, so the expected
  movement on non-scroll workloads is null; PO4's controls on the type
  change alone are the check, and
  `docs/design/2026-07-29-cross-module-value-dispatch.md` is the protocol
  if they move.
- AR2. In the published arm the evicted row's buffer is shared until the
  ring has turned over since the last publish, so recycling saves the
  per-line allocation only for lines beyond `rowCount` per frame. The row
  moves and the intermediate array disappear in both arms.
- RI1. The finding's hand-rolled head index over `[GridRow]` plus
  `slot(for:)`. Re-implements what `Deque` provides and pushes an index
  translation into every `screen.rows` site.
- RI2. ROW-5's contiguous `rows * columns` cell buffer. Rewrites the row
  type across resize/reflow, admission and the per-cell sites; ordered
  after this work by X2, and its payoff is unmeasured.
- RI3. The finding's cheaper fallback (keep the array, drop the two
  allocations). Keeps the O(region) row moves the corpora pay for. Its free
  half -- build the blank row without a per-column closure -- was tested only
  with recycling, whose performance gate rejected it; it does not land.

## 6. Implementation discretion

- How the evicted row is blanked under recycling so that it copies no stale
  content when shared and allocates nothing when unique.
- Whether the `[GridRow]`-typed helpers take `Deque<GridRow>` or a generic
  random-access collection, and where the array-built rows of resize/reflow
  and screen creation convert to the deque.

## Files

- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` -- the whole
  change; nothing outside it moves.
- `lib/TerminalCore/Tests/TerminalCoreTests/` -- new viewport-rotation
  suite (PO1, PO2, PO3); `TerminalInspectionInvalidationTests` (PO6);
  existing suites in PO5.
- `docs/scratch/2026-08-18-construction-audit.md` -- tick FEED-1 in a
  `docs(audit):` commit after the work lands.

## Verification

- TDD: pin PO1's literals and write PO2/PO3 on the current tree first; they
  pass before the change (characterization) and must keep passing after
  each step. PO2's incomplete-blank fail-first check happens when recycling
  is implemented.
- `swift test --package-path lib/TerminalCore --filter <suite>` into a log
  per edit; `just lint`; `just test` before each commit.
- PO4's benchmark pairs against the previous step's commit, recorded in
  each commit message.

## Commit progress

- [x] 1. test(terminal): pin viewport scroll behavior before the ring
- [x] 2. refactor(terminal): hold the viewport in a Deque
- [x] 3. perf(terminal): rotate the viewport instead of moving rows
- [x] 4. docs(perf): record rejected row recycling
- [ ] 5. docs(audit): mark FEED-1 done

## Implementation notes

- Commit 2's first confirm exposed an eager live-head read on retained-only frame planning.
  Defer that read to the history/live seam and derive `scrollProjection` from the terminal's
  scalar `rowCount`, so a parked history viewport does not pay for the Deque representation.
- Commit 4 tested row-buffer recycling and rejected it at PO4's prescribed gate. Against
  baseline commit `ed9a7f5fc0888014301f2bec8258481e53e949c2`, tree
  `609da028a216f1257bd71618c8c4be16decd7024`, candidate tree
  `a8f5a91760cd6984f4b0b13c10ee7dc1b4efc59d`, quick `terminal-feed` was
  `equivalent` at -0.43%; confirm `terminal-feed` was `equivalent` at -0.70% and
  `scrollback-stream` was `faster` at -3.89%, while its descriptive drain was flat
  (54.85 ms baseline, 55.03 ms candidate). Correctness, the full gate, and the exact census
  passed, but the best-case unshared boundary had no measurable gain, so no recycling code lands.
