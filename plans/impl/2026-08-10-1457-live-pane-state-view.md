# update() reads live pane state through a view

## Problem

Live pane semantics are owned by the pane session, not by `AppModel` -- the
duplicate model fields were removed deliberately (`3d8f1226`). But `update()`
has no way to read the surviving owner, so every consumer routes around it:

- `Msg.desktopNotification` carries a `PaneSemanticState` payload purely so
  alert titles can see the agent/command facets.
- `Msg.paneSemanticsChanged` carries the whole `PaneSemanticTransition`, so
  `update()` reads current pane state out of a message payload: the
  `commandEnded` arm branches on `transition.current.agent` to decide whether to
  checkpoint, and the waiting-alert arm passes `transition.current` down.
- `ls` and `pane.info` return half-built replies through deferred
  `.readPaneList` / `.readPaneInfo` commands, which the runtime finishes by
  patching semantics into an already-encoded JSON document.
- The `ls` patcher walks the whole document and decorates any object whose
  `id` parses as a UUID present in the semantics dictionary. Nothing structural
  stops it decorating a tab or group.

Underneath that sits a second coupling. The `ls` reply is the persistence
snapshot round-tripped through `JSONEncoder`, and `tab new` embeds one tab of
it. So the CLI's documented shape is an accident of the init-file format --
version 3 changed `ls` output as a side effect -- and live-only facts
structurally cannot appear in it. `pane.info` already carries a comment
recording that workaround: zoom "is transient and so never reaches the
persisted snapshot `ls` returns," so `pane.info` grew a field `ls` cannot have.
Semantics is the same wall hit again. The landed persistence work already
rejected this coupling in its own direction ("couples the CLI listing format to
the recovery file format forever"); borrowing `toSnapshot` for reply structure
is that same coupling one level down.

Desired outcome: `update()` reads live pane state directly, IPC replies are
encoded once by core from typed model values, and no reply is produced by
patching a document after the fact.

## Decision

`update()` takes a read-only view of live pane state alongside `env`. The
runtime supplies it at dispatch from the sessions it owns; core reads it and
never mutates it. Session-owned state still changes only by returning a command
(the existing pane-semantic IPC command is unaffected).

The view is the only channel for current pane state, so messages go back to
saying what happened. `Msg.paneSemanticsChanged` narrows to the pane id and the
semantic event; `Msg.desktopNotification` loses its semantics payload. The
transition value keeps its job at the session boundary, where the reducer
already builds it: `didChange` filtering and the recovery projection stay
there. Every `update()` decision that needs current pane state -- the
`commandEnded` checkpoint branch and the waiting-alert presentation alike --
reads the view.

The view is a nominal type with typed per-facet accessors, not an alias for a
`[PaneId: PaneSemanticState]` dictionary, so the follow-up moving pane title
and cwd adds accessors rather than a second parallel channel.

The view is **not** part of `CoreEnv` and must not be folded into it. `CoreEnv`
seams nondeterminism -- clock, fresh ids, home directory. This seams *state with
a different owner*. Its admission rule is explicit: a fact belongs in the view
when it is owned by a live pane session and not by `AppModel`. Today that is
pane semantics; the shape is general so the follow-up work moving pane title and
cwd out of the model has somewhere to put them.

IPC replies stop borrowing the persistence codec. Core gains typed per-entity
encoders -- pane, tab, group -- built from model values. `ls` composes them over
the model tree, `pane.info` composes all three, and the `tab new`, zoom, and
theme replies reuse them instead of round-tripping a snapshot. Semantics
attaches inside the one pane encoder, read from the view. The tree walk then has
no reason to exist, and neither do the two deferred commands, the two patch
functions, or the runtime code that calls them.

The view also replaces the loose `[PaneId: PaneSemanticState]` parameters
threaded into the pane-toolbar and pane-config projections, so one concept
covers every consumer. Neither those parameters nor the view parameter on
`update()` carries a default in production code: an empty default silently
turns a semantics-dependent assertion into a passing test. The test target
supplies its own defaulted call, so existing test call sites are unaffected and
production code cannot omit the view.

## Invariants

- **I1 Read-only.** `update()` never mutates the view and never branches on
  whether a runtime session object exists. Live pane state changes only through
  a returned command.
- **I2 Totality.** Every pane present in the model answers `ls` and `pane.info`
  with a complete semantics object; a pane with no live state encodes as
  never-reported / idle / local / no-agent. No IPC method fails because a
  session object is missing. (Methods that need a live session to *act* --
  reading text, sending keys, tape -- keep their existing errors.)
- **I3 One encoding site.** Semantics is attached where a pane is encoded, and
  no reply is assembled by editing an already-encoded document. No object other
  than a pane ever carries a `semantics` key.
- **I4 Format independence.** IPC reply shapes are determined by core's entity
  encoders alone. A change to the init-file snapshot format changes no reply.
- **I5 Wire compatibility.** The observable shapes of `ls`, `pane.info`, and
  `tab new` are unchanged, including home-abbreviated pane `cwd`.
- **I6 One live-state channel.** No message payload carries pane-owned live
  state. Messages name the event; every `update()` decision that depends on
  current pane state -- checkpoint scheduling, notification and alert titles --
  reads the view at dispatch.

## Proof obligations

- **PO1 (I5).** For a model with several groups, a nested split tree, custom tab
  titles, todos, and pane themes, `ls`, `pane.info`, and `tab new` produce the
  documented shape asserted against an explicit expected document -- not one
  derived from the snapshot encoder. Existing `ls`/`pane.info` shape assertions
  keep passing.
- **PO2 (I2).** `ls` and `pane.info` for a model-present pane with no live view
  entry return complete default semantics and succeed.
- **PO3 (I3).** A model in which a tab or group id equals a pane id yields
  semantics on the pane only. This is the regression the id-driven walk allowed.
- **PO4 (I4).** `ls` output is unchanged by a snapshot-format change: pinned by
  PO1's explicit expected document, which no longer has a path to the
  persistence codec.
- **PO5 (I6).** A desktop notification for a pane with an attached agent, and
  the agent-waiting alert, title from the view rather than from message state.
- **PO6 (I6).** One identical `commandEnded` message produces different
  behavior with different views: it schedules a checkpoint when the supplied
  view reports an attached agent for that pane, and schedules none when the view
  reports no agent. This is what proves the checkpoint decision reads the view
  and not a message payload.
- **PO7 (I1).** Core purity holds: the existing determinism and purity gates
  pass with the new parameter, and repeated `update()` over the same
  (model, msg, view) is identical.

## Non-goals

- Reshaping `ls` output. Decoupling stops the shape being an accident of the
  file format; changing it is a separate decision.
- Putting semantics into the persistence format.
- Changing the pane-semantic IPC method's reply, which stays a bare
  acknowledgement.
- Moving pane title and cwd out of the model. That is the follow-up this
  unblocks; note that both are persisted, so it must also decide how the
  checkpoint path reads them.

## Accepted risks

- **AR1.** The view is sampled at dispatch, so an alert reports semantics as of
  dispatch rather than as of the terminal event that raised it. Both sit in one
  runloop turn in practice, and where they differ the dispatch-time value is the
  more accurate one.
- **AR2.** The entity encoders and the checkpoint codec now describe overlapping
  structure in two places and can drift. That shared structure is exactly what
  made the CLI surface an accident of the file format; PO1 pins the wire side.

## Rejected ideas

- **RI1.** Mirror semantics back into `AppModel` so `update()` reads it without a
  new parameter. Reverses the mirror removal and reintroduces divergence between
  the pane's state and the model's copy.
- **RI2.** Carry the view as a `CoreEnv` field to avoid changing call-site arity.
  Cheaper diff, but it destroys the one thing `CoreEnv` means.
- **RI3.** Fix only the tree walk by giving the pane object a typed marker.
  Removes the decoration hazard but leaves the deferred commands, the message
  payload, and the persistence coupling in place.
- **RI4.** Expose session presence in the view so `pane.info` can keep its
  "pane session no longer available" error. That error is an artifact of the
  runtime resolving the session at reply time, is undocumented, and contradicts
  `ls`, which answers for the same pane in the same window. Preserving it would
  leak runtime object lifecycle into core.

## Implementation discretion

- The view type's name and internal representation, and how the per-entity
  encoders are decomposed and shared.
- Where the test-target defaulted call lives.

## Critical files

- `lib/DanTermCore/Sources/DanTermCore/Update.swift` -- `update()` signature and
  its ~22 self-calls; `dispatchIpc`'s `ls` / `pane.info` / zoom arms; the
  private reply builders (`paneInfoResult`, `tabSnapshotJSON`, `tabNewResult`,
  `paneResult`, `paneThemeResult`) that become the entity encoders; the bell,
  notification, and `paneSemanticsChanged` arms.
- `lib/DanTermCore/Sources/DanTermCore/PaneSemanticConsumers.swift` -- keeps the
  facet encoder, loses both `adding:` patchers.
- `lib/DanTermCore/Sources/DanTermCore/Command.swift`,
  `Msg.swift`, `TerminalBackendBoundary.swift` -- the deleted commands, the
  deleted `desktopNotification` semantics payload, and the narrowing of
  `paneSemanticsChanged` to an event; `terminalMessages` keeps the transition
  long enough to apply `didChange`.
- `lib/DanTermCore/Sources/DanTermCore/Projections.swift`,
  `AlertPresentation.swift` -- semantics parameters unify onto the view; the
  existing defaults go.
- `app/AppRuntime.swift` (`send`, and the deleted patch arms),
  `app/Reconcile.swift` -- one runtime accessor builds the view from `sessions`.
- `lib/DanTermCore/Tests/DanTermCoreTests/` -- `UpdateIpcTests`,
  `PaneSemanticConsumerTests`, `UpdateAlertTests`, `TestSupport`, plus the
  suites that construct transitions to drive `update()` today
  (`CheckpointTests`, `UpdateRemoteTests`, `UpdateSessionEventTests`,
  `TerminalBackendBoundaryTests`).

## Verification

- `swift test --package-path lib/DanTermCore` -- PO1-PO7 plus the existing
  suites; the IPC shape tests are the compatibility gate.
- `just test` as the full gate, including the core purity lint.
- End to end against a real instance: `just launch-slot`, then over that slot's
  socket confirm `ls` reports semantics under every pane and nowhere else,
  `pane info` matches it, `agent attach` followed by `pane info` shows the
  attached session, and `tab new` returns its usual shape.
- Confirm `integrations/danterm/SKILL.md` still describes the emitted shapes; no
  change is expected, and a needed change means I5 broke.

## Commit progress

- [x] 1. refactor(core): read pane semantics through a live-state view
- [ ] 2. refactor(ipc): encode entity replies directly in core
