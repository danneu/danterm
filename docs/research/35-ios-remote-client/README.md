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
- [t23-relay.py](t23-relay.py) and [t23-run.sh](t23-run.sh) -- the F7
  reproduction: a throwaway authenticated TCP relay on the Mac, and the run that
  drives a real pane while the phone replicates it. The phone half is the
  `client` mode of [ios-render-spike.sh](ios-render-spike.sh); its console
  transcript is under `t23-artifacts/`.
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
interactive, engine-rendered terminal on the phone (D1).

The doc converges toward plan files. Its Phase 1 to 4 tasks investigate and do
not implement; a spike is thrown away once the gate it feeds has chosen. Phase 5
is the exception, because the refactors there are the product of a decision this
doc already made: those tasks graduate to a plan and then land, and the finding
records what shipped. F6 is the first of those.

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
- The iOS platform pins are in the tree, on `TerminalCore`, `DanTermProtocol`,
  and `DanTermClient`, and a suite step proves each one on every run (T14, T17,
  T18). F1 established the claim by building rather than by an import census;
  T16 corrected what that proved, since compiling for iOS is not the same as
  having a role a client would call. `DanTermSupport` and `TerminalPTY` carry no
  pin by design: they are the Mac host's layer.
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

Restated after F2, and corrected on hardware by F3. The original H2 asked
whether CPU-composed frames present acceptably *without* IOSurface, and named
`CVPixelBuffer`/`CAMetalLayer` as the closer analogue to the N-buffer swapchain.
That framing is dead: `TerminalFrameSwapchain` and `TerminalFrameBackingStore`
compile and run on iOS unchanged, and an IOSurface displays as `layer.contents`
on a real device, not just in the simulator.

F2 went one step further and said CoreAnimation honors the same attach-to-publish
protocol the swapchain speaks, on the evidence that an in-place pixel rewrite
does not reach the screen while reassigning the same surface does. On device
that is wrong, and F3 replaces it. Mutating a surface while it is attached
presents *indeterminately*: from a single render, with nothing reattached, the
screen flashed the new frame, reverted, and then alternated between the two
frames indefinitely. The simulator's clean result was one sample of that, not a
rule. The real swapchain, which renders into a detached buffer and then attaches
it, published 100 consecutive frames with no coalescing and then held the last
one indefinitely.

So attach-to-publish is not a protocol iOS happens to share -- it is what makes
presentation deterministic there for a *reused* surface. This does not
disqualify the alternative, and it is worth being exact about why:
CGImage-copy-per-frame is deterministic by construction, because each frame is a
new immutable image rather than a mutation of an attached one, so the hazard F3
found cannot arise there. Probe A held its frame through every run, including
the ablation.

What separates the two arms is therefore cost, not correctness.
CGImage-copy-per-frame pays a full-frame copy and an allocation every frame --
at F3's grid the surface is 1113x480 px, about 2.1 MB, so roughly 128 MB/s of
copying at 60Hz -- and the swapchain pays none. On a phone that reads as an
energy question first and a throughput question second.

The live question is therefore: does the real `TerminalFrameSwapchain` beat
CGImage-copy-per-frame on a phone, at phone-scale grids, under a full-repaint
scroll workload, in frame timing and energy? T3's measurement half answers that;
D2 selects between them, with the swapchain the favorite and the copy path the
fallback. The substitute paths (`CAMetalLayer`/`CVPixelBuffer`) are no longer
candidates for the presentation mechanism, since the surface path is confirmed
on device; they would return only if the measurements show the swapchain cannot
hold a frame rate.

Open, and not needed for D2: what actually drives the re-sampling behind the
alternation. It is not app-requested compositing -- F3 rules that out -- and no
probe has established the mechanism.

### H3 -- a remote TerminalCore converges from snapshot plus tape

Confirmed by F4, Mac-to-Mac, and then by F7 on a phone: a replica engine on an
iPhone, joined to a live pane through the D5 sync, reached a viewport whose
digest matches that pane's own `pane read`. The iOS variables F4 excluded turned
out to change nothing about convergence.

A client replaying a
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

### H5 -- the split is decided by derivability, not by a smart/dumb dial

Adopted by D3: its invariant is now the rule later placement questions are
checked against, not a hypothesis waiting on evidence. The three things it does
not settle, listed at the end of this section, stay open and D3 repeats them.

The question this hypothesis answers: how much work belongs on the phone versus
the Mac, and whether a simpler client would cost less network traffic.

For most remote-UI systems a dumber client means more bytes on the wire, and the
two are traded against each other. Terminals do not work that way, because the
byte stream is itself an application-aware delta encoding of screen state. So the
candidate splits order the same way on fidelity and on cost: a pixel stream is
the dumbest client and the most traffic, a served `RenderFramePlan` is less (and
would force the Mac to know the phone's font metrics), a cell diff is less again,
and the raw byte stream is the least. The day-one-engine direction of D1/D3 is
therefore not fidelity bought with bandwidth. That argument is independent of the
fidelity one and belongs in the D3 restatement.

The rule that follows, and the ideal structure the whole question dissolves in,
is **single-owner replicated state over the terminal's own protocol**: the
PTY-owning engine on the Mac is the sole authority for terminal state and input
semantics; the wire is terminal bytes, plus sync-as-bytes (D5), plus the small
authoritative control surface; the client is a replica that derives everything
derivable and originates nothing. Under that invariant, what lives where is not a
dial to tune -- it is decided per item by "derivable from the byte stream or
not". Replicated: terminal state, scrollback, reflow, render planning,
rasterization, and local reflow in observe mode. Asked for: geometry (F4 settled
it as unconditional), the tab and pane list, semantic activity events, and the
query replies the replica must discard.

Three things this hypothesis does *not* settle, each recorded so it is not read
as settled:

- **The flood case is a real counterexample to the cost ordering.** Bytes cost
  what the program emits; a frame-bounded diff costs screen area times frame
  rate. A pane dumping 50 MB is the case where the byte stream is the expensive
  encoding, and it is also this product's headline workload -- panes running
  coding agents. The architecture survives it by skipping rather than by
  compressing, which is why the repair policy below is load bearing rather than
  cosmetic. T21 sizes it.
- **Input encoding contradicts a recorded finding.** F4's payload floor item 5
  states that a client encodes keystrokes from its own `inputModes`, "which is
  what a real client must do". The competing position is that the client sends
  `KeyTokens` and the PTY-owning engine encodes, which removes the race where a
  program toggles a mode inside the round trip and the phone encodes against dead
  modes, serializes input order across several writers, and matches D5's deferred
  input-direction rule. Neither is adopted here; T11 decides and says which of
  the two it overrules. Note that predictive local echo needs local modes either
  way, so the sync payload's mode floor stays load bearing under both.
- **No traffic number in this hypothesis has been measured.** The ordering is
  structural and stands; the magnitudes do not exist yet. T19, T20, and T21 are
  the probes, and no wire-format or policy change may cite this section as
  evidence until they report.

## Direction

The client leg is settled by D3; the rest is provisional and each leg has a gate
in the ledger.

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
  without them. The pins stayed out of the tree at the time, and
  [ios-cross-compile.sh](ios-cross-compile.sh) applied and restored them per
  run, so the result was re-derived rather than asserted by a manifest. T14 has
  since replaced that script's role with a suite step, and T16 corrected what
  the `DanTermSupport` result proved.
- **T2 DONE** (F2) -- `TerminalRenderExecution` on iOS. The `import AppKit`
  hid one symbol: `NSFont.monospacedSystemFont` on line 90, which `UIFont`
  answers identically, so the seam is one `typealias` behind
  `#if canImport(AppKit)`. `NSAttributedString` was a false alarm (Foundation).
  `TerminalFrameBackingStore` and `TerminalFrameSwapchain` port unchanged --
  IOSurface is public on iOS -- and a simulator spike showed CoreAnimation there
  honors the swapchain's attach-to-publish protocol. H2 is restated as a result.
  The font seam landed with the pins in T18.
- **T3 DONE** (F3) -- Presentation-path confirmation and measurement on a real
  device (iPhone 13 mini). The confirmation did not go as F2 predicted: an
  IOSurface does display as `layer.contents` on hardware, but mutating an
  attached surface presents indeterminately rather than not at all, while the
  swapchain's rotate-then-attach path is stable across 100 published frames and
  holds the last one. H2 is corrected above; attach-to-publish is a requirement,
  not a shared convention. On cost, the swapchain presents a full-repaint frame
  in 1195us against the copy path's 1984us, both arms hold 60Hz with no missed
  presentations, and on a bursty incrementally damaged workload the copy path
  spends about 11% more CPU across three runs while the swapchain's presentation
  cost is indistinguishable from presenting nothing.
  Signing needed no Xcode project: an existing wildcard development profile
  already covered the device, and `ios-render-spike.sh`
  ([ios-render-spike.sh](ios-render-spike.sh)) reproduces every mode, sharing
  its build and bundle assembly with the simulator target F2 used.
  Two results carry past D2. The plan build is not a control the presentation
  path cannot reach -- under display-link pacing it varied 2.5x with how much
  work the arm did around it, because a lighter frame lets the CPU settle
  lower -- so per-frame costs are only comparable under saturated pacing. And
  presentation is a small share of this workload's energy: presenting nothing
  costs 1.57s of the swapchain's 1.59s, with the rest going to engine feed, plan
  building, and a 60Hz display link ticking through an idle in which nothing is
  damaged.
- **T4 DONE** (F4) -- Mac-to-Mac thin-client spike. Convergence confirmed
  byte-for-byte against `pane read`. The join gap is modes, not just history,
  and the stream is not self-synchronizing; F4 states the `pane.snapshot` floor
  for T8 and the observe-vs-claim consequence for T10. Two unplanned results
  carry into Phase 3: tape eviction drops the oldest events, which are the ones
  that establish geometry and modes, so an evicted backlog replays into the
  wrong grid size; and resume already has its coordinates in
  `TerminalFlightRecordingCursor`, with only the ability for a client to supply
  one missing at the protocol edge.
- **D2 DECIDED** ([decisions.md](decisions.md)) -- the iOS presentation path is
  the existing `TerminalFrameSwapchain`. Both arms are correct on device, and
  the decision rests on keeping one presentation strategy rather than two, not
  on F3's numbers, which agree but are support. The client owns the swapchain's
  contract, including retrying a coalesced publish, so it is not free. D2
  records what selecting it declines.
- **D3 DECIDED** ([decisions.md](decisions.md)) -- the client is a replica
  engine, confirming D1's provisional direction. The gate's condition for
  reopening the text renderer was that Phase 1 fail, and every leg passed: the
  port cost platform pins, one typealias, and one file split. D3 adopts H5's
  invariant by name -- single-owner replicated state over the terminal's own
  protocol -- so later placement questions (who encodes input, who answers
  queries, who owns geometry, whether the client predicts) are checked against
  one rule instead of argued one at a time. It narrows two words of H5 on
  adoption ("originates nothing" becomes "originates no authoritative state",
  and the Mac's authority over "input semantics" is dropped, because that
  phrasing would silently decide T11), states that the invariant places state
  and does not resolve races, and records what the replica costs plus what
  would reopen it.

Phase 1 is closed, and so is the residual it closed over: every leg passed in
isolation, and F7 then ran the composition on a phone against a live pane.

### Phase 2 -- transport, authentication, security

- **T5 RESEARCH** -- Bridge prototype: TCP+TLS listener proxying frames into
  the Unix socket, bound to the tailnet interface; put Tailscale on the phone
  and connect with a scratch client. Record round-trip latency and behavior
  across a wifi/cell switch in F5. Two H5 consequences land here rather than in
  T8. First, the bridge is where an unbounded per-subscriber buffer can exist at
  all: the app side already holds a cursor and two booleans per subscription and
  stores no events, and the ring is the flight recorder, so the invariant to
  carry across the network is that **the bridge buffers at most one in-flight
  batch per subscriber**. State it where the bound lives, or it gets enforced in
  the layer that was never the risk. Second, stream compression at the bridge is
  architectural and safe to adopt now; a binary tape framing is not, because
  deflate over JSON envelopes and base64 may erase most of that tax for no
  protocol change. T19 decides whether any framing work is left.
- **T23 DONE** (F7) -- On-device integration smoke. It passes. An iOS binary
  links `DanTermClient`, subscribes to a live pane over a TCP conformance of the
  transport seam, applies the D5 sync with the shipped assembler, drives a
  replica `TerminalCore` on the phone from the following events, and presents it
  through the D2 swapchain. The phone's viewport digest matches the source pane's
  own `pane read`, the presented surface carries real ink, and `vim` moves the
  replica's modes and alternate screen and back. Nothing in `lib/` changed; the
  seam that names no socket kind absorbed the whole transport difference.
  Three things carry forward. The listener's authentication story is in F7 and
  is not the tailnet one this doc's rules assume, because this Mac has no
  tailnet. An iOS client needs `NSLocalNetworkUsageDescription` or the connection
  fails as "No route to host", which reads like a network fault. And the
  swapchain's pending-presentation retry never fired at this event rate, so that
  half of the D2 contract is still unexercised on a phone.
- **T24 TODO** -- Version skew between the two engines. D3 accepts that the
  client only works against engines whose behavior it agrees with, and the
  deployment model gives no atomic upgrade -- the Mac replaces its app, the
  phone updates through TestFlight, so the ends skew in normal use. There is no
  version field in the hello handshake and no mismatch detection. Decide what
  the handshake carries and what a mismatched client does: refuse, degrade, or
  warn. Wanted before the client ships, not before the smoke.
- **T6 VETTING** -- Pairing and auth model: compare tailnet-identity-only,
  pinned client certificates, and a pairing token; decide where the method
  allowlist, rate limits, and audit log live. Also weigh the ideal alternative
  to a bridge (the app listening on the network itself) rather than assuming
  the bridge. Records D4.
- **T7 TODO** -- Security review of the exposed surface: what
  internet-reachable `pane.input` implies, the `NSHomeDirectory` taint in `ls`
  and snapshot payloads (briefing.md sec. 7) now that replies cross machines,
  and what an audit log must capture. Feeds D4.
- **T19 TODO** -- Measure what the tape stream actually costs on the wire, since
  H5 asserts an ordering and no magnitude. Capture a follow stream's bytes over a
  real interactive session against a live slot, raw and deflated, and separate
  payload from envelope: an 8-byte echo rides inside a base64 payload and a JSON
  envelope, and the ratio between them decides whether a binary tape framing has
  anything left to win after compression. Report an interactive session, a build
  log, and an idle pane. Diagnostic, not benchmark, and labeled so.
- **T21 TODO** -- Size the flood counterexample H5 names: the byte rate for a
  pane emitting far faster than a screen can show it, against the bound a
  frame-coalesced cell diff would have at the same grid and frame rate. This is
  the one workload where the byte stream is the expensive encoding, and it is the
  agent-supervision workload, so the number decides how much the repair policy in
  T20 has to carry. It does not reopen the wire format by itself: a diff wire
  would have to beat bytes *plus* skipping, not bytes alone.
- **T22 TODO** -- Subscription scope: a full tape subscription for the pane on
  screen, and 34/D2 activity transitions for every other pane, so a backgrounded
  agent costs a few bytes per state change instead of its whole output. This is
  the one traffic lever that is architectural rather than an encoding tweak, and
  it survives H5's "no numbers yet" caveat because it changes what is sent rather
  than how. Its unexamined cost is the pane switch: if each switch splices a
  fresh sync, and sync carries history with attributes, then flipping between
  panes is expensive in exactly the way a scrollable pane list invites. Decide
  whether sync's history component can be lazy or bounded for the
  interactive-switch case -- T8-adjacent, but not a question D5 answered.

### Phase 3 -- durable subscriptions and resume

- **T8 DONE** (D5, shipped) -- Design `pane.snapshot` plus sequence-numbered tape resume:
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
  [plans/impl/2026-08-13-1942-pane-snapshot-and-tape-resume.md](../../../plans/impl/2026-08-13-1942-pane-snapshot-and-tape-resume.md).

  **Shipped** 2026-08-13, across `dd96996b`, `737c99c2`, `46a2da45`, and
  `fb1f0b0f`: stream version 3, `pane.snapshot`, structured start and mode
  parameters across the IPC, CLI, and client boundaries, and a raw mode that
  keeps serving the debugging dump. Four contract points that D5 did not
  anticipate are recorded with it: a sync is a multi-record indivisible prefix
  that takes effect only when complete; the inactive alternate screen is
  excluded because the engine blanks it on every entry and no byte stream can
  reveal it; unfinished input-stream state travels in the payload because a
  fence does not land in ground state; and a cursor is meaningful only to the
  recorder lifetime that minted it.
- **T20 TODO** -- Measure a sync payload against the backlog it would replace,
  across three panes: quiet with deep history, freshly started, and flooding.
  This decides two things H5 left open, and both currently rest on an unchecked
  assumption that sync is cheap. First, whether a reconnecting client should ever
  prefer sync to a reconstructible backlog: D5 already injects sync exactly when
  the requested position is unreachable, and because sync carries the primary
  screen's history with attributes, a preference rule would resend a whole
  scrollback to avoid replaying a few bytes on a quiet pane. Second, the repair
  policy for a subscriber that cannot keep up on a slow link -- drop it forward
  to a fresh sync, or deliver a gap record and let it hold stale-but-bounded
  state until the flood ends and then sync once. Under sustained flood the first
  can thrash, on exactly the deep-history pane where sync is largest. Sizes
  decide it; the buffering bound itself is not in question and belongs to T5.
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
  itemize what the token grammar cannot express today. Also decide who encodes,
  which H5 opened as a live contradiction: F4's payload floor says the client
  encodes from its own `inputModes`, and the competing position is that the
  client sends tokens and the PTY-owning engine encodes. Traffic does not
  separate them -- a keystroke is a keystroke either way -- so decide it on the
  mode race, on input ordering across several writers, and on D5's deferred
  input-direction rule, then say explicitly which position is overruled.

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
- **T14 DONE** (F6) -- The platform-layering lint exists as
  `scripts/ios-portability-gate.sh`, a step in `scripts/run-test-suite.sh`. It
  enforces the invariant T16 stated: *a package that declares `.iOS` in
  `platforms:` has every one of its manifest targets build for the iOS device
  triple, test targets included.* The open question is closed in favour of a
  full cross-compile: a static check cannot see a host-only call inside a
  compiled target, and a periodic build reports the breakage after the change
  that caused it. The gate discovers pinned packages by reading the manifests
  rather than from a list, so a package is covered the moment it is pinned. It
  carries its own fixture self-test
  (`scripts/tests/ios-portability-gate_test.sh`), also a suite step. It did not
  extend `core-purity-lint.sh` as the task first imagined -- a purity lint reads
  source for forbidden imports, and this claim is only settled by a compiler.
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
- **T17 DONE** (F6) -- `lib/DanTermClient` is the single owner of the client end
  of the conversation: a transport seam that names no socket kind, the framed
  request/reply/notification loop over `IpcLineFramer`, the hello handshake, and
  a pane-tape record decoder. It depends on `DanTermProtocol` and nothing else,
  is pinned for iOS, and the CLI's two hand-rolled transport copies are deleted
  and rewired onto it. `DanTermSupport` stays whole, is named the Mac host's
  side-effect layer, and gets no iOS pin.
- **T18 DONE** (F6) -- The font seam and the pins landed with T17. The seam is a
  `PlatformFont` typealias behind `#if canImport(AppKit)`, one import block and
  one call site. Pins are on `TerminalCore`, `DanTermProtocol`, and
  `DanTermClient`. Making the `TerminalCore` pin honest cost a new
  `lib/TerminalHostTools` package holding `GlyphPreview`, its test target, and
  `TerminalMemoryProbe`, plus two guarded fragments in test targets that stayed:
  the `vmmap` shell-out and a Swift Testing exit test, both instruments rather
  than behaviors, neither losing macOS coverage.

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
time. The reopen condition was that Phase 1 show the engine stack cannot
reasonably build or present on iOS; F1-F4 showed the opposite, so D3 closed the
gate in the confirming direction and this stays rejected.

### A fixed server-side coalescing window on the tape stream

Proposed under H5 as a traffic lever: hold appended events for one frame
(16-30ms) so an interactive echo cannot ride alone inside its envelope. Rejected
on inspection, for two reasons. Coalescing already exists and is paced by
backpressure rather than by a clock: `PaneTapeFollowSubscriptions` keeps one
batch in flight per stream and merges every append edge behind it into a single
next fetch, so batches grow by themselves exactly when the link is slow. A fixed
window on top of that adds latency to the most latency-sensitive traffic on the
phone -- the echo of the user's own keystroke -- to save bytes on the traffic
that already self-coalesces. Reopen only with T19 numbers plus an energy result
showing the radio cost of a trickle outweighs the added latency, which is the
tension recorded under open questions.

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
  needs a session-length measurement. Frame the model correctly when it runs:
  feed is per byte, but rendering is per frame under `CADisplayLink` and is
  bounded at display rate however fast the bytes arrive, so the cost is not
  "engine plus rendering per byte". The unresolved part is a genuine tension
  rather than a missing number -- the radio prefers fewer, larger transfers,
  which argues for coalescing, and interactive latency argues against it. Do not
  pick a window before T3 and T9 measure both sides.
- **Latency is the phone's dominant variable, and no task owns it.** Bandwidth
  over a tailnet is nearly free; the round trip on cell is not, so every traffic
  lever should be scored against latency and not only against bytes. The replica
  engine also makes mosh-style predictive local echo reachable later -- the
  client has a real terminal, so it can apply its own keystrokes speculatively
  and reconcile against the authoritative stream. That is not milestone-1 work
  under D1, but it is an option the day-one-engine direction keeps open, and it
  is a further argument at the D3 gate.
- **Fonts.** `monospacedSystemFont` exists on iOS, but parity for the user's
  configured font (Nerd Font glyphs, ligature behavior) on the phone is
  unexamined.

## Outcome

Investigation in progress.
