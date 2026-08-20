# RUNTIME-3: no nested modal run loops from an open send frame

Source finding: `docs/scratch/2026-08-18-construction-audit.md` RUNTIME-3.
The decision the audit marks "decide first" is made: the user funded the
full model-projected notice panel (the finding's ideal), split into the two
commits the finding asks for. Lane note: this work owns
`app/AppRuntime.swift`; its lane predecessor RUNTIME-6 merged at
`30c12990`, so the lane is clear.

## 1. Problem and evidence

Two shapes of the same defect, both verified against the current tree:

- `AppRuntimePorts.live.presentAlert` ends in `NSAlert.runModal()`, and the
  `.saveDanTermConfig` perform arm reaches it from inside an open send
  frame. `runModal` spins a nested run loop while `dispatchInFrame` is
  still iterating the command array, so IPC requests and the local NSEvent
  monitor can run `update()` re-entrantly and the outer loop resumes
  against a model that no longer exists. Four production sites reach the
  port: the config-error helper (itself called from the save arm, config
  reload, config open, and the launch-deferred config error), the import
  failure, and the export failure captured in the `.exportState` arm.
- The launch restore prompt in `applicationDidFinishLaunching` calls
  `alert.runModal()` after `AppRuntime.init` has already constructed and
  started the IPC server. A request served during the prompt mutates a
  model that `commitRestoreSession` then replaces wholesale -- the one
  demonstrated discard.

Facts the fix leans on, all re-verified:

- `IpcServer` binds and claims the socket in `init`
  (`ControlSocketListener.open`); acceptance starts only in `start()`.
  Deferring `start()` defers acceptance without releasing ownership, and
  the dev-slot launcher's readiness probe is connect-only, so a deferred
  accept cannot wedge `just launch-slot` (slots also launch `--fresh`, so
  they never see the prompt).
- The reconcile layer already carries six single-optional panel
  projections with the identical desired/diff/lazily-create shape;
  `reconcileConfirmation` takes key focus on the nil-to-non-nil
  transition, which is what preserves user assent for a projected notice.
- The test blast radius is small: only
  `app-tests/AppRuntimeCommandTestSupport.swift` constructs the ports
  value, exactly one test asserts on the recording port's alerts (three
  expect lines in `AppRuntimeIpcCommandTests`), and every app-test runtime
  passes `startsApplicationServices: false`.
- Two more `runModal` sites exist beyond the finding's list, in
  `AppDelegate.installDantermInPath` (install success and failure). They
  open no send frame, but they nest a run loop while IPC is accepting --
  the same class, undemonstrated.
- Found during planning, not in the audit: the launch-deferred config
  error is presented *before* the restore prompt, so at launch one broken
  config plus one recovery snapshot produces two notices that both want to
  be visible. A single notice slot would drop one of them, and dropping
  the restore prompt strands launch (no tabs, no IPC). Notices therefore
  queue.

## 2. Decision

Take the finding's ideal (Option 3), in two independently landed commits.

**Commit 1 -- IPC start split.** The accept loop starts only after the
launch bootstrap decision (init snapshot / restore prompt / fresh)
resolves. Server construction, socket ownership, its scheduling token, and
the initial tailnet status stay in `AppRuntime.init`; only the deferred
start moves behind an explicit runtime call that `AppDelegate` makes after
the bootstrap branch. This closes the demonstrated race by ordering alone
and unblocks RUNTIME-1.

**Commit 2 -- model-projected notices.** `AppRuntimePorts` loses
`presentAlert` entirely. Every user-visible notice -- config error, import
failure, export failure, and the install-in-PATH results -- is reported as
a Msg into an ephemeral FIFO notice queue on the model, projected by a
pure function, and rendered by a new reconcile pass driving a new
non-modal panel on the confirmation template. The launch restore prompt
becomes the same kind of projected notice: `AppDelegate` hands the runtime
the validated restore as inert data and sends a prompt-request Msg; Restore /
Start Fresh arrive as Msgs; the answer resolves to a Command the runtime
performs. After commit 2 no `NSAlert.runModal()` remains in `app/`.

Decisive constraints:

- **IPC start stays gated on the launch decision in commit 2.** The prompt
  path starts acceptance only after the answer commits (restore) or the
  fresh tab is created. Starting it while the projected prompt is up would
  reintroduce the demonstrated discard in a non-modal costume, because
  `commitRestoreSession` still replaces the model wholesale until
  RUNTIME-1 converts it to a Msg.
- **The notice state is a new, separate model slot.** It must not extend
  `PendingConfirmation` or widen `ConfirmationPanel`'s projection: MODEL-1
  and CHROME-2 (audit group C2, both open) are redesigning that
  transaction, and a notice subject dropped into it would be rewritten
  twice.
- **The retained restore stays inert data until the user answers Restore.**
  No terminal session, pane host, or replay file is built while the prompt is
  up: `stageValidatedRestore` runs only on the Restore answer, and Start Fresh
  discards the retained `ValidatedAppRestore` without building anything. A
  recovered shell or command must never run before assent, and Start Fresh must
  leave nothing to dispose.
- **The restore commit keeps its existing contract of running outside any
  send frame** (`sweepAndDispatchFollowUps` is documented and built for
  that), and the prompt panel must not be destroyed on its own
  button-action stack (docs/design/2026-06-09-appkit-lifetime-safety.md).
  The answer Msg therefore may not commit the restore synchronously inside
  its own frame.

## 3. Invariants

- I1: No IPC request is accepted before the launch bootstrap decision has
  resolved -- on the init-snapshot, prompt, and fresh paths alike. Socket
  ownership is still claimed during `AppRuntime.init` (bind, contention
  loss, and stop/teardown pairing are unchanged).
- I2: No code reachable from a command arm can block the main actor on a
  nested run loop. After commit 2 this is unwritable, not merely avoided:
  the ports struct has no alert port to call.
- I3: Every user-visible notice is model state: reported as a Msg,
  projected by a pure function, rendered by a reconcile pass. The panel
  takes key focus on appear (the confirmation panel's assent shape), and
  its buttons and key equivalents dispatch only Msgs.
- I4: Before a restore replaces the model, no reported notice is silently
  dropped while another is showing: they queue FIFO, and answering one
  reveals the next. In particular a launch config error and the restore
  prompt can both be reported and both get seen, and the restore prompt
  remains answerable. The one exception is the restore commit itself, which
  replaces the model wholesale and takes the queue with it (AR2).
- I5: The restore prompt's answer arrives as a Msg; the restore commit it
  triggers runs outside the answering send frame and off the panel's
  button-action stack. The validated restore is held as data until then --
  Restore is what builds sessions, and Start Fresh builds none.
- I6: A command arm may still legitimately re-enter `update()` with a
  non-blocking `send` (input rejection, font resolution). The fix outlaws
  blocking, not re-entry.
- I7: A failed config write still completes font resolution -- the running
  settings apply even when the write failed (existing behavior, kept).

No external-compatibility surface moves: no control sequence, CLI command,
IPC method, or socket path changes.

## 4. Proof obligations

- PO1 (I1): an app test drives a real request against a runtime whose
  services are on: written before the start call it gets no reply (a
  deliberate short expiry, far below the hang guard); after the start call
  it is answered. Needs a defaulted socket-path injection point on
  `AppRuntime.init`. `IpcServerOwnershipTests` (construction-time bind and
  contention) must pass unchanged, as must the pending-IPC-shutdown,
  remote, and scheduling-lifecycle suites.
- PO2 (I2, I7): the existing "config save failure alerts and completes
  font resolution before return" test is rewritten onto the model: a save
  failure driven through a real send frame leaves the failure in the
  notice queue and the font resolution applied. The port half of the old
  assertion becomes a compile-time fact (the field no longer exists).
- PO3 (I3): core tests cover the notice projection for both the error and
  restore-prompt shapes and the enqueue/answer arms; an app test shows the
  reconcile sweep creating the panel on report and retiring it on answer;
  a tests-ui suite in the `ConfirmationPanelTests` shape shows buttons and
  key equivalents sending the Msgs the projection names.
- PO4 (I4): core test: two notices reported in order are shown in order;
  answering the first reveals the second; a restore prompt queued behind a
  config error is still answerable and still resolves the launch.
- PO5 (I1, I5): app tests: while the prompt is up and before either answer,
  no recovered session exists (no pane hosts built from the retained
  restore); answering Restore then builds and commits the session (live pane
  hosts match the recovered panes) and IPC then accepts; answering Start
  Fresh creates a tab, creates no recovered session, and IPC then accepts.
- PO6 (I1): app test: a restore whose session build fails after Restore is
  answered still falls back to a fresh tab, and IPC then accepts -- the
  failure path must not leave the instance permanently unreachable.

## 5. Non-goals / accepted risks / rejected ideas

Non-goals:

- N1: RUNTIME-1 (restore commit as a Msg, `private(set) model`) -- explicitly
  sequenced after this work; `commitRestoreSession` keeps bypassing
  `update()` for now.
- N2: RUNTIME-2 (theme browser model slot) and the C2 confirmation redesign
  -- untouched, though commit 2's pass is the template both will copy.
- N3: Queueing or otherwise reworking confirmations -- only notices queue.

Accepted risks:

- AR1: A config write failure (and import/export/install outcomes) stops
  being must-dismiss-now. Funded by the user; key focus on appear keeps it
  prominent.
- AR2: Notices still queued when a restore commits are dropped with the rest
  of the ephemeral model, because restore replaces the model wholesale
  until RUNTIME-1. This is I4's stated exception, not a violation of it.
- AR3: While the projected restore prompt is up the app is interactive: the
  user can create tabs and then answer Restore, which replaces them. That
  is the ordinary "restore replaces the session" semantic, and the current
  teardown path already handles live sessions.
- AR4: An instance with an unanswered restore prompt is unreachable over
  IPC until the prompt is answered -- exactly today's modal behavior, kept
  deliberately until RUNTIME-1 (see the gating constraint in section 2).

Rejected ideas:

- RI1: Ordering fix alone (audit Option 1): leaves four blocking alert
  sites and the class writable. The user funded the ideal.
- RI2: Non-blocking sheet port (audit Option 2): keeps a synchronous port a
  future implementation can make blocking again, needs a window threaded
  through the port that the ideal must then unpick, and alerts raised
  before the window exists fall back to exactly the hazard being removed.
- RI3: Single notice slot: silently drops one of the two launch notices;
  dropping the restore prompt strands launch entirely.
- RI4: Implementing the notice inside `PendingConfirmation` /
  `ConfirmationPanel`: collides with the open C2 redesign.

## 6. Implementation discretion

- Names and shapes of the new Msgs, model field, projection, panel, and
  Command (note only: `AppModel.alerts` is taken by the bell feed).
- How the answer-to-commit hop leaves the send frame and the button stack,
  within I5.

## Commit progress

- [x] Commit 1 -- `refactor(runtime): start IPC accept after launch
  bootstrap resolves`. Move the deferred server start out of
  `AppRuntime.init` behind an explicit runtime call; `AppDelegate` calls it
  after the bootstrap branch on all three paths; add the socket-path
  injection point; land PO1. Gate: `just test` green; this commit alone
  closes the demonstrated race and unblocks RUNTIME-1.
- [x] Commit 2 -- `feat(runtime): project user-visible notices from the
  model`. Delete the `presentAlert` port; add the notice queue, projection,
  reconcile pass, and panel; convert the four alert sites, the install-path
  alerts, and the restore prompt; move IPC start for the prompt path behind
  the answer; land PO2-PO6 and rewrite the one recording-port test. Gate:
  `just test` green, `just test-ui` green, no `runModal` left in `app/`.

## Implementation notes

- Current master moved pane search state into `PaneModel.live`. The UI gate
  still used the removed `AppModel.searchState` API, so commit 2 also migrates
  those fixtures to the pane-owned state without changing their behavior.
