# Findings -- iOS remote client

Append-only evidence chain for doc 35. F3 and F5 are still reserved by the task
ledger in [README.md](README.md): F3 for the presentation-path measurement (T3),
and F5 for the bridge prototype over the tailnet (T5).

F2 and F4 outgrew this file and live beside it, per the promotion rule in
[FORMAT.md](../FORMAT.md). The entries here carry the result and the pointer;
the linked file carries the evidence.

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

  **Corrected by T16.** That inference is true as a compile result and
  misleading as a boundary, and the difference sent T16 looking for a file move
  that does not exist. Compiling for iOS is not the same as having a role a
  client would call: eight of the ten files that compile are either the producer
  end of the control socket or names for the Mac's own filesystem and session.
  "Portable" in this tree has always meant "not AppKit", never "not a Mac".
  There is no client half of `DanTermSupport` to separate out; the client end of
  the conversation is a module that does not exist yet, which is now T17.
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

### F2 -- `TerminalRenderExecution` needs one font seam; the swapchain is portable

Full finding: [f2-render-execution.md](f2-render-execution.md). Reproduction:
[ios-render-spike.sh](ios-render-spike.sh). Screenshots: `f2-artifacts/`.

- Status: settled for the compile and for the presentation mechanism in the
  simulator; the device result is a compile only.
- Date and investigator: 2026-08-12, agent (T2).
- Commit and worktree state: `58abcfc6`, `lib/` unmodified. The script applies
  and restores both the iOS platform pin and the font seam per run.
- Result: the `import AppKit` in `TerminalRenderExecution.swift:2` hides exactly
  one symbol. `NSFont.monospacedSystemFont(ofSize:weight:).fontName` on line 90
  is the whole dependency; swapping the import to UIKit leaves two errors, both
  on that line, and `UIFont` answers both members with the same spelling. A
  `typealias PlatformFont` behind `#if canImport(AppKit)` builds the module for
  the simulator triple, the device triple, and macOS.
- Result: `NSAttributedString` was a false alarm -- it is Foundation, and only
  `.Key` is used, as the dictionary key type for CoreText attributes.
- Result: `TerminalFrameBackingStore` and `TerminalFrameSwapchain` are portable
  as-is, with no change, no stub, and no replacement. IOSurface is public on
  iOS, and every call they make -- `IOSurface(properties:)`, `baseAddress`,
  `bytesPerRow`, `lock`/`unlock`, `isInUse` -- compiles and runs.
- Measurements or examples: one static 57x12 plan presented three ways at once
  (CGImage as `layer.contents`, the IOSurface as `layer.contents`, and a `blit`
  into a UIKit context) displays identically across colors, bold/italic/
  underline, reverse, box-drawing and block sprites, powerline and braille
  sprites, packaged Nerd Font PUA glyphs, and the cursor. Two further probes
  isolate the publish mechanism: rewriting the store's pixels in place changes
  nothing on screen (the two screenshots are byte-identical), and reassigning
  the *same* surface as `layer.contents` updates only that panel.
- Observation: attach-to-publish is exactly what `TerminalFrameSwapchain.publish`
  does, and `isInUse` reads false right after assignment and true while
  displaying, the shape the acquisition logic already assumes.
- Inference: H1's `TerminalRenderExecution` clause is confirmed, and it costs one
  line rather than a port. H2's framing no longer fits: it asks whether frames
  present "without IOSurface" and offers `CAMetalLayer`/`CVPixelBuffer` as the
  closer analogue to the swapchain, but the swapchain itself is available
  verbatim, so the substitute is unnecessary. H2 is restated in
  [README.md](README.md) and T3 now compares CGImage-copy-per-frame against the
  real `TerminalFrameSwapchain`, both on iOS.
- Competing interpretations: simulator CoreAnimation runs against the Mac's
  render server, so "an IOSurface displays as layer contents" could be a
  simulator affordance rather than an iOS one. The device-triple result is a
  compile, not a run. This is the single thing T3 must confirm before it
  measures anything, because the H2 restatement rests on it.
- Uncertainty: one static frame says nothing about sustained publish rates, the
  incremental `apply` path, scroll translation, or energy. There is no iOS
  equivalent of `tests-ui/IOSurfaceLayerContentsTests.swift` ("a detached
  surface reported free stays free"); `isInUse` was sampled twice seconds apart,
  not under a real publish cadence. Font parity for the user's configured family
  is untouched -- the spike used the system monospace at 11pt. `DanTermSupport`
  still exports nothing, so the spike drives a local `Terminal` with literal
  bytes rather than linking IPC or tape-follow.
- Next action: T3, starting with the device confirmation above. The font seam is
  deliberately uncommitted and lands with the platform pins in T16.

#### A silent bundle trap for any iOS client

`NerdFontSymbolsResource.packagedURL()` checks `Bundle.main` at
`NerdFontsSymbolsOnly/SymbolsNerdFontMono-Regular.ttf` and then returns nil
rather than consulting `Bundle.module` whenever `Bundle.main` is a `.app`. An
iOS bundle assembled naively -- SwiftPM's generated resource bundle copied
beside the executable -- therefore renders every PUA glyph as tofu, with no
error. Copying the `.ttf` to that path, which
`scripts/bundle-theme-resources.sh` already does for the macOS app, fixes it.
This is a bundle-assembly requirement, not a portability defect, and it fails
silently, which is why it is recorded here.

### F4 -- a second engine converges; joining mid-stream loses modes, not just history

Full finding: [f4-mac-to-mac.md](f4-mac-to-mac.md). Spike and scenarios:
`t4-spike/`.

- Status: settled for convergence and for the join gap; single-machine only.
- Date and investigator: 2026-08-12, agent (T4).
- Commit and worktree state: one commit on `38676539`. Nothing is wired into the
  app build or the test gate, and no API was extended.
- Environment: one machine, one Unix socket, one shell (fish), debug build, no
  network. No timings, so nothing here is a performance claim.
- Commands, inputs, or reproduction: `t4-spike/scenarios.sh <socket> <pane>
  <scenario>` runs ten scenarios against a live slot and captures both sides.
  The client speaks the control socket itself (AF_UNIX, hello, then a
  `pane.tape` request with follow); it does not use the CLI as a transport.
- Result: H3's convergence half is confirmed. A client replaying a pane's whole
  retained tape from birth produced a `viewportText` byte-identical to that
  pane's own `pane read` -- 30 lines, to the last byte, with SGR color, a
  wide-character pair, and scrolling in the workload -- and the same
  `totalRows`. It planned a `RenderFramePlan` (179x66, 96 text runs) from its own
  engine in a process with no AppKit. The uplink needs nothing new: the input
  driving that output was sent with `pane.input` on a second connection while
  the client watched.
- Measurements or examples: two clients on the same pane at the same moment, one
  replaying and one `--from-now`, against a program that had entered the
  alternate screen and set modes before either attached. Every difference is
  what the join lost: `isAlternateScreenActive` true vs false, cursor visibility
  true vs false, cursor row 5 vs 8, `applicationCursorKeys` true vs false,
  `bracketedPaste` true vs false, `mouseTracking` click vs off, and the pane's
  history vs none.
- Observation: the input-mode rows are the ones that bite. A client encodes
  keystrokes from its own `terminal.inputModes`, so a late joiner sends CSI
  arrows where the child expects SS3, and pastes unbracketed, purely because it
  joined late.
- Observation, from bytes: the first feed event after a join was `"echo " CR
  ESC[9C` -- fish repainting the command line and moving the cursor forward nine
  columns relative to a prompt the joiner never received. The joiner's first line
  read `echoecho after-join`. The stream is not self-synchronizing.
- Observation: a joiner that runs past the program's `?1049l` and the next prompt
  repaint ends up with a clean, correct-looking two-line prompt, because the
  erase sequences resynchronize the visible screen, while its `totalRows` is
  still just the grid. A joiner heals what a repaint covers and nothing else, so
  it can look fine and be empty. A check that only reads the top of the screen
  would report success.
- Inference: `pane.snapshot` has an explicit floor. Which screen is active plus
  both screens' contents; primary history with attributes; the live grid's cells
  with attributes; the cursor (row, column, visibility, shape, blink, DECSC);
  `inputModes` in full; the remaining parser and screen modes the tape sets and
  never restates (scroll region, origin, autowrap, tab stops, current SGR pen,
  charsets, synchronized output); the geometry the snapshot was taken at, which
  is NOT the tape's `initial`; and the stream cursor (sequence plus
  per-direction byte offsets) taken atomically with all of it.
  `TerminalFlightRecordingCapture` already fences origin against cursor snapshot
  for its own two captures for exactly this reason, and the snapshot needs the
  same fence against the subscription it splices onto.
- Inference, for T10: stream geometry is unconditional and authoritative. A
  client built at a phone-shaped 40x20 and given a backlog follow is clobbered to
  179x66 by the tape's resize event; with `--from-now` it never receives a resize
  at all, stays 40x20, and renders 179-column output into 40 columns as
  interleaved garbage (CUP clamped, CR/CUF landing in the wrong cells). There is
  no third option where the client quietly renders at its own size. *Observe*
  means local reflow AFTER applying the stream's geometry -- verified working,
  the client reflowed to 40 columns and planned a coherent frame -- and *claim*
  means the client's size enters the stream as a normal resize event.
- Inference: eviction corrupts geometry, not just history. After ~9.9 MB past the
  recorder's 8 MiB / 32,768-event bound, a backlog client got a gap of 756 events
  / 554,752 feed bytes, and the resize event correcting the recorder's 80x24
  birth geometry was among the evicted ones -- so it replayed 8,940 events into
  an 80x24 grid for a 179x66 pane. The events that establish geometry and modes
  are the oldest, so they go first. The corollary is that the retained tape is a
  usable snapshot substitute exactly while it is un-evicted, which makes the
  eviction bound a session-durability parameter rather than a debugging one.
- Inference: resume already has most of its coordinates.
  `TerminalFlightRecordingCursor` (sequence plus feed/write byte offsets) is a
  resume position, the start record already publishes it, and
  `cursorSnapshot(from:)` already computes exact per-direction loss against an
  arbitrary cursor and reports it as a gap. What is missing at the protocol edge
  is only the ability for a client to SUPPLY a cursor: `pane.tape` offers
  beginning or now, nothing else. Measured cost: a client dropped at sequence
  10089 reconnected with `--from-now`, got a start cursor of 10306, and no gap
  record -- 216 events skipped silently, because from the producer's view a
  from-now request lost nothing relative to what it asked for. A `fromSeq`
  request would reuse machinery that already exists and would turn that silence
  into a stated gap.
- Uncertainty: the snapshot floor is derived from what actually diverged plus
  what `Terminal.presentation`/`inputModes` expose. DCS state, OSC 4 palette
  redefinitions, OSC 11 background overrides, hyperlink state, the title stack,
  and OSC 133 marks were not individually probed, and OSC 11 query traffic is
  visibly present in the captured stream. Also unexamined: what a WRITER client
  should do with the reply bytes its own engine generates for `ESC[6n` /
  `ESC[0c`, that is, two engines answering the same query.
- Security: the spike opened no listener. Existing Unix control socket only;
  access control is filesystem permissions on the per-instance cache directory.
- Next action: T8 designs `pane.snapshot` plus sequence-numbered resume against
  the floor above. T10 chooses between observe and claim knowing there is no
  third option.

#### No control-surface query for pane state

Recorded for the record, not as a request. A client can watch a pane's bytes but
cannot ask what state it is in. `pane.info` reports title, cwd, integration,
agent, command, and connection, with no geometry, modes, or screen state;
`pane.rows` gives per-row width and structure but no attributes; `pane.read`
gives text. The closest thing to a snapshot today is `pane.rows` plus
`pane.read`, which carries no attributes, no cursor, and no modes.
