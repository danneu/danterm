# Semantic Terminal Model

## Problem

Owning the terminal engine means DanTerm can model what happened in a pane,
not only what was drawn. Today the engine already recognizes the needed
signals -- typed DanTermShell command and remote events, OSC 133
prompt/input/output row classification, OSC 7 cwd, alternate-screen
transitions, and the Claude Code / Codex hooks that attach an agent session
to a pane -- but that knowledge collapses on arrival into latest-value model
fields (`lastCommand`, cwd, remote identity, agent session, progress) and
transient engine state. No exit status survives at all: the envelope does
not carry one, and the status OSC 133 `D` reports is discarded on arrival.
Any consumer that needs history -- an agent debugging a pane, a notification
naming the command that failed, future timeline or command-navigation UI --
would have to scrape scrollback text and guess at structure the engine knew
and threw away. The gap lands hardest on agents: DanTerm already hosts
Claude Code and Codex sessions and lets them drive panes over IPC, yet an
agent that launches work in another pane can only poll scraped text, with no
reliable completion or exit signal.

## Decision

The engine retains pane history as first-class semantic state: model what
happened, not only what was drawn. Three commitments realize that, under one
governing principle: strictness. The model records only what an integration
explicitly and completely reported -- a record is complete or absent, with
no partial tiers, no inference, and no tolerance parsing of foreign
dialects. Strictness is the simplification lever that keeps every transition
table and assumption in this document small.

Strictness has a structural twin, inherited from the engine redesign's core
goals: impossible states are unrepresentable. Strictness governs what enters
the model; the types govern what the model can hold. Every invariant a type
can carry moves out of runtime checks and into structure: at most one open
record, always the newest; an outcome that is closed-with-status or
sealed-at-a-time, never a hybrid; honest emptiness as a distinct journal
state rather than a flag beside an empty list; the command facet as a
projection of the journal, so current state and history cannot disagree by
construction.

### Orthogonal pane facets, one semantic stream

Pane semantic state is a set of small independent facets, not one machine:

- **command**: idle, or running a reported command
- **connection**: local, or a reported remote identity
- **agent**: none, or an attached agent session (kind, session id, and its
  reported activity: working, waiting on the user, or idle)

Facets transition only on declared semantic inputs -- DanTermShell envelope
events and pane-scoped IPC events such as the bundled
Claude Code and Codex `danterm agent attach` and activity hooks -- and are
never inferred from rendered cells. Most facet
data already exists across engine and model; the decision is that every facet
derives from the same ordered semantic stream that feeds the journal below, so
current state and history cannot disagree about what happened. The facet set
may grow (progress and title remain latest-value model fields until a
demonstrated need moves them). Degradation is strict, not tiered: a pane
with DanTerm's integration gets complete records; any other pane stays idle
with an empty journal, and a consumer can tell that emptiness apart from an
integrated pane where no commands ran. Nothing is guessed in either state.
The same rule scopes agent activity: each integration reports only the
states its hooks genuinely distinguish, so a coarser hook surface yields
fewer states, never guessed ones.

### The command journal

Each pane retains a bounded, ordered journal of command records, owned by the
terminal core as deterministic state alongside selection and search. The
envelope is the journal's only source; everything lowers into one stream:

- DanTermShell envelope events are the sole record authority: command-start
  carries the required command text, cwd, and reporting identity (user and
  host) and is the only record opener; command-end carries the required exit
  status and closes the record. DanTerm owns both ends of the envelope, so
  the journal parses no foreign dialect.
- OSC 133 marks stay emitted by the bundled integrations -- extending the
  integration contract in
  [Protocols and shell integration](10-protocols-shell-integration.md) --
  and stay parsed by the engine, where they drive prompt/input/output row
  classification, navigation, and prompt redraw for DanTerm's scripts and
  foreign integrations alike. The journal never listens to them.
- OSC 7 likewise stays parsed for pane chrome (new splits inherit cwd), but
  the journal never listens to it either: a record's cwd arrives on
  command-start, from the same reporter, on the same host, in the same verb
  as its text -- never snapshotted from pane state that may be stale or
  belong to a different host.
- The envelope's remote events keep driving the live connection facet
  (chrome can show user@host even at an idle prompt), but the journal never
  listens to them either: a record's identity arrives on its own
  command-start, self-reported by whichever shell ran the command.

Envelope and IPC inputs lower into a single ordered stream that the
journal and facets consume, and the reducer over that stream is small and
total: command-start opens a record, sealing any dangling predecessor;
command-end closes it; pane teardown seals; agent attach decorates the
open record and is otherwise dropped. Each reported command yields exactly
one record.

Pane-scoped IPC events join the same ordered stream as explicit inputs
through the pane owner: an attached agent session becomes part of records
opened while it is active, and a command launched through the `danterm` CLI
records the requesting context as launch provenance. Agent activity reports
move the facet only; the journal ignores them -- what an agent was doing
moment to moment is live state, not history.

A record carries the reported command text, cwd, and identity (user and
host) -- all required, all carried on command-start; a record missing any
of them cannot exist -- plus stream order, injected wall-clock timestamps
(stamped at the owner boundary under the existing save/send/assert
injection rule), an outcome -- closed with the reported exit status and end
time, or sealed when the pane tore down or a new command-start arrived
first -- and an output span.

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
happened. Envelope events remain untrusted terminal output -- structurally validated,
bounded, pane-scoped, granted no authority -- and strictness narrows what a
forged sequence can do to inserting one bounded fake record, never
corrupting a neighboring one.

### Provisional shape (illustrative)

Names, nesting, and storage here are implementation discretion; the
contract is the invariants below, not this sketch. It exists so readers
share one concrete picture of the stream, the facets, the journal, and a
record -- and of the types carrying the invariants instead of runtime
checks:

```swift
/// The single vocabulary the journal consumes. Envelope and pane-scoped
/// IPC inputs lower into one ordered stream; the journal reducer never
/// sees an OSC.
enum CommandJournalEvent {
    case commandStarted(text: String, cwd: String, user: String, host: String)  // the only opener
    case commandEnded(exitStatus: Int32)                 // envelope command-end; $? required
    case agentAttached(kind: String, sessionId: String)  // IPC, via the pane owner
    case agentActivity(AgentActivity)                    // IPC; moves the facet, never a record
}

/// Facets snapshot for one pane. Every field derives from declared
/// sources; rendered cells are never an input. `command` is not stored
/// state: it projects the journal (running iff an open record exists),
/// so facet and history cannot disagree.
struct PaneSemanticState {
    var command: CommandFacet        // derived: .running(open.id) | .idle
    var connection: ConnectionFacet  // .local | .remote(user:host:)
    var agent: AgentFacet            // .none | .attached(kind:sessionId:activity:)
}

/// Reported by the bundled hooks; activity cannot exist without an
/// attached session. `waiting` is the needs-attention state: blocked on
/// a human (permission prompt, question).
enum AgentActivity { case working, waiting, idle }

/// The bounded per-pane journal. The case split carries the invariants:
/// records cannot exist under .neverReported, at most one record is
/// open, and the open record is always the newest.
enum CommandJournal {
    case neverReported  // honest emptiness: the integration has never spoken here
    case reporting(completed: [CompletedRecord], open: OpenRecord?)
}

/// The facts every record is born with -- all required, all carried on
/// command-start. No partial records exist.
struct CommandIdentity {
    let id: CommandRecordId
    let text: String
    let cwd: String
    let user: String
    let host: String
    let startedAt: Date               // injected at the owner boundary
    let agent: AgentProvenance?       // attached session and/or launch requester
}

/// The at-most-one running command. No outcome fields exist to be wrong;
/// its output is start-anchored and still growing.
struct OpenRecord {
    let identity: CommandIdentity
    var outputStart: SpanAnchor
}

/// A finished command. Never stores output text; `output` resolves
/// through the logical projection.
struct CompletedRecord {
    let identity: CommandIdentity
    let outcome: Outcome
    var output: OutputSpan            // reflow-attached; clamps under eviction
}

/// Closed or sealed -- an exit status without an end time, or the
/// reverse, cannot be represented.
enum Outcome {
    case closed(exitStatus: Int32, endedAt: Date)  // envelope command-end
    case sealed(at: Date)                          // teardown, or a new start arrived first
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

The activity facet adds a third first-release consumer: an attached agent
entering waiting in an unfocused pane fires a needs-attention notification
whose click focuses the pane -- composing one facet fact with the existing
notification-click-focuses-pane behavior.

CLI surface changes carry the standing `integrations/danterm/SKILL.md`
co-update rule. While both backends exist, journal queries are a
Swift-engine capability; a Ghostty pane reports the capability absent rather
than emulating it.

### Worked example: an agent session

Every signal in this walkthrough exists today; what changes is that they
become durable records instead of transient field updates.

A user runs `claude` in a pane at `~/Code/danterm`:

1. The shell integration reports the command through the envelope's
   command-start. The command facet becomes running, and the journal opens a
   record with the required command text, cwd, and identity (all carried on
   command-start) and an injected start timestamp. The integration's OSC 133 marks classify
   the prompt and output rows for navigation; the journal takes nothing from
   them.
2. Claude Code's session-start hook runs
   `danterm agent attach --kind claude --id <session-id>` (the bundled
   integration, same for Codex). The agent facet attaches, and the open
   record gains the agent session.
3. The agent splits a pane and runs `just test` there. The sibling pane's
   journal opens its own record -- carrying the requesting agent session as
   launch provenance -- and closes it with exit status 1 and an output span.
4. The Claude Code TUI redraws continuously. Nothing enters any journal:
   drawing is not an event.
5. Claude Code pauses on a permission prompt; its notification hook reports
   waiting. The pane is unfocused, so DanTerm fires a needs-attention
   notification; clicking it focuses the pane, and the user's next prompt
   returns the facet to working. Nothing enters the journal: activity is
   facet-only.
6. The user quits. The envelope command-end closes the record with exit
   status and end timestamp, and the agent facet detaches (today's
   command-end behavior, unchanged).

Later, any consumer -- the user, or a fresh agent asked to "debug what
happened in pane 32" -- queries structure first. Illustrative shapes only;
the grammar is implementation discretion:

```sh
danterm pane commands --pane 32 --last 3
# -> typed records: command text, exit status, timestamps, cwd,
#    agent and launch provenance, span state (retained or truncated)

danterm pane read --pane 32 --command c41
# -> only that command's output, materialized through its span
```

The journal answers "what happened"; spans answer "what it printed"; the
agent facet answers "who asked"; the record's cwd and host answer "where". A
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
  state and live agent sessions with their activity; today `lastCommand`
  never clears, so chrome cannot even distinguish running from finished.
- Semantic navigation and selection: scrollbar marks at command boundaries,
  jump to previous command, select one command's output, search scoped to a
  span -- bounded reuses of the proven viewport, selection, and search
  contracts.
- Clearing stale progress state at command end when a progress-reporting
  command dies without resetting it.

Later design candidates, each needing its own decision round: trimming the
recovery projection at record boundaries so restored text never starts
mid-output; treating command end as a checkpoint flush point; and whether
journals ever join enriched recovery checkpoints, and under what bounds --
which would let a restored pane brief a resumed agent session on what it
was running and how it ended.

None of these touch the byte-feed hot path: the journal mutates per command,
not per byte, so this direction does not trade against the indexed
feed-throughput work.

### Roadmap position

This direction gates nothing in Milestones 8-10 and adds no replacement proof
obligation. Its early protocol needs are small and DanTerm-owned: the
versioned envelope grows user, host, and cwd on command-start and a
required exit status on command-end, and the bundled shell integrations
start emitting the
OSC 133 marks the engine already parses -- which independently activates the
existing prompt-redraw-on-resize behavior for every DanTerm user, and which
serves navigation, never the journal.
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
- Each envelope-reported command produces exactly one record; unmatched or
  re-entrant envelope events (an end while idle, a start while running) have
  pinned outcomes, never a partial or duplicate record. Marks alone never
  produce a record.
- Every record carries its command text, cwd, and reporting identity; the
  journal admits no partial records. An empty journal is honest: a consumer can distinguish a
  pane whose integration has never reported from an integrated pane where no
  commands ran.
- The journal lives with the pane owner; the top-level model continues to
  receive only product-level latest values.

## Proof obligations

- Neutral replay fixtures produce identical journals and facets under
  authored, bytewise, and split replay.
- Width and height walks preserve span reads for retained content; eviction
  fixtures clamp spans and surface truncation without invalidating records.
- A single command whose output saturates the scrollback budget leaves every
  prior record intact with truncated spans; flooding the journal with forged
  envelope events evicts oldest records without touching scrollback.
- Unmatched and re-entrant traces have pinned outcomes: command-start while
  a record is open (the predecessor seals), command-end while idle, pane
  teardown mid-command, nested remote sessions,
  foreign OSC 133 marks arriving with and without the envelope,
  and agent attach with no running command -- each yielding at most one
  record per reported command and no record from marks alone.
- The bundled zsh, Bash, and fish integrations drive complete records
  through a real pane; a marks-only replay (a foreign integration) leaves
  the journal empty while row classification and prompt navigation still
  work, and a consumer can tell that pane's integration has never reported.
- Adversarial streams of envelope events stay within journal bounds and
  recover to later valid input.
- Journal queries return identical structured results before and after resize
  for retained content, and a command's span read equals the text a user
  would select over the same output region.
- An agent launch-and-await resolves with the awaited record's completion
  facts -- exit status and span state -- exactly once, including when pane
  teardown or span eviction intervenes.

## Non-goals

- Persisting journals in recovery checkpoints; recovery remains the existing
  plain-text contract.
- Parsing command text into argv or classifying applications; the record
  stores the reported command line only.
- Heuristic inference of state from screen contents, diffs, cursor motion, or
  prompt shapes -- including as a fallback.
- Journal records for panes without DanTerm's integration: foreign OSC 133
  marks earn row classification and navigation, never records.
- A cross-pane global timeline, analytics, or usage store.
- Agent integrations beyond the bundled Claude Code and Codex hooks in the
  first release.
- Workspace or VCS awareness: no repo context (worktree root, branch, dirty
  state) is modeled; the record's cwd is the only location fact.
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
- A workspace/git facet (worktree root, branch, dirty state): cut for
  lacking a first-release consumer after carrying a research item, an
  envelope verb, and freshness semantics. Two points are settled if a
  consumer ever revives it: the shell reports its own repo context at
  prompt boundaries over the versioned envelope (the same
  shell-reports-its-own-state pattern as the record's cwd, with honest
  report-time staleness), and app-side filesystem watching
  stays rejected -- it breaks remote panes, races cwd changes, and
  reintroduces the ambient-IO enrichment the declared-sources rule forbids.
- A presentation facet (primary vs alternate screen): cut for lacking a
  named consumer. Alternate-screen state remains engine and render state
  either way; re-projecting it as a facet is purely additive if an
  introspection consumer ("is a TUI active in this pane") ever earns it.
- Stamping records from facet snapshots and decoration events (connection
  at start, remote identity decorating the open record): replaced by
  self-reported identity on command-start, so every record fact shares one
  reporter, one host, and one verb; the live connection facet keeps
  consuming the envelope's remote events for chrome.
- Driving the journal from OSC 133 marks (dual-source records with an
  anonymous marks-only tier): cross-source arbitration, per-record
  provenance, and a foreign-dialect survey bought journal coverage only on
  machines the user never set up. Strictness deletes the tiers, the
  arbitration table, and the dialect tolerance; the lowering seam (one
  internal stream the journal consumes) keeps the door cheap to reopen if
  un-integrated coverage ever earns its cost.

## Implementation discretion

- Journal and span representation, exact count and byte bounds, and eviction
  batching, provided the bounds are explicit and tested and the chosen types
  keep the pinned impossible states unrepresentable (one open record,
  complete outcomes, honest emptiness) rather than runtime-checked.
- Retaining less of a command's text in the journal than the 64 KiB event
  limit, provided truncation is flagged.
- The internal stream representation that lowers envelope and IPC inputs
  into the events the journal consumes.
- Query grammar and JSON shape of the CLI/IPC surface.
- Slicing: exit-status capture, facets, journal, and query surface may land
  as independent green slices in any order.

## Implementation checklist

Ordered so every step lands green and independently valuable; research
precedes the contracts it informs. Reordering is implementation discretion.
None of this gates Milestones 8-10.

- [ ] **R1: Author the emitted OSC 133 dialect.** Record, as a research
  note, the exact marks DanTerm's scripts will emit for row classification
  and prompt redraw, checked against the engine's existing parser. No
  foreign survey: the journal parses no marks.
- [ ] **R2: Characterize pass-through.** Verify how the DanTermShell
  envelope (and secondarily the marks) traverses ssh, tmux, and nested PTYs
  so the remote-integration story matches reality; capture the traces as
  replay fixtures for later slices.
- [ ] **R3: Audit reusable engine state.** Map today's row classification,
  semantic-content tracking, and reflow-attached anchor machinery against
  the journal's needs; decide where journal state sits beside selection and
  search and what the record's span representation reuses -- including what
  span-anchor maintenance costs under resize at journal scale (thousands of
  endpoints per pane, not selection's handful).
- [ ] **1: Bundled integrations emit marks.** zsh, Bash, and fish scripts
  emit the authored marks alongside the existing envelope; prompt redraw on
  primary-screen resize activates with only DanTerm's integration installed;
  existing prompt hooks and ssh/mosh forwarding keep working; coexistence
  with a foreign emitter produces no visible misbehavior; the integration
  contract in
  [Protocols and shell integration](10-protocols-shell-integration.md)
  records the emission.
- [ ] **2: Record facts over the envelope.** The bundled scripts report
  user, host, and cwd on command-start and `$?` on command-end through the
  versioned envelope, and the engine retains them through pane-scoped
  semantics under the existing bounds.
- [ ] **3: Command facet and record lifecycle.** Envelope events alone drive
  idle/running transitions and open/close bounded journal records --
  command-start opens with required text, cwd, and identity, sealing any
  dangling predecessor;
  command-end closes with exit status; teardown seals; behavior is
  chunk-invariant and proven by neutral replay, including the unmatched and
  re-entrant traces.
- [ ] **4: Timestamps and honest emptiness.** Injected timestamps stamp
  records at the owner boundary; marks-only replays leave the journal empty
  while row classification still works.
- [ ] **5: Output spans.** Records carry reflow-attached spans into primary
  history; span reads equal the logical projection; eviction clamps and
  surfaces truncation without invalidating records.
- [ ] **6: Agent provenance and activity.** `danterm agent attach` sessions
  join the stream through the pane owner and appear on records opened while
  attached; the bundled hooks report activity transitions (working, waiting,
  idle) that move the facet only, each integration reporting the strict
  subset its hooks genuinely distinguish -- verified against each agent's
  real hook surface, not assumed; commands launched through the `danterm`
  CLI record the requesting context.
- [ ] **7: Query and await surface.** `danterm pane commands` and
  `danterm pane read --command` return typed results with the existing IPC
  layering, and an agent can launch a command in another pane and await its
  record's completion facts; results are stable across resize for retained
  content; teardown and eviction resolve an await rather than hanging it; a
  Ghostty pane reports the capability absent; `integrations/danterm/SKILL.md`
  updates in the same change.
- [ ] **8: First-release agent consumers.** The Claude Code and Codex
  recipes ship in the danterm skill: debugging (journal first, spans second)
  and launch-and-await replacing the poll-and-scrape pattern; the
  needs-attention notification ships (an attached agent entering waiting in
  an unfocused pane, click focuses the pane); then evaluate
  which product consumer from the downstream list follows
  (completion notifications, sidebar command chrome) and record the
  decision.
