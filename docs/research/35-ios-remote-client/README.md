# iOS remote client

Research started: 2026-08-12.

- [findings.md](findings.md) -- the append-only evidence chain.
- [decisions.md](decisions.md) -- the auditable decision log.
- [ios-cross-compile.sh](ios-cross-compile.sh) -- the F1 reproduction: builds
  each candidate portable module for both iOS triples and prints pass/fail.
- [f2-render-execution.md](f2-render-execution.md) -- F2 in full, with
  [ios-render-spike.sh](ios-render-spike.sh) and the `f2-artifacts/`
  screenshots.
- [f4-mac-to-mac.md](f4-mac-to-mac.md) -- F4 in full, with the `t4-spike/`
  client and its ten scenarios.
- [briefing.md](briefing.md) -- the initiating brainstorm dump: repo census, IPC
  surface, portability inference, candidate directions. Census-grade evidence;
  every claim that carries weight is re-verified by a Phase 1 task before a
  decision cites it.

## Purpose

This doc owns the viable path to an iOS thin client that drives a DanTerm
instance on the user's MacBook over the internet: whether the engine and render
stack build and present on iOS, what transport and authentication cross the
machines, how subscriptions survive mobile disconnects, what remote geometry
means for a pane the Mac window still owns, and which refactors in the existing
codebase the client justifies. The first daily-use milestone is a full
interactive, engine-rendered terminal on the phone (D1). The doc converges
toward one or more plan files; it does not implement.

## Investigation rules

- A portability claim is settled by a build for an iOS triple, not by an import
  census. briefing.md's module table is inference until a ledger task compiles
  the module and records the result.
- Wire and session behavior is established by real processes over real
  connections: a real second process on the control socket, a real TLS listener,
  a real phone on the tailnet. An in-process simulation selects the probe; it is
  not the finding.
- Presentation timings recorded here are diagnostic unless produced under
  [agent-docs/terminal-performance.md](../../../agent-docs/terminal-performance.md)
  conditions; label them so.
- Spikes are throwaway evidence generators. Production integration starts only
  after the decision gate that the spike feeds has selected a direction.
- Every decision names the ideal solution and keeps it on the table, per the
  design bar in [AGENTS.md](../../../AGENTS.md). Internal backwards
  compatibility (formats, flags, protocol shape between DanTerm components) is
  not a constraint; external compatibility (control sequences, shell output) is.
- Any task that opens a network listener records its authentication story in
  the same finding. There is no unauthenticated phase, even in a spike, unless
  the listener is bound to the tailnet interface and the finding says so.

## Trigger and current evidence

No defect triggered this doc; the trigger is a product decision: supervise and
drive DanTerm -- especially panes running coding agents -- from an iPhone away
from the Mac. [briefing.md](briefing.md) is the initiating context dump. The
spine that is already verifiable against the tree:

- The IPC surface (`lib/DanTermProtocol/Sources/DanTermProtocol/Methods.swift`)
  plus the `pane.tape --follow` stream of `NeutralTerminalRecordingEvent`
  (`lib/TerminalCore/Sources/TerminalCoreRecording/NeutralTerminalRecording.swift`)
  already form a candidate remote wire format, and `IpcLineFramer` is pure and
  transport-agnostic.
- Tape subscriptions die with their `IpcConnection`: no sequence numbers, no
  resume, no server-side buffering. Mobile clients disconnect constantly, so
  this is a known protocol gap, not a maybe. F4 measured what the gap costs: a
  client dropped at sequence 10089 and reconnected with `--from-now` skipped 216
  events and was told about none of them.
- There is no way to ask a pane what state it is in, only to watch its bytes.
  `pane.info` carries no geometry, modes, or screen state; `pane.rows` carries
  no attributes; `pane.read` carries text. F4 established that this is the same
  gap as the missing `pane.snapshot`, seen from the control surface.
- Every `lib/*/Package.swift` pins `platforms: [.macOS(.v26)]` and nothing
  else. F1 has since replaced the import census with builds: with a pin added,
  `TerminalCore`, `TerminalCoreRecording`, `TerminalRenderPlanning`,
  `TerminalSpriteGeometry`, `DanTermProtocol`, and `DanTermCore` compile for
  both iOS triples untouched, `DanTermSupport` needs two host-only files
  removed, and `TerminalRenderExecution` stops at `import AppKit`. The pins
  themselves stay out of the tree until T16, D2, and T14 make them true.
- 34/D2 pinned the exact agent activity transitions (working, waiting, idle,
  detach) that a push-notification sender would consume; that plumbing exists
  and needs no new inference.

User constraints, recorded as D1: milestone 1 is a full interactive terminal;
no todo surface on iOS; splits flatten to a pane list (the phone never splits);
everything else starts as simple as possible; a paid Apple Developer account
exists, so APNs and TestFlight are available; Tailscale runs on the Mac today
and the phone can join the tailnet.

## Current hypotheses

### H1 -- the engine stack compiles for iOS with platform pins and one font seam

`TerminalCore`, `TerminalRenderPlanning`, `TerminalSpriteGeometry`,
`DanTermProtocol`, `DanTermCore`, and `DanTermSupport` build for an iOS triple
after adding `.iOS` platform pins; `TerminalRenderExecution` additionally needs
an `NSFont`/`UIFont` seam and a decision about the IOSurface-backed swapchain.

Confirmed by F1 and F2, at compile time plus one simulator run -- nothing has
run on a device. The first five modules build for both iOS triples with nothing
but a platform pin, and no code is conditionally compiled out. `DanTermSupport`
builds on both triples once two host-only files leave the module
(`CLIPathInstaller`, `DoctorProber`), which is a file split, not a port. The
`TerminalRenderExecution` half cost less than the hypothesis guessed: the font
seam is one call site, and the IOSurface swapchain needed no decision at all
because it ports unchanged. H1 is closed; what remains is whether the
presentation mechanism behaves the same on hardware as in the simulator, which
is T3's first job.

### H2 -- the existing swapchain is the iOS presentation path, not a substitute

Restated after F2. The original H2 asked whether CPU-composed frames present
acceptably *without* IOSurface, and named `CVPixelBuffer`/`CAMetalLayer` as the
closer analogue to the N-buffer swapchain. That framing is dead: F2 shows
`TerminalFrameSwapchain` and `TerminalFrameBackingStore` compile and run on iOS
unchanged, and that CoreAnimation there honors the same attach-to-publish
protocol the swapchain already speaks -- an in-place pixel rewrite does not
reach the screen, and reassigning the same surface does.

So the live question is narrower: does the real `TerminalFrameSwapchain` beat
CGImage-copy-per-frame on a phone, at phone-scale grids, under a full-repaint
scroll workload, in frame timing and energy? T3 measures those two; D2 selects
between them. The substitute paths are candidates only if the device disconfirms
the simulator result below.

Competing explanation, and the one thing that could reopen the wider question:
simulator CoreAnimation runs against the Mac's render server, so F2's
presentation result may be a simulator affordance. On a device the surface path
could fail outright, which would put `CAMetalLayer`/`CVPixelBuffer` back on the
table.

### H3 -- a remote TerminalCore converges from snapshot plus tape

Confirmed by F4, Mac-to-Mac, with zero iOS variables. A client replaying a
pane's whole retained tape produced a viewport byte-identical to that pane's own
`pane read`, and planned a `RenderFramePlan` from its own engine in a process
with no AppKit. The uplink needs nothing new either.

Both parts that H3 called unproven are now answered, and neither is a maybe.
Joining mid-stream loses modes, not just history: a late joiner differs on
alternate-screen state, cursor visibility and position, `applicationCursorKeys`,
`bracketedPaste`, and `mouseTracking`, so it sends the wrong key encodings and
pastes unbracketed purely because it joined late. The stream is not
self-synchronizing, and worse, a joiner heals whatever a prompt repaint covers,
so it can look correct and be empty. Geometry is unconditional and
authoritative: there is no third option where a differently-sized client quietly
renders at its own size. F4 states the resulting `pane.snapshot` floor for T8,
and the observe-vs-claim consequence for T10.

### H4 -- a bridge process over the tailnet survives real phone mobility

A TCP+TLS listener proxying frames into the existing Unix socket, reached over
Tailscale, plus client-side reconnect and a resume protocol, yields a usable
session across wifi-to-cell transitions and app backgrounding. Competing
explanations: connection churn is frequent enough that even resume feels broken
without server-side buffering (feeds T8's design), or Tailscale's own iOS
background behavior dominates. T5 and T9 test with a real phone.

## Candidate direction, pending evidence

Provisional shape; every leg has a gate in the ledger.

- **Client: a real terminal from day one.** The iOS app links `TerminalCore` +
  `TerminalRenderPlanning` + `TerminalSpriteGeometry` and drives a local engine
  instance from the tape stream. A small UIKit shell re-establishes the
  invariant "the pane owns its pixels; there is no second render path" against
  `CADisplayLink` -- a rewrite of ~200 lines of presentation contract, not a
  port of `SwiftTerminalSessionView`. No interim text-only renderer (see
  Rejected).
- **Wire: the existing JSON-RPC surface, extended, not replaced.** The client
  is a protocol peer of the CLI: `ls`, `pane.input`, `pane.tape` events, plus
  new `pane.snapshot` and sequence-numbered resume. Todo methods are simply
  never called.
- **Server: a separate bridge process** (`danterm serve` or `danterm-bridge`)
  owns network listening, authentication, and later the APNs sender; the app's
  Unix-socket security model stays untouched.
- **Reachability: Tailscale**, already half-deployed.
- **UI: tabs/groups as a list, panes as a flat list within a tab, one pane
  on screen.**

## Task ledger

### Phase 1 -- rendering and engine viability (gates everything)

- **T1 DONE** (F1) -- Cross-compiled the candidate portable set for iOS:
  `TerminalCore`, `TerminalRenderPlanning`, `TerminalSpriteGeometry`,
  `DanTermProtocol`, `DanTermCore`, and `DanTermSupport`, for a simulator and a
  device triple, with iOS platform pins applied. Five of the six pass untouched
  on both triples; `DanTermSupport` fails on two host-only files and passes
  without them. The pins stay out of the tree, and
  [ios-cross-compile.sh](ios-cross-compile.sh) applies and restores them per
  run, so the result is re-derived rather than asserted by a manifest. T16
  carries the split the failure implies.
- **T2 DONE** (F2) -- `TerminalRenderExecution` on iOS. The `import AppKit`
  hid one symbol: `NSFont.monospacedSystemFont` on line 90, which `UIFont`
  answers identically, so the seam is one `typealias` behind
  `#if canImport(AppKit)`. `NSAttributedString` was a false alarm (Foundation).
  `TerminalFrameBackingStore` and `TerminalFrameSwapchain` port unchanged --
  IOSurface is public on iOS -- and a simulator spike showed CoreAnimation there
  honors the swapchain's attach-to-publish protocol. H2 is restated as a result.
  The font seam stays uncommitted and lands with the pins in T16.
- **T3 RESEARCH** -- Presentation-path measurement on a real device. First,
  confirm on hardware what F2 saw only in the simulator: that an IOSurface
  displays as `layer.contents` and that in-place mutation does not reach the
  screen. Do that before measuring anything, because the H2 restatement rests on
  it. F2's discriminator ports directly and takes minutes: render a frame and
  screenshot; rewrite the store's pixels in place without reattaching and
  screenshot again; reassign the same surface and screenshot a third time. If
  the device behaves like the simulator, the first two screenshots are
  byte-identical and the third differs. Then measure the real
  `TerminalFrameSwapchain` against
  CGImage-copy-per-frame, both on iOS, under a worst-case full-repaint scroll
  workload at a phone-typical grid. Diagnostic frame timings and energy notes
  into F3. Needs a physical device, so it also needs the signing and
  provisioning path the simulator spike deliberately avoided.
- **T4 DONE** (F4) -- Mac-to-Mac thin-client spike. Convergence confirmed
  byte-for-byte against `pane read`. The join gap is modes, not just history,
  and the stream is not self-synchronizing; F4 states the `pane.snapshot` floor
  for T8 and the observe-vs-claim consequence for T10. Two unplanned results
  carry into Phase 3: tape eviction drops the oldest events, which are the ones
  that establish geometry and modes, so an evicted backlog replays into the
  wrong grid size; and resume already has its coordinates in
  `TerminalFlightRecordingCursor`, with only the ability for a client to supply
  one missing at the protocol edge.
- **D2 gate** -- select the iOS presentation path, from F2 and F3. F2 narrowed
  the candidates to the real swapchain versus CGImage-per-frame; T3 supplies the
  numbers and the device confirmation.
- **D3 gate** -- confirm or restate the day-one-engine direction after F1-F4;
  reopening the rejected text renderer requires these spikes to have failed.

### Phase 2 -- transport, authentication, security

- **T5 RESEARCH** -- Bridge prototype: TCP+TLS listener proxying frames into
  the Unix socket, bound to the tailnet interface; put Tailscale on the phone
  and connect with a scratch client. Record round-trip latency and behavior
  across a wifi/cell switch in F5.
- **T6 VETTING** -- Pairing and auth model: compare tailnet-identity-only,
  pinned client certificates, and a pairing token; decide where the method
  allowlist, rate limits, and audit log live. Also weigh the ideal alternative
  to a bridge (the app listening on the network itself) rather than assuming
  the bridge. Records D4.
- **T7 TODO** -- Security review of the exposed surface: what
  internet-reachable `pane.input` implies, the `NSHomeDirectory` taint in `ls`
  and snapshot payloads (briefing.md sec. 7) now that replies cross machines,
  and what an audit log must capture. Feeds D4.

### Phase 3 -- durable subscriptions and resume

- **T8 VETTING** -- Design `pane.snapshot` plus sequence-numbered tape resume:
  a broker owning per-pane bounded ring buffers and subscriber cursors, resume
  as `fromSeq` backfill; decide whether the broker lives in the app runtime or
  the bridge. Unblocked -- F4 supplies the gap shapes, including an explicit
  floor for what the snapshot payload must carry and the fence it needs against
  the subscription it splices onto. Two F4 results shape the design: `fromSeq`
  mostly exposes machinery that already exists, since
  `cursorSnapshot(from:)` already computes exact per-direction loss against an
  arbitrary cursor, and today's `--from-now` reconnect reports no gap at all
  while silently skipping events. Settle at the same time whether the recorder's
  eviction bound is a session-durability parameter, since F4 showed eviction
  takes the geometry-establishing events first. Whatever design lands, its
  acceptance test must assert on state the screen does not restore by itself:
  join a pane running a full-screen program, let the program exit, then check
  scrollback depth and `inputModes`, not the visible screen. F4 showed the
  visible screen recovers on its own through a prompt repaint, so a test that
  reads it would pass against a snapshot that carries nothing. Records D5.

  **Decided as D5.** State transfers as terminal bytes in a `sync` record, not
  as a structured state dump: a reader already knows how to feed bytes to a
  terminal, so an engine change stops being a wire change. The broker is the app
  runtime and there is nothing new to build -- the ring is
  `TerminalFlightRecorder` and the cursors are `PaneTapeFollowSubscriptions` --
  so T8 does not depend on T5. The retention bound stays at 8 MiB / 32,768
  events and reverts to a debugging parameter, because the design invariant is
  that no stream's ability to reach exact state depends on retention. Plan:
  [plans/wip/2026-08-12-1500-pane-snapshot-and-tape-resume.md](../../../plans/wip/2026-08-12-1500-pane-snapshot-and-tape-resume.md).
- **T9 TODO** -- Reconnect behavior on the phone against the T5 bridge and the
  T8 protocol: airplane-mode toggles, backgrounding, cold relaunch. Record what
  each recovery actually required in a finding.

### Phase 4 -- geometry and input semantics

- **T10 VETTING** -- Geometry conflict semantics: *observe* (read-only, local
  reflow of history) vs *claim* (the phone owns the PTY size and restores it on
  detach), selectable per pane; define what the Mac window shows while a pane
  is claimed. F4 removed the third option: stream geometry is unconditional and
  authoritative, so a client cannot quietly render at its own size -- a
  differently-sized client that ignores the stream's resize renders wide output
  into a narrow grid as garbage. Observe therefore means local reflow *after*
  applying the stream's geometry, which F4 verified works; claim means the
  client's size enters the stream as a normal resize event. Records D6.
- **T11 TODO** -- Input surface: map an iOS keyboard plus an accessory key row
  (Esc, Ctrl, Tab, arrows, pipe, tilde, slash) onto `pane.input`/`KeyTokens`;
  itemize what the token grammar cannot express today.

### Phase 5 -- codebase refactors the client justifies

- **T12 VETTING** -- Re-examine the `DanTermCore` real-target migration against
  its recorded objection (the per-field `package` annotation tax;
  [docs/design/2026-05-28-core-module-via-symlink.md](../../design/2026-05-28-core-module-via-symlink.md)),
  and decide what the client actually reuses: the engine only, or the
  `DanTermCore` model too. A thin client whose source of truth is the Mac may
  not need the model at all -- settle that before paying any migration cost.
  Records D7.
- **T13 TODO** -- Split `TerminalSession` into a neutral control protocol and a
  view-owning half; implement `RemoteTerminalSession` as a peer so T4's spike
  can graduate into supported code and Mac-to-Mac attach becomes a product
  capability.
- **T14 TODO** -- Extend `scripts/core-purity-lint.sh` into a platform-layering
  lint once iOS pins exist, so boundary violations fail at the seam. T16 stated
  the invariant to enforce: *a package that declares `.iOS` in `platforms:` has
  every one of its targets build for the iOS device triple.* The package is the
  unit of the platform claim, which is exactly why the pin was dishonest. T16
  rejected the alternative of an allowlist of exempt targets, because that makes
  the pin mean "iOS, except where a list says otherwise", which is the unchecked
  claim F1 declined to land. Open: whether the gate is a full cross-compile or a
  cheaper static check backed by a periodic build.
- **T16 DONE as investigation** -- The task asked to separate the host-only half
  of `DanTermSupport` from the portable half. There is no portable half to
  separate. Of the ten files that compile for iOS, four are the *producer* end
  of the control socket (`ControlSocketListener` binds it, `IpcConnection`
  writes server responses and notifications, `PaneTapeFollow` tracks what the
  server owes a subscriber, `PaneTapeRecords` builds the records a server
  emits), and four more name the Mac's own filesystem and session
  (`RecoveryStore`, `CheckpointWriter`, `InstancePaths`, `DanTermConfigPaths`).
  Only `Debouncer` and `FontAvailability` carry no Mac-specific meaning, and
  both are under 80 lines. A client that linked the "portable half" would import
  it and call nothing. F1 fixed a *compile* boundary, and this task established
  that a compile boundary is not a role boundary. The work T16 was reaching for
  is T17. Plan:
  [plans/wip/2026-08-12-2225-host-layer-and-the-missing-client-module.md](../../../plans/wip/2026-08-12-2225-host-layer-and-the-missing-client-module.md).
- **T17 TODO** -- Create the client end of the control socket, which exists
  nowhere and is written three times: `cli/main.swift` (connect, framed read and
  write, hello), `cli/PaneTapeStream.swift` (a second copy), and the T4 spike (a
  third, about 85 lines). The pane-tape record shape has a producer and no
  reader -- the vocabulary is public in `DanTermProtocol`, but `kind`,
  `sequence`, and `byteOffset` are spelled out inside each reader separately,
  which is the direct reason T2's spike had to drive a local `Terminal` with
  literal bytes. Scope: a transport seam, the framed request/reply/notification
  loop over the existing `IpcLineFramer`, the hello handshake, and a tape record
  decoder. Rewire `cli/` onto it as the first consumer so `just test` gates it
  rather than it shipping untested. The module is `public` by construction, and
  `DanTermSupport` gains zero annotations -- the symlink doc's annotation-tax
  objection is about `DanTermCore`'s field-bearing model structs and does not
  transfer to a handful of behavioral types designed as an API. A candidate
  module already builds for macOS and both iOS triples with `DanTermProtocol`
  as its only dependency, referencing nothing in `DanTermSupport`
  ([t16-probe.sh](t16-probe.sh)). `DanTermSupport` itself stays whole, is named
  the Mac host's side-effect layer, and gets no iOS pin.
- **T18 TODO** -- Land F2's font seam and the iOS platform pins that F1 and T16
  deferred. The seam is a `PlatformFont` typealias behind
  `#if canImport(AppKit)`, one import block and one call site, after which
  `TerminalRenderExecution` builds for macOS and both iOS triples. The pin
  question then has a precise answer: a package-level iOS pin on
  `lib/TerminalCore` is false for exactly two of its roughly 26 targets,
  `GlyphPreview` (no AppKit on iOS) and `TerminalMemoryProbe` (no `Process`).
  Every other target builds for the device triple, including
  `TerminalDrawBenchmarkSupport`. So the honest pin costs moving host-only
  tooling out of the engine package, not a port. `lib/DanTermProtocol` is a
  single portable target and its pin is honest as-is.

### Phase 6 -- push notifications and quick replies (after milestone 1)

- **T15 TODO** -- APNs sender in the bridge keyed off the 34/D2 activity
  transitions; notification tap opens the pane, quick reply sends `pane.input`.
  Paid developer account is confirmed, so no blocker beyond the bridge itself.

## Rejected

### Text-only renderer for milestone 1

Considered because it is the cheapest path to pixels (`pane.read` plus tape
rendered as attributed text). Rejected: milestone 1 is a full interactive
terminal (D1), the render seam already ends in a platform-neutral
`RenderFramePlan`, and an interim text renderer would be thrown away while
misrepresenting wide characters, colors, and mouse-mode programs the whole
time. Reopen only if Phase 1 shows the engine stack cannot reasonably build or
present on iOS (D3 gate).

### Todo surface on iOS

Scoped out by the user (D1). The `todo.*` methods stay server-side; the client
never calls them. Reopen on user request only.

### Split panes rendered as splits on iOS

Scoped out by the user (D1): splits flatten to a pane list; the phone never
issues `pane.split`. Reopen on user request only.

## Open questions and caveats

- **Mac sleep.** What the client experiences when the MacBook lid closes or the
  machine sleeps: does the bridge hold a power assertion, can the phone wake
  it, or does the client just surface "Mac unreachable" honestly? No task owns
  this yet; it likely joins Phase 2.
- **Multi-client conflict.** The Mac GUI, the CLI, agents, and the phone can
  all send `pane.input` and focus changes concurrently. Today's answer is
  "last writer wins"; decide whether that is acceptable or needs surfacing.
- **iOS background execution.** The connection dies on backgrounding by design;
  the open part is how much re-sync a foreground return needs, which is T8/T9
  territory.
- **Distribution.** Personal use with a paid account: TestFlight internal or
  direct device install both work; nothing here needs App Store review. Record
  the choice when it first matters (push entitlements).
- **Battery.** A live tape stream driving a full engine plus rendering is
  unmeasured on the phone; T3 collects first energy notes, but a real answer
  needs a session-length measurement.
- **Fonts.** `monospacedSystemFont` exists on iOS, but parity for the user's
  configured font (Nerd Font glyphs, ligature behavior) on the phone is
  unexamined.

## Outcome

Investigation in progress.
