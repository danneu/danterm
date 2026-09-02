# <img src="icon/raw-readme.svg" width="64" height="64" alt="DanTerm icon" align="center" style="vertical-align: middle;"> danterm

danterm is a fast macOS terminal built in Swift with no third-party dependencies.

![DanTerm screenshot](docs/screenshot/screenshot1.png)

## Why?

I like vertical tabs, which for years meant using iTerm2 on macOS.

In the LLM era the terminal is becoming more and more central to my workflow,
not less. So, I decided to build my own to satisfy my own preferences.

It runs on its own Swift terminal engine -- grid, parser, renderer, and pty, with no third-party dependencies. It started as an AppKit wrapper around libghostty, but LLMs made writing the engine itself tractable, and the project doubles as a testbed for automating high-quality software with AI.

## Ideals

- Everything should be both keyboard- and mouse-driven
- The terminal engine should be reusable outside of danterm, embeddable by other projects
- Cross-platform

## Features

- Vertical tabs
- Split panes that inherit the current working directory
- Persistent pane alerts and macOS notifications (click a notification to focus its pane)
- Local and remote color themes
- Save, restore, and crash-recover tabs, panes, and the commands running in them
- Semantic pane states ("idle", "running command (make test)", "running agent claude (busy)") reported by shell and agent integrations
- Full control via `danterm` command-line interface for scripts and coding agents
- Remote IPC over a Tailscale tailnet ([docs](docs/tailnet.md))
- Config file
- Drive danterm running on macOS machine over Tailnet via iPhone app (Experimental)
- Linux GTK4 app (WIP)
- And much more

## Performance

Measured on a MacBookPro18,1 running macOS 26.5.2. Every terminal ran at
170x60 in Menlo 13.

### Throughput

`kitten __benchmark__ --render`, 3 reps, median MB/s as the kitten reported it.

| Test | danterm | ghostty 1.3.1 | iterm2 3.6.6 | kitty 0.48.2 |
| --- | --- | --- | --- | --- |
| Only ASCII chars | **127.2** | 87.9 | 12.7 | 105.5 |
| Unicode chars | **135.3** | 113.5 | 6.6 | 103.5 |
| Unique multi-codepoint Unicode cells | **53.3** | 47.1 | 1.1 | 23.0 |
| CSI codes with few chars | 47.5 | 41.4 | 1.3 | **59.3** |

The kitten times parsing, not rendering: terminals render asynchronously, and
`--render` only stops them from being asked not to.

### Memory

10 tabs, each running an inert `sleep`. Activity Monitor `phys_footprint`,
sampled every second for 10 seconds after a 5 second settle, median reported.
One rep, so read these as a rough ranking rather than a precise number.

| Terminal | 10 empty tabs | 10 tabs with scrollback |
| --- | --- | --- |
| danterm | **57 MB** | **248 MB** |
| iterm2 3.6.6 | 167 MB | 564 MB |
| kitty 0.48.2 | 239 MB | 788 MB |
| ghostty 1.3.1 | 793 MB | 1424 MB |

The scrollback case writes 10000 full-width lines per tab. iTerm2 and kitty were
capped at 10000 lines. danterm and Ghostty bound scrollback by bytes instead of
lines: danterm at 16 MB per pane (it kept all 10004 rows), Ghostty at 10 MB per
surface (retention not readable).

## Install

Requires macOS 26 on Apple Silicon.

Download the latest `.dmg` from
[GitHub Releases](https://github.com/danneu/danterm/releases/latest), then move
DanTerm to `/Applications`. Releases are Developer ID signed and notarized, and
the whole app is an 8 MB download.

If your shell tools need them, grant DanTerm Full Disk Access and Developer
Tools in System Settings under Privacy & Security.

### Nix

DanTerm ships a flake and a Home Manager module:
[docs/integrations/nix.md](docs/integrations/nix.md).

## Configure

Press Cmd+, to edit `~/.config/danterm/config.json`, Cmd+Shift+, to reload it.
Every setting has a default, so a new config file holds only
`{"schemaVersion": 1}`.

| Key                       | Default                | Meaning                                                                                                                          |
| ------------------------- | ---------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `font.family`             | system monospace       | Terminal font family. Omit the key to keep the system font.                                                                      |
| `font.size`               | `13`                   | Terminal font size, in points. Bounded to 8 through 72.                                                                          |
| `keyboard.optionAsAlt`    | native                 | Use `"left"`, `"right"`, or `"both"` to send that physical Option key as terminal Alt. Omit the key for native macOS text input. |
| `theme.default`           | `"Monokai Remastered"` | Theme for local panes.                                                                                                           |
| `theme.remote`            | `"Purplepeter"`        | Theme for panes in an SSH or other remote session.                                                                               |
| `shell.localeFallback`    | `true`                 | Give a local pane a UTF-8 `LANG` when it inherits none.                                                                          |
| `tailnet.listen`          | absent                 | Tailnet endpoint for remote IPC. See [docs/tailnet.md](docs/tailnet.md).                                                         |
| `tailnet.admittedNodeIds` | absent                 | Tailscale node ids allowed to use remote IPC. See [docs/tailnet.md](docs/tailnet.md).                                            |
| `tailnet.enable`          | `true`                 | Set to `false` to keep the tailnet settings on disk with the listener closed.                                                    |
| `ui.alertClearMode`       | `"focus"`              | `"focus"` clears pane alerts on focus, `"manual"` keeps them until you dismiss them.                                             |
| `ui.copyOnSelect`         | `true`                 | Copy a mouse selection to the clipboard when it finishes.                                                                        |
| `ui.unfocusedPaneOpacity` | `1`                    | Opacity of every pane except its tab's focused one. Bounded to 0.1 through 1; `1` dims nothing.                                  |

Nix users can point this file at a dotfiles repository so app edits survive a
rebuild: [docs/integrations/nix.md](docs/integrations/nix.md).

## Integrations

DanTerm is a plain terminal to everything you run in it. These are the tools it
does something extra with, or that need a setting to work well with it.

| Tool | What DanTerm does with it | Setup |
| --- | --- | --- |
| zsh, bash, fish | Tracks cwd, running command, and prompt marks per pane | [shells.md](docs/integrations/shells.md) |
| SSH, mosh | Remote theme and a user@host label on remote panes | [ssh.md](docs/integrations/ssh.md) |
| tmux | Needs two settings, or it eats notifications and invents others | [tmux.md](docs/integrations/tmux.md) |
| Claude Code | Pane-control skill, plus notifications that name their pane | [claude-code.md](docs/integrations/claude-code.md) |
| Codex | Pane-control skill, plus notifications that name their pane | [codex.md](docs/integrations/codex.md) |
| Nix, Home Manager | Flake and `programs.danterm` module | [nix.md](docs/integrations/nix.md) |
| DanTerm for iOS | Drives a pane over a Tailscale tailnet | [tailnet.md](docs/tailnet.md) |

A tool earns a page here when DanTerm ships code for it, or when DanTerm's
behavior with it differs from a plain terminal's. Everything else just works
and needs no page.

```sh
danterm doctor  # Check permissions, CLI, hooks, skills, jq, and configured font.
```

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

The app menus list all shortcuts. Rebind them in Settings > Key Bindings or the
config file: [docs/keybindings.md](docs/keybindings.md).

## Command-line interface

```sh
danterm ls
danterm tab new --cmd 'just test'
danterm pane split -h
danterm pane read --pane "$DANTERM_PANE" --lines 50
```

See [`integrations/danterm/SKILL.md`](integrations/danterm/SKILL.md) for all
commands and examples, and the
[terminal capability contract](docs/terminal-capabilities.md) for terminal
behavior.

## Develop

```sh
bash ./dev-build.sh --no-install  # Build without replacing an installed app.
just provision-worktree           # Run once in a new Git worktree.
just launch-slot                  # Run an isolated development copy.
just test                         # Run the test suite.
```

## License

MIT
