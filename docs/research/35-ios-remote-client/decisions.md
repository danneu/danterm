# Decisions -- iOS remote client

<!-- docs-lint: allow-missing t5-bridge/ -->

Auditable decision log for doc 35. D7 is reserved as a gate by the task ledger
in [README.md](README.md) and remains open.

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
    **Settled by F7** (T23, 2026-08-13): the composition ran on an iPhone against
    a live pane and converged with it, and the join needed no change to any
    shipped module. This gate's confidence is no longer resting on an
    unobserved composition.
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

### D4 -- the tailnet is the credential, and the app owns the listener

- Status: decided 2026-08-13, from F5 and F8. Implemented 2026-08-14. This is the gate on the Direction
  section's server leg, and it **overturns** that leg: the leg said a separate
  bridge process owns network listening, authentication, and the APNs sender,
  and this decision says the app listens and there is no bridge. The leg was
  written as a proposal with this task as its gate, so overturning it is what
  deciding it means, but the reversal is called out here because it changes a
  statement the doc has carried since briefing.md.
- Evidence used:
  - F5 in full: the tailnet-identity-only arm ran end to end, a phone drove a
    real pane for 215 seconds, and the connection survived a wifi-to-cell-to-wifi
    switch without reconnecting. Also its two absences -- no auth surface, no TLS
    -- both deliberate, so nothing here is inherited.
  - F8 in full: the surface is remote code execution, there is no least-privilege
    subset of it, today's authenticator is filesystem permissions, 64 idle
    connections deny service to new callers while leaving established ones alone,
    nothing is logged, and a tailnet peer address resolves locally to a stable
    node id and a user.
  - Read directly: `ControlSocketListener.open` (the 0700 directory and 0600
    socket), `IpcServer.accept` (hello then dispatch, no credential),
    `IpcDispatch`'s `quit` case (an authorization check that already lives in the
    pure core and reads its input from `CoreEnv`), `IpcRequestMethod`'s
    `terminatesInstance` and `isTargeting` (two exhaustive switches that already
    force every new method to classify itself), and `t5-bridge/`'s
    `TailnetBindAddress`.
  - [briefing.md](briefing.md) sec. 8.2, which proposed the bridge and named it
    "a natural home for rate limits, method allowlists, and an audit log". That
    sentence is the specific claim this decision rejects.
- Candidate solutions, on two axes that the task ledger names together and that
  turn out to interact:
  - Identity: (a) tailnet identity only; (b) pinned client certificates over
    TLS; (c) a pairing token.
  - Placement: (1) a separate bridge process that proxies into the Unix socket;
    (2) the app opens the network listener itself.
- Selected direction: **(a) with (2)** -- the app binds a tailnet listener, the
  peer's tailnet identity is the credential, and that identity must appear on an
  explicit admitted-node list. No TLS, no pairing token, no bridge process. Three
  things travel with it: an exhaustive remote-method classification in the pure
  core, an app-side audit log, and a cap on concurrent connections. The listener
  is per instance and closed by default, so an ordinary launch opens no port.
- Decision and rationale:
  - **The tailnet is a real credential, not a trusted-network assumption.** The
    source address of a packet on the tailnet interface is bound to a WireGuard
    peer key, and F8 verified that the address turns back into a stable node id,
    a machine name, and an owning user with a local `tailscale whois` that needs
    no root. So the listener learns *which device and whose account* is calling
    before it reads a byte, gets encryption and key rotation it does not
    implement, and gets revocation through an admin console the user already has.
    That is more identity than an application-layer credential would give, and it
    is the only one of the three arms whose revocation story does not require the
    user to be at the Mac.
  - **TLS is declined, and this closes the untested half of H4 rather than
    leaving it open.** Over WireGuard it re-encrypts an already encrypted
    transport. Unpinned it adds no identity. Pinned it adds a second credential
    system with its own provisioning, expiry, and revocation, all manual, to sit
    behind an identity that is already stronger -- and a second system whose
    revocation is worse than the first's is a security cost, not a defense in
    depth. The one threat it would genuinely address is a Tailscale coordination
    server that inserts a node into this tailnet; against that, node-key pinning
    at the *Tailscale* layer (tailnet lock) is the instrument, and it is the
    user's to turn on, not this listener's to reimplement. F5's mobility result
    also removes the argument that a handshake is too expensive for a phone --
    connections here are long-lived -- so TLS is declined on what it adds, not on
    what it costs.
  - **A pairing token is declined, and it stays declined.** It is a replayable
    bearer secret that has to be stored on both ends, rotated by hand, and kept
    out of logs and command lines, and it authenticates a secret rather than a
    device. F5 already retired the T23 token once. Nothing in this review found a
    case it covers that the tailnet identity does not.
  - **"Any tailnet peer" is too coarse, and this is where F5's arm needs
    narrowing.** F5 proved the listener can only exist on the tailnet; it says
    nothing about which peers may talk to it. Given F8 -- one request runs a
    command as the user, and no subset of the surface is safer -- "every device
    on my tailnet, forever, including ones added later" is the wrong grant. The
    listener therefore checks the resolved stable node id against an explicit
    admitted list, so admitting a work laptop to the tailnet does not silently
    hand it a shell on the MacBook. Stable node id, not address: addresses are
    reassignable and a name is a label, while the stable id is what the admin
    console revokes.
  - **The app listens; the bridge is rejected, and the reason is structural
    rather than economic.** This is the ideal the task was required to weigh, and
    it wins on three counts.
    1. *The allowlist drifts in a bridge and cannot drift in the app.* The app
       already decides authorization in pure code -- `quit` is refused in
       `IpcDispatch` unless the instance identity says the launcher pool minted
       it -- and `IpcRequestMethod` already carries two exhaustive switches whose
       whole purpose is that a new method must classify itself or fail to
       compile. A remote-caller classification is that same shape and gets that
       same guarantee. A bridge classifies JSON-RPC method *strings* it does not
       own, so adding a method to the enum forces no decision there and the
       method's remote status silently defaults to whatever the bridge does with
       names it has never seen.
    2. *A bridge that enforces anything stops being a proxy.* F5's bridge is a
       byte splice on purpose, and F5 recorded the price of making it act per
       record: a record can reach the 16 MiB IPC line bound, so a bridge that
       parses to allowlist must buffer whole records, and it grows a second copy
       of the framing, the method catalog, and the version skew T24 owns.
    3. *The audit log needs facts a proxy does not have.* F8's requirements are
       method, pane, outcome, and caller. A byte proxy sees a frame length. The
       app sees the request, the model, and the reply.
  - **What the bridge is genuinely better at, stated so the trade is visible.**
    It has an independent lifecycle: it can be restarted or killed without
    touching the GUI app, it runs under launchd, and a crash in network handling
    does not take the user's terminal down. That is real and this decision gives
    it up. It loses anyway, because the crash-isolation benefit is small next to
    the drift defect above, and because the *security* argument for it is empty:
    the bridge holds full authority over the app by construction, so anything
    that compromises the bridge has already won. It is a hop, not a boundary.
    "The app's Unix-socket security model stays untouched" is a slogan of the
    same kind -- F8 established that the model is "whoever opens the socket may
    run commands as the user", and a bridge hands exactly that to the network
    from a different pid.
  - **Where the pieces live.** The listener is a sibling of
    `ControlSocketListener` in `DanTermSupport`, which is the Mac host's
    side-effect layer and already owns socket lifetime. `TailnetBindAddress` is
    adopted as-is, because it is the precondition of the whole identity argument
    rather than a prototype artifact: peer addresses are only WireGuard-authentic
    on the tailnet interface, so a listener that could also accept a LAN
    connection would silently downgrade an identity check into trusting a source
    IP. Keeping the type's shape -- no public initializer, so holding the value
    is the proof the check ran -- is the point of adopting it. Caller identity
    then travels *with the request* into the pure core, not through `CoreEnv`:
    it is per-request rather than ambient, so the message carries it and
    `IpcDispatch` decides on it, which keeps the whole authorization rule unit
    testable with no socket.
  - **The remote-method classification is for attribution and availability, and
    it is not containment.** F8 is explicit that a surface including `pane.input`
    is equivalent to a shell, so refusing `tab.new --cmd` remotely would be
    theater. What the classification actually buys is that a new method must
    decide, and that `quit` is refused for remote callers: a phone that ends the
    app cannot start it again, so that one request destroys the client's own
    access until the user is back at the Mac. Every other method is recoverable
    from the phone. The classification axis is authority, not product scope --
    which resolves the tension the ledger records: D1's "the client never calls
    todo methods" stays a client-side convention and is *not* promoted to an
    enforced rule, because a todo method is not dangerous and an allowlist keyed
    on what the phone happens to use would need editing every time the client
    grows a feature.
  - **A request-rate limit is declined; a concurrent-connection cap is
    required.** With an explicit admitted-node list there is no anonymous caller
    to throttle, and F5 recorded that latency is the phone's dominant variable,
    so an unmeasured limiter on the interactive path is a cost with no matching
    threat. The bound that does exist is not about request rate at all: F8
    measured that 64 idle connections make the app deaf to new ones while
    established conversations keep answering, because each connection parks a
    worker in a blocking read. That is a real denial of service, it needs no
    valid request, and its shape is the worst one for this product -- it denies
    reconnect, which is what a phone does constantly. So the listener caps
    concurrent connections well below the pool, refuses past the cap with a
    stated error instead of accepting and never reading, and the refusal is
    audited. Fixing the thread-per-connection reader itself is the ideal and is
    the better repair; it is not this decision's to make, and the cap is stated
    as a bound that must hold however the reader is implemented.
  - **2026-08-14 audit amendment: request accounting replaces PTY byte
    accounting for `pane.input`.** F8 called for a byte count, but the PTY byte
    stream exists only after the owner reads live modes and encodes the request.
    Crossing back to fetch it would weaken the owner-side atomicity D8 protects.
    The durable record therefore counts UTF-8 bytes for the request's text form,
    or events for its events form. It never records text, character keys, key
    names, or encoded PTY bytes. Key identity is content, so logging names would
    turn the stated blind spot into a keylogger. This amendment supersedes F8's
    PTY-byte wording without changing its privacy requirement.
- What this declines, knowingly:
  - **Reachability without Tailscale.** The client cannot be used from a network
    the phone has not joined to the tailnet, and Tailscale becomes a hard
    dependency of the product rather than a convenient default. This is the real
    cost of letting the transport carry the identity: there is no fallback
    credential, so an outage of the coordination server is an outage of the
    feature. Accepted because the alternative is maintaining a second credential
    system full time to cover a case the user does not have.
  - **Crash isolation of network handling**, given up with the bridge, as above.
  - **Defense against a compromised admitted device.** A phone that is unlocked
    by someone else has a shell on the Mac. Nothing in this decision changes
    that, and no application-layer credential would have; the mitigations are
    the phone's own lock and the ability to revoke a node.
  - **Any claim that the audit log prevents something.** It is for
    reconstruction after the fact, and F8's deliberate blind spot on
    `pane.input` content means it will never show what was typed.
- What would reopen it:
  - **Any listener that binds something other than a tailnet address** -- a LAN
    address, a public address, or a relay in the middle. Then nothing
    authenticates the peer, `TailnetBindAddress` cannot be constructed, and TLS
    with pinning becomes mandatory rather than declined. This is the single
    condition that flips the TLS answer.
  - **A second human on the tailnet**, or a shared node from another tailnet.
    The admitted-node list already narrows this, but an identity model that
    assumes one owner would need re-examining rather than re-tuning.
  - **A remote consumer that must run while the app does not.** The bridge is
    not that -- it proxies into the app and is useless without it -- but a
    genuine headless component would reopen placement.
- Consequences for other tasks, recorded here because this decision moves them:
  - **T15's APNs sender moves into the app.** The ledger specifies it in the
    bridge; there is no bridge. This is the easier home anyway, because the
    34/D2 activity transitions the sender consumes are app-side model events that
    a separate process would have to subscribe to over IPC to relay.
  - **`t5-bridge/` is throwaway evidence and stays that way.** Under this doc's
    rules a spike is deleted once the gate it feeds has chosen, and this gate has
    chosen against the shape the spike prototyped. `TailnetBindAddress` is the
    one part adopted, by re-implementation in `DanTermSupport` rather than by
    moving the file, and F5's measurements stand on their own. Deleting the
    directory belongs with whoever implements the listener, so the evidence
    survives until it is replaced.
  - **H4 is settled and narrowed.** Its "TCP+TLS listener" wording is overruled
    on TLS, and its "bridge process" wording is overruled on placement. What
    survives, confirmed by F5, is the part that mattered: a TCP listener reached
    over Tailscale yields a session that survives real phone mobility.
  - **T24's handshake gains a second job.** The hello handshake is where a
    version field lands, and it is also the first place a rejected node learns it
    was rejected. T24 should decide the refusal shape at the same time, so a
    client can tell "you are not admitted" from "your version is wrong" from
    "the Mac is asleep".

### D5 -- durable subscriptions: state sync as tape bytes, and cursor resume

- Status: decided 2026-08-12, from F4. **Implemented and on master**
  2026-08-13, across `dd96996b`, `737c99c2`, `46a2da45`, and `fb1f0b0f`. What
  shipped is recorded at the end of this entry, including the four contract
  points the implementation settled that this decision did not anticipate.
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
- Selected direction: (2), delivered as `sync` records in the tape stream plus a
  one-shot method returning the same payload, with tape requests able to supply
  a start cursor. Both are plural: implementation established that one record
  cannot hold a full pane's history, so a sync is a contiguous multi-record
  prefix and the one-shot method is a bounded stream rather than a single
  reply.
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
- Plan: `plans/impl/2026-08-13-1942-pane-snapshot-and-tape-resume.md`.
- **What shipped, and the four contract points this decision did not
  anticipate.** All four were found by review or by implementation, and each one
  changes what a client must do, so they are recorded here rather than left in a
  historical plan.
  1. **A sync is a multi-record indivisible prefix, and it is all-or-nothing.**
     The engine's scrollback budget and the IPC line bound are both 16 MiB, so a
     full pane's encoded history cannot fit one line and a single-record
     transfer would silently drop history the source still holds. The records
     are contiguous, no recorded event is delivered between them, and the
     producer withholds the fence cursor until the last record completes the
     transfer. A reader applies a sync only when it is complete, so a stream cut
     partway leaves its terminal untouched and still exactly at its previous
     cursor. Recovery is then ordinary resume, with no separate retry route --
     which is what stops a reader that applied half a reset-and-repaint payload
     from being at no position at all.
  2. **The inactive alternate screen is excluded from the transferred state.**
     The engine blanks the alternate grid on every entry, so no byte stream can
     ever reveal what a retained inactive alternate screen holds. Carrying it
     would cost a full extra screen on every sync of any pane that has run a
     full-screen program, to reproduce state nothing can observe. The primary
     screen retained *under* an active alternate screen is the opposite case and
     is carried, because exiting the alternate screen reveals it.
  3. **Unfinished input-stream state is part of the payload.** A fence lands
     between two recorded byte chunks and nothing makes that boundary fall in
     ground state, so the transfer carries a partial UTF-8 scalar and a sequence
     the absorber has begun but not dispatched, with its parameters,
     intermediates, and collected payload. Without this a sync silently corrupts
     the first bytes delivered after it.
  4. **A cursor is meaningful only to the recorder lifetime that minted it.**
     Every published cursor carries that identity and a supplied cursor carries
     it back, so a stale cursor from a previous recorder is detected rather than
     placed in a sequence space where it means something else. The gap record
     grew a total-loss form for this case, because per-direction counts do not
     exist against a cursor the producer cannot place, and inventing them in
     exact fields would be worse than saying so.
- Surface as shipped: stream version 3, `pane.snapshot`, structured start and
  mode parameters across the IPC, CLI, and client boundaries, and a raw mode
  that keeps delivering retained evidence for the debugging dump while
  reconstructible readers get exact state.

### D6 -- geometry: claim is a gesture, not a lock

- Status: decided 2026-08-13, brainstormed with the user. This is the T10 gate.
  It decides the model and stages the build-out; nothing is implemented by this
  entry, and implementation graduates to a plan under milestone 1.
- Evidence used:
  - [f4-mac-to-mac.md](f4-mac-to-mac.md), the geometry runs in full: stream
    geometry is unconditional and authoritative (`geometry`), local reflow
    after applying it works (`reflow`), and a differently-sized client that
    ignores the stream's resize renders wide output as interleaved garbage.
    These kill every model in which a client quietly renders at its own size,
    and they are why this decision starts from "the pane has one size" rather
    than negotiating one.
  - F5's mobility result: the connection survived a wifi-to-cell-to-wifi
    switch *without reconnecting* and dies on backgrounding, so "the phone
    detached" is not a crisp event. This is the load-bearing argument against
    stored ownership: a stored claim needs a release rule, every release rule
    needs a detach event, and there is no detach event -- any timeout is wrong
    in one direction or the other.
  - F7's smoke: the phone scaled the whole 179x66 frame by 0.293 to fit its
    screen. Legible as proof, unusable as product; the status quo this
    replaces.
  - D3's invariant, which this decision is checked against: the client
    originates no authoritative state. A claimed resize enters through the
    control surface and returns as an ordinary authoritative resize event --
    the exact shape D3 named when it narrowed "originates nothing".
  - D5's fence: a sync is an indivisible multi-record prefix and the stream
    continues at the sync's own fence, so a resize landing mid-sync is
    delivered after the sync completes. State transfer needs nothing new from
    this decision.
  - Read directly: `references/tmux/resize.c#default_window_size` and
    `references/tmux/server-client.c#server_client_update_latest`. tmux's
    `window-size latest` sizes a window to its most recently active client --
    a keypress or a client resize marks the client latest -- with no lock, no
    release protocol, and no liveness tracking. Precedent that the no-lock
    shape survives daily use; viability evidence, not a rationale.
  - `lib/DanTermProtocol/Sources/DanTermProtocol/IpcRequest.swift`: no resize
    method exists today. The Mac layout is currently the only writer of pane
    geometry.
- Candidate solutions:
  1. A per-pane mode dial: *observe* vs *claim*, selectable per pane. The
     ledger's original framing.
  2. Stored ownership: a pane has exactly one owner; the iOS app shows each
     pane as owned by someone else; a claim button transfers ownership and
     resizes; detach releases it. The user's starting idea.
  3. Claim as a gesture over unchanged geometry: the pane keeps a single
     authoritative size with last-writer-wins resize events; "claimed" is not
     stored anywhere -- every client renders in one of two modes decided by a
     local predicate (*native* when its surface matches the pane size,
     *remote-sized* otherwise); claiming is an explicit gesture that sends the
     client's size as a resize; the anti-clobber mechanism, added only when
     use shows it is needed, is descriptive origin metadata on resize events,
     not a lock.
- Selected direction: (3).
- Decision and rationale:
  - **Ownership's one load-bearing job is suppressing incidental clobbers** --
    the Mac window dragged for an unrelated reason must not snap a
    deliberately phone-sized pane back mid-session. Everything else stored
    ownership adds is cost, and the costs are exactly T10's hard parts: a
    release protocol against a detach that F5 shows is not crisp, a stuck
    claim when the holder is neither present nor gone, and an arbitration
    rule for two claimers. Origin-tagged resizes do the one real job without
    liveness: a client suppresses its *incidental* (layout-driven) resizes
    for a pane whose current size origin is another client, until a direct
    interaction with that pane reasserts. Origin is metadata on an event the
    stream already carries, derivable by every replica -- no new
    authoritative store, so it passes D3's derivability sentence.
  - **Detach dissolves instead of being answered.** An absent phone leaves a
    size behind; recovery is one gesture at the Mac, which is the natural
    act when the user walks back to that machine. Auto-take-back when T9's
    lifecycle work gives the Mac a provable "that client is gone" becomes an
    optional policy knob, not a correctness requirement.
  - **The Mac window is just another client.** While the pane's size differs
    from its layout slot, the Mac renders remote-sized -- the small grid
    letterboxed in the slot with a take-back affordance -- and the phone
    renders remote-sized while the pane is Mac-sized. One rendering concept,
    implemented on both ends; the observe/claim dial disappears into the
    predicate.
  - **Two claimers self-heal.** Last writer wins, as everywhere in this doc,
    and it is *less* bad here than usual: the loser does not render garbage,
    its predicate flips to remote-sized and its UI shows who has the size and
    the claim affordance. No arbitration protocol exists because no lock
    exists.
  - **The fence needs nothing new.** A claim is a resize entering through the
    control surface; D5 already orders events against a sync's fence, so a
    claim landing mid-sync is delivered after the sync completes and applies
    to a replica that has already reached the fence state.
  - **Ownership does not govern input, because ownership does not exist.**
    Input stays orthogonal and T11 is untouched. The one named interaction:
    quick-replying to an agent pane from the phone must not reformat the pane
    the agent's TUI is drawn in, so *typing never claims* -- but that is
    client policy over `pane.input` plus `pane.resize`, not input semantics,
    and T11 remains free to place encoding wherever its race and ordering
    arguments land. tmux chose the opposite policy (a keypress marks latest);
    flipping to it later is a client change with no protocol consequence.
  - **The protocol layer never encodes a UX opinion, which is what keeps the
    staged build-out safe.** Every contested fork -- does typing claim, what
    reasserts at the Mac, scale vs reflow -- lives in client policy over two
    policy-free primitives. The stages, each motivated by use rather than
    speculation:
    1. *Remote-sized rendering on the phone, observe only.* Apply the
       stream's geometry (mandatory in every world), render scaled to fit,
       type freely. No new protocol, no Mac-side work, and groundwork no
       later stage deletes: even with claim, the phone renders remote-sized
       between joining and claiming and after any Mac take-back. This is the
       supervision milestone becoming usable, which is when the fork opinions
       become real.
    2. *`pane.resize` as a plain control method.* No semantics attached; the
       claim button calls it, and it is a general CLI verb (`danterm pane
       resize`) useful for headless geometry reproduction regardless of the
       phone. The new Mac work is rendering a pane smaller than its slot:
       v1 is the grid top-left with blank surround and no affordance, and
       take-back is crude and free -- any Mac layout event reasserts, because
       nothing suppresses it yet. "Claim survives until the Mac's layout next
       fires" is v1 behavior, not a bug.
    3. *Origin metadata on resize events*, only if stage-2 use shows the
       incidental clobber hurts: the suppression rule above plus the "sized
       by iPhone -- click to take back" affordance.
    4. *Client-local polish*, each revisable by living with it: hybrid
       observe rendering (reflow the primary screen, scale the alternate
       screen -- the alternate-screen flag is replicated state the phone
       already holds), auto-take-back on T9's death signal, typing-claims if
       the explicit gesture proves to be friction.
- What this declines, knowingly:
  - **Tenure.** There is no moment where the phone *has* the pane: a Mac
    take-back mid-vim silently drops the phone to remote-sized. With one
    human across both devices this is a feature -- the user is always the
    winner -- and it is the first thing a second human breaks.
  - **Stored ownership as a concept**, declined but not foreclosed: a lock
    would layer above these primitives without replacing them, so choosing
    the gesture model now costs nothing if ownership is ever really needed.
  - **Full-screen fidelity in observe.** Reflow cannot help a program drawing
    at absolute coordinates; vim on an unclaimed pane stays a scaled
    179-column screen. Claiming is the designed answer for that case, not a
    gap this decision failed to see (F4's reflow cost statement).
- What would reopen it:
  - **A second human sharing panes.** Last-writer-wins arbitration is
    acceptable exactly because both writers are the same person; two humans
    need tenure, which means stored ownership layered above the primitives.
  - **Origin suppression proving insufficient in use** -- if direct Mac
    interaction reasserting turns out to be wrong too, the model is
    misdescribing how the user wants take-back to feel, and the stored-state
    arm gets re-examined rather than re-tuned.
- Consequences for other tasks:
  - **T11 is untouched** and inherits one named constraint from the policy
    default: typing never claims, so the input surface must not couple
    keystrokes to geometry.
  - **T9's connection-death signal gains an optional consumer** -- the
    auto-take-back knob -- which is policy, not lifecycle correctness, so it
    adds no requirement to T9.
  - **Implementation surface, when a plan picks this up:** the `pane.resize`
    method and CLI verb (with the `integrations/danterm/SKILL.md` update in
    the same change, per AGENTS.md), Mac remote-sized rendering, and later
    the origin field on resize events. None of it belongs to this research
    doc's phases; it lands with milestone-1 client work.

### D8 -- input: the wire carries intent, and the PTY owner encodes

- Status: decided and implemented 2026-08-14, brainstormed with the user fork
  by fork. This closes the T11 gate. The shipped wire and CLI changes are the
  milestone-1 Mac input surface; the iOS client remains separate work.
- Evidence used:
  - Read directly, and this is the decisive evidence -- the tree already
    implements one of the two candidate positions for every existing writer:
    - `lib/TerminalCore/Sources/TerminalCore/TerminalInputEncoding.swift#encodeTerminalKey`
      is a pure function -- semantic key, modifiers, and a mode snapshot in,
      bytes out -- covering SS3-vs-CSI cursor keys, application keypad, LNM,
      and the kitty protocol. `TerminalCore` is iOS-pinned, so both ends hold
      the same encoder; the question was only which end's modes feed it.
    - `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#sendKey`
      states the invariant in its doc comment: mode read, encoding, viewport
      snap, and write stay atomic on the owner queue.
    - `app/SwiftTerminalSessionView.swift#keyDown`: the Mac's own keyboard
      encodes nothing. It normalizes the NSEvent to a semantic key and sends
      it down the same funnel the CLI and agents use.
    - The same file's `sendText`: the top-level `text` field of `pane.input`
      is contractually the paste path, with owner-side safe-paste policy and
      bracket markers from live modes; a `.text` token among key events is
      deliberately raw so full-screen programs see characters as typed.
  - F4's payload floor item 5 -- "a client encodes keystrokes from its own
    `inputModes`, which is what a real client must do" -- the recorded
    position this decision overrules.
  - F7: modes replicate to the phone live. Named because it makes client-side
    encoding look workable; staleness is why it is not.
  - D3's limit statement: the invariant places state and does not resolve
    races, so this race is T11's to decide. D5's deferred input-direction
    rule: only the PTY-owning engine answers queries.
- Candidate solutions:
  1. The client encodes from its own replicated `inputModes` and sends bytes.
     F4's position.
  2. The wire carries semantic intent -- text runs, named keys with
     modifiers, paste, wheel -- and the PTY-owning engine encodes atomically
     with the mode read. The shipped shape.
- Selected direction: (2). The phone is the fifth writer through the funnel
  the Mac GUI, the CLI, and agents already use.
- Decision and rationale:
  - **Wrong bytes are worse than a wrong target.** Both positions share the
    same timing hazard: a program can exit inside the round trip. Under (1)
    the phone sends bytes encoded for dead modes and the receiving program
    gets garbage. Under (2) the intent is encoded against whatever modes are
    live on arrival -- the keystroke may land in a different program than the
    user aimed at, which no design can prevent, but the bytes are always
    valid for the program that receives them.
  - **Atomicity is unreachable from the phone even in principle.** The owner
    encodes inside the same critical section that reads the modes. The
    client's mode snapshot is one round trip old at best; F7's "modes track
    live" is a latency observation, not a fence.
  - **It is the same rule D5 deferred, facing the other way.** Only the
    PTY-owning engine answers queries; only the PTY-owning engine produces
    PTY-bound bytes. One consequence travels free: the kitty keyboard
    protocol stays an owner-side encoding detail, and the client never needs
    the flags to type correctly.
  - **The steelman for (1), and why it loses.** Client-side encoding frees
    the client from the wire grammar's completeness: any byte sequence is
    typeable, and no gap waits on a protocol change. That cost is real under
    (2) -- the gap list below is exactly that bill coming due -- but it is
    recoverable: the grammar extends, and a raw-bytes form for
    mode-*independent* sequences could be added later without inheriting the
    race, because the race lives only in mode-dependent encodings. Adopting
    (1) bakes the race in permanently.
  - **F4's payload floor item 5 is overruled**, and the ledger's contradiction
    is closed. It described how standalone terminals work, not how DanTerm's
    writers work: no existing writer encodes locally.
  - **What does not change either way, stated so it is not re-argued:** echo
    latency, because the echo always returns through the tape stream from
    the PTY; and predictive local echo, because a prediction is a speculative
    application of the replica's own modes, reconciled against the stream --
    it is not an encoding, and D5's mode floor in the sync payload stays load
    bearing under (2) for exactly that use.
- The gap list -- what the wire grammar cannot express today, and what closes
  each gap. This is T11's itemization obligation, checked against
  `TerminalInputKey` and the accessory row (Esc, Ctrl, Tab, arrows, pipe,
  tilde, slash):
  1. **Ctrl over non-letters is inexpressible**: `C-\` (SIGQUIT), `C-[`,
     `C-]`, `C-^`, `C-_`, and `C-Space`, which the token classifier throws on
     by design. The engine's `TerminalInputKey.character` already encodes all
     of them; the gap is only in the wire enum. Close it by **widening
     `InputEvent`** with one case -- a character plus modifiers -- rather
     than adopting `TerminalInputKey` as the wire form: the engine type drags
     seventeen keypad cases onto the wire, and coupling the protocol to an
     engine type makes an engine refactor a wire change, which is the exact
     coupling D5 rejected for state.
  2. **The new case requires at least one modifier.** Without that rule the
     same keystroke has two wire spellings -- `{"text": "a"}` and
     `{"key": "a", "mods": []}` -- that must produce identical bytes in every
     mode forever, which is a standing invitation to quiet disagreement.
     One spelling per keystroke: plain characters are text; the key case
     exists for modifier combos. An empty-modifier key form is a parse error.
  3. **`Insert` exists in the engine and not on the wire.** Added with the
     widening; trivial.
  4. **Mouse has no wire form at all, and wheel is milestone-1 scope.**
     Scrolling splits by screen: on the primary screen the phone scrolls its
     own replica scrollback locally, free, no wire change; on the alternate
     screen (`less`, vim, htop) there is no scrollback and scrolling *is*
     wheel events, so without a wire form the phone cannot scroll a pager at
     all -- a known-broken case, and touch-scroll is the phone's most natural
     gesture. The wire gains wheel up/down at a cell; the owner's existing
     mode gating applies on arrival, like keys. Click, drag, and motion wait
     until real use asks for them. One client-policy rule travels with this,
     same flavor as D6's predicate and derived from replicated state: a
     scroll gesture moves the replica viewport while the alternate screen is
     off, and sends wheel events while it is on.
  5. **The accessory row needs nothing else.** Pipe, tilde, and slash are
     text; Esc, Tab, and arrows exist; Ctrl as a latching modifier is client
     UI with no wire presence. Shift+letter stays rejected -- shifted letters
     are text.
- Deferred: **focus reports move to T9**, with the expected shape recorded so
  it is not re-derived. Today a pane's focus-in/out report follows the Mac
  view's keyboard focus, so a phone driving a pane whose Mac window is
  backgrounded types into a program that was told nobody is looking. The
  expected answer is "focused means anyone is engaged" -- Mac view focus or
  an engaged remote client -- but "engaged" is a lifecycle fact (foreground,
  background, connection death) that T9 owns and has not established. Doing
  nothing fails mildly (a late autoread, a dim prompt), the reports are
  generated Mac-side, and the fix is a policy change rather than a wire
  change, so nothing in milestone 1 blocks on it.
- What this declines, knowingly: byte-exact client freedom. Under (2) an
  input the grammar cannot name cannot be typed remotely until the grammar
  grows. The gap list above is believed complete against the engine's own
  encoder; what it cannot cover is a future input class that is both
  mode-dependent and impossible to name semantically. That class is the one
  thing that would force the escape-hatch design to be weighed against the
  race rather than added casually, and it is this decision's reopen
  condition.
- Consequences for other tasks:
  - The CLI token grammar grows with the wire (`C-\`, `C-Space`, and
    friends stop throwing), and the `integrations/danterm/SKILL.md` update
    lands in the same change, per AGENTS.md.
  - T9 inherits the focus-report question with its expected shape.
  - D6 is untouched: typing never claims is a client policy over
    `pane.input` plus `pane.resize`, and nothing here couples keystrokes to
    geometry.

### D9 -- handshake policy: protocol-hard, app-soft

- Status: decided and implemented 2026-08-14. This closes T24.
- Selected direction: the server-first hello keeps its protocol number and app
  version. A client refuses an unsupported protocol number, but accepts and
  surfaces a different app version so the UI can warn without blocking use.
  Admission failures use a separate `rejected` notification with stable reasons
  for not admitted, unresolved identity, connection capacity, and unavailable
  audit storage.
- Rejected direction: strict app-version equality. Mac and TestFlight upgrades
  are not atomic, and a dev build routinely differs from the phone build. An
  app version is release identity, not an honest version of terminal behavior,
  so strict equality would reject normal skew without proving compatibility.
- Reopen condition: observed app-version skew causes a behavioral failure that
  the protocol number cannot distinguish. That evidence must define the missing
  compatibility boundary before another hard version field is added.
