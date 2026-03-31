# <img src="icon/raw-readme.svg" width="64" height="64" alt="DanTerm icon" align="center" style="vertical-align: middle;"> danterm

A macOS terminal built on ghostty with the behavior I want.

![DanTerm screenshot](docs/screenshot/screenshot1.png)

_Built-in theme picker sidebar (Cmd+Shift+T):_

![DanTerm theme picker](docs/screenshot/screenshot2.png)

## Install

Download the latest `.dmg` from [Releases](https://github.com/danneu/danterm/releases/latest).

<details>
<summary>Nix (home-manager)</summary>

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager.url = "github:nix-community/home-manager";
    danterm.url = "github:danneu/danterm";
  };

  outputs = { nixpkgs, home-manager, danterm, ... }: {
    homeConfigurations."myuser" = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages.aarch64-darwin;
      modules = [
        danterm.homeManagerModules.default
        {
          programs.danterm.enable = true;
        }
      ];
    };
  };
}
```

</details>

## Usage

Like any other terminal, you probably want to grant DanTerm.app these macOS permissions:

- Settings -> Privacy & Security -> Full Disk Access
- Settings -> Privacy & Security -> Developer Tools

## Configuration

DanTerm uses a config file at `~/.config/danterm/config` with the same `key = value`
format as Ghostty. Open it with **Cmd+,** from the menu bar.

This file is an **overlay** on top of Ghostty's own config (`~/.config/ghostty/config`).
You can put any Ghostty terminal setting in it (fonts, colors, cursor style, etc.) and
it will override the Ghostty config. You can also use DanTerm-specific keys listed below.

```
# Override Ghostty settings for DanTerm
font-size = 14
theme = Dracula

# DanTerm-specific settings
remote-theme = Purplepeter
```

Reload with **Cmd+Shift+,**. Open the underlying Ghostty config with **Cmd+Option+,**.

### DanTerm-specific keys

| Key                | Default       | Description                                               |
| ------------------ | ------------- | --------------------------------------------------------- |
| `remote-theme`     | `Purplepeter` | Ghostty theme applied to panes during SSH/remote sessions |
| `alert-clear-mode` | `focus`       | When to clear pane alerts: `focus` (on pane focus) or `manual` (only via ⌘. / ⇧⌘.) |

Set `alert-clear-mode = manual` to make alerts persist until you explicitly dismiss them with ⌘. (current pane) or ⇧⌘. (all panes in tab). This is useful when you want alerts to act as a to-do list — focusing a pane to check what triggered the alert won't clear it, so the badge stays visible as a reminder to come back to it.

## Non-negotiable features:

- Vertical tab sidebar
- Split panes
- Creating a tab/pane should use the cwd of the previous pane
- Highly visible terminal bell that remains until dismissed
- Notifications from panes toggle the originating pane when clicked

## Bonus features:

- Tabs can be grouped into collapsible sections
- Lightweight: Built with AppKit (Swift) on top of ghostty (zig)
- Theme browser sidebar lets you change the current pane's theme on the fly
- Remote session integration (ssh, mosh, etc)
  - Give remote sessions a custom theme
- Launch terminal with specific layout/tabs/panes/commands: `--init <model.json>`
- Dump and restore danterm state from a json file
- Restore danterm state if it detects non-graceful exit

## General terminal features

- Cmd-click to open URL and file paths
  - Cmd-shift-click needed if program is capturing mouse events (vim, tmux, etc). The shift modifier tells ghostty the click is for you, not the program.

## Claude Code Integration

For some reason, Claude Code seems to wait 1-2 minutes before sending an OSC 777 / OSC 9 notification when it's waiting for a response.

To work around this, create a script (e.g. `~/.claude/hooks/claude-notify.sh`):

(Must have [jq](https://jqlang.org/) installed)

```bash
#!/usr/bin/env bash
# Extracts Claude's last message and sends an OSC 777 notification.
MSG=$(cat | jq -r '.last_assistant_message // empty' | head -c 200)
printf '\e]777;notify;Claude Code;%s\a' "${MSG:-Claude finished responding}" > /dev/tty
```

Then add a `Stop` hook to your Claude Code settings (`~/.claude/settings.json`):

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/claude-notify.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

DanTerm turns OSC 777 and OSC 9 messages into a macOS notification that, when
clicked, will take you to the originating pane.

## OpenAI Codex Integration

Codex already works out of the box. Dunno what's wrong with Claude Code.

## Shell Integration

DanTerm can export its state or load from a state file.

This state includes the tab groups, tabs, pane layout, cwd of each pane, and
(once you opt in) the command running in each pane.

Add the snippet for your shell to opt in. It's zero-cost when not running inside DanTerm.

<details>
<summary>Zsh (~/.zshrc)</summary>

```zsh
# Restore scrollback from previous DanTerm session
if [[ -n "$DANTERM_RESTORE_SCROLLBACK_FILE" ]]; then
  _danterm_sbf="$DANTERM_RESTORE_SCROLLBACK_FILE"
  unset DANTERM_RESTORE_SCROLLBACK_FILE
  if [[ -r "$_danterm_sbf" ]]; then
    /bin/cat -- "$_danterm_sbf" 2>/dev/null || true
    /bin/rm -f -- "$_danterm_sbf" >/dev/null 2>&1 || true
  fi
  unset _danterm_sbf
fi

# Report current command to DanTerm.app
if [[ -n "$DANTERM_TOKEN" ]]; then
  typeset -g _danterm_tok="$DANTERM_TOKEN"
  unset DANTERM_TOKEN
  _danterm_b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
  _danterm_preexec() {
    printf '\e]0;__DANTERM_EVT__:%s:CMD_START:%s\a' "$_danterm_tok" "$(_danterm_b64 "$1")"
    printf '\e]0;%s\a' "$1"
  }
  _danterm_precmd() {
    printf '\e]0;__DANTERM_EVT__:%s:CMD_END\a' "$_danterm_tok"
    printf '\e]0;%s\a' "${(%):-%(4~|…/%3~|%~)}"
  }
  preexec_functions+=(_danterm_preexec)
  precmd_functions+=(_danterm_precmd)
  # Remote session detection: wraps ssh/mosh to emit REMOTE_START event
  ssh() {
    printf '\e]0;__DANTERM_EVT__:%s:REMOTE_START\a' "$_danterm_tok"
    command ssh "$@"
  }
  mosh() {
    printf '\e]0;__DANTERM_EVT__:%s:REMOTE_START\a' "$_danterm_tok"
    command mosh "$@"
  }
fi
```

</details>

<details>
<summary>Fish (~/.config/fish/config.fish)</summary>

```fish
# Restore scrollback from previous DanTerm session
if set -q DANTERM_RESTORE_SCROLLBACK_FILE
  set -l f $DANTERM_RESTORE_SCROLLBACK_FILE
  set -e DANTERM_RESTORE_SCROLLBACK_FILE
  if test -r "$f"
    /bin/cat -- "$f" 2>/dev/null; or true
    /bin/rm -f -- "$f" >/dev/null 2>&1; or true
  end
end

# Report current command to DanTerm.app
if set -q DANTERM_TOKEN
  set -g _danterm_tok $DANTERM_TOKEN
  set -e DANTERM_TOKEN
  function __danterm_preexec --on-event fish_preexec
    set -l b64 (printf '%s' $argv[1] | base64 | string replace -a '\n' '')
    printf '\e]0;__DANTERM_EVT__:%s:CMD_START:%s\a' $_danterm_tok $b64
    printf '\e]0;%s\a' $argv[1]
  end
  function __danterm_postcmd --on-event fish_prompt
    printf '\e]0;__DANTERM_EVT__:%s:CMD_END\a' $_danterm_tok
    printf '\e]0;%s\a' (prompt_pwd)
  end
  # Remote session detection: wraps ssh/mosh to emit REMOTE_START event
  function ssh --wraps ssh
    printf '\e]0;__DANTERM_EVT__:%s:REMOTE_START\a' $_danterm_tok
    command ssh $argv
  end
  function mosh --wraps mosh
    printf '\e]0;__DANTERM_EVT__:%s:REMOTE_START\a' $_danterm_tok
    command mosh $argv
  end
end
```

</details>

## Keybinds

| Action                         | Shortcut |
| ------------------------------ | -------- |
| New Tab                        | ⌘T       |
| Next Tab                       | ⇧⌘N      |
| Previous Tab                   | ⇧⌘P      |
| Close Pane                     | ⌘W       |
| Close Tab                      | ⇧⌘W      |
| Split Pane Right               | ⌘D       |
| Split Pane Down                | ⇧⌘D      |
| Focus Pane Left                | ⇧⌘H      |
| Focus Pane Down                | ⇧⌘J      |
| Focus Pane Up                  | ⇧⌘K      |
| Focus Pane Right               | ⇧⌘L      |
| Toggle Pane Zoom               | ⌘Enter   |
| New Group                      | ⌘N       |
| Go to Most Recent Unread Alert | ⇧⌘A      |
| Clear Pane Alerts              | ⌘.       |
| Clear Tab Alerts               | ⇧⌘.      |
| Open DanTerm Config            | ⌘,       |
| Open Ghostty Config            | ⌥⌘,      |
| Reload Config                  | ⇧⌘,      |
| Quit                           | ⌘Q       |

## Comparison

| Feature        | DanTerm | [cmux][cmux] | iTerm2 | Kitty |
| -------------- | ------- | ------------ | ------ | ----- |
| Vertical tabs  | Yes     | Yes          | Yes    | --    |
| Tab groups     | Yes     | Yes          | --     | --    |
| Fast           | Yes     | Yes          | --     | Yes   |
| No browser     | Yes     | --           | --     | Yes   |
| No nested tabs | Yes     | --           | Yes    | Yes   |
| Dan            | Yes     | --           | --     | --    |

[cmux]: https://github.com/manaflow-ai/cmux

As you can see, DanTerm is the clear winner.

### iTerm2

iTerm was my go-to macOS terminal for 10+ years, but I've been having enough random issues with it that I figured it would be less of a setback to build my own.

e.g. Copy (cmd-c) was unreliable and notifications never seemed to properly focus the originating pane when using the global hotkey window.

### Kitty/WezTerm

I tried these after iTerm, but they have really bad tab systems. I want something more first class and polished, like browser tabs.

### cmux

Cmux is a really good idea: https://github.com/manaflow-ai/cmux

But it's more complicated than I'd like since it includes a browser, and its panes can contain tabs.

## Development

The dev loop is to make changes and `just build-run` to try them out.

- `just build` or `bash ./dev-build.sh` to build a local dev app to
  ".build/DanTerm Dev.app" and copy to "~/Applications/DanTerm Dev.app".
- `just build-run` or `bash ./dev-build-run.sh` to build + run it.

I don't remember why, but there was some benefit to running the app from the macOS applications folder during dev.

I think so that it shows up in permissions lists in macOS settings.
