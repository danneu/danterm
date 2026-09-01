# Codex

DanTerm gives Codex two things: a skill that lets it drive tabs and panes, and
notifications that name the pane they came from.

Check the whole integration at any time:

```sh
danterm doctor  # Check permissions, CLI, hooks, skills, jq, and configured font.
danterm skill   # Print the bundled agent instructions.
```

## The skill

The skill teaches Codex to control tabs and panes, read output, send keys,
switch themes, and manage to-do items. Its source is
[`integrations/danterm/SKILL.md`](../../integrations/danterm/SKILL.md).

Install it from a local clone, then restart the agent:

```sh
mkdir -p ~/.codex/skills
ln -s /absolute/path/to/danterm/integrations/danterm ~/.codex/skills/danterm
```

Verify it with `/skills` inside Codex.

## Notifications

Point Codex at the terminal's own notification channel in
`~/.codex/config.toml`:

```toml
[tui]
notification_method = "osc9"
```

Restart existing Codex sessions after changing this setting.

Running Codex inside tmux needs one more setting, and Codex must wrap its own
sequences for it to help -- see [tmux.md](tmux.md).
