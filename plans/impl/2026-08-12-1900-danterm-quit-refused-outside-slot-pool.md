# danterm quit, refused outside the slot pool

## Problem

An agent that launches a dev slot app can start it (`just launch-slot`) and
kill it (`just stop-slot <n>`), but both live outside the CLI: `stop-slot`
reads the slot lock record and sends `SIGKILL` to the process group. That is
the only way an agent has to end an app it started, and it is the wrong shape
for two reasons.

`SIGKILL` gives the app no exit path. `applicationWillTerminate` is what stops
the IPC server, fences sessions, writes the final enriched recovery checkpoint,
and deletes the session lock file. A killed slot app skips all of it, so an
agent testing recovery, checkpointing, or shutdown behavior cannot produce a
normal exit at all.

The kill also requires the launcher's pool bookkeeping. An app started any
other way -- a worktree build run by hand, an app whose slot record was lost --
has no route to a graceful exit. The CLI, which is otherwise the whole remote
control surface, deliberately has no verb for it: `tab close` and `pane close`
refuse their last target precisely so that the CLI cannot quit the app as a
side effect.

The desired outcome is a first-class `danterm quit` that ends a targeted
instance the same way Cmd-Q does, and that cannot end the user's production
`DanTerm.app`.

Load-bearing premises, all read from the current tree:

- `Command.terminate` already performs the full graceful exit, and already sets
  `AppDelegate.quitConfirmed` so `applicationShouldTerminate` does not bounce
  it back into the confirmation panel. Today it is emitted only from UI and
  lifecycle paths, never from IPC dispatch.
- `DanTermInstanceIdentity.developmentSlot` is `0` for `DanTerm Dev.app`, `1`
  through `8` for launcher-claimed slots, and `nil` for production
  `com.danneu.danterm` and for any bundle identifier outside the scheme.
- The app never stores its identity; both existing uses re-derive it from
  `Bundle.main`. `CoreEnv`, the pure core's only ambient seam, does not carry
  it, so IPC dispatch cannot see it today.
- With no `--socket` and no `DANTERM_SOCK`, the CLI falls back to the
  identity-derived control socket, which for the shipped `danterm` binary is
  production's. A bare `danterm quit` would therefore aim at production by
  default. This is the accident the plan has to make impossible.
- The CLI's request loop treats end-of-stream as the error "DanTerm closed the
  connection". A successful quit closes the socket, so the generic loop would
  report success as failure.

## Decision

Add one IPC method and one CLI verb, `quit`, whose effect is the existing
graceful terminate. Guard it in two independent places, on the two different
sides of the socket:

**Server side, load-bearing.** Thread the process identity through `CoreEnv`
and refuse the method in pure IPC dispatch unless this instance holds a
launcher pool slot. The refusal is an allowlist over a named concept on the
identity type, not a denylist of the production bundle identifier, so any
identity the scheme does not recognize -- a future bundle id, a test harness --
is refused without anyone remembering to add it. This is the guard that
matters: it lives on the side that owns the decision, and no caller can
bypass it.

**Client side, defense in depth.** `quit` does not resolve a target from
ambient state. It requires an explicit `--socket`, and refuses both the
`DANTERM_SOCK` inheritance and the identity-derived fallback, so the verb can
never mean "whatever instance I happen to be running inside". This matches the
existing rule that an agent driving a slot keeps the target visible at every
call site.

Quit is not confirmed. Passing the instance's socket explicitly is the
authorization, the same way an explicit pane id authorizes `pane close` without
the GUI's todo confirmation. It ignores any pending confirmation panel and any
uncompleted todos.

The CLI accepts a closed connection as success for this verb. A quit that
worked ends the socket; only an explicit error reply is a failure. This keeps
the refusal legible (the app answers, then keeps running) without needing the
reply and the process exit to be ordered against each other.

## Invariants

- **I1.** An instance whose identity is not a launcher pool slot (1 through 8)
  refuses `quit` and keeps running. Production `DanTerm.app`, `DanTerm Dev.app`
  (slot 0), and any unrecognized bundle identifier are all refused.
- **I2.** A slot instance answering `quit` exits through the same path as
  Cmd-Q: the final recovery checkpoint is written and the session lock file is
  removed.
- **I3.** `quit` runs regardless of pending confirmation state or uncompleted
  todos, and leaves no confirmation stranded.
- **I4.** `danterm quit` without an explicit `--socket` fails without
  contacting any instance.
- **I5.** A quit the app honored exits 0; a quit the app refused exits non-zero
  and prints the refusal.

## Proof obligations

- I1: identity classification, naming the production bundle identifier
  literally, plus the boundary cases the scheme rejects; and a dispatch-level
  test that a refused instance emits an error and no terminate effect. The
  production case is discharged here, not live -- see the verification section.
- I1/I3: a dispatch-level test that a pool-slot instance emits the terminate
  effect, including from a model that has a confirmation pending.
- I2: exercised live against a claimed slot. A stale checkpoint left over from
  before the quit satisfies "a checkpoint exists", so the proof has to be
  differential: make a recovery-visible change with a unique marker immediately
  before quitting, and show that marker in the checkpoint written after the
  quit, alongside the removed session lock. No unit test can cover the AppKit
  teardown.
- I4: socket-selection test that the verb refuses the fallback and the
  environment variable.
- I5: covered by the dispatch tests plus the live run; the CLI's
  closed-connection-is-success behavior needs a test at the request-loop level.
- Protocol round-trip and CLI grammar coverage come from the existing catalog
  tests, which fail until the new method is represented.

## Non-goals

- No change to how the GUI quits, and no new confirmation behavior.
- No `--force` or `--timeout` variants. One verb, one meaning.
- `just stop-slot` keeps its `SIGKILL`. It has to work on an app that is wedged
  or still building, which is exactly when a graceful request cannot be
  answered. `quit` is the graceful sibling, not a replacement.

## Accepted risks

- **AR1.** An agent can quit another worktree's slot app if it passes that
  slot's socket. The pool is already shared and already killable by number;
  `quit` adds no reach that `stop-slot` did not have.
- **AR2.** The identity gate is a runtime check in one dispatch arm rather than
  a capability that production's binary structurally lacks. A per-identity
  method catalog would make the production path absent instead of refused, but
  it buys nothing today -- `quit` would be its only member -- and it would put
  the refusal outside the exhaustive switch that already forces every method to
  be handled. Revisit if a second dev-only method appears.
- **AR3.** Production's refusal is never observed live, only inferred from the
  dispatch test that names its bundle identifier and the slot-0 run that proves
  the runtime wiring. Observing it directly means aiming the verb at the app the
  guard exists to protect, and the run that would find a defect is the run that
  destroys the user's sessions. The inference is the safer proof.

## Critical files

- `lib/DanTermProtocol/Sources/DanTermProtocol/InstanceIdentity.swift` -- the
  named pool-slot concept the guard reads.
- `lib/DanTermProtocol/Sources/DanTermProtocol/IpcRequest.swift` -- method
  catalog, encode, decode.
- `lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift` -- grammar.
- `lib/DanTermCore/Sources/DanTermCore/CoreEnvironment.swift` -- the identity
  seam, marked for `scripts/core-purity-lint.sh` like the existing ambient
  seams. Identity is a fourth ambient input and an authorization input, unlike
  the other three, so the file comment has to say so rather than leaving a
  reader to infer it from the type.
- The two documents that state the seam count: `AGENTS.md` ("three ambient
  inputs -- home directory, fresh ids, wall-clock time") and
  `docs/design/2026-05-28-pure-core-support-split.md`, which repeats it as the
  worked example. Both become false with this change and are corrected in the
  same commit.
- `lib/DanTermCore/Sources/DanTermCore/IpcDispatch.swift` -- the guard and the
  terminate effect. The `tab.close` and `pane.close` comments there assert the
  CLI never quits the app; they now describe the absence of a *side effect* and
  need rewording.
- `cli/main.swift` -- usage text, the socket rule for this verb, and the
  quit request path.
- `app/AppRuntime.swift` -- supplies the live identity to `CoreEnv`.
- `integrations/danterm/SKILL.md` -- mandatory for any CLI surface change.
  Needs the synopsis line, the targeting bullet, the trigger-table row, a
  recipe, and an agent rule. The two "the CLI does not quit DanTerm as a side
  effect" sentences under close-tab and close-pane need updating to point at
  the new verb.
- `AGENTS.md` -- the slot-cleanup guidance should name `quit` as the graceful
  option beside `just stop-slot <n>`.

## Verification

1. `just test` green, including the protocol catalog tests that fail until the
   method is represented.
2. Claim a slot, capture its socket from the launch handle, and confirm the
   round trip: `danterm --socket "$SLOT_SOCKET" ls` works, then
   `danterm --socket "$SLOT_SOCKET" quit` exits 0, the process is gone, and
   `just slots` shows the slot free -- the lock is released by process death,
   so a graceful exit frees it with no launcher involvement.
3. Same slot: plant the unique recovery-visible marker, quit, and show that
   marker in the checkpoint written by the exit, plus the removed session lock.
4. Prove the live refusal on `DanTerm Dev.app`. It is slot 0, refused by the
   same rule as production, and it exercises the same runtime wiring -- the app
   really resolving its own identity and really refusing. If that wiring is
   broken in the dangerous direction, this is where it shows, and the cost is a
   dev app nobody minds losing. Do not aim any step of this at the user's
   production socket: the guard is what the test is trying to break, so the
   run that finds a defect is the run that kills the user's sessions. Production
   is covered by the dispatch test naming its bundle identifier plus this
   wiring proof.
5. `danterm quit` with no `--socket`, and with `DANTERM_SOCK` set, both fail
   without contacting anything.
6. Release the slot when done.

## Implementation discretion

- The wire method name and the exact refusal wording.
- Whether the quit reply carries a body or the CLI relies only on the closed
  connection.

## Implementation notes

- `app/AppRuntime.swift` is unchanged. The plan listed it as the file that
  supplies the live identity, but the app has exactly one `update()` call site
  and it already takes `CoreEnv.live`; the new `instanceIdentity` seam resolves
  `Bundle.main` there, which in the app process is the app's own bundle. Passing
  an explicit env from the runtime would have passed `.live` verbatim.
- The two client-side rules -- refuse ambient targeting, read a closed
  connection as success -- both derive from one exhaustive catalog property,
  `IpcRequestMethod.terminatesInstance`, rather than two properties that would
  have had to agree.
- Verification step 4 was run against an identity the scheme does not
  recognize, not against slot 0. No `DanTerm Dev.app` was running, and starting
  one built from this branch would have overwritten the user's dev recovery
  checkpoints within seconds (the light checkpoint timer fires every 2s) and
  could have left a stale session lock behind the `SIGKILL` a refused instance
  needs. A clone of the slot bundle repatched to `com.danneu.danterm-dev.9`
  hits the same refusal arm through the same runtime identity resolution, and
  its identity-derived state is isolated from everything the user owns. It
  refused with exit 1, kept answering `ls`, and its state was deleted after.
