# Milestone 6 slice 5: local viewport navigation and anchoring

## Context

`plan-terminal-engine/08-input-interaction.md` fixes the scrolling contract:
the primary screen exposes retained history through wheel scrolling and a
native vertical scrollbar; the local viewport follows the live bottom until
the user navigates away; while browsing, the top displayed logical position is
the stable anchor -- output and reflow do not snap it to the bottom, and
eviction clamps it to the oldest retained logical position without re-enabling
bottom follow; navigating explicitly to the newest row re-enables follow;
search navigation reveals its match without enabling follow; local scrolling
never clears selection or search; the scrollbar represents the currently
reflowed visual-row extent and viewport. `plan-terminal-engine/05-unicode-grid-scrollback.md`
requires reflow to preserve locally scrolled viewport anchoring across width
and height changes, and `plan-terminal-engine/06-inspection-recovery.md` makes
pane-read viewport text "the logical content intersecting the rows selected by
the pane's local viewport". The roadmap carries all three as open Milestone 6
bullets.

Slice-map note: the Milestone 6 map in
`plans/impl/2026-07-20-1014-alternate-screen-resize-semantics.md` sketched
viewport work as slice 6 after input encoding. This slice pulls it forward as
slice 5: it depends only on slice 2's eviction seam and slice 4's anchor
machinery (both landed), and it unlocks viewport pane reads, browsing-safe
selection/search, and the interaction seam mouse reporting will ride. Input
encoding and mouse reporting become slice 6.

Verified premises (against the working tree):

- No viewport concept exists anywhere. `Terminal`'s `geometry`,
  `cell(row:column:)`, and `screenText` project only the live grid (`rows`);
  `RenderFramePlanner.planFrame` reads only `geometry` + `cell(row:column:)`;
  the Swift pane's `readViewportText()` returns `screenText`. There is no
  scroll offset, follow flag, or damage tracking.
- `screenText` is a fixed-width grid serialization: it renders padding as
  spaces and joins every visual row with a newline. It therefore cannot
  satisfy 06's viewport-read contract (logical content, soft-wrap joins) even
  today, before any scrolling exists. The logical machinery that can
  (`forEachProjectionUnit`, feeding `fullHistoryText`/`primaryHistoryText`)
  already exists and is only ever run over the whole retained stream.
- `TerminalPTYHost` is the single serialized owner of both the authoritative
  `Terminal` and the child write path: `send` and `resize` are nonisolated
  submits onto one FIFO executor that also carries `.sendInput`. Any state a
  caller outside that executor holds is a lagging copy.
- The anchoring primitive exists. `TextAnchor(row:column:)` is absolute-row
  space (`evictedRowCount` + stream index; monotonic, never reused).
  `handleEviction(of:)` is the single eviction clamp seam (slice 4 D4);
  `resizeWidth` already remaps the cursor, selection endpoints, search
  endpoints, and a live viewport-top key through one cell-attachment map
  (`cellDestinations`/`boundaryDestinations`). ED 3 is treated as evict-all
  with the counter advanced. Two remap paths exist with different coverage:
  selection endpoints ride a projection-unit path that is partial over
  trailing blank regions (units stop at the last content row), while the live
  viewport-top rides per-row reflow metadata that is total over every source
  row, including blank ones.
- The window top index ranges over `0...scrollbackRowCount`, but a browsing
  anchor is not confined to scrollback: height growth, eviction, and reveal can
  leave it on a live-grid row, including a bottom-aligned one. Browsing is
  therefore explicit state, never derived from the anchor's position in the
  stream. Scroll-off push, height-shrink displacement, and height-growth
  pull-back move rows between arrays wholesale and preserve stream indices;
  region scroll/IL/DL permute only grid rows.
- Alt-screen transitions call `clearInspection()`; slice 4 D5/I5 defines the
  screen-replacement class (1047/1049 actual transitions, RIS,
  resize-while-alt clear; DECSTR-on-primary and mode 47 preserve).
- The app's scrollbar chrome is already built and backend-agnostic:
  `ScrollableTerminalView` wraps every pane (NSScrollView, blank document view
  sized by `ScrollbarMath`, live-scroll -> `scroll(toRow:)`), and sessions
  report `TerminalSessionState { scrollbarEnabled, cellHeight,
  scrollPosition: TerminalScrollPosition{total, offset, length}? }` through
  `TerminalSessionCallbackGate`. The Ghostty pane populates it
  (`app/TerminalView.swift`); the Swift pane leaves `scroll(toRow:)` and
  `setScrollbarEnabled` as no-ops, never emits `scrollPosition`, and does not
  override `scrollWheel`. The scroll chrome forwards every wheel event to the
  pane view, and a view without its own `scrollWheel` override lets the
  default responder-chain walk bounce the event back into the enclosing
  scroll view -- so the override is a mounting-correctness requirement, not
  just feature wiring (the Ghostty pane already overrides for this reason).
- `TerminalPaneSessionController.planIfNeeded`
  replans when the snapshot differs from `lastPlannedTerminal` and suppresses
  planning while synchronized output (2026) is active; `synchronizeState()`
  fences the host before IPC reads.
- A fixed-table key encoder exists (`encodeTerminalKey`: Up = `ESC [ A`,
  Down = `ESC [ B`; no DECCKM state anywhere yet). No mouse modes exist.
- Recordings (`NeutralTerminalRecordingEvent`) carry `feed`/`resize`/
  `checkpoint`; unknown event types fail decode (`unsupportedEvent`). The
  Milestone 4 invariant is capture/replay whole-value `Terminal` equality.
- `TerminalGeometry.cursor` is non-optional; the planner always plans a cursor
  when `presentation.isCursorVisible`.
- The slice 4 follow-up records a recurring pre-existing `EXC_BAD_ACCESS`
  while `planIfNeeded` copies a `Terminal`
  (`TerminalPaneSessionControllerTests`); wheel traffic multiplies load
  through exactly that path.

User-settled toggles for this slice: wheel over an active alternate screen
falls back to arrow-key writes; user input while browsing snaps the viewport
back to the live bottom.

## Decision

Scope: engine-owned viewport state and window projections (pure core), host
command routing plus session scroll-state emission (TerminalPTY), wheel and
scrollbar wiring in the Swift pane view (app), and capture/replay coverage.
No mouse reporting, no selection gestures, no renderer damage work.

- **D1. Engine-owned viewport state.** Local-viewport state lives in
  `Terminal`, like slice 4's selection: default "following the live bottom";
  otherwise "browsing" with a top anchor. Public mutating navigation entry
  points (names indicative, shapes contractual): scroll by a signed number of
  visual rows; scroll to a given top row in current-stream coordinates (the
  scrollbar's space); scroll to bottom. A read-only scroll projection exposes
  `{totalRows, topRow, windowRows, isFollowing}` in current-stream
  coordinates. All of it is semantic state participating in `Terminal ==`.
  `feed` can never enter or move browsing state -- only explicit navigation
  does -- but it does reset browsing to following through D3's
  screen-replacement operations, which arrive as child bytes. Engine
  ownership is forced by the contract: the
  anchor must be remapped inside width reflow and clamped inside the eviction
  seam, and a scroll must change the value so the existing
  snapshot-inequality replan trigger fires.
- **D2. The viewport projections follow the local window.** `geometry`,
  `cell(row:column:)`, and `screenText` present the grid-height window over
  the stream (scrollback then live rows) selected by the viewport state --
  bit-identical to today while following. The renderer therefore follows with
  no consumer wiring change, the slice 1 projection precedent. These stay
  grid-shaped (fixed width, padding as spaces, one line per visual row): that
  is what rendering and grid debugging want. While the window excludes the
  live cursor row, the geometry carries no cursor and the planned frame has
  no cursor (`TerminalGeometry.cursor` becomes optional -- the one geometry
  API-shape change); while the window includes it, the cursor reports at its
  window-relative row.
  Separately, pane-read viewport text becomes a *logical* projection over the
  window rows -- the same soft-wrap-joining, hard-boundary-respecting,
  trailing-padding-omitting machinery that already produces full-history
  text, restricted to the window's row range -- and the session's viewport
  read routes to it instead of `screenText`. This changes pane-read output
  for wrapped or padded content even while following; that is the point, 06
  specifies logical content and the grid serialization never satisfied it.
  `fullHistoryText`, `primaryHistoryText`, selection, search, export, and
  recovery reads are scroll-independent and unchanged.
- **D3. Anchor semantics.** The anchor is the top displayed logical position
  in absolute-row space. Operations that move rows wholesale (scroll-off push,
  height-shrink displacement, height-growth pull-back) preserve it by
  construction; width reflow remaps it through the per-row reflow metadata
  that already carries the live viewport top -- total over every source row,
  including blank rows below the last content -- not the selection
  projection-unit path, which is partial exactly there; eviction (and ED 3 as
  evict-all) clamps it to the oldest retained position at the single
  `handleEviction` seam without re-enabling follow. Height changes keep the
  anchor and re-fit the window (window height always equals grid height),
  clamping only so the window stays within the stream; clamping never
  re-enables follow. Screen replacement resets viewport state to following --
  exactly slice 4's D5/I5 class (1047/1049 transitions that actually switch or
  re-blank, RIS, resize while alt is active); DECSTR on the primary screen and
  ordinary overwrite mutations never touch it (the viewport has no analog of
  selection's overwrite invalidation -- a stable anchor during output is the
  point). While the alternate screen is active the viewport is pinned to the
  live grid: navigation entry points are no-ops there, and the scroll
  projection reports no scrollable extent (total equals window rows,
  following), so the scrollbar never exposes primary scrollback over an
  alternate-screen application.
- **D4. Viewport state is a lens.** Navigation and viewport state never change
  grid content, cursor, modes, styles, scrollback, reply bytes, resize
  semantics, or any byte sent to the child. Primary-screen wheel emits
  nothing to the PTY.
- **D5. Follow re-enables through exactly three triggers.** (1) Navigation
  whose resulting window includes the newest row -- wheel/scrollbar/scroll-to-
  bottom. (2) A user-originated PTY write -- typed text, encoded keys, and IPC
  pane input all ride the same session send paths and snap the viewport to
  the bottom (user-settled); engine reply drains and child output never snap.
  Because that snap mutates the `Terminal` value independently of anything the
  child echoes back, the owner records it as a viewport-navigation transition
  like any other (D10).
  (3) The screen-replacement resets of D3. Nothing else re-enables follow:
  not output, not resize, not eviction clamping, not search reveal -- a clamp
  that happens to land the window bottom-aligned leaves the terminal
  browsing.
- **D6. Search reveal is engine-owned.** A successful `beginSearch`/
  `searchNext`/`searchPrevious` leaves the active match's start row inside
  the window: no movement when it is already visible; otherwise the minimal
  scroll that brings it inside. Reveal never enables follow (a reveal that
  lands the window bottom-aligned still leaves the terminal browsing); when
  no movement is needed the follow state is unchanged. Failed navigation
  moves nothing. Local scrolling never clears selection or search. Reveal is
  core policy proven at the core layer this slice: the runtime has no search
  UI yet (the session search entry points are stubs), so no search host
  commands are added; wiring reveal to a real search UI lands with the slice
  that builds that UI.
- **D7. Wheel normalization is AppKit-free; wheel routing is owner-side.**
  Per the 03 boundary, AppKit only normalizes events: a pure, AppKit-free
  accumulator converts the wheel stream (precise pixel deltas against the
  cell height, line deltas otherwise, remainder carried, momentum treated as
  ordinary deltas) into ordered signed row steps. Those row steps travel to
  the host as a *semantic wheel intent*, not as a pre-decided action. The
  host, on its FIFO executor, reads the authoritative active screen and
  performs exactly one arm: primary -> local viewport navigation; alternate
  -> the equivalent count of Up/Down key writes (user-settled; unconditional
  this slice -- no 1007 gate, no DECCKM variance until the input-encoding
  slice). Those arrow bytes are encoded by the session through the existing
  key encoder and carried inside the intent, because the encoder lives in the
  session layer that depends on the host and encoding policy must not be
  duplicated across that edge; the host still decides exclusively whether to
  apply local navigation or write the carried payload. No caller outside the
  executor may decide
  the arm: a cached snapshot can lag a 1049 transition in either direction,
  which would either swallow arrows an alt-screen app is waiting for or emit
  child bytes while the primary screen is active, violating I11. The
  scrollbar is always local and is disabled while the alternate screen is
  active.
- **D8. The Swift pane populates the existing scrollbar chrome.** The pane
  view overrides `scrollWheel`, normalizes, forwards the intent, and consumes
  the event unconditionally -- the override is also what breaks the
  scroll-chrome forwarding cycle, so it lands as mounting correctness even
  when the intent is a no-op. The view implements `scroll(toRow:)` and emits
  `TerminalSessionState` with `scrollbarEnabled` (primary active) and
  `scrollPosition = {total: stream rows, offset: window top row,
  length: window rows}` from the engine scroll projection, on change only.
  `ScrollableTerminalView`, `ScrollbarMath`, and the Ghostty pane are
  untouched.
- **D9. Runtime routing rides the existing owner path.** Viewport navigation
  and wheel intents are explicit host commands like `resize`: a nonisolated
  submit onto the host's FIFO executor mutates the authoritative `Terminal`
  (and, on the alt arm, writes to the child) and signals the existing update
  stream; the controller replans through the existing value-inequality guard
  and `synchronizeState()` fencing covers scrolled IPC reads. No new update
  channels, timers, or recurring work: an idle scrolled pane schedules
  nothing. Because wheel traffic multiplies load through `planIfNeeded`'s
  snapshot copy, the pre-existing slice 4 follow-up crash there is resolved
  -- or demonstrated already fixed -- as part of this slice, and the host
  teardown ownership assertion in the existing PTY suite passes.
- **D10. Capture/replay stays whole-value exact.** Recordings gain an
  additive viewport-navigation event; host capture records navigation
  commands in feed order and replay applies them, so a captured session in
  which the user scrolled still replays to a whole-value-equal `Terminal`.
  Existing fixtures decode and replay unchanged. The governing rule: every
  host command that mutates the `Terminal` value is either recorded or
  prohibited during capture; after this slice the recorded set is feed,
  resize, and viewport navigation.
- **D11. No new fixtures or manifest changes.** libvterm delegates
  scrollback/viewport presentation to the embedder and has no
  viewport-navigation cases (verified during slices 2 and 4); alacritty's
  display tests are Rust unit tests with no adaptable recordings. Behavioral
  Swift Testing suites carry the slice, using the slice 2 small-budget knob
  for eviction cases. Shared structural assertions must stay valid for both
  following and scrolled terminals (today's assume a bottom-anchored window).

## Invariants

- **I1 (transparency).** Default viewport state is following; no `feed` can
  enter or move browsing state (it may only reset it to following, per I6);
  every existing fixture replay, chunk-invariance
  result, and recording replay is byte-identical; equal `Terminal` values
  answer every new projection equally; all new state entering `Equatable` is
  semantic.
- **I2 (lens purity).** For any interleaving of navigation with feeds and
  resizes, grid content, cursor, modes, styles, scrollback, reply bytes, and
  full-history/primary projections equal those of the same run without the
  navigation; primary-screen navigation emits no child bytes.
- **I3 (bottom follow).** While following, the window is the live grid:
  output and reflow keep the newest rows visible and every viewport
  projection is bit-identical to today's behavior.
- **I4 (stable anchor).** While browsing, the top displayed logical position
  stays attached to the same retained logical content across appended output,
  scroll-off push, height-shrink displacement, height-growth pull-back, and
  width reflow -- and where a width change is invertible, the window returns
  to its original top. Output and reflow never re-enable follow or snap the
  window to the bottom.
- **I5 (eviction clamp).** All eviction-driven viewport maintenance happens at
  the slice 2 seam plus ED 3: an anchor whose row is evicted clamps to the
  oldest retained position, follow stays off, and reflow-triggered eviction
  composes remap-then-clamp.
- **I6 (follow triggers).** Follow re-enables exactly via D5's three
  triggers; DECSTR on the primary screen, output, resize, eviction, and
  search reveal preserve browsing.
- **I7 (viewport text).** Pane-read viewport text is the logical content of
  the window rows -- soft-wrap joins, hard boundaries, trailing padding
  omitted -- for both following and scrolled terminals; `--lines`, export,
  and recovery reads are unaffected by scrolling.
- **I8 (render window).** The planned frame covers exactly the window rows;
  a cursor is planned iff the window includes the live cursor row (and
  visibility allows it), at its window-relative position; a scroll-only
  change replans; while following, planned frames are identical to today's.
- **I9 (search reveal).** After any successful search operation the active
  match's start row is inside the window per D6; reveal never enables
  follow; local scrolling and reveal never clear selection or search.
- **I10 (scrollbar).** The scroll projection reports the currently reflowed
  visual-row extent, window top, and window height; scrollbar navigation
  round-trips (scrolling to a row and reading the projection returns that
  row, clamped to the stream); session scroll state is emitted on change
  only; the scrollbar is disabled while the alternate screen is active.
- **I11 (alt wheel fallback).** Each wheel intent is routed against the
  active screen as it stands when the owner executes it, and performs exactly
  one arm: alternate -> the equivalent count of Up/Down key writes, byte-equal
  to what the existing key encoder produces, and no local scroll; primary ->
  local scroll and zero
  child bytes. A screen switch racing a wheel intent cannot produce the wrong
  arm, both arms, or neither.
- **I12 (capture equality).** A captured session including viewport
  navigation replays to a whole-value-equal `Terminal`; recordings without
  the new event are unaffected; every `Terminal`-mutating host command is
  recorded or prohibited during capture.

## Proof obligations

- **PO1 (I1).** The existing corpus, manifest, and recording replays pass
  with zero edits; terminals driven to equal values by different chunkings
  answer the scroll projection identically.
- **PO2 (I2).** A twin comparison interleaving navigation with output,
  resizes, and queries: content projections, cursor, modes, and reply bytes
  equal the navigation-free twin; primary wheel/navigation produces zero
  child writes.
- **PO3 (I3, I4).** Follow-live output and reflow; navigate away, then:
  appended output (top text stable), scroll-off push migrating the anchor
  row into scrollback, width shrink -> grow -> original round-trip restoring
  the window top (including an anchor on a blank scrollback row below the
  last content row), height shrink and growth while browsing (window
  re-fits, anchor held, clamp at the stream end), and a pull-back that
  forces a bottom clamp without re-following.
- **PO4 (I5).** Small-budget eviction: anchor above the eviction point
  clamps to the oldest retained row with follow off; eviction triggered by
  width reflow clamps after remap; ED 3 behaves as evict-all.
- **PO5 (I6).** Each D5 trigger re-enables follow (wheel/scroll-to-row
  reaching the newest row, scroll-to-bottom, user text/key/IPC input); reply
  drains and child output do not; alt navigation no-ops. Both arms of D3's
  screen-replacement classifier are exercised: the operations in the class
  reset browsing to following, and the operations outside it preserve it --
  including DECSTR-on-primary, mode 47, and 1047/1049 operations that do not
  actually replace the active screen.
- **PO6 (I7).** Pane-read viewport text equals the window's logical content
  for a following terminal whose window contains soft-wrapped and padded
  rows, and for a scrolled window; full-history and `--lines` reads unchanged
  while scrolled; the recovery read is unaffected.
- **PO7 (I8).** Planner frames for scrolled windows (scrollback-only window,
  mixed scrollback+grid window); cursor absent when outside, present at its
  window-relative row when the window includes it; follow frames
  byte-identical to today; a scroll-only value change plans exactly one new
  frame.
- **PO8 (I9).** Reveal with the match above, below, and inside the window;
  reveal from following (moves -> browsing) and reveal needing no movement
  (state unchanged); selection and search survive scrolling and reveal.
- **PO9 (I10).** Scroll-projection round-trips including a reflow that
  changes the total; controller emits session scroll state on change only;
  scrollbar disabled under alt; `scroll(toRow:)` clamps.
- **PO10 (I11).** Alt-active wheel intents produce the counted Up/Down
  writes and no scroll; primary-active intents produce a scroll and no child
  bytes; and a wheel intent submitted concurrently with a 1049 transition in
  each direction resolves to exactly one arm consistent with the screen the
  owner saw -- never both, neither, nor child bytes on the primary screen.
- **PO11 (I12).** A capture containing navigation events replays
  whole-value equal, including a capture whose only viewport transition is the
  D5 snap caused by sending input to a non-echoing child; legacy recordings
  decode and replay unchanged.
- **PO12 (D7).** Accumulator determinism without AppKit: precise-delta
  accumulation against cell height with remainder carry, line-delta
  scaling, direction, and momentum equivalence.
- **PO13 (D9).** A controller stress run interleaving sustained child output,
  viewport navigation at wheel rates, and replanning completes without a
  crash, ends on the correct final frame, and leaves no retained host at
  teardown. This slice does not land until the existing PTY suite -- whose
  teardown ownership assertion currently fails -- is green.
- **PO14 (D8).** The mounted AppKit pane consumes a wheel event exactly once
  (no responder-chain bounce into the enclosing scroll view) and forwards the
  expected normalized direction and row count.

Slice exit gate: `just test` green (all packages plus lint scripts), the app
target building (`just build`), and `just test-ui` green including PO14's
wheel case; plus a checked Milestone 6 slice 5 sub-bullet in
`plan-terminal-engine/14-roadmap.md` linking the promoted plan. Live sanity
check, non-gating: in a Swift-engine pane, wheel up through streaming `seq`
output and watch the view hold, drag the scrollbar knob, wheel-scroll `less`
(arrow fallback), and type to snap back to the prompt.

## Non-goals

- Mouse reporting, SGR mouse encoding, Shift-wheel/Shift-drag precedence,
  and capture-vs-local wheel routing (needs mouse-mode state; slice 6).
- DECCKM-aware arrow encoding and alternate-scroll (1007) as a real mode;
  the fallback is unconditional this slice.
- Keyboard history-navigation shortcuts (Page Up, Cmd-Home, etc.).
- Selection mouse gestures and drag autoscroll (slice 6/7).
- Damage/incremental rendering, scrollbar marks, or a truncation indicator.
- Smooth sub-row (pixel) scrolling; the viewport is row-quantized.
- Persisting viewport state across restarts.

## Accepted risks

- **AR1.** Scrolling while synchronized output (2026) suppresses planning
  does not render until the gate releases -- and 2026 also appears on the
  primary screen via prompt frameworks, not just alt-screen apps.
  Suppression deliberately wins over scroll replans: rendering a suppressed
  grid at a new offset would expose torn mid-update content. The slice 7
  host-side 2026 timeout (already accepted there) is the mitigation for a
  wedged child.
- **AR2.** Each wheel step is a MainActor -> host-executor round-trip plus a
  full replan. This is the existing per-output-batch path; correctness
  first, measured by feel in the live sanity check.
- **AR3.** The alt-screen arrow fallback emits the legacy CSI table
  regardless of application cursor mode (DECCKM does not exist yet) --
  exactly the limitation the existing `sendKey` path already has; the
  input-encoding slice refines both together.
- **AR4.** Snap-on-type treats IPC pane input as user-originated, so a CLI
  agent writing to a pane yanks a browsing viewport to the bottom. Accepted:
  it matches the one send path, and the write's output would move the
  scrollbar anyway.
- **AR5.** `scroll(toRow:)` computes its target from the last emitted scroll
  state, so an eviction between emission and application lands the drag
  lower by the newly evicted rows. Self-correcting at the next state
  emission; accepted.
- **AR6.** Every scroll step pays whole-value equality compares (host
  changed-value check, replan guard) that walk retained scrollback.
  Accepted correctness-first; a storage-identity fast path stays open as
  discretion if wheel feel demands it.

## Rejected ideas

- **RI1.** Session/controller-owned scroll offset (rows from bottom):
  cannot preserve logical anchoring across width reflow without duplicating
  the core's attachment machinery outside it, and cannot observe a mid-feed
  eviction; 05 and the roadmap place viewport anchoring in the core's reflow
  contract.
- **RI2.** Parallel presented-window projections beside the live-grid ones:
  two viewport vocabularies for one concept; every consumer must choose;
  slice 1's precedent is that the viewport projections follow.
- **RI3.** Excluding viewport state from `Terminal ==`: breaks the house
  rule that semantic state participates in equality and blinds the replan
  trigger and capture/replay proofs.
- **RI4.** Implementing the alt-wheel arrow fallback inside the core:
  encoding bytes from UI gestures is session policy at the 03 boundary; the
  core stays byte-silent for local interaction.
- **RI5.** A pixel-granular engine viewport offset: the grid is cell-based;
  smoothness can be layered at the view later without core changes.
- **RI6.** Remapping the viewport anchor through the selection
  projection-unit attachment path: projection units stop at the last content
  row, so an anchor in a trailing blank region has no unit at or after it
  and the fallback teleports it to the content end -- a stable-anchor
  violation with no eviction involved. The per-row reflow metadata path is
  total over source rows.
- **RI7.** Deciding the wheel arm (local scroll vs arrow writes) in the
  session or view layer: every such caller reads a snapshot that can lag the
  owner across a 1049 transition, so the decision races the screen state it
  depends on. The owner-side routing of D7 removes the race rather than
  fencing it.

## Implementation discretion

- Internal anchor representation within the per-row reflow-metadata remap.
- Accumulator constants (line-delta scaling) and the recording event's
  schema shape.
- Whether the scrollbar command carries an eviction epoch (AR5) and any
  equality fast path for wheel-rate compares (AR6).

## Commit progress

- [x] 1. Add core viewport navigation, anchoring, projections, and rendering
- [x] 2. Route viewport intent through PTY ownership and capture/replay
- [x] 3. Wire Swift-pane wheel and scrollbar interaction

## Implementation notes

- Line-based wheel deltas normalize at three rows per unit; precise deltas
  divide by cell height, and both modes share a fractional-row remainder.
- Recordings encode one additive `viewport` event with an `action` and optional
  row value; capture appends it only when the owner command changes `Terminal`.
- PO14 compiles the real Swift pane against UI-only terminal controller and
  renderer shims, then synthesizes a line-unit wheel event without launching a PTY.
