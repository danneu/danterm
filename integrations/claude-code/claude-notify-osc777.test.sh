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
  printf 'OK: %s/%s cases passed.\n' "$passed" "$TOTAL"
  exit 0
fi

printf 'FAILED: %s/%s passed, %s failed.\n' "$passed" "$TOTAL" "$failed" >&2
exit 1
