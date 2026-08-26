# Terminal Engine Reusability: What Blocks an Outside Consumer

- Date: 2026-08-26
- Status: Scratch. Nothing here is decided; the snag list is evidence, the
  ideals are proposals.

## The question

Could someone else use DanTerm's terminal engine in their own project?

`DanTermCore` cannot be used by anyone: it has zero `public` declarations, and
it is DanTerm's own model and reducer anyway. The reusable thing is the engine
-- `lib/TerminalCore` (grid, parser, renderer) and `lib/TerminalPTY` (process
lifecycle). `TerminalCore` alone carries 374 public declarations across 37
files and depends only on `swift-collections`.

## The probe: examples/MiniTerm

`examples/MiniTerm/` is the smallest real embedding: its own SwiftPM package,
path dependencies on the two engine packages, one window, one pane, no model
layer. It exists so that every gap in the reuse story fails as a compile error
or a visible defect rather than as an opinion.

It works. About 250 lines across three files reach a live shell with correct
colors and correct geometry, using only public API:

- `TerminalPaneSessionController` -- `onFrame`, `sendKey`, `setGridDimensions`,
  `setTheme`, `scroll`, `currentPlan`
- `TerminalRenderMetrics(displayScale:fontSize:fontFamily:)`, `RenderTheme.dark`
- `planFrame(for:presentation:)` and `drawRenderFrame(_:metrics:in:)`
- `terminalGridDimensions(size:cellSize:)`, `assembleTerminalPaneLaunch(request:facts:)`

Verified: the output path renders a live shell. Not verified: the input path.
The one attempt drove synthetic keystrokes through System Events, and they
landed in a different application. Test input by hand, or through a harness
that targets the process directly.

MiniTerm uses path dependencies, so it does NOT exercise the versioned
dependency case. Snag 5 below is untested by it on purpose.

## Snags, each with the ideal fix

### 1. The PTY bootstrap helper is the caller's problem

`TerminalPTYHost.init` takes `bootstrapExecutable: String`. DanTerm finds the
binary inside its own .app bundle. A plain SwiftPM executable has no bundle, so
MiniTerm needs an environment variable plus a separate
`swift build --product PTYSessionBootstrap`. An embedder cannot discover it.

Ideal: delete the executable. `PTYSessionBootstrap/main.c` is the classic
post-fork sequence -- `setsid`, open slave, `TIOCSCTTY`, `dup2`, `tcsetpgrp`,
`chdir`, `execve` -- and all of it is async-signal-safe. Make it a C library
target exporting one function, and have `PTYSpawner` `fork()` and call it in the
child instead of `posix_spawn`-ing a separate binary. The path parameter, the
bundle staging, and the embedder's file hunt all disappear.

What is wrong with the ideal: `fork()` in a process carrying the Swift runtime,
dispatch, and AppKit is safe only if nothing between `fork` and `execve`
allocates or takes a lock. The C function satisfies that, but the call site must
be `fork()` then the C function immediately, with no Swift in between, and the
compiler does not enforce that. `posix_spawn` was very likely chosen to avoid
exactly this hazard. The current design is not wrong; it moves the cost onto
every embedder.

Compromise if `posix_spawn` stays: ship the helper as a `Bundle.module`
resource. The executable bit and code signing make that fragile, and the app
bundle still needs staging, so the fork is the better of the two.

### 2. Render metrics cannot be rebuilt at a new display scale

`TerminalRenderMetrics.baseFontSize` and `baseFontName` are `internal`. An
embedder that wants metrics for a new `displayScale` has no way to name the font
inputs the existing value was built from. MiniTerm works around it by holding
the font size in a parallel property, which is exactly the duplication that
drifts.

Ideal: do not publish the fields. Give the value the operation:
`metrics.rescaled(toDisplayScale:)`, returning a sibling built from the same
font inputs. Publishing the raw fields fixes the compile error while leaving the
embedder free to rebuild with a drifted font size; the method makes "same font,
new scale" the only expressible move.

### 3. DanTerm branding is baked into launch assembly -- done

Fixed by
[plans/impl/2026-08-26-1243-engine-stops-naming-its-product.md](../../plans/impl/2026-08-26-1243-engine-stops-naming-its-product.md).
The shipped fix is a required `TerminalProductIdentity { name, version }` plus an
opaque `productEnvironment: [EnvironmentEntry]` the engine carries without
reading, not the `shellIntegration: ShellIntegration?` field proposed below: an
optional integration field still teaches the engine DanTerm's variable name and
asset layout, just behind a nil check. This snag also missed a second leak --
the XTVERSION reply built `DanTerm <version>` from a `programVersion: String`,
so an embedder answered the query with DanTerm's name over its own version. One
identity now feeds both channels.

The record of the snag as first written follows.


`assembleTerminalPaneLaunch` hardcodes `TERM_PROGRAM=DanTerm` and requires a
`shellIntegrationDirectory`. MiniTerm's first line of output was literally
`DanTerm shell integration is unreadable: .../examples/MiniTerm/danterm.zsh`:
the engine advertised DanTerm's shell integration to a shell that is not
DanTerm's.

Ideal: the function stops knowing a product name. Take a
`TerminalProductIdentity { termProgram, version, shellIntegration: ShellIntegration? }`
where a nil integration advertises nothing. DanTerm passes its own values, so
its wire behavior stays byte-identical -- which matters, because `TERM_PROGRAM`
is external-compatibility surface. An embedder that opts out cannot produce that
line at all.

### 4. Two launch facts are not facts

Revised on 2026-08-26. This snag was first written as "TerminalPaneLaunchFacts
has eight required fields", and its ideal was a separate target that reads the
process so no embedder rewrites the block. Reading the two call sites against
the policy that consumes them shows the repetition is a symptom. The real
problem is that two of the eight fields ask the embedder to pre-answer a
question the engine wants to ask, and the original ideal leaves that untouched.
A second revision the same day found that the first revision's fix (pass the
probe) still asks the question; it is now the fallback.

`executablePaths` and `accessibleDirectories` are documented as "already
verified executable/accessible by the app adapter". The engine consumes them as
a membership set, not as candidates
([LaunchPolicy.swift:202](../../lib/TerminalPTY/Sources/PaneProcessLifecycle/LaunchPolicy.swift)):

```swift
for candidate in [accountShell, "/bin/zsh", "/bin/sh"] {
    if executablePaths.contains(candidate) { return candidate }
}
```

The engine already owns the candidate ladder and the fallback order. The array
is a precomputed, positive-only answer to "is this path executable?". So the
seam asks the embedder to guess which paths the engine will query, and to answer
correctly for each. Both call sites show the cost:

- DanTerm duplicates the ladder. `SwiftTerminalBackend.launchFacts` filters
  exactly `[accountShell, "/bin/zsh", "/bin/sh"]`, and `selectedShell` walks
  exactly the same list. The cwd chain `[requested, home, "/"]` is duplicated
  the same way. Change the ladder in the engine and DanTerm stops verifying the
  new candidate, with no compile error and no failing test.
- MiniTerm gets it wrong. It passes `["/bin/zsh", "/bin/bash", "/bin/sh"]`
  unchecked. `/bin/bash` is inert, because the engine never queries it. Worse,
  because the set is a positive answer, an unverified `/bin/zsh` on a machine
  without zsh makes `selectedShell` return it and the spawn fails -- the
  `/bin/sh` fallback never runs. The one behavior the ladder exists to provide
  is defeated by an embedder that looks like it is doing the right thing. Its
  unfiltered `accessibleDirectories` is milder: the chain is a retry list, so an
  inaccessible directory costs one failed attempt.

Ideal: delete the question. Nobody pre-answers "is this path usable?" because
nobody asks it -- the spawn is the only test, and the host already has most of
the machinery. `PTYSessionBootstrap/main.c` reports a staged errno, the host maps
the cwd stage to `SpawnFailure.workingDirectoryUnavailable`, and the reducer
([PaneProcessLifecycle.swift:266](../../lib/TerminalPTY/Sources/PaneProcessLifecycle/PaneProcessLifecycle.swift))
already walks `plan.attempts` on that failure. So the cwd chain is already "try
it and see"; the `accessibleDirectories` probe is a pre-check on top of a retry
loop that handles the failure anyway. Only the shell is a hard stop today.

Make the shell a retry dimension too:

- `ResolvedLaunchPlan.attempts` becomes the full ladder, shell-major:
  `[accountShell, /bin/zsh, /bin/sh] x [requested, home, /]`, deduplicated.
- Add `SpawnFailure.executableUnavailable` for the exec stage with `ENOENT`,
  `ENOTDIR`, `EACCES`, or `ENOEXEC`. The reducer advances to the next shell's
  first cwd. A cwd failure advances to the next cwd under the same shell, as it
  does today. Any other errno stays `.systemError`.
- `noUsableShell` is reported when the ladder is exhausted at exec, not
  predicted up front.
- `executablePaths` and `accessibleDirectories` are deleted from
  `LaunchPolicyInput` and `TerminalPaneLaunchFacts`. The facts keep only what
  the embedder alone can answer: `accountShell`, `homeDirectory`,
  `inheritedEnvironment`, `localeFallback`, `productIdentity`,
  `productEnvironment`.

What this buys:

- The invariant is true by construction: there is no answer for an embedder to
  get wrong, so DanTerm's duplicate ladder deletes and MiniTerm's guess becomes
  unwritable. No new injection seam is needed to get there.
- TOCTOU disappears rather than moving: the check and the use are the same
  syscall.
- `LaunchPolicyInput` stays plain data. No closures in the pure policy,
  `Equatable` untouched, and the flight recorder records the ladder that
  actually ran.
- The separate "live facts" target shrinks to the block that is genuinely pure
  repetition -- the sorted `ProcessInfo` snapshot, `HOME`, and the
  `getpwuid`-then-`SHELL` lookup -- and nothing in it touches the filesystem.
  DanTerm layers its scrubbing and bundle lookups on top; that part is
  legitimately product-specific.

What is wrong with the ideal:

- Worst case is nine spawns before a failure report instead of one. Each is a
  `posix_spawn` of the bootstrap helper, milliseconds, and only on the failure
  path -- but it is a behavior change.
- The reducer's `attemptIndex` becomes two-dimensional, or a flat list with a
  "skip to the next shell" rule. That is the real design work, and it is small.
- Which exec errnos mean "next shell" versus "system error" is a new, explicit
  policy; today the distinction does not exist. Grep `references/` (ghostty,
  kitty) for how they classify exec failure before freezing the list.
- The engine loses the ability to say "no usable shell" without spawning.
  Nothing consumes that early answer today.
- Every test that builds a `LaunchPolicyInput` changes shape. Effort, not a
  constraint.

Fallback if the two-dimensional retry is judged too much: keep the pre-check but
pass the probe instead of the answer --
`TerminalLaunchProbes { isExecutableFile, isAccessibleDirectory }` handed to
`assembleTerminalPaneLaunch` and `resolveLaunchPlan` alongside the facts. It
fixes the duplicate ladder and the wrong guess, but it still lets a fake or a
careless embedder answer wrongly, it only moves the TOCTOU window, and it adds an
injection seam the ideal never needs. That is a trade-off, not the ideal.

Leave `localeFallback` alone in this change. It has the same candidates-plus-probe
shape (`lang_REGION.UTF-8`, then `en_US.UTF-8`, filtered by `acceptsLocale`), but
its language and region come from Foundation's `Locale`, and whether to advertise
one at all is a product switch DanTerm already exposes. Worth a second look once
the two membership sets are fixed, not bundled into the same change.

### 5. unsafeFlags blocks any versioned dependency

`lib/TerminalCore/Package.swift` sets a type-check budget through
`.unsafeFlags`. SwiftPM refuses `unsafeFlags` from a versioned dependency, so
the package works only for path dependencies -- which is to say, only inside
this repository. The manifest comment already names this as needing revisiting
before publishing.

Ideal: move `-warn-long-function-bodies=500` out of the manifest and into the
gate's build invocation. A type-check budget is a property of developing the
package, not of consuming it.

What is wrong with the ideal: it loses precisely what the manifest comment says
it bought, that every build measures whatever command produced it. That trades a
guarantee for a convention, and a 710 ms function body already slipped through
once. Move it anyway: an external consumer cannot depend on the package at all
today, and the gate is the only build where a breach has a reader.

### 6. The platform floor is a guess

Both engine packages declare `.macOS(.v26)` and `.iOS(.v26)`, almost certainly
higher than what the code actually requires.

Ideal: do not pick a number, discover it. Lower the declared floor until
compilation fails, then add a CI job that builds the engine packages at the
declared floor so it cannot drift upward again unnoticed.

### 7. There is no repository anyone can depend on

The packages live inside danterm. A SwiftPM URL dependency needs a manifest at
the repository root, and this root vends the DanTerm executables.

Ideal: do not split the repository. Publish a CI-generated mirror
(`git subtree`) holding `lib/TerminalCore` and `lib/TerminalPTY` together under
a root manifest, where the source of truth stays here and the mirror is an
output nobody edits. Divergence becomes structurally impossible instead of
disciplined against. Both packages must go into one mirror: `TerminalPTY`
depends on `../TerminalCore` by path.

### 8. TerminalPTY drags in DanTermProtocol -- done

Fixed as proposed: the one protocol-dependent case, `productionBoundsFitIPCLine`,
moved to the root package's cross-package test target as
`client-tests/PaneTapeEventLineBoundsTests.swift`, and `TerminalPTY` no longer
declares `DanTermProtocol` at all. `swift package show-dependencies` for
`lib/TerminalPTY` now resolves only `TerminalCore` and `swift-collections`.

The record of the snag as first written follows.


`lib/TerminalPTY/Package.swift` declares `.package(path: "../DanTermProtocol")`.
No shipped library imports it. The only consumer is `TerminalPTYHostTests`
(`TerminalFlightRecorderTests.swift`). Because it is a package-level dependency,
every external consumer resolves `DanTermProtocol` for a test they will never
run.

Ideal: move the protocol-dependent part of that test into the root package's
cross-package test target, which exists for exactly this shape already --
`DanTermPaneTapeRoundTripTests`, whose comment reads "Neither package can host
this on its own". `TerminalPTY` then sheds the dependency outright.

## Sequencing

Snags 2 and 4 are the API story; 3 and 8 are done. 2 is contained. 4 grew when it
was revised: it changes the launch seam, the lifecycle reducer's retry walk, and
every test that builds a `LaunchPolicyInput`, so it is no longer the small one. Snags 1, 5, 6, and 7 are
the distribution story, and 1 is the only hard one.

## Open

- MiniTerm's input path is unverified.
- Whether `posix_spawn` was chosen over `fork` deliberately, and on what
  grounds, is not recorded anywhere I found. Snag 1's ideal depends on that
  answer.
