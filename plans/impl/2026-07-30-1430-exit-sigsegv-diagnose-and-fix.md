# Diagnose and fix the SIGSEGV on application exit

## Context

Quitting DanTerm Dev (Cmd-Q, accept) segfaults after the window is gone.
Reproduced 2/2 on 2026-07-30 against `02f3ba1`, both times after saturating
scrollback and resizing. `EXC_BAD_ACCESS` on a cooperative-pool thread while the
main thread sits in `applicationWillTerminate`.

Not caused by the resize coalescing in `02f3ba1`: that commit changes only the
submission side of `TerminalPTYHost` and does not touch teardown, the exit
ladder, or any concurrency construct. It is in scope here only because it is what
the user was exercising when the crash surfaced.

## Problem

Two facts from the crash reports pin the shape of the defect.

**The faulting address is deterministic.** Both runs fault at
`(uint32)(image_base - 0x0FE3556C)`, despite different ASLR slides:

| run | image base | predicted | actual `pc` |
| 1 | `0x102c70000` | `0xF2E3AA94` | `0xF2E3AA94` |
| 2 | `0x1020dc000` | `0xF22A6A94` | `0xF22A6A94` |

A repeatable offset with the high 32 bits dropped is not heap noise. It is the
signature of a relative or compact function pointer resolved against the wrong
base -- something is being read as a value it is not.

**The victim is named.** The fault is at the call site inside
`swift::runJobInEstablishedExecutorContext`, before a single instruction of ours
runs, so the job's resume pointer was already garbage. `x8` identifies the job in
both reports: the `group.addTask { await handle.terminateForApplicationExit() }`
child at `app/SwiftTerminalBackend.swift:109`.

The arena is `SwiftTerminalBackend.terminateForApplicationExit()`
(`app/SwiftTerminalBackend.swift:102-115`): a `Task.detached` drives a
`withTaskGroup` over every live host while the main thread blocks on a
`DispatchSemaphore` with a 2-second deadline. That pattern is independently
defective regardless of what this crash turns out to be:

- If the deadline expires, main returns, `applicationWillTerminate` completes,
  and AppKit dismantles the process while the detached task and its children are
  still live and still holding the hosts -- the "longer-lived owner messaging a
  shorter-lived object after teardown" class that
  [docs/design/2026-06-09-appkit-lifetime-safety.md](../../docs/design/2026-06-09-appkit-lifetime-safety.md)
  exists to prevent.
- That deadline is not comfortable. `19/F4` found the teardown census enumerates
  every process on the machine and calls `getsid()` per pid on a 10 ms poll, so
  its cost is set by unrelated system load. The timeout branch is live.
- With main blocked, the per-pane `consumeTask`
  (`lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift:222`)
  inherits `@MainActor` and cannot make progress for the whole window.

Two Swift tasks that predate the exit path are live in the same window, and
finishing a host during exit is what resumes them:

- Ordinary pane teardown parks a detached `host.close()` task that then awaits a
  `@MainActor` completion (`TerminalPaneSession.swift:543`, `:100`). Quitting
  while a pane close is in flight resumes it against a main actor that is blocked
  and a process that is being dismantled.
- A host still spawning holds a task suspended inside `PTYSpawner.spawn`
  (`TerminalPTYHost.swift:826`), a blocking `posix_spawn` plus status-pipe read.
  Cancelling it cannot interrupt the syscall, so it resumes later -- and its
  cancellation branch discards an already-spawned child.

**Desired outcome:** Cmd-Q releases every child process and exits without a
crash report, with an exit path that cannot resume a job against a process that
is already being torn down.

## Decision

Two phases, gated. Phase D must produce a named root cause before Phase F
commits to a fix -- `19/F10` is the standing precedent (chasing the reported
symptom turned up a different and realer bug underneath), and `19/F13` is the
standing rule against guessing at a seam.

**Phase D -- diagnose.** Reproduce under a debugger and identify what writes the
job's resume slot. The offset is stable across runs, so this is a lookup, not a
search.

**Phase F -- fix: take Swift Concurrency out of the termination path, and put the
bound inside the host.** Each host's teardown ladder already runs on that host's
own serial queue, driven by its own dispatch sources. The exit path submits a
termination request to every host, then waits only on completions signalled from
those queues -- no detached task, no task group, no async task frames.

The backend keeps no deadline of its own. A completion *means* the host is
quiescent, so exit is bounded by construction rather than by racing host work
against an outer clock. Only the host can both cap its own wait and guarantee
that nothing it owns can run afterward; an application-level timeout can do
neither (`RI4`).

Scope is every way a host can be alive at Cmd-Q -- running, already mid-close
from ordinary pane teardown, or still spawning. All three converge through the
same dispatch-driven termination/completion mechanism, so ordinary teardown
leaves no parked task for exit to resume.

Main still blocks inside `applicationWillTerminate` -- AppKit gives no
alternative -- but on a signal from the queues that own the work, rather than on
a job on a pool that outlives the wait.

Phase F may be replaced if Phase D names a root cause elsewhere. It is not
contingent on that: the exit path is defective either way and gets fixed either
way.

Critical files:

- `app/SwiftTerminalBackend.swift` -- the exit ladder and the semaphore fence.
- `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift` -- owns the
  teardown ladder (`terminateForApplicationExit`, `waitForTeardown`,
  `finishTeardown`, the waiter slots) and the serial queue it runs on.
- `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneTerminationHandle.swift`
  -- the process-lifetime handle the backend retains.

## Invariants

- **I1.** No Swift Concurrency task, group, or continuation is created, retained,
  or resumed as a consequence of application exit -- including tasks created
  earlier, so finishing a host must not be what resumes an in-flight pane close
  or an in-flight spawn. No step of the exit path depends on the main actor
  making progress, because main is blocked for its duration.
- **I2.** Every live host is told to terminate and reaches quiescence before the
  process exits: PTY master closed, dispatch sources cancelled, child session
  ownership resolved rather than abandoned, and no callback or completion able to
  fire afterward.
- **I3.** Each host converges to `I2`'s quiescent state within its own bound,
  whether or not its teardown ladder completes normally. The exit path waits only
  on host completions and keeps no separate deadline; a completion is therefore
  synonymous with irreversible quiescence.
- **I4.** A host that has already finished teardown when the exit path reaches it
  completes immediately rather than waiting for a signal that will never come.

## Proof obligations

- **PO1** (Phase D): the root cause is stated with the write that corrupts the
  resume slot identified, or the diagnosis is recorded as inconclusive and the
  gate is re-decided. Not a test -- a finding.
- **PO2** (I1/I2): terminating a set of live hosts releases every child and
  signals completion, driven entirely from the hosts' own queues.
- **PO3** (I3): a host whose teardown ladder never signals still reaches
  quiescence within its bound and completes, and nothing it owns runs afterward.
- **PO4** (I4): terminating an already-torn-down host returns without waiting.
- **PO5** (I1/I2): application exit while a pane close is already in flight
  completes within its bound, releases native ownership, and fires no later
  callback or completion -- in particular none requiring the main actor.
- **PO6** (I1/I2): application exit while a host is still spawning completes
  within its bound and does not leak the child, including when the blocking
  spawn returns a live process after exit has been requested.
- **PO7**: the crash does not reproduce across repeated saturate-resize-quit
  cycles on the dev build.

## Non-goals

- Making teardown faster, including `19/F4`'s whole-machine process census. It is
  the reason the deadline is reachable, but the defect is what happens when the
  deadline is reached.
- The stacked-prompt question from `19/F15`, still open and still untested.
- Any change to the resize coalescing in `02f3ba1`.

## Accepted risks

- **AR1.** Quit may block main marginally longer than today in the common case,
  since the fixed path waits on real completion rather than racing a deadline.
  Accepted: the drain is milliseconds when the census is not pathological, and
  correctness at exit is worth more than the difference.
- **AR2.** If Phase D names a cause outside the exit path, Phase F fixes a real
  hazard without curing the crash. Accepted, and explicitly why D gates F rather
  than F shipping alone.

## Rejected ideas

- **RI1.** Keeping the detached task and timeout but cancelling the group and
  retaining the hosts past process teardown. Fences the hazard instead of
  removing it, and leaves the concurrency machinery that the crash lands in.
- **RI2.** Escalating to `exit(0)` when the deadline expires. Bounds the symptom
  by skipping teardown, which is what `I2` exists to prevent, and would mask the
  crash rather than fix it.
- **RI3.** Fixing the exit path without diagnosing first. The offset is
  deterministic and reproduces 2/2, so diagnosis is cheap; shipping past that is
  how a change gets credited with a cure it did not deliver.
- **RI4.** An application-level deadline wrapped around host termination.
  Cannot satisfy `I2` and `I3` together: expiring it either returns with a host's
  child abandoned, or returns while that host's work is still able to run. The
  bound has to sit where the resources are owned.

## Verification

- `just test` for the gate.
- `PO7` live: `scripts/saturate-scrollback.sh`, resize, Cmd-Q, accept -- repeated
  enough times to clear the 2/2 reproduction, watching for a crash report.
- Worth collecting in the same session, still owed from `19/F15`: resize one
  notch, let it settle, repeat, and record whether a single settled resize
  duplicates a prompt.

## Implementation discretion

- How a host signals completion from its own queue, and what its `I3` bound is.
- Whether the diagnosis in Phase D is recorded in a research doc or in the fix's
  commit message.

## Commit progress

- [x] 1. Phase D -- record the exit-crash diagnosis in `docs/research/22`
- [ ] 2. Phase F -- host-owned dispatch termination and completion signalling
- [ ] 3. Phase F -- backend and pane teardown adopt host-signalled termination

## Implementation notes

- **Phase D closed on `PO1`'s inconclusive branch.** The corrupting write is
  still unidentified. The user re-decided the gate on 2026-07-30: one focused
  live-debugger attempt, then proceed to Phase F under `AR2` regardless. The
  full record, including the register arithmetic and the rejected static routes,
  is `docs/research/22-application-exit-job-corruption.md`.
- **The arena is now confirmed rather than assumed** (`22/F13`). The crash
  report's main-thread stack shows `confirmQuit` -> `NSApplication.terminate:`
  -> `applicationWillTerminate` -> `terminateForApplicationExit()` blocked in
  `DispatchSemaphore.wait(wallTimeout:)` at `SwiftTerminalBackend.swift:114`,
  with the fault on the cooperative pool. Every structural claim in `## Problem`
  is therefore about the right code, which narrows `AR2` without removing it.
- **The reproduction is much cheaper than this plan assumed** (`22/F8`). A plain
  Cmd-Q with a single pane on a freshly launched app reproduces it; the
  saturate-scrollback and resize preamble is incidental. `PO7` should use the
  cheap recipe, and then the expensive one, rather than only the expensive one.
- **`nm`-address breakpoints are unusable against this bundle** (`22/F11`). They
  report themselves resolved and then never trap. Any further debugging of this
  crash needs a positive control before its negative results mean anything.

## Follow Up

- `docs/research/README.md` has no row for doc 22. It was left untouched because
  it carries unstaged in-flight edits of its own, and that file's own rule is
  that the table is the only record of which files are live -- so doc 22 is
  currently invisible to that index.
