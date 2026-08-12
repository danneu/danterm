#!/usr/bin/env bash

# Codex root-session hook: report only explicit attachment, activity, and detach
# transitions to the owning DanTerm pane. Success and no-op paths are
# stdout-silent because Codex adds hook stdout as extra developer context.

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
# Inert as of codex 0.147.0: no recorded payload carries agent_id. Codex signals
# subagent work with SubagentStart / SubagentStop instead, and whether the events
# between them reuse the root session_id is untested -- so this guard stays until
# a subagent run says which filter is the right one.
AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty')
if [ -n "$AGENT_ID" ]; then
  exit 0
fi

case "$EVENT" in
  SessionStart)
    danterm agent attach --pane "$DANTERM_PANE" --kind codex --id "$SESSION_ID" >/dev/null 2>&1 || true
    ;;
  UserPromptSubmit)
    danterm agent activity --pane "$DANTERM_PANE" --kind codex --id "$SESSION_ID" --state working >/dev/null 2>&1 || true
    ;;
  PreToolUse)
    TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
    if [ "$TOOL" = "request_user_input" ]; then
      danterm agent activity --pane "$DANTERM_PANE" --kind codex --id "$SESSION_ID" --state waiting >/dev/null 2>&1 || true
    fi
    ;;
  Stop)
    danterm agent activity --pane "$DANTERM_PANE" --kind codex --id "$SESSION_ID" --state idle >/dev/null 2>&1 || true
    ;;
  SessionEnd)
    danterm agent detach --pane "$DANTERM_PANE" --kind codex --id "$SESSION_ID" >/dev/null 2>&1 || true
    ;;
esac
exit 0
