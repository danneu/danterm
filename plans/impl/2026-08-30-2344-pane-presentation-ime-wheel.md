# The pane presentation value and its three readers

Audit items INPUT-3 (owner) + INPUT-2 + INPUT-4 + SELECT-6, Wave 12 of
docs/scratch/2026-08-26-improvement-audit.md (`## Combine these`: one folded
value, then its three readers). Supersedes
`plans/wip/plan-pane-presentation-value.md` -- delete that file when
implementation starts.

## 1. Context and problem

`SwiftTerminalSessionView` stores the pane's resolved presentation geometry as
four optionals (`currentMetrics`, `currentDimensions`, `currentGridPinned`,
`displayedCellSize`, lines 194-204) that are computed together, assigned
together in `synchronizePresentation` (1585-1620), and never assigned apart.
Nothing in the type says so, so every reader re-establishes the correlation by
hand: multi-clause guards (`presentationGeometryForTesting`,
`benchmarkGeometry`, `normalizedCell(at:)`) and two `?? 0` cell defaults
(`scrollWheel` line 744, `firstRect` line 999) that can only fire in states the
caller already excluded. Three real behaviors sit behind the missing value:

- **IME rect.** `firstRect(forCharacterRange:)` (997-1001) answers with a
  zero-width rect at the pane's top-left corner, so IME candidate windows and
  the Emoji picker open pinned to the corner instead of under the caret. The
  published plan already carries the answer: `publishedFrame` (line 220) holds
  `RenderFramePlan.cursor: RenderCursor?` with `row`, `column`, `columnWidth`,
  and `plan.cursor == nil` means exactly "hidden or scrolled out of view".
- **Horizontal wheel.** The view reads only `scrollingDeltaY` (plus the Shift
  projection case at 1913-1920, the sole `scrollingDeltaX` read in the tree).
  A program with mouse reporting on never receives a horizontal wheel report,
  though the encoder vocabulary (`TerminalMouseWheelDirection.left = 66`,
  `.right = 67`) and a replay producer (`NeutralTerminalRecording`) already
  exist. Ghostty and iTerm2 both report this axis as buttons 6/7.
- **Unclamped IPC wheel.** The IPC producer
  (`terminalWheelEvent(_:column:row:)`, 1075-1089) builds a
  `TerminalWheelEvent` from coordinates that never passed through any grid
  measurement (`IpcRequest.swift#inputCellCoordinate` checks only
  non-negativity), and `wheelDecision` hands them straight to the encoder: a
  CLI wheel at column 100000 under SGR reporting emits
  `ESC [ < 64 ; 100001 ; ... M` to the child.

All claims verified against the tree at c847469e. The audit's vetted
corrections hold: the `?? 0`s are dead or harmless (this is a closed-state-space
refactor, not a live bug), and the pointer path deliberately reports clamped
off-grid cells, so the wheel fix is a clamp, not an insideness gate.

## 2. Decision

D1. **One presentation value, one producer.** The four optionals become one
`private struct PanePresentation` (metrics, dimensions, pinned, displayed cell
box) stored as a single optional, built and assigned only in
`synchronizePresentation`. Every reader binds the whole value once; the two
`?? 0` defaults and the multi-clause guards collapse. The value records
resolved geometry only; the decision to submit a grid to the child stays a
separate step driven by the existing change flags, so CHROME-3 / Wave 14's
model-visibility gate can later sit between "geometry resolved" and "grid
submitted" without reshaping the value. That gate is out of scope here.

D2. **The model's published cursor answers the IME question.** `firstRect`
builds its rect from `publishedFrame?.plan.cursor` and the displayed cell box
-- origin at the caret's cell, width `cellWidth * columnWidth`, height one
cell -- converted to screen (the view is `isFlipped`; AppKit's rect conversion
handles the flip). Only when the view genuinely does not know -- no published
frame, or `plan.cursor == nil` -- does it keep the current placeholder rect.

D3. **The wheel event carries both axes.** `TerminalWheelEvent` gains
`columnDelta: Double` beside `rowDelta`, fed from `scrollingDeltaX` normalized
by the displayed cell *width* exactly as rows are normalized by the height
(mirror `TerminalWheelNormalizer.rows`). Sign convention mirrors the vertical
axis: negative `columnDelta` emits `.left` (66), positive emits `.right` (67),
which matches iTerm2's base mapping (positive `scrollingDeltaX` -> scroll-left)
and the audit's verification. Only the `.mouseReport` route consumes it, via a
second emission loop in `wheelDecision` and a per-axis remainder beside `rows`
in `WheelRemainder`; the `.localViewport` and `.alternateScreen` routes ignore
it (a grid never scrolls sideways, and there is no arrow equivalent). The
Shift projection special case in `verticalScrollDelta` is unchanged. The IPC
wheel producer keeps its vertical-only surface (`columnDelta: 0`).

D4. **No report escapes the grid.** Wheel-report coordinates are clamped
against `terminal.geometry` in one shared wheel-report encoding path that both
`wheelDecision` and the replay entry point `decideTerminalMouseWheelReport`
route through, so no producer -- live, IPC, or recorded -- can encode an
off-grid coordinate. This matches the pointer path, which also reports clamped
cells for off-grid events; suppressing off-grid wheel reports is explicitly
not the rule.

## 3. Invariants

- I1. A pane that knows some of its presentation geometry but not the rest is
  unrepresentable; no reader defaults a cell dimension to zero.
- I2. Re-running presentation sync with unchanged inputs submits no grid and
  emits no state: the metrics-changed / geometry-changed semantics survive the
  fold as two field comparisons against the stored value, computed before the
  assignment -- not one whole-value `!=` (a divider drag must not re-emit per
  frame).
- I3. With a published frame and a visible cursor, the IME rect's origin is
  the caret's cell and its size is that cell's box (width x `columnWidth`);
  otherwise the pre-change fallback rect.
- I4. Under mouse reporting, horizontal wheel motion of one cell width emits
  exactly one 66/67 report at the pointed cell; sub-cell motion accumulates
  per axis, so a vertical trackpad scroll with incidental sideways drift emits
  no horizontal report until a full cell width accrues. With reporting off,
  horizontal motion emits nothing and moves no viewport row.
- I5. Every wheel mouse report's encoded column and row lie inside the
  terminal's grid, whatever the event carried.

## 4. Critical files

- `app/SwiftTerminalSessionView.swift` -- the fold (D1), its readers
  (`state`, `presentationGeometryForTesting`, `benchmarkGeometry`,
  `normalizedCell(at:)`, `scrollWheel`, line-564 rerender guard, line-1741
  metrics read), `firstRect` (D2), the `scrollingDeltaX` feed (D3).
- `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalWheelNormalizer.swift`
  -- the horizontal counterpart of `rows(delta:isPrecise:cellHeight:)`.
- `lib/TerminalCore/Sources/TerminalCore/TerminalInteractionVocabulary.swift`
  -- `TerminalWheelEvent.columnDelta`.
- `lib/TerminalCore/Sources/TerminalCore/TerminalInteractionPolicy.swift` --
  `WheelRemainder` (line 132) gains the column accumulator, `consumeWheelRows`
  gets a column twin (or generalizes), `wheelDecision`'s `.mouseReport` arm
  gains the second loop, and the shared wheel-report encoding path clamps (D4)
  via `terminal.geometry` (`Terminal.swift:5308`).

Reuse: `terminalCell(at:)` and `TerminalViewportCell` stay as-is;
`encodeTerminalMouse(.wheel(...))` already encodes all four directions;
`decideTerminalMouseWheelReport` keeps its signature but routes through the
shared clamped path (D4).

## 5. Proof obligations

- PO1 (I1, I2): the fold changes no behavior -- the existing UI suite
  (`tests-ui/SwiftTerminalSessionViewTests.swift`: presentation-geometry,
  pointer-mapping, and wheel cases, plus the metrics-change state-emission
  case) passes unchanged.
- PO2 (I3): new UI cases (`just test-ui`): cursor at a known cell, assert
  `firstRect` converted back to view coordinates is that cell's box; a second
  case under `CSI ?25l` asserts the fallback rect.
- PO3 (I4): `TerminalInteractionPolicyTests`: with `CSI ?1000h CSI ?1006h`, a
  wheel event with `columnDelta: +1` at (c, r) emits `ESC [ < 67 ; c+1 ; r+1 M`
  and `-1` emits 66; two half-cell samples emit one report; with reporting
  off, no bytes and no viewport motion. Normalizer tests pin the
  cell-width scaling and sign. A UI case (`just test-ui`) synthesizes a
  nonzero-`scrollingDeltaX` wheel event and asserts the forwarded
  `TerminalWheelEvent.columnDelta` -- cell-width normalization and sign --
  so the AppKit wiring cannot silently drop or invert the axis while the
  policy and normalizer tests pass on constructed values.
- PO4 (I5): policy tests: a wheel event carrying out-of-range coordinates
  under SGR reporting encodes a column and row clamped to the grid, proven at
  both producers -- `decideTerminalWheel` and the replay entry point
  `decideTerminalMouseWheelReport`.
- PO5 (D4 premise): a policy case pins the existing pointer behavior the
  clamp-over-gate choice rests on: an off-grid `TerminalViewportCell` under
  mouse reporting emits a report for its clamped coordinates.

## 6. Non-goals / rejected ideas

- **Preedit rendering.** `setMarkedText` stores composition text nothing reads
  back, so CJK composition stays invisible in the grid; D2 places the
  candidate window correctly but does not make composing whole. Separate item
  (audit INPUT-2 correction).
- **Carrying `TerminalViewportCell` in `TerminalWheelEvent`** (SELECT-6's
  original shape). Rejected by the audit's own vetting: the pointer path
  reports clamped off-grid cells too, insideness and `offsetX` would be dead
  fields on the wheel, and D4 closes the real defect.
- **Deleting `.left`/`.right` instead of producing them** (INPUT-4's
  fallback): every reference terminal reports the axis, and the replay path
  already consumes the cases.
- **iTerm2's natural-scrolling swap for horizontal reports** (issue 10881
  quirk): out of scope; the sign convention mirrors the vertical axis.
- **The hidden-pane submit gate** (CHROME-3): a behavior change for background
  programs, decided with the user separately; D1 only leaves room for it.

## 7. Implementation discretion

- Where the horizontal remainder logic lives (a column twin of
  `consumeWheelRows` vs. an axis-generic helper), provided I4's per-axis
  accumulation holds.
- Whether `columnDelta` gets an `= 0` init default or every producer states it.

## 8. Verification

Edit loop: `swift test --package-path lib/TerminalCore --filter Interaction`
and `swift test --package-path lib/TerminalPTY --filter Wheel`, plus
`just lint`. The IME and fold changes: `just test-ui` (needs a WindowServer;
excluded from the gate). Before commit: `just test`. End-to-end check via the
`danterm` CLI on a launch-slot instance: send a wheel input at an absurd column
to a pane running `cat -v` with mouse reporting enabled and confirm the
reported column is clamped; two-finger horizontal scroll over the same pane
emits 66/67 reports, and vertical scrolling in `less -S` emits no horizontal
drift reports.

After implementation lands, tick the four `- [ ]` entries (INPUT-3, INPUT-2,
INPUT-4, SELECT-6) in the audit's `## Plan of work` with the commit hash.

## Commit progress

- [x] 1. refactor(app): unify pane presentation and place IME at the cursor
- [ ] 2. feat(input): report horizontal wheel motion within grid bounds
- [ ] 3. docs(audit): record the completed pane presentation work
