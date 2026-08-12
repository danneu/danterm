#!/usr/bin/env bash

# Claude Code root-session hook: report only explicit attachment, activity, and
# detach transitions to the owning DanTerm pane. Success and no-op paths are
# stdout-silent because Claude injects hook stdout into its prompt context.

INPUT=$(cat)

if [ -z "${DANTERM_SOCK:-}" ] || [ -z "${DANTERM_PANE:-}" ]; then
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi
if ! command -v danterm >/dev/null 2>&1; then
  exit 0
fi

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
if [ -z "$SESSION_ID" ]; then
  exit 0
fi

EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty')
AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty')
if [ -n "$AGENT_ID" ]; then
  exit 0
fi

case "$EVENT" in
  SessionStart)
    danterm agent attach --pane "$DANTERM_PANE" --kind claude --id "$SESSION_ID" >/dev/null 2>&1 || true
    ;;
  UserPromptSubmit)
    danterm agent activity --pane "$DANTERM_PANE" --kind claude --id "$SESSION_ID" --state working >/dev/null 2>&1 || true
    ;;
  PreToolUse)
    TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
    if [ "$TOOL" = "AskUserQuestion" ]; then
      danterm agent activity --pane "$DANTERM_PANE" --kind claude --id "$SESSION_ID" --state waiting >/dev/null 2>&1 || true
    fi
    ;;
  PostToolUse)
    TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
    if [ "$TOOL" = "AskUserQuestion" ]; then
      danterm agent activity --pane "$DANTERM_PANE" --kind claude --id "$SESSION_ID" --state working >/dev/null 2>&1 || true
    fi
    ;;
  PermissionRequest|Elicitation)
    danterm agent activity --pane "$DANTERM_PANE" --kind claude --id "$SESSION_ID" --state waiting >/dev/null 2>&1 || true
    ;;
  Stop)
    HAS_RUNNING_BACKGROUND=$(printf '%s' "$INPUT" | jq -r '[.background_tasks[]? | select(.status == "running")] | length > 0')
    if [ "$HAS_RUNNING_BACKGROUND" != "true" ]; then
      danterm agent activity --pane "$DANTERM_PANE" --kind claude --id "$SESSION_ID" --state idle >/dev/null 2>&1 || true
    fi
    ;;
  SessionEnd)
    danterm agent detach --pane "$DANTERM_PANE" --kind claude --id "$SESSION_ID" >/dev/null 2>&1 || true
    ;;
esac
exit 0
