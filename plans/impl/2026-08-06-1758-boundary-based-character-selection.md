# Boundary-based character selection

Repo: `~/Code/danterm-terminal-engine`

## Context

Click-and-drag cannot select a single cell or character. Two properties of
the current pointer path cause it, and they compound:

- Pointer position is quantized to an integer grid cell before it reaches
  interaction policy. `terminalCell` floors the point into a column and
  discards the remainder, and the pointer event cases carry only
  `column`/`row`. Sub-cell position is destroyed at the app boundary, so no
  policy can act on it.
  (`lib/TerminalCore/Sources/TerminalCore/TerminalInteractionPolicy.swift`)
- A character drag selection is the union of the whole-cell range under the
  press and the whole-cell range under the pointer. Union always includes
  both endpoint cells, so the smallest reachable drag selection is two
  cells, and a drag that stays inside one cell selects nothing. A
  `hasExtended` latch exists only to stop a plain press from selecting a
  character, which the union model would otherwise do immediately.

Desired outcome: a short drag inside a single cell selects that one
character, selection grows and shrinks smoothly in both directions, and a
press that does not move still selects nothing.

Load-bearing premise: the range model is already boundary-based, so this is
a simplification rather than an added mechanism. `TerminalTextRange` is
half-open (`start` included, `end` excluded) and `characterRange(at:)` is
built from the anchors before and after a cell — it already returns the two
boundaries surrounding a character. (`.../TerminalCore/Terminal.swift`)

## Decision

Define a character drag selection as the ordered pair of two character
boundaries: the boundary nearest the press point and the boundary nearest
the current pointer point. Ordering two boundaries is min/max, so direction
is symmetric by construction and no separate reverse-drag branch exists.
When the two boundaries coincide, the arm clears the selection outright
rather than setting an empty range. An empty *present* selection is a
distinct, deliberately-used state in this codebase — `selectAll` mints one
on a blank buffer specifically to keep Copy enabled — so it is not a way to
say "nothing is selected". Because the coincident case is expressible
directly as the absent selection, the `hasExtended` latch is deleted rather
than replaced.

This requires one interface change: the sub-cell horizontal offset must
survive point normalization and reach interaction policy alongside the
column and row. That offset is additive; the column and row it accompanies
keep their present meaning and values.

The offset is part of a pointer transition, not a detail of the live input
path, so it must survive every boundary a pointer transition crosses. That
includes neutral recording — capture, encoding, decoding, and replay —
which reconstructs pointer events from column and row alone today and
replays them through the same interaction policy.

Scope is character granularity only. Token and line granularity keep their
current union-based extension, which is already correct for symmetric
word and line units.

## Invariants

- **I1** A pointer position resolves to a character boundary, never to a
  position inside a character.
- **I2** The boundary chosen is the one nearer the pointer, measured across
  the full width of the character under it, with the midpoint biased toward
  the following boundary. A double-width character therefore snaps at its
  visual center, not at the center of either of its cells.
- **I2a** Horizontal position is clamped together with the column, as one
  value. A point at or left of the grid resolves to the leading boundary of
  the first column, and a point at or right of the grid resolves to the
  trailing boundary of the last column. A drag that leaves the grid
  therefore selects out to the edge it left through, and never snaps back
  across the pointer.
- **I3** A character drag selection is the ordered, half-open range between
  the press boundary and the current boundary. Consequently a drag from one
  side of a character's midpoint to the other selects exactly that
  character, and moving the pointer back toward the press point shrinks the
  selection.
- **I4** When the two boundaries coincide, the terminal is left with *no
  selection present* — not a present selection that happens to be empty.
  A press that never crosses a midpoint therefore leaves Copy disabled and
  the clipboard untouched, at press and on every subsequent move, and this
  remains true when rows are evicted beneath a held pointer.
- **I5** The anchored end of a held drag keeps naming the text it was placed
  on across eviction, scrolling, and repaints, and a held drag still stops
  when the text it anchors to stops existing. This is existing behavior and
  must be preserved, not re-derived.
- **I6** Token and line drag selection behavior is unchanged.
- **I7** Every non-selection pointer arm — mouse reporting, link activation
  and hover, wheel routing, pane menu — sees the same column and row it sees
  today, and is unaffected by the added offset.
- **I8** A captured pointer transition replays to the same local selection
  it produced live. Recorded position therefore carries the same horizontal
  information the live path acts on.
- **I9** A recording that predates the offset still decodes and replays;
  absent position information decodes to the leading edge of its cell.

## Proof obligations

Interaction policy is a pure function over a `Terminal` value, so each of
these is provable as a unit test against it. Existing tests in
`lib/TerminalCore/Tests/TerminalCoreTests/TerminalInteractionPolicyTests.swift`
already cover I5, I6, and I7 and should keep passing unmodified.

- **PO1** (I1, I2) Boundary resolution across a double-width character:
  positions on both sides of the character's visual center, in both of its
  cells, resolve to the character's outer boundaries and never between them.
  The existing wide-cell fixture in that file supplies the case.
- **PO2** (I3) A drag confined to a single cell that crosses the midpoint
  selects exactly that character; the resulting range's text is the
  character.
- **PO3** (I3) A drag reversed back across the press point yields a
  selection on the other side of it, and one shortened toward the press
  point yields a shorter selection. This must hold across a soft-wrapped row
  boundary as well as within a row: the trailing boundary of a row's last
  column and the leading boundary of the next row's first column name the
  same visual position, so extending, reversing, and shrinking across a wrap
  must each select the text a reader would expect, asserted as text.
- **PO4** (I4) A press with no crossing, and every move that follows it,
  leaves no selection present — asserted as the absence of a selection, not
  as empty selected text, which is satisfied by the very state this
  obligation exists to exclude. Holds including when rows are evicted while
  the pointer is held.
- **PO5** (I5) Existing anchor-survival coverage still holds under the new
  boundary anchor.
- **PO6** (I2a, I7) Point normalization still yields the same column and row
  for the same point, including its degenerate-geometry rejection, and
  clamps horizontal position together with the column so an off-grid point
  resolves to the boundary on the side it left through.
- **PO7** (I8, I9) A recorded character drag whose two endpoints sit on
  opposite sides of one midpoint round-trips through encoding and decoding
  and replays to the same selected text; a recording without the offset
  decodes and replays without error.

Beyond the unit tests, the change is only real if the gesture feels right,
so it needs a manual pass in the app: drag-select a single character, a
partial word, and a selection extended and then shortened, in both
directions and across a wrapped line.

## Non-goals

- Rectangular / block selection.
- Shift-click to extend an existing selection.
- Any change to double-click and triple-click selection, or to their drag
  extension.
- Any change to copy-on-select, clipboard behavior, or selection rendering.

## Accepted risks

- **AR1** The character-granularity policy tests encode the current
  whole-cell union semantics, and several will need new expected ranges.
  Risk: a test rewritten to match whatever the new code emits proves
  nothing. Mitigation: each rewritten expectation must state the intended
  gesture in terms of pointer offsets and assert the selected *text*, which
  several of these tests already do; a test that merely recompiles is not
  evidence.
- **AR2** Selection expectations may also appear outside the policy test
  file. Any such test must be evaluated against the invariants above rather
  than adjusted to pass.
- **AR3** Recordings captured before this change cannot reproduce a
  character drag's sub-cell intent — the information was never captured.
  They decode and replay (I9), but their character-granularity selections
  may differ from what was originally seen. Rationale: recordings are
  regression fixtures, re-capturable at will, and no alternative default
  recovers information that was never recorded.

## Rejected ideas

- **RI1** Keeping whole-cell coordinates and special-casing the
  single-cell drag. It restores the missing gesture without fixing the
  cause, leaves the two-cell minimum everywhere else, and keeps the
  `hasExtended` latch alive.
- **RI2** Making the midpoint threshold configurable. It is a
  caret-placement rule, not a preference; a constant is sufficient and the
  configuration surface would outlive any benefit.

## Critical files

- `lib/TerminalCore/Sources/TerminalCore/TerminalInteractionPolicy.swift` —
  point normalization, pointer event cases, and the character branches of
  press and drag handling. The bulk of the change, and net smaller than what
  it replaces.
- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` — reuse
  `characterRange(at:)`, `pinnedRange`, and `resolvedRange` as they are; the
  press anchor should keep pinning a real non-empty character range so the
  existing eviction and epoch rules continue to apply unchanged (I5).
- `app/SwiftTerminalSessionView.swift` — pass the offset through the
  existing pointer forwarding. No other view change.
- `lib/TerminalCore/Sources/TerminalCoreRecording/NeutralTerminalRecording.swift`
  and the pane-session capture that feeds it — the recorded mouse event, its
  encoded schema, and the replay path that rebuilds pointer events from it.
  Changing the recorded event's shape forces exhaustive updates at its
  construction and consumption sites; expect the compiler to enumerate them.
- `lib/TerminalCore/Tests/TerminalCoreTests/TerminalInteractionPolicyTests.swift`
  — the proof obligations, and the rewrites described in AR1.

The single consumer of the selection decision (`TerminalPTYHost`) applies
whatever range it is handed and needs no change.

## Implementation discretion

- How the sub-cell offset is carried from point normalization into the
  pointer event cases, including whether existing call sites get a default.
- Whether boundary resolution lives in interaction policy or beside the
  existing range helpers on `Terminal`.

## Verification

- `swift test` for the `TerminalCore` package — the proof obligations above
  plus the untouched existing suite. Run the recording and pane-session
  suites too; the recorded event's shape changes.
- Build and run the app, then perform the manual gesture pass named under
  the proof obligations. This is the acceptance test: the reported symptom
  is a feel problem, and only the running app settles it.

## Implementation notes

- The offset rides on `TerminalViewportCell` rather than a new normalized-point
  type, so `terminalCell(at:)` stays the single normalization seam I2a asks for.
  `paneMenuCell` reuses that type and simply never reads the offset.
- `offsetX` was added to `.down` and `.move` only. Release re-resolves no
  boundary, so carrying it on `.up` would have been an unread field on the
  recorded event and at every construction site.
- The press anchor still pins the whole character range, as the plan directed,
  plus one bit naming which of its two boundaries the gesture holds. The press
  boundary is re-derived from the resolved range on every move, so eviction
  clamping and epoch retirement reach it without a second rule (I5).
- A soft-wrap seam has two spellings -- past a wrapped row's last column, and
  before its continuation's first -- for one visual position. `canonicalBoundary`
  collapses them onto the second, which is what makes the I4 equality test exact
  across a wrap rather than only within a row.
- `TerminalWezTermAdaptedTests.characterDragSnapsWideCellsAndClampsOutOfBounds`
  fell under AR2. Its cluster-atomicity and off-grid-safety claims survive
  unchanged; its whole-cell union expectations were restated as boundary pairs.
  One upstream divergence became a convergence: DanTerm now also drops the emoji
  when the drag starts on its second column, though by the whole-character
  midpoint rule rather than WezTerm's per-cell one.

## Follow Up

- The manual gesture pass under **Verification** is unperformed: an agent cannot
  drive real pointer input. A dev build is running in slot 1. Drag-select a
  single character, a partial word, and a selection extended then shortened, in
  both directions and across a wrapped line.
- `docs/research/21-selection-gesture-cost.md` measured per-move selection cost
  against the union model. The character arm now resolves two boundaries instead
  of one range per move; all the added calls are O(1) over the lazy projection,
  but the probe's numbers predate the change and were not re-run.
