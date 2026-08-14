# Milestone-1 Mac side: tailnet listener, handshake refusals, input-grammar widening

## Problem and desired outcome

Milestone 1 of the iOS remote client (research/35, D1) is a pane on the phone
the user genuinely types into, rendered by the real engine. The research phase
is closed for everything this plan touches: D4 decided the app owns a
tailnet-bound listener with tailnet identity as the credential, D8 decided the
wire carries input intent and the PTY owner encodes, and D4 assigned the
refusal-shape work to the hello handshake (T24). None of it is implemented:
today the app listens only on the Unix control socket, the wire input grammar
cannot express `C-\` or a wheel event, and a rejected or version-skewed client
would see a silent close.

This plan is the Mac-side half of milestone 1, per the user's slicing decision:
the D4 listener, the T24 handshake refusal shapes, and the D8 grammar widening.
The step-0 iOS client app is a separate follow-on plan; it depends on all three
pieces here.

Evidence, not re-derived here:

- research/35/F8 -- the surface is remote code execution with no
  least-privilege subset; 64 idle connections make the app deaf to new
  callers; a tailnet peer address resolves locally (`tailscale whois`, no
  root) to a stable node id and owning user; the audit-log rules including
  the deliberate `pane.input` blind spot.
- research/35/F5 -- a tailnet TCP session survives a wifi-to-cell-to-wifi
  switch without reconnecting; `TailnetBindAddress`'s no-public-initializer
  shape is the precondition of the identity argument.
- decisions.md D4 and D8 in docs/research/35-ios-remote-client/ -- the full
  rationale this plan implements; alternatives (bridge process, TLS, pairing
  token, client-side encoding, request-rate limit) are rejected there and not
  re-argued here.

Load-bearing premises taken from the tree, not re-derived here:

- `ControlSocketListener` (DanTermSupport) owns bind/listen/unlink only; the
  accept loop lives in `app/IpcServer.swift`, which discards the peer address
  today. Everything downstream of accept takes only a file descriptor.
- `IpcRequestMethod` carries two exhaustive switches (`terminatesInstance`,
  `isTargeting`) whose purpose is that a new method must classify itself or
  fail to compile. The quit authorization rule already lives in pure dispatch
  (`IpcDispatch.swift`), reading `env.instanceIdentity()`.
- The hello is a one-way server-first notification
  `{"protocol": 1, "app": <version>}`; the `app` field is written but never
  read. Client checks live in `DanTermClientSession.handshake()` and a
  hand-rolled copy in `cli/main.swift`.
- The versioned JSON config (`~/.config/danterm/config.json`) is
  `DanTermConfig` in DanTermProtocol with the app-side store in
  `app/DanTermConfigStore.swift`; the file is shared by the production app and
  every dev slot.
- The owner-side input funnel exists end to end: `pane.input` events lower
  through pure dispatch to `TerminalPTYHost.sendKey` (mode read + encode +
  write, atomic on the owner queue) and `TerminalPTYHost.sendWheel`
  (`TerminalWheelEvent`: signed rows, cell, modifiers, phase, with existing
  mode-gated routing). The Mac keyboard, CLI, and agents all write through it;
  D8 makes the phone the fifth writer.
- `t5-bridge/` under docs/research/35-ios-remote-client/ is throwaway spike
  evidence; D4 assigns its deletion to whoever implements the listener, with
  `TailnetBindAddress` adopted by re-implementation, not by moving the file.

## Decision

**The app opens a tailnet TCP listener beside the control socket, and
DanTermSupport owns the bind while `IpcServer` owns the accept.** A new
listener type in DanTermSupport, sibling of `ControlSocketListener` with the
same contract (bind/listen/close only, `Mutex`-guarded idempotent teardown,
raw Darwin sockets -- no Network.framework dependency), constructible only
from a re-implemented `TailnetBindAddress`. The re-implementation keeps the
spike's shape: no public initializer, a single `resolve` entry that rejects
malformed input, wildcards, anything outside 100.64.0.0/10, and any address no
local interface carries -- holding the value proves the check ran. The
interface enumeration is an injectable seam so the rejection matrix is a pure
test; tests inside the module may use the internal initializer to bind
loopback, since the no-public-init guarantee is about call sites outside the
module. The remote accept loop captures the peer address that the Unix-socket
loop discards. Rejected alternative: a separate bridge process -- rejected by
D4 on classification drift, record parsing, and audit blindness; not
re-argued.

**No remote request is serviced before identity is resolved and admitted.**
Per accepted remote connection, in order: connection-cap check, peer-address
resolution to a stable tailnet node id (shelling out to `tailscale whois`
behind an injectable resolver seam -- DanTermSupport already shells out in
`CLIPathInstaller`, so no layering rule breaks), admission check against the
configured admitted-node list, and only then the hello and the read loop. Any
resolution failure -- binary missing, timeout, unparseable output -- refuses
the connection; it is never treated as admitted. The hello is the server's
promise of service and is written only after admission.

**Caller identity is per-request data, not ambient environment.** A caller
identity value (local, or remote with node id / user / machine name) is
defined in DanTermProtocol (both DanTermCore and DanTermSupport need it, and
Support cannot depend on Core), minted once per connection at admission time,
and stamped onto every request so it travels through `Msg.ipcRequest` into
pure dispatch. `CoreEnv` is untouched: identity of the *caller* is
per-request; identity of the *instance* stays the existing ambient
authorization seam. A third exhaustive switch on `IpcRequestMethod` classifies
remote authority; `quit` is its only refused case (a phone that ends the app
destroys its own access until the user is back at the Mac -- D4), refused in
pure dispatch with a stated error. Classification is authority, not product
scope: todo methods stay callable remotely, per D4.

**Activation is a config entry, closed by default** (user decision). A
`tailnet` object in the versioned JSON config -- listen address:port plus the
admitted-node-id list -- opens the listener at launch; absence, an empty
admitted list, or a `TailnetBindAddress` rejection means no listener. The key
is named `tailnet`, not `remote`, because the config already uses "remote" to
mean SSH-remote theming. A failed bind or rejected address is fail-soft: the
app runs fully functional without the listener, and the failure is audited --
never downgraded to a different bind. Fail-soft matters structurally because
prod and dev slots share the config file, so a configured port is held by at
most one instance and every other launch must survive losing the race.

**An app-side audit log records connections and requests, with F8's redaction
rules in one pure function.** JSON-lines, one object per event: connection
opened (transport, peer address, resolved identity), connection refused
(reason), connection closed, and per-request records -- caller, method,
target, outcome -- for local and remote callers alike (the guarantee levels
and the remote started/completed pair are I6's contract). Redaction is a pure
descriptor derived from `IpcRequest` beside the request type, so the invariant
is testable with no IO: `tab.new`/`pane.split` log full `cmd` and `cwd`
(that text is the authority exercised), and the content of
`pane.read`/`pane.rows`/`pane.tape`/`pane.snapshot` is never logged. The
audited quantity for `pane.input` is the request's own payload accounting --
the UTF-8 byte count of a text form, and the event count of an events form --
never key names, never text, and never the owner-encoded PTY bytes: key
identity is content (a log of key names is F8's keylogger by another name),
and the encoded byte stream exists only after the owner reads live modes, so
reporting it would add a cross-actor round trip to record an encoding detail
the audit does not need. The log records the authority the caller submitted,
which the request itself fully states. Traffic that never reaches dispatch is
still audited: a request that fails decoding is recorded with its raw method
string and the failure outcome, and an id-less line (which the server
otherwise ignores) is recorded as dropped. The writer lives in DanTermSupport
with explicit seams (directory, clock) in the RecoveryStore style, writes
0600 under the instance directory, and is size-bounded with one rotation. The
pure core never performs the write; the app runtime emits entries when it
performs reply/error commands.

**Remote service is write-ahead on the audit log; local service is not.**
The listener opens only if the audit sink is writable at launch -- an
unavailable sink is one more no-listener case under the config gate. The
gate is per connection and per request, with no global health state: the
admitted-connection record is appended before the hello, and a started
record for each remote request is appended before dispatch. If either append
fails, the caller receives the stable audit-unavailable refusal (the
rejection notification before the hello; a JSON-RPC error reply for an
in-flight request) and that connection closes without the effect running.
Other connections are untouched, and every later connection or request
retries the sink naturally, so recovery needs no trigger. A completed record
carrying the outcome is appended after the effect; a started record without
its completion marks the outcome indeterminate -- the strongest guarantee
available when the effect and the file write cannot be atomic. Local callers
are best-effort: their entries go through the same writer, but a log failure
never blocks the user's own terminal -- local authority predates the log,
and halting the Mac's own IPC over a failed rotation is the wrong trade.

**Remote connections are capped at the accept boundary, and past the cap the
listener refuses with a stated error.** Cap accounting is synchronous on the
accept thread: a slot is reserved before any admission work (whois, hello) is
scheduled, and released on every refusal and close path. The existing loop's
shape -- spawn a task per accepted descriptor, decide later -- would let a
burst accumulate unbounded pending descriptors before any check runs, which
is the resource exhaustion the cap exists to prevent; a connection that gets
no slot is refused immediately and holds nothing beyond the refusal write.
Refusal writes a rejection notification and closes (the existing
oversized-line path is the template) -- never accept-and-never-read, which is
F8's denial-of-reconnect. The refusal is audited. The ideal repair -- replacing thread-per-connection
blocking reads with a readiness-based reader so idle connections cost no
threads -- is named by D4 itself as the better fix and deferred below; the cap
is stated as a bound that must hold however the reader is implemented.

**Refusals and version skew get distinct wire shapes; the version policy is
protocol-hard, app-soft (T24).** A refused connection receives a JSON-RPC
notification (there is no request to answer) in place of the hello -- method
`rejected`, with a reason distinguishing not-admitted, identity-unresolved,
connection-limit, and audit-unavailable -- then close. The hello keeps its
one-way shape; what changes is that the `app` version field becomes read:
`DanTermClientSession` surfaces the server's app version and refuses only on
protocol-number mismatch, warning on app-version skew. A client can
therefore distinguish from the wire alone: not admitted, identity
unresolvable, connection limit, audit unavailable, protocol too new/old, and
(by connect failure) Mac unreachable. The CLI's
hand-rolled hello check is rewired onto the shared session logic. Rejected
alternative: a client-to-server hello with strict version equality -- it
would refuse every dev build and the routine TestFlight skew D3 accepts, and
no honest engine-behavior version exists to compare (both ends build from one
repo; a hand-bumped constant goes stale silently). If skew bites in practice,
that is the reopen condition, recorded in the research doc when T24 is marked
decided.

**The wire input grammar widens to D8's gap list, and the PTY owner keeps
encoding.** The `key` form of a `pane.input` event accepts single non-letter
ASCII characters (at minimum `\`, `[`, `]`, `^`, `_`, and space -- the
Ctrl-encodable set the engine's encoder already covers), with the new rule
that a character key requires at least one modifier: plain characters are
text, so every keystroke has exactly one wire spelling, and an
empty-modifier character key is a parse error (a deliberate wire break from
today's accepted `{"key":"a"}` -- internal compatibility is free).
`Insert` joins the named keys. The CLI token classifier stops throwing on
`C-\`, `C-Space`, `C-[`, `C-]`, `C-^`, `C-_`. Wheel events join the wire --
direction and cell, lowered to the existing `sendWheel` funnel so the owner's
mode gating applies on arrival; click, drag, and motion wait for real use.
Rejected alternative: adopting the engine's `TerminalInputKey` as the wire
form -- it drags seventeen keypad cases onto the wire and couples the
protocol to an engine type (D8). The exact wire field shapes for the widened
key and the wheel event are implementation discretion; the one-spelling rule
and the expressible set are contract.

**`t5-bridge/` and `t5-run.sh` are deleted** in the same change that lands
the listener, with `<!-- docs-lint: allow-missing ... -->` markers added to
the research files that cite them, per D4 and the docs-lint rule.

Behavioral scope:

- A configured, admitted tailnet peer can drive every IPC method except
  `quit` over TCP, with the same replies and streams the Unix socket serves.
- An unconfigured launch opens no port; a misconfigured one opens no port and
  keeps the app fully usable.
- A refused client learns why, in a machine-readable shape.
- `danterm pane input -- C-\` (and the rest of the gap list) reaches the PTY
  as the correct control byte; a wheel event scrolls a mouse-tracking
  program in a pane.
- No remote effect runs without a durable audit record; every other request,
  refusal, and connection event is recorded best-effort.

Out of scope for this plan:

- The iOS client app itself (follow-on plan), `pane.resize` and everything in
  D6 stages 2-4, APNs (T15), subscription scope (T22), reconnect lifecycle
  (T9), and focus-report semantics (deferred to T9 by D8).
- Capping or reworking Unix-socket connections; the cap governs the new
  remote surface only.

## Invariants

- **I1 -- closed by default, never downgraded.** An ordinary launch opens no
  network listener. A listener exists only when the config names an address
  that passes `TailnetBindAddress.resolve` at bind time; any resolution or
  bind failure yields no listener, an audit entry, and an otherwise fully
  functional app. There is no code path that binds a wildcard or non-tailnet
  address. Without this, the identity argument collapses: a LAN-reachable
  listener authenticates nobody.
- **I2 -- holding the address proves the check ran.** `TailnetBindAddress`
  has no public initializer; the listener type cannot be constructed without
  one.
- **I3 -- admission precedes service.** No bytes from a remote connection are
  read as requests, and no hello is written, before the peer address is
  resolved to a stable node id found on the admitted list. Resolution failure
  refuses with a reason distinct from not-admitted. Without this, "tailnet
  identity is the credential" is a slogan on an unauthenticated port.
- **I4 -- caller identity travels with the request.** Every dispatched
  request carries a caller identity minted at admission; pure dispatch
  refuses `quit` for remote callers with a stated error; the classification
  is an exhaustive switch on `IpcRequestMethod` so a new method cannot land
  without deciding its remote authority. `CoreEnv` gains no caller field.
- **I5 -- the cap bounds held connections, and refusal never strands.** At no
  point -- including a concurrent connect burst -- do remote connections held
  for admission or service exceed the cap: the slot is reserved on the accept
  thread before any admission work is scheduled and released on every refusal
  and close path. A connection past the cap receives a stated rejection and a
  close; it is never accepted and left unread. Established conversations are
  unaffected.
- **I6 -- the audit contract is precise about what is guaranteed.** Every
  *dispatched* remote request has a durable started record appended before
  its effect, and either a completed record carrying the outcome or -- when
  the completion append fails -- a started record that reads as an
  indeterminate outcome; that is the guaranteed set, and I10 enforces it.
  Everything else is recorded best-effort through the same writer, never
  blocking service: local requests (single entry with caller, method,
  target, outcome), connection lifecycle events, refusals including the
  gate's own audit-unavailable rejections, requests that fail decoding (raw
  method string plus failure outcome), and id-less lines (recorded as
  dropped). Redaction applies to every record: `pane.input` appears as payload
  accounting only -- text byte count or event count, never key names, never
  content, never owner-encoded bytes; pane content
  (`read`/`rows`/`tape`/`snapshot` payloads) never appears;
  `tab.new`/`pane.split` entries carry the full `cmd` and `cwd`. The log file
  is 0600 and size-bounded.
- **I10 -- no remote effect without a write-ahead audit record.** The
  listener does not open without a writable audit sink; a remote connection
  admits only after its connection record is appended, and a remote request
  dispatches only after its started record is appended. A failed append
  refuses with the stable audit-unavailable shape and closes only that
  connection; the outcome lands in the completed record or reads as
  indeterminate. There is no global audit-health state: each later
  connection or request retries the sink, so recovery needs no trigger.
  Local service never blocks on the log. Without this, a full disk lets
  remote commands run unrecorded.
- **I7 -- refusal shapes are distinguishable from the wire.** A client can
  tell not-admitted, identity-unresolved, connection-limit,
  audit-unavailable, and protocol-version mismatch apart without heuristics,
  and each shape is stable protocol surface.
- **I8 -- one wire spelling per keystroke.** Plain characters are text; the
  character-key form requires at least one modifier; an empty-modifier
  character key is a parse error. Without this, the same keystroke has two
  spellings that must agree in every mode forever.
- **I9 -- the gap list is expressible and the owner encodes.** `C-\`,
  `C-Space`, `C-[`, `C-]`, `C-^`, `C-_`, `Insert`, and wheel up/down at a
  cell are expressible as CLI tokens and wire events; each reaches the
  existing owner-side funnel (`sendKey`/`sendWheel`) where modes are read
  atomically with encoding. No client-side encoding path is added.

## Proof obligations

- **PO1 (I1).** With no `tailnet` config: no listening TCP socket exists
  (assertable by launching a slot and probing). With a config whose address
  fails resolution, and separately with a config whose port another process
  already holds: the app launches, serves the Unix socket normally, and the
  audit log holds the failure entry.
- **PO2 (I2, I1).** The rejection matrix, pure, with injected interface
  lists: malformed, wildcard, out-of-range, and not-locally-carried addresses
  all refuse; a carried 100.64.0.0/10 address resolves. This is behavioral
  (resolve accepts/refuses), not structural.
- **PO3 (I3).** Against a real loopback listener (internal-init address,
  socketPair-style fixtures) with an injected resolver: an admitted node id
  completes the hello and gets an `ls` reply; an unknown node id receives the
  not-admitted rejection and a close before any request is read; a resolver
  failure receives the identity-unresolved rejection. The wire bytes of each
  rejection are asserted, since they are stable protocol surface (I7).
- **PO4 (I4).** Pure dispatch: a remote-caller `quit` returns the stated
  error; a local launcher-slot `quit` still terminates; every other method
  dispatches identically for local and remote callers -- proven by a
  `CaseIterable` sweep asserting `quit` is the only method classified as
  requiring a local caller. No socket involved.
- **PO5 (I5).** With the cap held by open connections: the next connection
  receives the connection-limit rejection and a close, an established
  connection still answers a request, and closing one admitted connection
  readmits the next caller. Separately, a concurrent burst of connects
  against a full (or nearly full) cap, with admission work stalled behind a
  slow injected resolver: at no observable point do connections held for
  admission or service exceed the cap, and every excess connection is
  refused, not left pending.
- **PO6 (I6).** Pure redaction: the descriptor for a `pane.input` request
  with N bytes of text carries N and no text; the descriptor for an
  events-form request (a control key such as `C-\`, plus wheel events)
  carries the event count and neither key names nor characters; descriptors
  for `pane.read`/`rows`/`tape`/`snapshot` replies carry no content field; a
  `tab.new` descriptor carries the full `cmd` and `cwd`. Writer tests (tmp
  fixture): JSONL shape, 0600 mode, rotation at the bound.
- **PO7 (I7, T24).** `ScriptedTransport` client tests: each rejection reason
  (audit-unavailable included) surfaces as its own typed error; a hello with a future protocol number
  still refuses; a hello with a different app version succeeds and surfaces
  the server version. The CLI path shares the logic or repeats the cases.
- **PO8 (I8).** Decoding `{"key":"a"}` and `{"key":"\\"}` without mods is a
  parse error with a stated message; `{"text":"a"}` still types; the same
  key-with-modifier event round-trips encode/decode unchanged.
- **PO9 (I9).** End to end at the PTY boundary: `pane input -- C-Space`
  writes 0x00 and `C-\` writes 0x1C to the pane's PTY (mode-independent
  control bytes, so the assertion is byte-exact without structure
  sensitivity); `Insert` produces its escape sequence; a wheel event against
  a pane whose program enabled mouse tracking produces a wheel report on the
  PTY, and against a primary-screen pane with tracking off produces viewport
  scroll, not PTY bytes -- pinning that the owner's existing gating applies
  to the new writer.
- **PO10 (existing-behavior premise).** The Unix-socket path is unchanged:
  existing IPC tests keep passing with every local request minting the local
  caller, which the audit entries now make observable.
- **PO11 (I10).** With an unwritable audit sink at launch and a valid
  `tailnet` config: no listener opens and the Unix socket serves normally.
  With two admitted connections and the sink made unwritable mid-session:
  the next remote request receives the audit-unavailable error and its
  command never dispatches, only that connection closes -- the second stays
  open -- and a local request on the Unix socket still succeeds. With the
  sink restored: the second connection's next request succeeds with its
  started and completed records present, proving recovery needs no trigger.
- **PO12 (I6, runtime hookup).** One app-level sequence through the real
  server and audit path (socketPair-style fixtures, tmp audit directory):
  connection open, a local request that succeeds, a remote request that
  succeeds (its started and completed records both present, in order), a
  request that fails dispatch with an error, a line that fails decoding, an
  id-less line, and a connection close -- then assert the complete ordered
  audit sequence, with correct caller attribution on each record and
  redaction applied. This is the obligation that fails if any
  runtime path skips the log while the descriptor and writer tests stay
  green.

## Non-goals

- No TLS, no pairing token, no request-rate limit (rejected by D4).
- No enforcement that remote clients avoid todo methods (client convention,
  per D4).
- No live config reload for the listener: its state follows launch-time
  config. Restart to change it.
- No UI surface: no preferences pane, no menu item, no status indicator.
- No mouse click/drag/motion on the wire (D8: wait for real use).

## Accepted risks

- **AR1.** `tailscale whois` output format is an external dependency; the
  parser is written against a recorded fixture of the real `--json` output,
  and a Tailscale update could change it. Failure mode is refusal (fail
  closed), never false admission.
- **AR2.** The connection cap number and the audit rotation bound are
  discretionary constants (order: one phone plus reconnect churn, far below
  the 64-thread cliff; a few MiB). Wrong values inconvenience, not endanger.
- **AR3.** App-version skew only warns. A behaviorally incompatible pair of
  builds will connect and misbehave; accepted because no honest
  engine-behavior version exists to compare, and recorded as T24's reopen
  condition.
- **AR4.** The whois shell-out adds one process spawn per new remote
  connection, serialized before admission. Connections are long-lived (F5),
  so this is per-session, not per-request.

## Rejected ideas

- **RI1.** Bridge process, TLS, pairing token, rate limit, client-side input
  encoding: rejected in decisions.md D4/D8; this plan inherits, and does not
  restate, those arguments.
- **RI2.** A client-to-server hello with strict version equality (see
  Decision; refuses every dev build, no honest version to compare).
- **RI3.** `TerminalInputKey` as the wire input form (couples wire to engine
  internals; D8).
- **RI4.** Moving `TailnetBindAddress` from the spike instead of
  re-implementing it (D4 chose re-implementation so the spike stays
  throwaway evidence until replaced).

## Deferred, with the reason

- **Readiness-based connection reader** (kqueue/DispatchSource) replacing
  thread-per-connection blocking reads -- the ideal fix for F8's
  denial-of-reconnect, named by D4. Deferred because the cap holds the bound
  meanwhile and the reader rework is a separable change touching every
  connection path; it should become its own plan if remote use is adopted.
- **Focus-report semantics** ("focused means anyone is engaged") -- T9 owns
  the lifecycle facts it needs (D8).
- **Env-var or launch-argument override of the tailnet config** for driving a
  listener on a dev slot without editing the shared config file. If manual
  verification needs it, add it as a plain launch-time override and note it
  in SKILL.md; otherwise verification edits the config while only the slot
  runs.

## Deliverables

- The `tailnet` config schema (documented where config keys are documented
  today).
- Wire surface: the `rejected` notification method and its reason vocabulary
  (not-admitted, identity-unresolved, connection-limit, audit-unavailable)
  plus the matching request-level audit-unavailable error; the widened `key`
  grammar, `Insert`, and the wheel event; hello unchanged on the wire but
  `app` now read.
- CLI: `C-\`, `C-Space`, `C-[`, `C-]`, `C-^`, `C-_` tokens parse;
  `integrations/danterm/SKILL.md` updated in the same change (D8 and the
  standing AGENTS.md rule): token table, refusal messages, tailnet config
  note.
- Research-doc closeout in docs/research/35-ios-remote-client/: T24 recorded
  as decided (protocol-hard, app-soft, with RI2 as the rejected arm and AR3
  as the reopen condition); a D4 amendment recording that the `pane.input`
  audit quantity is request payload accounting -- text UTF-8 byte count or
  event count -- superseding F8's inherited PTY byte count, with the privacy
  rationale (key identity is content, and the encoded bytes exist only after
  the owner reads live modes); the ledger rows for the shipped D4/D8 surface
  updated; `t5-bridge/` and `t5-run.sh` deleted with docs-lint allow-missing
  markers in the files that cite them.

## Implementation discretion

- Exact wire field shapes for the widened character key and the wheel event
  (the one-spelling rule, the expressible set, and mode-gated arrival are
  contract; field names are not).
- Cap constant, audit rotation bound, whois timeout, and the whois binary
  search order.

## Commit progress

- [x] Pure caller-identity rule: identity type in DanTermProtocol, the third
      exhaustive switch, `Msg.ipcRequest` carries the caller, dispatch
      refuses remote `quit`; all existing call sites mint local. (PO4, PO10)
- [ ] Support layer: `TailnetBindAddress` re-implementation with injectable
      interfaces, the tailnet listener type, peer-address capture, whois
      resolver seam with fixture-tested parsing, audit log writer and pure
      redaction descriptor; delete `t5-bridge/` + `t5-run.sh` with docs-lint
      markers. (PO2, PO6)
- [ ] Handshake and refusal shapes: `rejected` notification, client session
      surfaces app version and typed rejections, CLI rewired, SKILL.md
      refusal notes. (PO7)
- [ ] App wiring: config schema and store read, listener enablement with
      fail-soft bind and the writable-sink precondition, remote accept path
      (accept-boundary cap reservation, whois, admission, hello), caller
      stamping, the per-connection/per-request write-ahead audit gate;
      research-doc closeout including the D4 amendment. (PO1, PO3, PO5,
      PO11, PO12)
- [ ] D8 grammar: widened key case with the modifier-required rule, `Insert`,
      CLI tokens, wheel event and its lowering to `sendWheel`, SKILL.md token
      table. (PO8, PO9)
