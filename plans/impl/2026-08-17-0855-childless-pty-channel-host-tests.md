# Drive the PTY host's tests through a real channel with no child

## Context

`TerminalPTYHostTests` is one serialized suite of 83 tests. 75 of them start a
host, and 33 fork `/bin/sh` plus a `PTYProbe` child whose only job is to hold the
PTY open, because the host's byte plane is reachable only through a real master
descriptor: input writes, `TIOCSWINSZ`, and `FIONREAD` all no-op when
`masterFD < 0`. The other half of the byte plane is faked instead --
`deliverOutputForTesting` applies child output directly, bypassing the read loop
-- so every such test is half real transport and half bypass, and pays a fork,
a shell, and a marker handshake for the real half.

Two costs follow. The host ships two test-only surfaces in release builds: the
direct output entry point, and an injected write errno with a matching branch in
the flush path. And the tests carry a marker protocol that exists only because a
real shell echoes its own command line before running it -- the `printMarker`
helper's own comment is an argument about what such a wait actually proves.

The desired outcome: the host's own tests drive it exactly as production does --
bytes in and out across a real PTY master descriptor -- with no child process,
no shell, no marker handshake, and no test-only branch in the host.

**This is not a wall-clock fix.** Measured warm on this machine: the PTY lane
runs 26.1s (suite 18.0s, descriptor-census lane 2.2s) against a gate whose
critical path is the TerminalCore lane at 57.9s. Any speedup here is incidental,
and per `agent-docs/measurement-discipline.md` it is not a success criterion.

Load-bearing premises, verified against the tree:

- The host already isolates its nondeterministic edges behind constructor-injected
  witnesses for spawning, child-exit probing, and source/descriptor lifecycle, and
  `scripts/terminal-pty-host-test-seam-lint.sh` already fails the gate when
  ad-hoc test knobs return to the host. This plan extends that pattern; it does
  not introduce it.
- Every process-plane step in the host -- session signalling, session kill,
  leader reap, child-exit handling -- already guards on an absent leader or
  session. Only dispatch process-source installation assumes a child exists.
- The tests the original audit finding called duplicates of `TerminalCore` policy
  are not duplicates: they assert bytes at the child descriptor, owner-queue
  frame publication, and update-signal counts, none of which `TerminalCore` can
  observe. That half of the finding is dropped.

## Decision

**D1 -- State the seam rule, durably.** The host never asks whether it is under
test: it must not query test identity and must not branch on a test-only fault
flag. That, and only that, is the defect. Everything else a test does to a host
it does in domain terms -- supplying an ordinary domain value, or driving a
transition the host's own domain defines -- and the route may be a
constructor-injected collaborator, a direct event entry point, or plain
observation-only capture. Injection is the usual route, not the only legal one,
and the production implementation of a collaborator need not be able to produce
every domain value the type permits. Record this as a new dated ADR in
`docs/design/`,
indexed in `docs/design/index.md`, because three separate pieces of work --
this plan, the wider PTY test-seam cleanup, and the AppRuntime effect-ports
work -- each depend on it and would otherwise argue against each other. A plan
is not a durable home for a rule cited from several places.

**D2 -- The injected collaborator supplies a real PTY channel with no child.**
The host keeps its own `read`/`write`/`ioctl` calls on a real master descriptor;
what a test substitutes is the adopted channel, not the byte path. A test owns
the slave end and plays the child directly: writing to it produces child output
through the host's real read source, reading from it proves the bytes the host
transmitted, and closing it produces the real end-of-output edge. Nothing about
the host's read turn, backpressure, or reply path is simulated.

**D3 -- Child identity becomes explicit and optional in the adopted-channel
model.** A host can own a byte plane with no child session. The channel model
carries leader and session identity together and permits their absence, and
source installation learns that absence. This is data on an injected value, not
a branch on being under test.

**D4 -- Delete what the real channel makes unnecessary.** The injected input-write
errno and its branch in the flush path go: a closed slave end produces the real
descriptor failure. The marker-and-echo shell dances go from every converted
test, since nothing echoes a command line any more.

**D5 -- Direct output application survives only as a consumer-side fixture.** The
pane-session tests use it to stage a host as a fixture while asserting consumer
behavior (publish deadlines, synchronization fences); that is legitimate setup,
not a bypassed seam. It moves under `#if DEBUG` so it leaves shipping builds,
and its name says it is fixture staging. The host's own suite calls it zero
times.

**D6 -- Serialization applies to what actually shares machine state.** Tests on a
childless channel neither fork nor signal, and run unserialized. A test that
stays serialized names the shared resource it needs. Classify each test by what
it asserts, never by trying it and seeing whether it flakes.

**D7 -- Probe files: nothing is deleted, moved, or edited by this plan.**
`PTYProbe` stays; the real-fork lifecycle, teardown, exit-convergence, and
descriptor-census tests keep using it, and they exercise production lifecycle
rather than a frozen prototype. The frozen scrollback probes that
`research/31/D4` protects are a different finding's scope and are untouched
here. This settles the probe-file ordering constraint for this work by scope.

## Invariants

- **I1.** No production source file in `TerminalPTYHost` conditions its behavior
  on test identity or on a test-only fault flag.
- **I2.** Bytes a `TerminalPTYHostTests` case asserts on have crossed a real PTY
  master descriptor in the direction the assertion is about: child output through
  the host's own read path, host transmission through its own write path and
  observed from the slave end.
- **I3.** A host that owns a channel with no child signals no process and reaps
  no process, and still converges to quiescence on shutdown.
- **I4.** Serialization is a stated dependency on a named shared resource, not a
  suite-wide default.
- **I5.** Input-write failure and partial-write rejection are proved by a real
  descriptor failure.
- **I6.** The seam rule in D1 is citable from outside any plan file.

## Proof obligations

- **PO1.** A host on a childless channel starts, receives output, transmits
  input, resizes, and reaches quiescence on shutdown without signalling or
  reaping anything. (I3)
- **PO2.** Bytes written to the slave end appear in a fenced snapshot, and bytes
  the host transmits are read back from the slave end. The second half is new
  coverage: input capture today records submission, not transmission. (I2)
- **PO3.** Closing the slave end drives the host's end-of-output edge, and input
  submitted afterwards is rejected as a real descriptor failure. A submission
  large enough to be held under backpressure, whose prefix has already crossed
  the master when the slave closes, is rejected whole with that same real
  descriptor error -- never reported delivered, and never rejected as a mere
  process end. (I5)
- **PO4.** The real-fork tests -- exit convergence, the teardown ladder, session
  ownership, and the process-wide descriptor census in its own lane -- pass
  unchanged. (premise: the seam did not weaken process-plane coverage)
- **PO5.** The seam lint fails when a deleted host seam returns, and fails when
  the host's own suite applies output directly. (I1, I2)
- **PO6.** A resize on a childless channel reaches the descriptor and the
  terminal geometry follows, proving the channel is a real PTY rather than a
  socket pair. (I2)

## Non-goals

- Reducing gate wall clock. Not a success criterion; see the measured baseline
  above.
- Relocating host tests into `TerminalCore`. The cited cases assert
  host-boundary facts `TerminalCore` cannot observe.
- Converting the pane-session consumer tests away from fixture output (D5).
- Touching the DEBUG output-observer window, the interaction entry point, or the
  exit-bound entry point. Under D1 they are legal: observation, and entry points
  that drive transitions the host's own domain already defines. None asks whether
  it is under test.

## Accepted risks

- **AR1.** Permitting an absent child adds one presence check to source
  installation. Accepted: the rest of the process plane already guards absence,
  and the check reads an injected value rather than a test flag.
- **AR2.** Converted tests trade synchronous byte application for real
  asynchronous arrival, so a test counting owner turns must anchor on a stated
  synchronization point. Accepted: that is the production ordering, and a test
  that cannot state its synchronization point was asserting an artifact of the
  bypass.
- **AR3.** Each childless channel owns two real descriptors. A leak surfaces in
  the process-wide census lane, not in the test that leaked it.

## Rejected ideas

- **RI1.** An in-memory transport protocol over the host's read, write, and
  ioctl calls -- the audit's original proposal. Rejected: it creates a second
  byte path that can drift from the real read loop, which is the risk the audit
  named against itself. A childless real PTY removes the fork without a second
  path.
- **RI2.** Keeping the suite serialized and merely deleting the "duplicate"
  policy tests -- the audit's cheaper fallback. Rejected: it deletes coverage
  that is not duplicated and leaves the seam half-built.
- **RI3.** A childless channel reporting the test process's own identity as the
  leader or session. Rejected: forced teardown kills every member of the owned
  session, so the suite could kill its own runner.

## Implementation discretion

- Where the childless channel lives among the existing PTY test-support targets,
  and its API shape. Note it cannot rely on `@testable`, so the adopted-channel
  model needs package-level access to be constructed from a test-support target.
- Which converted cases anchor on an armed output expectation and which on
  fenced polling.

## Critical files

- `lib/TerminalPTY/Sources/TerminalPTYHost/PTYSpawner.swift` -- adopted-channel
  model and its access level.
- `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift` -- source
  installation learns child absence; injected write-failure branch deleted;
  fixture output gated and renamed.
- `lib/TerminalPTY/TestSupport/TerminalPTYTestSupport/` -- the childless channel;
  the marker helper's remaining users shrink to the real-fork tests.
- `lib/TerminalPTY/Tests/TerminalPTYHostTests/TerminalPTYHostTests.swift` --
  conversion and the serialized/unserialized split.
- `scripts/terminal-pty-host-test-seam-lint.sh` -- the removed names, and the
  ban on direct output application in the host's own suite.
- `docs/design/` plus `docs/design/index.md` -- the D1 decision record.

## Verification

`just test` is the gate. Within it, `./scripts/test-terminal-pty.sh` covers both
PTY lanes, and the seam lint plus its own self-test cover PO5. Confirm the host
suite's test count does not fall: this plan converts tests, it deletes none.
`swift test --package-path lib/TerminalPTY` targeted while iterating; run each
suite once into a file under `.build/` and grep the file.

## Commit progress

- [x] 1. docs(design): record the test-seam rule for owning components (D1, I6)
- [ ] 2. feat(pty): let a host adopt a PTY channel with no child (D2, D3, I2, I3, PO1, PO2, PO6)
- [ ] 3. refactor(pty): prove input-write failure with a real descriptor (D4, I1, I5, PO3)
- [ ] 4. test(pty): drive the host suite through childless PTY channels (D4, D7, I2, PO4)
- [ ] 5. test(pty): serialize only the tests that share machine state (D6, I4)
- [ ] 6. refactor(pty): keep fixture output staging out of shipping builds (D5, I1, PO5)
