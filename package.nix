{ lib, stdenv, fetchzip }:
let
  version = "0.0.4";
in
stdenv.mkDerivation {
  pname = "danterm";
  inherit version;
  src = fetchzip {
    url = "https://github.com/danneu/danterm/releases/download/v${version}/DanTerm-${version}.zip";
    sha256 = "00l5yn5l6p5asmf9l00yrr2rssrwdgfkm4imb42b6ffd723a3xma";
  };
  installPhase = ''
    mkdir -p $out/Applications/DanTerm.app
    cp -R . $out/Applications/DanTerm.app/
  '';
  meta.platforms = [ "aarch64-darwin" ];
}
