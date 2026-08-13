# Pane input and creation replies must not lie

## Problem

A pane becomes addressable over IPC before its process exists, and every
operation aimed at it in that window reports success while doing nothing.

Evidence, all current behavior:

- `pane split`, `tab new`, and `group new` -- every IPC method that creates a
  session -- build their reply in the same dispatch pass that emits
  `.createSession`
  (`lib/DanTermCore/Sources/DanTermCore/IpcDispatch.swift`), and the runtime
  performs that list in order (`app/AppRuntime.swift`). But `.createSession`
  only installs the session object and enqueues the launch; the spawn hops to a
  shared concurrent queue and completes later. When the CLI returns, the PTY
  master fd may not exist.
- Input reaching the lifecycle reducer before the process runs falls through
  `default: return []`
  (`lib/TerminalPTY/Sources/PaneProcessLifecycle/PaneProcessLifecycle.swift`).
  The bytes are discarded with no buffering and no error. This is not
  IPC-specific: a GUI keystroke during a slow spawn is dropped by the same arm.
- When session creation fails synchronously, the runtime sends
  `.sessionCreationFailed` and breaks, but the loop still performs the reply
  dispatch appended. The caller gets success and a pane reference for a session
  that never existed.
- `pane input` aimed at a pane with no live session is a silent no-op that has
  already been answered `ok` (`app/AppRuntime.swift`).

The only readiness signal in the model is the shell-integration latch
(`lib/DanTermCore/Sources/DanTermCore/PaneLifecycleReducer.swift`), which is
opt-in and stays at its initial value forever when the shell snippets are not
sourced, so it cannot serve as a barrier.

`integrations/danterm/SKILL.md` documents the workaround -- prefer `--cmd` over
split-then-send -- and calls it a shell-prompt race. That framing is wrong:
once the fd exists, bytes written before the prompt sit in the kernel tty input
queue and are read normally. The race is a *spawn* race. `--cmd` is safe only
because it is carried as launch input and written from inside the state machine
the moment the spawn succeeds.

## Desired outcome

Addressability never implies process readiness, and no operation answers
success unless it happened. Split-then-send becomes correct, and `--cmd`
becomes an ergonomic shorthand rather than a race workaround.

## Decision

Three changes, in dependency order. The first makes the reported bug class
impossible; the second and third make the results honest.

**D1. The input path buffers instead of dropping.** Pending input is held in
the pre-running lifecycle states and flushed when the process starts. The
launch command becomes the first entry in that buffer rather than a separate
mechanism written on the success edge, so the two paths collapse into one and
arrival order alone decides sequence. The buffer survives the
working-directory retry ladder, as launch input does today. This fixes GUI
keystrokes during spawn as well as IPC input.

**D2. A reply is written at its effect's completion edge.** Every IPC method
that creates a session -- `pane split`, `tab new`, and `group new` alike --
stops appending a reply as a sibling of the creation command and instead
carries the request identity into the effect, answered when the effect
terminates -- success once the process runs, error on launch failure, creation
failure, close during spawn, and shutdown. The pending request identity lives
in the pure model keyed by session, so `update()` answers every terminating
edge; a runtime-side table would be a shadow model and would miss the
close-during-spawn edge. The deferred-reply shape already exists in the runtime
for permission probing.

Completion means the process is running. It deliberately does not mean the
shell has reached a prompt, which is unknowable without opt-in integration.

The same rule governs input, or D1 introduces a fresh lie. Handing bytes to the
host is not delivery: the host's own pending queue retains bytes across
`EAGAIN` and discards them outright when a write fails hard or the descriptor
closes, so a reply written when the lifecycle emits its write would still claim
a delivery that never happened. Input completion is therefore the whole
submission crossing the PTY master fd, and every submission ends in exactly one
result -- delivered, or rejected because the spawn failed, the process ended,
or the write failed. Because several submissions can be in flight against one
pane, the pending identity here is per submission, not per session.

The host already carries submission boundaries to that exact edge: it tags
pending bytes with their originating submission and splits each successful
write at those boundaries. Completion reporting attaches to that existing seam
rather than introducing a second tracking structure.

Shutdown is a terminating edge like any other. Today it drops every pending
request by clearing the connection census without answering
(`app/AppRuntime.swift`), which under D2 would strand a caller waiting on a
spawn. Shutdown must instead answer every still-unanswered request with an
error before closing the transports.

**D3. The process phase is observable.** Spawn and exit become sibling cases of
the backend-neutral session-event vocabulary alongside the existing
`closeRequested` host fact
(`lib/DanTermCore/Sources/DanTermCore/TerminalBackendBoundary.swift`), reduced
in `update()` into session-owned state and projected into the pane response.
They are host facts about the session, not facts the terminal reported, so they
do not enter the `SessionReport` vocabulary; this keeps
`docs/design/2026-08-10-session-owned-terminal-reported-facts.md` D1, D2, and
D4 intact without amending it. This state is also what D2's reply waits on.

D2 relies on the CLI already treating a missing reply as failure for every
method that does not end the instance (`cli/main.swift`, pinned by
`cli-tests/ReplyStreamTests.swift`). Deferring replies widens that window from
negligible to the whole spawn, so this existing behavior becomes load-bearing;
no CLI change is needed.

## Invariants

- **I1.** Input accepted for a pane whose process has not started is delivered
  once it starts, in arrival order, with the launch command ordered ahead of
  later input.
- **I2.** Every input submission ends in exactly one result: delivered once its
  bytes have crossed the PTY master fd, or an error. Bytes stranded anywhere
  short of that edge -- rejected on arrival, buffered before a failed spawn,
  queued behind a failed write, or held when the descriptor closes -- are
  errors. No path answers success without delivery.
- **I3.** Every creation request receives exactly one reply, at a terminating
  edge of its spawn, and a success reply implies the process is running.
  Shutdown is such an edge: no request outlives the connection unanswered.
- **I4.** The bytes awaiting completion for one pane are bounded across the
  whole path, pre-spawn buffer and host queue alike; exceeding the bound is an
  error, not a silent drop and not unbounded growth.
- **I5.** A pane's process phase is readable over IPC without shell
  integration installed.
- **I6.** A CLI invocation that receives no reply exits non-zero, except for
  methods whose success ends the instance. This already holds; D2 makes it
  load-bearing.

## Proof obligations

- **PO1 (I1).** Input submitted before the process starts arrives after it
  starts, ordered behind the launch command. The IPC submission is provable in
  the lifecycle and dispatch packages; the GUI keystroke is not reachable from
  either, so it needs its own behavioral test driving the real view or
  controller input path against a pane that has not finished spawning. That
  test must hold the pane in the spawning phase rather than racing a real
  spawn, or it proves the running path on most runs and flakes on the rest.
- **PO2 (I1).** Buffered input survives a working-directory retry, matching the
  launch input's existing behavior across that ladder. This premise is
  load-bearing for the collapse in D1 and is not currently pinned by a test.
- **PO3 (I2).** Delivered input reports success only once its bytes cross the
  master fd. Undeliverable input reports an error in each way it can strand:
  submitted after a failed launch, submitted against a finished process,
  accepted while spawning whose spawn then failed, accepted while spawning on a
  pane whose close arrives first so the successful spawn goes straight to
  teardown, and queued in the host when the write fails or the descriptor
  closes.
- **PO4 (I3).** Each terminating edge produces exactly one correct reply --
  success on a running process; error on launch failure, on creation failure,
  on close during spawn, and on shutdown during spawn. Two of these are
  regressions today: creation failure replies success, and shutdown replies
  not at all. Each creation surface carries its own edge, `group new` included.
  The shutdown edge must be proved deterministically, with the error observed
  reaching the caller before its transport closes; quitting a live app cannot
  be aimed at that window reliably enough to prove anything. It needs two
  in-flight cases, a creation and an input submission, because their pending
  identities travel different paths and one does not carry the other.
- **PO5 (I4).** Overflow reports an error and does not grow without bound.
- **PO6 (I5).** The process phase is projected in the pane response and
  distinguishes a spawning pane from a running one, with no integration
  reported.
- **PO7 (I6).** A method whose reply never arrives exits non-zero; an
  instance-ending method still exits zero. Already covered by
  `cli-tests/ReplyStreamTests.swift`; no new test needed.

## Non-goals

- Prompt readiness. Completion is a running process, not a ready shell.
- Reworking the shell-integration latch or its opt-in nature.
- Restart, hold-open, or detached-session behavior.

## Accepted risks

- **AR1.** Creation latency now includes the spawn, and the CLI receive timeout
  can be exceeded pathologically (a single spawn wedged on an unreachable
  working directory, a long retry ladder).
  The new failure mode is "CLI reports a timeout, pane appears anyway", so the
  timeout message must read as indeterminate rather than as failure. Accepted
  because lengthening the timeout trades a rare wrong message for a common slow
  one.
- **AR2.** Programs that flush the terminal input queue at startup -- password
  prompts, some full-screen programs -- still discard input typed before they
  start. That is their behavior, not ours; `--cmd` remains the recommendation
  for those, and SKILL.md must say why.

## Rejected ideas

- **RI1.** A polling barrier command that waits for a pane to be spawned. It
  pushes the race onto every caller and is only needed because the reply lies.
  A wait on *command* completion is a different feature, not covered here and
  not foreclosed.
- **RI2.** Withholding the pane id until the process runs. A pane is a UI region
  that must appear immediately on a split and accepts resize while spawning.
  Withholding the id recreates the race in reverse and makes launch failure
  unrepresentable.

## Implementation discretion

- The buffer's bound, and whether overflow rejects the submission or fails the
  pane.
- How the pending request identity is keyed within session-owned state.

## Verification

Unit coverage for PO2-PO5 sits in the lifecycle reducer, PTY host, and core
dispatch packages, and the full gate is `just test`. PO4's shutdown edge sits
with the runtime instead, in `app-tests/`, which already proves shutdown
terminal for every scheduling owner and runs deterministically without a
WindowServer. PO1's GUI half needs the AppKit harness (`just test-ui`), which
the gate excludes because it does require one.

End to end, with a slot claimed by `just launch-slot`: split a pane and
immediately send input in two back-to-back `danterm --socket <slot>` calls with
no delay between them, and confirm the input runs. The same pair against
current `master` is the failing baseline. Confirm too that `pane info` reports
the process phase with no shell integration sourced.

A launch failure is the one edge with no ready end-to-end trigger: an
unreachable working directory falls back to the account home and then to `/`
per `docs/design/2026-08-06-swift-terminal-engine.md` F4, so it does not fail.
PO4's launch-failure reply is proved at unit level; reaching it through the
real CLI needs a launch that exhausts or bypasses that fallback.

Doc changes travel with the behavior: `integrations/danterm/SKILL.md` must drop
the shell-prompt-race framing, state that split-then-send is now correct, keep
`--cmd` recommended for the AR2 case, document the new exit-code meaning for
creation, and add the process phase to the pane response table.

## Commit progress

- [x] 1. feat(pty): make input submissions bounded and observable
- [x] 2. fix(ipc): reply when pane effects complete
- [x] 3. test(app): prove pre-spawn GUI input and document readiness

## Implementation notes

- The PTY path uses one 8 MiB per-pane pending-input bound. Launch input consumes
  the same budget and fails launch when it alone exceeds the bound. Later input
  is admitted or rejected as a whole submission.
- An input submission that encodes to no bytes completes successfully without
  changing the viewport. It has no PTY bytes left to deliver and preserves the
  existing empty-paste behavior.
