{
  description = "DanTerm - custom terminal emulator using libghostty";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  # Patched Zig 0.15.2 for macOS 26.4+ SDK compatibility, re-exported as
  # packages.<system>.zig_0_15 below (see that comment for the full rationale).
  # Follows our nixpkgs so flake.lock doesn't carry a second nixpkgs node; the
  # brew derivation is self-contained, so its bundled deps come from Homebrew
  # regardless of which nixpkgs wraps it.
  inputs.zig-overlay = {
    url = "github:mitchellh/zig-overlay";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      zig-overlay,
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
          claude-notify-osc777 = pkgs.danterm-claude-notify-osc777;
        }
        // nixpkgs.lib.optionalAttrs (builtins.elem system appSystems) {
          default = pkgs.danterm;
          # Patched Zig 0.15.2 for macOS 26.4+ SDK compatibility.
          #
          # Apple's Xcode 26.4 / Command Line Tools 26.4-26.5 rewrote
          # /usr/lib/libSystem.B.tbd's targets from `arm64-macos` to
          # `arm64e-macos`. Zig 0.15.2's MachO linker
          # (src/link/MachO/Dylib.zig's TargetMatcher) only matches
          # `aarch64-macos` against the old form, so without a patch every
          # libSystem symbol -- _abort, _bzero, _clock_gettime,
          # __availability_version_check, ... -- is undefined and
          # `./build-lib.sh` fails before producing GhosttyKit.xcframework.
          # The fix is in Zig 0.16 (PR #31673) but will NOT be back-ported
          # to 0.15.x (per Ghostty issue #11991).
          #
          # This re-exports mitchellh/zig-overlay's Homebrew-bottled patched
          # 0.15.2. Homebrew applies the fix; zig-overlay wraps the bottle
          # as a self-contained Nix derivation (LLVM/LLD/zstd dylibs
          # bundled). Ghostty itself uses this mechanism (PR #12363).
          #
          # Exposed only as packages.<system>, NOT added to overlays.default:
          # the patch is for the GhosttyKit build only; ~/world's overlay
          # consumers should not inherit a patched system-wide zig.
          #
          # Remove this re-export (and the zig-overlay input) once
          # .ghostty-version bumps to a tag that requires Zig 0.16+ -- then
          # `nixpkgs#zig_0_16` is sufficient.
          #
          # Refs:
          #   - https://codeberg.org/ziglang/zig/issues/31658 (root cause)
          #   - https://codeberg.org/ziglang/zig/pulls/31673  (upstream fix)
          #   - https://github.com/ghostty-org/ghostty/issues/11991 (Ghostty hit it)
          #   - https://github.com/ghostty-org/ghostty/pull/12363 (Ghostty's fix)
          zig_0_15 = zig-overlay.packages.${system}.brew."0.15.2";
        }
      );

      checks = forEachSystem hookSystems (
        system: pkgs: {
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
        }
      );

      homeManagerModules.default =
        { pkgs, ... }:
        {
          imports = [ ./hm-module.nix ];
          programs.danterm.package = nixpkgs.lib.mkDefault (self.packages.${pkgs.stdenv.system}.default);
        };
    };
}
