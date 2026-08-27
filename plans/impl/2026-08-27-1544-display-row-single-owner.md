# Give a display row one owner (audit Wave 6: GRID-4 + GRID-2 + SELECT-3)

## 1. Problem and evidence

A display row in the active stream -- retained history rows followed by live
grid rows -- has no single owner. Three symptoms, all verified against the tree
at `fe5729f6`:

- **The seam rule is hand-written ten times.** "The last retained display row is
  projected against the live grid's first cell and may need the wrap spacer the
  store could not derive (`openTailPendingMarginCell`); when the alternate
  screen is active it gets no follower and its `isSoftWrapped` is forced false."
  Copies in `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`:
  `ProjectionRows.subscript`, `ProjectionRows.forEachRow`, `scrollbackRow(at:)`,
  `rowStructure`, `primaryProjectionRows` + `projectPrimarySeam`,
  `activeProjectionRows`, `presentedRowGeometry`, `projectViewportRow`,
  `projectedViewportCell`, `forEachViewportRow`. Three of them also restate the
  `logicallyContinues && marginProvenance == .wideWrap` disjunct that
  `GridRow.projected` already holds.
- **One reader applies no seam.** `TerminalStateSynchronizationEncoder`
  serializes `history.paintedDisplayRows(in:)` raw in `encodeStateSynchronization`
  and in its `boundedHistoryStart` byte estimator. The replica still comes out
  right, because the writer prints the following wide glyph at the pending
  margin and autowrap recreates the seam -- so this is an eleventh place that
  knows the seam rule by a different route, not a bug.
- **The row is materialized by two identical builders plus a third copy.**
  `LogicalLineStore.paintedRow` and `materializedGridRow` are the same twenty
  lines differing only in `includeFill`, each making two width-sized arrays;
  `pullBackOpenTailRemainder` repeats the build-then-place loop.
- **Two link walks materialize a row per cell.** `activationIdentity` and
  `explicitLink` call `stream[row]` inside per-column loops; for a history row
  each call is a locate plus a full row paint. `explicitLink` also builds a
  coordinates array over the whole soft-wrap chain to do a linear search.

Load-bearing premises (checked): `scrollbackRow(at:)` is public and used by
`TerminalRetainedRowProbeSupport`, so it stays. Two stream-row conventions
coexist (`ProjectionRows` indexes an alternate-screen row at `historyRows + r`;
the viewport path at `r`); the `!alt` guards in history-indexed readers state a
substantive rule, not an index disambiguation. A retained row participates in
two different streams: the **active** stream (history, then the live screen;
severed while the alternate screen is active) and the **primary** stream
(history, then the primary screen, seam preserved even while the alternate
screen is active -- `primaryHistoryText`, `primaryProjectionRows` and the
synchronization encoder read this one).

## 2. Decision

One projector owns how any display row -- retained or live -- is projected
against the cell that follows it: the row-scoped read (a projected `GridRow`),
the cell-scoped read (the margin cell, no row copy) and the kinds-only read.
It is the sole holder of `projectedMarginCell` and the sole reader of
`openTailPendingMarginCell` outside the store. It does not read the terminal's
active-screen flag: it receives its stream context explicitly -- which grid
follows history, and whether the history/grid seam is preserved or severed --
and two factories select that context: the active stream (live screen; severed
while the alternate screen is active) and the primary stream (primary screen;
seam always preserved). Every reader above goes through one of the two; the
sync encoder, `primaryHistoryText` and `primaryProjectionRows` use the primary
stream.

Only history rows have a seam, and both stream-row conventions agree on the
history index, so each caller maps its own convention and the projector never
decides which convention a stream row is in. Both conventions are kept
unchanged.

Underneath, the store has one materializer, `materializedRow(at:includeFill:)`,
built on one `GridRow` builder that appends and places in a single pass; the
open-tail hand-back uses the same builder.

On top, the two link walks fetch a row once per row: `activationIdentity`
hoists the fetch above the column loop; `explicitLink` steps outward from the
click with a row-scoped window, re-fetching only when it crosses a soft-wrap
boundary, and loses the coordinates array.

This is the row value Wave 7 (reflow) extends with fill style, content end and
continuation facts, so the projector is a value type with a per-row facts
result, not a set of free functions.

Order: builder, then projector and its callers, then the link walks. Landing the
link walks first would hoist a call that is about to change shape.

## 3. Invariants

- I1. Exactly one place in `TerminalCore` decides the seam and the
  alternate-screen severance; no reader outside it names
  `openTailPendingMarginCell` or `projectedMarginCell`. Enforced by a lint in
  `just lint` (the store hands the margin across a type boundary, so an access
  level cannot enforce it).
- I2. Every reader of the last retained row agrees on it within its stream.
  Active-stream readers -- `scrollbackRow(at:)`, `selectAll()` text,
  `logicalLineRange`, `cell(row:column:)`, `rowStructure`,
  `presentedRows`/geometry kinds, the frame style-run walk, the search
  projection -- show the same final column and the same `isSoftWrapped`, with
  the alternate screen inactive (spacer present, wrap kept) and active (no
  spacer, wrap severed). Primary-stream readers -- `primaryHistoryText` and the
  state-synchronization encoder -- show the spacer and keep the wrap in both
  cases.
- I3. The painted and content reads of a retained row are unchanged: painted
  carries the trailing fill to the margin, content stops at the line's cells,
  for a wide cluster at the fold boundary, a spilled multi-scalar cell, a
  forced-split seam and a background-erase fill.
- I4. History locates on the frame and geometry paths stay constant in
  retained depth; projection materializes no `GridRow` and adds no
  projection-specific per-row storage on those paths (a structural property,
  checked in review).
- I5. Resolving one hyperlink locates history once per row the link spans; the
  count does not grow with the link's cell length.
- I6. Synchronization behavior is unchanged: the replica of a terminal whose
  open tail has a pending wide margin reproduces the last retained row at full
  width, whether synchronization happens on the primary screen or while the
  alternate screen is active; after the source later leaves the alternate
  screen, replica and source agree.

## 4. Proof obligations

- PO1 (I1): the lint fails on a hand copy of the seam outside the projector
  and passes on the tree.
- PO2 (I2): new test -- print a soft-wrapped line whose tail is a wide cluster
  so the open tail leaves a pending margin, then, alt inactive and alt active:
  cell-bearing readers in I2 agree on the margin cell and `isSoftWrapped`;
  text readers agree on the projected text and on whether the line continues.
  Existing
  pins stay green: `TerminalScrollbackTests.crossBoundarySpacerRepair`,
  `retiredOneRowSeamMarginSurvivesProjectionAndResize`,
  `TerminalAlternateScreenTests.activeAndPrimaryHistoryProjections`,
  `alternateErasesKeepPrimaryHistorysWrapClaim`,
  `TerminalHyperlinkTests.explicitLinkCrossesWideWrapGap`.
- PO3 (I3): `TerminalLogicalLineFoldTests` and
  `TerminalRetainedRowReadPathTests` unchanged and green.
- PO4 (I4, locate clause): `TerminalFrameLocateTests` unchanged and green.
  The no-materialization clause is a review check, not a test.
- PO5 (I5): new test -- two OSC 8 links on retained rows of substantially
  different cell lengths (e.g. 6 and 180 cells); one `activatableLink(at:)` on
  each; `Instrument.displayRowLocate.measure` returns equal, nonzero counts.
  Also a link spanning three soft-wrapped rows with the click on the middle row
  resolves the same range as today.
- PO6 (I6): new pinning tests in `TerminalStateSynchronizationTests`, green
  before and after -- the pending-margin open tail round-trips through the
  encoder with the last retained row `columnCount` wide; and the same source
  synchronized while the alternate screen is active, then exiting it, matches
  the replica under the observable-state comparison the suite already uses.

## 5. Non-goals / Accepted risks / Rejected ideas

- Non-goal: unifying the two stream-row conventions. The audit's own
  correction shows the history-indexed `!alt` guards are a rule, and the
  viewport walk is the hottest read path; the projector centralizes the rule
  without moving the convention.
- Non-goal: `DRAW-7`'s `overlayState` change, though the audit groups it here;
  it lives in `RenderFramePlanner.swift` and lands with the planner wave.
- AR1: `forEachViewportRow` must decide "this is the last retained row" from
  the cursor running out, as it does today, and pass the history index
  explicitly -- computing it from the stream row would let a convention slip
  reach the projector. Risk accepted with PO2 + PO4 as the guard.
- AR2: the frame walk today never re-derives a stored `.spacerHead` at the seam
  while geometry does; routing both through the projector removes that
  divergence, which is a behavior change in the frame walk's favour.
- RI1: extend `projectPrimarySeam` into an index-taking form and call it from
  the ten sites. Removes the copies but keeps the restated `.wideWrap`
  disjunct, the encoder gap, and the per-site `!alt` conjuncts.

## 6. Implementation discretion

- The projector's type name, whether its per-row facts are an enum or a
  struct, and how the encoder reaches it (a `Terminal`-level wrapper is fine).
- Whether the lint is a new script or a case in an existing one.

## Verification

`swift test --package-path lib/TerminalCore` into a file after each slice, plus
`just lint`; `just test` before each commit. Then `just launch-slot`, scroll a
full-screen TUI and a long wrapped `ls` into history, and confirm the last
history row paints its wide glyph at the seam with no missing column.

## Commit progress

- [x] 1. refactor(terminal-core): unify retained row materialization (GRID-4)
- [ ] 2. refactor(terminal-core): centralize display-row projection (GRID-2)
- [ ] 3. perf(terminal-core): make link resolution row-scoped (SELECT-3)

## Implementation notes

- Slice 1: the single-pass builder is `GridRow.append(_:scalars:)` rather than
  a store-private helper, so the resize pull-back and the two folded reads share
  it without a placeholder array. The offset-taking `scalars(recordIndex:record:cellOffset:)`
  overload keeps its other callers and stays.
- Slice 1 bench: no `benchmark-quick` workload exercises the materializing
  reads (the frame path borrows, per `TerminalMemoryCensusTests`). Two
  `scrollback-stream` runs against `14bbccd5` came back `inconclusive` at
  +3.81% and -1.06% -- noise straddling zero, as expected for a workload that
  does not contain the changed cost.
