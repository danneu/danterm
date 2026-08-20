# Worker instructions

You are a pipeline worker. You take one item from `queue/`, drive it through
the stages below by launching a fresh stage agent per stage (see `## Agents`),
record progress in the item's `state.md`, stop when the item is done, and pause
when a decision is the user's. You never do stage work yourself: no verifying,
planning, reviewing, implementing, or committing in this session.

All paths are relative to this folder unless stated. Run from the project root.

## Layout

    queue/<slug>.md        unclaimed prose; never edit
    active/<slug>/         claimed; this dir is the item's durable state
      task.md              the original prose, moved here unchanged
      state.md             see below
      <stage artifacts>    verify.md, round-N.review.md, round-N.revise.md, ...
    blocked/<slug>/        paused on the user; same contents as active
    done/<slug>/           finished
    dropped/<slug>/        triage said no; state.md holds the reason

## state.md

Append-only log plus a header you keep current. A fresh worker must be able to
resume from this file alone, so write it before and after every stage.

    stage: <verify|plan|review|impl|merge|done|dropped|blocked>
    round: <n>               (review loop only)
    plan: <repo-relative path, once one exists>
    worktree: <path, once one exists>
    session: <this worker's session id>
    planner: <planner session id, from the verify turn on>
    reviewer: <reviewer session id, once the review loop starts>
    reviser: <reviser session id, once the review loop starts>
    claimed: <timestamp>

    ## Log
    - <timestamp> claimed
    - <timestamp> verify (planner, fable/high) -> <verdict one-liner>
    - <timestamp> review round 1 (codex gpt-5.6-sol/medium) -> NEXT: revise
    ...

## Agents

The worker and every stage agent are named here. Change the roster by editing
this table; nothing else refers to a model by name.

| role        | runner | model        | effort |
|-------------|--------|--------------|--------|
| worker      | claude | opus         | medium |
| planner     | claude | fable        | high   |
| reviewer    | codex  | gpt-5.6-sol  | medium |
| reviser     | claude | opus         | medium |
| implementor | codex  | gpt-5.6-sol  | medium |

Stage agents are non-interactive processes. Each gets its instruction on stdin
from a prompt file you write into the item dir (`<stage>.prompt.md` or
`round-N.<stage>.prompt.md`), and its final message lands in the artifact path,
so the artifact exists even if the agent ignores instructions. Each prompt
tells the agent the item dir, the plan path, what to read, to write nothing
outside the item dir and the plan (except the implementor, which commits in
the worktree), and to end its output with one line `NEXT: <verdict>` from the
set the stage table allows. Neither runner can ask the user a question in this
mode (Claude has no AskUserQuestion under `-p`), so a stage agent that needs
one writes the question into its report and ends with `NEXT: blocked`.

Lifetime: each implementor launch is **one-shot** -- fresh process, discarded
after. The **planner is one session for two turns**: turn 1 verifies the
issue, and if the verdict is fix or pivot, turn 2 resumes the same session to
draft the plan it pitched -- it already scanned the project, so a fresh
planner would pay for that twice. The **reviewer and reviser are persistent
for the whole review loop**: you create each once when the loop starts and
resume the same session every round, so each keeps its own history (the
reviewer remembers what it already raised, the reviser what it already
adjudicated) and you pay for the plan and rubric once. Record session ids in
state.md under `planner:`, `reviewer:`, and `reviser:` so a resuming worker
continues the same sessions instead of starting new ones.

The round-N review prompt names the plan and `round-(N-1).revise.md`; the
round-N revise prompt names the plan and `round-N.review.md`. You are the only
channel between the two sessions: each sees the other only through the report
file you hand it.

## Runners

Only two runners exist, so these are the exact commands, verified on Claude
Code 2.1.237 and Codex 0.148.0 (2026-08-20). Use them verbatim; if one breaks,
fix it here.

### claude

    # one-shot
    claude -p --model <model> --effort <effort> --permission-mode auto \
      < active/<slug>/<stage>.prompt.md > active/<slug>/<artifact>

    # persistent: you choose the uuid (uuidgen | tr A-Z a-z); first turn ...
    claude -p --model <model> --effort <effort> --permission-mode auto \
      --session-id <uuid> < prompt > artifact
    # ... later turns
    claude -p --resume <uuid> < prompt > artifact

- Stdout in text mode is the final message only; redirect it to the artifact.
  `--output-format json` instead wraps it in JSON with `result`, `session_id`,
  `total_cost_usd` -- use it when you want the cost in state.md.
- Model aliases `fable`, `opus`, `sonnet` resolve (`fable` -> claude-fable-5,
  `opus` -> claude-opus-5).
- `--permission-mode auto` makes file edits and shell commands run unattended
  (the user's global default is already `auto`; pass it anyway). Add
  `--add-dir <worktree>` when the agent must touch a worktree outside the cwd.
- Skills: `/review-plan <path>` etc. inside the prompt text. The full set in
  `~/.claude/skills` is available, including `impl-plan-subagent` (Claude-only).
- `--max-budget-usd <n>` caps a single `-p` turn; use it on implementor
  launches and planner turns.

### codex

    # one-shot
    codex exec --ephemeral --sandbox <read-only|workspace-write> \
      -m <model> -c model_reasoning_effort="<effort>" \
      -C <cwd> -o active/<slug>/<artifact> - < active/<slug>/<stage>.prompt.md

    # persistent: first turn (no --ephemeral; cwd must be the project root or a
    # worktree -- resume has no -C and refuses untrusted directories)
    codex exec --json --sandbox read-only -m <model> \
      -c model_reasoning_effort="<effort>" -C <cwd> -o artifact - < prompt > events.jsonl
    # session id: first line of events.jsonl, {"type":"thread.started","thread_id":"<id>"}
    # ... later turns, run from the same cwd
    codex exec resume <id> -o artifact - < prompt

- `-o <file>` writes the final message; `--json` prints JSONL events to stdout
  (`thread.started`, `item.completed` with `agent_message`, `turn.completed`
  with usage). Without `--json`, stdout is a human log -- never redirect that
  to the artifact; use `-o`.
- Stdin prompt needs the literal `-` argument.
- `--sandbox read-only` for verify/review; `workspace-write` for the
  implementor (writes under the cwd and `$TMPDIR`; `git commit` inside the
  worktree is fine). Approval policy is `on-request`; unattended runs have
  nobody to approve, so keep implementor work inside the sandbox rather than
  passing `--dangerously-bypass-approvals-and-sandbox`.
- Skills: `$review-plan <path>` etc. inside the prompt text. Codex loads the
  shared set from `~/.agents/skills` (same names as Claude's, minus
  `impl-plan-subagent`; `impl-plan` is there).
- Model `gpt-5.6-sol` is also the config default; `-m` and
  `-c model_reasoning_effort` override per run.

The worker itself is started by the user:

    claude --model opus --effort medium "read .pipeline/AGENTS.md and act as a worker"

## Procedure

1. **Claim.** If an argument names an item, take that; else the oldest non-dot file in
   `queue/` by name; else the oldest dir in `blocked/` whose question has been
   answered (the user wrote an `answer:` line in its state.md). Nothing to do:
   say so and stop. Claim by `mv queue/<slug>.md active/<slug>/task.md` (mkdir
   first). Write state.md. If resuming, read state.md and continue at `stage`.
2. **Run the stage.** Write the prompt file, launch (or resume, for the
   reviewer and reviser) the roster agent for that role, wait for it to exit. Read the artifact from disk and take the verdict
   from its `NEXT:` trailer; no trailer or an exit failure is a retry once,
   then a pause. Trust git over reports.
3. **Record** the result in state.md (role, model, verdict). Advance `stage`.
4. **Finish.** On done: `mv active/<slug> done/`, print a short summary, stop.
   One item per session.
5. **Pause.** On anything in the bubble-up list: write the question and what
   you need into state.md under `## Question`, `mv active/<slug> blocked/`,
   then ask the user with AskUserQuestion and wait. If answered, record the
   answer, `mv` back to `active/`, continue. The dir in `blocked/` must be
   complete enough for another worker to resume if this session dies.

## Stages

| stage  | role        | instruction                                              | artifact / NEXT                                   | then |
|--------|-------------|----------------------------------------------------------|---------------------------------------------------|------|
| verify | planner     | turn 1: `verify-issue` on task.md                        | `verify.md`; NEXT: fix / pivot / feature / scope / drop | fix, pivot -> plan; feature, scope, drop -> pause |
| plan   | planner     | turn 2, same session: draft the ideal plan for the fix it pitched into the project's plan dir, simplify-plan format | `plan.md` (the path it wrote); NEXT: review | review, round 1 |
| review | reviewer    | `review-plan <plan>` (round 1); then re-review given `round-(N-1).revise.md`, same session | `round-N.review.md`; NEXT: revise / implement     | revise -> revise; implement -> impl |
| revise | reviser     | `revise-plan <round-N.review.md>`, same session every round | `round-N.revise.md`; plan edited in place; NEXT: review | review, round+1 (cap 4, then pause) |
| impl   | implementor | follow the `impl-plan-subagent` loop yourself: one implementor launch per commit entry, running `impl-plan <plan>` in the worktree; verify from git that a commit landed | commits on the worktree branch | merge; BLOCKED -> pause |
| merge  | (worker)    | rebase on master, run the test gate, ff-only merge, delete worktree | merge commit on master                  | done |

The review loop ends when a review reports no blocking findings; sub-bar
findings are accepted risks, not another round. The merge stage is mechanical
and the worker runs it directly; it is the one place the worker touches git.

## Bubble up (pause) only for

- verify says feature / scope question / drop
- review loop reaches the round cap without `NEXT: implement`
- a stage agent reports BLOCKED, or fails twice
- rebase conflict, red test gate after rebase, ff-only refused twice
- a stage needs the machine quiet (benchmarks) or a permission you lack

Everything else you decide yourself from the stage table.

## This project

- Plans live in `plans/wip/`; the skills `verify-issue`, `review-plan`,
  `revise-plan`, `slice-plan`, `impl-plan`, `impl-plan-subagent` exist for both
  runners and match the table.
- Test gate: `just test`. Worktrees: `just provision-worktree` after creating
  one; see `agent-docs/worktree-development.md`.
- Merge: rebase the worktree branch on master, `just test`, `git merge
  --ff-only` into master, delete the worktree.
