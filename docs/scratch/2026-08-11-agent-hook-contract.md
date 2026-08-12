# Agent hook contract: measured codex behavior and the edits it implies

Date: 2026-08-11

Status: open scratch document. It records what codex 0.147.0 actually sends to
a hook, the edits that measurement implies, and a sketch of a test that would
keep the record honest as the agent CLIs move.

All eight edits are implemented, plus a ninth the list missed: Claude's wiring
in `~/world/common/claude-code.nix` had the same defect item 7 fixed for codex,
registering the agent hook on `SessionStart` alone. Item 7 called that file "the
same shape" without noticing it needed the same edit.

## What is still open

Everything below is a known gap, not an oversight. The rest of this document is
the record it came from.

| Gap | Where it bites | Status |
|---|---|---|
| Claude's test payloads are hand-written | Its field names are pinned only as far as we guessed them, so a renamed field passes | Needs a capture like the codex one; no trust gate, so it is cheap |
| Codex subagent behavior is untested | The `agent_id` guard is a placeholder for a contract we have not measured | One subagent turn settles it |
| `CLAUDE_CONFIG_DIR` isolation is unconfirmed | Decides whether test layer 2 can cover Claude at all | Untested |
| A fresh codex pane carries no chip until the first prompt | Looks like a broken hook, and cost an hour of debugging once already | Codex's behavior; not fixable in the hook |

Verified end to end on the real config, both agents: a pane goes `none` ->
`attached` -> `working` on the prompt -> `idle` on Stop -> `none` on
`/quit` or `/exit`. Test layers 2 and 3 are proposals, not decisions.

Watching Claude do it turned up a defect on our side. Attachment claimed
`.working`, a state no hook sends. Codex hid it by deferring `SessionStart` to
the first prompt, so a turn always followed within milliseconds; Claude fires it
at launch, so a pane at an untouched prompt reported work indefinitely. Attach
now records no activity and the first real event fills it in. Sessions that
started before a hook change keep the old wiring until they restart, so a
lingering wrong state usually means an old session, not a broken hook.

## Why this exists

A codex pane showed no agent chip and no agent label. The cause turned out to
be outside DanTerm: codex gates every hook behind a trust prompt, and the
`SessionStart` entry in `~/.codex/hooks.json` had never been approved, so
`danterm agent attach` never ran. Approving it fixed the pane.

Chasing that turned up several claims in our codex hook script that no one had
checked against a real payload. This document replaces the guesses with
measurements.

## Measured: codex 0.147.0 hook payloads

Captured by pointing an isolated `CODEX_HOME` at a hook that appends its stdin
to a log, then driving the real TUI through two turns and a `/quit`. Observed
event order:

    SessionStart  UserPromptSubmit  PreToolUse  PostToolUse  Stop
                  UserPromptSubmit  PreToolUse  PostToolUse  PreToolUse  PermissionRequest
                  UserPromptSubmit  Stop  SessionEnd

Every event carries `session_id`, `transcript_path`, `cwd`, `model`,
`permission_mode`, and `hook_event_name`. Every event except `SessionStart` and
`SessionEnd` also carries `turn_id`.

| Event | Fields beyond the common set |
|---|---|
| SessionStart | `source` (`"startup"`) |
| UserPromptSubmit | `prompt` |
| PreToolUse | `tool_name`, `tool_input`, `tool_use_id` |
| PostToolUse | `tool_name`, `tool_input`, `tool_use_id`, `tool_response` |
| PermissionRequest | `tool_name`, `tool_input` (carries `description`); no `tool_use_id` |
| Stop | `last_assistant_message`, `stop_hook_active` |
| SessionEnd | `reason` (`"other"` after `/quit`) |

The full event vocabulary, read from the `HookEventsToml` field list in the
0.147.0 binary: `PreToolUse`, `PermissionRequest`, `PostToolUse`, `PreCompact`,
`PostCompact`, `SessionStart`, `SessionEnd`, `UserPromptSubmit`,
`SubagentStart`, `SubagentStop`, `Stop`. There is no `Elicitation` event.

Four facts worth stating separately, because our script assumes otherwise:

- **Tool names are Claude-shaped.** A shell call reports `tool_name: "Bash"`
  with `tool_input: {"command": "echo hi"}`. Codex's ask-user tool is
  `request_user_input`; `AskUserQuestion` is Claude's name and never appears.
- **No payload carries `agent_id`.** Not on any of the thirteen captured
  events. Subagent work is signalled by `SubagentStart` / `SubagentStop`
  instead, neither of which fired in this capture.
- **`PermissionRequest` follows `PreToolUse` for the same call.** The
  escalation path ran `PreToolUse`, `PostToolUse` (the sandboxed attempt
  failing), then `PreToolUse` again, then `PermissionRequest`.
- **Declining an approval emits no terminal event.** Pressing Escape at the
  prompt ended the turn with no `Stop`. This made the old
  `PermissionRequest`-to-waiting mapping stale until the next
  `UserPromptSubmit`; the hook now ignores that event for activity.

**`SessionStart` is delivered at the first user prompt, not at process launch.**
A codex TUI sitting at an empty composer has run no hook at all, so the pane
shows no chip until you submit something. The payload still says
`source: "startup"`, and `SessionStart` still arrives before that turn's
`UserPromptSubmit`, so the ordering above holds -- what is deferred is the whole
batch, not the order within it. Measured by pointing a scratch `CODEX_HOME` at a
`bash -x` wrapper around the real hook: nothing was logged across three fresh
sessions, and the first prompt produced `SessionStart` and a successful
`agent attach` on the same line. Any check of "did the pane attach?" has to type
a prompt first.

The TUI's `/hooks` screen is the instrument for the rest. It lists every event
with Installed / Active / Review counts, which separates "not registered" from
"registered but untrusted" without reading `config.toml`. Note that an approved
entry is written with only a `trusted_hash`: `enabled` is absent by default and
adding `enabled = true` by hand changes nothing.

Hook trust is enforced, not advisory. Before approval no hook runs at all --
`codex exec` completes the session normally with hooks skipped -- and a
hand-written `[hooks.state]` entry with `enabled = true` and a wrong
`trusted_hash` does not bypass it. The prompt is keyed per file entry
(`<path>:<event>:<group>:<index>`), so every event added to `hooks.json`
triggers its own review.

## Recommended edits

### `integrations/codex/danterm-agent-session.sh`

1. Delete the `Elicitation` case. That event does not exist in 0.147.0.
2. Drop `AskUserQuestion` from the `PreToolUse` arm and keep only
   `request_user_input`.
3. Keep the `agent_id` guard, with a comment saying it is currently inert.
   Codex sends no such field, but whether subagent events reuse the root
   `session_id` is untested, so removing the guard is the riskier edit. If
   subagents do report, the correct filter is to ignore work between
   `SubagentStart` and `SubagentStop`.
4. Ignore `PermissionRequest` for Codex activity. A live automatic approval
   proved that the event does not establish a user-blocked wait, and Codex emits
   no paired resolution before resuming work. Keep `request_user_input` as the
   explicit waiting transition.

### `integrations/codex/danterm-agent-session.test.sh`

5. Update for edits 1 and 2, and pin the event names and field names against
   captured payloads rather than invented ones.

   Done, and it exposed a hole in the harness worth naming: `check_case` put the
   recording `danterm` stub on `PATH` only when a case expected an invocation, so
   every "is ignored" case passed by finding no `danterm` at all. The stub now
   goes on `PATH` for every case, and the one case that tests a missing CLI opts
   out with `NO_STUB=1`. Before the fix, the case for edit 2 passed against the
   unfixed script.

### `integrations/claude-code/danterm-agent-session.sh`

6. Drop `request_user_input` from its `PreToolUse` arm. That is codex's tool
   name; the Claude script carries the mirror image of the same dead check.

### Outside the repo, in the `~/world` nix config

7. `~/world/common/codex.nix` generates `~/.codex/hooks.json` and registers
   only `SessionStart` for `danterm-codex-agent-session`, so codex attaches and
   then never reports activity or detaches. The `hooksJson` attrset needs
   `UserPromptSubmit`, `Stop`, and `SessionEnd`, plus `PreToolUse` with a
   `matcher` so a process is not spawned on every tool call. `PermissionRequest`
   is deliberately absent because Codex does not pair it with a resolution
   event. Note the file's own comment: `config.toml` stays hand-managed because
   codex writes to it, which is also where the hook trust state lands -- so each
   added entry needs an interactive approval once.

   `~/world/common/claude-code.nix` needs the same fix, and reading it as merely
   "the same shape" is what hid that for a day. Its non-`SessionStart` events
   ran `danterm-claude-notify-osc777` and nothing else, and `UserPromptSubmit`
   and `SessionEnd` were absent, so a Claude pane attached and then went silent
   exactly as codex did. The two hooks answer different questions -- pane state
   versus get-the-user's-attention -- so the events that want both list both.
8. The `danterm` on PATH is `danterm-0.1.1`, whose CLI parses only
   `agent attach`; `agent activity` and `agent detach` exit 1 and are swallowed
   by the script's `|| true`. Both subcommands landed in v0.1.2. The cause is a
   one-commit lag, not a missing update: `~/world/flake.lock` pins the danterm
   input at `84b678d7` ("release v0.1.2"), but `package.nix` at that commit
   still declared `version = "0.1.1"`, and the bot bumped it to 0.1.2 in the
   very next commit, `ba19f965`. `nix flake update danterm` picks it up. Until
   then, edit 7 buys nothing.

Edits 1 through 6 travel the same path: `pkgs.danterm-codex-agent-session` and
`pkgs.danterm-claude-agent-session` are built by this repo's `flake.nix` from
`integrations/*/danterm-agent-session.sh` and consumed through the danterm
overlay. A script edit reaches the machine only after a danterm release and a
`nix flake update danterm`.

## A test that keeps this honest

The measurements above decay. Each agent CLI updates on its own schedule, and a
renamed event or a dropped field would break pane state silently -- the hooks
fail closed and the pane simply stops reporting, which is exactly the failure
that started this.

Two measurements make such a test far cheaper than it first looks.

**Hooks fire without working auth.** With `auth.json` moved aside, `codex exec`
returned ten 401s and still emitted `SessionStart`, `UserPromptSubmit`, and
`SessionEnd` with their complete field sets. No tokens, no successful network
call, no TUI. Only the tool-call events need a real turn.

**Trust state is a committable artifact.** Approving once wrote into the
scratch `CODEX_HOME`:

    [hooks.state."<abs path>/hooks.json:session_start:0:0"]
    trusted_hash = "sha256:cb67a2b8..."
    enabled = true

The key is the absolute path of the hooks file, so a fixture at a fixed path
can ship its own pre-approved `config.toml` and run unattended. The hash inputs
are undocumented and were not derived; if codex changes them the run fails,
which is the drift signal anyway -- provided the failure says "hook trust
rejected, re-approve the fixture" and not something cryptic.

### Three layers, three cadences

1. **Payload replay -- hermetic, free, already has a home.** Commit the
   captured payloads next to each script, put a stub `danterm` on `PATH` that
   records its argv, feed each payload to the hook script, and assert the exact
   command it emits. This is where "`SessionStart` produces `agent attach
   --kind codex --id <session_id>`" belongs. It catches every edit we make and
   costs nothing. This needs no new harness: `flake.nix` already runs
   `integrations/*/danterm-agent-session.test.sh` as `nix flake check`
   derivations, passing the packaged hook as `HOOK_UNDER_TEST` inside the nix
   sandbox. The change is replacing invented payloads with recorded ones.

   Done for codex. The Claude cases still carry hand-written payloads: no Claude
   capture has been taken, so its field sets are unpinned and a renamed field
   there would still pass.

2. **Contract conformance -- live, opt-in, auth-free.** A recipe that runs each
   agent headlessly against a scratch config directory, captures the payloads,
   normalizes them to `event -> sorted field names`, and diffs that against a
   committed contract. The codex half needs no auth and no tokens: point it at
   an empty auth and let the turn fail. Run it when bumping an agent CLI, not
   on every commit.

3. **Tool-event conformance -- live, spends tokens.** The only part needing a
   real turn: one prompt that forces a shell call, asserting `tool_name` and
   `tool_input` shape. Cheapest model, lowest effort, assertions on the event
   stream and never on the model's wording. Same recipe, separate flag.

### Isolation

- **codex**: `CODEX_HOME` covers config, sessions, and trust state.
  `codex exec --skip-git-repo-check` in a temp working directory.
- **Claude**: `CLAUDE_CONFIG_DIR` is the apparent equivalent, but whether it
  isolates hooks the way `CODEX_HOME` does is untested. Check that before
  building layer 2 for Claude.
- **DanTerm**: a stub `danterm` on `PATH` beats a real instance for layers 1
  and 2 -- no app, no window, no WindowServer, so the tests stay in
  `just test`. If a layer ever needs a real pane, `just launch-slot` with an
  explicit `--socket` is the isolated instance.

### The failure mode to design against

Layer 3 depends on the model, and nothing guarantees it calls the shell tool.
Split the assertions: the required events (`SessionStart`, `UserPromptSubmit`,
`Stop`, `SessionEnd`) fail the test when absent, while tool events assert their
shape only if they appear and report "not exercised" otherwise. A conformance
test that goes red because the model answered from memory teaches everyone to
ignore it.
