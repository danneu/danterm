# Live Pane Semantic Model

## Problem

The Swift engine already recognizes pane facts that matter outside terminal
rendering: typed DanTermShell command and remote events, OSC 7 cwd, and the
Claude Code and Codex hooks that attach an agent session to a pane. Today those
facts cross several callbacks and collapse into unrelated latest-value fields
in DanTerm's top-level model. That makes it difficult to answer even live
questions consistently: whether the shell integration is present, whether a
reported command is running, which remote identity is active, and whether an
attached agent is working or waiting on the user.

Historical command records are a separate problem. Retaining them requires
durable output anchors, destructive-mutation handling, independent retention
bounds, structured queries, and correlated command admission. None of that is
required to prove the live semantic architecture or replace libghostty.

## Decision

The first semantic-model slice is deliberately live and latest-value only.
Each pane owns a small deterministic semantic state beside its terminal and
lifecycle state. One ordered pane-scoped input stream drives independent
facets:

- **integration**: never reported, or ready
- **command**: idle, or running one completely reported command
- **connection**: local, remote with no reported identity, or remote with a
  reported identity
- **agent**: none, or an attached agent session with the subset of activity
  states its integration can genuinely report

The connection facet needs all three states because detection and identity
come from opposite ends of the connection. The local shell wrapper detects
that a remote command was launched and is always available; the remote
identity is reported by DanTerm's integration on the far host and may never
arrive at all. Remote-without-identity is therefore the normal state for any
host that does not run the integration, not a transient one, and today's pane
chrome already depends on the distinction -- the remote badge keys off
detection alone while the `user@host` label keys off the reported identity
(`app/PaneWrapperView.swift#updateToolbar`). Model it as one sum type rather
than a boolean beside an optional, so that a reported identity on a local
connection is unrepresentable instead of merely unreachable; the current pane
model carries `isRemote` and `remoteSession` as separate fields and holds that
invariant by hand.

Sketched as types, so that a missing state is visible rather than buried in a
sentence. This is illustrative, not normative: names and value representation
belong to the implementer except where an invariant below constrains the
shape, and it should be edited as the slice teaches us more.

```swift
enum IntegrationFacet {
    case neverReported
    case ready
}

enum CommandFacet {
    case idle
    case running(CommandReport)          // exactly one, completely reported
}

enum ConnectionFacet {
    case local
    case remote(identity: RemoteIdentity?)   // nil until the far end reports
}

enum AgentFacet {
    case none
    case attached(AgentSession, activity: AgentActivity?)
}

struct PaneSemanticState {
    var integration: IntegrationFacet
    var command: CommandFacet
    var connection: ConnectionFacet
    var agent: AgentFacet
}
```

`ConnectionFacet` is where the shape carries weight: folding identity inside
the `remote` case is what makes a reported identity on a local connection
unrepresentable. An equivalent phrasing is an optional
`RemoteConnection` struct holding an optional session. A `Bool` beside a
separate optional is not equivalent and does not satisfy the invariant.

The pane owner serializes terminal-originated envelope events, pane-scoped IPC
events, and teardown into that stream. The reducer performs no IO, reads no
ambient state, and produces latest-value snapshots and immediate product
effects. Rendered cells are never an input.

This slice does not retain a command list. Command completion is an immediate
semantic transition, not history: command-end moves the command facet to idle
and may emit a bounded pane-scoped completion fact containing the completely
reported command and exit status for a live consumer. Once delivered, that
fact is not queryable. If no consumer earns it in this slice, the reducer may
discard the status after applying the transition.

### Declared semantic inputs

DanTerm's private, versioned shell envelope remains the authority for shell
facts:

- `integration-ready` is emitted when the bundled shell integration
  initializes. It is the only input that distinguishes an integrated idle
  shell from a pane whose integration has never reported. Ready means the
  integration has reported at least once during this pane's lifetime, not
  that an integrated shell is necessarily still active; without an explicit
  loss report, replacing that shell can leave the latest value stale until
  pane teardown.
- `command-start` carries command text as one complete report. A malformed or
  oversized report is dropped whole.
- `command-end` carries the exit status. It ends the currently reported
  command; an end while idle is ignored. It changes only the command facet.
- remote events drive the live connection facet: detection from the local
  wrapper that launches the remote command, a reported identity from the far
  end's integration, and a connection-end report from the same local wrapper
  when that remote command returns.
- agent lifetime is symmetric with attachment: an attached session ends only on
  an explicit detach input from the agent's own end-of-session surface, or on
  pane teardown.

Each facet therefore ends on a lifetime-end input from the same source that
began it. Today's shipped behavior contradicts that: `update`'s `.commandEnded`
arm clears `isRemote`, `remoteSession`, `agentSession`, and
`remoteThemeOverride` together, pinned by
`lib/DanTermCore/Tests/DanTermCoreTests/UpdateRemoteTests.swift`. The coupling
is right only for the flat case where the connection's lifetime *is* the
command's; a command that ends inside a live connection -- any command run in
an `ssh` shell, tmux, or a nested PTY, whose far-end integration reports
command-end through the same PTY -- drops the remote badge and identity while
still connected. This slice removes the coupling deliberately and rewrites
those tests on purpose, rather than leaving the facet reducer and the pane
model holding disagreeing answers to the same question.

The local wrapper is where the connection-end report belongs: it already
brackets the remote command (`integrations/shell-integration/danterm.zsh#danterm_ssh`
emits detection before `command ssh` and regains control after it returns), so
the end report is authoritative and needs no inference. R2 settles how that
report survives ssh, mosh, tmux, and nested PTYs, and which end-of-session hook
each bundled agent integration actually exposes. An integration whose audit
finds no end hook detaches on pane teardown only; that is a stated limit, not a
license to reintroduce command-driven clearing.

Nesting is handled at the emitting end, not by making the facet a stack. The
integration wraps `ssh` on remote hosts too, so `local -> A -> B` is a real
trace; but the wrapper that pops a nested connection is the enclosing host's
own, and it re-reports the enclosing identity immediately after the inner
command returns (`danterm.zsh#danterm_ssh`, and the same branch in the Bash and
fish integrations). A single latest-value connection facet is therefore
sufficient: `connection-end` for B is followed in the same emission by
`remote-host` for A, and a reported identity with no prior detection re-enters
remote. Step 1 must keep that pairing intact and extend it to every wrapper it
adds an end report to -- a wrapper that emits `connection-end` without
re-reporting its own identity leaves the pane showing local until the enclosing
shell's next prompt.

OSC 133 prompt/input/output marks remain an engine-internal row-classification
and prompt-redraw protocol. They never create command state. OSC 7 remains the
live cwd source used by pane chrome and split inheritance, but the command
facet never assembles a command report from an OSC 7 snapshot.

Pane-scoped IPC events join the same owner-serialized stream. `danterm agent
attach` supplies the attached session. Activity hooks may report working,
waiting, or idle only where the corresponding Claude Code or Codex hook
surface can distinguish that state. An unsupported activity is absent rather
than inferred.

### Total live transitions

The reducer has pinned degradation behavior:

- integration-ready while already ready is idempotent
- command-start replaces any dangling running command with the newest complete
  report
- command-end while idle is ignored
- command-end while running returns the command facet to idle and leaves the
  connection and agent facets untouched
- remote detection while the connection facet already carries a reported
  identity keeps that identity rather than discarding it
- a reported remote identity with no prior detection still enters remote
- connection-end returns the connection facet to local, discarding any reported
  identity; connection-end while already local is ignored
- agent detach returns the agent facet to none; detach with no attached session
  is ignored
- pane teardown clears all live facets
- agent activity without an attached session is ignored
- malformed, oversized, and unknown inputs apply nothing

These rules keep the live model total without manufacturing partial commands
or preserving history. A replaced or torn-down command is simply no longer
live; explaining what happened to it belongs to the deferred journal design.

### Ownership and consumers

The semantic state lives with the pane owner, not in DanTerm's top-level Elm
model. Read-only snapshots may reach renderer chrome, sidebar projections, and
IPC. The top-level model continues to receive only product-level latest values
and immediate effects needed by existing behavior.

An IPC method that mutates semantic state replies only after the serialized
pane owner has applied the transition. Today `agent attach` mutates before
returning success in the same synchronous step; routing it through the pane
owner must not weaken that to enqueue-then-reply, or a successful attach
followed immediately by pane inspection can observe the pre-attach state --
exactly the inconsistency this slice exists to remove.

The first useful consumers are deliberately narrow:

- pane inspection can report whether semantic integration is absent or ready
  and expose the current facets as typed latest-value data
- command chrome can distinguish idle from running without treating
  `lastCommand` as permanent running state
- an attached agent entering a genuinely supported waiting state in an
  unfocused pane raises an alert through the existing alert/notification
  pipeline; its click follows the existing `.activateAlert` path to focus that
  pane, and it shares `alertPresentation` with the title behavior below
- notification titles name who raised the alert. `alertPresentation` already
  resolves that title through a fallback chain -- the sender's own OSC 777
  title, else the pane title -- and the attached agent session and the running
  command report become the earlier tiers. This is the cheapest consumer that
  proves a read-only snapshot actually reaches one, and it shares its title
  formatting with the needs-attention notification above rather than growing a
  second formatter

CLI surface changes carry the standing `integrations/danterm/SKILL.md`
co-update rule.

## Invariants

- Identical ordered explicit inputs produce identical live facets and ordered
  effects; terminal input chunking does not change the result.
- Every facet derives only from its declared semantic source; rendered cells
  are never an input.
- At most one completely reported command is running. No partial command state
  exists.
- Integration readiness is reported explicitly, never inferred from silence,
  marks, cwd, or command text.
- A reported remote identity cannot exist on a local connection, and remote
  without a reported identity is a valid steady state, not a transient one.
- Agent activity cannot exist without an attached session, and integrations
  never claim activity states their hooks cannot distinguish.
- Malformed, oversized, unknown, and excess inputs remain bounded, pane-scoped,
  and cannot prevent later valid inputs from being processed.
- Mutable semantic state has the same single pane owner as terminal and
  lifecycle state; consumers receive read-only latest-value snapshots.
- No command journal, output span, or historical text authority exists in this
  slice.

## Proof obligations

- Neutral replay fixtures produce identical live facets and ordered effects
  under authored, bytewise, and split replay.
- Integration fixtures pin the four relevant states: no integration stays
  never-reported; ready-then-idle reports ready and idle; marks-only foreign
  integration stays never-reported; malformed ready is dropped whole.
- Command traces cover start/end, end while idle, start while already running,
  malformed and oversized reports, pane teardown while running, and later
  valid recovery after adversarial events.
- Nested remote-session traces prove command and connection facets transition
  independently without adding connection identity or OSC 7 cwd to command
  state.
- Lifetime-end traces prove each facet ends from its own source: a command-end
  inside a live connection with an attached agent leaves both the connection
  and agent facets intact, connection-end returns the connection facet to local
  and drops the reported identity, and agent detach returns the agent facet to
  none.
- A nested connection trace -- detect A, identity A, detect B, identity B, end
  B, identity A, end A -- lands on identity A after B ends and on local only at
  the end, with the same result when B never reports an identity. A real
  nested-`ssh` run through the bundled integrations proves the emitted stream
  actually has that shape.
- A remote host that never reports an identity holds the connection facet at
  remote-without-identity for the whole session, and a later identity report
  upgrades it in place without a return through local.
- The bundled zsh, Bash, and fish integrations drive complete ready,
  command-start, and command-end transitions with exit status through a real
  Swift pane; ssh, mosh, tmux, and nested-PTY characterization determines and
  pins the supported forwarding behavior.
- Pane-owner ordering fixtures interleave envelope events with agent attach,
  supported activity transitions, command end, and teardown without exposing
  partial state or resurrecting a detached session.
- Hook fixtures prove the exact activity subset claimed for Claude Code and
  Codex. Unsupported or malformed activity reports apply nothing.
- A waiting transition in an unfocused pane raises one alert through the
  existing alert/notification pipeline, and its click focuses the originating
  pane; focused panes and repeated unchanged state do not duplicate it.
- After command-end inside an attached agent session, a recovery checkpoint
  still carries the agent resume hint; after agent detach, it does not.
- Pane inspection returns a typed live semantic snapshot matching reducer
  state, and an `agent attach` reply is followed by an inspection that observes
  the attachment.
- Aggregate semantic-event pressure remains within the existing per-pane
  bounds and recovers to later valid input.

## Non-goals

- Retaining completed commands or answering historical command queries.
- Output spans, output capture, semantic navigation, or search scoped to a
  command.
- Launch correlation, command admission, or launch-and-await. Pane input and
  `--cmd` retain their existing behavior.
- Persisting semantic facets in recovery checkpoints. The live facets are not
  checkpointed, and the two product projections that already are -- the pane's
  last command as restored-command prefill, and the raw agent session as a
  crash-recovery resume hint -- keep their existing capture and restore
  behavior. They are product effects of the stream, not the live model; the
  only change is that the agent hint now clears on agent detach rather than on
  command end, matching the lifetime-end rule above.
- Inferring integration, commands, agents, remote identity, or activity from
  screen contents, diffs, cursor motion, prompt shapes, process inspection, or
  workspace IO.
- Agent integrations beyond the bundled Claude Code and Codex hooks.
- Gating a terminal-engine replacement milestone on this document.

## Rejected ideas

- A stack of live remote frames for the connection facet, popped by
  connection-end. The enclosing host's own wrapper already re-reports its
  identity immediately after a nested connection returns, so a single
  latest-value facet lands on the same answer without durable nested state.

## Follow-up

The deferred journal and agent-command direction is recorded separately in
[Deferred command journal](deferred-command-journal.md). It is not an implementation
dependency of this plan.

## Implementation discretion

- The value representation of each facet and the internal typed event
  vocabulary, provided the invariants and total transitions above hold. One
  exception: the connection facet must make a reported identity on a local
  connection unrepresentable, so a boolean beside an optional does not
  satisfy it even though it can be made to hold the invariant by hand.
- Whether a command completion fact has an immediate first-slice consumer or
  is discarded after returning the live command facet to idle.
- Which existing pane-inspection response carries the live semantic snapshot.
- Slice boundaries among envelope growth, the pure reducer, pane-owner routing,
  and consumers, provided every slice lands green.

## Implementation checklist

- [x] **R1: Author the emitted OSC 133 dialect.** Record the exact marks
  DanTerm's scripts emit for row classification and prompt redraw, checked
  against the existing parser. The live semantic reducer consumes no marks.
  Authored in [OSC 133 dialect](../../docs/research/24-osc-133-dialect/README.md);
  the dialect itself is
  [dialect.md](../../docs/research/24-osc-133-dialect/dialect.md). The zsh, Bash,
  and fish integrations now ship emitters for that dialect.
- [x] **R2: Characterize declared-event forwarding and lifetime-end sources.**
  Capture how the private envelope traverses ssh, mosh, tmux, and nested PTYs,
  including whether the local wrapper's connection-end report survives each;
  audit the exact activity states and end-of-session surfaces the current
  Claude Code and Codex hooks can report. Recorded in
  [Live semantic event forwarding](../../docs/research/34-live-semantic-event-forwarding/README.md).
- [ ] **1: Extend bundled shell reports.** Version the private envelope; emit
  integration-ready; keep complete command text on command-start and add exit
  status on command-end; emit connection-end from each remote wrapper, paired
  with re-reporting the enclosing identity; preserve existing shell hooks;
  update the protocol contract.
- [ ] **2: Add the pure live reducer.** Implement the integration, command,
  connection, and agent facets with the total transition and bounded-degradation
  proofs above.
- [ ] **3: Route one pane-owned stream.** Lower envelope and pane-scoped IPC
  inputs through the serialized pane owner, add the agent detach input for the
  end-of-session surfaces R2 proves, reply to mutating IPC only after the owner
  applies the transition, publish read-only snapshots, and keep high-frequency
  terminal state out of the top-level model.
- [ ] **4: Ship the first live consumers.** Expose typed facet inspection,
  distinguish running from idle in command chrome, and ship needs-attention
  only for activity states proven by the hook audit; update
  `integrations/danterm/SKILL.md` with any CLI surface change.

## Commit progress

- [x] 1. docs: characterize live semantic event forwarding
- [ ] 2. feat(shell): extend bundled semantic reports
- [ ] 3. feat(core): add the live pane semantic reducer
- [ ] 4. feat(app): route pane-owned semantic events
- [ ] 5. feat(app): ship live semantic consumers

## Implementation notes

- R2 found that direct PTYs, nested PTYs, and SSH preserve the private envelope;
  mosh filters far-side OSC, while tmux requires its explicit DCS passthrough
  form and an already-enabled `allow-passthrough` policy. Both bundled agents
  expose `SessionEnd`, so detach does not need a pane-teardown-only fallback.
