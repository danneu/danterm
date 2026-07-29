# docs/research/ -- living research files

## File index and status

Reviewed 2026-07-29. **Docs 1 and 15 are live; every other file is closed.**
Closed means the
questions it opened have answers and nothing in it is waiting on anyone -- not
that every idea in it was implemented. Several closed with parked backlogs; each
one records its own reopening condition, and those conditions are the right
entry point, not a re-read of the evidence.

| # | Topic | Status |
| --- | --- | --- |
| 1 | External terminal tests | **LIVE.** Survey complete; its Milestone 8/9/10 injection points are not yet consumed. Close when M9's evidence package is assembled. |
| 2 | Wraptest coverage | Closed. Declined, on redundant coverage *and* unclear license. |
| 3 | Serialized redraw optimization | Closed. Per-run glyph batching shipped; medians -97%. |
| 4 | Fallback-glyph batching | Closed. Superseded by procedural sprites across eight families. |
| 6 | Sprite classification regression | Closed. Both regressions from the sprite series found and fixed. |
| 7 | Fast paired A/B benchmarks | Closed. Runner shipped and decided every verdict in docs 8-13. Ghostty baseline never built. |
| 8 | Benchmark variance regression | Closed. Cause is a CPU frequency governor; `D2` routes around it and graduated to a design note. |
| 9 | Plan/render allocation hotspots | Closed. Three changes shipped; Phase 5 parked with a measured ceiling. |
| 10 | `Terminal.feed` hotspots | Closed. -24.31% on `terminal-feed`; remaining items are optional backlog. |
| 11 | Render frame budget | Closed. The draw path fits the 60Hz budget; no change proposed or warranted. |
| 12 | Cell representation | Closed. Erase leg shipped; POD cell demonstrated-and-rejected; memory half parked. Its reopening condition was met on 2026-07-29 and taken up by doc 15. |
| 13 | Live-app compositing | Closed. Three candidates landed; compositing stall is substantially pipeline slack. |
| 14 | Live scroll workload profile | Closed. One trace, four candidates, two shipped: `TerminalScalars` accessor inlining (**-20% draw**, `14/D2`) and a row-scoped cell read (**-16% plan**, `14/D3`). One candidate rejected as too small to measure (`14/D1`). |
| 15 | Memory footprint | **LIVE.** Takes up doc 12's recorded reopening condition. Owns resident bytes per cell, per row, and in aggregate. **Phase 1 closed; Phase 2's engineering half shipped.** `15/F4`+`15/D1`: evicted scrollback rows kept their cells, so history held up to **2x** the rows it admitted (~22 MB at peak), fixed at no CPU cost. `15/F7` closed the attribution -- holding 21.75 MB of cells costs ~25 MB (cells, plus 1,488 B/row of malloc bucket rounding, plus ~4 MB allocator slack, plus **zero** retention). `15/D2`+`15/F9`: the byte budget charged 40 bytes for a 72-byte cell, so a 10 MB budget held ~22 MB; corrected, it holds ~10.8 MB and history halves from ~1,704 to ~810 rows. Two of Phase 1's four answers were corrections to its own instruments: `15/F6` (`benchmark-memory` cannot resolve a representation change) and `15/F7` (the headless probe charged its own feed call to resident state). Open: the budget's nominal value and whether it should be denominated in lines rather than bytes (`15/D2`). |

(There is no doc 5; numbers are never reused or renumbered.)

**Two results worth knowing before you open any of these.** The draw path fits
the frame budget (`11/F7`, `11/F8`), so a new render optimization needs a
trigger, not just a profile share. And `8/D2` moved damage-*drawing*
comparisons off the GUI benchmark onto `just benchmark-headless-draw`; damage
*generation* stays on a degraded `benchmark-quick`. Read
[docs/design/2026-07-27-damage-render-benchmark-routing.md](../design/2026-07-27-damage-render-benchmark-routing.md)
before measuring anything. A third: **the plan/draw ratio is workload-shaped and
no published ratio generalizes** -- doc 13's four captures are btop, doc 14's is
a full-viewport scroll, and they disagree by 2x in both directions (`14/F1`).
And a fourth, which is about method: **re-size any `sample`-derived hotspot on an
on-CPU instrument before spending a paired benchmark on it.** `just
benchmark-trace` costs one build and one 30 s run; in `14/F6` it deflated a node
by 2.5x and killed the candidate built on it (`14/D1`). `sample` counts blocked
threads, so it inflates anything near allocation, ARC, or the kernel. The
corollary, from `14/F11`: **do not then discount the on-CPU share.** `9/F3`'s ~3x
optimism factor attaches to `sample`, and applying it to an on-CPU share of
deletable work under-predicted a 16% win as 5%. And a mechanical trap worth
knowing before you measure a plan-path change: **`benchmark-confirm` does not
classify plan time at all** -- the calibrated plan rule lives only in
`benchmark-quick`, on `content-churn` and `style-churn` (`14/F11`). The memory
equivalent, from `15/F6`: **`just benchmark-memory` is a leak detector, not a
measurement instrument.** Asked to confirm a ~22 MB saving it reported the fixed
build as *larger* -- one memgraph samples one arbitrary point on a sawtoothing
quantity, and GUI IOSurface churn ran 50 MB over the same window. Use it for
"is this growing without bound"; do not use it for "did this get smaller".
Its replacement can be wrong too, in the same shape: the headless probe that
succeeded it charged its own oversized `feed` call to resident state and reported
cell bytes as 35-50% of process cost when the true figure is ~85% (`15/F7`). The
general rule those two cost: **vary something that should not matter -- sawtooth
phase, feed chunk size, column count -- before believing any memory number.**
Related, and cheap to be burned by: a 2-pair `benchmark-quick` reading of
**+1.05%** on `scrollback-stream` flipped to **-0.86%** at 4 pairs (`15/F6`) --
an "inconclusive" verdict is not a weak regression signal, so escalate before
reporting one.

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
- **The file is the handoff.** An investigation usually outlives the agent
  working it, and no agent knows in advance whether it is the one that closes
  the file. The file -- not the conversation that produced it -- is all the
  next agent inherits, so anything an agent knows and does not write down is
  lost. Write as you go, not at closure; see "Write for the next agent" below.

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

### Write for the next agent

Write as though the agent who continues this file starts cold: no chat history,
no memory of what you tried, only the file and the repo. That reader is often a
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
- **Prefer the file over the summary.** If you would put a fact in a hand-off
  message, it belongs in the file first.

## Reading order for agents

Before working in an area that has a research file: read its task list first,
then the findings, decisions, hypotheses, and caveats referenced by the active
task. Before proposing a new idea in that area, check the Rejected section and
the competing interpretations in relevant findings.
