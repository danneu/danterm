# <img src="icon/raw-readme.svg" width="64" height="64" alt="DanTerm icon" align="center" style="vertical-align: middle;"> danterm

DanTerm is a fast macOS terminal built in Swift. It has vertical tabs, split
panes, tab groups, clear alerts, and no web runtime.

![DanTerm screenshot](docs/screenshot/screenshot1.png)

## Human-written section

This section is human maintained.

### Why did I build this?

First, I wanted a terminal app with these non-negotiable features:

- Vertical tabs
- Split panes

I was using iTerm2 for that for over a decade, but latetly I've had
annoyances with iTerm2 and the hubris to build my own solution using LLMs.

My first iterations used libghostty for the terminal impl which worked well
enough, but after five months of waiting for libghostty to publish a release
to fix a memory link issue I reported, that's all I needed to have the hubris
to build my own terminal engine with LLMs which took three weeks.

It's pretty fun to vibe-code a tool so central to my workflow. If something
doesn't work exactly how I want it, I open a new tab and tell an LLM to change it.

I also experiment with crazy things like unsupervised performance tuning where
an agent will fan out subagents to look for major perf issues, rank them by
confidence/impact, and automatically verify them using the built-in benchmark
ssytem.

## Features

- Vertical tabs and collapsible tab groups
- Split panes that inherit the current working directory
- Persistent pane alerts and macOS notifications
- Click a notification to focus its pane
- Local and remote themes
- Save and restore windows, tabs, panes, and commands after shell integration
  is enabled
- A command-line interface for scripts and coding agents

Cmd-click opens web links. Hold Shift while selecting text or clicking a link
when a program such as tmux or Vim has captured the mouse.

## Install

Download the latest `.dmg` from
[GitHub Releases](https://github.com/danneu/danterm/releases/latest), then move
DanTerm to `/Applications`.

If your shell tools need them, grant DanTerm access in System Settings under
Privacy & Security:

- Full Disk Access
- Developer Tools

### Nix

Add the flake and Home Manager module:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager.url = "github:nix-community/home-manager";
    danterm.url = "github:danneu/danterm";
  };

  outputs = { nixpkgs, home-manager, danterm, ... }: {
    homeConfigurations.myuser = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages.aarch64-darwin;
      modules = [
        danterm.homeManagerModules.default
        { programs.danterm.enable = true; }
      ];
    };
  };
}
```

## Configure

Press Cmd+, to edit settings. DanTerm stores them in
`~/.config/danterm/config.json`.

```json
{
  "schemaVersion": 1,
  "font": { "size": 14 },
  "theme": { "default": "Dracula", "remote": "Purplepeter" },
  "ui": { "alertClearMode": "focus", "copyOnSelect": true }
}
```

Press Cmd+Shift+, to reload the file.

Keep alerts until you dismiss them:

```json
{
  "ui": { "alertClearMode": "manual" }
}
```

Nix users can keep the writable config in a dotfiles repository:

```nix
programs.danterm.configPath = "/Users/me/src/dotfiles/danterm/config.json";
```

## Shell integration

Shell integration lets DanTerm track working directories, commands, and remote
sessions. Home Manager users can enable it for each enabled shell:

```nix
programs.danterm.shellIntegration.enable = true;
```

For a normal app install, add the matching line to your shell config:

```sh
# ~/.zshrc
if [[ -n ${DANTERM_SHELL_INTEGRATION_DIR:-} ]]; then
  source "$DANTERM_SHELL_INTEGRATION_DIR/danterm.zsh"
fi

# ~/.bashrc
if [[ -n ${DANTERM_SHELL_INTEGRATION_DIR:-} ]]; then
  source "$DANTERM_SHELL_INTEGRATION_DIR/danterm.bash"
fi

# ~/.config/fish/config.fish
if set -q DANTERM_SHELL_INTEGRATION_DIR; and test -n "$DANTERM_SHELL_INTEGRATION_DIR"
  source "$DANTERM_SHELL_INTEGRATION_DIR/danterm.fish"
end
```

For remote labels:

```sh
scp -r /Applications/DanTerm.app/Contents/Resources/shell-integration \
  user@host:~/.danterm-shell-integration

# Run from the remote shell config. Use .bash or .fish for those shells.
source ~/.danterm-shell-integration/danterm.zsh
```

```sshconfig
# /etc/ssh/sshd_config
AcceptEnv LC_*
```

## Agent Skill

Run these commands after installing DanTerm:

```sh
danterm doctor  # Check CLI, hook, skill, and jq setup.
danterm skill   # Print the bundled agent instructions.
```

The bundled skill teaches Claude Code and Codex to control tabs and panes, read
output, send keys, switch themes, and manage to-do items. Its source and setup
instructions are in [`integrations/danterm/`](integrations/danterm).

Install the skill from a local clone, then restart the agent:

```sh
mkdir -p ~/.claude/skills ~/.codex/skills
ln -s /absolute/path/to/danterm/integrations/danterm ~/.claude/skills/danterm
ln -s /absolute/path/to/danterm/integrations/danterm ~/.codex/skills/danterm
```

Verify it in Claude Code or Codex:

```text
/skills
```

For immediate Claude Code alerts, add this to `~/.claude/settings.json`:

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

To make Codex use DanTerm notifications, add this to `~/.codex/config.toml`:

```toml
[tui]
notification_method = "osc9"
```

Restart existing Codex sessions after changing this setting.

## Shortcuts

| Action            | Shortcut          |
| ----------------- | ----------------- |
| New tab           | Cmd+T             |
| Close pane        | Cmd+W             |
| Close tab         | Cmd+Shift+W       |
| Split right       | Cmd+D             |
| Split down        | Cmd+Shift+D       |
| Focus panes       | Cmd+Shift+H/J/K/L |
| Zoom pane         | Cmd+Enter         |
| Theme browser     | Cmd+Shift+B       |
| Next alert        | Cmd+Shift+A       |
| Clear pane alerts | Cmd+Shift+.       |
| Preferences       | Cmd+,             |
| Reload config     | Cmd+Shift+,       |

The app menus list all shortcuts.

## Command-line interface

```sh
danterm ls
danterm tab new --cmd 'just test'
danterm pane split -h
danterm pane read --pane "$DANTERM_PANE" --lines 50
```

See [`integrations/danterm/SKILL.md`](integrations/danterm/SKILL.md) for all
commands and examples.

Terminal behavior is defined by the
[terminal capability contract](docs/terminal-capabilities.md).

## Develop

```sh
bash ./dev-build.sh --no-install  # Build without replacing an installed app.
just provision-worktree           # Run once in a new Git worktree.
just launch-slot                  # Run an isolated development copy.
just test                         # Run the test suite.
```
