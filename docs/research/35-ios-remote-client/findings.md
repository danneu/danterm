# Findings -- iOS remote client

<!-- docs-lint: allow-missing t5-bridge/ -->
<!-- docs-lint: allow-missing t5-run.sh -->

Append-only evidence chain for doc 35.

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

- Status: settled for the compile. The presentation-mechanism half was measured
  in the simulator only, and F3 superseded it on hardware: the in-place-mutation
  result below does not reproduce on a device, where mutating an attached
  surface presents indeterminately instead of not at all. Read the two
  "Measurements or examples" probes and the "Inference" clause about
  attach-to-publish as simulator behavior, not iOS behavior.
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

### F3 -- on device, attach-to-publish is required, not merely honored

Reproduction: `ios-render-spike.sh device`
([ios-render-spike.sh](ios-render-spike.sh)), which builds, signs, and installs
the same spike for a real iPhone, sharing everything up to the install with the
simulator target F2 used. Screenshots and console transcripts: `f3-artifacts/`.

- Status: settled. The presentation mechanism is confirmed on hardware, and the
  measurement half has run: frame cost, cadence, and a CPU-time energy proxy
  under a bursty incrementally damaged workload.
- Date and investigator: 2026-08-13, agent (T3), with the user holding the
  device and reporting what the screen did.
- Commit and worktree state: the runs span `642143b6..e4dd79e1`, because another
  session committed sidebar work while they were in progress. Nothing under
  `TerminalRenderExecution` or `TerminalRenderPlanning` changed across that
  range, so every probe ran against identical engine sources. Unlike F2 the
  script patches nothing: the iOS platform pin and the font seam are both in the
  tree now, so this is a plain `swift build` against the shipped sources.
- Device: iPhone 13 mini (iPhone14,4), iOS 26.6, `displayScale=3.0`. Signing
  reused an existing wildcard development profile that already listed the
  device, so no Xcode project was created; see the sub-section below.
- Result: F2's simulator discriminator does **not** reproduce on device, and the
  behavior it reported is not merely different but nondeterministic. Rewriting
  the backing store's pixels in place, with nothing reattached, made panel B
  flash the new frame, revert to the stale one, and then -- roughly thirty
  seconds later, with no further rendering -- alternate between the two frames
  indefinitely. The console proves the render happened exactly once
  (`PROBE-D-ABLATION` appears one time in `console-ablation.log`), so every
  change after it is presentation-side.
- Result: a forced compositing pass is not the trigger. Eighteen taps, each
  recoloring one unrelated square and touching neither the store nor panel B's
  `contents`, left all three panels on the stale frame.
- Result: the real `TerminalFrameSwapchain` driving a layer is stable. 100
  frames at 10Hz, each a full repaint with a changing counter and a cycling
  background, published and attached with **zero** coalesced publishes -- so
  buffer acquisition never stalled, which means CoreAnimation releases buffers
  through `isInUse` on device the way the acquisition logic assumes. After a
  deliberate stop, frame 99 held indefinitely with no reversion. Its background
  is blue, matching `41 + (99 % 6)`, so the frame displayed is the frame last
  published and not a lucky repaint.
- Result: an IOSurface does display as `layer.contents` on hardware, so F2's
  presentation result was not a simulator affordance. The packaged Nerd Font
  glyphs render from a hand-assembled device bundle too.
- Inference: the difference between the two outcomes is the one thing that
  differs between them -- whether the surface being written to is currently
  attached. `TerminalFrameSwapchain` renders into a detached buffer and then
  attaches it; violating that on iOS produces the alternation above. So
  attach-to-publish is not a macOS habit the port could drop. It is what makes
  presentation deterministic on iOS, which is a stronger claim than F2's
  "CoreAnimation honors the same protocol" and it points the same way.
- Inference: the H2 restatement in [README.md](README.md) is wrong as written on
  hardware. "An in-place pixel rewrite does not reach the screen, and
  reassigning the same surface does" describes one sample of an indeterminate
  behavior. Corrected there.
- Competing interpretations: the mechanism behind the alternation is not
  established. CoreAnimation plausibly holds a cached texture and re-samples the
  live surface on a schedule of its own, but nothing here probes that, and the
  finding does not need it -- the design consequence follows from the observable
  alone. What triggers the re-sampling is also unknown; it is not app-requested
  compositing, which the tap result rules out.
- Uncertainty: the ablation's evidence is the user's direct observation, not a
  screenshot, and deliberately so -- a screenshot forces a capture through the
  render server, which is the very thing under test. Everything about frame
  timing, sustained publish rates, the incremental `apply` path, scroll
  translation, and energy remains unmeasured. The probes used the system
  monospace at 11pt, so font parity for the user's configured family is still
  untouched.
- Scope of the inference: this says nothing against CGImage-copy-per-frame,
  which is deterministic by construction because each frame is a new immutable
  image rather than a mutation of an attached one. Probe A held its frame
  through every run here, the ablation included. The finding constrains how a
  *reused* surface may be driven; it does not choose between the two arms.
- Next action: D2 selects the presentation path; the measurements below are its
  evidence.

#### The measurement half, and two instruments that failed first

Console transcripts: `f3-artifacts/console-bench-paced.log`,
`console-bench-saturated.log`, `console-energy.log`. Reproduce with
`SPIKE_MODE` set to `bench`, `bench-sat`, or `energy`.

The harness carries a third arm, `plan-only`, that presents nothing. It exists
because the plan build was supposed to be a control the presentation path cannot
reach, and twice it proved it was not one.

- Under display-link pacing, that identical plan-building work read 3300us
  beside the swapchain, 2482us beside the copy path, and **6138us beside no
  presentation at all** -- ordered by how much the arm did around it, steady per
  block, with thermal state flat. A lighter frame lets the thread idle between
  vsyncs and the CPU settle into a lower power state, so the arms ran at
  different clocks. No per-frame comparison between them meant anything.
- Saturating the thread removes the idle, and the control equalizes to
  1922/1914/1945us across the three arms. That is the ablation: hold the clock
  up and identical work costs identical time.

So the two pacings answer different questions, and each transcript says which:
paced reports whether the cadence holds, saturated reports what a frame costs.

- Measurement (saturated, full repaint, 53x54 at `displayScale` 3.0, n=480 per
  arm): the swapchain presents in 1195us p50 against the copy path's 1984us.
  The ~788us gap is about what copying this grid's 9.6MB surface costs.
  Diagnostic timings, not benchmark results.
- Measurement (paced): both arms hold 60Hz -- tick gap p50 16.68ms, p99 under
  16.9ms, `missedPresentations=0` on both. Neither is a throughput problem.
- Measurement (energy proxy, three independent runs): under a 2-second cycle of
  0.25s output, 0.35s typing, and 1.4s idle, with damage drained from the engine
  rather than forced full (`damagedRows` p50=1, p95=3), CPU seconds over the
  same 12.02s wall clock and the same ~218 delivered frames were:

  | arm | run 1 | run 2 | run 3 |
  |---|---|---|---|
  | swapchain | 1.590s | 1.578s | 1.574s |
  | cgimage-copy | 1.737s | 1.756s | 1.743s |
  | plan-only | 1.580s | 1.565s | 1.573s |

  Within-arm spread is about 0.016s and the swapchain and copy ranges do not
  overlap. The copy path costs roughly 11% more CPU; the swapchain's
  presentation cost, +0.008s against presenting nothing, is indistinguishable
  from zero at that spread.
- Inference: the swapchain wins on both instruments, and on the realistic
  workload it wins by not paying per-frame copies that damage of one row does
  not justify. This is the cost half of D2, and it agrees with the correctness
  half.
- Inference, and the more useful one: presentation is not where this workload's
  energy goes. Presenting nothing at all costs 1.57s of the swapchain's 1.59s.
  The rest is shared -- engine feed, plan building, and a display link that
  keeps ticking at 60Hz through a 1.4s idle in which nothing is damaged. The
  arm choice moves total CPU by about 11%; not running a display link when
  there is no damage is the larger lever, and no arm's numbers can answer it.
  It belongs to the client's design, not to D2.
- Uncertainty: CPU seconds are a proxy for energy, not a joule count, and the
  transcript labels them so. Instruments never attached, so nothing here
  measures the display, the memory system's own power, or a session-length
  drain. One grid, one device, one font size. The workload is a plausible
  terminal cycle, not a recorded one; a heavier real workload would raise every
  arm's share and could change the ratio. `damage.apply` returning false falls
  back to a full render in the copy arm, and how often that happened is not
  instrumented.
- Uncertainty, and the one that bears on D2: the harness does not implement the
  swapchain's owner contract. `app/SwiftTerminalSessionView.swift` retries a
  coalesced publish on a later tick; the energy arm here does neither -- it
  ignores a nil return and still counts the frame, so a coalesced publish would
  read as a delivered frame. The paced benchmark did count them, at zero across
  480 samples per arm, which is the only reason to think the energy arm's frame
  counts are honest. A client that runs this swapchain has to own the retry, and
  that owner is real iOS code the copy path would not need.

#### Getting on device needs no Xcode project

The tree has no `.xcodeproj`, no xcodegen, and no `xcodebuild` in any build
path, and this finding did not add one. Three things already existed: the device
was paired to `devicectl` over the network, an `Apple Development` identity was
in the keychain, and a wildcard development profile (`TEAM.*`) listed the
device's UDID. That covers any bundle id, so the flat bundle the script already
assembled for the simulator only needs an embedded profile, an entitlements
plist, and `codesign` before `devicectl device install app` accepts it. That is
why the two targets are one script: they diverge only at the install.

The `device` target picks the profile by matching the team's wildcard app id
rather than by UUID, so a reissued profile does not break it, and it derives the
signing identity from the certificate that profile embeds, so the signature and
the profile cannot disagree. The one thing minting
a profile would still be needed for is a bundle id outside the wildcard, or a
device not yet registered.

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

### F5 -- the tailnet bridge holds a session across a wifi-to-cell switch

Discharges T5. Reproduction: [t5-run.sh](t5-run.sh), which builds and starts
[t5-bridge/](t5-bridge/) and launches the `t5` mode of
[ios-render-spike.sh](ios-render-spike.sh) against it.

- Status: settled for the path it exercised, on one device, over one tailnet,
  in one session per phase. The latency numbers are diagnostic, not benchmark:
  they were not produced under
  [agent-docs/terminal-performance.md](../../../agent-docs/terminal-performance.md)
  conditions, and this doc's rules require them to be labeled so.
- Date and investigator: 2026-08-13, agent (T5).
- Commit and worktree state: `061cf3d8`, plus the instrument changes that land
  with this finding.
- Environment: Xcode 26.6, Swift 6.3.3, macOS 26.5.2. Mac `macbook` at
  `100.106.152.106` on `utun4`; iPhone 13 mini `iphone-13-mini` at
  `100.98.63.67`, iOS 26. One dev slot from `just launch-slot`, one pane at
  179x66. Tailscale reported a DNS health failure the whole time (`openat
  ts.net: path escapes from parent`), so every address here is a raw 100.x one
  and MagicDNS was never used.
- **Authentication story, as this doc's investigation rules require of any task
  that opens a listener.** There is none, and this is the doc's own escape hatch
  rather than an omission: an unauthenticated listener is permitted exactly when
  it is bound to the tailnet interface and the finding says so. This one is, and
  the binding is structural rather than conventional. `TailnetBindAddress` is the
  only way to construct a listen address, and it refuses a wildcard, any address
  outside 100.64.0.0/10, and any tailnet address no local interface carries; all
  four refusals were exercised. There is no flag, no default, and no typo that
  reaches a listener the tailnet does not already gate, so reaching this port
  means holding a WireGuard key this tailnet has admitted. This supersedes F7's
  compromise -- one explicit LAN address plus a shared `token` line -- which
  existed only because the Mac had no tailnet when T23 ran. Nothing here decides
  pairing, certificate pinning, the method allowlist, rate limits, or the audit
  log: T6 owns all of them and records D4, and a prototype that grew an auth
  model would have pre-empted T6's obligation to weigh the ideal alternative of
  the app listening on the network itself.
- Result: **the bridge works, and the phone drove a real pane through it.** An
  iOS binary linking `DanTermClient` reached the control socket over the tailnet,
  completed the hello handshake, subscribed with `start: now` and
  `mode: reconstructible`, received a stream-version-3 opening sync at 179x66,
  and then held a conversation for 215 consecutive seconds. Nothing in `lib/`
  changed.
- Result: **H4 is confirmed in the confirming direction, and the margin is
  larger than the hypothesis assumed.** The TCP connection survived a full
  wifi -> cell -> wifi round trip *without reconnecting*. There was no stream
  close, no resume, no gap record, and no lost frame; the bridge never logged the
  connection closing, and the phone's own transcript has 215 unbroken beats. The
  tailnet address is stable across the interface change, so the connection the
  phone holds is not tied to the path underneath it.
- Measurements, diagnostic: round trips from the phone, 40 samples per phase.
  The Mac-to-its-own-tailnet-address baseline is 30 samples of the same request
  and exists to separate the network from the bridge and the app.

  | Path | p50 | p95 | max |
  |---|---|---|---|
  | Mac -> own tailnet address, `pane.info` (baseline) | 1.9ms | 5.6ms | 7.3ms |
  | Phone -> Mac, `pane.info` (no PTY, no shell) | 11.9ms | 86.8ms | 91.3ms |
  | Phone -> Mac, keystroke -> the pane's own echo | 21.9ms | 104.8ms | 127.3ms |

- Measurements, diagnostic: the heartbeat across the switch, 215 beats at one
  per second, segmented by the two transitions. The middle window is 5x slower
  at p50 and returns afterwards, which is what establishes that the phone really
  was carrying traffic over cellular rather than briefly dropping an association.

  | Window | beats | p50 | p95 | max | over 100ms |
  |---|---|---|---|---|---|
  | wifi, before the switch | 138 | 16.5ms | 128.0ms | 165.9ms | 7% |
  | cellular | 46 | 80.0ms | 176.7ms | 276.9ms | 28% |
  | wifi, after returning | 29 | 19.8ms | 124.7ms | 126.2ms | 17% |

  The two transitions cost one stalled beat each: **4.3s leaving wifi** and
  **6.4s returning to it**. Both completed rather than failing, so the cost of a
  network switch on this path is a single multi-second freeze, not a session.
- Result: **the buffering bound is enforced by there being no buffer.** The
  ledger states that the bridge is the only place an unbounded per-subscriber
  buffer can exist, so the invariant to carry is that it holds at most one
  in-flight batch per subscriber. The bridge holds no queue at all: each
  direction reads one 64 KiB buffer and writes every byte of it before reading
  again, so when the phone is slow the bridge stalls inside the write, stops
  draining the control socket, and lands the backpressure on the app -- where
  `PaneTapeFollowSubscriptions` already keeps one batch in flight and merges
  every append behind it. The coalescing stays in the component that implements
  it, and the bridge cannot grow a second, unbounded copy of it.
- Result: the framer is an observer rather than a gate. Bytes are forwarded as
  they arrive instead of being held until a record completes, which keeps the
  bound at one read buffer rather than one record -- and a record here can reach
  the 16 MiB IPC line bound that a D5 sync is sized against. A repair policy that
  must act per record is what would have to pay that cost. T20 owns it, and this
  finding is where the price is recorded rather than discovered later.
- Measurements, feeding T19 and not deciding it: over the whole 215-second
  session the downlink carried **252,265 bytes in 571 frames** (largest frame
  4,303 bytes) and the uplink **52,710 bytes in 372 frames** (largest 192). A
  stream deflater over the same downlink would have produced **17,973 bytes, a
  ratio of 0.071** -- about 14x. The bridge measures this and applies nothing:
  T19 decides whether a binary tape framing has anything left to win after
  compression, and a prototype that quietly compressed its stream would have
  answered that by accident. Note the traffic is a heartbeat plus an idle pane,
  which is the most compressible shape this stream has; it is a ceiling, not a
  typical case.
- Observation: **`devicectl device process launch --console` cannot be used for
  a mobility test, and the way it fails is misleading.** The first attempt lost
  its console the instant wifi went down -- the console streams over the same LAN
  wifi the experiment turns off -- and devicectl then SIGTERMed the app, which
  logged `App terminated due to signal 15`. The subject died with the instrument,
  for a reason with nothing to do with the tailnet, and the transcript ended at
  the exact moment the experiment began. The working shape is a detached launch
  plus two independent records: the phone writes its own timestamped transcript
  to its Documents container (pulled afterwards with `devicectl device copy
  from`), and the bridge reports live counters from the Mac. T9 tests airplane
  mode, backgrounding, and cold relaunch, and will meet this trap first.
- Uncertainty: **the bound was never stressed.** Across the whole session the
  bridge spent 27ms blocked writing to the phone, out of 215 seconds. The phone
  kept up with an idle pane trivially, so the backpressure path is proved to
  exist by construction and is not proved to behave under load. The workload that
  would exercise it is a flood, and T21 owns the flood.
- Uncertainty: **the p95 tail is unexplained.** On wifi the round trip is 12ms at
  p50 and 87ms at p95 on an otherwise idle link, and 7% of heartbeat beats
  exceeded 100ms. Phone wifi power saving, Tailscale, and the bridge are all
  candidates and none was separated. It matters because the doc already records
  that latency is the phone's dominant variable and that no task owns it.
- Uncertainty: **TLS was never tested.** H4 says "a TCP+TLS listener" and this
  prototype terminates no TLS. The user chose that: over WireGuard, TLS adds
  encryption that is already there and, without pinning, no identity -- and
  choosing an identity model is D4's job. So the TLS half of H4 is untested
  rather than disproved, and T6 should decide it rather than inherit it.
- Uncertainty: one run per phase, one device, one tailnet, one physical location.
  The switch was made from Control Center, which drops the wifi association but
  does not power the radio down, so a phone that walks out of range may behave
  differently from one that is told to leave.
- Uncertainty: nothing here measured battery, and the heartbeat is not a
  realistic workload for it.
- Inference: **resume is not what a network switch needs.** D5 built sync and
  cursor resume for a client whose subscription dies, and F4 measured what the
  gap costs. This finding says the wifi-to-cell case does not reach that
  machinery at all -- the connection simply persists through a multi-second
  freeze. That narrows what T9 is really testing: backgrounding, app death, and
  cold relaunch, where the process loses its socket, rather than mobility, where
  it does not. It also raises the value of the freeze itself as a UI problem: the
  client is unresponsive for four to six seconds with no error to show, and
  nothing in the protocol tells it which of the two situations it is in.
- Inference: Tailscale earns its place in the direction section on evidence now
  rather than on being half-deployed. It supplies the reachability, the stable
  address that makes the switch survivable, and the identity that lets this
  listener carry no auth of its own.
- Next action: T6 takes the auth model with the tailnet arm now demonstrated,
  and must still weigh the app listening on the network itself against a bridge.
  T9 takes backgrounding and cold relaunch, and the `--console` trap above. T19
  takes the compression ceiling. T21 takes the flood that would stress the bound.

#### The T23 relay is deleted, not archived

`t23-relay.py` is removed. It was a throwaway TCP splice with no framing, no
session state, and no buffering policy, and its shared-token authentication
existed only because there was no tailnet to bind to. Every one of those is now
answered by the bridge, and this doc's rules delete a spike once the gate it
feeds has chosen.

F7's reproduction is not orphaned by the deletion: the T23 client smoke runs
against the bridge instead, and [t23-run.sh](t23-run.sh) takes no token. That
is worth stating rather than leaving to be discovered, because it means F7's
result -- the composition works on a phone -- is still reproducible from the
tree as it stands.

### F6 -- the client module ships, and the platform claim is now gated

Discharges T17, T18, and T14. Plan:
[plans/wip/2026-08-12-2225-host-layer-and-the-missing-client-module.md](../../../plans/wip/2026-08-12-2225-host-layer-and-the-missing-client-module.md).

- Status: implemented and on master, gated by `just test`.
- Date and investigator: 2026-08-13, two agents working in parallel worktrees.
- Environment: Xcode 26.6, Swift 6.3.3, iOS 26.5 SDKs.
- Commands, inputs, or reproduction: `just test`. 81 steps.
- Result: `lib/DanTermClient` exists and owns the client end of the
  conversation -- a transport seam naming no socket kind, the framed
  request/reply/notification loop over `IpcLineFramer`, the hello handshake, and
  a pane-tape record decoder. It depends on `DanTermProtocol` alone. The CLI's
  two hand-rolled transport copies are deleted and rewired onto it, so the
  module is exercised by the existing gate rather than shipped untested.
- Result: `lib/TerminalHostTools` now holds `GlyphPreview`, its test target, and
  `TerminalMemoryProbe`, which is what makes the `TerminalCore` iOS pin true
  rather than allowlisted. Pins are on `TerminalCore`, `DanTermProtocol`, and
  `DanTermClient`.
- Result: `scripts/ios-portability-gate.sh` cross-compiles every manifest target
  of every pinned package for the iOS device triple, test targets included, as a
  suite step. It discovers pinned packages by reading the manifests, so a
  package is covered the moment it is pinned. It carries a fixture self-test
  that is also a suite step.
- Observation: the plan's requirement that a reader survive an unknown record
  kind is satisfied by making `unknown(kind:)` a case of the record type rather
  than a decode failure, and an unknown end reason still reads as an end. Both
  are what let T8 add a `sync` record without breaking an older client.
- Observation: two test fragments could not be made portable and were guarded
  rather than exempted -- a `/usr/bin/vmmap` shell-out, and a Swift Testing exit
  test, which is unavailable on iOS because it spawns a child process. Both are
  instruments rather than behaviors under test, and macOS keeps the coverage.
  The second was invisible to T16's evidence, which enumerated executable
  targets only.
- Inference: a compile boundary is not a role boundary, and this finding is the
  constructive half of that correction. F1 established which files compile for
  iOS; T16 established that the answer did not describe a module a client could
  use; F6 builds the module that was actually missing.
- Uncertainty: nothing here has run on a device, and no iOS client links
  `DanTermClient` yet. The module is proven to build and to behave against
  in-memory and socket transports, not to work from a phone.
- Uncertainty: the gate links test bundles against the macOS sysroot, which
  clang warns about. Compilation is faithful to the iOS triple, so a host-only
  import or call still fails the gate, but the link step is not a full iOS link.
- Next action: T3 remains Phase 1's only open task, and it needs a physical
  device. T8 implements against the vocabulary this module reads.

#### The T16 probe is deleted, not archived

`t16-probe.sh` and `t16-probe/` established that a client module could build for
both iOS triples with `DanTermProtocol` as its only dependency. They are removed
because that claim is now enforced continuously against the real module by the
suite step above, which is stronger evidence than a script nobody runs.

Deleting them also removes a trap. The probe named `GlyphPreview` and
`TerminalMemoryProbe` at paths T18 moved, its request loop discarded every frame
that was not the awaited reply -- the exact defect the plan's notification
obligation exists to catch -- and its decoder returned nil for an unknown record
kind, which would not survive T8 adding one. The plan cites it as evidence, which
is correct and stays correct; nobody should copy from it.

### F7 -- the composition runs on a phone: a real pane, a replica engine, real pixels

Discharges T23, the residual D3 closed over. Reproduction:
[t23-run.sh](t23-run.sh), against the client mode of
[ios-render-spike.sh](ios-render-spike.sh). It originally drove a throwaway
relay, `t23-relay.py`, which T5 replaced with the tailnet bridge and F5 deleted;
the smoke reproduces against [t5-bridge/](t5-bridge/) and sends no token.
Console transcript:
[t23-artifacts/console-client-smoke.log](t23-artifacts/console-client-smoke.log).

- Status: settled for the path it exercised. It is a smoke test: it says the
  seams join, and it measures nothing.
- Date and investigator: 2026-08-13, agent (T23).
- Commit and worktree state: `b17d30c9`, plus the spike itself.
- Environment: Xcode 26.6 (17F113), Swift 6.3.3, macOS 26.5.2, iOS device triple
  `arm64-apple-ios26.5`. iPhone 13 mini "Pelucho" on iOS 26, installed by
  `devicectl` over the LAN. Mac side: an isolated dev slot from `just
  launch-slot`, one pane at 179x66.
- Commands, inputs, or reproduction: start the relay, then
  `bash docs/research/35-ios-remote-client/t23-run.sh <slot-socket> <pane-id>
  <host> <port> <token>`. The run subscribes from the phone, waits until the
  phone reports its sync applied, then drives the real pane: two commands, a
  `vim` session with typing in it, `:q!`, and one command after the exit.
- **Authentication story, as this doc's investigation rules require of any task
  that opens a listener.** The listener is `t23-relay.py`, a throwaway TCP relay
  that splices one connection into the app's Unix socket, and it is *not* bound
  to the tailnet interface, because there is no tailnet on this Mac: Tailscale is
  not installed, and no interface carries a 100.64/10 address. The doc's
  unauthenticated escape hatch is therefore unavailable, and this took the
  authenticated branch instead. The relay binds one explicit LAN address and
  refuses `0.0.0.0` outright, and a connection must send `token <secret>` as its
  first line before one byte reaches the control socket; a wrong or missing token
  is closed with no reply and nothing proxied. The user chose this over
  installing Tailscale first. The token is a shared secret on a command line and
  decides nothing for T5 or T6, which own the bridge and the real auth model.
- Result: **the composition works.** An iOS binary links `DanTermClient`, speaks
  the hello handshake and the framed request loop over a TCP conformance of
  `DanTermClientTransport`, subscribes to a live pane with `start: now` and
  `mode: reconstructible`, applies the D5 sync with the shipped
  `PaneTapeSyncAssembler`, feeds every following event to a replica
  `TerminalCore` on the phone, and presents it through `TerminalFrameSwapchain`.
  One representative run: stream version 3, opening start with `syncPending=true`
  as D5 specifies, one sync of 18,758 bytes at 179x66, 95 live events applied, 13
  frames published, 0 coalesced.
- Result: **the replica converged with the source pane, checked on the phone.**
  The phone's viewport digest and the Mac's own `pane read` digest agree
  (`60ba87e3657bc82b`, 66 rows) over the same normalization on both sides. This
  is F4's convergence check moved onto the device, and it is the smoke's pass
  condition rather than a look at the screen.
- Result: **pixels, not just a plan.** The surface the layer is showing carries
  288,830 non-background pixels, counted on the device from the buffer the
  swapchain published. F3 established that an IOSurface presents on this
  hardware; this is the first time the pixels in one came from another machine's
  terminal.
- Result: **modes track the stream live, which is the state F4 found a late
  joiner gets wrong.** Entering `vim` moved the replica to
  `applicationCursorKeys=true mouseTracking=drag alternateScreen=true`, and
  `:q!` moved it back. Scrollback also accumulated on the phone past the
  viewport (66 rows visible, `totalRows` reaching 196), so history is replicated
  rather than only the screen.
- Result: the seam named no socket kind and did not have to be reopened for
  this. The TCP transport is a conformance written entirely inside the spike;
  nothing in `lib/DanTermClient` changed, and nothing in `lib/` changed at all.
  The only tree change outside the spike directory is the spike package's
  dependency on `lib/DanTermClient`.
- Observation: **iOS local network privacy fails as "No route to host".** The
  first device run could not connect, and the error read like a routing or
  firewall problem on a LAN where the phone was demonstrably reachable. The cause
  was the missing `NSLocalNetworkUsageDescription` key: without it iOS refuses
  the connection before it leaves the phone. Whatever the T5 bridge ends up
  being, an iOS client reaching a Mac on the same LAN needs that key, and this
  failure mode will be misdiagnosed once per person who meets it.
- Observation: a first run applied its sync and then reported
  `appliedEvents=0`, which looked like the live-follow half was broken. It was
  not: the phone joined after the driving finished, so everything the pane had
  emitted arrived *inside* the opening sync instead of as events. A `start: now`
  join makes "nothing streamed" and "everything already streamed" look identical
  from the client's counters. The run script now waits for the phone to report
  its sync before driving anything.
- Observation: a bug in the first spike client is worth recording because the
  shipped session is what caught it. Treating any reply as the tape request's
  reply killed the stream the moment a second request was sent on the same
  conversation -- `DanTermClientSession` had already delivered the frame
  correctly, and the correlation rule its doc comment states is the thing the
  spike ignored. Replies must be matched by id, on the client as on the server.
- Uncertainty: **the swapchain's pending-presentation retry never fired.** Across
  every run, `coalescedPublishes=0` and `retriedPresentations=0`: at this event
  rate a publish always acquired a buffer. The retry path D2 priced is
  implemented in the spike and is unexercised evidence, so nothing here supports
  or contradicts that part of the contract. A flood workload would exercise it;
  T21 owns the flood.
- Uncertainty: nothing about mobility, reconnect, resume from a cursor, or
  backgrounding was tested. The connection was a LAN TCP socket held open for the
  length of one run. T9 owns all of it, and the relay is deliberately unable to
  help -- it holds no session state.
- Uncertainty: no timings and no energy numbers, on purpose. F3 showed that
  per-frame costs under display-link pacing vary with what else the frame did,
  so a number from this run would be diagnostic at best and misleading at worst.
- Uncertainty: geometry was not negotiated. The pane is 179x66 because the Mac
  window is, the stream's geometry is authoritative as F4 established, and the
  phone scales the whole frame by 0.293 to fit its screen. That is legible as a
  smoke and is not a design: T10 owns what a phone-sized client does instead.
- Inference: D3's residual is closed in the confirming direction. Every seam it
  named -- the client module in an iOS binary, a real pane's stream driving a
  replica engine on a phone, the D2 swapchain presenting it -- holds when joined,
  and the join needed no change to any shipped module. What remains between here
  and a usable client is transport and lifecycle work that already has owners
  (T5, T6, T9, T24), not a question about whether the spine works.
- Next action: T5 can assume the client end is real, and should take the local
  network key and the correlate-by-id rule from this finding rather than
  rediscovering them. The spike and the relay are throwaway per this doc's
  rules; delete them once T5 has a bridge. **F5 deleted the relay.** The local
  network key turned out not to bite over the tailnet -- a 100.x address is not
  a local network address, so iOS did not gate it -- but the correlate-by-id
  rule did carry, and the T5 probe was written against it from the start.

### F8 -- the surface is remote code execution, and its only bound is a thread pool

Discharges T7 and feeds D4. Reproduction for the connection result:
[t7-connection-probe.py](t7-connection-probe.py). Every other result here is one
`just launch-slot` instance and the `danterm` CLI, and each is quoted with the
command that produced it.

- Status: settled as a review of the surface as it stands. It changes nothing.
  Every repair it names is listed with an owner at the end, because this doc's
  scope rule says a review that finds work hands that work to a task rather than
  doing it.
- Date and investigator: 2026-08-13, agent (T7).
- Commit and worktree state: `4621e55e`, with no source change in the tree for
  any file this finding reads.
- Environment: macOS 26.5.2, Swift 6.3.3. One dev slot from `just launch-slot`,
  released afterwards. No listener was opened by this task, so the doc's
  listener rule does not apply to it.
- Result: **the control surface is remote code execution, and `pane.input` is
  not the sharpest edge.** `tab.new` carries a `LaunchSpec` whose `cmd` field the
  app runs, so one request executes an arbitrary command with no pane, no
  keystrokes, and no user present. Verified against a slot: `danterm tab new
  --group <id> --cmd 'id > /tmp/danterm-t7-probe.txt; echo probe-ran'` wrote
  `uid=503(dan) gid=20(staff) groups=...,80(admin),...`. The reply is the
  ordinary tab document; nothing marks the request as privileged. `pane.split`
  takes the same spec.
- Result: **there is no least-privilege subset of this surface, so an allowlist
  is not a containment mechanism.** Removing `cmd` from the remote catalog would
  change nothing, because `pane.input` writes bytes into a live shell and a shell
  runs what it is given. Any catalog that lets the phone type into a pane -- which
  is D1's whole milestone -- is equivalent in authority to a shell. This is the
  fact every authentication argument has to be priced against: the question is
  never "how much can a remote caller do", it is only "who is admitted, and what
  is written down about it".
- Result: **today's authenticator is the filesystem, and it is exactly what
  crossing machines loses.** `ControlSocketListener.open` chmods the containing
  directory to 0700 and the bound socket to 0600, so reaching the socket proves
  the caller runs as this uid on this machine. There is no handshake credential,
  no peer-credential check, and no per-connection identity: `IpcServer.accept`
  writes hello and starts dispatching. The security model is not weak, it is
  *implicit*, and a network transport removes the thing it rests on rather than
  weakening it. That is the gap D4 has to fill, and it is the reason the doc's
  unauthenticated escape hatch is written in terms of an interface rather than a
  posture.
- Result: **idle connections deny service, and 64 of them are enough.** Every
  accepted connection parks one libdispatch worker inside a blocking `read` for
  its whole life (`IpcConnection.startReading` dispatches to the global utility
  queue and loops on `Darwin.read`). A peer that connects and sends nothing
  therefore consumes a thread per connection. Measured against a slot: with 63
  idle connections held, a fresh caller's `ls` answered in 6.9ms; with 64 held,
  the fresh caller waited 20s and gave up. The step is exactly where a 64-thread
  libdispatch pool for that QoS would put it, which is the mechanism this result
  suggests, though nothing here measured the pool itself.
- Result: **the flood attacks reconnect, not the live session, which is the worst
  shape it could have for this product.** With 100 idle connections held, an
  already-established conversation still answered `ls` in 1.9ms while a new
  connection failed, and new connections recovered as soon as the idle ones
  closed. So a flood does not interrupt a phone that is already attached -- it
  denies the phone the ability to come back, which is the operation a mobile
  client performs constantly and the one T9 owns. It costs the attacker no valid
  request, no credential, and no bytes after the handshake, and the app writes no
  record of it. Under the T5 bridge this crosses unchanged, because the bridge
  opens one Unix connection per accepted TCP connection and bounds neither.
- Result: **the `NSHomeDirectory` taint is real, and briefing.md sec. 7 frames it
  in a way that would produce the wrong repair.** `IpcEntityEncoder` abbreviates
  cwd for `ls` and does not for `pane.info`, which is a plain inconsistency:
  `ls` answered `"cwd":"~"` and `pane info` answered `"cwd":"/Users/dan"` for the
  same pane in the same session. But the abbreviation is defeated inside its own
  reply -- that same `ls` object carries `"title":"/Users/dan"`, because the
  shell sets the title and DanTerm passes it through. Chasing `~` substitution
  therefore protects nothing: the title carries the path, `pane.read` carries the
  screen, and the tape carries every byte the pane has emitted. The correct
  posture is that every reply on this surface is host-identifying and often
  secret-bearing, and that the protection is the confidentiality of the channel
  and the list of who may open it, not scrubbing fields. The `pane.info`
  inconsistency is worth fixing for tidiness and is not a security control.
- Result: **nothing is recorded.** A grep over `app/` and `lib/` for audit,
  rate-limit, or request logging finds no hit outside unrelated prose. No request
  is logged, no connection is logged, no failed decode is logged, and no counter
  exists. So today there is no way to answer "what did that device do", which is
  the only question that matters after a surface with this authority is exposed.
- Result: **`quit` is an availability asymmetry, not just an authority one.** It
  is already allowlisted -- `IpcDispatch` refuses it unless
  `env.instanceIdentity().isLauncherPoolSlot` -- and that guard exists for a
  different reason. The remote case adds one the guard does not cover: a phone
  that ends the Mac app cannot start it again, so a single request destroys the
  client's own access until the user walks back to the Mac. Every other method is
  recoverable from the phone; this one is not.
- What an audit log must capture, which T7 owes D4:
  1. **Connection lifetime with a resolved identity**: open and close, the peer
     address, and the tailnet identity it resolves to (see the next result), not
     just the address. An address without the resolution is a number nobody can
     act on a week later.
  2. **Every request, with caller, method, target id, and outcome** -- including
     local ones. A log that records only remote callers misreports history the
     moment the CLI and the phone both drive the same pane, which is the normal
     case here and is already this doc's open multi-client question.
  3. **The full `cmd` and `cwd` of `tab.new` and `pane.split`**, because that
     text *is* the authority exercised, and it is already visible in the pane
     title to anyone who could read the log.
  4. **`pane.input` as method, pane, and byte count -- never content.** This is
     the one deliberate blind spot. The user types passwords into panes from the
     phone, so a log that captured input content would be a keylogger stored at
     rest, and it would be a worse breach than the one it documents. The byte
     count is enough to reconstruct that input happened and how much.
  5. **Never the content of `pane.read`, `pane.rows`, `pane.tape`, or
     `pane.snapshot`** -- the fact and the pane only, for the same reason at
     larger scale.
  The log belongs to the app, not to a proxy: it needs the model to name a pane
  and needs dispatch to know an outcome, and a byte proxy has neither. It is
  written under the instance's own directory at 0600 with a bounded size, beside
  the recovery store.
- Result, found while reviewing T6's arms and recorded here because it is
  evidence rather than a decision: **a tailnet peer address resolves to a named
  identity locally, without root.** `tailscale whois 100.98.63.67` returns the
  machine name `iphone-13-mini.tail11347d.ts.net`, the stable node id
  `nYLVaWdKL811CNTRL`, the node key, and the owning user
  (`cgv4zsvr89@privaterelay.appleid.com`); `--json` returns the same
  structurally. This is what makes "the tailnet is the authenticator" a real
  identity claim rather than a statement that the network is trusted: the source
  address on the tailnet interface is bound to a WireGuard peer key, and the
  address can be turned back into a device and a person at accept time. D4 rests
  on it.
- Uncertainty: **the flood's effect on the GUI was not observed, only reasoned
  about.** The reader loops run on a global utility queue and the main actor is
  not in the path, so the terminal itself should keep running while IPC is deaf --
  but the instrument for checking is IPC, which is the thing that is down. A run
  that watched the window directly would settle it.
- Uncertainty: the connection bound was measured against a Unix socket on one
  machine. The same code path serves a bridged TCP connection, so the bound
  should carry, but no run has produced it from the network side.
- Uncertainty: nothing here reviewed the recovery store, the config file, or the
  checkpoint on disk, which is where the same session state lands at rest. The
  review was scoped to what crosses the wire.
- Uncertainty: this is one reviewer reading one surface. It is not a substitute
  for an adversarial review of the wire format itself, which nobody has done and
  no task currently owns.
- Inference: the three repairs this finding implies are not T7's to make, and
  each has an owner. The connection bound and the audit log are D4's, because
  both are properties of admitting a remote caller at all. The `pane.info` cwd
  inconsistency is a tidy-up that belongs with whoever next touches
  `IpcEntityEncoder` and is recorded here so it is not lost. The GUI-liveness
  uncertainty joins T9, which already has to distinguish a dead app from a slow
  one.
- Next action: D4 takes the identity model, the connection bound, and the audit
  log. T9 takes the reconnect consequence of the flood, and should assume a
  reconnect can be denied by something other than the network.

### F9 -- reconnect is exact and cheap when the socket closes, and invisible when it does not

Discharges T9. Reproduction: [t9-checkpoint/](t9-checkpoint/), which replays the
shipped client's own persisted replica checkpoint into a headless `TerminalCore`
so a reconnect's exactness is asserted on state the screen does not restore by
itself.

- Status: settled for the three lifecycle cases T9 names, on one device over one
  tailnet, one run per scenario. Timings are diagnostic, not benchmark: the
  audit log's resolution is one second and the phone-side clock is the user
  reading a header. Focus-report semantics, which D8 deferred to T9, are **not**
  examined here and stay open.
- Date and investigator: 2026-08-17, agent (T9), with the user holding the
  device and reporting what the screen said.
- Commit and worktree state: `5156cbad`, plus the reproduction package this
  finding adds. Nothing in `lib/`, `app/`, or `ios/` changed: the subject is the
  shipped T25 client against the shipped D4 listener and the shipped D5 sync.
- Environment: DanTerm 0.1.10 in one `just launch-slot` instance, tailnet
  listener on `100.106.152.106:7420` admitting the phone's stable node id
  `nYLVaWdKL811CNTRL`, one pane at 179x66. iPhone 13 mini "Pelucho" on iOS 26 at
  `100.98.63.67`, running the `scripts/ios-app.sh device` build of
  `ios/DanTermMobileApp`. The shared config carried the `tailnet` block for the
  run and was restored afterwards.
- **The instrument trap F5 recorded is avoided by not instrumenting the phone
  over the network at all.** `scripts/ios-app.sh` already launches detached, so
  nothing SIGTERMs the app when wifi drops. Three records replace the console:
  the Mac's `ipc-audit.jsonl` for the connection and request timeline, a socket
  census (`lsof`/`netstat`) for what the Mac still believes it holds, and -- the
  load-bearing one -- the client's own
  `Library/Application Support/DanTermMobile/pane-replica-checkpoint.plist`,
  pulled with `devicectl device copy from` and replayed by `t9-checkpoint/`.
  That yields the resume cursor, scrollback depth, input modes, and a viewport
  digest computed the same way as the source pane's own `pane read`. The chain
  was validated before any scenario ran: the phone's baseline digest and the
  pane's were both `444a926491065d7a`.
  The USB transport that would have kept `devicectl` alive through airplane mode
  was not achieved -- the device stayed on `transportType: localNetwork` -- so
  the phone's user-facing states are the user's reading, as in F3.
- Result: **backgrounding and app death are clean teardowns, and both resume
  exactly.** The measurements are scrollback depth and the digest, per D5's
  acceptance rule, not the visible screen.

  | | at baseline | background/foreground | kill/cold relaunch |
  |---|---|---|---|
  | lines emitted while away | -- | 300 | 300 |
  | `nextSequence` before / after | 13 | 29 / 47 | 47 / 66 |
  | `totalRows` before / after | 66 | 66 / 307 | 307 / 609 |
  | digest after | `444a9264...` | `bed678be9f790071` | `4d0e7317cd73b611` |
  | matches `pane read` | yes | yes | yes |

  The Mac logged one `connectionClosed` on each teardown (14:27:50 backgrounding,
  14:31:12 kill) and released the remote slot both times. Each reconnect's
  `connectionOpened`, `ls`, and `pane.tape` landed inside the same audit second.
  Scrollback depth is what makes this an assertion rather than a look at the
  screen: a `--from-now` rejoin would have left `totalRows` at 66 with a
  correct-looking prompt, which is exactly the false pass F4 warned about.
- Result: **a cold start transiently needs two of the eight remote slots.** It
  opened `100.98.63.67:64306` and `:64307` in the same second and closed the
  first immediately; a foreground return from background opened one. Nothing
  failed, and it is recorded because the D4 cap is 8 and this halves the
  headroom arithmetic for a client that reconnects often.
- Result: **an abrupt loss of the socket is invisible to both ends until the
  network returns.** With the app in the foreground, airplane mode on:
  - The Mac never learned. No `connectionClosed`, no audit event of any kind,
    and `netstat` still reported the connection `ESTABLISHED`.
  - The phone never learned either. The header read "Connected" for the whole
    outage, over a minute, with no error, no spinner, and no state change.
  - Pushing 3,000 lines at the dead peer accumulated 103,318 unacknowledged
    bytes in the Mac's send queue and cost the app nothing else: a local `ls`
    answered in 13ms and a fresh remote connection got its hello normally.
  - The abandoned connection **held a remote slot**. With it held, exactly 7
    further remote connections were admitted before a typed `connection-limit`
    rejection, which places the phone's ghost on the eighth.
  - On airplane mode off, the phone's own stack reset the socket: the Mac logged
    `connectionClosed` at 14:37:27 and released the slot, and the phone showed
    "Connection lost" a few seconds later. The screen held the last partial
    record it had received -- the echoed command line, without its output.
  - **There is no automatic retry.** It stayed in "Connection lost" until the
    user tapped Go.
- Result: **a reconnect refused for capacity is legible; a reconnect refused by
  deafness is not, and reads as a hang.** Both were driven deliberately.
  - Holding all 8 remote slots from the Mac and tapping Go produced "Refused by
    the Mac: connection limit", immediately. That is D4's cap doing the job F8
    asked of it, and I7's per-reason state earning its keep.
  - Holding 70 idle connections on the *local* control socket reproduced F8's
    thread-pool starvation (a local `ls` got no answer at all). The phone's
    connection then reached `ESTABLISHED`, received the hello, and its 88-byte
    `ls` sat **unread in the Mac's receive queue**. The header stayed
    "Connecting to ..." with no timeout and no other state.
    `MobileSessionAttempt` builds its `TCPSocketTransport` with
    `receiveTimeout: nil`, so the wait is unbounded by construction. Releasing
    the idle connections let the phone's `ls` and `pane.tape` complete at
    14:45:19 and the app reached Connected, about two minutes after the tap.
  - The audit log recorded `connectionOpened` for that starved connection and
    nothing further. A reader cannot distinguish "admitted and served" from
    "admitted and never read", which is the one question this failure raises.
- Result: after every disturbance in the session the replica reconverged with
  the source pane: `nextSequence=139`, `totalRows=3611`, digest
  `7fe9395860a98638` on both sides.
- Inference: **F5's narrowing is complete, and the remaining cases split in
  two.** Where the process closes its socket -- backgrounding, kill, cold
  relaunch -- D5 resume works, costs one connection and three requests inside a
  second, and is exact down to scrollback depth. Where the socket is abandoned
  rather than closed, neither end has any way to notice, and the whole cost of
  the case is that ignorance rather than anything in the resume machinery.
- Inference: **the client's failure vocabulary is total for errors and blind to
  silence.** I7 requires that no state read as a hang, and the two states the
  client cannot produce are exactly the silent ones: "the link is gone" (it says
  Connected) and "the Mac is deaf" (it says Connecting, forever). Both are
  reported as the wrong thing rather than as nothing, which is worse than a
  missing state.
- Inference: **one absent mechanism explains both directions.** There is no
  `SO_KEEPALIVE` anywhere in the tree, no application heartbeat, no idle timeout
  on the server, and no receive timeout on the client's handshake path. The
  server cannot reclaim a slot it cannot prove is dead, and the client cannot
  bound a wait it cannot prove is progressing. Naming that as one gap rather
  than two is what keeps the repair from becoming two unrelated timeouts.
- Inference: **the slot leak is bounded by the phone coming back, not by the
  server.** Reclamation happened because the phone's stack reset the socket on
  its return, not because the Mac timed anything out. For a phone that returns
  to the tailnet the leak self-heals; for one that does not -- flat battery, out
  of range overnight -- nothing in the Mac reclaims the slot, and with a cap of 8
  and a cold start needing 2, the headroom is thin.
- Inference: **F8's denial-of-reconnect crossed to the phone with a twist.** D4's
  connection cap converted the capacity case into a clean typed refusal, which
  is what F8 asked for. The thread-pool deafness F8 originally measured is
  untouched by that cap, and it is precisely the case the client cannot name.
  So the repair F8 handed to D4 fixed the half that was already legible.
- Competing interpretations: the two-connection cold start was read as scene
  activation racing `viewDidLoad`, but nothing here probes the client's launch
  path; only the wire behavior is established. The reclamation at 14:37:27 was
  attributed to the phone's reset rather than the Mac's retransmission timeout
  on the evidence of timing -- it landed within seconds of airplane mode ending,
  where a retransmission timeout on 103KB would have taken minutes -- but no
  packet capture separated them.
- Uncertainty: **the idle-zombie case is untested.** The abandoned connection
  carried 103KB of queued output, so the phone had something to reset against.
  Whether a zombie on a quiet pane, with nothing queued in either direction, is
  reclaimed the same way is not established, and it is the case that decides
  whether the leak is real in ordinary use.
- Uncertainty: one device, one tailnet, one physical location, one run per
  scenario. Airplane mode from Control Center is not a phone that walks out of
  range, which F5 already flagged for the mobility case.
- Uncertainty: whether the final recovery was a cursor resume or a fresh sync
  was not distinguished, because the audit's `pane.tape` descriptor records the
  pane and not the requested start position. The background and cold-relaunch
  scenarios are the clean cursor-resume evidence; the last one is only
  convergence. That audit gap is worth its own line: the log cannot tell a
  resume from a fresh join.
- Uncertainty: Mac sleep is still untouched and still belongs to nobody, and
  the session-length battery question is unmeasured, both as the doc's open
  questions already say.
- Next action: the repairs this finding implies are not T9's to make. A liveness
  check on an established stream and a bounded wait on the handshake are one
  decision, not two, and they belong with whoever next owns the client's
  connection lifecycle; automatic reconnect policy sits with them. The server
  half -- reclaiming a slot whose peer cannot be shown alive, and recording that
  an admitted connection was never serviced -- amends D4 rather than replacing
  it. F5's UI question about the multi-second freeze is the same question this
  finding answers for the disconnect case, and still has no owner.
