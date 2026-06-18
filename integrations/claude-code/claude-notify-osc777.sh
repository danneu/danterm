#!/usr/bin/env bash

# Claude Code hook: emits OSC 777 desktop notifications so DanTerm can show
# them with pane awareness. Top-level turn completion notifies, subagent
# completion stays quiet, a top-level turn that merely PARKS to wait on
# still-running background work (background agents/workflows/shells) stays
# quiet, and blocking prompts notify from any agent context.
# Returns the sequence via stdout JSON (`terminalSequence`); Claude Code
# v2.1.141+ handles emitting it, including tmux passthrough, so this script
# does not touch /dev/tty.
# The Nix package provides jq on PATH; non-Nix installs must do the same.

INPUT=$(cat)

EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // "Stop"')
AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty')
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' \
  | head -c 100 | LC_ALL=C tr -d '[:cntrl:]')

case "$EVENT" in
  Stop)
    # Subagent completion re-fires completion hooks. Suppress only when Claude
    # gives the explicit subagent discriminator; agent_type is metadata.
    if [ -n "$AGENT_ID" ]; then
      exit 0
    fi
    # A main-thread Stop ALSO fires when Claude merely parks to wait on
    # background work it just launched: background agents/workflows/shells land
    # in `.background_tasks` (each `{type,status,...}`). That stop is "yielded to
    # wait", not "done responding", so stay quiet while any task is non-terminal.
    # Bias to quiet: an unrecognized/missing status counts as active. Genuine
    # completion -- registry empty (or absent on older Claude) or every task
    # terminal -- still notifies.
    ACTIVE_BG=$(printf '%s' "$INPUT" | jq '
      [ (.background_tasks // [])[]
        | (.status // "" | ascii_downcase)
        | select(test("^(completed|complete|done|succeeded|failed|errored|cancelled|canceled|killed|stopped)$") | not)
      ] | length')
    if [ "${ACTIVE_BG:-0}" != "0" ]; then
      exit 0
    fi
    # Untrusted model text: cap length and strip C0+DEL so it can't close
    # the OSC early (BEL) or inject another escape (ESC). terminalSequence
    # validates the OSC envelope but does not police the body.
    MSG=$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // empty' \
      | head -c 200 | LC_ALL=C tr -d '[:cntrl:]')
    MSG=${MSG:-Claude finished responding}
    ;;
  SubagentStop)
    exit 0
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
  Elicitation)
    MSG=$(printf '%s' "$INPUT" | jq -r '.message // empty' \
      | head -c 200 | LC_ALL=C tr -d '[:cntrl:]')
    MSG=${MSG:-Claude needs your input}
    ;;
  *) exit 0 ;;
esac

# Build the OSC 777 sequence and hand it to Claude Code to emit.
SEQ=$(printf '\e]777;notify;Claude Code;%s\a' "$MSG")
jq -n --arg seq "$SEQ" '{terminalSequence: $seq}'
