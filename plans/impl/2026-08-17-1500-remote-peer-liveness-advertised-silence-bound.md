# Peer liveness for remote connections: one advertised silence bound

## Problem and desired outcome

Neither end of a tailnet connection can learn that the other is gone
(research/35/F9, measured on hardware):

- Airplane mode: the Mac holds the connection `ESTABLISHED` indefinitely,
  writes no audit event, and keeps one of its eight remote slots; the phone
  reads "Connected" for the whole outage. Reclamation happened only because
  the phone's own TCP stack reset the socket when the network returned; a
  phone that never returns (flat battery, out of range overnight) leaks the
  slot forever, against a cap of 8 of which a cold start transiently uses 2.
- A Mac made deaf by worker-pool starvation (research/35/F8) admits a
  connection, delivers hello, and never reads the client's first request; the
  client's transport is built with no receive timeout, so "Connecting" is
  unbounded by construction.
- The audit log records such a connection as admitted (`connectionOpened`)
  with nothing to distinguish "served" from "never read".

These are one gap, not two: both ends lack the same fact -- whether the peer
is still there -- and no `SO_KEEPALIVE`, heartbeat, idle timeout, or receive
deadline exists anywhere in the tree. Two independently tuned timeouts (a
client receive timeout here, a server idle timeout there) could disagree
about the same connection; the desired outcome is one shared rule both ends
apply.

Desired outcome: the Mac reclaims a dead peer's slot within a stated bound
and audits why; the phone leaves "Connected" and "Connecting" within the same
order of time and presents states its vocabulary already names; a
quiet-but-alive peer is never reclaimed; the audit log can distinguish an
admitted-and-never-serviced connection.

Load-bearing premises, from the tree and the research record:

- Server close detection is solely the per-connection blocking read
  returning; the tailnet accept path sets only `TCP_NODELAY` and
  `SO_NOSIGPIPE`. Remote slots are released only via the read loop's close
  callback, which is also what writes the `connectionClosed` audit event.
- The client conversation layer (`lib/DanTermClient`) is shared by the phone
  and the CLI's TCP transport. Its session contract already permits
  concurrent sends while one thread blocks reading, and its transports
  already support per-receive-call timeouts (`SO_RCVTIMEO`) -- passed as nil
  today on the phone's session path and on CLI tape-follows.
- The shipped iOS client's failure vocabulary is total over errors: every
  failure maps onto exactly one user-facing state, none reads as a hang, and
  it already names "Server unreachable (not answering in time)" and
  "Connection lost". The two silent cases are the only inputs with no
  mapping -- today they present as the wrong state, which is worse than a
  missing one.
- research/35/F5: mobility stalls on a connection that survives measured
  4.3-6.4s; cellular round trips p50 80ms.
- D4 (docs/research/35-ios-remote-client/decisions.md): audit is
  write-ahead, every remote request is recorded, the connection cap is 8.
  This plan amends D4's audit wording (below) rather than replacing it.

## Decision

**One liveness contract for remote connections, owned by the server and
advertised in hello.**

- The server defines a single silence bound -- default 30 seconds -- and
  advertises it in the hello it already sends first. Both ends apply the
  advertised bound, so the constant lives in one binary and cannot skew
  across independently shipped builds.
- Silence is byte-level: the bound measures time since any byte arrived,
  never time since a complete frame. A large sync record trickling over a
  slow cellular link does not trip it; a link that dies mid-record does.
- **Client obligation.** A live remote client sends a `ping` request every
  half-bound, on a fixed cadence, regardless of what else it is sending or
  receiving. The cadence is unconditional by design: it tracks no
  send-silence and assumes nothing about which other frames earn replies.
  Each ping feeds the server's deadline and each pong feeds the client's
  own, so the cadence by itself is enough to keep both deadlines fed
  whether the connection is idle, talking, or draining a flood. It is
  sufficient, not exclusive: silence stays byte-level on both ends, so any
  arriving byte resets receive-silence. The cost is one small ping during
  otherwise active periods.
- **Server deadline.** A remote connection whose receive-silence crosses the
  bound is closed, its slot released, and the close audited with a liveness
  reason. Local Unix connections are exempt from the whole contract: peer
  death without a socket close is impossible locally, and CLI unix follows
  legitimately idle forever.
- **Client deadline.** Receive-silence crossing the bound on an established
  remote session declares the peer dead, releases the session's transport
  resources, and presents as Connection lost. Before a valid hello arrives
  the client does not know the bound, so the pre-hello wait is bounded by an
  independent client establishment policy; once hello arrives the advertised
  bound governs everything after it, the first reply included. Either
  establishment failure presents as Server unreachable. No new user-facing
  states: the existing
  vocabulary already names both remedies; the phase distinction lives where
  the phase is known, not in the total error-to-state reducer.
- **A pong proves service, not reachability.** `ping` is an ordinary
  `IpcRequestMethod` case answered through the same dispatch path as every
  other request -- the exhaustive classification switches force its
  decisions like any new method's. Nothing below dispatch answers a ping, so
  a Mac that cannot service requests fails liveness and the client reports
  that instead of waiting forever.
- **Placement.** The client half -- ping scheduling, the receive deadline,
  dead-peer teardown -- lives in `lib/DanTermClient`, so the phone and the
  CLI-over-TCP share one implementation and the iOS kit only maps outcomes
  onto its existing states. Whether a session lives under the contract is
  declared by the transport conformance itself: every conformance must
  declare its liveness policy, mirroring the compile-forced method
  classification pattern, and no session call site chooses. The server half
  lives with the tailnet accept path and the existing close path:
  reclamation reuses the single existing close/release/audit route, so the
  slot is released exactly once.
- **Audit (amends D4).** `connectionClosed` gains a close reason and
  served-request accounting, with pings counted in that accounting, so
  "admitted and never serviced" is reconstructable from the log. Pings
  produce no per-request audit records and bypass the write-ahead request
  gate: a ping exercises no authority and names no target, and recording one
  every fifteen seconds would evict the events the log exists for. The
  amendment lands in the research/35 decision log with this plan.

**The ideal, weighed.** For the shared-fact problem this contract is the
ideal: one advertised bound, one obligation, one mechanism. Both measured
symptoms and the idle-zombie case F9 could not test collapse into it, and
disagreeing timeouts cannot exist because only one end defines the number.
The deafness case has a second, deeper ideal -- the readiness-based (kqueue)
connection reader that removes thread-per-connection starvation outright.
D4 named it, and its recorded deferral condition ("if remote use is
adopted") is now met. By user decision (2026-08-17) it proceeds as its own
plan: the contract here is designed to hold regardless of reader
implementation, and the reader deletes rather than fights this plan's server
mechanism. Likewise the client's automatic-retry policy, which consumes the
facts this plan creates, is by the same user decision its own follow-on
plan.

Behavioral scope: the wire gains `ping` and a hello field; remote
connections on both ends gain the contract; local connections and every
non-liveness behavior are unchanged. `integrations/danterm/SKILL.md` is
updated with the IPC surface change in the same change.

## Invariants

- **I1 -- one fact, one bound.** Peer death on a remote connection is
  decided only by byte-level receive-silence crossing the single
  server-advertised bound; neither end applies a second, differently tuned
  silence rule to the same established stream. (A client may still bound an
  individual expected reply more tightly as presentation policy; that ends
  its own wait, not the peer.)
- **I2 -- obligation.** A live client sends a `ping` every half-bound on an
  unconditional cadence. Nothing else the client sends or receives changes
  that schedule, so neither end's deadline depends on which other frames
  earn replies.
- **I3 -- honesty.** A pong is produced by the same dispatch path that
  services every other request; nothing below it answers.
- **I4 -- server reclamation.** Silence past the bound closes the
  connection, releases its slot exactly once, and audits a
  liveness-reasoned `connectionClosed` -- regardless of data queued in
  either direction. Local connections are exempt from the contract.
- **I5 -- no false kills.** A compliant peer is never reclaimed, however
  quiet the pane and idle the user; stalls at the scale F5 measured ride
  through untouched.
- **I6 -- client legibility.** No client wait is unbounded. Stream silence
  past the bound presents as Connection lost and releases the client's
  transport resources; establishment that stops progressing presents as
  Server unreachable within a bounded time. The existing state vocabulary
  becomes total in fact, not only in mapping.
- **I7 -- invisible heartbeats.** No pong reaches a session consumer or
  accumulates without bound; pings appear in no per-request audit record;
  close-time accounting still distinguishes a never-serviced connection
  from a serviced one.
- **I8 -- forced declaration.** Every client transport conformance declares
  its liveness policy at compile time; unix transports are exempt, TCP
  transports are under the contract, and no session call site decides.

## Proof obligations

- **PO1 (I4).** An admitted remote connection that goes silent is closed
  within the bound, its slot is released (a subsequent connection is
  admitted at the cap), and the close is audited with the liveness reason --
  including the idle-zombie shape F9 could not test: nothing queued in
  either direction.
- **PO2 (I4).** Reclamation with queued unsent output (the peer stopped
  reading and a write is blocked) completes within the bound, releases the
  slot exactly once, and carries the liveness reason rather than a generic
  close.
- **PO3 (I5, I2, I8).** A client with a quiet pane and no user input
  survives at least three bounds on pings alone; a client busy exchanging
  requests and draining a flood still pings on the same cadence; a CLI unix
  follow idles far past the bound untouched.
- **PO4 (I6, I1, I4).** Byte-level silence, proved on both ends. An
  established session whose server goes byte-silent surfaces dead-peer
  within the bound and presents Connection lost; a server trickling bytes
  with gaps below the bound but no complete frame for longer than the bound
  is not killed; and symmetrically, a client trickling one incomplete
  request the same way keeps its connection and then completes the request.
- **PO5 (I6, I3).** Against a deaf server -- accepts, sends hello, never
  replies -- establishment presents Server unreachable within the advertised
  bound; a server that never sends hello is bounded by the pre-hello policy
  instead. That nothing below
  dispatch rescues the deaf server is what discharges I3 behaviorally.
- **PO6 (I7).** Over a long follow spanning many pings, no pong is
  delivered to the session consumer and no per-ping memory grows; a
  ping-send failure surfaces as a prompt connection failure rather than
  leaving a silently non-pinging connection for the server to kill at the
  bound.
- **PO7 (I7).** The audit log distinguishes three connections -- served
  requests, only pinged, admitted-and-never-read -- via close reason and
  accounting, and no ping appears as a request record.
- **PO8 (I1, I2).** The bound travels in hello and both ends derive from
  it: against a server advertising a nonstandard bound, the client pings at
  half of it and applies it as its deadline.

## Non-goals

- Automatic client retry and backoff -- the designated follow-on plan (user
  decision, 2026-08-17); until it lands a liveness-declared death ends in a
  manual reconnect.
- The readiness-based connection reader -- its own plan (same user
  decision); see AR1.
- Mac sleep semantics and focus-report semantics (both unowned per the
  research/35 README; unchanged here).
- The audit descriptor's resume-versus-fresh-join gap (F9 records it as a
  distinct defect).
- Local-socket idle-connection starvation (F8's worker-pool cliff for local
  callers; the reader plan's subject).

## Accepted risks

- **AR1.** The server's deadline enforcement can itself be starved with the
  worker pool it runs on, so under F8-style starvation the slot leak
  persists until the readiness-reader plan lands; the client-side bound
  keeps that failure legible meanwhile. Accepted because starvation-proof
  interim scaffolding (a dedicated enforcement thread) is code the reader
  plan would delete.
- **AR2.** Outages longer than the bound that today's unchecked connection
  sometimes rode through now kill the connection, and without automatic
  retry the user reconnects by hand; Mac sleep now presents as Connection
  lost at the bound. Accepted as the price of noticing, priced low by D5
  resume (exact, about one second), and discharged by the retry plan.
- **AR3.** Pong-through-dispatch means a main-actor stall approaching half
  the bound drops every remote client at once -- an lldb pause on the Mac
  included. Deliberate: under this contract a Mac that is not servicing is
  dead.
- **AR4.** The default bound rests on diagnostic numbers (F5's 6.4s worst
  stall, F9's timings), not benchmark conditions. 30 seconds gives roughly
  2x margin at the obligation cadence over the worst measured stall, bounds
  the slot leak well inside the 8-slot budget, and keeps a foreground
  phone's radio duty cycle acceptable; retuning it is a one-binary change by
  construction.

## Rejected ideas

- **`SO_KEEPALIVE` / TCP keepalive.** Detects a dead network, not a deaf
  app, and its kernel-tuned timers are a second, independently configured
  liveness system -- exactly the two-disagreeing-timeouts shape this plan
  exists to prevent.
- **Server-originated heartbeats.** Needs per-connection server timers and
  adds nothing: the client's own unconditional ping cadence already earns a
  pong every half-bound, so no healthy connection can reach client-side
  silence.
- **Answering pings below dispatch.** Reports a starved Mac as alive; I3
  exists to forbid it.
- **Notification-form (id-less) ping.** The server drops and audits id-less
  frames today -- per-ping audit spam -- and, earning no pong, it
  leaves the client's own deadline unfed.
- **Independent client and server timeout constants.** Two ends can
  disagree about one connection; the advertised bound removes the agreement
  problem structurally.

## Implementation discretion

- The server's deadline mechanism (`SO_RCVTIMEO` on the accepted fd, a
  scanner, or otherwise), provided I4 holds in unstarved operation and
  reclamation reuses the single existing close/release/audit path
  (shutdown-before-close to unblock a parked writer is the known trap).
- The pre-hello establishment policy's exact bound, where the phase mapping lives, ping-scheduling internals, and the
  clock seam that makes the client half headless-testable.

## Deliverables

- Protocol: the `ping` method and hello's advertised bound
  (`lib/DanTermProtocol`), with the dispatch case in `lib/DanTermCore`.
- Server: deadline, liveness-reasoned close, and close accounting
  (`app/IpcServer.swift`, `lib/DanTermSupport` connection and listener
  files, the audit writer).
- Client: the contract in `lib/DanTermClient` (session plus
  transport-declared policy), establishment bounds on the phone's session
  path, and state mapping in `ios/DanTermMobileKit` /
  `ios/DanTermMobileApp`.
- Docs: the D4 audit amendment in the research/35 decision log, the
  research/35 README open-question closure pointing at this plan, and the
  `integrations/danterm/SKILL.md` surface update.

## Commit progress

- [x] 1. feat(ipc): advertise one silence bound and answer ping through dispatch
- [ ] 2. feat(ipc): reclaim a silent remote connection and audit why
- [ ] 3. feat(client): keep a remote session alive on the advertised bound
