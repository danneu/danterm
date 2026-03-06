{
  description = "DanTerm - custom terminal emulator using libghostty";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
  let
    supportedSystems = [ "aarch64-darwin" ];
    forEachSystem = f: nixpkgs.lib.genAttrs supportedSystems (system:
      f (import nixpkgs { inherit system; overlays = [ self.overlays.default ]; })
    );
  in {
    overlays.default = final: prev: {
      danterm = final.callPackage ./package.nix {};
    };

    packages = forEachSystem (pkgs: {
      default = pkgs.danterm;
    });

    homeManagerModules.default = { pkgs, ... }: {
      imports = [ ./hm-module.nix ];
      programs.danterm.package = nixpkgs.lib.mkDefault
        (self.packages.${pkgs.stdenv.system}.default);
    };
  };
}
