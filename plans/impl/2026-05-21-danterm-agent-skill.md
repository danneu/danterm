# DanTerm agent SKILL.md

## Context

DanTerm exposes a control surface via the `danterm` CLI (see
`cli/main.swift` and `lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift`).
Today users can shell out by hand (`danterm tab rename ...`,
`danterm pane split --cmd ...`), but coding agents running inside
DanTerm panes do not know the CLI exists. We already ship a Claude
Code Stop-hook (`integrations/claude-code/claude-notify-osc777.sh`)
that users wire into their settings; this plan ships its
LLM-agent-facing twin: an Agent Skill users can install into both
**Claude Code** (`~/.claude/skills/`) and **Codex**
(`~/.agents/skills/`) -- the two file-system-discovered skill
runtimes in scope.

Intended outcome: when a user inside DanTerm tells Claude Code or
Codex "rename this tab to X", "open a tab and run Y", or "what's
the build doing in the other pane", the agent reaches for the
`danterm` CLI instead of declining.

**Prerequisite:** this plan assumes the IPC redesign in
`plans/impl/2026-05-21-ipc-api-launch-spec.md` is fully landed --
the new dotted method names, wrapped response shapes, and
`--cmd`/`--cwd`/`--title` launch flags on `tab new` and
`pane split`. The authoritative contract is in
`lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift` and
`lib/DanTermProtocol/Sources/DanTermProtocol/Methods.swift`.

Scope is CLI-only for v1. Layout dump/restore and remote-session
details are deferred; the `danterm` subcommands are stable, the
snapshot shape less so.

## What gets added

### A skill *directory*, not a loose file

Both Claude Code and Codex define a skill as a directory containing
`SKILL.md` (Codex docs explicitly require this and require both
`name` and `description` in the frontmatter; Claude Code's spec is
compatible). So:

- New directory: `integrations/danterm/`
- New file: `integrations/danterm/SKILL.md`
- The directory's name (`danterm`) is what becomes the installed
  skill name on disk and the `/danterm` invocation. Naming the
  source directory after the install name keeps users from
  renaming during install.

No supporting files (`scripts/`, `references/`, `assets/`) for v1
-- the SKILL.md stands alone.

### A small Nix wrapper, for parity with the hook

- Add a `danterm-agent-skill` derivation to `flake.nix`'s
  `overlays.default` (sibling to `danterm-claude-notify-osc777`,
  line 16). Source is `./integrations/danterm`, installed verbatim
  to `$out/share/danterm-agent-skill/` so the output is a directory
  ready to symlink as `~/.claude/skills/danterm` or
  `~/.agents/skills/danterm`.
- Expose it in `packages` for `hookSystems` (Darwin + Linux --
  SKILL.md is text, not platform-specific).
- No new `checks` entry; it's a static text file.

### README "Agent Skill" section

New section in `README.md`, between the existing "Claude Code
Integration" (line 103) and "OpenAI Codex Integration" (line 192)
sections. Drafted body:

````markdown
## Agent Skill

DanTerm ships an [Agent Skill](https://code.claude.com/docs/en/skills)
under [`integrations/danterm/`](integrations/danterm). It teaches
coding agents (Claude Code, Codex, etc.) how to drive DanTerm from
the shell -- renaming the current tab, opening a new tab and
launching a command in it, reading another pane's output, sending
keys to another pane, theme switching, and todos.

Install the skill *directory* (not the loose file) into your agent
runtime's skill discovery path:

| Runtime | User-wide path | Per-project path |
|---|---|---|
| Claude Code | `~/.claude/skills/danterm` | `<repo>/.claude/skills/danterm` |
| Codex | `~/.agents/skills/danterm` | `<repo>/.agents/skills/danterm` |

### With Nix

Add `danterm.overlays.default` to your `nixpkgs.overlays`, then
symlink the packaged skill directory:

```nix
home.file.".claude/skills/danterm".source =
  "${pkgs.danterm-agent-skill}/share/danterm-agent-skill";
home.file.".agents/skills/danterm".source =
  "${pkgs.danterm-agent-skill}/share/danterm-agent-skill";
```

### Without Nix

Clone this repo (or download the directory) and symlink:

```sh
mkdir -p ~/.claude/skills ~/.agents/skills
ln -s /absolute/path/to/danterm/integrations/danterm \
  ~/.claude/skills/danterm
ln -s /absolute/path/to/danterm/integrations/danterm \
  ~/.agents/skills/danterm
```

### Verify

- Claude Code: type `/skills` and confirm `danterm` is listed.
- Codex: type `/skills` (or run `codex skills list`) and confirm
  `danterm` is listed.

Both runtimes watch the skill paths and pick up changes without a
restart.
````

No app code changes. No new automated tests required -- this is
documentation in a machine-consumed format.

## The SKILL.md content

Drafted against the **post-redesign** CLI by reading
`lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift`
(output modes, params shapes) and
`lib/DanTermProtocol/Sources/DanTermProtocol/KeyTokens.swift`
(`--literal` semantics). Stays under the 500-line skill guidance
(~130 lines).

```markdown
---
name: danterm
description: Drive the DanTerm terminal from the shell. Use when
  the user asks to rename this tab, open or split panes (optionally
  launching a command in them), read output from another pane,
  send keys into another pane, switch the theme, or work with
  DanTerm's built-in todos. DanTerm is a macOS-only terminal; only
  applies when the `danterm` command is on PATH.
allowed-tools: Bash(danterm *)
---

# danterm CLI

`danterm` is the shell client for the DanTerm terminal. Run
`danterm help` for the authoritative command list. The recipes
below cover the cases agents hit in practice.

## Context env vars (set per pane by DanTerm)

- `DANTERM_PANE` -- caller's pane id. Commands default to this pane
  when `--pane` is omitted.
- `DANTERM_TAB` -- caller's tab id. Tab commands default to this.
- `DANTERM_SOCK` -- control socket path (rarely needed; the CLI
  resolves it).

If none of these are set, the user is not inside DanTerm; do not
use this skill.

## When to reach for this skill

| User says | Command |
|---|---|
| "rename this tab to X" / "label this tab" | `tab rename` |
| "open a new tab" / "...and run X in it" | `tab new` (with `--cmd`) |
| "split the pane" / "...and run X in it" | `pane split` (with `--cmd`) |
| "what's the build doing in the other pane?" | `pane read` |
| "type X into pane <id>" / "send Ctrl-C to..." | `pane input` |
| "what tabs/panes are open?" | `ls` |
| "switch the theme to X" | `theme set` |

## Recipes

### Rename / clear the current tab

    danterm tab rename "fix scrollbar math"
    danterm tab rename --clear         # back to auto-derived title

### Open a new tab and (optionally) run a command in it

    danterm tab new
    danterm tab new --group dev
    danterm tab new --cmd 'vim notes.md' --title notes
    danterm tab new --cmd 'cargo test --workspace' --cwd ~/proj --title tests

`--cmd` launches the program directly via libghostty, NOT by typing
into a shell prompt -- it does not race shell startup. The pane
stays open after the command exits.

### Split the current pane and run a command in the new one

Orientation:

- `-h` = horizontal split = **side by side** (new pane to the right)
- `-v` = vertical split = **stacked** (new pane below)

Prefer `--cmd` over splitting and then sending keys -- it avoids
the shell-prompt race.

    danterm pane split -h --cmd 'just test' --title tests   # opens pane to the right

To capture the new pane id for later:

    NEW=$(danterm pane split -v --cmd 'just test' | jq -r '.pane.id')

### Read another pane's output

`pane read` prints raw text (not JSON). Without `--lines`, returns
the visible viewport. With `--lines N`, returns the last N lines
of scrollback.

    danterm pane read --pane "$PANE_ID"
    danterm pane read --pane "$PANE_ID" --lines 200

### Send keys to another pane

Use for interrupts, replies to prompts, or scripted interaction
with an already-running program. For *starting fresh commands* in
a new pane, prefer `tab new --cmd` or `pane split --cmd` instead.

    danterm pane input --pane "$PANE_ID" -- C-c
    danterm pane input --pane "$PANE_ID" -- "y" Enter

### Find a pane id

There is no `pane ls`. Parse `danterm ls`:

    danterm ls | jq -r '.panes[] | "\(.id)\t\(.title // "")\t\(.cwd // "")"'

`ls` returns `{groups, panes, selectedTabId}`. `panes[]` is the
flat list; `groups[].tabs[].rootNode` is the split tree per tab.

### Todos

    danterm todo list                  # {todos: [{id, text, isDone}, ...]}
    danterm todo add "write the failing test first"  # {todo: {...}}
    danterm todo done <todo-id>
    danterm todo delete <todo-id>
    danterm todo clear-completed

### Theme

    danterm theme set Dracula
    danterm theme set --clear          # revert to config default

## pane input token grammar

`pane input` takes tmux-style tokens after `--`. **Each shell arg
is one token, sent as a separate event** -- there is no implicit
space-joining. Quote a single arg when spaces or newlines must be
preserved.

- Bare words (`"ls"`, `"cargo"`) are typed as text.
- Named keys are key presses: `Enter`, `Tab`, `BSpace`, `Escape`,
  `Up`, `Down`, `Left`, `Right`, `Home`, `End`, `PgUp`, `PgDn`,
  `Delete`, `F1`..`F12`.
- `C-<x>` is Ctrl-x, `M-<x>` is Alt-x (e.g. `C-c`, `C-d`, `M-b`).
- `--literal` disables key parsing -- every token after `--` is
  emitted as text. Each token is still a separate event; pass one
  quoted argument if you need spaces inside the literal text.

Example: run a command and press enter (one quoted arg + one key).

    danterm pane input --pane "$PANE_ID" -- "ls -la" Enter

Example: paste literal text containing a word that would otherwise
be parsed as a key.

    danterm pane input --pane "$PANE_ID" --literal -- "Type Enter to continue"

## CLI stdout shapes

Only these subcommands print to stdout. Pipe to `jq` accordingly.
Everything else (e.g. `tab rename`, `pane input`, `pane focus`,
`theme set`, `todo done`, `todo delete`, `todo clear-completed`)
prints nothing on success and exits 0.

| Command | Stdout |
|---|---|
| `ls` | JSON: `{groups, panes, selectedTabId}` |
| `tab new` | JSON: `{tab: {...}, panes: [{id}], group?: {id, name}}` |
| `pane split` | JSON: `{pane: {id}}` |
| `todo list` | JSON: `{todos: [{id, text, isDone}, ...]}` |
| `todo add` | JSON: `{todo: {id, text, isDone}}` |
| `pane read` | Raw text (the requested pane content; NOT JSON) |

## Rules for agents

- **Never `pane input` into your own pane** (`$DANTERM_PANE`)
  without an explicit user request -- you would be typing into
  your own input stream.
- Prefer `tab new --cmd` / `pane split --cmd` over the
  split-then-`pane input` pattern. `--cmd` launches the program
  directly and avoids racing the shell prompt.
- When a recipe needs a pane id, run `ls` first; do not guess UUIDs.
- Errors print to stderr as `danterm: <message>` and exit non-zero;
  surface them rather than retrying blindly.
- macOS only. If `danterm` is not on PATH, the user is not inside
  DanTerm; stop.
```

## Critical files

- New: `/Users/dan/world/my-apps/danterm/integrations/danterm/SKILL.md`
- Edited: `/Users/dan/world/my-apps/danterm/flake.nix` -- add
  `danterm-agent-skill` to `overlays.default` and expose it in the
  `packages` output for `hookSystems`. Pattern mirrors
  `danterm-claude-notify-osc777` (lines 16-21, 28-34) but uses a
  plain `stdenvNoCC.mkDerivation` whose `src` is
  `./integrations/danterm` and whose `installPhase` copies the
  directory to `$out/share/danterm-agent-skill/`.
- Edited: `/Users/dan/world/my-apps/danterm/README.md` -- insert
  the "Agent Skill" section (drafted above) between the existing
  "Claude Code Integration" and "OpenAI Codex Integration" sections.

## Verification

Documentation + packaging change. End-to-end check, run after the
IPC redesign has landed:

1. `just build-run` (or use the installed DanTerm).
2. `nix build .#danterm-agent-skill` -- confirm
   `result/share/danterm-agent-skill/SKILL.md` exists and matches
   `integrations/danterm/SKILL.md` byte-for-byte.
3. `nix flake check` -- no regressions in the existing checks.
4. **Claude Code discovery.** Symlink per the README's non-Nix
   path, run `claude /skills`, confirm `danterm` is listed with
   the description preview.
5. **Codex discovery.** Symlink under `~/.agents/skills/danterm`,
   run `codex /skills` (or the equivalent listing command),
   confirm `danterm` is listed.
6. **Trigger check (Claude Code).** From a DanTerm pane, ask
   Claude Code "rename this tab to scratch" and confirm it runs
   `danterm tab rename scratch` without further prompting
   (verifies description triggers + `allowed-tools: Bash(danterm *)`
   pre-approval).
7. **Recipe spot-check.** Run
   `NEW=$(danterm pane split -h --cmd 'echo hi; sleep 60' | jq -r '.pane.id')`
   -- a new pane should appear **to the right** (sanity check for
   the `-h` = side-by-side documentation), print `hi`, and stay
   open. Then run with `-v` and confirm the pane appears **below**.
8. **--literal sanity check.** Run
   `danterm pane input --pane "$NEW" --literal -- "press Enter please"`
   -- the literal string (including the word `Enter`) should
   appear in the pane, with no actual Enter key pressed.

## Implementation notes

- Expanded the generated skill's todo recipe to include `todo edit` and
  `todo open`, which are present in `CLIParser.swift` and `cli/main.swift` but
  were omitted from the draft skill text.
- Corrected the README's Codex install path to `~/.codex/skills/danterm` based
  on the local `skill-installer` skill, whose install target is
  `$CODEX_HOME/skills` with a default of `~/.codex/skills`.
- Removed `codex skills list` from the README verification instructions because
  the installed Codex CLI does not expose a `skills list` subcommand.
- Replaced the README's live-reload claim with conservative reload guidance
  because the local `skill-installer` skill tells users to restart Codex after
  installing a skill.
