# Milestone 3: PTY process lifecycle

This plan starts and completes Milestone 3 of the Swift terminal-engine
experiment: a native macOS PTY and process-lifecycle owner proven with
controlled child processes, composed headlessly with the Milestone 2 terminal
core. The governing contracts are
[07-pty-process-lifecycle.md](../../plan-terminal-engine/07-pty-process-lifecycle.md)
(lifecycle invariants and proof obligations),
[03-engine-architecture.md](../../plan-terminal-engine/03-engine-architecture.md)
(functional core / imperative shell, one serialized owner per pane),
[12-testing-conformance.md](../../plan-terminal-engine/12-testing-conformance.md)
(deterministic policy proven without the system adapter, narrow real-system
adapter tests), the Milestone 3 exit criteria in
[14-roadmap.md](../../plan-terminal-engine/14-roadmap.md) lines 96-101, and
the Milestone 3 external-test guidance in
[docs/research/1-external-tests.md](../../docs/research/1-external-tests.md)
lines 111-121.

## Problem

No PTY or process code exists in DanTerm's Swift tree; child launch, IO,
resize, exit, and teardown all live inside libghostty today. Milestone 3 must
prove launch, ordered IO, environment, resize, EOF, exit, cancellation, and
teardown with controlled child processes, and show a headless pane running a
shell session without leaking resources or depending on rendering. This
milestone also resolves the two open questions that block implementation: the
concurrency primitive realizing the single serialized pane owner, and the
macOS PTY/process APIs
([15-open-questions.md](../../plan-terminal-engine/15-open-questions.md)
lines 7-11 and 28-32).

Load-bearing evidence (verified):

- `plan-terminal-engine/14-roadmap.md` lines 96-101: the two Milestone 3 exit
  boxes this plan closes.
- `plan-terminal-engine/07-pty-process-lifecycle.md`: the normative lifecycle
  contract -- login-shell selection and fallbacks (lines 27-31), cwd fallback
  and environment override rules (lines 33-38), session/controlling-terminal
  ownership and escalating teardown (lines 39-49), exactly-once exit into the
  existing `surfaceClosed` pane lifecycle (lines 51-54), invariants (lines
  56-70), proof obligations (lines 72-95), discretion on APIs, concurrency
  primitive, and grace durations (lines 110-117).
- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`: `public struct
  Terminal: Equatable, Sendable` (line 4), `init?(columns:rows:)` (114),
  `mutating feed(_ bytes: [UInt8])` (125), `mutating resize(columns:rows:)`
  (141), plus the public snapshot reads. Chunk invariance is already proven
  by `TerminalFixtureTests` (authored/bytewise/split strategies), so PTY read
  chunk boundaries cannot change terminal state -- only byte order matters.
- `lib/TerminalCore/Package.swift`: the standalone-package template
  (swift-tools 6.2, macOS 26, Swift 6 language mode, zero dependencies).
- `justfile` lines 29-46: the `just test` gate is one `swift test
  --package-path lib/<Pkg>` line per package plus purity-lint lines;
  TerminalCore carries tests + pure profile + `--forbid-imports`. Opt-in
  machine-state suites are separate recipes (`test-ui`,
  `test-terminal-characterization`).
- `scripts/core-purity-lint.sh`: pure and portable profiles plus the
  `--forbid-imports` gate.
- `app/TerminalBackend.swift` line 51: `TerminalSessionRequest`
  {workingDirectory, command, launchCommand, waitAfterCommand,
  restoreCommandBehavior, environment} -- the field shapes a Milestone 3
  launch spec must stay compatible with. `app/AppDelegate.swift` line 42: the
  `case .swift: fatalError` backend seam stays untouched this milestone.
- `lib/DanTermCore/Sources/DanTermCore/Persistence.swift` line 77:
  `restoreInitialInput(for:behavior:)` is byte-preserving -- prefill returns
  a non-empty command verbatim (trailing newlines included); execute appends
  one newline only when the command does not already end in one.
  `lib/DanTermCore/Sources/DanTermCore/TerminalLaunchEnvironment.swift`:
  pane-scoped `DANTERM_*` variables and `DANTERM_RESTORE_SCROLLBACK_FILE`.
- `lib/TerminalCore/Tests/TerminalCoreTests/TerminalFixtureTests.swift` lines
  520-531: fixture feed events carry `text` or `hex` -- the neutral form a
  raw PTY recording must serialize to.
- `docs/research/1-external-tests.md` lines 111-121: no imported fixture
  tranche for Milestone 3; add DanTerm-owned controlled-child recordings;
  preserve raw PTY output in neutral-runner-consumable form.

## Decision

Build Milestone 3 in three fixed slices: (1) a pure, import-free lifecycle
reducer with exhaustive trace tests; (2) the native macOS PTY owner actor
with controlled-child integration tests; (3) session teardown with bounded
escalation, race/leak proofs, the initial-input seam, and docs closure.

### Package layout and test gate

A new standalone SwiftPM package under `lib/` (working name
`lib/TerminalPTY`; final names are discretion, the layering and lint profile
are contract) with two library targets and matching test targets:

| Target (working name) | Role | Imports | Lint |
|---|---|---|---|
| PaneLifecycle | Pure lifecycle reducer + pure launch-spec policy | none (import-free) | pure profile + `--forbid-imports` |
| TerminalPTYHost | PTY/process owner actor, kqueue sources, teardown mechanism | Darwin, Dispatch, Foundation; depends on PaneLifecycle and TerminalCore (local path `../TerminalCore`) | none (it IS the system mechanism) |

The policy target is import-free like TerminalCore, not Foundation-allowed:
the reducer models time as opaque grace tokens delivered back as events, and
its data is byte arrays, strings, and small value types -- nothing requires
Foundation, and the import-free gate gives the same structural purity proof
TerminalCore already has. `just test` gains three lines mirroring the
TerminalCore pattern:

```
swift test --package-path lib/TerminalPTY
./scripts/core-purity-lint.sh lib/TerminalPTY/Sources/PaneLifecycle
./scripts/core-purity-lint.sh --forbid-imports lib/TerminalPTY/Sources/PaneLifecycle
```

plus one opt-in recipe (working name `test-pty-external`) for the ssh and
tmux teardown proofs, gated the way `test-terminal-characterization` is.

### Resolved open question: spawn mechanism is posix_spawn plus bootstrap

Recorded as decided (removes the runtime-integration open question in
`plan-terminal-engine/15-open-questions.md`). The app launches a tiny
DanTerm-owned bootstrap executable with `posix_spawn`; that bootstrap performs
the child-only `setsid`, `TIOCSCTTY`, foreground-process-group, standard-stream,
cwd, and `execve` steps needed to start the shell. A close-on-exec status pipe
reports bootstrap setup and exec failures synchronously to the spawn worker.
The spawn attributes and bootstrap together reset signal dispositions and the
mask, bind standard streams to the slave, inherit no unrelated descriptors,
use login-form `argv[0]`, and supply the explicit environment (I6, pinned by
PO3/PO4). Cwd fallback (requested directory if accessible, else home, else `/`)
is parent-side deterministic policy resolved before spawn; a bootstrap failure
attributable to the working directory returns to the reducer, which retries the
next step of the chain. Rationale: macOS does not acquire a controlling terminal
when the slave is merely opened, and the public `posix_spawn` file-action API has
no `TIOCSCTTY` action. The bootstrap preserves the no-fork-in-the-app constraint,
descriptor hygiene, and synchronous classified launch failures.

### Resolved open question: pane owner is an actor on a DispatchSerialQueue executor

Recorded as decided (removes the architecture-and-concurrency open
question). One serial dispatch queue is the actor's executor and the total
FIFO order over PTY reads, child exit, app commands, and escalation timers;
read-only state leaves the owner as `Sendable` `Terminal` value copies.
Rationale: the queue provides the total order either way; the actor layer
makes the single-ownership invariant compiler-checked under Swift 6.

That queue is also the only context that can run close and escalation, so
no host operation may block or monopolize it: writes to the master are
readiness-driven and may complete partially across turns, reads and writes
do bounded work per turn, and launch outcomes arrive as events rather than
being awaited inline. A child that has stopped reading while a large write
is outstanding, and a child that writes continuously, must each still close
within the teardown bound (I13, PO9).

### Lifecycle policy vocabulary

The reducer is `(state, event) -> (state, ordered commands)`. Contract-level
categories (exact cases are discretion):

| Events into the reducer | Origin |
|---|---|
| start(launch inputs), send input, request resize, request close, app termination | app intent |
| spawn succeeded, spawn failed (classified: cwd-missing vs other) | spawn outcome |
| output bytes read, output EOF | master IO |
| child exited(status) | process observation |
| grace elapsed(stage), session drained | timers / teardown progress |

| Commands out of the reducer | Interpreted by the host as |
|---|---|
| spawn(resolved spec: program, login argv, cwd, env, initial winsize) | openpty + posix_spawn bootstrap |
| write input(bytes) | write to master |
| resize(cols, rows) | one ordered transition applying the new geometry to both the composed `Terminal` and the kernel winsize, notifying the child |
| deliver output(bytes) | `Terminal.feed` + recording hook |
| close master | hangup |
| signal session stage(n) | enumerate + signal owned session |
| schedule grace(stage) / cancel grace | timer source |
| report exit(status) / report failure(reason) | product-level event, exactly once |
| finish teardown | release sources, reap child |

The launch spec is resolved by pure policy functions in the policy target
over injected inputs (account shell path, accessibility flags, inherited
environment snapshot): shell selection (account shell from the macOS account
database, else `/bin/zsh`, else `/bin/sh`), login `argv[0]`, cwd fallback
chain, environment merge (inherited app environment with advertised terminal
variables and pane `DANTERM_*` values overriding). Initial input is pure
policy mirroring `restoreInitialInput` byte for byte: prefill produces
exactly one write carrying the non-empty command verbatim, including any
trailing newline it already has; `--cmd`/launchCommand and restore execute
produce exactly one write with a single newline appended only when the
command does not already end in one; recovery replay delivers
`DANTERM_RESTORE_SCROLLBACK_FILE` in the spawn environment. Per doc
07 lines 29-31 there is no direct-exec launch mode: every requested command
is initial input to the ordinary interactive login shell.
`waitAfterCommand` has no Milestone 3 semantics (it only modified direct
exec); its product meaning is resolved at the Milestone 4 facade wiring.
Output bytes route through a policy-emitted deliver command so that bytes
arriving after a close decision are dropped deterministically instead of
feeding torn-down state.

### Teardown ladder

Policy drives stages as deterministic transitions: stage 1 SIGHUP (with
SIGCONT so stopped jobs can act on it) plus master close, grace, stage 2
SIGTERM (with SIGCONT), grace, stage 3 SIGKILL. Each stage targets every
process still in the owned session, not just the foreground group; the host
re-enumerates the session per stage, re-checks session membership
immediately before each signal, and reports an empty enumeration as a
session-drained event so policy finishes early. Only the leader is our
child; it alone is reaped, exactly once. Bounded close time (the sum of the
grace periods plus constant work) is contract; exact durations are
discretion per doc 07.

### Self-exit convergence

When the child exits on its own, the product-level exit is not reported at
the instant the exit event arrives. Self-exit is a bounded cleanup
transition with a defined output cutoff: bytes already committed to the
master when the leader's exit is observed are drained and delivered in
order before the master is closed; output written after that point by
surviving descendants may be dropped. Once the drain completes the leader
is reaped, any process still remaining in the owned session is terminated
through the same bounded ladder, and only then is exit reported, exactly
once. The cutoff is what makes cleanup converge: without it a continuously
writing background descendant would make "drain until empty" unbounded,
while closing the master before the drain would cut off the shell's final
bytes.

### Reducer trace tests (Slice 1)

Lifecycle traces are Swift-authored in the policy test target, not JSON
fixtures. Justification: unlike Milestone 2 there is no external corpus to
import (`docs/research/1-external-tests.md` line 112), the vocabulary is
DanTerm-internal and still moving (compile-checked traces beat a
serialization layer), and race coverage needs programmatic interleaving
generation, which JSON cannot express. Coverage strategy: golden
event-to-command sequence tests for the canonical orderings, plus a
permutation harness that, for each racing multiset (close vs spawn outcome,
close vs bytes/EOF, close vs exit, close vs spawn failure, resize vs close,
grace elapsed vs exit, EOF-before-exit and exit-before-EOF), replays every
interleaving and asserts invariant predicates: exactly-once report commands,
no spawn after close, no deliver after close, no commands from a finished
state, monotone stage progression.

### Controlled-child integration tests (Slices 2 and 3)

Helper children are spawned through the real recipe and report facts as
parseable lines over the PTY (and pid/marker files in the test scratch
directory): a probe reporting `getsid(0)`, `tcgetpgrp` of the controlling
tty, `ttyname`/`isatty` of fds 0-2, cwd, and selected environment; shell
scripts that `trap '' HUP TERM` (hangup-resistant), background jobs (`... &`
with pid reported), and stopped jobs (SIGSTOP after a ready marker). Tests
synchronize on ready markers, never sleeps. Everything needing only
`/bin/sh`, `/bin/zsh`, and standard tools runs headless in the default
`just test` gate (PTY tests need no GUI). The ssh and tmux teardown proofs
from doc 07 are opt-in (`test-pty-external`): they require Remote Login
enabled and tmux installed -- machine state the default gate must not
assume, same reasoning as `test-terminal-characterization`. The Milestone 3
roadmap boxes close on the controlled-child evidence; the ssh/tmux clauses
of doc 07's teardown PO are implemented but recorded as opt-in evidence
toward the later replacement gate.

### Raw PTY recording hook (Slice 2)

A small test-support recorder in the host test target observes every
transition the owner applies to the composed `Terminal` and serializes a
session as a complete neutral recording: version, DanTerm-authored
provenance, initial dims, and the owner-ordered event stream -- hex `feed`
events interleaved with the `resize` events at the exact positions they were
applied -- written to a directory named by an environment variable when set.
Recording read chunks alone would replay an output/resize/output session
entirely at the initial geometry and diverge from the live state, so the
recorder's input is the ordered command stream, not the read loop. The Milestone 3 guidance requires recordings the neutral replay
runner can feed directly into TerminalCore, so that runner's decode and
replay half stops being private to TerminalCore's test target and becomes a
component both packages' tests use, with provenance validation source-aware
instead of asserting `source == "libvterm"`. A failed system test is then
reduced by replaying its recording through the same path the corpus uses,
with no manual schema adaptation. What stays deferred is corpus membership:
fixture discovery, the manifest, and the gate that replays the permanent
corpus are untouched, so an emitted recording is replayable on demand but is
not yet a corpus fixture (non-goal below). Not a product feature.

### Headless pane session composition (Slice 2)

The owner actor composes lifecycle policy plus a `Terminal` value: events
enter on the queue, the reducer runs, commands execute in emission order,
deliver-output commands feed `Terminal` and resize commands apply to both
`Terminal` and the kernel winsize on that queue, and snapshot reads return
`Terminal` copies. Its launch spec mirrors the
`TerminalSessionRequest` fields so Milestone 4 can wire the
`TerminalSession` facade without reshaping anything; the facade, the
`AppDelegate` seam, and all AppKit integration are explicitly out of scope
this milestone.

### Docs closure (Slice 3)

Check the two Milestone 3 boxes in `plan-terminal-engine/14-roadmap.md` with
judgment text naming the proving tests; delete the two resolved questions
from `plan-terminal-engine/15-open-questions.md` (single-owner concurrency
primitive; macOS PTY/IO APIs); add the two decisions to "Decisions already
fixed" in `plan-terminal-engine/README.md`. Nothing else.

## Invariants

- I1: A pane session has exactly one owner and at most one live child
  session; identical event order produces identical state and command order.
- I2: All inputs (PTY reads, child exit, timers, app commands) serialize
  through the owner's single queue; commands execute in emission order; no
  observer sees a partially applied transition.
- I3: Master-to-terminal byte order is preserved. Bytes committed to the
  master before the leader's exit is observed are delivered even when that
  exit is observed first; output written past that cutoff by surviving
  descendants, and output arriving after a user-initiated close decision,
  is dropped deterministically, never delivered to torn-down state.
- I4: Exit or failure is reported exactly once across every interleaving,
  and on self-exit only after cleanup converges (pre-cutoff output drained,
  leader reaped, remaining session members terminated); spawn is issued at
  most once per step of the cwd fallback chain (requested, home, `/`) and
  never after close.
- I5: Initial input (`--cmd`, restore prefill, restore execute, recovery
  replay) is delivered exactly once, byte-identical to
  `restoreInitialInput`'s contract; no launch spec produces a direct-exec
  mode.
- I6: The child is a session leader whose controlling terminal is the slave,
  with stdio on the slave, its process group foreground, login `argv[0]`,
  the contract shell-selection and cwd fallback chains, and the contract
  environment merge.
- I7: A resize is one ordered transition that leaves the composed
  `Terminal` and the kernel winsize at the same dimensions and notifies the
  child, ordered with respect to surrounding IO; no observer can read a
  terminal snapshot whose geometry disagrees with what the child sees.
- I8: Closing a pane terminates every non-daemonized process remaining in
  the owned session within bounded time without touching sibling sessions;
  orderly app termination applies the same bound to every pane.
- I9: After teardown completes there are no open pane fds, no live dispatch
  sources, no callbacks into deallocated or torn-down state, and the child
  is reaped exactly once (no zombies).
- I10: The policy target performs no IO and has no imports (lint-enforced);
  system calls exist only in the host target.
- I11: Every transition applied to the composed `Terminal` -- master bytes
  and resizes alike -- is preserved in its applied order as a complete
  neutral recording; replaying an emitted recording through the shared
  neutral replay path (the same one the fixture corpus uses) reproduces the
  live session's terminal state, with no manual adaptation step.
- I12: A roadmap box closes only with its behavioral evidence named in the
  adjacent judgment text.
- I13: No host operation blocks or monopolizes the owner's queue: a child
  that stops reading with a write outstanding, or that writes continuously,
  cannot delay close past the teardown bound.

## Proof obligations

- PO1 (I1, I2, I4, I5): Golden reducer traces for launch, readiness, resize,
  EOF-then-exit, exit-then-EOF, spawn failure with cwd-fallback retry,
  self-exit, and user close, asserting exact ordered command sequences.
- PO2 (I2, I3, I4): The permutation harness replays every interleaving of
  each racing event multiset (close vs spawn outcome / bytes / EOF / exit /
  failure; resize vs close; grace vs exit) and asserts the invariant
  predicates, including exactly-once reporting and cancellation (close while
  spawning leaves no orphan path).
- PO3 (I6): The first integration test pins session leadership,
  controlling-terminal acquisition, foreground process group, and
  slave-bound stdio via the probe child.
- PO4 (I6): Controlled children observe shell selection and fallbacks
  (injected-lookup pure tests plus a real-spawn test), login `argv[0]`, the
  cwd fallback chain, and inherited-plus-override environment including
  `DANTERM_*`.
- PO5 (I3, I7): Ordered byte IO in both directions, including large and
  fragmented output delivered in order without deadlock or unbounded
  buffering; geometry correct at open; after a resize a WINCH-trapping child
  reports the new dimensions and a terminal snapshot taken afterwards shows
  the same dimensions.
- PO6 (I3, I4, I8, I9): EOF and exit status observed in both orders; a child
  that writes a final marker and exits while a background child holds the
  slave and keeps writing continuously delivers the marker, terminates the
  descendant, reaps the leader, and reports exit exactly once within the
  teardown bound, leaving no zombie.
- PO7 (I8): Teardown ladder terminates a shell with foreground, background,
  stopped, and hangup-resistant jobs; enumeration reaches empty; a sibling
  pane's session is untouched.
- PO8 (I9): Rapid create/close and resize/close stress leaves no leaked fds
  (fd census before/after), no live sources, and no callbacks after
  teardown.
- PO9 (I8, I13): Orderly app-termination teardown over multiple live panes
  completes within the bound, including a pane whose child stopped reading
  with a large write outstanding and a pane whose child writes continuously.
- PO10 (I5): The controlled app/PTY seam proves exactly-once delivery of
  `--cmd`, restore prefill, restore execute, and recovery replay into the
  interactive login shell, byte-identical to `restoreInitialInput` including
  commands that already end in a newline.
- PO11 (I11): Recording round-trip over a session that emits output, is
  resized, and emits more output: the emitted recording, decoded and
  replayed by the shared neutral replay path, yields a `Terminal` equal to
  the live session state; the existing libvterm corpus suite stays green
  across the provenance generalization.
- PO12 (I10): The two new purity-lint gate lines pass.
- PO13 (I8, opt-in): ssh and tmux sessions are torn down without survivors
  under `test-pty-external`.
- PO14 (I12): Roadmap boxes close with named evidence and `just test` green.

## Non-goals

- `TerminalSession`/`TerminalBackend` facade wiring, the `AppDelegate` swift
  seam, AppKit, rendering, and input (Milestone 4).
- The sleep/wake proof obligation from doc 07 line 94: explicitly deferred
  to Milestone 4 -- it is absent from the Milestone 3 roadmap line and not
  provable headless.
- A process broker, daemon, or session survival/reconnect; cross-platform
  PTY APIs; shell-integration semantics (doc 07 non-goals).
- Renderer backpressure/flow-control policy beyond ordered delivery.
- Corpus membership for emitted recordings -- fixture discovery, manifest
  entry, and gate replay: deferred to the first promoted recording. The
  runner's decode and provenance support is delivered this milestone.

## Accepted risks

- AR1: Pid-reuse TOCTOU between enumeration and signal; mitigated by the
  session-membership re-check immediately before each signal; the residual
  window is accepted.
- AR2: Deliberately daemonized processes escape the owned session (doc 07
  accepted risk restated, unchanged).
- AR3: The real account-shell value cannot be controlled on a developer
  machine; fallback ordering is proven with injected lookups, and the real
  spawn test asserts only recipe-consistent facts.
- AR4: ssh/tmux teardown proofs run opt-in, so the default gate does not
  continuously exercise them; prerequisites are documented in the recipe.
- AR5: Integration tests involve real grace timers; determinism lives in the
  reducer layer, and integration bounds are generous with marker-based
  synchronization to avoid flakes.

## Rejected ideas

- RI1: fork/exec via a C shim -- async-signal-safety burden and manual fd
  hygiene in the multithreaded app. The spawned bootstrap is different: it is
  already a single-threaded child process when it performs `TIOCSCTTY` and
  `execve`, which public `posix_spawn` actions cannot express on macOS.
- RI2: `forkpty` -- same fork burden with less attribute control.
- RI3: `@unchecked Sendable` class plus bare queue -- ownership unchecked by
  the compiler.
- RI4: Default actor with an AsyncStream event funnel -- manual ordering,
  unbounded buffering risk, and kqueue still needs GCD.
- RI5: JSON lifecycle trace fixtures -- no external corpus, no interleaving
  generation, needless serialization layer.
- RI6: Foundation-allowed policy target -- forfeits the import-free
  structural proof for zero need.
- RI7: killpg on the foreground group only -- misses background and stopped
  jobs in the session.
- RI8: Foundation `Process` -- no PTY, no setsid/ctty control.
- RI9: Direct-exec mode for `--cmd`/launchCommand -- contradicts doc 07's
  initial-input contract.
- RI10: Recording as a product feature -- test-support only per the
  external-tests guidance.

## Implementation discretion

- The concrete spawn attributes and file actions, the executor-entry and
  event-source topology, and the session-enumeration API -- the behavior
  they must produce is pinned by I2, I6, I8, I13 and PO3, PO7, PO9.
- Package, target, type, and helper names (working names above); read-buffer
  sizes; exact grace durations (bounded close is contract); probe
  implementation (compiled helper executable versus shell reporting); the
  permutation-harness mechanics; where the shared neutral replay path lives
  and how its provenance validation is parameterized, provided both the
  corpus suite and the PTY round-trip use it; recorder serialization details
  beyond recording-format compatibility; how account-shell lookup and fs
  accessibility
  are injected into pure policy; edge precedence when both `command` and
  `launchCommand` are present (must be deterministic and trace-pinned);
  commit slicing within slices provided every commit is green and
  failing-test-first (repo TDD rule, `AGENTS.md` line 219).

## Verification

- Targeted: `swift test --package-path lib/TerminalPTY` (optionally
  `--filter` per suite).
- Lint: `./scripts/core-purity-lint.sh lib/TerminalPTY/Sources/PaneLifecycle`
  and the same path with `--forbid-imports`.
- Full gate: `just test` (all packages, lints, script self-tests) before the
  docs commit that closes the boxes.
- Opt-in: `just test-pty-external` (requires Remote Login enabled for the
  ssh proof and tmux on PATH).

## Commit progress

Each slice lands its package/gate wiring with its first behavior, and every
commit is green and failing-test-first.

- [x] 1. Deterministic lifecycle reducer and pure launch-spec policy, with
  golden traces and the interleaving harness (PO1, PO2, PO4 pure half, PO12).
- [x] 2. Native macOS PTY owner with controlled children: launch, ordered
  duplex IO, resize, EOF, self-exit convergence, headless composition, and
  the recording round-trip (PO3, PO4, PO5, PO6, PO11).
- [ ] 3. Teardown ladder, race and leak proofs, liveness under a stalled and
  a chatty child, the initial-input seam, the opt-in external recipe, and
  docs closure (PO7, PO8, PO9, PO10, PO13, PO14).

## Implementation notes

- Slice 2 pivoted from a shell-only `POSIX_SPAWN_SETSID` recipe to a
  `posix_spawn`ed bootstrap after the controlled-child tests showed that the
  slave was not a controlling terminal and resize produced no `SIGWINCH`.
  macOS `tty(4)` requires child-side `TIOCSCTTY`, while the public spawn file
  actions expose no ioctl operation; the bootstrap and close-on-exec status
  pipe preserve the plan's no-fork-in-the-app and classified-failure goals.
