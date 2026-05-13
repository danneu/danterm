{
  description = "DanTerm - custom terminal emulator using libghostty";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
  let
    appSystems = [ "aarch64-darwin" ];
    hookSystems = [ "aarch64-darwin" "x86_64-linux" ];
    forEachSystem = systems: f: nixpkgs.lib.genAttrs systems (system:
      f system (import nixpkgs { inherit system; overlays = [ self.overlays.default ]; })
    );
  in {
    overlays.default = final: prev:
      {
        danterm-claude-notify-osc777 = final.writeShellApplication {
          name = "danterm-claude-notify-osc777";
          runtimeInputs = [ final.jq ];
          bashOptions = [];
          text = builtins.readFile ./integrations/claude-code/claude-notify-osc777.sh;
        };
      } // nixpkgs.lib.optionalAttrs
        (builtins.elem prev.stdenv.hostPlatform.system appSystems)
        {
          danterm = final.callPackage ./package.nix {};
        };

    packages = forEachSystem hookSystems (system: pkgs:
      {
        claude-notify-osc777 = pkgs.danterm-claude-notify-osc777;
      } // nixpkgs.lib.optionalAttrs (builtins.elem system appSystems) {
        default = pkgs.danterm;
      }
    );

    checks = forEachSystem hookSystems (system: pkgs: {
      claude-notify-osc777 = pkgs.runCommand "danterm-claude-notify-osc777-test" {
        nativeBuildInputs = with pkgs; [ bash jq coreutils diffutils findutils ];
      } ''
        mkdir -p integrations
        cp -R ${./integrations/claude-code} integrations/claude-code
        chmod -R u+w integrations
        HOOK_UNDER_TEST=${self.packages.${system}.claude-notify-osc777}/bin/danterm-claude-notify-osc777 \
          ${pkgs.bash}/bin/bash integrations/claude-code/claude-notify-osc777.test.sh
        touch $out
      '';
    });

    homeManagerModules.default = { pkgs, ... }: {
      imports = [ ./hm-module.nix ];
      programs.danterm.package = nixpkgs.lib.mkDefault
        (self.packages.${pkgs.stdenv.system}.default);
    };
  };
}
