{
  description = "DanTerm - custom terminal emulator using libghostty";

  outputs = { self }: {
    homeManagerModules.default = import ./hm-module.nix;
  };
}
