# Milestone 6 slice 7: SGR mouse reporting and native selection/copy interaction

## Context

[plan-terminal-engine/08-input-interaction.md](../../plan-terminal-engine/08-input-interaction.md)
fixes the mouse contract: the engine supports local text selection and SGR
mouse reporting; when an application has captured mouse input, Shift-drag
bypasses reporting and creates a local selection; an unmodified wheel goes to
the application while Shift-wheel forces local history navigation and emits no
mouse-report bytes; the native scrollbar is always local; copy-on-select is
out and explicit copy uses the current selection. Standing invariants: "Local
selection never emits mouse-report bytes to the child application",
"Mouse-report capture and its Shift override cannot both consume one wheel or
drag gesture", and "Identical normalized input and terminal modes produce
identical encoded bytes or local actions". The proof obligation reads: "Mouse
tracking modes receive correct press, release, motion, and wheel events, while
Shift-drag selects and Shift-wheel scrolls history locally."
[plan-terminal-engine/03-engine-architecture.md](../../plan-terminal-engine/03-engine-architecture.md)
(boundary table, Mouse row) places the report-vs-select decision in
deterministic policy outside the framework calls that receive events.

Slice-map note: the roadmap shows Milestone 6 slices 1-6 complete. Slice 6
([plans/impl/2026-07-20-2150-mode-aware-terminal-input.md](../impl/2026-07-20-2150-mode-aware-terminal-input.md))
kept "mouse reporting in any form" as a separate Milestone 6 slice (its first
non-goal) and left alternate-scroll mode 1007 deferred. This slice is that
mouse slice; it also completes the interaction story for the selection state
slice 4 built
([plans/impl/2026-07-20-1440-selection-search-logical-projection.md](../impl/2026-07-20-1440-selection-search-logical-projection.md))
and discharges the Shift-wheel/capture wheel routing slice 5 deferred
([plans/impl/2026-07-20-1659-local-viewport-navigation.md](../impl/2026-07-20-1659-local-viewport-navigation.md)).

Verified premises (against the working tree):

- `Terminal` has no mouse state anywhere: `applyDECPrivateModes`
  (lib/TerminalCore/Sources/TerminalCore/Terminal.swift:1916-1972) handles 1,
  6, 7, 25, 1004, 2004, 2026, 1047/1048/1049 only; `decPrivateModeStatus`
  (Terminal.swift:1859-1880) answers 0 for the whole mouse family;
  `resetControlState` (Terminal.swift:2491-2509) is the single mode-reset
  choke point; `inputModes` (Terminal.swift:311-320) projects all
  input-affecting modes into `TerminalInputModes`
  (TerminalInputEncoding.swift:4-37), and `encodeTerminalFocus`
  (TerminalInputEncoding.swift:113-117) is the pure mode-gated encoder
  pattern.
- Selection is already core state in current-stream coordinates:
  `TerminalTextPosition`/`TerminalTextRange` (Terminal.swift:4-31),
  `selectionRange` (567), `selectedText` (572), `setSelection(from:to:)`
  (583-594, clamps and orders endpoints), `clearSelection()` (597).
  `scrollProjection.topRow` (452-479) is in current-stream rows, so
  `topRow + viewportRow` maps a displayed cell to a selection endpoint.
- `TerminalPTYHost` is the serialized owner
  (lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift:66, FIFO
  `unownedExecutor` 123-125; nonisolated enqueue -> `assumeIsolated` apply,
  e.g. `sendKey` 192 -> `applyKey` 408-415). `applyWheel` (385-406) routes
  alt-screen arrows vs local scroll, but `TerminalWheelIntent` (26-33)
  carries only `rowDelta` -- no pointer cell, no modifiers. `applyKey` and
  `applyPaste` snap the viewport to bottom; `applyFocus` does not. Test
  evidence via `inputWrites()` (325); capture via
  `TerminalPTYAppliedTransition` (14-23), mirrored into
  `NeutralTerminalRecordingEvent` by `TerminalPaneSession.consume`
  (TerminalPaneSession.swift:274-312).
- `planIfNeeded` (TerminalPaneSession.swift:332-346) replans whenever the
  consumed `Terminal` value changes and emits through `onPlan` -- the
  existing live-feedback loop a host-side selection mutation rides for drag
  highlighting.
- Rendering: `RenderFramePlan`
  (lib/TerminalCore/Sources/TerminalRenderPlanning/TerminalRenderPlanning.swift:102-141)
  has columns/rows/defaultBackground/backgroundRuns/textRuns/decorationRuns/
  cursor and no selection field; `drawRenderFrame`
  (TerminalRenderExecution.swift:144) paints backgroundRuns, then textRuns,
  then decorationRuns.
- Fixtures: `NeutralTerminalRecordingEvent`
  (lib/TerminalCore/Sources/TerminalCoreRecording/NeutralTerminalRecording.swift:138-146)
  covers feed/input/paste/focus/resize/viewport/checkpoint; the fixture
  runner (lib/TerminalCore/Tests/TerminalCoreTests/TerminalFixtureTests.swift)
  accumulates encoder output into `inputBytes` per event and asserts it at
  checkpoints; the manifest test pins commit
  `934bc2fbf21800ac3458a499df8820ca5fb45fd3` and a hard-coded
  `expectedCases` table currently covering 33 files with no
  `t/17state_mouse.test` entry (its title says "thirty-three" while an
  inline comment still says "thirty-two" -- pre-existing drift this slice
  fixes in passing).
- `references/libvterm/t/17state_mouse.test` covers DECRQM off/on for
  1000/1002/1003/1005/1006/1015, X10 press/release/Ctrl/buttons/position/
  wheel 4-7, drag-mode motion with idempotent-cell suppression, any-motion,
  X10 byte clamping at 0xff, SGR press `\e[<0;301;301M` and release `...m`,
  disabled-reports-nothing, and multi-mode `\e[?1002;1006h`.
  `references/libvterm/src/mouse.c:55-100` updates position/button state
  *before* gating on mode flags (the disabled-then-enabled fixture case
  depends on this); `references/libvterm/src/state.c:821-846` pins DECSET of
  any of 1000/1002/1003 replacing the single tracking mode, DECRST of any of
  the three disabling tracking entirely, and 1005/1006/1015 toggling one
  shared encoding protocol; DECRQM (905-929) answers 1 only on exact match.
- View: `app/SwiftTerminalSessionView.swift` has no mouse handlers at all;
  `isFlipped` is true (51); cell metrics come from `currentMetrics.cellSize`;
  `scrollWheel` (125-133) collapses the event to rows, discarding position
  and modifiers; `hasSelection` is hardcoded false (49) and `copySelection()`
  is an empty stub (276). `PaneWrapperView.swift:436-437` enables the Copy
  menu item from `terminalSession.hasSelection` and 477-478 calls
  `copySelection()`; the `TerminalSession` protocol
  (app/TerminalBackend.swift:62-94) already requires both.
- UI harness: `tests-ui/SwiftTerminalSessionViewTests.swift` synthesizes
  wheel and key events but no mouse events; the shim controller
  (`tests-ui/SwiftTerminalSessionViewTestShim.swift`) records forwarded
  intents; new suites register in both `tests-ui/PaneSplitViewTests.swift`
  `main()` and `test-ui.sh`'s hand-listed file set.

User-settled toggles: tracking modes 1000/1002/1003 with legacy X10 default
encoding plus SGR 1006; 1005/1015/1016 out; owner-side atomic decisions on
the host FIFO; Shift-drag and Shift-wheel force local; double- and
triple-click word/line selection included; minimal selection highlight
through the render plan; copySelection/hasSelection wired; `17state_mouse`
adapted; OSC 52, OSC 8, copy-on-select, cursor blinking, and mode 1007 out.

## Decision

Scope: mouse tracking and SGR-encoding mode state in the core, a pure
mouse-report encoder with explicit tracker state, a normalized pointer-event
vocabulary decided owner-side, host routing for pointer and extended wheel
intents, core word/line range queries, a selection layer in the render plan
and executor, AppKit mouse handling with point-to-cell normalization,
copy/hasSelection wiring, the adapted `17state_mouse` fixture family, and
capture/replay coverage. Nothing else.

- **D1. Mouse modes are core `Terminal` state with libvterm's exclusivity
  semantics.** One tracking-mode field (off / click 1000 / drag 1002 /
  any-motion 1003) and one SGR-encoding flag (1006). DECSET of any of
  1000/1002/1003 replaces the tracking mode; DECRST of any of the three
  disables tracking entirely; 1006 toggles independently (which is what
  makes `\e[?1002;1006h` in one sequence work). DECRQM answers 1 for the
  exactly active tracking mode, 2 for the other two, 1/2 for 1006, and
  keeps answering 0 (not recognized) for 1005, 1015, and 1016 -- DanTerm
  does not implement those and will not claim reset state for them
  (recorded deviation, D11). `resetControlState()` restores defaults (RIS
  and DECSTR); the modes persist across 1047/1049 screen switches.
  `TerminalInputModes` gains the tracking mode and SGR flag.
- **D2. Pure mouse-report encoding with explicit tracker state; the tracker
  lives host-side, not in `Terminal`.** A TerminalCore value holds the
  pressed-button set and last-observed cell; a mutating encode step --
  semantically `(state, event, modes) -> (state', bytes)` -- implements the
  pinned libvterm `mouse.c` wire format: press/release codes 0-2 for
  left/middle/right; wheel up/down/left/right as codes 64-67, press-only;
  motion adds 32 and carries the lowest held button, or 3 with no button
  (emitted only under 1003); modifier bits shift 4 / alt 8 / ctrl 16; X10
  emits `ESC [ M` plus code+0x20, col+0x21, row+0x21 each clamped to 0xff,
  release code 3; SGR emits `ESC [ < code ; col+1 ; row+1` with final
  `M`/`m`, preserving the button code on release. Suppression is part of
  the encoder: same-cell motion emits nothing; redundant press/release of
  buttons 1-3 emits nothing; drag mode (1002) emits motion only while a
  button is held. The tracker updates position and button state on every
  event *even when tracking is off or the event is suppressed* -- emission
  alone is gated -- matching `mouse.c` and required by the fixture's
  disabled-section-then-enable case. Coordinates pass through unclamped
  except at the X10 byte level (grid clamping is the view normalizer's
  job). The tracker sits beside the host's `Terminal`, not inside it,
  because it describes host-input history rather than child-visible screen
  state; the fixture runner and recording replay each own a local tracker,
  so all three consumers share identical behavior.
- **D3. One normalized pointer-event vocabulary, normalized in the view,
  decided by the owner.** The event carries: action (down / up / move),
  button (left / middle / right / none), viewport cell (0-based column and
  row), `TerminalKeyModifiers`, and click count on down. AppKit drag
  variants normalize to `move`; drag-vs-hover is derived from tracker
  button state (report arm) or host drag state (selection arm), so the
  vocabulary needs no separate drag action. The view translates AppKit's
  mouse callbacks into this vocabulary, floors and clamps positions into the
  current grid, and forwards every event through the controller to the host
  with no local routing decision. Wheel keeps its own path: the view sends
  normalized fractional vertical motion with its pointer cell, modifiers, and
  gesture boundaries. One physical gesture includes its direct scrolling and
  any following momentum; phase-less wheel ticks are standalone gestures. Row
  quantization happens only after the owner chooses the route (D6).
- **D4. The owner decides report-vs-selection atomically via a pure policy
  shared with fixtures and replay.** On the host FIFO, one deterministic
  decision runs against (event, authoritative `terminal.inputModes`,
  tracker, gesture ownership): at button-down, (1) Shift chooses the local
  arm; (2) otherwise active tracking chooses the report arm; (3) otherwise
  left chooses local selection and right chooses a pending local pane-menu
  action; uncaptured middle does nothing. That choice is latched until the
  matching button-up, so modifier or mode changes cannot split one drag
  between local and report consumers. An uncaptured right-click releases its
  gesture ownership on that up and only then returns the pane-menu action.
  Control-click is normalized through the same down/up owner decision as a
  right click: uncaptured opens the pane menu after up, while captured reports
  only.
  The decision and local-action computation are pure policy shared by live
  input, fixtures, and replay; exactly one arm consumes any event. The AppKit
  adapter returns no automatic terminal-surface menu on down, forwards the
  real down/up lifecycle, and executes an owner-returned menu action only
  after the up. Because the decision runs after every previously enqueued
  output feed on the same FIFO, a `CSI ? 1000 h` echo can never race a pointer
  event into the wrong arm -- the same shape as slice 6's owner-side key
  encoding.
- **D5. Local selection gestures.** The host keeps transient drag state
  (anchor in current-stream coordinates plus granularity). Down with click
  count 1 clears any selection and anchors a character-granular drag;
  click count 2 selects the word at the cell; click count 3 or more
  selects the logical line. Moves while the left button is down extend the
  selection to the union of the anchor unit and the unit at the current
  cell via `terminal.setSelection`; up finalizes and drops the drag state;
  a single down-up on one cell with no movement leaves the selection
  cleared. Cell-to-stream mapping is `scrollProjection.topRow +
  viewportRow` computed inside the same owner step, so browsing history
  selects history. Word and line units come from two new pure `Terminal`
  queries over the logical projection: the word range is the maximal
  same-class run at the position under a three-class model (whitespace;
  word constituents: alphanumerics, `_`, and all non-ASCII scalars; other
  symbols), and the line range is the full logical line across soft wraps.
  Selection mutations mark the terminal changed, so live drag highlight
  flows through the existing consume -> `planIfNeeded` -> `onPlan`
  pipeline with no new feedback channel.
- **D6. Wheel routing priority.** At a wheel gesture's start, the owner decides
  its route in order:
  (1) Shift -> local viewport navigation only (a no-op on the alternate
  screen, which has no history) and never any bytes; (2) tracking active
  -> one wheel report per accumulated row (button 64 up / 65 down, at the
  intent's cell, ctrl/alt passed through) and no viewport movement;
  (3) alternate screen -> the existing DECCKM-aware arrow fallback;
  (4) primary screen -> local scroll. That route remains latched through the
  gesture's direct and momentum phases, regardless of later Shift or mode
  changes, and is released only at the normalized gesture end. A phase-less
  tick applies the priority independently. The native scrollbar keeps its
  existing local path and never reaches the wheel or pointer policy. The owner
  retains independent fractional-row remainders for each row-quantized route.
  Pending motion combines only while the route and all metadata that
  determine its eventual action remain equal; otherwise that route's old
  remainder is discarded. A delta observed under one position, modifier set,
  or mode can therefore never contribute to an action attributed to another.
- **D7. Mouse input never snaps the viewport.** Neither report emission
  (pointer or wheel) nor local selection moves the viewport to bottom,
  unlike keys and paste: motion and wheel report streams while browsing
  would make scrollback unusable, and selecting over history is the point
  of browsing. Reports encode the cell the user actually pointed at in the
  displayed viewport (AR2).
- **D8. Selection highlight is a distinct plan layer.** `RenderFramePlan`
  gains selection runs (row, start column, column count) and the theme
  gains a selection background color. The planner intersects
  `terminal.selectionRange` with the viewport window (offset by
  `scrollProjection.topRow`): the start row runs from the start column,
  interior rows span the full width, the end row runs to the end column
  (half-open); an empty or out-of-viewport range yields no runs. The
  executor paints selection runs after backgroundRuns and before textRuns.
  Chosen over baking selection into per-cell styles because an overlay
  leaves every existing run byte-identical -- no re-coalescing, no planner
  golden churn -- and makes selection independently assertable in plan
  equality; the cost is that a cursor block inside the selection is
  over-painted by the highlight (AR3).
- **D9. Copy and selection surface wiring.** The controller exposes
  `hasSelection` and the selected text from the cached terminal, and a
  clear-selection forwarder that enqueues the mutation on the host (the
  owner is the only `Terminal` mutator). Explicit copy first fences the owner,
  then reads the finalized selected text and writes it to the system
  pasteboard; menu enablement uses the controller's cached selection state.
  Copy happens only on explicit action -- no copy-on-select (08 contract).
- **D10. Capture and replay.** Capture preserves normalized pointer input,
  including click count, in the neutral recording. Replay runs the same pure
  decision policy with equivalent tracker and gesture-ownership state:
  selection actions mutate the replayed terminal
  (they must, for whole-value equality); report bytes are discarded exactly
  as key/paste/focus bytes are. Reports and arrow bytes never mutate
  `Terminal`, while local scrolls already capture as viewport transitions.
- **D11. Adapted `17state_mouse` corpus and manifest dispositions.** The
  neutral recording preserves normalized mouse action, button, position,
  modifiers, and click count; adapted upstream wheel inputs retain their
  buttons 4-7 semantics. Fixture execution applies each mouse input through
  the shared pure policy against authoritative modes and makes emitted bytes
  available to checkpoint assertions. Adopted cases: the DECRQM
  off/on matrices for 1000/1002/1003 and 1006, X10
  press/release/Ctrl/button-2/position/wheel, drag events with
  idempotent-cell suppression, any-motion, bounds clamping, SGR
  press/release, mouse-disabled silence, and multi-mode DECSET. Adapted:
  the DECRQM rows for 1005 and 1015 assert DanTerm's `0` reply where
  upstream answers `2`, under a new recorded deviation. Out-of-scope
  dispositions: the UTF-8 (1005) and rxvt (1015) extended-encoding cases.
  The manifest count, test title, and `expectedCases` table grow to 34
  files, fixing the existing count-comment drift in passing.

## Invariants

- **I1 (mode and encoding fidelity).** Report bytes are a pure function of
  (normalized pointer event, authoritative modes, tracker state);
  DECSET/DECRST/DECRQM for 1000/1002/1003/1006 follow D1's exclusivity
  semantics; 1005/1015/1016 remain unrecognized (DECRQM 0, set/reset
  inert); RIS and DECSTR restore defaults; modes persist across screen
  switches.
- **I2 (single consumer).** Every pointer or wheel gesture is consumed by
  exactly one arm: pointer ownership chosen at button-down remains latched
  through its matching button-up; a wheel route remains latched from gesture
  start through momentum end; Shift at gesture start forces the local arm;
  local selection, pane-menu display, and local scrolling emit zero report
  bytes; captured reporting mutates no selection, opens no pane menu, and
  moves no viewport; the scrollbar path never produces terminal input.
- **I3 (owner atomicity).** Mode read, tracker update, decision, and either
  byte write or local action happen in one host-executor step; the
  view and controller hold no mode mirrors and make no report-vs-select
  choice; fractional wheel motion is retained only by the owner and cannot
  cross routing arms; once the owner applies a mode-setting feed, no later
  unowned pointer or wheel gesture decides against the superseded mode.
- **I4 (suppression correctness).** Same-cell motion, redundant
  button-1-3 transitions, and no-button motion outside 1003 emit nothing,
  while tracker position and button state still update -- including while
  tracking is disabled.
- **I5 (selection coherence).** Selection endpoints are current-stream
  coordinates derived from the displayed viewport; the planned highlight
  equals the intersection of `selectionRange` with the viewport for every
  frame; live drag updates flow only through the existing snapshot ->
  plan -> onPlan pipeline.
- **I6 (no viewport disturbance).** No pointer event and no captured or
  Shift-modified wheel event snaps the viewport to bottom; Shift-wheel
  changes viewport state only.
- **I7 (fixture and replay transparency).** Mouse fixture events mutate the
  replayed terminal only through the shared selection policy; the adapted
  corpus passes under all chunkings; existing fixtures, manifest equality,
  and recording replays pass unchanged except for added coverage; a
  captured session containing pointer gestures, including multi-click local
  selection, replays whole-value equal.
- **I8 (explicit copy).** The pasteboard is written only by an explicit
  copy action, after owner-side selection changes preceding that action are
  visible; after cache synchronization, `hasSelection` agrees with
  selected-text availability; clearing selection is an owner-side mutation.

## Proof obligations

- **PO1 (I1).** Mode matrices: DECSET replacement among
  1000/1002/1003, DECRST-of-any disables, independent 1006 toggling,
  multi-parameter `?1002;1006h`, DECRQM exact-match replies including 0
  for 1005/1015/1016, RIS/DECSTR reset, persistence across 1047/1049, and
  the `inputModes` projection.
- **PO2 (I1, I4).** Mouse-encoding tests: the full
  encoder matrix -- X10 and SGR press/release for buttons 1-3, Ctrl and
  Alt modifier bits, wheel 64-67, drag motion with lowest-held-button,
  1003 no-button motion, same-cell suppression, redundant press/release
  suppression, X10 0xff clamping vs SGR pass-through at 300,300, and
  state-updates-while-disabled followed by enable-and-press.
- **PO3 (I5).** Word/line query tests: three-class
  word runs, whitespace runs, non-ASCII constituents, word and line ranges
  crossing soft wraps, positions in scrollback vs viewport, and clamping
  at stream edges.
- **PO4 (I2, I3).** Pure pointer-decision tests: the
  Shift/capture/local matrix, click-count granularity, drag-union
  extension in all three granularities, empty-click clears, right/middle
  behavior when uncaptured, captured right-click and control-click report
  without opening a menu, uncaptured right-click and control-click open the
  pane menu only after up and without reporting, and the D6 wheel priority
  order. Pointer cases change modifiers and mouse modes mid-drag in both
  ownership directions and prove the arm stays latched. Wheel cases change
  Shift and mouse modes during direct and momentum phases in both ownership
  directions, prove the route stays latched until gesture end, and prove a
  phase-less tick is an independent gesture. They also interleave sub-row
  deltas across modifier, mode, and pointer-cell changes and prove neither
  route consumes another's remainder and action-changing metadata
  cannot inherit an old remainder. Point-to-cell normalization covers
  flooring, clamping, and degenerate geometry.
- **PO5 (I7).** The adapted `17state_mouse` corpus passes every checkpoint
  under authored/bytewise/split chunkings; the manifest covers every
  upstream case with a disposition and carries the new DECRQM deviation;
  all existing fixtures replay byte-identical.
- **PO6 (I2, I3, I6).** Real-PTY `inputWrites()` deltas: child enables
  `?1000;1006h` then press/release
  produce exact `\e[<0;x;yM`/`m` writes; feed-then-pointer ordering yields
  mode-correct bytes; Shift-drag while captured produces zero input writes
  and a visible selection; unmodified wheel while captured produces wheel
  reports and no viewport movement; Shift-wheel produces zero writes and
  moves the viewport; a browsing viewport stays browsing across reports; a
  captured session with Shift character, double-click word, and triple-click
  line selection replays whole-value equal. In captured mode, invoking the
  native scrollbar changes the local viewport and produces no `inputWrites()`
  delta. An immediate selection followed by a fenced selected-text read
  returns the finalized owner-side selection before asynchronous consumption.
- **PO7 (I5).** Selection planning covers
  single-row, multi-row (start/interior/end shapes), out-of-viewport, and
  empty selections, plus unchanged background/text/decoration runs when
  selection is absent; execution coverage proves drawing order with the
  selection layer between background and text.
- **PO8 (I2, I8).** UI-harness tests (`just test-ui`): synthesized
  down/drag/up with click counts and Shift reach the shim controller as
  normalized cells from the 13pt grid with correct buttons, actions,
  modifiers, and click counts, with no view-side decisions; wheel forwards
  fractional motion, cell, modifiers, and direct/momentum gesture boundaries;
  the adapter suppresses automatic menu lookup, an uncaptured right-click or
  control-click opens the pane menu only after up, and dismissing that menu
  leaves a subsequent captured right-click able to report without reopening
  it;
  an immediate select-then-copy fences the owner and writes the finalized
  selection to the pasteboard; `hasSelection` tracks the cached selection;
  mouse-move delivery reaches the normalized adapter.

Slice exit gate: `just test` green (all packages plus lint scripts),
`just build` green, and `just test-ui` green including PO8; a checked
Milestone 6 slice 7 sub-bullet added to `plan-terminal-engine/14-roadmap.md`
linking the promoted plan. Live sanity check, non-gating: in a Swift-engine
pane run `vim` with `set mouse=a` and verify click-to-position, drag-select
inside vim, wheel scrolling vim, Shift-drag making a local highlight, and
Shift-wheel leaving vim alone; on the shell, drag/double-click/triple-click
select and Copy pastes elsewhere.

## Non-goals

- UTF-8 (1005), urxvt (1015), and SGR-pixel (1016) encodings --
  out-of-scope manifest dispositions, DECRQM 0.
- Alternate-scroll mode 1007 (stays deferred per slice 6; the wheel
  alt-arm remains unconditional when uncaptured).
- OSC 52 clipboard, OSC 8 hyperlinks, and Cmd-click link opening on the
  Swift pane.
- Copy-on-select (08 contract: explicit copy only).
- Drag-past-edge selection autoscroll and focus-follows-mouse.
- Pointer-cursor shape changes, hover styling, and cursor blinking.
- Configurable word-boundary classes or selection colors.

## Accepted risks

- **AR1.** The host-side tracker is not cleared by a child RIS, unlike
  libvterm's in-state position/buttons. Button state self-corrects on the
  next release; position state only affects suppression of one motion
  event.
- **AR2.** Reports encode displayed-viewport cells; a captured primary
  screen being browsed can report cells the application maps to different
  content. Mouse capture overwhelmingly runs on the alternate screen, and
  D7's no-snap behavior is worth the edge.
- **AR3.** A cursor block inside the selection is over-painted by the
  highlight layer (background only; the glyph still draws). Visually
  minor and confined to one cell.
- **AR4.** `hasSelection` reads the main-actor cache, which can lag the
  host by one consume cycle when the context menu opens. This can transiently
  disable Copy in that menu, but it cannot produce incorrect clipboard
  contents because the explicit copy action fences the owner before reading.
- **AR5.** Always-on `mouseMoved` tracking delivers move events that are
  usually dropped by the owner; per-event cost is one enqueued value on an
  already-hot queue, and the view may prefilter same-cell moves as pure
  normalization.
- **AR6.** Click-count granularity trusts AppKit's `clickCount` timing; no
  engine-side double-click interval policy.
- **AR7.** Native horizontal trackpad/wheel deltas are not forwarded in this
  slice. Horizontal report encoding and neutral fixtures remain supported,
  but live left/right wheel reporting waits for demonstrated application need.

## Rejected ideas

- **RI1.** Deciding report-vs-select in the view against a mode snapshot:
  every snapshot is a lagging mirror across a `CSI ? 1000 h` echo -- the
  exact race class slice 5 RI7 and slice 6 RI2 eliminated; it also puts
  policy where AppKit lives, against 03's boundary table.
- **RI2.** Mouse reporting as `Terminal` mutating methods appending to
  reply bytes (libvterm's shape): conflates child-output replies with
  host-originated input; slice 6 RI1 already rejected this for keys.
- **RI3.** Storing the tracker inside `Terminal`: pointer history is not
  child-visible screen state; it would leak host-input bookkeeping into
  value equality, chunk-invariance comparisons, and every fixture, for no
  behavioral gain over an explicit-state pure encoder.
- **RI4.** Baking selection into per-cell styles like the cursor:
  re-splits every coalesced run under a moving selection, churns planner
  goldens, and makes "is this cell selected" unrecoverable from the plan;
  a dedicated layer is strictly more assertable.
- **RI5.** A view-side selection model with controller readbacks (the
  Ghostty-style split): selection already lives in `Terminal` with
  reflow/eviction attachment from slice 4; duplicating it view-side would
  fork the invalidation rules 08 pins.
- **RI6.** Gating the `NSTrackingArea` on the active mouse mode: requires
  exactly the view-side mode mirror RI1 forbids; forwarding cheap moves
  and dropping them owner-side keeps the view policy-free.
- **RI7.** Supporting 1005 for fixture completeness: UTF-8 mouse encoding
  is ambiguous with real UTF-8 input, superseded by SGR in every modern
  client, and its fixture cases are exactly what the out-of-scope
  disposition mechanism exists for.
- **RI8.** A separate live-selection callback channel from host to view:
  selection mutations already flow through snapshot consumption and
  `planIfNeeded`; a second channel would create ordering questions between
  highlight and frame content.

## Implementation discretion

- Exact types, names, and file layout of the tracker, pointer event,
  decision policy, and selection-drag state; the neutral `mouse` JSON
  field spelling.
- The selection background color, whether selected text keeps its
  foreground, and word-class details beyond the pinned test vectors,
  provided the three-class model holds.
- View-side same-cell move prefiltering, tracking-area options, the wheel
  intent's initializer shape, and treatment of click counts above three
  (clamp to line granularity).

## Commit progress

- [x] 1. `feat(engine): add mouse tracking modes and report encoding`
- [x] 2. `feat(engine): add pure mouse and wheel interaction policy`
- [x] 3. `test(engine): adapt neutral mouse fixtures and replay`
- [x] 4. `feat(renderer): render terminal selections`
- [x] 5. `feat(pty): route mouse and wheel input through the pane owner`
- [x] 6. `feat(app): add native mouse selection reporting and copy`
