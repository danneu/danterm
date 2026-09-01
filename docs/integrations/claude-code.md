# Claude Code

DanTerm gives Claude Code two things: a skill that lets it drive tabs and
panes, and notifications that name the pane they came from.

Check the whole integration at any time:

```sh
danterm doctor  # Check permissions, CLI, hooks, skills, jq, and configured font.
danterm skill   # Print the bundled agent instructions.
```

## The skill

The skill teaches Claude Code to control tabs and panes, read output, send
keys, switch themes, and manage to-do items. Its source is
[`integrations/danterm/SKILL.md`](../../integrations/danterm/SKILL.md).

Install it from a local clone, then restart the agent:

```sh
mkdir -p ~/.claude/skills
ln -s /absolute/path/to/danterm/integrations/danterm ~/.claude/skills/danterm
```

Verify it with `/skills` inside Claude Code.

## Notifications

For immediate alerts, add this to `~/.claude/settings.json`:

```json
{
  "preferredNotifChannel": "notifications_disabled",
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Applications/DanTerm.app/Contents/Resources/danterm-hooks/danterm-claude-notify-osc777",
            "timeout": 10
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "AskUserQuestion",
        "hooks": [
          {
            "type": "command",
            "command": "/Applications/DanTerm.app/Contents/Resources/danterm-hooks/danterm-claude-notify-osc777",
            "timeout": 10
          }
        ]
      }
    ],
    "PermissionRequest": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Applications/DanTerm.app/Contents/Resources/danterm-hooks/danterm-claude-notify-osc777",
            "timeout": 10
          }
        ]
      }
    ],
    "Elicitation": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Applications/DanTerm.app/Contents/Resources/danterm-hooks/danterm-claude-notify-osc777",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

The hook notifies on a finished top-level turn and on any blocking prompt. It
stays quiet for a finished subagent, and for a turn that only parks to wait on
background work. Its source is
[`integrations/claude-code/claude-notify-osc777.sh`](../../integrations/claude-code/claude-notify-osc777.sh),
and it needs `jq` on `PATH` (the Nix package provides it).

Running Claude Code inside tmux needs one more setting -- see
[tmux.md](tmux.md).
