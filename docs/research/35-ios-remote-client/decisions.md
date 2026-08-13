# Decisions -- iOS remote client

Auditable decision log for doc 35. D4, D6, and D7 are reserved as gates by the
task ledger in [README.md](README.md) and remain open.

### D1 -- scope and first milestone

- Status: decided 2026-08-12, by user direction.
- Evidence used: the initiating conversation with the user;
  [briefing.md](briefing.md) sec. 8.7 (the phasing sketch and the
  early-vs-late engine question).
- Candidate solutions: (a) agent-supervision-first (push notification, text
  read, quick reply -- no renderer), (b) read-only live viewer first, (c) full
  interactive engine-rendered terminal as milestone 1.
- Selected direction: (c). The first thing the user wants to use daily is a
  pane they can genuinely type into, rendered by the real engine.
- Decision and rationale: milestone 1 is a full interactive, engine-rendered
  terminal pane on the iPhone. This puts the Phase 1 rendering and engine
  spikes on the critical path and provisionally resolves briefing.md's
  early-vs-late engine question toward linking the engine from day one; that
  direction is restated as the D3 gate so Phase 1 evidence can still overturn
  it. Standing scope constraints recorded with the same authority: no todo
  surface on iOS; splits flatten to a pane list and the phone never issues
  `pane.split`; everything else starts as simple as possible. Environment
  facts that weight later decisions: a paid Apple Developer account exists
  (APNs and TestFlight available), and Tailscale runs on the Mac today with
  the phone able to join the tailnet.

### D2 -- the iOS presentation path is the existing swapchain

- Status: decided 2026-08-13, by user direction, on a second opinion's
  recommendation.
- Evidence used: F3 in full -- the device confirmation and both instruments --
  plus F2 for the compile and the simulator behavior it corrected. The
  transcripts are in `f3-artifacts/`. Also read directly:
  `TerminalFrameSwapchain.defaultDepth`'s comment on why three buffers rather
  than two, and `app/SwiftTerminalSessionView.swift`, which shows what owning
  the swapchain costs a client.
- Candidate solutions:
  1. The existing `TerminalFrameSwapchain`, which renders into a detached
     buffer and then attaches it.
  2. CGImage-copy-per-frame: render into one store, wrap its pixels in an
     immutable image, assign that as layer contents.
  3. A substitute surface path (`CAMetalLayer`, `CVPixelBuffer`), which F2 and
     F3 removed from consideration -- IOSurface displays as `layer.contents` on
     a real device, so no substitute is needed.
- Selected direction: (1).
- Decision and rationale:
  - **One strategy, not two.** macOS keeps the swapchain whichever arm iOS
    picks, so (2) does not replace a path, it adds one. Two presentation
    strategies fork every later change to presentation -- colorspace, scale,
    damage semantics -- along a platform seam, and a divergence there produces
    exactly the bugs that reproduce on one device and not the other. This is
    the argument the decision rests on.
  - **The measurements agree but did not decide it.** The swapchain presents a
    full-repaint frame in 1195us against 1984us, and spends about 11% less CPU
    on a bursty workload where its own presentation cost is indistinguishable
    from presenting nothing. Those numbers were taken with a display link
    ticking through an idle in which nothing was damaged; once presentation is
    gated on damage the copy delta shrinks toward noise. Support, not the case.
  - **What this declines, knowingly.** (2) cannot present indeterminately *by
    construction*, because every frame is a new immutable image. The swapchain
    avoids the same hazard *by discipline* -- it never mutates an attached
    buffer -- and that discipline rests on "a detached surface reported free
    stays free", pinned by `tests-ui/IOSurfaceLayerContentsTests.swift` on
    macOS and by one 100-frame device run here. F3 showed what violating it
    looks like on iOS, and it is not a crash but an indefinite alternation
    between two frames, which is the kind of defect that reads as a rendering
    glitch and gets chased for a day.
  - **The client owns a contract.** The swapchain type is portable, but its
    owner is not: a coalesced publish must be retried on a later tick, as
    `app/SwiftTerminalSessionView.swift` does. That is real iOS code (2) would
    not need, and "the swapchain is free because it already exists" is wrong
    for that reason.
- Consequence for the client, larger than this decision: presentation is a
  small share of the workload's energy. Presenting nothing at all cost 1.57s
  against the swapchain's 1.59s, with the rest going to engine feed, plan
  building, and a display link running at 60Hz through an idle in which nothing
  was damaged. Gating presentation on damage matters more than the arm choice
  did, and it is a client design task, not part of this decision.

### D3 -- the client is a replica engine, and placement is decided by derivability

- Status: decided 2026-08-13. This is the Phase 1 gate; deciding it closes
  Phase 1. The two halves rest on different things and the entry keeps them
  apart: the *confirmation* that the replica arm is open is evidence-driven,
  from F1-F4 and F6; the *adoption* of H5's invariant is a design commitment
  made by argument under the design bar, because feasibility of a replica is
  equally consistent with a served-plan hybrid and no finding chooses between
  them.
- Evidence used:
  - F1 -- the candidate portable set builds for both iOS triples with platform
    pins and nothing else, with no code conditionally compiled out.
  - F2 -- `TerminalRenderExecution` needs one font seam, a `PlatformFont`
    typealias at one call site, and the swapchain types port unchanged.
  - F3 -- presentation works on real hardware: an IOSurface displays as
    `layer.contents` on an iPhone 13 mini. The instrument detail is D2's
    evidence, not this gate's; D3 needs only that a phone can present.
  - F4 -- a second engine replaying a pane's tape produced a viewport
    byte-identical to that pane's own `pane read`, and planned a
    `RenderFramePlan` from its own engine in a process with no AppKit.
  - F6 -- `lib/DanTermClient` exists as the client end of the conversation, is
    pinned for iOS, and `scripts/ios-portability-gate.sh` fails the suite if a
    pinned package stops building for the device triple.
- Candidate solutions:
  1. Day-one engine: the app links `TerminalCore` + `TerminalRenderPlanning` +
     `TerminalSpriteGeometry` + `DanTermClient`, drives a local engine from the
     tape stream, and renders through the swapchain D2 selected.
  2. The text-only renderer held in Rejected: `pane.read` plus tape drawn as
     attributed text, with the engine deferred to a later milestone.
  3. Server-side rendering: the Mac serves pixels, or serves a
     `RenderFramePlan` the phone rasterizes.
- Selected direction: (1), unchanged from the provisional direction D1 recorded.
- Decision and rationale:
  - **The gate's own condition was not met.** Reopening (2) required Phase 1 to
    have shown the engine stack cannot reasonably build or present on iOS. Every
    leg passed. It did not pass for free, and F1's "pins plus one file split"
    framing is the one T16 corrected: what the port actually cost is a new
    `lib/DanTermClient` module, a new `lib/TerminalHostTools` package extracted
    to make the `TerminalCore` pin honest, a font typealias, two guarded test
    fragments, and a suite gate with its own fixture self-test. That is real
    work already done and shipped, not a blocker, and nothing in
    F1-F4 argues for an interim renderer -- so this gate confirms rather than
    restates.
  - **(2) buys a milestone by spending the same work twice.** It would
    misrepresent wide characters, colors, and mouse-mode programs for its whole
    life, against a D1 milestone that is a pane the user can genuinely type
    into, and then be deleted. The render seam already ends in a
    platform-neutral `RenderFramePlan`, so the engine path is not the long way
    round.
  - **(3) moves the phone's display into the Mac's inputs.** This is the
    argument against server-side rendering that stands on its own. Serving a
    `RenderFramePlan` forces the Mac to know the phone's font metrics, display
    scale, and grid, so the phone's own display becomes a server-side input and
    every font or rotation change on the phone becomes a round trip. Serving
    pixels is worse still: it hard-codes the display scale into the wire.
  - **The traffic ordering points the same way but is not evidence yet.** H5
    argues structurally that a dumber client here costs *more* bytes, since the
    terminal byte stream is already an application-aware delta encoding of
    screen state. Recorded as a structural expectation only: H5 has no measured
    magnitude and forbids citing one until T19, T20, and T21 report, and its own
    flood counterexample -- a pane emitting far faster than a screen can show
    it -- is exactly this product's headline workload. So this bullet supports
    the decision and does not carry it, and T21 can weaken it without reopening
    the gate.
  - **What this decision adopts, by name: single-owner replicated state over the
    terminal's own protocol** (H5). The PTY-owning engine on the Mac is the sole
    authority for terminal state; the wire is terminal bytes, plus sync-as-bytes
    (D5), plus a small authoritative control surface; the client is a replica
    that derives everything derivable and **originates no authoritative state**.
    This is the ideal structure named per the design bar, and it is adopted
    rather than merely kept on the table.
  - **Two words of H5's prose are narrowed on adoption, because the looser form
    is false against things this doc already plans.** H5 says "originates
    nothing", and the client originates two things by design: a resize, when
    T10's *claim* mode gives the phone the PTY size, and speculative screen
    state, if predictive local echo ever lands. Both are compatible with single
    ownership and neither is a loophole, because a claimed resize enters through
    the control surface and comes back as an ordinary authoritative resize
    event, and a prediction is reconciled against the authoritative stream and
    never survives contradicting it. The adopted rule is therefore about
    *authority*, not about silence. H5 also says the Mac is sole authority for
    "input semantics"; that phrasing is dropped here, for the reason in the next
    bullet.
  - **The invariant's purpose is to stop placement being argued item by item.**
    From here, "what lives on the phone" is not a smart/dumb dial: each item is
    decided by whether it is derivable from the byte stream. Derived on the
    client: terminal state, scrollback, reflow, render planning, rasterization,
    and local reflow in observe mode. Asked for over the control surface:
    geometry (F4 settled it as unconditional and authoritative), the tab and
    pane list, semantic activity events, and the query replies the replica must
    discard. D6 and T10 are checked against this sentence, and a proposal that
    fails it needs an argument against the invariant, not against the item. D4
    is not: where a TLS listener, a method allowlist, and an audit log live is
    not a derivability question, and claiming the invariant governs it would
    make the rule mean whatever the arguer needs.
  - **The invariant does not decide T11, and this is a limit rather than an
    exemption.** Whether the client encodes keystrokes from its own
    `inputModes` or sends `KeyTokens` for the Mac to encode, both positions obey
    single ownership, because the modes the client would encode against are
    themselves replicated state derived from the authoritative stream. What
    separates them is staleness -- a program can toggle a mode inside the round
    trip -- plus input ordering across several writers. Those are timing
    questions the derivability rule is silent on, so T11 decides on them, as the
    ledger already says. The general form matters more than the instance: this
    invariant places state, and it does not resolve races.
  - **Every leg passed in isolation and the composition has never run.** F1 and
    F2 are compiles, F3 drove a local engine on a phone with a synthetic
    workload, and F4 converged from a tape stream on a Mac with no device. No
    iOS binary has linked `DanTermClient`, and no engine on a phone has ever
    been fed by a tape stream -- F6 says so in its own uncertainty. Candidate
    (1) as described is therefore a composition, not an observation. The gate
    still closes, because each seam is individually proven and the seams are
    narrow, but the residual is real and no ledger task owns an on-device
    integration smoke. Phase 2's first client work should be that smoke.
  - **What this declines, knowingly.**
    - The client owns the swapchain contract D2 priced, including retrying a
      coalesced publish. (2) would not have needed it.
    - The phone carries a real engine's memory and CPU, and this decision
      states no bound for either. Replicated scrollback is the open end: how
      many panes hold a replica at once (T22's subscription scope implies one
      live plus activity events for the rest, but does not decide it), and how
      deep each replica's history goes, are unmeasured and unbounded here.
    - Session-length energy for an engine plus a display link on the phone is
      unmeasured, and it is the doc's own headline open question. F3 measured
      seconds, not a session.
    - Both ends run the same engine code, so a client binary is only correct
      against engines whose behavior it agrees with. Calling that tolerable
      "because both ends ship from one repo" assumes an atomic upgrade the
      deployment model does not provide: the Mac upgrades by replacing the app
      and the phone through TestFlight, so the two ends will skew in normal
      use. There is no version field in the handshake, no mismatch detection,
      and no ledger task that owns it. Naming it here is not absorbing it, and
      it should get an owner before the client ships.
    - (2) would have had a working screen sooner, and none of the above.
  - **It also keeps an option that only a replica engine can reach.** Predictive
    local echo, mosh-style, needs a real terminal on the phone to apply
    keystrokes speculatively and reconcile against the authoritative stream.
    That is not milestone-1 work under D1, but latency is the phone's dominant
    variable and (2) and (3) both close this door permanently.
- What this decision does *not* settle, recorded so the invariant is not
  over-read: who encodes input (F4's payload floor and H5's competing position
  contradict each other; T11 decides and says which it overrules); the flood
  case, where the byte stream is the expensive encoding and the architecture
  survives by skipping rather than compressing (T21); and every traffic
  magnitude, which H5 forbids citing until T19, T20, and T21 report.
- **What would reopen this.** Recorded because a gate that closes without one is
  unfalsifiable from here, and the arms it rejected are cheap to re-derive
  badly. Three results reopen the replica direction, and nothing else does:
  a session-length energy measurement showing a replica engine plus a display
  link costs materially more battery than a served-frame client at the same
  fidelity; a phone-memory result showing a replica's replicated scrollback
  cannot be bounded without losing the scrollback the product exists to read;
  or T21 sizing the flood case such that skipping cannot hold the byte stream
  within a usable cell link. None of the three reopens (2), the text renderer,
  which stays rejected on fidelity under D1 regardless -- they would reopen the
  *placement*, toward (3) or a hybrid, and would do it against this invariant
  rather than item by item.

### D5 -- durable subscriptions: state sync as tape bytes, and cursor resume

- Status: decided 2026-08-12, from F4.
- Evidence used: [f4-mac-to-mac.md](f4-mac-to-mac.md) in full -- the
  divergence table for a from-now join, the `aftermath` run showing a joiner
  heals its visible screen and never its history, the `evict` run showing an
  evicted resize left a reader replaying 8,940 events into an 80x24 grid for a
  179x66 pane, and the `reconnect` run where 216 skipped events were reported
  as nothing. Plus the existing machinery F4 names:
  `TerminalFlightRecordingCursor`, `cursorSnapshot(from:)`, and the
  origin/cursor fence in `TerminalFlightRecordingCapture`.
- Candidate solutions:
  1. Structured state serialization -- the snapshot is a protocol value
     carrying cells, attributes, and mode flags, loaded through a new engine
     entry point.
  2. State serialized as terminal bytes -- the snapshot is a synthetic byte
     stream that reconstructs the state when fed to a reset terminal of a
     stated geometry, delivered as a record in the tape stream.
  3. No snapshot; raise the recorder's retention bound so backlog replay is a
     reliable recovery path.
- Selected direction: (2), delivered as a `sync` record in the tape stream plus
  a one-shot method returning the same payload, with tape requests able to
  supply a start cursor.
- Decision and rationale:
  - **Payload shape.** The wire is the terminal protocol itself. A reader
    already knows how to feed bytes to a terminal, so sync needs no new
    decoding path and no engine-internal format, and an engine change is not a
    wire change. (1) is exact but couples the wire to engine internals and
    needs a load-state entry point that exists for no other reason; anything
    the byte form cannot express is state no real terminal stream could have
    produced. (3) makes recovery probabilistic in memory rather than
    guaranteed, and F4 showed that failure is silent and geometric.
  - **Broker location: the app runtime, and there is no new broker.** The
    per-pane bounded ring buffer is the flight recorder and the per-subscriber
    cursors are the follow subscriptions; both already exist in the app. A ring
    in the bridge would duplicate them behind a second bound and a second
    sequence space, and would earn its place only if a client's offline window
    could outrun the app-side ring -- which sync removes as a failure mode. So
    T8 does not depend on T5, and the bridge stays a frame proxy.
  - **The retention bound stays a debugging parameter, unchanged at 8 MiB /
    32,768 events.** F4 correctly observed that today the retained tape is a
    snapshot substitute exactly while it is un-evicted, which made the bound a
    session-durability parameter. Sync ends that coupling rather than
    re-tuning it: the design invariant is that no stream's ability to reach
    exact state depends on retention. This is the structurally independent
    answer, so the bound goes back to deciding only how much raw history a
    debugging dump can show.
  - **Sync is injected exactly when the requested position is not
    reconstructible from the records that will be delivered**, and the stream
    continues at the sync's own fence. State and cursor are taken in one fence,
    the way `TerminalFlightRecordingCapture` already pairs origin with cursor
    snapshot, so no event is both reflected in the state and delivered after
    it. Loss is measured against the position the requester asked for, which
    turns F4's silent 216-event reconnect into a stated gap.
  - **Acceptance is asserted on state that does not self-heal**: join a pane
    running a full-screen program, let the program exit, then assert scrollback
    depth and `inputModes`. F4's `aftermath` run showed the visible screen
    heals through a prompt repaint, so a screen-reading test would pass against
    a sync that carried nothing.
  - **The round-trip obligation asserts state equality, not byte equality, and
    its corpus is classes of state rather than a fixed list.** Both are load
    bearing and both look like looseness worth tightening, so they are recorded
    here rather than left to the plan. Comparing emitted bytes would convert a
    behavioral test into a structure-sensitive one and would fail on encoding
    choices this decision deliberately leaves to implementation. A fixed corpus
    would silently stop covering the payload floor the moment the engine grows a
    mode, which is the exact failure the obligation exists to catch -- it is the
    only test here that fails when the serializer falls behind the engine.
- Deferred, with reasons recorded in the plan: the two-engines-answering-a-query
  question, which is an input-direction rule (only the engine owning the PTY
  answers) and belongs with the input surface, not with state transfer; and
  DCS state, OSC 4 palette redefinition, the title stack, and OSC 11 background
  override, which are not gaps in the payload because the engine models none of
  them -- they become sync work only if it starts to, and the round-trip proof
  obligation is what will say so.
- Plan: `plans/wip/2026-08-12-1500-pane-snapshot-and-tape-resume.md`.
