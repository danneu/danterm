# Milestone 4 slice 3: session adapter and AppKit integration

Milestone 4 (the interactive viability slice, plan-terminal-engine/14-roadmap.md:117-130)
lands in four slices (plans/impl/2026-07-19-1837-deterministic-render-planning.md:8-12):
(1) pure render planning -- shipped, (2) AppKit CoreText/CoreGraphics executor --
shipped, (3) session adapter over the backend seam, (4) viability harness and
gate closure. This plan covers slice 3 only: a real Swift-engine pane on screen
behind the existing `TerminalBackend`/`TerminalSession` boundary, selected with
`DANTERM_TERMINAL_BACKEND=swift`.

## Problem

Milestones 2-3 proved a headless terminal (`TerminalPTYHost` + `Terminal`) and
slices 1-2 proved snapshot -> plan -> pixels, but nothing connects them to a
pane: `DANTERM_TERMINAL_BACKEND=swift` hits a `fatalError`
(app/AppDelegate.swift:42), the engine packages are not linked into the app
(root Package.swift:24-44 depends only on GhosttyKit + DanTermProtocol), and
the host exposes no way to learn that terminal state changed -- PTY output is
consumed internally into the embedded `Terminal`
(TerminalPTYHost.swift:403-425, 474-485) and callers can only pull
`snapshot()`. Without this slice, slice 4 has nothing interactive to judge.

Load-bearing evidence (verified):

- `app/TerminalBackend.swift:60-105`: the `TerminalSession`/`TerminalBackend`
  protocols are synchronous `@MainActor` surfaces; `:27-48`
  `TerminalSessionCallbackGate` nils both callback channels at teardown;
  `:51-58` `TerminalSessionRequest`. `AppRuntime` is backend-agnostic:
  `makeTerminalSession` (app/AppRuntime.swift:1209-1234) installs the
  pane-scoped event translation, `tearDownSurface` (:785-793) calls
  `session.tearDown()`, and visibility/display sync (:404-437) flows through
  the seam. The event vocabulary is closed
  (lib/DanTermCore/.../TerminalBackendBoundary.swift): `.closeRequested` maps
  to `.surfaceClosed`.
- `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift`: the host is
  an actor on a private `DispatchSerialQueue` executor; dispatch sources
  re-enter isolation via `assumeIsolated` (:299-301). All lifecycle inputs
  funnel through one outer reducer drain (`process`, :217-230). `start()`
  deliberately sabotages the launch when `input.initialDimensions` differs
  from the init dimensions (:122-130). `report()` is set-once (:658-664), but
  `finishTeardown()` resumes output and teardown waiters only (:666-683) --
  teardown paths that never report a result (verified: close-before-spawn,
  PaneLifecycle.swift:131-133, 195-199) strand `waitForResult()` waiters
  forever, retaining the host.
- `lib/TerminalPTY/Sources/PaneLifecycle/LaunchPolicy.swift:41-98,146-183`:
  `LaunchPolicyInput` wants injected ambient facts (account shell, executable
  paths, home, accessible dirs, ordered environment layers);
  `resolveLaunchPlan` has no `waitAfterCommand` -- doc 07 pinned commands as
  initial shell input. The reducer buffers a pre-spawn resize and applies it
  after `spawnSucceeded` (PaneLifecycle.swift:172-178).
- `lib/TerminalCore`: `Terminal` is `Equatable + Sendable` (Terminal.swift:4)
  -- equality is the change check; `init?` requires columns >= 2, rows >= 1
  (:114-115); `screenText`/`fullHistoryText` (:157, :194) serve the session
  read methods. `planFrame(for:presentation:)`
  (RenderFramePlanner.swift:7-12) is the only plan source;
  `TerminalRenderMetrics(displayScale:)` refuses degenerate scales,
  `renderFrameSize` nil-refuses overflow, and `drawRenderFrame` draws a
  complete frame into a flipped point-space context and restores context
  state (TerminalRenderExecution.swift:39, 117-160).
- `dev-build.sh:23-32` hand-assembles the app bundle (precedent:
  `Contents/Helpers/danterm`); a root `swift build` does not build a
  dependency package's executable products, and host tests locate
  `PTYSessionBootstrap` from the build directory
  (TerminalPTYHostTests.swift:438-439).
- `scripts/terminal-backend-boundary-lint.sh` polices only `import GhosttyKit`
  against an allowlist; nothing confines engine imports.
- Contracts: callbacks cannot outlive the pane host (02:65); backend selection
  is a dev facility that never touches persisted model data (02:17-19, :80);
  creation failure follows established behavior (02:78); one serialized owner
  per pane, PTY bytes/grid/damage never enter the Elm model (03:22-27,
  :57-58); exit reported once, hidden panes keep consuming, bounded teardown
  incl. app termination (07:58-70); macOS owns composition, no Option-as-Alt,
  key encoding decided outside framework callbacks with AppKit-free tests
  (08:11-31, :117-119); no drawing for hidden panes, complete frame on
  reveal, teardown leaves nothing aimed at deallocated objects (09:38-43);
  coalescing never loses the final visible state, idle CPU ~zero, no display
  link (13:11-14, :26-49); backing-pixel size and content scale are one
  invariant with skip-on-degenerate guards (2026-03-05 scaling ADR); weak
  back-references and deinit-cleaned observers (2026-06-09 lifetime ADR);
  advertised environment `TERM=xterm-256color`, `COLORTERM=truecolor`,
  `TERM_PROGRAM=DanTerm`, `TERM_PROGRAM_VERSION` (10:14-19).

User-pinned scope decisions: `pasteClipboard` is an inert no-op this slice
(paste ships with its doc-08 security policy in Milestone 6); key encoding is
a fixed minimal CSI-normal table with no DECCKM (the core has no
input-affecting mode state); the slice's proof bar is headless package tests
plus a manual app smoke run -- the tests-ui harness is not extended.

## Decision

Build three layers, from proven to thin. All type, member, and file names
below are working names (discretion).

### Host additions (lib/TerminalPTY, TerminalPTYHost target)

- **Ordered submission.** Input bytes and resize requests gain synchronous,
  nonisolated submission entry points that enqueue directly onto the host's
  serial executor (the existing `assumeIsolated` dispatch-source idiom).
  Called from the main actor, FIFO on one queue makes submission order equal
  application order -- across input and resize jointly. Ordered operations are
  never awaited actor methods; only `snapshot`, `close`,
  `terminateForApplicationExit`, and `waitForResult` are awaited.
- **Update signal.** A conflated, single-consumer change signal
  (AsyncStream-shaped; exact carrier discretion): at most one pending token;
  a token is emitted once per outer reducer drain that applied a terminal
  mutation (output fed, resize applied) or reported the lifecycle result. The
  reducer emits `.report` and `.finishTeardown` in the same drain
  (PaneLifecycle.swift:299-307), so that drain's token is delivered before the
  signal terminates -- termination, not the host's teardown flag, is what
  bounds emission, and the last token survives for a consumer that reads after
  termination. An idle terminal produces zero tokens and zero work. A
  non-suspending accessor exposes the reported result so exit is observable
  in-band. The resource census gains a post-termination-signal counter in the
  existing `callbacksAfterTeardown` style.
- **`waitForResult` returns an optional.** Teardown that completes without a
  child result resumes waiters with nil instead of stranding them (the
  verified leak above). Existing `== .exited(...)` assertions still compile
  via optional promotion.

### Session controller (new library target in lib/TerminalPTY, working name `TerminalPaneSession`)

A `@MainActor` controller class is the sole client of its `TerminalPTYHost`
and owns all session policy, headless-testable with real PTYs inside
`just test` (deps: TerminalPTYHost, PaneLifecycle, TerminalCore,
TerminalRenderPlanning -- no AppKit, no TerminalRenderExecution; scale and
cell size stay explicit inputs at the view). `@MainActor` rather than an
actor because the `TerminalSession` protocol is synchronous main-actor
surface -- an actor would force per-call unstructured Tasks, which is exactly
the ordering hazard.

- **Consume loop.** One task iterates the update signal: pull `snapshot()`,
  check the result accessor (exit -> emit a session-ended callback once),
  skip planning when the snapshot equals the last-planned terminal
  (`Terminal` equality is the gate), otherwise `planFrame` with the baked
  presentation (`RenderTheme.dark`, cursor always visible) and deliver the
  plan on the main actor. Conflation plus one sequential consumer means the
  final state is always planned and at most one pull is in flight.
- **Visibility.** Visibility gates planning and drawing only. The controller
  consumes tokens and refreshes its cached snapshot regardless of visibility,
  so inspection and recovery reads stay current for a hidden pane; the host
  keeps consuming either way. Reveal with pending changes delivers exactly one
  complete current frame.
- **Cached snapshot.** The controller caches the latest pulled `Terminal` so
  `readViewportText`/`readFullHistoryText` (checkpointing, recovery) answer
  synchronously from `screenText`/`fullHistoryText` even during and after
  teardown. A read taken at clean termination reflects every mutation the host
  applied before it: the master contract's "clean termination flushes dirty
  recovery" (06:63) is unmeetable against a cache that can lag by an
  unconsumed token, and that output is permanently lost from recovery. How
  the terminating read is fenced against in-flight host work is discretion.
- **Grid changes** dedupe against the last submitted dimensions and go
  through the same ordered submission as input.
- **Teardown** (idempotent, synchronous): close the callback gate and set a
  torn-down flag (every later callback body and input submission no-ops),
  end the consume task (bodies guard the flag first -- cancellation alone
  cannot stop an already-resumed body), then launch one detached task that
  captures only the host and awaits `close()`. The session and view can
  deallocate while the bounded ladder runs; task closures hold `self` weakly
  and the host strongly, per the lifetime ADR.
- **Key encoding and grid sizing** are pure functions in this target. The
  encoder byte table is pinned by fixture: Return `0x0D`, Tab `0x09`,
  Backspace `0x7F`, Escape `0x1B`, arrows `ESC [ A/B/C/D`, Home `ESC [ H`,
  End `ESC [ F`, PgUp `ESC [ 5 ~`, PgDn `ESC [ 6 ~`, forward Delete
  `ESC [ 3 ~`, Ctrl+letter `0x01`-`0x1A`. The encoder defines its own key
  vocabulary (`KeyName`/`KeyMods` live in root-package DanTermProtocol; a
  package dependency on the root would be a cycle) -- the app maps both
  `KeyName`/`KeyMods` and NSEvent input into it; unmapped keys drop. Grid
  sizing floors size/cell per axis and clamps to columns >= 2, rows >= 1;
  degenerate inputs return nil.

### App layer (app/, thin)

- **`SwiftTerminalSessionView`** -- flipped, layer-backed NSView +
  `NSTextInputClient` + `TerminalSession` conformance. Drawing: the
  controller's delivered plan and the current metrics are published as one
  atomically-swapped pair; `draw(_:)` fills the dirty rect with the plan's
  default background then calls `drawRenderFrame` from that pair only --
  never mixing generations, never reading view bounds for glyph geometry,
  painting background-only before the first plan. Redraw is
  `setNeedsDisplay` on plan delivery; no timers, no display link. A frame
  whose grid is stale against the view size is an acceptable transient: the
  size/scale change that made it stale also submitted the resize whose
  applied snapshot re-plans it.
- **Geometry sync** -- one choke point recomputing (metrics from
  `window.backingScaleFactor`, grid from bounds) on `setFrameSize`,
  `viewDidMoveToWindow`, `viewDidChangeBackingProperties`, and
  `refreshBackingProperties`. Non-positive frames and refused metrics skip
  everything and remember nothing (AppKit re-reports both inputs; recovery is
  event-driven); last-known-good metrics keep drawing valid meanwhile. A
  scale change that leaves the grid unchanged stores new metrics and redraws
  without host traffic.
- **Input** -- `keyDown` mirrors the TerminalView accumulator pattern:
  `interpretKeyEvents` routes composition (dead keys, IME) through
  `insertText`/`setMarkedText`; committed text becomes UTF-8 bytes through
  the ordered submission; non-text keys map through the pure encoder. PUA
  scalars never reach the pipe as text. Marked text is tracked for
  `NSTextInputClient` correctness but not rendered this slice.
  `sendText`/`sendInputText` submit UTF-8; `sendInputKey` maps through the
  encoder. First responder emits `.becameFirstResponder` through the gate.
- **Honest no-ops this slice**: `setFocused`, `setDisplayID`,
  `setScrollbarEnabled`, `applyTheme`/`clearTheme`, all search methods,
  `scroll(toRow:)`, `copySelection` (`hasSelection` false), `pasteClipboard`
  (user-pinned). `state` reports scrollbar disabled, `cellHeight` from
  metrics, no scroll position; re-emitted through the gate when metrics
  change. `requestClose()` emits `.closeRequested` immediately (no
  process-owned confirmation state exists).
- **Exit**: a child-originated result (exit or post-creation launch failure)
  emits exactly one `.closeRequested` through the gate -- the existing
  `.surfaceClosed` model flow closes the pane, matching Ghostty UX.
- **`SwiftTerminalBackend`** -- the session-request-to-`LaunchPolicyInput`
  assembly is a pure function in the session-controller target, taking the
  request's fields plus explicit ambient facts, so the seam is provable
  headlessly; the app adapter only gathers those facts (account shell via
  passwd/`SHELL`, executable checks, home, accessible dirs, inherited
  environment as ordered entries, the pinned advertised environment with
  `TERM_PROGRAM_VERSION` from the bundle) and calls it. Pane env comes from
  `request.environment` and command/launchCommand/restore behavior from the
  request; `request.waitAfterCommand` is dropped per doc 07. The
  initial grid is a fixed 80x24 constant threaded through both the host
  init and `LaunchPolicyInput.initialDimensions` (the `start()` guard makes
  two independently computed values a guaranteed launch failure); the first
  real layout submits the correcting resize, which the reducer buffers
  across spawn. `isReady` is true iff the bundled bootstrap resolves to an
  executable; false takes the existing AppDelegate not-ready exit. A nil
  controller returns nil from `createSession` -> the established
  `.surfaceCreationFailed` path. The backend keeps a registry that covers
  every host whose teardown has not completed -- including mid-close ones,
  which the ladder must still reach at app exit -- and retains no host past
  its own teardown. `preferences` empty,
  `configFilePath` nil, `reloadConfig`/`setAppFocused` no-ops.
- **AppDelegate**: replace the `fatalError` with the Swift backend. App
  termination: a new no-op-default backend hook runs during orderly
  termination -- after the final enriched checkpoint captures session text
  (cached snapshots keep serving it) -- applying
  `terminateForApplicationExit()` to every registered host concurrently
  within a bounded overall wait before process exit. Ghostty path
  behaviorally unchanged.

### Packaging, lint, build

- Root `Package.swift` gains `.package(path:)` dependencies on
  lib/TerminalCore and lib/TerminalPTY and the needed products
  (TerminalPaneSession, PaneLifecycle, TerminalRenderPlanning,
  TerminalRenderExecution). Package products, not source symlinks: the
  engine's internal-init protection (plans are only constructible by
  `planFrame`) and Swift 6 mode survive only across a module boundary; the
  app stays language-mode v5.
- `scripts/terminal-backend-boundary-lint.sh` gains a second rule mirroring
  the GhosttyKit one: engine-module imports in `app/` are allowed only in
  the new adapter files; the lint self-test covers both directions.
- `dev-build.sh` builds the `PTYSessionBootstrap` product explicitly and
  bundles it (Contents/Helpers precedent); the backend resolves it from the
  bundle. Release scripts are master-only and untouched.
- No `justfile` changes: `swift test --package-path lib/TerminalPTY` picks up
  the new target's tests; purity lints and test-ui are untouched.

## Invariants

- I1 (ordering): bytes and resizes submitted from the main actor are applied
  by the host in submission order, interleaved exactly as submitted; every
  byte accepted before teardown reaches the reducer before the close
  request; nothing submitted after teardown reaches the PTY.
- I2 (signal): while the session's consumer is active, every applied terminal
  mutation or result report is followed by at least one consumer resumption
  observing that state or a later one -- including the final drain that both
  reports the result and finishes teardown; at most one token is ever pending;
  no token after the signal terminates; an unchanged terminal produces zero
  tokens and zero scheduled work. After `tearDown()` the consumer is gone and
  buffered tokens are discarded (I6).
- I3 (render): every delivered plan is `planFrame` of a real host snapshot
  with the baked presentation; equal snapshots are never replanned; for a
  visible, non-torn-down session the final state before quiescence is always
  planned and drawn -- changes accrued while hidden are covered by I4's reveal
  frame.
- I4 (visibility): hidden panes plan and draw nothing while the host keeps
  consuming and their cached reads stay current; reveal after hidden output
  delivers exactly one complete current frame.
- I5 (boundary): the controller is the sole client of its host; PTY bytes,
  grid state, and render damage never cross into the Elm model; only plans,
  read-only cached snapshots, and closed-vocabulary events cross to app
  code; model, runtime, persistence, and the Ghostty backend are
  behaviorally unchanged, with engine imports lint-confined to the adapter
  files.
- I6 (teardown): after `tearDown()` returns, no event, state, or plan
  callback is delivered and no task, timer, or callback targets the session,
  view, or any deallocated object; the host converges to released resources
  on its own; releasing the session never blocks on the ladder.
- I7 (exit-once): a child-originated result produces exactly one
  `.closeRequested` through the gate; teardown-first produces none;
  `waitForResult` resumes nil when teardown completes without a result --
  no waiter is ever stranded.
- I8 (geometry): grid dimensions and metrics derive only from explicit frame
  and backing-scale inputs, changing as one unit; degenerate inputs change
  nothing and a following valid input converges to the correct grid; applied
  grids satisfy columns >= 2, rows >= 1; host init dimensions equal
  launch-input dimensions.
- I9 (draw): drawing consumes an atomically published (plan, metrics) pair
  produced together, paints background-only before the first plan, and a
  stale-grid frame is always followed by a correct one without timers.
- I10 (encoding): key encoding is a pure, AppKit-free function with
  fixture-pinned byte forms; committed macOS composition text reaches the
  PTY as its exact UTF-8; no Option-as-Alt.
- I11 (app exit): orderly termination applies the bounded ladder concurrently,
  within a bounded overall wait, to every host whose teardown has not
  completed -- live or mid-close -- while no host is reachable from the
  backend after its own teardown completes; the final checkpoint still
  captures session text, covering every mutation applied before the read.
- I12 (concurrency hygiene): all new package code compiles under Swift 6
  strict concurrency with no `@unchecked Sendable` and no
  `nonisolated(unsafe)`; every cross-isolation value is a Sendable value
  type.

## Proof obligations

- PO1 (I2): host signal contract -- token after fed output and after an
  applied resize; the drain that reports the result and finishes teardown
  still delivers its token, and a consumer that first reads after that drain
  still observes the result through a non-nil result accessor; a burst
  conflates to fewer tokens whose final pull observes the final bytes; a
  pull followed by more output yields another token (the re-signal race);
  after termination the census records zero further tokens.
- PO2 (I1): interleaved input/resize submissions from one main-actor context
  apply in exact order (extends the `orderedResize`/`inputWrites` idioms);
  submissions after teardown produce no transitions.
- PO3 (I3): with a stalled consumer, a write burst yields fewer plans than
  writes and the last plan renders the final state; a result-only token
  and an equal snapshot produce no plan.
- PO4 (I4): hidden output produces zero plans while cached reads show the
  output arrived; reveal delivers exactly one complete plan.
- PO5 (I7): shell exit produces exactly one session-ended emission;
  teardown-before-exit produces none; user-closing a live shell resolves
  `waitForResult` with nil promptly and a weak host reference dies (the
  stranded-waiter regression).
- PO6 (I6): after teardown, buffered tokens and queued callbacks deliver
  nothing, input submission no-ops, double teardown is safe, and weak
  controller/session references die while the host census reports released
  resources under rapid create/close stress.
- PO7 (I10): encoder fixtures pin every byte form in the table, including
  the full Ctrl range; encoding is total over its vocabulary.
- PO8 (I8): sizing fixtures pin floors, clamps, and nil on degenerate
  input; equal dimensions submit no resize; a scale change with an unchanged
  grid redraws the existing plan against the new metrics, replanning nothing
  and generating no host traffic; a degenerate-then-valid trace converges.
- PO9 (I1-I4 integration): one end-to-end controller test on a live PTY via
  the real bootstrap -- launch, resize to a known grid, send bytes, and
  await a delivered plan whose text runs contain the echoed output, inside
  `just test`.
- PO10 (I11): the termination sweep covers live and mid-close hosts, reaches
  no host whose teardown already completed, and completes bounded (builds on
  `applicationTerminationClosesMultipleLivePanes`); a checkpoint read taken at
  termination contains output the host applied immediately before it,
  including from a hidden pane.
- PO11 (I5): lint self-test passes in both directions; full `just test`
  stays green with no justfile edits; the diff leaves TerminalCore sources,
  PaneLifecycle behavior, and all model files untouched.
- PO12 (I5, I8, I9, view behavior; the slice's manual bar): with
  `DANTERM_TERMINAL_BACKEND=swift just build-run` -- prompt renders; typing,
  Return, arrows, Ctrl+C, and dead-key composition (option-e, e -> e-acute)
  work; `ls` and `cat` output render; pane resize reflows; a 1x/2x display
  move stays crisp; hide/reveal redraws completely; `exit` and pane close
  remove the pane; quit leaves no orphaned shells; a plain `just build-run`
  confirms the Ghostty default is unchanged.
- PO13 (I12): the Swift 6 strict build of the new package target is the
  compile-time proof; the app-side adapter contains no concurrency-bearing
  logic beyond delegation.
- PO14 (I8, launch seam): the request-to-launch-input assembly carries the
  requested working directory; places inherited, advertised, and pane
  environment entries in their respective layers without cross-contamination;
  includes every pinned advertised variable; carries command, launch command,
  and restore behavior exactly once; and produces launch dimensions equal to
  the host's init dimensions.

## Non-goals

- Selection, copy, paste (inert no-op; Milestone 6 owns paste policy),
  search, scrollback presentation and scroll-position reporting, themes and
  config, mouse reporting, hyperlinks, OSC title/cwd/notification events
  (the core has no OSC dispatch yet).
- Option-as-Alt and keys beyond the pinned table (unmapped keys drop).
- A terminal-to-child write-back channel (DA/DSR/CPR responses) -- the core
  never emits bytes; recorded as AR2.
- Damage/partial redraw, plan diffing, glyph caching, focus-dependent or
  blinking cursors, preedit rendering, performance work.
- The interactive viability harness, recordings, and sleep/wake proofs
  (slice 4); extending tests-ui (user-pinned).
- Release-script bundling changes (master-only; the experiment branch never
  releases).

## Accepted risks

- AR1: full replan and full-view redraw per update token -- correctness
  first; conflation bounds the rate; damage is Milestone 6.
- AR2: programs that query the terminal get no responses; the gate's
  command set does not require them.
- AR3: dead-key/IME preedit is invisible until committed; commit itself is
  correct.
- AR4: a cached `Terminal` value lives per pane on the main actor (CoW
  copy) to serve synchronous reads and checkpointing.
- AR5: inherited environment entries are name-sorted for deterministic
  launch input, diverging from raw environ order; last-layer-wins merging
  makes this behaviorally inert.
- AR6: resizes are submitted per quantized grid change with no debounce --
  reflow at human drag cadence is normal terminal behavior; a trailing-edge
  debounce in the policy layer is reserved if profiling demands it.
- AR7: the app-exit bounded wait can expire under pathological children;
  the ladder's kill stage has already been issued and process exit reclaims
  the rest.
- AR8: encoder byte choices (notably Backspace = 0x7F) and the 80x24
  initial grid are product decisions, fixture-pinned and reversible behind
  the same contract shape.

## Rejected ideas

- RI1: an actor-shaped session controller -- the `TerminalSession` protocol
  is synchronous `@MainActor`; an actor forces per-call unstructured Tasks,
  the exact cross-task ordering hazard, and makes synchronous
  `state`/`readViewportText` unimplementable.
- RI2: per-call `Task { await host.send(...) }` -- Swift tasks give no
  cross-task FIFO; ordering must be structural (one queue, one submitter).
- RI3: push-with-payload update callbacks -- queue stale snapshots
  unboundedly under bursts; the conflated signal-then-pull model is doc
  13's coalescing shape.
- RI4: building exit observation on `waitForResult()` as it stands --
  verified teardown paths never report a result and never resume result
  waiters, so a watcher task and the host leak on every user-closed pane;
  hence in-band exit via the signal plus the optional-result fix.
- RI5: symlinking engine sources into the app module (the DanTermCore
  pattern) -- would compile them as v5 app-module internals, dissolving the
  internal-init canonical-form protection and the Swift 6 guarantees.
- RI6: NSView or render metrics inside the engine package -- WindowServer
  obligations do not belong in the headless gate; scale stays an explicit
  view-side input.
- RI7: encoding on `KeyName`/`KeyMods` inside the engine package -- a
  package dependency on the root package is a cycle; the app maps
  vocabularies instead.
- RI8: timer- or display-link-driven redraw -- violates the event-driven
  idle-zero contract; needsDisplay from delivered plans suffices.
- RI9: deferring launch until the first nonzero layout -- adds a pre-launch
  state machine and a teardown-before-launch race for no benefit; the
  reducer already buffers a pre-spawn resize.
- RI10: teaching `AppRuntime` or the model about Swift sessions for app-exit
  teardown -- a backend-protocol hook keeps the runtime backend-agnostic.

## Implementation discretion

- All type, member, and file names (working names throughout); file splits
  within the new target and the app adapter; the signal's exact carrier and
  construction; the host-registry type and the app-exit cap constant.
- NSEvent-to-vocabulary mapping keyed by keyCode or PUA scalar; the bundled
  bootstrap filename and any dev-run override.
- Lint rule spelling, provided both self-test directions exist.
- Commit slicing, provided every commit is green and failing-test-first
  (repo TDD rule).

## Verification

`just test` is the acceptance gate: the existing
`swift test --package-path lib/TerminalPTY` line runs the host-signal and
controller suites (real PTYs, headless); the extended boundary lint and its
self-test run in the same gate; purity lints stay untouched and green. The
PO12 manual checklist is the view-layer bar, recorded when the slice closes.

## Commit progress

- [x] 1. Add ordered host submission and lifecycle update signaling
- [x] 2. Add the headless terminal pane session controller
- [ ] 3. Integrate Swift terminal sessions into the app and development build

## Implementation notes

- The synchronous session constructor uses a FIFO `submitStart` host entry point so
  launch is structurally ordered before the first input or layout submission.
- Controller teardown refreshes its cache through a synchronous owner-queue fence;
  `synchronizeState()` provides the corresponding synchronous fence for orderly app
  checkpoints before teardown begins.
