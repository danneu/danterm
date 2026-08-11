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

export DANTERM_SOCK=/tmp/danterm.sock
export DANTERM_PANE=11111111-1111-4111-8111-111111111111
check_case "session start attaches silently" \
  '{"hook_event_name":"SessionStart","session_id":"4f3a2b1c-0000-4000-9000-abcdef123456"}' \
  'agent attach --pane 11111111-1111-4111-8111-111111111111 --kind claude --id 4f3a2b1c-0000-4000-9000-abcdef123456'

check_case "prompt submit reports working" \
  '{"hook_event_name":"UserPromptSubmit","session_id":"4f3a2b1c"}' \
  'agent activity --pane 11111111-1111-4111-8111-111111111111 --kind claude --id 4f3a2b1c --state working'
check_case "root question reports waiting" \
  '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","session_id":"4f3a2b1c"}' \
  'agent activity --pane 11111111-1111-4111-8111-111111111111 --kind claude --id 4f3a2b1c --state waiting'
check_case "permission request reports waiting" \
  '{"hook_event_name":"PermissionRequest","tool_name":"Bash","session_id":"4f3a2b1c"}' \
  'agent activity --pane 11111111-1111-4111-8111-111111111111 --kind claude --id 4f3a2b1c --state waiting'
check_case "elicitation reports waiting" \
  '{"hook_event_name":"Elicitation","session_id":"4f3a2b1c"}' \
  'agent activity --pane 11111111-1111-4111-8111-111111111111 --kind claude --id 4f3a2b1c --state waiting'
check_case "ordinary tool use is ignored" \
  '{"hook_event_name":"PreToolUse","tool_name":"Bash","session_id":"4f3a2b1c"}'
# request_user_input is codex's ask-user tool. Claude never sends it, so matching
# it here would be a check that can only ever fire on a payload we do not receive.
check_case "codex ask-user tool name is not matched" \
  '{"hook_event_name":"PreToolUse","tool_name":"request_user_input","session_id":"4f3a2b1c"}'
check_case "root stop reports idle" \
  '{"hook_event_name":"Stop","session_id":"4f3a2b1c","background_tasks":[]}' \
  'agent activity --pane 11111111-1111-4111-8111-111111111111 --kind claude --id 4f3a2b1c --state idle'
check_case "parked root stop does not report idle" \
  '{"hook_event_name":"Stop","session_id":"4f3a2b1c","background_tasks":[{"status":"running"}]}'
check_case "session end detaches" \
  '{"hook_event_name":"SessionEnd","session_id":"4f3a2b1c"}' \
  'agent detach --pane 11111111-1111-4111-8111-111111111111 --kind claude --id 4f3a2b1c'
check_case "subagent event is ignored" \
  '{"hook_event_name":"Stop","session_id":"4f3a2b1c","agent_id":"worker-1"}'

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
