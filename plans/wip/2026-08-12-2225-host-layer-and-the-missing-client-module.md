# The host layer and the missing client module

Discharges T16 in `research/35/T16`, and supplies the invariant T14 is to enforce.

## Problem

An iOS client cannot link any module in this tree that gives it a DanTerm
conversation. T16 was framed as a split: get the Mac-host roles out of
`DanTermSupport` so the module a client links carries none. Building the
candidates shows the frame is wrong in a way that changes the work.

`DanTermSupport` has no client half to separate out. F1 fixed a *compile*
boundary -- `CLIPathInstaller` and `DoctorProber` are the only two files that
fail for an iOS triple -- but the compile boundary is not the role boundary. Of
the ten files that compile, four are the producer end of the control socket
(`ControlSocketListener` binds it, `IpcConnection` writes server responses and
notifications, `PaneTapeFollow` tracks what the server owes a subscriber,
`PaneTapeRecords` builds the records a server emits), and four more name the
Mac's own filesystem and session (`RecoveryStore`, `CheckpointWriter`,
`InstancePaths`, `DanTermConfigPaths`). A client that imported the "portable
half" would call nothing in it.

What the client needs instead exists three times and is owned by nobody: the
client end of the conversation. `cli/main.swift` hand-rolls connect, framed
read, write, and hello validation; `cli/PaneTapeStream.swift` hand-rolls a
second copy of read and write for the tape stream; the T4 spike hand-rolls a
third, roughly 85 lines, plus its own re-derivation of the tape record shape
from string literals. The record shape has a producer and no reader: the
vocabulary is public in `DanTermProtocol`, but `kind`, `sequence`,
`byteOffset`, and the rest are spelled out inside each reader separately. This
is why T2's spike drove a local `Terminal` with literal bytes rather than a real
tape stream.

Separately, the iOS platform pins and the F2 font seam are still out of the
tree, because a `platforms:` pin is package-level and would have claimed iOS
support for host-only targets.

## Evidence

Built in a worktree at `fe32823b`; every manifest and source patch was applied
to a scratch copy and restored, so the tree is unchanged.

- A candidate client module -- transport seam, framed request/reply/notification
  loop over `IpcLineFramer`, hello handshake, and a tape record decoder -- builds
  for macOS and both iOS triples with `DanTermProtocol` as its only dependency.
  It references nothing in `DanTermSupport`.
- With the F2 font seam applied, a package-level iOS pin on `lib/TerminalCore`
  is false for two of its executable targets: `GlyphPreview` (`no such module
  'AppKit'`) and `TerminalMemoryProbe` (`cannot find 'Process' in scope`). Every
  other executable target in that package, including `TerminalRenderExecution`
  and all the other benchmark and probe executables, builds for the iOS device
  triple.
- That probe enumerated executable targets only, so it did not establish the
  claim I1 makes. Two test targets are also host-bound today, each at a single
  point: `TerminalRenderExecutionTests` calls
  `NSFont.monospacedSystemFont` in `RenderMetricsTests.swift`, and
  `TerminalCoreTests` shells out to `/usr/bin/vmmap` through `Process` in
  `TerminalLogicalLineEvictionProbe.swift`. The `import AppKit` lines in
  `RenderMetricsTests.swift` and `TextExecutionTests.swift` are otherwise
  serving CoreText, which is portable.
- `TerminalRenderExecution` builds for macOS and both iOS triples behind a
  `PlatformFont` typealias guarded by `#if canImport(AppKit)`, confirming F2's
  shape: one import block and one call site.
- `lib/DanTermProtocol` is a single portable target, so its pin is honest as-is.
- The root package already compiles `DanTermSupport` as a real cross-target
  module for `DanTermCLI`, which is why `DoctorProber`'s three declarations are
  `package`. Within-package `package` access serves the CLI; it cannot serve a
  client in a different package.

## Decision

Stop treating `DanTermSupport` as a module with a portable half. Name it as the
Mac host's side-effect layer, leave it whole, and give it no iOS pin. Create the
module the client actually links, as the single owner of the client end of the
conversation, and make the CLI its first consumer so it is exercised by the
existing gate rather than shipped untested.

Concretely, the work has four parts:

1. A new client package holding the client end of the control conversation: a
   transport seam that does not name a socket kind, the framed request /
   reply / notification loop, the hello handshake, and a decoder for the tape
   record shape. It depends on `DanTermProtocol` and nothing else.
2. The CLI's three hand-rolled transport copies are deleted and rewired onto
   that module. The T4 spike is not rewired; it is throwaway evidence.
3. The F2 font seam lands in `TerminalRenderExecution`.
4. iOS platform pins land only on packages where every target builds for iOS.
   `DanTermProtocol` and the new client package qualify today. `TerminalCore`
   qualifies once its host-only entry points leave it. The line is
   iOS-compatible engine and measurement targets versus genuinely host-only
   entry points: `GlyphPreview`, its test target, and `TerminalMemoryProbe`
   move to a sibling host-tools package, and every other benchmark, probe, and
   support target stays in `TerminalCore` because it already builds for the
   iOS device triple. The two host-bound test targets stay in `TerminalCore`:
   the font identity assertion moves onto the same `PlatformFont` seam F2
   introduces, and the `vmmap` dump -- the one genuinely host-only fragment --
   is guarded so the probe reports it as unavailable off the Mac. Neither
   target loses coverage on macOS. `DanTermSupport` and `TerminalPTY` get no
   pin.

The client module's surface is `public`. The annotation tax recorded against a
`DanTermCore` module split does not transfer: that objection is about
field-bearing model structs whose every member the app reads, whereas this
module is a handful of behavioral types designed as an API from the start.
`DanTermSupport` gains no annotations; it stays `internal` plus its existing
three `package` declarations.

## Invariants

- **I1.** A package that declares `.iOS` in `platforms:` has every one of its
  manifest targets build for the iOS device triple, test targets included. This
  is the invariant T14 enforces, and it is why a pin is a claim about a package
  rather than a target. Test targets are not carved out: a carve-out by
  category is the same unchecked claim as an allowlist by name, and the tests
  here are portable at the cost of two guarded fragments.
- **I2.** There is one implementation of the client end of the DanTerm
  conversation: line framing, the hello handshake, request/reply correlation,
  and notification delivery. A second copy inside `cli/` is the defect this plan
  removes.
- **I3.** The pane-tape record shape has exactly one reader and one writer, and
  neither spells the other's field names. A consumer that wants a record's
  fields decodes it; it does not index JSON by literal key.
- **I4.** The client module names no socket kind. AF\_UNIX on the Mac and a
  network transport from the phone are two conformances of one seam, so the
  conversation above them is not rewritten when the transport changes.
- **I5.** `DanTermSupport` carries Mac-host roles only, and nothing outside the
  Mac host links it.
- **I6.** The `danterm` CLI's observable surface -- stdout shapes, parser
  errors, and the messages it prints when DanTerm is absent, unresponsive, or
  speaking a protocol version it does not know -- is unchanged by the rewiring.
- **I7.** macOS rendering is unchanged by the font seam.

## Proof obligations

- **PO1** (I1): the local gate cross-compiles every manifest target of every
  iOS-pinned package -- test targets included, which means the build enables
  them rather than taking SwiftPM's default of skipping them -- for the iOS
  device triple. A static manifest or import check does not
  discharge this, and neither does a periodic build: adding `Process()` to an
  existing pinned target must fail the gate on the change that adds it, not on a
  later scheduled run. The build may be optimized for speed; it may not be
  substituted.
- **PO2** (I2, I6): black-box characterization tests of the `danterm`
  executable, written against the current CLI before any rewiring, and run
  unchanged after it. Each asserts exit status, stdout, and stderr against a
  controlled endpoint: connection refused, no socket present, receive timeout,
  malformed hello, unsupported protocol version, a representative ordinary
  reply, and tape output. A live-slot run is corroboration, not coverage.
- **PO3** (I3): every record the producer builds decodes to the value it was
  built from -- start, gap, event with and without an origin stamp and with and
  without a payload span, and each end reason. This obligation requires a test
  that links both ends, which no current test target does.
- **PO4** (I3): a reader survives a record kind it does not know, so a producer
  can gain one without breaking an older client.
- **PO5** (I4): the conversation runs over a transport that is not a socket.
  Satisfying this in a test is also the evidence that the seam is real.
- **PO6** (I7): the existing render-execution tests pass unchanged on macOS with
  the seam applied, and the module builds for macOS and both iOS triples.
- **PO7** (I5): `DanTermSupport` has no iOS pin, and the lint that enforces I1
  says so rather than leaving it to inspection.
- **PO8** (I2): notifications that arrive while a request is awaiting its
  correlated reply are delivered once and in order. The test interleaves
  notifications before the reply and between two replies, and it sends a reply
  the caller is not waiting for: the pending request is not satisfied by it, and
  no frame is dropped. A loop that discards every frame that is not the awaited
  response fails this.

## Non-goals

- No iOS client, app target, or bundle. This plan makes the module a client
  would link exist and be reachable; it does not build a client.
- No network transport. The seam admits one; T5 supplies it.
- No `pane.snapshot` and no sequence-numbered resume. That is T8, and this plan
  must not pre-empt its record vocabulary.
- No decision about whether the client links the `DanTermCore` model. That is
  T12, and it is independent of everything here.

## Accepted risks

- **AR1.** The claim that a client needs nothing from `DanTermSupport` rests on
  reading each file's role, plus one candidate client module that compiled
  without it. No iOS client has been built. If one turns out to want
  `Debouncer` or `FontAvailability` -- the only two files with no Mac-specific
  meaning -- each is under 80 lines and moves or is rewritten then.
- **AR2.** `TerminalMemoryProbe`'s invocation path changes, so the entry point
  [agent-docs/terminal-performance.md](../../agent-docs/terminal-performance.md)
  documents for it must be updated even though its behavior does not change.

## Rejected ideas

- **RI1. Move the two failing files out of `DanTermSupport`, mark the remaining
  ten `public`, and pin the package.** This is the cheap reading of T16 and it
  was the starting frame. It is rejected because it produces a module named for
  portability that a client still cannot use: eight of the ten remaining files
  are the producer end of the socket or the Mac's own filesystem, so the client
  imports it and calls nothing. It pays `public` annotations on host-role types
  that have no cross-package consumer, it puts an iOS pin on a package whose
  purpose is to serve the Mac host, and it leaves the triplicated client
  transport -- the thing actually blocking a client from linking real code --
  exactly where it is.
- **RI2. Accept a partly false iOS pin on `TerminalCore` and let a lint
  allowlist the two failing targets.** Rejected because it makes the pin mean
  "iOS, except where a list says otherwise", which is the unchecked claim F1
  declined to land. The package is the unit of the platform claim; an allowlist
  hides that rather than resolving it.
