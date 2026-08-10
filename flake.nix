{
  description = "DanTerm - custom macOS terminal emulator";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  # Only consumed by checks.x86_64-linux.home-manager-shell-integration, which
  # evaluates hm-module.nix against a real Home Manager rather than a stubbed
  # module harness. Follows our nixpkgs so the evaluated configuration uses the
  # same package set the shell-integration package is built from -- which is
  # also why the pin is a revision, not a branch: Home Manager tracks nixpkgs
  # closely (recent revisions need lib/services/lib.nix, absent from our
  # nixpkgs pin), so the two have to move together. When bumping nixpkgs, bump
  # this to a Home Manager revision of a similar date.
  inputs.home-manager = {
    url = "github:nix-community/home-manager/5a75730e6f21ee624cbf86f4915c6e7489c74acc";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
    }:
    let
      appSystems = [ "aarch64-darwin" ];
      hookSystems = [
        "aarch64-darwin"
        "x86_64-linux"
      ];
      forEachSystem =
        systems: f:
        nixpkgs.lib.genAttrs systems (
          system:
          f system (
            import nixpkgs {
              inherit system;
              overlays = [ self.overlays.default ];
            }
          )
        );
    in
    {
      overlays.default =
        final: prev:
        {
          danterm-claude-notify-osc777 = final.writeShellApplication {
            name = "danterm-claude-notify-osc777";
            runtimeInputs = [ final.jq ];
            bashOptions = [ ];
            text = builtins.readFile ./integrations/claude-code/claude-notify-osc777.sh;
          };
          danterm-claude-agent-session = final.writeShellApplication {
            name = "danterm-claude-agent-session";
            runtimeInputs = [ final.jq ];
            bashOptions = [ ];
            text = builtins.readFile ./integrations/claude-code/danterm-agent-session.sh;
          };
          danterm-codex-agent-session = final.writeShellApplication {
            name = "danterm-codex-agent-session";
            runtimeInputs = [ final.jq ];
            bashOptions = [ ];
            text = builtins.readFile ./integrations/codex/danterm-agent-session.sh;
          };
          # The whole integration directory is installed verbatim, not the three
          # `danterm.$shell` entry points alone: `danterm.bash` sources
          # `vendor/bash-preexec.sh` relative to its own location, so `vendor/`
          # has to stay a sibling. Copying rather than rewriting is also what
          # keeps the packaged assets byte-identical to the source tree.
          danterm-shell-integration = final.stdenvNoCC.mkDerivation {
            pname = "danterm-shell-integration";
            version = "0.0.0";
            src = ./integrations/shell-integration;
            dontConfigure = true;
            dontBuild = true;
            installPhase = ''
              runHook preInstall
              mkdir -p $out/share/danterm-shell-integration
              cp -R . $out/share/danterm-shell-integration/
              runHook postInstall
            '';
          };
          danterm-agent-skill = final.stdenvNoCC.mkDerivation {
            pname = "danterm-agent-skill";
            version = "0.0.0";
            src = ./integrations/danterm;
            dontConfigure = true;
            dontBuild = true;
            installPhase = ''
              runHook preInstall
              mkdir -p $out/share/danterm-agent-skill
              cp -R . $out/share/danterm-agent-skill/
              runHook postInstall
            '';
          };
        }
        // nixpkgs.lib.optionalAttrs (builtins.elem prev.stdenv.hostPlatform.system appSystems) {
          danterm = final.callPackage ./package.nix { };
        };

      packages = forEachSystem hookSystems (
        system: pkgs:
        {
          danterm-agent-skill = pkgs.danterm-agent-skill;
          shell-integration = pkgs.danterm-shell-integration;
          claude-notify-osc777 = pkgs.danterm-claude-notify-osc777;
          claude-agent-session = pkgs.danterm-claude-agent-session;
          codex-agent-session = pkgs.danterm-codex-agent-session;
        }
        // nixpkgs.lib.optionalAttrs (builtins.elem system appSystems) {
          default = pkgs.danterm;
        }
      );

      devShells = forEachSystem appSystems (
        system: pkgs: {
          terminal-workflows = pkgs.mkShell {
            packages = with pkgs; [
              asciinema
              fish
              fzf
            ];
            shellHook = ''
              export PATH="/usr/bin:/bin:/usr/sbin:$PATH"
              unset DEVELOPER_DIR SDKROOT
            '';
          };
        }
      );

      checks = forEachSystem hookSystems (
        system: pkgs:
        {
          claude-notify-osc777 =
            pkgs.runCommand "danterm-claude-notify-osc777-test"
              {
                nativeBuildInputs = with pkgs; [
                  bash
                  jq
                ];
              }
              ''
                mkdir -p integrations
                cp -R ${./integrations/claude-code} integrations/claude-code
                chmod -R u+w integrations
                HOOK_UNDER_TEST=${self.packages.${system}.claude-notify-osc777}/bin/danterm-claude-notify-osc777 \
                  ${pkgs.bash}/bin/bash integrations/claude-code/claude-notify-osc777.test.sh
                touch $out
              '';
          claude-agent-session =
            pkgs.runCommand "danterm-claude-agent-session-test"
              {
                nativeBuildInputs = with pkgs; [
                  bash
                  jq
                ];
              }
              ''
                mkdir -p integrations
                cp -R ${./integrations/claude-code} integrations/claude-code
                chmod -R u+w integrations
                HOOK_UNDER_TEST=${self.packages.${system}.claude-agent-session}/bin/danterm-claude-agent-session \
                  ${pkgs.bash}/bin/bash integrations/claude-code/danterm-agent-session.test.sh
                touch $out
              '';
          codex-agent-session =
            pkgs.runCommand "danterm-codex-agent-session-test"
              {
                nativeBuildInputs = with pkgs; [
                  bash
                  jq
                ];
              }
              ''
                mkdir -p integrations
                cp -R ${./integrations/codex} integrations/codex
                chmod -R u+w integrations
                HOOK_UNDER_TEST=${self.packages.${system}.codex-agent-session}/bin/danterm-codex-agent-session \
                  ${pkgs.bash}/bin/bash integrations/codex/danterm-agent-session.test.sh
                touch $out
              '';
          shell-integration =
            pkgs.runCommand "danterm-shell-integration-test"
              {
                # The test resolves every shell and helper it launches through
                # PATH rather than an absolute path, so each one has to be
                # supplied here -- `expect` included.
                nativeBuildInputs = with pkgs; [
                  bash
                  expect
                  fish
                  hostname
                  zsh
                ];
              }
              ''
                mkdir -p scripts/tests
                cp ${./scripts/tests/shell-integration_test.sh} scripts/tests/shell-integration_test.sh
                chmod -R u+w scripts
                # Against the package output, not the source tree: the shipped
                # layout is what a consumer sources, so that is what the check
                # has to make a tested claim about.
                packaged=${self.packages.${system}.shell-integration}
                DANTERM_INTEGRATION_DIR=$packaged/share/danterm-shell-integration \
                  bash scripts/tests/shell-integration_test.sh
                touch $out
              '';
        }
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          # Non-Darwin evaluation is the module's most fragile claim -- nothing
          # else in it is cross-platform, so a macOS-only reference creeping
          # back in would break only for Linux consumers and only at rebuild
          # time. Building the activation package forces the whole generated
          # configuration here instead. The same build asserts the enable
          # contract in both directions.
          home-manager-shell-integration =
            let
              assets = "${self.packages.${system}.shell-integration}/share/danterm-shell-integration";
              homeFilesFor =
                shells:
                (home-manager.lib.homeManagerConfiguration {
                  inherit pkgs;
                  modules = [
                    self.homeManagerModules.default
                    {
                      home.username = "danterm";
                      home.homeDirectory = "/home/danterm";
                      home.stateVersion = "24.11";
                      # Only shellIntegration: `programs.danterm.enable` stays
                      # false, so no macOS app package may be reached.
                      programs.danterm.shellIntegration.enable = true;
                      programs.bash.enable = shells.bash;
                      programs.zsh.enable = shells.zsh;
                      programs.fish.enable = shells.fish;
                    }
                  ];
                }).activationPackage;
              allShells = homeFilesFor {
                bash = true;
                zsh = true;
                fish = true;
              };
              # zsh off, the other two on: proves the wiring follows each
              # shell's own enable flag rather than being written unconditionally.
              zshDisabled = homeFilesFor {
                bash = true;
                zsh = false;
                fish = true;
              };
            in
            pkgs.runCommand "danterm-home-manager-shell-integration-test" { } ''
              all=${allShells}/home-files
              grep -qF 'DANTERM_SHELL_INTEGRATION_DIR' "$all/.bashrc"
              grep -qF 'source ${assets}/danterm.bash' "$all/.bashrc"
              grep -qF 'DANTERM_SHELL_INTEGRATION_DIR' "$all/.zshrc"
              grep -qF 'source ${assets}/danterm.zsh' "$all/.zshrc"
              grep -qF 'DANTERM_SHELL_INTEGRATION_DIR' "$all/.config/fish/config.fish"
              grep -qF 'source ${assets}/danterm.fish' "$all/.config/fish/config.fish"

              off=${zshDisabled}/home-files
              grep -qF 'source ${assets}/danterm.bash' "$off/.bashrc"
              if [ -e "$off/.zshrc" ] && grep -qF danterm-shell-integration "$off/.zshrc"; then
                echo "zsh is not enabled but received DanTerm wiring" >&2
                exit 1
              fi
              touch $out
            '';
        }
      );

      homeManagerModules.default =
        { pkgs, ... }:
        let
          system = pkgs.stdenv.system;
        in
        {
          imports = [ ./hm-module.nix ];
          # The GUI default is emitted only where a GUI package exists.
          # `packages.<system>.default` is `appSystems`-only, so defining it
          # unconditionally makes the module fail with `attribute 'default'
          # missing` on a Linux host the moment anything forces the option --
          # even one that only wants the shell assets. The shell-integration
          # default is available on every hook system, Linux included.
          programs.danterm = {
            shellIntegration.package = nixpkgs.lib.mkDefault self.packages.${system}.shell-integration;
          }
          // nixpkgs.lib.optionalAttrs (builtins.elem system appSystems) {
            package = nixpkgs.lib.mkDefault self.packages.${system}.default;
          };
        };
    };
}
