#!/usr/bin/env bash
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SOURCE_SCRIPT="$SCRIPT_DIR/danterm-agent-session.sh"
HOOK=${HOOK_UNDER_TEST:-$SOURCE_SCRIPT}

passed=0
failed=0
TOTAL=0

check_case() {
  local name=$1 input=$2 expect_invocation=${3:-}
  TOTAL=$((TOTAL + 1))

  local tmpdir out status
  tmpdir=$(mktemp -d)
  out="$tmpdir/out"
  status=0

  # The stub goes on PATH for every case, including the ones expecting silence:
  # without it a "no invocation" case would pass merely because no danterm exists
  # to find. NO_STUB=1 is for the case that tests exactly that absence.
  if [ "${NO_STUB:-0}" != "1" ]; then
    cat >"$tmpdir/danterm" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DANTERM_AGENT_STUB_LOG"
STUB
    chmod +x "$tmpdir/danterm"
  fi

  local old_path=${PATH:-}
  local old_log=${DANTERM_AGENT_STUB_LOG:-}
  local old_sock=${DANTERM_SOCK:-}
  local old_pane=${DANTERM_PANE:-}

  PATH="$tmpdir:$old_path"
  DANTERM_AGENT_STUB_LOG="$tmpdir/invocation"
  export PATH DANTERM_AGENT_STUB_LOG

  "$HOOK" <<<"$input" >"$out" 2>"$tmpdir/err" || status=$?

  PATH=$old_path
  if [ -n "$old_log" ]; then export DANTERM_AGENT_STUB_LOG="$old_log"; else unset DANTERM_AGENT_STUB_LOG; fi
  if [ -n "$old_sock" ]; then export DANTERM_SOCK="$old_sock"; else unset DANTERM_SOCK; fi
  if [ -n "$old_pane" ]; then export DANTERM_PANE="$old_pane"; else unset DANTERM_PANE; fi

  if [ "$status" -ne 0 ]; then
    printf 'FAIL: %s (hook exited %s)\n' "$name" "$status" >&2
    failed=$((failed + 1))
    rm -rf "$tmpdir"
    return
  fi
  if [ -s "$out" ]; then
    printf 'FAIL: %s (expected stdout silence)\n' "$name" >&2
    printf 'stdout: %s\n' "$(cat "$out")" >&2
    failed=$((failed + 1))
    rm -rf "$tmpdir"
    return
  fi
  if [ -n "$expect_invocation" ]; then
    if [ "$(cat "$tmpdir/invocation" 2>/dev/null)" != "$expect_invocation" ]; then
      printf 'FAIL: %s (wrong danterm invocation)\n' "$name" >&2
      printf 'expected: %s\n' "$expect_invocation" >&2
      printf 'actual: %s\n' "$(cat "$tmpdir/invocation" 2>/dev/null)" >&2
      failed=$((failed + 1))
      rm -rf "$tmpdir"
      return
    fi
  elif [ -s "$tmpdir/invocation" ]; then
    printf 'FAIL: %s (unexpected danterm invocation)\n' "$name" >&2
    failed=$((failed + 1))
    rm -rf "$tmpdir"
    return
  fi

  passed=$((passed + 1))
  rm -rf "$tmpdir"
}

# The payloads below are the field sets codex 0.147.0 was recorded emitting, not
# invented ones: every event carries session_id, transcript_path, cwd, model, and
# permission_mode, and every event but SessionStart and SessionEnd adds turn_id.
# Keeping the full set here means a codex release that renames or drops a field
# is caught by a case that already reads like the real thing.
SESSION=019ff23d-c60d-7022-ac1c-b57942b70021
TURN=019ff23d-c6dd-76c2-a023-d9a82b03ca6d
COMMON='"session_id":"'$SESSION'","transcript_path":"/tmp/rollout.jsonl","cwd":"/tmp/work","model":"gpt-5.6-sol","permission_mode":"bypassPermissions"'
TURN_COMMON="$COMMON"',"turn_id":"'$TURN'"'

export DANTERM_SOCK=/tmp/danterm.sock
export DANTERM_PANE=11111111-1111-4111-8111-111111111111
check_case "session start attaches silently" \
  '{'"$COMMON"',"hook_event_name":"SessionStart","source":"startup"}' \
  "agent attach --pane 11111111-1111-4111-8111-111111111111 --kind codex --id $SESSION"

check_case "prompt submit reports working" \
  '{'"$TURN_COMMON"',"hook_event_name":"UserPromptSubmit","prompt":"say hi"}' \
  "agent activity --pane 11111111-1111-4111-8111-111111111111 --kind codex --id $SESSION --state working"
check_case "request user input reports waiting" \
  '{'"$TURN_COMMON"',"hook_event_name":"PreToolUse","tool_name":"request_user_input","tool_input":{"questions":[]},"tool_use_id":"call_1"}' \
  "agent activity --pane 11111111-1111-4111-8111-111111111111 --kind codex --id $SESSION --state waiting"
# PermissionRequest carries no tool_use_id, unlike the tool events around it.
check_case "permission request reports waiting" \
  '{'"$TURN_COMMON"',"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls","description":"list files"}}' \
  "agent activity --pane 11111111-1111-4111-8111-111111111111 --kind codex --id $SESSION --state waiting"
check_case "ordinary tool use is ignored" \
  '{'"$TURN_COMMON"',"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"},"tool_use_id":"call_1"}'
# AskUserQuestion is Claude's ask-user tool. Codex never sends it, so matching it
# here would be a check that can only ever fire on a payload we do not receive.
check_case "claude ask-user tool name is not matched" \
  '{'"$TURN_COMMON"',"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{},"tool_use_id":"call_1"}'
check_case "tool completion is ignored" \
  '{'"$TURN_COMMON"',"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"},"tool_use_id":"call_1","tool_response":{"output":"hi"}}'
check_case "root stop reports idle" \
  '{'"$TURN_COMMON"',"hook_event_name":"Stop","last_assistant_message":"hi","stop_hook_active":false}' \
  "agent activity --pane 11111111-1111-4111-8111-111111111111 --kind codex --id $SESSION --state idle"
check_case "session end detaches" \
  '{'"$COMMON"',"hook_event_name":"SessionEnd","reason":"other"}' \
  "agent detach --pane 11111111-1111-4111-8111-111111111111 --kind codex --id $SESSION"
# No recorded codex payload carries agent_id; this pins the guard's behavior for
# the day one does.
check_case "subagent event is ignored" \
  '{'"$TURN_COMMON"',"hook_event_name":"Stop","agent_id":"worker-1"}'

unset DANTERM_SOCK
export DANTERM_PANE=11111111-1111-4111-8111-111111111111
check_case "missing socket is silent no-op" \
  '{"hook_event_name":"SessionStart","session_id":"4f3a2b1c"}'

export DANTERM_SOCK=/tmp/danterm.sock
unset DANTERM_PANE
check_case "missing pane is silent no-op" \
  '{"hook_event_name":"SessionStart","session_id":"4f3a2b1c"}'

export DANTERM_SOCK=/tmp/danterm.sock
export DANTERM_PANE=11111111-1111-4111-8111-111111111111
check_case "empty session id is silent no-op" \
  '{"hook_event_name":"SessionStart"}'

PATH=/usr/bin:/bin
export PATH
NO_STUB=1
check_case "missing cli is silent no-op" \
  '{"hook_event_name":"SessionStart","session_id":"4f3a2b1c"}'
unset NO_STUB

if [ "$failed" -eq 0 ]; then
  printf 'OK: %s/%s cases passed.\n' "$passed" "$TOTAL"
  exit 0
fi

printf 'FAILED: %s/%s passed, %s failed.\n' "$passed" "$TOTAL" "$failed" >&2
exit 1
