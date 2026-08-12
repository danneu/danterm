# iOS remote client

Research started: 2026-08-12.

- [findings.md](findings.md) -- the append-only evidence chain.
- [decisions.md](decisions.md) -- the auditable decision log.
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
  this is a known protocol gap, not a maybe.
- Every `lib/*/Package.swift` pins `platforms: [.macOS(.v26)]` and nothing
  else. The import census says most of the stack is iOS-clean and that the one
  known macOS-only mechanism is IOSurface-to-`CALayer.contents` presentation
  (briefing.md sec. 4) -- unverified by any build.
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
Supported only by the import census in briefing.md sec. 4. T1 and T2 confirm it
or itemize the failures. Rejection would reshape the whole doc, which is why
these tasks run first.

### H2 -- CPU-composed frames present acceptably on iOS without IOSurface

At phone-scale grids (tens of columns, not hundreds), drawing a
`RenderFramePlan` into a `CGBitmapContext` and assigning a `CGImage` to
`layer.contents` sustains device refresh at acceptable energy cost. Competing
explanation: the per-frame copy or color management stutters under a full-repaint
scroll workload, and a `CVPixelBuffer`/`CAMetalLayer` path (the closer analogue
to the existing N-buffer swapchain) is required. T3 measures both; D2 selects.

### H3 -- a remote TerminalCore converges from snapshot plus tape

`NeutralTerminalRecordingEvent.feed` carries raw PTY bytes, so a second
`TerminalCore` instance fed the same stream reproduces the source pane's grid;
the recording/corpus infrastructure already replays these tapes headlessly. The
unproven parts are joining mid-stream (a serialized grid snapshot must exist and
must splice cleanly onto the live stream) and how viewport/resize events from a
differently-sized client interact with the stream. T4 confirms Mac-to-Mac with
zero iOS variables.

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

- **T1 RESEARCH** -- Cross-compile the candidate portable set for iOS: on a
  scratch branch, add iOS platform pins and build `TerminalCore`,
  `TerminalRenderPlanning`, `TerminalSpriteGeometry`, `DanTermProtocol`,
  `DanTermCore`, and `DanTermSupport` for a simulator and a device triple.
  Record pass/fail per module and every failing symbol in F1.
- **T2 RESEARCH** -- `TerminalRenderExecution` on iOS: itemize what it actually
  needs (the `NSFont` call, `NSAttributedString` status, whether
  `TerminalFrameBackingStore`/`TerminalFrameSwapchain` are ported, stubbed, or
  replaced wholesale on iOS), then render one static `RenderFramePlan` in a
  minimal iOS app. Record in F2.
- **T3 RESEARCH** -- Presentation-path measurement on a real device: worst-case
  full-repaint scroll workload at a phone-typical grid, `CGImage` ->
  `layer.contents` vs a `CAMetalLayer`/`CVPixelBuffer` path. Diagnostic frame
  timings and energy notes into F3.
- **T4 RESEARCH** -- Mac-to-Mac thin-client spike: a second macOS process
  connects to the control socket, issues `pane.tape --follow`, feeds a local
  `TerminalCore`, and presents it. Proves the remote-session concept, and
  exposes the mid-stream-join gap concretely, with zero iOS variables. Record
  in F4, including exactly what state a joining client lacked.
- **D2 gate** -- select the iOS presentation path, from F2 and F3.
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
  the bridge. Begin only after T4 has exposed the real gap shapes. Records D5.
- **T9 TODO** -- Reconnect behavior on the phone against the T5 bridge and the
  T8 protocol: airplane-mode toggles, backgrounding, cold relaunch. Record what
  each recovery actually required in a finding.

### Phase 4 -- geometry and input semantics

- **T10 VETTING** -- Geometry conflict semantics: *observe* (read-only, local
  reflow of history) vs *claim* (the phone owns the PTY size and restores it on
  detach), selectable per pane; define what the Mac window shows while a pane
  is claimed. Records D6.
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
  lint once iOS pins exist, so boundary violations fail at the seam.

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
