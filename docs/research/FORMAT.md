# Research doc format

The contract for a research doc: how one is stored, what shape it takes, and how
it is run. This file is the portable half of `docs/research/` -- it is generic
research prose meant to survive extraction as a portable skill, so no link in it
may resolve outside `docs/research/`. Project-local pointers live in
[README.md](README.md), which is also the index of this project's docs.

Why the contract says what it says, and which of its rules are still supported
by one research domain only, is in [FORMAT-NOTES.md](FORMAT-NOTES.md).

## Contract

- **A doc is a folder.** A new doc is created as `N-topic/` holding
  `README.md`, `findings.md`, and `decisions.md` -- unconditionally, with no
  size threshold, because a doc's trajectory is not predictable when it is
  created and a migration that must be noticed mid-investigation does not
  happen. `README.md` holds purpose, investigation rules, trigger, hypotheses,
  task ledger, rejected ideas, open questions, and outcome: the orientation
  layer the reading order already sends agents to first. Docs that predate this
  form stay flat `N-topic.md`; that set is frozen and enumerated, never extended
  and never written as a number range, because the number line has holes in it.
- **Anything else that grows is promoted to its own file** in the folder --
  a large finding, a hypotheses section, a reproduction recipe, scratch
  evidence -- and linked from `README.md` with a one-line blurb. One general
  rule rather than a menu of named files, because the third-tier sections are
  not universal across investigations and naming them would encode one research
  domain. A supporting file nothing links to is unreachable, and so does not
  exist as far as a reader is concerned.
- **Files are numbered** (`N-topic/`, next unused integer) and never
  renumbered. A dead doc is marked superseded at the top, not deleted, so its
  rejected ideas stay findable.
- **The index is two tables**, `## Live` and `## Closed`, each in ascending
  doc-number order so a citation (`17/F7` -> doc 17) is still found by scan.
  Membership is the only record of liveness: closing a doc moves its row.
  Closure is one-way -- reopening gets a new number and a backreference -- so a
  row moves tables at most once, in a commit that means something.
- **An index row is capped.** It carries the doc number, a linked title, one
  clause naming what the doc owns, and one clause on what changed (`## Closed`)
  or on what it is waiting for (`## Live`). No cell exceeds 100 characters, and
  a `## Closed` result opens with `Shipped`, `No change`, `Rejected`,
  `Declined`, `Superseded`, or `Tooling`. The arc, the evidence, and the
  reopening condition live in the doc's own `## Outcome`, and a durable
  cross-cutting lesson graduates out of research entirely -- to whichever
  project guide owns that subject. The diagnostic reading is part of the rule:
  **a row that will not fit means the doc's `## Outcome` is underwritten -- fix
  it there.**
- **The index does not accumulate.** The only prose above the tables is a short
  list of things a reader must know before opening any doc, one line each,
  citing the `N/F#` that owns it. It is not a destination for lessons: an entry
  that needs a paragraph is a sign it belongs in a project guide, and an entry
  that only summarizes one doc belongs in that doc's `## Outcome`. Capping the
  rows without capping this list just moves the problem up the page.
- **A new file may continue an older one.** Reopening a closed investigation, or
  zooming in on one revelation from another file, gets its own number and names
  its ancestor at the top. See "Continue an older doc instead of reopening it"
  below.
- **The task ledger is the doc's primary interface.** Keep it near the top of
  `README.md`, after the short framing sections needed to interpret the tasks:
  purpose, investigation rules, triggering evidence, and current hypotheses. It
  is ever-growing and ever-changing: tasks are added as ideas appear, re-scoped
  as understanding improves, and closed with an outcome. Many tasks are
  legitimately "do further research on X" -- that is a first-class task, not a
  placeholder.
- **Each task carries a status**: `TODO` (idea, not yet examined), `RESEARCH`
  (needs investigation before it can be judged), `VETTING` (has a concrete
  proposal awaiting evidence or review), `ACTIVE` (being worked),
  `DONE` (landed; link the commit/plan), or `REJECTED` (kept, with the reason
  inline -- rejection reasons are the most valuable content in the doc).
  A checkbox ledger may use `[ ]` and `[x]` instead when the tasks form an
  ordered investigation; record the richer status and disposition in the
  corresponding finding or decision entry.
- **The doc is live.** Update it whenever the investigation learns something:
  new profile evidence, a dead end, a better decomposition, a changed
  recommendation. The body converges over time toward a final strategy that
  directs the actual implementation; when that happens, the strategy is
  extracted into a plan or design doc and the research doc records where it
  went.
- **Claims cite evidence.** Performance numbers name the benchmark, commit, and
  compatibility conditions the project's performance guide defines. Profiled
  timings are labeled as diagnostic, never as benchmark results.
- **Rejected ideas are never silently removed.** Move them to a "Rejected"
  section (or mark the task `REJECTED`) with one or two lines on why, so the
  same idea is not re-litigated six months later.
- **The doc is the handoff.** An investigation usually outlives the agent
  working it, and no agent knows in advance whether it is the one that closes
  the doc. The doc -- not the conversation that produced it -- is all the
  next agent inherits, so anything an agent knows and does not write down is
  lost. Write as you go, not at closure; see "Write for the next agent" below.

## Required shape

`README.md` uses this order unless the investigation has a concrete reason to
omit or rename a section. The two logs live in their own files so the largest
sections of a doc cannot crowd out its orientation layer.

```markdown
# Research topic

Research started: YYYY-MM-DD.
Continues: [N-topic/README.md](N-topic/README.md) (`N/F3`).   <!-- only when it has an ancestor -->

- [findings.md](findings.md) -- the append-only evidence chain.
- [decisions.md](decisions.md) -- the auditable decision log.

## Purpose

What this doc owns, why the investigation exists, and what evidence or
decision boundary it must preserve.

## Investigation rules

- Investigation-specific constraints on evidence, comparison, testing, and
  when implementation may begin.

## Trigger and current evidence

The observed behavior that opened the investigation, its provenance and
caveats, and the smallest useful summary of measurements or examples.

## Current hypotheses

### H1 -- falsifiable explanation

Evidence that supports it, competing explanations, and what would confirm or
reject it. Hypotheses are not conclusions.

## Candidate direction, pending evidence

The currently promising shape and why, explicitly labeled as provisional.
Omit this section when evidence does not yet justify a candidate.

## Task ledger

### Phase 1 -- establish evidence

- [ ] A concrete action with a recorded result in Finding F1.
- [ ] A decision gate with explicit acceptance or rejection criteria.

### Phase 2 -- attribute the cause

- [ ] ...

## Rejected

### Rejected idea

Why it was considered, the evidence against it, and what new evidence would
justify reopening it.

## Open questions and caveats

- Unresolved facts, provenance limits, and constraints that remain live.

## Outcome

Investigation in progress.
```

`findings.md` and `decisions.md` hold one entry per stable ID:

```markdown
### F1 -- stable descriptive name

- Status:
- Date and investigator:
- Commit and worktree state:
- Commands, inputs, or reproduction:
- Result or artifact paths:
- Measurements or examples:
- Observation:
- Inference:
- Competing interpretations:
- Uncertainty:
- Next action:

### D1 -- decision being made

- Status:
- Evidence used:
- Candidate solutions:
- Tradeoffs and correctness risks:
- Recommendation:
- Direction review:
- Selected direction:
- Behavioral verification:
- Quantitative verification, when applicable:
- Decision and rationale:
```

The template is a schema, not a demand for empty boilerplate. Omit fields that
do not apply, but do not collapse distinct observations, inferences, and
decisions into narrative prose.

## How to run the doc

### Start from a bounded trigger

State the concrete observation that caused the research to exist. Record enough
provenance to reproduce or audit it: commit and worktree state, command or
input, environment when relevant, artifact paths, and known compatibility
limits. Separate trustworthy evidence from exploratory evidence, and preserve
why either is usable.

### Continue an older doc instead of reopening it

Work that grows out of an existing doc -- reopening a closed question, or
zooming in on one revelation from another investigation -- gets its own new
numbered doc that names its ancestor. That keeps each doc scoped to one
question while the backreference still points at prior work, so it is not
redone.

Cite the specific `N/F#` or `N/D#` you are building on, and restate only the
boundary you inherit, not the evidence behind it. Leave a pointer in the
ancestor so the lineage is findable from either end; pointing at a successor
does not reopen a closed doc. Cross-file IDs are always qualified -- `F3` is
this doc's, `9/F3` is doc 9's -- and a continuation numbers its own findings
from `F1`.

### Turn theories into falsifiable hypotheses

Give hypotheses stable IDs (`H1`, `H2`, ...). For each one, record:

- the proposed mechanism;
- the evidence already supporting it;
- plausible competing explanations;
- the smallest experiment or observation that would distinguish them; and
- the condition that confirms, partially confirms, or rejects the hypothesis.

Do not let a plausible mechanism silently become the selected fix. A controlled
experiment may validate a cause without being suitable production code.

### Organize work as an evidence funnel

Make ledger phases narrow uncertainty in order:

1. establish a trustworthy baseline or reproduction;
2. attribute the behavior to a cause;
3. compare candidate directions against the evidence;
4. pause at an explicit direction gate when the choice matters;
5. implement and verify only the selected direction; and
6. close with a clean final measurement or behavioral result.

Each task should name its durable destination (`F1`, `D1`, a plan, a design
doc, or a commit) when one exists. Include explicit sequencing constraints such
as "begin only after..." when later evidence would otherwise be confounded.
Ledger tasks should say what result to record, not merely what command to run.

### Keep an append-only evidence chain

Findings use stable IDs (`F1`, `F2`, ...). One finding may cover a tightly
related task cluster, but it must preserve:

- what was actually observed;
- what is inferred from that observation;
- alternative interpretations;
- confidence or uncertainty; and
- the next action the result unlocks.

Do not silently replace an earlier measurement or interpretation. Append the
new evidence, mark the old interpretation superseded, and explain why. Link
large artifacts instead of pasting them unless a compact excerpt or table is
necessary to reason about the result.

### Make decisions auditable

Decisions use stable IDs (`D1`, `D2`, ...), cite the findings they depend on,
and compare credible candidates. Record expected benefit, behavioral and
correctness risks, maintenance risks, and the evidence that would falsify the
recommendation. Keep recommendation, direction approval, implementation, and
verification as separate states.

Audit behavioral coverage before implementation. Tests must protect observable
behavior or an invariant, not a helper, branch, or chosen internal structure.
It is valid to conclude that existing tests are sufficient; record the audit
and its reasoning rather than adding a structure-coupled test.

### Close without erasing uncertainty

The Outcome summarizes what was learned, what shipped or graduated elsewhere,
what was rejected, and which uncertainties or follow-up tasks remain. Link the
plan, design doc, and commits that received the settled work. If the
investigation is abandoned or superseded, say so at the top and link its
successor; keep the evidence and rejected paths intact.

### Write for the next agent

Write as though the agent who continues this doc starts cold: no chat history,
no memory of what you tried, only the doc and the repo. That reader is often a
future you with a fresh context window.

- **Update mid-investigation, not only at closure.** Record a result when you
  have it, not once the phase is done. An investigation that ends abruptly
  should lose at most the step in progress.
- **An `ACTIVE` task carries its in-progress state.** Note what is running or
  half-done, what has already been tried within the task, and the next concrete
  step. `ACTIVE` with no notes underneath tells the next agent nothing except
  that someone started.
- **Record inconclusive attempts, not just rejections.** A command that did not
  reproduce the behavior, a profiler that would not attach, a benchmark whose
  variance swamped the effect -- these are not findings-grade results and not
  rejected ideas, but re-running them is the most common way a fresh agent
  wastes an hour. One line under the task is enough.
- **Prefer the doc over the summary.** If you would put a fact in a hand-off
  message, it belongs in the doc first.

## Reading order for agents

Before working in an area that has a research doc: read its task list first,
then the findings, decisions, hypotheses, and caveats referenced by the active
task. Before proposing a new idea in that area, check the Rejected section and
the competing interpretations in relevant findings.
