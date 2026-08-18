---
name: danterm
description: >-
  Drive the DanTerm terminal from the shell. Use when the user asks to rename or close this tab, open or split panes, launch commands in new tabs or panes, inspect live key focus, read output or dump or follow a flight recording from another pane, send keys into another pane, switch the theme, quit a development instance it launched, or work with DanTerm todos. DanTerm is a macOS-only terminal; only applies when the `danterm` command is on PATH.
allowed-tools: Bash(danterm *)
---

# danterm CLI

`danterm` is the shell client for the DanTerm terminal. Run
`danterm help` for the authoritative command list. The recipes below cover the
cases agents hit in practice. Run `danterm skill` to print this exact,
version-matched file without installing the skill or starting DanTerm.

## CLI API

Keep this section synced with `danterm help` and the parser in
`lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift`.

Every IPC command accepts one explicit target before the command name:
`--socket <path>` for a local instance or `--tcp <host:port>` for a tailnet
listener. `--socket` overrides `DANTERM_SOCK` and identity-derived socket
lookup. TCP has no environment-variable form, and the two flags are mutually
exclusive.

`quit` inverts the ambient-target rule: it requires either explicit flag and
refuses both `DANTERM_SOCK` and identity lookup. A tailnet server refuses the
request because remote callers have no authority to end the app.

The local `skill` and `doctor` commands do not accept a target flag or inspect
pane targeting. `doctor` queries the matching running app for macOS permission
state and skips those rows when the app is unavailable.

    danterm --tcp 100.99.4.1:24863 ls

    danterm ls
    danterm focus
    danterm quit
    danterm group new --name <name> [--cmd <s>] [--cwd <p>] [--title <s>] [--background] [--foreground]
    danterm group rename --group <group-id> <name>
    danterm group close --group <group-id> [--move-tabs]
    danterm tab new (--group <group-id> | --after-tab <tab-id>) [--cmd <s>] [--cwd <p>] [--title <s>] [--background] [--foreground] [--after-selected | --at-group-end]
    danterm tab rename --tab <tab-id> <name>|--clear
    danterm tab close --tab <tab-id>
    danterm pane focus <pane-id>
    danterm pane info --pane <pane-id>
    danterm pane split --pane <pane-id> -h|-v [--cmd <s>] [--cwd <p>] [--title <s>] [--background] [--foreground]
    danterm pane close --pane <pane-id>
    danterm pane input --pane <pane-id> [--literal] -- <token>...
    danterm pane read --pane <pane-id> [--lines <n>]
    danterm pane zoom --pane <pane-id> on|off|toggle
    danterm pane resize --pane <pane-id> <columns>x<rows>|--fit
    danterm pane rows --pane <pane-id>
    danterm pane tape --pane <pane-id> [--follow] [--from-now | --from-cursor <cursor-json>] [--raw | --reconstructible] [--format replay|inspect]
    danterm pane snapshot --pane <pane-id>
    danterm theme set --pane <pane-id> <name>|--clear
    danterm agent attach --pane <pane-id> --kind <kind> --id <session-id>
    danterm agent activity --pane <pane-id> --kind <kind> --id <session-id> --state <working|waiting|idle>
    danterm agent detach --pane <pane-id> --kind <kind> --id <session-id>
    danterm skill
    danterm doctor
    danterm todo list (--pane <pane-id> | --tab <tab-id>)
    danterm todo add (--pane <pane-id> | --tab <tab-id>) <text>
    danterm todo edit (--pane <pane-id> | --tab <tab-id>) <todo-id> <text>
    danterm todo done (--pane <pane-id> | --tab <tab-id>) <todo-id>
    danterm todo open (--pane <pane-id> | --tab <tab-id>) <todo-id>
    danterm todo delete (--pane <pane-id> | --tab <tab-id>) <todo-id>
    danterm todo clear-completed (--pane <pane-id> | --tab <tab-id>)

CLI defaults are agent-safe: `tab new` opens in the background at the target
group end, `group new` opens in the background, and `pane split` opens in the
background. The interactive app UI keeps its own defaults. Use `--foreground`
only when the user asked for focus: for `tab new` and `group new`, it selects
the new tab; for `pane split`, it focuses the new pane within its tab without
selecting that tab.

`tab new` position flags are mutually exclusive:

- No position flag: append at the end of the target group.
- `--after-selected`: insert after the currently selected tab in the target
  group, falling back to the end of that group.
- `--at-group-end`: explicit form of the default append behavior.
- `--after-tab <tab-id>`: insert immediately after the referenced tab. It is
  the target anchor and cannot be combined with `--group`.

## Targeting rule

Assume the user may keep using DanTerm while you run commands. Do not rely on
the app's currently focused group, tab, or pane.

- `$DANTERM=1` means the agent originated inside a DanTerm pane.
- `$DANTERM_PANE` is the originating pane id. Use it only as input to
  `danterm pane info --pane "$DANTERM_PANE"` when deriving live ids.
- `danterm` may still work outside DanTerm if the app is running, but agents
  must use explicit ids for mutation commands.
- When driving an isolated source-tree instance, agents must also pass
  `--socket <path>` before every command. Do not export `DANTERM_SOCK`: the
  target should remain visible at each call site.
- If `$DANTERM_PANE` is absent, start with `danterm ls` and select targets only
  from explicit user-provided criteria visible in the JSON: id, exact group
  name, exact tab `customTitle`, exact pane title, or cwd. If the criteria do
  not produce one unique target, ask the user.
- Never target by `selectedTabId`, current focus, list order, display title, or
  a guessed id.

For agent commands:

- `tab new`: always pass `--group <group-id>` or an explicit
  `--after-tab <tab-id>` anchor. The default opens in the background at the
  target group end. Pass `--foreground` only when the user asked to switch to
  the new tab. Pass `--after-tab <tab-id>` or `--after-selected` only when the
  user gave that placement anchor.
- `group new`: `--name <name>` is required and takes no target, because a group
  anchors to nothing. The default opens in the background. Pass `--foreground`
  only when the user asked to switch to the new group's tab.
- `group rename`: always pass `--group <group-id>`. There is no `--clear`: a
  group always has a name. A name that is only whitespace is refused.
- `group close`: always pass `--group <group-id>`. It closes the group's tabs
  with it. Pass `--move-tabs` when the user wants those tabs kept.
- `tab rename`: always pass `--tab <tab-id>`.
- `tab close`: always pass `--tab <tab-id>`.
- `pane split`: always pass `--pane <pane-id>`. The default opens in the
  background. Pass `--foreground` only when the user asked to focus the new pane
  within its tab.
- `pane close`: always pass `--pane <pane-id>`.
- `pane input` and `theme set`: always pass `--pane <pane-id>`.
- Todos: always pass exactly one explicit owner, `--pane <pane-id>` or
  `--tab <tab-id>`.
- `agent attach`, `agent activity`, and `agent detach`: always pass
  `--pane <pane-id>`. The bundled hooks pass `$DANTERM_PANE` explicitly.
- `pane focus`, `pane info`, `pane read`, `pane rows`, `pane zoom`,
  `pane resize`, `pane tape`, and `pane snapshot`: always name the pane
  explicitly.
- `quit`: for a slot you launched, always pass `--socket <path>` naming it. The
  CLI also accepts an explicit TCP target so callers can observe the server's
  remote-authority refusal. Never aim a local quit at the user's DanTerm.

## Context env vars

DanTerm sets these per pane:

- `DANTERM` -- set to `1` when the process originated inside DanTerm.
- `DANTERM_PANE` -- caller's pane id. Pass it explicitly when the caller pane is
  the intended target, or use it to derive other live ids.
- `DANTERM_SOCK` -- control socket path. Rarely needed; the CLI resolves it.
  Inside DanTerm, an absent or empty value means that process does not own a
  control socket, so the CLI reports that DanTerm is not running instead of
  falling back to another same-identity instance. `--socket <path>` overrides
  this value.

If these are absent, the user may be outside DanTerm. You may still use
`danterm` only with explicit ids derived from `danterm ls` and unique
user-provided criteria.

## Env vars you set

DanTerm never sets this one; the caller does.

- `DANTERM_SOCKET_TIMEOUT` -- seconds the CLI waits on the control socket,
  default 5. Set it below the default when you expect an unresponsive instance
  and do not want to wait, or above it when a busy instance is answering slowly.
  It must be a positive number: any other value fails the command with
  `danterm: DANTERM_SOCKET_TIMEOUT must be a positive number of seconds: <value>`
  rather than falling back to the default. It never cuts a `pane tape` capture
  short: a tape connection carries no receive timeout at all, because a followed
  stream is idle whenever its pane is.

## Isolated source-tree instances

In a fresh linked worktree, run `just provision-worktree` before the first
build. It repeatably links the primary checkout's reference sources into the
worktree without changing the primary checkout.

When an agent needs its own development app, run `just launch-slot` from the
source tree instead of `just replace-dev`. The launcher builds without replacing
or focusing the user's slot-zero app, claims a free slot from 1 through 8, starts
the app detached, waits until that app's control socket accepts connections,
prints one JSON handle on stdout, and exits. Build output goes to stderr, so the
handle is the last stdout line, and the socket it names is ready to drive. Read
it and target its `socketPath` explicitly:

    SLOT_SOCKET="$(just launch-slot | tail -1 | jq -er '.socketPath')"
    danterm --socket "$SLOT_SOCKET" ls

The handle also contains `slot`, `bundleId`, and `pid`; `pid` is the detached
app. The app writes its own stdout and stderr to
`~/Library/Caches/com.danneu.danterm-dev-slots/logs/slot-<n>.log`, not to your
terminal. The default is fresh, background, and notification-prompt-free. Use
`just launch-slot-prime` only when a human is ready to grant one slot's
notification permission; it launches the same way and prints the same handle,
and only lets the app activate and prompt. Use
`just launch-slot-optimized` for an optimized build. Pool exhaustion exits with
status 75 and starts no process.

The eight slots are shared by every checkout on the machine, so agents in
separate worktrees launch beside each other and must give their slots back. Run
`just stop-slot <n>` on the slot from your handle when you are done with it:

    just slots                 # every slot as JSON, with the checkout holding it
    just stop-slot 3           # kill slot 3's app and return it to the pool
    just stop-slots            # the user's broom: empties the pool, other agents included

`danterm --socket "$SLOT_SOCKET" quit` is the graceful alternative to
`just stop-slot <n>`: it exits the app through the normal shutdown path instead
of killing it, and the slot frees itself because occupancy comes from the lock
the dead process held.

A busy slot reports `state`, `checkout`, `pid`, `bundleId`, and `socketPath`; a
slot still building reports only `state` and `checkout`, and refuses to be
stopped, because the process holding it is the launcher, not an app. Occupancy
comes from the slot's lock, so an app that died leaves its slot free however it
went.

Both stop commands print the JSON array of the occupants they killed and exit 0,
including when there was nothing to kill: stopping a slot that is already free is
a success, so an agent can always release its slot without checking first. They
exit 1 only when a slot could not be freed, such as one still building.

## Shell integration capability

DanTerm ships opt-in zsh, Bash, and fish integrations at
`Contents/Resources/shell-integration/danterm.{zsh,bash,fish}`. They report
command boundaries, cwd, and remote-session metadata to the owning pane. Local
integration is enabled by `DANTERM=1`; the bundled ssh/mosh wrappers forward
`LC_DANTERM=1` so an installed remote integration can report host metadata.

## Derive targets

Inside DanTerm, derive the originating pane, tab, and group:

    INFO=$(danterm pane info --pane "$DANTERM_PANE")
    PANE_ID=$(jq -r '.pane.id' <<<"$INFO")
    TAB_ID=$(jq -r '.tab.id' <<<"$INFO")
    GROUP_ID=$(jq -r '.group.id' <<<"$INFO")

Each pane projects its process phase and four typed current lifecycle objects:

    {
      "pane": {
        "processPhase": "spawning" | "running",
        "integration": {"state": "neverReported" | "ready"},
        "command": {"state": "idle"} | {"state": "running", "text": "..."},
        "connection": {"state": "local"} |
          {"state": "remote", "identity": null | {"user": "...", "host": "..."}},
        "agent": {"state": "none"} |
          {"state": "attached", "session": {"kind": "...", "sessionId": "..."},
           "activity": null | "working" | "waiting" | "idle"}
      }
    }

These are current lifecycles, not command history. They appear in `pane info` and
under every pane returned by `ls`, beside fields such as `title` and `cwd`;
they are not persisted in init files.

Every command names its target. Outside DanTerm, begin by discovering live ids:

    danterm ls

Filter only by explicit user-provided criteria visible in the JSON, and require
exactly one matching pane, tab, or group before running any mutation command.

## When to reach for this skill

| User says | Command |
|---|---|
| "make a new group" / "...and run X in it" | `group new --name <name>` with optional `--cmd` |
| "rename group X to Y" | `group rename --group <group-id>` |
| "close group X" / "...but keep its tabs" | `group close --group <group-id>` / `... --move-tabs` |
| "rename this tab to X" / "label this tab" | `tab rename --tab <tab-id>` |
| "close this tab" / "close tab X" | `tab close --tab <tab-id>` |
| "open a new tab" / "...and run X in it" | `tab new --group <group-id>` with optional `--cmd` / position flags |
| "split the pane" / "...and run X in it" | `pane split --pane <pane-id>` with optional `--cmd` |
| "close pane X" | `pane close --pane <pane-id>` |
| "what's the build doing in the other pane?" | `pane read --pane <pane-id>` |
| "make this pane fill the tab" / "restore the split" | `pane zoom --pane <pane-id> on` / `pane zoom --pane <pane-id> off` |
| "run this pane at 60 by 20" / "let it fit the window again" | `pane resize --pane <pane-id> 60x20` / `pane resize --pane <pane-id> --fit` |
| "why is the pane's text laid out wrong after a resize" | `pane rows --pane <pane-id>` |
| "dump the pane's flight recording" | `pane tape --pane <pane-id>` |
| "watch the pane's flight recording live" | `pane tape --pane <pane-id> --follow` |
| "get the pane's exact terminal state" | `pane snapshot --pane <pane-id>` |
| "type X into pane <id>" / "send Ctrl-C to..." | `pane input --pane <pane-id>` |
| "what tabs/panes are open?" | `ls` |
| "which control owns key focus?" | `focus` |
| "which tab/group contains this pane?" | `pane info --pane <pane-id>` |
| "switch the theme to X" | `theme set --pane <pane-id>` |
| "add/check off/edit a todo" | `todo ... --pane <pane-id>` or `todo ... --tab <tab-id>` |
| "quit the dev app I launched" / "shut down slot 3" | `--socket <slot-socket> quit` |
| "check DanTerm integration health" | `doctor` |
| "show DanTerm's agent instructions" | `skill` |

## Recipes

`group new`, `tab new`, and `pane split` return success only after the new
pane's process is running. Creation or launch failure exits non-zero. If the
CLI instead reports `DanTerm is not responding`, the outcome is indeterminate:
the process can still start after the receive timeout.

### Create a group

    danterm group new --name Scratch
    danterm group new --name Builds --cmd 'just test' --title tests

A group always contains at least one tab, so `group new` creates that first tab
too and the launch flags apply to it. The reply names both the new group and the
new tab. By default the user's current tab stays focused.

### Rename a group

    danterm group rename --group "$GROUP_ID" "release work"

Find the group id in `danterm ls`, which lists every group as
`{id, name, isCollapsed, tabs}`. There is no `group list`.

### Close a group

    danterm group close --group "$GROUP_ID"
    danterm group close --group "$GROUP_ID" --move-tabs

The default closes the group's tabs with it. `--move-tabs` moves them into the
adjacent group first. Two closes are refused: the last group, and the group
holding every tab when `--move-tabs` is absent. Quitting is `quit`'s job, never
a side effect of a close.

### Quit an instance you launched

    danterm --socket "$SLOT_SOCKET" quit

This is the graceful exit for a slot app you started with `just launch-slot`.
It ends the app the way Cmd-Q does, so the final recovery checkpoint is written
and the session lock file is removed -- unlike `just stop-slot <n>`, which sends
`SIGKILL` and skips all of it. Keep `stop-slot` for a slot that is wedged or
still building, where nothing can answer a request.

Two rules make the verb safe, and both are enforced:

- The CLI refuses `quit` without an explicit `--socket`, so it never resolves a
  target from `DANTERM_SOCK` or from identity lookup.
- The app refuses `quit` unless it holds a launcher pool slot, 1 through 8. The
  user's `DanTerm.app`, `DanTerm Dev.app`, and anything outside the scheme all
  answer with an error and keep running.

Quit is not confirmed. Passing the instance's socket is the authorization, so it
ignores any open confirmation panel and any uncompleted todos. A quit the app
honored exits 0 -- the closed socket is the proof it worked -- and a refused one
exits non-zero and prints the refusal.

### Rename or clear a tab

    danterm tab rename --tab "$TAB_ID" "fix scrollbar math"
    danterm tab rename --tab "$TAB_ID" --clear

### Close a tab

    danterm tab close --tab "$TAB_ID"

Closing the only remaining tab is refused. Quitting is `quit`'s job, never a
side effect of a close.

### Open a new tab and optionally run a command in it

    danterm tab new --group "$GROUP_ID"
    danterm tab new --group "$GROUP_ID" --cmd 'vim notes.md' --title notes
    danterm tab new --group "$GROUP_ID" --cmd 'cargo test --workspace' --cwd ~/proj --title tests
    danterm tab new --group "$GROUP_ID" --foreground --cmd 'vim .' --title work
    danterm tab new --group "$GROUP_ID" --at-group-end --cmd 'just test' --title tests
    danterm tab new --after-tab "$TAB_ID" --cmd 'just test' --title tests

`--cmd` runs inside your login shell, so shell config is sourced, PATH matches
your interactive panes, and shell integration reports cwd. The pane returns to
a shell prompt when the command exits.

By default, the user's current tab stays focused. Use `--foreground` only when
the user asked to switch to the new tab.

Use `--after-tab <tab-id>` when the user names an exact tab to place the new tab
after; this is an explicit target and can work without `$DANTERM_PANE`. Use
`--after-selected` with `--group <group-id>` only when the user explicitly
wants selected-tab-relative placement in that named group.

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

### Split a pane and run a command in the new one

Orientation:

- `-h` = horizontal split = side by side. The new pane opens to the right.
- `-v` = vertical split = stacked. The new pane opens below.

Splitting and then using `pane input` is ordered safely even while the process
is still spawning. Prefer `--cmd` when the new program can flush terminal input
at startup, because that program can discard bytes typed before it starts.

    danterm pane split --pane "$PANE_ID" -h --cmd 'just test' --title tests
    danterm pane split --pane "$PANE_ID" -h --foreground --cmd 'just test' --title tests

By default, the caller's pane stays focused inside its tab. Use `--foreground`
only when the user asked to focus the new pane within that tab.

To capture the new pane id for later:

    NEW=$(danterm pane split --pane "$PANE_ID" -v --cmd 'just test' | jq -r '.pane.id')

To navigate to a new pane that was split in another tab:

    NEW=$(danterm pane split --pane "$PANE_ID" -v --cmd 'just test' | jq -r '.pane.id')
    danterm pane focus "$NEW"

### Close a pane

    danterm pane close --pane "$PANE_ID"

Closing a pane in a split promotes its sibling. Closing a tab's only pane also
closes that tab. Closing the only pane of the only tab is refused; quitting is
`quit`'s job, never a side effect of a close. The command does not show the
GUI's todo confirmation because the explicit pane id authorizes the close.

### Read another pane's output

`pane read` prints raw text, not JSON. Without `--lines`, it returns the
visible viewport. With `--lines N`, it returns the last N lines of scrollback.

    danterm pane read --pane "$PANE_ID"
    danterm pane read --pane "$PANE_ID" --lines 200

### Zoom a pane

`pane zoom` drives the same zoom the Pane menu and the pane toolbar button
drive: the tab renders only the target pane, so the pane's width and height
change without the window resizing. This is the scripted form of the
resize stimulus, which is otherwise only reachable by a keyboard shortcut.

    danterm pane zoom --pane "$PANE_ID" on
    danterm pane zoom --pane "$PANE_ID" off

Prefer `on` and `off` over `toggle`: they are idempotent, so a script reaches a
known state without having to observe the current one first. The reply carries
`tab.isZoomed`, which is the state after the request. A tab holding a single
pane has nothing to zoom and reports `isZoomed: false` rather than failing --
check the field, not the exit status.

Zoom is deliberately transient and is not part of the persisted snapshot, so
`ls` does not report it. `pane info` does.

### Run a pane at an exact grid

`pane resize` decides the grid a pane runs at, whatever rectangle it occupies on
screen. It is the scripted form of what a small remote client needs: a Mac window
may run the pane at 179 columns while a phone can only show 60.

    danterm pane resize --pane "$PANE_ID" 60x20
    danterm pane resize --pane "$PANE_ID" --fit

The grid form pins the pane. The pane then keeps that grid through window
resizes, divider drags, zoom, and app restarts, until something clears it:
`--fit` returns the pane to the grid its rectangle implies. Pass one form or the
other, never both.

Columns must be 2 through 1024 and rows 1 through 1024. A value outside that
range is an error, never a clamp, so a caller is never left running at a size it
did not ask for. The reply is the `pane info` shape, whose `pane.gridOverride`
carries the resulting grid or is absent when the pane follows its rectangle.

Nothing records who asked. The last resize wins, and `ls` reports every claimed
grid alongside `pane info`.

### Inspect a pane's line structure

`pane rows` prints one JSON record per display row of the whole stream --
retained scrollback first, then the live grid:

    {"rows":[{"index":0,"retained":true,"softWrapped":false,"contentEnd":30,
              "width":117,"marginKind":"padding","staleWrapClaim":false}, ...]}

`contentEnd` is one past the last column holding printed content; background
erase paint is not content. `marginKind` is the last column's cell kind
(`padding`, `narrow`, `wideHead`, `wideTail`, `spacerHead`). `softWrapped` is
the *gated* continuation the line-structure readers consume; `staleWrapClaim`
marks the transient where a live row still carries a printer wrap claim whose
margin an erase blanked (EL 1/2 keep the claim for xterm parity, and the engine
declines it everywhere it would fuse lines). Use this when text lands at the
wrong columns after a resize, which text projections cannot diagnose: `pane
read` joins soft-wrapped rows, so a logical line holding more cells than its
content reads the same as legitimately wrapped prose.

The check worth running is heuristic, not exact: a wrap whose margin holds no
content is *suspect*. An autowrap prints at the last column, and a wide glyph
that could not fit leaves a `spacerHead` there -- but a reflow can legitimately
fold a line so an interior blank lands on the margin, which is
indistinguishable row-locally. Flag and then eyeball:

    danterm pane rows --pane "$PANE_ID" | python3 -c '
    import json, sys
    for row in json.load(sys.stdin)["rows"]:
        if row["softWrapped"] and row["contentEnd"] < row["width"] \
           and row["marginKind"] != "spacerHead":
            print(row)'

A genuinely spurious row renders correctly at the width it was built for and
garbled at every other one, so pair this with `pane tape` to capture the byte
stream that made it.

### Capture a pane flight recording

`pane tape` prints the pane's bounded recording as JSON Lines. Without
`--follow` it ends at one fence. With `--follow` it stays open for live events.
A finite stream from the beginning defaults to raw evidence. A follow,
`--from-now`, or `--from-cursor` defaults to reconstructible state. Override the
default with `--raw` or `--reconstructible`.

    danterm pane tape --pane "$PANE_ID" > tape.jsonl
    danterm pane tape --pane "$PANE_ID" --follow --raw > tape.jsonl
    danterm pane tape --pane "$PANE_ID" --follow --from-now > tape.jsonl
    danterm pane tape --pane "$PANE_ID" --format inspect

`--from-now` starts at current pane state. `--from-cursor '<json>'` resumes from
a cursor copied from a completed `start` or `sync` record. A cursor carries
`recorderLifetimeId`, `sequence`, `feedByteOffset`, and `writeByteOffset`. A
cursor from a previous app lifetime is accepted and repaired with total loss
plus fresh state. `--format replay` is the default and keeps exact bytes;
`--format inspect` is the readable event view described below.

Every stream opens with `start`. In between come recorded `event` values,
reported `gap` values, and synthesized `sync` values. A clean finite stream ends
with `end`. Every line is independently valid JSON; one state transfer can use
several lines.

- `start` opens every stream:
  `{"kind":"start","version":4,"capture":"dump"|"follow"|"snapshot",`
  `"format":"replay"|"inspect","reconstructible":true|false,`
  `"provenance":{...},"initial":{"columns":N,"rows":N,"pinned":true|false},`
  `"cursor":{...}}`.
  `cursor` is absent while a state sync is pending. It appears only after all
  state bytes have arrived.
- `gap` reports exact loss for a cursor from this recorder:
  `{"kind":"gap","droppedEventCount":N,"droppedFeedBytes":N,"droppedWriteBytes":N}`.
  A cursor the recorder cannot place reports `{"kind":"gap","loss":"total"}`.
- `event` carries one recorded event:
  `{"kind":"event","sequence":N,"elapsedNanoseconds":N,`
  `"byteOffset":N,"byteLength":N,"event":{"type":"feed","base64":"..."}}`.
  Timing sits above the event object. `byteOffset` and `byteLength` appear only
  on `feed` and `write` events; the offsets are zero-based and numbered
  independently per direction, so a feed offset counts feed bytes only.
  A geometry event is
  `{"type":"resize","columns":N,"rows":N,"pinned":true|false}`.
- `sync` carries synthesized terminal bytes in ordered parts. The first part
  carries current geometry. The final part carries the continuation cursor:
  `{"kind":"sync","part":1,"parts":N,"base64":"...",`
  `"initial":{"columns":N,"rows":N,"pinned":true|false}}`.
  Buffer every part and apply the bytes only after the final part arrives.
- `end` states why the producer stopped:
  `{"kind":"end","reason":"dump-complete"|"snapshot-complete"|"pane-closed"|"stream-failed"}`.

A finite tape dump (`capture: "dump"`) fences one atomic moment and always ends
with `dump-complete`. Events that arrive while its records reach you are not
in it, and the pane closing part way through delivery does not truncate it. If
the stream ends at EOF instead, the capture is incomplete and the CLI exits
nonzero saying DanTerm closed the connection before the tape ended -- do not
treat that output as a whole recording.

A followed capture (`capture: "follow"`) ends with `pane-closed` when the pane
goes away, or `stream-failed` when DanTerm cannot keep it going. Either record
ends that stream only -- other follows and requests on the same connection keep
working, and the connection stays open until you close it. A follow that ends at
EOF without an `end` record is still a valid capture of everything up to the
moment the app stopped, which is what surviving a crash looks like.

Geometry is one fact on this stream: the grid, plus whether that grid is pinned.
Pinned means the grid is an override a `pane resize` set; unpinned means it follows
the pane's rectangle. The start record, the first sync part, and every geometry
event all state both, so a reader always knows the pane's current pinnedness
without comparing grids. Clearing an override back to the grid the pane already
ran at still produces one geometry event, with `pinned` false and the same
columns and rows -- the child sees no size change and no cell content changes.

A reconstructible stream injects a sync only when the requested position plus
the delivered events cannot reconstruct exact pane state. A raw stream never
injects state. It reports retained events and loss as recorder evidence. Use
`--raw` for captures that will become fixtures.

### Snapshot exact pane state

`pane snapshot` returns the same atomic sync records a reconstructible tape
stream uses, then `snapshot-complete`. It always starts without a cursor because
the cursor takes effect only on the final sync part.

    danterm pane snapshot --pane "$PANE_ID" > pane-state.jsonl

The tape records both directions: `feed` events are bytes the child produced,
`write` events are bytes that reached the child. A `write` also carries
`originElapsedNanoseconds` when its bytes came from an event outside the pane
owner, so the gap between that stamp and `elapsedNanoseconds` is time the app
held the input; bytes the owner produced itself, such as terminal replies,
carry no origin. Feed payloads use lossless base64. Because input is recorded, a
tape can contain what was typed, including a password a `sudo` or `ssh` prompt
never echoed -- treat one as sensitive before sharing or committing it.

Raw output is unscrubbed; redirect it to a file, then run the repository's
fixture converter before committing it. The converter refuses every stream that
is reconstructible or reports a `gap`, because synthesized state and surviving
geometry are not raw evidence of the whole run. It also refuses a stream whose
event sequence or per-direction byte offsets do not continue. There is no
truncation override. A finite dump that stops without its `end` record is not a
whole recording and is refused. A followed capture that stops at EOF is accepted
as evidence up to that point. Every pane records, in production as well as in a
dev build, so this always answers for a live pane.

    scripts/terminal-tape-to-fixture.py tape.jsonl \
        lib/TerminalCore/Tests/TerminalCoreTests/Fixtures/danterm/my-case.json \
        --test TerminalPromptRegressionTests --shell fish --stimulus "dragged divider"

Because the output is one record per line, `jq -c` filters it record by record
and `jq -s` slurps the whole stream into an array:

    # How the stream started and how it ended.
    jq -c 'select(.kind == "start" or .kind == "end")' tape.jsonl

    # Count the event records.
    jq -s '[.[] | select(.kind == "event")] | length' tape.jsonl

    # The child's output as raw bytes, in order.
    jq -r 'select(.kind == "event" and .event.type == "feed") | .event.base64' \
        tape.jsonl | base64 -d

    # Any loss the producer reported.
    jq -c 'select(.kind == "gap")' tape.jsonl

    # Fail when a capture never stated a clean end.
    jq -e -s 'last | .kind == "end"' tape.jsonl > /dev/null

JSON-RPC notifications are socket transport only and are not a persisted
recording format.

### Read a capture with --format inspect

`--format inspect` derives a readable view of the same stream, for when you want
to read what a pane did rather than replay it. DanTerm always records and sends
the exact bytes; the CLI derives this view locally, one record at a time, so
nothing about the recording changes.

    {"kind":"start","version":3,"capture":"dump","format":"inspect","reconstructible":false,"initial":{"columns":80,"rows":24},"cursor":{"recorderLifetimeId":"...","sequence":0,"feedByteOffset":0,"writeByteOffset":0},"provenance":{...}}
    {"kind":"event","sequence":0,"elapsedNanoseconds":123652792,"byteOffset":0,"byteLength":41,"event":{"type":"feed","spans":[{"control":"ESC"},{"text":"]1337;DanTermShell=3;integration-ready"},{"control":"ESC"},{"text":"\\"}]}}

A `start` record changes only its `format` field; its version, capture,
provenance, geometry, and cursor are unchanged. An `event` record replaces
`base64` inside an event object with `spans`, and every field outside that
payload -- `sequence`, `elapsedNanoseconds`, `originElapsedNanoseconds`,
`byteOffset`, `byteLength` -- is identical to the replay record. `gap` and `end`
records pass through unchanged. A `sync` also stays base64 because it is terminal
state, not a recorded event payload.

Spans account for every payload byte exactly once, in order, under three keys:

- `{"text":"..."}` is a run of decodable characters. Only C0 and DEL leave it, so
  a C1 control or a zero-width character rides inside a text span.
- `{"control":"ESC"}` is one C0 byte or DEL, named individually.
- `{"hex":"ff fe"}` is a run of bytes that decode as nothing, lowercase and
  space separated.

An empty payload gives `"spans": []`. The separate keys are what keep the view
unambiguous: the three literal characters `ESC` are `{"text":"ESC"}` while the
escape byte is `{"control":"ESC"}`, so a reader never has to guess which one the
pane produced.

Bytes are classified within the one event that recorded them. A character split
across two recorded transfers stays split and shows as hex in each event,
because that is what the pane actually did.

Two limits to know before you rely on this view. Inspect does not interpret CSI,
OSC, DCS, or any other terminal sequence: each one reads as an ESC control span
followed by its literal text, the way the OSC in the example above does. And inspect output is not
replayable and is not acceptable fixture evidence -- the fixture converter
rejects it. Capture with the default `replay` format for anything you will
convert or replay.

    # The text the child printed, in order, with control bytes left out.
    jq -r 'select(.kind == "event" and .event.type == "feed") | .event.spans[].text // empty' \
        tape.jsonl

    # Events carrying bytes that decode as nothing.
    jq -c 'select(.kind == "event" and ((.event.spans // []) | any(.hex)))
           | {sequence, byteOffset, spans: .event.spans}' tape.jsonl

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

    danterm ls | jq -r '.. | objects | select(.type == "leaf") | .pane | [.id, .title // "", .cwd // ""] | @tsv'

`title` and `cwd` are reported by the terminal verbatim, so they can contain
newlines and control characters -- any program can put one there with a single
escape sequence. A script that needs one record per pane must use `@tsv` as
above, which escapes them; string interpolation would let one hostile title
split a record in two.

`ls` returns `{groups, selectedTabId, inlineRename}`. Each pane lives inline at
a split-tree leaf: `groups[].tabs[].rootNode` is the per-tab tree, and every
`{ "type": "leaf" }` node carries its pane under `.pane` (`{id, title, cwd,
command, connection, agent, integration, ...}`). The four lifecycle fields have
the same typed encoding as `pane info`, so agent lookup uses
`.agent.session.sessionId`. The `jq` above recurses the tree to list every pane.
Treat `selectedTabId` as display state, not as a targeting source.

`inlineRename` names the sidebar row whose inline edit field is open right now:
`{"type": "tab", "tabId": "..."}` or `{"type": "group", "groupId": "..."}`. The
key is absent when no editor is open, and at most one can be open at a time.
Every way of starting one -- the context menu, the menubar Rename Tab command,
a double-click on a row, and creating a group -- is reported here.

    danterm ls | jq -c '.inlineRename // "none"'

### Inspect live key focus

`focus` reports the main window's actual first-responder owner. Pane-owned
controls include their pane id; deliberate controls outside the pane tree and
an unclaimed window do not:

    danterm focus
    {"focus":{"type":"terminal","paneId":"..."}}

The `type` is `terminal`, `searchField`, `nonPane`, or `none`. Use this query to
verify focus behavior, not to select a target for mutation.

### Check integration health

`doctor` does not require the app to be running. Use it when
the user asks whether DanTerm's shell command, agent hooks, agent skill, `jq`, or
configured font setup is healthy:

    danterm doctor

When skill discovery is not installed, `doctor` points to `danterm skill` for
on-demand instructions. The installed discovery paths remain useful when an
agent should select this skill automatically.

The output reports all rows (INFO/SKIP/WARN/ERROR/OK) plus a summary footer.
Exit status is 1 only when a check is an ERROR; WARN/INFO/SKIP still exit 0.

The Notifications, Full Disk Access, and Developer Tools rows are app-owned
checks. They name the observed state: `enabled` or `disabled` for notifications,
and `permission granted` or `permission not granted` for the other two. They
report OK or WARN when the matching DanTerm instance is running and SKIP when it
is not.
Full Disk Access is tested by reading a protected TCC file. Developer Tools is
tested by having LLDB attach to a disposable child process because macOS exposes
no public status API for either permission.

The `Configured font installed` row checks `font.family` in
`~/.config/danterm/config.json`: SKIP when no family is set, OK when it names an
installed family, and WARN when it does not (DanTerm falls back to the system
monospace font) or when the config file can't be read as a schemaVersion 1 JSON
document. It is always advisory -- a font problem never changes the exit code.

### Todos

Every todo command requires exactly one owner flag: `--pane <pane-id>` or
`--tab <tab-id>`. The examples below use a pane; substitute `--tab "$TAB_ID"`
to edit the tab-level list.

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

Input submitted while the pane is spawning stays buffered in order. The
command returns success only after every submission is handled by the pane
owner; byte-producing submissions must cross the PTY master. Spawn, process,
or write failure returns an error instead.

| Token form | Meaning |
|---|---|
| Bare words such as `"ls"` or `"cargo"` | Text |
| `Space` | One text space |
| `Enter`, `Tab`, `BSpace`, `Escape`, `Up`, `Down`, `Left`, `Right`, `Home`, `End`, `PgUp`, `PgDn`, `Insert`, `Delete`, `F1` through `F12` | Named key press |
| `C-<x>` or `M-<x>` | Ctrl or Alt character, such as `C-c`, `C-\`, `C-[`, `C-]`, `C-^`, `C-_`, `C-Space`, or `M-b` |
| `S-<named-key>` | Shifted named key, such as `S-Tab` or `C-S-Up`; shifted letters such as `S-a` remain unsupported |
| `--literal` before `--` | Disable key parsing; every following token is text |

Each token remains a separate event. Pass one quoted argument when literal text
must contain spaces or newlines.

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
| `skill` | Raw Markdown bytes from the version-matched bundled `SKILL.md` |
| `ls` | JSON: `{groups, selectedTabId}` (each pane embedded at its `rootNode` leaf under `.pane`, with current `processPhase`, `command`, `connection`, `agent`, and `integration` values in the same encoding as `pane info`) |
| `focus` | JSON: `{focus: {type: "terminal"|"searchField", paneId: "..."}}` or `{focus: {type: "nonPane"|"none"}}` |
| `pane info --pane <pane-id>` | JSON: `{pane: {id, title, cwd, processPhase, command, connection, agent, integration, gridOverride?}, tab: {id, title, groupId, isZoomed}, group: {id, name}}` |
| `tab new ...` | JSON: `{tab: {...}, panes: [{id}], group?: {id, name}}` |
| `group new --name <name>` | Same JSON shape as `tab new`, naming the new group and its first tab |
| `pane split --pane <pane-id>` | JSON: `{pane: {id}}` |
| `todo list (--pane <pane-id> \| --tab <tab-id>)` | JSON: `{todos: [{id, text, isDone}, ...]}` |
| `todo add (--pane <pane-id> \| --tab <tab-id>)` | JSON: `{todo: {id, text, isDone}}` |
| `pane read --pane <pane-id>` | Raw text from the requested pane, not JSON |
| `pane zoom --pane <pane-id> on\|off\|toggle` | Same JSON shape as `pane info`, with the resulting `tab.isZoomed` and current session-reported fields |
| `pane resize --pane <pane-id> <columns>x<rows>\|--fit` | Same JSON shape as `pane info`, with the resulting `pane.gridOverride` (absent when the pane follows its rectangle) |
| `pane rows --pane <pane-id>` | JSON: per-display-row line structure |
| `pane tape --pane <pane-id>` | Raw JSON Lines: `start`, retained events or loss, then `dump-complete` |
| `pane tape --pane <pane-id> --follow [--from-now | --from-cursor <cursor-json>]` | Reconstructible JSON Lines held open for live events |
| `pane tape --pane <pane-id> [--format replay\|inspect]` | Same stream either way. `replay` (the default) carries exact `base64` payloads; `inspect` carries readable `spans` and is neither replayable nor fixture evidence |
| `pane snapshot --pane <pane-id>` | JSON Lines: `start`, one or more atomic `sync` parts, then `snapshot-complete` |

The `agent attach`, `agent activity`, and `agent detach` commands are silent
mutations: no stdout on success. Activity accepts only `working`, `waiting`, or
`idle`; every activity and detach report is qualified by the root session id so
a stale hook cannot mutate a replacement session.

## Rules for agents

- Never `pane input` into your own pane (`$DANTERM_PANE`) without an explicit
  user request; you would be typing into your own input stream.
- Split-then-`pane input` is safe while the pane process spawns. Prefer
  `tab new --group <group-id> --cmd` and `pane split --pane <pane-id> --cmd`
  when the new program can flush terminal input at startup; `--cmd` supplies
  the command as launch input instead.
- To launch Claude with an initial prompt, keep its stdout attached to the
  terminal. For serious agent work (implementing a plan, verifying an issue,
  reviewing a plan, reviewing an implementation, etc.), use `claude --effort
  max`. Pass simple prompts as arguments. For shell-hostile prompt text, stage
  it in a file and use the DanTerm-verified stdin form
  `--cmd 'claude --effort max < /tmp/danterm-prompt.txt'`. See the recipe above.
- `tab new` and `pane split` default to background behavior for autonomous work.
  Pass `--foreground` only when the user explicitly asked you to switch to the
  new tab or focus the new split pane within its tab.
- For `tab new`, the default position is the target group end. Use
  `--after-tab <tab-id>` or `--after-selected` only when the user gave that
  placement anchor.
- When a recipe needs an id, derive it from `pane info` or `ls` using the
  targeting rule above; do not guess UUIDs.
- Errors print to stderr as `danterm: <message>` and exit non-zero. `DanTerm is
  not running` means the app's control socket is unavailable. A `cannot access
  control socket (sandbox or permissions)` error is an access denial: surface
  it to the user instead of treating the app as stopped or retrying blindly.
  Surface other connection errors too; their POSIX reason and socket path are
  diagnostic context. A tailnet connection can instead refuse before its hello:
  `not admitted` means the node id is absent from the configured list;
  `could not resolve this device's tailnet identity` means identity lookup
  failed; `connection limit reached` means the server is full; and `audit
  unavailable` means the server cannot write the record required before remote
  work. Do not retry any of these in a loop. A protocol-version error requires
  compatible client and server builds; an app-version difference alone does not
  refuse the connection.
- Remote IPC is closed by default. To enable it, add a `tailnet` object to
  `~/.config/danterm/config.json` with `listen` set to this Mac's explicit
  Tailscale IPv4 address and port, and `admittedNodeIds` set to a non-empty list
  of stable Tailscale node ids. Restart DanTerm after changing it. The app never
  falls back to a wildcard or LAN bind, and a bad bind or unavailable audit log
  leaves the local control socket running.
- Drive an enabled listener with `danterm --tcp <tailnet-ip>:<port> <command>`.
  The TCP target is always explicit. It uses the same handshake, typed refusal
  errors, commands, and output shapes as a Unix-socket target. Remote `quit` is
  sent normally and refused by the server while the app stays running.
- A TCP connection lives under a liveness contract, and the server owns its one
  number: its hello carries `silenceSeconds`, the longest the connection may go
  with no arriving byte. Both ends apply that bound. The CLI pays the client's
  side automatically -- it sends a `ping` request every half-bound and absorbs
  the reply, so nothing appears in command output -- and reports `DanTerm
  stopped responding: no data within the liveness bound` when no byte arrives in
  time. The server closes a connection that goes silent and gives its slot back.
  Pings produce no audit records of their own. A local `--socket` connection is
  exempt from all of this and may idle forever, which is what lets `pane tape
  --follow` sit on a quiet pane indefinitely.
- macOS only. If `danterm` is not on PATH, stop.
