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

### 4. TerminalPaneLaunchFacts has eight required fields

Every embedder rewrites the same block that reads `HOME`, `SHELL`, and the
process environment.

Ideal: leave the type exactly as it is. The explicitness is the design -- it is
the same seam discipline as `CoreEnv`, and a convenience initializer that reads
the process would put ambient IO into a package that deliberately has none. The
ideal is a separate small target (`TerminalPaneLaunchEnvironment`) whose one job
is reading the process for those facts. Purity is preserved and no embedder
rewrites the block. This is the snag where the obvious fix is the wrong one.

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

### 8. TerminalPTY drags in DanTermProtocol

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

Snags 2, 4, and 8 are contained and unblock the API story; 3 is done. Snags 1, 5, 6, and
7 are the distribution story, and 1 is the only hard one.

## Open

- MiniTerm's input path is unverified.
- Whether `posix_spawn` was chosen over `fork` deliberately, and on what
  grounds, is not recorded anywhere I found. Snag 1's ideal depends on that
  answer.
