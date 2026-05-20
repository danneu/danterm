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
      ExitPlanMode) MSG="Claude is ready to exit plan mode" ;;
      "") MSG="Claude needs your input" ;;
      *) MSG="Claude wants to use $TOOL" ;;
    esac
    ;;
  *) exit 0 ;;
esac

# Build the OSC 777 sequence and hand it to Claude Code to emit.
SEQ=$(printf '\e]777;notify;Claude Code;%s\a' "$MSG")
jq -n --arg seq "$SEQ" '{terminalSequence: $seq}'
