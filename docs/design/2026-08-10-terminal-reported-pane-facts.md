# Terminal-Reported Pane Facts: the Model Owns Values, the Stream Owns Lifecycles

- Status: Superseded
- Date: 2026-08-10
- Superseded by: [Session-Owned Terminal-Reported Facts](2026-08-10-session-owned-terminal-reported-facts.md)

> **2026-08-10: superseded by session-owned terminal-reported facts.** The
> value/lifecycle distinction still determines how a report reduces, but it no
> longer determines where the result lives. Every terminal-reported fact ends
> with its terminal session, so the session model owns both kinds. The body is
> unedited as the record of the former split-ownership design.

## Context

A terminal program can tell DanTerm things about a pane: its title, its
working directory, a progress bar, "a command just started", "you are now on
a remote host". Every such fact needs a home, and there are two: flat fields
on the pane model, fed by Msgs and guarded in `update()`, or the pane-owned
lifecycle stream, reduced by the pure per-pane reducer and read as snapshots.

Until now the boundary between the two was picked by accident: the facts a
plan happened to cover became stream state, and the rest stayed model
fields. The collapse of the five mirrored fields (isRemote, remoteSession,
remoteThemeOverride, agentSession, lastCommand) removed the duplication but
not the ambiguity -- title, cwd, and progress arrive through the same
boundary and look, structurally, like the pattern that was just deleted.
This document states the rule that keeps the next fact from being placed by
accident.

## Decision

D1. **For terminal-reported facts: the model owns values; the pane's stream
owns lifecycles.**

A **value** is a fact where the latest report is the whole truth. A new
report overwrites the old one, no report is ever refused because of what the
state currently is, and the truth is carried until overwritten. Values live
as pane-model fields, one Msg each, with admission guards in `update()`.

A **lifecycle** is a state machine: order carries meaning. Something begins
and must be ended by the same source that began it, some reports must be
refused ("command ended" while idle, activity without an attached agent),
and some combinations must be unrepresentable (a remote identity on a local
connection). Lifecycles live in the pane-owned stream.

**The test, applied per fact, in two questions.** First: what would the
reducer do with each report about the fact? If any report must be refused,
paired, or forbidden, the fact is a lifecycle. (Per fact, not per report: an
attach report alone is bare assignment; the agent fact is a lifecycle
because detach and activity are not.) Second: is the end of the fact's
session itself a semantic end for the fact? A lifecycle's truth is a claim
about its session -- when the session that carries it ends while the pane
model remains, the fact has ended, whatever the last report said. Such
session-scoped truth belongs to the stream even when every report is plain
assignment. A value's truth is a claim about the pane; the session ending
does not falsify it, and the model carries it until overwritten. A fact is
a value only if every report is assignment *and* its truth is not
session-scoped. What a checkpoint saves or a restore replays is policy
layered on top and plays no part in the test.

Two clauses follow from the rule rather than standing beside it:

- D2. **Admission.** A lifecycle can only be enforced when its source is
  explicitly admitted and contracts to report every transition the reducer
  enforces for that fact. Admission is about contract, not protocol
  visibility: a public protocol that contracted complete transitions could
  qualify. The admitted sources today are DanTerm's shell envelope and pane
  IPC; today's public escape sequences contract nothing, so they can only
  ever yield values or stateless occurrences.
- D3. **One fact, one owner.** Nothing is stored in both places. The model
  reads lifecycle state only through read-only channels -- today the
  adapter's transition-bearing session event, lowered to an event-only Msg
  that carries no state; the runtime-sampled read-only view passed into
  `update()` and the projections; and the recovery projections grafted at
  checkpoint capture -- but never keeps its own copy. Placement also fixes the rest: the admission guard
  sits at the owner's front door (event lowering for lifecycles, `update()`
  for values), and persistence saves values directly from the model while
  lifecycles are never saved -- only grafted projections are.

Storage ownership does not dictate presentation shape. IPC reads both owners
and projects one flat pane snapshot: model values such as `title` and `cwd`
sit beside the stream's `command`, `connection`, `agent`, and `integration`
objects. Flattening the read does not create another stored copy.

### Classification

| Fact | Kind | Home |
|---|---|---|
| title, cwd, progress | value | pane-model field |
| command, connection, agent | lifecycle | pane-owned stream |
| integration readiness | lifecycle (a one-way latch) | pane-owned stream |
| bell, desktop notification | neither -- stateless occurrence | immediate effect, nothing stored |

Integration readiness is the degenerate lifecycle: a latch begun by its
first report and ended only by its session's own end. Its truth is "this
session's integration has spoken", not "some shell once spoke" --
session-scoped by the second question, even though its one report is plain
assignment.

Outside the rule entirely:

- **Todos, tab names, pane themes** are not reported facts. The user or an
  agent edits them over UI and IPC; they are model-owned content, like any
  document.
- **Search** is a lifecycle the *model* owns -- the user starts and ends a
  search -- so the engine's reported match counts are values inside it.

Placement follows this rule and nothing else: not how many consumers a fact
has, not whether it is persisted, not whether its protocol is private, and
not which plan introduced it.

## Naming

The code says the rule so the reader never has to ask it. "Semantic" is
retired: it was vague enough to cover both sides, which is how placement got
picked by accident. "Lifetime" is not used either; that word is spent on
AppKit object-lifetime safety, and the stored state here is the current
phase of a recurring machine, not a span.

- Stream side: `PaneLifecycles` holding `CommandLifecycle`,
  `ConnectionLifecycle`, `AgentLifecycle`, and `IntegrationLatch` (a latch
  is a lifecycle whose only report is its beginning). The reducer, stream,
  transition type, Msg, and the read-only view rename to match
  (`PaneLifecycleReducer`, `paneLifecycleChanged`, `LivePaneStateView` ->
  `PaneLifecyclesView`, ...).
- The plain `PaneLifecycle*` vocabulary belongs to the reported-fact machine
  in `DanTermCore`. The PTY child-process launch, exit, and teardown machine
  uses `PaneProcessLifecycle*`, including its module name, so the two meanings
  cannot collide at an import site.
- Model side: terminal-reported values remain direct `PaneModel` fields
  (`pane.title`, `pane.cwd`, `pane.progress`). They are independent values,
  not one atomic aggregate. Owned content (`todos`, `theme`, `fontSizeSteps`)
  remains beside them.
- CLI: `ls` and `pane.info` flatten the four lifecycle objects directly onto
  each pane as `command`, `connection`, `agent`, and `integration`. The CLI
  exposes the pane snapshot clients need, not the internal ownership split.

The word "facet" retires with "semantic": the fields of `PaneLifecycles`
are just `command`, `connection`, `agent`.

## Rejected

- Uniform stream ownership -- every terminal-reported fact pane-owned, one
  boundary for everything. It costs `splitPane`'s pure synchronous cwd read
  and extra checkpoint grafts, and prevents nothing: divergence requires two
  owners, and values have one.
- Uniform model ownership -- every fact in `PaneModel`, the lifecycle
  reducer applied inside `update()`, value-vs-lifecycle deciding only data
  shape. Out of scope, not refuted here: it re-opens the previously shipped
  stream-ownership decision. Such a change owes two proofs this document does
  not carry: that every path that ends a session also ends model-held
  session-scoped state (today the session owns that state, so the guarantee
  is structural rather than maintained), and that pane IPC replies stay
  ordered after the transition they report once the reducer moves inside
  `update()`. The Elm-purity concern it would answer is already answered:
  `update()` reads live state as an explicit read-only argument, so pure
  code sees no second mutable owner.

## Consequences

- This document graduates to `docs/design/` (with an index entry) before
  any code comment cites it; comments cite the final path and clause, never
  the scratch path.
- The internal rename is mechanical. The observable CLI change lands TDD:
  exact-shape IPC reply tests pin the four flat lifecycle objects in both
  `ls` and `pane.info`, with no `semantics` or `live` wrapper, while the value,
  reducer, recovery, and routing suites stay green. The CLI change carries
  the standing SKILL.md co-update rule.
- The rule travels to the lifecycle point of edit in the `PaneLifecycles`
  header, which cites D1 and its per-fact test, D2, and D3. Direct model values
  stay ordinary fields because their independent latest-value behavior needs
  no aggregate type.
- A fact moves the day a lifecycle is decided for it, and not before its
  source contracts to report that lifecycle. Worked example: if a progress
  bar's validity ever becomes bounded by the command that set it, that
  decision makes progress a phase of the command lifecycle's scope, and it
  moves into the reducer.

## References

- `lib/DanTermCore/Sources/DanTermCore/PaneLifecycleReducer.swift#reducePaneLifecycles`
  -- the current reducer for pane-owned lifecycle facts.
- `lib/DanTermCore/Sources/DanTermCore/Model.swift#PaneModel` -- the model that
  owns pane-scoped reported values and user-owned content.
- [2026-05-28-pure-core-support-split.md](2026-05-28-pure-core-support-split.md)
  -- the pure core boundary that contains both owners and their reduction.
- [2026-08-06-swift-terminal-engine.md](2026-08-06-swift-terminal-engine.md)
  -- the terminal engine and shell-integration decisions that produce these
  reports.
