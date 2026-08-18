# Dead-code sweep pivot: S60, S59, S41

## Context

Three items in `docs/scratch/2026-08-11-simplification-audit.md` were bundled as
one cheap sweep of "three deletions". Verification says the bundle is wrong in
two places, and the pivot is what this plan implements.

- **S60 is half right.** `runRepeating` is genuinely dead: `git log -S` shows
  `88c6bf2c` added it and `5ca4bfe1` ("push pane tape follow updates") deleted
  the 50 ms repeating follow timer that was its only caller. But
  `captureOwnerCensus` now has 15 assertions across four app test files
  (`AppRuntimeSchedulingLifecycleTests`, `AppRuntimeAmbientCommandTests`,
  `AppRuntimeSessionCommandTests`, `IpcServerRemoteTests`) covering real runtime
  behavior -- a timer armed then retired, a debouncer retired on pane close, a
  live subscription count. The audit's "delete it with its tests" would drop that
  coverage, and its alternative (assert an empty census at the end of
  `shutdown()`) is worthless because `shutdown()` already clears the table before
  that point. What is actually wrong is the doc comment: it claims the method
  exists "for termination assertions and diagnostics", and neither consumer
  exists.
- **S59 is exactly right**, and its ideal fix is the one to do. The only
  non-test conformer of `TerminalSession` builds `scrollPosition`
  unconditionally, so the scroll chrome's absence branch is unreachable in the
  app while four test doubles keep exercising it.
- **S41 is real but is not a deletion, and the audit's fix does not enforce
  anything.** Production discards `update()`'s result at six nested call sites
  now, not the two the audit found. But removing `@discardableResult` only
  produces a *warning* at a bare call, and nothing in this repository treats
  warnings as errors -- no `-warnings-as-errors` or `warningsAsErrors` in any
  `Package.swift`, build script, justfile recipe, or CI workflow. So that route
  costs roughly 1650 mechanical test lines and buys no guarantee: a developer can
  add a bare nested call, get a warning nobody reads in captured gate output, and
  pass `just test` while dropping commands.

Desired outcome: the two dead surfaces are gone, absence is encoded once at the
terminal-session boundary, and a nested reducer call can no longer drop commands
without saying so.

## Decision

Three independent changes, in three commits. They share no code, so the order is
only convenience; each must land green on its own.

1. **S60.** Delete `runRepeating`. Keep `captureOwnerCensus` and rewrite its doc
   comment to say what it is -- the tests' only window onto lifecycle ownership
   -- instead of naming consumers that do not exist.
2. **S59.** At the terminal-session boundary, `scrollPosition` becomes
   non-optional and cell height becomes optional. One question ("does this pane
   have layout metrics yet?"), one answer. The producer stops flattening its own
   `displayedCellSize` optional into a zero, and the two in-view consumers of
   cell height read that field directly rather than round-tripping through the
   boundary struct -- which today rebuilds the whole struct, including a
   `CGColor` conversion, on every scroll-wheel event.
3. **S41.** Keep `@discardableResult` -- it is what lets a test call the reducer
   for its mutation alone. Instead, remove the discards from production: each of
   the six nested results flows into the command list its arm returns. All six
   nested handlers return no commands today, so this is observationally
   identical, and any command those messages later gain propagates by
   construction rather than by someone remembering. Then a gate lint rejects a
   discarded `update()` result in production sources, so the rule is an error
   rather than a warning. This follows the house pattern: seventeen grep-based
   lint scripts already live in `scripts/`, each with a self-test under
   `scripts/tests/`, wired into `scripts/run-test-suite.sh`.

Critical files: `app/AppRuntimeSchedulingLifecycle.swift`,
`app/TerminalSession.swift`, `app/ScrollableTerminalView.swift`,
`app/SwiftTerminalSessionView.swift`,
`lib/DanTermCore/Sources/DanTermCore/Update.swift`,
`lib/DanTermCore/Sources/DanTermCore/IpcDispatch.swift`, a new lint script and
its self-test under `scripts/` and `scripts/tests/` wired into
`scripts/run-test-suite.sh`, plus the four terminal
session test doubles (`app-tests/PaneHostHeadlessTests.swift`,
`app-tests/AppRuntimeCommandTestSupport.swift`,
`tests-ui/SidebarViewTestShim.swift`,
`tests-ui/ScrollableTerminalViewTests.swift`,
`tests-ui/TerminalBackendBoundaryTests.swift`).

## Invariants

- **I1.** The scheduling lifecycle exposes no repeating-token admission API.
  Long-lived owner cancellation and the existing `isActive` callback guards are
  unchanged.
- **I2.** A pane's reported scroll position is always present. Absence at the
  terminal-session boundary is expressible only as missing layout metrics, and
  only in one field.
- **I3.** Scroll chrome behavior is unchanged. A pane with no layout metrics
  sizes its document view to the viewport and restores no row offset; a pane with
  metrics sizes and scrolls exactly as before.
- **I4.** Cell height inside the producing view is read from the view's own
  layout state, not from the boundary struct.
- **I5.** No production caller drops the reducer's commands. Every nested
  `update()` result reaches the command list its caller returns, and the gate
  fails on a production call whose result is discarded. Adding a command to any
  message reached through a nested call therefore cannot become a silent no-op.
- **I6.** Commit 3 changes no observable behavior: all six nested handlers return
  no commands on every path today, so propagating their results is identical to
  discarding them.
- **I7.** The gate rule has no per-line escape marker. There is no legitimate
  production discard once commit 3 lands, so a future one is a decision that has
  to be argued, not annotated.

## Proof obligations

- **PO1 (I1).** The existing scheduling lifecycle and app runtime suites still
  pass with no reference to a repeating gate.
- **PO2 (I2, I3).** Behavioral coverage of the scroll chrome for both states:
  a session without layout metrics, and one with metrics and scrollback. The
  four test doubles are updated to states the app can actually produce, which is
  the point of the change -- a double must no longer be able to express a missing
  scroll position.
- **PO3 (I3).** The pure scrollbar math suite is untouched and still green; its
  own numeric guards stay, because they guard a value, not an absence.
- **PO4 (I4).** Existing UI coverage of live font changes and cell metrics still
  observes the same cell height through the boundary.
- **PO5 (I5, I7).** The lint carries a self-test in the house pattern, pinning
  both directions: a production call whose result is discarded is rejected, and a
  call whose result is consumed is accepted. The test suite runs the lint, so the
  gate fails on a new production discard.
- **PO6 (I6).** The core reducer and IPC dispatch suites pass unchanged in
  behavior after the six results are propagated.

## Non-goals

- Changing what any of the six nested messages returns. The propagation is
  plumbing; giving one of them a command is a separate change.
- Any test-side change for S41. Tests keep calling the reducer for its mutation
  alone, and no test-only reducer wrapper is added.
- Adding a termination assertion to `shutdown()`.
- Any change to the pure scrollbar math functions or their tests.
- Enabling warnings-as-errors anywhere in the build.

## Accepted risks

- **AR1.** The gate rule is a grep heuristic, like its seventeen siblings in
  `scripts/`, so a production discard spelled in a shape the lint does not match
  would pass. Rationale: the self-test pins the shapes that exist, and
  propagation -- not the lint -- is what makes the six current sites correct.

## Rejected ideas

- **RI1.** Deleting `captureOwnerCensus` and its tests -- it carries live
  behavioral coverage of runtime ownership that nothing else provides.
- **RI2.** Removing `@discardableResult` from `update()` -- a bare call then
  warns rather than failing, and this repository has no warnings-as-errors
  setting, so the route costs roughly 1650 mechanical test lines and enforces
  nothing.

## Implementation discretion

- The spelling of the optional cell-height field and how the scroll-chrome guard
  is arranged, provided I2 and I3 hold.
- The lint's matching strategy and which source roots it scans, provided I5 and
  I7 hold and its self-test pins both directions.

## Verification

- `just test` for the gate (core reducer, app tests, scheduling lifecycle,
  scrollbar math).
- `just test-ui > .build/ui.log 2>&1`, then grep the log -- the scroll chrome and
  terminal-session boundary coverage lives there and is excluded from the gate.
- Launch a slot (`just launch-slot | tail -1`) and confirm the scroll chrome
  end to end against the real engine: scroll back through history in a pane with
  scrollback, drag the scrollbar, and split a pane so a fresh session mounts with
  no metrics yet. `danterm --socket <slot> pane grid` and `pane zoom` exercise
  two of the six sites; both must still report the same pane state after
  commit 3. Stop the slot when done.
- Confirm the gate actually fails: temporarily discard one propagated production
  result and check that `just test` reports the lint step, not a warning buried in
  captured output.

## Commit progress

- [x] 1. `refactor(app)`: delete the dead repeating gate; say what the owner
      census is for. Green gate.
- [x] 2. `refactor(app)`: give the terminal-session boundary one absence. Green
      gate plus `just test-ui`, and the live scroll check above.
- [ ] 3. `refactor(core)`: propagate nested reducer commands and gate the rule.
      Propagation, lint, and lint self-test travel together. Green gate; no
      behavior change.

## Implementation notes

- Commit 2: the wrapper's construction-time sync guard now reads layout metrics
  alone, where it used to accept either a positive cell height or any scroll
  position. With `scrollPosition` non-optional the old disjunction was always
  true, and the call it now skips was a no-op anyway: a freshly built wrapper has
  a zero-sized scroll view, so the document height it would set is the zero it
  already has, and the first `layout()` pass calls the same method.
- Commit 2: the four non-scroll test doubles report a plausible fresh-pane
  position (24 rows, viewport at the bottom) rather than an all-zero one, so no
  double describes a pane the app cannot produce.
- Commit 2: the live check could confirm only what the CLI can reach. A slot
  built from this branch launched, rendered 500 lines of output, took input, and
  split into a fresh pane that mounted and reported `integration: ready` with no
  layout metrics yet. The scroll chrome's own geometry has no CLI surface, so the
  document sizing and row restore are pinned by the two new UI-harness tests
  instead; both were confirmed to fail when the production scroll restore is
  removed.

## Follow Up

- The `danterm` CLI cannot report or drive a pane's scroll chrome: there is no
  query for the scrollbar's document height, knob position, or viewport row
  offset, and no command that scrolls a pane by rows. That left the plan's live
  scroll verification unreachable from the API and forced it into the UI harness.
  Adding a `pane scroll` command and scroll state on `pane info` would close it.
- `lib/DanTermCore/Sources/DanTermCore/Update.swift:717` binds `tabId` and never
  uses it, which the build reports as a warning on every compile. Commit 3 of
  this plan edits the same file and can clear it.
