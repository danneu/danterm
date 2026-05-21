---
name: danterm
description: >-
  Drive the DanTerm terminal from the shell. Use when the user asks to rename this tab, open or split panes, launch commands in new tabs or panes, read output from another pane, send keys into another pane, switch the theme, or work with DanTerm todos. DanTerm is a macOS-only terminal; only applies when the `danterm` command is on PATH.
allowed-tools: Bash(danterm *)
---

# danterm CLI

`danterm` is the shell client for the DanTerm terminal. Run
`danterm help` for the authoritative command list. The recipes below cover the
cases agents hit in practice.

## Context env vars

DanTerm sets these per pane:

- `DANTERM_PANE` -- caller's pane id. Commands default to this pane when
  `--pane` is omitted.
- `DANTERM_TAB` -- caller's tab id. `tab rename` falls back to this when
  `DANTERM_PANE` is unavailable.
- `DANTERM_SOCK` -- control socket path. Rarely needed; the CLI resolves it.

If none of these are set, the user is not inside DanTerm; do not use this
skill.

## When to reach for this skill

| User says | Command |
|---|---|
| "rename this tab to X" / "label this tab" | `tab rename` |
| "open a new tab" / "...and run X in it" | `tab new` with optional `--cmd` |
| "split the pane" / "...and run X in it" | `pane split` with optional `--cmd` |
| "what's the build doing in the other pane?" | `pane read` |
| "type X into pane <id>" / "send Ctrl-C to..." | `pane input` |
| "what tabs/panes are open?" | `ls` |
| "switch the theme to X" | `theme set` |
| "add/check off/edit a todo" | `todo` |

## Recipes

### Rename or clear the current tab

    danterm tab rename "fix scrollbar math"
    danterm tab rename --clear

### Open a new tab and optionally run a command in it

    danterm tab new
    danterm tab new --group dev
    danterm tab new --cmd 'vim notes.md' --title notes
    danterm tab new --cmd 'cargo test --workspace' --cwd ~/proj --title tests

`--cmd` launches the program directly via libghostty, not by typing into a
shell prompt, so it does not race shell startup. The pane stays open after the
command exits.

### Split the current pane and run a command in the new one

Orientation:

- `-h` = horizontal split = side by side. The new pane opens to the right.
- `-v` = vertical split = stacked. The new pane opens below.

Prefer `--cmd` over splitting and then sending keys; it avoids the
shell-prompt race.

    danterm pane split -h --cmd 'just test' --title tests

To capture the new pane id for later:

    NEW=$(danterm pane split -v --cmd 'just test' | jq -r '.pane.id')

### Read another pane's output

`pane read` prints raw text, not JSON. Without `--lines`, it returns the
visible viewport. With `--lines N`, it returns the last N lines of scrollback.

    danterm pane read --pane "$PANE_ID"
    danterm pane read --pane "$PANE_ID" --lines 200

### Send keys to another pane

Use this for interrupts, replies to prompts, or scripted interaction with an
already-running program. For starting fresh commands in a new pane, prefer
`tab new --cmd` or `pane split --cmd`.

    danterm pane input --pane "$PANE_ID" -- C-c
    danterm pane input --pane "$PANE_ID" -- "y" Enter

### Find a pane id

There is no `pane ls`. Parse `danterm ls`:

    danterm ls | jq -r '.panes[] | "\(.id)\t\(.title // "")\t\(.cwd // "")"'

`ls` returns `{groups, panes, selectedTabId}`. `panes[]` is the flat list;
`groups[].tabs[].rootNode` is the split tree per tab.

### Todos

    danterm todo list
    ID=$(danterm todo add "write the failing test first" | jq -r '.todo.id')
    danterm todo edit "$ID" "write the failing test first, then implement"
    danterm todo done "$ID"
    danterm todo open "$ID"
    danterm todo delete "$ID"
    danterm todo clear-completed

### Theme

    danterm theme set Dracula
    danterm theme set --clear

## pane input token grammar

`pane input` takes tmux-style tokens after `--`. Each shell arg is one token,
sent as a separate event; there is no implicit space-joining. Quote a single
arg when spaces or newlines must be preserved.

- Bare words (`"ls"`, `"cargo"`) are typed as text.
- Named keys are key presses: `Enter`, `Tab`, `BSpace`, `Escape`, `Up`,
  `Down`, `Left`, `Right`, `Home`, `End`, `PgUp`, `PgDn`, `Delete`, `F1`
  through `F12`.
- `C-<x>` is Ctrl-x and `M-<x>` is Alt-x, such as `C-c`, `C-d`, and `M-b`.
- `--literal` disables key parsing. Every token after `--` is emitted as text.
  Each token is still a separate event; pass one quoted argument if you need
  spaces inside the literal text.

Example: run a command and press enter:

    danterm pane input --pane "$PANE_ID" -- "ls -la" Enter

Example: paste literal text containing a word that would otherwise be parsed as
a key:

    danterm pane input --pane "$PANE_ID" --literal -- "Type Enter to continue"

## CLI stdout shapes

Only these subcommands print to stdout. Pipe to `jq` accordingly. Everything
else prints nothing on success and exits 0.

| Command | Stdout |
|---|---|
| `ls` | JSON: `{groups, panes, selectedTabId}` |
| `tab new` | JSON: `{tab: {...}, panes: [{id}], group?: {id, name}}` |
| `pane split` | JSON: `{pane: {id}}` |
| `todo list` | JSON: `{todos: [{id, text, isDone}, ...]}` |
| `todo add` | JSON: `{todo: {id, text, isDone}}` |
| `pane read` | Raw text from the requested pane, not JSON |

## Rules for agents

- Never `pane input` into your own pane (`$DANTERM_PANE`) without an explicit
  user request; you would be typing into your own input stream.
- Prefer `tab new --cmd` and `pane split --cmd` over the
  split-then-`pane input` pattern. `--cmd` launches the program directly and
  avoids racing the shell prompt.
- When a recipe needs a pane id, run `ls` first; do not guess UUIDs.
- Errors print to stderr as `danterm: <message>` and exit non-zero. Surface
  them rather than retrying blindly.
- macOS only. If `danterm` is not on PATH, the user is not inside DanTerm;
  stop.
