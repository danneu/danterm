{ lib, stdenvNoCC, fetchzip }:
let
  version = "0.0.50";
in
# stdenvNoCC: no compiler needed — we install a pre-built .app bundle from GitHub Releases.
stdenvNoCC.mkDerivation {
  pname = "danterm";
  inherit version;
  src = fetchzip {
    url = "https://github.com/danneu/danterm/releases/download/v${version}/DanTerm-${version}.zip";
    sha256 = "sha256-b+sg0iCEDVsu0laJMamXco+u4nvTEJaxUDoDUK7ixzs=";
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
