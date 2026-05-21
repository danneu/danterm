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

## Targeting rule

Assume the user may keep using DanTerm while you run commands. Do not rely on
the app's currently focused group, tab, or pane.

- `$DANTERM=1` means the agent originated inside a DanTerm pane.
- `$DANTERM_PANE` is the originating pane id. Use it only as input to
  `danterm pane info --pane "$DANTERM_PANE"` when deriving live ids.
- `danterm` may still work outside DanTerm if the app is running, but agents
  must use explicit ids for mutation commands.
- If `$DANTERM_PANE` is absent, start with `danterm ls` and select targets only
  from explicit user-provided criteria visible in the JSON: id, exact group
  name, exact tab `customTitle`, exact pane title, or cwd. If the criteria do
  not produce one unique target, ask the user.
- Never target by `selectedTabId`, current focus, list order, display title, or
  a guessed id.

For agent commands:

- `tab new`: always pass `--group <group-id>`; prefer `--background`
  unless the user asked to switch to the new tab.
- `tab rename`: always pass `--tab <tab-id>`.
- `pane split`: always pass `--pane <pane-id>`; prefer `--background`
  unless the user asked to focus the new pane.
- `pane input`, `theme set`, and todos: always pass `--pane <pane-id>`.
- `pane focus` and `pane read` already require explicit pane ids; keep them
  explicit.

## Context env vars

DanTerm sets these per pane:

- `DANTERM` -- set to `1` when the process originated inside DanTerm.
- `DANTERM_PANE` -- caller's pane id. Humans may omit explicit targets inside
  DanTerm; agents should use it only to derive live ids.
- `DANTERM_SOCK` -- control socket path. Rarely needed; the CLI resolves it.

If these are absent, the user may be outside DanTerm. You may still use
`danterm` only with explicit ids derived from `danterm ls` and unique
user-provided criteria.

## Derive targets

Inside DanTerm, derive the originating pane, tab, and group:

    INFO=$(danterm pane info --pane "$DANTERM_PANE")
    PANE_ID=$(jq -r '.pane.id' <<<"$INFO")
    TAB_ID=$(jq -r '.tab.id' <<<"$INFO")
    GROUP_ID=$(jq -r '.group.id' <<<"$INFO")

Outside DanTerm, do not use implicit app state:

    danterm ls

Filter only by explicit user-provided criteria visible in the JSON, and require
exactly one matching pane, tab, or group before running any mutation command.

## When to reach for this skill

| User says | Command |
|---|---|
| "rename this tab to X" / "label this tab" | `tab rename --tab <tab-id>` |
| "open a new tab" / "...and run X in it" | `tab new --group <group-id>` with optional `--cmd` |
| "split the pane" / "...and run X in it" | `pane split --pane <pane-id>` with optional `--cmd` |
| "what's the build doing in the other pane?" | `pane read --pane <pane-id>` |
| "type X into pane <id>" / "send Ctrl-C to..." | `pane input --pane <pane-id>` |
| "what tabs/panes are open?" | `ls` |
| "which tab/group contains this pane?" | `pane info --pane <pane-id>` |
| "switch the theme to X" | `theme set --pane <pane-id>` |
| "add/check off/edit a todo" | `todo ... --pane <pane-id>` |

## Recipes

### Rename or clear a tab

    danterm tab rename --tab "$TAB_ID" "fix scrollbar math"
    danterm tab rename --tab "$TAB_ID" --clear

### Open a new tab and optionally run a command in it

    danterm tab new --group "$GROUP_ID"
    danterm tab new --group "$GROUP_ID" --cmd 'vim notes.md' --title notes
    danterm tab new --group "$GROUP_ID" --cmd 'cargo test --workspace' --cwd ~/proj --title tests
    danterm tab new --group "$GROUP_ID" --background --cmd 'just test' --title tests

`--cmd` launches the program directly via libghostty, not by typing into a
shell prompt, so it does not race shell startup. The pane stays open after the
command exits.

Use `--background` to keep the user's current tab focused.

### Split a pane and run a command in the new one

Orientation:

- `-h` = horizontal split = side by side. The new pane opens to the right.
- `-v` = vertical split = stacked. The new pane opens below.

Prefer `--cmd` over splitting and then sending keys; it avoids the
shell-prompt race.

    danterm pane split --pane "$PANE_ID" -h --cmd 'just test' --title tests
    danterm pane split --pane "$PANE_ID" -h --background --cmd 'just test' --title tests

Use `--background` to leave the caller's pane focused inside its tab.

To capture the new pane id for later:

    NEW=$(danterm pane split --pane "$PANE_ID" -v --cmd 'just test' | jq -r '.pane.id')

### Read another pane's output

`pane read` prints raw text, not JSON. Without `--lines`, it returns the
visible viewport. With `--lines N`, it returns the last N lines of scrollback.

    danterm pane read --pane "$PANE_ID"
    danterm pane read --pane "$PANE_ID" --lines 200

### Send keys to another pane

Use this for interrupts, replies to prompts, or scripted interaction with an
already-running program. For starting fresh commands in a new pane, prefer
`tab new --group <group-id> --cmd` or `pane split --pane <pane-id> --cmd`.

    danterm pane input --pane "$PANE_ID" -- C-c
    danterm pane input --pane "$PANE_ID" -- "y" Enter

### Find ids

For the originating pane inside DanTerm:

    danterm pane info --pane "$DANTERM_PANE"

For broader discovery:

    danterm ls | jq -r '.panes[] | "\(.id)\t\(.title // "")\t\(.cwd // "")"'

`ls` returns `{groups, panes, selectedTabId}`. `panes[]` is the flat list;
`groups[].tabs[].rootNode` is the split tree per tab. Treat `selectedTabId` as
display state, not as a targeting source.

### Todos

    danterm todo list --pane "$PANE_ID"
    ID=$(danterm todo add --pane "$PANE_ID" "write the failing test first" | jq -r '.todo.id')
    danterm todo edit --pane "$PANE_ID" "$ID" "write the failing test first, then implement"
    danterm todo done --pane "$PANE_ID" "$ID"
    danterm todo open --pane "$PANE_ID" "$ID"
    danterm todo delete --pane "$PANE_ID" "$ID"
    danterm todo clear-completed --pane "$PANE_ID"

### Theme

    danterm theme set --pane "$PANE_ID" Dracula
    danterm theme set --pane "$PANE_ID" --clear

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
| `pane info --pane <pane-id>` | JSON: `{pane: {id, title, cwd}, tab: {id, title, groupId}, group: {id, name}}` |
| `tab new --group <group-id>` | JSON: `{tab: {...}, panes: [{id}], group?: {id, name}}` |
| `pane split --pane <pane-id>` | JSON: `{pane: {id}}` |
| `todo list --pane <pane-id>` | JSON: `{todos: [{id, text, isDone}, ...]}` |
| `todo add --pane <pane-id>` | JSON: `{todo: {id, text, isDone}}` |
| `pane read --pane <pane-id>` | Raw text from the requested pane, not JSON |

## Rules for agents

- Never `pane input` into your own pane (`$DANTERM_PANE`) without an explicit
  user request; you would be typing into your own input stream.
- Prefer `tab new --group <group-id> --cmd` and
  `pane split --pane <pane-id> --cmd` over the
  split-then-`pane input` pattern. `--cmd` launches the program directly and
  avoids racing the shell prompt.
- Prefer `--background` on `tab new` and `pane split` for autonomous work the
  user did not just ask for. The user may be focused on another tab or pane;
  stealing focus is disruptive. Omit `--background` only when the user
  explicitly asked you to switch to the new tab or pane.
- When a recipe needs an id, derive it from `pane info` or `ls` using the
  targeting rule above; do not guess UUIDs.
- Errors print to stderr as `danterm: <message>` and exit non-zero. Surface
  them rather than retrying blindly.
- macOS only. If `danterm` is not on PATH, stop.
