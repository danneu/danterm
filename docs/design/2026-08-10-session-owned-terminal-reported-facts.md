# Session-Owned Terminal-Reported Facts

- Status: Accepted
- Date: 2026-08-10
- Supersedes: [Terminal-Reported Pane Facts: the Model Owns Values, the Stream Owns Lifecycles](2026-08-10-terminal-reported-pane-facts.md)

## Context

A terminal session reports values such as title, cwd, and progress; state
machines such as command, connection, agent, and integration lifecycles; and
stateless occurrences such as bells and desktop notifications. The previous
design split their stored state between two owners. Values lived on
`PaneModel`, while lifecycles lived in a runtime-owned
`PaneLifecycleStream` sampled by pure code through `PaneLifecyclesView`.

That split kept one stored owner per fact, but it assigned ownership from the
fact's reduction behavior instead of its lifetime. Every reported fact is true
of the terminal session that emitted it. A title is assignment-only, but a
late title from a dead session must not rename the replacement session in the
same pane. Likewise, ending a session ends its command and connection state
without a separate cleanup operation. The pane/session relationship must make
those guarantees structural.

Split ownership also requires coordination outside the model. `update()` must
sample runtime lifecycle state, checkpoint capture must graft runtime recovery
state onto a pure snapshot, and agent IPC transitions must use a special
command so the runtime applies the transition before replying. These are
workarounds for state that belongs to the model but is stored outside it.

The superseded ADR explicitly required a uniform model design to prove two
properties: every session-end path must end session-scoped state, and an agent
IPC reply must follow the transition it acknowledges. This decision supplies
both proofs.

## Decision

D1. **A session owns every fact reported by that session.**

`SessionModel` is a pure value in `DanTermCore`. It carries a typed
`SessionId`, reported values, lifecycle state, and the recovery memo needed to
project a checkpoint. Value reports still assign. Lifecycle reports still
pass through their ordered reducer and may be refused. The distinction
determines reduction behavior, not ownership.

Bell and desktop notification reports remain stateless occurrences. They are
session-keyed so a late occurrence can be rejected, but they do not become
stored `SessionModel` fields.

D2. **A pane owns its session by nesting the value.**

`PaneModel` contains `session: SessionModel?`; there is no session table,
foreign key, or reverse index. Removing a pane's tree leaf removes its session
in the same mutation, so an orphan session is unrepresentable. Replacing or
detaching a session is one assignment. The optional is the seam for those
operations even though current behavior creates a session with every pane and
closes the pane when that session ends.

Pane-owned content such as theme, font size, and todos stays on `PaneModel`.
Search and first-responder state also remain pane-keyed because the user or
view owns those facts rather than the terminal session.

D3. **Every inbound terminal report carries a `SessionId`.**

Core resolves the pane whose nested session has that id. A report, bell,
notification, end, or creation failure for an unknown id changes nothing and
emits nothing. Fresh pane creation, splitting, and restore mint distinct
session ids. Restore never persists or reuses an old id.

This identity check separates a pane slot from whichever session currently
occupies it. A delayed report from a dead or replaced session cannot mutate,
alert for, or close the replacement.

D4. **Reduction happens inside `update()`.**

One `SessionReport` vocabulary and one pure reducer handle all stored reports.
`update()` performs metadata admission, resolves the session, reduces the
report, and emits effects only when the accepted report changed the model.
The runtime owns the PTY, terminal engine, and event delivery, but it owns no
terminal-reported state.

Agent attach, activity, and detach IPC methods recursively reduce their
session report during the same `update()` pass that appends the reply command.
The model therefore reflects the accepted transition whenever the reply
exists, and the command interpreter's list order sends the reply afterward.
No runtime callback or special apply command is needed to maintain ordering.

D5. **IPC and persistence are projections of session-owned state.**

IPC continues to flatten title, cwd, command, connection, agent, and
integration fields into the pane response. That wire shape does not mirror
storage ownership. A pane without a session projects the established terminal
defaults.

Checkpoint capture reads report values and recovery memo directly from the
nested session. The `PaneSnapshot` disk shape stays unchanged. Restore creates
a fresh session id and seeds its report values and recovery memo while leaving
live lifecycle attachments at their defaults. Engine-owned scrollback remains
an enriched checkpoint graft because it is not terminal-reported model state.

D6. **Terminal-reported text is stored verbatim; normalization happens once,
where a render-ready payload is built.**

The model, IPC JSON, and checkpoints hold a reported title, cwd, command, and
remote identity byte for byte. They are functional data: a new pane inherits
`cwd`, IPC clients target panes by exact `cwd` and `title`, and a checkpoint
must reproduce what was captured. Rewriting them where they are stored would
corrupt values that are not only displayed.

A program can put a newline or a raw control character into any of them with
one escape sequence, and a label in a fixed-height row wraps rather than
truncates. So the single-line invariant lives at the one boundary where model
state becomes a display string: the projection layer. `DisplayLine`
(`lib/DanTermCore/Sources/DanTermCore/DisplayLine.swift`) is a value type whose
only initializer normalizes, and it is the declared type of every render-ready
field -- projections, display-bearing `Command`s, and stored derived
presentation such as `AlertModel.title`. Shared model and IPC helpers keep
returning `String`; their projection call sites wrap.

The exception is text that is deliberately not one line: an alert body is the
sender's message and may legitimately wrap, and it stays raw.

## Proofs

P1. **Session-end cleanup is structural.** The only live `SessionModel` is the
value nested in its owning pane. Current session-end handling removes that
pane's leaf, which removes the session and every reported fact atomically.
Future detach or replacement assigns the optional once; it cannot leave a
second stored owner behind.

P2. **IPC reply ordering is structural.** Agent IPC dispatch invokes the pure
report reduction before appending `.ipcReply` to the returned command list.
The state transition and the decision to reply share one `update()` pass, and
the runtime performs the list in order.

P3. **Late reports are structurally droppable.** A session-keyed message can
reach state only through lookup of its exact `SessionId`. Removal or
replacement deletes that id from the live model, so every later message from
the old session follows the same pure no-op path.

## Consequences

- `PaneModel` has no copied terminal-session state. All terminal-reported
  values and lifecycle state move into its nested `SessionModel`.
- `PaneLifecycleStream`, `PaneLifecyclesView`, lifecycle recovery grafts, and
  the `livePaneState` input to pure functions disappear.
- Model projections for chrome, IPC, inherited cwd, alerts, and checkpoints
  resolve the pane's nested session and provide stable defaults when absent.
- Metadata byte limits move to the model's single report-admission boundary.
- Recovery becomes idempotent for command and agent memo: restoring and then
  taking a light checkpoint preserves the snapshot's recovery data.
- The error for an agent IPC event whose pane vanished becomes the standard
  pane-not-found error. Successful agent IPC replies remain unconditional, as
  before.
- Session end still closes the pane. Restart, hold-open, and detached-session
  behavior remain separate decisions.

## References

- [2026-08-10-terminal-reported-pane-facts.md](2026-08-10-terminal-reported-pane-facts.md)
  -- the superseded split-ownership decision and the two proof obligations
  answered here.
- [2026-08-05-pane-session-lexicon.md](2026-08-05-pane-session-lexicon.md)
  -- the distinction between a pane slot and a running terminal session.
- [2026-05-28-pure-core-support-split.md](2026-05-28-pure-core-support-split.md)
  -- the pure model boundary that owns `SessionModel` and its reducer.
- [2026-08-06-swift-terminal-engine.md](2026-08-06-swift-terminal-engine.md)
  -- the terminal engine and process-lifecycle contract, including pane close
  on session end.
