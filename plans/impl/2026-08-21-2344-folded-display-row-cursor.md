# Carry Folded Row State in the Display Cursor

## Problem and desired outcome

`DisplayRowCursor` retains only a record index and a row number. Readers must
therefore derive the same width-dependent row shape again when they paint the
row, determine its wrap state, advance to its successor, or map it back to a
cell address. The borrowed frame read folds each retained row twice; a
materializing read that also asks for wrap state folds it three times. For a
record with wide cells, each fold walks the record, so a forward traversal costs
O(rows * cells).

Make the transient cursor own the fold result for its current row. A forward
traversal must resume the fold from its current row boundary instead of
restarting at the record's first cell, reducing the cost to O(cells + rows)
without changing rendered rows, coordinates, stored history, or public APIs.

## Decision

- Keep `DisplayRowCursor` transient and `Sendable`, but make it opaque and
  non-equatable outside `LogicalLineStore`. Callers cannot construct one from
  raw record and row indices or mistake equality of fold state for identity of
  a display row.
- Carry the fold walk's resumable boundary: the current record and row, the
  current cell range, and the optional spacer source. The spacer source covers
  both an in-record wide head and a follower-record wide head across a forced
  split. Do not carry a total row count.
- Make `locate(displayRow:)` count records as it does today and obtain the
  selected row's shape during the selected record's count. Narrow records and
  width 1 remain arithmetic.
- Derive last-row status from the current range ending at the record's cell
  count. Use that fact for wrap state and trailing fill.
- Make `advance(_:)` derive the next row from the current boundary without
  restarting at the record's first cell. Enter a new record at its first row
  with the existing constant-work boundary probe.
- Make row materialization, borrowed cell reads, kind-only geometry, soft-wrap
  queries, and display-row-to-cell addressing consume the cursor's shape. No
  reader independently re-folds a row already represented by a cursor.
- Convert `allPaintedDisplayRows()` to enter at record 0, row 0 directly and
  then repeatedly advance, so Select All, search, and history export receive
  the same linear traversal bound as the frame path without adding a display-row
  locate.
- Validate a cursor-carried cell range against the record it addresses before
  an unsafe arena read. Validate a spacer source against its own record index
  and cell range, and drop an invalid source to no spacer. A stale cursor may
  name the wrong row, but it must not read outside a retained record's cells.
- Keep durable anchors and search coordinates as absolute display rows or
  record-relative coordinates. No cursor or width-derived state survives a
  store mutation.

## Invariants

- Display cells, styles, semantic marks, soft-wrap flags, fills, spacer
  placement, and coordinate resolution do not change.
- After a record's first row is resolved, no later row in that record re-walks
  its cells from cell zero. Entering a record costs the constant first-row probe,
  and each later row resumes from the prior boundary.
- A forced-split row continues to derive its spacer from the follower record
  when that record owns the deferred wide head.
- Whole-history materialization retains its row count and ordering while using
  the same O(cells + rows) cursor traversal.
- Random indexed reads remain available for callers that need one row rather
  than a traversal.
- The change introduces no persistent cache or invalidation path.

## Proof obligations

- Add an exact task-local instrument for cells traversed by any row-boundary
  walk that starts at a record's first cell, whether the walk is full or stops
  at a requested row. Record one bulk count per walk, with no per-cell or
  per-row task-local lookup.
- Start with a failing CJK frame-work test. A viewport over one long wide-cell
  record must report non-zero work equal to one traversal from that record's
  first cell, independent of how many of its display rows the frame consumes.
  A full or prefix restart in `advance` must make the test fail.
- Prove that one `locate` followed by repeated `advance` produces the same
  painted rows as fresh indexed reads across wide wrap boundaries, empty
  records, a trimmed head, open and closed records, and a forced-split spacer
  sourced from the follower record.
- Prove that whole-history materialization returns the same rows and preserves
  its `retainedRowMaterialization` count and zero `displayRowLocate` count while
  its row-boundary work remains linear for a long CJK record.
- Prove that applying a cursor after its source record has been head-trimmed or
  its follower has been removed by tail truncation cannot take an unsafe cell
  or spacer read beyond the respective records' current retained cells.
- Keep the live-grid fold oracle, resize-anchor tests, frame locate budget,
  retained-row read-path tests, and tail-truncation tests green. Rewrite the
  existing test that constructs two-field cursors so it asserts row addressing
  behavior instead of cursor representation.
- During development, run the focused TerminalCore frame-locate, logical-line
  fold, and logical-line store suites plus `just lint`. Run `just test` before
  committing.
- Compare against the pre-change revision with
  `just benchmark-quick baseline=<revision> workload=retained-browse`. Use this
  ASCII workload only as a common-path cursor-copy regression guard. Accept a
  `faster` or `equivalent` result, escalate `inconclusive` to
  `just benchmark-confirm baseline=<revision>`, and record the continuous
  estimate from a valid confirm-level `inconclusive` result as unresolved below
  the directional threshold rather than rerunning it. Do not ship a `slower`
  result until the regression is removed without weakening the cursor
  invariant; the other three valid verdicts permit this structurally proved
  change to ship.

## Dependencies and boundaries

- STORE-5, HIST-2, and STORE-3 have landed. No prerequisite remains.
- Land HIST-3 before HIST-4. HIST-4 depends on the settled `locate`/`advance`
  contract and will conflict around `truncateTail`.
- Serialize other `LogicalLineStore.swift` work or rebase it after this change.
- Do not include HIST-4's `truncateTail` conversion, add reverse traversal,
  clean up unrelated per-index history loops, widen durable coordinates, or
  change the retained-browse stimulus or its frozen rule.
- Exact cursor field packing and private helper decomposition are implementation
  discretion, provided the cursor is opaque and the invariants above hold.

## Accepted risk

- A cursor applied after store mutation may address the wrong logical row. All
  production consumers are synchronous traversals; bounds validation prevents
  the stale value from becoming an out-of-record arena read without adding a
  persistent generation or invalidation path.
