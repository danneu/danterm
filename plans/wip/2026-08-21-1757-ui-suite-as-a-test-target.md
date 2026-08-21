# The UI Suite Becomes an Ordinary Test Target

## Problem

`test-ui.sh` compiles the UI suite with a raw `swiftc` invocation over a
hand-maintained list of 131 source paths, into a fresh `mktemp -d` on every
run. Two costs follow.

The list rots. A file that a promoted view starts using breaks `just test-ui`
and nothing else, and the only way to add a view to the suite is to edit the
list by hand.

The build is cold by construction. Measured over two interleaved runs on the
current tree: 44s and 55s to compile, 11s to run 386 cases -- so roughly 100%
of `just test-ui` is a build that repeats work no edit touched. For comparison,
the existing `DanTermAppTests` target rebuilds in 2.0s after one production
view file changes, and 1.5s after one test file changes.

[docs/design/2026-08-06-ui-harness-whole-module-substitution.md](../../docs/design/2026-08-06-ui-harness-whole-module-substitution.md)
recorded a decision to keep the bespoke build, on the finding that the views
take a concrete `AppRuntime` no test can construct. **That finding is stale.**
`AppRuntime` already takes its ports, dialog surfaces, instance paths, and
config store as arguments and already gates the NSEvent monitor and the IPC
socket behind `startsApplicationServices`. `app-tests` constructs one
headlessly today, including a `PaneHost` over it.

## Evidence

A throwaway spike declared `tests-ui` as a `.testTarget` over the `DanTerm`
executable, added `@testable import DanTerm` plus the engine imports, and
excluded the two shim files. Every remaining compile error falls in four
classes:

1. **`AppRuntime` construction and message observation.** The real runtime
   already carries every member the fake had except the recording ones
   (`sentMessages`, `onSend`, `focusedPaneSessions`) and a settable `model`.
2. **The fake `TerminalView` session.** Already a protocol seam
   (`any TerminalSession`), so it is a test-local fake and needs no production
   change; the production type of that name is long deleted.
3. **`TerminalPaneSessionController`.** A `public final class` whose only
   public initializer forks a PTY child. This is the one real production seam
   the move needs.
4. **`TerminalFrameSwapchain`.** The pane view constructs it directly, and the
   suite observes which rows each render covered.

`IOSurfaceLayerContentsTests` compiles clean against the real engine types
already, which is the evidence that the faked renderer value types are an
artifact of the whole-module build rather than a requirement of the tests.

## Decision

Make `tests-ui` an ordinary SwiftPM test target and delete the bespoke build.

Production changes are confined to the pane view's concrete collaborators. It
names three seams, each with the shipping implementation as its default: the
session controller, the rotation of buffers it presents, and the resolver that
turns a font choice into cell geometry. The third is a seam because the real
answer reads the machine's installed fonts, and the pane's fallback behavior has
to be provable without depending on which faces are installed.

The flight recorder is a fourth collaborator, and it is *not* part of the
controller seam: a recorder fence is a value only a live recorder can mint, so a
session that records a tape says so by conforming to a separate protocol, and a
session with no recorder serves no tape.

The runtime half (1) is served by a test subclass that overrides the runtime's
message-send entry point, because a protocol there would only re-describe a type
tests can already build.

## Invariants

- **I1** The UI suite compiles from a manifest target. No script, anywhere,
  names the suite's individual source files.
- **I2** The suite covers the same behaviors it covers today, the pane-view
  cases included. No case is dropped or weakened to make the move fit.
- **I3** `SwiftTerminalSessionView` names its session controller and its frame
  swapchain through seams the real engine types satisfy, and its production
  path binds the real ones with no test-only branch.
- **I4** No production source carries a build flag that selects a test's
  collaborators.
- **I5** Every first-party test estate runs in `just test` exactly once. The
  UI estate is display-bound and stays out of that gate, excluded by a rule
  stated in one place rather than by a hand-listed exemption.
- **I6** A message a view reports through the runtime's outbox is observed by
  the same entry point as a message it sends directly, in production and in
  the suite alike.

## Proof obligations

- **PO1** (I1, I2) The suite runs green as a manifest target with its present
  case count, and `just test-ui` names no source file.
- **PO2** (I3) The pane view drives a real controller on its production path;
  a test drives it without a forked PTY.
- **PO3** (I4) An executed check fails when a production source selects a
  collaborator on a build flag.
- **PO4** (I5) The gate's test-coverage check accepts the resulting estate
  layout, and rejects a UI estate that is neither run nor excluded by the rule.
- **PO5** (I3) Terminal pane throughput is unchanged by the controller seam,
  measured with the existing terminal benchmark rather than asserted.
- **PO6** (I6) A message reported through the outbox reaches the same
  observation point as a directly sent one.

## Non-goals

- Running the UI suite inside `just test`. It needs a WindowServer.
- Changing what any UI test asserts. The move is a packaging and seam change;
  rewriting assertions is out of scope.

## Rejected ideas

- **RI1 Give the views a narrow protocol for `AppRuntime`.** This was the way
  out the superseded design doc named. Rejected on the evidence above: the
  real runtime is already headlessly constructible and already carries every
  member the fake had, so the protocol would restate a type the tests can
  build. What the suite actually lacks is message observation, which the
  send-entry-point override supplies.
- **RI2 Assert on resulting model state instead of on the dispatched message.**
  The purest form, and rejected: it rewrites roughly eighty assertion sites and
  couples view tests to reducer behavior they do not mean to pin.
- **RI3 Move only the test files that already compile clean.** Splits one suite
  across two runners and keeps the hand-maintained list.
- **RI4 De-finalize `TerminalPaneSessionController` so a test can subclass it.**
  Makes an engine type's whole surface overridable to serve a view test.

## Accepted risks

- **AR1** `AppRuntime`'s message-send entry point becomes a documented
  substitution point that must stay overridable. The alternative that removes
  the risk is RI2, whose cost is higher.
- **AR2** A protocol seam on the controller puts dynamic dispatch on the pane's
  input and frame path. PO5 bounds it; if the measurement shows a cost, the
  seam becomes a generic parameter rather than an existential.
- **AR3** Cell geometry can no longer be fabricated: the engine's metrics carry a
  measured font set, so the suite drives real measurements through the metrics
  seam. A handful of pane-geometry cases therefore state their expectation
  relative to the metrics they were given rather than against a fixed cell box.
  The risk is that re-deriving an expectation hides a regression; it is bounded
  by keeping each case's claim unchanged and only changing what the number is
  read from.

## Follow-up

- The suite is one Swift Testing case around the existing `uiTest` runner. Per-case
  conversion to `@Test` functions is deliberately not part of this move: doing both
  at once would make a behavior regression indistinguishable from a conversion slip.

## Implementation discretion

- Whether the swapchain seam is a factory the view is given or a protocol the
  swapchain satisfies.
- How the UI estate is named to the gate's coverage rule.
