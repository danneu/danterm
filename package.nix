{ lib, stdenvNoCC, fetchzip }:
let
  version = "0.0.47";
in
# stdenvNoCC: no compiler needed — we install a pre-built .app bundle from GitHub Releases.
stdenvNoCC.mkDerivation {
  pname = "danterm";
  inherit version;
  src = fetchzip {
    url = "https://github.com/danneu/danterm/releases/download/v${version}/DanTerm-${version}.zip";
    sha256 = "sha256-MnmAraRf7/8ip1cmSd5wnzyw8oRT2lh677JSrb07fIY=";
  };
  installPhase = ''
    mkdir -p $out/Applications/DanTerm.app
    cp -R . $out/Applications/DanTerm.app/
  '';
  # Prevent the fixup phase from running strip/patchShebangs on the app bundle,
  # which would invalidate the code signature applied during CI.
  # Without a valid signature, macOS won't show the notification permission prompt.
  dontFixup = true;
  meta.platforms = [ "aarch64-darwin" ];
}
