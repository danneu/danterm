---
name: danterm
description: >-
  Drive the DanTerm terminal from the shell. Use when the user asks to rename or close this tab, open or split panes, launch commands in new tabs or panes, inspect live key focus, read output or dump or follow a flight recording from another pane, send keys into another pane, switch the theme, or work with DanTerm todos. DanTerm is a macOS-only terminal; only applies when the `danterm` command is on PATH.
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

Every IPC command accepts `--socket <path>` before the command name. This
explicit instance target overrides `DANTERM_SOCK` and identity-derived socket
lookup.

The local `skill` and `doctor` commands do not accept `--socket` or inspect pane
targeting. `doctor` queries the matching running app for macOS permission state
and skips those rows when the app is unavailable.

    danterm ls
    danterm focus
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
    danterm pane rows --pane <pane-id>
    danterm pane tape --pane <pane-id> [--follow] [--from-now]
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
- `pane focus`, `pane info`, `pane read`, `pane rows`, `pane zoom`, and
  `pane tape`: always name the pane explicitly.

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

Each pane projects four typed current lifecycle objects:

    {
      "pane": {
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
| "why is the pane's text laid out wrong after a resize" | `pane rows --pane <pane-id>` |
| "dump the pane's flight recording" | `pane tape --pane <pane-id>` |
| "watch the pane's flight recording live" | `pane tape --pane <pane-id> --follow` |
| "type X into pane <id>" / "send Ctrl-C to..." | `pane input --pane <pane-id>` |
| "what tabs/panes are open?" | `ls` |
| "which control owns key focus?" | `focus` |
| "which tab/group contains this pane?" | `pane info --pane <pane-id>` |
| "switch the theme to X" | `theme set --pane <pane-id>` |
| "add/check off/edit a todo" | `todo ... --pane <pane-id>` or `todo ... --tab <tab-id>` |
| "check DanTerm integration health" | `doctor` |
| "show DanTerm's agent instructions" | `skill` |

## Recipes

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
adjacent group first. Two closes are refused so the CLI does not quit DanTerm as
a side effect: the last group, and the group holding every tab when
`--move-tabs` is absent.

### Rename or clear a tab

    danterm tab rename --tab "$TAB_ID" "fix scrollbar math"
    danterm tab rename --tab "$TAB_ID" --clear

### Close a tab

    danterm tab close --tab "$TAB_ID"

Closing the only remaining tab is refused so the CLI does not quit DanTerm as a
side effect.

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

Prefer `--cmd` over splitting and then sending keys; it avoids the
shell-prompt race.

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
closes that tab. Closing the only pane of the only tab is refused, so the CLI
does not quit DanTerm as a side effect. The command does not show the GUI's todo
confirmation because the explicit pane id authorizes the close.

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

### Dump a pane flight recording

`pane tape` prints the pane's bounded, raw recording as one complete
snapshot JSON document. This is the replay artifact format: it carries the
initial geometry, ordered neutral events, live-capture provenance, and
truncation metadata. Feed payloads emitted by the app use lossless base64.

The tape records both directions: `feed` events are bytes the child produced,
`write` events are bytes that reached the child. A `write` also carries
`originElapsedNanoseconds` when its bytes came from an event outside the pane
owner, so the gap between that stamp and `elapsedNanoseconds` is time the app
held the input; bytes the owner produced itself, such as terminal replies,
carry no origin. Because input is recorded, a tape can contain what was typed,
including a password a `sudo` or `ssh` prompt never echoed -- treat one as
sensitive before sharing or committing it.

The output is unscrubbed; redirect it to a file, then run the repository's
fixture converter before committing it. The converter refuses every snapshot
that reports dropped events because its surviving geometry and event sequence
cannot be trusted. There is no truncation override. Every pane records, in
production as well as in a dev build, so this always answers for a live pane.

    danterm pane tape --pane "$PANE_ID" > tape.json
    scripts/terminal-tape-to-fixture.py tape.json \\
        lib/TerminalCore/Tests/TerminalCoreTests/Fixtures/danterm/my-case.json \\
        --test TerminalPromptRegressionTests --shell fish --stimulus "dragged divider"

### Follow a pane flight recording

`--follow` is the incremental capture format: it writes unwrapped `start`,
`event`, optional `gap`, and `end` records as JSON Lines. An `event` record
hoists `elapsedNanoseconds`, and `originElapsedNanoseconds` when the event has
an origin, above the event object itself. `--from-now` skips the
backlog and waits for the next live event. Redirect the stream when evidence
must survive an app crash:

    danterm pane tape --pane "$PANE_ID" --follow > tape.jsonl
    danterm pane tape --pane "$PANE_ID" --follow --from-now > tape.jsonl

The stream is raw and unscrubbed. A slow reader may receive a `gap` record when
it falls behind the bounded recorder; the fixture converter rejects any such
stream.

An `end` record carries a `reason`: `pane-closed` when the followed pane goes
away, and `stream-failed` when DanTerm cannot keep the stream going. Either way
the record ends that stream only -- other follows and requests on the same
connection keep working, and the connection stays open until you close it. An
abrupt app exit can still leave a valid stream ending at EOF without an `end`
record.

The fixture converter accepts either complete snapshot JSON or follow JSONL:

    scripts/terminal-tape-to-fixture.py tape.jsonl \
        lib/TerminalCore/Tests/TerminalCoreTests/Fixtures/danterm/my-case.json \
        --test TerminalPromptRegressionTests --shell fish --stimulus "dragged divider"

JSON-RPC notifications are socket transport only and are not a persisted
recording format.

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

    danterm ls | jq -r '.. | objects | select(.type == "leaf") | .pane | "\(.id)\t\(.title // "")\t\(.cwd // "")"'

`ls` returns `{groups, selectedTabId}`. Each pane lives inline at a split-tree
leaf: `groups[].tabs[].rootNode` is the per-tab tree, and every
`{ "type": "leaf" }` node carries its pane under `.pane` (`{id, title, cwd,
command, connection, agent, integration, ...}`). The four lifecycle fields have
the same typed encoding as `pane info`, so agent lookup uses
`.agent.session.sessionId`. The `jq` above recurses the tree to list every pane.
Treat `selectedTabId` as display state, not as a targeting source.

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

- Bare words (`"ls"`, `"cargo"`) are typed as text.
- Named keys are key presses: `Enter`, `Tab`, `BSpace`, `Escape`, `Up`,
  `Down`, `Left`, `Right`, `Home`, `End`, `PgUp`, `PgDn`, `Delete`, `F1`
  through `F12`.
- `C-<x>` is Ctrl-x and `M-<x>` is Alt-x, such as `C-c`, `C-d`, and `M-b`.
  `S-` is accepted on named keys, such as `S-Tab` and `C-S-Up`; shifted
  letters such as `S-a` remain unsupported.
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
| `skill` | Raw Markdown bytes from the version-matched bundled `SKILL.md` |
| `ls` | JSON: `{groups, selectedTabId}` (each pane embedded at its `rootNode` leaf under `.pane`, with current `command`, `connection`, `agent`, and `integration` objects in the same encoding as `pane info`) |
| `focus` | JSON: `{focus: {type: "terminal"|"searchField", paneId: "..."}}` or `{focus: {type: "nonPane"|"none"}}` |
| `pane info --pane <pane-id>` | JSON: `{pane: {id, title, cwd, command, connection, agent, integration}, tab: {id, title, groupId, isZoomed}, group: {id, name}}` |
| `tab new ...` | JSON: `{tab: {...}, panes: [{id}], group?: {id, name}}` |
| `group new --name <name>` | Same JSON shape as `tab new`, naming the new group and its first tab |
| `pane split --pane <pane-id>` | JSON: `{pane: {id}}` |
| `todo list (--pane <pane-id> \| --tab <tab-id>)` | JSON: `{todos: [{id, text, isDone}, ...]}` |
| `todo add (--pane <pane-id> \| --tab <tab-id>)` | JSON: `{todo: {id, text, isDone}}` |
| `pane read --pane <pane-id>` | Raw text from the requested pane, not JSON |
| `pane zoom --pane <pane-id> on\|off\|toggle` | Same JSON shape as `pane info`, with the resulting `tab.isZoomed` and current session-reported fields |
| `pane rows --pane <pane-id>` | JSON: per-display-row line structure |
| `pane tape --pane <pane-id>` | JSON: replayable raw live-capture recording |
| `pane tape --pane <pane-id> --follow [--from-now]` | JSON Lines: `start`, `event`, optional `gap`, and `end` records |

The `agent attach`, `agent activity`, and `agent detach` commands are silent
mutations: no stdout on success. Activity accepts only `working`, `waiting`, or
`idle`; every activity and detach report is qualified by the root session id so
a stale hook cannot mutate a replacement session.

## Rules for agents

- Never `pane input` into your own pane (`$DANTERM_PANE`) without an explicit
  user request; you would be typing into your own input stream.
- Prefer `tab new --group <group-id> --cmd` and
  `pane split --pane <pane-id> --cmd` over the
  split-then-`pane input` pattern. `--cmd` seeds the command at session
  creation time and avoids racing the shell prompt.
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
  diagnostic context.
- macOS only. If `danterm` is not on PATH, stop.
