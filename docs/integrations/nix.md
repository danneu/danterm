# Nix

DanTerm ships a flake and a Home Manager module.

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

## Module options

| Option | Default | Meaning |
| --- | --- | --- |
| `programs.danterm.enable` | `false` | Install the app. |
| `programs.danterm.package` | set by the flake | The DanTerm package to install. |
| `programs.danterm.startAtLogin` | `false` | Launch DanTerm at login. |
| `programs.danterm.configPath` | `null` | Absolute out-of-store path to an app-writable config file. |
| `programs.danterm.shellIntegration.enable` | `false` | Source the [shell integration](shells.md) from every Home Manager shell you have enabled. |
| `programs.danterm.shellIntegration.package` | set by the flake | The package providing the shell assets. |

`shellIntegration` sits deliberately outside `enable`. The shell assets are the
only part of DanTerm a non-Darwin host can use, so a Linux box whose only job
is to report its cwd back over SSH can enable them without pulling a macOS-only
package into evaluation. It wires up only the shells you have already enabled
through Home Manager (`programs.bash`, `programs.zsh`, `programs.fish`).

## Keeping the config in a dotfiles repository

`configPath` makes `~/.config/danterm/config.json` an out-of-store symlink to a
file you own, so Cmd+, edits land in your repository and survive a rebuild:

```nix
programs.danterm.configPath = "/Users/me/src/dotfiles/danterm/config.json";
```

Leave it `null` and Home Manager does not manage the config file at all --
DanTerm creates and owns it as it would for any other user.
