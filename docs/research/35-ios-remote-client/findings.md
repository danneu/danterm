# Findings -- iOS remote client

Append-only evidence chain for doc 35. F2 through F5 are reserved by the task
ledger in [README.md](README.md): F2 for `TerminalRenderExecution` on iOS (T2),
F3 for the presentation-path measurement (T3), F4 for the Mac-to-Mac thin-client
spike (T4), and F5 for the bridge prototype over the tailnet (T5).

### F1 -- the portable module set builds for iOS; only host-only files fail

- Status: settled for the modules listed; supersedes the import-census inference
  in briefing.md sec. 4 for those modules.
- Date and investigator: 2026-08-12, agent (T1).
- Commit and worktree state: `98fcca12`, clean tree plus the temporary iOS
  platform pins the reproduction script applies and restores. Re-run unchanged
  on the merge that landed this finding, after six commits that touched
  `DanTermCore`.
- Environment: Xcode 26.6 (17F113), Swift 6.3.3, iOS 26.5 SDKs. Simulator triple
  `arm64-apple-ios26.5-simulator`, device triple `arm64-apple-ios26.5`.
- Commands, inputs, or reproduction:
  [ios-cross-compile.sh](ios-cross-compile.sh), from any directory. It adds
  `.iOS(.v26)` to the four `lib/*/Package.swift` manifests, builds one module at
  a time for both triples, runs the `DanTermSupport` exclusion probe below,
  restores the manifests, and writes one log per module to `.build-ios-logs/`.
- Result or artifact paths: per-module logs under `.build-ios-logs/`
  (gitignored; regenerate with the script).
- Measurements or examples: identical results on both triples, so the table does
  not split them.

  | Module | iOS build | Note |
  |---|---|---|
  | `TerminalCore` | PASS | |
  | `TerminalCoreRecording` | PASS | not in T1's list; the tape stream the client consumes |
  | `TerminalSpriteGeometry` | PASS | |
  | `TerminalRenderPlanning` | PASS | |
  | `DanTermProtocol` | PASS | |
  | `DanTermCore` | PASS | |
  | `DanTermSupport` | FAIL | two host-only files; passes on both triples with them excluded |
  | `TerminalRenderExecution` | FAIL | `import AppKit`; T2's subject, built here only to place the wall |

  `DanTermSupport` fails on exactly two symbols, in two files:

  - `CLIPathInstaller.swift:37` -- `Process()` does not exist on iOS.
  - `DoctorProber.swift:463` -- `FileManager.homeDirectoryForCurrentUser` is
    marked unavailable on iOS.

  Excluding those two files from the target makes the module build for both
  triples with no other error; the script runs that probe as its last two
  builds, tagged `minus-host-files`. The rest of the module compiles whole:
  `IpcConnection`, `ControlSocketListener`, `PaneTapeFollow`,
  `PaneTapeDumpPreparation`, `RecoveryStore`, `CheckpointWriter`, `Debouncer`,
  `InstancePaths`, `DanTermConfigPaths`, `FontAvailability`.

  `TerminalRenderExecution` stops at `import AppKit` in
  `TerminalRenderExecution.swift:2`, which aborts the module emit, so this run
  says nothing about what else in that module would fail. That is T2's job.
- Observation: five of the six modules H1 named build for both iOS triples
  untouched. The sixth, `DanTermSupport`, fails only on two files that exist to
  serve the Mac host -- installing the `/usr/local/bin/danterm` symlink, and the
  `danterm doctor` probes.
- Observation: none of the seven trees that compiled contain a single
  `#if os(...)`, `#if canImport(...)`, `@available`, or `#available` conditional,
  and no manifest excludes sources per platform. The passes are therefore
  whole-module passes: no code is silently dropped or degraded on iOS. Outside
  Foundation and the project's own modules, the passing set imports only
  `DequeModule` (swift-collections, in `TerminalCore`), `Darwin` (socket IO in
  `IpcConnection` and `ControlSocketListener`), `Synchronization`
  (`ControlSocketListener`), and `CoreText` (`FontAvailability`). All four exist
  on iOS, and the first of them means the client inherits the swift-collections
  package dependency.
- Inference: H1 is confirmed for `TerminalCore`, `TerminalRenderPlanning`,
  `TerminalSpriteGeometry`, `DanTermProtocol`, and `DanTermCore`, and confirmed
  for `DanTermSupport` only after two host-only files leave the module. The
  engine and protocol spine of the client carries no compile-time porting work.
  H1's
  claim about `TerminalRenderExecution` -- an `NSFont` seam plus a swapchain
  decision -- is neither confirmed nor rejected here; the module does not get
  far enough to itemize.
- Inference: the portability boundary in `DanTermSupport` runs between files,
  not through them. Two files are the whole failure, and both are Mac-host
  roles a phone client would never call.
- Competing interpretations: a compile is not a run. Several modules compile on
  iOS while carrying Mac-shaped runtime assumptions that only fail in use --
  `NSHomeDirectory()` in `DanTermCore` (`CoreEnvironment.swift`, `Model.swift`,
  `ModelOperations.swift`) resolves inside the app sandbox on iOS,
  `DanTermConfigPaths` hardcodes `~/.config/danterm/config.json`,
  `RecoveryStore` writes under `~/Library/Application Support/<bundle-id>/`, and
  `FontAvailability` enumerates the local font registry, which on a phone
  describes the phone. None of these is a build failure and none is settled by
  this finding.
- Uncertainty: the device-triple builds link nothing and run nowhere -- this is
  a compile result, not a working binary on hardware. T2 and T3 produce the
  first result that actually runs on a device.
- Uncertainty: `DanTermSupport` exports nothing. Every declaration is
  `internal` except three `package` ones in `DoctorProber.swift`, so an iOS
  client target outside the package cannot reference `IpcConnection` or
  `PaneTapeFollow` today even though both compile. T16 owns that access level,
  as part of the same split; T12 owns the separate question of whether the
  client links the `DanTermCore` model at all.
- Next action: T2 (`TerminalRenderExecution` on iOS) is now the only unanswered
  half of H1 and gates the D2 presentation choice. T16 records the
  `DanTermSupport` split the failure implies.

#### Why the iOS platform pins are not in the tree

The pins were added, built with, and removed. A SwiftPM `platforms:` pin is
package-level, and both packages that need one hold host-only targets in the
same package: pinning `TerminalCore` would declare iOS support for
`TerminalRenderExecution` and the benchmark executables, and pinning
`DanTermSupport` would declare it for the CLI installer and the doctor probes.
Landing the pins now would put a claim in the manifests that nothing checks and
that this finding shows to be false in part. The pins belong with the work that
makes them true: the `DanTermSupport` split (T16), the
`TerminalRenderExecution` decision (D2), and the platform-layering lint (T14).
Until then the reproduction script owns them.
