{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.programs.danterm;
in
{
  options.programs.danterm = {
    enable = mkEnableOption "DanTerm terminal emulator";
    package = mkOption {
      type = types.package;
      description = "The DanTerm package to use (default set by flake)";
    };
    startAtLogin = mkOption {
      type = types.bool;
      default = false;
    };
    configPath = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Absolute out-of-store path to DanTerm's app-writable config file";
    };

    # Deliberately outside `programs.danterm.enable`: the shell assets are the
    # only part of DanTerm a non-Darwin host can use, and gating them on the
    # GUI flag would force a macOS-only package into evaluation on a Linux
    # host that only wants a remote shell to report its cwd.
    shellIntegration = {
      enable = mkEnableOption "sourcing the DanTerm shell integration from every enabled shell";
      package = mkOption {
        type = types.package;
        description = "Package providing share/danterm-shell-integration (default set by flake)";
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      home.packages = [ cfg.package ];

      home.file.".config/danterm/config.json" = mkIf (cfg.configPath != null) {
        source = config.lib.file.mkOutOfStoreSymlink cfg.configPath;
      };

      launchd.agents.danterm = mkIf cfg.startAtLogin {
        enable = true;
        config = {
          Label = "com.danneu.danterm";
          ProgramArguments = [
            "${cfg.package}/Applications/DanTerm.app/Contents/MacOS/DanTerm"
          ];
          RunAtLoad = true;
          KeepAlive = false;
        };
      };
    })

    # One user-facing flag, three conditional wirings: a shell is configured if
    # and only if the user already enabled that shell through Home Manager, so
    # enabling this never writes config into a shell they do not use. The
    # Local DanTerm shells follow the running app bundle they advertise. Remote
    # LC_DANTERM shells have no bundle, so they fall back to this package, where
    # `vendor/bash-preexec.sh` remains a sibling of `danterm.bash`.
    (mkIf cfg.shellIntegration.enable (
      let
        assets = "${cfg.shellIntegration.package}/share/danterm-shell-integration";
      in
      mkMerge [
        (mkIf config.programs.bash.enable {
          programs.bash.initExtra = ''
            if [[ -n ''${DANTERM_SHELL_INTEGRATION_DIR:-} ]]; then
              _danterm_asset="$DANTERM_SHELL_INTEGRATION_DIR/danterm.bash"
              if [[ -r $_danterm_asset ]]; then
                source "$_danterm_asset"
              else
                printf 'DanTerm shell integration is unreadable: %s\n' "$_danterm_asset" >&2
              fi
              unset _danterm_asset
            elif [[ -n ''${LC_DANTERM:-} ]]; then
              source ${assets}/danterm.bash
            fi
          '';
        })
        (mkIf config.programs.zsh.enable {
          programs.zsh.initContent = ''
            if [[ -n ''${DANTERM_SHELL_INTEGRATION_DIR:-} ]]; then
              _danterm_asset="$DANTERM_SHELL_INTEGRATION_DIR/danterm.zsh"
              if [[ -r $_danterm_asset ]]; then
                source "$_danterm_asset"
              else
                printf 'DanTerm shell integration is unreadable: %s\n' "$_danterm_asset" >&2
              fi
              unset _danterm_asset
            elif [[ -n ''${LC_DANTERM:-} ]]; then
              source ${assets}/danterm.zsh
            fi
          '';
        })
        (mkIf config.programs.fish.enable {
          programs.fish.interactiveShellInit = ''
            if set -q DANTERM_SHELL_INTEGRATION_DIR; and test -n "$DANTERM_SHELL_INTEGRATION_DIR"
              set -l _danterm_asset "$DANTERM_SHELL_INTEGRATION_DIR/danterm.fish"
              if test -r "$_danterm_asset"
                source "$_danterm_asset"
              else
                printf 'DanTerm shell integration is unreadable: %s\n' "$_danterm_asset" >&2
              end
            else if set -q LC_DANTERM; and test -n "$LC_DANTERM"
              source ${assets}/danterm.fish
            end
          '';
        })
      ]
    ))
  ];
}
