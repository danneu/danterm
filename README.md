# <img src="icon/raw-readme.svg" width="64" height="64" alt="DanTerm icon" align="center" style="vertical-align: middle;"> danterm

A macOS terminal built on ghostty with the behavior I want.

![DanTerm screenshot](docs/screenshot/screenshot1.png)

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

## Non-negotiable features:

- Vertical tab sidebar
- Split panes
- Creating a tab/pane should use the cwd of the previous pane
- Highly visible terminal bell that remains until dismissed
- Notifications from panes toggle the originating pane when clicked

## Bonus features:

- Tabs can be grouped into collapsible sections
- Lightweight: Built with AppKit (Swift) on top of ghostty (zig)
- Launch terminal with specific layout/tabs/panes/commands: `--init <model.json>`

## Keybinds

| Action           | Shortcut |
| ---------------- | -------- |
| New Tab          | ⌘T       |
| Next Tab         | ⇧⌘N      |
| Previous Tab     | ⇧⌘P      |
| Close Pane       | ⌘W       |
| Split Pane Right | ⌘D       |
| Split Pane Down  | ⇧⌘D      |
| Focus Pane Left  | ⇧⌘H      |
| Focus Pane Down  | ⇧⌘J      |
| Focus Pane Up    | ⇧⌘K      |
| Focus Pane Right | ⇧⌘L      |
| Toggle Pane Zoom | ⇧⌘Enter  |
| New Group        | ⇧⌘G      |
| Quit             | ⌘Q       |

## Comparison

| Feature       | DanTerm | iTerm2 | Kitty | WezTerm |
| ------------- | ------- | ------ | ----- | ------- |
| Vertical tabs | Yes     | Yes    | --    | --      |
| Tab groups    | Yes     | --     | --    | --      |
| Fast          | Yes     | --     | Yes   | Yes     |
| Dan           | Yes     | --     | --    | --      |

### iTerm2

iTerm was my go-to macOS terminal for 10+ years, but I've been having enough random issues with it that I figured it would be less of a setback to build my own.

e.g. Copy (cmd-c) was unreliable and notifications never seemed to properly focus the originating pane when using the global hotkey window.

### Kitty/WezTerm

I tried these after iTerm, but they have really bad tab systems. I want something more first class and polished, like browser tabs.
