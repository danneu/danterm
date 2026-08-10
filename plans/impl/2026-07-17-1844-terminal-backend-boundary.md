# Terminal backend boundary and Ghostty adapter

Completes roadmap milestone 1 (plan-terminal-engine/14-roadmap.md) before
milestone 2 starts the Swift terminal core. Governing contracts: plan-terminal-engine/02-migration-and-
boundary.md, 03-engine-architecture.md, 06-inspection-recovery.md.

## Problem

DanTerm's runtime is hard-wired to libghostty. `AppRuntime`, `Reconcile`, and
`ScrollableTerminalView` reach through `surfaces[paneId]?.surface` and call
`ghostty_surface_*` inline (~50 call sites, ~35 of them in `TerminalView`);
surface creation is hard-wired to `TerminalView(ghosttyApp:...)`; product
events reach the model only through adapter-constructed Msgs sent via
`weak var runtime` backrefs in `GhosttyApp` and `TerminalView`. The Swift
engine cannot be developed behind this. Milestone 1 requires an app-owned
terminal boundary that models DanTerm's needs (not a one-for-one libghostty
wrapper), the existing Ghostty implementation routed through it without
behavior change, and a development-only backend-selection seam -- without
implementing the Swift backend.

Load-bearing premises (verified in exploration):

- The pure core and DanTermSupport have zero GhosttyKit references; Msgs and
  Commands are already backend-agnostic and PaneId-keyed.
- `AppRuntime.surfaces: [PaneId: TerminalView]` is the single ownership root;
  `TerminalView` owns the `ghostty_surface_t`; teardown is the reconciler
  projection `reconcileSurfaceExistence` (there is no destroy command); pane
  moves reparent the same view via `surfaceLookup`, never recreating surfaces.
- Creation failure today: a dead view is stored, `.surfaceCreationFailed`
  removes the whole containing tab (no alert); the restore staging path
  throws and falls back instead.
- `TerminalView` pushes scrollbar state (per-session enablement,
  total/offset/length, cell height) synchronously to its enclosing scroll
  chrome (`ScrollableTerminalView`) via a concrete delegate; the native
  scroll view's document height and thumb position are derived from those
  pushes, so a boundary without this channel leaves them stale.
- The characterization harness (`scripts/terminal-characterization.sh`,
  fixture `fixtures/terminal-characterization/ghostty-inspection-recovery.json`,
  run via `DANTERM_TERMINAL_ENGINE_TEST_ALLOW_APP_CONTROL=1 just
  test-terminal-characterization`, GUI + Accessibility required) pins the
  runtime text-extraction and recovery behavior byte-exactly through the
  shipped `danterm pane read` IPC path and the enriched recovery checkpoint.

## Decision

Introduce two app-owned protocols in `app/` (no GhosttyKit import), conformed
to by the existing types -- no wrapper objects, no new ownership layer:

- A per-pane **terminal session** protocol, conformed by `TerminalView`. It
  provides the stable, reparentable, first-responder-capable host view the
  reconciler mounts, and the operations DanTerm consumes per pane:
  programmatic text/key input (IPC commands), terminal focus, occlusion,
  display change, theme apply/clear, search (typed operations, not
  binding-action strings), viewport and full-history text reads (the
  characterization-pinned projections), selection presence + copy/paste,
  scrollbar values + scroll-to-row, polite close request, and teardown.
- A **terminal backend** protocol, conformed by `GhosttyApp`: session
  creation (which can fail), app-level focus, configuration reload,
  preferences reads for the prefs panel, config-file path for the menu.

Events cross the boundary as **typed event enums** (user decision,
2026-07-17): a per-session event enum -- titleChanged, cwdChanged, bell,
desktopNotification, progress, searchStarted, searchTotal, searchSelected,
becameFirstResponder, closeRequested -- and a backend event enum --
configReloaded, configChanged (prefs + scrollbar), quitRequested. Both enums
plus a pure event->Msg translation function live in DanTermCore (pure,
lint-clean, unit-tested). The runtime installs a per-session `onEvent`
closure at creation and the backend's at init; `GhosttyApp.handleAction`'s
product cases and `close_surface_cb` emit events instead of Msgs, and the
`weak var runtime` backrefs in `GhosttyApp` and `TerminalView` are deleted.
The event enums are the compiler-enforced vocabulary a backend may emit and
double as the milestone-2 contract in code.

Scrollbar state (per-session enablement, total/offset/length, cell height)
crosses the boundary as a second, equally closed channel: a main-actor,
view-local session-state observation consumed directly by the app's scroll
chrome. It stays outside `Msg` and the model -- it is view state, not
product state -- and obeys the same main-actor and no-delivery-after-
teardown rules as the event enums (I5).

Stays backend-private (never crosses the boundary): interactive keyboard/
mouse/IME/paste translation and geometry sync (the host view owns them, per
03's effectful-boundary table -- the app consumes interactive input by
mounting the host view), rendering, wakeup/tick, config handles and theme
file layering, clipboard completion handshakes, binding-action strings, text
decode, and the `SurfaceBridge` retention discipline. The 2026-06-09
lifetime invariants (retained bridge userdata, weak view backref, deferred
`ghostty_surface_free` on the next main-actor turn, bridge released after
free) move nowhere and change in no way.

Creation failure becomes a failable factory: on failure the runtime sends
`.surfaceCreationFailed` without storing a dead host (observably identical:
update removes the tab either way, and reconcile has nothing to tear down);
the restore staging path keeps its throw/discard/fallback shape.

Backend selection: `DANTERM_TERMINAL_BACKEND=ghostty|swift`, read once at
launch, resolved by a pure core function, default `ghostty`; `swift` fails
loudly (not implemented yet). Chosen over a build flag (same-binary A/B runs
are needed for the eventual dual-backend proofs, and the characterization
harness already selects behavior via env vars) and over a hidden preference
(persisted ambient state is exactly what a dev facility must not be).
`ghostty_init` in `main.swift` stays unconditional while Ghostty is linked.

A boundary lint (grep, alongside `scripts/core-purity-lint.sh`, in `just
test`) restricts `import GhosttyKit` to the adapter allowlist:
`TerminalView.swift` (+ its session extension), `GhosttyApp.swift`,
`GhosttyBindingAction.swift`, `GhosttyText.swift`, `main.swift`.
`AppDelegate.swift` imports GhosttyKit today without making any raw
framework call; the import is deleted rather than allowlisted, so launch
code stays behind the backend protocol. The tests-ui shim conforms to the
session protocol, and its GhosttyKit-free compile proves the protocol
itself carries no GhosttyKit dependency.

Ordering constraints (dependencies, not a commit script):

- Boundary types and the event->Msg translation exist and are unit-tested
  before any consumer rewires.
- The text-read-path motion and the ownership/creation retype are each
  bracketed by a green characterization run against the unchanged fixture.
- Every slice keeps `just test` and `just test-ui` green.

## Invariants

- I1. No observable behavior change: pane, tab, split, alert, persistence,
  and IPC behavior -- and the characterization corpus bytes -- are identical
  before and after. The fixture is never re-golded on this branch.
- I2. Model/update logic never knows which backend owns a pane; backend
  selection never enters `AppModel`, snapshots, or checkpoints.
- I3. One terminal owner per pane: a single session handle per pane, owned in
  one place; teardown remains a reconciler projection.
- I4. Outside the adapter allowlist, app code has no GhosttyKit dependency
  (lint-enforced).
- I5. A backend can emit only the closed boundary vocabulary: the typed
  product event enums (which become Msgs) and the scrollbar session-state
  observation. Both are delivered on the main actor and never after session
  teardown; all 2026-06-09 callback-lifetime invariants hold through create,
  move, hide, resize, failure, close, restore, and teardown.
- I6. The host view's identity is stable for the session's life; pane moves
  reparent, never recreate.
- I7. PTY bytes, grid state, and render damage never cross the boundary --
  no protocol surface can carry them.
- I8. Selecting the unimplemented `swift` backend fails loudly; it cannot
  silently run Ghostty.

## Proof obligations

- PO1 (I1, I7). Characterization harness green, byte-identical fixture,
  after the read-path motion and after the ownership retype.
- PO2 (I1, I3, I5, I6). `just test` + `just test-ui` green per slice, plus
  one manual QA pass over the lifecycle matrix: create, split, move pane
  across tabs, zoom, tab hide/show, resize, display change, per-pane theme
  set/clear, full search cycle, scrollbar drag + wheel + range/thumb
  tracking as output grows history, copy/paste incl.
  context menu and copy-on-select, IME dead keys, drag-drop, close pane with
  confirmation, shell exit, quit + enriched restore, crash restore,
  export/import, `--init`.
- PO3 (I5). Unit tests pin the complete event->Msg translation table; a test
  proves no event and no session-state observation is delivered after
  teardown.
- PO4 (I2, I8). Resolver unit tests; launches with env unset and `=ghostty`
  behave identically; `=swift` fails loudly.
- PO5 (I4). The boundary lint fails when a non-allowlisted file imports
  GhosttyKit (shell self-test, like the existing lint tests).
- PO6 (I6). A test or scripted check proves the same host view instance
  survives a container rebuild triggered by a pane move.
- PO7 (I1, I5). Ghostty adapter conformance: driving the adapter's real
  callback surface (product action cases -- title, cwd, bell, notification,
  progress -- plus close-surface and config change/reload) and the CLI
  text/structured-key input path yields exactly the pinned typed events and
  the same observable PTY/model outcomes as before the rewiring, by whatever
  vehicle (targeted adapter test or scripted harness) is practical.

## Non-goals

- Implementing the Swift backend, or any headless session/PTY/grid
  abstraction beneath the boundary (milestones 2-4; Ghostty offers no such
  decomposition to conform to).
- Renaming Ghostty-flavored core names (`GhosttyPrefs`,
  `.ghosttyConfigReloaded`, ...) -- cosmetic, nothing persisted depends on
  them.
- Per-pane backend mixing; selection is process-wide.
- Abstracting configuration beyond theme apply/clear + reload + prefs reads.
- Unlinking GhosttyKit or conditionalizing `ghostty_init` (milestone 10).
- A dual-backend lifecycle scenario suite -- 02's "while both exist"
  obligation needs two real subjects; it lands with the Swift backend.
- Event coverage for Ghostty-private actions (render, mouse shape, size
  limits, close window, open URL): they stay adapter-internal.

## Accepted risks

- The characterization gate is manual and GUI-bound; mitigated by naming it
  an explicit exit gate of the two bracketed stages rather than relying on
  CI.
- The event rewiring touches callback-path code where lifetime bugs live;
  mitigated by the bracketing characterization gates, PO3, and PO7.
- Two argued behavioral equivalences to re-verify during QA: not storing a
  dead host on creation failure, and an event racing final teardown being
  dropped rather than sent as a Msg that update ignores.
- The deferred-free `nsview` assumption remains upstream-dependent on
  Ghostty upgrades (unchanged from today, recorded in the 2026-06-09 ADR).

## Rejected ideas

- A generic abstraction over every libghostty call -- rejected by 02; it
  would preserve the shape of the dependency being removed. Interactive
  input, geometry, and rendering therefore stay inside the backend host view.
- The Msg vocabulary as the event contract (documented subset, injected send
  closure) -- lower churn, but enforcement would be review discipline instead
  of types, and the Swift backend would reverse-engineer its obligations from
  the adapter. Typed enums chosen 2026-07-17.
- Wrapper session objects around `TerminalView` -- new ownership layer with
  no consumer; the existing types conform directly.
- Build-flag or hidden-preference backend selection -- see Decision.

## Implementation discretion

- Exact protocol, type, and file names; whether the session protocol is
  NSView-constrained or exposes a host-view property (both satisfy I6).
- The concrete mechanism of the scrollbar session-state observation
  (delegate protocol, closures, or observed properties).
- Slicing and commit boundaries within the stated ordering constraints.
- Handling of unrecognized `DANTERM_TERMINAL_BACKEND` values.
- Whether focus/bell border chrome moves app-side now or remains a session
  method.
