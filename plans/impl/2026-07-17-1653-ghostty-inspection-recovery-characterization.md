# Ghostty inspection and recovery characterization

## Problem and desired outcome

DanTerm reads viewport and full-history text directly from Ghostty for
`danterm pane read` and enriched recovery checkpoints, but no real-backend test
pins Ghostty's behavior for wrapping, padding, spaces, empty rows, Unicode, or
final newlines. Moving that boundary without characterization could silently
change IPC output or recovered history while the pure post-processing tests
continue to pass.

The outcome is a reviewed, byte-exact characterization corpus produced through
the current app and CLI boundaries. It becomes the regression evidence for the
later backend extraction without making every observed Ghostty behavior
normative.

## Decision

- Add an opt-in, GUI-only `just test-terminal-characterization` suite, guarded
  by `DANTERM_TERMINAL_ENGINE_TEST_ALLOW_APP_CONTROL=1`. It remains outside
  `just test`, `just test-ui`, and CI.
- Exercise the real Ghostty-backed app, the bundled `danterm pane read` client,
  window resizing, and the clean-exit enriched checkpoint path.
- Run a controlled terminal child without user shell startup output. Cover a
  short viewport corpus, a longer history/reflow corpus, and a
  primary-screen -> alternate-screen -> primary-screen recovery corpus.
- Capture at two verified PTY widths: one that wraps the long logical line and
  one that does not. Synchronization observes process readiness and completed
  resize state rather than assuming fixed delays.
- Compare reviewed fixtures byte-for-byte, including written spaces and final
  newline state. A failure makes invisible whitespace visible and preserves the
  actual capture for diagnosis; it never overwrites checked-in expectations.
- Build a temporary app using the stable characterization-only bundle identity
  `com.danneu.danterm-terminal-characterization`. Isolate each run's resolved
  Foundation home and user-domain directories plus its process temporary
  directory. The suite does not install, replace, launch, or terminate the
  user's DanTerm or DanTerm Dev app.
- Treat the terminal-engine component contracts as authoritative. If an
  observation conflicts with them, record the divergence explicitly instead of
  silently converting the Ghostty result into a replacement requirement.

The developer entry point is:

```sh
DANTERM_TERMINAL_ENGINE_TEST_ALLOW_APP_CONTROL=1 just test-terminal-characterization
```

It requires a logged-in macOS GUI session, Accessibility permission for window
control, `jq`, and the cached `GhosttyKit.xcframework`.

## Invariants

- Characterization changes no production behavior, CLI or IPC contract, app
  model, or persistence schema.
- Captures traverse the same runtime text-reading and checkpoint paths used by
  the shipped Ghostty backend.
- Test execution cannot consume or destroy user terminal state, configuration,
  recovery data, installed applications, or unrelated processes.
- Every resolved config, cache, recovery, control-socket, and replay path stays
  under roots owned by the current characterization run.
- Fixture equality includes spaces, empty lines, Unicode text, and whether the
  source ended in a newline.
- Captures before and after reflow remain attributable to the same controlled
  corpus even when Ghostty serializes them differently.
- Success and failure both leave no characterization process, control socket,
  session lock, or per-run state behind.

## Proof obligations

- Without the explicit app-control opt-in, the suite exits before building or
  launching an application.
- Before terminal creation, the launch environment proves the app's actual
  `NSHomeDirectory()`, Foundation application-support and cache directories, and
  DanTerm process-temporary resolver stay beneath the run-owned roots; the
  derived config, recovery, socket, and replay paths must do the same.
- Viewport and full-history captures pin hard and soft boundaries, written and
  padding spaces, empty rows, Spanish text, Chinese wide text, basic emoji, and
  final-newline behavior at the narrow and wide PTY sizes.
- `pane read --lines` records exact output with both a limit larger than the
  corpus and a smaller limit at each width. If the observed separator counting
  or final-newline behavior differs from the terminal-engine logical-line
  contract, the fixture carries an explicit divergence record.
- Narrow-to-wide and wide-to-narrow resizing records Ghostty's exact
  serialization of the same corpus at each width. Any failure to preserve the
  terminal-engine logical-text contract is recorded as a divergence rather
  than made a passing requirement.
- After primary, alternate, and returned-primary activity, a normal app quit
  produces a reviewed, exact enriched-scrollback fixture. Whether it retains
  primary history, includes transient alternate text, and matches the existing
  whitespace and final-newline contract is asserted observationally, with any
  disagreement recorded explicitly.
- Clean termination removes the session lock and socket, and timeout or
  mismatch failure still cleans up only the isolated test resources.
- Harness control, cleanup, and comparison behavior is developed test-first;
  the real-backend suite passes alongside the existing `just test` and
  `just test-ui` gates.

## Non-goals

- Selection, search, export, or recovery scheduling and freshness behavior.
- Introducing the terminal backend abstraction or any Swift terminal-core
  implementation.
- Changing `pane read --lines 0`; the known mismatch between the current parser
  and the terminal-engine contract remains a separate follow-up.
- Making the real-app suite part of headless or default CI.

## Accepted risks

- The suite depends on macOS GUI automation and the pinned Ghostty build, so it
  is slower and more environment-sensitive than the pure test gates. Keeping it
  explicit is accepted because only a real surface can prove the behavior being
  characterized.
- Differential fixtures can preserve reference quirks. Each fixture is
  evidence, while the terminal-engine plan decides whether the behavior is
  retained.

## Implementation discretion

- The controlled child and synchronization mechanism, provided terminal bytes
  are not polluted by harness control traffic and resize completion is observed.
- Fixture file layout, temporary bundle assembly, and the exact narrow/wide
  dimensions, provided the isolation and behavioral coverage above hold.

## Implementation notes

- On macOS, Foundation ignored the characterization app's injected `TMPDIR`
  and resolved `FileManager.default.temporaryDirectory` to the shared per-user
  Darwin temp root. The characterization build therefore injects its run-owned
  temporary root at DanTerm's replay-directory resolver; production builds
  continue to use `FileManager.default.temporaryDirectory` unchanged. The path
  probe verifies the resolver and derived replay path before terminal creation.
