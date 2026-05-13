#!/usr/bin/env bash

# Claude Code Stop hook: sends an OSC 777 notification via the terminal
# so DanTerm can show it with pane awareness. The Nix package provides jq
# on PATH; non-Nix installs must do the same.

# Stop hooks also fire inside subagent contexts (Task tool / Explore / Plan /
# etc.). The docs say `agent_id` is "Present only when the hook fires inside
# a subagent call" -- skip those so only the main agent's turn notifies.
INPUT=$(cat)
if [ -n "$(printf '%s' "$INPUT" | jq -r '.agent_id // empty')" ]; then
  exit 0
fi

# Strip C0 controls + DEL so untrusted model text can't close the OSC
# early (BEL) or inject another escape (ESC); critical inside the tmux
# DCS branch where passthrough forwards sequences verbatim.
MSG=$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // empty' | head -c 200 | LC_ALL=C tr -d '[:cntrl:]')
MSG=${MSG:-Claude finished responding}

# CLAUDE_NOTIFY_TTY seam: if set, use that output path directly (tests
# inject a temp file here).
# CLAUDE_NOTIFY_DEV_DIR seam: device-directory prefix for the ancestor
# walker. Defaults to /dev; tests override it to capture output bytes.
: "${CLAUDE_NOTIFY_DEV_DIR:=/dev}"

# Claude Code 2.1.139+ runs hooks without terminal access, so opening
# /dev/tty from this hook can fail with ENXIO. Walk up from the hook's
# parent process and use the closest ancestor with a real tty instead.
find_ancestor_tty() {
  local pid=$PPID
  local i tty parent

  for ((i = 0; i < 20; i++)); do
    if [ -z "$pid" ] || [ "$pid" -le 1 ]; then
      return 1
    fi

    tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$tty" in
      ""|"?"|"??"|"-") ;;
      *)
        printf '%s/%s\n' "$CLAUDE_NOTIFY_DEV_DIR" "$tty"
        return 0
        ;;
    esac

    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -z "$parent" ]; then
      return 1
    fi
    pid=$parent
  done

  return 1
}

if [ -z "${CLAUDE_NOTIFY_TTY:-}" ]; then
  CLAUDE_NOTIFY_TTY=$(find_ancestor_tty) || exit 0
fi

if [ -n "$TMUX" ]; then
  # tmux swallows OSC 777; wrap in DCS passthrough (inner ESCs doubled).
  # Requires `set -g allow-passthrough on` in tmux.
  # Scope: visible/active pane only with `on`; `all` would cover background.
  # shellcheck disable=SC1003 # the `\\` is a literal pair of backslashes for printf, not a quote escape
  { printf '\ePtmux;\e\e]777;notify;Claude Code;%s\a\e\\' "$MSG" > "$CLAUDE_NOTIFY_TTY"; } 2>/dev/null || exit 0
else
  { printf '\e]777;notify;Claude Code;%s\a' "$MSG" > "$CLAUDE_NOTIFY_TTY"; } 2>/dev/null || exit 0
fi
