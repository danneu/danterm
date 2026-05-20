# Silence late Claude Code notifs; pivot hook to `terminalSequence`

## Context

DanTerm ships a Claude Code `Stop` hook (`integrations/claude-code/claude-notify-osc777.sh`) that emits OSC 777 so the terminal can surface per-pane notifications immediately when Claude finishes a turn. Two problems sit on top of that today:

1. **Late ghost notifs.** Claude Code *also* emits a native OSC 777 / OSC 9 on its hardcoded ~60-second `idle_prompt` timer, independent of whether Claude is actually blocking on user input. The duplicate arrives long after the turn ended, frequently from a pane the user has tabbed away from, so DanTerm's focus suppression at `app/Update.swift:812-814` no longer applies. Every Claude turn ends up roughly two notifs, half of them noise.
2. **TTY workaround is brittle.** Since Claude Code v2.1.139 the hook process has no controlling terminal; the current script works around this with a `find_ancestor_tty` walker (lines 30-56) that traverses `ps` output looking for an ancestor with a real tty, plus a tmux DCS wrap branch. Claude Code v2.1.141+ introduced `terminalSequence`, the supported replacement -- the hook returns JSON `{"terminalSequence": "<bytes>"}` and Claude Code emits it for us, race-free, tmux-aware.

Fix has three parts:

1. **Silence Claude's native channel** via `preferredNotifChannel: "notifications_disabled"` in Claude Code settings. User-facing prerequisite; DanTerm cannot enforce it programmatically. `preferredNotifChannel` is a documented setting (see Claude Code's settings reference) whose enumerated values include `"notifications_disabled"`.
2. **Cover the "Claude needs your input" cases** -- previously delivered (60s late) by the native `idle_prompt` channel -- with two explicit hooks: a `PreToolUse` hook gated on `AskUserQuestion` (the docs list `AskUserQuestion` under `PreToolUse` matchers, not `PermissionRequest`), and a `PermissionRequest` hook for everything else that gates on user approval (Bash, Edit, ExitPlanMode, MCP tools, ...).
3. **Pivot the hook script to `terminalSequence`.** Return JSON on stdout; let Claude Code handle the emission. Removes the ancestor-tty walk and the tmux DCS wrap entirely, drops the `CLAUDE_NOTIFY_TTY` / `CLAUDE_NOTIFY_DEV_DIR` test seams, and shrinks the script to a single readable case block.

Outcome: zero late ghost notifs; an immediate notif when Claude actually wants the user's attention; DanTerm's existing per-pane focus suppression continues to work because the OSC 777 still reaches the terminal the same way it does today, just emitted by Claude Code instead of the hook.

## Decisions

- **Single script branches on `.hook_event_name`** -- one binary, three event types, no new Nix package.
- **`AskUserQuestion` goes through `PreToolUse`; `ExitPlanMode` and tool permissions go through `PermissionRequest`.** Matches the docs' enumeration: `AskUserQuestion` is listed only under `PreToolUse` matchers. Script defensively skips `AskUserQuestion` if it somehow appears on `PermissionRequest` (no dupes).
- **No visual distinction between Stop/PreToolUse/PermissionRequest notifs in v1.** OSC body text disambiguates ("Claude finished responding" vs "Claude has a question" vs "Claude wants to use Bash"). Revisit if it feels muddy.
- **`terminalSequence` only.** Drop the TTY walker, drop the tmux DCS branch, drop the test seams. Requires Claude Code v2.1.141+; document the minimum version in the README.
- **README documents `preferredNotifChannel: "notifications_disabled"` as a prerequisite**, with both the JSON-snippet path and the `/config` path. Link to Claude Code's settings reference; it's a documented option, no caveats needed.
- **No app-side Swift changes.** The existing OSC 777 path through `app/GhosttyApp.swift:438` -> `app/Update.swift:810-839` handles all desktop notifications generically.

## File changes

### 1. `integrations/claude-code/claude-notify-osc777.sh`

Rewrite the script around `terminalSequence`. The replacement is short enough to give in full:

```bash
#!/usr/bin/env bash

# Claude Code hook: emits an OSC 777 desktop notification so DanTerm can
# show it with pane awareness. Returns the sequence via stdout JSON
# (`terminalSequence`); Claude Code v2.1.141+ handles emitting it,
# including tmux passthrough, so this script does not touch /dev/tty.
# The Nix package provides jq on PATH; non-Nix installs must do the same.

INPUT=$(cat)

# Subagent contexts (Task tool, Explore, Plan, etc.) re-fire hooks; skip
# them so only the main agent's turn notifies.
if [ -n "$(printf '%s' "$INPUT" | jq -r '.agent_id // empty')" ]; then
  exit 0
fi

EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // "Stop"')
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' \
  | head -c 100 | LC_ALL=C tr -d '[:cntrl:]')

case "$EVENT" in
  Stop)
    # Untrusted model text: cap length and strip C0+DEL so it can't close
    # the OSC early (BEL) or inject another escape (ESC). terminalSequence
    # validates the OSC envelope but does not police the body.
    MSG=$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // empty' \
      | head -c 200 | LC_ALL=C tr -d '[:cntrl:]')
    MSG=${MSG:-Claude finished responding}
    ;;
  PreToolUse)
    case "$TOOL" in
      AskUserQuestion) MSG="Claude has a question" ;;
      *) exit 0 ;;  # Nix matcher restricts to AskUserQuestion; defensive bail.
    esac
    ;;
  PermissionRequest)
    case "$TOOL" in
      AskUserQuestion) exit 0 ;;  # already covered by PreToolUse.
      ExitPlanMode)    MSG="Claude is ready to exit plan mode" ;;
      "")              MSG="Claude needs your input" ;;
      *)               MSG="Claude wants to use $TOOL" ;;
    esac
    ;;
  *) exit 0 ;;
esac

# Build the OSC 777 sequence and hand it to Claude Code to emit.
SEQ=$(printf '\e]777;notify;Claude Code;%s\a' "$MSG")
jq -n --arg seq "$SEQ" '{terminalSequence: $seq}'
```

Removed from the current script: `find_ancestor_tty`, the `CLAUDE_NOTIFY_TTY` and `CLAUDE_NOTIFY_DEV_DIR` seams, the tmux DCS wrap branch, the `> /dev/tty` redirect.

### 2. `integrations/claude-code/claude-notify-osc777.test.sh`

Rewrite around stdout JSON assertions. The walker-shim machinery (`write_success_ps_shim`, `check_walker_success_case`, `check_walker_skip_case`, `check_nonfatal_write_case` -- roughly lines 70-289 of the current file) is no longer needed.

New shape:

```bash
#!/usr/bin/env bash
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SOURCE_SCRIPT="$SCRIPT_DIR/claude-notify-osc777.sh"
HOOK=${HOOK_UNDER_TEST:-$SOURCE_SCRIPT}

require_command() {
  command -v "$1" >/dev/null 2>&1 || { printf 'missing %s\n' "$1" >&2; exit 1; }
}
require_command jq

passed=0; failed=0; TOTAL=0

# expected_seq: the inner OSC 777 bytes the script should hand to Claude Code.
expected_seq() {
  printf '\e]777;notify;Claude Code;%s\a' "$1"
}

# Run the hook on the given JSON input and assert what it emits on stdout.
# expected_seq="" means "expect no output" (the script exits silently).
check_case() {
  local name=$1 input=$2 expected_seq=$3
  TOTAL=$((TOTAL + 1))

  local out
  out=$("$HOOK" <<<"$input") || {
    printf 'FAIL: %s (hook exited non-zero)\n' "$name" >&2
    failed=$((failed + 1)); return
  }

  if [ -z "$expected_seq" ]; then
    if [ -z "$out" ]; then
      passed=$((passed + 1)); return
    fi
    printf 'FAIL: %s (expected silent, got JSON)\n' "$name" >&2
    printf 'actual: %s\n' "$out" >&2
    failed=$((failed + 1)); return
  fi

  local actual_seq
  actual_seq=$(printf '%s' "$out" | jq -r '.terminalSequence // empty')
  if [ "$actual_seq" = "$expected_seq" ]; then
    passed=$((passed + 1)); return
  fi

  printf 'FAIL: %s\n' "$name" >&2
  printf 'expected seq bytes:\n' >&2; printf '%s' "$expected_seq" | od -c >&2
  printf 'actual seq bytes:\n'   >&2; printf '%s' "$actual_seq"   | od -c >&2
  failed=$((failed + 1))
}

# --- Stop event ---

check_case "stop: hello" \
  '{"hook_event_name":"Stop","last_assistant_message":"hello"}' \
  "$(expected_seq hello)"

check_case "stop: fallback" \
  '{"hook_event_name":"Stop"}' \
  "$(expected_seq 'Claude finished responding')"

# Sanitization: jq encodes raw control bytes as \u00XX; the script must strip
# them after JSON decoding.
sanitize_msg=$(printf 'hi\033]9;evil\007there')
sanitize_input=$(jq -c -n --arg m "$sanitize_msg" \
  '{hook_event_name:"Stop", last_assistant_message:$m}')
check_case "stop: sanitization" \
  "$sanitize_input" \
  "$(expected_seq 'hi]9;evilthere')"

# Subagent context (agent_id present) is skipped on every event.
check_case "stop: subagent ignored" \
  '{"hook_event_name":"Stop","agent_id":"agent-1","last_assistant_message":"x"}' \
  ""

# --- PreToolUse event ---

check_case "pretooluse: AskUserQuestion" \
  '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}' \
  "$(expected_seq 'Claude has a question')"

check_case "pretooluse: other tool is silent" \
  '{"hook_event_name":"PreToolUse","tool_name":"Bash"}' \
  ""

check_case "pretooluse: subagent ignored" \
  '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","agent_id":"a1"}' \
  ""

# --- PermissionRequest event ---

check_case "permission: ExitPlanMode" \
  '{"hook_event_name":"PermissionRequest","tool_name":"ExitPlanMode"}' \
  "$(expected_seq 'Claude is ready to exit plan mode')"

check_case "permission: Bash" \
  '{"hook_event_name":"PermissionRequest","tool_name":"Bash"}' \
  "$(expected_seq 'Claude wants to use Bash')"

check_case "permission: empty tool" \
  '{"hook_event_name":"PermissionRequest"}' \
  "$(expected_seq 'Claude needs your input')"

# AskUserQuestion under PermissionRequest is suppressed to avoid duplicates
# with the PreToolUse branch.
check_case "permission: AskUserQuestion suppressed" \
  '{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion"}' \
  ""

# tool_name with embedded control bytes must be sanitized in the OSC body.
permission_sanitize_input=$(jq -c -n --arg t "$(printf 'Ev\033il')" \
  '{hook_event_name:"PermissionRequest", tool_name:$t}')
check_case "permission: sanitization" \
  "$permission_sanitize_input" \
  "$(expected_seq 'Claude wants to use Evil')"

check_case "permission: subagent ignored" \
  '{"hook_event_name":"PermissionRequest","tool_name":"Bash","agent_id":"a1"}' \
  ""

# --- Unknown event ---

check_case "unknown event is silent" \
  '{"hook_event_name":"FooBar"}' \
  ""

if [ "$failed" -eq 0 ]; then
  printf 'OK: %s/%s cases passed.\n' "$passed" "$TOTAL"; exit 0
fi
printf 'FAILED: %s/%s passed, %s failed.\n' "$passed" "$TOTAL" "$failed" >&2
exit 1
```

13 cases (matches the existing count, by coincidence -- the rewrite is not aiming for case parity). Track `TOTAL` dynamically rather than hard-coding to avoid the "remember to bump the constant" trap.

### 3. `flake.nix`

Remove `coreutils` from the check derivation's `nativeBuildInputs` if it's only there for the TTY shim plumbing; otherwise no changes. The same `danterm-claude-notify-osc777` binary serves all three hook events.

### 4. `README.md` (current lines 103-148)

Rewrite the "Claude Code Integration" section:

- Replace the opening paragraph ("For some reason, Claude Code seems to wait 1-2 minutes...") with an accurate explanation: Claude Code's default notification path waits on a ~60-second idle timer; DanTerm ships hooks that bypass that for immediate per-pane notifs.
- Insert a **Requirements** subsection: Claude Code v2.1.141+ (for `terminalSequence`).
- Insert a **Prerequisite** subsection before the Nix snippet: tell users to disable Claude Code's native notification channel so it doesn't duplicate the hook path. Two paths:
  - JSON: add `"preferredNotifChannel": "notifications_disabled"` to `~/.claude/settings.json` (or project-local equivalent).
  - Interactive: toggle the corresponding option via `/config` inside Claude Code.
  - Consequence of skipping: late ghost notifs roughly every turn, often from panes the user has already tabbed away from.
- Update the example JSON hooks block to include all three: `Stop` (no matcher), `PreToolUse` (matcher `"AskUserQuestion"`), and `PermissionRequest` (no matcher), each pointing at the same binary, each `timeout: 10`.
- Drop the closing "Dunno what's wrong with Claude Code" remark from the Codex section (line 148).

### 5. `~/world/common/claude-code.nix` (out-of-repo, user's dotfiles)

Three additions to the `settings` attrset (lines 22-185):

- Near the top of the attrset (alongside `alwaysThinkingEnabled`, `effortLevel`, etc.): `preferredNotifChannel = "notifications_disabled";`.
- Alongside the existing `hooks.Stop` block (lines 133-144), add two sibling blocks pointing at the same binary, `timeout = 10`:

```nix
PreToolUse = [
  {
    matcher = "AskUserQuestion";
    hooks = [
      {
        type = "command";
        command = "${pkgs.danterm-claude-notify-osc777}/bin/danterm-claude-notify-osc777";
        timeout = 10;
      }
    ];
  }
];
PermissionRequest = [
  {
    hooks = [
      {
        type = "command";
        command = "${pkgs.danterm-claude-notify-osc777}/bin/danterm-claude-notify-osc777";
        timeout = 10;
      }
    ];
  }
];
```

This change lives in the dotfiles repo, not the danterm repo; follow-up commit there after the danterm flake input is updated.

## Critical files

- `integrations/claude-code/claude-notify-osc777.sh` -- full rewrite around `terminalSequence`
- `integrations/claude-code/claude-notify-osc777.test.sh` -- full rewrite, stdout JSON assertions, walker-shim machinery deleted
- `README.md` (lines 103-148) -- prerequisite doc, version note, JSON snippet update
- `~/world/common/claude-code.nix` (lines 22-185) -- settings additions, out-of-repo

Reference, no edits:
- `app/GhosttyApp.swift:438` -- OSC notification dispatch
- `app/Update.swift:810-839` -- focus-aware desktop notif handling (note: focused pane returns `[]` before alert creation; no alert row is recorded)
- `flake.nix` (lines 16-46) -- package definition + check derivation; the test harness still works because the hook binary now writes to stdout, which the test captures the same way it captured the seam file

## Verification

Automated:

1. From the danterm repo, run the hook test suite directly: `bash integrations/claude-code/claude-notify-osc777.test.sh`. All cases pass.
2. `nix flake check` -- runs the test against the built `danterm-claude-notify-osc777` binary on every hook system (`aarch64-darwin`, `x86_64-linux`). Must pass.

Manual smoke test after `world:rebuild` activates the new settings:

3. Open a DanTerm pane, run `/copy` something inside Claude Code, tab away, wait ~90 seconds. **Expect**: no banner. Confirms the native channel is silenced and the Stop hook's focus suppression worked at t=0.
4. Ask Claude something that triggers `AskUserQuestion`, tab away. **Expect**: immediate banner with body "Claude has a question".
5. Run a Bash command that is not in the user's permission allowlist, tab away. **Expect**: immediate banner with body "Claude wants to use Bash".
6. Enter plan mode, have Claude produce a plan, tab away while it pauses on ExitPlanMode. **Expect**: immediate banner with body "Claude is ready to exit plan mode".
7. Run a long task, stay focused on the originating pane throughout. **Expect**: no banner *and* no row in the alerts popover -- per `Update.swift:810-814`, the focused-pane branch returns before any alert is created.

Regression check:

8. Confirm exactly one OSC 777 reaches the terminal per turn. The originating pane must be **unfocused** before the turn completes (focus suppression at `Update.swift:810-814` drops both the banner and the alert row for the focused pane, masking duplicates). Start a turn, tab away, wait until well past the 60s `idle_prompt` mark, then open the alerts popover for that pane -- there should be exactly one row, not two.

## Follow Up

- Update `/Users/dan/world/common/claude-code.nix` after consuming this DanTerm commit: set `preferredNotifChannel = "notifications_disabled";` and add `PreToolUse` and `PermissionRequest` hooks that call `pkgs.danterm-claude-notify-osc777`.
