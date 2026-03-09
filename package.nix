{ lib, stdenv, fetchzip }:
let
  version = "0.0.10";
in
stdenv.mkDerivation {
  pname = "danterm";
  inherit version;
  src = fetchzip {
    url = "https://github.com/danneu/danterm/releases/download/v${version}/DanTerm-${version}.zip";
    sha256 = "sha256-qzlYZeRBMdtv3+6azwJq+NFJ/Ow3spT89578I2Xqiik=";
  };
  installPhase = ''
    mkdir -p $out/Applications/DanTerm.app
    cp -R . $out/Applications/DanTerm.app/
  '';
  meta.platforms = [ "aarch64-darwin" ];
}
