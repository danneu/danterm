#!/usr/bin/env bash

# Codex SessionStart hook: report the current Codex session id to DanTerm so
# the pane toolbar and crash-recovery checkpoint know which conversation was
# active. Success and no-op paths are stdout-silent because Codex adds
# SessionStart hook stdout as extra developer context.

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

danterm agent attach --kind codex --id "$SESSION_ID" >/dev/null 2>&1 || true
exit 0
