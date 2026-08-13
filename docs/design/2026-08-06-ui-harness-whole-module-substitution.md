# The AppKit UI Harness Is a Whole-Module Substitution Seam, Not a Test Target

- Status: Accepted
- Date: 2026-08-06

<!-- docs-lint: allow-missing app/TerminalView.swift -->

## Context

`test-ui.sh` compiles ~60 hand-listed source paths -- app views, a subset of
`DanTermCore`, a subset of `DanTermSupport`, two engine files -- plus
`tests-ui/*` in a single raw `swiftc` invocation, and runs the resulting binary.
Every new view has to be "promoted" into that list by hand, and the list rots
silently: a file that stops compiling in isolation is only discovered on the
next `just test-ui`.

The only rationale ever recorded for the bespoke build was that it is "the
**GhosttyKit-free** UI harness"
(`plans/impl/2026-06-11-theme-browser-ui-harness.md:5`). With libghostty
removed, the app target has no binary framework dependency at all, so that
rationale is gone. The obvious follow-up was to make `tests-ui` an ordinary
SwiftPM `.testTarget` depending on the `DanTerm` executable target, exactly the
way `app-tests` (`DanTermAppTests`) already does, and keep it out of the
`just test` gate for the WindowServer reason alone.

That was tried, in a throwaway worktree at `e355768e`: a `DanTermUITests`
test target rooted at `tests-ui`, `@testable import DanTerm` added to every
file, the `@main` runner converted to a Swift Testing entry point.

## Decision

**Keep the bespoke `swiftc` harness.** It is not a packaging accident and it was
never really about GhosttyKit. Its mechanism is *whole-module compile-time
substitution of collaborators*: it compiles the production view files into the
same module as fake `AppRuntime` and `TerminalPaneSessionController` types, so a
view's concrete dependencies are swapped out with no dependency injection in
production code at all. A SwiftPM test target cannot do that by construction --
the system under test is compiled once, into a different module, already bound
to the real types.

### The concrete blocker

Two distinct compile errors, and the difference between them is the whole
finding:

```
tests-ui/PaneWrapperViewTests.swift:169:60: error: cannot convert value of type
  'DanTermUITests.AppRuntime' to expected argument type 'DanTerm.AppRuntime'
tests-ui/SwiftTerminalSessionViewTests.swift:18:57: error: cannot convert value of type
  'DanTermUITests.TerminalPaneSessionController' to expected argument type
  'TerminalPaneSession.TerminalPaneSessionController'
```

Where the production seam is a **protocol**, the fake ports across the module
boundary with no trouble. `PaneWrapperView.init(paneId:terminalView:...)` takes
`any TerminalSession` (`app/PaneWrapperView.swift:46`), so the harness's fake
terminal compiles fine as a test-target type. Where the production seam is a
**concrete type**, it cannot:

- `PaneWrapperView`, `SplitContainerView`, `SidebarView`, `ThemeBrowserView`,
  `PreferencesPanel`, and the three popover views all take `AppRuntime`
  concretely. The real `AppRuntime.init` (`app/AppRuntime.swift:193`) reads the
  user's config file from disk, installs a process-global `NSEvent` monitor,
  constructs a `SwiftTerminalBackend`, and **binds the live IPC control socket**
  -- so a test cannot construct one, and would hijack the user's running DanTerm
  instance if it did. There is no protocol to substitute.
- `SwiftTerminalSessionView` stores a concrete `TerminalPaneSessionController`.
  Its only public initializer
  (`lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift:324`)
  requires a `bootstrapExecutable` and forks a real PTY child process. The
  injectable `init(host:)` seam is `internal` to `TerminalPaneSession` and still
  takes a real `TerminalPTYHost`, itself built from a bootstrap executable
  (`lib/TerminalPTY/Tests/TerminalPaneSessionTests/TerminalPaneSessionControllerTests.swift#makeHost`).
  The 40 `SwiftTerminalSessionViewTests` are written against a *recording* fake
  (`textInputs`, `inputBytes`, `pointerEvents`, `appliedThemes`,
  `scrolledTopRows`, `searchQueries`); against the real controller they would
  each need a forked PTY and would stop being unit tests of the view.

Also substituted, and equally unavailable: the harness fakes the renderer value
types (`RenderTheme`, `RenderFramePlan`, `TerminalDamage`,
`TerminalRenderMetrics`, `TerminalViewportCell`, `TerminalPointerEvent`, ...) in
`tests-ui/SwiftTerminalSessionViewTestShim.swift`. In a test target the real
`TerminalRenderPlanning` / `TerminalCore` types are already in scope, so the
fakes collide with them rather than replacing them
(`cannot convert value of type 'TerminalCore.TerminalViewportCell' to expected
argument type 'DanTermUITests.TerminalViewportCell'`).

### What is *not* the blocker

Recorded so nobody re-derives it:

- **Depending on an executable target is fine.** `DanTermAppTests` already does
  it; `@testable import DanTerm` from a test target works.
- **The `@main` runner is not a problem.** Deleting `@main` and hanging the
  existing `uiTest`/`uiExpect` runner off a Swift Testing `@Test` compiles.
- **The `#if DANTERM_UI_TEST` seams are not the blocker.** Making
  `SidebarView`'s `testForceNextNilCell*` sets unconditional was enough for
  `SidebarSelectionCacheTests` (11 tests) to compile clean against the real
  `DanTerm` module. Note that in `SwiftTerminalSessionView.swift` and
  `ThemeRenderBridge.swift` the same flag is doing something different -- it
  guards `import TerminalPaneSession` / `import TerminalRenderPlanning` so the
  *fakes* win. It is a substitution flag there, not a test-seam flag.
- **WindowServer is not the blocker either.** A test target excluded from
  `scripts/run-test-suite.sh` would have handled that fine, exactly as the task
  supposed.

Of the 19 test files, 8 compile clean as an ordinary test target today
(`DanTermConfigStoreTests`, `LinkPreviewViewTests`, `MenuCommandPolicyTests`,
`PaneSplitViewTests`, `RemoteThemePickerSheetTests`, `SidebarBadgeTests`,
`SidebarContextMenuTests`, `TerminalBackendBoundaryTests`, plus
`SidebarSelectionCacheTests` once the seam above is unconditional). Moving only
those was rejected: it splits one UI suite across two runners and keeps the
hand-maintained file list anyway, which is strictly worse than either endpoint.

## Consequences

- `test-ui.sh`, its file list, `tests-ui/SidebarViewTestShim.swift`,
  `tests-ui/SwiftTerminalSessionViewTestShim.swift`, and
  `scripts/tests/test-ui-harness_test.sh` all stay. The per-view "promotion"
  ritual stays with them; it is the cost of the substitution seam.
- The list rot is real and unmitigated. A file added to `lib/DanTermCore` that a
  promoted view starts using breaks `just test-ui` and nothing else, which is
  how it is usually found.
- **The way out is a production change, not a test-packaging change.** Give the
  views a narrow protocol for the two things they actually use `AppRuntime` for
  (`send(_:)` plus a handful of imperative hooks), the way `TerminalSession`
  already works, and give `SwiftTerminalSessionView` a protocol for its
  controller. Then `tests-ui` becomes an ordinary test target with a normal
  fake, and the file list dies. That is a deliberate DI refactor across ~10 view
  files, worth doing on its own merits or not at all -- it should not be smuggled
  in as test plumbing.
- The harness's fake terminal class is named `TerminalView`
  (`tests-ui/SidebarViewTestShim.swift:46`). It was a stand-in for the deleted
  Ghostty `app/TerminalView.swift`; that production type is gone, so the name is
  now free and the class is really just a fake `TerminalSession`. Renaming it is
  a loose end, not a blocker.

## References

- `plans/impl/2026-08-06-libghostty-removal-and-post-removal-simplification.md`,
  section 3 and Wave 2 task 10, which posed the question and asked for the real
  reason if the answer was no.
- `plans/impl/2026-06-11-theme-browser-ui-harness.md:5` -- the superseded
  "GhosttyKit-free" rationale this note replaces.
- [2026-05-28: Pure Core Compiled Same-Module via Symlink, Tested via Nested Package](2026-05-28-core-module-via-symlink.md)
  -- the same-module-compilation trick, used there for access control rather than
  for substitution.
