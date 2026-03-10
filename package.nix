{ lib, stdenv, fetchzip }:
let
  version = "0.0.11";
in
stdenv.mkDerivation {
  pname = "danterm";
  inherit version;
  src = fetchzip {
    url = "https://github.com/danneu/danterm/releases/download/v${version}/DanTerm-${version}.zip";
    sha256 = "sha256-uy9gaAdQrurx5w4S7FaDU5jJQ2hY4zfV3KVKdSh+0AU=";
  };
  installPhase = ''
    mkdir -p $out/Applications/DanTerm.app
    cp -R . $out/Applications/DanTerm.app/
  '';
  meta.platforms = [ "aarch64-darwin" ];
}
