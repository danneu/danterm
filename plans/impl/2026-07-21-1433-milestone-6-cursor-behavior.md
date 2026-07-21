# Milestone 6 slice 11: cursor blinking, cursor shapes, and renderer lifecycle completion

## Context

The Milestone 6 closure audit is premature because the renderer contract's
cursor requirements are still unmet. The contract requires:

- "application-requested cursor shape and blinking" in the initial
  presentation ([09-renderer.md](../../plan-terminal-engine/09-renderer.md):27-28).
- "Application-requested cursor blinking runs only while the pane is visible
  and focused and DanTerm is active" (09-renderer.md:40-41).
- "Renderer teardown leaves no timer, display callback, or AppKit message
  aimed at a deallocated object" (09-renderer.md:42-43), with the proof
  obligation "Cursor blinking starts and stops with visibility, focus,
  activation, and teardown" (09-renderer.md:58-59).
- "Visibility, focus, activation, damage, and cursor-blink demand feed a
  deterministic scheduling policy. AppKit performs the resulting scheduling
  and drawing actions"
  ([13-power-performance.md](../../plan-terminal-engine/13-power-performance.md):20-22);
  blinking is "the only initial periodic visual behavior" and only while
  visible, focused, and active (13-power-performance.md:32-33); quiescence
  otherwise (13-power-performance.md:58-59); scheduling proofs use explicit
  traces, not elapsed-time assertions (13-power-performance.md:67-68).

Slice-map note: slices 1-10 delivered everything else in the Milestone 6 gate
bullet at [14-roadmap.md](../../plan-terminal-engine/14-roadmap.md):239-243;
"cursor behavior" is the last named renderer behavior without an owner. This
slice closes it.

### Verified premises (against the working tree)

- TerminalCore fully models the cursor request: `TerminalPresentation` carries
  `isCursorVisible`, `cursorShape` (block/underline/bar), `isCursorBlinking`
  (`lib/TerminalCore/Sources/TerminalCore/TerminalPresentation.swift:4-35`);
  DECSCUSR maps 0-6 to (shape, blinking) and DECTCEM toggles visibility
  (`Terminal.swift:3075-3098`, `:3023`); save/restore/reset round-trip is
  tested. No TerminalCore state changes are needed.
- `Terminal.recordDamage` already unions before/after cursor rows whenever
  `cursorPresentation` (including shape and blink mode) changes
  (`Terminal.swift:441-447`), so a DECSCUSR/DECTCEM arrival produces
  cursor-row damage that passes the owner's planning gate.
- Everything downstream drops the request today: `planIfNeeded` passes only
  `theme` + `isCursorVisible`
  (`lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift:453-471`);
  `RenderPresentation` cannot carry shape or phase and its doc forbids
  ambient/focus reads in planning
  (`lib/TerminalCore/Sources/TerminalRenderPlanning/TerminalRenderPlanning.swift:90-104`);
  the planner always bakes a steady filled block by overriding the covered
  cell's style (`RenderFramePlanner.swift:132-190`); the executor never reads
  `plan.cursor` (`TerminalRenderExecution.swift:144-197`).
- No focus or app-activation signal reaches the Swift session: the view's
  first-responder path forwards only mode-1004 focus reporting
  (`app/SwiftTerminalSessionView.swift:520-524`), and
  `SwiftTerminalBackend.setAppFocused` is a no-op
  (`app/SwiftTerminalBackend.swift:99`) even though the Elm path
  (`Msg.appBecameActive` -> `.setAppFocus` -> backend) already delivers it.
  Pane visibility already flows (`AppRuntime.syncSurfaceVisibility` ->
  `session.setVisible` -> controller).
- The view owns no timers; the established per-owner timer idiom is
  `DispatchSourceTimer` on main, `[weak self]`, cancel-before-replace, cancel
  in teardown (`app/AppRuntime.swift:839-883`), and
  [docs/design/2026-06-09-appkit-lifetime-safety.md](../../docs/design/2026-06-09-appkit-lifetime-safety.md)
  requires per-owner timers to cancel in deinit/teardown. The view's
  `tearDown()` runs from `isolated deinit`
  (`app/SwiftTerminalSessionView.swift:103-105,439-452`).
- Test surfaces exist at every layer: pure pane-session policy tests
  (`TerminalPaneSessionPolicyTests`), planner tests
  (`RenderFramePlanningTests` incl. the Slice 8 corpus/equivalence suites),
  executor bitmap tests, real-PTY controller tests
  (`TerminalPaneSessionControllerTests`), and the AppKit UI harness
  (`tests-ui/SwiftTerminalSessionViewTests.swift` + shim).

User-settled toggles: this slice renders DECSCUSR underline/bar shapes as well
as blinking (not blinking-only); when blinking is suppressed the cursor is a
solid steady cursor in its visible phase -- no hollow unfocused variant.

## Decision

**Scope:** make the Swift engine honor application-requested cursor shape and
blinking end to end: a pure deterministic blink policy in the pane-session
module, shape-aware planning and a cursor overlay pass in execution,
controller-owned blink phase with cursor-row-only replans, and an
AppKit-owned timer gated by pane visibility, render focus, and app
activation, with teardown-safe ownership.

- **D1 -- Pure blink policy in the pane-session module.** A deterministic pure
  function of (cursor visible per DECTCEM, cursor intersects the selected
  viewport, blink requested per DECSCUSR, pane visible, pane focused, app
  active) and the current phase decides two
  things: whether periodic blink work is wanted, and whether the cursor is
  drawn this frame. Blink work is wanted only when all six gates hold; a cursor
  outside the selected viewport or hidden by DECTCEM is absent with no timer
  demand, while suppression by any other gate yields a steady solid cursor
  (visible phase) with no timer demand. The policy lives beside the module's
  other pure policies (wheel normalizer, grid dimensions), not in
  `TerminalRenderPlanning`, whose contract excludes focus concerns.
- **D2 -- Shape-aware planning.** `RenderPresentation` gains the cursor shape
  (reusing `TerminalCursorShape`); cursor-drawn-this-frame stays a single
  explicit bit composed by the owner (DECTCEM and blink phase), so planning
  remains deterministic over explicit inputs (09-renderer.md:44-45). The
  block cursor keeps today's baked cell-style override bit-for-bit;
  underline/bar leave the covered cell's own colors untouched and instead
  enrich the plan's cursor metadata (shape + resolved cursor color) for the
  executor. A suppressed phase plans exactly like DECTCEM-off (no cursor, no
  overrides), so the retained plan is always self-consistent for expose
  redraws.
- **D3 -- Executor cursor overlay pass.** The executor gains a final cursor
  pass that draws underline/bar overlays from the plan's cursor metadata
  (block is a no-op there). Overlay geometry respects wide-cell snapping
  shared with the planner and is pixel-aligned at any backing scale.
- **D4 -- Controller owns phase, publishable state, and demand.** The controller
  gains render-focus and app-active inputs (distinct from mode-1004
  `sendFocus`), a blink-phase toggle that replans the last publishable terminal
  snapshot without touching terminal state and emits a frame whose damage is
  exactly the cursor row(s), and an observable blink-demand output (queryable
  + change callback) the view uses to reconcile its timer. The latest consumed
  terminal remains available for non-rendering reads, but synchronized output
  does not become the publishable snapshot or affect demand until the
  synchronization gate ends or child exit releases it.
- **D5 -- Phase-reset and redraw rules.** The phase resets to visible on every
  terminal-driven replan (cursor solid while typing), when demand rises
  (blinking restarts visible), and whenever demand falls. A terminal-driven
  replan that changes the composed cursor from hidden to visible unions the
  normalized cursor row into its outgoing damage even when terminal damage is
  on unrelated rows. A hidden-phase demand drop emits a restore frame only
  when the pane remains visible and the cursor remains drawable in the
  selected viewport; DECTCEM-off or leaving the viewport publishes the
  terminal-driven cursor-free frame, while hiding publishes no frame and
  reveal restores current state. When a terminal-driven replan resets a
  hidden phase while demand stays high, the demand callback re-fires so the
  view restarts a full interval.
- **D6 -- AppKit timer ownership.** The view owns the sole repeating blink
  timer (approximately 500 ms per phase), reconciled from demand callbacks,
  with a `[weak self]` handler and cancellation in `tearDown()` before
  controller teardown, so a queued tick after teardown is inert. A `false`
  callback cancels it; a `true` callback creates it when absent; and a repeated
  `true` reset notification cancel-replaces it so typing receives a full new
  interval and never leaves more than one timer active.
- **D7 -- App activation via the existing Elm path.** Implement
  `SwiftTerminalBackend.setAppFocused`: retain live session views weakly, fan
  activation out to them, and seed each newly created view with the stored
  value. Views default to inactive until told (deterministic under
  restore-time focus while the app is inactive). No per-view
  `NSApplication` notification observers.
- **D8 -- Render focus from first responder.** The view's existing
  focus-dedup path forwards render focus alongside mode-1004 focus, keeping
  the two in lockstep across `becomeFirstResponder`/`resignFirstResponder`
  and the `.focusSurface` command path.
- **D9 -- Roadmap.** Add the checked Slice 11 sub-bullet under Milestone 6 in
  `plan-terminal-engine/14-roadmap.md` linking the promoted plan.

## Invariants

- **I1 (blink gating).** Application-requested blinking -- periodic phase
  flips and their redraw work -- occurs only while DECTCEM is on, the cursor
  intersects the selected viewport, blinking is requested, and the pane is
  visible, focused, and DanTerm is active.
- **I2 (solid fallback).** Whenever blinking is suppressed with DECTCEM on and
  the cursor intersects the selected viewport, the cursor renders solid in
  its visible phase; no reachable sequence of gate changes strands a
  cursorless frame.
- **I3 (phase purity).** A blink-phase flip mutates no terminal state and
  emits a frame whose damage covers exactly the cursor row(s).
- **I4 (quiescence).** No blink timer exists while a tick could not change
  visible pixels; an unchanged focused terminal without requested blinking
  performs no recurring work.
- **I5 (teardown safety).** Teardown cancels the blink timer and nils the
  demand callback; no timer, callback, or AppKit message targets a
  deallocated object, and post-teardown inputs are inert.
- **I6 (shape rendering).** DECSCUSR shapes render: block as today's baked
  style override; underline/bar as overlays over a normally-colored cell;
  wide-cell head/tail snapping is consistent across shapes.
- **I7 (redraw equivalence).** Damage-driven partial redraw and full redraw
  produce identical visible output with the overlay pass in place; the Slice
  8 equivalence corpus stays green with block semantics unchanged.
- **I8 (typing solidity).** Terminal-driven replans reset the phase to
  visible, so the cursor is solid during output echo.

## Proof obligations

- **PO1 (I1, I4).** Exhaustive policy truth table over all gate combinations
  and both phases: timer demand true only when all gates hold; cursor drawn
  matches phase when blinking, solid when only a suppression gate fails, and
  absent under DECTCEM-off or outside the selected viewport.
- **PO2 (I6).** Planner proofs: underline/bar populate cursor metadata
  without cell-style overrides; block keeps baked overrides; suppressed phase
  and DECTCEM-off plan no cursor for every shape; wide-cell snapping per
  shape.
- **PO3 (I6, I7).** Executor bitmap proofs: underline and bar overlays paint
  cursor-colored geometry without disturbing neighbor cells or glyph rows
  outside the overlay; incremental cursor-row redraw between phases equals
  full redraw for each shape; overlay geometry assertions run at representative
  1x, 1.5x, and 2x backing scales; Slice 8 corpus/equivalence suites pass with
  shape-extended presentation inputs.
- **PO4 (I3, I8).** Controller proofs: a phase toggle emits exactly one frame
  with cursor-row-only damage and an unchanged terminal snapshot; a second
  toggle restores the cursor; terminal-driven replans reset the phase and
  union the cursor row when unrelated-row terminal damage makes a hidden
  cursor visible; blink ticks during synchronized output retain the last
  publishable grid and presentation until commit or child exit.
- **PO5 (I1, I2).** Gate-transition proofs at the controller seam: DECSCUSR
  blinking with all gates raises demand once; DECSCUSR steady, DECTCEM-off,
  focus loss, app deactivation, and hiding each drop demand with a single
  callback; a hidden-phase drop restores a solid cursor only while the pane and
  cursor remain drawable, DECTCEM-off publishes a cursor-free clear, and
  hiding publishes no frame; scrolling the cursor out of the selected viewport
  stops demand and returning to it restarts demand in the visible phase.
- **PO6 (I5).** Teardown proofs: controller teardown nils the demand callback
  and post-teardown toggles/setters are inert; UI-harness proofs via
  scheduling traces (shim-recorded calls and a timer-active hook, no sleeps,
  per 13-power-performance.md:67-68) that demand transitions activate and
  deactivate the view's timer, a repeated `true` reset leaves exactly one
  cancel-replaced timer with a full new interval, and teardown deactivates it
  permanently.
- **PO7 (I1).** UI-harness proof that first-responder transitions forward
  both render focus and mode-1004 focus, and that app-activation fan-out
  reaches sessions created before and after the activation change.
- **PO8 (I6).** TerminalCore damage proofs that standalone DECSCUSR and
  DECTCEM transitions damage exactly the visible cursor row.

**Slice exit gate:** `just test` green, `just build` green, `just test-ui`
green, roadmap sub-bullet added. Non-gating live sanity check: in the dev
app, `printf '\e[5 q'` blinks a bar cursor; Cmd-Tab away stops the blink and
leaves a solid cursor; `printf '\e[2 q'` returns a steady block.

## Non-goals

- A hollow/outline cursor variant for unfocused panes (user-settled).
- Configurable blink interval or any user-preference plumbing.
- Blink-phase reset on keyboard input alone; output echo already resets via
  terminal-driven replans (I8).
- New occlusion/sleep-wake handling beyond the existing visibility path.
- Ghostty-backend changes; its cursor behavior is untouched.

## Accepted risks

- **AR1.** Demand recomputation has several trigger points; a missed one
  surfaces as a stale timer. Mitigated by recomputing from the publishable
  snapshot whenever that snapshot advances and on every gate setter, pinned
  by PO4 and PO5.
- **AR2.** The demand callback re-fires on hidden-phase resets during output
  (D5); bounded to at most once per hide-tick, so it cannot become per-frame
  churn.
- **AR3.** Extending `RenderPresentation` churns its construction sites
  (roughly 30, mostly tests) with an explicit shape argument; mechanical.
- **AR4.** The UI-harness shim mirrors the new controller surface; drift risk
  accepted and kept small by mirroring signatures exactly.

## Rejected ideas

- **RI1.** Hollow unfocused cursor -- rejected by user decision; the focus
  border already marks the focused pane.
- **RI2.** Moving the block cursor into the overlay pass -- would force glyph
  redrawing into the executor's cursor pass and invalidate the Slice 8
  corpus baselines for every fixture; baking is proven.
- **RI3.** Per-view `NSApplication` activation observers -- activation already
  flows through the model to the backend; one source of truth with explicit
  seeding beats N observers and an ambient `NSApp.isActive` read.
- **RI4.** Hosting the blink policy in `TerminalRenderPlanning` --
  `RenderPresentation`'s contract explicitly excludes focus and ambient
  state from planning inputs.
- **RI5.** Owning the timer in the controller -- 13-power-performance.md:20-22
  assigns scheduling execution to AppKit, and the view's teardown already
  bounds the timer's lifetime to the pane.

## Implementation discretion

- Exact blink interval/leeway constants and underline/bar overlay thickness
  (pixel-aligned, at least one backing pixel).
- Policy output encoding (two bools vs. an enum) and API naming.

## Commit progress

- [x] 1. Plan and render DECSCUSR cursor shapes (planning, executor overlay pass, corpus updates)
- [ ] 2. Add the deterministic cursor-blink policy with exhaustive proofs
- [ ] 3. Drive blink phase, demand, and gate inputs from the pane controller
- [ ] 4. Schedule blinking from AppKit focus, visibility, and activation; roadmap entry

## Follow Up

- After landing, re-audit the Milestone 6 gate bullets
  (`plan-terminal-engine/14-roadmap.md:225-250`); with cursor behavior
  delivered, the renderer/input completion bullet and the external-case
  disposition bullet are the remaining audit targets.
