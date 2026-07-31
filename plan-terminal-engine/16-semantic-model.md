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
- **connection**: local, or a reported remote identity
- **agent**: none, or an attached agent session with the subset of activity
  states its integration can genuinely report

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
  command; an end while idle is ignored.
- remote events drive the live connection facet independently of command
  state.

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
- command-end while running returns the command facet to idle
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

The first useful consumers are deliberately narrow:

- pane inspection can report whether semantic integration is absent or ready
  and expose the current facets as typed latest-value data
- command chrome can distinguish idle from running without treating
  `lastCommand` as permanent running state
- an attached agent entering a genuinely supported waiting state in an
  unfocused pane fires the existing needs-attention notification whose click
  focuses that pane

CLI surface changes carry the standing `integrations/danterm/SKILL.md`
co-update rule. While both backends exist, these structured facets are a
Swift-engine capability; a Ghostty pane reports the capability absent rather
than emulating it.

## Invariants

- Identical ordered explicit inputs produce identical live facets and ordered
  effects; terminal input chunking does not change the result.
- Every facet derives only from its declared semantic source; rendered cells
  are never an input.
- At most one completely reported command is running. No partial command state
  exists.
- Integration readiness is reported explicitly, never inferred from silence,
  marks, cwd, or command text.
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
- The bundled zsh, Bash, and fish integrations drive complete ready,
  command-start, and command-end transitions with exit status through a real
  Swift pane; ssh, mosh, tmux, and nested-PTY characterization determines and
  pins the supported forwarding behavior.
- Pane-owner ordering fixtures interleave envelope events with agent attach,
  supported activity transitions, command end, and teardown without exposing
  partial state or resurrecting a detached session.
- Hook fixtures prove the exact activity subset claimed for Claude Code and
  Codex. Unsupported or malformed activity reports apply nothing.
- A waiting transition in an unfocused pane produces one needs-attention
  notification, and its existing click behavior focuses the originating pane;
  focused panes and repeated unchanged state do not duplicate it.
- Pane inspection returns a typed live semantic snapshot matching reducer
  state for an integrated Swift pane and reports the capability absent for a
  Ghostty pane rather than emulating it.
- Aggregate semantic-event pressure remains within the existing per-pane
  bounds and recovers to later valid input.

## Non-goals

- Retaining completed commands or answering historical command queries.
- Output spans, output capture, semantic navigation, or search scoped to a
  command.
- Launch correlation, command admission, or launch-and-await. Pane input and
  `--cmd` retain their existing behavior.
- Persisting semantic facets in recovery checkpoints.
- Inferring integration, commands, agents, remote identity, or activity from
  screen contents, diffs, cursor motion, prompt shapes, process inspection, or
  workspace IO.
- Agent integrations beyond the bundled Claude Code and Codex hooks.
- Gating a terminal-engine replacement milestone on this document.

## Follow-up

The deferred journal and agent-command direction is recorded separately in
[Deferred command journal](17-command-journal.md). It is not an implementation
dependency of this plan.

## Implementation discretion

- The value representation of each facet and the internal typed event
  vocabulary, provided the invariants and total transitions above hold.
- Whether a command completion fact has an immediate first-slice consumer or
  is discarded after returning the live command facet to idle.
- Which existing pane-inspection response carries the live semantic snapshot,
  provided Ghostty capability absence remains explicit.
- Slice boundaries among envelope growth, the pure reducer, pane-owner routing,
  and consumers, provided every slice lands green.

## Implementation checklist

- [x] **R1: Author the emitted OSC 133 dialect.** Record the exact marks
  DanTerm's scripts emit for row classification and prompt redraw, checked
  against the existing parser. The live semantic reducer consumes no marks.
  Authored in [OSC 133 dialect](../docs/research/24-osc-133-dialect/README.md);
  the dialect itself is
  [dialect.md](../docs/research/24-osc-133-dialect/dialect.md). The scripts emit
  no marks today, so R1 authors what they will emit; shipping the emitters is a
  separate task recorded in that doc's ledger.
- [ ] **R2: Characterize declared-event forwarding and hooks.** Capture how the
  private envelope traverses ssh, mosh, tmux, and nested PTYs, and audit the
  exact activity states the current Claude Code and Codex hooks can report.
- [ ] **1: Extend bundled shell reports.** Version the private envelope; emit
  integration-ready; keep complete command text on command-start and add exit
  status on command-end; preserve existing shell hooks; update the protocol
  contract.
- [ ] **2: Add the pure live reducer.** Implement the integration, command,
  connection, and agent facets with the total transition and bounded-degradation
  proofs above.
- [ ] **3: Route one pane-owned stream.** Lower envelope and pane-scoped IPC
  inputs through the serialized pane owner, publish read-only snapshots, and
  keep high-frequency terminal state out of the top-level model.
- [ ] **4: Ship the first live consumers.** Expose typed facet inspection,
  distinguish running from idle in command chrome, and ship needs-attention
  only for activity states proven by the hook audit; update
  `integrations/danterm/SKILL.md` with any CLI surface change.
