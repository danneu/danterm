# Semantic Terminal Model

## Problem

Owning the terminal engine means DanTerm can model what happened in a pane,
not only what was drawn. Today the engine already recognizes the needed
signals -- typed DanTermShell command and remote events, OSC 133
prompt/input/output row classification, OSC 7 cwd, alternate-screen
transitions, and the Claude Code / Codex hooks that attach an agent session
to a pane -- but that knowledge collapses on arrival into latest-value model
fields (`lastCommand`, cwd, remote identity, agent session, progress) and
transient engine state. The exit status OSC 133 `D` reports is discarded.
Any consumer that needs history -- an agent debugging a pane, a notification
naming the command that failed, future timeline or command-navigation UI --
would have to scrape scrollback text and guess at structure the engine knew
and threw away. The gap lands hardest on agents: DanTerm already hosts
Claude Code and Codex sessions and lets them drive panes over IPC, yet an
agent that launches work in another pane can only poll scraped text, with no
reliable completion or exit signal.

## Decision

The engine retains pane history as first-class semantic state: model what
happened, not only what was drawn. Three commitments realize that.

### Orthogonal pane facets, one semantic stream

Pane semantic state is a set of small independent facets, not one machine:

- **command**: idle, or running a reported command
- **presentation**: primary or alternate screen
- **connection**: local, or a reported remote identity
- **agent**: none, or an attached agent session (kind and session id)
- **workspace**: none, or the shell-reported repo context -- worktree root,
  branch, and optionally dirty state

Facets transition only on declared semantic inputs -- OSC 133 marks, shell
envelope events, parser state changes, and pane-scoped IPC events such as
the bundled Claude Code and Codex `danterm agent attach` hooks -- and are
never inferred from rendered cells. The workspace facet has prompt-time
freshness: the shell reports it at prompt boundaries, so it is accurate at
each prompt and honestly stale while a command runs -- the same freshness
the prompt itself displays. A remote shell with the integration reports the
remote repo's context, which is the context that matters for that pane. Most facet
data already exists across engine and model; the decision is that every facet
derives from the same ordered semantic stream that feeds the journal below, so
current state and history cannot disagree about what happened. The facet set
may grow (progress and title remain latest-value model fields until a
demonstrated need moves them). Degradation is honest and tiered: a pane with
DanTerm's integration gets full records; a pane whose shell emits only
foreign OSC 133 marks gets anonymous but accurate records -- lifecycle,
spans, and exit status without command text; a pane with neither stays idle
with an empty journal. Nothing is guessed at any tier.

### The command journal

Each pane retains a bounded, ordered journal of command records, owned by the
terminal core as deterministic state alongside selection and search. Sources
have fixed roles:

- OSC 133 marks are the primary lifecycle source: they drive the command
  facet's transitions and supply a record's skeleton -- prompt, input, and
  output boundaries plus the exit status reported at `D`. DanTerm's bundled
  shell integrations emit these marks themselves, extending the integration
  contract in
  [Protocols and shell integration](10-protocols-shell-integration.md), and
  any foreign integration that emits them drives the same machine.
- DanTermShell envelope events decorate the skeleton with the identity the
  marks cannot carry: the reported command text, remote identity, and
  workspace context reported at prompt boundaries. When both sources
  describe one command, marks are authoritative for boundaries and exit
  status.
- Parser facts supply presentation transitions during the command.

One executed command yields one record no matter which sources report it,
how their events interleave, or how often marks repeat.

Pane-scoped IPC events join the same ordered stream as explicit inputs
through the pane owner: an attached agent session becomes part of records
opened while it is active, and a command launched through the `danterm` CLI
records the requesting context as launch provenance.

A record carries the reported command text, stream order, injected wall-clock
timestamps (stamped at the owner boundary under the existing
save/send/assert injection rule), the cwd, connection, and workspace facets
at start, exit status when reported, source provenance, and an output span.

Workspace reporting must not tax the prompt: worktree root and branch are
cheap to compute; the dirty flag is not, so it ships opt-in or deferred, and
the integration may reuse what the user's prompt framework already computes
rather than double-computing. Git is the only VCS modeled in the first
release, as typed fields; the versioned envelope leaves room to grow.

A record stores no output text. Its output span is a reflow-attached logical
range into primary history under the same anchor contract selection and
search already prove: reflow preserves it, scrollback eviction clamps it, and
reads materialize text on demand through the one logical-text projection. A
record whose output has been evicted survives in the journal and reports its
span truncated.

The journal has explicit count and byte bounds inside the per-pane resource
policy -- provisionally on the order of 1,000 records and 1 MiB per pane,
pinned when the slice lands -- and the oldest records evict first. Journal
and scrollback evict independently, on the axes their value decays along:
scrollback by bytes, the journal by records. Eviction never crosses the
boundary in either direction; the only thing that crosses is span fidelity,
retained to truncated. A command whose output saturates the scrollback
budget therefore truncates older spans without erasing the history around
it -- flooding output degrades span fidelity, never the record of what
happened. All three sources remain untrusted terminal output -- bounded,
pane-scoped, granted no authority -- with provenance recorded so consumers
can distinguish shell-integration intent from generic marks any program may
emit.

### Provisional shape (illustrative)

Names, nesting, and storage here are implementation discretion; the
contract is the invariants below, not this sketch. It exists so readers
share one concrete picture of the facets and a record:

```swift
/// Facets snapshot for one pane. Every field derives from declared
/// sources; rendered cells are never an input.
struct PaneSemanticState {
    var command: CommandFacet            // .idle | .running(CommandRecordId)
    var presentation: PresentationFacet  // .primary | .alternate
    var connection: ConnectionFacet      // .local | .remote(user:host:)
    var agent: AgentFacet                // .none | .attached(kind:sessionId:)
    var workspace: WorkspaceContext?     // nil until the shell reports one
}

/// Shell-reported repo context with prompt-time freshness.
struct WorkspaceContext {
    var root: String       // worktree root
    var branch: String?    // nil when detached
    var dirty: Bool?       // nil when not reported (opt-in)
}

/// One executed command in the bounded per-pane journal. Never stores
/// output text; `output` resolves through the logical projection.
struct CommandRecord {
    let id: CommandRecordId
    var text: String?                 // envelope-reported; nil for marks-only
    var exitStatus: Int32?            // OSC 133 `D`
    var provenance: RecordProvenance  // which source supplied text and exit
    var startedAt: Date               // injected at the owner boundary
    var endedAt: Date?
    var cwd: String?                  // at start
    var connection: ConnectionFacet   // at start
    var workspace: WorkspaceContext?  // at start
    var agent: AgentProvenance?       // attached session and/or launch requester
    var output: OutputSpan            // reflow-attached; clamps under eviction
}
```

### One structured surface for every consumer

Renderer chrome, sidebar, notifications, IPC, and agents read the same
semantic state; there is no privileged side channel. The `danterm` surface
gains structured queries over the journal -- list a pane's records as typed
data; read one command's output through its span -- layered like existing
IPC: query semantics in the core, envelope in `DanTermProtocol`, transport in
support/app. An agent asked to debug a pane reads the journal first and
fetches only the spans it needs, instead of a whole-screen text dump.

First-class agent commands and introspection are an objective of the first
release, scoped to the agents DanTerm already integrates: Claude Code and
Codex. Introspection is the journal queries above. Commands means an agent
can launch work in another pane and deterministically await its record --
completion, exit status, output span -- replacing today's
launch-then-poll-and-scrape pattern. Both ride the surface every consumer
uses; agent priority sets delivery order, not a privileged channel.

CLI surface changes carry the standing `integrations/danterm/SKILL.md`
co-update rule. While both backends exist, journal queries are a
Swift-engine capability; a Ghostty pane reports the capability absent rather
than emulating it.

### Worked example: an agent session

Every signal in this walkthrough exists today; what changes is that they
become durable records instead of transient field updates.

A user runs `claude` in a pane at `~/Code/danterm`:

1. The shell integration emits the OSC 133 marks that open the command's
   regions and reports the command text through the envelope. The command
   facet becomes running, and the journal opens a record with the pane's
   cwd, workspace (worktree root and branch), connection facet, and an
   injected start timestamp.
2. Claude Code's session-start hook runs
   `danterm agent attach --kind claude --id <session-id>` (the bundled
   integration, same for Codex). The agent facet attaches, and the open
   record gains the agent session.
3. The agent splits a pane and runs `just test` there. The sibling pane's
   journal opens its own record -- carrying the requesting agent session as
   launch provenance -- and closes it with exit status 1 and an output span.
4. The Claude Code TUI redraws continuously. Nothing enters any journal:
   drawing is not an event, and the presentation facet changes only if the
   application actually switches screens.
5. The user quits. OSC 133 `D` and the envelope command-end close the record
   with exit status and end timestamp, and the agent facet detaches (today's
   command-end behavior, unchanged).

Later, any consumer -- the user, or a fresh agent asked to "debug what
happened in pane 32" -- queries structure first. Illustrative shapes only;
the grammar is implementation discretion:

```sh
danterm pane commands --pane 32 --last 3
# -> typed records: command text, exit status, timestamps, workspace,
#    agent and launch provenance, span state (retained or truncated)

danterm pane read --pane 32 --command c41
# -> only that command's output, materialized through its span
```

The journal answers "what happened"; spans answer "what it printed"; the
agent facet answers "who asked"; the workspace facet answers "where". A
debugging agent reads three records instead of two thousand scraped lines,
then fetches output only for the one command that failed.

### Downstream consumers

The journal is justified by consumers, not by retention for its own sake.
Beyond the first-release agent objective, these are candidates, not
commitments -- the checklist's first-consumer slice chooses among them. Each
near-composition item is one existing, proven mechanism plus one journal
fact:

- Synthesized command-completion notifications ("`cargo test` failed, exit
  101, 2m14s") for any command without program cooperation, gated by
  duration and focus, composing with the existing
  notification-click-focuses-pane behavior.
- Sidebar and tab chrome showing per-pane running, idle, or failed command
  state and live agent sessions; today `lastCommand` never clears, so chrome
  cannot even distinguish running from finished.
- Semantic navigation and selection: scrollbar marks at command boundaries,
  jump to previous command, select one command's output, search scoped to a
  span -- bounded reuses of the proven viewport, selection, and search
  contracts.
- Clearing stale progress state at command end when a progress-reporting
  command dies without resetting it.
- Workspace-aware chrome and targeting: branch and worktree shown per pane,
  panes grouped or queried by worktree, and agent launches aimed at a
  workspace instead of a remembered pane id -- the natural fit for the
  worktree-per-agent arrangement the plan README already documents.

Later design candidates, each needing its own decision round: trimming the
recovery projection at record boundaries so restored text never starts
mid-output; treating command end as a checkpoint flush point; and the
journal-in-recovery question already recorded in
[Open questions](15-open-questions.md), which would let a restored pane
brief a resumed agent session on what it was running and how it ended.

None of these touch the byte-feed hot path: the journal mutates per command,
not per byte, so this direction does not trade against the indexed
feed-throughput work.

### Roadmap position

This direction gates nothing in Milestones 8-10 and adds no replacement proof
obligation. Its early protocol needs are compatible by design: the bundled
shell integrations start emitting the OSC 133 marks the engine already
parses -- which independently activates the existing prompt-redraw-on-resize
behavior for every DanTerm user -- and the engine starts retaining the exit
status `D` already delivers. The envelope does not need to grow.
Everything else composes machinery with existing proof -- row
semantic classification, reflow-attached anchors, the logical projection,
bounded semantic-event delivery, versioned shell integrations -- rather than
introducing a new subsystem.

## Invariants

- Identical bytes and explicit inputs produce identical facets, journal, and
  spans; input chunking does not change them. Timestamps are explicit inputs.
- Facet, journal, and span state stay bounded under adversarial output within
  the per-pane resource policy, and reaching a bound never prevents later
  valid commands from recording.
- A span never begins or ends inside a grapheme cluster or wide cell, and a
  span read equals the logical projection of the same range; reflow changes
  visual rows without changing a retained span's text.
- Eviction of rows or records never leaves a dangling span; truncation is
  observable, not silent.
- Eviction never crosses the journal/scrollback boundary in either
  direction: a span never delays or prevents scrollback eviction, and
  scrollback eviction never removes a record; only span fidelity crosses,
  retained to truncated.
- Records retain no output text; scrollback remains the only text authority.
- Facets and records derive only from declared sources; rendered cells are
  never an input.
- Workspace state is only what the shell most recently reported; DanTerm
  performs no filesystem inspection to derive or refresh it, and staleness
  during a running command is defined behavior, not a defect.
- One executed command produces exactly one record regardless of which
  sources report it, how their events interleave, or how often marks repeat.
- A consumer can always tell which source supplied a record's command text
  and exit status.
- The journal lives with the pane owner; the top-level model continues to
  receive only product-level latest values.

## Proof obligations

- Neutral replay fixtures produce identical journals and facets under
  authored, bytewise, and split replay.
- Width and height walks preserve span reads for retained content; eviction
  fixtures clamp spans and surface truncation without invalidating records.
- A single command whose output saturates the scrollback budget leaves every
  prior record intact with truncated spans; flooding the journal with fake
  marks evicts oldest records without touching scrollback.
- Disagreement and duplication traces have pinned outcomes: `D` with no
  matching envelope command-end, envelope command-start with no marks,
  repeated or out-of-order marks, a foreign integration emitting alongside
  DanTerm's, pane teardown mid-command, nested remote sessions,
  alternate-screen entry mid-command, and agent attach with no running
  command -- each yielding at most one record per executed command.
- The bundled zsh, Bash, and fish integrations drive full-fidelity records
  through a real pane; a marks-only replay produces anonymous records with
  spans and exit status.
- Workspace traces pin prompt-time freshness: a branch switch mid-command
  does not change the running record's stamped workspace, and the next
  prompt's report updates the facet; a pane that leaves the repo clears it.
- Adversarial streams of command marks and envelope events stay within
  journal bounds and recover to later valid input.
- Journal queries return identical structured results before and after resize
  for retained content, and a command's span read equals the text a user
  would select over the same output region.
- An agent launch-and-await resolves with the awaited record's completion
  facts -- exit status and span state -- exactly once, including when pane
  teardown or span eviction intervenes.
- A live shell running a full-screen application inside one command (enter
  and exit alternate screen) produces the same facet transitions in headless
  replay and at the product boundary.

## Non-goals

- Persisting journals in recovery checkpoints; recovery remains the existing
  plain-text contract.
- Parsing command text into argv or classifying applications; the record
  stores the reported command line only.
- Heuristic inference of state from screen contents, diffs, cursor motion, or
  prompt shapes -- including as a fallback.
- A cross-pane global timeline, analytics, or usage store.
- Agent integrations beyond the bundled Claude Code and Codex hooks in the
  first release.
- VCS awareness beyond git in the first release; no generic VCS abstraction
  or open-ended context bag.
- Styled or annotated output capture.
- Gating any replacement milestone on this document.

## Rejected ideas

- Storing output text inside events or records: it duplicates scrollback,
  breaks the fixed per-pane budget, and creates a second text authority that
  can disagree with the projection.
- Screen-scraping application detection: it works until it silently
  misclassifies; DanTerm already rejected one covert channel (private
  directives as titles) and prefers declared events or honest absence.
- A dedicated AI endpoint separate from IPC: two surfaces drift; agents are
  ordinary IPC consumers under the same bounds.
- One monolithic pane state machine: independent facets keep each transition
  table small and testable, and let one facet be absent or wrong without
  corrupting the others.
- Keeping the journal in the top-level Elm model: journal mutation frequency
  tracks terminal output, not user actions; it stays pane-owned like grid,
  damage, and scrollback.
- App-side filesystem watching for git state: it breaks for remote panes,
  races cwd changes, and reintroduces the ambient-IO enrichment the
  declared-sources rule forbids; the shell reports its own environment
  instead, the same pattern OSC 7 cwd already uses.

## Implementation discretion

- Journal and span representation, exact count and byte bounds, and eviction
  batching, provided the bounds are explicit and tested.
- Retaining less of a command's text in the journal than the 64 KiB event
  limit, provided truncation is flagged.
- Arbitration mechanics, and how the bundled integrations coexist with a
  foreign 133 emitter, provided one command yields one record and provenance
  stays observable.
- Query grammar and JSON shape of the CLI/IPC surface.
- Slicing: exit-status capture, facets, journal, and query surface may land
  as independent green slices in any order.

## Implementation checklist

Ordered so every step lands green and independently valuable; research
precedes the contracts it informs. Reordering is implementation discretion.
None of this gates Milestones 8-10.

- [ ] **R1: Pin the OSC 133 dialect.** Survey the mark grammars emitted by
  the integrations users actually run (iTerm2, VS Code, WezTerm, Kitty,
  starship) and record, as a research note, the exact marks DanTerm's
  scripts will emit and the foreign variants arbitration must tolerate --
  including the double-emission and out-of-order cases observed in practice.
- [ ] **R2: Characterize pass-through.** Verify how OSC 133 and the
  DanTermShell envelope traverse ssh, tmux, and nested PTYs so the tiered
  degradation story matches reality; capture the traces as replay fixtures
  for later slices.
- [ ] **R3: Audit reusable engine state.** Map today's row classification,
  semantic-content tracking, and reflow-attached anchor machinery against
  the journal's needs; decide where journal state sits beside selection and
  search and what the record's span representation reuses.
- [ ] **R4: Workspace reporting cost.** Measure prompt-time cost of
  worktree-root, branch, and dirty computation across representative repos;
  survey what prompt frameworks (starship, powerlevel10k) already compute so
  the integration piggybacks rather than double-computing; pin what v1
  reports and what stays opt-in.
- [ ] **1: Bundled integrations emit marks and workspace.** zsh, Bash, and
  fish scripts emit the pinned marks alongside the existing envelope and
  report workspace context at prompt boundaries (root and branch; dirty per
  R4); prompt redraw on primary-screen resize activates with only DanTerm's
  integration installed; existing prompt hooks and ssh/mosh forwarding keep
  working; coexistence with a foreign emitter produces no visible
  misbehavior; the integration contract in
  [Protocols and shell integration](10-protocols-shell-integration.md)
  records the emission.
- [ ] **2: Exit status retention.** The engine retains the status `D`
  delivers instead of discarding it, exposed through pane-scoped semantics
  under the existing bounds.
- [ ] **3: Command facet and record skeleton.** Marks alone drive
  idle/running transitions and open/close bounded journal records with
  region boundaries and exit status; behavior is chunk-invariant and proven
  by neutral replay, including the repeated and out-of-order mark traces
  from R1.
- [ ] **4: Envelope decoration and one-record arbitration.** Envelope events
  attach command text, remote identity, and workspace context to mark-opened
  records; the disagreement and duplication traces pin at-most-one-record
  outcomes, including the workspace freshness traces; provenance stays
  observable; injected timestamps stamp records at the owner boundary.
- [ ] **5: Output spans.** Records carry reflow-attached spans into primary
  history; span reads equal the logical projection; eviction clamps and
  surfaces truncation without invalidating records.
- [ ] **6: Agent and launch provenance.** `danterm agent attach` sessions
  join the stream through the pane owner and appear on records opened while
  attached; commands launched through the `danterm` CLI record the
  requesting context.
- [ ] **7: Query and await surface.** `danterm pane commands` and
  `danterm pane read --command` return typed results with the existing IPC
  layering, and an agent can launch a command in another pane and await its
  record's completion facts; results are stable across resize for retained
  content; teardown and eviction resolve an await rather than hanging it; a
  Ghostty pane reports the capability absent; `integrations/danterm/SKILL.md`
  updates in the same change.
- [ ] **8: First-release agent consumers.** The Claude Code and Codex
  recipes ship in the danterm skill: debugging (journal first, spans second)
  and launch-and-await replacing the poll-and-scrape pattern; then evaluate
  which product consumer from the downstream list follows
  (completion notifications, sidebar command chrome) and record the
  decision.
