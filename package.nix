{ lib, stdenv, fetchzip }:
let
  version = "0.0.12";
in
stdenv.mkDerivation {
  pname = "danterm";
  inherit version;
  src = fetchzip {
    url = "https://github.com/danneu/danterm/releases/download/v${version}/DanTerm-${version}.zip";
    sha256 = "sha256-MOS5HOhn5BmiCY0lnBk6SuyhBxXEvUlUVYdOtdPtwuA=";
  };
  installPhase = ''
    mkdir -p $out/Applications/DanTerm.app
    cp -R . $out/Applications/DanTerm.app/
  '';
  meta.platforms = [ "aarch64-darwin" ];
}
