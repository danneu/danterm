# Frame-aware dispatch: a re-entrant send never re-enters update()

## Context

Commit cb827f40 fixed a crash: during a reconcile pass, hiding the active
General-settings field made AppKit synchronously call
`controlTextDidEndEditing`, which called `runtime.send(.prefSave)` and
re-entered reconcile against a projection cache the outer pass still held
`inout`. The fix rerouted that one call site through `outbox.report`.

That is call-site discipline, and the bug class survives it: ~50 other
`runtime.send(...)` sites in view code are each one AppKit-laundered edge away
from the same crash. Worse, the codebase already claims the backstop exists:
the `ReconcileFollowUps` doc comment (app/DanTermCore/ReconcileFollowUps.swift:12),
the reconciliation ADR (docs/design/2026-05-27-model-driven-view-reconciliation.md:174),
and the `reconcile-pass-lint.sh` header all say a send arriving while a sweep
is in flight "accumulates into the frame already running instead of
dispatching itself." Today that is true only of `report()`; a direct `send()`
mid-frame runs `dispatchInFrame` synchronously. This plan makes the documented
invariant actually true, at the one place frames are known.

Evidence the change is safe (full audit, 2026-08-21, all 131 `.send(` sites in
app/):

- Zero sites send inside a frame and then read the model. The only
  send-then-read cluster, `TodoPopoverController`'s select-after-mutate
  helpers (app/TodoPopoverController.swift:473-842), is reachable solely from
  top-of-stack user events, where dispatch stays synchronous.
- All five in-frame sends inside `perform(_:)` (app/AppRuntime.swift:803-889)
  are terminal statements in their switch arm; nothing reads after them.
- Precedent: TCA's `Store.send` shipped this exact design (`isSending` +
  `bufferedActions`) for years. It later deprecated *user-originated*
  reentrancy because that is fixable at the source; ours is AppKit-laundered
  and is not, so defined buffering is the right call here -- defined by the
  ADR, pinned by tests.

## Decision

Make the single dispatch entry frame-aware. In `AppRuntime.dispatch`
(app/AppRuntime.swift:466): if a send frame is already open, enqueue the
message through the outbox's existing report/drain path; otherwise dispatch
synchronously inside a new frame, as today. The frame-open predicate is pure
ordering logic and belongs with `ReconcileFollowUps`
(lib/DanTermCore/Sources/DanTermCore/ReconcileFollowUps.swift, symlinked into
app/), surfaced through `ReconcileOutbox` (app/ReconcileOutbox.swift), which
currently exposes no depth query.

The check lives in `dispatch`, not in the overridable `send`: the UI suite's
`RecordingAppRuntime` (tests-ui/UITestRuntime.swift:54) overrides `send` and
never reaches `dispatch`, so a check in `send` would be bypassed by every
subclass.

Decisive constraints:

- `send` stays the one entry point; the drain dispatcher already routes
  through it (app/AppRuntime.swift:289), so test subclasses keep seeing every
  message, deferred or not.
- cb827f40's call site stays on `outbox.report`; its UI regression test
  (tests-ui/PreferencesPanelTests.swift:382) stays as-is and must stay green.
- No view call site changes. The refactor is one branch plus one predicate.

Docs travel with the behavior: update the ADR's backstop paragraph and the
`ReconcileFollowUps` / `ReconcileOutbox` doc comments so they describe an
enforced invariant rather than an aspiration, citing the 2026-08-21 incident.
Extend the comment at app/TodoPopoverController.swift:470 to state the
top-of-stack dependency its select-after-send helpers rely on.

## Invariants

- I1: `update()` never re-enters. While a send frame is open, no path --
  direct send included -- runs a second dispatch inside it.
- I2: a message sent while a frame is open is delivered when the outermost
  frame exits, FIFO with everything else the frame accumulated.
- I3: a send with no frame open dispatches synchronously -- the model is
  updated before `send` returns. (Top-of-stack event handlers, including the
  TodoPopoverController cluster, depend on this.)
- I4: every message, direct or deferred, arrives through the overridable
  `send` entry point.
- I5: after scheduling-lifecycle shutdown, no message is dispatched, queued or
  direct. (Existing behavior: the outbox may still accept and queue a
  post-shutdown report; the lifecycle guard in front of dispatch is what drops
  it. Preserved as-is.)

## Proof obligations

- PO1 (I1, I2): with the real runtime and reducer, a send issued inside an
  open outbox frame mutates no model state until the frame exits, and has
  mutated it afterward; two such sends land in order. Belongs in app-tests/
  beside AppRuntimeSendEntryPointTests.swift -- the UI suite cannot exercise
  this path because `RecordingAppRuntime` stops messages at `send`.
- PO2 (I2, pure layer): the frame-open predicate and release ordering on
  `ReconcileFollowUps`, in
  lib/DanTermCore/Tests/DanTermCoreTests/ReconcileFollowUpTests.swift.
- PO3 (I3): a send with no frame open is observable synchronously. Existing
  suites pin this broadly; add an explicit case beside PO1 if none does.
- PO4 (I4): already pinned by app-tests/AppRuntimeSendEntryPointTests.swift
  and tests-ui/PreferencesPanelTests.swift:382; both must stay green.
- PO5 (I5): the lifecycle guard still runs before any actual dispatch --
  queuing post-shutdown is permitted, dispatching is not. No new test unless
  the implementation moves the guard relative to the queue.

## Non-goals

- Migrating view call sites from `send` to `report` (either direction).
- An awaitable or completion-carrying `send`.
- A runtime warning or telemetry on deferral.

## Accepted risks

- AR1: future in-frame code that sends and then reads the model sees the
  pre-send model. The pattern is already outlawed by the ADR, currently has
  zero instances, and the updated comments name the dependency; a violation
  degrades to stale-read behavior instead of a cache-corruption crash.
- AR2: the UI suite cannot detect a regression in this routing (its runtime
  bypasses `dispatch`); PO1 in app-tests/ is the sole automated guard, which
  is why it is a blocking obligation, not optional coverage.

## Rejected ideas

- RI1: awaitable dispatch to preserve send-then-read. The callers that would
  need it are synchronous AppKit delegates that cannot await; on the main
  actor an await inside an open frame cannot resume before the frame exits
  anyway; and interleaving at the suspension point yields a weaker guarantee
  than the synchronous read it replaces.
- RI2: ban re-entrant sends outright (ReSwift, TCA 2.0 direction). Their
  reentrancy is user code fixable at the source; ours arrives through AppKit
  edges no sender can see, so a ban is just the crash with a better message.
- RI3: Elm-style "views only report, never send." Equivalent safety to this
  plan but costs a ~50-site migration and, for top-of-stack events, either
  loses same-turn dispatch or reinvents this plan's branch inside `report`.

## Implementation discretion

- Whether the frame-open branch reads a forwarded predicate in `dispatch` or
  moves wholly into a single outbox delivery method, provided the
  scheduling-lifecycle guard keeps its current drop semantics (I5).
- Whether `dispatchInFrame` gains a debug-build re-entrancy assertion as a
  tripwire for future non-dispatch frame openers.

## Verification

- `swift test --package-path lib/DanTermCore --filter ReconcileFollowUp` (PO2)
- `just test` before commit (runs app-tests: PO1, PO3, PO4; plus lints --
  reconcile-pass-lint self-test must still pass)
- `just test-ui` once, for the cb827f40 regression test and the rest of the
  preferences/todo suites (PO4, and confirms the top-of-stack sites of I3
  still behave)

## Commit progress

- [x] 1. fix(runtime): defer re-entrant sends until the outer frame exits
