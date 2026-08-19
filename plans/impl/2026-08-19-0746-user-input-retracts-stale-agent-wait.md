# User input retracts a stale agent wait

## Problem

A pane whose agent reports `waiting` shows the attention dot and raises a
desktop alert. Claude Code sets that state from `PreToolUse(AskUserQuestion)`.
Dismissing the question with Esc emits no hook event at all, so the pane stays
in `waiting` indefinitely -- the attention dot claims the agent needs the user
long after the user has answered it.

Measured on Claude Code 2.1.228 with a hook that logs every event, driving a
live pane through the DanTerm CLI:

    UserPromptSubmit                  -> working
    PreToolUse AskUserQuestion        -> waiting
    PermissionRequest AskUserQuestion  -> waiting
    Notification
    <Esc>                             (no event)
    t+5s .. t+60s   pane info activity == "waiting"

Load-bearing premises, both measured:

- Dismissal produces no `PostToolUse`, no `Stop`, and no resolution of
  `PermissionRequest`. Claude Code's `Stop` hook does not run when a turn ends
  by user interrupt, and dismissing the question ends the turn that way.
- The stale state clears only at the next `UserPromptSubmit`.

The hole is not specific to one event or one agent. Escaping a permission
prompt is unpaired the same way, as is Codex's `request_user_input`. So the fix
cannot live in the hook scripts: there is no event to hook.

The desired outcome is that a pane stops claiming the agent needs the user once
the user has dealt with it, whatever the agent's hooks do or fail to emit.

## Decision

The rule, stated as a rule rather than as a mechanism: **a hook may assert that
a wait began, but only DanTerm may end it, because `waiting` is a claim about
the user and DanTerm is the only party that observes the user acting.** An
agent knows it asked a question; nothing in an agent's hook vocabulary fires
when the user walks away from one. DanTerm sees the bytes enter the pane's PTY.
Once that ownership is stated, the stuck state is unreachable for every agent
and every hook vocabulary, including agents with no hooks at all.

So: user input to a pane retracts a `waiting` claim.

Retract, not replace. Input tells us the wait is over; it does not tell us what
the agent is doing next. The model already distinguishes "attached, with no
activity reported" from "attached and idle", and `reduceSession` already uses
the former on attach for exactly this reason. Retraction returns the agent
there, and the next genuine hook report re-establishes truth: `PostToolUse`
restores `working` when the question was answered, and nothing further is owed
when it was dismissed.

The signal comes from the session's authoritative input owner, not from the
call sites that feed it. That owner already decides, per typed operation, what
bytes an input produces: it encodes a key, a paste, a pointer or wheel event
against the terminal's current input modes, and drops the result when it is
empty. The input lifecycle now also reports whether every byte crossed the PTY
or the submission was rejected. The owner can therefore report exactly the
fact this plan needs -- non-empty user-directed bytes were delivered to this
pane -- while empty encodings, rejected submissions, and the terminal's own
replies to the child stay excluded structurally. It reports an input occurrence
and gains no agent-specific logic.

Three constraints on how that occurrence travels:

- It rides the session's existing ordered semantic-event channel and the
  existing closed session-event vocabulary above it -- not a new callback --
  keyed by `SessionId`. At input origin it snapshots only the current wait's
  opaque generation, not an `AgentSession`. The PTY owner echoes that generation
  when the non-empty submission finishes delivery. It makes no claim about any
  agent: the generation lets the reducer identify the wait the user acted on,
  and `reduceSession` stays the sole writer of agent activity.
- The origin snapshot is a live read of the generation the model holds at the
  moment the input operation is submitted. No copy of the generation is pushed
  down to the pane session by the view sweep: activity reports defer that sweep
  by up to a coalesce window, so a swept copy would be stale exactly when a
  wait has just been admitted, and the single keystroke that dismisses it would
  read the previous generation and never retract. The runtime supplies the
  value on demand instead.
- Every admitted `waiting` report gets a fresh generation, including a report
  whose visible activity equals the current activity. A delivered input
  retracts only the still-current matching generation. A wait reported after
  the input began therefore survives even if its hook reaches the model before
  the input's asynchronous delivery occurrence. Input that began before a wait,
  input for a replaced agent, empty input, and rejected input have no matching
  occurrence that can retract it.
- It is gated before it reaches `update()`. `AppRuntime.send` takes a full
  model snapshot and an Equatable compare on every message, via the
  light-checkpoint projection; a per-keystroke message is a new cost category,
  not a rounding error. The gate is a fast path only, never a second rule: it
  must be expressible as one pure predicate that the reducer's own guard also
  uses, and deleting it must change no observable behavior.

Critical files: `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift`
(typed input, delivery completion, and the occurrence) and
`lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift` (the
channel upward), `lib/DanTermCore/Sources/DanTermCore/PaneLifecycleReducer.swift`
and `Model.swift` (the wait generation and reducer),
`lib/DanTermCore/Sources/DanTermCore/TerminalBackendBoundary.swift` (the
session-event seam and `terminalMessages`), and `app/TerminalSession.swift`,
`app/SwiftTerminalSessionView.swift`, and `app/AppRuntime.swift` (the
backend-neutral on-demand generation read and the gated session event closure).
Scripted input also uses the existing completion-aware commands in `IpcDispatch.swift`,
`Command.swift`, and `Update.swift`.

## Invariants

- I1. Delivered input from the user to a pane whose attached agent reports
  `waiting` leaves that agent attached with no reported activity, so the agent
  contributes nothing to that pane's chip dot. The dot goes quiet when no
  unread alert is claiming it; unread alerts keep their existing precedence
  and their existing owner.
- I2. Delivered input changes no other activity. A pane reporting `working`,
  `idle`, or nothing is unaffected by typing into it.
- I3. Input counts exactly when every non-empty byte from a user-directed pane
  input operation crosses the PTY: keys, committed text, paste, drag-and-drop,
  scripted input, and pointer or wheel events under a terminal mouse-reporting
  mode. Focus reporting is a separate operation and never counts. The
  terminal's replies to the child never pass through a user-directed operation.
  An input that encodes to nothing -- a filtered key, marked preedit text, an
  empty request -- and a submission the input lifecycle rejects do not count.
- I4. Retraction is session-scoped. Input to a pane cannot alter any agent
  session other than the one currently attached to that pane.
- I5. Retraction is not sticky: every admitted wait has a distinct generation,
  and a delivered input can retract only the matching generation that was
  current in the model when that input was submitted -- read live, never from a
  copy the view sweep refreshes. A later hook report sets activity normally and
  survives an older input's delayed completion, even when both reports say
  `waiting`. Renewing an otherwise identical wait is not a new visible activity
  transition and does not emit another alert.
- I6. `reduceSession` remains the only writer of agent activity.
- I7. DanTerm synthesizes no agent activity transition from elapsed time,
  terminal output, or unrelated tool events. It does end a `waiting` state on
  direct user input to that pane, because `waiting` is a claim about the user
  and only DanTerm can observe it ending. This supersedes the earlier, narrower
  statement of that boundary: the three forbidden triggers are all inferences
  about the agent from ambient signals, and a keystroke is neither ambient nor
  an inference.
- I8. Any gate that suppresses the input signal before it reaches `update()` is
  a fast path with no behavior of its own: removing it changes nothing
  observable.
- I9. Input delivery and rejection keep their existing completion contract.
  Retraction neither turns rejected scripted input into success nor delays or
  duplicates its one completion.

## Proof obligations

- PO1 (I1). A waiting agent plus delivered pane input yields an attached agent
  with no reported activity, and a chip that is quiet when no unread alert
  claims it. This test must fail against today's code for the reported reason.
- PO2 (I2). Working, idle, and unreported activity survive pane input unchanged.
- PO3 (I3). At the input owner: each non-empty user-directed input operation
  reports one occurrence only after all of its bytes cross the PTY. An operation
  that encodes to no bytes, a submission rejected before or during delivery, a
  focus report, and a terminal reply to the child report nothing. Scripted
  `pane input` retracts a wait through the same path as typing.
- PO4 (I4). Input cannot retract on a pane other than the one addressed, nor
  affect a replaced or detached agent session.
- PO5 (I5). A `working` report after a retraction attaches normally. A fresh
  `waiting` report renews the generation even when the visible state was already
  `waiting`, and a wait raised after an input began is not retracted when that
  input finishes later. Generation-only renewal emits no commands and no second
  desktop alert. A `waiting` report admitted with no view sweep yet run, then
  one delivered key, still retracts.
- PO6 (I8). The retraction behaves identically with the gate removed, and is
  idempotent when input repeats.
- PO7. Retraction is silent: it emits no commands, raises no alert, and clears
  no alert.
- PO8. The session-event boundary translates the input occurrence into exactly
  the session-scoped message for that session, and a typing burst coalesces its
  view sweep the same way an activity report already does.
- PO9 (existing behavior this change relies on). The desktop alert already
  emitted for the waiting report is neither re-emitted nor resurrected by
  retraction, and in the default alert-clear mode the pane's dot is quiet once
  the user has focused the pane and typed.
- PO10. The whole path holds end to end against a real agent pane, per the
  repo's rule that source picks the probe but does not replace running one.
  PO3 carries the per-operation coverage, so the live probe proves the join,
  not the enumeration.
- PO11 (I9). Existing input-completion behavior is unchanged: a delivered
  scripted submission still replies once with success, and every rejection
  still replies once with failure while leaving a matching wait intact.

## Non-goals, accepted risks, rejected ideas

- Non-goal: changing either bundled hook script. Escaping a permission prompt
  is itself input to the pane, so the existing `PermissionRequest` mapping
  self-heals once retraction exists.
- Non-goal: a `PermissionRequest` that Claude auto-approves without ever
  involving the user. That would set `waiting` with no input ever arriving.
  This change is no backstop for it: the desktop alert fires the instant
  `waiting` lands on an unfocused pane, and a later keystroke cannot un-ring
  it. It is a false start, not an unpaired end -- a different defect, of the
  shape already fixed for Codex, unmeasured for Claude. Its decisive experiment
  is specific: does Claude's `PermissionRequest` hook fire for a tool call that
  settings auto-allow?
- Non-goal: unread alerts. Whether the badge clears is `alertClearMode` policy
  and already has an owner.
- Accepted risk: under a mouse-reporting mode that forwards motion, moving the
  pointer across a waiting pane can deliver child bytes and so end the wait
  without the user answering. The child is genuinely receiving the user's
  input, the mode is rare, and fencing it would mean re-deriving authorship
  above the layer that knows the encoding.
- Accepted risk: an Esc that interrupts a *working* turn still leaves the pane
  reporting `working`, because no `Stop` arrives. This change neither fixes nor
  widens that gap; a spinner that overstays is a quieter lie than an attention
  dot that does.
- Rejected: mapping some hook event to the dismissal. Measured -- there is none.
- Rejected: a timeout. Elapsed time cannot distinguish a wait from work.
- Rejected: asserting `working` on input. The argument for it is that answering
  a question is the common branch, so claiming `working` avoids a brief quiet
  flicker and is self-correcting. The argument against, which decides it: after
  a dismissal no hook ever arrives, so the pane would report a running turn
  that ended, and `pane info` is the surface this repo treats as debugging
  truth. No-claim is never false.
- Rejected: keeping `waiting` and adding a separate DanTerm-owned "answered"
  fact for the chip to consult. More honest in the abstract -- the agent's
  request really was never resolved -- but it splits one wait across two
  representations every future reader must consult as a pair, and it leaves
  `pane info` reporting `waiting` after the user escaped.
- Rejected: emitting from the AppKit call sites that originate typing, paste,
  and drag-and-drop. It enumerates a list that can be missed, needs a second
  path for scripted input, and needs a hand-written emptiness rule -- all of
  which the input owner already decides once, correctly, for every caller.
- Rejected: retracting before descriptor delivery to put the occurrence ahead
  of the child's next hook. Input is bounded and fallible now, so this clears a
  real wait when the lifecycle later rejects the submission.
- Rejected: retracting on delivery without identifying the wait that input
  answered. Descriptor completion can reach the model after the child's hook
  has raised a new wait, so an unqualified late occurrence can erase that wait.
- Rejected: clearing on pane focus. A user can focus a pane to read the
  question without answering it, and the alert subsystem already owns focus.

## Implementation discretion

- How the retraction is spelled in the report vocabulary, subject to I4 and I6.
- The concrete value type and allocation scheme for the opaque wait generation,
  provided every admitted `waiting` report renews it and it remains ephemeral.
- Where the pure predicate behind the gate lives, so long as one definition
  serves both the reducer's guard and the runtime's fast path.

## Verification

- `just test` for the unit proofs above: the retraction and routing proofs in
  `lib/DanTermCore/Tests/DanTermCoreTests/` beside the existing
  `PaneLifecycleReducerTests`, `SessionReportTests`, and
  `UpdateSessionEventTests`; completion integration beside the existing
  `paneInputDefersSuccessUntilEverySubmissionIsDelivered` and
  `paneInputRejectsOnceWhenAnySubmissionFails` coverage; and the per-operation
  emission proof against the input owner in `lib/TerminalPTY/Tests/`.
- End to end against a live pane, reproducing the measurement that opened this
  plan: launch a slot instance, run `claude` in a pane, prompt it to call
  `AskUserQuestion`, confirm `danterm pane info` reports `waiting`, send
  `danterm pane input -- Escape`, and confirm the activity is null and the dot
  is quiet. Repeat with an answered question and confirm the pane returns to
  `working` on its own.
- One typed-key check, so the app-side origin read is proven and not only the
  scripted path, which snapshots inside core dispatch. A `just test-ui` case
  that types into a pane whose agent reports `waiting` is enough; the live probe
  above covers the rest of the join.

## Commit progress
- [x] 1. core: retract an agent wait on delivered pane input
- [x] 2. pty: report each delivered user-input operation with its wait generation
- [x] 3. app: wire delivered pane input and scripted input to wait retraction

## Implementation notes

- Commit structure: three commits, one per layer the plan names -- core
  (generation, retraction report, reducer, routing, gate predicate), then the
  input owner in `lib/TerminalPTY`, then the app wiring plus the scripted-input
  path. Each layer has its own test suite and leaves the tree green, so a
  failure lands on the layer that caused it.
- The generation is stored by coupling it into a new `AgentActivityState`
  (`waiting(generation:)`), leaving `AgentActivity` as the vocabulary a reporter
  can name. A separate `waitGeneration` field beside `activity` was the smaller
  edit but would let a generation exist with no wait.
- `SessionModel` mints its own generations from a private counter. Generations
  need to be unique only within a session, because retraction is session-scoped,
  so this needs no `CoreEnv` id and stays out of every snapshot.
- The desktop-alert guard changed from "the model changed" to "the pane was not
  already visibly waiting". Renewal now always changes the model, so the old
  guard would have raised a second alert for a wait the user could already see.
- `SessionReport.userInputDelivered` carries an optional generation, so an
  occurrence with no wait behind it is representable and inert. That is what
  lets commit 3's pre-`update()` fast path be deleted without changing behavior.
- The occurrence rides the pane's ordered semantic channel by widening that
  channel's element type to a new `PaneSemanticEvent` in `lib/TerminalPTY`,
  which wraps `TerminalSemanticEvent` and adds `userInputDelivered`. Adding the
  case to `TerminalCore.TerminalSemanticEvent` was the smaller edit, but it
  would make the parser's own vocabulary declare a meaning the parser never
  produces.
- Which submissions count is decided by the entry point that encodes them, not
  by a flag every caller passes: user-directed operations submit as `.user`,
  focus reports submit as `.pane`, and the terminal's replies to the child never
  reach `submitInput` at all.
- The `waitGeneration` parameter defaults to nil through this commit so the
  layer lands on its own. Commit 3 supplies the real values at the app call
  sites and can drop the default there.
- Widening the channel promoted `PaneSemanticEvent.swift` into the UI harness's
  compile list, so its `import TerminalCore` is guarded the way the view's
  engine imports already are. The harness's `emitSemanticEvents` still takes
  terminal events and wraps them, because every UI test drives the pane from the
  child's side.
- A delivered submission now wakes one update signal, so a keystroke on a silent
  pane does not hold its occurrence until the next output. That is why
  `queryReplyOrderingAndCapture` now takes its signal baseline after its own
  input has landed: the wake it rules out is the query's, not the user's.
- Input this pane originates itself reads its wait through a closure the runtime
  installs (`TerminalSession.currentAgentWaitGeneration`), and input the runtime
  dispatches as a `Command` carries the snapshot `update()` took. Both are live
  model reads at the submission; the two paths exist because typing never passes
  through a command, and scripted input never passes through the view's own
  entry points.
- The read is stored on `TerminalSessionCallbackGate` beside the emit channels,
  so a torn-down session structurally cannot call back into the runtime.
- The `waitGeneration` parameter on the controller and host keeps its nil
  default. Dropping it would have forced every call site in `lib/TerminalPTY` to
  restate nil -- 116 of them, nearly all tests -- for a compiler check the app's
  own call sites already get from the widened `TerminalSession` methods.
- The runtime's fast path is `retractionIsLive`, which asks
  `AgentLifecycle.retractsWait` and passes every other event untouched.
