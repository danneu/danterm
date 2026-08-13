# Effect ports for the Command interpreter (S21)

## Problem

The Elm loop's effectful half has no automated coverage. `update` is pure and
tested to ~27k lines; `AppRuntime.perform(_ command:)` (`app/AppRuntime.swift`,
22 exhaustive arms over the 22 `Command` cases) interprets every command by
reaching ambient effects directly -- PTY fork via the stored backend,
`UNUserNotificationCenter.current()`, `NSSavePanel`, `NSAlert`,
`NSApp.terminate`/`activate` -- so no arm's command-to-effect mapping can be
asserted. `app/AppRuntime.swift` is the second-most-churned file in the repo
(129 commits in four months vs 24 for all of `app-tests/`); every regression in
it is found by hand.

Corrections to the audit finding (docs/scratch/2026-08-11-simplification-audit.md,
S21), established by exploration:

- `AppRuntime` is already constructible in a test:
  `app-tests/AppRuntimePendingIpcShutdownTests.swift` does it with
  `startsApplicationServices: false` and an injected config store. The gap is
  not constructibility; it is that the effects are unobservable.
- The switch is 22 arms over 22 cases, not the audit's 35/31; projection
  refactors already deleted the view-sync cases.
- The Ports seam does NOT retire `test-ui.sh` or the `#if DANTERM_UI_TEST`
  machinery. That needs a view-facing runtime protocol plus a controller
  protocol for `SwiftTerminalSessionView` -- a different seam facing the
  opposite direction. It stays a named follow-up (see Non-goals); the audit's
  "one refactor closes two holes" claim is withdrawn.

## Desired outcome

Every `Command` case is dispatched through the real `perform` by at least one
test in `app-tests/` that asserts its external effect -- at a recording port,
on a fake session, or as bytes on a real IPC socketpair. The 22 arms become 22
assertable command-to-effect mappings, and a new arm cannot land without a
place to assert it.

## Decision

Adjudication rule first (audit theme T2, shared with S12/S20): **constructor
injection of collaborators is the fix; conditional test-only branches in
production paths are the disease.** Nothing in this plan adds an `#if`, a test
mode, or a branch only a test takes. `startsApplicationServices` stays as-is:
it gates init-time services, and is constructor configuration, not a branch.

The mechanism:

- **One flat closure-struct ports value** in `app/`, in the established
  `CoreEnv` / `DoctorPermissionProbeDependencies` style: closures plus a live
  constructor, injected through `AppRuntime.init` in place of the stored
  `terminalBackend`. The live value is constructible before the runtime
  exists and its closures never capture the runtime.
- **Ports cover only the ambient effects**: session creation (PTY fork),
  notification delivery, save-destination prompting, alert presentation,
  doctor permission probing, and app termination/activation. The
  authorization-gated notification enqueue and its policy move into the live
  implementation; the arm keeps content assembly (title/subtitle/body,
  thread-identifier-per-pane stacking, alert-id userInfo) so tests assert it.
- **Everything else keeps its existing, stronger seam.** Session input, focus,
  and search arms drive the `TerminalSession` protocol through the session
  table (a fake session installed via the create-session port). The eight IPC
  arms are asserted as real bytes on a `socketpair()`-backed `IpcConnection`,
  the pattern the shutdown test already proves. Scheduling stays on the
  existing `AppRuntimeSchedulingLifecycle` census, whose owner counts are a
  designed observable.
- **Msg emission is not a port.** `perform` re-enters `self.send` for its five
  synchronous emissions and its async completions, so the test loop and the
  production loop are the same code path.
- **`perform` stays a method on `AppRuntime`**, becomes `internal` so
  `@testable` tests can drive single commands directly. All state it mutates
  (sessions, pane hosts, debouncers, replay files, connections, tape-follow
  bookkeeping) stays runtime-owned.
- **The two static `CheckpointWriter`s become instance-owned.** The export
  write stays real in tests: the test's port supplies a temp URL and the
  assertion decodes the file the writer produced. The export completion
  captures the writer value, not the runtime, preserving today's
  no-self-capture shape.

Ordering constraint: the create-session path eagerly builds `PaneHost` view
chrome, and no current app-test constructs any view. A canary test proving
`PaneHost` constructs under headless `swift test` lands before anything
depends on it. If it fails, the direction is decided here and not improvised:
the create-session port widens from "make a session" to "make a session and
its pane host", so the fake supplies both and no test constructs view chrome.
The arms then assert the port call and the resulting session-table
registration, and I1's coverage of the create-session case is unchanged.

Sequencing against neighbors: S22 (merge `sessions`/`paneHosts`) rewrites
lookups inside arms; the port surface never names those tables, so neither
change blocks the other and whichever lands second rebases mechanically.

On completion, record the closing commit hashes in the audit's S21 row,
following the audit's completion convention.

## Invariants

- **I1.** Every `Command` case has at least one test driving the real
  `perform` and asserting its external effect. No test asserts the structure
  of a private helper.
- **I2.** After the migration, `perform` and its helpers contain no direct
  reference to `NSApp`, `UNUserNotificationCenter`, `NSSavePanel`, or
  `NSAlert`; those live only in the ports file's live implementations.
- **I3.** `perform` emits messages only via `self.send`; test dispatch and
  production dispatch are the same loop.
- **I4.** Within one `send`, commands perform in order, and a synchronous
  re-entrant `send` completes (update plus perform) before the outer arm
  continues.
- **I5.** Ports carry effects, not state: no port closure stores or shadows
  the runtime's session, host, connection, or subscription tables.
- **I6.** Shutdown ordering is unchanged: `.runtimeWillShutdown` commands
  still write pending IPC errors before transports close, and a retired IPC
  reply leaves its socket open (EOF only at shutdown).
- **I7.** No port closure captures the runtime; the live ports value is
  constructible before the runtime exists.
- **I8.** Boundaries hold: `Command` stays in pure DanTermCore, the ports
  value lives in `app/`, the terminal-backend import allowlist does not
  widen, and `test-ui.sh` plus both UI-test shims are byte-for-byte
  untouched.

## Proof obligations

- **PO1** (I1): the new app-tests suites; reviewable by diffing `Command`
  cases against tests. Representative shapes: a recorded notification request
  carrying the pane-thread and alert-id mapping; a fake session that received
  the sent text/key/focus/search calls; an IPC reply read back as JSON-RPC
  bytes; an export file decoded and checked for snapshot content, fake
  scrollback, and pretty-printing; terminate observed as zero remaining timer
  owners in the census, replay files removed, and one terminate-port call.
- **PO2** (I4): three parts. Re-entry: the config-save failure path -- an
  unwritable config store plus assertions that the alert was recorded AND the
  model's resolved font family updated before `perform` returned; and the
  input-rejection path -- a pending submission whose rejection arrives as bytes
  on the socketpair. Ordering: one test drives `send` with a message that
  produces several commands and asserts their externally observable order at
  the ports and the wire, so a reordering of the outer dispatch loop fails a
  test rather than passing every per-arm suite.
- **PO3** (I6): `AppRuntimePendingIpcShutdownTests` passes with only its
  construction line changed, and an IPC-reply test asserts the socket stays
  open after the reply.
- **PO4** (I2, I8): read `perform` and the effect helpers its arms reach, and
  confirm none of the four ambient names appears there. This is inspection of
  that call graph, not a repo-wide grep: AppDelegate, Reconcile, the popover
  and overlay views, `main.swift`, and AppRuntime's own non-`perform` alert
  paths use these names legitimately and stay untouched. The existing gate
  lints (core purity, backend boundary) and the untouched `test-ui.sh` cover
  the rest.
- **PO5** (headless canary): `PaneHost` with a fake session constructs under
  headless `swift test` -- the first slice.
- **PO6** (I7): review against docs/design/2026-06-09-appkit-lifetime-safety.md;
  the export-completion capture is the named hazard site.

Verification entry point: `just test` (the root-package step picks up new
app-tests automatically); targeted iteration via
`swift test --scratch-path .build-app-tests --filter <suite>`.

## Non-goals

- The view-facing runtime protocol, the `SwiftTerminalSessionView` controller
  protocol, and retiring `test-ui.sh` / `#if DANTERM_UI_TEST` / the
  `UITestRunner` registration list. That is the other half of the 2026-08-06
  ADR's "way out" and a separate plan; this plan must not touch it.
- Behavioral coverage for the notification authorization gating itself; it
  gains a seam here, not tests.
- A directory seam for `RecoveryStore`'s zero-arg checkpoint URL functions
  (named follow-up; see AR1).
- S22/S23/S24 stored-property cleanups, tracked separately.

## Accepted risks

- **AR1.** App-tests that route through `send` can arm a real light-checkpoint
  timer aimed at the identity's real recovery path, because the checkpoint URL
  functions have no directory seam. Mitigation: arm-mapping tests drive
  `perform` directly (checkpoint scheduling lives in `send`), and every
  runtime-constructing test shuts the runtime down in teardown, which cancels
  armed timers via the census. The URL seam is the named follow-up.
- **AR2.** Re-entrant sends run the real reconcile pass headless, which no
  test exercises today. The first re-entry test is the proof; if a pass
  touches WindowServer state, the fix is a nil-guard in that pass, never a
  faked loop (I3).
- **AR3.** Un-static-ing the writers assumes `CheckpointWriter` completes
  queued writes when its owner is released; verify against the class before
  relying on it in teardown-heavy tests.

## Rejected ideas

- **RI1. Extract a `CommandInterpreter` type owning the session/host state.**
  The state has two legitimate clients (perform and the reconciler/restore
  paths); an owning interpreter either back-references the runtime or shares
  the tables, recreating the two-owners shape S22 exists to kill. Testability
  gain over injected ports is zero, since the runtime already constructs
  headless.
- **RI2. An injectable Msg-emit port.** Lets a test record messages that never
  hit `update`, so the tested loop diverges from the production loop; re-entry
  is observable through model and wire consequences instead.
- **RI3. An `IpcConnection` protocol.** The socketpair wire is a stronger
  observation point than a recorded method call, and the pattern already
  exists in the shutdown test.
- **RI4. Clipboard or NSWorkspace ports.** No arm reaches either; the audit's
  mention was speculative.

## Implementation discretion

- The exact ports member list, closure signatures, naming, and the recording
  fixture / fake-session shapes.
- Whether `Command` gains `Equatable` for test convenience.

## Commit progress

- [x] 1. test(app): prove pane hosts construct headlessly
- [x] 2. refactor(app): inject ambient-effect ports into the command interpreter
- [ ] 3. test(app): cover session and scheduling command dispatch
- [ ] 4. test(app): cover IPC dispatch, re-entry, and command ordering
