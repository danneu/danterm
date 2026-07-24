# docs/research/ -- living research files

A research file is a scratchpad for a single investigation or strategy area.
It is not an ADR and not a plan: design decisions that are settled graduate to
`docs/design/`, and work that is ready to implement graduates to a plan file.
A research file is where ideas live while they are still being discovered,
vetted, refined, or rejected.

## Contract

- **Files are numbered** (`N-topic.md`, next unused integer) and never
  renumbered. A dead file is marked superseded at the top, not deleted, so its
  rejected ideas stay findable.
- **The task ledger is the file's primary interface.** Keep it near the top,
  after the short framing sections needed to interpret the tasks: purpose,
  investigation rules, triggering evidence, and current hypotheses. It is
  ever-growing and ever-changing: tasks are added as ideas appear, re-scoped as
  understanding improves, and closed with an outcome. Many tasks are
  legitimately "do further research on X" -- that is a first-class task, not a
  placeholder.
- **Each task carries a status**: `TODO` (idea, not yet examined), `RESEARCH`
  (needs investigation before it can be judged), `VETTING` (has a concrete
  proposal awaiting evidence or review), `ACTIVE` (being worked),
  `DONE` (landed; link the commit/plan), or `REJECTED` (kept, with the reason
  inline -- rejection reasons are the most valuable content in the file).
  A checkbox ledger may use `[ ]` and `[x]` instead when the tasks form an
  ordered investigation; record the richer status and disposition in the
  corresponding finding or decision entry.
- **The file is live.** Update it whenever the investigation learns something:
  new profile evidence, a dead end, a better decomposition, a changed
  recommendation. The body converges over time toward a final strategy that
  directs the actual implementation; when that happens, the strategy is
  extracted into a plan or design doc and the research file records where it
  went.
- **Claims cite evidence.** Performance numbers name the benchmark, commit,
  and compatibility conditions per
  [agent-docs/terminal-performance.md](../../agent-docs/terminal-performance.md).
  Profiled timings are labeled as diagnostic, never as benchmark results.
- **Rejected ideas are never silently removed.** Move them to a "Rejected"
  section (or mark the task `REJECTED`) with one or two lines on why, so the
  same idea is not re-litigated six months later.

## Required shape

Use this order unless the investigation has a concrete reason to omit or
rename a section:

```markdown
# Research topic

Research started: YYYY-MM-DD.

## Purpose

What this file owns, why the investigation exists, and what evidence or
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

## Findings log

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

## Decision log

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

## Rejected

### Rejected idea

Why it was considered, the evidence against it, and what new evidence would
justify reopening it.

## Open questions and caveats

- Unresolved facts, provenance limits, and constraints that remain live.

## Outcome

Investigation in progress.
```

The template is a schema, not a demand for empty boilerplate. Omit fields that
do not apply, but do not collapse distinct observations, inferences, and
decisions into narrative prose.

## How to run the file

### Start from a bounded trigger

State the concrete observation that caused the research to exist. Record enough
provenance to reproduce or audit it: commit and worktree state, command or
input, environment when relevant, artifact paths, and known compatibility
limits. Separate trustworthy evidence from exploratory evidence, and preserve
why either is usable.

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

## Reading order for agents

Before working in an area that has a research file: read its task list first,
then the findings, decisions, hypotheses, and caveats referenced by the active
task. Before proposing a new idea in that area, check the Rejected section and
the competing interpretations in relevant findings.
