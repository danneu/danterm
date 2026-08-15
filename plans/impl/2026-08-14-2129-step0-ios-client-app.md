# Milestone-1 iOS side: the step-0 client app

## Problem and desired outcome

Milestone 1 of the iOS remote client (research/35, D1) is a pane on the phone
the user genuinely types into, rendered by the real engine. The Mac side is
fully landed and live-verified: the tailnet listener with admission and audit
(D4), the handshake refusal shapes (D9), the widened input grammar with
owner-side encoding (D8), and a CLI TCP transport in `lib/DanTermClient`.
Nothing iOS exists in the tree as product code: the on-device evidence lives in
the throwaway `ios-render-spike`, which research rules say is adopted by
re-implementation, never by moving files.

This plan is the step-0 iOS client app: a UIKit app that connects to the Mac
over the tailnet, lists tabs and panes, subscribes to one pane, drives a
replica `TerminalCore` engine from the D5 sync-and-tape stream, presents it
through the D2 swapchain, and sends input as D8 intent. Done means the user
has typed into a live pane from their iPhone over the real tailnet (user
decision: the device smoke is part of this plan's acceptance).

Load-bearing premises taken from the tree and the research record, not
re-derived here:

- The client conversation layer is shipped in `lib/DanTermClient`: the
  transport seam and its TCP conformance, `DanTermClientSession` (handshake,
  typed refusals, reply correlation, notification delivery), and the pane-tape
  record reader with the D5 sync assembler (multi-record indivisible sync,
  fence cursor on the last part, gap records including total loss, cursor
  bound to a recorder lifetime). The session surface is pull-based and
  blocking; nothing in the module is thread-safe, and the TCP transport does
  not serialize concurrent writers.
- `pane.tape` is per-pane, takes follow/start/mode, and its reply is the
  stream's start record; subsequent records arrive as `pane.tape.event`
  notifications carrying a server-minted subscription id. Tape events decode
  to `NeutralTerminalRecordingEvent`; `DanTermClient` deliberately does not
  link the engine, so the app bridges the two.
- The replica discipline is proven on-device by research/35/F7: build a fresh
  `Terminal` at a sync's stated geometry, feed its bytes, and drain and
  discard reply bytes and clipboard writes -- a replica never answers
  queries. Feed, mouse, viewport, and resize events apply; write, input,
  paste, focus, and checkpoint events are ignored. Stream geometry is
  unconditional and authoritative (research/35/F4).
- `TerminalCore` (with `TerminalRenderPlanning`, `TerminalSpriteGeometry`,
  `TerminalRenderExecution`, `TerminalCoreRecording`), `DanTermProtocol`, and
  `DanTermClient` are iOS-pinned; `scripts/ios-portability-gate.sh`
  cross-compiles every target of every pinned manifest for the device triple,
  test targets included -- but it discovers manifests only at `Package.swift`
  and `lib/*/Package.swift`, so an `ios/` package is invisible to it today.
  `DanTermSupport` and `TerminalPTY` are the Mac host's layer and stay
  unpinned; the pane-session controller, damage gating, and fence pacing live
  there and are not available on iOS.
- The presentation contract is the client's to own (D2): render into a
  detached buffer, then attach; retry a coalesced publish on a later tick;
  never mutate an attached surface (F3: mutation presents indeterminately on
  device). The Mac view implements this contract for AppKit; no portable
  module does.
- Nerd Font glyphs resolve through a `Bundle.main` lookup, so the app bundle
  must carry the font or every PUA glyph renders as tofu; the spike's build
  script solved bundle assembly, signing, and install without an Xcode
  project.
- The tailnet listener is closed by default and admits explicit node ids; the
  config file is shared between the production app and every dev slot. The
  bind guard rejects loopback by design, so the development loop is the
  simulator connecting through the Mac's own tailnet address with the Mac's
  own node id admitted.
- `pane.input` replies complete asynchronously (the reply lands when every
  submission completes). The top-level `text` form is contractually the paste
  path (owner-side safe-paste and bracketing); a `text` token inside the
  events form is deliberately raw so full-screen programs see characters as
  typed (D8).
- The engine design register (docs/design/2026-08-06-swift-terminal-engine.md)
  scopes the engine to macOS in A1 and forbids periodic render work in
  L1/L3/L5; research/35 D2 records that a display link ticking through idle
  was most of the spike's measured energy.
- The `ls` reply carries groups, tabs, the split tree with panes as leaves,
  per-tab focused pane, and the selected tab; there is no push channel for
  layout or agent-activity changes -- a client polls.

## Decision

**A new `ios/` directory holds the app as two SwiftPM packages split on the
portability boundary.** A portable kit package carries everything that needs
no UIKit: connection and reconnect state, tape-stream application to the
replica engine, cursor tracking, input mapping to the D8 wire grammar, the
pane-list model derived from `ls`, and the presentation-retry policy as a
pure state machine. It is pinned for both macOS and iOS, so its tests run in
the ordinary Mac suite while the gate proves the iOS compile. A thin
UIKit shell package (iOS-only pin) owns views, `CADisplayLink`, gestures, the
keyboard, and the accessory row. The kit depends only on iOS-pinned packages
(`TerminalCore` products, `DanTermProtocol`, `DanTermClient`) -- never on
`DanTermSupport`, `TerminalPTY`, or `DanTermCore`. The step-0 client does not
link the `DanTermCore` model at all, leaving T12/D7 open rather than deciding
it by accident.

**The shell duplicates the Mac's presentation contract; extracting a shared
presenter is the named ideal, deferred by user decision.** The ideal is one
portable presenter both platforms consume, so presentation changes
(colorspace, scale, damage semantics) cannot diverge along a platform seam.
It is deferred because the Mac's half is entangled with the Mac-only pane
controller and paced by fences rather than a display link: the genuinely
common shape is only observable once a second implementation exists.
Extraction becomes the follow-on refactor once step 0 is in use; this plan
records it so the trade-off stays on the table (RI1).

**Presentation is damage-gated: an idle phone does no periodic render work.**
The display link runs only while there is unapplied stream input, undrained
damage, or a pending coalesced presentation; otherwise it is paused or
removed. This is the iOS restatement of the register's L1/L3 spirit and the
direct consequence of D2's energy finding.

**The replica is observe-only (D6 stage 1).** The phone adopts the stream's
geometry unconditionally and never originates a size: no `pane.resize` exists
on the wire and this plan defines none. It renders the remote grid at the
phone's full width and bottom-aligns it. When the keyboard leaves too little
height, the upper rows clip until the keyboard is dismissed; the grid does not
reflow or resize.

**Connection lifecycle: connect, list, subscribe, resume by cursor.** The app
persists a server target (host:port), connects with the shipped TCP
transport, performs the handshake, fetches `ls` on connect and on user
refresh (no periodic polling), and subscribes to one pane at a time with a
follow stream starting `now` in reconstructible mode. It tracks the newest
cursor continuously (start record, completed sync fence, applied events). The
connection dies on backgrounding by design, through I6's cancellation path
rather than by abandoning a blocked reader; on foreground return or explicit
retry the app reconnects and resumes from the stored cursor, and a gap or
total-loss-plus-sync reply is the designed recovery, surfaced rather than
rendered across. Automatic retry policy beyond this is T9's and is deferred.

**Input is D8 intent, and the two text paths keep their meanings.** Typed
characters travel as raw `text` tokens in the events form; a paste gesture
uses the top-level `text` field so owner-side safe-paste policy applies. The
accessory row (Esc, Ctrl as a latching modifier, Tab, arrows, pipe, tilde,
slash) and hardware-keyboard chords map to named keys and character-plus-
modifier events; the keyboard is configured for literal text (no
autocorrection, capitalization, or smart substitution). A scroll gesture
moves the replica's own viewport while the primary screen is active and sends
wheel events while the alternate screen is active -- the D8 client-policy
rule, decided on replicated state. No client-side encoding path exists.

**`lib/DanTermClient` gains an explicit long-lived-session concurrency and
teardown contract.** The phone is the first client that sends (input) while a
reader blocks in the tape stream, and the first that tears the session down
from another thread while that reader is still blocked -- today both are data
races the T23 spike papered over privately. The session layer serializes wire
writes so concurrent senders and one blocking reader are safe by contract, and
it defines cancellation: cancelling unblocks the reader, closes the descriptor
exactly once and only after every in-flight read and write has released it,
and fails a later send with a stated cancellation error. The doc comments say
so. This lands in the library because every future long-lived client
(Mac-to-Mac attach, T13) needs the same guarantee. Delivery lifetime is not
the library's to give -- it is synchronous and pull-based -- so the kit's
connection runner owns fencing UI delivery at teardown (I6).

**Build and verification are script-driven, no Xcode project (user
decision).** `scripts/ios-app.sh` builds the app for simulator or device,
assembles the bundle (Nerd Font and theme resources included), signs with the
existing development profile, and installs and launches -- re-implemented in
the spike's pattern. The portability gate's manifest discovery extends to
`ios/*/Package.swift`, so the new packages are enforced from the first
commit.

Behavioral scope:

- From the iPhone (and the simulator), over the tailnet: browse tabs and
  panes as a flat list, open one pane, watch it live at full engine fidelity
  (colors, wide characters, alternate screen), type into it, scroll it, and
  survive an app background/foreground cycle with an exact resume or an
  explicit gap.
- Refusals and failures are legible on the phone: each typed rejection
  reason, protocol mismatch, and transport failure presents as a distinct
  human-readable state.
- An idle, connected phone showing a quiet pane does no periodic render work.

Out of scope for this plan: everything under Non-goals below; no changes to
the Mac app, the wire protocol, or the CLI surface (`integrations/danterm/
SKILL.md` is untouched because no CLI surface changes).

## Invariants

- **I1 -- the replica derives and never originates.** The pane on the phone
  is a `TerminalCore` replica fed only by the D5 sync and following tape
  events. It never emits authoritative bytes: query replies and clipboard
  writes are drained and discarded, input leaves the phone only as D8 intent
  (`pane.input` text or events), and no client-side encoding path exists.
- **I2 -- observe-only geometry.** The replica adopts every stream geometry
  (initial, sync, resize events) unconditionally and the phone renders
  remote-sized. No code path requests, defines, or simulates a pane resize.
- **I3 -- state is exact or the gap is explicit.** Applied replica state is
  only ever a complete sync applied atomically at its stated geometry, or
  events applied in sequence order from a known cursor. A partial sync leaves
  the terminal and the stored cursor untouched. The newest cursor is
  persisted across reconnects, and any loss (gap or total-loss) is surfaced
  to the user, never silently rendered across.
- **I4 -- portability is compiler-enforced.** All connection, stream
  application, input mapping, pane-list, and presentation-policy logic lives
  in the kit package, which links no UIKit or AppKit, is tested headlessly in
  the Mac suite, and is cross-compiled for the device triple by the
  portability gate along with every other `ios/` target. The gate discovers
  `ios/*/Package.swift`; `DanTermSupport` stays unpinned.
- **I5 -- idle costs nothing, and attach-to-publish holds.** With no
  unapplied stream input, no undrained damage, and no pending presentation,
  the phone schedules no periodic render work. An attached surface is never
  mutated; a coalesced publish is retried on a later tick until it presents.
  Surface ownership is decided by the kit's presentation policy, not by the
  UIKit shell: the policy names which surface may be rendered into and which
  is attached, and the shell only obeys that answer. So the invariant is
  decidable in a headless test rather than only on a device.
- **I6 -- one session, safe concurrency and safe teardown.** Concurrent
  request sends against a session whose reader is blocked in `receive` are
  safe and produce well-formed frames on the wire, and frame consumption stays
  one thread's job (the delivered contract says so). Teardown is part of the
  same contract: cancelling a session unblocks an active receive, and the
  underlying descriptor is released exactly once, only after every in-flight
  transport operation -- reads and writes alike -- has stopped naming it. A
  send begun after cancellation fails with a stated cancellation error instead
  of touching a descriptor. The blocked read returns without producing a
  frame. This half lives in `lib/DanTermClient`, because backgrounding the
  phone tears down a session with a reader blocked mid-stream and a
  `pane.input` send possibly in flight, and every later long-lived client
  (T13) needs the same guarantee.
  The other half is the kit's: `DanTermClient` is synchronous and delivers
  nothing on its own, so the kit's connection runner owns UI-facing delivery
  and must finish or fence that path before cancellation returns to the shell.
  No frame, state change, or error reaches the shell after that point.
- **I7 -- failures and endings are legible.** Every failure and every ordinary
  end of service maps onto exactly one of these user-facing states, and the
  mapping is total -- there is no residual generic bucket and none of them
  reads as a hang:
  - **Host not found** -- the target name resolved to nothing.
  - **Server unreachable** -- resolved but refused, unreachable, or not
    answering in time.
  - **Refused by the Mac** -- one state per admission reason (node not
    admitted, identity unresolved, connection limit, audit unavailable),
    because each has its own remedy.
  - **Version mismatch** -- the Mac speaks a protocol number this app cannot.
  - **Connection lost** -- an established stream failed or the peer closed it
    mid-conversation.
  - **Device setup failure** -- the local socket could not be configured; a
    bug report, not a user action.
  - **Stream ended** -- a followed stream's end record, carrying its reason
    (such as the pane closing on the Mac).
  - **Request refused** -- an error reply, including a request-level audit
    refusal and a request against a pane that no longer exists, carrying the
    server's reason.
  Grouping several transport error cases under one of these states is
  intended: the states are the remedies the user has, not a mirror of the
  transport's error enum.

## Proof obligations

- **PO1 (I1, I3).** Headless kit tests drive the stream logic with scripted
  record sequences: a join with pending sync, mid-stream gap-plus-sync
  repair, a total-loss gap, and a sync cut off partway. Assert replica state
  (viewport text, input modes, alternate-screen flag, scrollback depth)
  against expectations, cursor progression at each step, and that the
  partial sync changed nothing. Assert the ignored event kinds (write,
  input, paste, focus, checkpoint) leave the replica untouched and that
  drained reply bytes are discarded. The gap scenarios assert the loss itself,
  not only the later convergence: a gap record moves the client into a
  distinct presented gap state on the record that carries it, and no event
  arriving after the gap changes presented replica state until a complete
  replacement sync applies.
- **PO2 (I3).** Reconnect round-trip: disconnect mid-stream, resume from the
  stored cursor against a producer that can place it (replayed events
  converge) and one that cannot (total gap plus fresh sync converges).
  Assertions land on state that does not self-heal -- scrollback depth and
  input modes, per D5's acceptance rule -- not on the visible screen. The
  unplaceable case also asserts the explicit gap state, on PO1's terms.
- **PO3 (I1).** Input mapping, pure: every accessory-row key and Ctrl combo
  produces its D8 wire event (character keys always carry a modifier; plain
  characters are text tokens); a paste maps to the top-level text form; a
  scroll maps to viewport navigation with the alternate screen off and wheel
  events with it on. The session's outbound requests are asserted, proving
  no other input-shaped traffic exists.
- **PO4 (I2).** A resize event mid-stream is adopted by the replica and the
  presentation follows the new grid; the outbound request log for the whole
  scenario contains no resize-shaped request.
- **PO5 (I4).** The portability gate discovers the `ios/` packages and fails
  when one of their targets stops building for the device triple, proven
  through the gate's fixture self-test; the kit's tests run (and pass) in the
  ordinary Mac suite.
- **PO6 (I5).** The presentation policy, tested as a state machine: no work
  is scheduled from the idle state; a coalesced publish schedules a retry and
  eventually attaches; going idle after the last attach stops the schedule.
  The same tests cover surface ownership, because the policy decides it: hold
  an attached surface across later damage and assert the policy names a
  detached surface as the render target before every successful attachment,
  including on the coalesced retry path, and never names the attached one.
- **PO7 (I6).** Against a loopback fixture, senders on other threads racing a
  blocked reader produce only well-framed, uninterleaved lines, and existing
  single-threaded client behavior is unchanged. Teardown is covered on the
  same fixture, and each half is tested at its owning layer. In
  `lib/DanTermClient`: cancelling while the reader is blocked in `receive`
  returns that reader promptly and without a frame; cancelling while a sender
  is mid-write leaves the descriptor closed exactly once, after that write has
  returned; a send begun after cancellation fails with the stated cancellation
  error; repeated cancellation is a no-op; and no read or write is attempted
  on a released descriptor. In the kit: cancelling the connection runner from
  the shell's backgrounding path delivers nothing to the shell after
  cancellation returns, including when a frame was already in hand.
- **PO8 (I7).** Connection-state reducer tests, table-driven over the whole
  failure surface: every scripted rejection reason, every public
  `TCPSocketTransportError` case, an unsupported protocol number, a
  request-level audit refusal, a followed stream's end record with a reason,
  and an error reply to a request against a vanished pane. Each row asserts
  the I7 state it must produce; the test fails if any input has no row or
  produces a state I7 does not name.
- **PO10 (pane list).** A headless projection test over an `ls` reply with
  nested split leaves, more than one tab, a selected tab, and a per-tab
  focused pane: every leaf pane appears exactly once, in the order the UI
  shows, carrying its tab, selected and focused state. Each AR4 title
  fallback (custom title, focused pane's title, running command) is covered.
- **PO9 (milestone acceptance -- live smoke, manual).** First on the
  simulator against a dev slot (config backed up and restored, Mac's own
  node id admitted, slot freed afterward): pane list renders, typing echoes
  in a live pane, vim enters and leaves the alternate screen correctly,
  representative Nerd Font PUA glyphs render as glyphs rather than tofu
  (proving the assembled bundle carries the font where `Bundle.main` finds
  it), and kill-and-relaunch resumes from the stored cursor. Then on the user's
  iPhone over the real tailnet: type into a live pane, background and
  foreground the app, and observe cursor-resume or an explicit gap. The
  device run closes the plan.

## Non-goals

- `pane.resize` and D6 stages 2-4 (claim, origin suppression, rendering
  polish).
- APNs and notification tap-through (T15); agent-activity push and
  multi-pane subscription scope (T22); the pane list shows no live activity.
- Reconnect lifecycle beyond foreground-return and manual retry with the D5
  cursor (T9: airplane-mode churn, automatic retry policy, distinguishing a
  refused reconnect from a dead network).
- The readiness-based connection reader on the Mac (deferred by the listener
  plan; unchanged here).
- Todo surface, splits rendered as splits, predictive local echo, theme and
  font preferences UI on the phone, TestFlight packaging, Mac-to-Mac
  `RemoteTerminalSession` (T13), and adopting `DanTermCore` on the phone
  (T12/D7 stays open).
- Focus-report semantics (deferred to T9 by D8).

## Accepted risks

- **AR1.** Both ends run the same engine code but skew in normal use
  (TestFlight later; dev builds now). D9's protocol-hard/app-soft policy
  applies: skew warns, and a behavioral failure under skew is T24's recorded
  reopen condition.
- **AR2.** Session-length battery on the phone is unmeasured (the research
  doc's own headline open question). Step 0 ships the damage-gated
  presentation policy (I5) and leaves measurement to later work rather than
  blocking the milestone on it.
- **AR3.** The device smoke may surface iOS network-permission friction
  (research/35/F7 saw a LAN connect fail as "No route to host" without the
  local-network entitlement; tailnet traffic through the VPN interface
  should not need it). If it bites, the fix is bundle metadata, not
  protocol.
- **AR4.** `ls` carries no computed tab title, so the phone derives display
  titles (custom title, else the focused pane's title or running command)
  and may diverge from the Mac's sidebar wording. Accepted for step 0.
- **AR5.** The simulator dev loop inherits the Mac-side posture: it needs
  this Mac's tailscaled variant (LocalAPI socket) and the shared config file
  edited on a dev slot with backup and restore.

## Rejected ideas

- **RI1.** Extracting the shared presenter before building the app (user
  decision; see Decision -- the ideal is recorded and deferred, not
  dropped).
- **RI2.** An Xcode project for the app (user decision: SwiftPM plus a build
  script, house style, agent-drivable; TestFlight packaging can be added
  later without redoing scaffolding).
- **RI3.** Moving spike sources into the product tree (research house rule:
  adopt by re-implementation; the spike stays evidence until deleted).
- **RI4.** A single dual-purpose package holding kit and shell together --
  the shell cannot build for macOS, which would evict the kit's tests from
  the Mac suite; the two-package split is what keeps I4 cheap.

## Deferred, with the reason

- **Shared presenter extraction** -- the named ideal; becomes tractable once
  the UIKit implementation exists beside the AppKit one and the common shape
  is observable, and should be weighed when presentation next changes.
- **`pane.resize` (D6 stage 2)** -- the first follow-on once observe-only is
  in daily use and the claim gesture earns its UI.
- **Deleting `ios-render-spike/` and its runner scripts** -- the app
  supersedes the spike's client-smoke role, but the spike also carries the
  F2/F3 presentation measurement modes that D2 cites; deletion belongs with
  the change that replaces or retires that measurement role, with docs-lint
  allow-missing markers when it happens.
- **Pane-switch sync cost** -- flipping panes splices a fresh sync whose
  history component is unbounded (T22's named open cost); step 0 accepts it
  for a one-pane-at-a-time UI and T20/T22 own the measurement.

## Deliverables

- `ios/` packages: the portable kit (dual-pinned, headless tests) and the
  UIKit shell app (iOS-pinned), named at implementation's discretion.
- `scripts/ios-portability-gate.sh` discovery extended to
  `ios/*/Package.swift`, with the fixture self-test covering the new root.
- `scripts/ios-app.sh`: build, bundle assembly (Nerd Font, theme resources),
  signing, install, and launch for simulator and device.
- `lib/DanTermClient`: the serialized-send and cancellation contract for
  long-lived sessions, and its tests.
- Docs: the engine register's A1 row amended to record the in-repo iOS
  client as a second consumer of the engine packages (the engine remains
  DanTerm-internal, not a public API), citing research/35 D3; the
  research/35 ledger updated to record the step-0 client as shipped
  milestone-1 work.

## Implementation discretion

- Package, target, and type names under `ios/`; UI layout and visual design;
  persisted-settings storage; timeout constants; display-link mechanics
  (pause versus add/remove) so long as I5's observable claim holds.
- Theme and font-size defaults on the phone (a bundled default theme and the
  system monospaced font; parity with the Mac pane's theme is future work).

## Commit progress

- [x] 1. Portable kit package and gate extension: connection/reconnect state,
      stream application to the replica, cursor tracking, input mapping,
      pane-list model, presentation policy -- all headless-tested -- plus
      `ios/*/Package.swift` gate discovery and its fixture self-test.
      (PO1-PO6 for the kit-side halves, PO5, PO8, PO10)
- [x] 2. `lib/DanTermClient` serialized-send and cancellation contract for
      long-lived sessions, then the kit's connection-runner delivery fence on
      top of it. (PO7)
- [x] 3. UIKit shell, `scripts/ios-app.sh`, and the simulator smoke against a
      dev slot. (PO6 shell wiring, PO9 simulator half)
- [x] 4. Device smoke and its UIKit presentation fixes on the user's iPhone,
      then the docs closeout: A1 amendment and research/35 ledger update.
      (PO9 device half)

## Implementation notes

- The pane-list projection treats the default `Terminal` pane title as absent
  when a running command exists. A custom title or a non-default focused-pane
  title still wins. This makes AR4's running-command fallback reachable without
  changing the Mac's `ls` reply.
- The connection runner enqueues shell events on an injected serial queue that
  defaults to the main queue. Each queued callback rechecks the cancellation
  fence, so a frame already read cannot become a UIKit update after background
  cancellation returns.
- Cursor-only persistence cannot restore exact terminal state after process
  death. The kit therefore archives the last complete synchronization plus the
  later neutral events and its cursor. The shell coalesces archive writes and
  restores that exact state before it requests continuation from the cursor.
- The physical-device smoke showed that uniform aspect-fit made the terminal
  shrink horizontally while the keyboard was visible. The user chose
  full-width, bottom-aligned presentation with temporary upper-row clipping so
  typed output stays readable without changing the authoritative remote grid.
- The 2026-08-15 device smoke used Pelucho over Tailscale through DERP `dfw`.
  The shipped listener admitted the phone's stable node id, the app connected
  to DanTerm 0.1.9, and `pane read` confirmed input sent from the phone in the
  exact source pane. Backgrounding for five seconds and reopening reconnected
  and retained the command output. The shared config was restored after each
  isolated-slot launch.
- The final build was installed over CoreDevice on the home LAN. Pelucho
  confirmed the full-width terminal, compact one-line key row, readable target
  controls, and keyboard dismissal with the software keyboard open.

## Follow Up

- `ios/DanTermMobileKit/Sources/DanTermMobileKit/PaneReplica.swift`: replace the
  replay-suffix archive with a compact portable terminal checkpoint when
  `TerminalCore` gains state serialization. The current archive grows with the
  events received after its last complete synchronization.
