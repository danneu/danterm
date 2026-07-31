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
  };

  config = mkIf cfg.enable {
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
  };
}
