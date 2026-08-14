# Tailnet smoke-test fixes: LocalAPI whois, CLI TCP transport, stable audit JSON

## Problem and desired outcome

The milestone-1 Mac side (plans/impl/2026-08-14-0101-tailnet-listener-handshake-input.md,
commits 85c78182..e51cebf4) landed, and a live smoke test on this machine
verified half of it: closed by default, tailnet-only bind, exact `rejected`
wire bytes, refusal auditing, `pane.input` redaction. It also found three
defects, and left the admitted path unverified because the first defect blocks
it:

- **Identity resolution never succeeds on this Mac.** `TailnetWhoisResolver`
  shells out to the `tailscale` binary, probing the App Store and Homebrew
  paths, then `/usr/bin/env tailscale`. This machine runs nix-darwin's
  tailscaled (`/run/current-system/sw/bin/tailscale`), and the app's launchd
  PATH is bare `/usr/bin:/bin:/usr/sbin:/sbin`, so every tailnet connection --
  including from an admitted node -- refuses as `identity-unresolved`. It
  fails closed (correct), but the feature is unusable, and the admitted path,
  not-admitted refusal, remote `quit` refusal, and remote started/completed
  audit pairs are all unexercised against the real daemon.
- **The durable audit log leaks Swift's synthesized Codable.** Observed:
  `"input":{"eventCount":{"_0":2}}` and `"timestamp":808419063.8581` (Date's
  reference-date seconds). `_0` is a compiler artifact in a durable,
  consumer-facing format; the timestamp is unreadable without knowing Swift's
  epoch.
- **No shipped client speaks the tailnet transport.** The CLI connects only
  to a Unix socket path, so the smoke test had to hand-speak the protocol
  with python3. The feature cannot verify itself first-party, and the typed
  refusal surface documented in SKILL.md is unreachable from the CLI.

Outcome: an admitted tailnet peer is actually served on this machine, the
CLI can drive the TCP listener directly, the audit format is stable
hand-written JSON, and the previously untestable smoke steps pass.

Load-bearing facts from exploration (not re-derived below):

- tailscaled's LocalAPI answers whois on this machine with no root and no
  token: `GET /localapi/v0/whois?addr=<ip:port>` over the unix socket
  `/var/run/tailscaled.socket` (mode 0666) returns HTTP 200 with JSON whose
  `Node.StableID` / `Node.Name` / `UserProfile.LoginName` fields are exactly
  what `TailnetWhoisResolver.parse` already decodes. The request must carry
  `Host: local-tailscaled.sock` -- a different Host gets 403. The App
  Store/GUI Tailscale variant has no such socket (it uses a token scheme).
- The resolver seam is a single injected closure
  (`TailnetWhoisResolver(query:)`); `runWhois` and the candidate list are
  file-private and unreachable from tests. `/usr/bin/env` always exists, so
  the current `binaryUnavailable` case is dead code -- the smoke failure
  surfaced as `commandFailed(127)`. All resolver errors already collapse to
  the `identity-unresolved` refusal at admission.
- `DanTermClientTransport` (lib/DanTermClient) is the client seam and its doc
  comment already anticipates a network conformance. A near-complete TCP
  transport exists in the research spike
  (`docs/research/35-ios-remote-client/ios-render-spike/.../T23ClientSmoke.swift#T23TCPTransport`),
  but it connects only the first resolved address, which PO3 rules out. Typed
  refusal errors live transport-agnostically in
  `DanTermClientSession.handshake()`; only `cli/main.swift`'s `openSession` /
  `cliError` / `reporting` are Unix-socket-specific.
- The audit types (`IpcAuditEvent`, `IpcAuditLogEntry` in
  `IpcAuditLogWriter.swift`; `IpcAuditRequestDescriptor`,
  `IpcAuditInputAccounting` in `IpcAuditDescriptor.swift`) are synthesized
  Codable with a default `JSONEncoder`. The only `_0` source is
  `IpcAuditInputAccounting` (associated-value enum). Existing tests decode
  entries back through the same types, so a matching hand-written decoder
  keeps them passing. No fixture, doc, or external consumer pins the current
  JSON: the format may break freely.
- The IPC protocol itself is the house precedent for stable JSON: exhaustive
  hand-built `JSONValue` trees (`IpcRequest.params` / `IpcRequest.decode`),
  never synthesized enum encoding.

## Decision

**Identity resolution queries tailscaled's LocalAPI directly; the shell-out
is deleted** (user decision). `TailnetWhoisResolver.live` becomes an HTTP/1.1
`GET /localapi/v0/whois?addr=<peer ip:port>` over the AF_UNIX socket
`/var/run/tailscaled.socket`, carrying `Host: local-tailscaled.sock`, using
the peer's observed address (the accept loop already captures ip:port). A
non-200 status, an unreachable socket, an unparseable body, and an
unresponsive daemon each fail within a bounded wait rather than hanging. The
body of a 200 feeds the existing `parse`. No process spawn, no binary
discovery, no PATH sensitivity: the failure class the smoke test found cannot
recur. The socket path is an injectable seam so tests run a scripted LocalAPI
server on a tmp socket; the whole-query closure seam and the fixture-tested
parser are unchanged. `runWhois` and the candidate list are deleted. Resolver
errors stay diagnostic-only -- every case still refuses as
`identity-unresolved`, fail closed, never false admission.

**The CLI gains a TCP target: `--tcp <host:port>`, sharing everything above
the transport.** A `TCPSocketTransport` conformance of
`DanTermClientTransport` joins `lib/DanTermClient`: it connects a host:port
target -- succeeding whenever any address the hostname resolves to is
reachable, so a dual-stack name still reaches a single-stack listener --
bounds its connect, send, and receive waits, sends interactively without
buffering delay, and never lets a peer disconnect terminate the process. No
token: the protocol has none. The parser accepts `--tcp`
in the same prefix loop as `--socket`, rejecting the two together, repeats,
and empty values; `DANTERM_SOCK` keeps meaning the Unix socket only.
`openSession` constructs either transport and hands it to the same
`DanTermClientSession`, so the handshake, typed refusals, and every command
work identically over TCP. `cliError` and `reporting` become target-agnostic
(they currently take a socket path and speak Unix-socket wording) and gain a
TCP transport-error arm. `quit` over `--tcp` is sent and refused by the
server's existing remote-caller rule -- the CLI adds no local special case,
because the server is the authority on remote authority. The explicitness
rule for `quit` (never ambient) is satisfied by either explicit flag.
SKILL.md, README's tailnet section, and `usageText` gain `--tcp` and a
first-party connect example in the same change, per the standing CLI rule. This transport is also the piece the follow-on iOS client plan promotes
anyway; landing it here serves both.

**The audit log format becomes deliberate, stable JSON.**
`IpcAuditInputAccounting` gets a hand-written Codable that encodes as a
single explicit key -- `{"textBytes":12}` / `{"eventCount":2}` -- with a
matching decoder, in the `IpcRequest.params` style. The writer's encoder
sets ISO-8601 UTC date encoding and sorted keys, so `timestamp` is
human-readable and every entry's key order is deterministic. The Swift types
and the redaction logic are untouched; this changes only the serialized
shape. No migration or version field: the format is two weeks old with no
consumers, and internal compatibility is free.

**Verification finishes the interrupted smoke test, first-party.** After the
code lands: configure `tailnet` with this Mac's own node id, launch a slot,
and drive it with `danterm --tcp <tailnet-ip>:<port>` -- admitted `ls`
served; bogus admitted list refuses `not-admitted`; `quit` over TCP refused
with the stated error while the app keeps running; the audit log shows the
remote started/completed pair in the new format. This closes every step the
original smoke test could not reach.

Behavioral scope:

- An admitted tailnet peer is served on a nix-darwin (open-source tailscaled)
  Mac with no PATH or binary-location dependency.
- `danterm --tcp <host:port> <command>` works for every command `--socket`
  supports, with distinct CLI messages for the four connection refusals. A
  hostname target connects whenever any of its resolved addresses is
  reachable.
- Audit entries contain no synthesized `_0` keys, carry ISO-8601 UTC
  timestamps, and have deterministic key order.
- Resolution failure of any kind still refuses `identity-unresolved`; wire
  refusal shapes and admission order are unchanged.

Out of scope: the iOS client app (follow-on plan), the deferred
readiness-based reader, any change to admission semantics or the wire
protocol.

## Invariants

- **I1 -- identity resolution is self-contained.** Resolving a peer needs no
  child process, no binary discovery, and no PATH: the resolver speaks to
  tailscaled's LocalAPI socket directly. Any failure -- socket absent, HTTP
  error, timeout, unparseable body -- refuses the connection as
  `identity-unresolved`; no failure path admits.
- **I2 -- one client stack, two targets.** `--tcp` and `--socket` differ only
  in the transport conformance; handshake, typed refusal errors, command
  encoding, and streaming all flow through the same `DanTermClientSession`
  code path. A behavior difference between the two targets (other than
  transport errors themselves) is a bug.
- **I3 -- the audit format is deliberate.** No synthesized associated-value
  enum encoding reaches the log; timestamps are ISO-8601 UTC; key order is
  deterministic. Encode and decode stay symmetric so entries round-trip.
- **I4 -- existing surfaces are unchanged.** Unix-socket CLI behavior,
  admission ordering, refusal wire shapes, and redaction semantics are
  untouched.

## Proof obligations

- **PO1 (I1).** Resolver against a scripted LocalAPI server on a tmp unix
  socket (injected socket path): a 200 response with the recorded whois JSON
  resolves to the exact identity, and the received request line and headers
  contain the whois path, the peer ip:port in `addr`, and
  `Host: local-tailscaled.sock`; a non-200 response, a missing socket, an
  unparseable body, and a server that never responds (timeout) each throw.
  Existing admission tests (stubbed resolver) keep passing unchanged.
- **PO2 (I1, I2 -- live smoke, manual gate on this machine).** With real
  tailscaled and this Mac's own node id admitted:
  `danterm --tcp <tailnet-ip>:<port> ls` returns the layout; with a bogus
  admitted list, the CLI prints the not-admitted message; `quit` over `--tcp`
  prints the remote-refusal error and the app stays up; the audit log holds
  the remote request as a started/completed pair. Run via a dev slot with the
  config backed up and restored, as in the first smoke test.
- **PO3 (I2).** Parser: `--tcp host:port` parses; `--tcp` with `--socket`,
  repeated, or empty-valued is a stated parse error. Client: against a
  loopback TCP listener fixture, the TCP transport completes the handshake
  and surfaces each scripted rejection as its typed error; a hostname whose
  resolution includes an unreachable address ahead of the reachable one --
  an IPv4-only listener reached through a dual-stack name such as
  `localhost` -- still connects; the CLI characterization suite covers the
  TCP refusal messages the way it covers the Unix-socket ones.
- **PO4 (I3).** The encoded entry for `.eventCount(2)` contains
  `"eventCount":2` and no `_0` anywhere; `.textBytes(12)` likewise; the
  timestamp field matches an ISO-8601 UTC shape; encoding the same entry
  twice yields identical bytes. Existing writer round-trip, rotation, and
  app-level audit-sequence tests keep passing with the matching decoder.
- **PO5 (I4).** The full existing suite passes: Unix-socket CLI
  characterization, remote server admission/refusal tests, redaction tests
  -- all unchanged except where a test decodes the audit JSON, which uses
  the symmetric decoder.

## Non-goals

- No support for the App Store/GUI Tailscale variant's LocalAPI token scheme
  (see AR1).
- No auth added to the TCP transport; tailnet identity remains the
  credential.
- No audit-format version field or migration; no consumers exist.
- No `DANTERM_TCP`-style environment variable; TCP targets are always
  explicit.

## Accepted risks

- **AR1.** The App Store/GUI Tailscale variant has no
  `/var/run/tailscaled.socket`, so on such a machine every remote connection
  refuses (fail closed). Accepted: this machine runs nix-darwin's tailscaled,
  and DanTerm has one user. Reopen if the user switches Tailscale variants.
- **AR2.** The LocalAPI path, Host-header requirement, and whois response
  shape are Tailscale-internal surface and could drift with an update
  (successor to the old AR1 on `whois --json` output). Failure mode is
  refusal, never false admission, and PO1's scripted server pins today's
  contract so a drift diagnoses quickly.

## Rejected ideas

- **RI1.** Keep the CLI shell-out as a fallback behind LocalAPI: two live
  resolver paths to test and audit, preserved binary-discovery fragility,
  and the only beneficiary is a Tailscale variant this machine does not run
  (user decision; see AR1's reopen condition).
- **RI2.** A `tailnet.tailscaleBinary` config key: adds config surface to
  keep the dependency the ideal fix removes.
- **RI3.** Only widening the binary candidate list: leaves per-connection
  process spawn and stays fragile to the next install-location drift; the
  failure class recurs instead of dissolving.
- **RI4.** Overloading `--socket` to accept `host:port`: ambiguous grammar
  (a relative path can contain a colon), and the two targets have different
  error surfaces; a separate flag is self-describing.

## Implementation discretion

- Resolver internals: the HTTP read strategy, socket and timeout mechanics,
  timeout constants, error-case names, and how the peer port is plumbed to
  the query.
- Timestamp sub-second precision; exact JSON key names inside the audit
  entry beyond the contract in I3/PO4.
- TCP transport internals: the POSIX calls and socket options used to meet
  the bounded-wait, no-buffering-delay, and disconnect-safety requirements;
  timeout constants; the loopback test fixture shape.
- Which files carry each change.

## Commit progress

- [x] Stable audit JSON: hand-written accounting Codable + symmetric
      decoder, ISO-8601 sorted-keys encoder; existing audit tests updated
      only where they decode. (PO4, part of PO5)
- [x] LocalAPI resolver: scripted-server tests first, rewrite `live`, delete
      `runWhois` and candidates, restate error taxonomy. (PO1)
- [x] CLI TCP target: `TCPSocketTransport`, `--tcp` parsing, target-agnostic
      CLI errors, loopback + characterization tests, SKILL.md + README +
      `usageText`. Gate the commit on the live smoke rerun (dev slot, config
      backed up and restored): admitted `ls`, not-admitted refusal, remote
      `quit` refusal, started/completed audit pair -- record its result in
      the commit message. (PO2, PO3, PO5)
