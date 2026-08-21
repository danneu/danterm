# The UI Suite Is an Ordinary Test Target, Behind Three Named Seams

- Status: Accepted
- Date: 2026-08-21
- Supersedes: [2026-08-06: The AppKit UI Harness Is a Whole-Module Substitution Seam, Not a Test Target](2026-08-06-ui-harness-whole-module-substitution.md)

## Context

[2026-08-06: The AppKit UI Harness Is a Whole-Module Substitution Seam, Not a
Test Target](2026-08-06-ui-harness-whole-module-substitution.md) decided to keep
`test-ui.sh`, a raw `swiftc` build over a hand-maintained list of source paths.
Its central finding was that the views take a concrete `AppRuntime` no test can
construct, because `AppRuntime.init` reads the user's config, installs a
process-global event monitor, and binds the live IPC control socket.

That finding no longer holds. `AppRuntime` takes its ports, dialog surfaces,
instance paths, and config store as arguments, and gates the event monitor and
the IPC server behind `startsApplicationServices`. `DanTermAppTests` constructs
one headlessly today and builds a `PaneHost` over it. Given an explicit initial
model, the runtime never reads the user's config file at all.

What the UI suite actually lacked from the real runtime was not construction but
**observation**: the ability to read which `Msg` a view reported without the
reducer, the reconcile sweep, and the command interpreter running behind every
click.

The cost of the bespoke build was measured before the change: two interleaved
runs compiled 131 files in 44s and 55s and ran 386 cases in 11s, so effectively
all of `just test-ui` was a build repeating work no edit touched. A SwiftPM test
target over the same app rebuilds in 2.0s after one production view file
changes.

## Decision

**D1 -- `tests-ui` is an ordinary SwiftPM test target.** No script names the
suite's individual source files.

**D2 -- The pane view names its engine collaborators through three seams, each
defaulting to the shipping implementation.** `SwiftTerminalSessionView` drives a
live terminal, and each of its collaborators is a thing a test cannot build:

- the **session controller**, whose production initializer forks a PTY child;
- the **rotation of buffers it presents**, a final engine type a test cannot
  wrap;
- the **resolver from a font choice to cell geometry**, whose real answer reads
  the machine's installed fonts.

The third is a seam for a reason the other two do not share: the pane must fall
back when a face has no usable cell box, and that behavior has to be provable
without depending on which faces a given machine has installed.

**D3 -- The flight recorder is a separate protocol, not part of the controller
seam.** A recorder fence is a value only a live recorder can mint. A session
that records a tape says so by conforming; a session with no recorder serves no
tape, and every pane-tape entry point answers nothing. Stating that by
conformance is clearer than a controller protocol whose recording half must
return nothing.

**D4 -- The runtime is substituted at its message entry point, not behind a
protocol.** The UI suite subclasses the real `AppRuntime` and overrides
`send(_:)`. A protocol would only re-describe a type the suite can already
build. Two consequences bind: `send(_:)` stays overridable, and every route a
`Msg` takes into the runtime -- a direct send, or a fact a view reported through
the outbox -- passes through it, so no class of report is invisible to the
substitution.

**D5 -- A target that cannot run headless declares it, and the gate reads the
declaration.** `DanTermUITests` carries `DANTERM_REQUIRES_WINDOWSERVER` in its
`swiftSettings`, and `scripts/gate-test-coverage-lint.py` requires the gate lane
over that package to skip it by name. The manifest that owns the target is the one
place this is said; no check keeps a list of excluded names, and a lane that merely
fails to reach the estate is not accepted as an exclusion.

**D6 -- The suite suspends; it does not spin a run loop.** The suite runs inside a
main-queue work item, and a serial queue does not re-enter itself, so a nested
`RunLoop.run` cannot deliver a block the code under test just posted. Every wait is
a suspension, which releases the work item and lets the queue drain.

**D7 -- No production source selects a test's collaborators on a build flag.**
`DANTERM_UI_TEST` is gone. Where it guarded an engine import so a fake would
win, a seam replaced it. Where it hid a forced branch in the sidebar, the branch
became one given cell lookup: "on screen but not yet materialized" is a real
state the reconcile loop retries through, and nothing else can put AppKit into
it on demand.

## Consequences

- The per-view "promotion" ritual is gone, and with it the silent list rot.
- Measured after the move, against 44s and 55s to build plus 11s to run before it:
  a cold run is 40s, a run after one production view file changes is 17s, and a
  run with nothing changed is 11.5s. The suite's own execution is about 10s of
  each, so the build fell from most of the wall clock to a few seconds of it.
- **The move exposed a real over-release.** Test windows are created
  programmatically, so `isReleasedWhenClosed` defaults to true and `close()`
  released a window ARC still owned. The bespoke harness never popped an
  autorelease pool, so the freed memory was never touched again; a suspending
  suite pops one at every await, and the double free became a reproducible
  segfault in `objc_autoreleasePoolPop`. The suite now clears the flag on the
  windows it owns.
- The suite is one Swift Testing case driving the existing `uiTest` runner, not
  386 `@Test` functions. Converting each case as well would have made a behavior
  regression indistinguishable from a conversion slip; that conversion is a
  follow-up.
- The UI suite stays out of `just test`: it needs a WindowServer connection.
- Cell geometry can no longer be fabricated -- the engine's metrics carry a
  measured font set -- so pane-geometry cases state their expectation relative
  to the metrics they were given rather than against a fixed cell box.
- Every seam here is a constructor-injected collaborator, the first of the three
  legal routes in
  [2026-08-17: The Test-Seam Rule](2026-08-17-test-seam-rule.md). No production
  component asks whether it is under test.
- The seams are dependency injection in production code, which the superseded
  note declined to smuggle in as test plumbing. They are taken here on their own
  merits: each one names a collaborator the view already had, and each defaults
  to the shipping implementation.
