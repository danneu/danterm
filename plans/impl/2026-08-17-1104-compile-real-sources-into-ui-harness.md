# Compile the real sources into the UI harness instead of faking them

## Problem

The `DANTERM_UI_TEST` build compiles the real `SwiftTerminalSessionView`
against a 705-line shim that re-declares production value types and pure
functions rather than compiling them. The copies have drifted, so UI tests are
green about an artifact the app does not ship:

- Shim `terminalGridDimensions` omits production's `max(2, columns)` /
  `max(1, rows)` floors and every finiteness and `Int`-range guard.
- Shim `terminalCell` omits the finiteness and `Int`-range guards.
- Shim `PaneInputSubmissionResult.rejected` drops its
  `PaneInputSubmissionFailure` payload, and `PaneProcessLifecycleResult`
  drops both of its payloads, so a harness test cannot observe why a
  submission failed or how a child exited.
- Shim `TerminalSemanticEvent`, `TerminalConnectionState`,
  `TerminalRemoteIdentity`, `TerminalProgress`, and `TerminalSearchStatus`
  drop `Equatable` and `Sendable`, so recorded events cannot be compared.

A change to the real floors, guards, or payloads would not fail a single UI
test.

This is the audit's T2 root cause -- tests re-implement production because
production has no seam to drive -- and the audit's combined fix names "the two
pure geometry sources compiled into the UI-test target" as part of it.

The test-seam rule is already accepted in
[docs/design/2026-08-17-test-seam-rule.md](../../docs/design/2026-08-17-test-seam-rule.md),
R1-R3. A production component must not ask whether it is under test; tests
instead supply production-shaped domain input through a legal route. This plan
applies that rule. It does not create or restate it.

### Load-bearing premises

- **The harness already compiles real production sources into its module.**
  `test-ui.sh` links `lib/TerminalCore/.../TerminalInputEncoding.swift` (481
  lines, linked for two of its types, carrying its encoders along unused),
  `.../ActivatableWebURI.swift`, and
  `lib/TerminalPTY/.../TerminalWheelNormalizer.swift`. Nothing principled
  separates those from the faked ones; the dividing line is whether the file
  happens to have an `import`.
- **The one blocker for `TerminalGridSizing.swift` is its `import
  PaneProcessLifecycle`,** which a whole-module `swiftc` build cannot resolve.
  `PaneProcessLifecycle` is a leaf SwiftPM target: two files, zero imports, no
  dependencies. `test-ui.sh` already pre-builds `DanTermProtocol` as a static
  module the same way.
- **`TerminalInteractionPolicy.swift` holds two separable things,** and only
  one of them can compile in the harness. Its interaction vocabulary -- the
  point and cell values, the pointer and wheel events, and the pure
  point-to-cell function -- depends on nothing beyond what the harness already
  links. Its decision policy takes the live `Terminal` and traffics in
  `TerminalTextRange` and `TerminalResolvedLink`, so the file as a whole cannot
  compile there. The vocabulary is what the view speaks; the policy is what the
  session controller runs.

- **`app/SwiftTerminalSessionView.swift` guards `import PaneProcessLifecycle`
  behind `#if !DANTERM_UI_TEST`,** so building that module is not by itself
  enough to make its declarations visible to the view during the UI build.
- **No current UI test observes a grid below the production floors.** Every
  grid assertion in `tests-ui/` sits at 6 or more columns and rows, where the
  shim and production agree. Adopting the floors changes no existing
  expectation.

## Decision

Four moves, in this order.

**1. Separate the interaction vocabulary from the interaction policy.** The
values and the pure point-to-cell function move into their own import-free
production source in `TerminalCore`; the `Terminal`-dependent decision policy
stays behind. This is the seam the file already has -- the view speaks the
vocabulary and never calls the policy -- and it is what makes the vocabulary
linkable anywhere, the harness included.

**2. Make the lifecycle module reachable from the view in both builds,**
by lifting `import PaneProcessLifecycle` out of the `#if !DANTERM_UI_TEST`
block in `app/SwiftTerminalSessionView.swift`. The module is a leaf with no
engine dependency, so it is available in both builds and the guard buys
nothing.

**3. Delete the shadowing fakes.** Teach `test-ui.sh` to pre-build
`PaneProcessLifecycle` as a static module, add the real geometry, vocabulary,
and semantic sources to its compile list, and delete every fake in
`tests-ui/SwiftTerminalSessionViewTestShim.swift` those sources replace.

**4. Close the audit finding after the implementation lands.** As the final
task, after the implementation and its checks have landed, fill the blank
Status cell for S35 in
`docs/scratch/2026-08-11-simplification-audit.md` with the landing commit SHA.
Leave the finding body unchanged: that audit defines a SHA in the ranked table
as the authoritative signal that the historical source reading is stale.

The critical files: `test-ui.sh`,
`tests-ui/SwiftTerminalSessionViewTestShim.swift`,
`scripts/tests/test-ui-harness_test.sh`, and
`app/SwiftTerminalSessionView.swift`, plus the final status update in
`docs/scratch/2026-08-11-simplification-audit.md`. The production sources
compiled into the harness are `lib/TerminalPTY/Sources/PaneProcessLifecycle/*`,
`lib/TerminalPTY/Sources/TerminalPaneSession/TerminalGridSizing.swift`, the
extracted interaction vocabulary, and
`lib/TerminalCore/Sources/TerminalCore/TerminalSemanticEvent.swift` and
`TerminalSearchStatus.swift`.

This work is a strict step toward the DI refactor that retires the harness:
every fake deleted here is one the refactor no longer has to unwind.

## Invariants

- **I1.** No declaration in `tests-ui/` shadows a production declaration the
  harness is able to compile. A fake survives only where the real source cannot
  compile in the harness -- the renderer and IOSurface types, the live session
  controller, `AppRuntime`.
- **I2.** The grid the harness reports for a pane is the grid the app reports
  for that pane: the same floors, and the same refusal of geometry that is not
  finite or is out of `Int` range.
- **I3.** Pointer-to-cell resolution in the harness refuses exactly the inputs
  production refuses.
- **I4.** A value the harness records carries its production payload and
  conformances. No case is flattened to lose its reason.
- **I5.** This work adds no conditional test-only branch to any production
  path. It may delete one where the guarded code is correct unconditionally,
  but it does not take on retiring the substitution machinery as a whole.

## Proof obligations

- **PO1** (I2) -- a pane too small for the production floors reports the
  floored grid, and the app and the harness agree on it.
- **PO2** (I2, I3) -- geometry that is not finite, or out of `Int` range, is
  refused rather than producing a grid or a cell.
- **PO3** (I1) -- a gate that fails on either half of the regression: a
  production source this change made harness-compatible dropping out of the
  compiler invocation, or `tests-ui/` declaring a name those sources supply.
  Catching only the second half leaves the original failure shape green,
  because deleting the source and restoring the fake removes the name that a
  collision check compares against.
  `scripts/tests/test-ui-harness_test.sh` already pins one source by path for
  the sibling failure ("the explicit harness source list can omit a
  dependency"), and runs in `just test`.
- **PO4** (I4) -- a rejected input submission observed through the harness
  names its failure reason.
- **PO5** -- `just test-ui` passes, and `just test` passes.
- **PO6** -- the S35 Status cell names the landing commit and is no longer
  blank.

## Non-goals

- Retiring `#if DANTERM_UI_TEST`, the shim's `TerminalPaneSessionController`
  fake, or the `AppRuntime` fake. That is the DI refactor, which the harness
  ADR says is "worth doing on its own merits or not at all -- it should not be
  smuggled in as test plumbing." The `AppRuntimePorts` effect seam has landed,
  but UI views still take concrete `AppRuntime` and
  `TerminalPaneSessionController` dependencies. Replacing those view-facing
  dependencies remains separate work.
- Deleting the render-side fakes (`RenderTheme`, `RenderFramePlan`,
  `TerminalDamage`, `TerminalRenderMetrics`, the frame backing store and
  swapchain). Their real sources need `TerminalRenderPlanning` /
  `TerminalRenderExecution`, Metal, and IOSurface.
- Deleting the fakes whose real declarations live in `TerminalGeometry.swift`.
  That file drags `TerminalScalars` and `TerminalStyle` behind it.

## Accepted risks

- **AR1.** Declarations that now arrive from a real module rather than the same
  file need an import in each harness file that names them, and an explicit
  initializer where a memberwise one sufficed. Mechanical, and the compiler
  names each site.
- **AR2.** `just test-ui` gains a second module compile step and gets slightly
  slower.
- **AR3.** Adopting the production floors could in principle change an existing
  UI expectation. Checked against every current grid assertion and none sits
  below the floors, so this is latent rather than a known break.

## Rejected ideas

- **RI1.** Make the shim copies byte-identical to production and bind them with
  a comment (the finding's own cheaper fallback). It keeps two sources of truth
  and lets them drift again silently, which is the defect.
- **RI2.** Move `terminalGridDimensions` into `PaneProcessLifecycle` so the
  file has no import to resolve. The move follows no seam in the code -- it
  exists only to dodge an import -- and it frees one function rather than the
  constraint that produced the fakes. The vocabulary extraction is not this:
  it splits a file along a boundary the code already has.
- **RI3.** Move `import PaneProcessLifecycle` in the view behind a
  harness-only alias or a second conditional arm rather than making it
  unconditional. It adds a conditional branch to a production path, which I5
  forbids, to avoid an import that costs the app nothing.

## Implementation discretion

- Which further import-free production files get linked: walk each candidate's
  transitive references and stop at the first that needs Metal, IOSurface, or
  swift-collections, leaving that fake in place.
- The form of the PO3 gate, so long as it fails on both halves of the
  regression.

## Commit progress
- [x] 1. refactor(terminal-core): split the interaction vocabulary out of the policy file
- [ ] 2. test(ui): compile the real geometry and semantic sources into the UI harness
- [ ] 3. docs(scratch): record S35's landing commit in the simplification audit
