# .pipeline -- design notes

Our notes, not agent instructions (those are in AGENTS.md). Terse and live:
edit in place as the design changes.

## Objective

Automate the manual loop: issue -> verify -> plan -> review/revise -> impl ->
merge, unsupervised until an agent needs a human. The human's job shrinks to
appending issues and answering questions.

## Shape

- The folder is the whole system: data (five state dirs) + instructions
  (AGENTS.md). No scripts, no config format. Claude is the only executable.
- A *worker* is one interactive Claude session started by hand in a pane. It
  claims one item, drives it to completion or a pause, then stops. Parallelism
  = number of panes. Workers never do stage work themselves; they delegate each
  stage to a separate process so their own context stays thin and judgment
  stays small (which stage next, did the artifact land, does this need the
  user). Implementor launches are one-shot; the planner is one session for
  two turns (verify, then plan the fix it pitched, so the project scan is paid
  for once); reviewer and reviser are persistent sessions for the whole
  review loop (resumed each round, so the plan and rubric are paid for once
  and each remembers its own history). The
  worker is the only channel between them: it hands each one the other's
  report file.
- Stage agents are processes, not Agent-tool subagents, because the roster
  mixes runners (Claude and Codex). Only those two will ever exist, so the
  calling conventions are baked in verbatim rather than abstracted. The roster is one table in AGENTS.md;
  stdin = prompt file, stdout = artifact file, last line = `NEXT:` verdict.
  Redirecting stdout means the artifact exists even if the agent misbehaves.
- `active/<slug>/state.md` is the durable state. Sessions are disposable; a
  fresh worker must be able to resume any item from its dir alone.
- Pause = AskUserQuestion in the worker's own pane, with the item moved to
  `blocked/` first so the pause survives the session. The pane is the question
  UI; no new UI yet.
- Intake is structureless prose. Triage (verify-issue) is the pipeline's job,
  not the human's.

## Portability

Generic above the `## This project` line in AGENTS.md, project-specific below
it. Install in another project = copy the folder, rewrite that section.
DanTerm integration stays in that section so the core never depends on it.

## Open questions / next

- The `NEXT:` trailer is asked for in the prompt, not built into the skills.
  If agents forget it, bake it into review-plan / revise-plan.
- Runner commands in AGENTS.md `## Runners` are probed and verified
  (2026-08-20, Claude Code 2.1.237, Codex 0.148.0); that section carries the
  versions so a CLI change is one section to fix.
- Stale claims (worker died mid-item) are fixed by hand for now.
- Auto-advance vs approval gate after verify: current rule is auto-advance for
  local fix / clear pivot, ask for feature / scope / drop.
- Later, maybe: `q` append script, `status` script, promote AGENTS.md into a
  `/worker` skill once the text settles, danterm sidebar as dashboard, phone
  answers over tailnet.
