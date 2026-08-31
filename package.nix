{
  lib,
  stdenvNoCC,
  fetchzip,
}:
let
  version = "0.1.24";
in
# stdenvNoCC: no compiler needed — we install a pre-built .app bundle from GitHub Releases.
stdenvNoCC.mkDerivation {
  pname = "danterm";
  inherit version;
  src = fetchzip {
    url = "https://github.com/danneu/danterm/releases/download/v${version}/DanTerm-${version}.zip";
    sha256 = "sha256-77lR7rvEhFxoNiUZX6a5Ir54gueYmxHLvRSQcJQj06I=";
  };
  installPhase = ''
    mkdir -p "$out/Applications/DanTerm.app"
    cp -R . "$out/Applications/DanTerm.app/"

    # This package checks a pinned published ZIP without a source checkout, so
    # the repository-owned bundle layout verifier cannot run here.
    gui="$out/Applications/DanTerm.app/Contents/MacOS/DanTerm"
    cli="$out/Applications/DanTerm.app/Contents/Helpers/danterm"

    test -x "$gui"
    test -x "$cli"

    if cmp -s "$gui" "$cli"; then
      echo "Error: bundled GUI and CLI helper are byte-identical" >&2
      exit 1
    fi

    mkdir -p "$out/bin"
    ln -s "$cli" "$out/bin/danterm"
  '';
  # Prevent the fixup phase from running strip/patchShebangs on the app bundle,
  # which would invalidate the code signature applied during CI.
  # Without a valid signature, macOS won't show the notification permission prompt.
  dontFixup = true;
  meta = {
    mainProgram = "danterm";
    license = lib.licenses.mit;
    platforms = [ "aarch64-darwin" ];
  };
}
