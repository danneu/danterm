# Plan: document launching interactive agents (claude) from `danterm tab new --cmd`

## Context

This session created 10 DanTerm tabs, each launching `claude --effort max` seeded
with a `/verify-issue <finding>` prompt. Getting that right required reasoning
through three non-obvious things that the skill does not currently mention:

1. **Claude's TTY boundary.** Claude Code's documented interactive
   initial-prompt form is `claude "query"`. On Claude Code 2.1.152, stdout decides
   the interactive boundary: piped or redirected stdin is also accepted as the
   initial prompt as long as stdout stays attached to the terminal. The
   natural-looking `echo "..." | claude` (or `cat file | claude`) launches the
   TUI and sends that text as the first user message. Do not document stdin
   pipes as forcing headless mode; Claude's own help ties non-interactive mode
   to `--print` or stdout not being a TTY.
2. **Quoting hostile prompt text.** The findings contained backticks, `$`,
   quotes, parens, and newlines (normal for code-review text and `file:line`
   refs). Embedding that inline through the `danterm -> login shell -> claude`
   boundary is a quoting minefield (I hit a zsh arithmetic-expansion error on the
   first attempt). The robust pattern is to stage the prompt in a file and feed
   it on stdin with a single-quoted command such as
   `--cmd 'claude --effort max < /tmp/danterm-prompt.txt'`.
3. **Effort level for serious agent work.** The live tabs in this session were
   spawned for `/verify-issue` investigation, which is the kind of work where
   the agent should trade speed for reasoning quality. The recipe should make
   `--effort max` the default for serious tasks such as implementing a plan,
   verifying an issue, reviewing a plan, or reviewing an implementation.

The existing "Open a new tab and optionally run a command in it" recipe only
shows self-contained commands like `--cmd 'vim notes.md'`, so a future agent has
no guidance for the (increasingly common) "launch an agent CLI in a tab" case.
Goal: add a focused recipe + a cross-reference rule so agents get this right the
first time.

This is a docs-only change. It does NOT touch the CLI surface, flags, stdout
shape, or parser, so the AGENTS.md "keep SKILL.md synced with the CLI" rule
imposes no code changes.

## File to modify

- `/Users/dan/world/my-apps/danterm/integrations/danterm/SKILL.md` (DanTerm repo
  source of truth; the installed copy at `~/.claude/skills/danterm/SKILL.md` is an
  identical build artifact that regenerates on the next `world:rebuild`). Path is
  absolute on purpose: this plan file currently lives under `.refs/cmux/plans/wip/`
  (a vendored clone of a different repo), so a repo-relative target would
  misresolve. Recommend relocating this plan to
  `~/world/my-apps/danterm/plans/wip/` before implementing.

Two insertions, matching the file's existing style (imperative prose,
4-space-indented code blocks, ASCII `--`):

### 1. New recipe, inserted between the end of the "Open a new tab" recipe (after its `--after-tab`/`--after-selected` paragraph) and the `### Split a pane and run a command in the new one` heading

```
### Launch Claude with an initial prompt

To open Claude Code in the new tab and seed its first prompt, keep stdout
attached to the terminal and pass simple prompts as an argument. This is Claude
Code's documented interactive initial-prompt form. Claude stays interactive
unless you use `--print` or send its stdout somewhere other than the terminal.
For serious agent work -- implementing a plan, verifying an issue, reviewing a
plan, reviewing an implementation, or similarly high-judgment tasks -- launch
Claude with `--effort max`.

    danterm tab new --group "$GROUP_ID" --title review \
      --cmd 'claude --effort max "review the staged diff"'

For shell-hostile or multi-line prompts -- backticks, `$`, quotes, parens,
newlines, which are common in code-review findings and `file:line` refs -- stage
the prompt in a file and feed it on stdin. This is not the docs' primary example,
but it is verified on Claude Code 2.1.152 and avoids shell-quoting the prompt
contents:

    # write $PROMPT to the file first (heredoc/editor/agent write, not inline quoting)
    danterm tab new --group "$GROUP_ID" --title verify \
      --cmd 'claude --effort max < /tmp/danterm-prompt.txt'

Single-quote the whole `--cmd` value so the redirection is interpreted by the
tab's login shell. Use a unique filename per tab when launching several at once.
```

### 2. New bullet in "## Rules for agents", immediately after the `--cmd` seeding bullet (the "Prefer `tab new --group <group-id> --cmd` ..." bullet), before the background-default bullet

```
- To launch Claude with an initial prompt, keep its stdout attached to the
  terminal. For serious agent work (implementing a plan, verifying an issue,
  reviewing a plan, reviewing an implementation, etc.), use `claude --effort
  max`. Pass simple prompts as arguments. For shell-hostile prompt text, stage
  it in a file and use the DanTerm-verified stdin form
  `--cmd 'claude --effort max < /tmp/danterm-prompt.txt'`. See the recipe above.
```

## Verification

- The recipe matches the official Claude Code CLI reference: `claude "query"`
  starts an interactive session with an initial prompt; `claude -p "query"` is
  the non-interactive/SDK form; the docs' piped-content example is
  `cat file | claude -p "query"`.
- The recipe matches current Claude Code behavior: local `claude --help` says
  Claude starts an interactive session by default and identifies `--print` or
  non-TTY stdout as non-interactive mode.
- Verified in DanTerm this session: launching `claude --effort max "$(cat <file>)"`
  (prompt passed as a positional argument) opened an interactive session that
  auto-submitted the prompt -- confirmed via `danterm pane read`. This exercises
  the same positional-arg path as the recipe's headline
  `claude --effort max "review the staged diff"` example.
- Verified in DanTerm on Claude Code 2.1.152: `printf ... | claude
--permission-mode plan` launched the TUI, treated the piped bytes as the first
  user message, accepted a second message via `danterm pane input`, and replied.
- Verified in DanTerm on Claude Code 2.1.152: `claude --permission-mode plan <
/private/tmp/danterm-claude-file-interact.txt` launched the TUI, treated the
  file bytes as the first user message, accepted a second message via
  `danterm pane input`, and replied.
- Verified in DanTerm on Claude Code 2.1.152: `claude --permission-mode plan <
/private/tmp/danterm-claude-stdout-probe.txt > /private/tmp/danterm-claude-stdout-probe.out`
  exited with status 0 and wrote plain output, confirming the non-TTY stdout
  path is non-interactive.
- Re-read `integrations/danterm/SKILL.md` to confirm the two blocks render
  cleanly and the surrounding section headers/numbering are intact.
- Optional sanity check that nothing else broke:
  `bash scripts/tests/danterm-integration_test.sh` (shell-integration smoke
  test; unrelated to docs but cheap to run).
- The installed skill picks up the change on the next `world:rebuild`; until
  then the repo copy is the reference.

## Out of scope

- No commit is made as part of this plan (commit only on explicit request).
- No CLI/parser/`CLIParser.swift` changes -- documentation only.
