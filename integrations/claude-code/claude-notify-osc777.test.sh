#!/usr/bin/env bash
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SOURCE_SCRIPT="$SCRIPT_DIR/claude-notify-osc777.sh"
HOOK=${HOOK_UNDER_TEST:-$SOURCE_SCRIPT}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing %s\n' "$1" >&2
    exit 1
  }
}
require_command jq

passed=0
failed=0
TOTAL=0

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
    failed=$((failed + 1))
    return
  }

  if [ -z "$expected_seq" ]; then
    if [ -z "$out" ]; then
      passed=$((passed + 1))
      return
    fi
    printf 'FAIL: %s (expected silent, got JSON)\n' "$name" >&2
    printf 'actual: %s\n' "$out" >&2
    failed=$((failed + 1))
    return
  fi

  local actual_seq
  actual_seq=$(printf '%s' "$out" | jq -r '.terminalSequence // empty')
  if [ "$actual_seq" = "$expected_seq" ]; then
    passed=$((passed + 1))
    return
  fi

  printf 'FAIL: %s\n' "$name" >&2
  printf 'expected seq bytes:\n' >&2
  printf '%s' "$expected_seq" | od -c >&2
  printf 'actual seq bytes:\n' >&2
  printf '%s' "$actual_seq" | od -c >&2
  failed=$((failed + 1))
}

# --- Stop event ---

check_case "stop: hello" \
  '{"hook_event_name":"Stop","last_assistant_message":"hello"}' \
  "$(expected_seq hello)"

check_case "stop: fallback" \
  '{"hook_event_name":"Stop"}' \
  "$(expected_seq 'Claude finished responding')"

check_case "stop: agent_type without agent_id not subagent" \
  '{"hook_event_name":"Stop","agent_type":"planner","last_assistant_message":"still main"}' \
  "$(expected_seq 'still main')"

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

check_case "subagentstop: subagent ignored" \
  '{"hook_event_name":"SubagentStop","agent_id":"agent-1","last_assistant_message":"x"}' \
  ""

# --- Stop while background work is pending (the "parked to wait" case) ---
# A main-thread Stop fires the moment Claude launches background agents and
# parks; that is not "done responding", so it must stay quiet.

check_case "stop: parked on running background agent suppressed" \
  '{"hook_event_name":"Stop","last_assistant_message":"2 background agents launched","background_tasks":[{"id":"t1","type":"subagent","status":"running","description":"Research"}]}' \
  ""

check_case "stop: mixed completed+running background tasks suppressed" \
  '{"hook_event_name":"Stop","last_assistant_message":"x","background_tasks":[{"id":"t1","type":"subagent","status":"completed"},{"id":"t2","type":"subagent","status":"running"}]}' \
  ""

# Unknown/future status counts as active (bias to quiet).
check_case "stop: unknown background status suppressed" \
  '{"hook_event_name":"Stop","last_assistant_message":"x","background_tasks":[{"id":"t1","type":"workflow","status":"reticulating"}]}' \
  ""

# Once every background task is terminal, the main-thread Stop is genuine
# completion and notifies normally.
check_case "stop: all background tasks terminal notifies" \
  '{"hook_event_name":"Stop","last_assistant_message":"all done","background_tasks":[{"id":"t1","type":"subagent","status":"completed"},{"id":"t2","type":"subagent","status":"failed"}]}' \
  "$(expected_seq 'all done')"

# Empty background_tasks (or the field absent on older Claude) notifies.
check_case "stop: empty background_tasks notifies" \
  '{"hook_event_name":"Stop","last_assistant_message":"hi","background_tasks":[]}' \
  "$(expected_seq hi)"

# --- PreToolUse event ---

check_case "pretooluse: AskUserQuestion" \
  '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}' \
  "$(expected_seq 'Claude has a question')"

check_case "pretooluse: other tool is silent" \
  '{"hook_event_name":"PreToolUse","tool_name":"Bash"}' \
  ""

check_case "pretooluse: subagent AskUserQuestion alerts" \
  '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","agent_id":"a1"}' \
  "$(expected_seq 'Claude has a question')"

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

check_case "permission: subagent Bash alerts" \
  '{"hook_event_name":"PermissionRequest","tool_name":"Bash","agent_id":"a1"}' \
  "$(expected_seq 'Claude wants to use Bash')"

check_case "permission: subagent AskUserQuestion suppressed" \
  '{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","agent_id":"a1"}' \
  ""

# --- Elicitation event ---

elicitation_sanitize_input=$(jq -c -n --arg m "$(printf 'Need\033 input\007 now')" \
  '{hook_event_name:"Elicitation", message:$m}')
check_case "elicitation: sanitization" \
  "$elicitation_sanitize_input" \
  "$(expected_seq 'Need input now')"

check_case "elicitation: subagent alerts" \
  '{"hook_event_name":"Elicitation","agent_id":"a1","message":"Need input"}' \
  "$(expected_seq 'Need input')"

# Claude 2.1.216 omits agent identity on Elicitation even when the preceding
# MCP PreToolUse carries agent_id. Blocking behavior is still unambiguous.
check_case "elicitation: current subagent payload without identity alerts" \
  '{"hook_event_name":"Elicitation","mcp_server_name":"live-notification-fixture","message":"DANTERM_LIVE_ELICITATION","mode":"form","requested_schema":{"type":"object"}}' \
  "$(expected_seq 'DANTERM_LIVE_ELICITATION')"

check_case "elicitation: fallback" \
  '{"hook_event_name":"Elicitation"}' \
  "$(expected_seq 'Claude needs your input')"

# --- Unknown event ---

check_case "unknown event is silent" \
  '{"hook_event_name":"FooBar"}' \
  ""

if [ "$failed" -eq 0 ]; then
  printf 'OK: %s/%s cases passed.\n' "$passed" "$TOTAL"
  exit 0
fi

printf 'FAILED: %s/%s passed, %s failed.\n' "$passed" "$TOTAL" "$failed" >&2
exit 1
