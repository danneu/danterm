{ config, lib, pkgs, ... }:
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
  };

  config = mkIf cfg.enable {
    home.packages = [ cfg.package ];

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
